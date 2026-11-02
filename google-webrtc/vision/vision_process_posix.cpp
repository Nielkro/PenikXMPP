#include "vision_process.hpp"

#if !defined(_WIN32)
#include <algorithm>
#include <array>
#include <cerrno>
#include <csignal>
#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace dinox::vision::process_detail {
namespace {

void close_fd(int& fd) {
    if (fd >= 0) {
        const int old = fd;
        fd = -1;
        // Linux close(EINTR) has already released the descriptor. Retrying can
        // close a different thread's newly allocated descriptor.
        ::close(old);
    }
}

bool above_stdio(int& fd) {
    if (fd >= 3) return true;
    const int moved = ::fcntl(fd, F_DUPFD_CLOEXEC, 3);
    if (moved < 0) return false;
    close_fd(fd);
    fd = moved;
    return true;
}

bool nonblocking(int fd) {
    const int flags = ::fcntl(fd, F_GETFL);
    return flags >= 0 && ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

class PosixProcess final : public Process {
 public:
    ~PosixProcess() override {
        // The client's guardian retains this object until quiescent(). No
        // blocking process wait may enter a UI/capture-thread destructor.
        stop();
    }

    bool launch(const Paths& paths) override {
        if (pid_ > 0) return false;
        std::array<int, 2> input{-1, -1};
        std::array<int, 2> output{-1, -1};
        int errors = -1;
        const auto close_temporary = [&] {
            for (int& fd : input) close_fd(fd);
            for (int& fd : output) close_fd(fd);
            close_fd(errors);
        };
        if (::pipe2(input.data(), O_CLOEXEC) != 0 || ::pipe2(output.data(), O_CLOEXEC) != 0) {
            close_temporary();
            return false;
        }
        errors = ::open("/dev/null", O_WRONLY | O_CLOEXEC);
        bool prepared = errors >= 0;
        for (int& fd : input) prepared = above_stdio(fd) && prepared;
        for (int& fd : output) prepared = above_stdio(fd) && prepared;
        if (errors >= 0) prepared = above_stdio(errors) && prepared;
        prepared = nonblocking(input[1]) && nonblocking(output[0]) && prepared;
        if (!prepared) {
            close_temporary();
            return false;
        }
        posix_spawn_file_actions_t actions;
        if (::posix_spawn_file_actions_init(&actions) != 0) {
            close_temporary();
            return false;
        }
        bool actions_valid = ::posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0 &&
            ::posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0 &&
            ::posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO) == 0;
        // Open P2: unrelated parent descriptors still rely on FD_CLOEXEC.
        // A strict stdio-only closefrom policy needs a verified libc baseline;
        // do not infer the Windows handle-allowlist guarantee for this backend.
        // Close every non-stdio descriptor in the child, including parent XMPP
        // sockets without CLOEXEC. Resolve the glibc extension at runtime so
        // it adds no strong libc-version requirement to the main application.
        // Supported Linux baselines provide it; otherwise optional vision
        // launch fails closed instead of inheriting application descriptors.
        using CloseFrom = int (*)(posix_spawn_file_actions_t*, int);
        const auto close_from = reinterpret_cast<CloseFrom>(
            ::dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addclosefrom_np"));
        actions_valid = close_from != nullptr && actions_valid;
        if (actions_valid) actions_valid = close_from(&actions, 3) == 0;
        posix_spawnattr_t attributes;
        if (::posix_spawnattr_init(&attributes) != 0) {
            ::posix_spawn_file_actions_destroy(&actions);
            close_temporary();
            return false;
        }
        sigset_t child_mask;
        sigset_t defaults;
        ::pthread_sigmask(SIG_SETMASK, nullptr, &child_mask);
        ::sigdelset(&child_mask, SIGPIPE);
        ::sigemptyset(&defaults);
        ::sigaddset(&defaults, SIGPIPE);
        const bool attributes_valid = ::posix_spawnattr_setpgroup(&attributes, 0) == 0 &&
            ::posix_spawnattr_setsigmask(&attributes, &child_mask) == 0 &&
            ::posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 &&
            ::posix_spawnattr_setflags(&attributes,
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) == 0;
        std::array<std::string, 5> arguments{paths.executable, "--segmentation-model",
            paths.segmentation_model, "--face-model", paths.face_model};
        std::array<char*, 6> argv{};
        for (size_t i = 0; i < arguments.size(); ++i) argv[i] = arguments[i].data();
        pid_t child = -1;
        const int status = actions_valid && attributes_valid ?
            ::posix_spawn(&child, paths.executable.c_str(), &actions, &attributes, argv.data(), environ) : EINVAL;
        ::posix_spawnattr_destroy(&attributes);
        ::posix_spawn_file_actions_destroy(&actions);
        if (status != 0) {
            close_temporary();
            return false;
        }
        pid_ = child;
        input_ = input[1]; input[1] = -1;
        output_ = output[0]; output[0] = -1;
        stopping_ = false;
        close_temporary();
        return true;
    }

    IoStatus write(std::span<const uint8_t> bytes, const std::atomic<uint64_t>& epoch,
            uint64_t expected, Deadline deadline) override {
        while (!bytes.empty()) {
            const auto ready = wait(input_, POLLOUT, epoch, expected, deadline);
            if (ready != IoStatus::Complete) return ready;
            const ssize_t count = ::write(input_, bytes.data(), bytes.size());
            if (count > 0) bytes = bytes.subspan(static_cast<size_t>(count));
            else if (count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) return IoStatus::Failed;
        }
        return IoStatus::Complete;
    }

    IoStatus read(std::span<uint8_t> bytes, const std::atomic<uint64_t>& epoch,
            uint64_t expected, Deadline deadline) override {
        while (!bytes.empty()) {
            const auto ready = wait(output_, POLLIN, epoch, expected, deadline);
            if (ready != IoStatus::Complete) return ready;
            const ssize_t count = ::read(output_, bytes.data(), bytes.size());
            if (count > 0) bytes = bytes.subspan(static_cast<size_t>(count));
            else if (count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) return IoStatus::Failed;
        }
        return IoStatus::Complete;
    }

    void stop() override {
        if (stopping_) return;
        stopping_ = true;
        close_fd(input_);
        close_fd(output_);
        if (pid_ > 0) {
            // The child has its own process group; no application process is
            // signalled. A killed worker must be reaped before a new launch.
            ::kill(-pid_, SIGKILL);
            ::kill(pid_, SIGKILL);
        }
    }

    bool quiescent() override {
        if (pid_ < 0) return true;
        int status = 0;
        const pid_t result = ::waitpid(pid_, &status, WNOHANG);
        if (result == pid_ || (result < 0 && errno == ECHILD)) {
            pid_ = -1;
            close_fd(input_);
            close_fd(output_);
            return true;
        }
        return false;
    }

 private:
    static IoStatus wait(int fd, short events, const std::atomic<uint64_t>& epoch,
            uint64_t expected, Deadline deadline) {
        if (fd < 0) return IoStatus::Failed;
        for (;;) {
            if (epoch.load(std::memory_order_acquire) != expected) return IoStatus::Cancelled;
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) return IoStatus::Timeout;
            const int timeout = static_cast<int>(std::clamp<int64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count(), 1, 20));
            pollfd descriptor{fd, events, 0};
            const int result = ::poll(&descriptor, 1, timeout);
            if (result < 0 && errno != EINTR) return IoStatus::Failed;
            if (result > 0) {
                if (descriptor.revents & (POLLNVAL | POLLERR)) return IoStatus::Failed;
                if (descriptor.revents & (events | POLLHUP)) return IoStatus::Complete;
            }
        }
    }

    pid_t pid_ = -1;
    int input_ = -1, output_ = -1;
    bool stopping_ = false;
};

} // namespace

std::unique_ptr<Process> make_process() { return std::make_unique<PosixProcess>(); }

void prepare_io_thread() {
    sigset_t signals;
    ::sigemptyset(&signals);
    ::sigaddset(&signals, SIGPIPE);
    ::pthread_sigmask(SIG_BLOCK, &signals, nullptr);
}

} // namespace dinox::vision::process_detail
#endif
