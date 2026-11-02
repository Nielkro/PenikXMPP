#ifndef DINOX_VISION_PROCESS_HPP
#define DINOX_VISION_PROCESS_HPP

// Private process interface: called solely by VisionClient's I/O executor.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <span>
#include <string>

namespace dinox::vision::process_detail {

struct Paths {
    std::string executable;
    std::string segmentation_model;
    std::string face_model;
};

enum class IoStatus { Complete, Cancelled, Timeout, Failed };
using Deadline = std::chrono::steady_clock::time_point;

class Process {
 public:
    virtual ~Process() = default;
    virtual bool launch(const Paths& paths) = 0;
    // Complete proves this access terminal, so its buffer may be released.
    // Otherwise keep supplied buffers alive until quiescent(), including after
    // a cancelled Windows OVERLAPPED access. No additional RGB copy.
    virtual IoStatus write(std::span<const uint8_t> bytes,
        const std::atomic<uint64_t>& cancel_epoch, uint64_t expected_epoch, Deadline deadline) = 0;
    virtual IoStatus read(std::span<uint8_t> bytes,
        const std::atomic<uint64_t>& cancel_epoch, uint64_t expected_epoch, Deadline deadline) = 0;
    virtual void stop() = 0; // cancel/kill, idempotent, no blocking wait
    virtual bool quiescent() = 0; // nonblocking terminal IO + child exit/reap
};

std::unique_ptr<Process> make_process();
// Thread-local SIGPIPE handling on POSIX; no application-wide signal changes.
void prepare_io_thread();

} // namespace dinox::vision::process_detail
#endif
