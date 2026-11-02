#ifndef DINOX_WEBRTC_EXECUTOR_HPP
#define DINOX_WEBRTC_EXECUTOR_HPP

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <unordered_set>

namespace dinox::webrtc {

class EngineCommandExecutor final {
 public:
    using RequestId = uint64_t;
    using Task = std::function<void()>;

    enum class ShutdownMode {
        kDrain,
        kCancelPending,
    };

    EngineCommandExecutor();
    ~EngineCommandExecutor();

    EngineCommandExecutor(const EngineCommandExecutor&) = delete;
    EngineCommandExecutor& operator=(const EngineCommandExecutor&) = delete;

    bool submit(RequestId request_id, Task task);
    bool cancel(RequestId request_id);
    bool is_cancelled(RequestId request_id) const;
    bool wait_idle(std::chrono::milliseconds timeout);
    void shutdown(ShutdownMode mode = ShutdownMode::kCancelPending);
    bool is_executor_thread() const;

 private:
    struct Command {
        RequestId request_id;
        Task task;
    };

    void run();

    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::deque<Command> pending_;
    std::unordered_set<RequestId> known_requests_;
    std::unordered_set<RequestId> cancelled_requests_;
    std::thread thread_;
    std::thread::id executor_thread_id_;
    RequestId active_request_ = 0;
    bool accepting_ = true;
    bool stop_requested_ = false;
    bool drain_on_stop_ = false;
    bool started_ = false;
};

}  // namespace dinox::webrtc

#endif
