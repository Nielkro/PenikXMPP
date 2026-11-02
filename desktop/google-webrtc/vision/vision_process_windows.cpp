#if defined(_WIN32)

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include "vision_process.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace dinox::vision::process_detail {
namespace {

constexpr DWORD kPipeBufferBytes = 64 * 1024;
constexpr DWORD kPollMilliseconds = 20;

class Handle final {
 public:
    Handle() = default;
    explicit Handle(HANDLE value) : value_(value) {}
    ~Handle() { reset(); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;

    HANDLE get() const { return value_; }
    explicit operator bool() const {
        return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
    }
    void reset(HANDLE value = nullptr) {
        if (*this) CloseHandle(value_);
        value_ = value;
    }

 private:
    HANDLE value_ = nullptr;
};

struct Operation {
    Handle event;
    OVERLAPPED access{};
    DWORD immediate_bytes = 0;
    bool pending = false;

    bool initialize() {
        event.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        return bool(event);
    }
    bool prepare() {
        if (pending || !event || !ResetEvent(event.get())) return false;
        access = {};
        access.hEvent = event.get();
        immediate_bytes = 0;
        return true;
    }
};

// All handles and access state belong to the I/O executor. In particular,
// CancelIoEx queues cancellation; it does not permit freeing OVERLAPPED yet.
struct Resources {
    Handle process;
    Handle job;
    Handle input;
    Handle output;
    Operation write;
    Operation read;
};

bool utf8_to_wide(const std::string& value, std::wstring* result, bool allow_empty = false) {
    if (value.empty()) {
        result->clear();
        return allow_empty;
    }
    if (value.find('\0') != std::string::npos ||
            value.size() > size_t(std::numeric_limits<int>::max())) return false;
    const int length = static_cast<int>(value.size());
    const int required = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), length, nullptr, 0);
    if (required <= 0) return false;
    result->resize(static_cast<size_t>(required));
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        value.data(), length, result->data(), required) == required;
}

// Quote every argument using the CRT rules: only backslashes before a quote
// or the closing quote are doubled. This also preserves trailing backslashes.
std::wstring quote_argument(const std::wstring& value) {
    std::wstring quoted(1, L'"');
    size_t backslashes = 0;
    for (wchar_t character : value) {
        if (character == L'\\') {
            ++backslashes;
            continue;
        }
        quoted.append(backslashes * (character == L'"' ? 2 : 1), L'\\');
        if (character == L'"') quoted.push_back(L'\\');
        quoted.push_back(character);
        backslashes = 0;
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'"');
    return quoted;
}

class Attributes final {
 public:
    ~Attributes() {
        if (initialized_) DeleteProcThreadAttributeList(list());
    }
    bool initialize(std::array<HANDLE, 3>& child_handles) {
        SIZE_T bytes = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
        if (bytes == 0) return false;
        storage_.resize(bytes);
        if (!InitializeProcThreadAttributeList(list(), 1, 0, &bytes)) return false;
        initialized_ = true;
        return UpdateProcThreadAttribute(list(), 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            child_handles.data(), child_handles.size() * sizeof(HANDLE), nullptr, nullptr) != FALSE;
    }
    LPPROC_THREAD_ATTRIBUTE_LIST list() {
        return reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage_.data());
    }

 private:
    std::vector<std::byte> storage_;
    bool initialized_ = false;
};

std::wstring pipe_name() {
    static std::atomic<uint64_t> sequence{0};
    return L"\\\\.\\pipe\\dinox-vision-" + std::to_wstring(GetCurrentProcessId()) +
        L"-" + std::to_wstring(GetTickCount64()) + L"-" +
        std::to_wstring(sequence.fetch_add(1, std::memory_order_relaxed));
}

bool make_pipe(Handle* parent, Handle* child, Operation* operation, bool parent_writes) {
    const std::wstring name = pipe_name();
    // Parent endpoints never inherit. Child endpoints are deliberately opened
    // without FILE_FLAG_OVERLAPPED for the worker's synchronous stdio.
    parent->reset(CreateNamedPipeW(name.c_str(),
        (parent_writes ? PIPE_ACCESS_OUTBOUND : PIPE_ACCESS_INBOUND) |
            FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, kPipeBufferBytes, kPipeBufferBytes, 0, nullptr));
    if (!*parent) return false;
    SECURITY_ATTRIBUTES inherit{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    child->reset(CreateFileW(name.c_str(), parent_writes ? GENERIC_READ : GENERIC_WRITE,
        0, &inherit, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS, nullptr));
    if (!*child || !operation->prepare()) return false;
    // Opening the client first makes this normally return ERROR_PIPE_CONNECTED.
    // Keep even an unexpected pending connect in persistent access state, so a
    // failed launch still follows stop()/quiescent() before destruction.
    if (ConnectNamedPipe(parent->get(), &operation->access)) return true;
    const DWORD error = GetLastError();
    if (error == ERROR_PIPE_CONNECTED) return true;
    if (error == ERROR_IO_PENDING) operation->pending = true;
    return false;
}

// An API error alone is not proof of terminal IO. Retain access state unless
// the kernel's OVERLAPPED completion status confirms completion or abortion.
bool terminal(Operation* operation, HANDLE pipe) {
    if (!operation->pending) return true;
    DWORD transferred = 0;
    if (GetOverlappedResult(pipe, &operation->access, &transferred, FALSE)) {
        operation->pending = false;
        return true;
    }
    if (!HasOverlappedIoCompleted(&operation->access)) return false;
    operation->pending = false;
    return true;
}

DWORD poll_interval(Deadline deadline) {
    const auto remaining = deadline - std::chrono::steady_clock::now();
    if (remaining <= Deadline::duration::zero()) return 0;
    const auto rounded = std::chrono::ceil<std::chrono::milliseconds>(remaining).count();
    return static_cast<DWORD>(std::min<int64_t>(kPollMilliseconds, rounded));
}

class WindowsProcess final : public Process {
 public:
    ~WindowsProcess() override {
        stop();
        if (!quiescent()) {
            // Defensive quarantine only for a violated private lifetime
            // invariant. The normal guardian retains this object until true;
            // never free an access still owned by the kernel on this error path.
            resources_.release();
        }
    }

    bool launch(const Paths& paths) override {
        if (launched_ || stopping_) return false;
        launched_ = true;
        std::wstring executable, segmentation_model, face_model;
        if (!utf8_to_wide(paths.executable, &executable) ||
                !utf8_to_wide(paths.segmentation_model, &segmentation_model, true) ||
                !utf8_to_wide(paths.face_model, &face_model, true)) return false;
        std::wstring command = quote_argument(executable) +
            L" --segmentation-model " + quote_argument(segmentation_model) +
            L" --face-model " + quote_argument(face_model);
        // CreateProcessW's limit includes the terminating null character.
        if (command.size() >= 32767) return false;

        resources_ = std::make_unique<Resources>();
        auto& resources = *resources_;
        Handle child_input, child_output, child_error;
        if (!resources.write.initialize() || !resources.read.initialize() ||
                !make_pipe(&resources.input, &child_input, &resources.write, true) ||
                !make_pipe(&resources.output, &child_output, &resources.read, false)) {
            stop();
            return false;
        }
        SECURITY_ATTRIBUTES inherit{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        child_error.reset(CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            &inherit, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!child_error) { stop(); return false; }
        resources.job.reset(CreateJobObjectW(nullptr, nullptr));
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!resources.job || !SetInformationJobObject(resources.job.get(),
                JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
            stop();
            return false;
        }

        std::array<HANDLE, 3> inherited{child_input.get(), child_output.get(), child_error.get()};
        Attributes attributes;
        if (!attributes.initialize(inherited)) { stop(); return false; }
        STARTUPINFOEXW startup{};
        startup.StartupInfo.cb = sizeof(startup);
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = child_input.get();
        startup.StartupInfo.hStdOutput = child_output.get();
        startup.StartupInfo.hStdError = child_error.get();
        startup.lpAttributeList = attributes.list();
        PROCESS_INFORMATION child{};
        // Explicit applicationName avoids PATH lookup and executable ambiguity.
        if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW,
                nullptr, nullptr, &startup.StartupInfo, &child)) {
            stop();
            return false;
        }
        resources.process.reset(child.hProcess);
        Handle thread(child.hThread);
        if (!AssignProcessToJobObject(resources.job.get(), resources.process.get()) ||
                ResumeThread(thread.get()) == DWORD(-1)) {
            stop();
            return false;
        }
        // Locals close the parent's duplicate child endpoints after launch.
        return true;
    }

    IoStatus write(std::span<const uint8_t> bytes,
            const std::atomic<uint64_t>& cancel_epoch, uint64_t expected_epoch,
            Deadline deadline) override {
        return transfer(bytes.data(), nullptr, bytes.size(), true,
            cancel_epoch, expected_epoch, deadline);
    }

    IoStatus read(std::span<uint8_t> bytes,
            const std::atomic<uint64_t>& cancel_epoch, uint64_t expected_epoch,
            Deadline deadline) override {
        return transfer(nullptr, bytes.data(), bytes.size(), false,
            cancel_epoch, expected_epoch, deadline);
    }

    void stop() override {
        stopping_ = true;
        if (!resources_) return;
        auto& resources = *resources_;
        if (resources.write.pending) CancelIoEx(resources.input.get(), &resources.write.access);
        if (resources.read.pending) CancelIoEx(resources.output.get(), &resources.read.access);
        if (resources.job) TerminateJobObject(resources.job.get(), 1);
        // Also covers failure to assign the suspended child to its job.
        if (resources.process) TerminateProcess(resources.process.get(), 1);
    }

    bool quiescent() override {
        if (!resources_) return true;
        auto& resources = *resources_;
        const bool writes_terminal = terminal(&resources.write, resources.input.get());
        const bool reads_terminal = terminal(&resources.read, resources.output.get());
        const bool child_terminal = !resources.process ||
            WaitForSingleObject(resources.process.get(), 0) == WAIT_OBJECT_0;
        if (!writes_terminal || !reads_terminal || !child_terminal) return false;
        resources_.reset();
        return true;
    }

 private:
    IoStatus await(Operation* operation, HANDLE pipe,
            const std::atomic<uint64_t>& cancel_epoch, uint64_t expected_epoch,
            Deadline deadline, DWORD* transferred) {
        for (;;) {
            if (stopping_ || cancel_epoch.load(std::memory_order_acquire) != expected_epoch) {
                CancelIoEx(pipe, &operation->access);
                return IoStatus::Cancelled;
            }
            if (std::chrono::steady_clock::now() >= deadline) {
                CancelIoEx(pipe, &operation->access);
                return IoStatus::Timeout;
            }
            if (GetOverlappedResult(pipe, &operation->access, transferred, FALSE)) {
                operation->pending = false;
                return IoStatus::Complete;
            }
            const DWORD error = GetLastError();
            if (error != ERROR_IO_INCOMPLETE) {
                if (HasOverlappedIoCompleted(&operation->access)) operation->pending = false;
                else CancelIoEx(pipe, &operation->access);
                return error == ERROR_OPERATION_ABORTED ? IoStatus::Cancelled : IoStatus::Failed;
            }
            const DWORD wait = WaitForSingleObject(operation->event.get(), poll_interval(deadline));
            if (wait != WAIT_OBJECT_0 && wait != WAIT_TIMEOUT) {
                CancelIoEx(pipe, &operation->access);
                return IoStatus::Failed;
            }
        }
    }

    IoStatus transfer(const uint8_t* source, uint8_t* destination, size_t length,
            bool writing, const std::atomic<uint64_t>& cancel_epoch,
            uint64_t expected_epoch, Deadline deadline) {
        if (stopping_ || cancel_epoch.load(std::memory_order_acquire) != expected_epoch) {
            return IoStatus::Cancelled;
        }
        if (!resources_ || !resources_->process) return IoStatus::Failed;
        auto& resources = *resources_;
        Operation& operation = writing ? resources.write : resources.read;
        const HANDLE pipe = writing ? resources.input.get() : resources.output.get();
        if (operation.pending) return IoStatus::Failed;
        size_t used = 0;
        while (used < length) {
            if (stopping_ || cancel_epoch.load(std::memory_order_acquire) != expected_epoch) {
                return IoStatus::Cancelled;
            }
            if (std::chrono::steady_clock::now() >= deadline) return IoStatus::Timeout;
            if (!operation.prepare()) return IoStatus::Failed;
            const DWORD count = static_cast<DWORD>(std::min<size_t>(
                length - used, std::numeric_limits<DWORD>::max()));
            DWORD transferred = 0;
            const BOOL issued = writing ?
                WriteFile(pipe, source + used, count, &operation.immediate_bytes, &operation.access) :
                ReadFile(pipe, destination + used, count, &operation.immediate_bytes, &operation.access);
            if (!issued && GetLastError() != ERROR_IO_PENDING) return IoStatus::Failed;
            // A successful overlapped call has already completed, but use the
            // same nonblocking result check rather than trusting its byte count.
            operation.pending = true;
            const IoStatus status = await(&operation, pipe,
                cancel_epoch, expected_epoch, deadline, &transferred);
            if (status != IoStatus::Complete) return status;
            if (transferred == 0 || transferred > count) return IoStatus::Failed;
            used += transferred;
        }
        return IoStatus::Complete;
    }

    std::unique_ptr<Resources> resources_;
    bool launched_ = false;
    bool stopping_ = false;
};

} // namespace

std::unique_ptr<Process> make_process() { return std::make_unique<WindowsProcess>(); }

void prepare_io_thread() {}

} // namespace dinox::vision::process_detail

#endif // _WIN32
