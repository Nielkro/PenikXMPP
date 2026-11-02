namespace Xmpp.Test {

/**
 * Spec-based tests for XMPP stanza parsing per RFC 6120.
 *
 * References:
 *   - RFC 6120 §4.2: Stream opening (<stream:stream>)
 *   - RFC 6120 §4.3.2: Stream features (<stream:features>)
 *   - RFC 6120 §4.7.1: XML stanza structure (<message>, <iq>, <presence>)
 *   - RFC 6120 §4.8: XML namespace handling
 *   - RFC 6120 §13.9: Attribute integer parsing (non-numeric = default)
 */
class StanzaTest : Gee.TestCase {
    public StanzaTest() {
        base("Stanza");

        add_async_test("RFC6120_xml_roundtrip_preserves_namespaces", (cb) => { test_node_one.begin(cb); });
        add_async_test("RFC6120_parse_stream_and_message", (cb) => { test_typical_stream.begin(cb); });
        add_async_test("RFC6120_parse_stream_features_with_namespaces", (cb) => { test_ack_stream.begin(cb); });
        add_test("RFC6120_attribute_int_parsing_edge_cases", test_get_attribute_int);
        add_test("RFC6120_error_condition_ignores_leading_text", test_error_condition_text_first);
        add_test("RFC6120_text_only_error_has_undefined_condition", test_error_condition_text_only);
        add_test("RFC6120_error_condition_ignores_foreign_namespace", test_error_condition_namespace);
    }

    private void test_error_condition_text_first() {
        const string NS_ERROR = "urn:ietf:params:xml:ns:xmpp-stanzas";
        foreach (string condition in new string[] {
                ErrorStanza.CONDITION_NOT_AUTHORIZED,
                ErrorStanza.CONDITION_ITEM_NOT_FOUND,
                ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT }) {
            var error_node = new StanzaNode.build("error")
                .put_attribute("type", ErrorStanza.TYPE_AUTH)
                .put_node(new StanzaNode.build("text", NS_ERROR)
                    .put_node(new StanzaNode.text("Diagnostic explanation")))
                .put_node(new StanzaNode.build(condition, NS_ERROR));
            var stanza = new StanzaNode.build("iq", "jabber:client").put_node(error_node);
            ErrorStanza? error = ErrorStanza.from_stanza(stanza);
            fail_if(error == null, "fixture must contain a stanza error");
            fail_if_not_eq_str(((!) error).condition, condition);
            fail_if_not_eq_str(((!) error).text, "Diagnostic explanation");
            var result = Xep.Pubsub.RequestAllResult.from_error_stanza((!) error);
            fail_if_not_eq_str(result.error_condition, condition,
                "PubSub must retain the actual condition, not the text element name");
            fail_if(result.is_item_not_found() != (condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND));
        }
    }

    private void test_error_condition_text_only() {
        var stanza = new StanzaNode.build("iq", "jabber:client")
            .put_node(new StanzaNode.build("error")
                .put_node(new StanzaNode.build("text", "urn:ietf:params:xml:ns:xmpp-stanzas")
                    .put_node(new StanzaNode.text("Explanation without a condition"))));
        ErrorStanza? error = ErrorStanza.from_stanza(stanza);
        fail_if_not_eq_str(((!) error).condition, ErrorStanza.CONDITION_UNDEFINED_CONDITION);
    }

    private void test_error_condition_namespace() {
        var stanza = new StanzaNode.build("iq", "jabber:client")
            .put_node(new StanzaNode.build("error")
                .put_node(new StanzaNode.build("not-authorized", "urn:example:test"))
                .put_node(new StanzaNode.build("forbidden", "urn:ietf:params:xml:ns:xmpp-stanzas")));
        ErrorStanza? error = ErrorStanza.from_stanza(stanza);
        fail_if_not_eq_str(((!) error).condition, ErrorStanza.CONDITION_FORBIDDEN);
    }

    /**
     * RFC 6120 §4.8: XML namespaces MUST be preserved through
     * serialization → parse → reserialization.
     * Build a node with multiple namespaces, serialize, parse back,
     * and verify structural equality.
     */
    private async void test_node_one(Gee.TestFinishedCallback cb) {
        try {
            var node1 = new StanzaNode.build("test", "ns1_uri")
                    .add_self_xmlns()
                    .put_attribute("ns2", "ns2_uri", XMLNS_URI)
                    .put_attribute("bla", "blub")
                    .put_node(new StanzaNode.build("testaa", "ns2_uri")
                        .put_attribute("ns3", "ns3_uri", XMLNS_URI))
                    .put_node(new StanzaNode.build("testbb", "ns3_uri")
                        .add_self_xmlns());

            var xml1 = node1.to_xml();
            var node2 = yield new StanzaReader.for_string(xml1).read_node();
            fail_if_not(node1.equals(node2));
            fail_if_not_eq_str(node1.to_string(), node2.to_string());
        } catch (Error e) {
            fail_if_reached("Unexpected error: " + e.message);
        }
        cb();
    }

    /**
     * RFC 6120 §4.7.1 Example: Parse a complete XMPP stream with
     * stream header and a <message> stanza.
     *
     * Verifies:
     * - Stream root node attributes (to, version, xmlns)
     * - Message stanza attributes (from, to, xml:lang)
     * - Body text content preservation
     * - End-of-stream detection
     */
    private async void test_typical_stream(Gee.TestFinishedCallback cb) {
        try {
            // Based on RFC 6120 §4.7.1
            var stream = """
            <?xml version='1.0' encoding='UTF-8'?>
            <stream:stream
                    to='example.com'
                    xmlns='jabber:client'
                    xmlns:stream='http://etherx.jabber.org/streams'
                    version='1.0'>
                <message from='laurence@example.net/churchyard'
                        to='juliet@example.com'
                        xml:lang='en'>
                    <body> I'll send a friar with speed, to Mantua, with my letters to thy lord.</body>
                </message>
            </stream:stream>
            """;
            var root_node_cmp = new StanzaNode.build("stream", "http://etherx.jabber.org/streams")
                    .put_attribute("to", "example.com")
                    .put_attribute("xmlns", "jabber:client")
                    .put_attribute("stream", "http://etherx.jabber.org/streams", XMLNS_URI)
                    .put_attribute("version", "1.0");
            var node_cmp = new StanzaNode.build("message")
                    .put_attribute("from", "laurence@example.net/churchyard")
                    .put_attribute("to", "juliet@example.com")
                    .put_attribute("lang", "en", XML_URI)
                    .put_node(new StanzaNode.build("body")
                            .put_node(new StanzaNode.text(" I'll send a friar with speed, to Mantua, with my letters to thy lord.")));

            var reader = new StanzaReader.for_string(stream);
            fail_if_not_eq_node(root_node_cmp, yield reader.read_root_node());
            fail_if_not_eq_node(node_cmp, yield reader.read_node());
            yield reader.read_node();
            yield fail_if_not_end_of_stream(reader);
        } catch (Error e) {
            fail_if_reached("Unexpected error: " + e.message);
        }
        cb();
    }


    private async void fail_if_not_end_of_stream(StanzaReader reader) {
        try {
            yield reader.read_node();
            fail_if_reached("end of stream should be reached");
        } catch (IOError.CLOSED e) {
            return;
        } catch (Error e) {
            fail_if_reached("Unexpected error");
        }
    }

    /**
     * RFC 6120 §4.3.2: Stream features with multiple namespace prefixes.
     * Tests parsing of <stream:features> containing child elements from
     * different XML namespaces (ack:, bind:).
     *
     * Also verifies that non-stanza elements like <ack:r/> are parsed
     * correctly.
     */
    private async void test_ack_stream(Gee.TestFinishedCallback cb) {
        try {
            var stream = """
            <?xml version='1.0' encoding='UTF-8'?>
            <stream:stream
                    to='example.com'
                    xmlns='jabber:client'
                    xmlns:stream='http://etherx.jabber.org/streams'
                    xmlns:ack='http://jabber.org/protocol/ack'
                    version='1.0'>
                <stream:features>
                    <ack:ack/>
                    <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>
                        <required/>
                    </bind>
                </stream:features>
                <ack:r/>
            </stream:stream>
            """;
            var root_node_cmp = new StanzaNode.build("stream", "http://etherx.jabber.org/streams")
                    .put_attribute("to", "example.com")
                    .put_attribute("xmlns", "jabber:client")
                    .put_attribute("stream", "http://etherx.jabber.org/streams", XMLNS_URI)
                    .put_attribute("ack", "http://jabber.org/protocol/ack", XMLNS_URI)
                    .put_attribute("version", "1.0");
            var node_cmp = new StanzaNode.build("features", XmppStream.NS_URI)
                    .put_node(new StanzaNode.build("ack", "http://jabber.org/protocol/ack"))
                    .put_node(new StanzaNode.build("bind", "urn:ietf:params:xml:ns:xmpp-bind")
                            .add_self_xmlns()
                            .put_node(new StanzaNode.build("required", "urn:ietf:params:xml:ns:xmpp-bind")));
            var node2_cmp = new StanzaNode.build("r", "http://jabber.org/protocol/ack");

            var reader = new StanzaReader.for_string(stream);
            fail_if_not_eq_node(root_node_cmp, yield reader.read_root_node());
            fail_if_not_eq_node(node_cmp, yield reader.read_node());
            fail_if_not_eq_node(node2_cmp, yield reader.read_node());
            yield reader.read_node();
            yield fail_if_not_end_of_stream(reader);
        } catch (Error e) {
            fail_if_reached("Unexpected error: " + e.message);
        }
        cb();
    }

    /**
     * RFC 6120 §13.9 / XML Schema: Integer attribute parsing.
     *
     * get_attribute_int/uint MUST:
     * - Return parsed integer for valid decimal strings ("42", "-42")
     * - Return default for missing attributes
     * - Return default for non-decimal strings ("0x42", "str")
     * - get_attribute_uint: Return default for negative values
     */
    private void test_get_attribute_int() {
        // Valid positive integer
        var stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "42");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), 42);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 42);

        // Negative integer: valid for int, default for uint
        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "-42");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -42);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

        // Missing attribute: return default
        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns();
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -2);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

        // Hex string: not decimal → default
        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "0x42");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -2);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

        // Non-numeric string: default
        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "str");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -2);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

    }

}

}
