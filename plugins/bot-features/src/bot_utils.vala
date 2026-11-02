// Static utility functions shared across bot-features plugin modules.
// Extracted from ai_integration.vala / telegram_bridge.vala / ejabberd_api.vala
// to eliminate code duplication (clone detection).

namespace Dino.Plugins.BotFeatures.BotUtils {

    [CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
    private extern static void soup_server_message_set_response_text(Soup.ServerMessage msg, string? content_type, Soup.MemoryUse resp_use, string resp_body, size_t resp_length);

    public class BotMucRoom : Object {
        public string room_jid { get; private set; }
        public string nick { get; private set; }

        public BotMucRoom(string room_jid, string nick) {
            this.room_jid = room_jid;
            this.nick = nick;
        }
    }

    // RFC 8259 compliant JSON string escaping (BUG-05 fix)
    public static string escape_json(string s) {
        string safe = s.validate() ? s : s.make_valid();
        var sb = new StringBuilder.sized(safe.length);
        int byte_index = 0;
        unichar c;
        while (safe.get_next_char(ref byte_index, out c)) {
            if (c == '\\') sb.append("\\\\");
            else if (c == '"') sb.append("\\\"");
            else if (c == '\n') sb.append("\\n");
            else if (c == '\r') sb.append("\\r");
            else if (c == '\t') sb.append("\\t");
            else if (c < 0x20) sb.append("\\u%04x".printf(c));
            else sb.append_unichar(c);
        }
        return sb.str;
    }

    public static string truncate_utf8(string text, int max_chars) {
        string safe = text.validate() ? text : text.make_valid();
        int limit = int.max(max_chars, 0);
        if (safe.char_count() <= limit) return safe;
        return safe.substring(0, safe.index_of_nth_char(limit)) + "...";
    }

    public static bool has_permission(BotInfo bot, string scope) {
        string permissions = bot.permissions ?? "all";
        foreach (string raw_part in permissions.split(",")) {
            string part = raw_part.strip();
            if (part == "all" || part == scope) return true;
        }
        return false;
    }

    public static string join_strings(string separator, Gee.Collection<string> values) {
        string[] parts = new string[values.size];
        int i = 0;
        foreach (string value in values) {
            parts[i++] = value;
        }
        return string.joinv(separator, parts);
    }

    public static void set_json_response(Soup.ServerMessage msg, string json) {
        soup_server_message_set_response_text(msg, "application/json", Soup.MemoryUse.COPY, json, json.length);
    }

    public static bool can_receive_updates(BotInfo? bot) {
        return bot != null && bot.status == "active" && has_permission(bot, "receive_updates");
    }

    public static bool can_receive_updates_for_enabled_account(BotInfo? bot, BotRegistry? registry) {
        if (!can_receive_updates(bot)) return false;
        return is_owner_account_enabled(bot, registry);
    }

    public static bool is_owner_account_enabled(BotInfo? bot, BotRegistry? registry) {
        if (bot == null) return false;
        if (registry == null) return true;

        string owner_jid = bot.owner_jid ?? "";
        if (owner_jid.strip() == "") return true;

        string? val = registry.get_setting("botmother_account_enabled:" + owner_jid.strip());
        return val == null || val == "true";
    }

    public static bool can_process_dedicated_inbound_command(BotInfo? bot, BotRegistry? registry) {
        return bot != null && bot.status == "active" && is_owner_account_enabled(bot, registry);
    }

    public static bool is_owner_jid(BotInfo bot, string from_jid) {
        string? owner = bot.owner_jid;
        if (owner == null || owner.strip() == "" || from_jid.strip() == "") return false;
        return bare_jid(owner) == bare_jid(from_jid);
    }

    private static string bare_jid(string jid) {
        return jid.strip().split("/", 2)[0];
    }

    public static bool is_valid_telegram_mode(string mode) {
        return mode == "bridge" || mode == "forward";
    }

    public static bool is_valid_muc_ai_mode(string mode) {
        return mode == "mention_only" || mode == "support_questions" || mode == "active_support";
    }

    public static bool is_legacy_aesgcm_file_url(string? body) {
        if (body == null) return false;

        string text = ((!) body).strip();
        if (text == "" || text.contains(" ") || text.contains("\n") || text.contains("\r") || text.contains("\t")) {
            return false;
        }

        try {
            Regex aesgcm_url_regex = new Regex("^aesgcm://[^\\s#]+#[0-9A-Fa-f]+$");
            return aesgcm_url_regex.match(text);
        } catch (Error e) {
            return false;
        }
    }

    public static bool should_dedicated_group_ai_reply(BotInfo bot, string body, bool bot_mentioned, string mode) {
        if (bot_mentioned) return true;

        string normalized_mode = is_valid_muc_ai_mode(mode) ? mode : "mention_only";
        if (normalized_mode == "mention_only") return false;

        string text = body.down();
        bool support_topic = contains_support_topic(text);
        bool likely_question = contains_question_signal(text);
        if (normalized_mode == "support_questions") {
            return support_topic && likely_question;
        }

        if (normalized_mode == "active_support") {
            if (support_topic && likely_question) return true;
            if (support_topic && contains_problem_signal(text)) return true;
        }
        return false;
    }

    public static bool dedicated_group_message_mentions_owner(BotInfo bot, string body) {
        string? owner = bot.owner_jid;
        if (owner == null || owner.strip() == "") return false;

        string haystack = body.down();
        string bare_owner = bare_jid(owner).down();
        if (contains_mention_token(haystack, bare_owner)) return true;

        if (bare_owner.contains("@")) {
            string localpart = bare_owner.split("@", 2)[0];
            if (localpart != "" && contains_mention_token(haystack, localpart)) return true;
        }

        return false;
    }

    public static bool should_notify_owner_about_group_mention(BotInfo bot, string body, bool bot_mentioned) {
        if (bot_mentioned) return false;
        return dedicated_group_message_mentions_owner(bot, body);
    }

    public static bool dedicated_group_message_mentions_bot(BotInfo bot, string body) {
        string haystack = body.down();
        string? bot_name = bot.name != null ? bot.name.strip() : null;
        if (bot_name != null && bot_name != "") {
            string name = bot_name.down();
            if (contains_mention_token(haystack, "@" + name) ||
                    contains_mention_token(haystack, name) ||
                    haystack.has_prefix(name + ":") ||
                    haystack.contains(" " + name + ":")) {
                return true;
            }
        }

        if (bot.jid != null && bot.jid.contains("@")) {
            string localpart = bot.jid.split("@", 2)[0].down();
            if (localpart != "" && (
                    contains_mention_token(haystack, "@" + localpart) ||
                    contains_mention_token(haystack, localpart) ||
                    contains_mention_token(haystack, bot.jid.down()))) {
                return true;
            }
        }
        return false;
    }

    private static bool contains_mention_token(string haystack, string needle) {
        if (needle == "") return false;

        int offset = 0;
        while (offset < haystack.length) {
            int index = haystack.index_of(needle, offset);
            if (index < 0) return false;

            int after = index + needle.length;
            bool before_ok = index == 0 || !is_mention_word_char(haystack[index - 1]);
            bool after_ok = after >= haystack.length || !is_mention_word_char(haystack[after]);
            if (before_ok && after_ok) return true;

            offset = index + 1;
        }
        return false;
    }

    private static bool is_mention_word_char(char c) {
        return (c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') ||
            c == '_' || c == '-' || c == '.';
    }

    private static bool contains_support_topic(string text) {
        string[] topics = {
            "dinox", "xmpp", "jabber", "omemo", "omemo2", "muc", "gruppenchat",
            "group chat", "ejabberd", "prosody", "gajim", "conversations",
            "monal", "monocles", "flatpak", "appimage", "debian", "ubuntu",
            "gtk", "adwaita", "gstreamer", "webrtc", "jingle", "audio", "video",
            "benachrichtigung", "notification", "systray", "sni", "mqtt", "socks5", "tor"
        };
        foreach (string topic in topics) {
            if (topic.contains(" ")) {
                if (text.contains(topic)) return true;
            } else if (contains_mention_token(text, topic)) {
                return true;
            }
        }
        return false;
    }

    private static bool contains_question_signal(string text) {
        if (text.contains("?")) return true;
        string[] words = {
            "wie", "was", "warum", "wieso", "weshalb", "welche", "welcher", "welches",
            "wo", "wann", "kann", "könnte", "soll", "sollte", "hilfe", "help",
            "info", "infos", "information", "informationen", "erkläre", "erklaere",
            "empfiehl", "empfehle", "recommend", "how", "what", "why", "which",
            "where", "when", "can", "could", "should"
        };
        foreach (string word in words) {
            if (contains_mention_token(text, word)) return true;
        }
        return false;
    }

    private static bool contains_problem_signal(string text) {
        string[] words = {
            "problem", "bug", "fehler", "crash", "absturz", "geht nicht", "funktioniert nicht",
            "kaputt", "warning", "error", "failed", "timeout", "trace", "speicherzugriff",
            "broken", "issue", "does not work", "not working"
        };
        foreach (string word in words) {
            if (text.contains(word)) return true;
        }
        return false;
    }

    public static string muc_rooms_setting_key(int bot_id) {
        return "bot_%d_muc_rooms".printf(bot_id);
    }

    public static Gee.ArrayList<BotMucRoom> get_muc_rooms(BotRegistry registry, int bot_id) {
        var result = new Gee.ArrayList<BotMucRoom>();
        string? raw = registry.get_setting(muc_rooms_setting_key(bot_id));
        if (raw == null || raw.strip() == "") return result;

        foreach (string line in raw.split("\n")) {
            string trimmed = line.strip();
            if (trimmed == "") continue;
            string[] parts = trimmed.split("\t", 2);
            string room = normalize_room_jid(parts[0]);
            if (room == "") continue;
            string nick = parts.length > 1 ? sanitize_room_nick(parts[1]) : "";
            result.add(new BotMucRoom(room, nick));
        }
        return result;
    }

    public static void remember_muc_room(BotRegistry registry, int bot_id, string room_jid, string? nick) {
        string room = normalize_room_jid(room_jid);
        if (room == "") return;
        string clean_nick = sanitize_room_nick(nick ?? "");

        var rooms = get_muc_rooms(registry, bot_id);
        bool replaced = false;
        var lines = new Gee.ArrayList<string>();
        foreach (BotMucRoom entry in rooms) {
            if (entry.room_jid.down() == room.down()) {
                lines.add(room + "\t" + clean_nick);
                replaced = true;
            } else {
                lines.add(entry.room_jid + "\t" + entry.nick);
            }
        }
        if (!replaced) {
            lines.add(room + "\t" + clean_nick);
        }
        registry.set_setting(muc_rooms_setting_key(bot_id), join_strings("\n", lines));
    }

    public static void forget_muc_room(BotRegistry registry, int bot_id, string room_jid) {
        string room = normalize_room_jid(room_jid);
        if (room == "") return;

        var rooms = get_muc_rooms(registry, bot_id);
        var lines = new Gee.ArrayList<string>();
        foreach (BotMucRoom entry in rooms) {
            if (entry.room_jid.down() != room.down()) {
                lines.add(entry.room_jid + "\t" + entry.nick);
            }
        }
        if (lines.size == 0) {
            registry.delete_setting(muc_rooms_setting_key(bot_id));
        } else {
            registry.set_setting(muc_rooms_setting_key(bot_id), join_strings("\n", lines));
        }
    }

    private static string normalize_room_jid(string room_jid) {
        string room = room_jid.strip().split("/", 2)[0];
        return room.contains("@") ? room : "";
    }

    private static string sanitize_room_nick(string nick) {
        return nick.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip();
    }

    public static bool dedicated_command_requires_admin(string command, string? action, string? args) {
        string cmd = command.strip().ascii_down();
        string? normalized_action = action != null ? action.strip().ascii_down() : null;
        string? normalized_args = args != null ? args.strip() : null;

        if (cmd == "/clear") return true;
        if (cmd == "/api") {
            if (normalized_action == null || normalized_action != "server") return false;
            if (normalized_args == null || normalized_args == "") return false;
            string server_action = normalized_args.split(" ", 2)[0].strip().ascii_down();
            switch (server_action) {
                case "status":
                    return false;
                default:
                    return true;
            }
        }

        if (cmd == "/ki") {
            if (normalized_action == null || normalized_action == "") return false;

            switch (normalized_action) {
                case "status":
                case "providers":
                case "anbieter":
                    return false;
                case "model":
                case "modell":
                case "system":
                    return normalized_args != null && normalized_args != "";
                case "setup":
                    if (normalized_args == null || normalized_args == "") return false;
                    return normalized_args.split(" ", 3).length >= 3;
                default:
                    return true;
            }
        }

        if (cmd == "/telegram") {
            if (normalized_action == null || normalized_action == "") return false;

            switch (normalized_action) {
                case "status":
                    return false;
                case "mode":
                case "modus":
                case "setup":
                    return normalized_args != null && normalized_args != "";
                default:
                    return true;
            }
        }

        return false;
    }
}
