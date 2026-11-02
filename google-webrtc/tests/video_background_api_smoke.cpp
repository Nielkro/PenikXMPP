#include "dinox_webrtc.h"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <span>
#include <string>
#include <thread>
#include <vector>
#define CHECK(x) do{if(!(x)){std::cerr<<"background check "<<__LINE__<<": "<<#x<<'\n';return 1;}}while(false)
namespace {
struct State{std::mutex mutex;std::condition_variable changed;uint64_t frames=0,green=0,gray=0;
    DinoXWebrtcVideoPipelineState pipeline{};};
bool env(const char* key,const std::string& value){
#ifdef _WIN32
    return _putenv_s(key,value.c_str())==0;
#else
    return setenv(key,value.c_str(),1)==0;
#endif
}
void state_callback(DinoXWebrtcVideoPipeline*,const DinoXWebrtcVideoPipelineState* value,void* data){
    auto& s=*static_cast<State*>(data);std::lock_guard lock(s.mutex);if(value)s.pipeline=*value;s.changed.notify_all();
}
// External C callback: validate the supplied extent before borrowing.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
void frame_callback(DinoXWebrtcSession*,const uint8_t* bytes,int w,int h,int stride,uint64_t,void* data){
    if(!bytes||w<1||h<1||w>4096||h>4096||stride<4*w)return;
    const auto pixels=std::span(bytes,size_t(stride)*h);
    const size_t p=size_t(h/2)*stride+size_t(w/2)*4;
    auto& s=*static_cast<State*>(data);std::lock_guard lock(s.mutex);++s.frames;
    if(pixels[p+1]>pixels[p]+20&&pixels[p+1]>pixels[p+2]+20)++s.green;
    if(pixels[p]>=45&&pixels[p]<=51&&pixels[p+1]==pixels[p]&&pixels[p+2]==pixels[p])++s.gray;
    s.changed.notify_all();
}
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
bool applied(State& s,uint64_t revision){std::unique_lock lock(s.mutex);
    return s.changed.wait_for(lock,std::chrono::seconds(3),[&]{return s.pipeline.applied_revision==revision&&
        s.pipeline.application_state==DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED;});}
}
int main(int argc,char** argv){
    std::string worker;
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    if(argc==2&&argv&&argv[1])worker=argv[1];
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
    CHECK(!worker.empty());worker=std::filesystem::absolute(worker).string();
    const auto original=std::filesystem::current_path();
    const auto temp=std::filesystem::temp_directory_path()/
        ("dinox-bg-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(temp);std::filesystem::current_path(temp);std::ofstream("normal").put('\n');
    struct Cleanup{std::filesystem::path temp,original;~Cleanup(){std::filesystem::current_path(original);std::filesystem::remove_all(temp);}}cleanup{temp,original};
    CHECK(env("DINOX_WEBRTC_VISION_TEST_PATHS","1")&&env("DINOX_WEBRTC_VISION_TEST_WORKER",worker)&&
        env("DINOX_WEBRTC_VISION_TEST_SEGMENT_MODEL","normal")&&env("DINOX_WEBRTC_VISION_TEST_FACE_MODEL","normal"));
    DinoXWebrtcContext* context=nullptr;CHECK(dinox_webrtc_context_new(&context)==DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoEffectCapabilities caps{};CHECK(dinox_webrtc_context_get_video_effect_capabilities(context,&caps)==DINOX_WEBRTC_STATUS_OK);
    CHECK(caps.supported_background_mask==15);
    State s;auto cb=dinox_webrtc_video_pipeline_callbacks_default();cb.on_state_changed=state_callback;
    DinoXWebrtcVideoPipeline *pipeline=nullptr,*foreign=nullptr;
    CHECK(dinox_webrtc_video_pipeline_new(context,88551,&cb,&s,&pipeline)==DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_new(context,88552,&cb,&s,&foreign)==DINOX_WEBRTC_STATUS_OK);
    uint32_t id=777,previous=0;
    // Cancellation leaves physical staging in flight. The next valid stage
    // must retire the unused previous ID even when its caller never released it.
    for(unsigned i=0;i<40;++i){
        CHECK(dinox_webrtc_video_pipeline_background_builtin(pipeline,
            static_cast<DinoXWebrtcBackgroundBuiltin>(1+i%10),&id)==DINOX_WEBRTC_STATUS_OK);
        CHECK(id>previous&&dinox_webrtc_video_pipeline_background_prepare(pipeline,id)==DINOX_WEBRTC_STATUS_OK);
        if(previous)CHECK(dinox_webrtc_video_pipeline_background_prepare(pipeline,previous)==DINOX_WEBRTC_STATUS_NOT_READY);
        previous=id;
    }
    CHECK(id>8&&dinox_webrtc_video_pipeline_background_prepare(foreign,id)==DINOX_WEBRTC_STATUS_NOT_READY);
    // >1MiB padded/odd straight-alpha input exercises the chunked transport.
    const uint32_t width=513,height=513,stride=width*4+7;
    std::vector<uint8_t> pixels(size_t(stride)*height,0xa5);
    for(uint32_t y=0;y<height;++y)for(uint32_t x=0;x<width;++x){const size_t p=size_t(y)*stride+x*4;
        pixels[p]=0;pixels[p+1]=255;pixels[p+2]=0;pixels[p+3]=255;}
    CHECK(dinox_webrtc_video_pipeline_background_upload(pipeline,width,height,stride,
        DINOX_WEBRTC_BACKGROUND_RGBA8888,pixels.data(),pixels.size(),&id)==DINOX_WEBRTC_STATUS_OK);
    CHECK(id>previous&&dinox_webrtc_video_pipeline_background_prepare(pipeline,id)==DINOX_WEBRTC_STATUS_OK);
    std::fill(pixels.begin(),pixels.end(),0); // registry must own the green copy
    uint32_t unchanged=991;
    CHECK(dinox_webrtc_video_pipeline_background_upload(pipeline,width,height,stride,
        DINOX_WEBRTC_BACKGROUND_RGBA8888,pixels.data(),pixels.size(),nullptr)==DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    CHECK(dinox_webrtc_video_pipeline_background_upload(pipeline,1921,height,stride,
        DINOX_WEBRTC_BACKGROUND_RGBA8888,pixels.data(),pixels.size(),&unchanged)==DINOX_WEBRTC_STATUS_INVALID_ARGUMENT&&unchanged==991);
    auto config=dinox_webrtc_video_effect_config_default();config.background_mode=DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE;config.asset_id=id;
    uint64_t revision=0;CHECK(dinox_webrtc_video_pipeline_set_config(foreign,&config,&revision)==DINOX_WEBRTC_STATUS_NOT_READY&&revision==0);
    CHECK(dinox_webrtc_video_pipeline_set_config(pipeline,&config,&revision)==DINOX_WEBRTC_STATUS_OK&&applied(s,revision));
    auto sc=dinox_webrtc_session_config_default();auto session_cb=dinox_webrtc_callbacks_default();session_cb.on_local_video_frame=frame_callback;
    DinoXWebrtcSession* session=nullptr;CHECK(dinox_webrtc_session_new(context,&sc,&session_cb,&s,&session)==DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_attach_session(pipeline,session,1)==DINOX_WEBRTC_STATUS_OK);
    for(int i=0;i<12;++i){CHECK(dinox_webrtc_session_push_synthetic_video_frame(session,8,8)==DINOX_WEBRTC_STATUS_OK);
        std::this_thread::sleep_for(std::chrono::milliseconds(120));}
    {std::lock_guard lock(s.mutex);CHECK(s.green>0&&s.pipeline.asset_id==id);}
    // Keep the active image while replacing a never-selected staged choice.
    uint32_t staged=0;CHECK(dinox_webrtc_video_pipeline_background_builtin(pipeline,DINOX_WEBRTC_BACKGROUND_BUILTIN_OFFICE,&staged)==DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_background_prepare(pipeline,staged)==DINOX_WEBRTC_STATUS_OK);
    uint32_t newest=0;CHECK(dinox_webrtc_video_pipeline_background_builtin(pipeline,DINOX_WEBRTC_BACKGROUND_BUILTIN_CAFE,&newest)==DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_background_prepare(pipeline,staged)==DINOX_WEBRTC_STATUS_NOT_READY);
    CHECK(dinox_webrtc_video_pipeline_background_prepare(pipeline,id)==DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_background_release(pipeline,id)==DINOX_WEBRTC_STATUS_OK);
    uint64_t before=0;{std::lock_guard lock(s.mutex);before=s.gray;}
    CHECK(dinox_webrtc_session_push_synthetic_video_frame(session,8,8)==DINOX_WEBRTC_STATUS_OK);
    {std::unique_lock lock(s.mutex);CHECK(s.changed.wait_for(lock,std::chrono::seconds(3),[&]{return s.gray>before;}));}
    unchanged=991;revision=991;CHECK(dinox_webrtc_video_pipeline_set_config(pipeline,&config,&revision)==DINOX_WEBRTC_STATUS_NOT_READY&&revision==991);
    CHECK(dinox_webrtc_video_pipeline_background_release(pipeline,newest)==DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_video_pipeline_free(foreign);dinox_webrtc_video_pipeline_free(pipeline);
    dinox_webrtc_session_free(session);dinox_webrtc_context_free(context);return 0;
}
