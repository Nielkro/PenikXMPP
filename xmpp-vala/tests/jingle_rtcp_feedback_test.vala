using Gee;
using Xmpp.Xep.JingleRtp;

namespace Xmpp.Test {

/** Pure XEP-0293 scope and XML/SDP conversion regressions. */
class JingleRtcpFeedbackTest : Gee.TestCase {

    public JingleRtcpFeedbackTest() {
        base("JingleRtcpFeedbackTest");
        add_test("description_feedback_is_additive_and_deduplicated", test_description_feedback);
        add_test("payload_interval_overrides_description_interval", test_description_interval);
        add_test("wildcard_feedback_and_interval_are_order_independent", test_sdp_wildcard);
        add_test("trr_int_uses_distinct_xml_and_roundtrips", test_interval_roundtrip);
        add_test("description_interval_rejects_invalid_values", test_invalid_description_interval);
        add_test("sdp_interval_rejects_invalid_values", test_invalid_sdp_interval);
        add_test("conflicting_intervals_at_one_scope_are_rejected", test_conflicting_intervals);
        add_test("feedback_namespace_is_scoped", test_feedback_namespace);
        add_test("description_feedback_preserves_rrtr", test_preserves_rrtr);
        add_test("interval_numeric_dedupe_keeps_objects_and_xml_sdp_lexical_rules", test_numeric_interval_dedupe);
    }

    private StanzaNode description() {
        var node = new StanzaNode.build("description", Xep.JingleRtp.NS_URI)
                .put_attribute("media", "video");
        node.put_node(payload(96));
        node.put_node(payload(97));
        return node;
    }

    private StanzaNode payload(uint8 id) {
        var payload_type = new PayloadType() { id = id, name = "VP8", clockrate = 90000 };
        return payload_type.to_xml();
    }

    private StanzaNode transport() {
        return new StanzaNode.build("transport", Xep.JingleIceUdp.NS_URI)
                .put_attribute("ufrag", "ufrag").put_attribute("pwd", "password");
    }

    private StanzaNode interval(string value) {
        return new StanzaNode.build(RtcpFeedback.TRR_INT_NAME, RtcpFeedback.NS_URI)
                .put_attribute("value", value);
    }

    private SdpMediaSection parse_description(StanzaNode node) throws Xep.Jingle.IqError {
        return SdpBridge.media_section_from_jingle_nodes("video", node, transport());
    }

    private bool has_feedback(PayloadType payload_type, string type, string? subtype = null) {
        return payload_type.rtcp_fbs.any_match((it) => it.type_ == type && it.subtype == subtype);
    }

    private void test_description_feedback() {
        var node = description();
        node.put_node(new RtcpFeedback("nack", "pli").to_xml());
        node.put_node(new RtcpFeedback("nack", "pli").to_xml());
        node.put_node(new RtcpFeedback("ccm", "fir").to_xml());
        var first = node.get_subnodes(PayloadType.NAME)[0];
        first.put_node(new RtcpFeedback("nack", "sli").to_xml());
        first.put_node(new RtcpFeedback("nack", "pli").to_xml());
        first.put_node(new RtcpFeedback("nack", "sli").to_xml());
        try {
            var section = parse_description(node);
            var a = section.payload_types[0];
            var b = section.payload_types[1];
            fail_if_not_eq_int(a.rtcp_fbs.size, 3, "Local and shared capabilities form a set");
            fail_if_not_eq_int(b.rtcp_fbs.size, 2, "Shared capabilities reach every payload");
            fail_if_not(has_feedback(a, "nack", "pli") && has_feedback(a, "nack", "sli"));
            fail_if_not(has_feedback(a, "ccm", "fir") && has_feedback(b, "ccm", "fir"));
            fail_if(has_feedback(b, "nack", "sli"), "Payload feedback must retain its scope");
            var lines = SdpBridge.media_section_to_sdp_lines(section);
            int pli_lines = 0;
            foreach (string line in lines) {
                if (line == "a=rtcp-fb:96 nack pli") pli_lines++;
            }
            fail_if_not_eq_int(pli_lines, 1);
            var roundtrip = parse_description(SdpBridge.media_section_to_jingle_description_node(section));
            fail_if_not(PayloadType.equals_func(a, roundtrip.payload_types[0]));
            fail_if_not(PayloadType.equals_func(b, roundtrip.payload_types[1]));
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(e.message);
        }
    }

    private void test_description_interval() {
        var node = description();
        node.put_node(interval("100"));
        node.put_node(interval("100"));
        node.get_subnodes(PayloadType.NAME)[0].put_node(interval("0"));
        try {
            var section = parse_description(node);
            fail_if_not_eq_int(section.payload_types[0].rtcp_fbs.size, 1);
            fail_if_not_eq_int(section.payload_types[1].rtcp_fbs.size, 1);
            fail_if_not(has_feedback(section.payload_types[0], "trr-int", "0"));
            fail_if_not(has_feedback(section.payload_types[1], "trr-int", "100"));
            var xml = SdpBridge.media_section_to_jingle_description_node(section);
            var first_interval = xml.get_subnodes(PayloadType.NAME)[0].get_subnode(
                    RtcpFeedback.TRR_INT_NAME, RtcpFeedback.NS_URI);
            fail_if_not(first_interval != null, "A zero interval is explicit on the XML wire");
            if (first_interval != null) fail_if_not_eq_str(first_interval.get_attribute("value"), "0");
            var roundtrip = parse_description(xml);
            fail_if_not(PayloadType.equals_func(section.payload_types[0], roundtrip.payload_types[0]));
            fail_if_not(PayloadType.equals_func(section.payload_types[1], roundtrip.payload_types[1]));
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(e.message);
        }
    }

    private SdpMediaSection parse_sdp_feedback(bool wildcard_first) throws Xep.Jingle.IqError {
        var lines = new ArrayList<string>();
        lines.add("m=video 9 UDP/TLS/RTP/SAVPF 96 97");
        lines.add("a=rtpmap:96 VP8/90000");
        lines.add("a=rtpmap:97 VP8/90000");
        string[] shared = {"a=rtcp-fb:* nack pli", "a=rtcp-fb:* nack pli", "a=rtcp-fb:* trr-int 100"};
        string[] local = {"a=rtcp-fb:96 nack pli", "a=rtcp-fb:96 nack sli", "a=rtcp-fb:96 trr-int 0"};
        string[] first = wildcard_first ? shared : local;
        string[] last = wildcard_first ? local : shared;
        foreach (string line in first) lines.add(line);
        foreach (string line in last) lines.add(line);
        return SdpBridge.media_section_from_sdp_lines(lines);
    }

    private void test_sdp_wildcard() {
        try {
            var first = parse_sdp_feedback(true);
            var last = parse_sdp_feedback(false);
            for (int i = 0; i < first.payload_types.size; i++) {
                fail_if_not(PayloadType.equals_func(first.payload_types[i], last.payload_types[i]),
                        "Wildcard expansion must not depend on SDP line order");
            }
            fail_if_not_eq_int(first.payload_types[0].rtcp_fbs.size, 3);
            fail_if_not_eq_int(first.payload_types[1].rtcp_fbs.size, 2);
            fail_if_not(has_feedback(first.payload_types[0], "trr-int", "0"));
            fail_if_not(has_feedback(first.payload_types[1], "trr-int", "100"));
            fail_if_not(has_feedback(first.payload_types[1], "nack", "pli"));
            var roundtrip = parse_description(SdpBridge.media_section_to_jingle_description_node(first));
            fail_if_not(PayloadType.equals_func(first.payload_types[0], roundtrip.payload_types[0]));
            fail_if_not(PayloadType.equals_func(first.payload_types[1], roundtrip.payload_types[1]));
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(e.message);
        }
    }

    private void test_interval_roundtrip() {
        try {
            foreach (string value in new string[] {"0", "100", "4294967295"}) {
                uint8 id;
                var feedback = SdpBridge.rtcp_feedback_from_sdp("a=rtcp-fb:96 trr-int " + value, out id);
                var original = new PayloadType() { id = id, name = "VP8", clockrate = 90000 };
                original.rtcp_fbs.add(feedback);
                var xml = original.to_xml();
                fail_if(xml.get_subnode(RtcpFeedback.NAME, RtcpFeedback.NS_URI) != null,
                        "trr-int must not be emitted as an ordinary rtcp-fb element");
                var trr = xml.get_subnode(RtcpFeedback.TRR_INT_NAME, RtcpFeedback.NS_URI);
                fail_if_not(trr != null);
                if (trr != null) fail_if_not_eq_str(trr.get_attribute("value"), value);
                var parsed = PayloadType.parse(xml);
                fail_if_not(PayloadType.equals_func(original, parsed));
                fail_if_not(PayloadType.equals_func(parsed, parsed.clone()));
                fail_if_not_eq_str(SdpBridge.rtcp_feedback_to_sdp(id, parsed.rtcp_fbs[0]),
                        "a=rtcp-fb:96 trr-int " + value);
            }
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(e.message);
        }
    }

    private void test_invalid_description_interval() {
        foreach (string value in new string[] {"", "-1", "1x", "4294967296", "1\r\na=sendonly", "+", "+ 100"}) {
            foreach (bool description_scope in new bool[] {true, false}) {
                var node = description();
                var scope = description_scope ? node : node.get_subnodes(PayloadType.NAME)[0];
                scope.put_node(interval(value));
                try {
                    parse_description(node);
                    fail_if_reached("Invalid Jingle interval accepted: " + value);
                } catch (Xep.Jingle.IqError e) {
                    // Expected.
                }
            }
        }
    }

    private void test_invalid_sdp_interval() {
        foreach (string value in new string[] {"", "-1", "1x", "4294967296", "+100"}) {
            try {
                uint8 id;
                SdpBridge.rtcp_feedback_from_sdp("a=rtcp-fb:96 trr-int " + value, out id);
                fail_if_reached("Invalid SDP interval accepted: " + value);
            } catch (Xep.Jingle.IqError e) {
                // Expected.
            }
        }
    }

    private void test_conflicting_intervals() {
        foreach (bool description_scope in new bool[] {true, false}) {
            var node = description();
            var scope = description_scope ? node : node.get_subnodes(PayloadType.NAME)[0];
            scope.put_node(interval("100"));
            scope.put_node(interval("200"));
            try {
                parse_description(node);
                fail_if_reached("Conflicting intervals at one scope must not reach SDP");
            } catch (Xep.Jingle.IqError e) {
                // Expected.
            }
        }
    }

    private void test_feedback_namespace() {
        var node = description();
        node.put_node(new StanzaNode.build(RtcpFeedback.NAME, "urn:unrelated")
                .put_attribute("type", "nack").put_attribute("subtype", "pli"));
        node.put_node(new StanzaNode.build(RtcpFeedback.TRR_INT_NAME, "urn:unrelated")
                .put_attribute("value", "100"));
        node.get_subnodes(PayloadType.NAME)[0].put_node(new StanzaNode.build(
                RtcpFeedback.TRR_INT_NAME, "urn:unrelated").put_attribute("value", "100"));
        try {
            var section = parse_description(node);
            foreach (var payload_type in section.payload_types) fail_if_not_eq_int(payload_type.rtcp_fbs.size, 0);
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(e.message);
        }
    }

    private void test_preserves_rrtr() {
        var node = description();
        node.put_node(new RtcpFeedback("rrtr").to_xml());
        try {
            var section = parse_description(node);
            foreach (var payload_type in section.payload_types) fail_if_not(has_feedback(payload_type, "rrtr"));
            fail_if_not(SdpBridge.media_section_to_sdp(section).contains("a=rtcp-fb:96 rrtr\r\n"));
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(e.message);
        }
    }

    private void test_numeric_interval_dedupe() {
        var node = description();
        var padded = interval(" \t+00100\r\n");
        node.put_node(interval("0100"));
        node.put_node(interval("100"));
        node.put_node(interval("+100"));
        node.put_node(padded);
        var local = node.get_subnodes(PayloadType.NAME)[0];
        local.put_node(interval("000"));
        local.put_node(interval("0"));
        try {
            var section = parse_description(node);
            fail_if_not_eq_int(section.payload_types[0].rtcp_fbs.size, 1);
            fail_if_not_eq_int(section.payload_types[1].rtcp_fbs.size, 1);
            fail_if_not(has_feedback(section.payload_types[0], "trr-int", "000"));
            fail_if_not(has_feedback(section.payload_types[1], "trr-int", "0100"));
            fail_if_not_eq_str(padded.get_attribute("value"), " \t+00100\r\n",
                    "XML normalization must not alter the input node");

            var lines = new ArrayList<string>();
            lines.add("m=video 9 UDP/TLS/RTP/SAVPF 96 97");
            lines.add("a=rtpmap:96 VP8/90000");
            lines.add("a=rtpmap:97 VP8/90000");
            lines.add("a=rtcp-fb:* trr-int 0100");
            lines.add("a=rtcp-fb:* trr-int 100");
            lines.add("a=rtcp-fb:96 trr-int 000");
            lines.add("a=rtcp-fb:96 trr-int 0");
            var parsed = SdpBridge.media_section_from_sdp_lines(lines);
            fail_if_not_eq_int(parsed.payload_types[0].rtcp_fbs.size, 1);
            fail_if_not_eq_int(parsed.payload_types[1].rtcp_fbs.size, 1);
            var shared_feedback = parsed.payload_types[1].rtcp_fbs[0];
            var shallow_clone = parsed.payload_types[1].clone();
            var roundtrip = parse_description(SdpBridge.media_section_to_jingle_description_node(parsed));
            fail_if_not_eq_str(shared_feedback.subtype, "0100");
            fail_if_not_eq_str(shallow_clone.rtcp_fbs[0].subtype, "0100",
                    "Numeric comparisons must not canonicalize shared feedback objects");
            fail_if_not(PayloadType.equals_func(parsed.payload_types[1], roundtrip.payload_types[1]));
            fail_if_not_eq_str(SdpBridge.rtcp_feedback_to_sdp(97, shared_feedback),
                    "a=rtcp-fb:97 trr-int 0100");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(e.message);
        }
    }
}

}
