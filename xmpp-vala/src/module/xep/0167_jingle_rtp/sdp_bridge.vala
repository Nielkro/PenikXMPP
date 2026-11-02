using Gee;
using Xmpp;
using Xmpp.Xep;

public class Xmpp.Xep.JingleRtp.SdpBridge {

    private static void require_sdp_line(string? value, string field) throws Jingle.IqError {
        require_sdp_token(value, field);
    }

    private static void require_sdp_token(string? value, string field) throws Jingle.IqError {
        if (value == null || value == "") {
            throw new Jingle.IqError.BAD_REQUEST(@"missing SDP field: $(field)");
        }
        if (((!) value).contains("\r") || ((!) value).contains("\n")) {
            throw new Jingle.IqError.BAD_REQUEST(@"illegal newline in SDP field: $(field)");
        }
    }

    private static void require_sdp_atom(string? value, string field) throws Jingle.IqError {
        require_sdp_token(value, field);
        if (((!) value).contains(" ") || ((!) value).contains("\t")) {
            throw new Jingle.IqError.BAD_REQUEST(@"illegal whitespace in SDP field: $(field)");
        }
    }

    private static Gee.List<string> split_whitespace(string value) {
        var tokens = new ArrayList<string>();
        foreach (string part in value.strip().split(" ")) {
            string token = part.strip();
            if (token != "") tokens.add(token);
        }
        return tokens;
    }

    private static string strip_required_prefix(string line, string prefix, string field) throws Jingle.IqError {
        require_sdp_line(line, field);
        if (!line.has_prefix(prefix)) {
            throw new Jingle.IqError.BAD_REQUEST(@"expected SDP prefix $(prefix) for $(field)");
        }
        string value = line.substring(prefix.length).strip();
        require_sdp_token(value, field);
        return value;
    }

    private static string split_first_whitespace_field(string value, out string first, string field) throws Jingle.IqError {
        string stripped = value.strip();
        int split_index = stripped.index_of(" ");
        if (split_index < 0) {
            throw new Jingle.IqError.BAD_REQUEST(@"missing value for SDP field $(field)");
        }
        first = stripped.substring(0, split_index);
        string rest = stripped.substring(split_index + 1).strip();
        require_sdp_token(first, @"$(field) id");
        require_sdp_token(rest, field);
        return rest;
    }

    private static uint64 parse_uint_bounded(string value, string field, uint64 max) throws Jingle.IqError {
        require_sdp_token(value, field);
        for (int i = 0; i < value.length; i++) {
            char c = value[i];
            if (c < '0' || c > '9') {
                throw new Jingle.IqError.BAD_REQUEST(@"illegal unsigned integer for $(field)");
            }
        }

        // SDP numeric fields are decimal even when they contain leading zeroes.
        uint64 parsed = uint64.parse(value, 10);
        if (parsed > max) {
            throw new Jingle.IqError.BAD_REQUEST(@"unsigned integer out of range for $(field)");
        }
        return parsed;
    }

    private static uint8 parse_payload_id(string value) throws Jingle.IqError {
        return (uint8) parse_uint_bounded(value, "payload id", 127);
    }

    private static void validate_payload_id(uint8 payload_id) throws Jingle.IqError {
        parse_payload_id(payload_id.to_string());
    }

    private static void validate_payload_type_id(PayloadType payload_type)
            throws Jingle.IqError {
        if (!payload_type.id_valid) {
            throw new Jingle.IqError.BAD_REQUEST(
                "payload id is missing, malformed, or out of range");
        }
        validate_payload_id(payload_type.id);
    }

    private static uint8 parse_uint8(string value, string field) throws Jingle.IqError {
        return (uint8) parse_uint_bounded(value, field, uint8.MAX);
    }

    private static uint16 parse_uint16(string value, string field) throws Jingle.IqError {
        return (uint16) parse_uint_bounded(value, field, uint16.MAX);
    }

    private static uint32 parse_uint32(string value, string field) throws Jingle.IqError {
        return (uint32) parse_uint_bounded(value, field, uint32.MAX);
    }

    private static uint8 parse_hex_nibble(char c, string field) throws Jingle.IqError {
        if (c >= '0' && c <= '9') return (uint8) (c - '0');
        if (c >= 'a' && c <= 'f') return (uint8) (10 + c - 'a');
        if (c >= 'A' && c <= 'F') return (uint8) (10 + c - 'A');
        throw new Jingle.IqError.BAD_REQUEST(@"illegal hex digit in $(field)");
    }

    private static string validate_setup_value(string setup) throws Jingle.IqError {
        require_sdp_token(setup, "DTLS setup");
        switch (setup) {
            case "active":
            case "passive":
            case "actpass":
            case "holdconn":
                return setup;
            default:
                throw new Jingle.IqError.BAD_REQUEST("illegal DTLS setup value");
        }
    }

    private static string normalize_sdp_input_line(string line) throws Jingle.IqError {
        string normalized = line;
        if (normalized.has_suffix("\r")) {
            normalized = normalized.substring(0, normalized.length - 1);
        }
        normalized = normalized.strip();
        require_sdp_line(normalized, "SDP line");
        return normalized;
    }

    private static PayloadType? find_payload_type(SdpMediaSection section, uint8 payload_id) {
        foreach (PayloadType payload_type in section.payload_types) {
            if (payload_type.id == payload_id) return payload_type;
        }
        return null;
    }

    private static PayloadType get_or_create_payload_type(SdpMediaSection section, uint8 payload_id) {
        PayloadType? existing = find_payload_type(section, payload_id);
        if (existing != null) return (!) existing;

        var payload_type = new PayloadType();
        payload_type.id = payload_id;
        section.payload_types.add(payload_type);
        return payload_type;
    }

    private static string fingerprint_to_jingle_text(uint8[] fingerprint) throws Jingle.IqError {
        if (fingerprint.length == 0) {
            throw new Jingle.IqError.BAD_REQUEST("fingerprint must not be empty");
        }

        var formatted = new StringBuilder();
        for (int i = 0; i < fingerprint.length; i++) {
            if (i > 0) formatted.append(":");
            formatted.append("%02X".printf(fingerprint[i]));
        }
        return formatted.str;
    }

    public static string payload_type_to_rtpmap(PayloadType payload_type) throws Jingle.IqError {
        validate_payload_type_id(payload_type);
        require_sdp_token(payload_type.name, "payload-type name");
        if (payload_type.clockrate == 0) {
            throw new Jingle.IqError.BAD_REQUEST("payload-type clockrate is required for SDP rtpmap");
        }

        string encoding = @"$((!) payload_type.name)/$(payload_type.clockrate)";
        if (payload_type.channels > 1) {
            encoding += @"/$(payload_type.channels)";
        }
        return @"a=rtpmap:$(payload_type.id) $(encoding)";
    }

    public static string? payload_type_to_fmtp(PayloadType payload_type) throws Jingle.IqError {
        if (payload_type.parameters.size == 0) return null;

        var sdp_parameters = new HashMap<string, string>();
        foreach (string key in payload_type.parameters.keys) {
            string sdp_key;
            string sdp_value;
            if (fmtp_parameter_to_sdp(payload_type, key, payload_type.parameters[key], out sdp_key, out sdp_value)) {
                sdp_parameters[sdp_key] = sdp_value;
            }
        }
        if (sdp_parameters.size == 0) return null;

        var keys = new ArrayList<string>();
        foreach (string key in sdp_parameters.keys) keys.add(key);
        keys.sort((left, right) => left.collate(right));

        var parameters = new StringBuilder();
        bool first = true;
        foreach (string key in keys) {
            if (!first) parameters.append(";");
            first = false;
            parameters.append(@"$(key)=$(sdp_parameters[key])");
        }

        return @"a=fmtp:$(payload_type.id) $(parameters.str)";
    }

    private static bool fmtp_parameter_to_sdp(
            PayloadType payload_type,
            string key,
            string? value,
            out string sdp_key,
            out string sdp_value) throws Jingle.IqError {
        require_sdp_token(key, "fmtp parameter name");
        require_sdp_token(value, "fmtp parameter value");

        sdp_key = key.strip();
        sdp_value = ((!) value).strip();
        string codec_name = payload_type.name != null ? ((!) payload_type.name).strip().ascii_down() : "";
        if (codec_name != "opus") {
            return true;
        }

        string opus_key = sdp_key.ascii_down().replace("_", "-");
        switch (opus_key) {
            case "cbr":
            case "maxaveragebitrate":
            case "maxplaybackrate":
            case "minptime":
            case "sprop-maxcapturerate":
            case "sprop-stereo":
            case "stereo":
            case "usedtx":
            case "useinbandfec":
                sdp_key = opus_key;
                sdp_value = normalize_fmtp_boolean_value(sdp_value);
                return true;
            default:
                return false;
        }
    }

    private static string normalize_fmtp_boolean_value(string value) {
        string normalized = value.strip().ascii_down();
        if (normalized == "true" || normalized == "yes") return "1";
        if (normalized == "false" || normalized == "no") return "0";
        return value;
    }

    public static Gee.List<string> payload_type_to_sdp_attributes(PayloadType payload_type) throws Jingle.IqError {
        var lines = new ArrayList<string>();
        lines.add(payload_type_to_rtpmap(payload_type));

        string? fmtp = payload_type_to_fmtp(payload_type);
        if (fmtp != null) {
            lines.add(fmtp);
        }

        foreach (RtcpFeedback feedback in payload_type.rtcp_fbs) {
            lines.add(rtcp_feedback_to_sdp(payload_type.id, feedback));
        }
        return lines;
    }

    public static string rtcp_feedback_to_sdp(uint8 payload_id, RtcpFeedback feedback) throws Jingle.IqError {
        validate_payload_id(payload_id);
        validate_rtcp_feedback(feedback);
        if (feedback.subtype != null) {
            return @"a=rtcp-fb:$(payload_id) $(feedback.type_) $((!) feedback.subtype)";
        }
        return @"a=rtcp-fb:$(payload_id) $(feedback.type_)";
    }

    public static PayloadType payload_type_from_rtpmap(string line) throws Jingle.IqError {
        string value = strip_required_prefix(line, "a=rtpmap:", "rtpmap");
        Gee.List<string> tokens = split_whitespace(value);
        if (tokens.size != 2) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP rtpmap attribute");
        }

        string[] encoding = tokens[1].split("/");
        if (encoding.length < 2 || encoding.length > 3) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP rtpmap encoding");
        }

        var payload_type = new PayloadType();
        payload_type.id = parse_payload_id(tokens[0]);
        payload_type.name = encoding[0];
        require_sdp_token(payload_type.name, "payload-type name");
        payload_type.clockrate = parse_uint32(encoding[1], "payload clockrate");
        payload_type.channels = encoding.length == 3 ? parse_uint8(encoding[2], "payload channels") : 1;
        if (payload_type.clockrate == 0) {
            throw new Jingle.IqError.BAD_REQUEST("payload clockrate must not be zero");
        }
        if (payload_type.channels == 0) {
            throw new Jingle.IqError.BAD_REQUEST("payload channels must not be zero");
        }
        return payload_type;
    }

    public static void apply_fmtp_to_payload(PayloadType payload_type, string line) throws Jingle.IqError {
        string value = strip_required_prefix(line, "a=fmtp:", "fmtp");
        string payload_id;
        string parameters = split_first_whitespace_field(value, out payload_id, "fmtp");
        if (parse_payload_id(payload_id) != payload_type.id) {
            throw new Jingle.IqError.BAD_REQUEST("SDP fmtp payload id does not match payload");
        }

        foreach (string raw_pair in parameters.split(";")) {
            string pair = raw_pair.strip();
            require_sdp_token(pair, "fmtp parameter");
            string[] key_value = pair.split("=", 2);
            if (key_value.length != 2) {
                // libwebrtc can emit bare fmtp payload values such as
                // "a=fmtp:63 111/111" for RED. XEP-0167 parameters only have
                // name/value shape, so preserve parseability and ignore values
                // that cannot be represented as Jingle RTP parameters.
                continue;
            }
            string key = key_value[0].strip();
            string val = key_value[1].strip();
            require_sdp_token(key, "fmtp parameter name");
            require_sdp_token(val, "fmtp parameter value");
            payload_type.parameters[key] = val;
        }
    }

    private static void validate_rtcp_feedback(RtcpFeedback feedback) throws Jingle.IqError {
        require_sdp_token(feedback.type_, "rtcp-fb type");
        if (feedback.subtype != null) {
            require_sdp_token(feedback.subtype, "rtcp-fb subtype");
        }
        if (feedback.type_ == RtcpFeedback.TRR_INT_TYPE) {
            require_sdp_token(feedback.subtype, "rtcp-fb trr-int value");
            parse_uint32((!) feedback.subtype, "rtcp-fb trr-int value");
        }
    }

    private static void add_rtcp_feedback(
            Gee.List<RtcpFeedback> feedbacks, RtcpFeedback feedback) throws Jingle.IqError {
        validate_rtcp_feedback(feedback);
        foreach (RtcpFeedback existing in feedbacks) {
            if (existing.type_ != feedback.type_) continue;
            if (existing.subtype == feedback.subtype) return;
            if (feedback.type_ == RtcpFeedback.TRR_INT_TYPE) {
                if (parse_uint32((!) existing.subtype, "rtcp-fb trr-int value") ==
                        parse_uint32((!) feedback.subtype, "rtcp-fb trr-int value")) return;
                throw new Jingle.IqError.BAD_REQUEST("conflicting RTCP trr-int values at the same scope");
            }
        }
        feedbacks.add(feedback);
    }

    private static void apply_global_rtcp_feedback(
            SdpMediaSection section, Gee.List<RtcpFeedback> global_feedback) throws Jingle.IqError {
        foreach (PayloadType payload_type in section.payload_types) {
            var effective = new ArrayList<RtcpFeedback>();
            foreach (RtcpFeedback local_feedback in payload_type.rtcp_fbs) {
                add_rtcp_feedback(effective, local_feedback);
            }
            bool local_interval = effective.any_match((it) => it.type_ == RtcpFeedback.TRR_INT_TYPE);
            foreach (RtcpFeedback shared_feedback in global_feedback) {
                // Feedback capabilities are additive (e.g. global nack pli and
                // payload nack sli). Treat a payload-specific scalar interval as
                // overriding the content default; XEP-0293 does not state precedence.
                if (local_interval && shared_feedback.type_ == RtcpFeedback.TRR_INT_TYPE) continue;
                add_rtcp_feedback(effective, shared_feedback);
            }
            payload_type.rtcp_fbs = effective;
        }
    }

    private static RtcpFeedback rtcp_feedback_from_sdp_attribute(
            string line, out string payload_token) throws Jingle.IqError {
        string value = strip_required_prefix(line, "a=rtcp-fb:", "rtcp-fb");
        Gee.List<string> tokens = split_whitespace(value);
        if (tokens.size < 2 || tokens.size > 3) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP rtcp-fb attribute");
        }

        payload_token = tokens[0];
        require_sdp_token(tokens[1], "rtcp-fb type");
        var feedback = new RtcpFeedback(tokens[1], tokens.size == 3 ? tokens[2] : null);
        validate_rtcp_feedback(feedback);
        return feedback;
    }

    public static RtcpFeedback rtcp_feedback_from_sdp(string line, out uint8 payload_id) throws Jingle.IqError {
        string payload_token;
        RtcpFeedback feedback = rtcp_feedback_from_sdp_attribute(line, out payload_token);
        payload_id = parse_payload_id(payload_token);
        return feedback;
    }

    public static string header_extension_to_sdp(SdpHeaderExtension extension) throws Jingle.IqError {
        if (!HeaderExtension.id_is_valid(extension.id)) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP RTP header extension id");
        }
        require_sdp_atom(extension.uri, "RTP header extension URI");

        var line = new StringBuilder();
        line.append(@"a=extmap:$(extension.id)");
        if (extension.direction != SdpMediaDirection.SEND_RECV) {
            line.append(@"/$(extension.direction.to_sdp())");
        }
        line.append(@" $(extension.uri)");
        foreach (HeaderExtensionParameter parameter in extension.parameters) {
            require_sdp_atom(parameter.name, "RTP header extension parameter name");
            line.append(@" $(parameter.name)");
            if (parameter.value != null) {
                require_sdp_atom((!) parameter.value, "RTP header extension parameter value");
                line.append(@"=$((!) parameter.value)");
            }
        }
        return line.str;
    }

    public static SdpHeaderExtension header_extension_from_sdp(string line) throws Jingle.IqError {
        string value = strip_required_prefix(line, "a=extmap:", "RTP header extension");
        Gee.List<string> tokens = split_whitespace(value);
        if (tokens.size < 2) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP RTP header extension attribute");
        }

        string[] id_and_direction = tokens[0].split("/", 2);
        if (id_and_direction.length < 1 || id_and_direction.length > 2) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP RTP header extension id/direction");
        }
        uint16 id = parse_uint16(id_and_direction[0], "RTP header extension id");
        if (!HeaderExtension.id_is_valid(id)) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP RTP header extension id");
        }
        SdpMediaDirection direction = SdpMediaDirection.SEND_RECV;
        if (id_and_direction.length == 2) {
            direction = SdpMediaDirection.parse_sdp_attribute(@"a=$(id_and_direction[1])");
        }

        require_sdp_atom(tokens[1], "RTP header extension URI");
        var extension = new SdpHeaderExtension(id, tokens[1], direction);
        for (int i = 2; i < tokens.size; i++) {
            string[] key_value = tokens[i].split("=", 2);
            require_sdp_atom(key_value[0], "RTP header extension parameter name");
            string? parameter_value = null;
            if (key_value.length == 2) {
                require_sdp_atom(key_value[1], "RTP header extension parameter value");
                parameter_value = key_value[1];
            }
            extension.parameters.add(new HeaderExtensionParameter(key_value[0], parameter_value));
        }
        return extension;
    }

    public static string candidate_to_sdp(Xmpp.Xep.JingleIceUdp.Candidate candidate) throws Jingle.IqError {
        require_sdp_token(candidate.foundation, "candidate foundation");
        require_sdp_token(candidate.ip, "candidate ip");
        require_sdp_token(candidate.protocol, "candidate protocol");

        var line = new StringBuilder();
        line.append(@"a=candidate:$(candidate.foundation) $(candidate.component) $(candidate.protocol.ascii_down()) ");
        line.append(@"$(candidate.priority) $(candidate.ip) $(candidate.port) typ $(candidate.type_.to_string())");

        if (candidate.rel_addr != null && candidate.rel_addr != "") {
            require_sdp_token(candidate.rel_addr, "candidate rel-addr");
            line.append(@" raddr $((!) candidate.rel_addr)");
            if (candidate.rel_port != 0) {
                line.append(@" rport $(candidate.rel_port)");
            }
        }

        line.append(@" generation $(candidate.generation)");
        return line.str;
    }

    public static Xmpp.Xep.JingleIceUdp.Candidate candidate_from_sdp(string line, string? id = null) throws Jingle.IqError {
        string value = strip_required_prefix(line, "a=candidate:", "candidate");
        Gee.List<string> tokens = split_whitespace(value);
        if (tokens.size < 8 || tokens[6] != "typ") {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP ICE candidate");
        }

        var candidate = new Xmpp.Xep.JingleIceUdp.Candidate();
        candidate.foundation = tokens[0];
        candidate.component = parse_uint8(tokens[1], "candidate component");
        candidate.protocol = tokens[2].ascii_down();
        candidate.priority = parse_uint32(tokens[3], "candidate priority");
        candidate.ip = tokens[4];
        candidate.port = parse_uint16(tokens[5], "candidate port");
        candidate.type_ = Xmpp.Xep.JingleIceUdp.Candidate.Type.parse(tokens[7]);
        candidate.network = 0;
        candidate.generation = 0;

        require_sdp_token(candidate.foundation, "candidate foundation");
        require_sdp_token(candidate.protocol, "candidate protocol");
        require_sdp_token(candidate.ip, "candidate ip");

        int index = 8;
        while (index < tokens.size) {
            string name = tokens[index];
            if (index + 1 >= tokens.size) {
                throw new Jingle.IqError.BAD_REQUEST(@"missing value for SDP candidate extension $(name)");
            }
            string val = tokens[index + 1];
            switch (name) {
                case "raddr":
                    candidate.rel_addr = val;
                    require_sdp_token(candidate.rel_addr, "candidate rel-addr");
                    break;
                case "rport":
                    candidate.rel_port = parse_uint16(val, "candidate rel-port");
                    break;
                case "generation":
                    candidate.generation = parse_uint8(val, "candidate generation");
                    break;
                default:
                    // Ignore unknown candidate extension pairs. They are not
                    // required to preserve the XEP-0176 fields DinoX consumes.
                    break;
            }
            index += 2;
        }

        candidate.id = id ?? @"sdp-$(candidate.foundation)-$(candidate.component)-$(candidate.ip)-$(candidate.port)";
        require_sdp_token(candidate.id, "candidate id");
        return candidate;
    }

    public static string fingerprint_to_sdp(string hash, uint8[] fingerprint) throws Jingle.IqError {
        require_sdp_token(hash, "fingerprint hash");
        if (fingerprint.length == 0) {
            throw new Jingle.IqError.BAD_REQUEST("fingerprint must not be empty");
        }

        var formatted = new StringBuilder();
        for (int i = 0; i < fingerprint.length; i++) {
            if (i > 0) formatted.append(":");
            formatted.append("%02X".printf(fingerprint[i]));
        }
        return @"a=fingerprint:$(hash.ascii_down()) $(formatted.str)";
    }

    public static SdpFingerprint fingerprint_from_sdp(string line) throws Jingle.IqError {
        string value = strip_required_prefix(line, "a=fingerprint:", "fingerprint");
        Gee.List<string> tokens = split_whitespace(value);
        if (tokens.size != 2) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP fingerprint attribute");
        }

        string hash = tokens[0].ascii_down();
        require_sdp_token(hash, "fingerprint hash");
        string[] octets = tokens[1].split(":");
        if (octets.length == 0) {
            throw new Jingle.IqError.BAD_REQUEST("fingerprint must not be empty");
        }

        uint8[] fingerprint = new uint8[octets.length];
        for (int i = 0; i < octets.length; i++) {
            if (octets[i].length != 2) {
                throw new Jingle.IqError.BAD_REQUEST("invalid fingerprint octet");
            }
            fingerprint[i] = (uint8) ((parse_hex_nibble(octets[i][0], "fingerprint") << 4) |
                    parse_hex_nibble(octets[i][1], "fingerprint"));
        }

        return new SdpFingerprint(hash, fingerprint);
    }

    public static string setup_to_sdp(string setup) throws Jingle.IqError {
        return @"a=setup:$(validate_setup_value(setup))";
    }

    public static string setup_from_sdp(string line) throws Jingle.IqError {
        return validate_setup_value(strip_required_prefix(line, "a=setup:", "DTLS setup"));
    }

    public static string media_direction_to_sdp(SdpMediaDirection direction) {
        return @"a=$(direction.to_sdp())";
    }

    public static Gee.List<string> media_section_to_sdp_lines(
            SdpMediaSection section,
            bool include_extmap_allow_mixed = true) throws Jingle.IqError {
        require_sdp_token(section.media, "media");
        require_sdp_token(section.protocol, "media protocol");
        if (section.payload_types.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("media section requires at least one payload type");
        }
        if ((section.ice_ufrag == null) != (section.ice_pwd == null)) {
            throw new Jingle.IqError.BAD_REQUEST("ICE ufrag and pwd must be present together");
        }

        var lines = new ArrayList<string>();
        var media_line = new StringBuilder();
        media_line.append(@"m=$(section.media) $(section.port) $(section.protocol)");
        foreach (PayloadType payload_type in section.payload_types) {
            validate_payload_type_id(payload_type);
            media_line.append(@" $(payload_type.id)");
        }
        lines.add(media_line.str);

        if (section.mid != null) {
            require_sdp_token(section.mid, "mid");
            lines.add(@"a=mid:$((!) section.mid)");
        }
        if (section.ice_ufrag != null) {
            require_sdp_token(section.ice_ufrag, "ice-ufrag");
            lines.add(@"a=ice-ufrag:$((!) section.ice_ufrag)");
        }
        if (section.ice_pwd != null) {
            require_sdp_token(section.ice_pwd, "ice-pwd");
            lines.add(@"a=ice-pwd:$((!) section.ice_pwd)");
        }
        if (section.fingerprint != null) {
            SdpFingerprint fingerprint = (!) section.fingerprint;
            lines.add(fingerprint_to_sdp(fingerprint.hash, fingerprint.fingerprint));
        }
        if (section.setup != null) {
            lines.add(setup_to_sdp((!) section.setup));
        }
        if (section.rtcp_mux) {
            lines.add("a=rtcp-mux");
        }
        if (section.direction != null) {
            lines.add(media_direction_to_sdp((!) section.direction));
        }
        if (include_extmap_allow_mixed && section.extmap_allow_mixed) {
            lines.add("a=extmap-allow-mixed");
        }
        foreach (SdpHeaderExtension extension in section.header_extensions) {
            lines.add(header_extension_to_sdp(extension));
        }

        foreach (PayloadType payload_type in section.payload_types) {
            lines.add_all(payload_type_to_sdp_attributes(payload_type));
        }
        foreach (Xmpp.Xep.JingleIceUdp.Candidate candidate in section.candidates) {
            lines.add(candidate_to_sdp(candidate));
        }
        return lines;
    }

    public static string media_section_to_sdp(SdpMediaSection section) throws Jingle.IqError {
        var builder = new StringBuilder();
        foreach (string line in media_section_to_sdp_lines(section)) {
            builder.append(line);
            builder.append("\r\n");
        }
        return builder.str;
    }

    public static SdpMediaSection media_section_from_sdp_lines(Gee.List<string> lines) throws Jingle.IqError {
        if (lines.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("SDP media section is empty");
        }

        string media_value = strip_required_prefix(lines[0], "m=", "media line");
        Gee.List<string> media_tokens = split_whitespace(media_value);
        if (media_tokens.size < 4) {
            throw new Jingle.IqError.BAD_REQUEST("invalid SDP media line");
        }

        var section = new SdpMediaSection(
                media_tokens[0],
                parse_uint16(media_tokens[1], "media port"),
                media_tokens[2]);
        var global_feedback = new ArrayList<RtcpFeedback>();

        for (int i = 3; i < media_tokens.size; i++) {
            get_or_create_payload_type(section, parse_payload_id(media_tokens[i]));
        }

        for (int i = 1; i < lines.size; i++) {
            string line = lines[i].strip();
            require_sdp_line(line, "media section line");

            if (line.has_prefix("m=")) {
                throw new Jingle.IqError.BAD_REQUEST("nested SDP media line is not allowed in one media section");
            } else if (line.has_prefix("a=mid:")) {
                section.mid = strip_required_prefix(line, "a=mid:", "mid");
            } else if (line.has_prefix("a=ice-ufrag:")) {
                section.ice_ufrag = strip_required_prefix(line, "a=ice-ufrag:", "ice-ufrag");
            } else if (line.has_prefix("a=ice-pwd:")) {
                section.ice_pwd = strip_required_prefix(line, "a=ice-pwd:", "ice-pwd");
            } else if (line == "a=rtcp-mux") {
                section.rtcp_mux = true;
            } else if (line.has_prefix("a=fingerprint:")) {
                section.fingerprint = fingerprint_from_sdp(line);
            } else if (line.has_prefix("a=setup:")) {
                section.setup = setup_from_sdp(line);
            } else if (SdpMediaDirection.is_sdp_direction_line(line)) {
                section.direction = SdpMediaDirection.parse_sdp_attribute(line);
            } else if (line == "a=extmap-allow-mixed") {
                section.extmap_allow_mixed = true;
            } else if (line.has_prefix("a=extmap:")) {
                section.header_extensions.add(header_extension_from_sdp(line));
            } else if (line.has_prefix("a=rtpmap:")) {
                PayloadType parsed = payload_type_from_rtpmap(line);
                PayloadType existing = get_or_create_payload_type(section, parsed.id);
                existing.name = parsed.name;
                existing.clockrate = parsed.clockrate;
                existing.channels = parsed.channels;
            } else if (line.has_prefix("a=fmtp:")) {
                string value = strip_required_prefix(line, "a=fmtp:", "fmtp");
                string payload_id_token;
                split_first_whitespace_field(value, out payload_id_token, "fmtp");
                PayloadType payload_type = get_or_create_payload_type(section, parse_payload_id(payload_id_token));
                apply_fmtp_to_payload(payload_type, line);
            } else if (line.has_prefix("a=rtcp-fb:")) {
                string payload_token;
                RtcpFeedback feedback = rtcp_feedback_from_sdp_attribute(line, out payload_token);
                if (payload_token == "*") {
                    add_rtcp_feedback(global_feedback, feedback);
                } else {
                    add_rtcp_feedback(get_or_create_payload_type(
                        section, parse_payload_id(payload_token)).rtcp_fbs, feedback);
                }
            } else if (line.has_prefix("a=candidate:")) {
                section.candidates.add(candidate_from_sdp(line));
            }
        }

        apply_global_rtcp_feedback(section, global_feedback);
        if ((section.ice_ufrag == null) != (section.ice_pwd == null)) {
            throw new Jingle.IqError.BAD_REQUEST("ICE ufrag and pwd must be present together");
        }
        return section;
    }

    public static StanzaNode media_section_to_jingle_description_node(
            SdpMediaSection section,
            Jingle.Role described_role = Jingle.Role.INITIATOR) throws Jingle.IqError {
        require_sdp_token(section.media, "media");
        if (section.payload_types.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("Jingle RTP description requires at least one payload type");
        }

        var description = new StanzaNode.build("description", NS_URI)
                .add_self_xmlns()
                .put_attribute("media", section.media);

        foreach (PayloadType payload_type in section.payload_types) {
            validate_payload_type_id(payload_type);
            description.put_node(payload_type.to_xml());
        }
        foreach (SdpHeaderExtension extension in section.header_extensions) {
            description.put_node(header_extension_to_jingle(extension, described_role).to_xml());
        }
        if (section.extmap_allow_mixed) {
            description.put_node(new StanzaNode.build("extmap-allow-mixed", HeaderExtension.NS_URI)
                    .add_self_xmlns());
        }
        if (section.rtcp_mux) {
            description.put_node(new StanzaNode.build("rtcp-mux", NS_URI));
        }
        return description;
    }

    public static StanzaNode media_section_to_jingle_transport_node(SdpMediaSection section) throws Jingle.IqError {
        if (section.ice_ufrag == null || section.ice_pwd == null) {
            throw new Jingle.IqError.BAD_REQUEST("Jingle ICE-UDP transport requires ICE ufrag and pwd");
        }
        require_sdp_token(section.ice_ufrag, "ice-ufrag");
        require_sdp_token(section.ice_pwd, "ice-pwd");

        var transport = new StanzaNode.build("transport", Xmpp.Xep.JingleIceUdp.NS_URI)
                .add_self_xmlns()
                .put_attribute("ufrag", (!) section.ice_ufrag)
                .put_attribute("pwd", (!) section.ice_pwd);

        if (section.fingerprint != null) {
            SdpFingerprint fingerprint = (!) section.fingerprint;
            require_sdp_token(fingerprint.hash, "fingerprint hash");
            var fingerprint_node = new StanzaNode.build("fingerprint", Xmpp.Xep.JingleIceUdp.DTLS_NS_URI)
                    .add_self_xmlns()
                    .put_attribute("hash", fingerprint.hash.ascii_down())
                    .put_node(new StanzaNode.text(fingerprint_to_jingle_text(fingerprint.fingerprint)));
            if (section.setup != null) {
                fingerprint_node.put_attribute("setup", validate_setup_value((!) section.setup));
            }
            transport.put_node(fingerprint_node);
        } else if (section.setup != null) {
            throw new Jingle.IqError.BAD_REQUEST("DTLS setup requires a fingerprint in Jingle ICE-UDP transport");
        }

        foreach (Xmpp.Xep.JingleIceUdp.Candidate candidate in section.candidates) {
            transport.put_node(candidate.to_xml());
        }
        return transport;
    }

    public static SdpMediaSection media_section_from_jingle_nodes(
            string mid,
            StanzaNode description,
            StanzaNode transport,
            Jingle.Role described_role = Jingle.Role.INITIATOR) throws Jingle.IqError {
        require_sdp_token(mid, "Jingle content name");
        if (description.name != "description" || description.ns_uri != NS_URI) {
            throw new Jingle.IqError.BAD_REQUEST("expected XEP-0167 RTP description node");
        }
        if (transport.name != "transport" || transport.ns_uri != Xmpp.Xep.JingleIceUdp.NS_URI) {
            throw new Jingle.IqError.BAD_REQUEST("expected XEP-0176 ICE-UDP transport node");
        }

        string? media = description.get_attribute("media");
        require_sdp_token(media, "RTP media");
        var section = new SdpMediaSection((!) media);
        section.mid = mid;
        section.ice_ufrag = transport.get_attribute("ufrag");
        section.ice_pwd = transport.get_attribute("pwd");
        section.rtcp_mux = description.get_subnode("rtcp-mux") != null;

        foreach (StanzaNode payload_type in description.get_subnodes(PayloadType.NAME)) {
            section.payload_types.add(PayloadType.parse(payload_type));
        }
        if (section.payload_types.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("Jingle RTP description requires at least one payload type");
        }
        var global_feedback = new ArrayList<RtcpFeedback>();
        foreach (StanzaNode feedback_node in description.get_subnodes(RtcpFeedback.NAME, RtcpFeedback.NS_URI)) {
            add_rtcp_feedback(global_feedback, RtcpFeedback.parse(feedback_node));
        }
        foreach (StanzaNode feedback_node in description.get_subnodes(RtcpFeedback.TRR_INT_NAME, RtcpFeedback.NS_URI)) {
            add_rtcp_feedback(global_feedback, RtcpFeedback.parse(feedback_node));
        }
        apply_global_rtcp_feedback(section, global_feedback);
        foreach (StanzaNode extension_node in description.get_subnodes(
                HeaderExtension.NAME, HeaderExtension.NS_URI)) {
            section.header_extensions.add(header_extension_from_jingle(
                HeaderExtension.parse(extension_node), described_role));
        }
        section.extmap_allow_mixed = description.get_subnode(
            "extmap-allow-mixed", HeaderExtension.NS_URI) != null;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate")) {
            section.candidates.add(Xmpp.Xep.JingleIceUdp.Candidate.parse(candidate));
        }

        StanzaNode? fingerprint_node = transport.get_subnode("fingerprint", Xmpp.Xep.JingleIceUdp.DTLS_NS_URI);
        if (fingerprint_node != null) {
            string? hash = ((!) fingerprint_node).get_attribute("hash");
            string? value = ((!) fingerprint_node).get_string_content();
            require_sdp_token(hash, "fingerprint hash");
            require_sdp_token(value, "fingerprint");
            section.fingerprint = fingerprint_from_sdp(@"a=fingerprint:$((!) hash) $((!) value)");

            string? setup = ((!) fingerprint_node).get_attribute("setup");
            if (setup != null) {
                section.setup = validate_setup_value((!) setup);
            }
        }

        if (section.ice_ufrag == null || section.ice_pwd == null) {
            throw new Jingle.IqError.BAD_REQUEST("Jingle ICE-UDP transport requires ICE ufrag and pwd");
        }
        return section;
    }

    public static SdpSession session_from_jingle_content_node_pairs(
            Gee.List<SdpJingleContentNodePair> content_pairs,
            Jingle.Role described_role = Jingle.Role.INITIATOR) throws Jingle.IqError {
        if (content_pairs.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("SDP session requires at least one Jingle content node pair");
        }

        var session = new SdpSession();
        var content_names = new HashSet<string>();
        foreach (SdpJingleContentNodePair content_pair in content_pairs) {
            require_sdp_token(content_pair.content_name, "Jingle content name");
            if (content_names.contains(content_pair.content_name)) {
                throw new Jingle.IqError.BAD_REQUEST("duplicate Jingle content name");
            }
            content_names.add(content_pair.content_name);
            session.media_sections.add(media_section_from_jingle_nodes(
                content_pair.content_name,
                content_pair.description,
                content_pair.transport,
                described_role));
        }
        return session;
    }

    public static Gee.List<SdpJingleContentNodePair> jingle_content_node_pairs_from_session(
            SdpSession session,
            Jingle.Role described_role = Jingle.Role.INITIATOR) throws Jingle.IqError {
        if (session.media_sections.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("Jingle content node pairs require at least one media section");
        }

        var content_pairs = new ArrayList<SdpJingleContentNodePair>();
        var content_names = new HashSet<string>();
        foreach (SdpMediaSection section in session.media_sections) {
            string content_name = section.mid ?? section.media;
            require_sdp_token(content_name, "Jingle content name");
            if (content_names.contains(content_name)) {
                throw new Jingle.IqError.BAD_REQUEST("duplicate Jingle content name");
            }
            content_names.add(content_name);
            content_pairs.add(new SdpJingleContentNodePair(
                content_name,
                media_section_to_jingle_description_node(section, described_role),
                media_section_to_jingle_transport_node(section)));
        }
        return content_pairs;
    }

    public static void apply_bundle_policy(SdpSession session, SdpBundlePolicy policy) throws Jingle.IqError {
        session.bundle_mids.clear();

        switch (policy) {
            case SdpBundlePolicy.NONE:
                return;
            case SdpBundlePolicy.ALL_MEDIA_SECTIONS:
                var mids = new HashSet<string>();
                foreach (SdpMediaSection section in session.media_sections) {
                    if (section.mid == null) {
                        throw new Jingle.IqError.BAD_REQUEST("BUNDLE policy requires every media section to have a MID");
                    }
                    string mid = (!) section.mid;
                    require_sdp_token(mid, "BUNDLE mid");
                    if (mids.contains(mid)) {
                        throw new Jingle.IqError.BAD_REQUEST("duplicate BUNDLE mid");
                    }
                    mids.add(mid);
                    session.bundle_mids.add(mid);
                }
                return;
            default:
                assert_not_reached();
        }
    }

    public static Gee.List<string> session_to_sdp_lines(SdpSession session) throws Jingle.IqError {
        require_sdp_token(session.origin_username, "SDP origin username");
        require_sdp_token(session.origin_session_id, "SDP origin session id");
        require_sdp_token(session.origin_session_version, "SDP origin session version");
        require_sdp_token(session.origin_address, "SDP origin address");
        require_sdp_token(session.session_name, "SDP session name");
        if (session.media_sections.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("SDP session requires at least one media section");
        }

        var lines = new ArrayList<string>();
        lines.add("v=0");
        lines.add(@"o=$(session.origin_username) $(session.origin_session_id) $(session.origin_session_version) IN IP4 $(session.origin_address)");
        lines.add(@"s=$(session.session_name)");
        lines.add("t=0 0");

        if (!session.bundle_mids.is_empty) {
            var group = new StringBuilder("a=group:BUNDLE");
            foreach (string mid in session.bundle_mids) {
                require_sdp_token(mid, "BUNDLE mid");
                group.append(@" $(mid)");
            }
            lines.add(group.str);
        }

        bool session_extmap_allow_mixed = !session.media_sections.is_empty &&
            session.media_sections.all_match((section) => section.extmap_allow_mixed);
        if (session_extmap_allow_mixed) {
            lines.add("a=extmap-allow-mixed");
        }

        foreach (SdpMediaSection media_section in session.media_sections) {
            lines.add_all(media_section_to_sdp_lines(media_section, !session_extmap_allow_mixed));
        }
        return lines;
    }

    public static string session_to_sdp(SdpSession session) throws Jingle.IqError {
        var builder = new StringBuilder();
        foreach (string line in session_to_sdp_lines(session)) {
            builder.append(line);
            builder.append("\r\n");
        }
        return builder.str;
    }

    public static SdpSession session_from_sdp(string sdp) throws Jingle.IqError {
        if (sdp == "") {
            throw new Jingle.IqError.BAD_REQUEST("SDP session is empty");
        }
        var lines = new ArrayList<string>();
        foreach (string raw_line in sdp.split("\n")) {
            string line = raw_line;
            if (line.has_suffix("\r")) {
                line = line.substring(0, line.length - 1);
            }
            line = line.strip();
            if (line != "") {
                lines.add(line);
            }
        }
        return session_from_sdp_lines(lines);
    }

    public static SdpSession session_from_sdp_lines(Gee.List<string> lines) throws Jingle.IqError {
        if (lines.size < 4) {
            throw new Jingle.IqError.BAD_REQUEST("SDP session is too short");
        }

        var session = new SdpSession();
        var current_media_lines = new ArrayList<string>();
        bool saw_version = false;
        bool saw_origin = false;
        bool saw_session_name = false;
        bool saw_timing = false;
        bool session_extmap_allow_mixed = false;

        foreach (string raw_line in lines) {
            string line = normalize_sdp_input_line(raw_line);
            if (line.has_prefix("m=")) {
                if (!current_media_lines.is_empty) {
                    session.media_sections.add(media_section_from_sdp_lines(current_media_lines));
                    current_media_lines.clear();
                }
                current_media_lines.add(line);
                continue;
            }

            if (!current_media_lines.is_empty) {
                current_media_lines.add(line);
                continue;
            }

            if (line.has_prefix("v=")) {
                string version = strip_required_prefix(line, "v=", "SDP version");
                if (version != "0") {
                    throw new Jingle.IqError.BAD_REQUEST("unsupported SDP version");
                }
                saw_version = true;
            } else if (line.has_prefix("o=")) {
                Gee.List<string> origin = split_whitespace(strip_required_prefix(line, "o=", "SDP origin"));
                if (origin.size != 6 || origin[3] != "IN" || origin[4] != "IP4") {
                    throw new Jingle.IqError.BAD_REQUEST("unsupported SDP origin line");
                }
                session.origin_username = origin[0];
                session.origin_session_id = origin[1];
                session.origin_session_version = origin[2];
                session.origin_address = origin[5];
                saw_origin = true;
            } else if (line.has_prefix("s=")) {
                session.session_name = strip_required_prefix(line, "s=", "SDP session name");
                saw_session_name = true;
            } else if (line.has_prefix("t=")) {
                string timing = strip_required_prefix(line, "t=", "SDP timing");
                if (timing != "0 0") {
                    throw new Jingle.IqError.BAD_REQUEST("unsupported SDP timing");
                }
                saw_timing = true;
            } else if (line.has_prefix("a=group:BUNDLE")) {
                Gee.List<string> group = split_whitespace(strip_required_prefix(line, "a=group:", "SDP group"));
                if (group.size < 2 || group[0] != "BUNDLE") {
                    throw new Jingle.IqError.BAD_REQUEST("unsupported SDP group");
                }
                for (int i = 1; i < group.size; i++) {
                    require_sdp_token(group[i], "BUNDLE mid");
                    session.bundle_mids.add(group[i]);
                }
            } else if (line == "a=extmap-allow-mixed") {
                session_extmap_allow_mixed = true;
            }
        }

        if (!current_media_lines.is_empty) {
            session.media_sections.add(media_section_from_sdp_lines(current_media_lines));
        }
        if (!saw_version || !saw_origin || !saw_session_name || !saw_timing) {
            throw new Jingle.IqError.BAD_REQUEST("SDP session is missing required session lines");
        }
        if (session.media_sections.is_empty) {
            throw new Jingle.IqError.BAD_REQUEST("SDP session requires at least one media section");
        }
        if (session_extmap_allow_mixed) {
            foreach (SdpMediaSection section in session.media_sections) {
                section.extmap_allow_mixed = true;
            }
        }
        return session;
    }

    private static HeaderExtension header_extension_to_jingle(
            SdpHeaderExtension extension,
            Jingle.Role described_role) {
        Jingle.Senders senders;
        switch (extension.direction) {
            case SdpMediaDirection.SEND_RECV:
                senders = Jingle.Senders.BOTH;
                break;
            case SdpMediaDirection.INACTIVE:
                senders = Jingle.Senders.NONE;
                break;
            case SdpMediaDirection.SEND_ONLY:
                senders = senders_for_role(described_role);
                break;
            case SdpMediaDirection.RECV_ONLY:
                senders = senders_for_role(opposite_role(described_role));
                break;
            default:
                assert_not_reached();
        }

        var mapped = new HeaderExtension(extension.id, extension.uri, senders);
        foreach (HeaderExtensionParameter parameter in extension.parameters) {
            mapped.parameters.add(new HeaderExtensionParameter(parameter.name, parameter.value));
        }
        return mapped;
    }

    private static SdpHeaderExtension header_extension_from_jingle(
            HeaderExtension extension,
            Jingle.Role described_role) {
        SdpMediaDirection direction;
        switch (extension.senders) {
            case Jingle.Senders.BOTH:
                direction = SdpMediaDirection.SEND_RECV;
                break;
            case Jingle.Senders.NONE:
                direction = SdpMediaDirection.INACTIVE;
                break;
            case Jingle.Senders.INITIATOR:
                direction = described_role == Jingle.Role.INITIATOR
                    ? SdpMediaDirection.SEND_ONLY
                    : SdpMediaDirection.RECV_ONLY;
                break;
            case Jingle.Senders.RESPONDER:
                direction = described_role == Jingle.Role.RESPONDER
                    ? SdpMediaDirection.SEND_ONLY
                    : SdpMediaDirection.RECV_ONLY;
                break;
            default:
                assert_not_reached();
        }

        var mapped = new SdpHeaderExtension(extension.id, extension.uri, direction);
        foreach (HeaderExtensionParameter parameter in extension.parameters) {
            mapped.parameters.add(new HeaderExtensionParameter(parameter.name, parameter.value));
        }
        return mapped;
    }

    private static Jingle.Senders senders_for_role(Jingle.Role role) {
        return role == Jingle.Role.INITIATOR
            ? Jingle.Senders.INITIATOR
            : Jingle.Senders.RESPONDER;
    }

    private static Jingle.Role opposite_role(Jingle.Role role) {
        return role == Jingle.Role.INITIATOR
            ? Jingle.Role.RESPONDER
            : Jingle.Role.INITIATOR;
    }
}

public enum Xmpp.Xep.JingleRtp.SdpBundlePolicy {
    NONE,
    ALL_MEDIA_SECTIONS
}

public enum Xmpp.Xep.JingleRtp.SdpMediaDirection {
    SEND_RECV,
    SEND_ONLY,
    RECV_ONLY,
    INACTIVE;

    public string to_sdp() {
        switch (this) {
            case SEND_RECV:
                return "sendrecv";
            case SEND_ONLY:
                return "sendonly";
            case RECV_ONLY:
                return "recvonly";
            case INACTIVE:
                return "inactive";
            default:
                assert_not_reached();
        }
    }

    public static bool is_sdp_direction_line(string line) {
        return line == "a=sendrecv" ||
                line == "a=sendonly" ||
                line == "a=recvonly" ||
                line == "a=inactive";
    }

    public static SdpMediaDirection parse_sdp_attribute(string line) throws Jingle.IqError {
        switch (line) {
            case "a=sendrecv":
                return SEND_RECV;
            case "a=sendonly":
                return SEND_ONLY;
            case "a=recvonly":
                return RECV_ONLY;
            case "a=inactive":
                return INACTIVE;
            default:
                throw new Jingle.IqError.BAD_REQUEST("invalid SDP media direction");
        }
    }
}

public class Xmpp.Xep.JingleRtp.SdpFingerprint {
    public string hash { get; private set; }
    public uint8[] fingerprint { get; private set; }

    public SdpFingerprint(string hash, uint8[] fingerprint) {
        this.hash = hash;
        this.fingerprint = fingerprint;
    }
}

public class Xmpp.Xep.JingleRtp.SdpMediaSection {
    public string media { get; set; }
    public uint16 port { get; set; }
    public string protocol { get; set; }
    public string? mid { get; set; default = null; }
    public string? ice_ufrag { get; set; default = null; }
    public string? ice_pwd { get; set; default = null; }
    public bool rtcp_mux { get; set; default = false; }
    public SdpFingerprint? fingerprint { get; set; default = null; }
    public string? setup { get; set; default = null; }
    public SdpMediaDirection? direction { get; set; default = null; }
    public bool extmap_allow_mixed { get; set; default = false; }

    public Gee.List<PayloadType> payload_types = new ArrayList<PayloadType>(PayloadType.equals_func);
    public Gee.List<SdpHeaderExtension> header_extensions = new ArrayList<SdpHeaderExtension>();
    public Gee.List<Xmpp.Xep.JingleIceUdp.Candidate> candidates =
            new ArrayList<Xmpp.Xep.JingleIceUdp.Candidate>(Xmpp.Xep.JingleIceUdp.Candidate.equals_func);

    public SdpMediaSection(string media, uint16 port = 9, string protocol = "UDP/TLS/RTP/SAVPF") {
        this.media = media;
        this.port = port;
        this.protocol = protocol;
    }
}

public class Xmpp.Xep.JingleRtp.SdpHeaderExtension {
    public uint16 id { get; private set; }
    public string uri { get; private set; }
    public SdpMediaDirection direction { get; private set; default = SdpMediaDirection.SEND_RECV; }
    public Gee.List<HeaderExtensionParameter> parameters = new ArrayList<HeaderExtensionParameter>();

    public SdpHeaderExtension(
            uint16 id,
            string uri,
            SdpMediaDirection direction = SdpMediaDirection.SEND_RECV) {
        this.id = id;
        this.uri = uri;
        this.direction = direction;
    }
}

public class Xmpp.Xep.JingleRtp.SdpSession {
    public string origin_username { get; set; default = "-"; }
    public string origin_session_id { get; set; default = "0"; }
    public string origin_session_version { get; set; default = "0"; }
    public string origin_address { get; set; default = "0.0.0.0"; }
    public string session_name { get; set; default = "-"; }

    public Gee.List<string> bundle_mids = new ArrayList<string>();
    public Gee.List<SdpMediaSection> media_sections = new ArrayList<SdpMediaSection>();
}

public class Xmpp.Xep.JingleRtp.SdpJingleContentNodePair {
    public string content_name { get; private set; }
    public StanzaNode description { get; private set; }
    public StanzaNode transport { get; private set; }

    public SdpJingleContentNodePair(string content_name, StanzaNode description, StanzaNode transport) {
        this.content_name = content_name;
        this.description = description;
        this.transport = transport;
    }
}
