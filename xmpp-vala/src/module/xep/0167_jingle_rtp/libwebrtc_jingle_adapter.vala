using Gee;
using Xmpp;
using Xmpp.Xep;

/**
 * Thin XEP-0167/XEP-0176 adapter for the DinoX Google/libwebrtc C ABI.
 *
 * This class intentionally does not link to the native wrapper. It converts
 * between the data shapes exposed by `dinox_webrtc.h` ABI v3 and DinoX's
 * Jingle RTP model:
 *
 * - local libwebrtc SDP callbacks -> Jingle content descriptions/transports
 * - incoming Jingle content descriptions/transports -> remote SDP
 * - libwebrtc ICE callbacks -> Jingle candidates
 * - Jingle candidates -> libwebrtc remote ICE arguments
 *
 * The production GStreamer RTP call path does not use this adapter.
 */
public class Xmpp.Xep.JingleRtp.LibwebrtcJingleAdapter : Object {

    private ArrayList<string> local_content_names = new ArrayList<string>();
    private ArrayList<string> remote_content_names = new ArrayList<string>();
    private HashMap<string, int> local_mline_by_content_name = new HashMap<string, int>();
    private HashMap<string, int> remote_mline_by_content_name = new HashMap<string, int>();
    private HashMap<string, string> local_ufrag_by_content_name = new HashMap<string, string>();
    private HashMap<string, string> local_pwd_by_content_name = new HashMap<string, string>();
    private HashMap<string, string> configured_content_name_by_media =
        new HashMap<string, string>();
    private HashMap<string, Gee.List<PayloadType>>
        configured_payload_types_by_media =
            new HashMap<string, Gee.List<PayloadType>>();
    private HashMap<string, string> initial_offer_content_name_by_media =
        new HashMap<string, string>();
    private HashMap<string, Gee.List<PayloadType>>
        initial_offer_payload_types_by_media =
            new HashMap<string, Gee.List<PayloadType>>();
    private HashMap<string, string> local_content_name_by_internal_mid =
        new HashMap<string, string>();
    private HashMap<string, string> local_internal_mid_by_content_name =
        new HashMap<string, string>();
    private HashMap<string, string> remote_internal_mid_by_content_name =
        new HashMap<string, string>();
    private bool conference_media_configured = false;

    public bool has_local_content_map { get { return !local_content_names.is_empty; } }
    public bool has_remote_content_map { get { return !remote_content_names.is_empty; } }

    /**
     * Configures external XEP-0272 conference identities while allowing the
     * native PeerConnection to keep its own SDP MIDs. Direct-call adapters are
     * unchanged unless this is called before either content map exists.
     */
    public void configure_conference_media(
            Gee.Map<string, string> content_names_by_media,
            Gee.Map<string, Gee.List<PayloadType>> payload_types_by_media)
            throws Jingle.IqError {
        if (conference_media_configured || has_local_content_map ||
                has_remote_content_map) {
            throw new Jingle.IqError.OUT_OF_ORDER(
                "conference media must be configured before SDP mapping");
        }
        if (!content_names_by_media.has_key("audio") ||
                content_names_by_media.size < 1 ||
                content_names_by_media.size > 2 ||
                payload_types_by_media.size != content_names_by_media.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                "conference audio content and payload map are required");
        }
        var unique_names = new HashSet<string>();
        var validated_names = new HashMap<string, string>();
        var validated_payloads = new HashMap<string,
            Gee.List<PayloadType>>();
        foreach (var entry in content_names_by_media.entries) {
            if ((entry.key != "audio" && entry.key != "video")) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "unsupported conference content media");
            }
            require_content_name(entry.value, "conference content name");
            if (!is_supported_native_conference_mid(entry.value)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "conference content name cannot be represented by a native SDP MID");
            }
            if (unique_names.contains(entry.value)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "duplicate conference content name");
            }
            Gee.List<PayloadType>? media_payloads =
                payload_types_by_media[entry.key];
            if (media_payloads == null || ((!) media_payloads).is_empty) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "conference payload map is missing configured media");
            }
            var payload_copy = new ArrayList<PayloadType>(
                PayloadType.equals_func);
            var media_payload_ids = new HashSet<int>();
            foreach (PayloadType payload_type in (!) media_payloads) {
                if (!payload_type.id_valid || payload_type.id > 127 ||
                        payload_type.name == null ||
                        ((!) payload_type.name).strip() == "" ||
                        media_payload_ids.contains((int) payload_type.id)) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "conference payload IDs must be unique per content");
                }
                media_payload_ids.add((int) payload_type.id);
                payload_copy.add(copy_conference_payload(payload_type));
            }
            unique_names.add(entry.value);
            validated_names[entry.key] = entry.value;
            validated_payloads[entry.key] = payload_copy;
        }
        foreach (string media in payload_types_by_media.keys) {
            if (!validated_names.has_key(media)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "conference payload map contains unconfigured media");
            }
        }
        foreach (var entry in validated_payloads.entries) {
            validate_configured_apt_references(entry.key, entry.value);
            if (!has_supported_conference_timing(entry.value)) {
                throw new Jingle.IqError.BAD_REQUEST("conference media timing cannot be represented natively");
            }
        }
        foreach (var entry in validated_names.entries) {
            configured_content_name_by_media[entry.key] = entry.value;
        }
        foreach (var entry in validated_payloads.entries) {
            configured_payload_types_by_media[entry.key] = entry.value;
        }
        conference_media_configured = true;
    }


    /** Native libwebrtc MID limit, not a restriction on general XEP-0166 names. */
    public static bool is_supported_native_conference_mid(string name) {
        if (name.length == 0 || name.length > 16) return false;
        for (int i = 0; i < name.length; i++) {
            char c = name[i];
            if (c <= 0x20 || c >= 0x7f || "()<>@,;:\\\"/[]?={}".index_of_char(c) >= 0) {
                return false;
            }
        }
        return true;
    }

    /**
     * Projects a prepared, not yet committed native description. Preserve
     * native source, stream, transport and extension lines which SdpBridge does
     * not model. Only the conference codec map, timing, MID and BUNDLE names
     * change. No offer/ICE maps become visible until the native commit succeeds.
     */
    public string prepare_conference_local_description(
            LibwebrtcSdpType type, string sdp) throws Jingle.IqError {
        if (!conference_media_configured || has_local_content_map) {
            throw new Jingle.IqError.OUT_OF_ORDER(
                "conference SDP preparation requires an uncommitted local description");
        }
        SdpSession session = SdpBridge.session_from_sdp(sdp);
        read_conference_timing(session, sdp);
        foreach (SdpMediaSection section in session.media_sections) {
            Gee.List<PayloadType>? configured = configured_payload_types_by_media[section.media];
            if (configured == null) throw new Jingle.IqError.BAD_REQUEST("unexpected prepared conference media");
            uint32 expected_ptime, expected_maxptime;
            conference_media_timing((!) configured, out expected_ptime, out expected_maxptime);
            foreach (PayloadType payload in section.payload_types) {
                if ((payload.ptime != 0 && expected_ptime != 0 && payload.ptime != expected_ptime) ||
                        (payload.maxptime != 0 && expected_maxptime != 0 && payload.maxptime != expected_maxptime) ||
                        (payload.ptime != 0 && expected_maxptime != 0 && payload.ptime > expected_maxptime) ||
                        (payload.maxptime != 0 && expected_ptime != 0 && expected_ptime > payload.maxptime)) {
                    throw new Jingle.IqError.BAD_REQUEST("prepared native timing conflicts with the conference map");
                }
            }
        }
        if (type == LibwebrtcSdpType.OFFER) {
            map_local_offer_payloads_to_conference(session);
        } else {
            normalize_local_answer_payloads_to_conference(session);
        }
        var native_to_conference_mid = new HashMap<string, string>();
        foreach (SdpMediaSection section in session.media_sections) {
            require_adapter_token(section.mid, "prepared native MID");
            native_to_conference_mid[(!) section.mid] =
                configured_content_name_by_media[section.media];
        }
        var result = new StringBuilder();
        int section_index = -1;
        var discarded_sources_by_section = new ArrayList<HashSet<string>>();
        string[] lines = sdp.replace("\r\n", "\n").split("\n");
        foreach (string line in lines) {
            if (line.has_prefix("m=")) discarded_sources_by_section.add(new HashSet<string>());
            if (!line.has_prefix("a=ssrc-group:FID ") || discarded_sources_by_section.is_empty) continue;
            string[] source_ids = line.substring(17).split(" ");
            for (int i = 1; i < source_ids.length; i++) {
                discarded_sources_by_section[discarded_sources_by_section.size - 1].add(source_ids[i]);
            }
        }
        foreach (string line in lines) {
            if (line == "") continue;
            if (line.has_prefix("m=")) {
                if (section_index >= 0) append_projected_payload_lines(
                    result, session.media_sections[section_index]);
                section_index++;
                SdpMediaSection section = session.media_sections[section_index];
                string[] fields = line.split(" ");
                if (fields.length < 4) throw new Jingle.IqError.BAD_REQUEST("invalid native m-line");
                result.append("%s %s %s".printf(fields[0], fields[1], fields[2]));
                foreach (PayloadType payload in section.payload_types) {
                    result.append(" %u".printf(payload.id));
                }
                result.append("\r\n");
                continue;
            }
            if (line.has_prefix("a=group:BUNDLE ")) {
                result.append("a=group:BUNDLE");
                foreach (string mid in line.substring(15).split(" ")) {
                    string? mapped = native_to_conference_mid[mid];
                    if (mapped == null) throw new Jingle.IqError.BAD_REQUEST("unknown native BUNDLE MID");
                    result.append(" %s".printf((!) mapped));
                }
                result.append("\r\n");
                continue;
            }
            if (section_index >= 0) {
                SdpMediaSection section = session.media_sections[section_index];
                bool has_rtx = section.payload_types.any_match((payload) => payload.parameters.has_key("apt"));
                if (line.has_prefix("a=rtpmap:") || line.has_prefix("a=fmtp:") ||
                        line.has_prefix("a=rtcp-fb:") || line.has_prefix("a=ptime:") ||
                        line.has_prefix("a=maxptime:")) continue;
                if (line.has_prefix("a=rtcp-xr:")) {
                    // M152 folds receiver-reference-time signaling into one
                    // media flag and serializes it back as rrtr for every PT.
                    // Derive that flag from the frozen rtcp-fb map emitted
                    // below, not from this unprojected native capability.
                    var formats = new ArrayList<string>();
                    foreach (string format in line.substring(10).split_set(" \t")) {
                        if (format != "" && !format.has_prefix("rcvr-rtt=")) {
                            formats.add(format);
                        }
                    }
                    if (!formats.is_empty) {
                        result.append("a=rtcp-xr:%s\r\n".printf(
                            string.joinv(" ", formats.to_array())));
                    }
                    continue;
                }
                if (line.has_prefix("a=mid:")) {
                    result.append("a=mid:%s\r\n".printf(
                        configured_content_name_by_media[section.media]));
                    continue;
                }
                if (!has_rtx && line.has_prefix("a=ssrc-group:FID ")) {
                    continue;
                }
                if (!has_rtx && line.has_prefix("a=ssrc:")) {
                    string source_id = line.substring(7).split(" ")[0];
                    if (discarded_sources_by_section[section_index].contains(source_id)) continue;
                }
            }
            result.append(line);
            result.append("\r\n");
        }
        if (section_index >= 0) append_projected_payload_lines(result, session.media_sections[section_index]);
        return result.str;
    }

    private static void append_projected_payload_lines(StringBuilder result, SdpMediaSection section)
            throws Jingle.IqError {
        foreach (PayloadType payload in section.payload_types) {
            foreach (string line in SdpBridge.payload_type_to_sdp_attributes(payload)) {
                result.append(line);
                result.append("\r\n");
            }
        }
        append_projected_timing(result, section);
    }

    private static void conference_media_timing(Gee.List<PayloadType> payloads,
            out uint32 ptime, out uint32 maxptime) throws Jingle.IqError {
        ptime = 0;
        maxptime = 0;
        foreach (PayloadType payload in payloads) {
            if ((payload.ptime != 0 && ptime != 0 && payload.ptime != ptime) ||
                    (payload.maxptime != 0 && maxptime != 0 && payload.maxptime != maxptime)) {
                throw new Jingle.IqError.BAD_REQUEST("conference timing conflicts within one native media section");
            }
            if (payload.ptime != 0) ptime = payload.ptime;
            if (payload.maxptime != 0) maxptime = payload.maxptime;
        }
        if (ptime != 0 && maxptime != 0 && ptime > maxptime) {
            throw new Jingle.IqError.BAD_REQUEST("conference ptime exceeds maxptime");
        }
    }

    public static bool has_supported_conference_timing(Gee.List<PayloadType> payloads) {
        try {
            uint32 ptime, maxptime;
            conference_media_timing(payloads, out ptime, out maxptime);
            return true;
        } catch (Jingle.IqError e) {
            return false;
        }
    }

    private static void append_projected_timing(StringBuilder result, SdpMediaSection section)
            throws Jingle.IqError {
        uint32 ptime, maxptime;
        conference_media_timing(section.payload_types, out ptime, out maxptime);
        if (ptime != 0) result.append("a=ptime:%u\r\n".printf(ptime));
        if (maxptime != 0) result.append("a=maxptime:%u\r\n".printf(maxptime));
    }

    private static void read_conference_timing(SdpSession session, string sdp)
            throws Jingle.IqError {
        int media_index = -1;
        var ptime_seen = new HashSet<int>();
        var maxptime_seen = new HashSet<int>();
        foreach (string raw_line in sdp.split("\n")) {
            string line = raw_line.has_suffix("\r") ? raw_line.substring(0, raw_line.length - 1) : raw_line;
            if (line.has_prefix("m=")) media_index++;
            bool maximum = line.has_prefix("a=maxptime:");
            if (!maximum && !line.has_prefix("a=ptime:")) continue;
            if (media_index < 0 || media_index >= session.media_sections.size) {
                throw new Jingle.IqError.BAD_REQUEST("conference timing must be media scoped");
            }
            var seen = maximum ? maxptime_seen : ptime_seen;
            uint value = 0;
            if (seen.contains(media_index) || !uint.try_parse(line.substring(maximum ? 11 : 8), out value) || value == 0) {
                throw new Jingle.IqError.BAD_REQUEST("invalid committed conference timing");
            }
            seen.add(media_index);
            foreach (PayloadType payload in session.media_sections[media_index].payload_types) {
                if (maximum) payload.maxptime = value;
                else payload.ptime = value;
                if (payload.ptime != 0 && payload.maxptime != 0 && payload.ptime > payload.maxptime) {
                    throw new Jingle.IqError.BAD_REQUEST("native ptime exceeds maxptime");
                }
            }
        }
    }

    private void validate_committed_conference_description(SdpSession session, string sdp)
            throws Jingle.IqError {
        read_conference_timing(session, sdp);
        foreach (SdpMediaSection section in session.media_sections) {
            Gee.List<PayloadType>? configured = configured_payload_types_by_media[section.media];
            if (configured == null) throw new Jingle.IqError.BAD_REQUEST("unexpected committed conference media");
            uint32 expected_ptime, expected_maxptime;
            conference_media_timing((!) configured, out expected_ptime, out expected_maxptime);
            foreach (PayloadType actual in section.payload_types) {
                PayloadType? expected = find_payload_by_id((!) configured, actual.id);
                if (expected == null) throw new Jingle.IqError.BAD_REQUEST("unexpected committed conference payload");
                Gee.List<string> expected_lines = conference_non_feedback_attributes((!) expected);
                Gee.List<string> actual_lines = conference_non_feedback_attributes(actual);
                if (expected_lines.size != actual_lines.size ||
                        !actual_lines.contains_all(expected_lines) ||
                        !conference_feedback_sets_equal(((!) expected).rtcp_fbs, actual.rtcp_fbs) ||
                        actual.ptime != expected_ptime || actual.maxptime != expected_maxptime) {
                    throw new Jingle.IqError.BAD_REQUEST("native SDP changed the committed conference codec parameters");
                }
            }
        }
    }

    private static Gee.List<string> conference_non_feedback_attributes(PayloadType payload)
            throws Jingle.IqError {
        var lines = new ArrayList<string>();
        foreach (string line in SdpBridge.payload_type_to_sdp_attributes(payload)) {
            if (!line.has_prefix("a=rtcp-fb:")) lines.add(line);
        }
        return lines;
    }

    private static string add_conference_timing_to_sdp(string sdp, SdpSession session)
            throws Jingle.IqError {
        var result = new StringBuilder();
        int media_index = -1;
        foreach (string line in sdp.replace("\r\n", "\n").split("\n")) {
            if (line == "") continue;
            if (line.has_prefix("m=")) {
                if (media_index >= 0) append_projected_timing(result, session.media_sections[media_index]);
                media_index++;
            }
            if (line.has_prefix("a=ptime:") || line.has_prefix("a=maxptime:")) continue;
            result.append(line);
            result.append("\r\n");
        }
        if (media_index >= 0) append_projected_timing(result, session.media_sections[media_index]);
        return result.str;
    }

    public LibwebrtcJingleDescription local_description_to_jingle(
            LibwebrtcSdpType type,
            string sdp,
            Jingle.Role local_role,
            bool low_bandwidth_audio = false) throws Jingle.IqError {
        SdpSession session = SdpBridge.session_from_sdp(sdp);
        if (low_bandwidth_audio && !conference_media_configured) {
            apply_low_bandwidth_opus_parameters(session);
        }
        if (conference_media_configured) {
            // Only already committed native SDP may reach the Jingle path.
            // Preparation is a separate operation and never publishes maps.
            validate_committed_conference_description(session, sdp);
            normalize_local_answer_payloads_to_conference(session);
            foreach (SdpMediaSection section in session.media_sections) {
                if (section.mid != configured_content_name_by_media[section.media]) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "committed native MID differs from the conference content identity");
                }
            }
        }
        Gee.List<SdpJingleContentNodePair> internal_pairs =
            SdpBridge.jingle_content_node_pairs_from_session(session, local_role);
        Gee.List<SdpJingleContentNodePair> pairs = conference_media_configured
            ? map_local_pairs_to_conference_names(session, internal_pairs)
            : internal_pairs;
        Gee.List<LibwebrtcJingleContent> contents = contents_from_session_pairs(
            session,
            pairs,
            local_role);

        if (type == LibwebrtcSdpType.OFFER) {
            remember_initial_offer_media(session, contents);
        }

        remember_content_names(contents, local_content_names, local_mline_by_content_name);
        remember_local_mid_mapping(session, contents);
        remember_local_ice_credentials(contents);
        return new LibwebrtcJingleDescription(type, sdp, session, contents);
    }

    private static void apply_low_bandwidth_opus_parameters(SdpSession session) throws Jingle.IqError {
        bool opus_found = false;
        foreach (SdpMediaSection section in session.media_sections) {
            if (section.media != "audio") continue;
            foreach (PayloadType payload in section.payload_types) {
                string name = payload.name == null ? "" : ((!) payload.name).strip().ascii_down();
                if (name != "opus" || payload.clockrate != 48000) continue;
                opus_found = true;
                payload.parameters["maxaveragebitrate"] = "16000";
                payload.parameters["maxplaybackrate"] = "16000";
                payload.parameters["sprop-maxcapturerate"] = "16000";
                payload.parameters["stereo"] = "0";
                payload.parameters["sprop-stereo"] = "0";
                payload.parameters["usedtx"] = "1";
                payload.parameters["useinbandfec"] = "1";
            }
        }
        if (!opus_found) {
            throw new Jingle.IqError.BAD_REQUEST("low-bandwidth mode requires Opus at 48000 Hz");
        }
    }

    private void remember_initial_offer_media(
            SdpSession session,
            Gee.List<LibwebrtcJingleContent> contents)
            throws Jingle.IqError {
        if (session.media_sections.size != contents.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                "offer SDP/Jingle content count mismatch");
        }
        var names = new HashMap<string, string>();
        var payloads = new HashMap<string, Gee.List<PayloadType>>();
        for (int i = 0; i < contents.size; i++) {
            string media = session.media_sections[i].media;
            require_adapter_token(media, "RTP media");
            require_content_name(contents[i].content_name,
                "Jingle content name");
            if (names.has_key(media) ||
                    session.media_sections[i].payload_types.is_empty) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "offer contains duplicate or empty conference media");
            }
            names[media] = contents[i].content_name;
            payloads[media] = clone_payload_types(
                session.media_sections[i].payload_types);
        }
        initial_offer_content_name_by_media.clear();
        initial_offer_payload_types_by_media.clear();
        initial_offer_content_name_by_media.set_all(names);
        initial_offer_payload_types_by_media.set_all(payloads);
    }

    private static Gee.List<PayloadType> clone_payload_types(
            Gee.List<PayloadType> source) {
        var copy = new ArrayList<PayloadType>(PayloadType.equals_func);
        foreach (PayloadType payload_type in source) {
            copy.add(payload_type.clone());
        }
        return copy;
    }

    /**
     * Projects an uncommitted native offer to the immutable XEP-0272 map.
     * Native payload IDs are used only to find compatible primary/RTX pairs;
     * the committed PeerConnection must use the conference IDs themselves.
     */
    private void map_local_offer_payloads_to_conference(SdpSession session)
            throws Jingle.IqError {
        var seen_media = new HashSet<string>();
        var local_internal_payload_id_by_external_key = new HashMap<string, int>();
        foreach (SdpMediaSection section in session.media_sections) {
            string media = section.media;
            require_adapter_token(media, "SDP media");
            Gee.List<PayloadType>? configured =
                configured_payload_types_by_media[media];
            if (configured == null || seen_media.contains(media)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "local SDP does not match configured conference media");
            }
            seen_media.add(media);

            var matched_native = new HashMap<int, PayloadType>();
            var used_native_ids = new HashSet<int>();
            foreach (PayloadType external_payload in (!) configured) {
                if (external_payload.parameters.has_key("apt")) continue;
                PayloadType native_payload = select_native_payload(
                    media, external_payload, section.payload_types,
                    used_native_ids, local_internal_payload_id_by_external_key);
                matched_native[(int) external_payload.id] = native_payload;
                used_native_ids.add((int) native_payload.id);
                local_internal_payload_id_by_external_key[
                    payload_key(media, external_payload.id)] =
                        (int) native_payload.id;
            }
            foreach (PayloadType external_payload in (!) configured) {
                if (!external_payload.parameters.has_key("apt")) continue;
                PayloadType native_payload = select_native_payload(
                    media, external_payload, section.payload_types,
                    used_native_ids, local_internal_payload_id_by_external_key);
                matched_native[(int) external_payload.id] = native_payload;
                used_native_ids.add((int) native_payload.id);
                local_internal_payload_id_by_external_key[
                    payload_key(media, external_payload.id)] =
                        (int) native_payload.id;
            }
            if (matched_native.size != ((!) configured).size) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "native SDP cannot represent the conference payload map");
            }
            section.payload_types.clear();
            foreach (PayloadType payload_type in (!) configured) {
                section.payload_types.add(payload_type.clone());
            }
        }
        require_configured_media_coverage(seen_media);
    }

    private PayloadType select_native_payload(
            string media,
            PayloadType external_payload,
            Gee.List<PayloadType> native_payloads,
            HashSet<int> used_native_ids,
            HashMap<string, int> local_internal_payload_id_by_external_key) throws Jingle.IqError {
        var candidates = new ArrayList<PayloadType>();
        var exact_candidates = new ArrayList<PayloadType>();
        int expected_internal_apt = -1;
        string? external_apt = external_payload.parameters["apt"];
        if (external_apt != null) {
            int external_apt_id;
            if (!int.try_parse((!) external_apt, out external_apt_id,
                    null, 10)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "conference payload has an invalid apt reference");
            }
            int? mapped_apt = local_internal_payload_id_by_external_key[
                payload_key_from_int(media, external_apt_id)];
            if (mapped_apt == null) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "conference dependent payload precedes its primary codec");
            }
            expected_internal_apt = (!) mapped_apt;
        }

        foreach (PayloadType native_payload in native_payloads) {
            if (used_native_ids.contains((int) native_payload.id) ||
                    !codec_identity_matches(external_payload,
                        native_payload)) continue;
            string? native_apt = native_payload.parameters["apt"];
            if (external_apt == null) {
                if (native_apt != null) continue;
            } else {
                int native_apt_id = -1;
                if (native_apt == null ||
                        !int.try_parse((!) native_apt, out native_apt_id,
                            null, 10) ||
                        native_apt_id != expected_internal_apt) continue;
            }
            candidates.add(native_payload);
            if (parameter_maps_equal_except_apt(
                    external_payload, native_payload)) {
                exact_candidates.add(native_payload);
            }
        }
        if (exact_candidates.size == 1) return exact_candidates[0];
        if (exact_candidates.size > 1 || candidates.size != 1) {
            throw new Jingle.IqError.BAD_REQUEST(
                "conference codec has no unique native payload mapping");
        }
        return candidates[0];
    }

    /**
     * Reduces a peer's pairwise Jingle payloads to the immutable conference
     * map. Some clients include their complete native WebRTC codec list in a
     * MUJI leg even though their ready presence advertises only the global
     * subset. Undeclared payloads are not negotiated, while an ID that is
     * declared globally must still identify the same codec and dependency.
     */
    private void normalize_remote_payloads_to_conference(SdpSession session)
            throws Jingle.IqError {
        var seen_media = new HashSet<string>();
        foreach (SdpMediaSection section in session.media_sections) {
            string media = section.media;
            Gee.List<PayloadType>? configured =
                configured_payload_types_by_media[media];
            if (configured == null || seen_media.contains(media) ||
                    section.payload_types.is_empty) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "Jingle payloads do not match configured conference media");
            }
            seen_media.add(media);
            var seen_payload_ids = new HashSet<int>();
            var accepted_payload_ids = new HashSet<int>();
            foreach (PayloadType payload_type in section.payload_types) {
                if (!payload_type.id_valid || payload_type.id > 127) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "conference payload ID is missing, malformed, or out of range");
                }
                if (seen_payload_ids.contains((int) payload_type.id)) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "conference payload ID is duplicated");
                }
                seen_payload_ids.add((int) payload_type.id);
                PayloadType? expected = find_payload_by_id(
                    (!) configured, payload_type.id);
                if (expected == null) continue;
                if (!conference_payload_mapping_equal(
                        (!) expected, payload_type)) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "Jingle payload changed the conference mapping");
                }
                accepted_payload_ids.add((int) payload_type.id);
            }

            var normalized = new ArrayList<PayloadType>(
                PayloadType.equals_func);
            bool has_primary_payload = false;
            foreach (PayloadType expected in (!) configured) {
                if (!accepted_payload_ids.contains((int) expected.id)) {
                    continue;
                }
                string? apt = expected.parameters["apt"];
                if (apt != null) {
                    int apt_id = -1;
                    if (!int.try_parse((!) apt, out apt_id, null, 10) ||
                            !accepted_payload_ids.contains(apt_id)) {
                        continue;
                    }
                } else {
                    has_primary_payload = true;
                }
                normalized.add(expected.clone());
            }
            if (!has_primary_payload || normalized.is_empty) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "Jingle payloads have no configured conference codec");
            }
            section.payload_types.clear();
            section.payload_types.add_all(normalized);
        }
        require_configured_media_coverage(seen_media);
    }

    private void normalize_local_answer_payloads_to_conference(
            SdpSession session) throws Jingle.IqError {
        var seen_media = new HashSet<string>();
        foreach (SdpMediaSection section in session.media_sections) {
            string media = section.media;
            Gee.List<PayloadType>? configured =
                configured_payload_types_by_media[media];
            if (configured == null || seen_media.contains(media) ||
                    section.payload_types.is_empty) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "local answer does not match configured conference media");
            }
            seen_media.add(media);
            var seen_payload_ids = new HashSet<int>();
            var normalized = new ArrayList<PayloadType>(
                PayloadType.equals_func);
            foreach (PayloadType native_payload in section.payload_types) {
                if (seen_payload_ids.contains((int) native_payload.id)) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "local conference answer duplicated a payload ID");
                }
                seen_payload_ids.add((int) native_payload.id);
                PayloadType? expected = find_payload_by_id(
                    (!) configured, native_payload.id);
                if (expected == null ||
                        !codec_identity_matches((!) expected,
                            native_payload) ||
                        !apt_targets_equal((!) expected, native_payload)) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "local answer changed the conference codec mapping");
                }
                normalized.add(((!) expected).clone());
            }
            bool has_primary_payload = false;
            foreach (PayloadType payload_type in normalized) {
                string? apt = payload_type.parameters["apt"];
                if (apt == null) {
                    has_primary_payload = true;
                    continue;
                }
                int apt_id = -1;
                if (!int.try_parse((!) apt, out apt_id, null, 10) ||
                        !seen_payload_ids.contains(apt_id)) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "local conference answer has RTX without its primary codec");
                }
            }
            if (!has_primary_payload) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "local conference answer has no primary codec");
            }
            section.payload_types.clear();
            section.payload_types.add_all(normalized);
        }
        require_configured_media_coverage(seen_media);
    }

    private static void validate_configured_apt_references(
            string media, Gee.List<PayloadType> payloads)
            throws Jingle.IqError {
        var ids = new HashSet<int>();
        var payloads_by_id = new HashMap<int, PayloadType>();
        foreach (PayloadType payload_type in payloads) {
            ids.add((int) payload_type.id);
            payloads_by_id[(int) payload_type.id] = payload_type;
        }
        foreach (PayloadType payload_type in payloads) {
            string? apt = payload_type.parameters["apt"];
            bool rtx = payload_type.name != null &&
                ((!) payload_type.name).strip().ascii_down() == "rtx";
            if (!rtx) {
                if (apt != null) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        @"non-RTX conference payload has apt for $(media)");
                }
                continue;
            }
            int apt_id = -1;
            if (apt == null ||
                    !int.try_parse((!) apt, out apt_id, null, 10) ||
                    !ids.contains(apt_id) ||
                    apt_id == (int) payload_type.id ||
                    (payloads_by_id[apt_id].name != null &&
                        ((!) payloads_by_id[apt_id].name).strip().ascii_down() ==
                            "rtx")) {
                throw new Jingle.IqError.BAD_REQUEST(
                    @"invalid conference apt reference for $(media)");
            }
        }
    }

    private static PayloadType? find_payload_by_id(
            Gee.List<PayloadType> payloads, uint8 id) {
        foreach (PayloadType payload_type in payloads) {
            if (payload_type.id == id) return payload_type;
        }
        return null;
    }

    private static bool codec_identity_matches(
            PayloadType left, PayloadType right) {
        if (left.name == null || right.name == null) return false;
        return ((!) left.name).strip().ascii_down() ==
                ((!) right.name).strip().ascii_down() &&
            left.clockrate == right.clockrate &&
            left.channels == right.channels;
    }

    private static bool conference_payload_mapping_equal(
            PayloadType expected, PayloadType received) {
        if (!expected.id_valid || !received.id_valid ||
                expected.id != received.id ||
                !codec_identity_matches(expected, received) ||
                expected.maxptime != received.maxptime ||
                expected.ptime != received.ptime ||
                expected.parameters.size != received.parameters.size) {
            return false;
        }
        foreach (var entry in expected.parameters.entries) {
            if (!received.parameters.has_key(entry.key) ||
                    received.parameters[entry.key] != entry.value) {
                return false;
            }
        }

        return conference_feedback_sets_equal(expected.rtcp_fbs, received.rtcp_fbs);
    }

    private static bool conference_feedback_sets_equal(
            Gee.List<RtcpFeedback> expected, Gee.List<RtcpFeedback> received) {
        var expected_feedback = new HashSet<string>();
        var received_feedback = new HashSet<string>();
        foreach (RtcpFeedback feedback in expected) {
            string? key = rtcp_feedback_key(feedback);
            if (key == null) return false;
            expected_feedback.add((!) key);
        }
        foreach (RtcpFeedback feedback in received) {
            string? key = rtcp_feedback_key(feedback);
            if (key == null) return false;
            received_feedback.add((!) key);
        }
        return expected_feedback.size == received_feedback.size &&
            received_feedback.contains_all(expected_feedback);
    }

    private static string? rtcp_feedback_key(RtcpFeedback feedback) {
        string? type = feedback.type_;
        string? raw_subtype = feedback.subtype;
        if (type == null || type == "" || ((!) type).contains("\r") ||
                ((!) type).contains("\n") ||
                (raw_subtype != null &&
                    (((!) raw_subtype) == "" ||
                        ((!) raw_subtype).contains("\r") ||
                        ((!) raw_subtype).contains("\n")))) {
            return null;
        }
        string subtype = raw_subtype ?? "";
        if (type == RtcpFeedback.TRR_INT_TYPE) {
            if (subtype == "") return null;
            for (int i = 0; i < subtype.length; i++) {
                char digit = subtype[i];
                if (digit < '0' || digit > '9') return null;
            }
            uint64 interval = 0;
            if (!uint64.try_parse(subtype, out interval, null, 10) || interval > uint32.MAX) return null;
            // Compare interval values without changing the immutable feedback
            // objects shared by PayloadType.clone() and the ready-presence map.
            subtype = interval.to_string();
        }
        return "%u:%s%u:%s".printf(
            ((!) type).length, (!) type,
            subtype.length, subtype);
    }

    private static PayloadType copy_conference_payload(PayloadType source) throws Jingle.IqError {
        var copy = source.clone();
        copy.rtcp_fbs.clear();
        var keys = new HashSet<string>();
        string? interval_key = null;
        foreach (RtcpFeedback feedback in source.rtcp_fbs) {
            string? key = rtcp_feedback_key(feedback);
            if (key == null) throw new Jingle.IqError.BAD_REQUEST("invalid conference RTCP feedback");
            if (feedback.type_ == RtcpFeedback.TRR_INT_TYPE) {
                if (interval_key != null && interval_key != key) {
                    throw new Jingle.IqError.BAD_REQUEST("conflicting conference RTCP intervals");
                }
                interval_key = key;
            }
            if (keys.add((!) key)) copy.rtcp_fbs.add(feedback);
        }
        return copy;
    }

    private static bool parameter_maps_equal_except_apt(
            PayloadType left, PayloadType right) {
        int left_size = left.parameters.size -
            (left.parameters.has_key("apt") ? 1 : 0);
        int right_size = right.parameters.size -
            (right.parameters.has_key("apt") ? 1 : 0);
        if (left_size != right_size) return false;
        foreach (var entry in left.parameters.entries) {
            if (entry.key == "apt") continue;
            if (!right.parameters.has_key(entry.key) ||
                    right.parameters[entry.key] != entry.value) return false;
        }
        return true;
    }

    private static bool apt_targets_equal(
            PayloadType left, PayloadType right) {
        string? left_apt = left.parameters["apt"];
        string? right_apt = right.parameters["apt"];
        if (left_apt == null || right_apt == null) {
            return left_apt == null && right_apt == null;
        }
        int left_id = -1;
        int right_id = -1;
        return int.try_parse((!) left_apt, out left_id, null, 10) &&
            int.try_parse((!) right_apt, out right_id, null, 10) &&
            left_id == right_id;
    }

    private static string payload_key(string media, uint8 id) {
        return payload_key_from_int(media, (int) id);
    }

    private static string payload_key_from_int(string media, int id) {
        return "%s:%d".printf(media, id);
    }

    public LibwebrtcJingleDescription remote_description_from_jingle_contents(
            LibwebrtcSdpType type,
            Gee.List<LibwebrtcJingleContent> contents,
            Jingle.Role local_role,
            SdpBundlePolicy bundle_policy = SdpBundlePolicy.NONE) throws Jingle.IqError {
        Gee.List<LibwebrtcJingleContent> ordered_contents =
            order_and_validate_remote_contents(contents, local_role, type);
        Gee.List<SdpJingleContentNodePair> pairs =
            content_pairs_from_contents(ordered_contents);
        SdpSession session = SdpBridge.session_from_jingle_content_node_pairs(
            pairs,
            opposite_role(local_role));
        apply_remote_directions(session, ordered_contents, local_role);
        if (conference_media_configured) {
            normalize_remote_payloads_to_conference(session);
            // Native MIDs and payload IDs are the frozen conference identities.
            // Translating either back to generated defaults breaks actual RTP.
        }
        if (type == LibwebrtcSdpType.OFFER) {
            remember_initial_offer_media(session, ordered_contents);
        }
        SdpBridge.apply_bundle_policy(session, bundle_policy);

        string sdp = session_to_native_sdp(session);
        SdpSession sdp_session = SdpBridge.session_from_sdp(sdp);
        if (conference_media_configured) read_conference_timing(sdp_session, sdp);
        remember_content_names(ordered_contents,
            remote_content_names, remote_mline_by_content_name);
        remember_remote_mid_mapping(sdp_session, ordered_contents);
        return new LibwebrtcJingleDescription(
            type, sdp, sdp_session, ordered_contents);
    }

    /** Keep media-level MUJI timing when a caller adjusts native BUNDLE policy. */
    public string session_to_native_sdp(SdpSession session) throws Jingle.IqError {
        string sdp = SdpBridge.session_to_sdp(session);
        return conference_media_configured ? add_conference_timing_to_sdp(sdp, session) : sdp;
    }

    /** Deep copy of the current Jingle offer mapping for safe MUJI adoption. */
    public bool copy_initial_offer_conference_media(
            out HashMap<string, string> content_names_by_media,
            out HashMap<string, Gee.List<PayloadType>> payload_types_by_media) {
        content_names_by_media = new HashMap<string, string>();
        payload_types_by_media = new HashMap<string,
            Gee.List<PayloadType>>();
        if (!initial_offer_content_name_by_media.has_key("audio") ||
                initial_offer_payload_types_by_media["audio"] == null) {
            return false;
        }
        foreach (var entry in initial_offer_content_name_by_media.entries) {
            content_names_by_media[entry.key] = entry.value;
        }
        foreach (var entry in initial_offer_payload_types_by_media.entries) {
            payload_types_by_media[entry.key] =
                clone_payload_types(entry.value);
        }
        return true;
    }

    public LibwebrtcJingleDescription remote_description_from_jingle_content_pairs(
            LibwebrtcSdpType type,
            Gee.List<SdpJingleContentNodePair> pairs,
            Jingle.Role local_role,
            SdpBundlePolicy bundle_policy = SdpBundlePolicy.NONE) throws Jingle.IqError {
        var contents = new ArrayList<LibwebrtcJingleContent>();
        foreach (SdpJingleContentNodePair pair in pairs) {
            contents.add(new LibwebrtcJingleContent(
                pair.content_name,
                Jingle.Senders.BOTH,
                pair.description,
                pair.transport));
        }
        return remote_description_from_jingle_contents(type, contents, local_role, bundle_policy);
    }

    public LibwebrtcJingleIceCandidate local_ice_candidate_to_jingle(
            string? sdp_mid,
            int sdp_mline_index,
            string candidate) throws Jingle.IqError {
        string content_name = resolve_local_content_name(
            sdp_mid, sdp_mline_index, "local ICE candidate");
        string? ufrag = local_ufrag_by_content_name[content_name];
        string? pwd = local_pwd_by_content_name[content_name];
        if (ufrag == null || pwd == null) {
            throw new Jingle.IqError.OUT_OF_ORDER("local ICE candidate arrived before local ICE credentials were known");
        }
        string normalized_candidate = normalize_webrtc_candidate(candidate);
        Xmpp.Xep.JingleIceUdp.Candidate jingle_candidate =
            SdpBridge.candidate_from_sdp(@"a=$(normalized_candidate)");
        return new LibwebrtcJingleIceCandidate(
            content_name,
            sdp_mid ?? local_internal_mid_by_content_name[content_name] ??
                content_name,
            sdp_mline_index,
            normalized_candidate,
            (!) ufrag,
            (!) pwd,
            jingle_candidate);
    }

    public LibwebrtcRemoteIceCandidate remote_jingle_candidate_to_webrtc(
            string content_name,
            Xmpp.Xep.JingleIceUdp.Candidate candidate) throws Jingle.IqError {
        require_content_name(content_name, "Jingle content name");
        if (!remote_mline_by_content_name.has_key(content_name)) {
            throw new Jingle.IqError.OUT_OF_ORDER("remote Jingle content map is not ready for ICE candidate");
        }

        int sdp_mline_index = remote_mline_by_content_name[content_name];
        string? internal_mid =
            remote_internal_mid_by_content_name[content_name];
        if (internal_mid == null) {
            throw new Jingle.IqError.OUT_OF_ORDER(
                "remote internal SDP MID map is not ready for ICE candidate");
        }
        string candidate_line = SdpBridge.candidate_to_sdp(candidate);
        string normalized_candidate = normalize_webrtc_candidate(candidate_line);
        return new LibwebrtcRemoteIceCandidate(
            content_name,
            (!) internal_mid,
            sdp_mline_index,
            normalized_candidate);
    }

    private Gee.List<SdpJingleContentNodePair>
            map_local_pairs_to_conference_names(
                SdpSession session,
                Gee.List<SdpJingleContentNodePair> internal_pairs)
                throws Jingle.IqError {
        if (session.media_sections.size != internal_pairs.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                "local SDP/Jingle content count mismatch");
        }
        var mapped = new ArrayList<SdpJingleContentNodePair>();
        var seen_media = new HashSet<string>();
        for (int i = 0; i < internal_pairs.size; i++) {
            string media = session.media_sections[i].media;
            require_adapter_token(media, "SDP media");
            string? external_name = configured_content_name_by_media[media];
            if (external_name == null || seen_media.contains(media)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "local SDP does not match configured conference media");
            }
            seen_media.add(media);
            mapped.add(new SdpJingleContentNodePair(
                (!) external_name,
                internal_pairs[i].description,
                internal_pairs[i].transport));
        }
        require_configured_media_coverage(seen_media);
        return mapped;
    }

    private Gee.List<LibwebrtcJingleContent>
            order_and_validate_remote_contents(
                Gee.List<LibwebrtcJingleContent> contents,
                Jingle.Role local_role,
                LibwebrtcSdpType type) throws Jingle.IqError {
        if (!conference_media_configured) {
            if (type != LibwebrtcSdpType.ANSWER) return contents;
            if (!has_local_content_map) {
                throw new Jingle.IqError.OUT_OF_ORDER(
                    "remote answer arrived before the local offer map");
            }
            if (contents.size != local_content_names.size) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "remote answer must preserve the offered content set");
            }
            var ordered_answer = new ArrayList<LibwebrtcJingleContent>();
            var seen_answer_names = new HashSet<string>();
            foreach (LibwebrtcJingleContent content in contents) {
                string? media = content.description.get_attribute("media");
                if (!local_mline_by_content_name.has_key(content.content_name) ||
                        seen_answer_names.contains(content.content_name) || media == null ||
                        initial_offer_content_name_by_media[(!) media] != content.content_name) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "remote answer changed an offered content identity");
                }
                seen_answer_names.add(content.content_name);
                ordered_answer.add(content);
            }
            // Jingle identifies contents by name, independently of XML order.
            // RFC 3264 section 6 requires the answer's SDP m-lines in offer order.
            ordered_answer.sort((left, right) =>
                local_mline_by_content_name[left.content_name] -
                local_mline_by_content_name[right.content_name]);
            return ordered_answer;
        }

        var ordered = new ArrayList<LibwebrtcJingleContent>();
        var seen_media = new HashSet<string>();
        var seen_names = new HashSet<string>();
        foreach (LibwebrtcJingleContent content in contents) {
            require_content_name(content.content_name,
                "Jingle content name");
            string? media = content.description.get_attribute("media");
            require_adapter_token(media, "RTP media");
            string? configured_name =
                configured_content_name_by_media[(!) media];
            if (configured_name == null ||
                    (!) configured_name != content.content_name ||
                    seen_media.contains((!) media) ||
                    seen_names.contains(content.content_name)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "remote Jingle content does not match the conference identity");
            }
            seen_media.add((!) media);
            seen_names.add(content.content_name);
            ordered.add(content);
        }
        require_configured_media_coverage(seen_media);

        if (local_role == Jingle.Role.INITIATOR) {
            if (!has_local_content_map) {
                throw new Jingle.IqError.OUT_OF_ORDER(
                    "remote answer arrived before the local conference offer map");
            }
            foreach (LibwebrtcJingleContent content in ordered) {
                if (!local_mline_by_content_name.has_key(content.content_name)) {
                    throw new Jingle.IqError.BAD_REQUEST(
                        "remote answer contains an unknown conference content");
                }
            }
            ordered.sort((left, right) =>
                local_mline_by_content_name[left.content_name] -
                local_mline_by_content_name[right.content_name]);
        }
        return ordered;
    }

    private void require_configured_media_coverage(HashSet<string> seen_media)
            throws Jingle.IqError {
        if (seen_media.size != configured_content_name_by_media.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                "conference SDP is missing configured media");
        }
        foreach (string media in configured_content_name_by_media.keys) {
            if (!seen_media.contains(media)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "conference SDP is missing configured media");
            }
        }
    }

    private void remember_local_mid_mapping(
            SdpSession session,
            Gee.List<LibwebrtcJingleContent> contents) throws Jingle.IqError {
        if (session.media_sections.size != contents.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                "local SDP/Jingle content count mismatch");
        }
        local_content_name_by_internal_mid.clear();
        local_internal_mid_by_content_name.clear();
        for (int i = 0; i < contents.size; i++) {
            string content_name = contents[i].content_name;
            string internal_mid = session.media_sections[i].mid ??
                session.media_sections[i].media;
            require_adapter_token(internal_mid, "internal SDP MID");
            if (local_content_name_by_internal_mid.has_key(internal_mid) ||
                    local_internal_mid_by_content_name.has_key(content_name)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "duplicate local SDP/content mapping");
            }
            string? remote_internal_mid =
                remote_internal_mid_by_content_name[content_name];
            if (remote_internal_mid != null &&
                    (!) remote_internal_mid != internal_mid) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "local answer changed the remote offer MID");
            }
            local_content_name_by_internal_mid[internal_mid] = content_name;
            local_internal_mid_by_content_name[content_name] = internal_mid;
        }
    }

    private void remember_remote_mid_mapping(
            SdpSession session,
            Gee.List<LibwebrtcJingleContent> contents) throws Jingle.IqError {
        if (session.media_sections.size != contents.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                "remote SDP/Jingle content count mismatch");
        }
        remote_internal_mid_by_content_name.clear();
        for (int i = 0; i < contents.size; i++) {
            string? internal_mid = session.media_sections[i].mid;
            require_adapter_token(internal_mid, "internal SDP MID");
            string content_name = contents[i].content_name;
            if (remote_internal_mid_by_content_name.has_key(content_name)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "duplicate remote SDP/content mapping");
            }
            remote_internal_mid_by_content_name[content_name] =
                (!) internal_mid;
        }
    }

    private string resolve_local_content_name(
            string? sdp_mid,
            int sdp_mline_index,
            string field) throws Jingle.IqError {
        if (local_content_names.is_empty) {
            throw new Jingle.IqError.OUT_OF_ORDER(
                @"$(field) arrived before a content map was known");
        }
        if (sdp_mid != null && sdp_mid != "") {
            require_adapter_token((!) sdp_mid, "SDP MID");
            string? content_name =
                local_content_name_by_internal_mid[(!) sdp_mid];
            if (content_name == null) {
                throw new Jingle.IqError.BAD_REQUEST(
                    @"unknown SDP MID in $(field)");
            }
            return (!) content_name;
        }
        if (sdp_mline_index < 0 ||
                sdp_mline_index >= local_content_names.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                @"invalid SDP m-line index in $(field)");
        }
        return local_content_names[sdp_mline_index];
    }

    private static Gee.List<SdpJingleContentNodePair> content_pairs_from_contents(
            Gee.List<LibwebrtcJingleContent> contents) throws Jingle.IqError {
        var pairs = new ArrayList<SdpJingleContentNodePair>();
        foreach (LibwebrtcJingleContent content in contents) {
            require_content_name(content.content_name, "Jingle content name");
            pairs.add(content.to_content_pair());
        }
        return pairs;
    }

    private static Gee.List<LibwebrtcJingleContent> contents_from_session_pairs(
            SdpSession session,
            Gee.List<SdpJingleContentNodePair> pairs,
            Jingle.Role local_role) throws Jingle.IqError {
        if (session.media_sections.size != pairs.size) {
            throw new Jingle.IqError.BAD_REQUEST("SDP/Jingle content count mismatch");
        }

        var contents = new ArrayList<LibwebrtcJingleContent>();
        for (int i = 0; i < pairs.size; i++) {
            SdpMediaDirection direction = session.media_sections[i].direction ?? SdpMediaDirection.SEND_RECV;
            contents.add(new LibwebrtcJingleContent(
                pairs[i].content_name,
                senders_from_local_direction(direction, local_role),
                pairs[i].description,
                pairs[i].transport));
        }
        return contents;
    }

    private static void apply_remote_directions(
            SdpSession session,
            Gee.List<LibwebrtcJingleContent> contents,
            Jingle.Role local_role) throws Jingle.IqError {
        if (session.media_sections.size != contents.size) {
            throw new Jingle.IqError.BAD_REQUEST("Jingle content/media count mismatch");
        }

        for (int i = 0; i < contents.size; i++) {
            session.media_sections[i].direction =
                remote_direction_from_senders(contents[i].senders, local_role);
        }
    }

    private static Jingle.Senders senders_from_local_direction(
            SdpMediaDirection direction,
            Jingle.Role local_role) {
        switch (direction) {
            case SdpMediaDirection.SEND_RECV:
                return Jingle.Senders.BOTH;
            case SdpMediaDirection.INACTIVE:
                return Jingle.Senders.NONE;
            case SdpMediaDirection.SEND_ONLY:
                return senders_for_role(local_role);
            case SdpMediaDirection.RECV_ONLY:
                return senders_for_role(opposite_role(local_role));
            default:
                assert_not_reached();
        }
    }

    private static SdpMediaDirection remote_direction_from_senders(
            Jingle.Senders senders,
            Jingle.Role local_role) {
        switch (senders) {
            case Jingle.Senders.BOTH:
                return SdpMediaDirection.SEND_RECV;
            case Jingle.Senders.NONE:
                return SdpMediaDirection.INACTIVE;
            case Jingle.Senders.INITIATOR:
                return local_role == Jingle.Role.INITIATOR
                    ? SdpMediaDirection.RECV_ONLY
                    : SdpMediaDirection.SEND_ONLY;
            case Jingle.Senders.RESPONDER:
                return local_role == Jingle.Role.RESPONDER
                    ? SdpMediaDirection.RECV_ONLY
                    : SdpMediaDirection.SEND_ONLY;
            default:
                assert_not_reached();
        }
    }

    private static Jingle.Senders senders_for_role(Jingle.Role role) {
        switch (role) {
            case Jingle.Role.INITIATOR:
                return Jingle.Senders.INITIATOR;
            case Jingle.Role.RESPONDER:
                return Jingle.Senders.RESPONDER;
            default:
                assert_not_reached();
        }
    }

    private static Jingle.Role opposite_role(Jingle.Role role) {
        switch (role) {
            case Jingle.Role.INITIATOR:
                return Jingle.Role.RESPONDER;
            case Jingle.Role.RESPONDER:
                return Jingle.Role.INITIATOR;
            default:
                assert_not_reached();
        }
    }

    private static void remember_content_names(
            Gee.List<LibwebrtcJingleContent> contents,
            ArrayList<string> names,
            HashMap<string, int> indexes) throws Jingle.IqError {
        names.clear();
        indexes.clear();

        for (int i = 0; i < contents.size; i++) {
            string content_name = contents[i].content_name;
            require_content_name(content_name, "Jingle content name");
            if (indexes.has_key(content_name)) {
                throw new Jingle.IqError.BAD_REQUEST("duplicate Jingle content name");
            }
            names.add(content_name);
            indexes[content_name] = i;
        }
    }

    private void remember_local_ice_credentials(Gee.List<LibwebrtcJingleContent> contents) throws Jingle.IqError {
        local_ufrag_by_content_name.clear();
        local_pwd_by_content_name.clear();

        foreach (LibwebrtcJingleContent content in contents) {
            require_content_name(content.content_name, "Jingle content name");
            string? ufrag = content.transport.get_attribute("ufrag");
            string? pwd = content.transport.get_attribute("pwd");
            require_adapter_token(ufrag, "ICE ufrag");
            require_adapter_token(pwd, "ICE pwd");
            local_ufrag_by_content_name[content.content_name] = (!) ufrag;
            local_pwd_by_content_name[content.content_name] = (!) pwd;
        }
    }

    private static string normalize_webrtc_candidate(string candidate) throws Jingle.IqError {
        string normalized = candidate.strip();
        require_adapter_text(normalized, "ICE candidate");
        if (normalized.has_prefix("a=candidate:")) {
            return normalized.substring(2);
        }
        if (normalized.has_prefix("candidate:")) {
            return normalized;
        }
        throw new Jingle.IqError.BAD_REQUEST("ICE candidate must use SDP candidate syntax");
    }

    private static void require_adapter_token(string? value, string field) throws Jingle.IqError {
        require_adapter_text(value, field);
        if (((!) value).contains(" ") || ((!) value).contains("\t")) {
            throw new Jingle.IqError.BAD_REQUEST(@"illegal whitespace in $(field)");
        }
    }

    /** XEP-0166 content@name is xs:string, not an SDP token. */
    private static void require_content_name(string? value, string field)
            throws Jingle.IqError {
        if (value == null || ((!) value).length == 0) {
            throw new Jingle.IqError.BAD_REQUEST(@"missing $(field)");
        }
    }

    private static void require_adapter_text(string? value, string field) throws Jingle.IqError {
        if (value == null || value == "") {
            throw new Jingle.IqError.BAD_REQUEST(@"missing $(field)");
        }
        if (((!) value).contains("\r") || ((!) value).contains("\n")) {
            throw new Jingle.IqError.BAD_REQUEST(@"illegal newline in $(field)");
        }
    }
}

public enum Xmpp.Xep.JingleRtp.LibwebrtcSdpType {
    OFFER,
    ANSWER;

    public string to_c_abi_name() {
        switch (this) {
            case OFFER:
                return "DINOX_WEBRTC_SDP_TYPE_OFFER";
            case ANSWER:
                return "DINOX_WEBRTC_SDP_TYPE_ANSWER";
            default:
                assert_not_reached();
        }
    }

    public string to_jingle_action_name() {
        switch (this) {
            case OFFER:
                return "session-initiate";
            case ANSWER:
                return "session-accept";
            default:
                assert_not_reached();
        }
    }
}

public class Xmpp.Xep.JingleRtp.LibwebrtcJingleDescription : Object {
    public LibwebrtcSdpType sdp_type { get; private set; }
    public string sdp { get; private set; }
    public SdpSession session { get; private set; }
    public Gee.List<LibwebrtcJingleContent> contents { get; private set; }

    public LibwebrtcJingleDescription(
            LibwebrtcSdpType type,
            string sdp,
            SdpSession session,
            Gee.List<LibwebrtcJingleContent> contents) {
        this.sdp_type = type;
        this.sdp = sdp;
        this.session = session;
        this.contents = contents;
    }

    public Gee.List<SdpJingleContentNodePair> to_content_pairs() {
        var pairs = new ArrayList<SdpJingleContentNodePair>();
        foreach (LibwebrtcJingleContent content in contents) {
            pairs.add(content.to_content_pair());
        }
        return pairs;
    }
}

public class Xmpp.Xep.JingleRtp.LibwebrtcJingleContent : Object {
    public string content_name { get; private set; }
    public Jingle.Senders senders { get; private set; }
    public StanzaNode description { get; private set; }
    public StanzaNode transport { get; private set; }

    public LibwebrtcJingleContent(
            string content_name,
            Jingle.Senders senders,
            StanzaNode description,
            StanzaNode transport) {
        this.content_name = content_name;
        this.senders = senders;
        this.description = description;
        this.transport = transport;
    }

    public SdpJingleContentNodePair to_content_pair() {
        return new SdpJingleContentNodePair(content_name, description, transport);
    }
}

public class Xmpp.Xep.JingleRtp.LibwebrtcJingleIceCandidate : Object {
    public string content_name { get; private set; }
    public string sdp_mid { get; private set; }
    public int sdp_mline_index { get; private set; }
    public string candidate { get; private set; }
    public string ice_ufrag { get; private set; }
    public string ice_pwd { get; private set; }
    public Xmpp.Xep.JingleIceUdp.Candidate jingle_candidate { get; private set; }

    public LibwebrtcJingleIceCandidate(
            string content_name,
            string sdp_mid,
            int sdp_mline_index,
            string candidate,
            string ice_ufrag,
            string ice_pwd,
            Xmpp.Xep.JingleIceUdp.Candidate jingle_candidate) {
        this.content_name = content_name;
        this.sdp_mid = sdp_mid;
        this.sdp_mline_index = sdp_mline_index;
        this.candidate = candidate;
        this.ice_ufrag = ice_ufrag;
        this.ice_pwd = ice_pwd;
        this.jingle_candidate = jingle_candidate;
    }
}

public class Xmpp.Xep.JingleRtp.LibwebrtcRemoteIceCandidate : Object {
    public string content_name { get; private set; }
    public string sdp_mid { get; private set; }
    public int sdp_mline_index { get; private set; }
    public string candidate { get; private set; }

    public LibwebrtcRemoteIceCandidate(
            string content_name,
            string sdp_mid,
            int sdp_mline_index,
            string candidate) {
        this.content_name = content_name;
        this.sdp_mid = sdp_mid;
        this.sdp_mline_index = sdp_mline_index;
        this.candidate = candidate;
    }
}
