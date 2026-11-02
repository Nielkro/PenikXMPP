#include "dinox_webrtc_executor.hpp"

#include <utility>

namespace dinox::webrtc {

EngineCommandExecutor::EngineCommandExecutor()
    : thread_([this]() { run(); }) {
    std::unique_lock<std::mutex> lock(mutex_);
    changed_.wait(lock, [this]() { return started_; });
}

EngineCommandExecutor::~EngineCommandExecutor() {
    shutdown(ShutdownMode::kCancelPending);
}

bool EngineCommandExecutor::submit(RequestId request_id, Task task) {
    if (request_id == 0 || !task) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!accepting_ || known_requests_.contains(request_id)) return false;
    known_requests_.insert(request_id);
    pending_.push_back(Command{request_id, std::move(task)});
    changed_.notify_all();
    return true;
}

bool EngineCommandExecutor::cancel(RequestId request_id) {
    if (request_id == 0) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto iterator = pending_.begin(); iterator != pending_.end(); ++iterator) {
        if (iterator->request_id != request_id) continue;
        pending_.erase(iterator);
        known_requests_.erase(request_id);
        cancelled_requests_.erase(request_id);
        changed_.notify_all();
        return true;
    }
    if (active_request_ == request_id) {
        cancelled_requests_.insert(request_id);
        changed_.notify_all();
        return true;
    }
    return false;
}

bool EngineCommandExecutor::is_cancelled(RequestId request_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return cancelled_requests_.contains(request_id);
}

bool EngineCommandExecutor::wait_idle(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return changed_.wait_for(lock, timeout, [this]() {
        return pending_.empty() && active_request_ == 0;
    });
}

void EngineCommandExecutor::shutdown(ShutdownMode mode) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!thread_.joinable()) return;
        accepting_ = false;
        stop_requested_ = true;
        drain_on_stop_ = mode == ShutdownMode::kDrain;
        if (!drain_on_stop_) {
            for (const Command& command : pending_) {
                known_requests_.erase(command.request_id);
            }
            pending_.clear();
        }
        changed_.notify_all();
    }
    if (std::this_thread::get_id() == thread_.get_id()) {
        return;
    }
    thread_.join();
}

bool EngineCommandExecutor::is_executor_thread() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return started_ && std::this_thread::get_id() == executor_thread_id_;
}

void EngineCommandExecutor::run() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        executor_thread_id_ = std::this_thread::get_id();
        started_ = true;
        changed_.notify_all();
    }

    while (true) {
        Command command = {};
        {
            std::unique_lock<std::mutex> lock(mutex_);
            changed_.wait(lock, [this]() {
                return stop_requested_ || !pending_.empty();
            });
            if (stop_requested_ && (!drain_on_stop_ || pending_.empty())) break;
            command = std::move(pending_.front());
            pending_.pop_front();
            active_request_ = command.request_id;
        }

        try {
            command.task();
        } catch (...) {
            // A command failure is reported by the command owner. The executor
            // must remain alive for later requests.
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            known_requests_.erase(command.request_id);
            cancelled_requests_.erase(command.request_id);
            active_request_ = 0;
            changed_.notify_all();
        }
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        active_request_ = 0;
        changed_.notify_all();
    }
}

}  // namespace dinox::webrtc
