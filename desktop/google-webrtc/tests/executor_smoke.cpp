#include "dinox_webrtc_executor.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <stdio.h>
#include <thread>
#include <vector>

#define DINOX_CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "DINOX_CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (false)

int main() {
    using dinox::webrtc::EngineCommandExecutor;
    EngineCommandExecutor executor;
    std::mutex result_mutex;
    std::vector<int> order;
    std::thread::id task_thread;
    const std::thread::id caller_thread = std::this_thread::get_id();

    for (uint64_t request = 1; request <= 20; ++request) {
        DINOX_CHECK(executor.submit(request, [&, request]() {
            std::lock_guard<std::mutex> lock(result_mutex);
            order.push_back(static_cast<int>(request));
            task_thread = std::this_thread::get_id();
        }));
    }
    DINOX_CHECK(executor.wait_idle(std::chrono::seconds(2)));
    DINOX_CHECK(order.size() == 20);
    for (size_t index = 0; index < order.size(); ++index) {
        DINOX_CHECK(order[index] == static_cast<int>(index + 1));
    }
    DINOX_CHECK(task_thread != caller_thread);

    std::mutex blocker_mutex;
    std::condition_variable blocker_changed;
    bool blocker_started = false;
    bool blocker_released = false;
    DINOX_CHECK(executor.submit(100, [&]() {
        std::unique_lock<std::mutex> lock(blocker_mutex);
        blocker_started = true;
        blocker_changed.notify_all();
        blocker_changed.wait(lock, [&]() { return blocker_released; });
    }));
    {
        std::unique_lock<std::mutex> lock(blocker_mutex);
        DINOX_CHECK(blocker_changed.wait_for(
            lock,
            std::chrono::seconds(2),
            [&]() { return blocker_started; }));
    }
    std::atomic<bool> cancelled_task_ran = false;
    DINOX_CHECK(executor.submit(101, [&]() { cancelled_task_ran.store(true); }));
    DINOX_CHECK(!executor.submit(101, []() {}));
    DINOX_CHECK(executor.cancel(101));
    {
        std::lock_guard<std::mutex> lock(blocker_mutex);
        blocker_released = true;
        blocker_changed.notify_all();
    }
    DINOX_CHECK(executor.wait_idle(std::chrono::seconds(2)));
    DINOX_CHECK(!cancelled_task_ran.load());

    std::mutex active_mutex;
    std::condition_variable active_changed;
    bool active_started = false;
    bool active_released = false;
    std::atomic<bool> active_saw_cancel = false;
    DINOX_CHECK(executor.submit(200, [&]() {
        {
            std::unique_lock<std::mutex> lock(active_mutex);
            active_started = true;
            active_changed.notify_all();
            active_changed.wait(lock, [&]() { return active_released; });
        }
        active_saw_cancel.store(executor.is_cancelled(200));
    }));
    {
        std::unique_lock<std::mutex> lock(active_mutex);
        DINOX_CHECK(active_changed.wait_for(
            lock,
            std::chrono::seconds(2),
            [&]() { return active_started; }));
    }
    DINOX_CHECK(executor.cancel(200));
    {
        std::lock_guard<std::mutex> lock(active_mutex);
        active_released = true;
        active_changed.notify_all();
    }
    DINOX_CHECK(executor.wait_idle(std::chrono::seconds(2)));
    DINOX_CHECK(active_saw_cancel.load());

    DINOX_CHECK(executor.submit(300, []() { throw 1; }));
    DINOX_CHECK(executor.submit(301, [&]() {
        std::lock_guard<std::mutex> lock(result_mutex);
        order.push_back(301);
    }));
    DINOX_CHECK(executor.wait_idle(std::chrono::seconds(2)));
    DINOX_CHECK(order.back() == 301);
    executor.shutdown(EngineCommandExecutor::ShutdownMode::kDrain);
    DINOX_CHECK(!executor.submit(400, []() {}));
    return 0;
}
