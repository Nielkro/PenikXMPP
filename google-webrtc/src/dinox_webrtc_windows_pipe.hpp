#ifndef DINOX_WEBRTC_WINDOWS_PIPE_HPP
#define DINOX_WEBRTC_WINDOWS_PIPE_HPP

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>

namespace dinox::webrtc_windows_pipe {

constexpr DWORD kWriteTimeoutMs = 5000;

inline bool wait_for_io(
    HANDLE handle,
    OVERLAPPED* overlapped,
    DWORD timeout_ms,
    DWORD* out_count) {
    const DWORD wait_status = WaitForSingleObject(overlapped->hEvent, timeout_ms);
    if (wait_status != WAIT_OBJECT_0) {
        CancelIoEx(handle, overlapped);
        WaitForSingleObject(overlapped->hEvent, INFINITE);
        DWORD ignored = 0;
        GetOverlappedResult(handle, overlapped, &ignored, FALSE);
        return false;
    }
    return GetOverlappedResult(handle, overlapped, out_count, FALSE) != FALSE;
}

inline bool transfer(
    HANDLE handle,
    void* buffer,
    DWORD size,
    bool read,
    DWORD timeout_ms,
    DWORD* out_count) {
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) return false;

    DWORD count = 0;
    const BOOL completed = read
        ? ReadFile(handle, buffer, size, &count, &overlapped)
        : WriteFile(handle, buffer, size, &count, &overlapped);
    bool success = completed != FALSE;
    if (!success && GetLastError() == ERROR_IO_PENDING) {
        success = wait_for_io(handle, &overlapped, timeout_ms, &count);
    }
    CloseHandle(overlapped.hEvent);
    if (success && out_count != nullptr) *out_count = count;
    return success;
}

inline bool read_exact(HANDLE handle, void* output, size_t size) {
    std::span<uint8_t> remaining(static_cast<uint8_t*>(output), size);
    while (!remaining.empty()) {
        DWORD count = 0;
        const DWORD chunk = static_cast<DWORD>(
            std::min<size_t>(remaining.size(), MAXDWORD));
        if (!transfer(handle, remaining.data(), chunk, true, INFINITE, &count) || count == 0) {
            return false;
        }
        remaining = remaining.subspan(count);
    }
    return true;
}

inline bool write_exact(HANDLE handle, const void* input, size_t size) {
    std::span<const uint8_t> remaining(static_cast<const uint8_t*>(input), size);
    while (!remaining.empty()) {
        DWORD count = 0;
        const DWORD chunk = static_cast<DWORD>(
            std::min<size_t>(remaining.size(), MAXDWORD));
        if (!transfer(
                handle,
                const_cast<uint8_t*>(remaining.data()),
                chunk,
                false,
                kWriteTimeoutMs,
                &count) || count == 0) {
            return false;
        }
        remaining = remaining.subspan(count);
    }
    return true;
}

inline bool connect_server(HANDLE pipe, HANDLE child_process, DWORD timeout_ms) {
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) return false;

    bool connected = ConnectNamedPipe(pipe, &overlapped) != FALSE;
    if (!connected) {
        const DWORD error = GetLastError();
        if (error == ERROR_PIPE_CONNECTED) {
            connected = true;
        } else if (error == ERROR_IO_PENDING) {
            HANDLE wait_handles[] = {overlapped.hEvent, child_process};
            const DWORD wait_status = WaitForMultipleObjects(
                2, wait_handles, FALSE, timeout_ms);
            if (wait_status == WAIT_OBJECT_0) {
                DWORD ignored = 0;
                connected = GetOverlappedResult(pipe, &overlapped, &ignored, FALSE) != FALSE;
                if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = true;
            } else {
                CancelIoEx(pipe, &overlapped);
                WaitForSingleObject(overlapped.hEvent, INFINITE);
                DWORD ignored = 0;
                GetOverlappedResult(pipe, &overlapped, &ignored, FALSE);
            }
        }
    }
    CloseHandle(overlapped.hEvent);
    return connected;
}

}  // namespace dinox::webrtc_windows_pipe

#endif  // _WIN32

#endif  // DINOX_WEBRTC_WINDOWS_PIPE_HPP
