#include "dinox_webrtc_video_background_preparation.hpp"
#include <condition_variable>
#include <mutex>
#include <optional>
#include <system_error>
#include <thread>
namespace dinox::video_background_images {
struct BackgroundPreparation::State {
    struct Ticket { uint32_t id; video_compositor::Range range;
        video_compositor::Matrix matrix; uint64_t generation;
        bool operator==(const Ticket&) const = default; };
    explicit State(std::shared_ptr<BackgroundImageRegistry> value):registry(std::move(value)) {}
    std::shared_ptr<BackgroundImageRegistry> registry;
    std::mutex mutex;
    std::condition_variable changed;
    std::optional<Ticket> pending, active;
    bool closed=false, started=false;
};
BackgroundPreparation::BackgroundPreparation(std::shared_ptr<BackgroundImageRegistry> registry)
    :state_(std::make_shared<State>(std::move(registry))) {}
BackgroundPreparation::~BackgroundPreparation(){close();}
void BackgroundPreparation::request(uint32_t id,video_compositor::Range range,video_compositor::Matrix matrix) {
    auto state=state_;
    if(!id||!state->registry->contains(id))return;
    const State::Ticket ticket{id,range,matrix,state->registry->generation()};
    std::lock_guard lock(state->mutex);
    if(state->closed||state->active==ticket||state->pending==ticket)return;
    state->pending=ticket;
    if(!state->started) {
        const auto run=[state] {
            for(;;) {
                std::optional<State::Ticket> next;
                {
                    std::unique_lock lock(state->mutex);
                    state->changed.wait(lock,[&]{return state->closed||state->pending.has_value();});
                    if(state->closed)return;
                    next=state->pending;state->pending.reset();state->active=next;
                }
                if(next->generation==state->registry->generation())
                    state->registry->prepare(next->id,next->range,next->matrix);
                {std::lock_guard lock(state->mutex);state->active.reset();}
            }
        };
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
        try {std::thread(run).detach();state->started=true;}
        catch(const std::system_error&){state->pending.reset();}
#else
        std::thread(run).detach();state->started=true;
#endif
    }
    state->changed.notify_one();
}
void BackgroundPreparation::close(){
    const auto state=state_;
    {
        std::lock_guard lock(state->mutex);
        if(state->closed)return;
        state->closed=true;state->pending.reset();
    }
    // Reset the lookup generation before an old conversion can commit. Old
    // readers keep immutable pixels; the detached guardian ends after that job.
    state->registry->reset();state->changed.notify_all();
}
}
