using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc.Native {

public const uint ABI_VERSION = 40;

[CCode (cname = "DinoXWebrtcStatus", cprefix = "DINOX_WEBRTC_STATUS_", has_type_id = false)]
public enum Status {
    OK,
    INVALID_ARGUMENT,
    NOT_READY,
    INTERNAL_ERROR,
    PARSE_ERROR;

    public string to_log_string() {
        return status_to_string(this);
    }
}

[CCode (cname = "DinoXWebrtcSdpType", cprefix = "DINOX_WEBRTC_SDP_TYPE_", has_type_id = false)]
public enum SdpType {
    OFFER,
    ANSWER
}

[CCode (cname = "DinoXWebrtcMediaDirection", cprefix = "DINOX_WEBRTC_MEDIA_DIRECTION_", has_type_id = false)]
public enum MediaDirection {
    SEND_RECV,
    SEND_ONLY,
    RECV_ONLY,
    INACTIVE
}

[CCode (cname = "DinoXWebrtcAudioDeviceMode", cprefix = "DINOX_WEBRTC_AUDIO_DEVICE_", has_type_id = false)]
public enum AudioDeviceMode {
    SYNTHETIC,
    PLATFORM_DEFAULT
}

[CCode (cname = "DinoXWebrtcNetworkPolicy", cprefix = "DINOX_WEBRTC_NETWORK_POLICY_", has_type_id = false)]
public enum NetworkPolicy {
    AUTOMATIC,
    LOW_BANDWIDTH_2G
}

[CCode (cname = "DinoXWebrtcPeerConnectionState", cprefix = "DINOX_WEBRTC_PEER_CONNECTION_STATE_", has_type_id = false)]
public enum PeerConnectionState {
    NEW,
    CONNECTING,
    CONNECTED,
    DISCONNECTED,
    FAILED,
    CLOSED
}

[CCode (cname = "DinoXWebrtcIceConnectionState", cprefix = "DINOX_WEBRTC_ICE_CONNECTION_STATE_", has_type_id = false)]
public enum IceConnectionState {
    NEW,
    CHECKING,
    CONNECTED,
    COMPLETED,
    FAILED,
    DISCONNECTED,
    CLOSED
}

[CCode (cname = "DinoXWebrtcMediaRecorderKind", cprefix = "DINOX_WEBRTC_MEDIA_RECORDER_KIND_", has_type_id = false)]
public enum MediaRecorderKind {
    AUDIO,
    VIDEO
}

[CCode (cname = "DinoXWebrtcMediaRecorderState", cprefix = "DINOX_WEBRTC_MEDIA_RECORDER_STATE_", has_type_id = false)]
public enum MediaRecorderState {
    IDLE,
    STARTING,
    RECORDING,
    FINALIZING,
    FAILED
}

[CCode (cname = "DinoXWebrtcBuildInfo", has_type_id = false)]
public struct BuildInfo {
    public uint abi_version;
    public uint webrtc_milestone;
    public unowned string webrtc_branch;
    public unowned string webrtc_commit;
    public unowned string artifact_abi;
    public int runtime_enabled;
}

[CCode (cname = "DinoXWebrtcSessionConfig", has_type_id = false)]
public struct SessionConfig {
    public uint abi_version;
    public int audio_enabled;
    public int video_enabled;
    public MediaDirection audio_direction;
    public MediaDirection video_direction;
    public int defer_audio_transceiver_until_answer;
    public int defer_video_transceiver_until_answer;
    public int ice_candidate_pool_size;
    public int max_bundle;
    public NetworkPolicy network_policy;
}

[CCode (cname = "DinoXWebrtcIceServer", has_type_id = false)]
public struct IceServer {
    public unowned string url;
    public unowned string? username;
    public unowned string? credential;
}

[CCode (cname = "DinoXWebrtcLocalDescriptionCallback", has_target = false)]
public delegate void LocalDescriptionCallback(Session? session, SdpType type, string? sdp, void* user_data);

[CCode (cname = "DinoXWebrtcRemoteDescriptionSetCallback", has_target = false)]
public delegate void RemoteDescriptionSetCallback(Session? session, SdpType type, void* user_data);

[CCode (cname = "DinoXWebrtcIceCandidateCallback", has_target = false)]
public delegate void IceCandidateCallback(Session? session, string? sdp_mid, int sdp_mline_index, string? candidate, void* user_data);

[CCode (cname = "DinoXWebrtcIceGatheringCompleteCallback", has_target = false)]
public delegate void IceGatheringCompleteCallback(Session? session, void* user_data);

[CCode (cname = "DinoXWebrtcErrorCallback", has_target = false)]
public delegate void ErrorCallback(Session? session, Status status, string? message, void* user_data);

[CCode (cname = "DinoXWebrtcVideoFrameCallback", has_target = false)]
public delegate void VideoFrameCallback(
    Session? session,
    uint8* bgra_data,
    int width,
    int height,
    int stride,
    uint64 frame_id,
    void* user_data);

[CCode (cname = "DinoXWebrtcCallbacks", has_type_id = false)]
public struct Callbacks {
    public uint abi_version;
    public LocalDescriptionCallback? on_local_description;
    public RemoteDescriptionSetCallback? on_remote_description_set;
    public IceCandidateCallback? on_ice_candidate;
    public IceGatheringCompleteCallback? on_ice_gathering_complete;
    public ErrorCallback? on_error;
    public VideoFrameCallback? on_video_frame;
    public VideoFrameCallback? on_local_video_frame;
    public LocalDescriptionCallback? on_local_description_prepared;
}

[CCode (cname = "DinoXWebrtcSessionState", has_type_id = false)]
public struct SessionState {
    public uint abi_version;
    public int audio_transceiver_count;
    public int video_transceiver_count;
    public int local_audio_source_attached;
    public int local_audio_track_attached;
    public int local_audio_track_enabled;
    public int local_video_source_attached;
    public int local_video_track_attached;
    public int local_video_track_enabled;
    public uint64 local_video_source_frame_count;
    public int local_video_source_last_width;
    public int local_video_source_last_height;
    public int local_video_capture_running;
    public uint64 local_video_capture_frame_count;
    public int local_video_capture_last_width;
    public int local_video_capture_last_height;
    public int remote_audio_receiver_count;
    public int remote_video_receiver_count;
    public int remote_audio_sink_count;
    public uint64 remote_audio_sink_frame_count;
    public uint64 remote_audio_sink_sample_count;
    public double remote_audio_sink_peak_level;
    public int remote_video_sink_count;
    public uint64 remote_video_sink_frame_count;
    public int remote_video_sink_last_width;
    public int remote_video_sink_last_height;
    public uint64 inbound_audio_packets_received;
    public uint64 inbound_audio_bytes_received;
    public uint64 inbound_audio_total_samples_received;
    public uint64 inbound_video_packets_received;
    public uint64 inbound_video_bytes_received;
    public uint64 inbound_video_frames_received;
    public uint64 inbound_video_frames_decoded;
    public int inbound_video_frame_width;
    public int inbound_video_frame_height;
    public uint64 outbound_audio_packets_sent;
    public uint64 outbound_audio_bytes_sent;
    public double outbound_audio_target_bitrate;
    public uint64 outbound_video_packets_sent;
    public uint64 outbound_video_bytes_sent;
    public uint64 outbound_video_frames_sent;
    public uint64 outbound_video_frames_encoded;
    public double outbound_video_target_bitrate;
    public int outbound_video_frame_width;
    public int outbound_video_frame_height;
    public double inbound_audio_level;
    public double source_audio_level;
    public double source_audio_total_energy;
    public double source_audio_total_duration;
    public uint64 stats_report_count;
    public int audio_device_initialized;
    public int audio_device_playout_initialized;
    public int audio_device_recording_initialized;
    public int audio_device_playing;
    public int audio_device_recording;
    public uint64 audio_device_capture_sample_count;
    public uint64 audio_device_capture_probe_frame_count;
    public uint64 audio_device_capture_probe_sample_count;
    public double audio_device_capture_probe_peak_level;
    public uint64 audio_device_playout_sample_count;
    public int audio_device_microphone_volume_available;
    public double audio_device_microphone_volume;
    public int audio_device_speaker_volume_available;
    public double audio_device_speaker_volume;
    public uint64 local_dtmf_feedback_start_count;
    public uint64 local_dtmf_feedback_mix_call_count;
    public uint64 local_dtmf_feedback_mixed_frame_count;
    public uint64 local_dtmf_feedback_unsupported_format_count;
    public uint local_dtmf_feedback_last_sample_rate;
    public uint local_dtmf_feedback_last_channels;
    public uint local_dtmf_feedback_last_bytes_per_sample;
    public double local_dtmf_feedback_peak_level;
    public int local_dtmf_feedback_active;
    public int ice_server_count;
    public PeerConnectionState peer_connection_state;
    public IceConnectionState ice_connection_state;
    public NetworkPolicy network_policy;
    public int audio_sender_bitrate_cap_bps;
    public int audio_sender_adaptive_ptime;
    public int audio_sender_policy_applied;
}

[CCode (cname = "DinoXWebrtcMediaRecorderConfig", has_type_id = false)]
public struct MediaRecorderConfig {
    public uint abi_version;
    public MediaRecorderKind kind;
    public unowned string? output_path;
    public unowned string? mime_type;
    public int width;
    public int height;
    public int max_fps;
    public unowned string? video_device_unique_id;
    public int include_audio_track;
}

[CCode (cname = "DinoXWebrtcMediaRecorderEventCallback", has_target = false)]
public delegate void MediaRecorderEventCallback(MediaRecorder? recorder, void* user_data);

[CCode (cname = "DinoXWebrtcMediaRecorderErrorCallback", has_target = false)]
public delegate void MediaRecorderErrorCallback(MediaRecorder? recorder, Status status, string? message, void* user_data);

[CCode (cname = "DinoXWebrtcMediaRecorderAudioFrameCallback", has_target = false)]
public delegate void MediaRecorderAudioFrameCallback(
    MediaRecorder? recorder,
    uint8* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    uint64 frame_id,
    void* user_data);

[CCode (cname = "DinoXWebrtcMediaRecorderVideoFrameCallback", has_target = false)]
public delegate void MediaRecorderVideoFrameCallback(
    MediaRecorder? recorder,
    uint8* bgra_data,
    int width,
    int height,
    int stride,
    uint64 frame_id,
    void* user_data);

[CCode (cname = "DinoXWebrtcMediaRecorderCallbacks", has_type_id = false)]
public struct MediaRecorderCallbacks {
    public uint abi_version;
    public MediaRecorderEventCallback? on_started;
    public MediaRecorderEventCallback? on_stopped;
    public MediaRecorderErrorCallback? on_error;
    public MediaRecorderAudioFrameCallback? on_audio_frame;
    public MediaRecorderVideoFrameCallback? on_video_frame;
}

[CCode (cname = "dinox_webrtc_get_build_info")]
public extern unowned BuildInfo? get_build_info();

[CCode (cname = "dinox_webrtc_status_to_string")]
public extern unowned string status_to_string(Status status);

[CCode (cname = "dinox_webrtc_session_config_default")]
public extern SessionConfig session_config_default();

[CCode (cname = "dinox_webrtc_callbacks_default")]
public extern Callbacks callbacks_default();

[CCode (cname = "dinox_webrtc_media_recorder_config_default")]
public extern MediaRecorderConfig media_recorder_config_default();

[CCode (cname = "dinox_webrtc_media_recorder_callbacks_default")]
public extern MediaRecorderCallbacks media_recorder_callbacks_default();

[CCode (cname = "dinox_webrtc_context_new")]
public extern Status context_new(out Context? out_context);

[CCode (cname = "dinox_webrtc_context_new_with_audio_device_mode")]
public extern Status context_new_with_audio_device_mode(AudioDeviceMode audio_device_mode, out Context? out_context);

[CCode (cname = "dinox_webrtc_context_get_audio_device_count")]
public extern Status context_get_audio_device_count(Context? context, int incoming, out int out_count);

[CCode (cname = "dinox_webrtc_context_get_audio_device_name")]
public extern Status context_get_audio_device_name(
    Context? context,
    int incoming,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_guid,
    size_t out_guid_size);

[CCode (cname = "dinox_webrtc_context_set_audio_device")]
public extern Status context_set_audio_device(Context? context, int incoming, int index);

[CCode (cname = "dinox_webrtc_context_get_audio_device_volume")]
public extern Status context_get_audio_device_volume(Context? context, int incoming, out double out_volume, out int out_available);

[CCode (cname = "dinox_webrtc_context_set_audio_device_volume")]
public extern Status context_set_audio_device_volume(Context? context, int incoming, double volume);

[CCode (cname = "dinox_webrtc_context_play_test_tone")]
public extern Status context_play_test_tone(Context? context, char digit, uint duration_ms);

[CCode (cname = "dinox_webrtc_context_play_audio_test_clip")]
public extern Status context_play_audio_test_clip(
    Context? context,
    uint8* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    out uint out_duration_ms);

[CCode (cname = "dinox_webrtc_context_stop_audio_test_playout")]
public extern Status context_stop_audio_test_playout(Context? context);

[CCode (cname = "dinox_webrtc_context_media_audio_playout_start")]
public extern Status context_media_audio_playout_start(
    Context? context,
    int sample_rate,
    int channels,
    int bytes_per_sample);

[CCode (cname = "dinox_webrtc_context_media_audio_playout_push")]
public extern Status context_media_audio_playout_push(
    Context? context,
    uint8* pcm_data,
    size_t byte_count,
    out uint out_queued_duration_ms);

[CCode (cname = "dinox_webrtc_context_media_audio_playout_set_paused")]
public extern Status context_media_audio_playout_set_paused(Context? context, int paused);

[CCode (cname = "dinox_webrtc_context_media_audio_playout_flush")]
public extern Status context_media_audio_playout_flush(Context? context);

[CCode (cname = "dinox_webrtc_context_media_audio_playout_finish")]
public extern Status context_media_audio_playout_finish(
    Context? context,
    out uint out_queued_duration_ms);

[CCode (cname = "dinox_webrtc_context_media_audio_playout_stop")]
public extern Status context_media_audio_playout_stop(Context? context);

[CCode (cname = "dinox_webrtc_context_get_video_device_count")]
public extern Status context_get_video_device_count(Context? context, out int out_count);

[CCode (cname = "dinox_webrtc_context_get_video_device_name")]
public extern Status context_get_video_device_name(
    Context? context,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_unique_id,
    size_t out_unique_id_size,
    char* out_product_id,
    size_t out_product_id_size);

[CCode (cname = "dinox_webrtc_session_new")]
public extern Status session_new(
    Context? context,
    ref SessionConfig config,
    ref Callbacks callbacks,
    void* user_data,
    out Session? out_session);

[CCode (cname = "dinox_webrtc_session_add_ice_server")]
public extern Status session_add_ice_server(Session? session, string url, string? username, string? credential);

[CCode (cname = "dinox_webrtc_session_create_offer")]
public extern Status session_create_offer(Session? session);

[CCode (cname = "dinox_webrtc_session_create_answer")]
public extern Status session_create_answer(Session? session);

[CCode (cname = "dinox_webrtc_session_prepare_local_description")]
public extern Status session_prepare_local_description(Session? session, SdpType type);

[CCode (cname = "dinox_webrtc_session_set_local_description")]
public extern Status session_set_local_description(Session? session, SdpType type, string sdp);

[CCode (cname = "dinox_webrtc_session_set_remote_description")]
public extern Status session_set_remote_description(Session? session, SdpType type, string sdp);

[CCode (cname = "dinox_webrtc_session_add_remote_ice_candidate")]
public extern Status session_add_remote_ice_candidate(
    Session? session,
    string sdp_mid,
    int sdp_mline_index,
    string candidate);

[CCode (cname = "dinox_webrtc_session_set_local_audio_enabled")]
public extern Status session_set_local_audio_enabled(Session? session, int enabled);

[CCode (cname = "dinox_webrtc_session_set_local_video_enabled")]
public extern Status session_set_local_video_enabled(Session? session, int enabled);

[CCode (cname = "dinox_webrtc_session_send_dtmf")]
public extern Status session_send_dtmf(Session? session, char digit, uint duration_ms);

[CCode (cname = "dinox_webrtc_session_play_local_dtmf_feedback")]
public extern Status session_play_local_dtmf_feedback(Session? session, char digit, uint duration_ms);

[CCode (cname = "dinox_webrtc_session_push_synthetic_video_frame")]
public extern Status session_push_synthetic_video_frame(Session? session, int width, int height);

[CCode (cname = "dinox_webrtc_session_start_video_capture")]
public extern Status session_start_video_capture(Session? session, string device_unique_id, int width, int height, int max_fps);

[CCode (cname = "dinox_webrtc_session_stop_video_capture")]
public extern Status session_stop_video_capture(Session? session);

[CCode (cname = "dinox_webrtc_session_get_state")]
public extern Status session_get_state(Session? session, out SessionState out_state);

[CCode (cname = "dinox_webrtc_session_close")]
public extern Status session_close(Session? session);

[CCode (cname = "dinox_webrtc_media_recorder_new")]
public extern Status media_recorder_new(
    Context? context,
    ref MediaRecorderConfig config,
    ref MediaRecorderCallbacks callbacks,
    void* user_data,
    out MediaRecorder? out_recorder);

[CCode (cname = "dinox_webrtc_media_recorder_start")]
public extern Status media_recorder_start(MediaRecorder? recorder);

[CCode (cname = "dinox_webrtc_media_recorder_stop")]
public extern Status media_recorder_stop(MediaRecorder? recorder);

[CCode (cname = "dinox_webrtc_media_recorder_cancel")]
public extern Status media_recorder_cancel(MediaRecorder? recorder);

[CCode (cname = "dinox_webrtc_media_recorder_push_synthetic_frame")]
public extern Status media_recorder_push_synthetic_frame(MediaRecorder? recorder);

[CCode (cname = "dinox_webrtc_media_recorder_get_state")]
public extern Status media_recorder_get_state(MediaRecorder? recorder, out MediaRecorderState out_state);

public static SdpType sdp_type_to_native(JingleRtp.LibwebrtcSdpType type) {
    switch (type) {
        case JingleRtp.LibwebrtcSdpType.OFFER:
            return SdpType.OFFER;
        case JingleRtp.LibwebrtcSdpType.ANSWER:
            return SdpType.ANSWER;
        default:
            assert_not_reached();
    }
}

public static JingleRtp.LibwebrtcSdpType sdp_type_from_native(SdpType type) {
    switch (type) {
        case SdpType.OFFER:
            return JingleRtp.LibwebrtcSdpType.OFFER;
        case SdpType.ANSWER:
            return JingleRtp.LibwebrtcSdpType.ANSWER;
        default:
            assert_not_reached();
    }
}

public static MediaDirection media_direction_to_native(JingleRtp.SdpMediaDirection direction) {
    switch (direction) {
        case JingleRtp.SdpMediaDirection.SEND_RECV:
            return MediaDirection.SEND_RECV;
        case JingleRtp.SdpMediaDirection.SEND_ONLY:
            return MediaDirection.SEND_ONLY;
        case JingleRtp.SdpMediaDirection.RECV_ONLY:
            return MediaDirection.RECV_ONLY;
        case JingleRtp.SdpMediaDirection.INACTIVE:
            return MediaDirection.INACTIVE;
        default:
            assert_not_reached();
    }
}

}
