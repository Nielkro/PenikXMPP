#include "dinox_webrtc.h"
#include "dinox_webrtc_video_decoder_factory.hpp"
#include "dinox_webrtc_video_effects.hpp"
#include "dinox_webrtc_video_effect_config.hpp"
#include "dinox_webrtc_video_background_protocol.hpp"
#include "dinox_webrtc_worker_proxy.hpp"

#include <array>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cctype>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <memory>
#include <mutex>
#include <new>
#include <limits>
#include <optional>
#include <span>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <fcntl.h>

#include "api/audio_options.h"
#include "api/audio/audio_mixer.h"
#include "api/audio/builtin_audio_processing_builder.h"
#include "api/audio_codecs/builtin_audio_decoder_factory.h"
#include "api/audio_codecs/builtin_audio_encoder_factory.h"
#include "api/create_peerconnection_factory.h"
#include "api/environment/environment_factory.h"
#include "api/jsep.h"
#include "api/make_ref_counted.h"
#include "api/media_stream_interface.h"
#include "api/media_types.h"
#include "api/peer_connection_interface.h"
#include "api/rtp_transceiver_direction.h"
#include "api/rtp_transceiver_interface.h"
#include "api/rtp_receiver_interface.h"
#include "api/rtp_sender_interface.h"
#include "api/rtc_error.h"
#include "api/rtc_event_log_output.h"
#include "api/scoped_refptr.h"
#include "api/stats/rtc_stats_collector_callback.h"
#include "api/stats/rtcstats_objects.h"
#include "api/units/time_delta.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_broadcaster.h"
#include "api/video/video_frame.h"
#include "api/video/video_sink_interface.h"
#include "api/video_codecs/builtin_video_decoder_factory.h"
#include "api/video_codecs/builtin_video_encoder_factory.h"
#include "modules/audio_device/include/audio_device_default.h"
#include "modules/audio_mixer/audio_mixer_impl.h"
#include "modules/video_capture/video_capture_defines.h"
#include "modules/video_capture/video_capture_factory.h"
#include "libyuv/convert_argb.h"
#include "pc/video_track_source.h"
#include "rtc_base/crypto_random.h"
#include "rtc_base/ssl_adapter.h"
#include "rtc_base/ref_counted_object.h"
#include "rtc_base/thread.h"

#if defined(WEBRTC_WIN)
#include <io.h>
#include <sys/stat.h>
#include "modules/audio_device/include/audio_device_factory.h"
#include "rtc_base/win/scoped_com_initializer.h"
#include "rtc_base/win32_socket_init.h"
#else
#include <unistd.h>
#include "modules/audio_device/audio_device_impl.h"
#endif

#ifndef DINOX_WEBRTC_MILESTONE
#define DINOX_WEBRTC_MILESTONE 0
#endif

#ifndef DINOX_WEBRTC_BRANCH
#define DINOX_WEBRTC_BRANCH "unknown"
#endif

#ifndef DINOX_WEBRTC_COMMIT
#define DINOX_WEBRTC_COMMIT "unknown"
#endif

#ifndef DINOX_WEBRTC_ARTIFACT_ABI
#define DINOX_WEBRTC_ARTIFACT_ABI "unknown"
#endif

static const DinoXWebrtcBuildInfo kBuildInfo = {
    DINOX_WEBRTC_ABI_VERSION,
    DINOX_WEBRTC_MILESTONE,
    DINOX_WEBRTC_BRANCH,
    DINOX_WEBRTC_COMMIT,
    DINOX_WEBRTC_ARTIFACT_ABI,
    1,
};

namespace {

struct SessionCore;
struct VideoPipelineCore;
class SyntheticVideoTrackSource;

bool copy_session_callbacks(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcCallbacks* out_callbacks,
    void** out_user_data,
    std::unique_lock<std::recursive_mutex>* out_callback_lock);

bool route_outgoing_video_frame(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    const webrtc::scoped_refptr<SyntheticVideoTrackSource>& source,
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    uint64_t camera_lease = 0);

void prune_video_pipeline_attachments_locked(VideoPipelineCore* core);
DinoXWebrtcVideoPipelineState video_pipeline_state_locked(VideoPipelineCore* core);

std::mutex g_ssl_mutex;
unsigned int g_ssl_ref_count = 0;
std::atomic<uint64_t> g_next_control_object_id{1};

DinoXWebrtcStatus retain_ssl() {
    std::lock_guard<std::mutex> lock(g_ssl_mutex);
    if (g_ssl_ref_count == 0 && !webrtc::InitializeSSL()) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    ++g_ssl_ref_count;
    return DINOX_WEBRTC_STATUS_OK;
}

bool recorder_debug_enabled() {
    const char* enabled = std::getenv("DINOX_WEBRTC_RECORDER_DEBUG");
    return enabled != nullptr &&
        (std::strcmp(enabled, "1") == 0 ||
         std::strcmp(enabled, "true") == 0 ||
         std::strcmp(enabled, "yes") == 0);
}

void recorder_debug(const char* message) {
    if (!recorder_debug_enabled() || message == nullptr) {
        return;
    }
    std::fprintf(stderr, "DinoX WebRTC recorder: %s\n", message);
}

bool lifecycle_debug_enabled() {
    const char* enabled = std::getenv("DINOX_GOOGLE_WEBRTC_LIFECYCLE_DEBUG");
    return enabled != nullptr &&
        (std::strcmp(enabled, "1") == 0 ||
         std::strcmp(enabled, "true") == 0 ||
         std::strcmp(enabled, "yes") == 0);
}

bool device_debug_enabled() {
    const char* enabled = std::getenv("DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG");
    return enabled != nullptr &&
        (std::strcmp(enabled, "1") == 0 ||
         std::strcmp(enabled, "true") == 0 ||
         std::strcmp(enabled, "yes") == 0);
}

uint32_t video_effect_test_block_us() {
    const char* value = std::getenv("DINOX_WEBRTC_VIDEO_EFFECT_TEST_BLOCK_US");
    if (value == nullptr || value[0] == '\0') return 0;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 10);
    if (end == value || *end != '\0' || parsed > UINT32_MAX) return 0;
    return static_cast<uint32_t>(parsed);
}

bool is_enabled_video_effect(const DinoXWebrtcVideoEffectConfig& config) {
    return dinox::webrtc_effects::active_config(config);
}

void device_debug(const char* format, ...) {
    if (!device_debug_enabled() || format == nullptr) {
        return;
    }

    static std::mutex debug_mutex;
    std::lock_guard<std::mutex> lock(debug_mutex);
    FILE* output = stderr;
    const char* path = std::getenv("DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG_FILE");
    if (path != nullptr && path[0] != '\0') {
        FILE* file = std::fopen(path, "a");
        if (file != nullptr) {
            output = file;
        }
    }

    va_list arguments;
    va_start(arguments, format);
    std::vfprintf(output, format, arguments);
    va_end(arguments);
    std::fflush(output);
    if (output != stderr) {
        std::fclose(output);
    }
}

bool call_debug_enabled() {
    const char* enabled = std::getenv("DINOX_GOOGLE_WEBRTC_CALL_DEBUG");
    return enabled != nullptr &&
        (std::strcmp(enabled, "1") == 0 ||
         std::strcmp(enabled, "true") == 0 ||
         std::strcmp(enabled, "yes") == 0);
}

class BoundedRtcEventLogOutput final : public webrtc::RtcEventLogOutput {
 public:
    BoundedRtcEventLogOutput(FILE* file, size_t limit) : file_(file), limit_(limit) {}
    ~BoundedRtcEventLogOutput() override { std::fclose(file_); }

    bool IsActive() const override { return active_.load(); }

    bool Write(absl::string_view output) override {
        // WebRTC serializes writes and destruction on its event-log task queue.
        if (!active_.load() || output.size() > limit_ - written_ ||
                std::fwrite(output.data(), 1, output.size(), file_) != output.size()) {
            active_.store(false);
            return false;
        }
        written_ += output.size();
        return true;
    }

    void Flush() override {
        if (std::fflush(file_) != 0) active_.store(false);
    }

 private:
    FILE* const file_;
    const size_t limit_;
    size_t written_ = 0;
    std::atomic<bool> active_{true};
};

bool start_rtc_event_log(
        const webrtc::scoped_refptr<webrtc::PeerConnectionInterface>& peer_connection) {
#if defined(WEBRTC_WIN)
    const wchar_t* directory = _wgetenv(L"DINOX_GOOGLE_WEBRTC_RTC_EVENT_LOG_DIR");
    const wchar_t* debug = _wgetenv(L"DINOX_GOOGLE_WEBRTC_CALL_DEBUG");
    if (peer_connection == nullptr || directory == nullptr || directory[0] == L'\0' ||
            debug == nullptr || std::wcscmp(debug, L"1") != 0) {
        return false;
    }
#else
    const char* directory = std::getenv("DINOX_GOOGLE_WEBRTC_RTC_EVENT_LOG_DIR");
    const char* debug = std::getenv("DINOX_GOOGLE_WEBRTC_CALL_DEBUG");
    if (peer_connection == nullptr || directory == nullptr || directory[0] == '\0' ||
            debug == nullptr || std::strcmp(debug, "1") != 0) {
        return false;
    }
#endif

    // The launcher supplies an existing private directory. Do not alter it.
    // Exclusive creation keeps traces independent; the directory controls Windows ACLs.
    std::filesystem::path path;
    int fd = -1;
    for (int attempt = 0; attempt < 16; ++attempt) {
        std::string suffix;
        if (!webrtc::CreateRandomString(12,
                "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_", &suffix)) {
            std::fprintf(stderr, "DinoX WebRTC RTC event log: status=random-name-failed\n");
            return false;
        }
        path = std::filesystem::path(directory) / ("dinox-webrtc-rtc-" + suffix);
#if defined(WEBRTC_WIN)
        fd = _wopen(path.c_str(),
            _O_WRONLY | _O_CREAT | _O_EXCL | _O_NOINHERIT | _O_BINARY,
            _S_IREAD | _S_IWRITE);
#else
        int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_CLOEXEC
        flags |= O_CLOEXEC;
#endif
        fd = open(path.c_str(), flags, 0600);
#ifndef O_CLOEXEC
        if (fd >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) {
            close(fd);
            unlink(path.c_str());
            std::fprintf(stderr, "DinoX WebRTC RTC event log: status=close-on-exec-failed\n");
            return false;
        }
#endif
#endif
        if (fd >= 0 || errno != EEXIST) break;
    }
    if (fd < 0) {
        std::fprintf(stderr, "DinoX WebRTC RTC event log: status=create-file-failed\n");
        return false;
    }
#if defined(WEBRTC_WIN)
    FILE* file = _fdopen(fd, "wb");
#else
    FILE* file = fdopen(fd, "wb");
#endif
    if (file == nullptr) {
#if defined(WEBRTC_WIN)
        _close(fd);
        _wunlink(path.c_str());
#else
        close(fd);
        unlink(path.c_str());
#endif
        std::fprintf(stderr, "DinoX WebRTC RTC event log: status=open-stream-failed\n");
        return false;
    }

    constexpr size_t kMaxRtcEventLogBytes = 4 * 1024 * 1024;
    auto output = std::make_unique<BoundedRtcEventLogOutput>(
        file, kMaxRtcEventLogBytes);
    // StartRtcEventLog closes and destroys the output even if starting fails.
    const bool started = peer_connection->StartRtcEventLog(std::move(output));
    const auto utf8_path = path.u8string();
    const std::string logged_path(utf8_path.begin(), utf8_path.end());
    std::fprintf(stderr,
        "DinoX WebRTC RTC event log: status=%s path=%s max-bytes=%zu\n",
        started ? "started" : "start-failed", logged_path.c_str(), kMaxRtcEventLogBytes);
    return started;
}

class LifecycleTrace final {
 public:
    explicit LifecycleTrace(const char* operation)
        : operation_(operation),
          enabled_(lifecycle_debug_enabled()),
          started_(std::chrono::steady_clock::now()) {}

    ~LifecycleTrace() {
        if (!enabled_) return;
        const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started_).count();
        std::fprintf(
            stderr,
            "DinoX WebRTC lifecycle: operation=%s duration_us=%lld\n",
            operation_ == nullptr ? "unknown" : operation_,
            static_cast<long long>(elapsed));
    }

 private:
    const char* operation_;
    bool enabled_;
    std::chrono::steady_clock::time_point started_;
};

void release_ssl() {
    std::lock_guard<std::mutex> lock(g_ssl_mutex);
    if (g_ssl_ref_count == 0) {
        return;
    }
    --g_ssl_ref_count;
    if (g_ssl_ref_count == 0) {
        webrtc::CleanupSSL();
    }
}

webrtc::RtpTransceiverDirection to_webrtc_direction(DinoXWebrtcMediaDirection direction) {
    switch (direction) {
        case DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV:
            return webrtc::RtpTransceiverDirection::kSendRecv;
        case DINOX_WEBRTC_MEDIA_DIRECTION_SEND_ONLY:
            return webrtc::RtpTransceiverDirection::kSendOnly;
        case DINOX_WEBRTC_MEDIA_DIRECTION_RECV_ONLY:
            return webrtc::RtpTransceiverDirection::kRecvOnly;
        case DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE:
            return webrtc::RtpTransceiverDirection::kInactive;
    }
    return webrtc::RtpTransceiverDirection::kSendRecv;
}

webrtc::SdpType to_webrtc_sdp_type(DinoXWebrtcSdpType type) {
    switch (type) {
        case DINOX_WEBRTC_SDP_TYPE_OFFER:
            return webrtc::SdpType::kOffer;
        case DINOX_WEBRTC_SDP_TYPE_ANSWER:
            return webrtc::SdpType::kAnswer;
    }
    return webrtc::SdpType::kOffer;
}

DinoXWebrtcSdpType from_webrtc_sdp_type(webrtc::SdpType type) {
    switch (type) {
        case webrtc::SdpType::kAnswer:
            return DINOX_WEBRTC_SDP_TYPE_ANSWER;
        case webrtc::SdpType::kOffer:
        case webrtc::SdpType::kPrAnswer:
        case webrtc::SdpType::kRollback:
            return DINOX_WEBRTC_SDP_TYPE_OFFER;
    }
    return DINOX_WEBRTC_SDP_TYPE_OFFER;
}

DinoXWebrtcPeerConnectionState from_webrtc_peer_connection_state(
    webrtc::PeerConnectionInterface::PeerConnectionState state) {
    switch (state) {
        case webrtc::PeerConnectionInterface::PeerConnectionState::kNew:
            return DINOX_WEBRTC_PEER_CONNECTION_STATE_NEW;
        case webrtc::PeerConnectionInterface::PeerConnectionState::kConnecting:
            return DINOX_WEBRTC_PEER_CONNECTION_STATE_CONNECTING;
        case webrtc::PeerConnectionInterface::PeerConnectionState::kConnected:
            return DINOX_WEBRTC_PEER_CONNECTION_STATE_CONNECTED;
        case webrtc::PeerConnectionInterface::PeerConnectionState::kDisconnected:
            return DINOX_WEBRTC_PEER_CONNECTION_STATE_DISCONNECTED;
        case webrtc::PeerConnectionInterface::PeerConnectionState::kFailed:
            return DINOX_WEBRTC_PEER_CONNECTION_STATE_FAILED;
        case webrtc::PeerConnectionInterface::PeerConnectionState::kClosed:
            return DINOX_WEBRTC_PEER_CONNECTION_STATE_CLOSED;
    }
    return DINOX_WEBRTC_PEER_CONNECTION_STATE_NEW;
}

DinoXWebrtcIceConnectionState from_webrtc_ice_connection_state(
    webrtc::PeerConnectionInterface::IceConnectionState state) {
    switch (state) {
        case webrtc::PeerConnectionInterface::kIceConnectionNew:
            return DINOX_WEBRTC_ICE_CONNECTION_STATE_NEW;
        case webrtc::PeerConnectionInterface::kIceConnectionChecking:
            return DINOX_WEBRTC_ICE_CONNECTION_STATE_CHECKING;
        case webrtc::PeerConnectionInterface::kIceConnectionConnected:
            return DINOX_WEBRTC_ICE_CONNECTION_STATE_CONNECTED;
        case webrtc::PeerConnectionInterface::kIceConnectionCompleted:
            return DINOX_WEBRTC_ICE_CONNECTION_STATE_COMPLETED;
        case webrtc::PeerConnectionInterface::kIceConnectionFailed:
            return DINOX_WEBRTC_ICE_CONNECTION_STATE_FAILED;
        case webrtc::PeerConnectionInterface::kIceConnectionDisconnected:
            return DINOX_WEBRTC_ICE_CONNECTION_STATE_DISCONNECTED;
        case webrtc::PeerConnectionInterface::kIceConnectionClosed:
        case webrtc::PeerConnectionInterface::kIceConnectionMax:
            return DINOX_WEBRTC_ICE_CONNECTION_STATE_CLOSED;
    }
    return DINOX_WEBRTC_ICE_CONNECTION_STATE_NEW;
}

class CountingAudioSink final : public webrtc::AudioTrackSinkInterface {
 public:
    void OnData(
        const void* audio_data,
        int bits_per_sample,
        int,
        size_t number_of_channels,
        size_t number_of_frames) override {
        record(audio_data, bits_per_sample, number_of_channels, number_of_frames);
    }

    void OnData(
        const void* audio_data,
        int bits_per_sample,
        int,
        size_t number_of_channels,
        size_t number_of_frames,
        std::optional<int64_t>) override {
        record(audio_data, bits_per_sample, number_of_channels, number_of_frames);
    }

    void snapshot(
        uint64_t* out_frame_count,
        uint64_t* out_sample_count,
        double* out_peak_level) const {
        if (out_frame_count == nullptr ||
            out_sample_count == nullptr ||
            out_peak_level == nullptr) {
            return;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        *out_frame_count = frame_count_;
        *out_sample_count = sample_count_;
        *out_peak_level = peak_level_;
    }

 private:
    void record(
        const void* audio_data,
        int bits_per_sample,
        size_t number_of_channels,
        size_t number_of_frames) {
        double peak_level = 0.0;
        if (audio_data != nullptr && bits_per_sample == 16 && number_of_channels > 0) {
            const size_t sample_count = number_of_frames * number_of_channels;
            const int16_t* samples = static_cast<const int16_t*>(audio_data);
            int peak = 0;
            for (size_t i = 0; i < sample_count; i++) {
                int value = static_cast<int>(samples[i]);
                if (value < 0) {
                    value = -value;
                }
                if (value > peak) {
                    peak = value;
                }
            }
            peak_level = static_cast<double>(peak) / 32768.0;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        frame_count_ += static_cast<uint64_t>(number_of_frames);
        sample_count_ += static_cast<uint64_t>(number_of_frames) *
            static_cast<uint64_t>(number_of_channels);
        if (peak_level > peak_level_) {
            peak_level_ = peak_level;
        }
    }

    mutable std::mutex mutex_;
    uint64_t frame_count_ = 0;
    uint64_t sample_count_ = 0;
    double peak_level_ = 0.0;
};

struct RemoteAudioSinkBinding {
    webrtc::scoped_refptr<webrtc::AudioTrackInterface> track;
    std::unique_ptr<CountingAudioSink> sink;
};

int64_t monotonic_time_us() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

int16_t clamp_int16(int value) {
    if (value < -32768) return -32768;
    if (value > 32767) return 32767;
    return static_cast<int16_t>(value);
}

constexpr int kRemoteRenderTargetPixelCount = 640 * 480;
constexpr int kRemoteRenderMaxPixelCount = 1280 * 720;

std::pair<int, int> bounded_video_dimensions(
    int width,
    int height,
    int max_pixel_count) {
    if (width <= 0 || height <= 0 || max_pixel_count <= 0 ||
            static_cast<int64_t>(width) * height <= max_pixel_count) {
        return {width, height};
    }

    const double factor = std::sqrt(
        static_cast<double>(max_pixel_count) /
        static_cast<double>(static_cast<int64_t>(width) * height));
    int output_width = std::max(2, static_cast<int>(std::floor(width * factor))) & ~1;
    int output_height = std::max(2, static_cast<int>(std::floor(height * factor))) & ~1;
    while (static_cast<int64_t>(output_width) * output_height > max_pixel_count) {
        if (output_width >= output_height && output_width > 2) {
            output_width -= 2;
        } else if (output_height > 2) {
            output_height -= 2;
        } else {
            break;
        }
    }
    return {output_width, output_height};
}

std::optional<webrtc::VideoFrame> make_black_video_frame(int width, int height) {
    if (width <= 0 || height <= 0) {
        return std::nullopt;
    }

    webrtc::scoped_refptr<webrtc::I420Buffer> buffer =
        webrtc::I420Buffer::Create(width, height);
    if (buffer == nullptr) {
        return std::nullopt;
    }
    webrtc::I420Buffer::SetBlack(buffer.get());

    return webrtc::VideoFrame::Builder()
        .set_video_frame_buffer(buffer)
        .set_timestamp_us(monotonic_time_us())
        .build();
}

bool emit_video_frame_callback(
    DinoXWebrtcVideoFrameCallback callback,
    DinoXWebrtcSession* session,
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    int max_output_pixel_count,
    void* user_data) {
    if (callback == nullptr || session == nullptr) {
        return false;
    }

    webrtc::scoped_refptr<webrtc::VideoFrameBuffer> buffer =
        frame.video_frame_buffer();
    if (buffer == nullptr) {
        return false;
    }
    webrtc::scoped_refptr<webrtc::I420BufferInterface> i420 =
        buffer->ToI420();
    if (i420 == nullptr) {
        return false;
    }

    // RTP CVO (urn:3gpp:video-orientation) deliberately allows the sender to
    // transmit camera-native pixels and carry the display rotation as frame
    // metadata.  GTK receives raw BGRA bytes through this callback and cannot
    // apply VideoFrame::rotation() itself, so consume any pending rotation
    // before scaling and copying the frame across the process boundary.
    if (frame.rotation() != webrtc::kVideoRotation_0) {
        webrtc::scoped_refptr<webrtc::I420Buffer> rotated =
            webrtc::I420Buffer::Rotate(*i420, frame.rotation());
        if (rotated == nullptr) {
            return false;
        }
        i420 = rotated;
    }

    const auto [width, height] = bounded_video_dimensions(
        i420->width(), i420->height(), max_output_pixel_count);
    if (width <= 0 || height <= 0) {
        return false;
    }

    if (width != i420->width() || height != i420->height()) {
        webrtc::scoped_refptr<webrtc::I420Buffer> scaled =
            webrtc::I420Buffer::Create(width, height);
        if (scaled == nullptr) {
            return false;
        }
        scaled->ScaleFrom(*i420);
        i420 = scaled;
    }

    const int stride = width * 4;
    // DinoX exposes video frames to GTK and ffmpeg as B8G8R8A8/BGRA bytes.
    // In libyuv naming, ARGB little-endian is "bgra in memory"; I420ToBGRA
    // would produce argb-in-memory and swaps red/blue for our consumers.
    std::vector<uint8_t> bgra(static_cast<size_t>(stride) * static_cast<size_t>(height));
    const int convert_status = libyuv::I420ToARGB(
        i420->DataY(),
        i420->StrideY(),
        i420->DataU(),
        i420->StrideU(),
        i420->DataV(),
        i420->StrideV(),
        bgra.data(),
        stride,
        width,
        height);
    if (convert_status != 0) {
        return false;
    }

    callback(
        session,
        bgra.data(),
        width,
        height,
        stride,
        frame_id,
        user_data);
    return true;
}

class CountingVideoSink final : public webrtc::VideoSinkInterface<webrtc::VideoFrame> {
 public:
    CountingVideoSink(
        std::weak_ptr<SessionCore> core,
        DinoXWebrtcSession* session)
        : core_(std::move(core)),
          session_(session) {}

    void OnFrame(const webrtc::VideoFrame& frame) override {
        uint64_t frame_id = 0;
        int oriented_width = frame.width();
        int oriented_height = frame.height();
        if (frame.rotation() == webrtc::kVideoRotation_90 ||
                frame.rotation() == webrtc::kVideoRotation_270) {
            std::swap(oriented_width, oriented_height);
        }
        const auto [output_width, output_height] = bounded_video_dimensions(
            oriented_width, oriented_height, kRemoteRenderTargetPixelCount);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            frame_count_ += 1;
            frame_id = frame_count_;
            last_width_ = output_width;
            last_height_ = output_height;
        }

        auto core = core_.lock();
        if (core == nullptr || session_ == nullptr) {
            return;
        }

        DinoXWebrtcCallbacks callbacks = {};
        void* user_data = nullptr;
        std::unique_lock<std::recursive_mutex> callback_lock;
        if (!copy_session_callbacks(core, &callbacks, &user_data, &callback_lock) ||
            callbacks.on_video_frame == nullptr) {
            return;
        }

        const bool delivered = emit_video_frame_callback(
            callbacks.on_video_frame,
            session_,
            frame,
            frame_id,
            kRemoteRenderTargetPixelCount,
            user_data);
        if (call_debug_enabled() && frame_id == 1) {
            std::fprintf(
                stderr,
                "DinoX WebRTC remote video orientation: input=%dx%d pending=%d output=%dx%d delivered=%s\n",
                frame.width(),
                frame.height(),
                static_cast<int>(frame.rotation()),
                output_width,
                output_height,
                delivered ? "yes" : "no");
        }
    }

    void snapshot(
        uint64_t* out_frame_count,
        int* out_last_width,
        int* out_last_height) const {
        if (out_frame_count == nullptr ||
            out_last_width == nullptr ||
            out_last_height == nullptr) {
            return;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        *out_frame_count = frame_count_;
        *out_last_width = last_width_;
        *out_last_height = last_height_;
    }

 private:
    std::weak_ptr<SessionCore> core_;
    DinoXWebrtcSession* session_ = nullptr;
    mutable std::mutex mutex_;
    uint64_t frame_count_ = 0;
    int last_width_ = 0;
    int last_height_ = 0;
};

struct RemoteVideoSinkBinding {
    webrtc::scoped_refptr<webrtc::VideoTrackInterface> track;
    std::unique_ptr<CountingVideoSink> sink;
};

webrtc::VideoSinkWants remote_render_sink_wants() {
    // The call window normally renders one participant below a 704-pixel long
    // edge. Request an aspect-ratio-independent VGA-sized frame while retaining
    // a 720p ceiling for larger windows. Without a passive-renderer request,
    // Monal can deliver 1344x1792 frames: each BGRA frame is about 9.2 MiB and
    // needlessly saturates the process-boundary copy path before GTK scales it
    // back down.
    webrtc::VideoSinkWants wants;
    // Keep pending RTP CVO metadata on the frame.  The remote VideoTrack path
    // stops delivering Monal frames when rotation_applied is requested here;
    // emit_video_frame_callback() consumes the rotation before GTK instead.
    wants.target_pixel_count = kRemoteRenderTargetPixelCount;
    wants.max_pixel_count = kRemoteRenderMaxPixelCount;
    wants.max_framerate_fps = 30;
    return wants;
}

class SyntheticVideoTrackSource : public webrtc::VideoTrackSource {
 public:
    SyntheticVideoTrackSource() : webrtc::VideoTrackSource(false) {}

    bool GetStats(webrtc::VideoTrackSourceInterface::Stats* stats) override {
        if (stats == nullptr) {
            return false;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        stats->input_width = last_width_;
        stats->input_height = last_height_;
        return true;
    }

    bool push_black_frame(int width, int height) {
        std::optional<webrtc::VideoFrame> frame = make_black_video_frame(width, height);
        if (!frame.has_value()) return false;
        return push_frame(frame.value());
    }

    bool push_frame(const webrtc::VideoFrame& frame) {
        int width = frame.width();
        int height = frame.height();
        if (width <= 0 || height <= 0) {
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            frame_count_ += 1;
            last_width_ = width;
            last_height_ = height;
        }
        video_broadcaster_.OnFrame(frame);
        return true;
    }

    void snapshot(
        uint64_t* out_frame_count,
        int* out_last_width,
        int* out_last_height) const {
        if (out_frame_count == nullptr || out_last_width == nullptr ||
                out_last_height == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        *out_frame_count = frame_count_;
        *out_last_width = last_width_;
        *out_last_height = last_height_;
    }

 protected:
    ~SyntheticVideoTrackSource() override = default;

    webrtc::VideoSourceInterface<webrtc::VideoFrame>* source() override {
        return &video_broadcaster_;
    }

 private:
    mutable std::mutex mutex_;
    uint64_t frame_count_ = 0;
    int last_width_ = 0;
    int last_height_ = 0;
    webrtc::VideoBroadcaster video_broadcaster_;
};

class LocalVideoCaptureSink final : public webrtc::VideoSinkInterface<webrtc::VideoFrame> {
 public:
    LocalVideoCaptureSink(
        std::weak_ptr<SessionCore> core,
        DinoXWebrtcSession* session,
        webrtc::scoped_refptr<SyntheticVideoTrackSource> source,
        uint64_t camera_lease)
        : core_(std::move(core)),
          session_(session),
          source_(std::move(source)), camera_lease_(camera_lease) {}

    void OnFrame(const webrtc::VideoFrame& frame) override {
        auto core = core_.lock();
        if (core == nullptr || session_ == nullptr || source_ == nullptr) {
            return;
        }
        uint64_t frame_id = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            frame_count_ += 1;
            frame_id = frame_count_;
            last_width_ = frame.width();
            last_height_ = frame.height();
        }
        route_outgoing_video_frame(core, session_, source_, frame, frame_id, camera_lease_);
    }

    void snapshot(
        uint64_t* out_frame_count,
        int* out_last_width,
        int* out_last_height) const {
        if (out_frame_count == nullptr ||
            out_last_width == nullptr ||
            out_last_height == nullptr) {
            return;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        *out_frame_count = frame_count_;
        *out_last_width = last_width_;
        *out_last_height = last_height_;
    }

 private:
    std::weak_ptr<SessionCore> core_;
    DinoXWebrtcSession* session_ = nullptr;
    webrtc::scoped_refptr<SyntheticVideoTrackSource> source_;
    const uint64_t camera_lease_;
    mutable std::mutex mutex_;
    uint64_t frame_count_ = 0;
    int last_width_ = 0;
    int last_height_ = 0;
};

class AudioCaptureProbe final {
 public:
    void record(
        const void* audio_samples,
        size_t n_samples,
        size_t n_bytes_per_sample,
        size_t n_channels) {
        const uint64_t frame_count = static_cast<uint64_t>(n_samples);
        const uint64_t sample_count =
            static_cast<uint64_t>(n_samples) * static_cast<uint64_t>(n_channels);
        double peak_level = 0.0;
        if (audio_samples != nullptr && n_bytes_per_sample == 2 && n_channels > 0) {
            const int16_t* samples = static_cast<const int16_t*>(audio_samples);
            int peak = 0;
            for (uint64_t i = 0; i < sample_count; i++) {
                int value = static_cast<int>(samples[i]);
                if (value < 0) {
                    value = -value;
                }
                if (value > peak) {
                    peak = value;
                }
            }
            peak_level = static_cast<double>(peak) / 32768.0;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        frame_count_ += frame_count;
        sample_count_ += sample_count;
        if (peak_level > peak_level_) {
            peak_level_ = peak_level;
        }
    }

    void snapshot(
        uint64_t* out_frame_count,
        uint64_t* out_sample_count,
        double* out_peak_level) const {
        if (out_frame_count == nullptr ||
            out_sample_count == nullptr ||
            out_peak_level == nullptr) {
            return;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        *out_frame_count = frame_count_;
        *out_sample_count = sample_count_;
        *out_peak_level = peak_level_;
    }

 private:
    mutable std::mutex mutex_;
    uint64_t frame_count_ = 0;
    uint64_t sample_count_ = 0;
    double peak_level_ = 0.0;
};

class AudioCaptureSink {
 public:
    virtual ~AudioCaptureSink() = default;

    virtual void on_audio_capture(
        const void* audio_samples,
        size_t n_samples,
        size_t n_bytes_per_sample,
        size_t n_channels,
        uint32_t samples_per_sec) = 0;

    virtual void deactivate() {}
};

class VideoCaptureSink : public webrtc::VideoSinkInterface<webrtc::VideoFrame> {
 public:
    virtual void deactivate() {}
};

class AudioCaptureRouter final {
 public:
    void add_sink(std::shared_ptr<AudioCaptureSink> sink) {
        if (sink == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        sinks_.push_back(std::move(sink));
    }

    void remove_sink(const std::shared_ptr<AudioCaptureSink>& sink) {
        if (sink == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        sinks_.erase(
            std::remove_if(
                sinks_.begin(),
                sinks_.end(),
                [&](const std::weak_ptr<AudioCaptureSink>& candidate) {
                    auto locked = candidate.lock();
                    return locked == nullptr || locked == sink;
                }),
            sinks_.end());
    }

    void dispatch(
        const void* audio_samples,
        size_t n_samples,
        size_t n_bytes_per_sample,
        size_t n_channels,
        uint32_t samples_per_sec) {
        std::vector<std::shared_ptr<AudioCaptureSink>> sinks;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            sinks_.erase(
                std::remove_if(
                    sinks_.begin(),
                    sinks_.end(),
                    [](const std::weak_ptr<AudioCaptureSink>& candidate) {
                        return candidate.expired();
                    }),
                sinks_.end());
            sinks.reserve(sinks_.size());
            for (const auto& weak_sink : sinks_) {
                auto sink = weak_sink.lock();
                if (sink != nullptr) {
                    sinks.push_back(std::move(sink));
                }
            }
        }

        for (const auto& sink : sinks) {
            sink->on_audio_capture(
                audio_samples,
                n_samples,
                n_bytes_per_sample,
                n_channels,
                samples_per_sec);
        }
    }

 private:
    std::mutex mutex_;
    std::vector<std::weak_ptr<AudioCaptureSink>> sinks_;
};

class LocalDtmfToneGenerator final : public webrtc::AudioMixer::Source {
 public:
    bool start(char digit, unsigned int duration_ms) {
        double low_frequency = 0.0;
        double high_frequency = 0.0;
        if (!frequencies_for_digit(digit, &low_frequency, &high_frequency) ||
            duration_ms < 20 ||
            duration_ms > 1000) {
            return false;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        low_frequency_ = low_frequency;
        high_frequency_ = high_frequency;
        duration_ms_ = duration_ms;
        sample_rate_ = 0;
        low_phase_ = 0.0;
        high_phase_ = 0.0;
        total_frames_ = 0;
        remaining_frames_ = 0;
        peak_level_ = 0.0;
        start_count_++;
        active_ = true;
        return true;
    }

    void stop() {
        std::lock_guard<std::mutex> lock(mutex_);
        active_ = false;
        remaining_frames_ = 0;
    }

    bool is_active() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return active_;
    }

    bool mix(
        void* audio_samples,
        size_t frames,
        size_t bytes_per_sample,
        size_t channels,
        uint32_t sample_rate) {
        std::lock_guard<std::mutex> lock(mutex_);
        mix_call_count_++;
        last_sample_rate_ = sample_rate;
        last_channels_ = static_cast<uint32_t>(channels);
        last_bytes_per_sample_ = static_cast<uint32_t>(bytes_per_sample);

        if (audio_samples == nullptr ||
            frames == 0 ||
            bytes_per_sample != sizeof(int16_t) ||
            channels == 0 ||
            sample_rate == 0) {
            if (audio_samples != nullptr && frames != 0 && active_) {
                unsupported_format_count_++;
            }
            return false;
        }

        if (!active_) {
            return false;
        }
        if (sample_rate_ != sample_rate || total_frames_ == 0) {
            sample_rate_ = sample_rate;
            total_frames_ = static_cast<uint64_t>(duration_ms_) *
                static_cast<uint64_t>(sample_rate_) / 1000;
            if (total_frames_ == 0) {
                total_frames_ = 1;
            }
            remaining_frames_ = total_frames_;
        }

        int16_t* samples = static_cast<int16_t*>(audio_samples);
        const double two_pi = 6.28318530717958647692;
        const double low_increment = two_pi * low_frequency_ / static_cast<double>(sample_rate_);
        const double high_increment = two_pi * high_frequency_ / static_cast<double>(sample_rate_);
        const uint64_t fade_frames =
            minimum_u64(static_cast<uint64_t>(sample_rate_) * 5 / 1000, total_frames_ / 2);
        bool mixed = false;

        for (size_t frame = 0; frame < frames; frame++) {
            if (remaining_frames_ == 0) {
                active_ = false;
                break;
            }

            const uint64_t rendered_frames = total_frames_ - remaining_frames_;
            double envelope = 1.0;
            if (fade_frames > 0) {
                const double fade_in = rendered_frames >= fade_frames ?
                    1.0 :
                    static_cast<double>(rendered_frames) / static_cast<double>(fade_frames);
                const double fade_out = remaining_frames_ >= fade_frames ?
                    1.0 :
                    static_cast<double>(remaining_frames_) / static_cast<double>(fade_frames);
                envelope = fade_in < fade_out ? fade_in : fade_out;
            }

            const int mixed_sample = static_cast<int>(
                std::lround((std::sin(low_phase_) + std::sin(high_phase_)) *
                    0.35 * envelope * 32767.0));
            const double mixed_level = std::fabs(static_cast<double>(mixed_sample)) / 32767.0;
            if (mixed_level > peak_level_) {
                peak_level_ = mixed_level;
            }
            for (size_t channel = 0; channel < channels; channel++) {
                const size_t index = frame * channels + channel;
                samples[index] = clamp_int16(static_cast<int>(samples[index]) + mixed_sample);
            }

            low_phase_ += low_increment;
            high_phase_ += high_increment;
            if (low_phase_ >= two_pi) low_phase_ -= two_pi;
            if (high_phase_ >= two_pi) high_phase_ -= two_pi;
            remaining_frames_--;
            mixed_frame_count_++;
            mixed = true;
        }

        if (remaining_frames_ == 0) {
            active_ = false;
        }
        return mixed;
    }

    AudioFrameInfo GetAudioFrameWithInfo(
        int sample_rate_hz,
        webrtc::AudioFrame* audio_frame) override {
        if (audio_frame == nullptr || sample_rate_hz <= 0) {
            return AudioFrameInfo::kError;
        }

        const size_t frames = webrtc::SampleRateToDefaultChannelSize(
            static_cast<size_t>(sample_rate_hz));
        if (frames == 0 || frames > webrtc::AudioFrame::kMaxDataSizeSamples) {
            return AudioFrameInfo::kError;
        }

        std::array<int16_t, webrtc::AudioFrame::kMaxDataSizeSamples> samples = {};
        const bool has_tone = mix(
            samples.data(),
            frames,
            sizeof(int16_t),
            1,
            static_cast<uint32_t>(sample_rate_hz));
        const uint32_t timestamp = mixer_timestamp_.fetch_add(
            static_cast<uint32_t>(frames),
            std::memory_order_relaxed);

        audio_frame->UpdateFrame(
            timestamp,
            samples.data(),
            frames,
            sample_rate_hz,
            has_tone ? webrtc::AudioFrame::kNormalSpeech : webrtc::AudioFrame::kUndefined,
            has_tone ? webrtc::AudioFrame::kVadActive : webrtc::AudioFrame::kVadPassive,
            1);
        if (!has_tone) {
            audio_frame->Mute();
            return AudioFrameInfo::kMuted;
        }

        return AudioFrameInfo::kNormal;
    }

    int Ssrc() const override {
        return 0x44494e58;  // "DINX", stable local-only mixer source id.
    }

    int PreferredSampleRate() const override {
        return 48000;
    }

    void snapshot(
        uint64_t* out_start_count,
        uint64_t* out_mix_call_count,
        uint64_t* out_mixed_frame_count,
        uint64_t* out_unsupported_format_count,
        uint32_t* out_last_sample_rate,
        uint32_t* out_last_channels,
        uint32_t* out_last_bytes_per_sample,
        double* out_peak_level,
        int* out_active) const {
        std::lock_guard<std::mutex> lock(mutex_);
        if (out_start_count != nullptr) *out_start_count = start_count_;
        if (out_mix_call_count != nullptr) *out_mix_call_count = mix_call_count_;
        if (out_mixed_frame_count != nullptr) *out_mixed_frame_count = mixed_frame_count_;
        if (out_unsupported_format_count != nullptr) *out_unsupported_format_count = unsupported_format_count_;
        if (out_last_sample_rate != nullptr) *out_last_sample_rate = last_sample_rate_;
        if (out_last_channels != nullptr) *out_last_channels = last_channels_;
        if (out_last_bytes_per_sample != nullptr) *out_last_bytes_per_sample = last_bytes_per_sample_;
        if (out_peak_level != nullptr) *out_peak_level = peak_level_;
        if (out_active != nullptr) *out_active = active_ ? 1 : 0;
    }

 private:
    static uint64_t minimum_u64(uint64_t left, uint64_t right) {
        return left < right ? left : right;
    }

    static int16_t clamp_int16(int value) {
        if (value < -32768) return -32768;
        if (value > 32767) return 32767;
        return static_cast<int16_t>(value);
    }

    static bool frequencies_for_digit(char digit, double* out_low, double* out_high) {
        if (out_low == nullptr || out_high == nullptr) {
            return false;
        }

        switch (digit) {
            case '1': *out_low = 697.0; *out_high = 1209.0; return true;
            case '2': *out_low = 697.0; *out_high = 1336.0; return true;
            case '3': *out_low = 697.0; *out_high = 1477.0; return true;
            case '4': *out_low = 770.0; *out_high = 1209.0; return true;
            case '5': *out_low = 770.0; *out_high = 1336.0; return true;
            case '6': *out_low = 770.0; *out_high = 1477.0; return true;
            case '7': *out_low = 852.0; *out_high = 1209.0; return true;
            case '8': *out_low = 852.0; *out_high = 1336.0; return true;
            case '9': *out_low = 852.0; *out_high = 1477.0; return true;
            case '*': *out_low = 941.0; *out_high = 1209.0; return true;
            case '0': *out_low = 941.0; *out_high = 1336.0; return true;
            case '#': *out_low = 941.0; *out_high = 1477.0; return true;
            case 'A': *out_low = 697.0; *out_high = 1633.0; return true;
            case 'B': *out_low = 770.0; *out_high = 1633.0; return true;
            case 'C': *out_low = 852.0; *out_high = 1633.0; return true;
            case 'D': *out_low = 941.0; *out_high = 1633.0; return true;
            default:
                return false;
        }
    }

    mutable std::mutex mutex_;
    bool active_ = false;
    double low_frequency_ = 0.0;
    double high_frequency_ = 0.0;
    unsigned int duration_ms_ = 0;
    uint32_t sample_rate_ = 0;
    uint64_t total_frames_ = 0;
    uint64_t remaining_frames_ = 0;
    double low_phase_ = 0.0;
    double high_phase_ = 0.0;
    uint64_t start_count_ = 0;
    uint64_t mix_call_count_ = 0;
    uint64_t mixed_frame_count_ = 0;
    uint64_t unsupported_format_count_ = 0;
    uint32_t last_sample_rate_ = 0;
    uint32_t last_channels_ = 0;
    uint32_t last_bytes_per_sample_ = 0;
    double peak_level_ = 0.0;
    std::atomic<uint32_t> mixer_timestamp_ = 0;
};

class LocalAudioTestClip final {
 public:
    bool start(
        const uint8_t* pcm_data,
        size_t byte_count,
        int sample_rate,
        int channels,
        int bytes_per_sample,
        unsigned int* out_duration_ms) {
        if (pcm_data == nullptr ||
            byte_count == 0 ||
            bytes_per_sample != static_cast<int>(sizeof(int16_t)) ||
            sample_rate < 8000 ||
            sample_rate > 96000 ||
            channels < 1 ||
            channels > 2 ||
            byte_count % (static_cast<size_t>(channels) * sizeof(int16_t)) != 0) {
            return false;
        }

        const size_t frame_count =
            byte_count / (static_cast<size_t>(channels) * sizeof(int16_t));
        if (frame_count == 0 ||
            frame_count > static_cast<size_t>(sample_rate) * 5) {
            return false;
        }

        if (!start_stream(sample_rate, channels, bytes_per_sample)) {
            return false;
        }
        unsigned int queued_duration_ms = 0;
        if (!push_stream(pcm_data, byte_count, &queued_duration_ms)) {
            stop();
            return false;
        }
        finish(nullptr);
        if (out_duration_ms != nullptr) {
            *out_duration_ms = static_cast<unsigned int>(
                (static_cast<uint64_t>(frame_count) * 1000 +
                 static_cast<uint64_t>(sample_rate) - 1) /
                static_cast<uint64_t>(sample_rate));
        }
        return true;
    }

    bool start_stream(int sample_rate, int channels, int bytes_per_sample) {
        if (bytes_per_sample != static_cast<int>(sizeof(int16_t)) ||
                sample_rate < 8000 || sample_rate > 96000 ||
                channels < 1 || channels > 2) {
            return false;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        samples_.clear();
        first_frame_offset_ = 0;
        sample_rate_ = sample_rate;
        channels_ = channels;
        source_position_ = 0.0;
        played_source_frames_ = 0;
        accepting_ = true;
        paused_ = false;
        active_ = true;
        return true;
    }

    bool push_stream(
        const uint8_t* pcm_data,
        size_t byte_count,
        unsigned int* out_queued_duration_ms) {
        if (out_queued_duration_ms != nullptr) {
            *out_queued_duration_ms = 0;
        }
        if (pcm_data == nullptr || byte_count == 0 ||
                byte_count % sizeof(int16_t) != 0 ||
                byte_count > kMaxPushByteCount) {
            return false;
        }

        std::vector<int16_t> appended_samples(byte_count / sizeof(int16_t));
        for (size_t index = 0; index < appended_samples.size(); index++) {
            const size_t offset = index * 2;
            const uint16_t raw = static_cast<uint16_t>(pcm_data[offset]) |
                (static_cast<uint16_t>(pcm_data[offset + 1]) << 8);
            appended_samples[index] = static_cast<int16_t>(raw);
        }

        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || !accepting_ || channels_ <= 0 || sample_rate_ <= 0 ||
                appended_samples.size() % static_cast<size_t>(channels_) != 0) {
            return false;
        }
        const size_t queued_frames = queued_frames_locked();
        const size_t appended_frames =
            appended_samples.size() / static_cast<size_t>(channels_);
        const size_t max_queued_frames =
            static_cast<size_t>(sample_rate_) * kMaxQueuedDurationMs / 1000;
        if (appended_frames > max_queued_frames ||
                queued_frames > max_queued_frames - appended_frames) {
            return false;
        }

        samples_.insert(
            samples_.end(), appended_samples.begin(), appended_samples.end());
        if (out_queued_duration_ms != nullptr) {
            *out_queued_duration_ms = queued_duration_ms_locked();
        }
        return true;
    }

    bool set_paused(bool paused) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_) return false;
        paused_ = paused;
        return true;
    }

    bool flush() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_) return false;
        samples_.clear();
        first_frame_offset_ = 0;
        source_position_ = 0.0;
        played_source_frames_ = 0;
        return true;
    }

    bool finish(unsigned int* out_queued_duration_ms) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_) return false;
        accepting_ = false;
        if (out_queued_duration_ms != nullptr) {
            *out_queued_duration_ms = queued_duration_ms_locked();
        }
        if (queued_frames_locked() == 0) active_ = false;
        return true;
    }

    void stop() {
        std::lock_guard<std::mutex> lock(mutex_);
        active_ = false;
        accepting_ = false;
        paused_ = false;
        samples_.clear();
        first_frame_offset_ = 0;
        source_position_ = 0.0;
        played_source_frames_ = 0;
    }

    bool is_active() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return active_;
    }

    bool mix(
        void* audio_samples,
        size_t output_frames,
        size_t bytes_per_sample,
        size_t output_channels,
        uint32_t output_sample_rate) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ ||
            paused_ ||
            audio_samples == nullptr ||
            output_frames == 0 ||
            bytes_per_sample != sizeof(int16_t) ||
            output_channels == 0 ||
            output_sample_rate == 0) {
            return false;
        }

        int16_t* output = static_cast<int16_t*>(audio_samples);
        const double source_step =
            static_cast<double>(sample_rate_) / static_cast<double>(output_sample_rate);
        const size_t total_frame_count =
            samples_.size() / static_cast<size_t>(channels_);
        if (first_frame_offset_ >= total_frame_count) return false;
        const size_t source_frame_count = total_frame_count - first_frame_offset_;
        const size_t fade_frames = static_cast<size_t>(sample_rate_) / 200;
        bool mixed = false;

        for (size_t output_frame = 0; output_frame < output_frames; output_frame++) {
            const size_t source_frame = static_cast<size_t>(source_position_);
            if (source_frame >= source_frame_count) break;

            double envelope = 1.0;
            if (fade_frames > 0) {
                const uint64_t absolute_source_frame =
                    played_source_frames_ + static_cast<uint64_t>(source_frame);
                if (absolute_source_frame < fade_frames) {
                    envelope = static_cast<double>(absolute_source_frame) /
                        static_cast<double>(fade_frames);
                }
                const size_t remaining = source_frame_count - source_frame;
                if (!accepting_ && remaining < fade_frames) {
                    const double fade_out = static_cast<double>(remaining) /
                        static_cast<double>(fade_frames);
                    if (fade_out < envelope) envelope = fade_out;
                }
            }

            for (size_t output_channel = 0; output_channel < output_channels; output_channel++) {
                int source_sample = 0;
                if (channels_ == 1) {
                    source_sample = samples_[
                        (first_frame_offset_ + source_frame) *
                        static_cast<size_t>(channels_)];
                } else if (output_channels == 1) {
                    const size_t offset = (first_frame_offset_ + source_frame) * 2;
                    source_sample =
                        (static_cast<int>(samples_[offset]) +
                         static_cast<int>(samples_[offset + 1])) / 2;
                } else {
                    const size_t source_channel = output_channel < 2 ? output_channel : 0;
                    source_sample = samples_[
                        (first_frame_offset_ + source_frame) * 2 + source_channel];
                }
                const size_t output_index = output_frame * output_channels + output_channel;
                const int mixed_sample = static_cast<int>(
                    static_cast<double>(source_sample) * envelope);
                output[output_index] = clamp_int16(
                    static_cast<int>(output[output_index]) + mixed_sample);
            }

            source_position_ += source_step;
            mixed = true;
        }

        const size_t consumed_frames = std::min(
            static_cast<size_t>(source_position_), source_frame_count);
        if (consumed_frames > 0) {
            first_frame_offset_ += consumed_frames;
            source_position_ -= static_cast<double>(consumed_frames);
            played_source_frames_ += static_cast<uint64_t>(consumed_frames);
        }
        if (first_frame_offset_ == total_frame_count) {
            samples_.clear();
            first_frame_offset_ = 0;
            if (!accepting_) {
                active_ = false;
                source_position_ = 0.0;
            }
        } else {
            compact_consumed_prefix_locked();
        }
        return mixed;
    }

 private:
    static constexpr size_t kMaxQueuedDurationMs = 6000;
    static constexpr size_t kMaxPushByteCount =
        static_cast<size_t>(96000) * 2 * sizeof(int16_t) *
        kMaxQueuedDurationMs / 1000;

    static int16_t clamp_int16(int value) {
        if (value < -32768) return -32768;
        if (value > 32767) return 32767;
        return static_cast<int16_t>(value);
    }

    size_t queued_frames_locked() const {
        if (channels_ <= 0) return 0;
        const size_t total_frames =
            samples_.size() / static_cast<size_t>(channels_);
        if (first_frame_offset_ >= total_frames) return 0;
        const size_t available_frames = total_frames - first_frame_offset_;
        const size_t consumed_frames = std::min(
            static_cast<size_t>(source_position_), available_frames);
        return available_frames - consumed_frames;
    }

    void compact_consumed_prefix_locked() {
        if (channels_ <= 0 || first_frame_offset_ == 0) return;
        const size_t consumed_samples =
            first_frame_offset_ * static_cast<size_t>(channels_);
        if (consumed_samples < samples_.size() / 2 &&
                consumed_samples < static_cast<size_t>(sample_rate_) *
                    static_cast<size_t>(channels_)) {
            return;
        }
        samples_.erase(samples_.begin(), samples_.begin() + consumed_samples);
        first_frame_offset_ = 0;
    }

    unsigned int queued_duration_ms_locked() const {
        if (sample_rate_ <= 0) return 0;
        return static_cast<unsigned int>(
            (static_cast<uint64_t>(queued_frames_locked()) * 1000 +
             static_cast<uint64_t>(sample_rate_) - 1) /
            static_cast<uint64_t>(sample_rate_));
    }

    mutable std::mutex mutex_;
    std::vector<int16_t> samples_;
    size_t first_frame_offset_ = 0;
    int sample_rate_ = 0;
    int channels_ = 0;
    double source_position_ = 0.0;
    uint64_t played_source_frames_ = 0;
    bool accepting_ = false;
    bool paused_ = false;
    bool active_ = false;
};

struct AudioGainState {
    static constexpr uint32_t kUnity = 65536;
    std::atomic<uint32_t> microphone{kUnity};
    std::atomic<uint32_t> speaker{kUnity};
};

class MeasuringAudioTransport final : public webrtc::AudioTransport {
 public:
    MeasuringAudioTransport(
        webrtc::AudioTransport* delegate,
        std::shared_ptr<AudioCaptureProbe> capture_probe,
        std::shared_ptr<LocalDtmfToneGenerator> local_dtmf_tones,
        std::shared_ptr<LocalAudioTestClip> local_audio_test_clip,
        std::shared_ptr<AudioCaptureRouter> capture_router,
        std::shared_ptr<AudioGainState> audio_gain_state)
        : delegate_(delegate),
          capture_probe_(std::move(capture_probe)),
          local_dtmf_tones_(std::move(local_dtmf_tones)),
          local_audio_test_clip_(std::move(local_audio_test_clip)),
          capture_router_(std::move(capture_router)),
          audio_gain_state_(std::move(audio_gain_state)) {}

    void set_delegate(webrtc::AudioTransport* delegate) {
        // AudioDeviceBuffer stores this wrapper as a raw pointer. Keep the
        // wrapper stable and only swap its downstream transport after both
        // capture and playout callbacks have left their delegate calls.
        std::scoped_lock lock(
            capture_delegate_mutex_,
            playout_delegate_mutex_);
        delegate_ = delegate;
    }

    int32_t RecordedDataIsAvailable(
        const void* audio_samples,
        size_t n_samples,
        size_t n_bytes_per_frame,
        size_t n_channels,
        uint32_t samples_per_sec,
        uint32_t total_delay_ms,
        int32_t clock_drift,
        uint32_t current_mic_level,
        bool key_pressed,
        uint32_t& new_mic_level) override {
        const size_t bytes_per_sample = n_channels > 0 &&
                n_bytes_per_frame % n_channels == 0 ?
            n_bytes_per_frame / n_channels : 0;
        if (capture_probe_ != nullptr) {
            capture_probe_->record(audio_samples, n_samples, bytes_per_sample, n_channels);
        }
        if (capture_router_ != nullptr) {
            capture_router_->dispatch(
                audio_samples,
                n_samples,
                bytes_per_sample,
                n_channels,
                samples_per_sec);
        }
        std::lock_guard<std::recursive_mutex> delegate_lock(
            capture_delegate_mutex_);
        if (delegate_ == nullptr) {
            new_mic_level = current_mic_level;
            return 0;
        }
        const void* samples_for_delegate = apply_capture_gain(
            audio_samples,
            n_samples,
            bytes_per_sample,
            n_channels);
        return delegate_->RecordedDataIsAvailable(
            samples_for_delegate,
            n_samples,
            n_bytes_per_frame,
            n_channels,
            samples_per_sec,
            total_delay_ms,
            clock_drift,
            current_mic_level,
            key_pressed,
            new_mic_level);
    }

    int32_t RecordedDataIsAvailable(
        const void* audio_samples,
        size_t n_samples,
        size_t n_bytes_per_frame,
        size_t n_channels,
        uint32_t samples_per_sec,
        uint32_t total_delay_ms,
        int32_t clock_drift,
        uint32_t current_mic_level,
        bool key_pressed,
        uint32_t& new_mic_level,
        std::optional<int64_t> estimated_capture_time_ns) override {
        const size_t bytes_per_sample = n_channels > 0 &&
                n_bytes_per_frame % n_channels == 0 ?
            n_bytes_per_frame / n_channels : 0;
        if (capture_probe_ != nullptr) {
            capture_probe_->record(audio_samples, n_samples, bytes_per_sample, n_channels);
        }
        if (capture_router_ != nullptr) {
            capture_router_->dispatch(
                audio_samples,
                n_samples,
                bytes_per_sample,
                n_channels,
                samples_per_sec);
        }
        std::lock_guard<std::recursive_mutex> delegate_lock(
            capture_delegate_mutex_);
        if (delegate_ == nullptr) {
            new_mic_level = current_mic_level;
            return 0;
        }
        const void* samples_for_delegate = apply_capture_gain(
            audio_samples,
            n_samples,
            bytes_per_sample,
            n_channels);
        return delegate_->RecordedDataIsAvailable(
            samples_for_delegate,
            n_samples,
            n_bytes_per_frame,
            n_channels,
            samples_per_sec,
            total_delay_ms,
            clock_drift,
            current_mic_level,
            key_pressed,
            new_mic_level,
            estimated_capture_time_ns);
    }

    int32_t NeedMorePlayData(
        size_t n_samples,
        size_t n_bytes_per_frame,
        size_t n_channels,
        uint32_t samples_per_sec,
        void* audio_samples,
        size_t& n_samples_out,
        int64_t* elapsed_time_ms,
        int64_t* ntp_time_ms) override {
        const size_t bytes_per_sample = n_channels > 0 &&
                n_bytes_per_frame % n_channels == 0 ?
            n_bytes_per_frame / n_channels : 0;
        if (n_channels == 0 || bytes_per_sample == 0) {
            n_samples_out = 0;
            return -1;
        }
        if (n_samples > std::numeric_limits<size_t>::max() / n_bytes_per_frame) {
            n_samples_out = 0;
            return -1;
        }
        std::unique_lock<std::recursive_mutex> delegate_lock(
            playout_delegate_mutex_);
        if (delegate_ == nullptr) {
            delegate_lock.unlock();
            n_samples_out = 0;
            if (audio_samples != nullptr &&
                    n_samples > 0 &&
                    n_bytes_per_frame > 0) {
                std::memset(
                    audio_samples,
                    0,
                    n_samples * n_bytes_per_frame);
                mix_local_dtmf_feedback(
                    n_samples,
                    bytes_per_sample,
                    n_channels,
                    samples_per_sec,
                    audio_samples,
                    n_samples_out);
                mix_local_audio_test_clip(
                    n_samples,
                    bytes_per_sample,
                    n_channels,
                    samples_per_sec,
                    audio_samples,
                    n_samples_out);
                apply_playout_gain(
                    audio_samples,
                    n_samples_out / n_channels,
                    bytes_per_sample,
                    n_channels);
            }
            if (elapsed_time_ms != nullptr) *elapsed_time_ms = 0;
            if (ntp_time_ms != nullptr) *ntp_time_ms = 0;
            return 0;
        }
        int32_t result = delegate_->NeedMorePlayData(
            n_samples,
            n_bytes_per_frame,
            n_channels,
            samples_per_sec,
            audio_samples,
            n_samples_out,
            elapsed_time_ms,
            ntp_time_ms);
        delegate_lock.unlock();
        mix_local_dtmf_feedback(
            n_samples,
            bytes_per_sample,
            n_channels,
            samples_per_sec,
            audio_samples,
            n_samples_out);
        mix_local_audio_test_clip(
            n_samples,
            bytes_per_sample,
            n_channels,
            samples_per_sec,
            audio_samples,
            n_samples_out);
        if (result == 0 && n_samples_out % n_channels == 0) {
            apply_playout_gain(
                audio_samples,
                n_samples_out / n_channels,
                bytes_per_sample,
                n_channels);
        }
        return result;
    }

    void PullRenderData(
        int bits_per_sample,
        int sample_rate,
        size_t number_of_channels,
        size_t number_of_frames,
        void* audio_data,
        int64_t* elapsed_time_ms,
        int64_t* ntp_time_ms) override {
        std::unique_lock<std::recursive_mutex> delegate_lock(
            playout_delegate_mutex_);
        if (delegate_ == nullptr) {
            delegate_lock.unlock();
            if (audio_data != nullptr &&
                    bits_per_sample > 0 &&
                    number_of_channels > 0 &&
                    number_of_frames > 0) {
                std::memset(
                    audio_data,
                    0,
                    number_of_frames * number_of_channels *
                        static_cast<size_t>(bits_per_sample / 8));
                mix_local_dtmf_feedback(
                    number_of_frames,
                    static_cast<size_t>(bits_per_sample / 8),
                    number_of_channels,
                    static_cast<uint32_t>(sample_rate),
                    audio_data);
                mix_local_audio_test_clip(
                    number_of_frames,
                    static_cast<size_t>(bits_per_sample / 8),
                    number_of_channels,
                    static_cast<uint32_t>(sample_rate),
                    audio_data);
                apply_playout_gain(
                    audio_data,
                    number_of_frames,
                    static_cast<size_t>(bits_per_sample / 8),
                    number_of_channels);
            }
            if (elapsed_time_ms != nullptr) *elapsed_time_ms = 0;
            if (ntp_time_ms != nullptr) *ntp_time_ms = 0;
            return;
        }
        delegate_->PullRenderData(
            bits_per_sample,
            sample_rate,
            number_of_channels,
            number_of_frames,
            audio_data,
            elapsed_time_ms,
            ntp_time_ms);
        delegate_lock.unlock();
        mix_local_dtmf_feedback(
            number_of_frames,
            static_cast<size_t>(bits_per_sample / 8),
            number_of_channels,
            static_cast<uint32_t>(sample_rate),
            audio_data);
        mix_local_audio_test_clip(
            number_of_frames,
            static_cast<size_t>(bits_per_sample / 8),
            number_of_channels,
            static_cast<uint32_t>(sample_rate),
            audio_data);
        apply_playout_gain(
            audio_data,
            number_of_frames,
            static_cast<size_t>(bits_per_sample / 8),
            number_of_channels);
    }

 private:
    const void* apply_capture_gain(
        const void* audio_samples,
        size_t frames,
        size_t bytes_per_sample,
        size_t channels) const {
        if (audio_gain_state_ == nullptr ||
                audio_samples == nullptr ||
                frames == 0 ||
                channels == 0 ||
                bytes_per_sample != sizeof(int16_t)) {
            return audio_samples;
        }
        const uint32_t gain = audio_gain_state_->microphone.load(std::memory_order_relaxed);
        if (gain >= AudioGainState::kUnity) {
            return audio_samples;
        }
        if (frames > std::numeric_limits<size_t>::max() / channels) {
            return audio_samples;
        }
        const size_t sample_count = frames * channels;
        const std::span<const int16_t> input(
            static_cast<const int16_t*>(audio_samples), sample_count);
        thread_local std::vector<int16_t> adjusted_samples;
        adjusted_samples.resize(sample_count);
        std::span<int16_t> output(adjusted_samples.data(), adjusted_samples.size());
        for (size_t index = 0; index < sample_count; ++index) {
            output[index] = scale_audio_sample(input[index], gain);
        }
        return adjusted_samples.data();
    }

    void apply_playout_gain(
        void* audio_samples,
        size_t frames,
        size_t bytes_per_sample,
        size_t channels) const {
        if (audio_gain_state_ == nullptr ||
                audio_samples == nullptr ||
                frames == 0 ||
                channels == 0 ||
                bytes_per_sample != sizeof(int16_t) ||
                frames > std::numeric_limits<size_t>::max() / channels) {
            return;
        }
        const uint32_t gain = audio_gain_state_->speaker.load(std::memory_order_relaxed);
        if (gain >= AudioGainState::kUnity) {
            return;
        }
        const size_t sample_count = frames * channels;
        std::span<int16_t> samples(static_cast<int16_t*>(audio_samples), sample_count);
        for (size_t index = 0; index < sample_count; ++index) {
            samples[index] = scale_audio_sample(samples[index], gain);
        }
    }

    static int16_t scale_audio_sample(int16_t sample, uint32_t gain) {
        const int64_t product = static_cast<int64_t>(sample) * gain;
        const int64_t rounded = product >= 0 ?
            product + AudioGainState::kUnity / 2 :
            product - AudioGainState::kUnity / 2;
        const int64_t scaled = rounded / AudioGainState::kUnity;
        if (scaled <= -32768) return -32768;
        if (scaled >= 32767) return 32767;
        return static_cast<int16_t>(scaled);
    }

    void mix_local_dtmf_feedback(
        size_t requested_frames,
        size_t bytes_per_sample,
        size_t channels,
        uint32_t sample_rate,
        void* audio_samples,
        size_t& samples_out) {
        if (local_dtmf_tones_ == nullptr ||
                audio_samples == nullptr ||
                requested_frames == 0 ||
                channels == 0 ||
                (samples_out != 0 && samples_out % channels != 0)) {
            return;
        }

        size_t frames_to_mix = samples_out > 0 ? samples_out / channels : requested_frames;
        if (samples_out == 0) {
            if (!local_dtmf_tones_->is_active()) {
                return;
            }
            std::memset(audio_samples, 0, requested_frames * channels * bytes_per_sample);
            frames_to_mix = requested_frames;
        }

        if (local_dtmf_tones_->mix(audio_samples, frames_to_mix, bytes_per_sample, channels, sample_rate) &&
            samples_out == 0) {
            samples_out = frames_to_mix * channels;
        }
    }

    void mix_local_dtmf_feedback(
        size_t frames,
        size_t bytes_per_sample,
        size_t channels,
        uint32_t sample_rate,
        void* audio_samples) {
        if (local_dtmf_tones_ == nullptr || audio_samples == nullptr || frames == 0) {
            return;
        }
        local_dtmf_tones_->mix(audio_samples, frames, bytes_per_sample, channels, sample_rate);
    }

    void mix_local_audio_test_clip(
        size_t requested_frames,
        size_t bytes_per_sample,
        size_t channels,
        uint32_t sample_rate,
        void* audio_samples,
        size_t& samples_out) {
        if (local_audio_test_clip_ == nullptr ||
                audio_samples == nullptr ||
                requested_frames == 0 ||
                channels == 0 ||
                (samples_out != 0 && samples_out % channels != 0)) {
            return;
        }
        size_t frames_to_mix = samples_out > 0 ? samples_out / channels : requested_frames;
        if (samples_out == 0) {
            if (!local_audio_test_clip_->is_active()) return;
            std::memset(audio_samples, 0, requested_frames * channels * bytes_per_sample);
            frames_to_mix = requested_frames;
        }
        if (local_audio_test_clip_->mix(
                audio_samples,
                frames_to_mix,
                bytes_per_sample,
                channels,
                sample_rate) &&
                samples_out == 0) {
            samples_out = frames_to_mix * channels;
        }
    }

    void mix_local_audio_test_clip(
        size_t frames,
        size_t bytes_per_sample,
        size_t channels,
        uint32_t sample_rate,
        void* audio_samples) {
        if (local_audio_test_clip_ == nullptr ||
                audio_samples == nullptr ||
                frames == 0) {
            return;
        }
        local_audio_test_clip_->mix(
            audio_samples,
            frames,
            bytes_per_sample,
            channels,
            sample_rate);
    }

    std::recursive_mutex capture_delegate_mutex_;
    std::recursive_mutex playout_delegate_mutex_;
    webrtc::AudioTransport* delegate_;
    std::shared_ptr<AudioCaptureProbe> capture_probe_;
    std::shared_ptr<LocalDtmfToneGenerator> local_dtmf_tones_;
    std::shared_ptr<LocalAudioTestClip> local_audio_test_clip_;
    std::shared_ptr<AudioCaptureRouter> capture_router_;
    std::shared_ptr<AudioGainState> audio_gain_state_;
};

struct RtpStatsSnapshot {
    uint64_t inbound_audio_packets_received = 0;
    uint64_t inbound_audio_bytes_received = 0;
    uint64_t inbound_audio_total_samples_received = 0;
    uint64_t inbound_video_packets_received = 0;
    uint64_t inbound_video_bytes_received = 0;
    uint64_t inbound_video_frames_received = 0;
    uint64_t inbound_video_frames_decoded = 0;
    uint64_t inbound_video_key_frames_decoded = 0;
    uint64_t inbound_video_frames_dropped = 0;
    int inbound_video_frame_width = 0;
    int inbound_video_frame_height = 0;
    int64_t inbound_video_packets_lost = 0;
    double inbound_video_frames_per_second = 0.0;
    double inbound_video_jitter = 0.0;
    double inbound_video_jitter_buffer_delay = 0.0;
    double inbound_video_jitter_buffer_target_delay = 0.0;
    double inbound_video_jitter_buffer_minimum_delay = 0.0;
    uint64_t inbound_video_jitter_buffer_emitted_count = 0;
    double inbound_video_total_decode_time = 0.0;
    double inbound_video_total_processing_delay = 0.0;
    uint64_t inbound_video_freeze_count = 0;
    double inbound_video_total_freezes_duration = 0.0;
    uint64_t inbound_video_pli_count = 0;
    uint64_t inbound_video_fir_count = 0;
    uint64_t inbound_video_nack_count = 0;
    std::string inbound_video_decoder_implementation;
    std::string inbound_video_transport_id;
    uint64_t outbound_audio_packets_sent = 0;
    uint64_t outbound_audio_bytes_sent = 0;
    double outbound_audio_target_bitrate = 0.0;
    uint64_t outbound_video_packets_sent = 0;
    uint64_t outbound_video_bytes_sent = 0;
    uint64_t outbound_video_frames_sent = 0;
    uint64_t outbound_video_frames_encoded = 0;
    double outbound_video_target_bitrate = 0.0;
    int outbound_video_frame_width = 0;
    int outbound_video_frame_height = 0;
    double inbound_audio_level = 0.0;
    double source_audio_level = 0.0;
    double source_audio_total_energy = 0.0;
    double source_audio_total_duration = 0.0;
    std::string selected_pair_state;
    std::string selected_local_candidate_type;
    std::string selected_remote_candidate_type;
    std::string selected_candidate_protocol;
    std::string selected_local_network_type;
    std::string selected_relay_protocol;
    double selected_pair_current_round_trip_time = -1.0;
    double selected_pair_available_incoming_bitrate = -1.0;
    double selected_pair_available_outgoing_bitrate = -1.0;
    uint64_t selected_pair_packets_received = 0;
    uint64_t selected_pair_packets_sent = 0;
    uint64_t selected_pair_bytes_received = 0;
    uint64_t selected_pair_bytes_sent = 0;
    uint64_t stats_report_count = 0;
    std::chrono::steady_clock::time_point collected_at;
};

uint64_t monotonic_counter_delta(uint64_t current, uint64_t previous) {
    return current >= previous ? current - previous : 0;
}

double cumulative_average_ms(double total_seconds, uint64_t count) {
    return count > 0 ? (total_seconds * 1000.0) / static_cast<double>(count) : -1.0;
}

void populate_selected_video_candidate_pair(
        const webrtc::scoped_refptr<const webrtc::RTCStatsReport>& report,
        RtpStatsSnapshot* snapshot) {
    if (report == nullptr || snapshot == nullptr) {
        return;
    }

    const webrtc::RTCTransportStats* transport = nullptr;
    if (!snapshot->inbound_video_transport_id.empty()) {
        transport = report->GetAs<webrtc::RTCTransportStats>(
            snapshot->inbound_video_transport_id);
    }
    if (transport == nullptr) {
        for (const webrtc::RTCTransportStats* candidate_transport :
             report->GetStatsOfType<webrtc::RTCTransportStats>()) {
            if (candidate_transport != nullptr &&
                    candidate_transport->selected_candidate_pair_id.has_value()) {
                transport = candidate_transport;
                break;
            }
        }
    }
    if (transport == nullptr || !transport->selected_candidate_pair_id.has_value()) {
        return;
    }

    const webrtc::RTCIceCandidatePairStats* pair =
        report->GetAs<webrtc::RTCIceCandidatePairStats>(
            transport->selected_candidate_pair_id.value());
    if (pair == nullptr) {
        return;
    }

    snapshot->selected_pair_state = pair->state.value_or("unknown");
    snapshot->selected_pair_current_round_trip_time =
        pair->current_round_trip_time.value_or(-1.0);
    snapshot->selected_pair_available_incoming_bitrate =
        pair->available_incoming_bitrate.value_or(-1.0);
    snapshot->selected_pair_available_outgoing_bitrate =
        pair->available_outgoing_bitrate.value_or(-1.0);
    snapshot->selected_pair_packets_received = pair->packets_received.value_or(0);
    snapshot->selected_pair_packets_sent = pair->packets_sent.value_or(0);
    snapshot->selected_pair_bytes_received = pair->bytes_received.value_or(0);
    snapshot->selected_pair_bytes_sent = pair->bytes_sent.value_or(0);

    if (pair->local_candidate_id.has_value()) {
        const webrtc::RTCLocalIceCandidateStats* local =
            report->GetAs<webrtc::RTCLocalIceCandidateStats>(
                pair->local_candidate_id.value());
        if (local != nullptr) {
            snapshot->selected_local_candidate_type =
                local->candidate_type.value_or("unknown");
            snapshot->selected_candidate_protocol =
                local->protocol.value_or("unknown");
            snapshot->selected_local_network_type =
                local->network_type.value_or("unknown");
            snapshot->selected_relay_protocol =
                local->relay_protocol.value_or("none");
        }
    }
    if (pair->remote_candidate_id.has_value()) {
        const webrtc::RTCRemoteIceCandidateStats* remote =
            report->GetAs<webrtc::RTCRemoteIceCandidateStats>(
                pair->remote_candidate_id.value());
        if (remote != nullptr) {
            snapshot->selected_remote_candidate_type =
                remote->candidate_type.value_or("unknown");
            if (snapshot->selected_candidate_protocol.empty()) {
                snapshot->selected_candidate_protocol =
                    remote->protocol.value_or("unknown");
            }
        }
    }
}

void log_receive_startup_stats(
        const RtpStatsSnapshot& current,
        const RtpStatsSnapshot& previous) {
    if (!call_debug_enabled()) {
        return;
    }

    double elapsed_seconds = -1.0;
    if (previous.stats_report_count > 0 &&
            previous.collected_at.time_since_epoch().count() != 0) {
        elapsed_seconds = std::chrono::duration<double>(
            current.collected_at - previous.collected_at).count();
    }
    const uint64_t delta_bytes = monotonic_counter_delta(
        current.inbound_video_bytes_received,
        previous.inbound_video_bytes_received);
    const uint64_t delta_frames = monotonic_counter_delta(
        current.inbound_video_frames_received,
        previous.inbound_video_frames_received);
    const uint64_t delta_decoded = monotonic_counter_delta(
        current.inbound_video_frames_decoded,
        previous.inbound_video_frames_decoded);
    const double delta_bitrate = elapsed_seconds > 0.0
        ? static_cast<double>(delta_bytes) * 8.0 / elapsed_seconds
        : -1.0;
    const double delta_fps = elapsed_seconds > 0.0
        ? static_cast<double>(delta_decoded) / elapsed_seconds
        : -1.0;
    const double jitter_buffer_average_ms = cumulative_average_ms(
        current.inbound_video_jitter_buffer_delay,
        current.inbound_video_jitter_buffer_emitted_count);
    const double jitter_buffer_target_average_ms = cumulative_average_ms(
        current.inbound_video_jitter_buffer_target_delay,
        current.inbound_video_jitter_buffer_emitted_count);
    const double jitter_buffer_minimum_average_ms = cumulative_average_ms(
        current.inbound_video_jitter_buffer_minimum_delay,
        current.inbound_video_jitter_buffer_emitted_count);
    const double decode_average_ms = cumulative_average_ms(
        current.inbound_video_total_decode_time,
        current.inbound_video_frames_decoded);
    const double processing_average_ms = cumulative_average_ms(
        current.inbound_video_total_processing_delay,
        current.inbound_video_frames_decoded);
    const double current_round_trip_time_ms =
        current.selected_pair_current_round_trip_time >= 0.0
        ? current.selected_pair_current_round_trip_time * 1000.0
        : -1.0;

    std::fprintf(
        stderr,
        "DinoX WebRTC receive startup: report=%llu elapsed=%.3fs "
        "rtp=packets:%llu lost:%lld bytes:%llu delta-frames:%llu bitrate:%.0fbps "
        "video=received:%llu decoded:%llu dropped:%llu key:%llu fps:%.2f delta-fps:%.2f "
        "size:%dx%d decoder=%s decode-avg:%.3fms processing-avg:%.3fms "
        "jitter:%.3fms jb:avg:%.3fms/target:%.3fms/min:%.3fms emitted:%llu "
        "freeze:%llu/%.3fs feedback=pli:%llu/fir:%llu/nack:%llu "
        "ice=%s/%s-%s/%s network:%s relay:%s rtt:%.3fms "
        "available:in:%.0fbps/out:%.0fbps pair-packets:in:%llu/out:%llu\n",
        static_cast<unsigned long long>(current.stats_report_count),
        elapsed_seconds,
        static_cast<unsigned long long>(current.inbound_video_packets_received),
        static_cast<long long>(current.inbound_video_packets_lost),
        static_cast<unsigned long long>(current.inbound_video_bytes_received),
        static_cast<unsigned long long>(delta_frames),
        delta_bitrate,
        static_cast<unsigned long long>(current.inbound_video_frames_received),
        static_cast<unsigned long long>(current.inbound_video_frames_decoded),
        static_cast<unsigned long long>(current.inbound_video_frames_dropped),
        static_cast<unsigned long long>(current.inbound_video_key_frames_decoded),
        current.inbound_video_frames_per_second,
        delta_fps,
        current.inbound_video_frame_width,
        current.inbound_video_frame_height,
        current.inbound_video_decoder_implementation.empty()
            ? "unknown"
            : current.inbound_video_decoder_implementation.c_str(),
        decode_average_ms,
        processing_average_ms,
        current.inbound_video_jitter * 1000.0,
        jitter_buffer_average_ms,
        jitter_buffer_target_average_ms,
        jitter_buffer_minimum_average_ms,
        static_cast<unsigned long long>(current.inbound_video_jitter_buffer_emitted_count),
        static_cast<unsigned long long>(current.inbound_video_freeze_count),
        current.inbound_video_total_freezes_duration,
        static_cast<unsigned long long>(current.inbound_video_pli_count),
        static_cast<unsigned long long>(current.inbound_video_fir_count),
        static_cast<unsigned long long>(current.inbound_video_nack_count),
        current.selected_pair_state.empty() ? "unknown" : current.selected_pair_state.c_str(),
        current.selected_local_candidate_type.empty()
            ? "unknown"
            : current.selected_local_candidate_type.c_str(),
        current.selected_remote_candidate_type.empty()
            ? "unknown"
            : current.selected_remote_candidate_type.c_str(),
        current.selected_candidate_protocol.empty()
            ? "unknown"
            : current.selected_candidate_protocol.c_str(),
        current.selected_local_network_type.empty()
            ? "unknown"
            : current.selected_local_network_type.c_str(),
        current.selected_relay_protocol.empty()
            ? "none"
            : current.selected_relay_protocol.c_str(),
        current_round_trip_time_ms,
        current.selected_pair_available_incoming_bitrate,
        current.selected_pair_available_outgoing_bitrate,
        static_cast<unsigned long long>(current.selected_pair_packets_received),
        static_cast<unsigned long long>(current.selected_pair_packets_sent));
}

class SyntheticAudioDeviceModule
    : public webrtc::webrtc_impl::AudioDeviceModuleDefault<webrtc::AudioDeviceModule> {
 public:
    ~SyntheticAudioDeviceModule() override {
        stop_worker();
    }

    int32_t RegisterAudioCallback(webrtc::AudioTransport* audio_callback) override {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        audio_callback_ = audio_callback;
        return 0;
    }

    int32_t Init() override {
        initialized_.store(true);
        return 0;
    }

    int32_t Terminate() override {
        recording_.store(false);
        playing_.store(false);
        stop_worker();
        initialized_.store(false);
        return 0;
    }

    bool Initialized() const override {
        return initialized_.load();
    }

    int32_t ActiveAudioLayer(AudioLayer* audio_layer) const override {
        if (audio_layer != nullptr) {
            *audio_layer = webrtc::AudioDeviceModule::kDummyAudio;
        }
        return 0;
    }

    int16_t PlayoutDevices() override {
        return 1;
    }

    int16_t RecordingDevices() override {
        return 1;
    }

    int32_t PlayoutDeviceName(
        uint16_t,
        char name[webrtc::kAdmMaxDeviceNameSize],
        char guid[webrtc::kAdmMaxGuidSize]) override {
        write_device_name(name, guid, "DinoX synthetic speaker");
        return 0;
    }

    int32_t RecordingDeviceName(
        uint16_t,
        char name[webrtc::kAdmMaxDeviceNameSize],
        char guid[webrtc::kAdmMaxGuidSize]) override {
        write_device_name(name, guid, "DinoX synthetic microphone");
        return 0;
    }

    int32_t SetPlayoutDevice(uint16_t index) override {
        return index == 0 ? 0 : -1;
    }

    int32_t SetRecordingDevice(uint16_t index) override {
        return index == 0 ? 0 : -1;
    }

    int32_t PlayoutIsAvailable(bool* available) override {
        if (available != nullptr) {
            *available = true;
        }
        return 0;
    }

    int32_t RecordingIsAvailable(bool* available) override {
        if (available != nullptr) {
            *available = true;
        }
        return 0;
    }

    int32_t InitPlayout() override {
        playout_initialized_.store(true);
        return 0;
    }

    bool PlayoutIsInitialized() const override {
        return playout_initialized_.load();
    }

    int32_t InitRecording() override {
        recording_initialized_.store(true);
        return 0;
    }

    bool RecordingIsInitialized() const override {
        return recording_initialized_.load();
    }

    int32_t StartPlayout() override {
        playing_.store(true);
        ensure_worker();
        return 0;
    }

    int32_t StopPlayout() override {
        playing_.store(false);
        stop_worker_if_idle();
        return 0;
    }

    bool Playing() const override {
        return playing_.load();
    }

    int32_t StartRecording() override {
        recording_.store(true);
        ensure_worker();
        return 0;
    }

    int32_t StopRecording() override {
        recording_.store(false);
        stop_worker_if_idle();
        return 0;
    }

    bool Recording() const override {
        return recording_.load();
    }

    std::optional<webrtc::AudioDeviceModule::Stats> GetStats() const override {
        webrtc::AudioDeviceModule::Stats stats;
        stats.total_capture_samples_count = captured_sample_count_.load();
        stats.total_capture_samples_duration_s =
            static_cast<double>(captured_sample_count_.load()) / kSampleRateHz;
        stats.total_samples_count = pulled_playout_sample_count_.load();
        stats.total_samples_duration_s =
            static_cast<double>(pulled_playout_sample_count_.load()) / kSampleRateHz;
        return stats;
    }

 private:
    static constexpr int kSampleRateHz = 48000;
    static constexpr size_t kChannelCount = 1;
    static constexpr size_t kFramesPerBuffer = 480;
    static constexpr size_t kBytesPerSample = sizeof(int16_t);

    static void write_device_name(
        char name[webrtc::kAdmMaxDeviceNameSize],
        char guid[webrtc::kAdmMaxGuidSize],
        const char* value) {
        if (name != nullptr) {
            std::snprintf(name, webrtc::kAdmMaxDeviceNameSize, "%s", value);
        }
        if (guid != nullptr) {
            std::snprintf(guid, webrtc::kAdmMaxGuidSize, "%s", value);
        }
    }

    webrtc::AudioTransport* copy_audio_callback() const {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        return audio_callback_;
    }

    void ensure_worker() {
        std::lock_guard<std::mutex> lock(worker_mutex_);
        if (worker_.joinable()) {
            return;
        }
        stop_worker_.store(false);
        worker_ = std::thread([this]() { worker_loop(); });
    }

    void stop_worker_if_idle() {
        if (!recording_.load() && !playing_.load()) {
            stop_worker();
        }
    }

    void stop_worker() {
        std::thread worker_to_join;
        {
            std::lock_guard<std::mutex> lock(worker_mutex_);
            if (!worker_.joinable()) {
                return;
            }
            stop_worker_.store(true);
            worker_to_join = std::move(worker_);
        }
        worker_to_join.join();
        stop_worker_.store(false);
    }

    void worker_loop() {
        auto next_tick = std::chrono::steady_clock::now();
        while (!stop_worker_.load()) {
            next_tick += std::chrono::milliseconds(10);

            webrtc::AudioTransport* audio_callback = copy_audio_callback();
            if (audio_callback != nullptr) {
                if (recording_.load()) {
                    push_capture_frame(audio_callback);
                }
                if (playing_.load()) {
                    pull_playout_frame(audio_callback);
                }
            }

            std::this_thread::sleep_until(next_tick);
        }
    }

    void push_capture_frame(webrtc::AudioTransport* audio_callback) {
        std::array<int16_t, kFramesPerBuffer * kChannelCount> frame = {};
        for (size_t i = 0; i < frame.size(); ++i) {
            frame[i] = ((capture_sample_position_++ / 24) % 2) == 0 ? 12000 : -12000;
        }

        uint32_t new_mic_level = current_mic_level_;
        audio_callback->RecordedDataIsAvailable(
            frame.data(),
            kFramesPerBuffer,
            kBytesPerSample,
            kChannelCount,
            kSampleRateHz,
            0,
            0,
            current_mic_level_,
            false,
            new_mic_level);
        current_mic_level_ = new_mic_level;
        captured_sample_count_.fetch_add(frame.size());
    }

    void pull_playout_frame(webrtc::AudioTransport* audio_callback) {
        std::array<int16_t, kFramesPerBuffer * kChannelCount> frame = {};
        size_t samples_out = 0;
        int64_t elapsed_time_ms = 0;
        int64_t ntp_time_ms = 0;
        audio_callback->NeedMorePlayData(
            kFramesPerBuffer,
            kBytesPerSample,
            kChannelCount,
            kSampleRateHz,
            frame.data(),
            samples_out,
            &elapsed_time_ms,
            &ntp_time_ms);
        pulled_playout_sample_count_.fetch_add(samples_out * kChannelCount);
    }

    mutable std::mutex callback_mutex_;
    webrtc::AudioTransport* audio_callback_ = nullptr;
    std::mutex worker_mutex_;
    std::thread worker_;
    std::atomic<bool> initialized_ = true;
    std::atomic<bool> playout_initialized_ = true;
    std::atomic<bool> recording_initialized_ = true;
    std::atomic<bool> recording_ = false;
    std::atomic<bool> playing_ = false;
    std::atomic<bool> stop_worker_ = false;
    std::atomic<uint64_t> captured_sample_count_ = 0;
    std::atomic<uint64_t> pulled_playout_sample_count_ = 0;
    size_t capture_sample_position_ = 0;
    uint32_t current_mic_level_ = 0;
};

class MeasuringAudioDeviceModule
    : public webrtc::webrtc_impl::AudioDeviceModuleDefault<webrtc::AudioDeviceModule> {
 public:
    MeasuringAudioDeviceModule(
        webrtc::scoped_refptr<webrtc::AudioDeviceModule> delegate,
        std::shared_ptr<AudioCaptureProbe> capture_probe,
        std::shared_ptr<LocalDtmfToneGenerator> local_dtmf_tones,
        std::shared_ptr<LocalAudioTestClip> local_audio_test_clip,
        std::shared_ptr<AudioCaptureRouter> capture_router,
        std::shared_ptr<AudioGainState> audio_gain_state)
        : delegate_(std::move(delegate)),
          capture_probe_(std::move(capture_probe)),
          local_dtmf_tones_(std::move(local_dtmf_tones)),
          local_audio_test_clip_(std::move(local_audio_test_clip)),
          capture_router_(std::move(capture_router)),
          audio_gain_state_(std::move(audio_gain_state)) {}

    int32_t ensure_audio_device_selected(int incoming) {
        return incoming != 0 ?
            ensure_playout_device_selected() :
            ensure_recording_device_selected();
    }

    int32_t RegisterAudioCallback(webrtc::AudioTransport* audio_callback) override {
        if (delegate_ == nullptr) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(transport_mutex_);
        if (terminated_) {
            return -1;
        }
        if (transport_registered_) {
            measuring_transport_->set_delegate(audio_callback);
            standalone_test_playout_transport_ = false;
            return 0;
        }
        if (audio_callback == nullptr && recorder_capture_ref_count_ == 0) {
            return delegate_->RegisterAudioCallback(nullptr);
        }
        int32_t result =
            ensure_transport_registered_locked(audio_callback);
        standalone_test_playout_transport_ = false;
        return result;
    }

    DinoXWebrtcStatus ensure_standalone_test_playout_transport() {
        if (delegate_ == nullptr) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        std::lock_guard<std::mutex> lock(transport_mutex_);
        if (terminated_) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        int32_t result = ensure_transport_registered_locked(nullptr);
        if (result != 0) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        standalone_test_playout_transport_ = true;
        return DINOX_WEBRTC_STATUS_OK;
    }

    void stop_standalone_test_playout_transport() {
        if (delegate_ == nullptr) {
            return;
        }

        std::lock_guard<std::mutex> lock(transport_mutex_);
        if (!standalone_test_playout_transport_) {
            return;
        }
        standalone_test_playout_transport_ = false;
    }

    DinoXWebrtcStatus start_media_recorder_capture() {
        if (delegate_ == nullptr) {
            recorder_debug("start_media_recorder_capture failed: missing delegate ADM");
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        {
            std::lock_guard<std::mutex> lock(transport_mutex_);
            if (terminated_) {
                recorder_debug("start_media_recorder_capture failed: terminated ADM");
                return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            }
            recorder_capture_ref_count_++;
            int32_t result = ensure_transport_registered_locked(nullptr);
            if (result != 0) {
                recorder_capture_ref_count_--;
                recorder_debug("start_media_recorder_capture failed: RegisterAudioCallback");
                return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            }
        }

        int16_t recording_device_count = delegate_->RecordingDevices();
        if (recording_device_count <= 0) {
            stop_media_recorder_capture();
            recorder_debug("start_media_recorder_capture failed: no recording devices");
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        if (ensure_recording_device_selected() != 0) {
            stop_media_recorder_capture();
            recorder_debug("start_media_recorder_capture failed: selecting recording device");
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        if (!delegate_->MicrophoneIsInitialized() && delegate_->InitMicrophone() != 0) {
            stop_media_recorder_capture();
            recorder_debug("start_media_recorder_capture failed: InitMicrophone");
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        if (!delegate_->RecordingIsInitialized() && delegate_->InitRecording() != 0) {
            stop_media_recorder_capture();
            recorder_debug("start_media_recorder_capture failed: InitRecording");
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        bool was_recording = delegate_->Recording();
        if (!was_recording && delegate_->StartRecording() != 0) {
            stop_media_recorder_capture();
            recorder_debug("start_media_recorder_capture failed: StartRecording");
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        if (!was_recording) {
            std::lock_guard<std::mutex> lock(transport_mutex_);
            recorder_started_recording_ = true;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    void stop_media_recorder_capture() {
        if (delegate_ == nullptr) {
            return;
        }

        bool should_stop_recording = false;
        {
            std::lock_guard<std::mutex> lock(transport_mutex_);
            if (recorder_capture_ref_count_ > 0) {
                recorder_capture_ref_count_--;
            }
            if (recorder_capture_ref_count_ == 0) {
                should_stop_recording = recorder_started_recording_;
                recorder_started_recording_ = false;
                standalone_test_playout_transport_ = false;
            }
        }

        if (should_stop_recording && delegate_->Recording()) {
            delegate_->StopRecording();
        }
    }

    int32_t ActiveAudioLayer(webrtc::AudioDeviceModule::AudioLayer* audio_layer) const override {
        return delegate_ != nullptr ? delegate_->ActiveAudioLayer(audio_layer) : -1;
    }
    int32_t Init() override {
        if (delegate_ == nullptr) {
            return -1;
        }

        // libwebrtc terminates the shared ADM when the last active audio
        // channel disappears and initializes that same ADM again for a later
        // call in the still-live PeerConnectionFactory.  `terminated_` is
        // therefore a per-activation state, not a terminal wrapper state.
        // Reset it only after the native ADM has initialized successfully so
        // RegisterAudioCallback() can install the new VoiceEngine transport.
        int32_t result = delegate_->Init();
        if (result == 0) {
            std::lock_guard<std::mutex> lock(transport_mutex_);
            terminated_ = false;
        }
        return result;
    }
    int32_t Terminate() override {
        if (delegate_ == nullptr) {
            return -1;
        }

        bool transport_registered = false;
        {
            std::lock_guard<std::mutex> lock(transport_mutex_);
            if (terminated_) {
                return 0;
            }
            terminated_ = true;
            recorder_capture_ref_count_ = 0;
            recorder_started_recording_ = false;
            standalone_test_playout_transport_ = false;
            transport_registered = transport_registered_;
            if (measuring_transport_ != nullptr) {
                measuring_transport_->set_delegate(nullptr);
            }
        }

        // AudioDeviceBuffer documents that its raw transport pointer must not
        // change while media is active. Terminate first joins the native ADM
        // threads; the stable wrapper remains alive throughout that join.
        int32_t terminate_result = delegate_->Terminate();
        {
            std::lock_guard<std::mutex> lock(device_mutex_);
            // Terminate invalidates native device selection. Keep the user's
            // preferred indices, but reselect them when this shared ADM is
            // initialized for a later MUJI peer or call.
            playout_device_selected_ = false;
            recording_device_selected_ = false;
        }
        int32_t callback_result = 0;
        if (transport_registered) {
            callback_result = delegate_->RegisterAudioCallback(nullptr);
            std::lock_guard<std::mutex> lock(transport_mutex_);
            if (callback_result == 0) {
                transport_registered_ = false;
            }
        }
        return terminate_result != 0 ? terminate_result : callback_result;
    }
    bool Initialized() const override { return delegate_ != nullptr && delegate_->Initialized(); }
    int16_t PlayoutDevices() override { return delegate_ != nullptr ? delegate_->PlayoutDevices() : -1; }
    int16_t RecordingDevices() override { return delegate_ != nullptr ? delegate_->RecordingDevices() : -1; }
    int32_t PlayoutDeviceName(
        uint16_t index,
        char name[webrtc::kAdmMaxDeviceNameSize],
        char guid[webrtc::kAdmMaxGuidSize]) override {
        return delegate_ != nullptr ? delegate_->PlayoutDeviceName(index, name, guid) : -1;
    }
    int32_t RecordingDeviceName(
        uint16_t index,
        char name[webrtc::kAdmMaxDeviceNameSize],
        char guid[webrtc::kAdmMaxGuidSize]) override {
        return delegate_ != nullptr ? delegate_->RecordingDeviceName(index, name, guid) : -1;
    }
    int32_t SetPlayoutDevice(uint16_t index) override {
        if (delegate_ == nullptr) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(device_mutex_);
        if (device_debug_enabled()) {
            device_debug(
                "DinoX WebRTC device: event=set-playout-index-enter index=%u selected=%d selected_index=%d initialized=%d playing=%d\n",
                static_cast<unsigned int>(index),
                playout_device_selected_ ? 1 : 0,
                selected_playout_device_index_.has_value() ?
                    static_cast<int>(selected_playout_device_index_.value()) : -1,
                delegate_->PlayoutIsInitialized() ? 1 : 0,
                delegate_->Playing() ? 1 : 0);
        }
        if (playout_device_selected_ &&
                selected_playout_device_index_.has_value() &&
                selected_playout_device_index_.value() == index) {
            return 0;
        }
        if (delegate_->Playing()) {
            return -1;
        }
        if (delegate_->PlayoutIsInitialized() && delegate_->StopPlayout() != 0) {
            return -1;
        }
        int32_t result = delegate_->SetPlayoutDevice(index);
        if (result == 0) {
            selected_playout_device_index_ = index;
            playout_device_selected_ = true;
        }
        if (device_debug_enabled()) {
            device_debug(
                "DinoX WebRTC device: event=set-playout-index-exit index=%u result=%d selected=%d selected_index=%d\n",
                static_cast<unsigned int>(index),
                result,
                playout_device_selected_ ? 1 : 0,
                selected_playout_device_index_.has_value() ?
                    static_cast<int>(selected_playout_device_index_.value()) : -1);
        }
        return result;
    }
    int32_t SetPlayoutDevice(webrtc::AudioDeviceModule::WindowsDeviceType device) override {
        if (delegate_ == nullptr) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(device_mutex_);
        if (device_debug_enabled()) {
            device_debug(
                "DinoX WebRTC device: event=set-playout-default-enter device=%d initialized=%d playing=%d\n",
                static_cast<int>(device),
                delegate_->PlayoutIsInitialized() ? 1 : 0,
                delegate_->Playing() ? 1 : 0);
        }
        if (delegate_->Playing()) {
            return -1;
        }
        if (delegate_->PlayoutIsInitialized() && delegate_->StopPlayout() != 0) {
            return -1;
        }
        int32_t result = delegate_->SetPlayoutDevice(device);
        if (result == 0) {
            selected_playout_device_index_.reset();
            playout_device_selected_ = true;
        }
        if (device_debug_enabled()) {
            device_debug(
                "DinoX WebRTC device: event=set-playout-default-exit device=%d result=%d\n",
                static_cast<int>(device),
                result);
        }
        return result;
    }
    int32_t SetRecordingDevice(uint16_t index) override {
        if (delegate_ == nullptr) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(device_mutex_);
        if (recording_device_selected_ &&
                selected_recording_device_index_.has_value() &&
                selected_recording_device_index_.value() == index) {
            return 0;
        }
        if (delegate_->Recording()) {
            return -1;
        }
        if (delegate_->RecordingIsInitialized() && delegate_->StopRecording() != 0) {
            return -1;
        }
        int32_t result = delegate_->SetRecordingDevice(index);
        if (result == 0) {
            selected_recording_device_index_ = index;
            recording_device_selected_ = true;
        }
        return result;
    }
    int32_t SetRecordingDevice(webrtc::AudioDeviceModule::WindowsDeviceType device) override {
        if (delegate_ == nullptr) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(device_mutex_);
        if (delegate_->Recording()) {
            return -1;
        }
        if (delegate_->RecordingIsInitialized() && delegate_->StopRecording() != 0) {
            return -1;
        }
        int32_t result = delegate_->SetRecordingDevice(device);
        if (result == 0) {
            selected_recording_device_index_.reset();
            recording_device_selected_ = true;
        }
        return result;
    }
    int32_t PlayoutIsAvailable(bool* available) override {
        return delegate_ != nullptr ? delegate_->PlayoutIsAvailable(available) : -1;
    }
    int32_t InitPlayout() override {
        if (delegate_ == nullptr || ensure_playout_device_selected() != 0) {
            return -1;
        }
        return delegate_->InitPlayout();
    }
    bool PlayoutIsInitialized() const override {
        return delegate_ != nullptr && delegate_->PlayoutIsInitialized();
    }
    int32_t RecordingIsAvailable(bool* available) override {
        return delegate_ != nullptr ? delegate_->RecordingIsAvailable(available) : -1;
    }
    int32_t InitRecording() override {
        if (delegate_ == nullptr || ensure_recording_device_selected() != 0) {
            return -1;
        }
        return delegate_->InitRecording();
    }
    bool RecordingIsInitialized() const override {
        return delegate_ != nullptr && delegate_->RecordingIsInitialized();
    }
    int32_t StartPlayout() override { return delegate_ != nullptr ? delegate_->StartPlayout() : -1; }
    int32_t StopPlayout() override { return delegate_ != nullptr ? delegate_->StopPlayout() : -1; }
    bool Playing() const override { return delegate_ != nullptr && delegate_->Playing(); }
    int32_t StartRecording() override { return delegate_ != nullptr ? delegate_->StartRecording() : -1; }
    int32_t StopRecording() override { return delegate_ != nullptr ? delegate_->StopRecording() : -1; }
    bool Recording() const override { return delegate_ != nullptr && delegate_->Recording(); }
    int32_t InitSpeaker() override { return delegate_ != nullptr ? delegate_->InitSpeaker() : -1; }
    bool SpeakerIsInitialized() const override {
        return delegate_ != nullptr && delegate_->SpeakerIsInitialized();
    }
    int32_t InitMicrophone() override { return delegate_ != nullptr ? delegate_->InitMicrophone() : -1; }
    bool MicrophoneIsInitialized() const override {
        return delegate_ != nullptr && delegate_->MicrophoneIsInitialized();
    }
    int32_t SpeakerVolumeIsAvailable(bool* available) override {
        return delegate_ != nullptr ? delegate_->SpeakerVolumeIsAvailable(available) : -1;
    }
    int32_t SetSpeakerVolume(uint32_t volume) override {
        return delegate_ != nullptr ? delegate_->SetSpeakerVolume(volume) : -1;
    }
    int32_t SpeakerVolume(uint32_t* volume) const override {
        return delegate_ != nullptr ? delegate_->SpeakerVolume(volume) : -1;
    }
    int32_t MaxSpeakerVolume(uint32_t* max_volume) const override {
        return delegate_ != nullptr ? delegate_->MaxSpeakerVolume(max_volume) : -1;
    }
    int32_t MinSpeakerVolume(uint32_t* min_volume) const override {
        return delegate_ != nullptr ? delegate_->MinSpeakerVolume(min_volume) : -1;
    }
    int32_t MicrophoneVolumeIsAvailable(bool* available) override {
        return delegate_ != nullptr ? delegate_->MicrophoneVolumeIsAvailable(available) : -1;
    }
    int32_t SetMicrophoneVolume(uint32_t volume) override {
        return delegate_ != nullptr ? delegate_->SetMicrophoneVolume(volume) : -1;
    }
    int32_t MicrophoneVolume(uint32_t* volume) const override {
        return delegate_ != nullptr ? delegate_->MicrophoneVolume(volume) : -1;
    }
    int32_t MaxMicrophoneVolume(uint32_t* max_volume) const override {
        return delegate_ != nullptr ? delegate_->MaxMicrophoneVolume(max_volume) : -1;
    }
    int32_t MinMicrophoneVolume(uint32_t* min_volume) const override {
        return delegate_ != nullptr ? delegate_->MinMicrophoneVolume(min_volume) : -1;
    }
    int32_t SpeakerMuteIsAvailable(bool* available) override {
        return delegate_ != nullptr ? delegate_->SpeakerMuteIsAvailable(available) : -1;
    }
    int32_t SetSpeakerMute(bool enable) override {
        return delegate_ != nullptr ? delegate_->SetSpeakerMute(enable) : -1;
    }
    int32_t SpeakerMute(bool* enabled) const override {
        return delegate_ != nullptr ? delegate_->SpeakerMute(enabled) : -1;
    }
    int32_t MicrophoneMuteIsAvailable(bool* available) override {
        return delegate_ != nullptr ? delegate_->MicrophoneMuteIsAvailable(available) : -1;
    }
    int32_t SetMicrophoneMute(bool enable) override {
        return delegate_ != nullptr ? delegate_->SetMicrophoneMute(enable) : -1;
    }
    int32_t MicrophoneMute(bool* enabled) const override {
        return delegate_ != nullptr ? delegate_->MicrophoneMute(enabled) : -1;
    }
    int32_t StereoPlayoutIsAvailable(bool* available) const override {
        return delegate_ != nullptr ? delegate_->StereoPlayoutIsAvailable(available) : -1;
    }
    int32_t SetStereoPlayout(bool enable) override {
        return delegate_ != nullptr ? delegate_->SetStereoPlayout(enable) : -1;
    }
    int32_t StereoPlayout(bool* enabled) const override {
        return delegate_ != nullptr ? delegate_->StereoPlayout(enabled) : -1;
    }
    int32_t StereoRecordingIsAvailable(bool* available) const override {
        return delegate_ != nullptr ? delegate_->StereoRecordingIsAvailable(available) : -1;
    }
    int32_t SetStereoRecording(bool enable) override {
        return delegate_ != nullptr ? delegate_->SetStereoRecording(enable) : -1;
    }
    int32_t StereoRecording(bool* enabled) const override {
        return delegate_ != nullptr ? delegate_->StereoRecording(enabled) : -1;
    }
    int32_t PlayoutDelay(uint16_t* delay_ms) const override {
        return delegate_ != nullptr ? delegate_->PlayoutDelay(delay_ms) : -1;
    }
    bool BuiltInAECIsAvailable() const override {
        return delegate_ != nullptr && delegate_->BuiltInAECIsAvailable();
    }
    bool BuiltInAGCIsAvailable() const override {
        return delegate_ != nullptr && delegate_->BuiltInAGCIsAvailable();
    }
    bool BuiltInNSIsAvailable() const override {
        return delegate_ != nullptr && delegate_->BuiltInNSIsAvailable();
    }
    int32_t EnableBuiltInAEC(bool enable) override {
        return delegate_ != nullptr ? delegate_->EnableBuiltInAEC(enable) : -1;
    }
    int32_t EnableBuiltInAGC(bool enable) override {
        return delegate_ != nullptr ? delegate_->EnableBuiltInAGC(enable) : -1;
    }
    int32_t EnableBuiltInNS(bool enable) override {
        return delegate_ != nullptr ? delegate_->EnableBuiltInNS(enable) : -1;
    }
    int32_t GetPlayoutUnderrunCount() const override {
        return delegate_ != nullptr ? delegate_->GetPlayoutUnderrunCount() : -1;
    }
    std::optional<webrtc::AudioDeviceModule::Stats> GetStats() const override {
        std::optional<webrtc::AudioDeviceModule::Stats> stats =
            delegate_ != nullptr ? delegate_->GetStats() : std::nullopt;
        if (!stats.has_value()) {
            stats = webrtc::AudioDeviceModule::Stats();
        }
        if (capture_probe_ != nullptr) {
            uint64_t frame_count = 0;
            uint64_t sample_count = 0;
            double peak_level = 0.0;
            capture_probe_->snapshot(&frame_count, &sample_count, &peak_level);
            if (sample_count > stats->total_capture_samples_count) {
                stats->total_capture_samples_count = sample_count;
            }
        }
        return stats;
    }

#if defined(WEBRTC_IOS)
    int GetPlayoutAudioParameters(webrtc::AudioParameters* params) const override {
        return delegate_ != nullptr ? delegate_->GetPlayoutAudioParameters(params) : -1;
    }
    int GetRecordAudioParameters(webrtc::AudioParameters* params) const override {
        return delegate_ != nullptr ? delegate_->GetRecordAudioParameters(params) : -1;
    }
#endif

 private:
    int32_t ensure_playout_device_selected() {
        std::lock_guard<std::mutex> lock(device_mutex_);
        if (device_debug_enabled()) {
            device_debug(
                "DinoX WebRTC device: event=ensure-playout selected=%d selected_index=%d initialized=%d playing=%d\n",
                playout_device_selected_ ? 1 : 0,
                selected_playout_device_index_.has_value() ?
                    static_cast<int>(selected_playout_device_index_.value()) : -1,
                delegate_ != nullptr && delegate_->PlayoutIsInitialized() ? 1 : 0,
                delegate_ != nullptr && delegate_->Playing() ? 1 : 0);
        }
        if (playout_device_selected_) {
            return 0;
        }
        int32_t result;
        if (selected_playout_device_index_.has_value()) {
            result = delegate_->SetPlayoutDevice(
                selected_playout_device_index_.value());
        } else {
#if defined(WEBRTC_WIN)
            result = delegate_->SetPlayoutDevice(
                webrtc::AudioDeviceModule::kDefaultDevice);
#else
            result = delegate_->SetPlayoutDevice(0);
#endif
        }
        if (result == 0) {
            playout_device_selected_ = true;
        }
        return result;
    }

    int32_t ensure_recording_device_selected() {
        std::lock_guard<std::mutex> lock(device_mutex_);
        if (recording_device_selected_) {
            return 0;
        }
        int32_t result;
        if (selected_recording_device_index_.has_value()) {
            result = delegate_->SetRecordingDevice(
                selected_recording_device_index_.value());
        } else {
#if defined(WEBRTC_WIN)
            result = delegate_->SetRecordingDevice(
                webrtc::AudioDeviceModule::kDefaultDevice);
#else
            result = delegate_->SetRecordingDevice(0);
#endif
        }
        if (result == 0) {
            recording_device_selected_ = true;
        }
        return result;
    }

    int32_t ensure_transport_registered_locked(
        webrtc::AudioTransport* initial_delegate) {
        if (transport_registered_) {
            return measuring_transport_ != nullptr ? 0 : -1;
        }

        auto measuring_transport =
            std::make_unique<MeasuringAudioTransport>(
                initial_delegate,
                capture_probe_,
                local_dtmf_tones_,
                local_audio_test_clip_,
                capture_router_,
                audio_gain_state_);
        int32_t result =
            delegate_->RegisterAudioCallback(measuring_transport.get());
        if (result == 0) {
            measuring_transport_ = std::move(measuring_transport);
            transport_registered_ = true;
        }
        return result;
    }

    // AudioDeviceBuffer retains its AudioTransport as a raw pointer. Declare
    // the stable wrapper before the native ADM so reverse field destruction
    // keeps the wrapper alive until after the ADM has gone away.
    std::unique_ptr<MeasuringAudioTransport> measuring_transport_;
    webrtc::scoped_refptr<webrtc::AudioDeviceModule> delegate_;
    std::shared_ptr<AudioCaptureProbe> capture_probe_;
    std::shared_ptr<LocalDtmfToneGenerator> local_dtmf_tones_;
    std::shared_ptr<LocalAudioTestClip> local_audio_test_clip_;
    std::shared_ptr<AudioCaptureRouter> capture_router_;
    std::shared_ptr<AudioGainState> audio_gain_state_;
    mutable std::mutex transport_mutex_;
    mutable std::mutex device_mutex_;
    std::optional<uint16_t> selected_playout_device_index_;
    std::optional<uint16_t> selected_recording_device_index_;
    bool playout_device_selected_ = false;
    bool recording_device_selected_ = false;
    unsigned int recorder_capture_ref_count_ = 0;
    bool recorder_started_recording_ = false;
    bool transport_registered_ = false;
    bool terminated_ = false;
    bool standalone_test_playout_transport_ = false;
};

struct ContextCore {
    std::unique_ptr<webrtc::Thread> network_thread;
    std::unique_ptr<webrtc::Thread> worker_thread;
    std::unique_ptr<webrtc::Thread> signaling_thread;
#if defined(WEBRTC_WIN)
    std::unique_ptr<webrtc::WinsockInitializer> windows_winsock_initializer;
    // Keep COM initialized on the worker process' context thread for at least
    // as long as the Windows Core Audio ADM exists.
    std::unique_ptr<webrtc::ScopedCOMInitializer> windows_com_initializer;
#endif
    webrtc::scoped_refptr<webrtc::AudioDeviceModule> audio_device_module;
    webrtc::scoped_refptr<MeasuringAudioDeviceModule> measuring_audio_device_module;
    std::shared_ptr<AudioCaptureProbe> audio_capture_probe = std::make_shared<AudioCaptureProbe>();
    std::shared_ptr<AudioCaptureRouter> audio_capture_router = std::make_shared<AudioCaptureRouter>();
    std::shared_ptr<LocalDtmfToneGenerator> local_dtmf_tones = std::make_shared<LocalDtmfToneGenerator>();
    std::shared_ptr<LocalAudioTestClip> local_audio_test_clip = std::make_shared<LocalAudioTestClip>();
    std::shared_ptr<AudioGainState> audio_gain_state = std::make_shared<AudioGainState>();
    webrtc::scoped_refptr<webrtc::AudioMixer> audio_mixer;
    webrtc::scoped_refptr<webrtc::PeerConnectionFactoryInterface> factory;
    DinoXWebrtcAudioDeviceMode audio_device_mode = DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC;
    bool ssl_retained = false;
    bool local_dtmf_tone_source_added = false;
    std::mutex audio_volume_mutex;
    std::mutex activity_mutex;
    uint64_t test_tone_generation = 0;
    unsigned int active_session_count = 0;
    double cached_microphone_volume = 1.0;
    double cached_speaker_volume = 1.0;

    explicit ContextCore(DinoXWebrtcAudioDeviceMode audio_device_mode)
        : audio_device_mode(audio_device_mode) {}

    ~ContextCore() {
        // Release every owner of the Windows ADM while this creating thread is
        // still COM initialized. `audio_device_module` and
        // `measuring_audio_device_module` reference the same wrapper; clearing
        // only the interface reference leaves the final Core Audio/COM release
        // until after the destructor body and therefore after CoUninitialize().
        factory = nullptr;
        if (audio_mixer != nullptr && local_dtmf_tone_source_added && local_dtmf_tones != nullptr) {
            audio_mixer->RemoveSource(local_dtmf_tones.get());
            local_dtmf_tone_source_added = false;
        }
        audio_mixer = nullptr;
        if (measuring_audio_device_module != nullptr) {
            measuring_audio_device_module->Terminate();
        }
        audio_device_module = nullptr;
        measuring_audio_device_module = nullptr;
#if defined(WEBRTC_WIN)
        windows_com_initializer = nullptr;
#endif
        if (signaling_thread != nullptr) {
            signaling_thread->Stop();
        }
        if (worker_thread != nullptr) {
            worker_thread->Stop();
        }
        if (network_thread != nullptr) {
            network_thread->Stop();
        }
#if defined(WEBRTC_WIN)
        windows_winsock_initializer = nullptr;
#endif
        if (ssl_retained) {
            release_ssl();
        }
    }

    DinoXWebrtcStatus initialize() {
        DinoXWebrtcStatus ssl_status = retain_ssl();
        if (ssl_status != DINOX_WEBRTC_STATUS_OK) {
            return ssl_status;
        }
        ssl_retained = true;

#if defined(WEBRTC_WIN)
        windows_winsock_initializer = std::make_unique<webrtc::WinsockInitializer>();
        if (windows_winsock_initializer->error() != 0) {
            windows_winsock_initializer = nullptr;
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
#endif

        network_thread = webrtc::Thread::CreateWithSocketServer();
        worker_thread = webrtc::Thread::Create();
        signaling_thread = webrtc::Thread::Create();
        if (network_thread == nullptr || worker_thread == nullptr || signaling_thread == nullptr) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        network_thread->SetName("dinox-webrtc-network", nullptr);
        worker_thread->SetName("dinox-webrtc-worker", nullptr);
        signaling_thread->SetName("dinox-webrtc-signaling", nullptr);

        if (!network_thread->Start() || !worker_thread->Start() || !signaling_thread->Start()) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

#if defined(WEBRTC_WIN)
        if (audio_device_mode == DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT) {
            windows_com_initializer = std::make_unique<webrtc::ScopedCOMInitializer>(
                webrtc::ScopedCOMInitializer::kMTA);
            if (!windows_com_initializer->Succeeded()) {
                windows_com_initializer = nullptr;
                return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            }
        }
#endif

        measuring_audio_device_module = create_audio_device_module(
            audio_device_mode,
            audio_capture_probe,
            local_dtmf_tones,
            local_audio_test_clip,
            audio_capture_router,
            audio_gain_state);
        audio_device_module = measuring_audio_device_module;
        if (audio_device_module == nullptr) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        // The platform ADM must be initialized before DinoX enumerates or
        // selects devices. Without this, Linux backends can return
        // internal-error for RecordingDevices()/PlayoutDevices() even though
        // the default PipeWire/PulseAudio devices exist.
        if (audio_device_module->Init() != 0) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        webrtc::AudioProcessing::Config audio_processing_config;
        // The M150 built-in noise suppressor can abort with
        // RTC_NOTREACHED in InitializeNoiseSuppressor() when DinoX creates a
        // second Linux PulseAudio-backed call context in the same process.
        // Keep WebRTC's basic echo/high-pass pipeline active, but do not
        // enable the crashing noise suppressor path or DinoX-specific digital
        // gain in the native wrapper.
        audio_processing_config.high_pass_filter.enabled = true;
        audio_processing_config.echo_canceller.enabled = true;
        audio_processing_config.noise_suppression.enabled = false;

        webrtc::BuiltinAudioProcessingBuilder audio_processing_builder;
        audio_processing_builder.SetConfig(audio_processing_config);
        webrtc::scoped_refptr<webrtc::AudioProcessing> audio_processing =
            audio_processing_builder.Build(webrtc::CreateEnvironment());
        if (audio_processing == nullptr) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        audio_processing->SetRuntimeSetting(
            webrtc::AudioProcessing::RuntimeSetting::CreateCaptureOutputUsedSetting(true));

        audio_mixer = webrtc::AudioMixerImpl::Create();
        if (audio_mixer == nullptr || local_dtmf_tones == nullptr) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        if (!audio_mixer->AddSource(local_dtmf_tones.get())) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        local_dtmf_tone_source_added = true;

        factory = webrtc::CreatePeerConnectionFactory(
            network_thread.get(),
            worker_thread.get(),
            signaling_thread.get(),
            audio_device_module,
            webrtc::CreateBuiltinAudioEncoderFactory(),
            webrtc::CreateBuiltinAudioDecoderFactory(),
            dinox::webrtc_runtime::CreateVideoEncoderFactory(),
            dinox::webrtc_runtime::CreateVideoDecoderFactory(),
            audio_mixer,
            audio_processing);

        if (factory == nullptr) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        return DINOX_WEBRTC_STATUS_OK;
    }

    static webrtc::scoped_refptr<MeasuringAudioDeviceModule> create_audio_device_module(
            DinoXWebrtcAudioDeviceMode mode,
            std::shared_ptr<AudioCaptureProbe> capture_probe,
            std::shared_ptr<LocalDtmfToneGenerator> local_dtmf_tones,
            std::shared_ptr<LocalAudioTestClip> local_audio_test_clip,
            std::shared_ptr<AudioCaptureRouter> capture_router,
            std::shared_ptr<AudioGainState> audio_gain_state) {
        webrtc::scoped_refptr<webrtc::AudioDeviceModule> delegate;
        if (mode == DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT) {
#if defined(WEBRTC_WIN)
            delegate = webrtc::CreateWindowsCoreAudioAudioDeviceModule(
                webrtc::CreateEnvironment());
#else
            delegate = webrtc::AudioDeviceModuleImpl::Create(
                webrtc::CreateEnvironment(),
                webrtc::AudioDeviceModule::kPlatformDefaultAudio);
#endif
        } else {
            delegate = webrtc::scoped_refptr<webrtc::AudioDeviceModule>(
                new webrtc::RefCountedObject<SyntheticAudioDeviceModule>());
        }
        if (delegate == nullptr) {
            return nullptr;
        }
        return webrtc::scoped_refptr<MeasuringAudioDeviceModule>(
            new webrtc::RefCountedObject<MeasuringAudioDeviceModule>(
                delegate,
                std::move(capture_probe),
                std::move(local_dtmf_tones),
                std::move(local_audio_test_clip),
                std::move(capture_router),
                std::move(audio_gain_state)));
    }

    void retain_session() {
        std::lock_guard<std::mutex> lock(activity_mutex);
        active_session_count++;
    }

    void release_session() {
        std::lock_guard<std::mutex> lock(activity_mutex);
        if (active_session_count > 0) {
            active_session_count--;
        }
    }

    uint64_t next_test_tone_generation() {
        std::lock_guard<std::mutex> lock(activity_mutex);
        test_tone_generation++;
        return test_tone_generation;
    }
};

struct SessionCore {
    explicit SessionCore(std::shared_ptr<ContextCore> context_in) : context(std::move(context_in)) {}

    std::shared_ptr<ContextCore> context;
    DinoXWebrtcCallbacks callbacks = {};
    void* user_data = nullptr;
    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection;
    webrtc::scoped_refptr<webrtc::AudioSourceInterface> local_audio_source;
    webrtc::scoped_refptr<webrtc::AudioTrackInterface> local_audio_track;
    webrtc::scoped_refptr<SyntheticVideoTrackSource> local_video_source;
    webrtc::scoped_refptr<webrtc::VideoTrackInterface> local_video_track;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> local_video_capture_module;
    std::unique_ptr<LocalVideoCaptureSink> local_video_capture_sink;
    std::vector<RemoteAudioSinkBinding> remote_audio_sinks;
    std::vector<RemoteVideoSinkBinding> remote_video_sinks;
    RtpStatsSnapshot cached_rtp_stats;
    DinoXWebrtcMediaDirection local_audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    DinoXWebrtcMediaDirection local_video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    bool stats_request_in_flight = false;
    bool rtc_event_log_started = false;
    DinoXWebrtcNetworkPolicy network_policy = DINOX_WEBRTC_NETWORK_POLICY_AUTOMATIC;
    int audio_sender_bitrate_cap_bps = 0;
    uint64_t control_id = 0;
    uint64_t synthetic_video_frame_id = 0;
    bool audio_sender_adaptive_ptime = false;
    bool audio_sender_policy_applied = false;
    // Two-phase MUJI SDP state: idle, preparing, prepared, committing.
    int local_description_phase = 0;
    DinoXWebrtcSdpType prepared_local_description_type = DINOX_WEBRTC_SDP_TYPE_OFFER;
    bool closed = false;
    std::atomic<bool> local_video_effect_active{false};
    // A detached/failed logical effect must not reopen raw camera publication.
    // This latch survives weak-pipeline loss until an explicit neutral binding.
    std::atomic<bool> local_video_privacy_required{false};
    std::atomic<uint64_t> local_video_camera_lease{0};
    std::atomic<uint64_t> local_video_camera_request{0};
    const uint64_t synthetic_camera_lease = g_next_control_object_id.fetch_add(1);
    std::weak_ptr<VideoPipelineCore> local_video_effect_pipeline;
    std::recursive_mutex callback_mutex;
    std::mutex mutex;
};

struct VideoPipelineAttachment {
    std::weak_ptr<SessionCore> session;
    DinoXWebrtcSession* public_session = nullptr;
    uint64_t subscriber_id = 0;
    uint64_t subscriber_generation = 0;
    // Changes whenever a binding is created or its publisher role changes.
    // Asynchronous effect output carries this token so a frame captured before
    // detach/reattach can never enter the replacement binding.
    uint64_t publication_token = 0;
    bool preview_publisher = false;
};

struct VideoPipelineCore {
    VideoPipelineCore(std::shared_ptr<ContextCore> context_in, uint64_t logical_call_id_in)
        : context(std::move(context_in)),
          pipeline_id(g_next_control_object_id.fetch_add(1)),
          logical_call_id(logical_call_id_in) {
        config.abi_version = DINOX_WEBRTC_ABI_VERSION;
        config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
        config.quality = DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO;
    }

    std::shared_ptr<ContextCore> context;
    DinoXWebrtcVideoPipelineCallbacks callbacks = {};
    void* user_data = nullptr;
    DinoXWebrtcVideoPipeline* public_pipeline = nullptr;
    const uint64_t pipeline_id;
    const uint64_t pipeline_generation = 1;
    const uint64_t logical_call_id;
    DinoXWebrtcVideoEffectConfig config = {};
    DinoXWebrtcVideoEffectApplicationState application_state =
        DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_IDLE;
    uint64_t accepted_revision = 0;
    uint64_t applied_revision = 0;
    uint64_t configuration_request_count = 0;
    std::unordered_map<SessionCore*, VideoPipelineAttachment> attachments;
    std::unordered_map<uint64_t, uint64_t> subscriber_generations;
    uint64_t capture_owner_publication_token = 0;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> video_capture_module;
    std::unique_ptr<LocalVideoCaptureSink> video_capture_sink;
    std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor> processor;
    std::shared_ptr<dinox::webrtc_effects::VideoRuntime> video_runtime =
        std::make_shared<dinox::webrtc_effects::VideoRuntime>(
            dinox::webrtc_effects::installed_vision_paths());
    uint64_t camera_lease = 0;
    uint64_t source_epoch = 1;
    uint64_t transform_epoch = 1;
    int source_width = 0, source_height = 0, source_rotation = -1;
    bool source_full_range=false,source_bt709=false;
    dinox::webrtc_effects::FrameIdentity frame_identity;
    bool closed = false;
    std::recursive_mutex callback_mutex;
    std::recursive_mutex publication_mutex;
    std::mutex mutex;
};

// Called inside the pipeline publication gate and core mutex BEFORE a device
// StopCapture can block. Immutable sink leases make all old callbacks stale.
void invalidate_video_source_locked(VideoPipelineCore* core) {
    if (!core) return;
    core->camera_lease = 0;
    if (core->source_epoch != UINT64_MAX) ++core->source_epoch;
    if (core->transform_epoch != UINT64_MAX) ++core->transform_epoch;
    core->source_width = core->source_height = 0; core->source_rotation = -1;
    core->frame_identity = {};
    core->video_runtime->invalidate(true);
    for (const auto& item : core->attachments)
        if (auto session = item.second.session.lock()) {
            session->local_video_camera_lease.store(0, std::memory_order_release);
            session->local_video_camera_request.store(0, std::memory_order_release);
        }
}

bool frame_privacy_proof_fresh(const dinox::webrtc_effects::FrameIdentity& identity) {
    if (identity.concealed) return true;
    const uint64_t now = dinox::vision::VisionClient::monotonic_now_ns();
    return identity.mask_capture_ns != 0 && identity.mask_capture_ns <= now &&
        now - identity.mask_capture_ns <= UINT64_C(500000000);
}

void set_video_pipeline_sessions_active_locked(
    VideoPipelineCore* core,
    bool active) {
    if (core == nullptr) return;
    for (const auto& item : core->attachments) {
        std::shared_ptr<SessionCore> session = item.second.session.lock();
        if (session != nullptr) {
            session->local_video_effect_active.store(
                active, active ? std::memory_order_release : std::memory_order_relaxed);
            session->local_video_privacy_required.store(
                core->config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE,
                std::memory_order_release);
        }
    }
}

struct MediaRecorderCore {
    explicit MediaRecorderCore(std::shared_ptr<ContextCore> context_in)
        : context(std::move(context_in)) {}

    std::shared_ptr<ContextCore> context;
    DinoXWebrtcMediaRecorderKind kind = DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO;
    std::string output_path;
    std::string mime_type;
    std::string video_device_unique_id;
    bool include_audio_track = false;
    int width = 0;
    int height = 0;
    int max_fps = 0;
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    void* user_data = nullptr;
    DinoXWebrtcMediaRecorderState state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE;
    uint64_t audio_frame_id = 0;
    uint64_t video_frame_id = 0;
    std::shared_ptr<AudioCaptureSink> audio_capture_sink;
    bool audio_capture_started = false;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> video_capture_module;
    std::unique_ptr<VideoCaptureSink> video_capture_sink;
    bool video_capture_started = false;
    bool closed = false;
    std::recursive_mutex operation_mutex;
    std::recursive_mutex callback_mutex;
    std::mutex mutex;
};

bool copy_session_callbacks(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcCallbacks* out_callbacks,
    void** out_user_data,
    std::unique_lock<std::recursive_mutex>* out_callback_lock) {
    if (core == nullptr || out_callbacks == nullptr || out_user_data == nullptr ||
            out_callback_lock == nullptr) {
        return false;
    }

    *out_callback_lock = std::unique_lock<std::recursive_mutex>(core->callback_mutex);
    std::lock_guard<std::mutex> lock(core->mutex);
    if (core->closed) {
        return false;
    }
    *out_callbacks = core->callbacks;
    *out_user_data = core->user_data;
    return true;
}

bool publish_outgoing_video_frame(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    const webrtc::scoped_refptr<SyntheticVideoTrackSource>& preferred_source,
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    bool publish_preview,
    bool privacy_proven = false,
    const dinox::webrtc_effects::FrameIdentity* identity = nullptr,
    const VideoPipelineCore* expected_pipeline = nullptr) {
    if (core == nullptr || session == nullptr || frame_id == 0) return false;

    DinoXWebrtcCallbacks callbacks = {};
    void* user_data = nullptr;
    std::unique_lock<std::recursive_mutex> callback_lock;
    if (!copy_session_callbacks(core, &callbacks, &user_data, &callback_lock)) {
        return false;
    }
    {
        // A camera callback may have sampled an unbound session before attach
        // acquired this gate. Never let that old direct route bypass the newly
        // installed pipeline. Attach uses the same callback gate.
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->local_video_effect_pipeline.lock().get() != expected_pipeline)
            return true; // consumed stale frame, never a source push
    }
    // Waiting for another callback can outlive a valid mask. Check its age at
    // the final publication point, after acquiring the callback gate; opaque
    // concealment has no mask age and remains safe.
    if (core->local_video_privacy_required.load(std::memory_order_acquire) &&
            (!privacy_proven || !identity || !frame_privacy_proof_fresh(*identity)))
        return true; // consumed by privacy drop, never a source push
    webrtc::scoped_refptr<SyntheticVideoTrackSource> source = preferred_source;
    if (source == nullptr) {
        std::lock_guard<std::mutex> lock(core->mutex);
        source = core->local_video_source;
    }
    if (source == nullptr || !source->push_frame(frame)) return false;
    if (publish_preview && callbacks.on_local_video_frame != nullptr) {
        emit_video_frame_callback(
            callbacks.on_local_video_frame, session, frame, frame_id, 0, user_data);
    }
    return true;
}

bool publish_video_pipeline_frame_locked(
    const std::shared_ptr<VideoPipelineCore>& core,
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    bool privacy_proven = false,
    const dinox::webrtc_effects::FrameIdentity* identity = nullptr) {
    if (core == nullptr || frame_id == 0) return false;

    std::vector<VideoPipelineAttachment> attachments;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed) return false;
        if (core->config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE &&
                !privacy_proven) return true; // valid bounded drop, not a camera error
        prune_video_pipeline_attachments_locked(core.get());
        attachments.reserve(core->attachments.size());
        for (const auto& item : core->attachments) {
            attachments.push_back(item.second);
        }
    }

    bool published = false;
    for (const VideoPipelineAttachment& attachment : attachments) {
        std::shared_ptr<SessionCore> session = attachment.session.lock();
        if (session == nullptr || attachment.public_session == nullptr) continue;
        DinoXWebrtcSession* public_session = nullptr;
        bool preview_publisher = false;
        {
            // A preview callback may synchronously close another session or
            // free the whole pipeline. Revalidate the raw ABI pointer before
            // every publication instead of trusting the earlier snapshot.
            std::lock_guard<std::mutex> lock(core->mutex);
            if (core->closed || (core->config.background_mode !=
                    DINOX_WEBRTC_VIDEO_BACKGROUND_NONE && !privacy_proven)) break;
            if (identity && (core->camera_lease != identity->camera_lease ||
                    core->source_epoch != identity->binding.source_generation ||
                    core->transform_epoch != identity->binding.transform_id ||
                    core->accepted_revision != identity->binding.config_revision)) break;
            if (core->config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE &&
                    (!identity || !frame_privacy_proof_fresh(*identity))) break;
            const auto current = core->attachments.find(session.get());
            if (current == core->attachments.end() ||
                    current->second.publication_token !=
                        attachment.publication_token ||
                    current->second.public_session != attachment.public_session) {
                continue;
            }
            public_session = current->second.public_session;
            preview_publisher = current->second.preview_publisher;
        }
        published = publish_outgoing_video_frame(
                session,
                public_session,
                nullptr,
                frame,
                frame_id,
                preview_publisher,
                privacy_proven,
                identity,
                core.get()) || published;
    }
    return published;
}

void apply_video_effect_processor_state(
    const std::weak_ptr<VideoPipelineCore>& weak_core,
    uint64_t revision,
    DinoXWebrtcVideoEffectType effect_type) {
    std::shared_ptr<VideoPipelineCore> core = weak_core.lock();
    if (core == nullptr) return;

    std::lock_guard<std::recursive_mutex> callback_lock(core->callback_mutex);
    std::lock_guard<std::recursive_mutex> publication_lock(core->publication_mutex);
    DinoXWebrtcVideoPipelineStateCallback callback = nullptr;
    DinoXWebrtcVideoPipeline* public_pipeline = nullptr;
    void* user_data = nullptr;
    DinoXWebrtcVideoPipelineState state = {};
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed || revision == 0 || core->accepted_revision != revision ||
                core->config.effect_type != effect_type) {
            return;
        }
        core->applied_revision = revision;
        core->application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED;
        set_video_pipeline_sessions_active_locked(
            core.get(), is_enabled_video_effect(core->config));
        state = video_pipeline_state_locked(core.get());
        callback = core->callbacks.on_state_changed;
        public_pipeline = core->public_pipeline;
        user_data = core->user_data;
    }
    if (callback != nullptr && public_pipeline != nullptr) {
        callback(public_pipeline, &state, user_data);
    }
}

void degrade_video_effect_pipeline(
    const std::weak_ptr<VideoPipelineCore>& weak_core,
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    uint64_t revision,
    uint64_t source_id,
    const dinox::webrtc_effects::FrameIdentity& identity) {
    std::shared_ptr<VideoPipelineCore> core = weak_core.lock();
    if (core == nullptr) return;

    std::lock_guard<std::recursive_mutex> callback_lock(core->callback_mutex);
    std::lock_guard<std::recursive_mutex> publication_lock(core->publication_mutex);
    DinoXWebrtcVideoPipelineStateCallback callback = nullptr;
    DinoXWebrtcVideoPipeline* public_pipeline = nullptr;
    void* user_data = nullptr;
    DinoXWebrtcVideoPipelineState state = {};
    bool source_binding_current = false;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed || revision == 0 || core->accepted_revision != revision ||
                core->applied_revision != revision ||
                !is_enabled_video_effect(core->config) ||
                core->application_state != DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED) {
            return;
        }
        prune_video_pipeline_attachments_locked(core.get());
        for (const auto& item : core->attachments) {
            if (item.second.publication_token == source_id &&
                    item.second.preview_publisher) {
                source_binding_current = true;
                break;
            }
        }
        // A processor stall belongs to this pipeline revision, not to the
        // publisher binding which happened to start the transform. Publisher
        // handover may invalidate source_id while the processor is blocked;
        // the pipeline must still open its direct path. Only publishing the
        // concrete bypass frame remains guarded by the current binding below.
        core->application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_DEGRADED;
        set_video_pipeline_sessions_active_locked(core.get(), false);
        state = video_pipeline_state_locked(core.get());
        callback = core->callbacks.on_state_changed;
        public_pipeline = core->public_pipeline;
        user_data = core->user_data;
    }

    // Every raw exit passes the final privacy gate. Selected backgrounds keep
    // their latch across this DEGRADED transition, so this frame is dropped;
    // legacy colour-only effects keep their historical direct fallback.
    // The frame that crossed the watchdog deadline is released through the
    // historical direct path only after the circuit breaker is visible. All
    // subsequent capture callbacks observe the atomic inactive flag first.
    if (source_binding_current) {
        publish_video_pipeline_frame_locked(core, frame, frame_id, false, &identity);
    }
    if (callback != nullptr && public_pipeline != nullptr) {
        callback(public_pipeline, &state, user_data);
    }
}

void publish_processed_pipeline_frame(
    const std::weak_ptr<VideoPipelineCore>& weak_core,
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    uint64_t revision,
    uint64_t source_id,
    const dinox::webrtc_effects::FrameIdentity& identity) {
    std::shared_ptr<VideoPipelineCore> core = weak_core.lock();
    if (core == nullptr) return;

    std::lock_guard<std::recursive_mutex> publication_lock(core->publication_mutex);
    bool source_binding_current = false;
    bool privacy_proven = false;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed || core->application_state !=
                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED ||
                core->accepted_revision != revision || core->applied_revision != revision ||
                !is_enabled_video_effect(core->config) ||
                core->camera_lease != identity.camera_lease ||
                core->source_epoch != identity.binding.source_generation ||
                core->transform_epoch != identity.binding.transform_id) {
            return;
        }
        privacy_proven = core->config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE;
        prune_video_pipeline_attachments_locked(core.get());
        for (const auto& item : core->attachments) {
            if (item.second.publication_token == source_id &&
                    item.second.preview_publisher) {
                source_binding_current = true;
                break;
            }
        }
    }
    if (source_binding_current) {
        publish_video_pipeline_frame_locked(core, frame, frame_id, privacy_proven, &identity);
    }
}

std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor>
ensure_video_effect_processor(const std::shared_ptr<VideoPipelineCore>& core) {
    if (core == nullptr) return nullptr;
    std::lock_guard<std::mutex> lock(core->mutex);
    if (core->closed) return nullptr;
    if (core->processor == nullptr) {
        std::weak_ptr<VideoPipelineCore> weak_core = core;
        core->processor = std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
            dinox::webrtc_effects::VideoEffectProcessor::OutputCallback{},
            [weak_core](uint64_t revision, DinoXWebrtcVideoEffectType effect_type) {
                std::shared_ptr<VideoPipelineCore> strong_core = weak_core.lock();
                if (strong_core == nullptr || strong_core->context == nullptr ||
                        strong_core->context->signaling_thread == nullptr) {
                    return;
                }
                strong_core->context->signaling_thread->PostTask(
                    [weak_core, revision, effect_type] {
                        apply_video_effect_processor_state(
                            weak_core, revision, effect_type);
                    });
            },
            video_effect_test_block_us(),
            dinox::webrtc_effects::VideoEffectProcessor::DegradedCallback{}, core->video_runtime,
            [weak_core](const webrtc::VideoFrame& frame, uint64_t frame_id,
                        uint64_t revision, uint64_t source_id,
                        const dinox::webrtc_effects::FrameIdentity& identity) {
                publish_processed_pipeline_frame(
                    weak_core, frame, frame_id, revision, source_id, identity);
            },
            [weak_core](const webrtc::VideoFrame& frame, uint64_t frame_id,
                        uint64_t revision, uint64_t source_id,
                        const dinox::webrtc_effects::FrameIdentity& identity) {
                degrade_video_effect_pipeline(
                    weak_core, frame, frame_id, revision, source_id, identity);
            });
    }
    return core->processor;
}

bool route_outgoing_video_frame(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    const webrtc::scoped_refptr<SyntheticVideoTrackSource>& source,
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    uint64_t camera_lease) {
    if (core == nullptr || session == nullptr || source == nullptr || frame_id == 0 ||
            frame.width() <= 0 || frame.height() <= 0) {
        return false;
    }
    const bool physical_camera = camera_lease != 0;
    std::shared_ptr<VideoPipelineCore> pipeline;
    const uint64_t captured_ns = dinox::vision::VisionClient::monotonic_now_ns();
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed) return false;
        const uint64_t active_camera = core->local_video_camera_lease.load(std::memory_order_acquire);
        if (camera_lease ? camera_lease != active_camera : active_camera != 0) return true;
        if (camera_lease == 0) camera_lease = core->synthetic_camera_lease;
        pipeline = core->local_video_effect_pipeline.lock();
    }
    if (pipeline == nullptr) {
        core->local_video_effect_active.store(false, std::memory_order_relaxed);
        return publish_outgoing_video_frame(core, session, source, frame, frame_id, true);
    }
    std::unique_lock<std::recursive_mutex> publication_lock(
        pipeline->publication_mutex);
    std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor> stalled_processor;
    uint64_t stalled_revision = 0;
    uint64_t publication_token = 0;
    dinox::webrtc_effects::FrameIdentity identity;
    {
        std::lock_guard<std::mutex> lock(pipeline->mutex);
        if (pipeline->closed) {
            core->local_video_effect_active.store(false, std::memory_order_relaxed);
            return publish_outgoing_video_frame(core, session, source, frame, frame_id, true);
        }
        // Stop/Start may have won while this callback waited for publication.
        // An immutable old sink may never resurrect the newly invalidated epoch.
        const uint64_t active_camera = core->local_video_camera_lease.load(std::memory_order_acquire);
        if (physical_camera ? active_camera != camera_lease : active_camera != 0) return true;
        prune_video_pipeline_attachments_locked(pipeline.get());
        const auto source_attachment = pipeline->attachments.find(core.get());
        if (source_attachment == pipeline->attachments.end() ||
                source_attachment->second.public_session != session ||
                !source_attachment->second.preview_publisher ||
                source_attachment->second.publication_token == 0) {
            return false;
        }
        publication_token = source_attachment->second.publication_token;
        const bool source_full=frame.color_space()&&frame.color_space()->range()==webrtc::ColorSpace::RangeID::kFull;
        const bool source_bt709=frame.color_space()&&frame.color_space()->matrix()==webrtc::ColorSpace::MatrixID::kBT709;
        if (pipeline->camera_lease != camera_lease) {
            if (pipeline->source_epoch == UINT64_MAX || pipeline->transform_epoch == UINT64_MAX) return true;
            ++pipeline->source_epoch; ++pipeline->transform_epoch;
            pipeline->camera_lease = camera_lease;
            pipeline->source_width = pipeline->source_height = 0;
        }
        if (pipeline->source_width != frame.width() || pipeline->source_height != frame.height() ||
                pipeline->source_rotation != static_cast<int>(frame.rotation()) ||
                pipeline->source_full_range!=source_full || pipeline->source_bt709!=source_bt709) {
            if (pipeline->transform_epoch == UINT64_MAX) return true;
            ++pipeline->transform_epoch;
            pipeline->source_width = frame.width(); pipeline->source_height = frame.height();
            pipeline->source_rotation = static_cast<int>(frame.rotation());
            pipeline->source_full_range=source_full;pipeline->source_bt709=source_bt709;
        }
        identity.camera_lease = camera_lease;
        identity.binding = {pipeline->pipeline_id, pipeline->source_epoch, publication_token,
            pipeline->accepted_revision, pipeline->transform_epoch,
            dinox::webrtc_effects::vision_demand(pipeline->config)};
        identity.frame.frame_id = frame_id;
        identity.frame.media_timestamp_ns = frame.timestamp_us() >= 0 ?
            static_cast<uint64_t>(frame.timestamp_us()) * 1000 : 0;
        identity.frame.captured_monotonic_ns = captured_ns;
        identity.frame.width = static_cast<uint32_t>(frame.width());
        identity.frame.height = static_cast<uint32_t>(frame.height());
        identity.frame.rotation = static_cast<uint32_t>(frame.rotation());
        const bool quarter_turn=frame.rotation()==webrtc::kVideoRotation_90||frame.rotation()==webrtc::kVideoRotation_270;
        const int vision_width=quarter_turn?frame.height():frame.width();
        const int vision_height=quarter_turn?frame.width():frame.height();
        identity.frame.segment_content = dinox::webrtc_effects::video_letterbox(vision_width, vision_height, 256, 144);
        identity.frame.face_content = dinox::webrtc_effects::video_letterbox(vision_width, vision_height, 128, 128);
        identity.full_range=source_full;identity.bt709=source_bt709;
        pipeline->frame_identity = identity;
        pipeline->video_runtime->bind(identity);
        if (core->local_video_effect_active.load(std::memory_order_acquire) &&
                pipeline->application_state ==
                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
                is_enabled_video_effect(pipeline->config) &&
                pipeline->accepted_revision == pipeline->applied_revision &&
                pipeline->processor != nullptr) {
            stalled_processor = pipeline->processor;
            stalled_revision = pipeline->applied_revision;
        }
    }
    if (!core->local_video_effect_active.load(std::memory_order_acquire)) {
        return publish_video_pipeline_frame_locked(pipeline, frame, frame_id);
    }
    // The processor serializes watchdog transitions and output callbacks with
    // its configure mutex. Those callbacks enter the publication gate, so the
    // capture path must never wait for the configure mutex while holding that
    // gate. A role/config transition may run while it is open; revalidate the
    // complete publisher binding before enqueueing or publishing below.
    publication_lock.unlock();
    if (stalled_processor != nullptr && stalled_processor->degrade_if_stalled(
            frame, frame_id, stalled_revision, publication_token, identity)) {
        return true;
    }
    publication_lock.lock();
    {
        std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor> processor;
        uint64_t revision = 0;
        bool publish_direct = false;
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            if (pipeline->closed) {
                // Pipeline teardown won the open-gate race. Consume this stale
                // frame; the next frame observes the cleared session binding.
                return true;
            }
            const uint64_t active_camera = core->local_video_camera_lease.load(std::memory_order_acquire);
            if (physical_camera ? active_camera != camera_lease : active_camera != 0) return true;
            prune_video_pipeline_attachments_locked(pipeline.get());
            const auto current = pipeline->attachments.find(core.get());
            if (current == pipeline->attachments.end() ||
                    current->second.public_session != session ||
                    !current->second.preview_publisher ||
                    current->second.publication_token != publication_token ||
                    pipeline->camera_lease != camera_lease ||
                    pipeline->source_epoch != identity.binding.source_generation ||
                    pipeline->transform_epoch != identity.binding.transform_id) {
                return true;
            }
            publish_direct = !core->local_video_effect_active.load(
                std::memory_order_acquire);
            if (!publish_direct && pipeline->application_state ==
                    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
                    is_enabled_video_effect(pipeline->config) &&
                    pipeline->accepted_revision == pipeline->applied_revision) {
                processor = pipeline->processor;
                revision = pipeline->applied_revision;
            }
        }
        if (publish_direct) {
            return publish_video_pipeline_frame_locked(pipeline, frame, frame_id);
        }
        if (processor != nullptr && processor->enqueue(
                frame, frame_id, revision, publication_token, identity)) {
            return true;
        }
    }
    // A concurrent Off/Detach/Degraded transition has already disabled the
    // effect and may send this frame directly. If the effect is still active,
    // fail closed: an enqueue/pool race must never leak one colour frame.
    if (!core->local_video_effect_active.load(std::memory_order_acquire)) {
        return publish_video_pipeline_frame_locked(pipeline, frame, frame_id);
    }
    return true;
}

webrtc::scoped_refptr<webrtc::PeerConnectionInterface> get_peer_connection(
    const std::shared_ptr<SessionCore>& core) {
    if (core == nullptr) {
        return nullptr;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    if (core->closed) {
        return nullptr;
    }
    return core->peer_connection;
}

std::string negotiated_header_extensions_to_log(
        const std::vector<webrtc::RtpExtension>& extensions) {
    if (extensions.empty()) {
        return "-";
    }

    std::ostringstream output;
    bool first = true;
    for (const webrtc::RtpExtension& extension : extensions) {
        if (!first) {
            output << ',';
        }
        first = false;
        output << extension.id.value() << ':' << extension.uri;
        if (extension.encrypt) {
            output << ":encrypted";
        }
    }
    return output.str();
}

std::string negotiated_header_extensions_to_log(
        const std::vector<webrtc::RtpHeaderExtensionCapability>& extensions) {
    if (extensions.empty()) {
        return "-";
    }

    std::ostringstream output;
    bool first = true;
    for (const auto& extension : extensions) {
        if (!first) output << ',';
        first = false;
        if (extension.preferred_id.has_value()) {
            output << extension.preferred_id->value();
        } else {
            output << '?';
        }
        output << ':' << extension.uri;
        if (extension.preferred_encrypt) output << ":encrypted";
        switch (extension.direction) {
            case webrtc::RtpTransceiverDirection::kSendRecv:
                output << "/sendrecv";
                break;
            case webrtc::RtpTransceiverDirection::kSendOnly:
                output << "/sendonly";
                break;
            case webrtc::RtpTransceiverDirection::kRecvOnly:
                output << "/recvonly";
                break;
            case webrtc::RtpTransceiverDirection::kInactive:
                output << "/inactive";
                break;
            case webrtc::RtpTransceiverDirection::kStopped:
                output << "/stopped";
                break;
        }
    }
    return output.str();
}

void log_negotiated_header_extensions(
        const std::shared_ptr<SessionCore>& core,
        const char* phase) {
    if (!call_debug_enabled() || phase == nullptr) {
        return;
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(core);
    if (peer_connection == nullptr) {
        return;
    }

    int transceiver_index = 0;
    for (const auto& transceiver : peer_connection->GetTransceivers()) {
        if (transceiver == nullptr) {
            continue;
        }
        const char* media = "other";
        if (transceiver->media_type() == webrtc::MediaType::AUDIO) {
            media = "audio";
        } else if (transceiver->media_type() == webrtc::MediaType::VIDEO) {
            media = "video";
        }

        // Receiver GetParameters() may omit extensions for unsignaled receivers.
        // The transceiver reports negotiated IDs independently; stopped entries
        // are unsupported, and its direction is not a wire-direction check.
        const std::string negotiated_extensions = negotiated_header_extensions_to_log(
            transceiver->GetNegotiatedHeaderExtensions());
        std::string sender_extensions = "-";
        if (transceiver->sender() != nullptr) {
            sender_extensions = negotiated_header_extensions_to_log(
                transceiver->sender()->GetParameters().header_extensions);
        }
        std::string receiver_extensions = "-";
        if (transceiver->receiver() != nullptr) {
            receiver_extensions = negotiated_header_extensions_to_log(
                transceiver->receiver()->GetParameters().header_extensions);
        }

        std::fprintf(
            stderr,
            "DinoX WebRTC negotiated header extensions: phase=%s transceiver=%d "
            "media=%s negotiated=[%s] sender-parameters=[%s] receiver-parameters=[%s]\n",
            phase,
            transceiver_index,
            media,
            negotiated_extensions.c_str(),
            sender_extensions.c_str(),
            receiver_extensions.c_str());
        ++transceiver_index;
    }
}

void copy_local_audio_state(
    const std::shared_ptr<SessionCore>& core,
    webrtc::scoped_refptr<webrtc::AudioSourceInterface>* out_source,
    webrtc::scoped_refptr<webrtc::AudioTrackInterface>* out_track) {
    if (core == nullptr || out_source == nullptr || out_track == nullptr) {
        return;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    *out_source = core->local_audio_source;
    *out_track = core->local_audio_track;
}

void copy_local_video_state(
    const std::shared_ptr<SessionCore>& core,
    webrtc::scoped_refptr<SyntheticVideoTrackSource>* out_source,
    webrtc::scoped_refptr<webrtc::VideoTrackInterface>* out_track) {
    if (core == nullptr || out_source == nullptr || out_track == nullptr) {
        return;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    *out_source = core->local_video_source;
    *out_track = core->local_video_track;
}

void take_local_video_capture(
    const std::shared_ptr<SessionCore>& core,
    webrtc::scoped_refptr<webrtc::VideoCaptureModule>* out_capture_module,
    std::unique_ptr<LocalVideoCaptureSink>* out_capture_sink) {
    if (core == nullptr || out_capture_module == nullptr || out_capture_sink == nullptr) {
        return;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    *out_capture_module = core->local_video_capture_module;
    core->local_video_capture_module = nullptr;
    *out_capture_sink = std::move(core->local_video_capture_sink);
}

void stop_video_capture_module(webrtc::VideoCaptureModule* capture_module) {
    if (capture_module == nullptr) {
        return;
    }
    if (capture_module->CaptureStarted()) {
        capture_module->StopCapture();
    }
    capture_module->DeRegisterCaptureDataCallback();
}

bool direction_receives(webrtc::RtpTransceiverDirection direction);
void attach_remote_track_sink(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    webrtc::scoped_refptr<webrtc::RtpTransceiverInterface> transceiver);
void snapshot_remote_audio_sink_state(
    const std::shared_ptr<SessionCore>& core,
    int* out_sink_count,
    uint64_t* out_frame_count,
    uint64_t* out_sample_count,
    double* out_peak_level);
void snapshot_remote_video_sink_state(
    const std::shared_ptr<SessionCore>& core,
    int* out_sink_count,
    uint64_t* out_frame_count,
    int* out_last_width,
    int* out_last_height);

void emit_session_error(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    DinoXWebrtcStatus status,
    const char* message) {
    DinoXWebrtcCallbacks callbacks = {};
    void* user_data = nullptr;
    std::unique_lock<std::recursive_mutex> callback_lock;
    if (!copy_session_callbacks(core, &callbacks, &user_data, &callback_lock) || callbacks.on_error == nullptr) {
        return;
    }
    callbacks.on_error(session, status, message, user_data);
}

void emit_local_description(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    const std::string& sdp) {
    DinoXWebrtcCallbacks callbacks = {};
    void* user_data = nullptr;
    std::unique_lock<std::recursive_mutex> callback_lock;
    if (!copy_session_callbacks(core, &callbacks, &user_data, &callback_lock) || callbacks.on_local_description == nullptr) {
        return;
    }
    callbacks.on_local_description(session, type, sdp.c_str(), user_data);
}

void emit_local_description_prepared(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    const std::string& sdp) {
    DinoXWebrtcCallbacks callbacks = {};
    void* user_data = nullptr;
    std::unique_lock<std::recursive_mutex> callback_lock;
    if (!copy_session_callbacks(core, &callbacks, &user_data, &callback_lock) ||
            callbacks.on_local_description_prepared == nullptr) return;
    callbacks.on_local_description_prepared(session, type, sdp.c_str(), user_data);
}

void reset_local_description_phase(const std::shared_ptr<SessionCore>& core) {
    std::lock_guard<std::mutex> lock(core->mutex);
    core->local_description_phase = 0;
}

void emit_remote_description_set(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type) {
    DinoXWebrtcCallbacks callbacks = {};
    void* user_data = nullptr;
    std::unique_lock<std::recursive_mutex> callback_lock;
    if (!copy_session_callbacks(core, &callbacks, &user_data, &callback_lock) || callbacks.on_remote_description_set == nullptr) {
        return;
    }
    callbacks.on_remote_description_set(session, type, user_data);
}

class SetLocalDescriptionObserver : public webrtc::SetSessionDescriptionObserver {
 public:
    SetLocalDescriptionObserver(
        std::shared_ptr<SessionCore> core,
        DinoXWebrtcSession* session,
        DinoXWebrtcSdpType type,
        std::string sdp,
        bool read_committed_description = false)
        : core_(std::move(core)), session_(session), type_(type), sdp_(std::move(sdp)),
          read_committed_description_(read_committed_description) {}

    void OnSuccess() override {
        reset_local_description_phase(core_);
        log_negotiated_header_extensions(core_, "local-description-set");
        if (read_committed_description_) {
            auto peer_connection = get_peer_connection(core_);
            if (peer_connection == nullptr) return;
            const auto* committed = peer_connection->local_description();
            if (committed == nullptr || from_webrtc_sdp_type(committed->GetType()) != type_) {
                emit_session_error(core_, session_, DINOX_WEBRTC_STATUS_INTERNAL_ERROR,
                    "native conference description was not committed");
                return;
            }
            sdp_ = committed->ToString();
        }
        emit_local_description(core_, session_, type_, sdp_);
    }

    void OnFailure(webrtc::RTCError error) override {
        reset_local_description_phase(core_);
        emit_session_error(core_, session_, DINOX_WEBRTC_STATUS_INTERNAL_ERROR, error.message());
    }

 protected:
    ~SetLocalDescriptionObserver() override = default;

 private:
    std::shared_ptr<SessionCore> core_;
    DinoXWebrtcSession* session_;
    DinoXWebrtcSdpType type_;
    std::string sdp_;
    bool read_committed_description_;
};

class SetRemoteDescriptionObserver : public webrtc::SetSessionDescriptionObserver {
 public:
    SetRemoteDescriptionObserver(
        std::shared_ptr<SessionCore> core,
        DinoXWebrtcSession* session,
        DinoXWebrtcSdpType type)
        : core_(std::move(core)), session_(session), type_(type) {}

    void OnSuccess() override {
        log_negotiated_header_extensions(core_, "remote-description-set");
        emit_remote_description_set(core_, session_, type_);
    }

    void OnFailure(webrtc::RTCError error) override {
        emit_session_error(core_, session_, DINOX_WEBRTC_STATUS_INTERNAL_ERROR, error.message());
    }

 protected:
    ~SetRemoteDescriptionObserver() override = default;

 private:
    std::shared_ptr<SessionCore> core_;
    DinoXWebrtcSession* session_;
    DinoXWebrtcSdpType type_;
};

class CreateDescriptionObserver : public webrtc::CreateSessionDescriptionObserver {
 public:
    CreateDescriptionObserver(std::shared_ptr<SessionCore> core, DinoXWebrtcSession* session,
                              bool prepare_only)
        : core_(std::move(core)), session_(session), prepare_only_(prepare_only) {}

    void OnSuccess(webrtc::SessionDescriptionInterface* description) override {
        std::unique_ptr<webrtc::SessionDescriptionInterface> owned_description(description);
        if (owned_description == nullptr) {
            reset_local_description_phase(core_);
            emit_session_error(core_, session_, DINOX_WEBRTC_STATUS_INTERNAL_ERROR, "libwebrtc returned an empty session description");
            return;
        }

        std::string sdp = owned_description->ToString();
        DinoXWebrtcSdpType type = from_webrtc_sdp_type(owned_description->GetType());
        if (prepare_only_) {
            {
                std::lock_guard<std::mutex> lock(core_->mutex);
                if (core_->closed) return;
                core_->local_description_phase = 2;
                core_->prepared_local_description_type = type;
            }
            emit_local_description_prepared(core_, session_, type, sdp);
            return;
        }
        webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection = get_peer_connection(core_);
        if (peer_connection == nullptr) {
            return;
        }

        auto observer = webrtc::make_ref_counted<SetLocalDescriptionObserver>(
            core_,
            session_,
            type,
            sdp);
        peer_connection->SetLocalDescription(observer.get(), owned_description.release());
    }

    void OnFailure(webrtc::RTCError error) override {
        reset_local_description_phase(core_);
        emit_session_error(core_, session_, DINOX_WEBRTC_STATUS_INTERNAL_ERROR, error.message());
    }

 protected:
    ~CreateDescriptionObserver() override = default;

 private:
    std::shared_ptr<SessionCore> core_;
    DinoXWebrtcSession* session_;
    bool prepare_only_;
};

class PeerObserver final : public webrtc::PeerConnectionObserver {
 public:
    PeerObserver(std::shared_ptr<SessionCore> core, DinoXWebrtcSession* session)
        : core_(std::move(core)), session_(session) {}

    void OnSignalingChange(webrtc::PeerConnectionInterface::SignalingState) override {}

    void OnDataChannel(webrtc::scoped_refptr<webrtc::DataChannelInterface>) override {}

    void OnTrack(
        webrtc::scoped_refptr<webrtc::RtpTransceiverInterface> transceiver) override {
        // Unified Plan creates the receiving track while applying the remote
        // description.  Monal can expose that receiver later than a simple
        // post-SetRemoteDescription scan, so attach the DinoX sink at the
        // lifecycle callback libwebrtc provides for exactly this event.
        attach_remote_track_sink(core_, session_, std::move(transceiver));
    }

    void OnIceGatheringChange(webrtc::PeerConnectionInterface::IceGatheringState new_state) override {
        if (new_state != webrtc::PeerConnectionInterface::kIceGatheringComplete) {
            return;
        }

        DinoXWebrtcCallbacks callbacks = {};
        void* user_data = nullptr;
        std::unique_lock<std::recursive_mutex> callback_lock;
        if (!copy_session_callbacks(core_, &callbacks, &user_data, &callback_lock) ||
            callbacks.on_ice_gathering_complete == nullptr) {
            return;
        }
        callbacks.on_ice_gathering_complete(session_, user_data);
    }

    void OnIceCandidate(const webrtc::IceCandidate* candidate) override {
        if (candidate == nullptr) {
            return;
        }

        DinoXWebrtcCallbacks callbacks = {};
        void* user_data = nullptr;
        std::unique_lock<std::recursive_mutex> callback_lock;
        if (!copy_session_callbacks(core_, &callbacks, &user_data, &callback_lock) ||
            callbacks.on_ice_candidate == nullptr) {
            return;
        }

        std::string candidate_sdp = candidate->ToString();
        std::string sdp_mid = candidate->sdp_mid();
        callbacks.on_ice_candidate(
            session_,
            sdp_mid.c_str(),
            candidate->sdp_mline_index(),
            candidate_sdp.c_str(),
            user_data);
    }

 private:
    std::shared_ptr<SessionCore> core_;
    DinoXWebrtcSession* session_;
};

class SessionStatsCollectorCallback : public webrtc::RTCStatsCollectorCallback {
 public:
    explicit SessionStatsCollectorCallback(std::shared_ptr<SessionCore> core)
        : core_(std::move(core)) {}

    void OnStatsDelivered(
        const webrtc::scoped_refptr<const webrtc::RTCStatsReport>& report) override {
        RtpStatsSnapshot snapshot;
        if (report != nullptr) {
            for (const webrtc::RTCStats& stats : *report) {
                if (stats.type() == webrtc::RTCInboundRtpStreamStats::kType) {
                    const auto& inbound =
                        stats.cast_to<webrtc::RTCInboundRtpStreamStats>();
                    if (inbound.kind.has_value() && inbound.kind.value() == "audio") {
                        snapshot.inbound_audio_packets_received +=
                            inbound.packets_received.value_or(0);
                        snapshot.inbound_audio_bytes_received +=
                            inbound.bytes_received.value_or(0);
                        snapshot.inbound_audio_total_samples_received +=
                            inbound.total_samples_received.value_or(0);
                        if (inbound.audio_level.has_value()) {
                            snapshot.inbound_audio_level = inbound.audio_level.value();
                        }
                    } else if (inbound.kind.has_value() && inbound.kind.value() == "video") {
                        snapshot.inbound_video_packets_received +=
                            inbound.packets_received.value_or(0);
                        snapshot.inbound_video_packets_lost +=
                            inbound.packets_lost.value_or(0);
                        snapshot.inbound_video_bytes_received +=
                            inbound.bytes_received.value_or(0);
                        snapshot.inbound_video_frames_received +=
                            inbound.frames_received.value_or(0);
                        snapshot.inbound_video_frames_decoded +=
                            inbound.frames_decoded.value_or(0);
                        snapshot.inbound_video_key_frames_decoded +=
                            inbound.key_frames_decoded.value_or(0);
                        snapshot.inbound_video_frames_dropped +=
                            inbound.frames_dropped.value_or(0);
                        snapshot.inbound_video_frames_per_second = std::max(
                            snapshot.inbound_video_frames_per_second,
                            inbound.frames_per_second.value_or(0.0));
                        snapshot.inbound_video_jitter = std::max(
                            snapshot.inbound_video_jitter,
                            inbound.jitter.value_or(0.0));
                        snapshot.inbound_video_jitter_buffer_delay +=
                            inbound.jitter_buffer_delay.value_or(0.0);
                        snapshot.inbound_video_jitter_buffer_target_delay +=
                            inbound.jitter_buffer_target_delay.value_or(0.0);
                        snapshot.inbound_video_jitter_buffer_minimum_delay +=
                            inbound.jitter_buffer_minimum_delay.value_or(0.0);
                        snapshot.inbound_video_jitter_buffer_emitted_count +=
                            inbound.jitter_buffer_emitted_count.value_or(0);
                        snapshot.inbound_video_total_decode_time +=
                            inbound.total_decode_time.value_or(0.0);
                        snapshot.inbound_video_total_processing_delay +=
                            inbound.total_processing_delay.value_or(0.0);
                        snapshot.inbound_video_freeze_count +=
                            inbound.freeze_count.value_or(0);
                        snapshot.inbound_video_total_freezes_duration +=
                            inbound.total_freezes_duration.value_or(0.0);
                        snapshot.inbound_video_pli_count +=
                            inbound.pli_count.value_or(0);
                        snapshot.inbound_video_fir_count +=
                            inbound.fir_count.value_or(0);
                        snapshot.inbound_video_nack_count +=
                            inbound.nack_count.value_or(0);
                        if (inbound.decoder_implementation.has_value()) {
                            snapshot.inbound_video_decoder_implementation =
                                inbound.decoder_implementation.value();
                        }
                        if (snapshot.inbound_video_transport_id.empty() &&
                                inbound.transport_id.has_value()) {
                            snapshot.inbound_video_transport_id =
                                inbound.transport_id.value();
                        }
                        if (inbound.frame_width.has_value()) {
                            snapshot.inbound_video_frame_width =
                                static_cast<int>(inbound.frame_width.value());
                        }
                        if (inbound.frame_height.has_value()) {
                            snapshot.inbound_video_frame_height =
                                static_cast<int>(inbound.frame_height.value());
                        }
                    }
                    continue;
                }

                if (stats.type() == webrtc::RTCOutboundRtpStreamStats::kType) {
                    const auto& outbound =
                        stats.cast_to<webrtc::RTCOutboundRtpStreamStats>();
                    if (outbound.kind.has_value() && outbound.kind.value() == "audio") {
                        snapshot.outbound_audio_packets_sent +=
                            outbound.packets_sent.value_or(0);
                        snapshot.outbound_audio_bytes_sent +=
                            outbound.bytes_sent.value_or(0);
                        if (outbound.target_bitrate.has_value()) {
                            snapshot.outbound_audio_target_bitrate = outbound.target_bitrate.value();
                        }
                    } else if (outbound.kind.has_value() && outbound.kind.value() == "video") {
                        snapshot.outbound_video_packets_sent +=
                            outbound.packets_sent.value_or(0);
                        snapshot.outbound_video_bytes_sent +=
                            outbound.bytes_sent.value_or(0);
                        snapshot.outbound_video_frames_sent +=
                            outbound.frames_sent.value_or(0);
                        snapshot.outbound_video_frames_encoded +=
                            outbound.frames_encoded.value_or(0);
                        if (outbound.target_bitrate.has_value()) {
                            snapshot.outbound_video_target_bitrate =
                                outbound.target_bitrate.value();
                        }
                        if (outbound.frame_width.has_value()) {
                            snapshot.outbound_video_frame_width =
                                static_cast<int>(outbound.frame_width.value());
                        }
                        if (outbound.frame_height.has_value()) {
                            snapshot.outbound_video_frame_height =
                                static_cast<int>(outbound.frame_height.value());
                        }
                    }
                    continue;
                }

                if (stats.type() == webrtc::RTCAudioSourceStats::kType) {
                    const auto& source =
                        stats.cast_to<webrtc::RTCAudioSourceStats>();
                    if (source.audio_level.has_value()) {
                        snapshot.source_audio_level = source.audio_level.value();
                    }
                    if (source.total_audio_energy.has_value()) {
                        snapshot.source_audio_total_energy = source.total_audio_energy.value();
                    }
                    if (source.total_samples_duration.has_value()) {
                        snapshot.source_audio_total_duration = source.total_samples_duration.value();
                    }
                }
            }
        }

        populate_selected_video_candidate_pair(report, &snapshot);
        snapshot.collected_at = std::chrono::steady_clock::now();
        RtpStatsSnapshot previous;
        bool stored = false;
        {
            std::lock_guard<std::mutex> lock(core_->mutex);
            previous = core_->cached_rtp_stats;
            if (!core_->closed) {
                snapshot.stats_report_count = previous.stats_report_count + 1;
                core_->cached_rtp_stats = snapshot;
                stored = true;
            }
            core_->stats_request_in_flight = false;
        }
        if (stored) {
            log_receive_startup_stats(snapshot, previous);
        }
    }

 protected:
    ~SessionStatsCollectorCallback() override = default;

 private:
    std::shared_ptr<SessionCore> core_;
};

bool validate_config(const DinoXWebrtcSessionConfig& config) {
    if (config.abi_version != DINOX_WEBRTC_ABI_VERSION) {
        return false;
    }
    if (!config.audio_enabled && !config.video_enabled) {
        return false;
    }
    if (config.network_policy != DINOX_WEBRTC_NETWORK_POLICY_AUTOMATIC &&
            config.network_policy != DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G) {
        return false;
    }
    if (config.network_policy == DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G &&
            (!config.audio_enabled || config.video_enabled ||
                (config.audio_direction != DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV &&
                    config.audio_direction != DINOX_WEBRTC_MEDIA_DIRECTION_SEND_ONLY))) {
        return false;
    }
    if (config.ice_candidate_pool_size < 0) {
        return false;
    }
    auto valid_direction = [](DinoXWebrtcMediaDirection direction) {
        return direction == DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV ||
            direction == DINOX_WEBRTC_MEDIA_DIRECTION_SEND_ONLY ||
            direction == DINOX_WEBRTC_MEDIA_DIRECTION_RECV_ONLY ||
            direction == DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    };
    if (!valid_direction(config.audio_direction) || !valid_direction(config.video_direction)) {
        return false;
    }
    return true;
}

bool valid_audio_device_mode(DinoXWebrtcAudioDeviceMode mode) {
    return mode == DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC ||
        mode == DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT;
}

bool valid_media_recorder_kind(DinoXWebrtcMediaRecorderKind kind) {
    return kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO ||
        kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO;
}

bool validate_media_recorder_config(const DinoXWebrtcMediaRecorderConfig& config) {
    if (config.abi_version != DINOX_WEBRTC_ABI_VERSION) {
        return false;
    }
    if (!valid_media_recorder_kind(config.kind)) {
        return false;
    }
    if (config.output_path == nullptr || config.output_path[0] == '\0') {
        return false;
    }
    if (config.mime_type == nullptr || config.mime_type[0] == '\0') {
        return false;
    }
    if (config.kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO &&
            (config.width <= 0 || config.height <= 0 || config.max_fps <= 0)) {
        return false;
    }
    if (config.kind != DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO &&
            ((config.video_device_unique_id != nullptr &&
              config.video_device_unique_id[0] != '\0') ||
             config.include_audio_track != 0)) {
        return false;
    }
    return true;
}

bool validate_video_effect_config(const DinoXWebrtcVideoEffectConfig& config) {
    return dinox::webrtc_effects::valid_config(config);
}

DinoXWebrtcVideoEffectCapabilities video_effect_capabilities() {
    DinoXWebrtcVideoEffectCapabilities capabilities = {};
    capabilities.abi_version = DINOX_WEBRTC_ABI_VERSION;
    capabilities.supported_effect_mask = dinox::webrtc_effects::kSupportedEffectMask;
    capabilities.supported_quality_mask = UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO;
    capabilities.max_subscribers = DINOX_WEBRTC_VIDEO_PIPELINE_MAX_SUBSCRIBERS;
    // One preview publisher owns capture for the logical call. Its raw or
    // processed frames are fanned out to every attached session source.
    capabilities.shared_pipeline_supported = 1;
    capabilities.preview_publisher_supported = 1;
    capabilities.supported_adjustment_mask = dinox::webrtc_effects::kSupportedAdjustmentMask;
    const auto paths = dinox::webrtc_effects::installed_vision_paths();
    capabilities.supported_background_mask = paths.segmentation ? UINT32_C(15) : UINT32_C(1);
    capabilities.auto_framing_supported = paths.segmentation;
    capabilities.supported_glasses_mask = paths.face ? UINT32_C(15) : UINT32_C(1);
    capabilities.supported_hat_mask = capabilities.supported_glasses_mask;
    capabilities.supported_beard_mask = capabilities.supported_glasses_mask;
    capabilities.supported_face_accessory_mask = paths.face ? UINT32_C(7) : UINT32_C(1);
    capabilities.supported_scene_effect_mask = UINT32_C(31);
    capabilities.touch_up_supported = paths.face;
    capabilities.low_light_supported = 1;
    return capabilities;
}

void prune_video_pipeline_attachments_locked(VideoPipelineCore* core) {
    for (auto iterator = core->attachments.begin(); iterator != core->attachments.end();) {
        std::shared_ptr<SessionCore> session = iterator->second.session.lock();
        if (session == nullptr && iterator->second.publication_token !=
                core->capture_owner_publication_token) {
            core->subscriber_generations.erase(iterator->second.subscriber_id);
            iterator = core->attachments.erase(iterator);
        } else {
            // A successfully locked SessionCore remains owned by the explicit
            // Close/Detach/Free path even after it is marked closed. Those paths
            // remove the attachment and, for the capture owner, move and stop
            // the module/sink in one ordered operation. Generic observation or
            // frame routing must never erase that ownership first. An expired
            // capture owner is likewise retained as a fail-safe invariant until
            // pipeline teardown can release its device resources.
            ++iterator;
        }
    }
}

DinoXWebrtcVideoPipelineState video_pipeline_state_locked(VideoPipelineCore* core) {
    prune_video_pipeline_attachments_locked(core);
    DinoXWebrtcVideoPipelineState state = {};
    state.abi_version = DINOX_WEBRTC_ABI_VERSION;
    state.application_state = core->application_state;
    state.pipeline_id = core->pipeline_id;
    state.pipeline_generation = core->pipeline_generation;
    state.logical_call_id = core->logical_call_id;
    state.accepted_revision = core->accepted_revision;
    state.applied_revision = core->applied_revision;
    state.effect_type = core->config.effect_type;
    state.quality = core->config.quality;
    state.preset_id = core->config.preset_id;
    state.asset_id = core->config.asset_id;
    state.brightness = core->config.brightness;
    state.contrast = core->config.contrast;
    state.saturation = core->config.saturation;
    state.sharpness = core->config.sharpness;
    state.background_mode = core->config.background_mode;
    state.background_strength = core->config.background_strength;
    state.background_color_rgb = core->config.background_color_rgb;
    state.framing_mode = core->config.framing_mode;
    state.glasses_style = core->config.glasses_style;
    state.hat_style = core->config.hat_style;
    state.beard_style = core->config.beard_style;
    state.face_accessory = core->config.face_accessory;
    state.touch_up = core->config.touch_up;
    state.low_light = core->config.low_light;
    state.scene_effect = core->config.scene_effect;
    state.subscriber_count = static_cast<uint32_t>(core->attachments.size());
    for (const auto& [session, attachment] : core->attachments) {
        (void) session;
        if (attachment.preview_publisher) {
            state.preview_subscriber_id = attachment.subscriber_id;
            state.preview_subscriber_generation = attachment.subscriber_generation;
            break;
        }
    }
    return state;
}

bool valid_incoming_flag(int incoming) {
    return incoming == 0 || incoming == 1;
}

bool direction_sends(DinoXWebrtcMediaDirection direction) {
    return direction == DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV ||
        direction == DINOX_WEBRTC_MEDIA_DIRECTION_SEND_ONLY;
}

bool normalize_dtmf_digit(char digit, char* out_digit) {
    if (out_digit == nullptr) {
        return false;
    }
    switch (digit) {
        case '0':
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
        case '8':
        case '9':
        case '*':
        case '#':
            *out_digit = digit;
            return true;
        case 'a':
        case 'b':
        case 'c':
        case 'd':
            *out_digit = static_cast<char>(std::toupper(static_cast<unsigned char>(digit)));
            return true;
        case 'A':
        case 'B':
        case 'C':
        case 'D':
            *out_digit = digit;
            return true;
        default:
            return false;
    }
}

bool ensure_audio_playout_started(const std::shared_ptr<ContextCore>& core) {
    if (core == nullptr || core->audio_device_module == nullptr) {
        device_debug("DinoX WebRTC device: event=playout-start-failed stage=missing-context\n");
        return false;
    }
    device_debug(
        "DinoX WebRTC device: event=playout-start-enter initialized=%d playout_initialized=%d playing=%d\n",
        core->audio_device_module->Initialized() ? 1 : 0,
        core->audio_device_module->PlayoutIsInitialized() ? 1 : 0,
        core->audio_device_module->Playing() ? 1 : 0);
    if (!core->audio_device_module->Initialized() &&
        core->audio_device_module->Init() != 0) {
        device_debug("DinoX WebRTC device: event=playout-start-failed stage=init-adm\n");
        return false;
    }
    if (core->measuring_audio_device_module == nullptr ||
            core->measuring_audio_device_module->ensure_audio_device_selected(1) != 0) {
        device_debug("DinoX WebRTC device: event=playout-start-failed stage=select-device\n");
        return false;
    }
    if (!core->audio_device_module->SpeakerIsInitialized() &&
        core->audio_device_module->InitSpeaker() != 0) {
        device_debug("DinoX WebRTC device: event=playout-start-failed stage=init-speaker\n");
        return false;
    }
    if (!core->audio_device_module->PlayoutIsInitialized() &&
        core->audio_device_module->InitPlayout() != 0) {
        device_debug("DinoX WebRTC device: event=playout-start-failed stage=init-playout\n");
        return false;
    }
    if (!core->audio_device_module->Playing() &&
        core->audio_device_module->StartPlayout() != 0) {
        device_debug("DinoX WebRTC device: event=playout-start-failed stage=start-playout\n");
        return false;
    }
    device_debug("DinoX WebRTC device: event=playout-start-ok\n");
    return true;
}

bool ensure_audio_device_module_initialized(const std::shared_ptr<ContextCore>& core) {
    if (core == nullptr || core->audio_device_module == nullptr) {
        return false;
    }
    if (core->audio_device_module->Initialized()) {
        return true;
    }
    return core->audio_device_module->Init() == 0;
}

bool ensure_audio_mixer_initialized(const std::shared_ptr<ContextCore>& core, int incoming) {
    if (core == nullptr || core->audio_device_module == nullptr || !valid_incoming_flag(incoming)) {
        return false;
    }
    if (!ensure_audio_device_module_initialized(core)) {
        return false;
    }
    if (core->measuring_audio_device_module == nullptr ||
            core->measuring_audio_device_module->ensure_audio_device_selected(incoming) != 0) {
        return false;
    }
    if (incoming != 0) {
        return core->audio_device_module->SpeakerIsInitialized() ||
            core->audio_device_module->InitSpeaker() == 0;
    }
    return core->audio_device_module->MicrophoneIsInitialized() ||
        core->audio_device_module->InitMicrophone() == 0;
}

bool should_stop_standalone_test_playout(
    const std::shared_ptr<ContextCore>& core,
    uint64_t generation) {
    if (core == nullptr) {
        return false;
    }

    std::lock_guard<std::mutex> lock(core->activity_mutex);
    return core->active_session_count == 0 &&
        core->test_tone_generation == generation;
}

double clamp_unit_interval(double value) {
    if (value < 0.0) {
        return 0.0;
    }
    if (value > 1.0) {
        return 1.0;
    }
    return value;
}

DinoXWebrtcStatus get_audio_device_volume_state(
    const std::shared_ptr<ContextCore>& core,
    int incoming,
    double* out_volume,
    int* out_available) {
    if (core == nullptr ||
        core->audio_device_module == nullptr ||
        !valid_incoming_flag(incoming) ||
        out_volume == nullptr ||
        out_available == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    *out_volume = 1.0;
    *out_available = 0;
    if (core->audio_device_mode == DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT) {
        // Avoid reading the Linux PulseAudio mixer state from libwebrtc's ADM.
        // Some Pulse backends abort the process from pa_operation_get_state()
        // when the sink-input info operation is unavailable. DinoX keeps the
        // UI volume state itself and only pushes explicit user changes down.
        std::lock_guard<std::mutex> lock(core->audio_volume_mutex);
        *out_volume = incoming != 0 ? core->cached_speaker_volume : core->cached_microphone_volume;
        *out_available = 1;
        return DINOX_WEBRTC_STATUS_OK;
    }

    if (!ensure_audio_mixer_initialized(core, incoming)) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    bool available = false;
    int32_t available_result = incoming != 0 ?
        core->audio_device_module->SpeakerVolumeIsAvailable(&available) :
        core->audio_device_module->MicrophoneVolumeIsAvailable(&available);
    if (available_result != 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    *out_available = available ? 1 : 0;
    if (!available) {
        return DINOX_WEBRTC_STATUS_OK;
    }

    uint32_t current = 0;
    uint32_t minimum = 0;
    uint32_t maximum = 0;
    int32_t current_result = incoming != 0 ?
        core->audio_device_module->SpeakerVolume(&current) :
        core->audio_device_module->MicrophoneVolume(&current);
    int32_t minimum_result = incoming != 0 ?
        core->audio_device_module->MinSpeakerVolume(&minimum) :
        core->audio_device_module->MinMicrophoneVolume(&minimum);
    int32_t maximum_result = incoming != 0 ?
        core->audio_device_module->MaxSpeakerVolume(&maximum) :
        core->audio_device_module->MaxMicrophoneVolume(&maximum);
    if (current_result != 0 || minimum_result != 0 || maximum_result != 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    if (maximum <= minimum) {
        *out_volume = 1.0;
        return DINOX_WEBRTC_STATUS_OK;
    }
    if (current < minimum) {
        current = minimum;
    }
    if (current > maximum) {
        current = maximum;
    }
    *out_volume = static_cast<double>(current - minimum) /
        static_cast<double>(maximum - minimum);
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus set_audio_device_volume_state(
    const std::shared_ptr<ContextCore>& core,
    int incoming,
    double volume) {
    if (core == nullptr || core->audio_device_module == nullptr || !valid_incoming_flag(incoming)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    double normalized = clamp_unit_interval(volume);
    auto cache_volume = [&] {
        std::lock_guard<std::mutex> lock(core->audio_volume_mutex);
        if (incoming != 0) {
            core->cached_speaker_volume = normalized;
        } else {
            core->cached_microphone_volume = normalized;
        }
    };
    // Keep volume local to this DinoX context. Platform mixer controls can be
    // unavailable while media is active, and Linux microphone mixer changes
    // affect other applications using the same endpoint. The existing gain
    // transport scales peer audio PCM without changing capture-router input
    // or depending on the platform's mixer initialization.
    if (core->audio_device_mode == DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT &&
            core->audio_gain_state != nullptr) {
        const uint32_t gain = static_cast<uint32_t>(
            normalized * static_cast<double>(AudioGainState::kUnity) + 0.5);
        if (incoming != 0) {
            core->audio_gain_state->speaker.store(gain, std::memory_order_relaxed);
        } else {
            core->audio_gain_state->microphone.store(gain, std::memory_order_relaxed);
        }
        cache_volume();
        return DINOX_WEBRTC_STATUS_OK;
    }
    if (!ensure_audio_mixer_initialized(core, incoming)) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    bool available = false;
    int32_t available_result = incoming != 0 ?
        core->audio_device_module->SpeakerVolumeIsAvailable(&available) :
        core->audio_device_module->MicrophoneVolumeIsAvailable(&available);
    if (available_result != 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    if (!available) {
        cache_volume();
        return DINOX_WEBRTC_STATUS_OK;
    }

    uint32_t minimum = 0;
    uint32_t maximum = 0;
    int32_t minimum_result = incoming != 0 ?
        core->audio_device_module->MinSpeakerVolume(&minimum) :
        core->audio_device_module->MinMicrophoneVolume(&minimum);
    int32_t maximum_result = incoming != 0 ?
        core->audio_device_module->MaxSpeakerVolume(&maximum) :
        core->audio_device_module->MaxMicrophoneVolume(&maximum);
    if (minimum_result != 0 || maximum_result != 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    if (maximum <= minimum) {
        cache_volume();
        return DINOX_WEBRTC_STATUS_OK;
    }

    uint32_t target = minimum + static_cast<uint32_t>(
        normalized * static_cast<double>(maximum - minimum) + 0.5);
    if (target < minimum) {
        target = minimum;
    }
    if (target > maximum) {
        target = maximum;
    }

    int32_t set_result = incoming != 0 ?
        core->audio_device_module->SetSpeakerVolume(target) :
        core->audio_device_module->SetMicrophoneVolume(target);
    if (set_result != 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    cache_volume();
    return DINOX_WEBRTC_STATUS_OK;
}

bool direction_receives(webrtc::RtpTransceiverDirection direction) {
    return direction == webrtc::RtpTransceiverDirection::kSendRecv ||
        direction == webrtc::RtpTransceiverDirection::kRecvOnly;
}

bool has_remote_audio_sink_locked(
    const SessionCore& core,
    const webrtc::AudioTrackInterface* track) {
    for (const auto& binding : core.remote_audio_sinks) {
        if (binding.track.get() == track) {
            return true;
        }
    }
    return false;
}

bool has_remote_video_sink_locked(
    const SessionCore& core,
    const webrtc::VideoTrackInterface* track) {
    for (const auto& binding : core.remote_video_sinks) {
        if (binding.track.get() == track) {
            return true;
        }
    }
    return false;
}

void attach_remote_audio_track_sink(
    const std::shared_ptr<SessionCore>& core,
    webrtc::scoped_refptr<webrtc::AudioTrackInterface> audio_track) {
    if (core == nullptr || audio_track == nullptr) return;
    bool already_attached = false;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed) return;
        already_attached = has_remote_audio_sink_locked(*core, audio_track.get());
    }
    if (already_attached) return;

    auto sink = std::make_unique<CountingAudioSink>();
    audio_track->AddSink(sink.get());

    bool stored = false;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (!core->closed &&
            !has_remote_audio_sink_locked(*core, audio_track.get())) {
            RemoteAudioSinkBinding binding;
            binding.track = audio_track;
            binding.sink = std::move(sink);
            core->remote_audio_sinks.push_back(std::move(binding));
            stored = true;
        }
    }
    if (!stored && sink != nullptr) audio_track->RemoveSink(sink.get());
}

void attach_remote_video_track_sink(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    webrtc::scoped_refptr<webrtc::VideoTrackInterface> video_track) {
    if (core == nullptr || session == nullptr || video_track == nullptr) return;
    bool already_attached = false;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed) return;
        already_attached = has_remote_video_sink_locked(*core, video_track.get());
    }
    if (already_attached) return;

    auto sink = std::make_unique<CountingVideoSink>(core, session);
    video_track->AddOrUpdateSink(sink.get(), remote_render_sink_wants());

    bool stored = false;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (!core->closed &&
            !has_remote_video_sink_locked(*core, video_track.get())) {
            RemoteVideoSinkBinding binding;
            binding.track = video_track;
            binding.sink = std::move(sink);
            core->remote_video_sinks.push_back(std::move(binding));
            stored = true;
        }
    }
    if (!stored && sink != nullptr) video_track->RemoveSink(sink.get());
}

void attach_remote_track_sink(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcSession* session,
    webrtc::scoped_refptr<webrtc::RtpTransceiverInterface> transceiver) {
    if (core == nullptr || session == nullptr || transceiver == nullptr ||
        transceiver->receiver() == nullptr) {
        return;
    }
    webrtc::scoped_refptr<webrtc::MediaStreamTrackInterface> media_track =
        transceiver->receiver()->track();
    if (media_track == nullptr) return;

    if (transceiver->media_type() == webrtc::MediaType::AUDIO &&
        media_track->kind() == webrtc::MediaStreamTrackInterface::kAudioKind) {
        attach_remote_audio_track_sink(
            core,
            webrtc::scoped_refptr<webrtc::AudioTrackInterface>(
                static_cast<webrtc::AudioTrackInterface*>(media_track.get())));
        return;
    }
    if (transceiver->media_type() == webrtc::MediaType::VIDEO &&
        media_track->kind() == webrtc::MediaStreamTrackInterface::kVideoKind) {
        attach_remote_video_track_sink(
            core,
            session,
            webrtc::scoped_refptr<webrtc::VideoTrackInterface>(
                static_cast<webrtc::VideoTrackInterface*>(media_track.get())));
    }
}

void snapshot_remote_audio_sink_state(
    const std::shared_ptr<SessionCore>& core,
    int* out_sink_count,
    uint64_t* out_frame_count,
    uint64_t* out_sample_count,
    double* out_peak_level) {
    if (out_sink_count == nullptr ||
        out_frame_count == nullptr ||
        out_sample_count == nullptr ||
        out_peak_level == nullptr) {
        return;
    }

    *out_sink_count = 0;
    *out_frame_count = 0;
    *out_sample_count = 0;
    *out_peak_level = 0.0;
    if (core == nullptr) {
        return;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    *out_sink_count = static_cast<int>(core->remote_audio_sinks.size());
    for (const auto& binding : core->remote_audio_sinks) {
        if (binding.sink == nullptr) {
            continue;
        }

        uint64_t frame_count = 0;
        uint64_t sample_count = 0;
        double peak_level = 0.0;
        binding.sink->snapshot(&frame_count, &sample_count, &peak_level);
        *out_frame_count += frame_count;
        *out_sample_count += sample_count;
        if (peak_level > *out_peak_level) {
            *out_peak_level = peak_level;
        }
    }
}

void snapshot_remote_video_sink_state(
    const std::shared_ptr<SessionCore>& core,
    int* out_sink_count,
    uint64_t* out_frame_count,
    int* out_last_width,
    int* out_last_height) {
    if (out_sink_count == nullptr ||
        out_frame_count == nullptr ||
        out_last_width == nullptr ||
        out_last_height == nullptr) {
        return;
    }

    *out_sink_count = 0;
    *out_frame_count = 0;
    *out_last_width = 0;
    *out_last_height = 0;
    if (core == nullptr) {
        return;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    *out_sink_count = static_cast<int>(core->remote_video_sinks.size());
    for (const auto& binding : core->remote_video_sinks) {
        if (binding.sink == nullptr) {
            continue;
        }

        uint64_t frame_count = 0;
        int last_width = 0;
        int last_height = 0;
        binding.sink->snapshot(&frame_count, &last_width, &last_height);
        *out_frame_count += frame_count;
        if (last_width > 0 && last_height > 0) {
            *out_last_width = last_width;
            *out_last_height = last_height;
        }
    }
}

RtpStatsSnapshot snapshot_rtp_stats(const std::shared_ptr<SessionCore>& core) {
    if (core == nullptr) {
        return {};
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    return core->cached_rtp_stats;
}

void request_rtp_stats(const std::shared_ptr<SessionCore>& core) {
    if (core == nullptr) {
        return;
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(core);
    if (peer_connection == nullptr) {
        return;
    }

    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed || core->stats_request_in_flight) {
            return;
        }
        core->stats_request_in_flight = true;
    }

    peer_connection->GetStats(
        webrtc::make_ref_counted<SessionStatsCollectorCallback>(core).get());
}

DinoXWebrtcStatus add_transceiver(
    const webrtc::scoped_refptr<webrtc::PeerConnectionInterface>& peer_connection,
    webrtc::MediaType media_type,
    DinoXWebrtcMediaDirection direction) {
    webrtc::RtpTransceiverInit init;
    init.direction = to_webrtc_direction(direction);
    auto result = peer_connection->AddTransceiver(media_type, init);
    if (!result.ok()) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus create_local_audio_track(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcMediaDirection direction) {
    if (core == nullptr || core->context == nullptr || core->context->factory == nullptr ||
        core->peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::AudioOptions audio_options;
    audio_options.echo_cancellation = true;
    audio_options.auto_gain_control = true;
    audio_options.noise_suppression = false;
    audio_options.highpass_filter = true;
    audio_options.init_recording_on_send = true;

    webrtc::scoped_refptr<webrtc::AudioSourceInterface> source =
        core->context->factory->CreateAudioSource(audio_options);
    if (source == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    webrtc::scoped_refptr<webrtc::AudioTrackInterface> track =
        core->context->factory->CreateAudioTrack("dinox-audio", source.get());
    if (track == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    if (core->closed) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    core->local_audio_source = source;
    core->local_audio_track = track;
    core->local_audio_direction = direction;
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus apply_low_bandwidth_audio_policy(
    const std::shared_ptr<SessionCore>& core) {
    if (core == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    if (core->network_policy == DINOX_WEBRTC_NETWORK_POLICY_AUTOMATIC) {
        return DINOX_WEBRTC_STATUS_OK;
    }
    if (core->network_policy != DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G ||
            core->context == nullptr || core->context->factory == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(core);
    if (peer_connection == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;

    std::vector<webrtc::RtpCodecCapability> codecs =
        core->context->factory->GetRtpSenderCapabilities(webrtc::MediaType::AUDIO).codecs;
    bool opus_found = false;
    for (auto& codec : codecs) {
        std::string name = codec.name;
        std::transform(name.begin(), name.end(), name.begin(), [](unsigned char value) {
            return static_cast<char>(std::tolower(value));
        });
        if (name != "opus") continue;
        opus_found = true;
    }
    if (!opus_found) return DINOX_WEBRTC_STATUS_NOT_READY;

    unsigned int sender_count = 0;
    for (const auto& transceiver : peer_connection->GetTransceivers()) {
        if (transceiver == nullptr || transceiver->media_type() != webrtc::MediaType::AUDIO) continue;
        webrtc::scoped_refptr<webrtc::RtpSenderInterface> sender = transceiver->sender();
        if (sender == nullptr || sender->track() == nullptr) continue;
        ++sender_count;
        webrtc::RtpParameters parameters = sender->GetParameters();
        if (parameters.encodings.empty()) return DINOX_WEBRTC_STATUS_NOT_READY;
        for (auto& encoding : parameters.encodings) {
            encoding.max_bitrate_bps = 16000;
            encoding.adaptive_ptime = true;
        }
        webrtc::RTCError parameter_error = sender->SetParameters(parameters);
        if (!parameter_error.ok()) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    if (sender_count != 1) return DINOX_WEBRTC_STATUS_NOT_READY;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        core->audio_sender_bitrate_cap_bps = 16000;
        core->audio_sender_adaptive_ptime = true;
        core->audio_sender_policy_applied = true;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus add_local_audio_transceiver(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcMediaDirection direction) {
    DinoXWebrtcStatus track_status = create_local_audio_track(core, direction);
    if (track_status != DINOX_WEBRTC_STATUS_OK) {
        return track_status;
    }

    webrtc::scoped_refptr<webrtc::AudioTrackInterface> track;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        track = core->local_audio_track;
    }
    if (track == nullptr || core == nullptr || core->peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::RtpTransceiverInit init;
    init.direction = to_webrtc_direction(direction);
    init.stream_ids.push_back("dinox");
    auto result = core->peer_connection->AddTransceiver(track, init);
    if (!result.ok()) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    return apply_low_bandwidth_audio_policy(core);
}

DinoXWebrtcStatus create_local_video_track(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcMediaDirection direction) {
    if (core == nullptr || core->context == nullptr || core->context->factory == nullptr ||
        core->peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::scoped_refptr<SyntheticVideoTrackSource> source =
        webrtc::make_ref_counted<SyntheticVideoTrackSource>();
    if (source == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    webrtc::scoped_refptr<webrtc::VideoTrackInterface> track =
        core->context->factory->CreateVideoTrack(source, "dinox-video");
    if (track == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    std::lock_guard<std::mutex> lock(core->mutex);
    if (core->closed) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    core->local_video_source = source;
    core->local_video_track = track;
    core->local_video_direction = direction;
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus add_local_video_transceiver(
    const std::shared_ptr<SessionCore>& core,
    DinoXWebrtcMediaDirection direction) {
    DinoXWebrtcStatus track_status = create_local_video_track(core, direction);
    if (track_status != DINOX_WEBRTC_STATUS_OK) {
        return track_status;
    }

    webrtc::scoped_refptr<webrtc::VideoTrackInterface> track;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        track = core->local_video_track;
    }
    if (track == nullptr || core == nullptr || core->peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::RtpTransceiverInit init;
    init.direction = to_webrtc_direction(direction);
    init.stream_ids.push_back("dinox");
    auto result = core->peer_connection->AddTransceiver(track, init);
    if (!result.ok()) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus bind_local_audio_track_to_senders(const std::shared_ptr<SessionCore>& core) {
    if (core == nullptr || !direction_sends(core->local_audio_direction)) {
        return DINOX_WEBRTC_STATUS_OK;
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection = get_peer_connection(core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::scoped_refptr<webrtc::AudioTrackInterface> local_audio_track;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        local_audio_track = core->local_audio_track;
    }
    if (local_audio_track == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    webrtc::scoped_refptr<webrtc::RtpSenderInterface> bound_sender;
    for (const auto& transceiver : peer_connection->GetTransceivers()) {
        if (transceiver == nullptr || transceiver->media_type() != webrtc::MediaType::AUDIO) {
            continue;
        }
        webrtc::scoped_refptr<webrtc::RtpSenderInterface> sender = transceiver->sender();
        if (sender == nullptr) {
            continue;
        }
        if (sender->track().get() == local_audio_track.get()) {
            bound_sender = sender;
            break;
        }
    }

    if (bound_sender == nullptr) {
        // Use the PeerConnection operation rather than setting the sender's
        // track manually.  In Unified Plan this reuses the compatible
        // transceiver created by SetRemoteDescription and performs the media
        // engine bookkeeping needed to start capture for a deferred answer.
        auto add_result = peer_connection->AddTrack(local_audio_track, {"dinox"});
        if (!add_result.ok()) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        bound_sender = add_result.MoveValue();
    }

    bool direction_applied = false;
    for (const auto& transceiver : peer_connection->GetTransceivers()) {
        if (transceiver == nullptr || transceiver->media_type() != webrtc::MediaType::AUDIO ||
                transceiver->sender().get() != bound_sender.get()) {
            continue;
        }
        bound_sender->SetStreams({"dinox"});
        webrtc::RTCError direction_error =
            transceiver->SetDirectionWithError(to_webrtc_direction(core->local_audio_direction));
        if (!direction_error.ok()) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        direction_applied = true;
        break;
    }
    if (!direction_applied) return DINOX_WEBRTC_STATUS_NOT_READY;
    return apply_low_bandwidth_audio_policy(core);
}

DinoXWebrtcStatus bind_local_video_track_to_senders(const std::shared_ptr<SessionCore>& core) {
    if (core == nullptr || !direction_sends(core->local_video_direction)) {
        return DINOX_WEBRTC_STATUS_OK;
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection = get_peer_connection(core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::scoped_refptr<webrtc::VideoTrackInterface> local_video_track;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        local_video_track = core->local_video_track;
    }
    if (local_video_track == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    bool bound_video_sender = false;
    for (const auto& transceiver : peer_connection->GetTransceivers()) {
        if (transceiver == nullptr || transceiver->media_type() != webrtc::MediaType::VIDEO) {
            continue;
        }
        webrtc::scoped_refptr<webrtc::RtpSenderInterface> sender = transceiver->sender();
        if (sender == nullptr) {
            continue;
        }
        webrtc::scoped_refptr<webrtc::MediaStreamTrackInterface> sender_track = sender->track();
        if (sender_track.get() != local_video_track.get()) {
            if (!sender->SetTrack(local_video_track.get())) {
                return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            }
        }
        sender->SetStreams({"dinox"});
        webrtc::RTCError direction_error =
            transceiver->SetDirectionWithError(to_webrtc_direction(core->local_video_direction));
        if (!direction_error.ok()) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        bound_video_sender = true;
    }

    return bound_video_sender ? DINOX_WEBRTC_STATUS_OK : DINOX_WEBRTC_STATUS_NOT_READY;
}

DinoXWebrtcStatus get_audio_device_count(const std::shared_ptr<ContextCore>& core, int incoming, int* out_count) {
    if (core == nullptr || core->audio_device_module == nullptr || !valid_incoming_flag(incoming) || out_count == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (!ensure_audio_device_module_initialized(core)) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    int16_t count = incoming != 0 ?
        core->audio_device_module->PlayoutDevices() :
        core->audio_device_module->RecordingDevices();
    if (count < 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    *out_count = static_cast<int>(count);
    return DINOX_WEBRTC_STATUS_OK;
}

std::unique_ptr<webrtc::VideoCaptureModule::DeviceInfo> create_video_device_info() {
    return std::unique_ptr<webrtc::VideoCaptureModule::DeviceInfo>(
        webrtc::VideoCaptureFactory::CreateDeviceInfo());
}

DinoXWebrtcStatus get_video_device_count(int* out_count) {
    if (out_count == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    std::unique_ptr<webrtc::VideoCaptureModule::DeviceInfo> device_info =
        create_video_device_info();
    if (device_info == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    uint32_t count = device_info->NumberOfDevices();
    if (count > static_cast<uint32_t>(std::numeric_limits<int>::max())) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    *out_count = static_cast<int>(count);
    return DINOX_WEBRTC_STATUS_OK;
}

void copy_c_string(char* out, size_t out_size, const char* value) {
    if (out == nullptr || out_size == 0) {
        return;
    }
    std::snprintf(out, out_size, "%s", value == nullptr ? "" : value);
}

}  // namespace

struct DinoXWebrtcContext {
    unsigned int abi_version;
    std::shared_ptr<ContextCore> core;
    std::shared_ptr<dinox::webrtc_worker::Context> worker;
};

struct DinoXWebrtcSession {
    explicit DinoXWebrtcSession(std::shared_ptr<SessionCore> core_in)
        : control_id(g_next_control_object_id.fetch_add(1)), core(std::move(core_in)) {}

    const uint64_t control_id;
    const uint64_t control_generation = 1;
    std::shared_ptr<SessionCore> core;
    std::shared_ptr<dinox::webrtc_worker::Session> worker;
    std::unique_ptr<PeerObserver> observer;
};

struct DinoXWebrtcVideoPipeline {
    explicit DinoXWebrtcVideoPipeline(std::shared_ptr<VideoPipelineCore> core_in)
        : core(std::move(core_in)) {}

    unsigned int abi_version = DINOX_WEBRTC_ABI_VERSION;
    std::shared_ptr<VideoPipelineCore> core;
    std::shared_ptr<dinox::webrtc_worker::VideoPipeline> worker;
};

struct DinoXWebrtcMediaRecorder {
    explicit DinoXWebrtcMediaRecorder(std::shared_ptr<MediaRecorderCore> core_in)
        : core(std::move(core_in)) {}

    unsigned int abi_version = DINOX_WEBRTC_ABI_VERSION;
    std::shared_ptr<MediaRecorderCore> core;
    std::shared_ptr<dinox::webrtc_worker::Recorder> worker;
};

namespace {

bool emit_media_recorder_audio_frame_from_pcm(
    DinoXWebrtcMediaRecorder* recorder,
    const void* audio_samples,
    size_t n_samples,
    size_t n_bytes_per_sample,
    size_t n_channels,
    uint32_t samples_per_sec) {
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    void* user_data = nullptr;
    uint64_t frame_id = 0;
    std::vector<int16_t> mono_frame;
    const uint8_t* callback_data = nullptr;
    size_t callback_byte_count = 0;
    int callback_channels = 0;

    if (recorder == nullptr ||
        recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
        recorder->core == nullptr ||
        audio_samples == nullptr ||
        n_samples == 0 ||
        n_bytes_per_sample != sizeof(int16_t) ||
        n_channels == 0 ||
        samples_per_sec == 0) {
        return false;
    }
    // Match the video-frame path and serialize only against callback teardown.
    // StopRecording() can wait for this capture callback to return, so taking
    // operation_mutex here would invert the stop path's lock order and deadlock:
    // stop holds operation_mutex while the capture thread waits for it.
    std::unique_lock<std::recursive_mutex> callback_lock(recorder->core->callback_mutex);

    const size_t input_sample_count = n_samples * n_channels;
    if (input_sample_count == 0 ||
        input_sample_count > static_cast<size_t>(48000 * 8)) {
        return false;
    }

    if (n_channels == 1) {
        callback_data = static_cast<const uint8_t*>(audio_samples);
        callback_byte_count = n_samples * sizeof(int16_t);
        callback_channels = 1;
    } else {
        const int16_t* input = static_cast<const int16_t*>(audio_samples);
        mono_frame.resize(n_samples);
        for (size_t frame = 0; frame < n_samples; ++frame) {
            int mixed = 0;
            for (size_t channel = 0; channel < n_channels; ++channel) {
                mixed += static_cast<int>(input[frame * n_channels + channel]);
            }
            mixed /= static_cast<int>(n_channels);
            mono_frame[frame] = clamp_int16(mixed);
        }
        callback_data = reinterpret_cast<const uint8_t*>(mono_frame.data());
        callback_byte_count = mono_frame.size() * sizeof(int16_t);
        callback_channels = 1;
    }

    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        if (recorder->core->closed ||
            (recorder->core->kind != DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO &&
             !(recorder->core->kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO &&
               recorder->core->include_audio_track)) ||
            recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING) {
            return false;
        }
        callbacks = recorder->core->callbacks;
        user_data = recorder->core->user_data;
        frame_id = ++recorder->core->audio_frame_id;
    }

    if (callbacks.on_audio_frame == nullptr) {
        return true;
    }

    callbacks.on_audio_frame(
        recorder,
        callback_data,
        callback_byte_count,
        static_cast<int>(samples_per_sec),
        callback_channels,
        static_cast<int>(sizeof(int16_t)),
        frame_id,
        user_data);
    return true;
}

bool emit_media_recorder_audio_frame(DinoXWebrtcMediaRecorder* recorder) {
    static constexpr int kSampleRateHz = 48000;
    static constexpr int kChannels = 1;
    static constexpr size_t kFramesPerBuffer = 480;

    std::array<int16_t, kFramesPerBuffer * kChannels> frame = {};
    for (size_t i = 0; i < frame.size(); ++i) {
        frame[i] = ((i / 24) % 2) == 0 ? 10000 : -10000;
    }

    return emit_media_recorder_audio_frame_from_pcm(
        recorder,
        frame.data(),
        kFramesPerBuffer,
        sizeof(int16_t),
        kChannels,
        kSampleRateHz);
}

bool emit_media_recorder_video_frame_from_webrtc(
    DinoXWebrtcMediaRecorder* recorder,
    const webrtc::VideoFrame& frame) {
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    void* user_data = nullptr;
    uint64_t frame_id = 0;
    if (recorder == nullptr ||
            recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            recorder->core == nullptr) {
        return false;
    }
    std::unique_lock<std::recursive_mutex> callback_lock(recorder->core->callback_mutex);
    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        if (recorder->core->closed ||
            recorder->core->kind != DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO ||
            recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING) {
            return false;
        }
        callbacks = recorder->core->callbacks;
        user_data = recorder->core->user_data;
        frame_id = ++recorder->core->video_frame_id;
    }

    if (callbacks.on_video_frame == nullptr) {
        return true;
    }

    webrtc::scoped_refptr<webrtc::VideoFrameBuffer> buffer =
        frame.video_frame_buffer();
    if (buffer == nullptr) {
        return false;
    }
    webrtc::scoped_refptr<webrtc::I420BufferInterface> i420 =
        buffer->ToI420();
    if (i420 == nullptr) {
        return false;
    }

    const int width = i420->width();
    const int height = i420->height();
    if (width <= 0 || height <= 0) {
        return false;
    }

    const int stride = width * 4;
    // DinoX exposes video frames to GTK and ffmpeg as B8G8R8A8/BGRA bytes.
    // In libyuv naming, ARGB little-endian is "bgra in memory"; I420ToBGRA
    // would produce argb-in-memory and swaps red/blue for our consumers.
    std::vector<uint8_t> bgra(static_cast<size_t>(stride) * static_cast<size_t>(height));
    const int convert_status = libyuv::I420ToARGB(
        i420->DataY(),
        i420->StrideY(),
        i420->DataU(),
        i420->StrideU(),
        i420->DataV(),
        i420->StrideV(),
        bgra.data(),
        stride,
        width,
        height);
    if (convert_status != 0) {
        return false;
    }

    callbacks.on_video_frame(
        recorder,
        bgra.data(),
        width,
        height,
        stride,
        frame_id,
        user_data);
    return true;
}

class MediaRecorderVideoCaptureSink final : public VideoCaptureSink {
 public:
    explicit MediaRecorderVideoCaptureSink(DinoXWebrtcMediaRecorder* recorder)
        : recorder_(recorder),
          core_(recorder == nullptr ? nullptr : recorder->core) {}

    void OnFrame(const webrtc::VideoFrame& frame) override {
        DinoXWebrtcMediaRecorder* recorder = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_) {
                return;
            }
            recorder = recorder_;
        }
        auto core = core_.lock();
        if (core == nullptr) {
            return;
        }
        std::unique_lock<std::recursive_mutex> callback_lock(core->callback_mutex);
        {
            std::lock_guard<std::mutex> lock(core->mutex);
            if (core->closed) {
                return;
            }
        }
        emit_media_recorder_video_frame_from_webrtc(recorder, frame);
    }

    void deactivate() override {
        std::lock_guard<std::mutex> lock(mutex_);
        active_ = false;
        recorder_ = nullptr;
    }

 private:
    std::mutex mutex_;
    DinoXWebrtcMediaRecorder* recorder_ = nullptr;
    std::weak_ptr<MediaRecorderCore> core_;
    bool active_ = true;
};

class MediaRecorderAudioCaptureSink final : public AudioCaptureSink {
 public:
    explicit MediaRecorderAudioCaptureSink(DinoXWebrtcMediaRecorder* recorder)
        : recorder_(recorder),
          core_(recorder == nullptr ? nullptr : recorder->core) {}

    void on_audio_capture(
        const void* audio_samples,
        size_t n_samples,
        size_t n_bytes_per_sample,
        size_t n_channels,
        uint32_t samples_per_sec) override {
        DinoXWebrtcMediaRecorder* recorder = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_) {
                return;
            }
            recorder = recorder_;
        }
        auto core = core_.lock();
        if (core == nullptr) {
            return;
        }
        std::unique_lock<std::recursive_mutex> callback_lock(core->callback_mutex);
        {
            std::lock_guard<std::mutex> lock(core->mutex);
            if (core->closed) {
                return;
            }
        }
        emit_media_recorder_audio_frame_from_pcm(
            recorder,
            audio_samples,
            n_samples,
            n_bytes_per_sample,
            n_channels,
            samples_per_sec);
    }

    void deactivate() override {
        std::lock_guard<std::mutex> lock(mutex_);
        active_ = false;
        recorder_ = nullptr;
    }

 private:
    std::mutex mutex_;
    DinoXWebrtcMediaRecorder* recorder_ = nullptr;
    std::weak_ptr<MediaRecorderCore> core_;
    bool active_ = true;
};

bool emit_media_recorder_video_frame(DinoXWebrtcMediaRecorder* recorder) {
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    void* user_data = nullptr;
    uint64_t frame_id = 0;
    int width = 0;
    int height = 0;
    if (recorder == nullptr ||
            recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            recorder->core == nullptr) {
        return false;
    }
    std::unique_lock<std::recursive_mutex> callback_lock(recorder->core->callback_mutex);
    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        if (recorder->core->closed ||
            recorder->core->kind != DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO ||
            recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING) {
            return false;
        }
        callbacks = recorder->core->callbacks;
        user_data = recorder->core->user_data;
        frame_id = ++recorder->core->video_frame_id;
        width = recorder->core->width;
        height = recorder->core->height;
    }

    if (callbacks.on_video_frame == nullptr) {
        return true;
    }
    if (width <= 0 || height <= 0) {
        return false;
    }

    const int stride = width * 4;
    const size_t byte_count = static_cast<size_t>(stride) * static_cast<size_t>(height);
    if (stride <= 0 || byte_count == 0 || byte_count > static_cast<size_t>(64 * 1024 * 1024)) {
        return false;
    }

    std::vector<uint8_t> bgra(byte_count);
    for (int y = 0; y < height; ++y) {
        uint8_t* row = bgra.data() + static_cast<size_t>(y) * static_cast<size_t>(stride);
        for (int x = 0; x < width; ++x) {
            const size_t offset = static_cast<size_t>(x) * 4;
            row[offset + 0] = static_cast<uint8_t>(x % 256);       // B
            row[offset + 1] = static_cast<uint8_t>(y % 256);       // G
            row[offset + 2] = static_cast<uint8_t>(frame_id % 256); // R
            row[offset + 3] = 255;                                  // A
        }
    }

    callbacks.on_video_frame(
        recorder,
        bgra.data(),
        width,
        height,
        stride,
        frame_id,
        user_data);
    return true;
}

DinoXWebrtcStatus create_local_description(DinoXWebrtcSession* session, bool answer,
                                         bool prepare_only = false) {
    if (session == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(session->core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    if (answer) {
        DinoXWebrtcStatus status = bind_local_audio_track_to_senders(session->core);
        if (status != DINOX_WEBRTC_STATUS_OK) {
            return status;
        }
        status = bind_local_video_track_to_senders(session->core);
        if (status != DINOX_WEBRTC_STATUS_OK) {
            return status;
        }
    }

    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed || session->core->local_description_phase != 0) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        if (prepare_only) {
            if (session->core->callbacks.on_local_description_prepared == nullptr) {
                return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
            }
            session->core->local_description_phase = 1;
        }
    }
    auto observer = webrtc::make_ref_counted<CreateDescriptionObserver>(
        session->core, session, prepare_only);
    webrtc::PeerConnectionInterface::RTCOfferAnswerOptions options;
    if (answer) {
        peer_connection->CreateAnswer(observer.get(), options);
    } else {
        peer_connection->CreateOffer(observer.get(), options);
    }
    return DINOX_WEBRTC_STATUS_OK;
}

}  // namespace

extern "C" const DinoXWebrtcBuildInfo* dinox_webrtc_get_build_info(void) {
    return &kBuildInfo;
}

extern "C" void dinox_webrtc_internal_worker_enter(void) {
    dinox::webrtc_worker::enter_internal_worker_mode();
}

extern "C" const char* dinox_webrtc_status_to_string(DinoXWebrtcStatus status) {
    switch (status) {
        case DINOX_WEBRTC_STATUS_OK:
            return "ok";
        case DINOX_WEBRTC_STATUS_INVALID_ARGUMENT:
            return "invalid-argument";
        case DINOX_WEBRTC_STATUS_NOT_READY:
            return "not-ready";
        case DINOX_WEBRTC_STATUS_INTERNAL_ERROR:
            return "internal-error";
        case DINOX_WEBRTC_STATUS_PARSE_ERROR:
            return "parse-error";
    }
    return "unknown-status";
}

extern "C" DinoXWebrtcSessionConfig dinox_webrtc_session_config_default(void) {
    DinoXWebrtcSessionConfig config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    config.audio_enabled = 1;
    config.video_enabled = 1;
    config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV;
    config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV;
    config.defer_audio_transceiver_until_answer = 0;
    config.defer_video_transceiver_until_answer = 0;
    config.ice_candidate_pool_size = 0;
    config.max_bundle = 1;
    config.network_policy = DINOX_WEBRTC_NETWORK_POLICY_AUTOMATIC;
    return config;
}

extern "C" DinoXWebrtcCallbacks dinox_webrtc_callbacks_default(void) {
    DinoXWebrtcCallbacks callbacks = {};
    callbacks.abi_version = DINOX_WEBRTC_ABI_VERSION;
    return callbacks;
}

extern "C" DinoXWebrtcMediaRecorderConfig dinox_webrtc_media_recorder_config_default(void) {
    DinoXWebrtcMediaRecorderConfig config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    config.kind = DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO;
    config.output_path = nullptr;
    config.mime_type = "audio/mp4";
    config.width = 640;
    config.height = 480;
    config.max_fps = 24;
    config.video_device_unique_id = nullptr;
    config.include_audio_track = 0;
    return config;
}

extern "C" DinoXWebrtcMediaRecorderCallbacks dinox_webrtc_media_recorder_callbacks_default(void) {
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    callbacks.abi_version = DINOX_WEBRTC_ABI_VERSION;
    return callbacks;
}

extern "C" DinoXWebrtcVideoEffectConfig dinox_webrtc_video_effect_config_default(void) {
    DinoXWebrtcVideoEffectConfig config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    config.quality = DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO;
    return config;
}

extern "C" DinoXWebrtcVideoPipelineCallbacks dinox_webrtc_video_pipeline_callbacks_default(void) {
    DinoXWebrtcVideoPipelineCallbacks callbacks = {};
    callbacks.abi_version = DINOX_WEBRTC_ABI_VERSION;
    return callbacks;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_new(DinoXWebrtcContext** out_context) {
    return dinox_webrtc_context_new_with_audio_device_mode(
        DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC,
        out_context);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_new_with_audio_device_mode(
    DinoXWebrtcAudioDeviceMode audio_device_mode,
    DinoXWebrtcContext** out_context) {
    LifecycleTrace trace("context-new");
    if (out_context == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    *out_context = nullptr;
    if (!valid_audio_device_mode(audio_device_mode)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    DinoXWebrtcContext* context = new (std::nothrow) DinoXWebrtcContext();
    if (context == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    context->abi_version = DINOX_WEBRTC_ABI_VERSION;
    if (dinox::webrtc_worker::should_use_process_engine()) {
        DinoXWebrtcStatus status = dinox::webrtc_worker::context_new(
            audio_device_mode,
            &context->worker);
        if (status != DINOX_WEBRTC_STATUS_OK) {
            delete context;
            return status;
        }
        *out_context = context;
        return DINOX_WEBRTC_STATUS_OK;
    }
    context->core = std::make_shared<ContextCore>(audio_device_mode);
    DinoXWebrtcStatus status = context->core->initialize();
    if (status != DINOX_WEBRTC_STATUS_OK) {
        delete context;
        return status;
    }

    *out_context = context;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" void dinox_webrtc_context_free(DinoXWebrtcContext* context) {
    LifecycleTrace trace("context-free");
    delete context;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_get_audio_device_count(
    DinoXWebrtcContext* context,
    int incoming,
    int* out_count) {
    LifecycleTrace trace("audio-device-count");
    if (context == nullptr || context->core == nullptr) {
        if (context != nullptr && context->worker != nullptr) {
            return dinox::webrtc_worker::context_get_audio_device_count(
                context->worker.get(), incoming, out_count);
        }
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return get_audio_device_count(context->core, incoming, out_count);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_get_audio_device_name(
    DinoXWebrtcContext* context,
    int incoming,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_guid,
    size_t out_guid_size) {
    LifecycleTrace trace("audio-device-name");
    if (context == nullptr || context->core == nullptr || context->core->audio_device_module == nullptr ||
            !valid_incoming_flag(incoming) || index < 0 || out_name == nullptr || out_name_size == 0 ||
            out_guid == nullptr || out_guid_size == 0) {
        if (context != nullptr && context->worker != nullptr) {
            return dinox::webrtc_worker::context_get_audio_device_name(
                context->worker.get(), incoming, index, out_name, out_name_size, out_guid, out_guid_size);
        }
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (!ensure_audio_device_module_initialized(context->core)) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    int count = 0;
    DinoXWebrtcStatus count_status = get_audio_device_count(context->core, incoming, &count);
    if (count_status != DINOX_WEBRTC_STATUS_OK) {
        return count_status;
    }
    if (index >= count) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    char name[webrtc::kAdmMaxDeviceNameSize] = {};
    char guid[webrtc::kAdmMaxGuidSize] = {};
    int32_t result = incoming != 0 ?
        context->core->audio_device_module->PlayoutDeviceName(static_cast<uint16_t>(index), name, guid) :
        context->core->audio_device_module->RecordingDeviceName(static_cast<uint16_t>(index), name, guid);
    if (result != 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    copy_c_string(out_name, out_name_size, name);
    copy_c_string(out_guid, out_guid_size, guid);
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_set_audio_device(
    DinoXWebrtcContext* context,
    int incoming,
    int index) {
    LifecycleTrace trace("audio-device-select");
    if (context == nullptr || context->core == nullptr || context->core->audio_device_module == nullptr ||
            !valid_incoming_flag(incoming) || index < 0) {
        if (context != nullptr && context->worker != nullptr) {
            return dinox::webrtc_worker::context_set_audio_device(
                context->worker.get(), incoming, index);
        }
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (!ensure_audio_device_module_initialized(context->core)) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    int count = 0;
    DinoXWebrtcStatus count_status = get_audio_device_count(context->core, incoming, &count);
    if (count_status != DINOX_WEBRTC_STATUS_OK) {
        return count_status;
    }
    if (index >= count) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    int32_t result = incoming != 0 ?
        context->core->audio_device_module->SetPlayoutDevice(static_cast<uint16_t>(index)) :
        context->core->audio_device_module->SetRecordingDevice(static_cast<uint16_t>(index));
    return result == 0 ? DINOX_WEBRTC_STATUS_OK : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_get_audio_device_volume(
    DinoXWebrtcContext* context,
    int incoming,
    double* out_volume,
    int* out_available) {
    if (context == nullptr || context->core == nullptr) {
        if (context != nullptr && context->worker != nullptr) {
            return dinox::webrtc_worker::context_get_audio_device_volume(
                context->worker.get(), incoming, out_volume, out_available);
        }
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return get_audio_device_volume_state(context->core, incoming, out_volume, out_available);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_set_audio_device_volume(
    DinoXWebrtcContext* context,
    int incoming,
    double volume) {
    if (context == nullptr || context->core == nullptr) {
        if (context != nullptr && context->worker != nullptr) {
            return dinox::webrtc_worker::context_set_audio_device_volume(
                context->worker.get(), incoming, volume);
        }
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return set_audio_device_volume_state(context->core, incoming, volume);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_play_test_tone(
    DinoXWebrtcContext* context,
    char digit,
    unsigned int duration_ms) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_play_test_tone(
            context->worker.get(), digit, duration_ms);
    }
    char normalized_digit = '\0';
    if (context == nullptr ||
            context->core == nullptr ||
            context->core->local_dtmf_tones == nullptr ||
            !normalize_dtmf_digit(digit, &normalized_digit) ||
            duration_ms < 20 ||
            duration_ms > 1000) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    if (context->core->measuring_audio_device_module == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    DinoXWebrtcStatus transport_status =
        context->core->measuring_audio_device_module->ensure_standalone_test_playout_transport();
    if (transport_status != DINOX_WEBRTC_STATUS_OK) {
        return transport_status;
    }
    if (!context->core->local_dtmf_tones->start(normalized_digit, duration_ms)) {
        context->core->measuring_audio_device_module->stop_standalone_test_playout_transport();
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (!ensure_audio_playout_started(context->core)) {
        context->core->local_dtmf_tones->stop();
        context->core->measuring_audio_device_module->stop_standalone_test_playout_transport();
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_play_audio_test_clip(
    DinoXWebrtcContext* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    unsigned int* out_duration_ms) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_play_audio_test_clip(
            context->worker.get(), pcm_data, byte_count, sample_rate, channels,
            bytes_per_sample, out_duration_ms);
    }
    if (context == nullptr ||
            context->core == nullptr ||
            context->core->measuring_audio_device_module == nullptr ||
            context->core->local_audio_test_clip == nullptr ||
            out_duration_ms == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    *out_duration_ms = 0;

    DinoXWebrtcStatus transport_status =
        context->core->measuring_audio_device_module->ensure_standalone_test_playout_transport();
    if (transport_status != DINOX_WEBRTC_STATUS_OK) {
        return transport_status;
    }

    unsigned int duration_ms = 0;
    if (!context->core->local_audio_test_clip->start(
            pcm_data,
            byte_count,
            sample_rate,
            channels,
            bytes_per_sample,
            &duration_ms)) {
        context->core->measuring_audio_device_module->stop_standalone_test_playout_transport();
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (!ensure_audio_playout_started(context->core)) {
        context->core->local_audio_test_clip->stop();
        context->core->measuring_audio_device_module->stop_standalone_test_playout_transport();
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    *out_duration_ms = duration_ms;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_stop_audio_test_playout(
    DinoXWebrtcContext* context) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_stop_audio_test_playout(context->worker.get());
    }
    if (context == nullptr ||
            context->core == nullptr ||
            context->core->measuring_audio_device_module == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    const uint64_t generation = context->core->next_test_tone_generation();
    device_debug(
        "DinoX WebRTC device: event=test-playout-stop-enter generation=%llu playing=%d\n",
        static_cast<unsigned long long>(generation),
        context->core->audio_device_module != nullptr &&
            context->core->audio_device_module->Playing() ? 1 : 0);
    if (context->core->local_dtmf_tones != nullptr) {
        context->core->local_dtmf_tones->stop();
    }
    if (context->core->local_audio_test_clip != nullptr) {
        context->core->local_audio_test_clip->stop();
    }
    if (should_stop_standalone_test_playout(context->core, generation)) {
        if (context->core->audio_device_module != nullptr &&
                context->core->audio_device_module->Playing()) {
            const int32_t stop_result = context->core->audio_device_module->StopPlayout();
            device_debug(
                "DinoX WebRTC device: event=test-playout-stop-adm result=%d\n",
                stop_result);
        }
        context->core->measuring_audio_device_module->stop_standalone_test_playout_transport();
    }
    device_debug("DinoX WebRTC device: event=test-playout-stop-ok\n");
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_start(
    DinoXWebrtcContext* context,
    int sample_rate,
    int channels,
    int bytes_per_sample) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_media_audio_playout_start(
            context->worker.get(), sample_rate, channels, bytes_per_sample);
    }
    if (context == nullptr || context->core == nullptr ||
            context->core->measuring_audio_device_module == nullptr ||
            context->core->local_audio_test_clip == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    DinoXWebrtcStatus transport_status =
        context->core->measuring_audio_device_module->ensure_standalone_test_playout_transport();
    if (transport_status != DINOX_WEBRTC_STATUS_OK) {
        return transport_status;
    }
    if (!context->core->local_audio_test_clip->start_stream(
            sample_rate, channels, bytes_per_sample)) {
        context->core->measuring_audio_device_module->stop_standalone_test_playout_transport();
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_push(
    DinoXWebrtcContext* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    unsigned int* out_queued_duration_ms) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_media_audio_playout_push(
            context->worker.get(), pcm_data, byte_count, out_queued_duration_ms);
    }
    if (context == nullptr || context->core == nullptr ||
            context->core->local_audio_test_clip == nullptr ||
            pcm_data == nullptr || byte_count == 0 ||
            out_queued_duration_ms == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    *out_queued_duration_ms = 0;
    if (!context->core->local_audio_test_clip->push_stream(
            pcm_data, byte_count, out_queued_duration_ms)) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    if (!ensure_audio_playout_started(context->core)) {
        context->core->local_audio_test_clip->stop();
        context->core->measuring_audio_device_module->stop_standalone_test_playout_transport();
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_set_paused(
    DinoXWebrtcContext* context,
    int paused) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_media_audio_playout_set_paused(
            context->worker.get(), paused);
    }
    if (context == nullptr || context->core == nullptr ||
            context->core->local_audio_test_clip == nullptr ||
            (paused != 0 && paused != 1)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return context->core->local_audio_test_clip->set_paused(paused != 0)
        ? DINOX_WEBRTC_STATUS_OK
        : DINOX_WEBRTC_STATUS_NOT_READY;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_flush(
    DinoXWebrtcContext* context) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_media_audio_playout_flush(
            context->worker.get());
    }
    if (context == nullptr || context->core == nullptr ||
            context->core->local_audio_test_clip == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return context->core->local_audio_test_clip->flush()
        ? DINOX_WEBRTC_STATUS_OK
        : DINOX_WEBRTC_STATUS_NOT_READY;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_finish(
    DinoXWebrtcContext* context,
    unsigned int* out_queued_duration_ms) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_media_audio_playout_finish(
            context->worker.get(), out_queued_duration_ms);
    }
    if (context == nullptr || context->core == nullptr ||
            context->core->local_audio_test_clip == nullptr ||
            out_queued_duration_ms == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    *out_queued_duration_ms = 0;
    return context->core->local_audio_test_clip->finish(out_queued_duration_ms)
        ? DINOX_WEBRTC_STATUS_OK
        : DINOX_WEBRTC_STATUS_NOT_READY;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_stop(
    DinoXWebrtcContext* context) {
    if (context != nullptr && context->worker != nullptr) {
        return dinox::webrtc_worker::context_media_audio_playout_stop(
            context->worker.get());
    }
    return dinox_webrtc_context_stop_audio_test_playout(context);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_get_video_device_count(
    DinoXWebrtcContext* context,
    int* out_count) {
    LifecycleTrace trace("video-device-count");
    if (context == nullptr || context->core == nullptr) {
        if (context != nullptr && context->worker != nullptr) {
            return dinox::webrtc_worker::context_get_video_device_count(
                context->worker.get(), out_count);
        }
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return get_video_device_count(out_count);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_get_video_device_name(
    DinoXWebrtcContext* context,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_unique_id,
    size_t out_unique_id_size,
    char* out_product_id,
    size_t out_product_id_size) {
    LifecycleTrace trace("video-device-name");
    if (context == nullptr || context->core == nullptr || index < 0 ||
            out_name == nullptr || out_name_size == 0 ||
            out_unique_id == nullptr || out_unique_id_size == 0 ||
            out_product_id == nullptr || out_product_id_size == 0) {
        if (context != nullptr && context->worker != nullptr) {
            return dinox::webrtc_worker::context_get_video_device_name(
                context->worker.get(), index, out_name, out_name_size,
                out_unique_id, out_unique_id_size, out_product_id, out_product_id_size);
        }
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    int count = 0;
    DinoXWebrtcStatus count_status = get_video_device_count(&count);
    if (count_status != DINOX_WEBRTC_STATUS_OK) {
        return count_status;
    }
    if (index >= count) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    std::unique_ptr<webrtc::VideoCaptureModule::DeviceInfo> device_info =
        create_video_device_info();
    if (device_info == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    char name[webrtc::kVideoCaptureDeviceNameLength] = {};
    char unique_id[webrtc::kVideoCaptureUniqueNameLength] = {};
    char product_id[webrtc::kVideoCaptureProductIdLength] = {};
    int32_t result = device_info->GetDeviceName(
        static_cast<uint32_t>(index),
        name,
        sizeof(name),
        unique_id,
        sizeof(unique_id),
        product_id,
        sizeof(product_id));
    if (result != 0) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    copy_c_string(out_name, out_name_size, name);
    copy_c_string(out_unique_id, out_unique_id_size, unique_id);
    copy_c_string(out_product_id, out_product_id_size, product_id);
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_inject_worker_failure_for_test(
    DinoXWebrtcContext* context,
    int failure_kind) {
    if (context == nullptr || context->worker == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    return dinox::webrtc_worker::context_inject_failure_for_test(
        context->worker.get(), failure_kind);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_context_get_video_effect_capabilities(
    DinoXWebrtcContext* context,
    DinoXWebrtcVideoEffectCapabilities* out_capabilities) {
    if (context == nullptr || out_capabilities == nullptr ||
            context->abi_version != DINOX_WEBRTC_ABI_VERSION) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (context->worker != nullptr) {
        return dinox::webrtc_worker::context_get_video_effect_capabilities(
            context->worker.get(), out_capabilities);
    }
    if (context->core == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
    *out_capabilities = video_effect_capabilities();
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_new(
    DinoXWebrtcContext* context,
    const DinoXWebrtcSessionConfig* config,
    const DinoXWebrtcCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcSession** out_session) {
    LifecycleTrace trace("session-new");
    if (context == nullptr || out_session == nullptr || config == nullptr || callbacks == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (context->abi_version != DINOX_WEBRTC_ABI_VERSION ||
        callbacks->abi_version != DINOX_WEBRTC_ABI_VERSION ||
        !validate_config(*config)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    *out_session = nullptr;
    if (context->worker != nullptr) {
        DinoXWebrtcSession* session = new (std::nothrow) DinoXWebrtcSession(nullptr);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        DinoXWebrtcStatus status = dinox::webrtc_worker::session_new(
            context->worker.get(),
            config,
            callbacks,
            user_data,
            session,
            &session->worker);
        if (status != DINOX_WEBRTC_STATUS_OK) {
            delete session;
            return status;
        }
        *out_session = session;
        return DINOX_WEBRTC_STATUS_OK;
    }
    if (context->core == nullptr || context->core->factory == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    auto core = std::make_shared<SessionCore>(context->core);
    core->network_policy = config->network_policy;
    core->callbacks = *callbacks;
    core->user_data = user_data;

    DinoXWebrtcSession* session = new (std::nothrow) DinoXWebrtcSession(core);
    if (session == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    core->control_id = session->control_id;

    session->observer = std::make_unique<PeerObserver>(core, session);

    webrtc::PeerConnectionInterface::RTCConfiguration rtc_config;
    rtc_config.sdp_semantics = webrtc::SdpSemantics::kUnifiedPlan;
    rtc_config.rtcp_mux_policy = webrtc::PeerConnectionInterface::kRtcpMuxPolicyRequire;
    rtc_config.bundle_policy = config->max_bundle
        ? webrtc::PeerConnectionInterface::kBundlePolicyMaxBundle
        : webrtc::PeerConnectionInterface::kBundlePolicyBalanced;
    rtc_config.ice_candidate_pool_size = config->ice_candidate_pool_size;

    webrtc::PeerConnectionDependencies dependencies(session->observer.get());
    auto peer_connection_result = context->core->factory->CreatePeerConnectionOrError(
        rtc_config,
        std::move(dependencies));
    if (!peer_connection_result.ok()) {
        delete session;
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    core->peer_connection = peer_connection_result.MoveValue();
    if (core->peer_connection == nullptr) {
        dinox_webrtc_session_free(session);
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    core->rtc_event_log_started = start_rtc_event_log(core->peer_connection);

    if (config->audio_enabled) {
        DinoXWebrtcStatus status = DINOX_WEBRTC_STATUS_OK;
        if (direction_sends(config->audio_direction)) {
            status = config->defer_audio_transceiver_until_answer != 0
                ? create_local_audio_track(core, config->audio_direction)
                : add_local_audio_transceiver(core, config->audio_direction);
        } else {
            status = add_transceiver(
                core->peer_connection,
                webrtc::MediaType::AUDIO,
                config->audio_direction);
        }
        if (status != DINOX_WEBRTC_STATUS_OK) {
            dinox_webrtc_session_free(session);
            return status;
        }
    }
    if (config->video_enabled) {
        DinoXWebrtcStatus status = DINOX_WEBRTC_STATUS_OK;
        if (direction_sends(config->video_direction)) {
            status = config->defer_video_transceiver_until_answer != 0
                ? create_local_video_track(core, config->video_direction)
                : add_local_video_transceiver(core, config->video_direction);
        } else {
            status = add_transceiver(
                core->peer_connection,
                webrtc::MediaType::VIDEO,
                config->video_direction);
        }
        if (status != DINOX_WEBRTC_STATUS_OK) {
            dinox_webrtc_session_free(session);
            return status;
        }
    }

    context->core->retain_session();
    *out_session = session;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" void dinox_webrtc_session_free(DinoXWebrtcSession* session) {
    if (session == nullptr) {
        return;
    }
    if (session->worker != nullptr) {
        dinox::webrtc_worker::session_free(&session->worker);
    } else {
        dinox_webrtc_session_close(session);
    }
    delete session;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_new(
    DinoXWebrtcContext* context,
    uint64_t logical_call_id,
    const DinoXWebrtcVideoPipelineCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcVideoPipeline** out_pipeline) {
    if (context == nullptr || callbacks == nullptr || out_pipeline == nullptr ||
            logical_call_id == 0 || context->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            callbacks->abi_version != DINOX_WEBRTC_ABI_VERSION) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    *out_pipeline = nullptr;
    if (context->worker != nullptr) {
        auto* pipeline = new (std::nothrow) DinoXWebrtcVideoPipeline(nullptr);
        if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        DinoXWebrtcStatus status = dinox::webrtc_worker::video_pipeline_new(
            context->worker.get(), logical_call_id, callbacks, user_data, pipeline,
            &pipeline->worker);
        if (status != DINOX_WEBRTC_STATUS_OK) {
            delete pipeline;
            return status;
        }
        *out_pipeline = pipeline;
        return DINOX_WEBRTC_STATUS_OK;
    }
    if (context->core == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
    auto core = std::make_shared<VideoPipelineCore>(context->core, logical_call_id);
    auto* pipeline = new (std::nothrow) DinoXWebrtcVideoPipeline(core);
    if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    core->callbacks = *callbacks;
    core->user_data = user_data;
    core->public_pipeline = pipeline;
    *out_pipeline = pipeline;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" void dinox_webrtc_video_pipeline_free(DinoXWebrtcVideoPipeline* pipeline) {
    if (pipeline == nullptr) return;
    if (pipeline->worker != nullptr) {
        dinox::webrtc_worker::video_pipeline_free(&pipeline->worker);
    } else if (pipeline->core != nullptr) {
        std::shared_ptr<VideoPipelineCore> core = pipeline->core;
        std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor> processor;
        webrtc::scoped_refptr<webrtc::VideoCaptureModule> capture_module;
        std::unique_ptr<LocalVideoCaptureSink> capture_sink;
        std::vector<std::shared_ptr<SessionCore>> sessions;
        {
            std::lock_guard<std::recursive_mutex> callback_lock(core->callback_mutex);
            std::lock_guard<std::recursive_mutex> publication_lock(core->publication_mutex);
            {
                std::lock_guard<std::mutex> lock(core->mutex);
                core->closed = true;
                invalidate_video_source_locked(core.get());
                core->video_runtime->close();
                sessions.reserve(core->attachments.size());
                for (const auto& item : core->attachments) {
                    std::shared_ptr<SessionCore> session = item.second.session.lock();
                    if (session != nullptr) {
                        session->local_video_effect_active.store(
                            false, std::memory_order_relaxed);
                        sessions.push_back(std::move(session));
                    }
                }
                core->attachments.clear();
                core->callbacks = {};
                core->user_data = nullptr;
                core->public_pipeline = nullptr;
                capture_module = core->video_capture_module;
                core->video_capture_module = nullptr;
                capture_sink = std::move(core->video_capture_sink);
                core->capture_owner_publication_token = 0;
                processor = std::move(core->processor);
            }
            for (const std::shared_ptr<SessionCore>& session : sessions) {
                std::lock_guard<std::mutex> session_lock(session->mutex);
                std::shared_ptr<VideoPipelineCore> bound =
                    session->local_video_effect_pipeline.lock();
                if (bound.get() == core.get()) session->local_video_effect_pipeline.reset();
            }
            pipeline->core.reset();
        }
        stop_video_capture_module(capture_module.get());
        capture_sink.reset();
        capture_module = nullptr;
        if (processor != nullptr) processor->shutdown();
    }
    delete pipeline;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_attach_session(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcSession* session,
    int preview_publisher) {
    if (pipeline == nullptr || session == nullptr ||
            (preview_publisher != 0 && preview_publisher != 1)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (pipeline->worker != nullptr || session->worker != nullptr) {
        if (pipeline->worker == nullptr || session->worker == nullptr) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox::webrtc_worker::video_pipeline_attach_session(
            pipeline->worker.get(), session->worker.get(), preview_publisher);
    }
    if (pipeline->core == nullptr || session->core == nullptr ||
            pipeline->core->context.get() != session->core->context.get()) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::shared_ptr<VideoPipelineCore> core = pipeline->core;
    std::unique_lock<std::recursive_mutex> publication_lock(core->publication_mutex);
    bool activate_on_bind = false;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> capture_module_to_stop;
    std::unique_ptr<LocalVideoCaptureSink> capture_sink_to_stop;
    {
        std::lock_guard<std::mutex> session_lock(session->core->mutex);
        if (session->core->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
        std::shared_ptr<VideoPipelineCore> bound =
            session->core->local_video_effect_pipeline.lock();
        if (bound != nullptr && bound.get() != core.get()) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
    }
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
        prune_video_pipeline_attachments_locked(core.get());
        auto existing = core->attachments.find(session->core.get());
        if (preview_publisher != 0) {
            for (const auto& [attached_session, attachment] : core->attachments) {
                if (attachment.preview_publisher && attached_session != session->core.get()) {
                    return DINOX_WEBRTC_STATUS_NOT_READY;
                }
            }
        }
        if (existing == core->attachments.end() &&
                core->attachments.size() >= video_effect_capabilities().max_subscribers) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        uint64_t subscriber_generation = 0;
        uint64_t publication_token = 0;
        if (existing != core->attachments.end()) {
            subscriber_generation = existing->second.subscriber_generation;
            publication_token = existing->second.publication_token;
            if (existing->second.preview_publisher != (preview_publisher != 0)) {
                if (existing->second.preview_publisher && core->capture_owner_publication_token == 0)
                    invalidate_video_source_locked(core.get());
                if (existing->second.publication_token ==
                        core->capture_owner_publication_token) {
                    invalidate_video_source_locked(core.get());
                    capture_module_to_stop = core->video_capture_module;
                    core->video_capture_module = nullptr;
                    capture_sink_to_stop = std::move(core->video_capture_sink);
                    core->capture_owner_publication_token = 0;
                }
                publication_token = g_next_control_object_id.fetch_add(1);
            }
        } else {
            uint64_t& previous = core->subscriber_generations[session->control_id];
            if (previous == UINT64_MAX) return DINOX_WEBRTC_STATUS_NOT_READY;
            subscriber_generation = ++previous;
            publication_token = g_next_control_object_id.fetch_add(1);
        }
        if (publication_token == 0) return DINOX_WEBRTC_STATUS_NOT_READY;
        VideoPipelineAttachment attachment = {};
        attachment.session = session->core;
        attachment.public_session = session;
        attachment.subscriber_id = session->control_id;
        attachment.subscriber_generation = subscriber_generation;
        attachment.publication_token = publication_token;
        attachment.preview_publisher = preview_publisher != 0;
        core->attachments[session->core.get()] = std::move(attachment);
        activate_on_bind = core->application_state ==
                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
            is_enabled_video_effect(core->config) &&
            core->accepted_revision == core->applied_revision;
    }
    bool bound = false;
    {
        // Drain a direct pre-bind publication before installing a privacy
        // selection. Lock order is always publication gate then callback gate.
        std::lock_guard<std::recursive_mutex> callback_lock(session->core->callback_mutex);
        std::lock_guard<std::mutex> session_lock(session->core->mutex);
        std::shared_ptr<VideoPipelineCore> previous =
            session->core->local_video_effect_pipeline.lock();
        if (!session->core->closed &&
                (previous == nullptr || previous.get() == core.get())) {
            session->core->local_video_effect_pipeline = core;
            session->core->local_video_effect_active.store(
                activate_on_bind,
                activate_on_bind ? std::memory_order_release : std::memory_order_relaxed);
            session->core->local_video_privacy_required.store(
                core->config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE,
                std::memory_order_release);
            bound = true;
        }
    }
    if (!bound) {
        {
            std::lock_guard<std::mutex> lock(core->mutex);
            core->attachments.erase(session->core.get());
        }
        publication_lock.unlock();
        stop_video_capture_module(capture_module_to_stop.get());
        capture_sink_to_stop.reset();
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    if (preview_publisher != 0) {
        // A session may have started its camera immediately before being bound
        // to the logical pipeline. Transfer that single live capture into the
        // call-scoped owner instead of opening a second device instance.
        webrtc::scoped_refptr<webrtc::VideoCaptureModule> transferred_module;
        std::unique_ptr<LocalVideoCaptureSink> transferred_sink;
        take_local_video_capture(
            session->core, &transferred_module, &transferred_sink);
        if (transferred_module != nullptr) {
            std::lock_guard<std::mutex> lock(core->mutex);
            const auto current = core->attachments.find(session->core.get());
            if (current != core->attachments.end() &&
                    current->second.preview_publisher) {
                core->video_capture_module = transferred_module;
                core->video_capture_sink = std::move(transferred_sink);
                core->capture_owner_publication_token =
                    current->second.publication_token;
            } else {
                capture_module_to_stop = transferred_module;
                capture_sink_to_stop = std::move(transferred_sink);
            }
        }
    }
    publication_lock.unlock();
    stop_video_capture_module(capture_module_to_stop.get());
    capture_sink_to_stop.reset();
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_detach_session(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcSession* session) {
    if (pipeline == nullptr || session == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (pipeline->worker != nullptr || session->worker != nullptr) {
        if (pipeline->worker == nullptr || session->worker == nullptr) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox::webrtc_worker::video_pipeline_detach_session(
            pipeline->worker.get(), session->worker.get());
    }
    if (pipeline->core == nullptr || session->core == nullptr ||
            pipeline->core->context.get() != session->core->context.get()) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::shared_ptr<VideoPipelineCore> core = pipeline->core;
    session->core->local_video_effect_active.store(false, std::memory_order_relaxed);
    std::unique_lock<std::recursive_mutex> publication_lock(core->publication_mutex);
    {
        std::lock_guard<std::mutex> session_lock(session->core->mutex);
        std::shared_ptr<VideoPipelineCore> bound =
            session->core->local_video_effect_pipeline.lock();
        if (bound.get() == core.get()) session->core->local_video_effect_pipeline.reset();
    }
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> capture_module;
    std::unique_ptr<LocalVideoCaptureSink> capture_sink;
    bool detached = false;
    {
        std::lock_guard<std::mutex> lock(core->mutex);
        if (core->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
        const auto attachment = core->attachments.find(session->core.get());
        if (attachment == core->attachments.end()) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        if (attachment->second.preview_publisher && core->capture_owner_publication_token == 0)
            invalidate_video_source_locked(core.get());
        if (attachment->second.publication_token ==
                core->capture_owner_publication_token) {
            invalidate_video_source_locked(core.get());
            capture_module = core->video_capture_module;
            core->video_capture_module = nullptr;
            capture_sink = std::move(core->video_capture_sink);
            core->capture_owner_publication_token = 0;
        }
        core->attachments.erase(attachment);
        detached = true;
    }
    publication_lock.unlock();
    stop_video_capture_module(capture_module.get());
    capture_sink.reset();
    capture_module = nullptr;
    return detached ? DINOX_WEBRTC_STATUS_OK : DINOX_WEBRTC_STATUS_NOT_READY;
}

namespace {
DinoXWebrtcStatus background_status(dinox::video_background_images::Status status) {
    using Status=dinox::video_background_images::Status;
    return status==Status::Ok ? DINOX_WEBRTC_STATUS_OK :
        status==Status::InvalidInput ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT : DINOX_WEBRTC_STATUS_NOT_READY;
}
}
// This is the sole borrowed C buffer/extent boundary. Layout and total bytes
// are validated before retirement/allocation; registry copies before return.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_upload(
    DinoXWebrtcVideoPipeline* pipeline,uint32_t width,uint32_t height,uint32_t stride,
    DinoXWebrtcBackgroundPixelFormat format,const uint8_t* pixels,size_t bytes,uint32_t* out_id) {
    if(!pipeline||!pixels||!out_id||!dinox::video_background_protocol::valid_upload(
            width,height,stride,static_cast<uint32_t>(format),bytes))return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    const auto worker=pipeline->worker;
    if(worker)return dinox::webrtc_worker::video_pipeline_background_upload(
        worker.get(),width,height,stride,format,pixels,bytes,out_id);
    auto core=pipeline->core;if(!core)return DINOX_WEBRTC_STATUS_NOT_READY;
    {std::lock_guard lock(core->mutex);if(core->closed)return DINOX_WEBRTC_STATUS_NOT_READY;}
    const auto result=core->video_runtime->background_upload({static_cast<int>(width),static_cast<int>(height),
        stride,static_cast<dinox::video_background_images::PixelFormat>(format),std::span(pixels,bytes)});
    if(result.status==dinox::video_background_images::Status::Ok)*out_id=result.id;
    return background_status(result.status);
}
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_builtin(
    DinoXWebrtcVideoPipeline* pipeline,DinoXWebrtcBackgroundBuiltin choice,uint32_t* out_id) {
    if(!pipeline||!out_id||uint32_t(choice)<1||uint32_t(choice)>10)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    const auto worker=pipeline->worker;
    if(worker)return dinox::webrtc_worker::video_pipeline_background_builtin(worker.get(),choice,out_id);
    auto core=pipeline->core;if(!core)return DINOX_WEBRTC_STATUS_NOT_READY;
    {std::lock_guard lock(core->mutex);if(core->closed)return DINOX_WEBRTC_STATUS_NOT_READY;}
    const auto result=core->video_runtime->background_builtin(static_cast<dinox::video_background_images::Builtin>(choice));
    if(result.status==dinox::video_background_images::Status::Ok)*out_id=result.id;
    return background_status(result.status);
}
extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_prepare(
    DinoXWebrtcVideoPipeline* pipeline,uint32_t id) {
    if(!pipeline||!id)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    const auto worker=pipeline->worker;
    if(worker)return dinox::webrtc_worker::video_pipeline_background_prepare(worker.get(),id);
    auto core=pipeline->core;if(!core)return DINOX_WEBRTC_STATUS_NOT_READY;
    {std::lock_guard lock(core->mutex);if(core->closed)return DINOX_WEBRTC_STATUS_NOT_READY;}
    return background_status(core->video_runtime->background_prepare(id));
}
extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_release(
    DinoXWebrtcVideoPipeline* pipeline,uint32_t id) {
    if(!pipeline||!id)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    const auto worker=pipeline->worker;
    if(worker)return dinox::webrtc_worker::video_pipeline_background_release(worker.get(),id);
    auto core=pipeline->core;if(!core)return DINOX_WEBRTC_STATUS_NOT_READY;
    {std::lock_guard lock(core->mutex);if(core->closed)return DINOX_WEBRTC_STATUS_NOT_READY;}
    return background_status(core->video_runtime->background_release(id));
}

extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_set_config(
    DinoXWebrtcVideoPipeline* pipeline,
    const DinoXWebrtcVideoEffectConfig* config,
    uint64_t* out_revision) {
    if (pipeline == nullptr || config == nullptr || out_revision == nullptr ||
            !validate_video_effect_config(*config)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    // Known but unavailable capabilities must not accept a revision, alter
    // the live selection or silently transmit a raw background.
    const auto paths = dinox::webrtc_effects::installed_vision_paths();
    if (!dinox::webrtc_effects::supported_config(*config, paths.segmentation, paths.face)) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    std::shared_ptr<dinox::webrtc_worker::VideoPipeline> worker = pipeline->worker;
    if (worker != nullptr) {
        return dinox::webrtc_worker::video_pipeline_set_config(
            worker.get(), config, out_revision);
    }
    if (pipeline->core == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
    std::shared_ptr<VideoPipelineCore> core = pipeline->core;
    if (core->context == nullptr || core->context->signaling_thread == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    DinoXWebrtcVideoPipelineState state = {};
    std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor> processor;
    {
        // Publish and configuration share this short gate.  The processor
        // control call happens only after it is released: an output callback
        // may itself need the publication gate and must never invert it with
        // the processor's configuration mutex.
        std::lock_guard<std::recursive_mutex> publication_lock(core->publication_mutex);
        {
            std::lock_guard<std::mutex> lock(core->mutex);
            if (core->closed || core->accepted_revision == UINT64_MAX) {
                return DINOX_WEBRTC_STATUS_NOT_READY;
            }
            if(config->background_mode==DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE&&
                    !core->video_runtime->background_contains(config->asset_id))
                return DINOX_WEBRTC_STATUS_NOT_READY;
            core->config = *config;
            core->video_runtime->select_background(config->background_mode==
                DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE ? config->asset_id : 0);
            core->accepted_revision++;
            core->application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_ACCEPTED;
            set_video_pipeline_sessions_active_locked(core.get(), false);
            core->configuration_request_count++;
            if (core->frame_identity.camera_lease != 0) {
                core->frame_identity.binding.config_revision = core->accepted_revision;
                core->frame_identity.binding.demand = dinox::webrtc_effects::vision_demand(*config);
                core->video_runtime->bind(core->frame_identity);
            } else { core->video_runtime->invalidate(true); }
            *out_revision = core->accepted_revision;
            state = video_pipeline_state_locked(core.get());
            processor = core->processor;
        }
    }
    if (is_enabled_video_effect(*config)) {
        processor = ensure_video_effect_processor(core);
        if (processor != nullptr && processor->enable_config(
                *config, state.accepted_revision)) {
            return DINOX_WEBRTC_STATUS_OK;
        }
        core->context->signaling_thread->PostTask(
            [core, accepted_revision = state.accepted_revision] {
                std::lock_guard<std::recursive_mutex> callback_lock(core->callback_mutex);
                DinoXWebrtcVideoPipelineStateCallback callback = nullptr;
                DinoXWebrtcVideoPipeline* public_pipeline = nullptr;
                void* user_data = nullptr;
                DinoXWebrtcVideoPipelineState failed_state = {};
                {
                    std::lock_guard<std::mutex> lock(core->mutex);
                    if (core->closed || core->accepted_revision != accepted_revision) return;
                    core->application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_FAILED;
                    set_video_pipeline_sessions_active_locked(core.get(), false);
                    failed_state = video_pipeline_state_locked(core.get());
                    callback = core->callbacks.on_state_changed;
                    public_pipeline = core->public_pipeline;
                    user_data = core->user_data;
                }
                if (callback != nullptr && public_pipeline != nullptr) {
                    callback(public_pipeline, &failed_state, user_data);
                }
            });
        return DINOX_WEBRTC_STATUS_OK;
    }

    // A fully neutral config is the exact historical direct path. A processor is neither
    // allocated nor started for a cold pipeline.  If an effect was active, its
    // executor publishes NONE only after the bounded worker has stopped.
    if (processor != nullptr && processor->disable(state.accepted_revision)) {
        return DINOX_WEBRTC_STATUS_OK;
    }
    core->context->signaling_thread->PostTask(
        [weak_core = std::weak_ptr<VideoPipelineCore>(core),
         accepted_revision = state.accepted_revision] {
            apply_video_effect_processor_state(
                weak_core, accepted_revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE);
        });
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_get_state(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcVideoPipelineState* out_state) {
    if (pipeline == nullptr || out_state == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (pipeline->worker != nullptr) {
        return dinox::webrtc_worker::video_pipeline_get_state(
            pipeline->worker.get(), out_state);
    }
    if (pipeline->core == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
    std::lock_guard<std::mutex> lock(pipeline->core->mutex);
    if (pipeline->core->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
    *out_state = video_pipeline_state_locked(pipeline->core.get());
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_video_pipeline_get_diagnostics(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcVideoEffectDiagnostics* out_diagnostics) {
    if (pipeline == nullptr || out_diagnostics == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (pipeline->worker != nullptr) {
        return dinox::webrtc_worker::video_pipeline_get_diagnostics(
            pipeline->worker.get(), out_diagnostics);
    }
    if (pipeline->core == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
    std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor> processor;
    DinoXWebrtcVideoEffectDiagnostics diagnostics = {};
    {
        std::lock_guard<std::mutex> lock(pipeline->core->mutex);
        if (pipeline->core->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
        prune_video_pipeline_attachments_locked(pipeline->core.get());
        diagnostics.abi_version = DINOX_WEBRTC_ABI_VERSION;
        diagnostics.configuration_request_count =
            pipeline->core->configuration_request_count;
        diagnostics.logical_pipeline_count = 1;
        diagnostics.subscriber_count =
            static_cast<uint32_t>(pipeline->core->attachments.size());
        processor = pipeline->core->processor;
        if(!processor)diagnostics.effect_owned_allocated_bytes=pipeline->core->video_runtime->owned_bytes();
    }
    if (processor != nullptr) {
        const dinox::webrtc_effects::Diagnostics effect = processor->snapshot();
        diagnostics.captured = effect.captured;
        diagnostics.enqueued = effect.enqueued;
        diagnostics.processed = effect.processed;
        diagnostics.bypassed = effect.bypassed;
        diagnostics.queue_replaced = effect.queue_replaced;
        diagnostics.failed = effect.failed;
        diagnostics.watchdog_bypass = effect.watchdog_bypass;
        diagnostics.processing_time_total_us = effect.processing_time_total_us;
        diagnostics.processing_time_max_us = effect.processing_time_max_us;
        diagnostics.processing_time_p95_us = effect.processing_time_p95_us;
        diagnostics.processing_time_p99_us = effect.processing_time_p99_us;
        diagnostics.last_completed_monotonic_us = effect.last_completed_monotonic_us;
        diagnostics.effect_owned_allocated_bytes = effect.effect_owned_allocated_bytes;
        diagnostics.frame_copy_count = effect.frame_copy_count;
        diagnostics.effect_thread_count = effect.effect_thread_count;
        diagnostics.effect_handle_count = effect.effect_handle_count;
    }
    *out_diagnostics = diagnostics;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_media_recorder_new(
    DinoXWebrtcContext* context,
    const DinoXWebrtcMediaRecorderConfig* config,
    const DinoXWebrtcMediaRecorderCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcMediaRecorder** out_recorder) {
    LifecycleTrace trace("recorder-new");
    if (context == nullptr || config == nullptr || callbacks == nullptr || out_recorder == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    *out_recorder = nullptr;
    if (context->worker != nullptr) {
        if (context->abi_version != DINOX_WEBRTC_ABI_VERSION ||
                callbacks->abi_version != DINOX_WEBRTC_ABI_VERSION ||
                !validate_media_recorder_config(*config)) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        auto* recorder = new (std::nothrow) DinoXWebrtcMediaRecorder(nullptr);
        if (recorder == nullptr) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        DinoXWebrtcStatus status = dinox::webrtc_worker::recorder_new(
            context->worker.get(), config, callbacks, user_data, recorder, &recorder->worker);
        if (status != DINOX_WEBRTC_STATUS_OK) {
            delete recorder;
            return status;
        }
        *out_recorder = recorder;
        return DINOX_WEBRTC_STATUS_OK;
    }
    if (context->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            context->core == nullptr ||
            callbacks->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            !validate_media_recorder_config(*config)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    auto core = std::make_shared<MediaRecorderCore>(context->core);
    core->kind = config->kind;
    core->output_path = config->output_path;
    core->mime_type = config->mime_type;
    if (config->video_device_unique_id != nullptr) {
        core->video_device_unique_id = config->video_device_unique_id;
    }
    core->include_audio_track = config->include_audio_track != 0;
    core->width = config->width;
    core->height = config->height;
    core->max_fps = config->max_fps;
    core->callbacks = *callbacks;
    core->user_data = user_data;

    DinoXWebrtcMediaRecorder* recorder = new (std::nothrow) DinoXWebrtcMediaRecorder(core);
    if (recorder == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    *out_recorder = recorder;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" void dinox_webrtc_media_recorder_free(DinoXWebrtcMediaRecorder* recorder) {
    if (recorder == nullptr) {
        return;
    }
    if (recorder->worker != nullptr) {
        dinox::webrtc_worker::recorder_free(&recorder->worker);
    } else {
        dinox_webrtc_media_recorder_cancel(recorder);
    }
    delete recorder;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_media_recorder_start(DinoXWebrtcMediaRecorder* recorder) {
    if (recorder != nullptr && recorder->worker != nullptr) {
        return dinox::webrtc_worker::recorder_start(recorder->worker.get());
    }
    LifecycleTrace trace("recorder-start");
    if (recorder == nullptr || recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            recorder->core == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::unique_lock<std::recursive_mutex> callback_lock(recorder->core->callback_mutex);
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    void* user_data = nullptr;
    bool start_live_audio_capture = false;
    bool start_live_video_capture = false;
    bool emit_synthetic_frame_on_start = false;
    std::shared_ptr<AudioCaptureSink> audio_capture_sink;
    std::string video_device_unique_id;
    int video_width = 0;
    int video_height = 0;
    int video_max_fps = 0;
    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        if (recorder->core->closed) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        if (recorder->core->state == DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING) {
            return DINOX_WEBRTC_STATUS_OK;
        }
        if (recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE &&
                recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_STARTING;
        recorder->core->audio_frame_id = 0;
        recorder->core->video_frame_id = 0;
        callbacks = recorder->core->callbacks;
        user_data = recorder->core->user_data;
        if (((recorder->core->kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO) ||
             (recorder->core->kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO &&
              recorder->core->include_audio_track)) &&
                recorder->core->context != nullptr &&
                recorder->core->context->audio_device_mode == DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT) {
            audio_capture_sink = std::make_shared<MediaRecorderAudioCaptureSink>(recorder);
            recorder->core->audio_capture_sink = audio_capture_sink;
            start_live_audio_capture = true;
        }
        if (recorder->core->kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO &&
                !recorder->core->video_device_unique_id.empty()) {
            video_device_unique_id = recorder->core->video_device_unique_id;
            video_width = recorder->core->width;
            video_height = recorder->core->height;
            video_max_fps = recorder->core->max_fps;
            start_live_video_capture = true;
        }
        if (!start_live_audio_capture && !start_live_video_capture) {
            emit_synthetic_frame_on_start = true;
        }
    }

    if (start_live_audio_capture) {
        if (recorder->core->context == nullptr ||
                recorder->core->context->audio_capture_router == nullptr ||
                recorder->core->context->measuring_audio_device_module == nullptr ||
                audio_capture_sink == nullptr) {
            std::lock_guard<std::mutex> lock(recorder->core->mutex);
            recorder->core->audio_capture_sink = nullptr;
            recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        recorder->core->context->audio_capture_router->add_sink(audio_capture_sink);
        DinoXWebrtcStatus capture_status =
            recorder->core->context->measuring_audio_device_module->start_media_recorder_capture();
        if (capture_status != DINOX_WEBRTC_STATUS_OK) {
            audio_capture_sink->deactivate();
            recorder->core->context->audio_capture_router->remove_sink(audio_capture_sink);
            std::lock_guard<std::mutex> lock(recorder->core->mutex);
            recorder->core->audio_capture_sink = nullptr;
            recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
            return capture_status;
        }
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        recorder->core->audio_capture_started = true;
        if (!start_live_video_capture) {
            recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING;
        }
    }
    if (start_live_video_capture) {
        webrtc::scoped_refptr<webrtc::VideoCaptureModule> capture_module =
            webrtc::VideoCaptureFactory::Create(video_device_unique_id.c_str());
        if (capture_module == nullptr) {
            recorder_debug("media recorder video capture failed: creating camera module");
            if (audio_capture_sink != nullptr) {
                audio_capture_sink->deactivate();
            }
            if (start_live_audio_capture &&
                    recorder->core->context != nullptr &&
                    recorder->core->context->audio_capture_router != nullptr &&
                    recorder->core->context->measuring_audio_device_module != nullptr) {
                recorder->core->context->audio_capture_router->remove_sink(audio_capture_sink);
                recorder->core->context->measuring_audio_device_module->stop_media_recorder_capture();
            }
            std::lock_guard<std::mutex> lock(recorder->core->mutex);
            recorder->core->audio_capture_sink = nullptr;
            recorder->core->audio_capture_started = false;
            recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        auto capture_sink = std::make_unique<MediaRecorderVideoCaptureSink>(recorder);
        if (capture_sink == nullptr) {
            if (audio_capture_sink != nullptr) {
                audio_capture_sink->deactivate();
            }
            if (start_live_audio_capture &&
                    recorder->core->context != nullptr &&
                    recorder->core->context->audio_capture_router != nullptr &&
                    recorder->core->context->measuring_audio_device_module != nullptr) {
                recorder->core->context->audio_capture_router->remove_sink(audio_capture_sink);
                recorder->core->context->measuring_audio_device_module->stop_media_recorder_capture();
            }
            std::lock_guard<std::mutex> lock(recorder->core->mutex);
            recorder->core->audio_capture_sink = nullptr;
            recorder->core->audio_capture_started = false;
            recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        capture_module->RegisterCaptureDataCallback(capture_sink.get());
        webrtc::VideoCaptureCapability capability;
        capability.width = video_width;
        capability.height = video_height;
        capability.maxFPS = video_max_fps;
        capability.videoType = webrtc::VideoType::kI420;
        if (capture_module->StartCapture(capability) != 0 || !capture_module->CaptureStarted()) {
            recorder_debug("media recorder video capture failed: starting camera capability");
            stop_video_capture_module(capture_module.get());
            if (audio_capture_sink != nullptr) {
                audio_capture_sink->deactivate();
            }
            if (start_live_audio_capture &&
                    recorder->core->context != nullptr &&
                    recorder->core->context->audio_capture_router != nullptr &&
                    recorder->core->context->measuring_audio_device_module != nullptr) {
                recorder->core->context->audio_capture_router->remove_sink(audio_capture_sink);
                recorder->core->context->measuring_audio_device_module->stop_media_recorder_capture();
            }
            std::lock_guard<std::mutex> lock(recorder->core->mutex);
            recorder->core->audio_capture_sink = nullptr;
            recorder->core->audio_capture_started = false;
            recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        bool closed_after_start = false;
        {
            std::lock_guard<std::mutex> lock(recorder->core->mutex);
            if (recorder->core->closed) {
                closed_after_start = true;
            } else {
                recorder->core->video_capture_module = capture_module;
                recorder->core->video_capture_sink = std::move(capture_sink);
                recorder->core->video_capture_started = true;
                recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING;
            }
        }
        if (closed_after_start) {
            if (capture_sink != nullptr) {
                capture_sink->deactivate();
            }
            stop_video_capture_module(capture_module.get());
            if (audio_capture_sink != nullptr) {
                audio_capture_sink->deactivate();
            }
            if (start_live_audio_capture &&
                    recorder->core->context != nullptr &&
                    recorder->core->context->audio_capture_router != nullptr &&
                    recorder->core->context->measuring_audio_device_module != nullptr) {
                recorder->core->context->audio_capture_router->remove_sink(audio_capture_sink);
                recorder->core->context->measuring_audio_device_module->stop_media_recorder_capture();
            }
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
    } else if (!start_live_audio_capture) {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING;
    }
    if (callbacks.on_started != nullptr) {
        std::unique_lock<std::recursive_mutex> callback_lock(recorder->core->callback_mutex);
        callbacks.on_started(recorder, user_data);
    }
    if (emit_synthetic_frame_on_start) {
        return dinox_webrtc_media_recorder_push_synthetic_frame(recorder);
    }
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_media_recorder_stop(DinoXWebrtcMediaRecorder* recorder) {
    if (recorder != nullptr && recorder->worker != nullptr) {
        return dinox::webrtc_worker::recorder_stop(recorder->worker.get());
    }
    LifecycleTrace trace("recorder-stop");
    if (recorder == nullptr || recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            recorder->core == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::unique_lock<std::recursive_mutex> operation_lock(recorder->core->operation_mutex);
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    void* user_data = nullptr;
    std::shared_ptr<AudioCaptureSink> audio_capture_sink;
    bool stop_live_audio_capture = false;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> video_capture_module;
    std::unique_ptr<VideoCaptureSink> video_capture_sink;
    bool stop_live_video_capture = false;
    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        if (recorder->core->closed) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        if (recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING &&
                recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_STARTING) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FINALIZING;
        callbacks = recorder->core->callbacks;
        user_data = recorder->core->user_data;
        audio_capture_sink = recorder->core->audio_capture_sink;
        recorder->core->audio_capture_sink = nullptr;
        stop_live_audio_capture = recorder->core->audio_capture_started;
        recorder->core->audio_capture_started = false;
        video_capture_module = recorder->core->video_capture_module;
        recorder->core->video_capture_module = nullptr;
        video_capture_sink = std::move(recorder->core->video_capture_sink);
        stop_live_video_capture = recorder->core->video_capture_started;
        recorder->core->video_capture_started = false;
    }
    if (audio_capture_sink != nullptr) {
        audio_capture_sink->deactivate();
    }
    if (stop_live_audio_capture &&
            recorder->core->context != nullptr &&
            recorder->core->context->audio_capture_router != nullptr &&
            recorder->core->context->measuring_audio_device_module != nullptr) {
        recorder->core->context->audio_capture_router->remove_sink(audio_capture_sink);
        recorder->core->context->measuring_audio_device_module->stop_media_recorder_capture();
    }
    if (video_capture_sink != nullptr) {
        video_capture_sink->deactivate();
    }
    if (stop_live_video_capture) {
        stop_video_capture_module(video_capture_module.get());
    }
    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        if (!recorder->core->closed) {
            recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE;
        }
    }
    // Always drain an in-flight audio/video callback before stop returns, even
    // when the embedding C-ABI user did not install an on_stopped callback.
    {
        std::unique_lock<std::recursive_mutex> callback_lock(recorder->core->callback_mutex);
        if (callbacks.on_stopped != nullptr) {
            callbacks.on_stopped(recorder, user_data);
        }
    }
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_media_recorder_cancel(DinoXWebrtcMediaRecorder* recorder) {
    if (recorder != nullptr && recorder->worker != nullptr) {
        return dinox::webrtc_worker::recorder_cancel(recorder->worker.get());
    }
    LifecycleTrace trace("recorder-cancel");
    if (recorder == nullptr || recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            recorder->core == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    // Drain callbacks that may still hold the C-ABI recorder/user-data
    // pointers before cancel returns and the public handle can be deleted.
    std::unique_lock<std::recursive_mutex> operation_lock(recorder->core->operation_mutex);
    std::unique_lock<std::recursive_mutex> callback_lock(recorder->core->callback_mutex);
    std::shared_ptr<AudioCaptureSink> audio_capture_sink;
    bool stop_live_audio_capture = false;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> video_capture_module;
    std::unique_ptr<VideoCaptureSink> video_capture_sink;
    bool stop_live_video_capture = false;
    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        audio_capture_sink = recorder->core->audio_capture_sink;
        recorder->core->audio_capture_sink = nullptr;
        stop_live_audio_capture = recorder->core->audio_capture_started;
        recorder->core->audio_capture_started = false;
        video_capture_module = recorder->core->video_capture_module;
        recorder->core->video_capture_module = nullptr;
        video_capture_sink = std::move(recorder->core->video_capture_sink);
        stop_live_video_capture = recorder->core->video_capture_started;
        recorder->core->video_capture_started = false;
        recorder->core->closed = true;
        recorder->core->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE;
        recorder->core->callbacks = {};
        recorder->core->user_data = nullptr;
    }
    callback_lock.unlock();
    if (audio_capture_sink != nullptr) {
        audio_capture_sink->deactivate();
    }
    if (stop_live_audio_capture &&
            recorder->core->context != nullptr &&
            recorder->core->context->audio_capture_router != nullptr &&
            recorder->core->context->measuring_audio_device_module != nullptr) {
        recorder->core->context->audio_capture_router->remove_sink(audio_capture_sink);
        recorder->core->context->measuring_audio_device_module->stop_media_recorder_capture();
    }
    if (video_capture_sink != nullptr) {
        video_capture_sink->deactivate();
    }
    if (stop_live_video_capture) {
        stop_video_capture_module(video_capture_module.get());
    }
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_media_recorder_push_synthetic_frame(DinoXWebrtcMediaRecorder* recorder) {
    if (recorder != nullptr && recorder->worker != nullptr) {
        return dinox::webrtc_worker::recorder_push_synthetic(recorder->worker.get());
    }
    if (recorder == nullptr || recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            recorder->core == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    DinoXWebrtcMediaRecorderKind kind;
    {
        std::lock_guard<std::mutex> lock(recorder->core->mutex);
        if (recorder->core->closed) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        if (recorder->core->state != DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        kind = recorder->core->kind;
    }

    bool emitted = kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO ?
        emit_media_recorder_audio_frame(recorder) :
        emit_media_recorder_video_frame(recorder);
    return emitted ? DINOX_WEBRTC_STATUS_OK : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_media_recorder_get_state(
    DinoXWebrtcMediaRecorder* recorder,
    DinoXWebrtcMediaRecorderState* out_state) {
    if (recorder != nullptr && recorder->worker != nullptr) {
        return dinox::webrtc_worker::recorder_get_state(recorder->worker.get(), out_state);
    }
    if (recorder == nullptr || recorder->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            recorder->core == nullptr || out_state == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(recorder->core->mutex);
    *out_state = recorder->core->state;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_add_ice_server(
    DinoXWebrtcSession* session,
    const char* url,
    const char* username,
    const char* credential) {
    if (session == nullptr || url == nullptr || url[0] == '\0') {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_add_ice_server(
            session->worker.get(),
            url,
            username == nullptr ? "" : username,
            credential == nullptr ? "" : credential);
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(session->core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::PeerConnectionInterface::RTCConfiguration rtc_config =
        peer_connection->GetConfiguration();
    webrtc::PeerConnectionInterface::IceServer ice_server;
    ice_server.uri = url;
    ice_server.urls.push_back(url);
    if (username != nullptr) {
        ice_server.username = username;
    }
    if (credential != nullptr) {
        ice_server.password = credential;
    }
    // Match the WebRTC mobile-client behavior for XEP-0215 TURN/TURNS entries:
    // media remains SRTP-encrypted and TURN credentials are short lived, while
    // relays in the wild often do not have browser-style certificate chains.
    ice_server.tls_cert_policy = webrtc::PeerConnectionInterface::kTlsCertPolicyInsecureNoCheck;
    rtc_config.servers.push_back(std::move(ice_server));

    webrtc::RTCError error = peer_connection->SetConfiguration(rtc_config);
    if (!error.ok()) {
        emit_session_error(
            session->core,
            session,
            DINOX_WEBRTC_STATUS_INVALID_ARGUMENT,
            error.message());
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_create_offer(DinoXWebrtcSession* session) {
    if (session != nullptr && session->worker != nullptr) {
        return dinox::webrtc_worker::session_create_offer(session->worker.get());
    }
    return create_local_description(session, false);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_create_answer(DinoXWebrtcSession* session) {
    if (session != nullptr && session->worker != nullptr) {
        return dinox::webrtc_worker::session_create_answer(session->worker.get());
    }
    return create_local_description(session, true);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_prepare_local_description(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type) {
    if (session == nullptr || (type != DINOX_WEBRTC_SDP_TYPE_OFFER &&
            type != DINOX_WEBRTC_SDP_TYPE_ANSWER)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_prepare_local_description(
            session->worker.get(), type);
    }
    return create_local_description(session, type == DINOX_WEBRTC_SDP_TYPE_ANSWER, true);
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_set_local_description(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    const char* sdp) {
    if (session == nullptr || sdp == nullptr || sdp[0] == '\0' ||
            (type != DINOX_WEBRTC_SDP_TYPE_OFFER && type != DINOX_WEBRTC_SDP_TYPE_ANSWER)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_set_local_description(session->worker.get(), type, sdp);
    }
    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(session->core);
    if (peer_connection == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->local_description_phase != 2 ||
                session->core->prepared_local_description_type != type) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
    }
    webrtc::SdpParseError error;
    std::unique_ptr<webrtc::SessionDescriptionInterface> description =
        webrtc::CreateSessionDescription(to_webrtc_sdp_type(type), sdp, &error);
    if (description == nullptr) {
        emit_session_error(session->core, session, DINOX_WEBRTC_STATUS_PARSE_ERROR,
            error.description.c_str());
        return DINOX_WEBRTC_STATUS_PARSE_ERROR;
    }
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed || session->core->local_description_phase != 2 ||
                session->core->prepared_local_description_type != type) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        session->core->local_description_phase = 3;
    }
    auto observer = webrtc::make_ref_counted<SetLocalDescriptionObserver>(
        session->core, session, type, description->ToString(), true);
    peer_connection->SetLocalDescription(observer.get(), description.release());
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_set_remote_description(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    const char* sdp) {
    if (session == nullptr || sdp == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_set_remote_description(
            session->worker.get(), type, sdp);
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(session->core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::SdpParseError error;
    std::unique_ptr<webrtc::SessionDescriptionInterface> description =
        webrtc::CreateSessionDescription(to_webrtc_sdp_type(type), sdp, &error);
    if (description == nullptr) {
        emit_session_error(session->core, session, DINOX_WEBRTC_STATUS_PARSE_ERROR, error.description.c_str());
        return DINOX_WEBRTC_STATUS_PARSE_ERROR;
    }

    auto observer = webrtc::make_ref_counted<SetRemoteDescriptionObserver>(session->core, session, type);
    peer_connection->SetRemoteDescription(observer.get(), description.release());
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_add_remote_ice_candidate(
    DinoXWebrtcSession* session,
    const char* sdp_mid,
    int sdp_mline_index,
    const char* candidate) {
    if (session == nullptr || sdp_mid == nullptr || candidate == nullptr || sdp_mline_index < 0) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_add_remote_candidate(
            session->worker.get(), sdp_mid, sdp_mline_index, candidate);
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(session->core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    webrtc::SdpParseError error;
    std::unique_ptr<webrtc::IceCandidate> ice_candidate(
        webrtc::CreateIceCandidate(sdp_mid, sdp_mline_index, candidate, &error));
    if (ice_candidate == nullptr) {
        emit_session_error(session->core, session, DINOX_WEBRTC_STATUS_PARSE_ERROR, error.description.c_str());
        return DINOX_WEBRTC_STATUS_PARSE_ERROR;
    }

    if (!peer_connection->AddIceCandidate(ice_candidate.get())) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_set_local_audio_enabled(
    DinoXWebrtcSession* session,
    int enabled) {
    if (session == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_set_audio_enabled(session->worker.get(), enabled);
    }

    webrtc::scoped_refptr<webrtc::AudioTrackInterface> local_audio_track;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        local_audio_track = session->core->local_audio_track;
    }
    if (local_audio_track == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    local_audio_track->set_enabled(enabled != 0);
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_set_local_video_enabled(
    DinoXWebrtcSession* session,
    int enabled) {
    if (session == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_set_video_enabled(session->worker.get(), enabled);
    }

    webrtc::scoped_refptr<webrtc::VideoTrackInterface> local_video_track;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        local_video_track = session->core->local_video_track;
    }
    if (local_video_track == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    local_video_track->set_enabled(enabled != 0);
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_send_dtmf(
    DinoXWebrtcSession* session,
    char digit,
    unsigned int duration_ms) {
    if (session != nullptr && session->worker != nullptr) {
        return dinox::webrtc_worker::session_send_dtmf(
            session->worker.get(), digit, duration_ms, false);
    }
    char normalized_digit = '\0';
    if (session == nullptr ||
        !normalize_dtmf_digit(digit, &normalized_digit) ||
        duration_ms < 70 ||
        duration_ms > 6000) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(session->core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    for (const auto& transceiver : peer_connection->GetTransceivers()) {
        if (transceiver == nullptr || transceiver->media_type() != webrtc::MediaType::AUDIO) {
            continue;
        }
        webrtc::scoped_refptr<webrtc::RtpSenderInterface> sender = transceiver->sender();
        if (sender == nullptr) {
            continue;
        }
        webrtc::scoped_refptr<webrtc::DtmfSenderInterface> dtmf_sender =
            sender->GetDtmfSender();
        if (dtmf_sender == nullptr || !dtmf_sender->CanInsertDtmf()) {
            continue;
        }

        std::string tones(1, normalized_digit);
        if (!dtmf_sender->InsertDtmf(tones, static_cast<int>(duration_ms), 70)) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    return DINOX_WEBRTC_STATUS_NOT_READY;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_play_local_dtmf_feedback(
    DinoXWebrtcSession* session,
    char digit,
    unsigned int duration_ms) {
    if (session != nullptr && session->worker != nullptr) {
        return dinox::webrtc_worker::session_send_dtmf(
            session->worker.get(), digit, duration_ms, true);
    }
    char normalized_digit = '\0';
    if (session == nullptr ||
        session->core == nullptr ||
        !normalize_dtmf_digit(digit, &normalized_digit) ||
        duration_ms < 20 ||
        duration_ms > 1000) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    std::shared_ptr<ContextCore> context;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        context = session->core->context;
    }
    if (context == nullptr || context->local_dtmf_tones == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }
    if (!context->local_dtmf_tones->start(normalized_digit, duration_ms)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (!ensure_audio_playout_started(context)) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_push_synthetic_video_frame(
    DinoXWebrtcSession* session,
    int width,
    int height) {
    if (session != nullptr && session->worker != nullptr) {
        return dinox::webrtc_worker::session_push_synthetic_video(
            session->worker.get(), width, height);
    }
    if (session == nullptr || width <= 0 || height <= 0 || width > 4096 || height > 4096) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }

    std::optional<webrtc::VideoFrame> frame = make_black_video_frame(width, height);
    if (!frame.has_value()) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    webrtc::scoped_refptr<SyntheticVideoTrackSource> local_video_source;
    uint64_t frame_id = 0;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed || session->core->synthetic_video_frame_id == UINT64_MAX) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        local_video_source = session->core->local_video_source;
        frame_id = ++session->core->synthetic_video_frame_id;
    }
    if (local_video_source == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    return route_outgoing_video_frame(
        session->core, session, local_video_source, frame.value(), frame_id)
        ? DINOX_WEBRTC_STATUS_OK : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_start_video_capture(
    DinoXWebrtcSession* session,
    const char* device_unique_id,
    int width,
    int height,
    int max_fps) {
    LifecycleTrace trace("video-capture-start");
    if (session == nullptr || device_unique_id == nullptr || device_unique_id[0] == '\0' ||
            width <= 0 || height <= 0 || max_fps <= 0 ||
            width > 4096 || height > 4096 || max_fps > 120) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_start_video_capture(
            session->worker.get(), device_unique_id, width, height, max_fps);
    }

    webrtc::scoped_refptr<SyntheticVideoTrackSource> local_video_source;
    std::shared_ptr<VideoPipelineCore> pipeline;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        local_video_source = session->core->local_video_source;
        pipeline = session->core->local_video_effect_pipeline.lock();
    }
    if (local_video_source == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    const uint64_t camera_lease = g_next_control_object_id.fetch_add(1);
    if (camera_lease == 0) return DINOX_WEBRTC_STATUS_NOT_READY;

    std::unique_lock<std::recursive_mutex> pipeline_publication_lock;
    uint64_t capture_owner_token = 0;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> old_capture_module;
    std::unique_ptr<LocalVideoCaptureSink> old_capture_sink;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> extra_capture_module;
    std::unique_ptr<LocalVideoCaptureSink> extra_capture_sink;
    if (pipeline != nullptr) {
        pipeline_publication_lock =
            std::unique_lock<std::recursive_mutex>(pipeline->publication_mutex);
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            if (pipeline->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
            prune_video_pipeline_attachments_locked(pipeline.get());
            const auto attachment = pipeline->attachments.find(session->core.get());
            if (attachment == pipeline->attachments.end() ||
                    attachment->second.public_session != session ||
                    !attachment->second.preview_publisher ||
                    attachment->second.publication_token == 0) {
                return DINOX_WEBRTC_STATUS_NOT_READY;
            }
            capture_owner_token = attachment->second.publication_token;
            invalidate_video_source_locked(pipeline.get());
            session->core->local_video_camera_request.store(camera_lease, std::memory_order_release);
            old_capture_module = pipeline->video_capture_module;
            pipeline->video_capture_module = nullptr;
            old_capture_sink = std::move(pipeline->video_capture_sink);
            pipeline->capture_owner_publication_token = 0;
        }
        // A pre-bind capture is normally transferred by attach_session. Take
        // any remaining session-owned instance defensively so the logical call
        // still has at most one open camera.
        take_local_video_capture(
            session->core, &extra_capture_module, &extra_capture_sink);
    } else {
        session->core->local_video_camera_request.store(camera_lease, std::memory_order_release);
        session->core->local_video_camera_lease.store(0, std::memory_order_release);
        take_local_video_capture(session->core, &old_capture_module, &old_capture_sink);
    }
    if (pipeline_publication_lock.owns_lock()) {
        // StopCapture may wait for an in-flight frame callback. That callback
        // enters the publication gate, so the device must be stopped only
        // after the old owner has been invalidated and the gate released.
        pipeline_publication_lock.unlock();
    }
    stop_video_capture_module(old_capture_module.get());
    stop_video_capture_module(extra_capture_module.get());
    extra_capture_sink.reset();
    extra_capture_module = nullptr;
    old_capture_sink.reset();
    old_capture_module = nullptr;

    webrtc::scoped_refptr<webrtc::VideoCaptureModule> capture_module =
        webrtc::VideoCaptureFactory::Create(device_unique_id);
    if (capture_module == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    auto capture_sink = std::make_unique<LocalVideoCaptureSink>(
        session->core,
        session,
        local_video_source,
        camera_lease);
    if (capture_sink == nullptr) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    capture_module->RegisterCaptureDataCallback(capture_sink.get());
    webrtc::VideoCaptureCapability capability;
    capability.width = width;
    capability.height = height;
    capability.maxFPS = max_fps;
    capability.videoType = webrtc::VideoType::kI420;
    if (capture_module->StartCapture(capability) != 0 || !capture_module->CaptureStarted()) {
        stop_video_capture_module(capture_module.get());
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }

    bool closed_after_start = false;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        closed_after_start = session->core->closed ||
            session->core->local_video_camera_request.load(std::memory_order_acquire) != camera_lease;
    }
    if (!closed_after_start && pipeline != nullptr) {
        pipeline_publication_lock.lock();
        std::lock_guard<std::mutex> lock(pipeline->mutex);
        const auto attachment = pipeline->attachments.find(session->core.get());
        if (pipeline->closed || attachment == pipeline->attachments.end() ||
                session->core->local_video_camera_request.load(std::memory_order_acquire) != camera_lease ||
                !attachment->second.preview_publisher ||
                attachment->second.publication_token != capture_owner_token) {
            closed_after_start = true;
        } else {
            pipeline->video_capture_module = capture_module;
            pipeline->video_capture_sink = std::move(capture_sink);
            pipeline->capture_owner_publication_token = capture_owner_token;
            session->core->local_video_camera_lease.store(camera_lease, std::memory_order_release);
        }
    } else if (!closed_after_start) {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed ||
                session->core->local_video_camera_request.load(std::memory_order_acquire) != camera_lease) {
            closed_after_start = true;
        } else {
            session->core->local_video_capture_module = capture_module;
            session->core->local_video_capture_sink = std::move(capture_sink);
            session->core->local_video_camera_lease.store(camera_lease, std::memory_order_release);
        }
    }
    if (pipeline_publication_lock.owns_lock()) {
        pipeline_publication_lock.unlock();
    }
    if (closed_after_start) {
        stop_video_capture_module(capture_module.get());
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_stop_video_capture(
    DinoXWebrtcSession* session) {
    LifecycleTrace trace("video-capture-stop");
    if (session == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_stop_video_capture(session->worker.get());
    }

    std::shared_ptr<VideoPipelineCore> pipeline;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        pipeline = session->core->local_video_effect_pipeline.lock();
    }
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> capture_module;
    std::unique_ptr<LocalVideoCaptureSink> capture_sink;
    if (pipeline != nullptr) {
        std::lock_guard<std::recursive_mutex> publication_lock(
            pipeline->publication_mutex);
        std::lock_guard<std::mutex> lock(pipeline->mutex);
        const auto attachment = pipeline->attachments.find(session->core.get());
        if (pipeline->closed || attachment == pipeline->attachments.end() ||
                attachment->second.public_session != session ||
                !attachment->second.preview_publisher ||
                (pipeline->capture_owner_publication_token == 0 &&
                 (pipeline->video_capture_module != nullptr ||
                  pipeline->video_capture_sink != nullptr))) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        if (pipeline->capture_owner_publication_token == 0) {
            // Stop is intentionally idempotent. A freshly attached preview
            // publisher has a publication token but owns no capture until
            // Start succeeds; the same state follows a successful Stop.
            invalidate_video_source_locked(pipeline.get());
            return DINOX_WEBRTC_STATUS_OK;
        }
        if (attachment->second.publication_token !=
                pipeline->capture_owner_publication_token) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        capture_module = pipeline->video_capture_module;
        invalidate_video_source_locked(pipeline.get());
        pipeline->video_capture_module = nullptr;
        capture_sink = std::move(pipeline->video_capture_sink);
        pipeline->capture_owner_publication_token = 0;
    } else {
        session->core->local_video_camera_request.store(0, std::memory_order_release);
        session->core->local_video_camera_lease.store(0, std::memory_order_release);
        take_local_video_capture(session->core, &capture_module, &capture_sink);
    }
    stop_video_capture_module(capture_module.get());
    capture_sink.reset();
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_get_state(
    DinoXWebrtcSession* session,
    DinoXWebrtcSessionState* out_state) {
    if (session == nullptr || out_state == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_get_state(session->worker.get(), out_state);
    }

    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection =
        get_peer_connection(session->core);
    if (peer_connection == nullptr) {
        return DINOX_WEBRTC_STATUS_NOT_READY;
    }

    DinoXWebrtcSessionState state = {};
    state.abi_version = DINOX_WEBRTC_ABI_VERSION;
    state.ice_server_count = static_cast<int>(peer_connection->GetConfiguration().servers.size());

    for (const auto& transceiver : peer_connection->GetTransceivers()) {
        if (transceiver == nullptr) {
            continue;
        }
        bool has_remote_receiver =
            transceiver->current_direction().has_value() &&
            direction_receives(transceiver->current_direction().value());
        switch (transceiver->media_type()) {
            case webrtc::MediaType::AUDIO:
                state.audio_transceiver_count += 1;
                if (has_remote_receiver) {
                    state.remote_audio_receiver_count += 1;
                }
                break;
            case webrtc::MediaType::VIDEO:
                state.video_transceiver_count += 1;
                if (has_remote_receiver) {
                    state.remote_video_receiver_count += 1;
                }
                break;
            case webrtc::MediaType::DATA:
            case webrtc::MediaType::UNSUPPORTED:
            case webrtc::MediaType::ANY:
                break;
        }
    }

    webrtc::scoped_refptr<webrtc::AudioSourceInterface> local_audio_source;
    webrtc::scoped_refptr<webrtc::AudioTrackInterface> local_audio_track;
    copy_local_audio_state(session->core, &local_audio_source, &local_audio_track);
    state.local_audio_source_attached = local_audio_source != nullptr ? 1 : 0;
    state.local_audio_track_attached = local_audio_track != nullptr ? 1 : 0;
    state.local_audio_track_enabled =
        local_audio_track != nullptr && local_audio_track->enabled() ? 1 : 0;
    webrtc::scoped_refptr<SyntheticVideoTrackSource> local_video_source;
    webrtc::scoped_refptr<webrtc::VideoTrackInterface> local_video_track;
    copy_local_video_state(session->core, &local_video_source, &local_video_track);
    state.local_video_source_attached = local_video_source != nullptr ? 1 : 0;
    state.local_video_track_attached = local_video_track != nullptr ? 1 : 0;
    state.local_video_track_enabled =
        local_video_track != nullptr && local_video_track->enabled() ? 1 : 0;
    if (local_video_source != nullptr) {
        local_video_source->snapshot(
            &state.local_video_source_frame_count,
            &state.local_video_source_last_width,
            &state.local_video_source_last_height);
    }
    std::shared_ptr<VideoPipelineCore> capture_pipeline;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        capture_pipeline = session->core->local_video_effect_pipeline.lock();
        if (session->core->local_video_capture_module != nullptr) {
            state.local_video_capture_running =
                session->core->local_video_capture_module->CaptureStarted() ? 1 : 0;
        }
        if (session->core->local_video_capture_sink != nullptr) {
            session->core->local_video_capture_sink->snapshot(
                &state.local_video_capture_frame_count,
                &state.local_video_capture_last_width,
                &state.local_video_capture_last_height);
        }
    }
    if (capture_pipeline != nullptr && state.local_video_capture_running == 0) {
        std::lock_guard<std::recursive_mutex> publication_lock(
            capture_pipeline->publication_mutex);
        std::lock_guard<std::mutex> lock(capture_pipeline->mutex);
        const auto attachment = capture_pipeline->attachments.find(session->core.get());
        if (!capture_pipeline->closed &&
                attachment != capture_pipeline->attachments.end() &&
                attachment->second.preview_publisher &&
                attachment->second.publication_token ==
                    capture_pipeline->capture_owner_publication_token) {
            if (capture_pipeline->video_capture_module != nullptr) {
                state.local_video_capture_running =
                    capture_pipeline->video_capture_module->CaptureStarted() ? 1 : 0;
            }
            if (capture_pipeline->video_capture_sink != nullptr) {
                capture_pipeline->video_capture_sink->snapshot(
                    &state.local_video_capture_frame_count,
                    &state.local_video_capture_last_width,
                    &state.local_video_capture_last_height);
            }
        }
    }
    snapshot_remote_audio_sink_state(
        session->core,
        &state.remote_audio_sink_count,
        &state.remote_audio_sink_frame_count,
        &state.remote_audio_sink_sample_count,
        &state.remote_audio_sink_peak_level);
    snapshot_remote_video_sink_state(
        session->core,
        &state.remote_video_sink_count,
        &state.remote_video_sink_frame_count,
        &state.remote_video_sink_last_width,
        &state.remote_video_sink_last_height);
    RtpStatsSnapshot rtp_stats = snapshot_rtp_stats(session->core);
    state.inbound_audio_packets_received = rtp_stats.inbound_audio_packets_received;
    state.inbound_audio_bytes_received = rtp_stats.inbound_audio_bytes_received;
    state.inbound_audio_total_samples_received =
        rtp_stats.inbound_audio_total_samples_received;
    state.inbound_video_packets_received = rtp_stats.inbound_video_packets_received;
    state.inbound_video_bytes_received = rtp_stats.inbound_video_bytes_received;
    state.inbound_video_frames_received = rtp_stats.inbound_video_frames_received;
    state.inbound_video_frames_decoded = rtp_stats.inbound_video_frames_decoded;
    state.inbound_video_frame_width = rtp_stats.inbound_video_frame_width;
    state.inbound_video_frame_height = rtp_stats.inbound_video_frame_height;
    state.outbound_audio_packets_sent = rtp_stats.outbound_audio_packets_sent;
    state.outbound_audio_bytes_sent = rtp_stats.outbound_audio_bytes_sent;
    state.outbound_audio_target_bitrate = rtp_stats.outbound_audio_target_bitrate;
    state.outbound_video_packets_sent = rtp_stats.outbound_video_packets_sent;
    state.outbound_video_bytes_sent = rtp_stats.outbound_video_bytes_sent;
    state.outbound_video_frames_sent = rtp_stats.outbound_video_frames_sent;
    state.outbound_video_frames_encoded = rtp_stats.outbound_video_frames_encoded;
    state.outbound_video_target_bitrate = rtp_stats.outbound_video_target_bitrate;
    state.outbound_video_frame_width = rtp_stats.outbound_video_frame_width;
    state.outbound_video_frame_height = rtp_stats.outbound_video_frame_height;
    state.inbound_audio_level = rtp_stats.inbound_audio_level;
    state.source_audio_level = rtp_stats.source_audio_level;
    state.source_audio_total_energy = rtp_stats.source_audio_total_energy;
    state.source_audio_total_duration = rtp_stats.source_audio_total_duration;
    state.stats_report_count = rtp_stats.stats_report_count;
    request_rtp_stats(session->core);

    webrtc::scoped_refptr<webrtc::AudioDeviceModule> audio_device_module;
    std::shared_ptr<LocalDtmfToneGenerator> local_dtmf_tones;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->context != nullptr) {
            audio_device_module = session->core->context->audio_device_module;
            local_dtmf_tones = session->core->context->local_dtmf_tones;
        }
    }
    if (audio_device_module != nullptr) {
        state.audio_device_initialized = audio_device_module->Initialized() ? 1 : 0;
        state.audio_device_playout_initialized = audio_device_module->PlayoutIsInitialized() ? 1 : 0;
        state.audio_device_recording_initialized = audio_device_module->RecordingIsInitialized() ? 1 : 0;
        state.audio_device_playing = audio_device_module->Playing() ? 1 : 0;
        state.audio_device_recording = audio_device_module->Recording() ? 1 : 0;
        {
            std::lock_guard<std::mutex> lock(session->core->mutex);
            if (session->core->context != nullptr &&
                session->core->context->audio_capture_probe != nullptr) {
                session->core->context->audio_capture_probe->snapshot(
                    &state.audio_device_capture_probe_frame_count,
                    &state.audio_device_capture_probe_sample_count,
                    &state.audio_device_capture_probe_peak_level);
            }
        }
        std::optional<webrtc::AudioDeviceModule::Stats> stats = audio_device_module->GetStats();
        if (stats.has_value()) {
            state.audio_device_capture_sample_count =
                static_cast<uint64_t>(stats->total_capture_samples_count);
            state.audio_device_playout_sample_count =
                static_cast<uint64_t>(stats->total_samples_count);
        }
        get_audio_device_volume_state(
            session->core->context,
            0,
            &state.audio_device_microphone_volume,
            &state.audio_device_microphone_volume_available);
        get_audio_device_volume_state(
            session->core->context,
            1,
            &state.audio_device_speaker_volume,
            &state.audio_device_speaker_volume_available);
    }
    if (local_dtmf_tones != nullptr) {
        local_dtmf_tones->snapshot(
            &state.local_dtmf_feedback_start_count,
            &state.local_dtmf_feedback_mix_call_count,
            &state.local_dtmf_feedback_mixed_frame_count,
            &state.local_dtmf_feedback_unsupported_format_count,
            &state.local_dtmf_feedback_last_sample_rate,
            &state.local_dtmf_feedback_last_channels,
            &state.local_dtmf_feedback_last_bytes_per_sample,
            &state.local_dtmf_feedback_peak_level,
            &state.local_dtmf_feedback_active);
    }
    state.peer_connection_state =
        from_webrtc_peer_connection_state(peer_connection->peer_connection_state());
    state.ice_connection_state =
        from_webrtc_ice_connection_state(peer_connection->standardized_ice_connection_state());
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        state.network_policy = session->core->network_policy;
        state.audio_sender_bitrate_cap_bps = session->core->audio_sender_bitrate_cap_bps;
        state.audio_sender_adaptive_ptime = session->core->audio_sender_adaptive_ptime ? 1 : 0;
        state.audio_sender_policy_applied = session->core->audio_sender_policy_applied ? 1 : 0;
    }

    *out_state = state;
    return DINOX_WEBRTC_STATUS_OK;
}

extern "C" DinoXWebrtcStatus dinox_webrtc_session_close(DinoXWebrtcSession* session) {
    LifecycleTrace trace("session-close");
    if (session == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    if (session->worker != nullptr) {
        return dinox::webrtc_worker::session_close(session->worker.get());
    }

    // Serialize teardown with every callback that may carry the raw C-ABI
    // session/user-data pointers. Once this lock is acquired, prior callbacks
    // have returned and later callbacks observe core->closed before invoking
    // client code.
    std::unique_lock<std::recursive_mutex> callback_lock(session->core->callback_mutex);
    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_connection;
    webrtc::scoped_refptr<webrtc::AudioSourceInterface> local_audio_source;
    webrtc::scoped_refptr<webrtc::AudioTrackInterface> local_audio_track;
    webrtc::scoped_refptr<SyntheticVideoTrackSource> local_video_source;
    webrtc::scoped_refptr<webrtc::VideoTrackInterface> local_video_track;
    webrtc::scoped_refptr<webrtc::VideoCaptureModule> local_video_capture_module;
    std::unique_ptr<LocalVideoCaptureSink> local_video_capture_sink;
    std::vector<RemoteAudioSinkBinding> remote_audio_sinks;
    std::vector<RemoteVideoSinkBinding> remote_video_sinks;
    std::shared_ptr<ContextCore> context;
    std::shared_ptr<VideoPipelineCore> bound_video_pipeline;
    bool rtc_event_log_started = false;
    {
        std::lock_guard<std::mutex> lock(session->core->mutex);
        if (session->core->closed) {
            return DINOX_WEBRTC_STATUS_OK;
        }
        session->core->closed = true;
        session->core->local_video_camera_request.store(0, std::memory_order_release);
        session->core->local_video_camera_lease.store(0, std::memory_order_release);
        session->core->local_video_effect_active.store(
            false, std::memory_order_relaxed);
        bound_video_pipeline = session->core->local_video_effect_pipeline.lock();
        session->core->local_video_effect_pipeline.reset();
        context = session->core->context;
        peer_connection = session->core->peer_connection;
        rtc_event_log_started = session->core->rtc_event_log_started;
        session->core->rtc_event_log_started = false;
        local_audio_source = session->core->local_audio_source;
        local_audio_track = session->core->local_audio_track;
        local_video_source = session->core->local_video_source;
        local_video_track = session->core->local_video_track;
        local_video_capture_module = session->core->local_video_capture_module;
        session->core->peer_connection = nullptr;
        session->core->local_audio_track = nullptr;
        session->core->local_audio_source = nullptr;
        session->core->local_video_track = nullptr;
        session->core->local_video_source = nullptr;
        session->core->local_video_capture_module = nullptr;
        session->core->callbacks = {};
        session->core->user_data = nullptr;
        local_video_capture_sink = std::move(session->core->local_video_capture_sink);
        remote_audio_sinks.swap(session->core->remote_audio_sinks);
        remote_video_sinks.swap(session->core->remote_video_sinks);
    }

    // The gate above drains callbacks and prevents new ones by setting closed.
    // Do not hold it while calling into libwebrtc Close()/sink teardown: those
    // operations may synchronously wait for a media/signaling callback which
    // must be allowed to observe the closed state and return.
    callback_lock.unlock();

    webrtc::scoped_refptr<webrtc::VideoCaptureModule> pipeline_capture_module;
    std::unique_ptr<LocalVideoCaptureSink> pipeline_capture_sink;
    if (bound_video_pipeline != nullptr) {
        std::lock_guard<std::recursive_mutex> publication_lock(
            bound_video_pipeline->publication_mutex);
        {
            std::lock_guard<std::mutex> lock(bound_video_pipeline->mutex);
            const auto attachment =
                bound_video_pipeline->attachments.find(session->core.get());
            if (attachment != bound_video_pipeline->attachments.end()) {
                if (attachment->second.preview_publisher &&
                        bound_video_pipeline->capture_owner_publication_token == 0)
                    invalidate_video_source_locked(bound_video_pipeline.get());
                if (attachment->second.publication_token ==
                        bound_video_pipeline->capture_owner_publication_token) {
                    invalidate_video_source_locked(bound_video_pipeline.get());
                    pipeline_capture_module =
                        bound_video_pipeline->video_capture_module;
                    bound_video_pipeline->video_capture_module = nullptr;
                    pipeline_capture_sink =
                        std::move(bound_video_pipeline->video_capture_sink);
                    bound_video_pipeline->capture_owner_publication_token = 0;
                }
                bound_video_pipeline->attachments.erase(attachment);
            }
        }
    }
    stop_video_capture_module(pipeline_capture_module.get());
    pipeline_capture_sink.reset();
    pipeline_capture_module = nullptr;

    stop_video_capture_module(local_video_capture_module.get());
    local_video_capture_sink.reset();
    local_video_capture_module = nullptr;

    for (const auto& binding : remote_audio_sinks) {
        if (binding.track != nullptr && binding.sink != nullptr) {
            binding.track->RemoveSink(binding.sink.get());
        }
    }
    for (const auto& binding : remote_video_sinks) {
        if (binding.track != nullptr && binding.sink != nullptr) {
            binding.track->RemoveSink(binding.sink.get());
        }
    }

    if (peer_connection != nullptr) {
        if (rtc_event_log_started) {
            peer_connection->StopRtcEventLog();
        }
        peer_connection->Close();
    }
    session->observer = nullptr;
    if (context != nullptr) {
        context->release_session();
    }
    return DINOX_WEBRTC_STATUS_OK;
}
