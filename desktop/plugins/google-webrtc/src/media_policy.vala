namespace Dino.Plugins.GoogleWebrtc {

/**
 * Development-engine media policy for the Google/libwebrtc call path.
 *
 * This is deliberately separate from the native wrapper. DinoX may express
 * codec preference and fallback policy, but runtime bandwidth adaptation,
 * packet-loss handling, frame-rate changes and resolution changes must remain
 * owned by libwebrtc.
 */
public class EngineMediaPolicy : Object {
    public const string PREFERRED_AUDIO_CODEC = "opus";
    public const string PREFERRED_VIDEO_CODEC = "VP8";
    public const bool VIDEO_CODEC_FALLBACKS_ALLOWED = true;
    public const bool AUDIO_ONLY_FALLBACK_ALLOWED = true;
    public const bool LIBWEBRTC_OWNS_RUNTIME_ADAPTATION = true;

    public static bool is_preferred_video_codec(string? codec_name) {
        return normalize_codec(codec_name) == "vp8";
    }

    public static bool is_video_fallback_codec(string? codec_name) {
        // This class ranks codec preferences; native SDP determines which
        // codecs the loaded runtime actually supports.
        string normalized = normalize_codec(codec_name);
        return normalized == "h264" ||
            normalized == "vp9" ||
            normalized == "av1";
    }

    public static int video_codec_preference_rank(string? codec_name) {
        if (is_preferred_video_codec(codec_name)) return 0;
        if (is_video_fallback_codec(codec_name)) return 1;
        return 2;
    }

    private static string normalize_codec(string? codec_name) {
        if (codec_name == null) return "";
        return ((!) codec_name).strip().ascii_down().replace(".", "").replace("-", "");
    }
}

}
