using Gee;

namespace Xmpp.Xep.MessageMarkup {

    public const string NS_URI = "urn:xmpp:markup:0";
    public const string EMOJI_NS_URI = "urn:xmpp:markup:emoji:0";

    public enum SpanType {
        EMPHASIS,
        STRONG_EMPHASIS,
        DELETED,
    }

    public class Span : Object {
        public Gee.List<SpanType> types { get; set; }
        public int start_char { get; set; }
        public int end_char { get; set; }
    }

    public Gee.List<Span> get_spans(MessageStanza stanza) {
        var ret = new ArrayList<Span>();
        string? body = stanza.body;
        if (body == null) return ret;
        int body_length = body.char_count();

        foreach (StanzaNode span_node in stanza.stanza.get_deep_subnodes(NS_URI + ":markup", NS_URI + ":span")) {
            int start_char = span_node.get_attribute_int("start", -1, NS_URI);
            int end_char = span_node.get_attribute_int("end", -1, NS_URI);
            if (start_char < 0 || end_char <= start_char || end_char > body_length) continue;

            var types = new ArrayList<SpanType>();
            foreach (StanzaNode span_subnode in span_node.get_all_subnodes()) {
                if (span_subnode.ns_uri != NS_URI ||
                        (span_subnode.name != "emphasis" && span_subnode.name != "strong" &&
                         span_subnode.name != "deleted")) continue;
                types.add(str_to_span_type(span_subnode.name));
            }
            if (types.is_empty) continue;
            ret.add(new Span() { types=types, start_char=start_char, end_char=end_char });
        }
        return ret;
    }

    // Receive-only compatibility: keep the textual fallback, without advertising
    // custom-emoji rendering or fetching the referenced images as attachments.
    public Gee.Set<string> get_emoji_hashes(MessageStanza stanza) {
        var hashes = new HashSet<string>();
        if (stanza.body == null) return hashes;
        int length = stanza.body.char_count();
        foreach (var span in stanza.stanza.get_deep_subnodes(NS_URI + ":markup", NS_URI + ":span")) {
            int start = span.get_attribute_int("start", -1);
            int end = span.get_attribute_int("end", -1);
            if (start < 0 || end < start || end > length) continue;
            foreach (var emoji in span.get_subnodes("emoji", EMOJI_NS_URI)) {
                foreach (var hash in CryptographicHashes.get_hashes(emoji)) {
                    string? key = emoji_hash_key(hash);
                    if (key != null) hashes.add(key);
                }
            }
        }
        return hashes;
    }

    public string? emoji_hash_key(CryptographicHashes.Hash hash) {
        if (hash.algo == null || hash.val == null || hash.algo.length == 0 ||
                hash.algo.length > 64 || hash.val.length == 0 || hash.val.length > 256) return null;
        string value = hash.val.strip();
        uint8[] decoded = Base64.decode(value);
        if (decoded.length == 0 || Base64.encode(decoded) != value) return null;
        return hash.algo + ":" + value;
    }

    public void add_spans(MessageStanza stanza, Gee.List<Span> spans) {
        if (spans.is_empty) return;

        StanzaNode markup_node = new StanzaNode.build("markup", NS_URI).add_self_xmlns();

        foreach (var span in spans) {
            StanzaNode span_node = new StanzaNode.build("span", NS_URI)
                    .put_attribute("start", span.start_char.to_string(), NS_URI)
                    .put_attribute("end", span.end_char.to_string(), NS_URI);

            foreach (var type in span.types) {
                span_node.put_node(new StanzaNode.build(span_type_to_str(type), NS_URI));
            }
            markup_node.put_node(span_node);
        }

        stanza.stanza.put_node(markup_node);
    }

    public static string span_type_to_str(Xep.MessageMarkup.SpanType span_type) {
        switch (span_type) {
            case Xep.MessageMarkup.SpanType.EMPHASIS:
                return "emphasis";
            case Xep.MessageMarkup.SpanType.STRONG_EMPHASIS:
                return "strong";
            case Xep.MessageMarkup.SpanType.DELETED:
                return "deleted";
            default:
                return "";
        }
    }

    public static Xep.MessageMarkup.SpanType str_to_span_type(string span_str) {
        switch (span_str) {
            case "emphasis":
                return Xep.MessageMarkup.SpanType.EMPHASIS;
            case "strong":
                return Xep.MessageMarkup.SpanType.STRONG_EMPHASIS;
            case "deleted":
                return Xep.MessageMarkup.SpanType.DELETED;
            default:
                return Xep.MessageMarkup.SpanType.EMPHASIS;
        }
    }

}
