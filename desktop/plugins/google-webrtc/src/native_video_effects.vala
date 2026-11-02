namespace Dino.Plugins.GoogleWebrtc.Native {

[CCode (cname = "DinoXWebrtcVideoEffectType", cprefix = "DINOX_WEBRTC_VIDEO_EFFECT_", has_type_id = false)]
public enum VideoEffectType {
    NONE,
    GRAYSCALE,
    WARM_TONE,
    COLD_TONE,
    SEPIA,
    LIGHT_LEAK,
    DREAMY,
    PRISM_LIGHT,
    FISHEYE,
    VINTAGE_TV,
    FROSTED_GLASS,
    DUO_TONE,
    UNDERWATER
}

[CCode (cname = "DinoXWebrtcVideoBackgroundMode", cprefix = "DINOX_WEBRTC_VIDEO_BACKGROUND_", has_type_id = false)]
public enum VideoBackgroundMode {
    NONE,
    BLUR,
    SOLID,
    IMAGE
}

[CCode (cname = "DinoXWebrtcVideoFramingMode", cprefix = "DINOX_WEBRTC_VIDEO_FRAMING_", has_type_id = false)]
public enum VideoFramingMode {
    NONE,
    AUTO
}

[CCode (cname = "DinoXWebrtcVideoEffectQuality", cprefix = "DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_", has_type_id = false)]
public enum VideoEffectQuality {
    AUTO
}

[CCode (cname = "DinoXWebrtcVideoEffectApplicationState", cprefix = "DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_", has_type_id = false)]
public enum VideoEffectApplicationState {
    IDLE,
    ACCEPTED,
    APPLIED,
    UNAVAILABLE,
    DEGRADED,
    FAILED
}

[CCode (cname = "DinoXWebrtcVideoEffectConfig", has_type_id = false)]
public struct VideoEffectConfig {
    public uint abi_version;
    public VideoEffectType effect_type;
    public VideoEffectQuality quality;
    public uint32 preset_id;
    public uint32 asset_id;
    public uint32 reserved;
    public int32 brightness;
    public int32 contrast;
    public int32 saturation;
    public int32 sharpness;
    public VideoBackgroundMode background_mode;
    public int32 background_strength;
    public uint32 background_color_rgb;
    public VideoFramingMode framing_mode;
    public uint32 glasses_style;
    public uint32 hat_style;
    public uint32 beard_style;
    public uint32 face_accessory;
    public uint32 touch_up;
    public uint32 low_light;
    public uint32 scene_effect;
}

[CCode (cname = "DinoXWebrtcVideoEffectCapabilities", has_type_id = false)]
public struct VideoEffectCapabilities {
    public uint abi_version;
    public uint64 supported_effect_mask;
    public uint64 supported_quality_mask;
    public uint32 max_subscribers;
    public int shared_pipeline_supported;
    public int preview_publisher_supported;
    public uint32 reserved;
    public uint32 supported_adjustment_mask;
    public uint32 supported_background_mask;
    public int auto_framing_supported;
    public uint32 supported_glasses_mask;
    public uint32 supported_hat_mask;
    public uint32 supported_beard_mask;
    public uint32 supported_face_accessory_mask;
    public uint32 supported_scene_effect_mask;
    public uint32 touch_up_supported;
    public uint32 low_light_supported;
}

[CCode (cname = "DinoXWebrtcVideoPipelineState", has_type_id = false)]
public struct VideoPipelineState {
    public uint abi_version;
    public VideoEffectApplicationState application_state;
    public uint64 pipeline_id;
    public uint64 pipeline_generation;
    public uint64 logical_call_id;
    public uint64 accepted_revision;
    public uint64 applied_revision;
    public VideoEffectType effect_type;
    public VideoEffectQuality quality;
    public uint32 preset_id;
    public uint32 asset_id;
    public uint32 subscriber_count;
    public uint32 reserved;
    public uint64 preview_subscriber_id;
    public uint64 preview_subscriber_generation;
    public int32 brightness;
    public int32 contrast;
    public int32 saturation;
    public int32 sharpness;
    public VideoBackgroundMode background_mode;
    public int32 background_strength;
    public uint32 background_color_rgb;
    public VideoFramingMode framing_mode;
    public uint32 glasses_style;
    public uint32 hat_style;
    public uint32 beard_style;
    public uint32 face_accessory;
    public uint32 touch_up;
    public uint32 low_light;
    public uint32 scene_effect;
}

[CCode (cname = "DinoXWebrtcVideoEffectDiagnostics", has_type_id = false)]
public struct VideoEffectDiagnostics {
    public uint abi_version;
    public uint32 active_quality_tier;
    public uint64 captured;
    public uint64 enqueued;
    public uint64 processed;
    public uint64 bypassed;
    public uint64 queue_replaced;
    public uint64 failed;
    public uint64 watchdog_bypass;
    public uint64 quality_downgrade;
    public uint64 processing_time_total_us;
    public uint64 processing_time_max_us;
    public uint64 processing_time_p95_us;
    public uint64 processing_time_p99_us;
    public uint64 last_completed_monotonic_us;
    public uint64 stale_result_age_us;
    public uint64 loaded_model_bytes;
    public uint64 effect_owned_allocated_bytes;
    public uint64 configuration_request_count;
    public uint64 frame_copy_count;
    public uint32 logical_pipeline_count;
    public uint32 subscriber_count;
    public uint32 effect_thread_count;
    public uint32 effect_handle_count;
    public uint32 effect_mapping_count;
    public uint32 reserved;
}

[CCode (cname = "DinoXWebrtcVideoPipelineStateCallback", has_target = false)]
public delegate void VideoPipelineStateCallback(
    VideoPipeline? pipeline,
    VideoPipelineState* state,
    void* user_data);

[CCode (cname = "DinoXWebrtcVideoPipelineCallbacks", has_type_id = false)]
public struct VideoPipelineCallbacks {
    public uint abi_version;
    public VideoPipelineStateCallback? on_state_changed;
}

[CCode (cname = "dinox_webrtc_video_effect_config_default")]
public extern VideoEffectConfig video_effect_config_default();

[CCode (cname = "dinox_webrtc_context_get_video_effect_capabilities")]
public extern Status context_get_video_effect_capabilities(
    Context? context,
    out VideoEffectCapabilities out_capabilities);

[CCode (cname = "dinox_webrtc_video_pipeline_new")]
public extern Status video_pipeline_new(
    Context? context,
    uint64 logical_call_id,
    ref VideoPipelineCallbacks callbacks,
    void* user_data,
    out VideoPipeline? out_pipeline);

[CCode (cname = "dinox_webrtc_video_pipeline_attach_session")]
public extern Status video_pipeline_attach_session(
    VideoPipeline? pipeline,
    Session? session,
    int preview_publisher);

[CCode (cname = "dinox_webrtc_video_pipeline_detach_session")]
public extern Status video_pipeline_detach_session(
    VideoPipeline? pipeline,
    Session? session);

[CCode (cname = "dinox_webrtc_video_pipeline_set_config")]
public extern Status video_pipeline_set_config(
    VideoPipeline? pipeline,
    ref VideoEffectConfig config,
    out uint64 out_revision);

[CCode (cname = "dinox_webrtc_video_pipeline_get_state")]
public extern Status video_pipeline_get_state(
    VideoPipeline? pipeline,
    out VideoPipelineState out_state);

[CCode (cname = "dinox_webrtc_video_pipeline_get_diagnostics")]
public extern Status video_pipeline_get_diagnostics(
    VideoPipeline? pipeline,
    out VideoEffectDiagnostics out_diagnostics);


[CCode (cname = "DinoXWebrtcBackgroundPixelFormat", cprefix = "DINOX_WEBRTC_BACKGROUND_", has_type_id = false)]
public enum BackgroundPixelFormat { RGB888, RGBA8888 }
[CCode (cname = "DinoXWebrtcBackgroundBuiltin", cprefix = "DINOX_WEBRTC_BACKGROUND_BUILTIN_", has_type_id = false)]
public enum BackgroundBuiltin { NONE, LIVING_ROOM, OFFICE, CAFE, STONES, FOOD, ABSTRACT, BEACH, SUNSET, CELEBRATION, FOREST }
[CCode (cname = "dinox_webrtc_video_pipeline_background_upload")]
public extern Status video_pipeline_background_upload(VideoPipeline pipeline,
    uint32 width, uint32 height, uint32 stride, BackgroundPixelFormat format,
    [CCode (array_length_type = "size_t")] uint8[] pixels, out uint32 out_asset_id);
[CCode (cname = "dinox_webrtc_video_pipeline_background_builtin")]
public extern Status video_pipeline_background_builtin(VideoPipeline pipeline,
    BackgroundBuiltin choice, out uint32 out_asset_id);
[CCode (cname = "dinox_webrtc_video_pipeline_background_prepare")]
public extern Status video_pipeline_background_prepare(VideoPipeline pipeline, uint32 asset_id);
[CCode (cname = "dinox_webrtc_video_pipeline_background_release")]
public extern Status video_pipeline_background_release(VideoPipeline pipeline, uint32 asset_id);

}
