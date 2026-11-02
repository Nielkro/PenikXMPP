#ifndef DINOX_GOOGLE_WEBRTC_NATIVE_HANDLES_H
#define DINOX_GOOGLE_WEBRTC_NATIVE_HANDLES_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DinoXWebrtcContext DinoXWebrtcContext;
typedef struct DinoXWebrtcSession DinoXWebrtcSession;
typedef struct DinoXWebrtcVideoPipeline DinoXWebrtcVideoPipeline;
typedef struct DinoXWebrtcMediaRecorder DinoXWebrtcMediaRecorder;

void dinox_webrtc_context_free(DinoXWebrtcContext* context);
void dinox_webrtc_session_free(DinoXWebrtcSession* session);
void dinox_webrtc_video_pipeline_free(DinoXWebrtcVideoPipeline* pipeline);
void dinox_webrtc_media_recorder_free(DinoXWebrtcMediaRecorder* recorder);

#ifdef __cplusplus
}
#endif

#endif  // DINOX_GOOGLE_WEBRTC_NATIVE_HANDLES_H
