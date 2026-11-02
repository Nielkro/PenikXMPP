using Xmpp;
using Xmpp.Xep;

namespace Xmpp.Test {
class EmojiMarkupTest : Gee.TestCase {
    private const string HASH = "AQIDBA==";
    public EmojiMarkupTest() {
        base("EmojiMarkup");
        add_async_test("wire_emoji_keeps_body_without_emphasis_or_attachment", (cb) => { test_wire.begin(cb); });
        add_test("known_styles_and_foreign_namespaces", test_styles);
        add_test("unicode_ranges_and_zero_length_insertion", test_ranges);
        add_test("unrelated_attachments_and_stickers_remain", test_attachments);
        add_test("malformed_or_unmatched_hash_does_not_hide_attachment", test_bad_hashes);
    }
    private MessageStanza message(string body = "Hi :wave:") {
        var stanza = new MessageStanza(); stanza.body = body; return stanza;
    }
    private StanzaNode emoji_span(MessageStanza stanza, int start = 3, int end = 9) {
        var span = new StanzaNode.build("span", MessageMarkup.NS_URI)
            .put_attribute("start", start.to_string()).put_attribute("end", end.to_string());
        var emoji = new StanzaNode.build("emoji", MessageMarkup.EMOJI_NS_URI)
            .put_node(new StanzaNode.build("hash", CryptographicHashes.NS_URI)
                .put_attribute("algo", "sha-256").put_node(new StanzaNode.text(HASH)));
        span.put_node(emoji);
        stanza.stanza.put_node(new StanzaNode.build("markup", MessageMarkup.NS_URI).put_node(span));
        return emoji;
    }
    private void share(MessageStanza stanza, string hash = HASH) {
        var metadata = new FileMetadataElement.FileMetadata() { name="same.png", mime_type="image/png", size=100 };
        metadata.hashes.add(new CryptographicHashes.Hash.with_checksum(ChecksumType.SHA256, hash));
        stanza.stanza.put_node(new StanzaNode.build("file-sharing", StatelessFileSharing.NS_URI).put_node(metadata.to_stanza_node()));
    }
    private async void test_wire(Gee.TestFinishedCallback cb) {
        try {
            string xml = """<message xmlns='jabber:client' from='a@example.test' to='b@example.test' type='chat'><body>Hi :wave:</body><markup xmlns='urn:xmpp:markup:0'><span start='3' end='9'><emoji xmlns='urn:xmpp:markup:emoji:0'><hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>AQIDBA==</hash></emoji></span></markup><file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'><name>same.png</name><hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>AQIDBA==</hash></file></file-sharing></message>""";
            var reader = new StanzaReader.for_string(xml);
            var stanza = new MessageStanza.from_stanza(yield reader.read_node(), new Jid("b@example.test"));
            assert_true(MessageMarkup.get_spans(stanza).is_empty);
            assert_true(MessageMarkup.get_emoji_hashes(stanza).size == 1);
            assert_null(StatelessFileSharing.get_attachment_file_shares(stanza));
            assert_cmpstr(stanza.body, CompareOperator.EQ, "Hi :wave:");
        } catch (Error e) { fail_if_reached(e.message); }
        cb();
    }
    private void test_styles() {
        var stanza = message();
        emoji_span(stanza);
        var span = stanza.stanza.get_subnode("markup", MessageMarkup.NS_URI).get_subnode("span", MessageMarkup.NS_URI);
        span.put_node(new StanzaNode.build("strong", "urn:foreign"));
        span.put_node(new StanzaNode.build("future-style", MessageMarkup.NS_URI));
        assert_true(MessageMarkup.get_spans(stanza).is_empty);
        span.put_node(new StanzaNode.build("strong", MessageMarkup.NS_URI));
        var parsed = MessageMarkup.get_spans(stanza);
        assert_true(parsed.size == 1 && parsed[0].types.size == 1);
        assert_true(parsed[0].types[0] == MessageMarkup.SpanType.STRONG_EMPHASIS);
    }
    private void test_ranges() {
        var valid = message("🙂 אב"); emoji_span(valid, 0, 1);
        assert_true(MessageMarkup.get_emoji_hashes(valid).size == 1);
        var insertion = message("🙂 אב"); emoji_span(insertion, 4, 4);
        assert_true(MessageMarkup.get_emoji_hashes(insertion).size == 1);
        foreach (int end in new int[]{-1, 5, 999999}) {
            var invalid = message("🙂 אב"); emoji_span(invalid, 0, end);
            assert_true(MessageMarkup.get_emoji_hashes(invalid).is_empty);
        }
        var negative = message(); emoji_span(negative, -1, 2);
        assert_true(MessageMarkup.get_emoji_hashes(negative).is_empty);
    }
    private void test_attachments() {
        var stanza = message(); share(stanza);
        assert_true(StatelessFileSharing.get_attachment_file_shares(stanza).size == 1);
        stanza.stanza.put_node(new StanzaNode.build("sticker", Stickers.NS_URI));
        assert_true(StatelessFileSharing.get_attachment_file_shares(stanza).size == 1);
        emoji_span(stanza); share(stanza, "BQYHCA==");
        var attachments = StatelessFileSharing.get_attachment_file_shares(stanza);
        assert_true(attachments.size == 1);
        assert_cmpstr(attachments[0].metadata.hashes[0].val, CompareOperator.EQ, "BQYHCA==");
    }
    private void test_bad_hashes() {
        foreach (string hash in new string[]{"", "%%%", "AQID", "BQYHCA=="}) {
            var stanza = message(); var emoji = emoji_span(stanza); share(stanza);
            emoji.get_subnode("hash", CryptographicHashes.NS_URI).sub_nodes.clear();
            emoji.get_subnode("hash", CryptographicHashes.NS_URI).put_node(new StanzaNode.text(hash));
            assert_true(StatelessFileSharing.get_attachment_file_shares(stanza).size == 1);
        }
        var missing = message(); var emoji = emoji_span(missing); emoji.sub_nodes.clear(); share(missing);
        assert_true(StatelessFileSharing.get_attachment_file_shares(missing).size == 1);
    }
}
}
