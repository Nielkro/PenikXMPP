using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino {

/** One account-scoped classification shared by history, notifications and UI. */
public class MessageMentions : Object {
    private static HashMap<string, Regex>? nickname_patterns;
    public static bool is_mentioned(StreamInteractor stream_interactor,
            Conversation conversation, Message message) {
        if (!belongs_to_conversation(conversation, message) ||
                is_own_message(conversation, message) ||
                message.decryption_failed || message.body == null ||
                ((!) message.body).strip() == "") return false;
        if (message.mention_state == Message.MentionState.MENTIONED) return true;
        if (message.mention_state == Message.MentionState.NONE) return false;
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return false;

        // Old databases did not keep XEP-0372 references. Their text can still
        // be recognized before a room joins, using its saved account nickname.
        string? nickname = get_room_nickname(stream_interactor, conversation);
        if (nickname == null) return false;
        string body = mask_reply_fallback((!) message.body,
            message.get_fallbacks());
        int begin, end;
        return find_nickname(body, (!) nickname, out begin, out end);
    }

    internal static void classify(StreamInteractor stream_interactor,
            Conversation conversation, Message message, MessageStanza stanza) {
        message.mention_state = Message.MentionState.NONE;
        if (!belongs_to_conversation(conversation, message) ||
                is_own_message(conversation, message) ||
                message.decryption_failed || message.body == null ||
                ((!) message.body).strip() == "") return;

        string body = (!) message.body;
        // The parser trims ordinary text. Wire offsets address the untrimmed
        // body; encrypted protocols may instead replace it with plaintext.
        if (stanza.body != null && ((!) stanza.body).strip() == body) {
            body = (!) stanza.body;
        }
        Gee.List<Xep.FallbackIndication.Fallback> fallbacks =
            Xep.FallbackIndication.get_fallbacks(stanza);
        string visible_body = mask_reply_fallback(body, fallbacks);
        if (visible_body.strip() == "") return;
        string? nickname = conversation.type_.is_muc_semantic()
            ? get_room_nickname(stream_interactor, conversation) : null;
        Jid? own_room_jid = null;
        if (nickname != null) {
            try {
                own_room_jid = conversation.counterpart.bare_jid.with_resource(
                    (!) nickname);
            } catch (InvalidJidError error) { }
        }

        foreach (Xep.References.Reference reference in
                Xep.References.get_references(stanza)) {
            if (reference.type_ != "mention" || reference.uri == null ||
                    !reference_has_visible_range(reference, body, fallbacks)) {
                continue;
            }
            Jid? target = parse_reference_jid((!) reference.uri);
            if (target != null && (((!) target).equals_bare(
                    conversation.account.bare_jid) ||
                    (own_room_jid != null && ((!) target).equals(
                        (!) own_room_jid)))) {
                message.mention_state = Message.MentionState.MENTIONED;
                return;
            }
        }
        if (conversation.type_ == Conversation.Type.GROUPCHAT && nickname != null) {
            int begin, end;
            if (find_nickname(visible_body, (!) nickname, out begin, out end)) {
                message.mention_state = Message.MentionState.MENTIONED;
            }
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            // A newly discovered room can deliver history before its nickname
            // is known. Leave those texts eligible for the later join refresh.
            message.mention_state = Message.MentionState.UNKNOWN;
        }
    }

    private static bool belongs_to_conversation(Conversation conversation,
            Message message) {
        if (message.account == null || message.counterpart == null ||
                message.account.id != conversation.account.id ||
                !message.account.bare_jid.equals_bare(
                    conversation.account.bare_jid) ||
                message.type_ != Util.get_message_type_for_conversation(
                    conversation)) return false;
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            return ((!) message.counterpart).equals(conversation.counterpart);
        }
        return ((!) message.counterpart).equals_bare(conversation.counterpart);
    }

    private static bool is_own_message(Conversation conversation,
            Message message) {
        if (message.direction == Message.DIRECTION_SENT) return true;
        // Authorized non-anonymous room archives can identify our older nick
        // even when the current nickname made initial direction parsing fail.
        return conversation.type_ == Conversation.Type.GROUPCHAT &&
            message.real_jid != null && ((!) message.real_jid).equals_bare(
                conversation.account.bare_jid);
    }

    private static string? get_room_nickname(StreamInteractor stream_interactor,
            Conversation conversation) {
        MucManager? manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        Jid? own_jid = manager != null ? ((!) manager).get_own_jid(
            conversation.counterpart, conversation.account) : null;
        string? saved_nickname = conversation.nickname;
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            ConversationManager? conversations = stream_interactor.get_module<
                ConversationManager>(ConversationManager.IDENTITY);
            Conversation? room = conversations != null
                ? ((!) conversations).get_conversation(
                    conversation.counterpart.bare_jid, conversation.account,
                    Conversation.Type.GROUPCHAT) : null;
            saved_nickname = room != null ? ((!) room).nickname : null;
        }
        string? nickname = own_jid != null
            ? ((!) own_jid).resourcepart : saved_nickname;
        return nickname != null && ((!) nickname).strip() != ""
            ? nickname : null;
    }

    /** Find complete Unicode nicknames, including nicknames ending in symbols. */
    internal static bool find_nickname(string body, string nickname,
            out int begin, out int end) {
        begin = -1;
        end = -1;
        if (nickname == "" || body == "") return false;
        try {
            if (nickname_patterns == null) {
                nickname_patterns = new HashMap<string, Regex>();
            }
            Regex? regex = ((!) nickname_patterns)[nickname];
            if (regex == null) {
                if (((!) nickname_patterns).size >= 32) {
                    ((!) nickname_patterns).clear();
                }
                regex = new Regex("(?<![\\p{L}\\p{N}\\p{M}_])" +
                    Regex.escape_string(nickname) +
                    "(?![\\p{L}\\p{N}\\p{M}_])", RegexCompileFlags.CASELESS);
                ((!) nickname_patterns)[nickname] = (!) regex;
            }
            MatchInfo match;
            if (!((!) regex).match(body, 0, out match)) return false;
            int start_byte, end_byte;
            if (!match.fetch_pos(0, out start_byte, out end_byte)) return false;
            begin = (int) body.substring(0, start_byte).char_count();
            end = (int) body.substring(0, end_byte).char_count();
            return true;
        } catch (RegexError error) {
            return false;
        }
    }

    internal static bool find_nickname_in_message(Message message,
            string nickname, out int begin, out int end) {
        string body = message.body != null
            ? mask_reply_fallback((!) message.body, message.get_fallbacks()) : "";
        return find_nickname(body, nickname, out begin, out end);
    }

    internal static string reference_uri(Jid jid) {
        // Resourceparts may contain ?, #, %, or spaces. Those are URI syntax,
        // not XMPP JID syntax, and must survive a URI round trip unchanged.
        return "xmpp:" + Uri.escape_string(jid.to_string(), "@/:", true);
    }

    private static Jid? parse_reference_jid(string uri) {
        if (!uri.has_prefix("xmpp:")) return null;
        string jid_part = uri.substring(5);
        int query_index = jid_part.index_of("?");
        if (query_index >= 0) jid_part = jid_part.substring(0, query_index);
        int fragment_index = jid_part.index_of("#");
        if (fragment_index >= 0) jid_part = jid_part.substring(0, fragment_index);
        string? unescaped = Uri.unescape_string(jid_part);
        if (unescaped == null || unescaped == "") return null;
        try {
            return new Jid((!) unescaped);
        } catch (InvalidJidError error) {
            return null;
        }
    }

    private static bool parse_offset(string value, out int offset) {
        offset = -1;
        if (value == "") return false;
        for (int i = 0; i < value.length; i++) {
            if (value[i] < '0' || value[i] > '9') return false;
        }
        int64 parsed;
        if (!int64.try_parse(value, out parsed) || parsed > int.MAX) return false;
        offset = (int) parsed;
        return true;
    }

    private static bool reference_has_visible_range(
            Xep.References.Reference reference, string body,
            Gee.List<Xep.FallbackIndication.Fallback> fallbacks) {
        if (reference.begin == null && reference.end == null) return true;
        if (reference.begin == null || reference.end == null) return false;
        int begin = -1, end = -1;
        if (!parse_offset((!) reference.begin, out begin) ||
                !parse_offset((!) reference.end, out end) || begin >= end ||
                end > body.char_count()) return false;
        foreach (Xep.FallbackIndication.Fallback fallback in fallbacks) {
            if (fallback.ns_uri != Xep.Replies.NS_URI) continue;
            foreach (Xep.FallbackIndication.FallbackLocation location in
                    fallback.locations) {
                if (location.is_whole) return false;
                if (location.from_char >= 0 &&
                        location.to_char > location.from_char &&
                        location.to_char <= body.char_count() &&
                        begin < location.to_char && end > location.from_char) {
                    return false;
                }
            }
        }
        return true;
    }

    private static string mask_reply_fallback(string body,
            Gee.List<Xep.FallbackIndication.Fallback> fallbacks) {
        var ranges = new ArrayList<Xep.FallbackIndication.FallbackLocation>();
        foreach (Xep.FallbackIndication.Fallback fallback in fallbacks) {
            if (fallback.ns_uri != Xep.Replies.NS_URI) continue;
            foreach (Xep.FallbackIndication.FallbackLocation location in
                    fallback.locations) {
                if (location.is_whole) return "";
                if (location.from_char >= 0 &&
                        location.to_char > location.from_char &&
                        location.to_char <= body.char_count()) ranges.add(location);
            }
        }
        if (ranges.is_empty) return body;
        var result = new StringBuilder();
        int byte_index = 0;
        int character_index = 0;
        unichar character;
        while (body.get_next_char(ref byte_index, out character)) {
            bool hidden = false;
            foreach (Xep.FallbackIndication.FallbackLocation range in ranges) {
                if (character_index >= range.from_char &&
                        character_index < range.to_char) {
                    hidden = true;
                    break;
                }
            }
            result.append_unichar(hidden ? ' ' : character);
            character_index++;
        }
        return result.str;
    }
}

}
