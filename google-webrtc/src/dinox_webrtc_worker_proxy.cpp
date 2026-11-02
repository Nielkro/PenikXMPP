#include "dinox_webrtc_worker_proxy.hpp"

#include "dinox_webrtc_ipc.h"
#include "dinox_webrtc_video_ring.hpp"
#include "dinox_webrtc_windows_pipe.hpp"
#include "dinox_webrtc_video_background_protocol.hpp"

#include <atomic>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifndef DINOX_WEBRTC_INSTALLED_WORKER_PATH
#define DINOX_WEBRTC_INSTALLED_WORKER_PATH "dinox-webrtc-worker"
#endif

namespace dinox::webrtc_worker {
class Context;

namespace {

constexpr auto kRequestTimeout = std::chrono::seconds(5);
constexpr auto kDiagnosticsRequestTimeout = std::chrono::milliseconds(500);
constexpr auto kShutdownTimeout = std::chrono::seconds(2);
std::atomic<bool> internal_worker_mode{false};

void proxy_device_debug(const char* phase, const std::string& detail) {
    const char* enabled = std::getenv("DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG");
    if (enabled == nullptr ||
            (std::strcmp(enabled, "1") != 0 &&
             std::strcmp(enabled, "true") != 0 &&
             std::strcmp(enabled, "yes") != 0)) {
        return;
    }

    const char* path = std::getenv("DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG_FILE");
    FILE* output = stderr;
    if (path != nullptr && path[0] != '\0') {
        FILE* file = std::fopen(path, "a");
        if (file != nullptr) output = file;
    }
    std::fprintf(
        output,
        "DinoX WebRTC proxy: phase=%s detail=%s\n",
        phase == nullptr ? "unknown" : phase,
        detail.c_str());
    std::fflush(output);
    if (output != stderr) std::fclose(output);
}

void append_u32(std::vector<uint8_t>* payload, uint32_t value) {
    for (unsigned int byte = 0; byte < 4; ++byte) {
        payload->push_back(static_cast<uint8_t>((value >> (byte * 8)) & 0xffu));
    }
}

void append_u64(std::vector<uint8_t>* payload, uint64_t value) {
    for (unsigned int byte = 0; byte < 8; ++byte) {
        payload->push_back(static_cast<uint8_t>((value >> (byte * 8)) & 0xffu));
    }
}

uint32_t read_u32(const uint8_t* input) {
    return static_cast<uint32_t>(input[0]) |
        (static_cast<uint32_t>(input[1]) << 8) |
        (static_cast<uint32_t>(input[2]) << 16) |
        (static_cast<uint32_t>(input[3]) << 24);
}

uint64_t read_u64(const uint8_t* input) {
    uint64_t value = 0;
    for (unsigned int byte = 0; byte < 8; ++byte) {
        value |= static_cast<uint64_t>(input[byte]) << (byte * 8);
    }
    return value;
}

bool valid_status(uint32_t value) {
    return value <= static_cast<uint32_t>(DINOX_WEBRTC_STATUS_PARSE_ERROR);
}

bool valid_sdp_type(uint32_t value) {
    return value <= static_cast<uint32_t>(DINOX_WEBRTC_SDP_TYPE_ANSWER);
}

bool valid_recorder_state(uint32_t value) {
    return value <= static_cast<uint32_t>(DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED);
}

bool has_embedded_nul(
    const std::vector<uint8_t>& payload,
    size_t begin = 0) {
    return begin > payload.size() ||
        std::find(payload.begin() + begin, payload.end(), uint8_t{0}) != payload.end();
}

#ifdef _WIN32
using dinox::webrtc_windows_pipe::read_exact;
using dinox::webrtc_windows_pipe::write_exact;

std::wstring worker_path() {
    const wchar_t* override_path = _wgetenv(L"DINOX_WEBRTC_WORKER_PATH");
    if (override_path != nullptr && override_path[0] != L'\0') return override_path;
    HMODULE module = nullptr;
    wchar_t module_path[32768] = {};
    if (GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&should_use_process_engine), &module) &&
            GetModuleFileNameW(module, module_path, 32768) > 0) {
        std::filesystem::path sibling =
            std::filesystem::path(module_path).parent_path() / L"dinox-webrtc-worker.exe";
        if (std::filesystem::exists(sibling)) return sibling.wstring();
    }
    return std::filesystem::path(DINOX_WEBRTC_INSTALLED_WORKER_PATH).wstring();
}
#else
bool read_exact(int fd, void* output, size_t size) {
    auto* cursor = static_cast<uint8_t*>(output);
    while (size > 0) {
        const ssize_t count = read(fd, cursor, size);
        if (count == 0) return false;
        if (count < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        cursor += static_cast<size_t>(count);
        size -= static_cast<size_t>(count);
    }
    return true;
}

bool write_exact(int fd, const void* input, size_t size) {
    const auto* cursor = static_cast<const uint8_t*>(input);
    while (size > 0) {
        const ssize_t count = write(fd, cursor, size);
        if (count < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        cursor += static_cast<size_t>(count);
        size -= static_cast<size_t>(count);
    }
    return true;
}

std::string worker_path() {
    const char* override_path = std::getenv("DINOX_WEBRTC_WORKER_PATH");
    if (override_path != nullptr && override_path[0] != '\0') return override_path;

    Dl_info info = {};
    if (dladdr(reinterpret_cast<void*>(&should_use_process_engine), &info) != 0 &&
            info.dli_fname != nullptr) {
        std::filesystem::path sibling =
            std::filesystem::path(info.dli_fname).parent_path() / "dinox-webrtc-worker";
        if (access(sibling.c_str(), X_OK) == 0) return sibling.string();
    }
    return DINOX_WEBRTC_INSTALLED_WORKER_PATH;
}
#endif

struct Reply {
    DinoXWebrtcStatus status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    std::vector<uint8_t> payload;
    std::function<void(DinoXWebrtcStatus)> completion;
    std::chrono::steady_clock::time_point deadline = {};
    DinoXWebrtcIpcMessageType request_type = DINOX_WEBRTC_IPC_MESSAGE_ERROR;
    bool timeout_claimed = false;
    bool complete = false;
};

struct VideoFrameDeliveryContext {
    DinoXWebrtcVideoFrameCallback callback = nullptr;
    DinoXWebrtcSession* session = nullptr;
    void* user_data = nullptr;
};

void deliver_video_frame_view(const VideoFrameView* frame, void* user_data) {
    auto* delivery = static_cast<VideoFrameDeliveryContext*>(user_data);
    if (frame == nullptr || delivery == nullptr || delivery->callback == nullptr) return;
    delivery->callback(
        delivery->session,
        frame->pixels,
        frame->width,
        frame->height,
        frame->stride,
        frame->frame_id,
        delivery->user_data);
}

thread_local const Context* active_reader_context = nullptr;

}  // namespace

class Session final {
 public:
    uint64_t id = 0;
    uint64_t generation = 0;
    DinoXWebrtcCallbacks callbacks = {};
    void* user_data = nullptr;
    DinoXWebrtcSession* public_session = nullptr;
    std::shared_ptr<class Context> context;
    std::recursive_mutex callback_mutex;
    std::atomic<uint64_t> local_video_fence_count{0};
    std::atomic<bool> closed{false};
};

class Recorder final {
 public:
    uint64_t id = 0;
    uint64_t generation = 0;
    DinoXWebrtcMediaRecorderCallbacks callbacks = {};
    void* user_data = nullptr;
    DinoXWebrtcMediaRecorder* public_recorder = nullptr;
    std::shared_ptr<class Context> context;
    std::recursive_mutex callback_mutex;
    DinoXWebrtcMediaRecorderState state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE;
    bool closed = false;
};

class VideoPipeline final {
 public:
    uint64_t id = 0;
    uint64_t generation = 0;
    uint64_t logical_call_id = 0;
    DinoXWebrtcVideoPipelineCallbacks callbacks = {};
    void* user_data = nullptr;
    DinoXWebrtcVideoPipeline* public_pipeline = nullptr;
    std::shared_ptr<class Context> context;
    std::recursive_mutex callback_mutex;
    std::mutex control_mutex;
    std::mutex background_control_mutex;
    std::unordered_map<uint64_t, uint64_t> subscriber_generations;
    std::unordered_map<uint64_t, uint64_t> attached_subscribers;
    std::unordered_set<uint64_t> preview_subscribers;
    bool control_request_in_flight = false;
    uint64_t control_request_session_id = 0;
    bool in_flight_preview_publisher = false;
    bool in_flight_session_closed = false;
    std::atomic<bool> closed{false};
};

class Context final : public std::enable_shared_from_this<Context> {
 public:
    Context() = default;
    ~Context() { stop(); }

    DinoXWebrtcStatus start(DinoXWebrtcAudioDeviceMode mode) {
        std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
        return start_locked(mode);
    }

    DinoXWebrtcStatus start_locked(DinoXWebrtcAudioDeviceMode mode) {
        mode_ = mode;
        intentional_stop_.store(false);
        active_failure_reported_.store(false);
        {
            std::lock_guard<std::mutex> lock(failure_detail_mutex_);
            failure_detail_.clear();
        }
#ifdef _WIN32
        video_ring_size_ = video_ring_size();
        SECURITY_ATTRIBUTES security = {};
        security.nLength = sizeof(security);
        security.bInheritHandle = TRUE;
        video_mapping_ = CreateFileMappingA(
            INVALID_HANDLE_VALUE,
            &security,
            PAGE_READWRITE,
            static_cast<DWORD>((static_cast<uint64_t>(video_ring_size_) >> 32) & 0xffffffffu),
            static_cast<DWORD>(video_ring_size_ & 0xffffffffu),
            nullptr);
        if (video_mapping_ == nullptr) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        video_ring_ = MapViewOfFile(video_mapping_, FILE_MAP_ALL_ACCESS, 0, 0, video_ring_size_);
        if (video_ring_ == nullptr || !initialize_video_ring(video_ring_, video_ring_size_)) {
            if (video_ring_ != nullptr) UnmapViewOfFile(video_ring_);
            video_ring_ = nullptr;
            CloseHandle(video_mapping_);
            video_mapping_ = nullptr;
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        static std::atomic<uint64_t> pipe_counter{1};
        const std::string pipe_name = "\\\\.\\pipe\\dinox-webrtc-" +
            std::to_string(GetCurrentProcessId()) + "-" +
            std::to_string(pipe_counter.fetch_add(1));
        pipe_ = CreateNamedPipeA(
            pipe_name.c_str(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            64 * 1024,
            64 * 1024,
            5000,
            nullptr);
        if (pipe_ == INVALID_HANDLE_VALUE) {
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        const std::wstring path = worker_path();
        const std::wstring pipe_name_wide(pipe_name.begin(), pipe_name.end());
        std::wstring command = L"\"" + path + L"\" --control-pipe \"" + pipe_name_wide +
            L"\" --video-map-handle " +
            std::to_wstring(reinterpret_cast<uintptr_t>(video_mapping_));
        std::vector<wchar_t> command_line(command.begin(), command.end());
        command_line.push_back(L'\0');
        SIZE_T attribute_size = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
        if (attribute_size == 0) {
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        std::vector<uint8_t> attribute_storage(attribute_size);
        STARTUPINFOEXW startup = {};
        startup.StartupInfo.cb = sizeof(startup);
        startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
            attribute_storage.data());
        if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attribute_size)) {
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        HANDLE inherited_handles[] = {video_mapping_};
        if (!UpdateProcThreadAttribute(
                startup.lpAttributeList,
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                inherited_handles,
                sizeof(inherited_handles),
                nullptr,
                nullptr)) {
            DeleteProcThreadAttributeList(startup.lpAttributeList);
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        PROCESS_INFORMATION process = {};
        const BOOL process_created = CreateProcessW(
                path.c_str(), command_line.data(), nullptr, nullptr, TRUE,
                CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
                nullptr, nullptr, &startup.StartupInfo, &process);
        DeleteProcThreadAttributeList(startup.lpAttributeList);
        if (!process_created) {
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        process_ = process.hProcess;

        job_ = CreateJobObjectA(nullptr, nullptr);
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_limits = {};
        job_limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (job_ == nullptr ||
                !SetInformationJobObject(
                    job_, JobObjectExtendedLimitInformation, &job_limits, sizeof(job_limits)) ||
                !AssignProcessToJobObject(job_, process_)) {
            TerminateProcess(process_, 87);
            CloseHandle(process.hThread);
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        if (ResumeThread(process.hThread) == static_cast<DWORD>(-1)) {
            TerminateProcess(process_, 87);
            CloseHandle(process.hThread);
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        CloseHandle(process.hThread);

        const bool connected = dinox::webrtc_windows_pipe::connect_server(
            pipe_, process_, static_cast<DWORD>(
                std::chrono::duration_cast<std::chrono::milliseconds>(kRequestTimeout).count()));
        if (!connected) {
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        running_.store(true);
        reader_ = std::thread([this] { reader_loop(); });
        start_async_watchdog();

        const size_t handshake_size = dinox_webrtc_ipc_build_handshake(nullptr, 0);
        std::vector<char> handshake(handshake_size + 1, '\0');
        if (handshake_size == 0 ||
                dinox_webrtc_ipc_build_handshake(handshake.data(), handshake.size()) != handshake_size) {
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        DinoXWebrtcStatus status = request(
            DINOX_WEBRTC_IPC_MESSAGE_HELLO, 0, 0,
            handshake.data(), static_cast<uint32_t>(handshake_size));
        if (status == DINOX_WEBRTC_STATUS_OK) {
            const uint8_t payload[4] = {static_cast<uint8_t>(mode), 0, 0, 0};
            status = request(
                DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CREATE, 0, 0, payload, sizeof(payload));
        }
        if (status != DINOX_WEBRTC_STATUS_OK) stop_locked();
        return status;
#else
        video_ring_size_ = video_ring_size();
        int video_shm_fd = -1;
#ifdef SYS_memfd_create
        video_shm_fd = static_cast<int>(syscall(SYS_memfd_create, "dinox-webrtc-video", 0));
#endif
        if (video_shm_fd < 0) {
            char temporary[] = "/tmp/dinox-webrtc-video-XXXXXX";
            video_shm_fd = mkstemp(temporary);
            if (video_shm_fd >= 0) unlink(temporary);
        }
        if (video_shm_fd < 0 || ftruncate(video_shm_fd, static_cast<off_t>(video_ring_size_)) != 0) {
            if (video_shm_fd >= 0) close(video_shm_fd);
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        video_ring_ = mmap(
            nullptr, video_ring_size_, PROT_READ | PROT_WRITE, MAP_SHARED, video_shm_fd, 0);
        if (video_ring_ == MAP_FAILED || !initialize_video_ring(video_ring_, video_ring_size_)) {
            if (video_ring_ != MAP_FAILED) munmap(video_ring_, video_ring_size_);
            video_ring_ = nullptr;
            close(video_shm_fd);
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }

        int sockets[2] = {-1, -1};
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
            munmap(video_ring_, video_ring_size_);
            video_ring_ = nullptr;
            close(video_shm_fd);
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        const pid_t child = fork();
        if (child == 0) {
            close(sockets[0]);
            std::string fd = std::to_string(sockets[1]);
            std::string shm_fd = std::to_string(video_shm_fd);
            const std::string path = worker_path();
            execl(
                path.c_str(), path.c_str(), "--control-fd", fd.c_str(),
                "--video-shm-fd", shm_fd.c_str(), nullptr);
            _exit(127);
        }
        close(sockets[1]);
        close(video_shm_fd);
        if (child < 0) {
            close(sockets[0]);
            munmap(video_ring_, video_ring_size_);
            video_ring_ = nullptr;
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        fd_ = sockets[0];
        {
            std::lock_guard<std::mutex> lock(child_mutex_);
            pid_ = child;
        }
        running_.store(true);
        reader_ = std::thread([this] { reader_loop(); });
        start_async_watchdog();

        const size_t handshake_size = dinox_webrtc_ipc_build_handshake(nullptr, 0);
        std::vector<char> handshake(handshake_size + 1, '\0');
        if (handshake_size == 0 ||
                dinox_webrtc_ipc_build_handshake(handshake.data(), handshake.size()) != handshake_size) {
            stop_locked();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        DinoXWebrtcStatus status = request(
            DINOX_WEBRTC_IPC_MESSAGE_HELLO,
            0,
            0,
            handshake.data(),
            static_cast<uint32_t>(handshake_size));
        if (status == DINOX_WEBRTC_STATUS_OK) {
            uint8_t payload[4] = {
                static_cast<uint8_t>(mode), 0, 0, 0,
            };
            status = request(
                DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CREATE,
                0,
                0,
                payload,
                sizeof(payload));
        }
        if (status != DINOX_WEBRTC_STATUS_OK) stop_locked();
        return status;
#endif
    }

    void stop() {
        std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
        stop_locked();
    }

    void stop_locked() {
        intentional_stop_.store(true);
        stop_async_watchdog();
#ifdef _WIN32
        if (pipe_ == INVALID_HANDLE_VALUE && process_ == nullptr && job_ == nullptr &&
                video_mapping_ == nullptr) return;
        if (running_.load()) {
            request(
                DINOX_WEBRTC_IPC_MESSAGE_SHUTDOWN,
                0, 0, nullptr, 0, kShutdownTimeout);
        }
        running_.store(false);
        if (pipe_ != INVALID_HANDLE_VALUE) {
            CancelIoEx(pipe_, nullptr);
        }
        if (reader_.joinable() && reader_.get_id() != std::this_thread::get_id()) reader_.join();
        if (pipe_ != INVALID_HANDLE_VALUE) {
            DisconnectNamedPipe(pipe_);
            CloseHandle(pipe_);
            pipe_ = INVALID_HANDLE_VALUE;
        }
        if (process_ != nullptr) {
            if (WaitForSingleObject(process_, 2000) == WAIT_TIMEOUT) {
                TerminateProcess(process_, 87);
                WaitForSingleObject(process_, 2000);
            }
            CloseHandle(process_);
            process_ = nullptr;
        }
        if (job_ != nullptr) {
            CloseHandle(job_);
            job_ = nullptr;
        }
        fail_pending();
        if (video_ring_ != nullptr) {
            UnmapViewOfFile(video_ring_);
            video_ring_ = nullptr;
        }
        if (video_mapping_ != nullptr) {
            CloseHandle(video_mapping_);
            video_mapping_ = nullptr;
        }
        video_ring_size_ = 0;
#else
        {
            std::lock_guard<std::mutex> lock(child_mutex_);
            if (fd_ < 0 && pid_ <= 0) return;
        }
        if (running_.load()) {
            request(
                DINOX_WEBRTC_IPC_MESSAGE_SHUTDOWN,
                0,
                0,
                nullptr,
                0,
                kShutdownTimeout);
        }
        running_.store(false);
        if (fd_ >= 0) {
            shutdown(fd_, SHUT_RDWR);
            close(fd_);
            fd_ = -1;
        }
        if (reader_.joinable() && reader_.get_id() != std::this_thread::get_id()) {
            reader_.join();
        }
        {
            std::lock_guard<std::mutex> lock(child_mutex_);
            if (pid_ > 0) {
            int status = 0;
            const pid_t result = waitpid(pid_, &status, WNOHANG);
            if (result == 0) {
                kill(pid_, SIGTERM);
                for (unsigned int attempt = 0; attempt < 20; ++attempt) {
                    if (waitpid(pid_, &status, WNOHANG) == pid_) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                }
                if (waitpid(pid_, &status, WNOHANG) == 0) {
                    kill(pid_, SIGKILL);
                    waitpid(pid_, &status, 0);
                }
            }
            pid_ = -1;
            }
        }
        fail_pending();
        if (video_ring_ != nullptr) {
            munmap(video_ring_, video_ring_size_);
            video_ring_ = nullptr;
            video_ring_size_ = 0;
        }
#endif
    }

    DinoXWebrtcStatus restart_for_new_operation() {
        if (running_.load()) return DINOX_WEBRTC_STATUS_OK;
        std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
        if (running_.load()) return DINOX_WEBRTC_STATUS_OK;
        stop_locked();
        return start_locked(mode_);
    }

    DinoXWebrtcStatus create_session(
        const DinoXWebrtcSessionConfig* config,
        const DinoXWebrtcCallbacks* callbacks,
        void* user_data,
        DinoXWebrtcSession* public_session,
        std::shared_ptr<Session>* out_session) {
        if (config == nullptr || callbacks == nullptr || out_session == nullptr) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        auto session = std::make_shared<Session>();
        session->id = next_session_id_.fetch_add(1);
        session->generation = 1;
        session->callbacks = *callbacks;
        session->user_data = user_data;
        session->public_session = public_session;
        session->context = shared_from_this();
        DinoXWebrtcIpcSessionConfig wire = {};
        wire.abi_version = config->abi_version;
        wire.audio_enabled = config->audio_enabled != 0;
        wire.video_enabled = config->video_enabled != 0;
        wire.audio_direction = static_cast<uint32_t>(config->audio_direction);
        wire.video_direction = static_cast<uint32_t>(config->video_direction);
        wire.defer_audio_transceiver_until_answer = config->defer_audio_transceiver_until_answer != 0;
        wire.defer_video_transceiver_until_answer = config->defer_video_transceiver_until_answer != 0;
        wire.ice_candidate_pool_size = config->ice_candidate_pool_size;
        wire.max_bundle = config->max_bundle != 0;
        wire.network_policy = static_cast<uint32_t>(config->network_policy);
        uint8_t payload[DINOX_WEBRTC_IPC_SESSION_CONFIG_SIZE] = {};
        if (dinox_webrtc_ipc_encode_session_config(&wire, payload, sizeof(payload)) !=
                DINOX_WEBRTC_IPC_VALIDATION_OK) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        {
            std::lock_guard<std::mutex> lock(sessions_mutex_);
            sessions_[session->id] = std::weak_ptr<Session>(session);
        }
        DinoXWebrtcStatus status = request(
            DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE,
            session->id,
            session->generation,
            payload,
            sizeof(payload));
        if (status != DINOX_WEBRTC_STATUS_OK) {
            std::lock_guard<std::mutex> lock(sessions_mutex_);
            sessions_.erase(session->id);
            return status;
        }
        *out_session = std::move(session);
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus create_recorder(
        const DinoXWebrtcMediaRecorderConfig* config,
        const DinoXWebrtcMediaRecorderCallbacks* callbacks,
        void* user_data,
        DinoXWebrtcMediaRecorder* public_recorder,
        std::shared_ptr<Recorder>* out_recorder) {
        if (config == nullptr || callbacks == nullptr || out_recorder == nullptr ||
                config->output_path == nullptr || config->mime_type == nullptr) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        auto recorder = std::make_shared<Recorder>();
        recorder->id = next_session_id_.fetch_add(1);
        recorder->generation = 1;
        recorder->callbacks = *callbacks;
        recorder->user_data = user_data;
        recorder->public_recorder = public_recorder;
        recorder->context = shared_from_this();
        const char* device = config->video_device_unique_id == nullptr ? "" : config->video_device_unique_id;
        const size_t path_size = std::strlen(config->output_path);
        const size_t mime_size = std::strlen(config->mime_type);
        const size_t device_size = std::strlen(device);
        if (path_size == 0 || mime_size == 0 || path_size > 65535 || mime_size > 65535 ||
                device_size > 65535 || path_size + mime_size + device_size + 32 >
                    DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        std::vector<uint8_t> payload;
        append_u32(&payload, static_cast<uint32_t>(config->kind));
        append_u32(&payload, static_cast<uint32_t>(config->width));
        append_u32(&payload, static_cast<uint32_t>(config->height));
        append_u32(&payload, static_cast<uint32_t>(config->max_fps));
        append_u32(&payload, static_cast<uint32_t>(config->include_audio_track != 0));
        append_u32(&payload, static_cast<uint32_t>(path_size));
        append_u32(&payload, static_cast<uint32_t>(mime_size));
        append_u32(&payload, static_cast<uint32_t>(device_size));
        payload.insert(payload.end(), config->output_path, config->output_path + path_size);
        payload.insert(payload.end(), config->mime_type, config->mime_type + mime_size);
        payload.insert(payload.end(), device, device + device_size);
        {
            std::lock_guard<std::mutex> lock(recorders_mutex_);
            recorders_[recorder->id] = std::weak_ptr<Recorder>(recorder);
        }
        DinoXWebrtcStatus status = request(
            DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CREATE,
            recorder->id,
            recorder->generation,
            payload.data(),
            static_cast<uint32_t>(payload.size()));
        if (status != DINOX_WEBRTC_STATUS_OK) {
            std::lock_guard<std::mutex> lock(recorders_mutex_);
            recorders_.erase(recorder->id);
            return status;
        }
        *out_recorder = std::move(recorder);
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus create_video_pipeline(
        uint64_t logical_call_id,
        const DinoXWebrtcVideoPipelineCallbacks* callbacks,
        void* user_data,
        DinoXWebrtcVideoPipeline* public_pipeline,
        std::shared_ptr<VideoPipeline>* out_pipeline) {
        if (logical_call_id == 0 || callbacks == nullptr || out_pipeline == nullptr ||
                callbacks->abi_version != DINOX_WEBRTC_ABI_VERSION) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        auto pipeline = std::make_shared<VideoPipeline>();
        pipeline->id = next_session_id_.fetch_add(1);
        pipeline->generation = 1;
        pipeline->logical_call_id = logical_call_id;
        pipeline->callbacks = *callbacks;
        pipeline->user_data = user_data;
        pipeline->public_pipeline = public_pipeline;
        pipeline->context = shared_from_this();
        uint8_t payload[8] = {};
        for (unsigned int byte = 0; byte < 8; ++byte) {
            payload[byte] = static_cast<uint8_t>((logical_call_id >> (byte * 8)) & 0xffu);
        }
        {
            std::lock_guard<std::mutex> lock(pipelines_mutex_);
            pipelines_[pipeline->id] = std::weak_ptr<VideoPipeline>(pipeline);
        }
        DinoXWebrtcStatus status = request(
            DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_CREATE,
            pipeline->id,
            pipeline->generation,
            payload,
            sizeof(payload));
        if (status != DINOX_WEBRTC_STATUS_OK) {
            std::lock_guard<std::mutex> lock(pipelines_mutex_);
            pipelines_.erase(pipeline->id);
            return status;
        }
        *out_pipeline = std::move(pipeline);
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus request(
        DinoXWebrtcIpcMessageType type,
        uint64_t session_id,
        uint64_t generation,
        const void* payload,
        uint32_t payload_size,
        std::chrono::milliseconds timeout = kRequestTimeout,
        std::vector<uint8_t>* out_payload = nullptr,
        bool terminate_on_timeout = true) {
        const bool may_start_worker = session_id == 0 ||
            type == DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE ||
            type == DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CREATE ||
            type == DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_CREATE;
        if (!running_.load() && may_start_worker) {
            DinoXWebrtcStatus restart_status = restart_for_new_operation();
            if (restart_status != DINOX_WEBRTC_STATUS_OK) return restart_status;
        }
        const bool transport_valid =
#ifdef _WIN32
            pipe_ != INVALID_HANDLE_VALUE;
#else
            fd_ >= 0;
#endif
        if (!running_.load() || !transport_valid ||
                payload_size > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD ||
                (payload_size > 0 && payload == nullptr)) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        const uint64_t request_id = next_request_id_.fetch_add(1);
        auto reply = std::make_shared<Reply>();
        {
            std::lock_guard<std::mutex> lock(pending_mutex_);
            pending_[request_id] = reply;
        }
        DinoXWebrtcIpcHeader header = dinox_webrtc_ipc_header_default(
            type,
            request_id,
            session_id,
            generation,
            payload_size);
        uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
        bool sent = dinox_webrtc_ipc_encode_header(&header, encoded, sizeof(encoded)) ==
                DINOX_WEBRTC_IPC_VALIDATION_OK;
        if (sent) {
            std::lock_guard<std::mutex> lock(write_mutex_);
            sent =
#ifdef _WIN32
                write_exact(pipe_, encoded, sizeof(encoded)) &&
                (payload_size == 0 || write_exact(pipe_, payload, payload_size));
#else
                write_exact(fd_, encoded, sizeof(encoded)) &&
                (payload_size == 0 || write_exact(fd_, payload, payload_size));
#endif
        }
        if (!sent) {
            {
                std::lock_guard<std::mutex> lock(pending_mutex_);
                pending_.erase(request_id);
            }
            running_.store(false);
#ifdef _WIN32
            if (pipe_ != INVALID_HANDLE_VALUE) CancelIoEx(pipe_, nullptr);
#else
            if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
#endif
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        std::unique_lock<std::mutex> lock(pending_mutex_);
        const bool completed = pending_cv_.wait_for(lock, timeout, [&] {
            return reply->complete || !running_.load();
        });
        pending_.erase(request_id);
        if (!completed || !reply->complete) {
            lock.unlock();
            if (!running_.load()) {
                return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            }
            if (!terminate_on_timeout) {
                return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            }
            terminate_worker_for_timeout(type);
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        if (out_payload != nullptr) *out_payload = reply->payload;
        return reply->status;
    }

    DinoXWebrtcStatus send_async(
        DinoXWebrtcIpcMessageType type,
        uint64_t session_id,
        uint64_t generation,
        const void* payload,
        uint32_t payload_size) {
        const bool transport_valid =
#ifdef _WIN32
            pipe_ != INVALID_HANDLE_VALUE;
#else
            fd_ >= 0;
#endif
        if (!running_.load() || !transport_valid || session_id == 0 || generation == 0 ||
                payload_size > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD ||
                (payload_size > 0 && payload == nullptr)) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        DinoXWebrtcIpcHeader header = dinox_webrtc_ipc_header_default(
            type, 0, session_id, generation, payload_size);
        header.flags = DINOX_WEBRTC_IPC_FLAG_ONEWAY;
        uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
        bool sent = dinox_webrtc_ipc_encode_header(&header, encoded, sizeof(encoded)) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK;
        if (sent) {
            std::lock_guard<std::mutex> lock(write_mutex_);
            sent =
#ifdef _WIN32
                write_exact(pipe_, encoded, sizeof(encoded)) &&
                (payload_size == 0 || write_exact(pipe_, payload, payload_size));
#else
                write_exact(fd_, encoded, sizeof(encoded)) &&
                (payload_size == 0 || write_exact(fd_, payload, payload_size));
#endif
        }
        if (!sent) {
            running_.store(false);
#ifdef _WIN32
            if (pipe_ != INVALID_HANDLE_VALUE) CancelIoEx(pipe_, nullptr);
#else
            if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
#endif
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus request_async(
        DinoXWebrtcIpcMessageType type,
        uint64_t session_id,
        uint64_t generation,
        const void* payload,
        uint32_t payload_size,
        std::function<void(DinoXWebrtcStatus)> completion) {
        const bool transport_valid =
#ifdef _WIN32
            pipe_ != INVALID_HANDLE_VALUE;
#else
            fd_ >= 0;
#endif
        if (!running_.load() || !transport_valid || session_id == 0 || generation == 0 ||
                payload_size > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD ||
                (payload_size > 0 && payload == nullptr) || !completion) {
            if (completion) completion(DINOX_WEBRTC_STATUS_NOT_READY);
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        const uint64_t request_id = next_request_id_.fetch_add(1);
        auto reply = std::make_shared<Reply>();
        reply->completion = std::move(completion);
        reply->deadline = std::chrono::steady_clock::now() + kRequestTimeout;
        reply->request_type = type;
        {
            std::lock_guard<std::mutex> lock(pending_mutex_);
            pending_[request_id] = reply;
            ++pending_revision_;
        }
        pending_cv_.notify_all();
        DinoXWebrtcIpcHeader header = dinox_webrtc_ipc_header_default(
            type, request_id, session_id, generation, payload_size);
        uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
        bool sent = dinox_webrtc_ipc_encode_header(&header, encoded, sizeof(encoded)) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK;
        if (sent) {
            std::lock_guard<std::mutex> lock(write_mutex_);
            sent =
#ifdef _WIN32
                write_exact(pipe_, encoded, sizeof(encoded)) &&
                (payload_size == 0 || write_exact(pipe_, payload, payload_size));
#else
                write_exact(fd_, encoded, sizeof(encoded)) &&
                (payload_size == 0 || write_exact(fd_, payload, payload_size));
#endif
        }
        if (!sent) {
            std::function<void(DinoXWebrtcStatus)> failed_completion;
            {
                std::lock_guard<std::mutex> lock(pending_mutex_);
                const auto found = pending_.find(request_id);
                if (found != pending_.end()) {
                    failed_completion = std::move(found->second->completion);
                    pending_.erase(found);
                    ++pending_revision_;
                }
            }
            pending_cv_.notify_all();
            running_.store(false);
#ifdef _WIN32
            if (pipe_ != INVALID_HANDLE_VALUE) CancelIoEx(pipe_, nullptr);
#else
            if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
#endif
            if (failed_completion) failed_completion(DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    bool is_reader_thread() const {
        return active_reader_context == this;
    }

    std::vector<std::shared_ptr<Session>> retain_sessions(
        const std::vector<uint64_t>& session_ids) {
        std::vector<std::shared_ptr<Session>> sessions;
        std::lock_guard<std::mutex> lock(sessions_mutex_);
        sessions.reserve(session_ids.size());
        for (uint64_t session_id : session_ids) {
            const auto found = sessions_.find(session_id);
            if (found == sessions_.end()) continue;
            std::shared_ptr<Session> session = found->second.lock();
            if (session != nullptr) sessions.push_back(std::move(session));
        }
        return sessions;
    }

    void remove_session(const std::shared_ptr<Session>& session) {
        if (session == nullptr) return;
        std::lock_guard<std::mutex> lock(sessions_mutex_);
        const auto found = sessions_.find(session->id);
        if (found != sessions_.end() && found->second.lock() == session) sessions_.erase(found);
    }

    void remove_session_from_video_pipelines(uint64_t session_id) {
        std::vector<std::shared_ptr<VideoPipeline>> pipelines;
        {
            std::lock_guard<std::mutex> lock(pipelines_mutex_);
            pipelines.reserve(pipelines_.size());
            for (const auto& [id, weak_pipeline] : pipelines_) {
                (void) id;
                std::shared_ptr<VideoPipeline> pipeline = weak_pipeline.lock();
                if (pipeline != nullptr) pipelines.push_back(std::move(pipeline));
            }
        }
        // Do not hold the registry lock while taking a per-pipeline control
        // lock: attach/detach may be waiting on IPC and teardown must remain
        // independent of reader-side event lookup.
        for (const auto& pipeline : pipelines) {
            std::lock_guard<std::mutex> lock(pipeline->control_mutex);
            pipeline->attached_subscribers.erase(session_id);
            pipeline->preview_subscribers.erase(session_id);
            pipeline->subscriber_generations.erase(session_id);
            if (pipeline->control_request_in_flight &&
                    pipeline->control_request_session_id == session_id) {
                pipeline->in_flight_session_closed = true;
            }
        }
    }

    void remove_recorder(const std::shared_ptr<Recorder>& recorder) {
        if (recorder == nullptr) return;
        std::lock_guard<std::mutex> lock(recorders_mutex_);
        const auto found = recorders_.find(recorder->id);
        if (found != recorders_.end() && found->second.lock() == recorder) recorders_.erase(found);
    }

    void remove_video_pipeline(const std::shared_ptr<VideoPipeline>& pipeline) {
        if (pipeline == nullptr) return;
        std::lock_guard<std::mutex> lock(pipelines_mutex_);
        const auto found = pipelines_.find(pipeline->id);
        if (found != pipelines_.end() && found->second.lock() == pipeline) {
            pipelines_.erase(found);
        }
    }

 private:
    void start_async_watchdog() {
        {
            std::lock_guard<std::mutex> lock(pending_mutex_);
            async_watchdog_stop_ = false;
            ++pending_revision_;
        }
        pending_cv_.notify_all();
        async_watchdog_ = std::thread([this] { async_watchdog_loop(); });
    }

    void stop_async_watchdog() {
        {
            std::lock_guard<std::mutex> lock(pending_mutex_);
            async_watchdog_stop_ = true;
            ++pending_revision_;
        }
        pending_cv_.notify_all();
        if (async_watchdog_.joinable() &&
                async_watchdog_.get_id() != std::this_thread::get_id()) {
            async_watchdog_.join();
        }
    }

    void async_watchdog_loop() {
        DinoXWebrtcIpcMessageType timed_out_type = DINOX_WEBRTC_IPC_MESSAGE_ERROR;
        {
            std::unique_lock<std::mutex> lock(pending_mutex_);
            while (!async_watchdog_stop_) {
                const auto now = std::chrono::steady_clock::now();
                std::shared_ptr<Reply> next_reply;
                auto next_deadline = std::chrono::steady_clock::time_point::max();
                for (const auto& [request_id, reply] : pending_) {
                    (void) request_id;
                    if (!reply->completion || reply->timeout_claimed) continue;
                    if (reply->deadline < next_deadline) {
                        next_deadline = reply->deadline;
                        next_reply = reply;
                    }
                }
                if (next_reply != nullptr && next_deadline <= now) {
                    // Claim the timeout while holding the same lock used by
                    // reply dispatch.  A reply wins or the watchdog wins;
                    // never both.  Keep the request pending so fail_pending()
                    // releases its lifecycle fence only after the reader has
                    // stopped and no queued event can escape.
                    next_reply->timeout_claimed = true;
                    timed_out_type = next_reply->request_type;
                    ++pending_revision_;
                    break;
                }
                const uint64_t revision = pending_revision_;
                if (next_reply == nullptr) {
                    pending_cv_.wait(lock, [&] {
                        return async_watchdog_stop_ || pending_revision_ != revision;
                    });
                } else {
                    pending_cv_.wait_until(lock, next_deadline, [&] {
                        return async_watchdog_stop_ || pending_revision_ != revision;
                    });
                }
            }
            if (async_watchdog_stop_) return;
        }
        terminate_worker_for_timeout(timed_out_type);
    }

    void reader_loop() {
        active_reader_context = this;
        while (running_.load()) {
            uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
            const bool header_read =
#ifdef _WIN32
                read_exact(pipe_, encoded, sizeof(encoded));
#else
                read_exact(fd_, encoded, sizeof(encoded));
#endif
            if (!header_read) break;
            DinoXWebrtcIpcHeader header = {};
            if (dinox_webrtc_ipc_decode_header(encoded, sizeof(encoded), &header) !=
                    DINOX_WEBRTC_IPC_VALIDATION_OK) break;
            std::vector<uint8_t> payload(header.payload_size);
            if (!payload.empty()) {
                const bool payload_read =
#ifdef _WIN32
                    read_exact(pipe_, payload.data(), payload.size());
#else
                    read_exact(fd_, payload.data(), payload.size());
#endif
                if (!payload_read) break;
            }
            if ((header.flags & DINOX_WEBRTC_IPC_FLAG_REPLY) != 0) {
                dispatch_reply(header, std::move(payload));
            } else if ((header.flags & DINOX_WEBRTC_IPC_FLAG_EVENT) != 0) {
                dispatch_event(header, payload);
            }
        }
        active_reader_context = nullptr;
        running_.store(false);
        fail_pending();
        std::string detail = worker_exit_detail();
        proxy_device_debug("reader-exit", detail);
        if (!intentional_stop_.load()) fail_active(detail.c_str());
    }

    void set_failure_detail(std::string detail) {
        std::lock_guard<std::mutex> lock(failure_detail_mutex_);
        failure_detail_ = std::move(detail);
    }

    void terminate_worker_for_timeout(DinoXWebrtcIpcMessageType type) {
        set_failure_detail(
            "worker-timeout:type=" + std::to_string(static_cast<uint32_t>(type)));
        running_.store(false);
#ifdef _WIN32
        if (pipe_ != INVALID_HANDLE_VALUE) CancelIoEx(pipe_, nullptr);
        if (process_ != nullptr) TerminateProcess(process_, 88);
#else
        if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
        terminate_child(SIGKILL);
#endif
    }

    std::string worker_exit_detail() {
        std::string detail;
        {
            std::lock_guard<std::mutex> lock(failure_detail_mutex_);
            detail = failure_detail_;
        }
#ifndef _WIN32
        pid_t child = -1;
        {
            std::lock_guard<std::mutex> lock(child_mutex_);
            child = pid_;
        }
        if (child > 0) {
            int status = 0;
            pid_t result = 0;
            // A worker that closed its control socket normally becomes
            // waitable immediately.  A timeout path sends SIGKILL first; give
            // the kernel a short bounded window to publish the wait status so
            // the failed call never leaves a zombie behind.
            for (unsigned int attempt = 0; attempt < 50; ++attempt) {
                result = waitpid(child, &status, WNOHANG);
                if (result != 0) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            if (result == child) {
                {
                    std::lock_guard<std::mutex> lock(child_mutex_);
                    if (pid_ == child) pid_ = -1;
                }
                if (detail.empty()) {
                    if (WIFSIGNALED(status)) {
                        detail = "worker-exited:signal=" + std::to_string(WTERMSIG(status));
                    } else if (WIFEXITED(status)) {
                        detail = "worker-exited:code=" + std::to_string(WEXITSTATUS(status));
                    }
                }
            }
        }
#else
        if (detail.empty() && process_ != nullptr) {
            DWORD exit_code = STILL_ACTIVE;
            if (GetExitCodeProcess(process_, &exit_code) && exit_code != STILL_ACTIVE) {
                detail = "worker-exited:code=" + std::to_string(exit_code);
            }
        }
#endif
        return detail.empty() ? "worker-exited" : detail;
    }

#ifndef _WIN32
    void terminate_child(int signal_number) {
        std::lock_guard<std::mutex> lock(child_mutex_);
        if (pid_ > 0) kill(pid_, signal_number);
    }
#endif

    void dispatch_reply(const DinoXWebrtcIpcHeader& header, std::vector<uint8_t> payload) {
        std::function<void(DinoXWebrtcStatus)> completion;
        DinoXWebrtcStatus completion_status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        {
            std::lock_guard<std::mutex> lock(pending_mutex_);
            const auto found = pending_.find(header.request_id);
            if (found == pending_.end()) return;
            std::shared_ptr<Reply> reply = found->second;
            if (reply->timeout_claimed) return;
            if (header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR) {
                const uint32_t raw_status = payload.size() >= 4
                    ? read_u32(payload.data())
                    : UINT32_MAX;
                reply->status = valid_status(raw_status)
                    ? static_cast<DinoXWebrtcStatus>(raw_status)
                    : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
                if (payload.size() > 4) reply->payload.assign(payload.begin() + 4, payload.end());
            } else if (payload.size() >= 4) {
                const uint32_t raw_status = read_u32(payload.data());
                reply->status = valid_status(raw_status)
                    ? static_cast<DinoXWebrtcStatus>(raw_status)
                    : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
                reply->payload.assign(payload.begin() + 4, payload.end());
            } else {
                reply->status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            }
            reply->complete = true;
            if (reply->completion) {
                completion = std::move(reply->completion);
                completion_status = reply->status;
                pending_.erase(found);
                ++pending_revision_;
            }
        }
        pending_cv_.notify_all();
        if (completion) completion(completion_status);
    }

    void dispatch_event(
        const DinoXWebrtcIpcHeader& header,
        const std::vector<uint8_t>& payload) {
        if (header.message_type == DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_PIPELINE_STATE) {
            dispatch_video_pipeline_event(header, payload);
            return;
        }
        if (header.message_type >= DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STARTED &&
                header.message_type <= DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_VIDEO_FRAME) {
            dispatch_recorder_event(header, payload);
            return;
        }
        const bool video_event =
            header.message_type == DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_FRAME ||
            header.message_type == DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_VIDEO_FRAME;
        const auto discard_video_event = [&] {
            if (video_event && payload.size() == 12) {
                discard_video_ring_frame(
                    video_ring_, video_ring_size_,
                    read_u32(payload.data()), read_u64(payload.data() + 4));
            }
        };
        std::shared_ptr<Session> session;
        {
            std::lock_guard<std::mutex> lock(sessions_mutex_);
            const auto found = sessions_.find(header.session_id);
            if (found == sessions_.end()) {
                discard_video_event();
                return;
            }
            session = found->second.lock();
            if (session == nullptr || session->generation != header.generation) {
                discard_video_event();
                return;
            }
        }
        std::lock_guard<std::recursive_mutex> lock(session->callback_mutex);
        if (session->closed) {
            discard_video_event();
            return;
        }
        switch (header.message_type) {
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION:
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION_PREPARED: {
                auto callback = header.message_type == DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION
                    ? session->callbacks.on_local_description
                    : session->callbacks.on_local_description_prepared;
                if (payload.size() > 4 && valid_sdp_type(read_u32(payload.data())) &&
                        !has_embedded_nul(payload, 4) &&
                        callback != nullptr) {
                    std::string sdp(payload.begin() + 4, payload.end());
                    callback(
                        session->public_session,
                        static_cast<DinoXWebrtcSdpType>(read_u32(payload.data())),
                        sdp.c_str(),
                        session->user_data);
                }
                break;
            }
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_REMOTE_DESCRIPTION_SET:
                if (payload.size() == 4 && valid_sdp_type(read_u32(payload.data())) &&
                        session->callbacks.on_remote_description_set != nullptr) {
                    session->callbacks.on_remote_description_set(
                        session->public_session,
                        static_cast<DinoXWebrtcSdpType>(read_u32(payload.data())),
                        session->user_data);
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_CANDIDATE:
                if (payload.size() > 8 && session->callbacks.on_ice_candidate != nullptr) {
                    const uint32_t mline = read_u32(payload.data());
                    const uint32_t mid_size = read_u32(payload.data() + 4);
                    if (mline <= static_cast<uint32_t>(INT32_MAX) &&
                            mid_size > 0 && mid_size < payload.size() - 8 &&
                            !has_embedded_nul(payload, 8)) {
                        std::string mid(payload.begin() + 8, payload.begin() + 8 + mid_size);
                        std::string candidate(payload.begin() + 8 + mid_size, payload.end());
                        session->callbacks.on_ice_candidate(
                            session->public_session,
                            mid.c_str(),
                            static_cast<int>(mline),
                            candidate.c_str(),
                            session->user_data);
                    }
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_GATHERING_COMPLETE:
                if (payload.empty() && session->callbacks.on_ice_gathering_complete != nullptr) {
                    session->callbacks.on_ice_gathering_complete(
                        session->public_session,
                        session->user_data);
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_SESSION_ERROR:
                if (payload.size() >= 4 && valid_status(read_u32(payload.data())) &&
                        !has_embedded_nul(payload, 4) &&
                        session->callbacks.on_error != nullptr) {
                    std::string detail(payload.begin() + 4, payload.end());
                    session->callbacks.on_error(
                        session->public_session,
                        static_cast<DinoXWebrtcStatus>(read_u32(payload.data())),
                        detail.c_str(),
                        session->user_data);
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_FRAME:
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_VIDEO_FRAME:
                if (payload.size() == 12) {
                    const bool local = header.message_type ==
                        DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_VIDEO_FRAME;
                    DinoXWebrtcVideoFrameCallback callback = local
                        ? session->callbacks.on_local_video_frame
                        : session->callbacks.on_video_frame;
                    if ((local && session->local_video_fence_count.load() > 0) ||
                            callback == nullptr) {
                        discard_video_event();
                    } else {
                        VideoFrameDeliveryContext delivery = {
                            callback,
                            session->public_session,
                            session->user_data,
                        };
                        with_video_ring_frame_view(
                            video_ring_,
                            video_ring_size_,
                            read_u32(payload.data()),
                            read_u64(payload.data() + 4),
                            session->id,
                            session->generation,
                            local ? VideoFrameKind::Local : VideoFrameKind::Remote,
                            deliver_video_frame_view,
                            &delivery);
                    }
                }
                break;
            default:
                break;
        }
    }

    void dispatch_video_pipeline_event(
        const DinoXWebrtcIpcHeader& header,
        const std::vector<uint8_t>& payload) {
        DinoXWebrtcVideoPipelineState state = {};
        if (dinox_webrtc_ipc_decode_video_pipeline_state(
                payload.data(), payload.size(), &state) != DINOX_WEBRTC_IPC_VALIDATION_OK ||
                state.pipeline_id != header.session_id ||
                state.pipeline_generation != header.generation) {
            return;
        }
        std::shared_ptr<VideoPipeline> pipeline;
        {
            std::lock_guard<std::mutex> lock(pipelines_mutex_);
            const auto found = pipelines_.find(header.session_id);
            if (found == pipelines_.end()) return;
            pipeline = found->second.lock();
            if (pipeline == nullptr || pipeline->generation != header.generation ||
                    pipeline->logical_call_id != state.logical_call_id) {
                return;
            }
        }
        std::lock_guard<std::recursive_mutex> lock(pipeline->callback_mutex);
        if (!pipeline->closed && pipeline->callbacks.on_state_changed != nullptr) {
            pipeline->callbacks.on_state_changed(
                pipeline->public_pipeline, &state, pipeline->user_data);
        }
    }

    void dispatch_recorder_event(
        const DinoXWebrtcIpcHeader& header,
        const std::vector<uint8_t>& payload) {
        const bool video_event =
            header.message_type == DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_VIDEO_FRAME;
        const auto discard_video_event = [&] {
            if (video_event && payload.size() == 12) {
                discard_video_ring_frame(
                    video_ring_, video_ring_size_,
                    read_u32(payload.data()), read_u64(payload.data() + 4));
            }
        };
        std::shared_ptr<Recorder> recorder;
        {
            std::lock_guard<std::mutex> lock(recorders_mutex_);
            const auto found = recorders_.find(header.session_id);
            if (found == recorders_.end()) {
                discard_video_event();
                return;
            }
            recorder = found->second.lock();
            if (recorder == nullptr || recorder->generation != header.generation) {
                discard_video_event();
                return;
            }
        }
        std::lock_guard<std::recursive_mutex> lock(recorder->callback_mutex);
        if (recorder->closed) {
            discard_video_event();
            return;
        }
        switch (header.message_type) {
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STARTED:
                if (!payload.empty()) break;
                recorder->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING;
                if (recorder->callbacks.on_started != nullptr) {
                    recorder->callbacks.on_started(recorder->public_recorder, recorder->user_data);
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STOPPED:
                if (!payload.empty()) break;
                recorder->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE;
                if (recorder->callbacks.on_stopped != nullptr) {
                    recorder->callbacks.on_stopped(recorder->public_recorder, recorder->user_data);
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_ERROR:
                if (payload.size() < 4 || !valid_status(read_u32(payload.data())) ||
                        has_embedded_nul(payload, 4)) break;
                recorder->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
                if (recorder->callbacks.on_error != nullptr) {
                    std::string detail(payload.begin() + 4, payload.end());
                    recorder->callbacks.on_error(
                        recorder->public_recorder,
                        static_cast<DinoXWebrtcStatus>(read_u32(payload.data())),
                        detail.c_str(),
                        recorder->user_data);
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_AUDIO_FRAME:
                if (payload.size() >= 24 && recorder->callbacks.on_audio_frame != nullptr) {
                    const uint32_t sample_rate = read_u32(payload.data());
                    const uint32_t channels = read_u32(payload.data() + 4);
                    const uint32_t bytes_per_sample = read_u32(payload.data() + 8);
                    const uint32_t byte_count = read_u32(payload.data() + 12);
                    const uint64_t block_size = static_cast<uint64_t>(channels) * bytes_per_sample;
                    if (sample_rate > 0 && sample_rate <= 384000 &&
                            channels > 0 && channels <= 32 &&
                            bytes_per_sample > 0 && bytes_per_sample <= 8 &&
                            block_size > 0 && byte_count > 0 &&
                            byte_count == payload.size() - 24 &&
                            byte_count % block_size == 0) {
                        recorder->callbacks.on_audio_frame(
                            recorder->public_recorder,
                            payload.data() + 24,
                            byte_count,
                            static_cast<int>(sample_rate),
                            static_cast<int>(channels),
                            static_cast<int>(bytes_per_sample),
                            read_u64(payload.data() + 16),
                            recorder->user_data);
                    }
                }
                break;
            case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_VIDEO_FRAME:
                if (payload.size() == 12 && recorder->callbacks.on_video_frame == nullptr) {
                    discard_video_event();
                } else if (payload.size() == 12) {
                    VideoFrame frame;
                    if (read_video_ring_frame(
                            video_ring_, video_ring_size_,
                            read_u32(payload.data()), read_u64(payload.data() + 4),
                            recorder->id, recorder->generation, VideoFrameKind::Recorder, &frame)) {
                        recorder->callbacks.on_video_frame(
                            recorder->public_recorder,
                            frame.pixels.data(), frame.width, frame.height, frame.stride,
                            frame.frame_id, recorder->user_data);
                    }
                }
                break;
            default:
                break;
        }
    }

    void fail_pending() {
        std::vector<std::function<void(DinoXWebrtcStatus)>> completions;
        {
            std::lock_guard<std::mutex> lock(pending_mutex_);
            bool removed_async_reply = false;
            for (auto iterator = pending_.begin(); iterator != pending_.end();) {
                std::shared_ptr<Reply> reply = iterator->second;
                reply->status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
                reply->complete = true;
                if (reply->completion) {
                    completions.push_back(std::move(reply->completion));
                    iterator = pending_.erase(iterator);
                    removed_async_reply = true;
                } else {
                    ++iterator;
                }
            }
            if (removed_async_reply) ++pending_revision_;
        }
        pending_cv_.notify_all();
        for (auto& completion : completions) {
            completion(DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
        }
    }

    void fail_active(const char* detail) {
        if (active_failure_reported_.exchange(true)) return;
        std::vector<std::shared_ptr<Session>> sessions;
        std::vector<std::shared_ptr<Recorder>> recorders;
        std::vector<std::shared_ptr<VideoPipeline>> pipelines;
        {
            std::lock_guard<std::mutex> lock(sessions_mutex_);
            for (const auto& [id, weak_session] : sessions_) {
                (void) id;
                std::shared_ptr<Session> session = weak_session.lock();
                if (session != nullptr) sessions.push_back(std::move(session));
            }
            sessions_.clear();
        }
        {
            std::lock_guard<std::mutex> lock(recorders_mutex_);
            for (const auto& [id, weak_recorder] : recorders_) {
                (void) id;
                std::shared_ptr<Recorder> recorder = weak_recorder.lock();
                if (recorder != nullptr) recorders.push_back(std::move(recorder));
            }
            recorders_.clear();
        }
        {
            std::lock_guard<std::mutex> lock(pipelines_mutex_);
            for (const auto& [id, weak_pipeline] : pipelines_) {
                (void) id;
                std::shared_ptr<VideoPipeline> pipeline = weak_pipeline.lock();
                if (pipeline != nullptr) pipelines.push_back(std::move(pipeline));
            }
            pipelines_.clear();
        }
        for (const auto& session : sessions) {
            std::lock_guard<std::recursive_mutex> lock(session->callback_mutex);
            if (session->closed) continue;
            session->closed = true;
            if (session->callbacks.on_error != nullptr) {
                session->callbacks.on_error(
                    session->public_session,
                    DINOX_WEBRTC_STATUS_INTERNAL_ERROR,
                    detail,
                    session->user_data);
            }
        }
        for (const auto& recorder : recorders) {
            std::lock_guard<std::recursive_mutex> lock(recorder->callback_mutex);
            if (recorder->closed) continue;
            recorder->closed = true;
            if (recorder->state == DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE ||
                    recorder->state == DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED) {
                // A completed recorder is no longer an active operation. Do
                // not turn an unrelated later worker failure into a second,
                // misleading recording error for its former UI consumer.
                recorder->callbacks = {};
                recorder->user_data = nullptr;
                recorder->public_recorder = nullptr;
                continue;
            }
            recorder->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
            if (recorder->callbacks.on_error != nullptr) {
                recorder->callbacks.on_error(
                    recorder->public_recorder,
                    DINOX_WEBRTC_STATUS_INTERNAL_ERROR,
                    detail,
                    recorder->user_data);
            }
        }
        for (const auto& pipeline : pipelines) {
            std::lock_guard<std::recursive_mutex> lock(pipeline->callback_mutex);
            pipeline->closed = true;
            pipeline->callbacks = {};
            pipeline->user_data = nullptr;
            pipeline->public_pipeline = nullptr;
        }
    }

#ifdef _WIN32
    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    HANDLE process_ = nullptr;
    HANDLE job_ = nullptr;
    HANDLE video_mapping_ = nullptr;
#else
    int fd_ = -1;
    pid_t pid_ = -1;
    std::mutex child_mutex_;
#endif
    std::atomic<bool> running_{false};
    std::atomic<bool> intentional_stop_{false};
    std::atomic<bool> active_failure_reported_{false};
    DinoXWebrtcAudioDeviceMode mode_ = DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC;
    std::mutex lifecycle_mutex_;
    std::mutex failure_detail_mutex_;
    std::string failure_detail_;
    std::atomic<uint64_t> next_request_id_{1};
    std::atomic<uint64_t> next_session_id_{1};
    std::thread reader_;
    std::mutex write_mutex_;
    std::mutex pending_mutex_;
    std::condition_variable pending_cv_;
    std::unordered_map<uint64_t, std::shared_ptr<Reply>> pending_;
    uint64_t pending_revision_ = 0;
    bool async_watchdog_stop_ = true;
    std::thread async_watchdog_;
    std::mutex sessions_mutex_;
    std::unordered_map<uint64_t, std::weak_ptr<Session>> sessions_;
    std::mutex recorders_mutex_;
    std::unordered_map<uint64_t, std::weak_ptr<Recorder>> recorders_;
    std::mutex pipelines_mutex_;
    std::unordered_map<uint64_t, std::weak_ptr<VideoPipeline>> pipelines_;
    void* video_ring_ = nullptr;
    size_t video_ring_size_ = 0;
};

bool should_use_process_engine() {
#ifdef DINOX_WEBRTC_ENABLE_IN_PROCESS_TEST_ORACLE
    const char* oracle = std::getenv("DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE");
    return !internal_worker_mode.load() &&
        !(oracle != nullptr && std::strcmp(oracle, "1") == 0);
#else
    return !internal_worker_mode.load();
#endif
}

void enter_internal_worker_mode() {
    internal_worker_mode.store(true);
}

DinoXWebrtcStatus context_new(
    DinoXWebrtcAudioDeviceMode mode,
    std::shared_ptr<Context>* out_context) {
    if (out_context == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    auto context = std::make_shared<Context>();
    DinoXWebrtcStatus status = context->start(mode);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    *out_context = std::move(context);
    return DINOX_WEBRTC_STATUS_OK;
}

void context_close(std::shared_ptr<Context>* context) {
    if (context != nullptr) context->reset();
}

namespace {

bool take_string(const std::vector<uint8_t>& payload, size_t* offset, std::string* value) {
    if (offset == nullptr || value == nullptr || *offset > payload.size() || payload.size() - *offset < 4) {
        return false;
    }
    const uint32_t size = read_u32(payload.data() + *offset);
    *offset += 4;
    if (size > payload.size() - *offset) return false;
    value->assign(payload.begin() + *offset, payload.begin() + *offset + size);
    *offset += size;
    return value->find('\0') == std::string::npos;
}

void copy_string(char* output, size_t output_size, const std::string& value) {
    if (output == nullptr || output_size == 0) return;
    std::snprintf(output, output_size, "%s", value.c_str());
}

DinoXWebrtcStatus audio_catalog(
    Context* context,
    int incoming,
    std::vector<uint8_t>* catalog) {
    if (context == nullptr || catalog == nullptr || (incoming != 0 && incoming != 1)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    uint8_t payload[4] = {static_cast<uint8_t>(incoming), 0, 0, 0};
    return context->request(
        DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_LIST,
        0, 0, payload, sizeof(payload), kRequestTimeout, catalog);
}

DinoXWebrtcStatus video_catalog(Context* context, std::vector<uint8_t>* catalog) {
    if (context == nullptr || catalog == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    return context->request(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_DEVICE_LIST,
        0, 0, nullptr, 0, kRequestTimeout, catalog);
}

}  // namespace

DinoXWebrtcStatus context_get_audio_device_count(Context* context, int incoming, int* out_count) {
    if (out_count == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> catalog;
    DinoXWebrtcStatus status = audio_catalog(context, incoming, &catalog);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (catalog.size() < 4 || read_u32(catalog.data()) > static_cast<uint32_t>(INT32_MAX)) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    *out_count = static_cast<int>(read_u32(catalog.data()));
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus context_get_audio_device_name(
    Context* context,
    int incoming,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_guid,
    size_t out_guid_size) {
    if (index < 0 || out_name == nullptr || out_name_size == 0 || out_guid == nullptr || out_guid_size == 0) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> catalog;
    DinoXWebrtcStatus status = audio_catalog(context, incoming, &catalog);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (catalog.size() < 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    const uint32_t count = read_u32(catalog.data());
    size_t offset = 4;
    for (uint32_t item = 0; item < count; ++item) {
        if (catalog.size() - offset < 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        const uint32_t item_index = read_u32(catalog.data() + offset);
        offset += 4;
        std::string name;
        std::string guid;
        if (!take_string(catalog, &offset, &name) || !take_string(catalog, &offset, &guid)) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        if (item_index == static_cast<uint32_t>(index)) {
            copy_string(out_name, out_name_size, name);
            copy_string(out_guid, out_guid_size, guid);
            return DINOX_WEBRTC_STATUS_OK;
        }
    }
    return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
}

DinoXWebrtcStatus context_set_audio_device(Context* context, int incoming, int index) {
    if (context == nullptr || (incoming != 0 && incoming != 1) || index < 0) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(incoming));
    append_u32(&payload, static_cast<uint32_t>(index));
    return context->request(
        DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_SELECT,
        0, 0, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus context_get_audio_device_volume(
    Context* context,
    int incoming,
    double* out_volume,
    int* out_available) {
    if (context == nullptr || out_volume == nullptr || out_available == nullptr ||
            (incoming != 0 && incoming != 1)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    uint8_t payload[4] = {static_cast<uint8_t>(incoming), 0, 0, 0};
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = context->request(
        DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_GET,
        0, 0, payload, sizeof(payload), kRequestTimeout, &reply);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (reply.size() != 12) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_available = read_u32(reply.data()) != 0;
    const uint64_t volume_bits = read_u64(reply.data() + 4);
    std::memcpy(out_volume, &volume_bits, sizeof(*out_volume));
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus context_set_audio_device_volume(Context* context, int incoming, double volume) {
    if (context == nullptr || (incoming != 0 && incoming != 1)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(incoming));
    uint64_t volume_bits = 0;
    std::memcpy(&volume_bits, &volume, sizeof(volume_bits));
    append_u64(&payload, volume_bits);
    return context->request(
        DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_SET,
        0, 0, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus context_play_test_tone(
    Context* context,
    char digit,
    unsigned int duration_ms) {
    if (context == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint8_t>(digit));
    append_u32(&payload, duration_ms);
    return context->request(
        DINOX_WEBRTC_IPC_MESSAGE_TEST_TONE_PLAY,
        0, 0, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus context_play_audio_test_clip(
    Context* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    unsigned int* out_duration_ms) {
    if (context == nullptr || pcm_data == nullptr || byte_count == 0 || out_duration_ms == nullptr ||
            byte_count + 12 > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(sample_rate));
    append_u32(&payload, static_cast<uint32_t>(channels));
    append_u32(&payload, static_cast<uint32_t>(bytes_per_sample));
    payload.insert(payload.end(), pcm_data, pcm_data + byte_count);
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = context->request(
        DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_CLIP_PLAY,
        0, 0, payload.data(), static_cast<uint32_t>(payload.size()), kRequestTimeout, &reply);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (reply.size() != 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_duration_ms = read_u32(reply.data());
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus context_stop_audio_test_playout(Context* context) {
    return context == nullptr ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT : context->request(
        DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_PLAYOUT_STOP,
        0, 0, nullptr, 0);
}

DinoXWebrtcStatus context_media_audio_playout_start(
    Context* context,
    int sample_rate,
    int channels,
    int bytes_per_sample) {
    if (context == nullptr || sample_rate <= 0 || channels <= 0 || bytes_per_sample <= 0) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(sample_rate));
    append_u32(&payload, static_cast<uint32_t>(channels));
    append_u32(&payload, static_cast<uint32_t>(bytes_per_sample));
    return context->request(
        DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_START,
        0, 0, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus context_media_audio_playout_push(
    Context* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    unsigned int* out_queued_duration_ms) {
    if (context == nullptr || pcm_data == nullptr || byte_count == 0 ||
            out_queued_duration_ms == nullptr ||
            byte_count > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = context->request(
        DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PUSH,
        0, 0, pcm_data, static_cast<uint32_t>(byte_count), kRequestTimeout, &reply);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (reply.size() != 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_queued_duration_ms = read_u32(reply.data());
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus context_media_audio_playout_set_paused(Context* context, int paused) {
    if (context == nullptr || (paused != 0 && paused != 1)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(paused));
    return context->request(
        DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PAUSE,
        0, 0, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus context_media_audio_playout_flush(Context* context) {
    return context == nullptr ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT : context->request(
        DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FLUSH,
        0, 0, nullptr, 0);
}

DinoXWebrtcStatus context_media_audio_playout_finish(
    Context* context,
    unsigned int* out_queued_duration_ms) {
    if (context == nullptr || out_queued_duration_ms == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = context->request(
        DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FINISH,
        0, 0, nullptr, 0, kRequestTimeout, &reply);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (reply.size() != 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_queued_duration_ms = read_u32(reply.data());
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus context_media_audio_playout_stop(Context* context) {
    return context == nullptr ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT : context->request(
        DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_STOP,
        0, 0, nullptr, 0);
}

DinoXWebrtcStatus context_get_video_device_count(Context* context, int* out_count) {
    if (out_count == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> catalog;
    DinoXWebrtcStatus status = video_catalog(context, &catalog);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (catalog.size() < 4 || read_u32(catalog.data()) > static_cast<uint32_t>(INT32_MAX)) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    *out_count = static_cast<int>(read_u32(catalog.data()));
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus context_get_video_device_name(
    Context* context,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_unique_id,
    size_t out_unique_id_size,
    char* out_product_id,
    size_t out_product_id_size) {
    if (index < 0 || out_name == nullptr || out_name_size == 0 ||
            out_unique_id == nullptr || out_unique_id_size == 0 ||
            out_product_id == nullptr || out_product_id_size == 0) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> catalog;
    DinoXWebrtcStatus status = video_catalog(context, &catalog);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (catalog.size() < 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    const uint32_t count = read_u32(catalog.data());
    size_t offset = 4;
    for (uint32_t item = 0; item < count; ++item) {
        if (catalog.size() - offset < 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        const uint32_t item_index = read_u32(catalog.data() + offset);
        offset += 4;
        std::string name;
        std::string unique_id;
        std::string product_id;
        if (!take_string(catalog, &offset, &name) ||
                !take_string(catalog, &offset, &unique_id) ||
                !take_string(catalog, &offset, &product_id)) {
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        if (item_index == static_cast<uint32_t>(index)) {
            copy_string(out_name, out_name_size, name);
            copy_string(out_unique_id, out_unique_id_size, unique_id);
            copy_string(out_product_id, out_product_id_size, product_id);
            return DINOX_WEBRTC_STATUS_OK;
        }
    }
    return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
}

DinoXWebrtcStatus context_get_video_effect_capabilities(
    Context* context,
    DinoXWebrtcVideoEffectCapabilities* out_capabilities) {
    if (context == nullptr || out_capabilities == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = context->request(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_EFFECT_CAPABILITIES_GET,
        0, 0, nullptr, 0, kRequestTimeout, &reply);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    return dinox_webrtc_ipc_decode_video_effect_capabilities(
        reply.data(), reply.size(), out_capabilities) == DINOX_WEBRTC_IPC_VALIDATION_OK
        ? DINOX_WEBRTC_STATUS_OK
        : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
}

DinoXWebrtcStatus context_inject_failure_for_test(Context* context, int failure_kind) {
    if (context == nullptr || (failure_kind != 1 && failure_kind != 2)) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    return context->request(
        failure_kind == 1
            ? DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_ABORT
            : DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_HANG,
        0, 0, nullptr, 0,
        failure_kind == 1 ? std::chrono::seconds(2) : std::chrono::milliseconds(100));
}

DinoXWebrtcStatus session_new(
    Context* context,
    const DinoXWebrtcSessionConfig* config,
    const DinoXWebrtcCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcSession* public_session,
    std::shared_ptr<Session>* out_session) {
    return context == nullptr
        ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT
        : context->create_session(config, callbacks, user_data, public_session, out_session);
}

void session_free(std::shared_ptr<Session>* session) {
    if (session == nullptr || *session == nullptr) return;
    session_close(session->get());
    (*session)->context->remove_session(*session);
    session->reset();
}

DinoXWebrtcStatus session_add_ice_server(
    Session* session,
    const char* url,
    const char* username,
    const char* credential) {
    if (session == nullptr || url == nullptr || username == nullptr || credential == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    const size_t url_size = std::strlen(url);
    const size_t username_size = std::strlen(username);
    const size_t credential_size = std::strlen(credential);
    if (url_size == 0 || url_size > 65535 || username_size > 65535 || credential_size > 65535 ||
            url_size + username_size + credential_size + 12 > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(url_size));
    append_u32(&payload, static_cast<uint32_t>(username_size));
    append_u32(&payload, static_cast<uint32_t>(credential_size));
    payload.insert(payload.end(), url, url + url_size);
    payload.insert(payload.end(), username, username + username_size);
    payload.insert(payload.end(), credential, credential + credential_size);
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_ICE_SERVER,
        session->id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_create_offer(Session* session) {
    return session == nullptr ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT : session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_OFFER, session->id, session->generation, nullptr, 0);
}

DinoXWebrtcStatus session_create_answer(Session* session) {
    return session == nullptr ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT : session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_ANSWER, session->id, session->generation, nullptr, 0);
}

DinoXWebrtcStatus session_prepare_local_description(Session* session, DinoXWebrtcSdpType type) {
    if (session == nullptr || !valid_sdp_type(static_cast<uint32_t>(type)) ||
            session->callbacks.on_local_description_prepared == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(type));
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_PREPARE_LOCAL_DESCRIPTION,
        session->id, session->generation, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_set_local_description(
    Session* session, DinoXWebrtcSdpType type, const char* sdp) {
    if (session == nullptr || sdp == nullptr || sdp[0] == '\0' ||
            !valid_sdp_type(static_cast<uint32_t>(type))) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(type));
    payload.insert(payload.end(), sdp, sdp + std::strlen(sdp));
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_LOCAL_DESCRIPTION,
        session->id, session->generation, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_set_remote_description(
    Session* session,
    DinoXWebrtcSdpType type,
    const char* sdp) {
    if (session == nullptr || sdp == nullptr || sdp[0] == '\0') return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(type));
    payload.insert(payload.end(), sdp, sdp + std::strlen(sdp));
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_REMOTE_DESCRIPTION,
        session->id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_add_remote_candidate(
    Session* session,
    const char* sdp_mid,
    int sdp_mline_index,
    const char* candidate) {
    if (session == nullptr || sdp_mid == nullptr || candidate == nullptr || sdp_mline_index < 0) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    const size_t mid_size = std::strlen(sdp_mid);
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(sdp_mline_index));
    append_u32(&payload, static_cast<uint32_t>(mid_size));
    payload.insert(payload.end(), sdp_mid, sdp_mid + mid_size);
    payload.insert(payload.end(), candidate, candidate + std::strlen(candidate));
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_REMOTE_CANDIDATE,
        session->id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_set_audio_enabled(Session* session, int enabled) {
    if (session == nullptr || (enabled != 0 && enabled != 1)) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    uint8_t payload[4] = {static_cast<uint8_t>(enabled), 0, 0, 0};
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_AUDIO_ENABLED,
        session->id, session->generation, payload, sizeof(payload));
}

DinoXWebrtcStatus session_set_video_enabled(Session* session, int enabled) {
    if (session == nullptr || (enabled != 0 && enabled != 1)) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    uint8_t payload[4] = {static_cast<uint8_t>(enabled), 0, 0, 0};
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_VIDEO_ENABLED,
        session->id, session->generation, payload, sizeof(payload));
}

DinoXWebrtcStatus session_send_dtmf(
    Session* session,
    char digit,
    unsigned int duration_ms,
    bool local_feedback) {
    if (session == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint8_t>(digit));
    append_u32(&payload, duration_ms);
    return session->context->send_async(
        local_feedback
            ? DINOX_WEBRTC_IPC_MESSAGE_SESSION_PLAY_DTMF_FEEDBACK
            : DINOX_WEBRTC_IPC_MESSAGE_SESSION_SEND_DTMF,
        session->id, session->generation, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_start_video_capture(
    Session* session,
    const char* device_unique_id,
    int width,
    int height,
    int max_fps) {
    if (session == nullptr || device_unique_id == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    const size_t id_size = std::strlen(device_unique_id);
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(width));
    append_u32(&payload, static_cast<uint32_t>(height));
    append_u32(&payload, static_cast<uint32_t>(max_fps));
    append_u32(&payload, static_cast<uint32_t>(id_size));
    payload.insert(payload.end(), device_unique_id, device_unique_id + id_size);
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_START,
        session->id, session->generation, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_stop_video_capture(Session* session) {
    return session == nullptr ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT : session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_STOP,
        session->id, session->generation, nullptr, 0);
}

DinoXWebrtcStatus session_push_synthetic_video(Session* session, int width, int height) {
    if (session == nullptr || width <= 0 || height <= 0) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(width));
    append_u32(&payload, static_cast<uint32_t>(height));
    return session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_PUSH_SYNTHETIC_VIDEO,
        session->id, session->generation, payload.data(), static_cast<uint32_t>(payload.size()));
}

DinoXWebrtcStatus session_get_state(Session* session, DinoXWebrtcSessionState* out_state) {
    if (session == nullptr || out_state == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = session->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_STATE_GET,
        session->id,
        session->generation,
        nullptr,
        0,
        kDiagnosticsRequestTimeout,
        &reply,
        false);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    return dinox_webrtc_ipc_decode_session_state(
        reply.data(), reply.size(), out_state) == DINOX_WEBRTC_IPC_VALIDATION_OK
        ? DINOX_WEBRTC_STATUS_OK
        : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
}

DinoXWebrtcStatus session_close(Session* session) {
    if (session == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    {
        std::lock_guard<std::recursive_mutex> lock(session->callback_mutex);
        if (session->closed) return DINOX_WEBRTC_STATUS_OK;
        session->closed = true;
    }
    DinoXWebrtcStatus status = session->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE,
        session->id, session->generation, nullptr, 0);
    session->context->remove_session_from_video_pipelines(session->id);
    {
        std::lock_guard<std::recursive_mutex> lock(session->callback_mutex);
        session->callbacks = {};
        session->user_data = nullptr;
        session->public_session = nullptr;
    }
    return status;
}

DinoXWebrtcStatus video_pipeline_new(
    Context* context,
    uint64_t logical_call_id,
    const DinoXWebrtcVideoPipelineCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcVideoPipeline* public_pipeline,
    std::shared_ptr<VideoPipeline>* out_pipeline) {
    return context == nullptr
        ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT
        : context->create_video_pipeline(
            logical_call_id, callbacks, user_data, public_pipeline, out_pipeline);
}

void video_pipeline_free(std::shared_ptr<VideoPipeline>* pipeline) {
    if (pipeline == nullptr || *pipeline == nullptr) return;
    std::shared_ptr<VideoPipeline> value = *pipeline;
    bool destroy = false;
    {
        std::lock_guard<std::recursive_mutex> callback_lock(value->callback_mutex);
        destroy = !value->closed.exchange(true);
        value->callbacks = {};
        value->user_data = nullptr;
        value->public_pipeline = nullptr;
    }
    std::vector<uint64_t> preview_session_ids;
    {
        std::lock_guard<std::mutex> control_lock(value->control_mutex);
        preview_session_ids.reserve(value->preview_subscribers.size());
        for (uint64_t session_id : value->preview_subscribers) {
            preview_session_ids.push_back(session_id);
        }
        if (value->control_request_in_flight && value->in_flight_preview_publisher &&
                value->control_request_session_id != 0 &&
                value->preview_subscribers.count(value->control_request_session_id) == 0) {
            preview_session_ids.push_back(value->control_request_session_id);
        }
        value->preview_subscribers.clear();
        value->attached_subscribers.clear();
    }
    std::vector<std::shared_ptr<Session>> fenced_sessions =
        value->context->retain_sessions(preview_session_ids);
    for (auto iterator = fenced_sessions.begin(); iterator != fenced_sessions.end();) {
        std::shared_ptr<Session> session = *iterator;
        bool session_closed = false;
        {
            std::lock_guard<std::recursive_mutex> callback_lock(session->callback_mutex);
            session_closed = session->closed;
            if (!session_closed) {
                session->local_video_fence_count.fetch_add(1);
            }
        }
        if (session_closed) {
            iterator = fenced_sessions.erase(iterator);
            continue;
        }
        ++iterator;
    }
    const auto release_preview_fences = [fenced_sessions](DinoXWebrtcStatus) {
        for (const auto& session : fenced_sessions) {
            std::lock_guard<std::recursive_mutex> callback_lock(session->callback_mutex);
            const uint64_t previous = session->local_video_fence_count.load();
            if (previous > 0) session->local_video_fence_count.fetch_sub(1);
        }
    };

    // The worker's destroy reply is an ordering barrier: pipeline destruction
    // joins its processor before replying, and events/replies share one ordered
    // transport.  Until that reply, discard local preview frames for sessions
    // which published this pipeline.  A callback can destroy its own pipeline
    // on the reader thread, so that special path registers an asynchronous
    // reply completion instead of blocking the reader on itself.
    if (destroy) {
        if (value->context->is_reader_thread()) {
            value->context->request_async(
                DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DESTROY,
                value->id, value->generation, nullptr, 0,
                release_preview_fences);
        } else {
            value->context->request(
                DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DESTROY,
                value->id, value->generation, nullptr, 0);
            release_preview_fences(DINOX_WEBRTC_STATUS_OK);
        }
    } else {
        release_preview_fences(DINOX_WEBRTC_STATUS_OK);
    }
    value->context->remove_video_pipeline(value);
    pipeline->reset();
}

DinoXWebrtcStatus video_pipeline_attach_session(
    VideoPipeline* pipeline,
    Session* session,
    int preview_publisher) {
    if (pipeline == nullptr || session == nullptr ||
            (preview_publisher != 0 && preview_publisher != 1) ||
            pipeline->context.get() != session->context.get()) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    uint64_t subscriber_generation = 0;
    bool was_attached = false;
    {
        std::lock_guard<std::mutex> lock(pipeline->control_mutex);
        if (pipeline->closed || session->closed || pipeline->control_request_in_flight) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        const auto active = pipeline->attached_subscribers.find(session->id);
        was_attached = active != pipeline->attached_subscribers.end();
        if (was_attached) {
            subscriber_generation = active->second;
        } else {
            const auto previous = pipeline->subscriber_generations.find(session->id);
            const uint64_t previous_generation = previous == pipeline->subscriber_generations.end()
                ? 0
                : previous->second;
            if (previous_generation == UINT64_MAX) return DINOX_WEBRTC_STATUS_NOT_READY;
            subscriber_generation = previous_generation + 1;
        }
        pipeline->control_request_in_flight = true;
        pipeline->control_request_session_id = session->id;
        pipeline->in_flight_preview_publisher = preview_publisher != 0;
        pipeline->in_flight_session_closed = false;
    }
    std::vector<uint8_t> payload;
    append_u64(&payload, session->id);
    append_u64(&payload, session->generation);
    append_u64(&payload, subscriber_generation);
    append_u32(&payload, static_cast<uint32_t>(preview_publisher));
    DinoXWebrtcStatus status = pipeline->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH,
        pipeline->id, pipeline->generation,
        payload.data(), static_cast<uint32_t>(payload.size()));
    {
        std::lock_guard<std::mutex> lock(pipeline->control_mutex);
        const bool invalidated = pipeline->in_flight_session_closed ||
            pipeline->closed || session->closed;
        pipeline->control_request_in_flight = false;
        pipeline->control_request_session_id = 0;
        pipeline->in_flight_preview_publisher = false;
        pipeline->in_flight_session_closed = false;
        if (status == DINOX_WEBRTC_STATUS_OK && !invalidated) {
            pipeline->subscriber_generations[session->id] = subscriber_generation;
            pipeline->attached_subscribers[session->id] = subscriber_generation;
            if (preview_publisher != 0) {
                pipeline->preview_subscribers.insert(session->id);
            } else {
                pipeline->preview_subscribers.erase(session->id);
            }
        } else if (invalidated) {
            status = DINOX_WEBRTC_STATUS_NOT_READY;
        }
    }
    return status;
}

DinoXWebrtcStatus video_pipeline_detach_session(VideoPipeline* pipeline, Session* session) {
    if (pipeline == nullptr || session == nullptr ||
            pipeline->context.get() != session->context.get()) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    uint64_t subscriber_generation = 0;
    {
        std::lock_guard<std::mutex> lock(pipeline->control_mutex);
        if (pipeline->closed || pipeline->control_request_in_flight) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        const auto active = pipeline->attached_subscribers.find(session->id);
        if (active == pipeline->attached_subscribers.end()) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        subscriber_generation = active->second;
        pipeline->control_request_in_flight = true;
        pipeline->control_request_session_id = session->id;
        pipeline->in_flight_preview_publisher = false;
        pipeline->in_flight_session_closed = false;
    }
    std::vector<uint8_t> payload;
    append_u64(&payload, session->id);
    append_u64(&payload, session->generation);
    append_u64(&payload, subscriber_generation);
    DinoXWebrtcStatus status = pipeline->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DETACH,
        pipeline->id, pipeline->generation,
        payload.data(), static_cast<uint32_t>(payload.size()));
    {
        std::lock_guard<std::mutex> lock(pipeline->control_mutex);
        const bool invalidated = pipeline->in_flight_session_closed || pipeline->closed;
        pipeline->control_request_in_flight = false;
        pipeline->control_request_session_id = 0;
        pipeline->in_flight_preview_publisher = false;
        pipeline->in_flight_session_closed = false;
        if (status == DINOX_WEBRTC_STATUS_OK) {
            pipeline->attached_subscribers.erase(session->id);
            pipeline->preview_subscribers.erase(session->id);
        } else if (invalidated) {
            status = DINOX_WEBRTC_STATUS_NOT_READY;
        }
    }
    return status;
}

DinoXWebrtcStatus video_pipeline_set_config(
    VideoPipeline* pipeline,
    const DinoXWebrtcVideoEffectConfig* config,
    uint64_t* out_revision) {
    if (pipeline == nullptr || config == nullptr || out_revision == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    uint8_t payload[DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE] = {};
    if (dinox_webrtc_ipc_encode_video_effect_config(config, payload, sizeof(payload)) !=
            DINOX_WEBRTC_IPC_VALIDATION_OK) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = pipeline->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG,
        pipeline->id, pipeline->generation,
        payload, sizeof(payload), kRequestTimeout, &reply);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (reply.size() != 8) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_revision = read_u64(reply.data());
    return *out_revision != 0 ? DINOX_WEBRTC_STATUS_OK : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
}

DinoXWebrtcStatus video_pipeline_get_state(
    VideoPipeline* pipeline,
    DinoXWebrtcVideoPipelineState* out_state) {
    if (pipeline == nullptr || out_state == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = pipeline->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET,
        pipeline->id, pipeline->generation, nullptr, 0,
        kDiagnosticsRequestTimeout, &reply, false);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (dinox_webrtc_ipc_decode_video_pipeline_state(
            reply.data(), reply.size(), out_state) != DINOX_WEBRTC_IPC_VALIDATION_OK ||
            out_state->pipeline_id != pipeline->id ||
            out_state->pipeline_generation != pipeline->generation ||
            out_state->logical_call_id != pipeline->logical_call_id) {
        return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    }
    return DINOX_WEBRTC_STATUS_OK;
}

DinoXWebrtcStatus video_pipeline_get_diagnostics(
    VideoPipeline* pipeline,
    DinoXWebrtcVideoEffectDiagnostics* out_diagnostics) {
    if (pipeline == nullptr || out_diagnostics == nullptr) {
        return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = pipeline->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DIAGNOSTICS_GET,
        pipeline->id, pipeline->generation, nullptr, 0,
        kDiagnosticsRequestTimeout, &reply, false);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    return dinox_webrtc_ipc_decode_video_effect_diagnostics(
        reply.data(), reply.size(), out_diagnostics) == DINOX_WEBRTC_IPC_VALIDATION_OK
        ? DINOX_WEBRTC_STATUS_OK
        : DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
}

// Background staging has its own serialized lane: chunks cannot interleave
// with another upload/builtin/release, while capture and reply reader continue.
DinoXWebrtcStatus video_pipeline_background_upload(VideoPipeline* pipeline,
    uint32_t width,uint32_t height,uint32_t stride,DinoXWebrtcBackgroundPixelFormat format,
    const uint8_t* pixels,size_t bytes,uint32_t* out_id) {
    if(!pipeline||!pixels||!out_id||!video_background_protocol::valid_upload(width,height,stride,
        uint32_t(format),bytes))return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::lock_guard serialized(pipeline->background_control_mutex);
    if(pipeline->closed.load())return DINOX_WEBRTC_STATUS_NOT_READY;
    std::vector<uint8_t> payload,reply;
    for(uint32_t field:{width,height,stride,uint32_t(format),uint32_t(bytes)})append_u32(&payload,field);
    auto status=pipeline->context->request(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,
        pipeline->id,pipeline->generation,payload.data(),uint32_t(payload.size()),kRequestTimeout,&reply);
    if(status!=DINOX_WEBRTC_STATUS_OK)return status;
    if(reply.size()!=8||read_u64(reply.data())==0)return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    const uint64_t ticket=read_u64(reply.data());
    const auto abort=[&]{std::vector<uint8_t> cancel;append_u64(&cancel,ticket);
        pipeline->context->request(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_ABORT,
            pipeline->id,pipeline->generation,cancel.data(),uint32_t(cancel.size()),kRequestTimeout);};
    for(size_t offset=0;offset<bytes;) {
        const size_t count=std::min(bytes-offset,video_background_protocol::kChunkBytes);
        payload.clear();append_u64(&payload,ticket);append_u32(&payload,uint32_t(offset));
        // Public upload owns the validated explicit buffer for this complete
        // synchronous controller operation; each copy is bounded to64KiB.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
        payload.insert(payload.end(),pixels+offset,pixels+offset+count);
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
        status=pipeline->context->request(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK,
            pipeline->id,pipeline->generation,payload.data(),uint32_t(payload.size()),kRequestTimeout);
        if(status!=DINOX_WEBRTC_STATUS_OK){abort();return status;}
        offset+=count;
    }
    payload.clear();append_u64(&payload,ticket);reply.clear();
    status=pipeline->context->request(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT,
        pipeline->id,pipeline->generation,payload.data(),uint32_t(payload.size()),kRequestTimeout,&reply);
    if(status!=DINOX_WEBRTC_STATUS_OK){abort();return status;}
    if(reply.size()!=4||read_u32(reply.data())==0)return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_id=read_u32(reply.data());return DINOX_WEBRTC_STATUS_OK;
}
DinoXWebrtcStatus video_pipeline_background_builtin(VideoPipeline* pipeline,
    DinoXWebrtcBackgroundBuiltin choice,uint32_t* out_id) {
    if(!pipeline||!out_id||uint32_t(choice)<1||uint32_t(choice)>10)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::lock_guard serialized(pipeline->background_control_mutex);
    std::vector<uint8_t> payload,reply;append_u32(&payload,uint32_t(choice));
    auto status=pipeline->context->request(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_BUILTIN,
        pipeline->id,pipeline->generation,payload.data(),uint32_t(payload.size()),kRequestTimeout,&reply);
    if(status!=DINOX_WEBRTC_STATUS_OK)return status;
    if(reply.size()!=4||read_u32(reply.data())==0)return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_id=read_u32(reply.data());return DINOX_WEBRTC_STATUS_OK;
}
DinoXWebrtcStatus video_pipeline_background_prepare(VideoPipeline* pipeline,uint32_t id) {
    if(!pipeline||!id)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::lock_guard serialized(pipeline->background_control_mutex);
    std::vector<uint8_t> payload;append_u32(&payload,id);
    return pipeline->context->request(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_PREPARE,
        pipeline->id,pipeline->generation,payload.data(),uint32_t(payload.size()),kRequestTimeout);
}
DinoXWebrtcStatus video_pipeline_background_release(VideoPipeline* pipeline,uint32_t id) {
    if(!pipeline||!id)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::lock_guard serialized(pipeline->background_control_mutex);
    std::vector<uint8_t> payload;append_u32(&payload,id);
    return pipeline->context->request(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE,
        pipeline->id,pipeline->generation,payload.data(),uint32_t(payload.size()),kRequestTimeout);
}

DinoXWebrtcStatus recorder_new(
    Context* context,
    const DinoXWebrtcMediaRecorderConfig* config,
    const DinoXWebrtcMediaRecorderCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcMediaRecorder* public_recorder,
    std::shared_ptr<Recorder>* out_recorder) {
    return context == nullptr
        ? DINOX_WEBRTC_STATUS_INVALID_ARGUMENT
        : context->create_recorder(
            config, callbacks, user_data, public_recorder, out_recorder);
}

void recorder_free(std::shared_ptr<Recorder>* recorder) {
    if (recorder == nullptr || *recorder == nullptr) return;
    recorder_cancel(recorder->get());
    (*recorder)->context->remove_recorder(*recorder);
    recorder->reset();
}

DinoXWebrtcStatus recorder_start(Recorder* recorder) {
    if (recorder == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    {
        std::lock_guard<std::recursive_mutex> lock(recorder->callback_mutex);
        if (recorder->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
        recorder->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_STARTING;
    }
    return recorder->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_RECORDER_START,
        recorder->id, recorder->generation, nullptr, 0);
}

DinoXWebrtcStatus recorder_stop(Recorder* recorder) {
    if (recorder == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    {
        std::lock_guard<std::recursive_mutex> lock(recorder->callback_mutex);
        if (recorder->closed) return DINOX_WEBRTC_STATUS_NOT_READY;
        recorder->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FINALIZING;
    }
    // Capture must be quiescent before the caller finalizes its AAC/MP4
    // writer. Otherwise worker frames can race the finalized output file.
    return recorder->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STOP,
        recorder->id, recorder->generation, nullptr, 0);
}

DinoXWebrtcStatus recorder_cancel(Recorder* recorder) {
    if (recorder == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    {
        std::lock_guard<std::recursive_mutex> lock(recorder->callback_mutex);
        if (recorder->closed) return DINOX_WEBRTC_STATUS_OK;
        recorder->closed = true;
    }
    DinoXWebrtcStatus status = recorder->context->send_async(
        DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CANCEL,
        recorder->id, recorder->generation, nullptr, 0);
    {
        std::lock_guard<std::recursive_mutex> lock(recorder->callback_mutex);
        recorder->callbacks = {};
        recorder->user_data = nullptr;
        recorder->public_recorder = nullptr;
        recorder->state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE;
    }
    return status;
}

DinoXWebrtcStatus recorder_push_synthetic(Recorder* recorder) {
    if (recorder == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    // This is a deterministic test-only operation. Keep it request/reply so it
    // is ordered after an asynchronous start and exposes the worker's real
    // recorder-state validation to the caller.
    return recorder->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_RECORDER_PUSH_SYNTHETIC,
        recorder->id, recorder->generation, nullptr, 0);
}

DinoXWebrtcStatus recorder_get_state(
    Recorder* recorder,
    DinoXWebrtcMediaRecorderState* out_state) {
    if (recorder == nullptr || out_state == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
    std::vector<uint8_t> reply;
    DinoXWebrtcStatus status = recorder->context->request(
        DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STATE_GET,
        recorder->id, recorder->generation, nullptr, 0, kRequestTimeout, &reply);
    if (status != DINOX_WEBRTC_STATUS_OK) return status;
    if (reply.size() != 4) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    const uint32_t raw_state = read_u32(reply.data());
    if (!valid_recorder_state(raw_state)) return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    *out_state = static_cast<DinoXWebrtcMediaRecorderState>(raw_state);
    return DINOX_WEBRTC_STATUS_OK;
}

}  // namespace dinox::webrtc_worker
