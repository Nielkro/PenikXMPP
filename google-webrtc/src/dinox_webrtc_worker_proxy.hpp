#ifndef DINOX_WEBRTC_WORKER_PROXY_HPP
#define DINOX_WEBRTC_WORKER_PROXY_HPP

#include "dinox_webrtc.h"

#include <memory>

namespace dinox::webrtc_worker {

class Context;
class Session;
class Recorder;
class VideoPipeline;

bool should_use_process_engine();
void enter_internal_worker_mode();

DinoXWebrtcStatus context_new(
    DinoXWebrtcAudioDeviceMode mode,
    std::shared_ptr<Context>* out_context);
void context_close(std::shared_ptr<Context>* context);
DinoXWebrtcStatus context_get_audio_device_count(Context* context, int incoming, int* out_count);
DinoXWebrtcStatus context_get_audio_device_name(
    Context* context,
    int incoming,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_guid,
    size_t out_guid_size);
DinoXWebrtcStatus context_set_audio_device(Context* context, int incoming, int index);
DinoXWebrtcStatus context_get_audio_device_volume(
    Context* context,
    int incoming,
    double* out_volume,
    int* out_available);
DinoXWebrtcStatus context_set_audio_device_volume(Context* context, int incoming, double volume);
DinoXWebrtcStatus context_play_test_tone(
    Context* context,
    char digit,
    unsigned int duration_ms);
DinoXWebrtcStatus context_play_audio_test_clip(
    Context* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    unsigned int* out_duration_ms);
DinoXWebrtcStatus context_stop_audio_test_playout(Context* context);
DinoXWebrtcStatus context_media_audio_playout_start(
    Context* context,
    int sample_rate,
    int channels,
    int bytes_per_sample);
DinoXWebrtcStatus context_media_audio_playout_push(
    Context* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    unsigned int* out_queued_duration_ms);
DinoXWebrtcStatus context_media_audio_playout_set_paused(Context* context, int paused);
DinoXWebrtcStatus context_media_audio_playout_flush(Context* context);
DinoXWebrtcStatus context_media_audio_playout_finish(
    Context* context,
    unsigned int* out_queued_duration_ms);
DinoXWebrtcStatus context_media_audio_playout_stop(Context* context);
DinoXWebrtcStatus context_get_video_device_count(Context* context, int* out_count);
DinoXWebrtcStatus context_get_video_device_name(
    Context* context,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_unique_id,
    size_t out_unique_id_size,
    char* out_product_id,
    size_t out_product_id_size);
DinoXWebrtcStatus context_get_video_effect_capabilities(
    Context* context,
    DinoXWebrtcVideoEffectCapabilities* out_capabilities);
DinoXWebrtcStatus context_inject_failure_for_test(Context* context, int failure_kind);

DinoXWebrtcStatus session_new(
    Context* context,
    const DinoXWebrtcSessionConfig* config,
    const DinoXWebrtcCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcSession* public_session,
    std::shared_ptr<Session>* out_session);
void session_free(std::shared_ptr<Session>* session);
DinoXWebrtcStatus session_add_ice_server(
    Session* session,
    const char* url,
    const char* username,
    const char* credential);
DinoXWebrtcStatus session_create_offer(Session* session);
DinoXWebrtcStatus session_create_answer(Session* session);
DinoXWebrtcStatus session_prepare_local_description(Session* session, DinoXWebrtcSdpType type);
DinoXWebrtcStatus session_set_local_description(
    Session* session, DinoXWebrtcSdpType type, const char* sdp);
DinoXWebrtcStatus session_set_remote_description(
    Session* session,
    DinoXWebrtcSdpType type,
    const char* sdp);
DinoXWebrtcStatus session_add_remote_candidate(
    Session* session,
    const char* sdp_mid,
    int sdp_mline_index,
    const char* candidate);
DinoXWebrtcStatus session_set_audio_enabled(Session* session, int enabled);
DinoXWebrtcStatus session_set_video_enabled(Session* session, int enabled);
DinoXWebrtcStatus session_send_dtmf(
    Session* session,
    char digit,
    unsigned int duration_ms,
    bool local_feedback);
DinoXWebrtcStatus session_start_video_capture(
    Session* session,
    const char* device_unique_id,
    int width,
    int height,
    int max_fps);
DinoXWebrtcStatus session_stop_video_capture(Session* session);
DinoXWebrtcStatus session_push_synthetic_video(Session* session, int width, int height);
DinoXWebrtcStatus session_get_state(Session* session, DinoXWebrtcSessionState* out_state);
DinoXWebrtcStatus session_close(Session* session);

DinoXWebrtcStatus video_pipeline_new(
    Context* context,
    uint64_t logical_call_id,
    const DinoXWebrtcVideoPipelineCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcVideoPipeline* public_pipeline,
    std::shared_ptr<VideoPipeline>* out_pipeline);
void video_pipeline_free(std::shared_ptr<VideoPipeline>* pipeline);
DinoXWebrtcStatus video_pipeline_attach_session(
    VideoPipeline* pipeline,
    Session* session,
    int preview_publisher);
DinoXWebrtcStatus video_pipeline_detach_session(VideoPipeline* pipeline, Session* session);
DinoXWebrtcStatus video_pipeline_set_config(
    VideoPipeline* pipeline,
    const DinoXWebrtcVideoEffectConfig* config,
    uint64_t* out_revision);
DinoXWebrtcStatus video_pipeline_get_state(
    VideoPipeline* pipeline,
    DinoXWebrtcVideoPipelineState* out_state);
DinoXWebrtcStatus video_pipeline_get_diagnostics(
    VideoPipeline* pipeline,
    DinoXWebrtcVideoEffectDiagnostics* out_diagnostics);
DinoXWebrtcStatus video_pipeline_background_upload(VideoPipeline* pipeline,
    uint32_t width,uint32_t height,uint32_t stride,DinoXWebrtcBackgroundPixelFormat format,
    const uint8_t* pixels,size_t bytes,uint32_t* out_id);
DinoXWebrtcStatus video_pipeline_background_builtin(VideoPipeline* pipeline,
    DinoXWebrtcBackgroundBuiltin choice,uint32_t* out_id);
DinoXWebrtcStatus video_pipeline_background_prepare(VideoPipeline* pipeline,uint32_t id);
DinoXWebrtcStatus video_pipeline_background_release(VideoPipeline* pipeline,uint32_t id);

DinoXWebrtcStatus recorder_new(
    Context* context,
    const DinoXWebrtcMediaRecorderConfig* config,
    const DinoXWebrtcMediaRecorderCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcMediaRecorder* public_recorder,
    std::shared_ptr<Recorder>* out_recorder);
void recorder_free(std::shared_ptr<Recorder>* recorder);
DinoXWebrtcStatus recorder_start(Recorder* recorder);
DinoXWebrtcStatus recorder_stop(Recorder* recorder);
DinoXWebrtcStatus recorder_cancel(Recorder* recorder);
DinoXWebrtcStatus recorder_push_synthetic(Recorder* recorder);
DinoXWebrtcStatus recorder_get_state(Recorder* recorder, DinoXWebrtcMediaRecorderState* out_state);

}  // namespace dinox::webrtc_worker

#endif
