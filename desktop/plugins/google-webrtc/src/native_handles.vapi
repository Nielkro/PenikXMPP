[CCode (cheader_filename = "native_handles.h")]
namespace Dino.Plugins.GoogleWebrtc.Native {

[CCode (cname = "DinoXWebrtcContext", free_function = "dinox_webrtc_context_free", has_type_id = false)]
[Compact]
public class Context {
}

[CCode (cname = "DinoXWebrtcSession", free_function = "dinox_webrtc_session_free", has_type_id = false)]
[Compact]
public class Session {
}

[CCode (cname = "DinoXWebrtcVideoPipeline", free_function = "dinox_webrtc_video_pipeline_free", has_type_id = false)]
[Compact]
public class VideoPipeline {
}

[CCode (cname = "DinoXWebrtcMediaRecorder", free_function = "dinox_webrtc_media_recorder_free", has_type_id = false)]
[Compact]
public class MediaRecorder {
}

}
