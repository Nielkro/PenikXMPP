using Gee;
using Xmpp;
using Xmpp.Xep;

public class Xmpp.Xep.JingleRtp.PayloadType {
    public const string NAME = "payload-type";

    public uint8 id { get; set; }
    /** False when a wire id was missing, malformed, or outside RTP's 0..127 range. */
    public bool id_valid { get; private set; default = true; }
    public string? name { get; set; }
    public uint8 channels { get; set; default = 1; }
    public uint32 clockrate { get; set; }
    public uint32 maxptime { get; set; }
    public uint32 ptime { get; set; }
    public Map<string, string> parameters = new HashMap<string, string>();
    public Gee.List<RtcpFeedback> rtcp_fbs = new ArrayList<RtcpFeedback>();

    public static PayloadType parse(StanzaNode node) {
        PayloadType payloadType = new PayloadType();
        payloadType.channels = (uint8) node.get_attribute_uint("channels", payloadType.channels);
        payloadType.clockrate = node.get_attribute_uint("clockrate");
        string? raw_id = node.get_attribute("id");
        uint parsed_id = 0;
        string normalized_id = raw_id != null ? ((!) raw_id).strip() : "";
        if (normalized_id == "" || normalized_id.has_prefix("-") ||
                !uint.try_parse(normalized_id, out parsed_id, null, 10) ||
                parsed_id > 127) {
            payloadType.id_valid = false;
        } else {
            payloadType.id = (uint8) parsed_id;
        }
        payloadType.maxptime = node.get_attribute_uint("maxptime");
        payloadType.name = node.get_attribute("name");
        payloadType.ptime = node.get_attribute_uint("ptime");
        foreach (StanzaNode parameter in node.get_subnodes("parameter")) {
            payloadType.parameters[parameter.get_attribute("name")] = parameter.get_attribute("value");
        }
        foreach (StanzaNode subnode in node.get_subnodes(RtcpFeedback.NAME, RtcpFeedback.NS_URI)) {
            payloadType.rtcp_fbs.add(RtcpFeedback.parse(subnode));
        }
        foreach (StanzaNode subnode in node.get_subnodes(RtcpFeedback.TRR_INT_NAME, RtcpFeedback.NS_URI)) {
            payloadType.rtcp_fbs.add(RtcpFeedback.parse(subnode));
        }
        return payloadType;
    }

    public StanzaNode to_xml() {
        StanzaNode node = new StanzaNode.build(NAME, NS_URI)
                .put_attribute("id", id.to_string());
        if (channels != 1) node.put_attribute("channels", channels.to_string());
        if (clockrate != 0) node.put_attribute("clockrate", clockrate.to_string());
        if (maxptime != 0) node.put_attribute("maxptime", maxptime.to_string());
        if (name != null) node.put_attribute("name", name);
        if (ptime != 0) node.put_attribute("ptime", ptime.to_string());
        foreach (string parameter in parameters.keys) {
            node.put_node(new StanzaNode.build("parameter", NS_URI)
                    .put_attribute("name", parameter)
                    .put_attribute("value", parameters[parameter]));
        }
        foreach (RtcpFeedback rtcp_fb in rtcp_fbs) {
            node.put_node(rtcp_fb.to_xml());
        }
        return node;
    }

    public PayloadType clone() {
        PayloadType clone = new PayloadType();
        clone.id = id;
        clone.id_valid = id_valid;
        clone.name = name;
        clone.channels = channels;
        clone.clockrate = clockrate;
        clone.maxptime = maxptime;
        clone.ptime = ptime;
        clone.parameters.set_all(parameters);
        clone.rtcp_fbs.add_all(rtcp_fbs);
        return clone;
    }

    public static bool equals_func(PayloadType a, PayloadType b) {
        bool simple = a.id == b.id &&
                a.id_valid == b.id_valid &&
                a.name == b.name &&
                a.channels == b.channels &&
                a.clockrate == b.clockrate &&
                a.maxptime == b.maxptime &&
                a.ptime == b.ptime &&
                a.parameters.size == b.parameters.size &&
                a.rtcp_fbs.size == b.rtcp_fbs.size;
        if (!simple) return false;
        foreach (string key in a.parameters.keys) {
            if (!b.parameters.has_key(key)) return false;
            if (a.parameters[key] != b.parameters[key]) return false;
        }
        foreach (RtcpFeedback fb in a.rtcp_fbs) {
            if (!b.rtcp_fbs.any_match((it) => it.type_ == fb.type_ && it.subtype == fb.subtype)) return false;
        }
        return true;
    }

    public static uint hash_func(PayloadType payload_type) {
        return payload_type.to_xml().to_string().hash();
    }
}

public class Xmpp.Xep.JingleRtp.RtcpFeedback {
    public const string NS_URI = "urn:xmpp:jingle:apps:rtp:rtcp-fb:0";
    public const string NAME = "rtcp-fb";
    public const string TRR_INT_NAME = "rtcp-fb-trr-int";
    public const string TRR_INT_TYPE = "trr-int";

    public string type_ { get; private set; }
    public string? subtype { get; private set; }

    public RtcpFeedback(string type, string? subtype = null) {
        this.type_ = type;
        this.subtype = subtype;
    }

    private static bool is_xml_whitespace(char value) {
        return value == ' ' || value == '\t' || value == '\r' || value == '\n';
    }

    private static string interval_value_from_xml(string value) {
        // XML Schema integer lexemes allow outer XML whitespace and a positive
        // sign. SDP's trr-int uses 1*DIGIT instead. Normalize only this XML input
        // when creating a new feedback object; existing/shared objects stay intact.
        int start = 0;
        int end = value.length;
        while (start < end && is_xml_whitespace(value[start])) start++;
        while (end > start && is_xml_whitespace(value[end - 1])) end--;
        if (start < end && value[start] == '+') start++;
        return value.substring(start, end - start);
    }

    public static RtcpFeedback parse(StanzaNode node) {
        if (node.name == TRR_INT_NAME) {
            // Keep the SDP interval value in the existing feedback model, but
            // use XEP-0293's distinct XML element on the wire.
            return new RtcpFeedback(TRR_INT_TYPE,
                    interval_value_from_xml(node.get_attribute("value") ?? ""));
        }
        return new RtcpFeedback(
            node.get_attribute("type") ?? "",
            node.get_attribute("subtype"));
    }

    public StanzaNode to_xml() {
        if (type_ == TRR_INT_TYPE) {
            return new StanzaNode.build(TRR_INT_NAME, NS_URI)
                    .add_self_xmlns()
                    .put_attribute("value", subtype ?? "");
        }
        StanzaNode node = new StanzaNode.build(NAME, NS_URI)
                .add_self_xmlns()
                .put_attribute("type", type_);
        if (subtype != null) node.put_attribute("subtype", subtype);
        return node;
    }
}
