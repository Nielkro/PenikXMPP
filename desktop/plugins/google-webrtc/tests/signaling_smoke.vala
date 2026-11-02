using Gee;
using Xmpp;
using Xmpp.Xep;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private void assert_true(bool condition, string message) throws Error {
    if (!condition) {
        throw new IOError.FAILED(message);
    }
}

private void assert_int_eq(int actual, int expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): $(actual) != $(expected)");
    }
}

private void assert_str_eq(string? actual, string expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): '$(actual ?? "(null)")' != '$(expected)'");
    }
}

private JingleRtp.LibwebrtcJingleDescription make_description(JingleRtp.LibwebrtcSdpType type) throws Error {
    var contents = new ArrayList<JingleRtp.LibwebrtcJingleContent>();
    contents.add(new JingleRtp.LibwebrtcJingleContent(
        "audio",
        Jingle.Senders.BOTH,
        make_description_node("audio", "111", "opus", "48000", "2"),
        make_transport_node()));
    contents.add(new JingleRtp.LibwebrtcJingleContent(
        "video",
        Jingle.Senders.BOTH,
        make_description_node("video", "98", "VP8", "90000", null),
        make_transport_node()));
    return new JingleRtp.LibwebrtcJingleDescription(type, "", new JingleRtp.SdpSession(), contents);
}

private JingleRtp.LibwebrtcJingleDescription make_bundled_description(
        JingleRtp.LibwebrtcSdpType type) throws Error {
    JingleRtp.LibwebrtcJingleDescription description =
        make_description(type);
    var session = new JingleRtp.SdpSession();
    var audio = new JingleRtp.SdpMediaSection("audio") {
        mid = "0"
    };
    var video = new JingleRtp.SdpMediaSection("video") {
        mid = "1"
    };
    session.media_sections.add(audio);
    session.media_sections.add(video);
    session.bundle_mids.add("0");
    session.bundle_mids.add("1");
    return new JingleRtp.LibwebrtcJingleDescription(
        type,
        description.sdp,
        session,
        description.contents);
}

private StanzaNode make_description_node(
        string media,
        string id,
        string name,
        string clockrate,
        string? channels) {
    var payload = new StanzaNode.build("payload-type", JingleRtp.NS_URI)
        .put_attribute("id", id)
        .put_attribute("name", name)
        .put_attribute("clockrate", clockrate);
    if (channels != null) {
        payload.put_attribute("channels", (!) channels);
    }
    return new StanzaNode.build("description", JingleRtp.NS_URI)
        .add_self_xmlns()
        .put_attribute("media", media)
        .put_node(new StanzaNode.build("rtcp-mux", JingleRtp.NS_URI))
        .put_node(payload);
}

private StanzaNode make_transport_node() {
    return new StanzaNode.build("transport", JingleIceUdp.NS_URI)
        .add_self_xmlns()
        .put_attribute("ufrag", "ufrag")
        .put_attribute("pwd", "password");
}

private JingleRtp.LibwebrtcJingleIceCandidate make_candidate(string content_name = "audio") throws Error {
    JingleIceUdp.Candidate candidate = JingleRtp.SdpBridge.candidate_from_sdp(
        "a=candidate:1 1 udp 2130706431 192.0.2.10 5000 typ host generation 0");
    return new JingleRtp.LibwebrtcJingleIceCandidate(
        content_name,
        content_name,
        content_name == "audio" ? 0 : 1,
        "candidate:1 1 udp 2130706431 192.0.2.10 5000 typ host generation 0",
        "ufrag",
        "password",
        candidate);
}

private StanzaNode make_candidate_node(string foundation, string ip, uint16 port) throws Error {
    JingleIceUdp.Candidate candidate = JingleRtp.SdpBridge.candidate_from_sdp(
        "a=candidate:%s 1 udp 2130706431 %s %u typ host generation 0".printf(foundation, ip, port));
    return candidate.to_xml();
}

private JingleRtp.LibwebrtcJingleDescription make_named_video_description(
        JingleRtp.LibwebrtcSdpType type, string content_name) {
    var contents = new ArrayList<JingleRtp.LibwebrtcJingleContent>();
    contents.add(new JingleRtp.LibwebrtcJingleContent(
        content_name,
        Jingle.Senders.BOTH,
        make_description_node("video", "98", "VP8", "90000", null),
        make_transport_node()));
    return new JingleRtp.LibwebrtcJingleDescription(
        type, "", new JingleRtp.SdpSession(), contents);
}

private void test_outgoing_offer_accept_and_ice() throws Error {
    var local = new Jid("alice@example.test/DinoX");
    var peer = new Jid("bob@example.test/Phone");
    var outgoing = JingleSignalingSession.outgoing("sid-outgoing", local, peer);

    outgoing.queue_local_ice_candidate(make_candidate());
    assert_int_eq(outgoing.drain_local_ice_transport_info().size, 0, "ICE must be queued before session-initiate");

    StanzaNode initiate = outgoing.build_session_initiate(make_description(JingleRtp.LibwebrtcSdpType.OFFER));
    assert_str_eq(initiate.get_attribute("action"), "session-initiate", "action");
    assert_str_eq(initiate.get_attribute("sid"), "sid-outgoing", "sid");
    assert_str_eq(initiate.get_attribute("initiator"), local.to_string(), "initiator");
    assert_int_eq(initiate.get_subnodes("content", Jingle.NS_URI).size, 2, "session-initiate content count");
    StanzaNode first_content = initiate.get_subnodes("content", Jingle.NS_URI)[0];
    assert_str_eq(first_content.get_attribute("creator"), "initiator", "content creator");
    assert_str_eq(first_content.get_attribute("senders"), "both", "content senders");
    assert_true(first_content.get_subnode("description", JingleRtp.NS_URI) != null, "description must be present");
    assert_true(first_content.get_subnode("transport", JingleIceUdp.NS_URI) != null, "transport must be present");

    Gee.List<StanzaNode> queued_transport_infos = outgoing.drain_local_ice_transport_info();
    assert_int_eq(queued_transport_infos.size, 1, "queued ICE must drain after session-initiate");
    assert_str_eq(queued_transport_infos[0].get_attribute("action"), "transport-info", "transport-info action");
    StanzaNode queued_content = queued_transport_infos[0].get_subnodes("content", Jingle.NS_URI)[0];
    StanzaNode queued_transport = (!) queued_content.get_subnode("transport", JingleIceUdp.NS_URI);
    assert_str_eq(queued_transport.get_attribute("ufrag"), "ufrag", "transport-info ICE ufrag");
    assert_str_eq(queued_transport.get_attribute("pwd"), "password", "transport-info ICE pwd");

    var rejecting_responder = JingleSignalingSession.incoming("sid-outgoing", peer, local);
    rejecting_responder.read_session_initiate(initiate);
    rejecting_responder.mark_remote_description_set(JingleRtp.LibwebrtcSdpType.OFFER);
    StanzaNode mismatched_accept = rejecting_responder.build_session_accept(make_description(JingleRtp.LibwebrtcSdpType.ANSWER));
    mismatched_accept.set_attribute("responder", "mallory@example.test/Phone");
    bool rejected_wrong_responder = false;
    try {
        outgoing.read_session_accept(mismatched_accept);
    } catch (SignalingError e) {
        rejected_wrong_responder = e is SignalingError.BAD_STANZA;
    }
    assert_true(rejected_wrong_responder, "session-accept with mismatched responder must be rejected");
    assert_true(outgoing.state == SignalingState.LOCAL_OFFER_SENT, "bad session-accept must not advance initiator state");

    var responder = JingleSignalingSession.incoming("sid-outgoing", peer, local);
    Gee.List<JingleRtp.LibwebrtcJingleContent> remote_offer = responder.read_session_initiate(initiate);
    assert_int_eq(remote_offer.size, 2, "remote offer content count");
    responder.mark_remote_description_set(JingleRtp.LibwebrtcSdpType.OFFER);
    StanzaNode accept = responder.build_session_accept(make_description(JingleRtp.LibwebrtcSdpType.ANSWER));
    assert_str_eq(accept.get_attribute("action"), "session-accept", "session-accept action");
    assert_str_eq(accept.get_attribute("responder"), peer.to_string(), "responder");
    assert_int_eq(accept.get_subnodes("content", Jingle.NS_URI).size, 2, "session-accept content count");
    assert_true(responder.state == SignalingState.ACTIVE, "responder should become active after sending session-accept");

    Gee.List<JingleRtp.LibwebrtcJingleContent> remote_answer = outgoing.read_session_accept(accept);
    assert_int_eq(remote_answer.size, 2, "remote answer content count");
    outgoing.mark_remote_description_set(JingleRtp.LibwebrtcSdpType.ANSWER);
    assert_true(outgoing.state == SignalingState.ACTIVE, "initiator should become active after remote answer is set");

    JingleRtp.LibwebrtcJingleIceCandidate parsed_candidate =
        responder.read_transport_info(queued_transport_infos[0]);
    assert_str_eq(parsed_candidate.content_name, "audio", "transport-info content name");
    assert_str_eq(parsed_candidate.jingle_candidate.ip, "192.0.2.10", "transport-info candidate IP");
    assert_str_eq(parsed_candidate.ice_ufrag, "ufrag", "transport-info parsed ICE ufrag");
    assert_str_eq(parsed_candidate.ice_pwd, "password", "transport-info parsed ICE pwd");

    StanzaNode batched = queued_transport_infos[0];
    StanzaNode batched_content = batched.get_subnodes("content", Jingle.NS_URI)[0];
    StanzaNode batched_transport = (!) batched_content.get_subnode("transport", JingleIceUdp.NS_URI);
    batched_transport.put_node(make_candidate_node("2", "192.0.2.11", 5001));
    Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> batched_candidates =
        responder.read_transport_info_candidates(batched);
    assert_int_eq(batched_candidates.size, 2, "batched transport-info candidate count");
    assert_str_eq(batched_candidates[0].jingle_candidate.ip, "192.0.2.10", "batched first candidate IP");
    assert_str_eq(batched_candidates[1].jingle_candidate.ip, "192.0.2.11", "batched second candidate IP");

    StanzaNode remote_candidate_info = new StanzaNode.build("jingle", Jingle.NS_URI)
        .add_self_xmlns()
        .put_attribute("action", "transport-info")
        .put_attribute("sid", "sid-outgoing")
        .put_node(new StanzaNode.build("content", Jingle.NS_URI)
            .put_attribute("creator", "initiator")
            .put_attribute("name", "audio")
            .put_node(new StanzaNode.build("transport", JingleIceUdp.NS_URI)
                .add_self_xmlns()
                .put_attribute("ufrag", "ufrag")
                .put_attribute("pwd", "password")
                .put_node(new StanzaNode.build("remote-candidate", JingleIceUdp.NS_URI)
                    .put_attribute("component", "1")
                    .put_attribute("ip", "192.0.2.10")
                    .put_attribute("port", "5000"))));
    Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> remote_candidate_candidates =
        responder.read_transport_info_candidates(remote_candidate_info);
    assert_int_eq(remote_candidate_candidates.size, 0, "remote-candidate is acknowledged without remote ICE injection");
}

private void test_state_rejections() throws Error {
    var local = new Jid("alice@example.test/DinoX");
    var peer = new Jid("bob@example.test/Phone");
    var outgoing = JingleSignalingSession.outgoing("sid-errors", local, peer);

    bool rejected_accept_before_offer = false;
    try {
        outgoing.read_session_accept(new StanzaNode.build("jingle", Jingle.NS_URI)
            .add_self_xmlns()
            .put_attribute("action", "session-accept")
            .put_attribute("sid", "sid-errors"));
    } catch (SignalingError e) {
        rejected_accept_before_offer = e is SignalingError.BAD_STATE;
    }
    assert_true(rejected_accept_before_offer, "session-accept before offer must be rejected");

    outgoing.build_session_initiate(make_description(JingleRtp.LibwebrtcSdpType.OFFER));
    bool rejected_second_offer = false;
    try {
        outgoing.build_session_initiate(make_description(JingleRtp.LibwebrtcSdpType.OFFER));
    } catch (SignalingError e) {
        rejected_second_offer = e is SignalingError.BAD_STATE;
    }
    assert_true(rejected_second_offer, "second session-initiate must be rejected");

    StanzaNode terminate = outgoing.build_session_terminate("success", "done");
    assert_str_eq(terminate.get_attribute("action"), "session-terminate", "terminate action");
    assert_true(outgoing.state == SignalingState.ENDED, "state must be ended after terminate");

    bool rejected_after_end = false;
    try {
        outgoing.queue_local_ice_candidate(make_candidate());
    } catch (SignalingError e) {
        rejected_after_end = e is SignalingError.ENDED;
    }
    assert_true(rejected_after_end, "ended session must reject more ICE");
}

private void test_bundle_grouping_roundtrip_and_validation() throws Error {
    var local = new Jid("alice-bundle@example.test/DinoX");
    var peer = new Jid("bob-bundle@example.test/Phone");
    var room = new Jid("bundle@conference.example.test");

    var direct_bundle_attempt = JingleSignalingSession.outgoing(
        "sid-direct-bundle-rejected", local, peer);
    bool direct_bundle_rejected = false;
    try {
        direct_bundle_attempt.build_session_initiate_with_bundle(
            make_bundled_description(JingleRtp.LibwebrtcSdpType.OFFER));
    } catch (SignalingError e) {
        direct_bundle_rejected = e is SignalingError.BAD_STATE;
    }
    assert_true(direct_bundle_rejected,
        "explicit BUNDLE output must stay on the MUJI signaling branch");

    var direct_outgoing = JingleSignalingSession.outgoing(
        "sid-direct-bundle-ignored", local, peer);
    StanzaNode direct_offer = direct_outgoing.build_session_initiate(
        make_bundled_description(JingleRtp.LibwebrtcSdpType.OFFER));
    direct_offer.put_node(new StanzaNode.build("group", JINGLE_GROUPING_NS)
        .add_self_xmlns()
        .put_attribute("semantics", "BUNDLE")
        .put_node(new StanzaNode.build("content", JINGLE_GROUPING_NS)
            .put_attribute("name", "audio")));
    var direct_incoming = JingleSignalingSession.incoming(
        "sid-direct-bundle-ignored", peer, local);
    Gee.List<JingleRtp.LibwebrtcJingleContent> direct_contents =
        direct_incoming.read_session_initiate(direct_offer);
    assert_int_eq(direct_contents.size, 2,
        "direct signaling must retain its established content parser");

    var unbundled = JingleSignalingSession.muji_outgoing(
        "sid-bundle-disabled", local, peer, room);
    StanzaNode unbundled_offer = unbundled.build_session_initiate(
        make_bundled_description(JingleRtp.LibwebrtcSdpType.OFFER));
    assert_int_eq(
        unbundled_offer.get_subnodes("group", JINGLE_GROUPING_NS).size,
        0,
        "BUNDLE must stay disabled without an advertised peer capability");

    var outgoing = JingleSignalingSession.muji_outgoing(
        "sid-bundle", local, peer, room);
    StanzaNode initiate = outgoing.build_session_initiate_with_bundle(
        make_bundled_description(JingleRtp.LibwebrtcSdpType.OFFER));
    Gee.List<StanzaNode> groups =
        initiate.get_subnodes("group", JINGLE_GROUPING_NS);
    assert_int_eq(groups.size, 1, "session-initiate BUNDLE group count");
    assert_str_eq(groups[0].get_attribute("semantics"), "BUNDLE",
        "session-initiate grouping semantics");
    Gee.List<StanzaNode> grouped_contents =
        groups[0].get_subnodes("content", JINGLE_GROUPING_NS);
    assert_int_eq(grouped_contents.size, 2,
        "session-initiate bundled content count");
    assert_str_eq(grouped_contents[0].get_attribute("name"), "audio",
        "first bundled content");
    assert_str_eq(grouped_contents[1].get_attribute("name"), "video",
        "second bundled content");
    initiate.put_node(new StanzaNode.build("group", JINGLE_GROUPING_NS)
        .add_self_xmlns()
        .put_attribute("semantics", "LS")
        .put_node(new StanzaNode.build("content", JINGLE_GROUPING_NS)
            .put_attribute("name", "audio")));

    var incoming = JingleSignalingSession.muji_incoming(
        "sid-bundle", peer, local, room);
    JingleSignalingDescription parsed_offer =
        incoming.read_session_initiate_with_bundle(initiate);
    assert_true(parsed_offer.bundle_content_names != null,
        "incoming BUNDLE group must be retained");
    assert_int_eq(((!) parsed_offer.bundle_content_names).size, 2,
        "parsed BUNDLE content count");
    assert_str_eq(((!) parsed_offer.bundle_content_names)[0], "audio",
        "parsed first BUNDLE content");
    assert_str_eq(((!) parsed_offer.bundle_content_names)[1], "video",
        "parsed second BUNDLE content");
    incoming.mark_remote_description_set(JingleRtp.LibwebrtcSdpType.OFFER);
    StanzaNode accept = incoming.build_session_accept_with_bundle(
        make_bundled_description(JingleRtp.LibwebrtcSdpType.ANSWER));
    JingleSignalingDescription parsed_answer =
        outgoing.read_session_accept_with_bundle(accept);
    assert_true(parsed_answer.bundle_content_names != null,
        "BUNDLE answer must be retained");
    assert_int_eq(((!) parsed_answer.bundle_content_names).size, 2,
        "parsed BUNDLE answer count");

    var subset_outgoing = JingleSignalingSession.muji_outgoing(
        "sid-bundle-subset", local, peer, room);
    StanzaNode subset_offer = subset_outgoing.build_session_initiate_with_bundle(
        make_bundled_description(JingleRtp.LibwebrtcSdpType.OFFER));
    var subset_incoming = JingleSignalingSession.muji_incoming(
        "sid-bundle-subset", peer, local, room);
    subset_incoming.read_session_initiate_with_bundle(subset_offer);
    subset_incoming.mark_remote_description_set(
        JingleRtp.LibwebrtcSdpType.OFFER);
    JingleRtp.LibwebrtcJingleDescription subset_description =
        make_bundled_description(JingleRtp.LibwebrtcSdpType.ANSWER);
    subset_description.session.bundle_mids.clear();
    subset_description.session.bundle_mids.add("1");
    StanzaNode subset_accept =
        subset_incoming.build_session_accept_with_bundle(
            subset_description);
    JingleSignalingDescription parsed_subset_answer =
        subset_outgoing.read_session_accept_with_bundle(subset_accept);
    assert_true(parsed_subset_answer.bundle_content_names != null,
        "a legal BUNDLE answer subset must be retained");
    assert_int_eq(
        ((!) parsed_subset_answer.bundle_content_names).size,
        1,
        "BUNDLE answer may select a smaller offered subset");
    assert_str_eq(
        ((!) parsed_subset_answer.bundle_content_names)[0],
        "video",
        "BUNDLE answer may select a different first bundled content");

    var no_bundle_outgoing = JingleSignalingSession.muji_outgoing(
        "sid-bundle-not-offered", local, peer, room);
    StanzaNode no_bundle_offer = no_bundle_outgoing.build_session_initiate(
        make_description(JingleRtp.LibwebrtcSdpType.OFFER));
    var no_bundle_incoming = JingleSignalingSession.muji_incoming(
        "sid-bundle-not-offered", peer, local, room);
    no_bundle_incoming.read_session_initiate_with_bundle(no_bundle_offer);
    no_bundle_incoming.mark_remote_description_set(
        JingleRtp.LibwebrtcSdpType.OFFER);
    bool local_unsolicited_bundle_rejected = false;
    try {
        no_bundle_incoming.build_session_accept_with_bundle(
            make_bundled_description(JingleRtp.LibwebrtcSdpType.ANSWER));
    } catch (SignalingError e) {
        local_unsolicited_bundle_rejected =
            e is SignalingError.BAD_STANZA;
    }
    assert_true(local_unsolicited_bundle_rejected,
        "a local BUNDLE answer must be rejected when BUNDLE was not offered");
    StanzaNode unsolicited_bundle_answer =
        no_bundle_incoming.build_session_accept_with_bundle(
            make_description(JingleRtp.LibwebrtcSdpType.ANSWER));
    assert_int_eq(
        unsolicited_bundle_answer.get_subnodes(
            "group", JINGLE_GROUPING_NS).size,
        0,
        "a responder must not add BUNDLE when it was not offered");
    unsolicited_bundle_answer.put_node(
        new StanzaNode.build("group", JINGLE_GROUPING_NS)
            .add_self_xmlns()
            .put_attribute("semantics", "BUNDLE")
            .put_node(new StanzaNode.build(
                    "content", JINGLE_GROUPING_NS)
                .put_attribute("name", "audio")));
    bool unsolicited_bundle_rejected = false;
    try {
        no_bundle_outgoing.read_session_accept_with_bundle(
            unsolicited_bundle_answer);
    } catch (SignalingError e) {
        unsolicited_bundle_rejected = e is SignalingError.BAD_STANZA;
    }
    assert_true(unsolicited_bundle_rejected,
        "an unsolicited BUNDLE answer must be rejected");

    JingleRtp.LibwebrtcJingleDescription audio_bundle_offer_description =
        make_bundled_description(JingleRtp.LibwebrtcSdpType.OFFER);
    audio_bundle_offer_description.session.bundle_mids.clear();
    audio_bundle_offer_description.session.bundle_mids.add("0");
    var enlarged_outgoing = JingleSignalingSession.muji_outgoing(
        "sid-bundle-enlarged", local, peer, room);
    StanzaNode audio_bundle_offer =
        enlarged_outgoing.build_session_initiate_with_bundle(
            audio_bundle_offer_description);
    var enlarged_incoming = JingleSignalingSession.muji_incoming(
        "sid-bundle-enlarged", peer, local, room);
    enlarged_incoming.read_session_initiate_with_bundle(
        audio_bundle_offer);
    enlarged_incoming.mark_remote_description_set(
        JingleRtp.LibwebrtcSdpType.OFFER);
    bool local_enlarged_bundle_rejected = false;
    try {
        enlarged_incoming.build_session_accept_with_bundle(
            make_bundled_description(JingleRtp.LibwebrtcSdpType.ANSWER));
    } catch (SignalingError e) {
        local_enlarged_bundle_rejected = e is SignalingError.BAD_STANZA;
    }
    assert_true(local_enlarged_bundle_rejected,
        "a local BUNDLE answer must not enlarge the offered group");

    JingleRtp.LibwebrtcJingleDescription legal_audio_bundle_answer =
        make_bundled_description(JingleRtp.LibwebrtcSdpType.ANSWER);
    legal_audio_bundle_answer.session.bundle_mids.clear();
    legal_audio_bundle_answer.session.bundle_mids.add("0");
    StanzaNode enlarged_answer =
        enlarged_incoming.build_session_accept_with_bundle(
            legal_audio_bundle_answer);
    StanzaNode? enlarged_group = enlarged_answer.get_subnode(
        "group", JINGLE_GROUPING_NS);
    assert_true(enlarged_group != null,
        "the legal offered BUNDLE member must remain in the answer");
    ((!) enlarged_group).put_node(
        new StanzaNode.build("content", JINGLE_GROUPING_NS)
            .put_attribute("name", "video"));
    bool enlarged_bundle_rejected = false;
    try {
        enlarged_outgoing.read_session_accept_with_bundle(
            enlarged_answer);
    } catch (SignalingError e) {
        enlarged_bundle_rejected = e is SignalingError.BAD_STANZA;
    }
    assert_true(enlarged_bundle_rejected,
        "a BUNDLE answer must not enlarge the offered group");

    var malformed_outgoing = JingleSignalingSession.muji_outgoing(
        "sid-bundle-malformed", local, peer, room);
    StanzaNode malformed = malformed_outgoing.build_session_initiate(
        make_description(JingleRtp.LibwebrtcSdpType.OFFER));
    malformed.put_node(new StanzaNode.build("group", JINGLE_GROUPING_NS)
        .add_self_xmlns()
        .put_attribute("semantics", "BUNDLE")
        .put_node(new StanzaNode.build("content", JINGLE_GROUPING_NS)
            .put_attribute("name", "unknown")));
    var malformed_incoming = JingleSignalingSession.muji_incoming(
        "sid-bundle-malformed", peer, local, room);
    bool unknown_content_rejected = false;
    try {
        malformed_incoming.read_session_initiate_with_bundle(malformed);
    } catch (SignalingError e) {
        unknown_content_rejected = e is SignalingError.BAD_STANZA;
    }
    assert_true(unknown_content_rejected,
        "BUNDLE group with an unknown content must be rejected");
}

private void test_muji_room_serialization_and_validation() throws Error {
    var local = new Jid("alice@example.test/DinoX");
    var peer = new Jid("bob@example.test/Phone");
    var room = new Jid("call-123@conference.example.test");
    var outgoing = JingleSignalingSession.muji_outgoing(
        "sid-muji-room", local, peer, room);

    StanzaNode initiate = outgoing.build_session_initiate(
        make_description(JingleRtp.LibwebrtcSdpType.OFFER));
    Gee.List<StanzaNode> muji_nodes = initiate.get_subnodes("muji", Muji.NS_URI);
    assert_int_eq(muji_nodes.size, 1, "MUJI session-initiate room count");
    assert_str_eq(muji_nodes[0].get_attribute("room"), room.to_string(),
        "MUJI session-initiate room");

    var matching = JingleSignalingSession.muji_incoming(
        "sid-muji-room", peer, local, room);
    assert_int_eq(matching.read_session_initiate(initiate).size, 2,
        "matching MUJI room must be accepted");

    var wrong_room = JingleSignalingSession.muji_incoming(
        "sid-muji-room", peer, local,
        new Jid("other@conference.example.test"));
    bool wrong_room_rejected = false;
    try {
        wrong_room.read_session_initiate(initiate);
    } catch (SignalingError e) {
        wrong_room_rejected = e is SignalingError.BAD_STANZA;
    }
    assert_true(wrong_room_rejected, "wrong MUJI room must be rejected");

    var missing_room_outgoing = JingleSignalingSession.muji_outgoing(
        "sid-muji-room", local, peer, room);
    StanzaNode missing_room = missing_room_outgoing.build_session_initiate(
        make_description(JingleRtp.LibwebrtcSdpType.OFFER));
    StanzaNode? missing_room_muji = missing_room.get_subnode("muji", Muji.NS_URI);
    assert_true(missing_room_muji != null, "MUJI clone must retain room node");
    missing_room.sub_nodes.remove((!) missing_room_muji);
    var requires_room = JingleSignalingSession.muji_incoming(
        "sid-muji-room", peer, local, room);
    bool missing_room_rejected = false;
    try {
        requires_room.read_session_initiate(missing_room);
    } catch (SignalingError e) {
        missing_room_rejected = e is SignalingError.BAD_STANZA;
    }
    assert_true(missing_room_rejected, "missing MUJI room must be rejected");

    var non_muji = JingleSignalingSession.incoming(
        "sid-muji-room", peer, local);
    bool unexpected_room_rejected = false;
    try {
        non_muji.read_session_initiate(initiate);
    } catch (SignalingError e) {
        unexpected_room_rejected = e is SignalingError.BAD_STANZA;
    }
    assert_true(unexpected_room_rejected,
        "non-MUJI session must reject an unsolicited room marker");
}

private void test_xs_string_content_name_wire_roundtrip() throws Error {
    var local = new Jid("alice-xs-string@example.test/DinoX");
    var peer = new Jid("bob-xs-string@example.test/Phone");
    var room = new Jid("xs-string@conference.example.test");
    const string CONTENT_NAME = "camera channel main";
    var outgoing = JingleSignalingSession.muji_outgoing(
        "sid-xs-string", local, peer, room);
    outgoing.queue_local_ice_candidate(make_candidate(CONTENT_NAME));

    StanzaNode initiate = outgoing.build_session_initiate(
        make_named_video_description(
            JingleRtp.LibwebrtcSdpType.OFFER, CONTENT_NAME));
    StanzaNode initiate_content =
        initiate.get_subnodes("content", Jingle.NS_URI)[0];
    assert_str_eq(initiate_content.get_attribute("name"), CONTENT_NAME,
        "xs:string session-initiate content name");

    var incoming = JingleSignalingSession.muji_incoming(
        "sid-xs-string", peer, local, room);
    Gee.List<JingleRtp.LibwebrtcJingleContent> offer =
        incoming.read_session_initiate(initiate);
    assert_str_eq(offer[0].content_name, CONTENT_NAME,
        "xs:string parsed offer content name");
    incoming.mark_remote_description_set(JingleRtp.LibwebrtcSdpType.OFFER);
    StanzaNode accept = incoming.build_session_accept(
        make_named_video_description(
            JingleRtp.LibwebrtcSdpType.ANSWER, CONTENT_NAME));
    Gee.List<JingleRtp.LibwebrtcJingleContent> answer =
        outgoing.read_session_accept(accept);
    assert_str_eq(answer[0].content_name, CONTENT_NAME,
        "xs:string parsed answer content name");
    outgoing.mark_remote_description_set(JingleRtp.LibwebrtcSdpType.ANSWER);

    Gee.List<StanzaNode> transport_infos =
        outgoing.drain_local_ice_transport_info();
    assert_int_eq(transport_infos.size, 1,
        "xs:string content candidate must drain");
    JingleRtp.LibwebrtcJingleIceCandidate candidate =
        incoming.read_transport_info(transport_infos[0]);
    assert_str_eq(candidate.content_name, CONTENT_NAME,
        "xs:string transport-info content name");
}

private int run_smoke() {
    try {
        test_outgoing_offer_accept_and_ice();
        test_state_rejections();
        test_bundle_grouping_roundtrip_and_validation();
        test_muji_room_serialization_and_validation();
        test_xs_string_content_name_wire_roundtrip();
        return 0;
    } catch (Error e) {
        printerr("google-webrtc-signaling-smoke failed: %s\n", e.message);
        return 1;
    }
}

}

public int main(string[] args) {
    return Dino.Plugins.GoogleWebrtc.Test.run_smoke();
}
