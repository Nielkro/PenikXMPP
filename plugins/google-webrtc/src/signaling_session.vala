using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

internal const string JINGLE_GROUPING_NS =
    "urn:xmpp:jingle:apps:grouping:0";
internal const string JINGLE_GROUPING_DISCO_FEATURE = "urn:ietf:rfc:5888";
internal const string MUJI_BUNDLE_DISCO_FEATURE = "urn:dinox:muji:bundle:0";

internal class JingleSignalingDescription : Object {
    public Gee.List<JingleRtp.LibwebrtcJingleContent> contents {
        get; private set;
    }
    public Gee.List<string>? bundle_content_names { get; private set; }

    public JingleSignalingDescription(
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents,
            Gee.List<string>? bundle_content_names) {
        this.contents = contents;
        this.bundle_content_names = bundle_content_names;
    }
}

public errordomain SignalingError {
    BAD_STATE,
    BAD_STANZA,
    ENDED
}

public enum SignalingState {
    NEW,
    LOCAL_OFFER_SENT,
    REMOTE_OFFER_RECEIVED,
    REMOTE_OFFER_SET,
    REMOTE_ANSWER_RECEIVED,
    ACTIVE,
    ENDED
}

/**
 * Development-only Jingle signaling shell for the Google/libwebrtc engine.
 *
 * It owns only the XEP-0166/0167/0176 payload shape and ordering rules needed
 * by the libwebrtc engine. It intentionally does not touch XmppStream,
 * Jingle.Module, VideoCallPlugin or the production GStreamer RTP runtime.
 */
public class JingleSignalingSession : Object {
    public string sid { get; private set; }
    public Jid local_full_jid { get; private set; }
    public Jid peer_full_jid { get; private set; }
    public Jid? muji_room_jid { get; private set; }
    public Jingle.Role local_role { get; private set; }
    public SignalingState state { get; private set; default = SignalingState.NEW; }

    private ArrayList<JingleRtp.LibwebrtcJingleIceCandidate> queued_local_ice =
        new ArrayList<JingleRtp.LibwebrtcJingleIceCandidate>();
    private Gee.List<string>? local_offer_bundle_content_names = null;
    private Gee.List<string>? remote_offer_bundle_content_names = null;

    private JingleSignalingSession(
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jingle.Role local_role,
            Jid? muji_room_jid) {
        this.sid = sid;
        this.local_full_jid = local_full_jid;
        this.peer_full_jid = peer_full_jid;
        this.local_role = local_role;
        this.muji_room_jid = muji_room_jid;
    }

    public static JingleSignalingSession outgoing(
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid) throws SignalingError {
        require_token(sid, "Jingle SID");
        return new JingleSignalingSession(
            sid, local_full_jid, peer_full_jid, Jingle.Role.INITIATOR, null);
    }

    internal static JingleSignalingSession muji_outgoing(
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        require_token(sid, "Jingle SID");
        validate_muji_room_jid(muji_room_jid);
        return new JingleSignalingSession(
            sid, local_full_jid, peer_full_jid, Jingle.Role.INITIATOR,
            muji_room_jid);
    }

    public static JingleSignalingSession incoming(
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid) throws SignalingError {
        require_token(sid, "Jingle SID");
        return new JingleSignalingSession(
            sid, local_full_jid, peer_full_jid, Jingle.Role.RESPONDER, null);
    }

    internal static JingleSignalingSession muji_incoming(
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        require_token(sid, "Jingle SID");
        validate_muji_room_jid(muji_room_jid);
        return new JingleSignalingSession(
            sid, local_full_jid, peer_full_jid, Jingle.Role.RESPONDER,
            muji_room_jid);
    }

    public StanzaNode build_session_initiate(
            JingleRtp.LibwebrtcJingleDescription description) throws SignalingError {
        require_open();
        require_state(SignalingState.NEW, "building session-initiate");
        require_description_type(description, JingleRtp.LibwebrtcSdpType.OFFER, "session-initiate");
        if (local_role != Jingle.Role.INITIATOR) {
            throw new SignalingError.BAD_STATE("only the initiator can build session-initiate");
        }

        StanzaNode jingle = build_outer_jingle("session-initiate")
            .put_attribute("initiator", local_full_jid.to_string());
        append_contents(jingle, description.contents, Jingle.Role.INITIATOR);
        state = SignalingState.LOCAL_OFFER_SENT;
        return jingle;
    }

    internal StanzaNode build_session_initiate_with_bundle(
            JingleRtp.LibwebrtcJingleDescription description) throws SignalingError {
        require_muji_bundle_context();
        return build_session_initiate_internal(description, true);
    }

    private StanzaNode build_session_initiate_internal(
            JingleRtp.LibwebrtcJingleDescription description,
            bool allow_bundle_grouping) throws SignalingError {
        require_open();
        require_state(SignalingState.NEW, "building session-initiate");
        require_description_type(description, JingleRtp.LibwebrtcSdpType.OFFER, "session-initiate");
        if (local_role != Jingle.Role.INITIATOR) {
            throw new SignalingError.BAD_STATE("only the initiator can build session-initiate");
        }

        StanzaNode jingle = build_outer_jingle("session-initiate")
            .put_attribute("initiator", local_full_jid.to_string());
        append_contents(jingle, description.contents, Jingle.Role.INITIATOR);
        if (allow_bundle_grouping) {
            Gee.List<string> emitted_bundle_content_names =
                append_bundle_group(jingle, description, null);
            local_offer_bundle_content_names =
                emitted_bundle_content_names.is_empty
                    ? null
                    : emitted_bundle_content_names;
        }
        state = SignalingState.LOCAL_OFFER_SENT;
        return jingle;
    }

    public Gee.List<JingleRtp.LibwebrtcJingleContent> read_session_initiate(StanzaNode jingle) throws SignalingError {
        require_open();
        require_state(SignalingState.NEW, "reading session-initiate");
        if (local_role != Jingle.Role.RESPONDER) {
            throw new SignalingError.BAD_STATE("only the responder can read incoming session-initiate here");
        }

        validate_muji_room(jingle);
        Gee.List<JingleRtp.LibwebrtcJingleContent> contents =
            parse_description_contents(jingle, "session-initiate", Jingle.Role.INITIATOR);
        validate_optional_jid_attribute(jingle, "initiator", peer_full_jid);
        state = SignalingState.REMOTE_OFFER_RECEIVED;
        return contents;
    }

    internal JingleSignalingDescription read_session_initiate_with_bundle(
            StanzaNode jingle) throws SignalingError {
        require_muji_bundle_context();
        return read_session_initiate_internal(jingle, true);
    }

    private JingleSignalingDescription read_session_initiate_internal(
            StanzaNode jingle,
            bool allow_bundle_grouping) throws SignalingError {
        require_open();
        require_state(SignalingState.NEW, "reading session-initiate");
        if (local_role != Jingle.Role.RESPONDER) {
            throw new SignalingError.BAD_STATE("only the responder can read incoming session-initiate here");
        }

        validate_muji_room(jingle);
        Gee.List<JingleRtp.LibwebrtcJingleContent> contents =
            parse_description_contents(jingle, "session-initiate", Jingle.Role.INITIATOR);
        Gee.List<string>? bundle_content_names = allow_bundle_grouping
            ? parse_optional_bundle_group(jingle, contents)
            : null;
        remote_offer_bundle_content_names =
            copy_optional_string_list(bundle_content_names);
        validate_optional_jid_attribute(jingle, "initiator", peer_full_jid);
        state = SignalingState.REMOTE_OFFER_RECEIVED;
        return new JingleSignalingDescription(
            contents, bundle_content_names);
    }

    public void mark_remote_description_set(JingleRtp.LibwebrtcSdpType type) throws SignalingError {
        require_open();
        if (type == JingleRtp.LibwebrtcSdpType.OFFER && state == SignalingState.REMOTE_OFFER_RECEIVED) {
            state = SignalingState.REMOTE_OFFER_SET;
            return;
        }
        if (type == JingleRtp.LibwebrtcSdpType.ANSWER && state == SignalingState.REMOTE_ANSWER_RECEIVED) {
            state = SignalingState.ACTIVE;
            return;
        }
        throw new SignalingError.BAD_STATE("remote description was set in an invalid signaling state");
    }

    public StanzaNode build_session_accept(
            JingleRtp.LibwebrtcJingleDescription description) throws SignalingError {
        require_open();
        require_state(SignalingState.REMOTE_OFFER_SET, "building session-accept");
        require_description_type(description, JingleRtp.LibwebrtcSdpType.ANSWER, "session-accept");
        if (local_role != Jingle.Role.RESPONDER) {
            throw new SignalingError.BAD_STATE("only the responder can build session-accept");
        }

        StanzaNode jingle = build_outer_jingle("session-accept")
            .put_attribute("responder", local_full_jid.to_string());
        append_contents(jingle, description.contents, Jingle.Role.INITIATOR);
        state = SignalingState.ACTIVE;
        return jingle;
    }

    internal StanzaNode build_session_accept_with_bundle(
            JingleRtp.LibwebrtcJingleDescription description) throws SignalingError {
        require_muji_bundle_context();
        return build_session_accept_internal(description, true);
    }

    private StanzaNode build_session_accept_internal(
            JingleRtp.LibwebrtcJingleDescription description,
            bool allow_bundle_grouping) throws SignalingError {
        require_open();
        require_state(SignalingState.REMOTE_OFFER_SET, "building session-accept");
        require_description_type(description, JingleRtp.LibwebrtcSdpType.ANSWER, "session-accept");
        if (local_role != Jingle.Role.RESPONDER) {
            throw new SignalingError.BAD_STATE("only the responder can build session-accept");
        }

        StanzaNode jingle = build_outer_jingle("session-accept")
            .put_attribute("responder", local_full_jid.to_string());
        append_contents(jingle, description.contents, Jingle.Role.INITIATOR);
        if (allow_bundle_grouping) {
            if (remote_offer_bundle_content_names == null) {
                if (!bundle_content_names_for_muji(description).is_empty) {
                    throw new SignalingError.BAD_STANZA(
                        "BUNDLE answer was not offered");
                }
            } else {
                append_bundle_group(
                    jingle,
                    description,
                    remote_offer_bundle_content_names);
            }
        }
        state = SignalingState.ACTIVE;
        return jingle;
    }

    public Gee.List<JingleRtp.LibwebrtcJingleContent> read_session_accept(StanzaNode jingle) throws SignalingError {
        require_open();
        require_state(SignalingState.LOCAL_OFFER_SENT, "reading session-accept");
        if (local_role != Jingle.Role.INITIATOR) {
            throw new SignalingError.BAD_STATE("only the initiator can read incoming session-accept here");
        }

        Gee.List<JingleRtp.LibwebrtcJingleContent> contents =
            parse_description_contents(jingle, "session-accept", Jingle.Role.INITIATOR);
        validate_optional_jid_attribute(jingle, "responder", peer_full_jid);
        state = SignalingState.REMOTE_ANSWER_RECEIVED;
        return contents;
    }

    internal JingleSignalingDescription read_session_accept_with_bundle(
            StanzaNode jingle) throws SignalingError {
        require_muji_bundle_context();
        return read_session_accept_internal(jingle, true);
    }

    private JingleSignalingDescription read_session_accept_internal(
            StanzaNode jingle,
            bool allow_bundle_grouping) throws SignalingError {
        require_open();
        require_state(SignalingState.LOCAL_OFFER_SENT, "reading session-accept");
        if (local_role != Jingle.Role.INITIATOR) {
            throw new SignalingError.BAD_STATE("only the initiator can read incoming session-accept here");
        }

        Gee.List<JingleRtp.LibwebrtcJingleContent> contents =
            parse_description_contents(jingle, "session-accept", Jingle.Role.INITIATOR);
        Gee.List<string>? bundle_content_names = allow_bundle_grouping
            ? parse_optional_bundle_group(jingle, contents)
            : null;
        validate_bundle_answer_against_offer(bundle_content_names);
        validate_optional_jid_attribute(jingle, "responder", peer_full_jid);
        state = SignalingState.REMOTE_ANSWER_RECEIVED;
        return new JingleSignalingDescription(
            contents, bundle_content_names);
    }

    public void queue_local_ice_candidate(JingleRtp.LibwebrtcJingleIceCandidate candidate) throws SignalingError {
        require_open();
        require_content_name(candidate.content_name);
        queued_local_ice.add(candidate);
    }

    public Gee.List<StanzaNode> drain_local_ice_transport_info() throws SignalingError {
        require_open();
        var nodes = new ArrayList<StanzaNode>();
        if (!can_send_transport_info()) return nodes;

        foreach (JingleRtp.LibwebrtcJingleIceCandidate candidate in queued_local_ice) {
            nodes.add(build_transport_info(candidate));
        }
        queued_local_ice.clear();
        return nodes;
    }

    public JingleRtp.LibwebrtcJingleIceCandidate read_transport_info(StanzaNode jingle) throws SignalingError, Jingle.IqError {
        Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> candidates = read_transport_info_candidates(jingle);
        if (candidates.size != 1) {
            throw new SignalingError.BAD_STANZA("expected exactly one transport-info candidate");
        }
        return candidates[0];
    }

    public Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> read_transport_info_candidates(StanzaNode jingle) throws SignalingError, Jingle.IqError {
        require_open();
        validate_outer_jingle(jingle, "transport-info");
        StanzaNode content = get_single_child(jingle, "content", Jingle.NS_URI);
        string? creator = content.get_attribute("creator");
        if (creator == null || Jingle.Role.parse((!) creator) != Jingle.Role.INITIATOR) {
            throw new SignalingError.BAD_STANZA("transport-info has an unexpected content creator");
        }
        string? content_name = content.get_attribute("name");
        require_content_name(content_name);

        StanzaNode transport = get_single_child(content, "transport", JingleIceUdp.NS_URI);
        Gee.List<StanzaNode> candidate_nodes = transport.get_subnodes("candidate", JingleIceUdp.NS_URI);
        Gee.List<StanzaNode> remote_candidate_nodes = transport.get_subnodes("remote-candidate", JingleIceUdp.NS_URI);
        if (candidate_nodes.size == 0) {
            if (remote_candidate_nodes.size == 1) {
                return new ArrayList<JingleRtp.LibwebrtcJingleIceCandidate>();
            }
            throw new SignalingError.BAD_STANZA("transport-info is missing a candidate or remote-candidate");
        }
        if (remote_candidate_nodes.size != 0) {
            throw new SignalingError.BAD_STANZA("transport-info must not mix candidate and remote-candidate");
        }

        string? ufrag = transport.get_attribute("ufrag");
        string? pwd = transport.get_attribute("pwd");
        require_token(ufrag, "ICE ufrag");
        require_token(pwd, "ICE pwd");

        var candidates = new ArrayList<JingleRtp.LibwebrtcJingleIceCandidate>();
        foreach (StanzaNode candidate_node in candidate_nodes) {
            JingleIceUdp.Candidate candidate = JingleIceUdp.Candidate.parse(candidate_node);
            candidates.add(new JingleRtp.LibwebrtcJingleIceCandidate(
                (!) content_name,
                (!) content_name,
                -1,
                JingleRtp.SdpBridge.candidate_to_sdp(candidate).substring(2),
                (!) ufrag,
                (!) pwd,
                candidate));
        }
        return candidates;
    }

    public StanzaNode build_session_terminate(string? reason_name = null, string? reason_text = null) throws SignalingError {
        require_open();
        StanzaNode jingle = build_outer_jingle("session-terminate");
        if (reason_name != null || reason_text != null) {
            StanzaNode reason = new StanzaNode.build("reason", Jingle.NS_URI);
            if (reason_name != null) {
                require_token(reason_name, "Jingle reason");
                reason.put_node(new StanzaNode.build((!) reason_name, Jingle.NS_URI));
            }
            if (reason_text != null) {
                require_text(reason_text, "Jingle reason text");
                reason.put_node(new StanzaNode.build("text", Jingle.NS_URI).put_node(new StanzaNode.text((!) reason_text)));
            }
            jingle.put_node(reason);
        }
        state = SignalingState.ENDED;
        queued_local_ice.clear();
        return jingle;
    }

    public void read_session_terminate(StanzaNode jingle) throws SignalingError {
        require_open();
        validate_outer_jingle(jingle, "session-terminate");
        state = SignalingState.ENDED;
        queued_local_ice.clear();
    }

    private bool can_send_transport_info() {
        return state == SignalingState.LOCAL_OFFER_SENT ||
            state == SignalingState.ACTIVE;
    }

    private StanzaNode build_transport_info(JingleRtp.LibwebrtcJingleIceCandidate candidate) throws SignalingError {
        require_content_name(candidate.content_name);
        StanzaNode transport = new StanzaNode.build("transport", JingleIceUdp.NS_URI)
            .add_self_xmlns()
            .put_attribute("ufrag", candidate.ice_ufrag)
            .put_attribute("pwd", candidate.ice_pwd)
            .put_node(candidate.jingle_candidate.to_xml());

        return build_outer_jingle("transport-info")
            .put_node(new StanzaNode.build("content", Jingle.NS_URI)
                .put_attribute("creator", Jingle.Role.INITIATOR.to_string())
                .put_attribute("name", candidate.content_name)
                .put_node(transport));
    }

    private StanzaNode build_outer_jingle(string action) throws SignalingError {
        require_token(action, "Jingle action");
        StanzaNode jingle = new StanzaNode.build("jingle", Jingle.NS_URI)
            .add_self_xmlns()
            .put_attribute("action", action)
            .put_attribute("sid", sid);
        if (action == "session-initiate" && muji_room_jid != null) {
            jingle.put_node(new StanzaNode.build("muji", Muji.NS_URI)
                .add_self_xmlns()
                .put_attribute("room", ((!) muji_room_jid).to_string()));
        }
        return jingle;
    }

    private void validate_muji_room(StanzaNode jingle) throws SignalingError {
        Gee.List<StanzaNode> muji_nodes = jingle.get_subnodes("muji", Muji.NS_URI);
        if (muji_room_jid == null) {
            if (!muji_nodes.is_empty) {
                throw new SignalingError.BAD_STANZA("unexpected MUJI room on a non-MUJI Jingle session");
            }
            return;
        }
        if (muji_nodes.size != 1) {
            throw new SignalingError.BAD_STANZA("MUJI session-initiate must contain exactly one room");
        }

        string? room = muji_nodes[0].get_attribute("room");
        if (room == null || ((!) room).strip() == "") {
            throw new SignalingError.BAD_STANZA("MUJI session-initiate is missing its room");
        }
        try {
            Jid parsed = new Jid((!) room);
            if (parsed.resourcepart != null || !parsed.equals((!) muji_room_jid)) {
                throw new SignalingError.BAD_STANZA("MUJI session-initiate has an unexpected room");
            }
        } catch (InvalidJidError e) {
            throw new SignalingError.BAD_STANZA("MUJI session-initiate has an invalid room");
        }
    }

    private static void validate_muji_room_jid(Jid room_jid) throws SignalingError {
        if (room_jid.resourcepart != null) {
            throw new SignalingError.BAD_STANZA("MUJI room must be a bare JID");
        }
    }

    private static void append_contents(
            StanzaNode jingle,
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents,
            Jingle.Role creator) throws SignalingError {
        if (contents.size == 0) {
            throw new SignalingError.BAD_STANZA("Jingle description must contain at least one content");
        }

        var names = new HashSet<string>();
        foreach (JingleRtp.LibwebrtcJingleContent content in contents) {
            require_content_name(content.content_name);
            if (names.contains(content.content_name)) {
                throw new SignalingError.BAD_STANZA("duplicate Jingle content name");
            }
            names.add(content.content_name);
            jingle.put_node(new StanzaNode.build("content", Jingle.NS_URI)
                .put_attribute("creator", creator.to_string())
                .put_attribute("name", content.content_name)
                .put_attribute("senders", content.senders.to_string())
                .put_node(content.description)
                .put_node(content.transport));
        }
    }

    private static Gee.List<string> append_bundle_group(
            StanzaNode jingle,
            JingleRtp.LibwebrtcJingleDescription description,
            Gee.List<string>? allowed_content_names)
            throws SignalingError {
        Gee.List<string> bundle_content_names =
            bundle_content_names_for_muji(description);
        var emitted_names = new ArrayList<string>();
        if (bundle_content_names.is_empty) return emitted_names;

        var content_names = new HashSet<string>();
        foreach (JingleRtp.LibwebrtcJingleContent content in
                description.contents) {
            content_names.add(content.content_name);
        }

        var bundled_names = new HashSet<string>();
        StanzaNode group = new StanzaNode.build(
                "group", JINGLE_GROUPING_NS)
            .add_self_xmlns()
            .put_attribute("semantics", "BUNDLE");
        foreach (string content_name in bundle_content_names) {
            if (allowed_content_names != null &&
                    !((!) allowed_content_names).contains(content_name)) {
                throw new SignalingError.BAD_STANZA(
                    "BUNDLE answer contains a content that was not bundled in the offer");
            }
            if (!content_names.contains(content_name)) {
                throw new SignalingError.BAD_STANZA(
                    "BUNDLE group references an unknown Jingle content");
            }
            if (bundled_names.contains(content_name)) {
                throw new SignalingError.BAD_STANZA(
                    "BUNDLE group contains a duplicate Jingle content");
            }
            bundled_names.add(content_name);
            emitted_names.add(content_name);
            group.put_node(new StanzaNode.build(
                    "content", JINGLE_GROUPING_NS)
                .put_attribute("name", content_name));
        }
        if (!emitted_names.is_empty) jingle.put_node(group);
        return emitted_names;
    }

    private void validate_bundle_answer_against_offer(
            Gee.List<string>? answer_bundle_content_names)
            throws SignalingError {
        if (answer_bundle_content_names == null) return;
        if (local_offer_bundle_content_names == null) {
            throw new SignalingError.BAD_STANZA(
                "BUNDLE answer was not offered");
        }
        foreach (string content_name in
                (!) answer_bundle_content_names) {
            if (!((!) local_offer_bundle_content_names)
                    .contains(content_name)) {
                throw new SignalingError.BAD_STANZA(
                    "BUNDLE answer contains a content that was not bundled in the offer");
            }
        }
    }

    private static Gee.List<string>? copy_optional_string_list(
            Gee.List<string>? source) {
        if (source == null) return null;
        var copy = new ArrayList<string>();
        copy.add_all((!) source);
        return copy;
    }

    private static Gee.List<string> bundle_content_names_for_muji(
            JingleRtp.LibwebrtcJingleDescription description)
            throws SignalingError {
        var names = new ArrayList<string>();
        if (description.session.bundle_mids.is_empty) return names;
        if (description.session.media_sections.size !=
                description.contents.size) {
            throw new SignalingError.BAD_STANZA(
                "SDP/Jingle content count mismatch while mapping BUNDLE");
        }

        var seen_mids = new HashSet<string>();
        foreach (string bundled_mid in
                description.session.bundle_mids) {
            require_token(bundled_mid, "BUNDLE MID");
            if (seen_mids.contains(bundled_mid)) {
                throw new SignalingError.BAD_STANZA(
                    "duplicate BUNDLE MID");
            }
            seen_mids.add(bundled_mid);

            int matched_index = -1;
            for (int i = 0;
                    i < description.session.media_sections.size; i++) {
                if (description.session.media_sections[i].mid ==
                        bundled_mid) {
                    matched_index = i;
                    break;
                }
            }
            if (matched_index < 0) {
                throw new SignalingError.BAD_STANZA(
                    "BUNDLE MID does not identify a Jingle content");
            }
            names.add(
                description.contents[matched_index].content_name);
        }
        return names;
    }

    private Gee.List<JingleRtp.LibwebrtcJingleContent> parse_description_contents(
            StanzaNode jingle,
            string expected_action,
            Jingle.Role expected_creator) throws SignalingError {
        validate_outer_jingle(jingle, expected_action);
        var contents = new ArrayList<JingleRtp.LibwebrtcJingleContent>();
        var names = new HashSet<string>();

        foreach (StanzaNode content in jingle.get_subnodes("content", Jingle.NS_URI)) {
            string? creator = content.get_attribute("creator");
            Jingle.Role parsed_creator;
            try {
                if (creator == null) {
                    throw new Jingle.IqError.BAD_REQUEST("missing content creator");
                }
                parsed_creator = Jingle.Role.parse((!) creator);
            } catch (Jingle.IqError e) {
                throw new SignalingError.BAD_STANZA(e.message);
            }
            if (parsed_creator != expected_creator) {
                throw new SignalingError.BAD_STANZA(@"$(expected_action) has an unexpected content creator");
            }
            string? content_name = content.get_attribute("name");
            require_content_name(content_name);
            if (names.contains((!) content_name)) {
                throw new SignalingError.BAD_STANZA("duplicate Jingle content name");
            }
            names.add((!) content_name);

            Jingle.Senders senders;
            try {
                senders = Jingle.Senders.parse(content.get_attribute("senders"));
            } catch (Jingle.IqError e) {
                throw new SignalingError.BAD_STANZA(e.message);
            }
            StanzaNode description = get_single_child_any_ns(content, "description");
            StanzaNode transport = get_single_child_any_ns(content, "transport");
            contents.add(new JingleRtp.LibwebrtcJingleContent((!) content_name, senders, description, transport));
        }

        if (contents.size == 0) {
            throw new SignalingError.BAD_STANZA(@"$(expected_action) has no content");
        }
        return contents;
    }

    private static Gee.List<string>? parse_optional_bundle_group(
            StanzaNode jingle,
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents)
            throws SignalingError {
        Gee.List<StanzaNode> groups =
            jingle.get_subnodes("group", JINGLE_GROUPING_NS);
        if (groups.size == 0) return null;

        StanzaNode? bundle_group = null;
        foreach (StanzaNode candidate in groups) {
            if (candidate.get_attribute("semantics") != "BUNDLE") continue;
            if (bundle_group != null) {
                throw new SignalingError.BAD_STANZA(
                    "Jingle description contains multiple BUNDLE groups");
            }
            bundle_group = candidate;
        }
        if (bundle_group == null) return null;
        StanzaNode group = (!) bundle_group;

        var known_names = new HashSet<string>();
        foreach (JingleRtp.LibwebrtcJingleContent content in contents) {
            known_names.add(content.content_name);
        }

        var bundled_names = new HashSet<string>();
        var ordered_names = new ArrayList<string>();
        foreach (StanzaNode grouped_content in
                group.get_subnodes("content", JINGLE_GROUPING_NS)) {
            string? content_name = grouped_content.get_attribute("name");
            require_content_name(content_name);
            if (!known_names.contains((!) content_name)) {
                throw new SignalingError.BAD_STANZA(
                    "BUNDLE group references an unknown Jingle content");
            }
            if (bundled_names.contains((!) content_name)) {
                throw new SignalingError.BAD_STANZA(
                    "BUNDLE group contains a duplicate Jingle content");
            }
            bundled_names.add((!) content_name);
            ordered_names.add((!) content_name);
        }
        if (ordered_names.is_empty) {
            throw new SignalingError.BAD_STANZA(
                "BUNDLE group must reference at least one Jingle content");
        }
        return ordered_names;
    }

    private void validate_outer_jingle(StanzaNode jingle, string expected_action) throws SignalingError {
        if (jingle.name != "jingle" || jingle.ns_uri != Jingle.NS_URI) {
            throw new SignalingError.BAD_STANZA("expected a Jingle node");
        }
        string? action = jingle.get_attribute("action");
        string? stanza_sid = jingle.get_attribute("sid");
        if (action != expected_action) {
            throw new SignalingError.BAD_STANZA(@"expected Jingle action $(expected_action)");
        }
        if (stanza_sid != sid) {
            throw new SignalingError.BAD_STANZA("Jingle SID does not match the signaling session");
        }
    }

    private static void validate_optional_jid_attribute(
            StanzaNode jingle,
            string attribute,
            Jid expected) throws SignalingError {
        string? jid_string = jingle.get_attribute(attribute);
        if (jid_string == null) return;
        try {
            Jid parsed = new Jid((!) jid_string);
            if (!parsed.equals(expected)) {
                throw new SignalingError.BAD_STANZA(@"Jingle $(attribute) does not match the peer JID");
            }
        } catch (InvalidJidError e) {
            throw new SignalingError.BAD_STANZA(e.message);
        }
    }

    private static StanzaNode get_single_child(StanzaNode parent, string name, string ns_uri) throws SignalingError {
        Gee.List<StanzaNode> nodes = parent.get_subnodes(name, ns_uri);
        if (nodes.size != 1) {
            throw new SignalingError.BAD_STANZA(@"expected exactly one $(name) node");
        }
        return nodes[0];
    }

    private static StanzaNode get_single_child_any_ns(StanzaNode parent, string name) throws SignalingError {
        StanzaNode? result = null;
        foreach (StanzaNode child in parent.get_all_subnodes()) {
            if (child.name != name) continue;
            if (result != null) {
                throw new SignalingError.BAD_STANZA(@"expected exactly one $(name) node");
            }
            result = child;
        }
        if (result == null) {
            throw new SignalingError.BAD_STANZA(@"missing $(name) node");
        }
        return (!) result;
    }

    private void require_muji_bundle_context() throws SignalingError {
        if (muji_room_jid == null) {
            throw new SignalingError.BAD_STATE(
                "Explicit BUNDLE signalling is restricted to MUJI sessions");
        }
    }

    private void require_open() throws SignalingError {
        if (state == SignalingState.ENDED) {
            throw new SignalingError.ENDED("Jingle signaling session has ended");
        }
    }

    private void require_state(SignalingState expected, string action) throws SignalingError {
        if (state != expected) {
            throw new SignalingError.BAD_STATE(@"invalid state for $(action)");
        }
    }

    private static void require_description_type(
            JingleRtp.LibwebrtcJingleDescription description,
            JingleRtp.LibwebrtcSdpType expected,
            string action) throws SignalingError {
        if (description.sdp_type != expected) {
            throw new SignalingError.BAD_STANZA(@"$(action) used the wrong SDP type");
        }
    }

    private static void require_token(string? value, string field) throws SignalingError {
        require_text(value, field);
        if (((!) value).contains(" ")) {
            throw new SignalingError.BAD_STANZA(@"illegal whitespace in $(field)");
        }
    }

    /** XEP-0166 declares content@name as xs:string, not as an XML token. */
    private static void require_content_name(string? value) throws SignalingError {
        if (value == null) {
            throw new SignalingError.BAD_STANZA("missing Jingle content name");
        }
        // Preserve every legal character exactly. StanzaNode owns XML escaping
        // and the XML parser owns attribute normalization on the real wire.
    }

    private static void require_text(string? value, string field) throws SignalingError {
        if (value == null || value == "") {
            throw new SignalingError.BAD_STANZA(@"missing $(field)");
        }
        if (((!) value).contains("\r") || ((!) value).contains("\n")) {
            throw new SignalingError.BAD_STANZA(@"illegal newline in $(field)");
        }
    }
}

}
