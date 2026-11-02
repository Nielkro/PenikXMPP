/**
 * MqttUtils — Pure utility functions for the MQTT plugin.
 *
 * All methods are static and free of runtime/DB/UI dependencies.
 * This enables standalone unit testing without the full plugin.
 *
 * Extracted from: alert_manager.vala, bridge_manager.vala, bot_conversation.vala
 */

namespace Dino.Plugins.Mqtt {

public class MqttUtils : Object {

    /**
     * Detect if a text payload looks like an HTML page.
     * Checks for common HTML markers in the first 512 bytes.
     */
    public static bool is_html_payload(string text) {
        if (text.length < 15) return false;
        string head = text.substring(0, int.min(512, text.length)).ascii_down();
        return head.contains("<!doctype html") || head.contains("<html")
            || head.contains("<head>") || head.contains("<head ")
            || head.contains("<meta ");
    }

    /**
     * Detect M3U/PLS playlist content and extract the first stream URL.
     * Returns the stream URL or null if not a playlist.
     */
    public static string? extract_stream_url(string text) {
        if (text.length < 10) return null;
        /* Strip Unicode replacement chars (U+FFFD) that make_valid() inserts
         * for binary garbage at the end of HTTP responses from Node-RED. */
        string cleaned = text.replace("\xef\xbf\xbd", "");
        string trimmed = cleaned.strip();
        string lower = trimmed.ascii_down();

        /* M3U: starts with #EXTM3U or first non-comment line is a URL */
        if (lower.has_prefix("#extm3u") || lower.has_prefix("#extinf")) {
            int line_count = 0;
            foreach (string line in trimmed.split("\n")) {
                if (++line_count > 100) break;
                string l = line.strip().replace("\xef\xbf\xbd", "");
                if (l.has_prefix("http://") || l.has_prefix("https://")) {
                    try {
                        GLib.Uri.parse(l, GLib.UriFlags.NONE);
                        return l;
                    } catch { return null; }
                }
            }
            return null;
        }

        /* PLS: starts with [playlist] */
        if (lower.has_prefix("[playlist]")) {
            int line_count = 0;
            foreach (string line in trimmed.split("\n")) {
                if (++line_count > 100) break;
                string l = line.strip();
                /* File1=http://... */
                if (l.ascii_down().has_prefix("file") && l.contains("=")) {
                    string val = l.substring(l.index_of("=") + 1).strip().replace("\xef\xbf\xbd", "");
                    if (val.has_prefix("http://") || val.has_prefix("https://")) {
                        try {
                            GLib.Uri.parse(val, GLib.UriFlags.NONE);
                            return val;
                        } catch { return null; }
                    }
                }
            }
            return null;
        }

        /* Direct URL to a stream/playlist file (.m3u, .m3u8, .pls, .xspf)
         * e.g. https://frontend.streamonkey.net/antthue-90er/mp3-stream.m3u */
        if ((lower.has_prefix("http://") || lower.has_prefix("https://"))
            && !trimmed.contains("\n")) {
            /* Check for stream-related file extensions or path patterns */
            string path_lower = lower;
            /* Strip query string for extension check */
            int qpos = path_lower.index_of("?");
            if (qpos > 0) path_lower = path_lower.substring(0, qpos);
            if (path_lower.has_suffix(".m3u") || path_lower.has_suffix(".m3u8")
                || path_lower.has_suffix(".pls") || path_lower.has_suffix(".xspf")) {
                try {
                    GLib.Uri.parse(trimmed, GLib.UriFlags.NONE);
                    return trimmed;
                } catch { return null; }
            }
        }

        return null;
    }

    public static string join_strings(string separator, Gee.Collection<string> values) {
        string[] parts = new string[values.size];
        int i = 0;
        foreach (string value in values) {
            parts[i++] = value;
        }
        return string.joinv(separator, parts);
    }

    /**
     * MQTT 3.1.1 §4.7 — Topic filter matching with wildcards.
     *
     * Supports:
     *   - Exact match: "home/temp" matches "home/temp"
     *   - Single-level wildcard (+): "home/+/temp" matches "home/living/temp"
     *   - Multi-level wildcard (#): "home/#" matches "home" and descendants
     *   - Root wildcard: "#" matches every non-system topic
     *
     * @param pattern  The topic filter pattern (may contain + and #)
     * @param topic    The incoming concrete topic name
     * @return true if the topic matches the filter pattern
     */
    public static bool topic_matches(string pattern, string topic) {
        /* Topic names and filters must contain at least one character.
         * Incoming topic names must never contain wildcard characters. */
        if (pattern == "" || topic == ""
                || topic.contains("#") || topic.contains("+")) {
            return false;
        }

        string[] rule_parts = pattern.split("/");
        string[] topic_parts = topic.split("/");

        /* Wildcards must occupy an entire level and '#' must be the final
         * level of the filter (MQTT 3.1.1 §4.7.1). */
        for (int i = 0; i < rule_parts.length; i++) {
            string part = rule_parts[i];
            if (part.contains("#") && (part != "#" || i != rule_parts.length - 1)) {
                return false;
            }
            if (part.contains("+") && part != "+") {
                return false;
            }
        }

        /* A filter whose first level is a wildcard does not match topics
         * beginning with '$' (MQTT 3.1.1 §4.7.2). */
        if (topic.has_prefix("$")
                && (rule_parts[0] == "#" || rule_parts[0] == "+")) {
            return false;
        }

        int ti = 0;
        for (int ri = 0; ri < rule_parts.length; ri++) {
            /* '#' matches zero or more remaining levels. This deliberately
             * makes "example/topic/#" match both "example/topic" and every
             * descendant below it. */
            if (rule_parts[ri] == "#") return true;

            if (ti >= topic_parts.length) return false;
            if (rule_parts[ri] != "+" && rule_parts[ri] != topic_parts[ti]) {
                return false;
            }
            ti++;
        }

        return ti == topic_parts.length;
    }

    /**
     * Prosody topic format conversion.
     *
     * Prosody mod_pubsub_mqtt uses topic format: HOST/pubsub/NODE
     * (e.g. "pubsub.example.org/pubsub/sensors").
     *
     * This converts to human-readable: "sensors (PubSub@pubsub.example.org)"
     *
     * Non-Prosody topics are returned unchanged.
     *
     * @param topic  The MQTT topic string
     * @return Human-readable topic display string
     */
    public static string format_topic_display(string topic) {
        if (topic.contains("/pubsub/")) {
            int pubsub_idx = topic.index_of("/pubsub/");
            if (pubsub_idx > 0) {
                string host = topic.substring(0, pubsub_idx);
                string node = topic.substring(pubsub_idx + 8);  /* skip /pubsub/ */
                if (host.contains(".") && node.length > 0) {
                    return "%s (PubSub@%s)".printf(node, host);
                }
            }
        }
        return topic;
    }

    /**
     * Extract a numeric value from a payload string.
     *
     * Attempts:
     *   1. Direct double parse of the trimmed string
     *   2. JSON: first numeric field value from a JSON object
     *
     * @param payload  The MQTT message payload
     * @return The numeric value, or null if not extractable
     */
    public static double? try_extract_numeric(string payload) {
        string trimmed = payload.strip();

        /* Empty string is not numeric */
        if (trimmed == "") return null;

        /* Try direct parse */
        double val;
        if (double.try_parse(trimmed, out val)) {
            return val;
        }

        /* Try JSON: first numeric field */
        if (trimmed.has_prefix("{")) {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(trimmed, -1);
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                    var obj = root.get_object();
                    foreach (string member in obj.get_members()) {
                        var node = obj.get_member(member);
                        if (node.get_node_type() == Json.NodeType.VALUE) {
                            var vt = node.get_value_type();
                            if (vt == typeof(double)) {
                                return node.get_double();
                            } else if (vt == typeof(int64)) {
                                return (double) node.get_int();
                            }
                        }
                    }
                }
            } catch (GLib.Error e) {
                debug("MqttUtils.try_extract_numeric: JSON parse failed: %s", e.message);
            }
        }

        return null;
    }

    /**
     * Unicode sparkline block characters (8 levels).
     * Index 0 = lowest bar, index 7 = highest bar.
     */
    public const string[] SPARK_CHARS = {
        "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"
    };

    /**
     * Build a Unicode sparkline string from numeric values.
     *
     * Maps values to 8-level block characters based on min/max range.
     * Returns null if fewer than 2 values are provided.
     *
     * @param values  Array of numeric values
     * @return Sparkline string, or null if insufficient data
     */
    public static string? build_sparkline(double[] values) {
        if (values.length < 2) return null;

        double min_val = values[0];
        double max_val = values[0];
        for (int i = 1; i < values.length; i++) {
            if (values[i] < min_val) min_val = values[i];
            if (values[i] > max_val) max_val = values[i];
        }

        double range = max_val - min_val;
        if (range < 0.001) range = 1.0;  /* avoid div by zero for constant values */

        var sb = new StringBuilder();
        foreach (double v in values) {
            int idx = (int) (((v - min_val) / range) * 7.0 + 0.5);
            if (idx < 0) idx = 0;
            if (idx > 7) idx = 7;
            sb.append(SPARK_CHARS[idx]);
        }

        return sb.str;
    }

    /**
     * Sparkline statistics: min, max, average.
     *
     * @param values  Array of numeric values (must be non-empty)
     * @param out_min  Output: minimum value
     * @param out_max  Output: maximum value
     * @param out_avg  Output: average value
     */
    public static void sparkline_stats(double[] values,
                                       out double out_min,
                                       out double out_max,
                                       out double out_avg) {
        if (values.length == 0) {
            out_min = 0;
            out_max = 0;
            out_avg = 0;
            return;
        }
        out_min = values[0];
        out_max = values[0];
        double sum = 0;
        foreach (double v in values) {
            if (v < out_min) out_min = v;
            if (v > out_max) out_max = v;
            sum += v;
        }
        out_avg = sum / values.length;
    }

    /**
     * Truncate a string to a maximum length, appending "..." if truncated.
     *
     * @param s        The input string
     * @param max_len  Maximum allowed length (must be > 3)
     * @return The original or truncated string
     */
    public static string truncate_string(string s, int max_len) {
        if (max_len <= 3) return s;
        if (s.length <= max_len) return s;
        return s.substring(0, max_len - 3) + "...";
    }

    /**
     * Format a bridge message according to the specified format type.
     *
     * Formats:
     *   - "payload": Raw payload only
     *   - "short":   "[topic] payload" (truncated to 200 chars)
     *   - "full":    "MQTT [topic]\npayload" (default)
     *
     * @param format_type  One of "full", "payload", "short"
     * @param topic_name   The MQTT topic
     * @param payload      The message payload
     * @return Formatted message string
     */
    public static string format_bridge_message(string format_type,
                                                string topic_name,
                                                string payload) {
        switch (format_type) {
            case "payload":
                return payload;
            case "short":
                return "[%s] %s".printf(topic_name, truncate_string(payload, 200));
            default: /* "full" */
                return "MQTT [%s]\n%s".printf(topic_name, payload);
        }
    }

    /**
     * Check if a host string refers to a local/private network address.
     *
     * Returns true for:
     *   - localhost, 127.0.0.1, ::1
     *   - RFC 1918 private ranges: 10.x, 192.168.x, 172.16-31.x
     *   - Common local domain suffixes: .local, .lan, .home
     */
    public static bool is_local_host(string host) {
        string h = host.down().strip();
        if (h == "" ) return true;  /* empty = probably auto-detect → local */
        if (h == "localhost" || h == "127.0.0.1" || h == "::1") return true;
        if (h.has_prefix("192.168.")) return true;
        if (h.has_prefix("10.")) return true;
        if (h.has_prefix("172.")) {
            string[] parts = h.split(".");
            if (parts.length >= 2) {
                int second = int.parse(parts[1]);
                if (second >= 16 && second <= 31) return true;
            }
        }
        if (h.has_suffix(".local") || h.has_suffix(".lan") || h.has_suffix(".home")) return true;
        return false;
    }

    /**
     * Safe wrapper for getting current UTC time as Unix timestamp.
     *
     * new DateTime.now_utc() can return NULL in edge cases (timezone
     * database issues, system clock problems), which causes a
     * GLib-CRITICAL when .to_unix() is called on it.
     *
     * Returns: Current Unix timestamp, or 0 if the system clock is unavailable.
     */
    public static int64 now_unix() {
        DateTime? dt = new DateTime.now_utc();
        if (dt == null) {
            warning("MqttUtils.now_unix: DateTime.now_utc() returned NULL!");
            return 0;
        }
        return dt.to_unix();
    }
}

} // namespace
