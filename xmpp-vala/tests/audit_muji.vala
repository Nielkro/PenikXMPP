using Gee;

namespace Xmpp.Test {

private errordomain AuditMujiCodecError {
    PROVIDER_FAILURE
}

private class AuditMujiCodecProvider : Object, Xep.Muji.CodecProvider {
    public bool fail_get { get; set; default = false; }
    public bool fail_check { get; set; default = false; }
    public bool audio_available { get; set; default = true; }
    public bool video_available { get; set; default = false; }

    public async Gee.List<Xep.JingleRtp.PayloadType> get_supported_payloads(
            string media) throws Error {
        if (fail_get) {
            throw new AuditMujiCodecError.PROVIDER_FAILURE("codec enumeration failed");
        }
        var ret = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        if ((media == "audio" && audio_available) ||
                (media == "video" && video_available)) {
            ret.add(make_payload(media));
        }
        return ret;
    }

    public async bool is_payload_supported(
            string media, Xep.JingleRtp.PayloadType payload_type) throws Error {
        if (fail_check) {
            throw new AuditMujiCodecError.PROVIDER_FAILURE("codec check failed");
        }
        return (media == "audio" && audio_available) ||
            (media == "video" && video_available);
    }

    public static Xep.JingleRtp.PayloadType make_payload(string media) {
        var payload = new Xep.JingleRtp.PayloadType();
        payload.id = media == "audio" ? 111 : 96;
        payload.name = media == "audio" ? "opus" : "VP8";
        payload.clockrate = media == "audio" ? 48000 : 90000;
        payload.channels = media == "audio" ? 2 : 1;
        return payload;
    }
}

private class AuditMujiPayloadSetProvider : Object, Xep.Muji.CodecProvider {
    public Gee.List<Xep.JingleRtp.PayloadType> local_payloads =
        new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);

    public async Gee.List<Xep.JingleRtp.PayloadType> get_supported_payloads(
            string media) throws Error {
        var copy = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        foreach (Xep.JingleRtp.PayloadType payload in local_payloads) {
            copy.add(payload.clone());
        }
        return copy;
    }

    public async bool is_payload_supported(
            string media, Xep.JingleRtp.PayloadType payload_type) throws Error {
        foreach (Xep.JingleRtp.PayloadType local in local_payloads) {
            if (local.name != null && payload_type.name != null &&
                    ((!) local.name).strip().down() ==
                        ((!) payload_type.name).strip().down() &&
                    local.clockrate == payload_type.clockrate &&
                    local.channels == payload_type.channels) {
                return true;
            }
        }
        return false;
    }
}

/**
 * XEP-0272: MUJI (Multi-User Jingle Interaction) -- Group Call Protocol
 * XEP-0482: Call Invites -- MUJI propose/accept/retract stanzas
 * XEP-0167: Jingle RTP -- PayloadType codec intersection
 * XEP-0045: MUC -- Presence with MUJI extension
 *
 * Tests pure-logic and stanza-format aspects of the MUJI group call
 * implementation. No network I/O required -- only XML parsing via
 * StanzaReader, data class contracts, and namespace correctness.
 *
 * References:
 *   XEP-0272 S3: MUJI presence with <muji xmlns='urn:xmpp:jingle:muji:0'>
 *   XEP-0272 S4: <preparing/> element during codec negotiation
 *   XEP-0272 S5: <content> with <description> carrying payload-types
 *   XEP-0482 S3: <invite> with <muji room='...'/>
 *   XEP-0167 S5: PayloadType id, name, clockrate, channels
 *   RFC 4566 S6: SDP payload type IDs 0-127 (static+dynamic)
 */
class MujiAudit : Gee.TestCase {

    public MujiAudit() {
        base("MujiAudit");

        // --- XEP-0272: Namespace & Constants ---
        add_test("XEP0272_ns_uri_is_jingle_muji_0", test_ns_uri);
        add_test("XEP0272_call_invites_ns_uri", test_call_invites_ns);

        // --- XEP-0272 S3: MUJI Presence Stanza Format ---
        add_async_test("XEP0272_S3_preparing_presence_parse", test_preparing_presence_parse);
        add_async_test("XEP0272_S3_ready_presence_with_codecs_parse", test_ready_presence_parse);
        add_test("XEP0272_S3_jingle_namespace_content_is_not_muji_content", test_jingle_namespace_content_rejected);
        add_async_test("XEP0272_S3_presence_missing_muji_node_ignored", test_presence_no_muji_node);
        add_async_test("XEP0272_S3_presence_preparing_is_empty_element", test_preparing_is_empty);
        add_async_test("XEP0272_S3_preparing_generation_wire_parse",
            test_preparing_generation_wire_parse);
        add_async_test("XEP0272_existing_room_reuses_occupancy",
            test_existing_room_reuses_occupancy);
        add_async_test("XEP0272_ready_presence_survives_occupant_resync",
            test_ready_presence_survives_occupant_resync);
        add_async_test("XEP0272_status_presence_preserves_muji_without_aliasing",
            test_status_presence_preserves_muji_without_aliasing);
        add_async_test("XEP0272_preparing_presence_survives_occupant_resync",
            test_preparing_presence_survives_occupant_resync);
        add_async_test("XEP0272_presence_replay_scope_and_leave",
            test_presence_replay_scope_and_leave);
        add_async_test("XEP0272_presence_replay_is_stream_scoped",
            test_presence_replay_is_stream_scoped);
        add_async_test("XEP0272_stale_join_cannot_clear_successor",
            test_stale_join_cannot_clear_successor);
        add_async_test("XEP0272_existing_room_join_is_cancellable",
            test_existing_room_join_is_cancellable);
        add_async_test("XEP0272_existing_room_accepts_idless_self_echo",
            test_existing_room_accepts_idless_self_echo);
        add_async_test("XEP0272_existing_room_accepts_legacy_id_echo",
            test_existing_room_accepts_legacy_id_echo);
        add_async_test("MUJI_ready_echo_releases_only_current_outgoing",
            (cb) => test_ready_echo_scope_async.begin(cb));
        add_async_test("MUJI_ready_wait_keeps_incoming_admission",
            (cb) => test_ready_incoming_async.begin(cb));
        add_async_test("MUJI_ready_wait_cancellation_is_immediate",
            (cb) => test_ready_cancellation_async.begin(cb));
        add_async_test("MUJI_ready_wait_falls_back_after_five_seconds",
            (cb) => test_ready_timeout_async.begin(cb, false));
        add_async_test("MUJI_ready_timeout_cannot_release_replacement",
            (cb) => test_ready_timeout_async.begin(cb, true));
        add_async_test("XEP0272_disconnected_release_is_local_only",
            test_disconnected_release_is_local_only);
        add_test("XEP0272_dedicated_room_uses_confirmed_nick_on_leave",
            test_dedicated_room_uses_confirmed_nick_on_leave);

        // --- XEP-0272 S5: Payload Type in MUJI Presence ---
        add_async_test("XEP0272_S5_audio_payload_type_opus_parsed", test_payload_type_opus);
        add_async_test("XEP0272_S5_video_payload_type_vp8_parsed", test_payload_type_vp8);
        add_async_test("XEP0272_S5_multiple_payload_types_in_description", test_multiple_payload_types);
        add_async_test("XEP0272_S5_payload_type_with_parameters", test_payload_type_parameters);

        // --- XEP-0272: Codec Intersection Logic ---
        add_test("XEP0167_payload_type_equals_same", test_payload_equals_same);
        add_test("XEP0167_payload_type_equals_different_id", test_payload_equals_different_id);
        add_test("XEP0167_payload_type_clone_is_equal", test_payload_clone_equal);

        // --- XEP-0272: GroupCall Data Class ---
        add_test("XEP0272_groupcall_muc_jid_stored", test_groupcall_muc_jid);
        add_test("XEP0272_groupcall_peers_initially_empty", test_groupcall_peers_empty);
        add_test("XEP0272_groupcall_peers_to_connect_initially_empty", test_groupcall_connect_empty);
        add_test("XEP0272_groupcall_signal_peer_joined_fires", test_groupcall_peer_joined_signal);
        add_test("XEP0272_groupcall_signal_peer_left_fires", test_groupcall_peer_left_signal);
        add_test("XEP0272_groupcall_signal_codecs_changed_fires", test_groupcall_codecs_changed_signal);

        // --- XEP-0272: Flag (stream flag) ---
        add_test("XEP0272_flag_ns_matches_module", test_flag_ns);
        add_test("XEP0272_flag_calls_map_initially_empty", test_flag_calls_empty);
        add_test("XEP0272_flag_calls_map_store_retrieve", test_flag_calls_store);

        // --- XEP-0272: Nick Format ---
        add_test("XEP0272_nick_is_8_hex_chars", test_nick_format);

        // --- XEP-0482: Call Invite Stanza with MUJI ---
        add_async_test("XEP0482_muji_propose_has_room_attribute", test_cim_muji_propose);
        add_async_test("XEP0482_muji_propose_muji_ns_correct", test_cim_muji_ns);
        add_test("XEP0482_invite_uses_message_reference_id", test_cim_invite_call_id);
        add_test("XEP0482_groupchat_uses_room_stanza_id", test_cim_groupchat_reference_id);
        add_test("XEP0482_groupchat_without_room_stanza_id_is_rejected", test_cim_groupchat_missing_reference_id);
        add_test("XEP0482_groupchat_conflicting_room_stanza_ids_are_rejected", test_cim_groupchat_conflicting_reference_ids);
        add_test("XEP0482_standard_left_is_parsed", test_cim_left);
        add_async_test("XEP0482_invite_video_attribute", test_cim_invite_video);
        add_async_test("XEP0482_retract_has_id", test_cim_retract);
        add_async_test("XEP0482_accept_has_muji_room", test_cim_accept_muji);

        add_test("MUJI_nick_election_matches_Monocles_UTF16", test_nick_election_utf16);
        add_test("MUJI_three_participant_roles_ignore_join_order", test_nick_election_three_participants);

        // --- RFC 4566 / XEP-0167: PayloadType ID Range ---
        add_test("RFC4566_payload_id_range_0_127", test_payload_id_range);
        add_test("RFC4566_payload_id_parse_fails_closed", test_payload_id_parse_fail_closed);

        // --- XEP-0272: Payload Intersection Determinism ---
        add_test("XEP0272_payload_intersection_empty_if_no_common", test_intersection_no_common);
        add_test("XEP0272_payload_intersection_keeps_common", test_intersection_keeps_common);
        add_test("XEP0272_common_content_name_is_preserved", test_common_content_name_preserved);
        add_test("XEP0272_same_media_different_content_names_do_not_intersect", test_different_content_names_do_not_intersect);
        add_test("XEP0272_duplicate_content_identity_is_fail_closed", test_duplicate_content_identity_is_fail_closed);
        add_test("XEP0166_content_name_accepts_xs_string_whitespace", test_content_name_accepts_xs_string_whitespace);
        add_test("XEP0272_content_without_creator_is_not_negotiable", test_content_without_creator_is_not_negotiable);
        add_test("XEP0272_group_content_names_are_frozen", test_group_content_names_are_frozen);
        add_async_test("XEP0272_codec_provider_get_error_propagates", test_codec_provider_get_error);
        add_async_test("XEP0272_codec_provider_check_error_propagates", test_codec_provider_check_error);
        add_async_test("XEP0272_empty_audio_is_required_unavailable", test_empty_audio_required);
        add_async_test("XEP0272_empty_video_downgrades_to_optional_unavailable", test_empty_video_optional);
        add_async_test("XEP0272_payload_map_filters_unsupported_primary_and_its_RTX_atomically", test_payload_map_filters_unsupported_rtx_pair);
        add_async_test("XEP0272_duplicate_payload_ids_fail_closed_before_presence", test_duplicate_payload_ids_fail_closed);
        add_async_test("RFC4588_RTX_without_apt_fails_closed_before_presence", test_rtx_without_apt_fails_closed);
        add_test("XEP0272_late_ready_malformed_full_payload_map_fails_closed", test_late_ready_malformed_full_payload_map_fails_closed);
        add_test("XEP0272_late_ready_uses_frozen_payload_map_synchronously", test_late_ready_uses_frozen_payload_map_synchronously);
        add_async_test("XEP0272_late_join_video_downgrade_is_sticky_and_media_scoped", test_late_join_video_downgrade);
        add_test("XEP0272_preparing_peer_is_excluded_from_codec_intersection", test_preparing_peer_excluded);
        add_async_test("XEP0272_ready_peer_missing_expected_content_is_unavailable", test_ready_peer_missing_expected_content);
        add_test("XEP0272_membership_change_invalidates_all_codec_snapshots", test_membership_change_invalidates_all_codec_snapshots);
        add_test("XEP0272_initial_muji_snapshot_tracks_before_any_await", test_initial_muji_snapshot_tracks_before_any_await);
        add_test("XEP0272_available_presence_without_muji_removes_participant", test_available_presence_without_muji_removes_participant);
    }

    // ===================== XEP-0272 Namespace =====================

    /**
     * XEP-0272 S2: The namespace MUST be "urn:xmpp:jingle:muji:0".
     */
    private void test_ns_uri() {
        fail_if_not_eq_str(Xep.Muji.NS_URI, "urn:xmpp:jingle:muji:0",
            "XEP-0272 S2: MUJI namespace MUST be 'urn:xmpp:jingle:muji:0'");
    }

    /**
     * XEP-0482 S2: Call Invites namespace MUST be "urn:xmpp:call-invites:0".
     */
    private void test_call_invites_ns() {
        fail_if_not_eq_str(Xep.CallInvites.NS_URI, "urn:xmpp:call-invites:0",
            "XEP-0482 S2: Call Invites namespace MUST be 'urn:xmpp:call-invites:0'");
    }

    // ===================== XEP-0272 S3: Preparing Presence =====================

    /**
     * XEP-0272 S3: A participant joining sends presence with
     * <muji xmlns='urn:xmpp:jingle:muji:0'><preparing/></muji>
     * Parse via StanzaReader to verify structure.
     */
    private void test_preparing_presence_parse(Gee.TestFinishedCallback cb) {
        string xml = "<presence xmlns='jabber:client' from='call@conference.example.com/abc123' to='user@example.com'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0'><preparing/></muji>"
            + "</presence>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? muji = node.get_subnode("muji", Xep.Muji.NS_URI);
            fail_if(muji == null, "XEP-0272 S3: <muji> element MUST be present in preparing presence");
            if (muji != null) {
                StanzaNode? preparing = muji.get_subnode("preparing", Xep.Muji.NS_URI);
                fail_if(preparing == null, "XEP-0272 S3: <preparing/> MUST be child of <muji> during negotiation");
            }
            cb();
        });
    }

    /**
     * XEP-0272 S3: After negotiation, participant sends MUJI presence with
     * <content> elements containing <description> with payload-types.
     * The <preparing/> element MUST be absent.
     */
    private void test_ready_presence_parse(Gee.TestFinishedCallback cb) {
        string xml = "<presence xmlns='jabber:client' from='call@conference.example.com/peer1'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0'>"
            + "<content xmlns='urn:xmpp:jingle:muji:0' creator='initiator' name='audio'>"
            + "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>"
            + "<payload-type xmlns='urn:xmpp:jingle:apps:rtp:1' id='111' name='opus' clockrate='48000' channels='2'/>"
            + "</description>"
            + "</content>"
            + "</muji>"
            + "</presence>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? muji = node.get_subnode("muji", Xep.Muji.NS_URI);
            fail_if(muji == null, "XEP-0272 S3: <muji> MUST be present in ready presence");
            if (muji != null) {
                StanzaNode? preparing = muji.get_subnode("preparing", Xep.Muji.NS_URI);
                fail_if(preparing != null, "XEP-0272 S3: <preparing/> MUST be absent in ready presence");

                Gee.List<StanzaNode> contents = muji.get_subnodes(
                    "content", Xep.Muji.NS_URI);
                fail_if(contents.is_empty, "XEP-0272 S5: Ready presence MUST have at least one <content>");

                if (!contents.is_empty) {
                    fail_if_not_eq_str(
                        contents[0].get_attribute("creator"), "initiator",
                        "XEP-0272/XEP-0166: MUJI <content> MUST identify its creator");
                    StanzaNode? desc = contents[0].get_subnode("description", Xep.JingleRtp.NS_URI);
                    fail_if(desc == null, "XEP-0272 S5: <content> MUST contain <description>");
                    if (desc != null) {
                        fail_if_not_eq_str(desc.get_attribute("media"), "audio",
                            "XEP-0272 S5: description media attribute MUST match content name");
                    }
                }
            }
            cb();
        });
    }

    /**
     * XEP-0272 0.2.0 S3: <content> inherits the MUJI namespace. A Jingle
     * <content> child belongs to a different protocol context and must not be
     * interpreted as a MUJI codec advertisement.
     */
    private void test_jingle_namespace_content_rejected() {
        try {
            var presence = new Presence.Stanza();
            presence.from = new Jid(
                "call@conference.example.com/wrong-content-namespace");
            var description = new StanzaNode.build(
                "description", Xep.JingleRtp.NS_URI)
                .add_self_xmlns()
                .put_attribute("media", "audio")
                .put_node(AuditMujiCodecProvider.make_payload("audio").to_xml()
                    .add_self_xmlns());
            presence.stanza.put_node(new StanzaNode.build(
                    "muji", Xep.Muji.NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build(
                        "content", Xep.Jingle.NS_URI).add_self_xmlns()
                    .put_attribute("name", "audio")
                    .put_node(description)));

            var presences = new ArrayList<Presence.Stanza>();
            presences.add(presence);
            Gee.List<Xep.JingleRtp.PayloadType> payloads =
                Xep.Muji.Module.payload_intersection_for_ready_presences(
                    "audio", presences);
            fail_if(!payloads.is_empty,
                "XEP-0272: Jingle-namespace <content> MUST not be parsed as MUJI content");
        } catch (Error e) {
            fail_if_reached(@"Unexpected MUJI namespace test error: $(e.message)");
        }
    }

    /**
     * XEP-0272: Presence stanza without <muji> node must be ignored.
     */
    private void test_presence_no_muji_node(Gee.TestFinishedCallback cb) {
        string xml = "<presence xmlns='jabber:client' from='call@conference.example.com/nick1'>"
            + "<x xmlns='http://jabber.org/protocol/muc#user'/>"
            + "</presence>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? muji = node.get_subnode("muji", Xep.Muji.NS_URI);
            fail_if(muji != null, "XEP-0272: Non-MUJI presence MUST NOT have <muji> node");
            cb();
        });
    }

    /**
     * XEP-0272 S3: <preparing/> MUST be an empty element (no children, no text).
     */
    private void test_preparing_is_empty(Gee.TestFinishedCallback cb) {
        string xml = "<presence xmlns='jabber:client' from='call@conference.example.com/nick1'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0'><preparing/></muji>"
            + "</presence>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? preparing = node.get_deep_subnode(
                Xep.Muji.NS_URI + ":muji", Xep.Muji.NS_URI + ":preparing");
            fail_if(preparing == null, "XEP-0272 S3: <preparing/> MUST be parseable");
            if (preparing != null) {
                fail_if(!preparing.sub_nodes.is_empty,
                    "XEP-0272 S3: <preparing/> MUST be an empty element (no children)");
            }
            cb();
        });
    }

    private void test_preparing_generation_wire_parse(
            Gee.TestFinishedCallback cb) {
        string xml = "<presence xmlns='jabber:client' "
            + "from='call@conference.example.com/nick1'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0'>"
            + "<preparing/>"
            + "<generation xmlns='urn:dinox:muji:liveness:0' "
            + "id='current-generation'/>"
            + "</muji></presence>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? muji = ((!) node).get_subnode(
                "muji", Xep.Muji.NS_URI);
            StanzaNode? preparing = muji != null
                ? ((!) muji).get_subnode("preparing", Xep.Muji.NS_URI)
                : null;
            StanzaNode? generation = muji != null
                ? ((!) muji).get_subnode(
                    "generation", Xep.Muji.LIVENESS_NS_URI)
                : null;
            fail_if(preparing == null ||
                    !((!) preparing).sub_nodes.is_empty,
                "The MUJI preparing element must remain empty");
            fail_if(generation == null ||
                    ((!) generation).get_attribute("id") !=
                        "current-generation",
                "The liveness generation must retain its namespace and id");
            cb();
        });
    }

    private void test_existing_room_reuses_occupancy(
            Gee.TestFinishedCallback cb) {
        test_existing_room_reuses_occupancy_async.begin((obj, result) => {
            try {
                test_existing_room_reuses_occupancy_async.end(result);
            } catch (Error e) {
                fail_if_reached("Unexpected existing-room MUJI error: %s"
                    .printf(e.message));
            }
            cb();
        });
    }

    private async void test_existing_room_reuses_occupancy_async()
            throws Error {
        string room = "private@conference.example.test";
        string nick = "existing-nick";
        Xep.Muc.Flag muc_flag;
        Xep.Muji.Module muji;
        MujiExistingRoomAuditStream stream =
            create_existing_room_audit_stream(room, nick,
                out muc_flag, out muji);

        Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
            new Jid(room), false, new AuditMujiCodecProvider());
        fail_if(joined == null,
            "An existing private MUC must accept a MUJI presence update");
        if (joined == null) return;

        fail_if(!((!) joined).reuses_muc_occupancy ||
                ((!) joined).our_nick != nick,
            "Existing-room MUJI must preserve the current occupant nick");
        fail_if(stream.muc_enter_presence_count != 0 ||
                stream.preparing_presence_count != 1,
            "Existing-room MUJI must publish preparing without a second MUC enter");
        fail_if(!stream.correct_echo_sent,
            "Only the current own MUJI generation may release the join");

        ((!) joined).leave(stream);
        fail_if(stream.unavailable_presence_count != 0 ||
                stream.muji_cleanup_presence_count != 1,
            "Leaving borrowed MUJI occupancy must remove MUJI without leaving the MUC");
        fail_if(muc_flag.get_muc_nick(new Jid(room)) != nick,
            "Leaving borrowed MUJI occupancy must preserve MUC state");
    }

    private void emit_ready_echo(MujiExistingRoomAuditStream stream,
            string from, string? id, string? generation, bool preparing = false) {
        StanzaNode sent = last_written_presence(stream);
        var muji = new StanzaNode.build("muji", Xep.Muji.NS_URI).add_self_xmlns();
        StanzaNode? original = sent.get_subnode("muji", Xep.Muji.NS_URI);
        if (original != null) {
            foreach (StanzaNode content in ((!) original).get_subnodes("content", Xep.Muji.NS_URI)) {
                muji.put_node(content);
            }
        }
        if (generation != null) {
            muji.put_node(new StanzaNode.build("generation", Xep.Muji.LIVENESS_NS_URI)
                .add_self_xmlns().put_attribute("id", (!) generation));
        }
        if (preparing) muji.put_node(new StanzaNode.build("preparing", Xep.Muji.NS_URI));
        var echo = new StanzaNode.build("presence").put_attribute("from", from).put_node(muji);
        if (id != null) echo.put_attribute("id", (!) id);
        stream.received_presence_stanza(stream, echo);
    }

    private string? ready_generation(MujiExistingRoomAuditStream stream) {
        StanzaNode? generation = last_written_presence(stream).get_deep_subnode(
            Xep.Muji.NS_URI + ":muji", Xep.Muji.LIVENESS_NS_URI + ":generation");
        return generation != null ? ((!) generation).get_attribute("id") : null;
    }

    private async void test_ready_echo_scope_async(Gee.TestFinishedCallback cb) {
        try {
            for (int mode = 0; mode < 3; mode++) {
                string room = "ready-echo@conference.example.test";
                Xep.Muc.Flag muc;
                Xep.Muji.Module muji;
                var stream = create_existing_room_audit_stream(room, "alice", out muc, out muji);
                Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
                    new Jid(room), false, new AuditMujiCodecProvider());
                fail_if(joined == null, "Publishing READY must not wait for its own echo");
                if (joined == null) break;
                Xep.Muji.GroupCall group = (!) joined;
                string? id = last_written_presence(stream).get_attribute("id");
                string? generation = ready_generation(stream);
                fail_if(generation == null, "READY must correlate the current call generation");
                var completed = new Promise<bool>();
                group.wait_for_own_ready.begin((obj, result) => {
                    completed.set_value(group.wait_for_own_ready.end(result));
                });
                emit_ready_echo(stream, "other@conference.example.test/alice", id, generation);
                emit_ready_echo(stream, room + "/alice", id, "stale-generation");
                emit_ready_echo(stream, room + "/alice", "wrong-id", null);
                emit_ready_echo(stream, room + "/alice", id, generation, true);
                fail_if(group.outgoing_connections_ready || completed.future.ready,
                    "Another room, stale READY or PREPARING must not release outgoing legs");
                emit_ready_echo(stream, room + "/alice",
                    mode == 0 ? "server-rewritten-id" : mode == 1 ? null : id,
                    mode == 2 ? null : generation);
                bool allowed = yield completed.future.wait_async();
                fail_if(!allowed || !group.outgoing_connections_ready,
                    "Current READY must accept rewritten/idless ids or exact legacy id");
                group.leave(stream);
                fail_if(yield group.wait_for_own_ready(), "Leaving must revoke outgoing readiness");
            }
        } catch (Error e) { fail_if_reached(e.message); }
        cb();
    }

    private async void test_ready_incoming_async(Gee.TestFinishedCallback cb) {
        try {
            string room = "ready-incoming@conference.example.test";
            Xep.Muc.Flag muc;
            Xep.Muji.Module muji;
            var stream = create_existing_room_audit_stream(room, "alice", out muc, out muji);
            Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
                new Jid(room), false, new AuditMujiCodecProvider());
            fail_if(joined == null, "The group must be available before its READY echo");
            if (joined != null) {
                Xep.Muji.GroupCall group = (!) joined;
                var peer = new Jid("bob@example.test/phone");
                var selections = new HashMap<string, Xep.Muji.CodecSelection>();
                selections["audio"] = yield Xep.Muji.CodecNegotiation.select(
                    new AuditMujiCodecProvider(), "audio");
                int admitted = 0;
                group.peer_joined.connect((jid) => {
                    if (jid.equals(peer) && !group.peer_should_initiate_outgoing(jid)) admitted++;
                });
                group.complete_ready_peer(new Jid(room + "/bob"), peer, selections, false);
                fail_if(admitted != 1 || !group.has_muji_participant(new Jid(room + "/bob")),
                    "An incoming peer must be exposed before our READY echo");
                fail_if(group.outgoing_connections_ready,
                    "Admitting an incoming participant must not release our outgoing gate");
                group.leave(stream);
            }
        } catch (Error e) { fail_if_reached(e.message); }
        cb();
    }

    private async void test_ready_cancellation_async(Gee.TestFinishedCallback cb) {
        try {
            string room = "ready-cancel@conference.example.test";
            Xep.Muc.Flag muc;
            Xep.Muji.Module muji;
            var stream = create_existing_room_audit_stream(room, "alice", out muc, out muji);
            var cancellable = new Cancellable();
            Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
                new Jid(room), false, new AuditMujiCodecProvider(), null, null, null, cancellable);
            fail_if(joined == null, "The call must reach READY before cancellation");
            if (joined != null) {
                Xep.Muji.GroupCall group = (!) joined;
                string? id = last_written_presence(stream).get_attribute("id");
                string? generation = ready_generation(stream);
                Idle.add(() => { cancellable.cancel(); return Source.REMOVE; });
                int64 started = GLib.get_monotonic_time();
                bool allowed = yield group.wait_for_own_ready();
                fail_if(allowed || !group.left || GLib.get_monotonic_time() - started >= 1000000,
                    "Cancelling must release the wait immediately without starting a leg");
                emit_ready_echo(stream, room + "/alice", id, generation);
                fail_if(group.outgoing_connections_ready, "A delayed echo must not revive the call");
            }
        } catch (Error e) { fail_if_reached(e.message); }
        cb();
    }

    private async void test_ready_timeout_async(Gee.TestFinishedCallback cb, bool replace) {
        try {
            string room = "ready-timeout@conference.example.test";
            Xep.Muc.Flag muc;
            Xep.Muji.Module muji;
            var stream = create_existing_room_audit_stream(room, "alice", out muc, out muji);
            Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
                new Jid(room), false, new AuditMujiCodecProvider());
            fail_if(joined == null, "The call must reach READY before timeout");
            if (joined != null) {
                Xep.Muji.GroupCall group = (!) joined;
                Xep.Muji.GroupCall? successor = null;
                if (replace) {
                    successor = new Xep.Muji.GroupCall(new Jid(room), new AuditMujiCodecProvider());
                    successor.our_nick = "alice";
                    stream.get_flag(Xep.Muji.Flag.IDENTITY).calls[new Jid(room)] = successor;
                }
                int64 started = GLib.get_monotonic_time();
                bool allowed = yield group.wait_for_own_ready();
                int64 elapsed = GLib.get_monotonic_time() - started;
                fail_if(allowed == replace || elapsed < 4800000 || elapsed > 8000000,
                    "Five-second fallback must release only the current, live room call");
                group.leave(stream);
                if (successor != null) {
                    fail_if(stream.get_flag(Xep.Muji.Flag.IDENTITY).calls.get(new Jid(room)) != successor,
                        "Stale teardown must preserve the successor");
                    successor.leave(stream);
                }
            }
        } catch (Error e) { fail_if_reached(e.message); }
        cb();
    }

    private MujiExistingRoomAuditStream create_existing_room_audit_stream(
            string room, string nick, out Xep.Muc.Flag muc_flag,
            out Xep.Muji.Module muji) throws Error {
        var stream = new MujiExistingRoomAuditStream(
            new Jid("example.test"));
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = new Jid("alice@example.test/dinox");
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var presence = new Presence.Module();
        stream.add_module(presence);
        presence.attach(stream);

        var muc = new Xep.Muc.Module();
        stream.add_module(muc);

        muc_flag = new Xep.Muc.Flag();
        muc_flag.set_muc_nick(new Jid(room + "/" + nick));
        stream.add_flag(muc_flag);

        muji = new Xep.Muji.Module();
        stream.add_module(muji);
        muji.attach(stream);
        return stream;
    }

    private async Xep.Muji.GroupCall? join_presence_replay_call(
            MujiExistingRoomAuditStream stream, Xep.Muji.Module muji,
            string room, bool video = true) throws Error {
        var provider = new AuditMujiCodecProvider() {
            video_available = video
        };
        var names = new HashMap<string, string>();
        var payloads = new HashMap<string,
            Gee.List<Xep.JingleRtp.PayloadType>>();
        foreach (string media in video
                ? new string[] { "audio", "video" }
                : new string[] { "audio" }) {
            names[media] = media == "audio" ? "conference voice" : "camera";
            var selected = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            var payload = AuditMujiCodecProvider.make_payload(media);
            payload.id = media == "audio" ? 109 : 98;
            selected.add(payload);
            payloads[media] = selected;
        }
        return yield muji.join_call(stream, new Jid(room), video,
            provider, names, payloads);
    }

    private StanzaNode last_written_presence(
            MujiExistingRoomAuditStream stream) {
        return stream.written_presences[stream.written_presences.size - 1];
    }

    private string written_muji_xml(StanzaNode presence) throws Error {
        StanzaNode? muji = presence.get_subnode("muji", Xep.Muji.NS_URI);
        fail_if(muji == null, "An active own presence must retain MUJI");
        return muji != null ? ((!) muji).to_xml() : "";
    }

    private void test_ready_presence_survives_occupant_resync(
            Gee.TestFinishedCallback cb) {
        test_ready_presence_survives_occupant_resync_async.begin(cb);
    }

    private async void test_ready_presence_survives_occupant_resync_async(
            Gee.TestFinishedCallback cb) {
        try {
            string room = "ready-resync@conference.example.test";
            Xep.Muc.Flag muc_flag;
            Xep.Muji.Module muji;
            MujiExistingRoomAuditStream stream =
                create_existing_room_audit_stream(room, "existing-nick",
                    out muc_flag, out muji);
            Xep.Muji.GroupCall? joined =
                yield join_presence_replay_call(stream, muji, room);
            fail_if(joined == null, "The audio/video MUJI join must succeed");
            if (joined != null) {
                StanzaNode ready = last_written_presence(stream);
                string expected = written_muji_xml(ready);
                StanzaNode? ready_muji = ready.get_subnode(
                    "muji", Xep.Muji.NS_URI);
                fail_if(ready_muji == null ||
                        ((!) ready_muji).get_subnodes("content",
                            Xep.Muji.NS_URI).size != 2,
                    "Ready must advertise both negotiated media");
                if (ready_muji != null) {
                    foreach (StanzaNode content in ((!) ready_muji)
                            .get_subnodes("content", Xep.Muji.NS_URI)) {
                        StanzaNode description = (!) content.get_subnode(
                            "description", Xep.JingleRtp.NS_URI);
                        bool audio = description.get_attribute("media") == "audio";
                        fail_if_not_eq_str(content.get_attribute("name"),
                            audio ? "conference voice" : "camera",
                            "Ready must keep the selected conference content name");
                        StanzaNode payload = (!) description.get_subnode(
                            "payload-type", Xep.JingleRtp.NS_URI);
                        fail_if_not_eq_uint(payload.get_attribute_uint("id"),
                            (uint) (audio ? 109 : 98),
                            "Ready must keep the selected conference payload ID");
                    }
                }
                var muc = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
                fail_if(!muc.request_occupant_presence_resync(stream, new Jid(room)),
                    "An occupied room must accept the real occupant resync");
                StanzaNode replay = last_written_presence(stream);
                fail_if_not_eq_str(written_muji_xml(replay), expected,
                    "Occupant resync must preserve the complete ready MUJI payload");
                StanzaNode? history = replay.get_deep_subnode(
                    "http://jabber.org/protocol/muc:x",
                    "http://jabber.org/protocol/muc:history");
                fail_if(history == null ||
                        ((!) history).get_attribute("maxchars") != "0",
                    "MUJI preservation must keep the MUC resync history request");
                ((!) joined).leave(stream);
            }
        } catch (Error e) {
            fail_if_reached("Unexpected ready resync error: %s".printf(e.message));
        }
        cb();
    }

    private void test_status_presence_preserves_muji_without_aliasing(
            Gee.TestFinishedCallback cb) {
        test_status_presence_preserves_muji_without_aliasing_async.begin(cb);
    }

    private async void test_status_presence_preserves_muji_without_aliasing_async(
            Gee.TestFinishedCallback cb) {
        try {
            string room = "status-resync@conference.example.test";
            Xep.Muc.Flag muc_flag;
            Xep.Muji.Module muji;
            MujiExistingRoomAuditStream stream =
                create_existing_room_audit_stream(room, "existing-nick",
                    out muc_flag, out muji);
            Xep.Muji.GroupCall? joined =
                yield join_presence_replay_call(stream, muji, room);
            fail_if(joined == null, "The status-preservation join must succeed");
            if (joined != null) {
                StanzaNode ready = last_written_presence(stream);
                string expected = written_muji_xml(ready);
                StanzaNode ready_muji = (!) ready.get_subnode("muji", Xep.Muji.NS_URI);
                ready_muji.get_subnodes("content", Xep.Muji.NS_URI)[0]
                    .set_attribute("name", "changed-after-write");
                var presence = new Presence.Stanza() {
                    to = new Jid(room + "/existing-nick"),
                    status = "Still in the group call", show = Presence.Stanza.SHOW_AWAY,
                    priority = 7
                };
                var avatar = new StanzaNode.build("x", "vcard-temp:x:update")
                    .add_self_xmlns().put_node(new StanzaNode.build(
                        "photo", "vcard-temp:x:update").put_node(
                            new StanzaNode.text("avatar-hash")));
                presence.stanza.put_node(avatar);
                yield stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                    .send_presence_async(stream, presence);
                StanzaNode sent = last_written_presence(stream);
                fail_if_not_eq_str(written_muji_xml(sent), expected,
                    "Changing a sent node must not mutate the remembered MUJI payload");
                fail_if(presence.status != "Still in the group call" ||
                        presence.show != Presence.Stanza.SHOW_AWAY || presence.priority != 7 ||
                        sent.get_subnode("x", "vcard-temp:x:update") != avatar,
                    "MUJI replay must preserve status, show, priority and avatar data");
                StanzaNode? replayed = sent.get_subnode("muji", Xep.Muji.NS_URI);
                if (replayed != null) ((!) replayed).sub_nodes.clear();
                fail_if(!stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(stream, new Jid(room)),
                    "The second presence update must use the real resync path");
                fail_if_not_eq_str(written_muji_xml(last_written_presence(stream)), expected,
                    "Every injected MUJI payload must be an independent copy");
                ((!) joined).leave(stream);
            }
        } catch (Error e) {
            fail_if_reached("Unexpected status replay error: %s".printf(e.message));
        }
        cb();
    }

    private void test_preparing_presence_survives_occupant_resync(
            Gee.TestFinishedCallback cb) {
        test_preparing_presence_survives_occupant_resync_async.begin(cb);
    }

    private async void test_preparing_presence_survives_occupant_resync_async(
            Gee.TestFinishedCallback cb) {
        try {
            string room = "preparing-resync@conference.example.test";
            Xep.Muc.Flag muc_flag;
            Xep.Muji.Module muji;
            MujiExistingRoomAuditStream stream =
                create_existing_room_audit_stream(room, "existing-nick",
                    out muc_flag, out muji);
            var presence = stream.get_module<Presence.Module>(Presence.Module.IDENTITY);
            var room_jid = new Jid(room);
            bool resync_requested = false;
            ulong handler = presence.pre_send_presence_stanza.connect((_, stanza) => {
                StanzaNode? preparing = stanza.stanza.get_deep_subnode(
                    Xep.Muji.NS_URI + ":muji", Xep.Muji.NS_URI + ":preparing");
                if (preparing == null || resync_requested) return;
                resync_requested = true;
                fail_if(!stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(stream, room_jid),
                    "Preparing must survive a concurrent real occupant resync");
            });
            Xep.Muji.GroupCall? joined = yield join_presence_replay_call(stream, muji, room);
            presence.disconnect(handler);
            fail_if(joined == null || !resync_requested,
                "Preparing resync must not prevent the own-echo join barrier");
            fail_if(stream.preparing_presence_count != 2,
                "Original preparing and occupant resync must both retain preparing");
            string? expected = null;
            foreach (StanzaNode written in stream.written_presences) {
                if (written.get_deep_subnode(Xep.Muji.NS_URI + ":muji",
                        Xep.Muji.NS_URI + ":preparing") == null) continue;
                string actual = written_muji_xml(written);
                if (expected == null) expected = actual;
                else fail_if_not_eq_str(actual, expected,
                    "Preparing resync must retain the original generation and payload");
            }
            if (joined != null) ((!) joined).leave(stream);
        } catch (Error e) {
            fail_if_reached("Unexpected preparing resync error: %s".printf(e.message));
        }
        cb();
    }

    private void test_presence_replay_scope_and_leave(Gee.TestFinishedCallback cb) {
        test_presence_replay_scope_and_leave_async.begin(cb);
    }

    private async void test_presence_replay_scope_and_leave_async(
            Gee.TestFinishedCallback cb) {
        try {
            string room = "scope-resync@conference.example.test";
            Xep.Muc.Flag muc_flag;
            Xep.Muji.Module muji;
            MujiExistingRoomAuditStream stream =
                create_existing_room_audit_stream(room, "existing-nick",
                    out muc_flag, out muji);
            Xep.Muji.GroupCall? joined = yield join_presence_replay_call(stream, muji, room);
            fail_if(joined == null, "The scope-test join must succeed");
            if (joined != null) {
                string expected = written_muji_xml(last_written_presence(stream));
                var presence_module = stream.get_module<Presence.Module>(Presence.Module.IDENTITY);
                foreach (string target in new string[] {
                        "unrelated@conference.example.test/existing-nick",
                        room + "/other-nick", room, "" }) {
                    var presence = new Presence.Stanza();
                    if (target != "") presence.to = new Jid(target);
                    yield presence_module.send_presence_async(stream, presence);
                    fail_if(last_written_presence(stream).get_subnode("muji", Xep.Muji.NS_URI) != null,
                        "Only the exact own occupant target may receive cached MUJI");
                }
                foreach (string type in new string[] {
                        Presence.Stanza.TYPE_UNAVAILABLE, Presence.Stanza.TYPE_PROBE,
                        Presence.Stanza.TYPE_SUBSCRIBE }) {
                    var presence = new Presence.Stanza() {
                        to = new Jid(room + "/existing-nick"), type_ = type
                    };
                    yield presence_module.send_presence_async(stream, presence);
                    fail_if(last_written_presence(stream).get_subnode("muji", Xep.Muji.NS_URI) != null,
                        "Unavailable and subscription traffic must not advertise MUJI");
                }
                fail_if(!stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(stream, new Jid(room)),
                    "Excluded presence targets and types must not clear the active call");
                fail_if_not_eq_str(written_muji_xml(last_written_presence(stream)), expected,
                    "Excluded presence traffic must not overwrite the active MUJI payload");
                ((!) joined).leave(stream);
                fail_if(last_written_presence(stream).get_subnode("muji", Xep.Muji.NS_URI) != null,
                    "Borrowed-room leave must withdraw MUJI immediately");
                var normal = new Presence.Stanza() { to = new Jid(room + "/existing-nick") };
                yield presence_module.send_presence_async(stream, normal);
                fail_if(last_written_presence(stream).get_subnode("muji", Xep.Muji.NS_URI) != null,
                    "Normal presence after leave must not resurrect MUJI");
                fail_if(!stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(stream, new Jid(room)),
                    "Leave must retain the borrowed room occupancy for resync");
                fail_if(last_written_presence(stream).get_subnode("muji", Xep.Muji.NS_URI) != null ||
                        muc_flag.get_muc_nick(new Jid(room)) != "existing-nick",
                    "Resync after leave must preserve the room without resurrecting MUJI");
            }
        } catch (Error e) {
            fail_if_reached("Unexpected replay scope error: %s".printf(e.message));
        }
        cb();
    }

    private void test_presence_replay_is_stream_scoped(Gee.TestFinishedCallback cb) {
        test_presence_replay_is_stream_scoped_async.begin(cb);
    }

    private async void test_presence_replay_is_stream_scoped_async(
            Gee.TestFinishedCallback cb) {
        try {
            string room = "stream-resync@conference.example.test";
            Xep.Muc.Flag first_muc_flag;
            Xep.Muji.Module first_muji;
            MujiExistingRoomAuditStream first = create_existing_room_audit_stream(
                room, "shared-nick", out first_muc_flag, out first_muji);
            Xep.Muji.GroupCall? first_call =
                yield join_presence_replay_call(first, first_muji, room);
            fail_if(first_call == null, "The first account call must become ready");
            if (first_call != null) {
                string first_payload = written_muji_xml(last_written_presence(first));
                Xep.Muc.Flag fresh_muc_flag;
                Xep.Muji.Module fresh_muji;
                MujiExistingRoomAuditStream fresh = create_existing_room_audit_stream(
                    room, "shared-nick", out fresh_muc_flag, out fresh_muji);
                fail_if(!fresh.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(fresh, new Jid(room)),
                    "The fresh stream must resync its own room occupancy");
                fail_if(last_written_presence(fresh).get_subnode("muji", Xep.Muji.NS_URI) != null,
                    "A fresh stream of the same account must not inherit another stream's active call");
                Xep.Muc.Flag second_muc_flag;
                Xep.Muji.Module second_muji;
                MujiExistingRoomAuditStream second = create_existing_room_audit_stream(
                    room, "shared-nick", out second_muc_flag, out second_muji);
                second.get_flag(Bind.Flag.IDENTITY).my_jid = new Jid("bob@example.test/phone");
                fail_if(!second.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(second, new Jid(room)),
                    "The other account must resync its own room occupancy");
                fail_if(last_written_presence(second).get_subnode("muji", Xep.Muji.NS_URI) != null,
                    "Another account with the same room and nick must not inherit MUJI");
                Xep.Muji.GroupCall? second_call =
                    yield join_presence_replay_call(second, second_muji, room, false);
                fail_if(second_call == null, "The second account call must become ready");
                if (second_call != null) {
                    string second_payload = written_muji_xml(last_written_presence(second));
                    fail_if(first_payload == second_payload,
                        "The fixtures must advertise different audio/video conference payloads");
                    first.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(first, new Jid(room));
                    fail_if_not_eq_str(written_muji_xml(last_written_presence(first)), first_payload,
                        "Another account's ready payload must not replace this stream's payload");
                    ((!) first_call).leave(first);
                    second.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                        .request_occupant_presence_resync(second, new Jid(room));
                    fail_if_not_eq_str(written_muji_xml(last_written_presence(second)), second_payload,
                        "Leaving one account must not clear another account's MUJI payload");
                    ((!) second_call).leave(second);
                }
                ((!) first_call).leave(first);
            }
        } catch (Error e) {
            fail_if_reached("Unexpected stream replay error: %s".printf(e.message));
        }
        cb();
    }

    private void test_stale_join_cannot_clear_successor(
            Gee.TestFinishedCallback cb) {
        test_stale_join_cannot_clear_successor_async.begin((obj, result) => {
            try {
                test_stale_join_cannot_clear_successor_async.end(result);
            } catch (Error e) {
                fail_if_reached("Unexpected MUJI ownership error: %s"
                    .printf(e.message));
            }
            cb();
        });
    }

    private async void test_stale_join_cannot_clear_successor_async()
            throws Error {
        string room = "ownership@conference.example.test";
        string nick = "existing-nick";
        Xep.Muc.Flag muc_flag;
        Xep.Muji.Module muji;
        MujiExistingRoomAuditStream stream =
            create_existing_room_audit_stream(room, nick,
                out muc_flag, out muji);
        var provider = new AuditMujiCodecProvider();
        Xep.Muji.GroupCall? first = yield muji.join_call(stream,
            new Jid(room), false, provider);
        fail_if(first == null, "The first existing-room join must succeed");
        if (first == null) return;

        var successor = new Xep.Muji.GroupCall(
            new Jid(room), provider, false);
        successor.our_nick = nick;
        Xep.Muji.Flag muji_flag = stream.get_flag(Xep.Muji.Flag.IDENTITY);
        muji_flag.calls[new Jid(room)] = successor;
        int cleanup_before = stream.muji_cleanup_presence_count;

        ((!) first).leave(stream);
        fail_if(muji_flag.calls.get(new Jid(room)) != successor,
            "A stale GroupCall must not remove its successor");
        fail_if(stream.muji_cleanup_presence_count != cleanup_before ||
                stream.unavailable_presence_count != 0,
            "A stale GroupCall must not alter its successor's MUC presence");
    }

    private void test_existing_room_join_is_cancellable(
            Gee.TestFinishedCallback cb) {
        test_existing_room_join_is_cancellable_async.begin((obj, result) => {
            try {
                test_existing_room_join_is_cancellable_async.end(result);
            } catch (Error e) {
                fail_if_reached("Unexpected cancellable MUJI error: %s"
                    .printf(e.message));
            }
            cb();
        });
    }

    private async void test_existing_room_join_is_cancellable_async()
            throws Error {
        string room = "cancel@conference.example.test";
        string nick = "existing-nick";
        Xep.Muc.Flag muc_flag;
        Xep.Muji.Module muji;
        MujiExistingRoomAuditStream stream =
            create_existing_room_audit_stream(room, nick,
                out muc_flag, out muji);
        stream.suppress_correct_echo = true;
        var cancellable = new Cancellable();
        Timeout.add(20, () => {
            cancellable.cancel();
            return Source.REMOVE;
        });

        int64 started = GLib.get_monotonic_time();
        Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
            new Jid(room), false, new AuditMujiCodecProvider(),
            null, null, null, cancellable);
        int64 elapsed_ms = (GLib.get_monotonic_time() - started) / 1000;
        fail_if(joined != null || elapsed_ms >= 1000,
            "Cancelling a pending existing-room join must wake it immediately");
        Xep.Muji.Flag muji_flag = stream.get_flag(Xep.Muji.Flag.IDENTITY);
        fail_if(muji_flag.calls.get(new Jid(room)) != null,
            "A cancelled MUJI join must release only its own map entry");
        fail_if(stream.muji_cleanup_presence_count != 1 ||
                muc_flag.get_muc_nick(new Jid(room)) != nick,
            "Cancellation must withdraw MUJI but preserve the private MUC");
    }

    private void test_existing_room_accepts_idless_self_echo(
            Gee.TestFinishedCallback cb) {
        test_existing_room_accepts_idless_self_echo_async.begin(
            (obj, result) => {
                try {
                    test_existing_room_accepts_idless_self_echo_async.end(
                        result);
                } catch (Error e) {
                    fail_if_reached("Unexpected idless MUJI echo error: %s"
                        .printf(e.message));
                }
                cb();
            });
    }

    private async void test_existing_room_accepts_idless_self_echo_async()
            throws Error {
        string room = "idless@conference.example.test";
        string nick = "existing-nick";
        Xep.Muc.Flag muc_flag;
        Xep.Muji.Module muji;
        MujiExistingRoomAuditStream stream =
            create_existing_room_audit_stream(room, nick,
                out muc_flag, out muji);
        stream.omit_correct_echo_id = true;
        Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
            new Jid(room), false, new AuditMujiCodecProvider());
        fail_if(joined == null || !stream.correct_echo_sent,
            "A matching own MUJI generation may omit the reflected id");
        if (joined != null) ((!) joined).leave(stream);
    }

    private void test_existing_room_accepts_legacy_id_echo(
            Gee.TestFinishedCallback cb) {
        test_existing_room_accepts_legacy_id_echo_async.begin(
            (obj, result) => {
                try {
                    test_existing_room_accepts_legacy_id_echo_async.end(
                        result);
                } catch (Error e) {
                    fail_if_reached("Unexpected legacy MUJI echo error: %s"
                        .printf(e.message));
                }
                cb();
            });
    }

    private async void test_existing_room_accepts_legacy_id_echo_async()
            throws Error {
        string room = "legacy-echo@conference.example.test";
        string nick = "existing-nick";
        Xep.Muc.Flag muc_flag;
        Xep.Muji.Module muji;
        MujiExistingRoomAuditStream stream =
            create_existing_room_audit_stream(room, nick,
                out muc_flag, out muji);
        stream.omit_correct_echo_generation = true;
        Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
            new Jid(room), false, new AuditMujiCodecProvider());
        fail_if(joined == null || !stream.correct_echo_sent,
            "A legacy echo without generation requires the original stanza id");
        if (joined != null) ((!) joined).leave(stream);
    }

    private void test_disconnected_release_is_local_only(
            Gee.TestFinishedCallback cb) {
        test_disconnected_release_is_local_only_async.begin((obj, result) => {
            try {
                test_disconnected_release_is_local_only_async.end(result);
            } catch (Error e) {
                fail_if_reached("Unexpected disconnected MUJI release error: %s"
                    .printf(e.message));
            }
            cb();
        });
    }

    private async void test_disconnected_release_is_local_only_async()
            throws Error {
        string room = "disconnect@conference.example.test";
        string nick = "existing-nick";
        Xep.Muc.Flag muc_flag;
        Xep.Muji.Module muji;
        MujiExistingRoomAuditStream stream =
            create_existing_room_audit_stream(room, nick,
                out muc_flag, out muji);
        Xep.Muji.GroupCall? joined = yield muji.join_call(stream,
            new Jid(room), false, new AuditMujiCodecProvider());
        fail_if(joined == null,
            "The borrowed occupancy must publish before disconnect");
        if (joined == null) return;

        int cleanup_before = stream.muji_cleanup_presence_count;
        ((!) joined).leave(stream, false);
        Xep.Muji.Flag muji_flag = stream.get_flag(Xep.Muji.Flag.IDENTITY);
        fail_if(!((!) joined).left ||
                muji_flag.calls.get(new Jid(room)) != null,
            "Disconnect cleanup must release GroupCall and its owned map entry");
        fail_if(stream.muji_cleanup_presence_count != cleanup_before ||
                stream.unavailable_presence_count != 0,
            "Disconnect cleanup must not write to a dead stream");
        fail_if(muc_flag.get_muc_nick(new Jid(room)) != nick,
            "Disconnect cleanup must not mutate borrowed MUC occupancy state");
    }

    private void test_dedicated_room_uses_confirmed_nick_on_leave() {
        try {
            string room = "dedicated@conference.example.test";
            string requested_nick = "requested-nick";
            string confirmed_nick = "server-nick";
            Xep.Muc.Flag muc_flag;
            Xep.Muji.Module muji;
            MujiExistingRoomAuditStream stream =
                create_existing_room_audit_stream(room, confirmed_nick,
                    out muc_flag, out muji);
            var group_call = new Xep.Muji.GroupCall(new Jid(room),
                new AuditMujiCodecProvider(), false);
            group_call.our_nick = requested_nick;
            var result = new Xep.Muc.JoinResult() { nick=confirmed_nick };
            fail_if(!group_call.bind_confirmed_muc_occupancy(result) ||
                    group_call.our_nick != confirmed_nick,
                "Status 210 must bind teardown to the confirmed server nick");
            Xep.Muji.Flag muji_flag = stream.get_flag(
                Xep.Muji.Flag.IDENTITY);
            muji_flag.calls[new Jid(room)] = group_call;

            group_call.leave(stream);
            fail_if(stream.unavailable_presence_count != 1 ||
                    muc_flag.get_muc_nick(new Jid(room)) != null,
                "A dedicated MUJI room must leave the server-confirmed nick once");
            fail_if(muji_flag.calls.get(new Jid(room)) != null,
                "Dedicated-room leave must release its owned map entry");
        } catch (Error e) {
            fail_if_reached("Unexpected dedicated MUJI leave error: %s"
                .printf(e.message));
        }
    }

    // ===================== XEP-0272 S5: PayloadType Parsing =====================

    /**
     * XEP-0272 S5 / XEP-0167 S5: Opus payload-type in MUJI presence.
     * id=111, name=opus, clockrate=48000, channels=2
     */
    private void test_payload_type_opus(Gee.TestFinishedCallback cb) {
        string xml = "<payload-type xmlns='urn:xmpp:jingle:apps:rtp:1' id='111' name='opus' clockrate='48000' channels='2'/>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            Xep.JingleRtp.PayloadType pt = Xep.JingleRtp.PayloadType.parse(node);
            fail_if_not_eq_uint(pt.id, 111, "XEP-0167 S5: Opus payload ID MUST be 111");
            fail_if_not_eq_str(pt.name, "opus", "XEP-0167 S5: Opus payload name MUST be 'opus'");
            fail_if_not_eq_uint(pt.clockrate, 48000, "XEP-0167 S5: Opus clockrate MUST be 48000");
            fail_if_not_eq_uint(pt.channels, 2, "XEP-0167 S5: Opus channels MUST be 2");
            cb();
        });
    }

    /**
     * XEP-0272 S5 / XEP-0167: VP8 video payload-type.
     */
    private void test_payload_type_vp8(Gee.TestFinishedCallback cb) {
        string xml = "<payload-type xmlns='urn:xmpp:jingle:apps:rtp:1' id='96' name='VP8' clockrate='90000'/>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            Xep.JingleRtp.PayloadType pt = Xep.JingleRtp.PayloadType.parse(node);
            fail_if_not_eq_uint(pt.id, 96, "XEP-0167: VP8 dynamic payload ID");
            fail_if_not_eq_str(pt.name, "VP8", "XEP-0167: VP8 payload name");
            fail_if_not_eq_uint(pt.clockrate, 90000, "XEP-0167: VP8 clockrate MUST be 90000 (video)");
            fail_if_not_eq_uint(pt.channels, 1, "XEP-0167: VP8 channels defaults to 1");
            cb();
        });
    }

    /**
     * XEP-0272 S5: A description may contain multiple payload-types.
     * All must be parsed correctly.
     */
    private void test_multiple_payload_types(Gee.TestFinishedCallback cb) {
        string xml = "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>"
            + "<payload-type xmlns='urn:xmpp:jingle:apps:rtp:1' id='111' name='opus' clockrate='48000' channels='2'/>"
            + "<payload-type xmlns='urn:xmpp:jingle:apps:rtp:1' id='0' name='PCMU' clockrate='8000'/>"
            + "<payload-type xmlns='urn:xmpp:jingle:apps:rtp:1' id='8' name='PCMA' clockrate='8000'/>"
            + "</description>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            Gee.List<StanzaNode> payload_nodes = node.get_subnodes("payload-type", Xep.JingleRtp.NS_URI);
            fail_if_not_eq_int(payload_nodes.size, 3,
                "XEP-0272 S5: All payload-types in description MUST be parsed");

            if (payload_nodes.size >= 3) {
                Xep.JingleRtp.PayloadType pt0 = Xep.JingleRtp.PayloadType.parse(payload_nodes[0]);
                Xep.JingleRtp.PayloadType pt1 = Xep.JingleRtp.PayloadType.parse(payload_nodes[1]);
                Xep.JingleRtp.PayloadType pt2 = Xep.JingleRtp.PayloadType.parse(payload_nodes[2]);
                fail_if_not_eq_str(pt0.name, "opus", "First payload MUST be opus");
                fail_if_not_eq_str(pt1.name, "PCMU", "Second payload MUST be PCMU");
                fail_if_not_eq_str(pt2.name, "PCMA", "Third payload MUST be PCMA");
            }
            cb();
        });
    }

    /**
     * XEP-0167 S5: PayloadType may contain <parameter name='...' value='...'/>.
     */
    private void test_payload_type_parameters(Gee.TestFinishedCallback cb) {
        string xml = "<payload-type xmlns='urn:xmpp:jingle:apps:rtp:1' id='111' name='opus' clockrate='48000' channels='2'>"
            + "<parameter xmlns='urn:xmpp:jingle:apps:rtp:1' name='useinbandfec' value='1'/>"
            + "<parameter xmlns='urn:xmpp:jingle:apps:rtp:1' name='stereo' value='1'/>"
            + "</payload-type>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            Xep.JingleRtp.PayloadType pt = Xep.JingleRtp.PayloadType.parse(node);
            fail_if_not_eq_int(pt.parameters.size, 2,
                "XEP-0167 S5: Both parameters MUST be parsed");
            fail_if_not_eq_str(pt.parameters["useinbandfec"], "1",
                "XEP-0167 S5: useinbandfec parameter value MUST be '1'");
            fail_if_not_eq_str(pt.parameters["stereo"], "1",
                "XEP-0167 S5: stereo parameter value MUST be '1'");
            cb();
        });
    }

    // ===================== XEP-0167: PayloadType Equality =====================

    /**
     * XEP-0167: Two PayloadTypes with identical fields MUST be equal.
     */
    private void test_payload_equals_same() {
        var a = new Xep.JingleRtp.PayloadType();
        a.id = 111; a.name = "opus"; a.clockrate = 48000; a.channels = 2;
        var b = new Xep.JingleRtp.PayloadType();
        b.id = 111; b.name = "opus"; b.clockrate = 48000; b.channels = 2;
        fail_if(!Xep.JingleRtp.PayloadType.equals_func(a, b),
            "XEP-0167: Identical PayloadTypes MUST be equal");
    }

    /**
     * XEP-0167: PayloadTypes with different IDs MUST NOT be equal.
     */
    private void test_payload_equals_different_id() {
        var a = new Xep.JingleRtp.PayloadType();
        a.id = 111; a.name = "opus"; a.clockrate = 48000; a.channels = 2;
        var b = new Xep.JingleRtp.PayloadType();
        b.id = 112; b.name = "opus"; b.clockrate = 48000; b.channels = 2;
        fail_if(Xep.JingleRtp.PayloadType.equals_func(a, b),
            "XEP-0167: PayloadTypes with different ID MUST NOT be equal");
    }

    /**
     * XEP-0167: clone() MUST produce an equal PayloadType.
     */
    private void test_payload_clone_equal() {
        var a = new Xep.JingleRtp.PayloadType();
        a.id = 96; a.name = "VP8"; a.clockrate = 90000; a.channels = 1;
        a.parameters["profile-level-id"] = "42e01f";
        var b = a.clone();
        fail_if(!Xep.JingleRtp.PayloadType.equals_func(a, b),
            "XEP-0167: clone() MUST produce an equal PayloadType");
        // Verify parameters are independent copies
        b.parameters["new-param"] = "test";
        fail_if(a.parameters.has_key("new-param"),
            "XEP-0167: clone() parameters MUST be independent copy");
    }

    // ===================== XEP-0272: GroupCall Data Class =====================

    /**
     * XEP-0272: GroupCall stores the MUC JID.
     */
    private void test_groupcall_muc_jid() {
        try {
            Jid muc_jid = new Jid("abc123@conference.example.com");
            var gc = new Xep.Muji.GroupCall(muc_jid, new AuditMujiCodecProvider());
            fail_if(!gc.muc_jid.equals(muc_jid),
                "XEP-0272: GroupCall.muc_jid MUST match constructor argument");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0272: New GroupCall has no peers.
     */
    private void test_groupcall_peers_empty() {
        try {
            var gc = new Xep.Muji.GroupCall(
                new Jid("r@c.example.com"), new AuditMujiCodecProvider());
            fail_if(!gc.peers.is_empty,
                "XEP-0272: New GroupCall.peers MUST be empty");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0272: New GroupCall has no peers_to_connect_to.
     */
    private void test_groupcall_connect_empty() {
        try {
            var gc = new Xep.Muji.GroupCall(
                new Jid("r@c.example.com"), new AuditMujiCodecProvider());
            fail_if(!gc.peers_to_connect_to.is_empty,
                "XEP-0272: New GroupCall.peers_to_connect_to MUST be empty");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0272: peer_joined signal fires when connected externally.
     */
    private void test_groupcall_peer_joined_signal() {
        try {
            var gc = new Xep.Muji.GroupCall(
                new Jid("r@c.example.com"), new AuditMujiCodecProvider());
            Jid? received_jid = null;
            gc.peer_joined.connect((jid) => { received_jid = jid; });

            Jid test_jid = new Jid("alice@example.com/res");
            gc.peer_joined(test_jid);

            fail_if(received_jid == null,
                "XEP-0272: peer_joined signal MUST fire");
            fail_if(!received_jid.equals(test_jid),
                "XEP-0272: peer_joined signal MUST carry the correct JID");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0272: peer_left signal fires when connected externally.
     */
    private void test_groupcall_peer_left_signal() {
        try {
            var gc = new Xep.Muji.GroupCall(
                new Jid("r@c.example.com"), new AuditMujiCodecProvider());
            Jid? received_jid = null;
            gc.peer_left.connect((jid) => { received_jid = jid; });

            Jid test_jid = new Jid("bob@example.com/res");
            gc.peer_left(test_jid);

            fail_if(received_jid == null,
                "XEP-0272: peer_left signal MUST fire");
            fail_if(!received_jid.equals(test_jid),
                "XEP-0272: peer_left signal MUST carry the correct JID");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0272: codecs_changed signal fires with payload types.
     */
    private void test_groupcall_codecs_changed_signal() {
        try {
            var gc = new Xep.Muji.GroupCall(
                new Jid("r@c.example.com"), new AuditMujiCodecProvider());
            bool signal_fired = false;
            int received_count = 0;
            gc.codecs_changed.connect((pts) => {
                signal_fired = true;
                received_count = pts.size;
            });

            var pts = new ArrayList<Xep.JingleRtp.PayloadType>();
            var opus = new Xep.JingleRtp.PayloadType();
            opus.id = 111; opus.name = "opus";
            pts.add(opus);
            gc.codecs_changed(pts);

            fail_if(!signal_fired,
                "XEP-0272: codecs_changed signal MUST fire");
            fail_if_not_eq_int(received_count, 1,
                "XEP-0272: codecs_changed MUST carry 1 payload type");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    // ===================== XEP-0272: Flag =====================

    /**
     * XEP-0272: Flag namespace must match module namespace.
     */
    private void test_flag_ns() {
        var flag = new Xep.Muji.Flag();
        fail_if_not_eq_str(flag.get_ns(), Xep.Muji.NS_URI,
            "XEP-0272: Flag.get_ns() MUST return MUJI namespace");
    }

    /**
     * XEP-0272: New Flag has empty calls map.
     */
    private void test_flag_calls_empty() {
        var flag = new Xep.Muji.Flag();
        fail_if(!flag.calls.is_empty,
            "XEP-0272: New Flag.calls MUST be empty");
    }

    /**
     * XEP-0272: Flag.calls stores and retrieves GroupCall by MUC JID.
     */
    private void test_flag_calls_store() {
        try {
            var flag = new Xep.Muji.Flag();
            Jid muc_jid = new Jid("room@conference.example.com");
            var gc = new Xep.Muji.GroupCall(muc_jid, new AuditMujiCodecProvider());
            gc.our_nick = "testnick";
            flag.calls[muc_jid] = gc;

            fail_if(!flag.calls.has_key(muc_jid),
                "XEP-0272: Flag.calls MUST store GroupCall by MUC JID");
            fail_if_not_eq_str(flag.calls[muc_jid].our_nick, "testnick",
                "XEP-0272: Retrieved GroupCall MUST match stored one");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    // ===================== XEP-0272: Nick Format =====================

    /**
     * XEP-0272: MUJI nick is generated as %08x (8 hex chars).
     * Verify format by generating 20 samples.
     */
    private void test_nick_format() {
        for (int i = 0; i < 20; i++) {
            string nick = "%08x".printf(Random.next_int());
            fail_if(nick.length != 8,
                @"XEP-0272: Nick MUST be 8 chars, got $(nick.length): '$nick'");
            for (int j = 0; j < nick.length; j++) {
                char c = nick[j];
                bool valid = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                fail_if(!valid,
                    @"XEP-0272: Nick char at pos $j MUST be lowercase hex, got '$(c)' in '$nick'");
            }
        }
    }

    // ===================== XEP-0482: Call Invite Stanzas =====================

    /**
     * XEP-0482 S3: MUJI <invite> MUST contain <muji room='...'/>.
     */
    private void test_cim_muji_propose(Gee.TestFinishedCallback cb) {
        string xml = "<message xmlns='jabber:client' id='call-123' type='chat' to='bob@example.com'>"
            + "<invite xmlns='urn:xmpp:call-invites:0' video='true' multi='true'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0' room='abc@conference.example.com'/>"
            + "</invite>"
            + "</message>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? invite = node.get_subnode("invite", Xep.CallInvites.NS_URI);
            fail_if(invite == null, "XEP-0482: <invite> element MUST be present");
            if (invite != null) {
                StanzaNode? muji = invite.get_subnode("muji", Xep.Muji.NS_URI);
                fail_if(muji == null, "XEP-0482: <invite> MUST contain <muji> for group calls");
                if (muji != null) {
                    string? room = muji.get_attribute("room");
                    fail_if(room == null, "XEP-0482: <muji> MUST have 'room' attribute");
                    fail_if_not_eq_str(room, "abc@conference.example.com",
                        "XEP-0482: room attribute MUST contain the MUJI MUC JID");
                }
            }
            cb();
        });
    }

    /**
     * XEP-0482: The <muji> element inside <invite> MUST use the MUJI namespace.
     */
    private void test_cim_muji_ns(Gee.TestFinishedCallback cb) {
        string xml = "<message xmlns='jabber:client' id='c1'>"
            + "<invite xmlns='urn:xmpp:call-invites:0'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0' room='r@c.example.com'/>"
            + "</invite>"
            + "</message>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? muji = node.get_deep_subnode(
                Xep.CallInvites.NS_URI + ":invite",
                Xep.Muji.NS_URI + ":muji");
            fail_if(muji == null,
                "XEP-0482: <muji> inside <invite> MUST use namespace '" + Xep.Muji.NS_URI + "'");
            cb();
        });
    }

    /**
     * XEP-0482: the invite message is the call reference.  The standards
     * element has no id attribute; origin-id takes precedence over message@id.
     */
    private void test_cim_invite_call_id() {
        try {
            Jid inviter = new Jid("alice@example.com/phone");
            Jid invitee = new Jid("bob@example.com/laptop");
            StanzaNode method = new StanzaNode.build("muji", Xep.Muji.NS_URI)
                .add_self_xmlns().put_attribute("room", "r@c.example.com");
            StanzaNode legacy_method = new StanzaNode.build("muji",
                Xep.Muji.NS_URI).add_self_xmlns()
                .put_attribute("room", "r@c.example.com");
            MessageStanza outgoing = Xep.CallInvites.Module.build_propose_message(
                "unique-call-42", invitee, false, true,
                MessageStanza.TYPE_CHAT, method, legacy_method);
            StanzaNode? invite = outgoing.stanza.get_subnode("invite",
                Xep.CallInvites.NS_URI);
            fail_if(invite == null, "XEP-0482: <invite> MUST be present");
            if (invite != null) {
                fail_if(invite.get_attribute("id") != null,
                    "XEP-0482: standards <invite> MUST use the message reference, not invite@id");
            }
            fail_if_not_eq_str(outgoing.id, "unique-call-42",
                "XEP-0482: outgoing message@id MUST preserve the provisional reference");
            fail_if_not_eq_str(Xep.UniqueStableStanzaIDs.get_origin_id(outgoing),
                "unique-call-42",
                "XEP-0482: outgoing origin-id MUST preserve the provisional reference");
            StanzaNode? legacy = outgoing.stanza.get_subnode("propose",
                Xep.CallInvites.NS_URI_CUSTOM);
            fail_if(legacy == null,
                "DinoX legacy call invite facet MUST remain present");
            if (legacy != null) {
                fail_if_not_eq_str(legacy.get_attribute("id"),
                    "unique-call-42",
                    "Legacy propose id MUST preserve its legacy correlation ID");
            }

            outgoing.from = inviter;
            // A non-standard invite@id must not override XEP-0359/message IDs.
            if (invite != null) invite.put_attribute("id", "wrong-invite-id");
            Xep.CallInvites.ParsedCallInvite? parsed =
                Xep.CallInvites.Module.parse_call_invite(outgoing);
            fail_if(parsed == null,
                "XEP-0482: outgoing invite MUST parse");
            if (parsed != null) {
                fail_if(parsed.action != Xep.CallInvites.Action.INVITE,
                    "XEP-0482: outgoing invite MUST parse as INVITE");
                fail_if_not_eq_str(parsed.call_id, "unique-call-42",
                "XEP-0482: origin-id MUST win over undeclared invite@id");
            }
        } catch (InvalidJidError e) {
            fail_if_reached(@"Unexpected JID parse error: $(e.message)");
        }
    }

    private void test_cim_groupchat_reference_id() {
        try {
            Jid room = new Jid("source@conference.example.com");
            MessageStanza message = new MessageStanza("client-id") {
                from = new Jid("source@conference.example.com/alice"),
                to = new Jid("bob@example.com/laptop"),
                type_ = MessageStanza.TYPE_GROUPCHAT
            };
            Xep.UniqueStableStanzaIDs.set_origin_id(message, "origin-id");
            message.stanza.put_node(new StanzaNode.build("stanza-id",
                Xep.UniqueStableStanzaIDs.NS_URI).add_self_xmlns()
                .put_attribute("by", room.to_string())
                .put_attribute("id", "room-stanza-id"));
            message.stanza.put_node(new StanzaNode.build("invite",
                Xep.CallInvites.NS_URI).add_self_xmlns()
                .put_attribute("id", "wrong-invite-id")
                .put_node(new StanzaNode.build("muji", Xep.Muji.NS_URI)
                    .add_self_xmlns().put_attribute("room",
                        "call@conference.example.com")));

            Xep.CallInvites.ParsedCallInvite? parsed =
                Xep.CallInvites.Module.parse_call_invite(message);
            fail_if(parsed == null,
                "XEP-0482: groupchat invite with room stanza-id MUST parse");
            if (parsed != null) {
                fail_if(parsed.action != Xep.CallInvites.Action.INVITE,
                    "XEP-0482: groupchat invite MUST parse as INVITE");
                fail_if_not_eq_str(parsed.call_id, "room-stanza-id",
                    "XEP-0482: groupchat MUST use the room stanza-id");
            }
        } catch (InvalidJidError e) {
            fail_if_reached(@"Unexpected JID parse error: $(e.message)");
        }
    }

    private void test_cim_groupchat_missing_reference_id() {
        try {
            MessageStanza message = new MessageStanza("client-id") {
                from = new Jid("source@conference.example.com/alice"),
                to = new Jid("bob@example.com/laptop"),
                type_ = MessageStanza.TYPE_GROUPCHAT
            };
            Xep.UniqueStableStanzaIDs.set_origin_id(message, "origin-id");
            message.stanza.put_node(new StanzaNode.build("invite",
                Xep.CallInvites.NS_URI).add_self_xmlns()
                .put_attribute("id", "wrong-invite-id")
                .put_node(new StanzaNode.build("muji", Xep.Muji.NS_URI)
                    .add_self_xmlns().put_attribute("room",
                        "call@conference.example.com")));

            Xep.CallInvites.ParsedCallInvite? parsed =
                Xep.CallInvites.Module.parse_call_invite(message);
            fail_if(parsed != null,
                "XEP-0482: groupchat invite without room stanza-id MUST fail closed");
        } catch (InvalidJidError e) {
            fail_if_reached(@"Unexpected JID parse error: $(e.message)");
        }
    }

    private void test_cim_groupchat_conflicting_reference_ids() {
        try {
            Jid room = new Jid("source@conference.example.com");
            MessageStanza message = new MessageStanza("client-id") {
                from = new Jid("source@conference.example.com/alice"),
                to = new Jid("bob@example.com/laptop"),
                type_ = MessageStanza.TYPE_GROUPCHAT
            };
            Xep.UniqueStableStanzaIDs.set_origin_id(message, "origin-id");
            message.stanza.put_node(new StanzaNode.build("stanza-id",
                Xep.UniqueStableStanzaIDs.NS_URI).add_self_xmlns()
                .put_attribute("by", room.to_string())
                .put_attribute("id", "room-stanza-id-one"));
            message.stanza.put_node(new StanzaNode.build("stanza-id",
                Xep.UniqueStableStanzaIDs.NS_URI).add_self_xmlns()
                .put_attribute("by", room.to_string())
                .put_attribute("id", "room-stanza-id-two"));
            message.stanza.put_node(new StanzaNode.build("invite",
                Xep.CallInvites.NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build("muji", Xep.Muji.NS_URI)
                    .add_self_xmlns().put_attribute("room",
                        "call@conference.example.com")));

            Xep.CallInvites.ParsedCallInvite? parsed =
                Xep.CallInvites.Module.parse_call_invite(message);
            fail_if(parsed != null,
                "XEP-0359: conflicting stanza-ids from the same room must fail closed");
        } catch (InvalidJidError e) {
            fail_if_reached(@"Unexpected JID parse error: $(e.message)");
        }
    }

    private void test_cim_left() {
        try {
            MessageStanza message = new MessageStanza() {
                from = new Jid("alice@example.com/phone"),
                to = new Jid("bob@example.com/laptop"),
                type_ = MessageStanza.TYPE_CHAT
            };
            message.stanza.put_node(new StanzaNode.build("left",
                Xep.CallInvites.NS_URI).add_self_xmlns()
                .put_attribute("id", "call-left-1"));

            Xep.CallInvites.ParsedCallInvite? parsed =
                Xep.CallInvites.Module.parse_call_invite(message);
            fail_if(parsed == null,
                "XEP-0482: standards <left> MUST parse");
            if (parsed != null) {
                fail_if(parsed.action != Xep.CallInvites.Action.LEFT,
                    "XEP-0482: standards <left> MUST parse as LEFT");
                fail_if_not_eq_str(parsed.call_id, "call-left-1",
                    "XEP-0482: standards <left> MUST preserve its call id");
            }
        } catch (InvalidJidError e) {
            fail_if_reached(@"Unexpected JID parse error: $(e.message)");
        }
    }

    /**
     * XEP-0482: <invite> 'video' attribute MUST be parseable.
     */
    private void test_cim_invite_video(Gee.TestFinishedCallback cb) {
        string xml = "<message xmlns='jabber:client' id='c1'>"
            + "<invite xmlns='urn:xmpp:call-invites:0' video='true' multi='true'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0' room='r@c.example.com'/>"
            + "</invite>"
            + "</message>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? invite = node.get_subnode("invite", Xep.CallInvites.NS_URI);
            fail_if(invite == null, "XEP-0482: <invite> MUST be present");
            if (invite != null) {
                bool video = invite.get_attribute_bool("video", false);
                fail_if(!video, "XEP-0482: video='true' MUST parse as true");
                bool multi = invite.get_attribute_bool("multi", false);
                fail_if(!multi, "XEP-0482: multi='true' MUST parse as true for MUJI calls");
            }
            cb();
        });
    }

    /**
     * XEP-0482: <retract> MUST have 'id' attribute matching the call.
     */
    private void test_cim_retract(Gee.TestFinishedCallback cb) {
        string xml = "<message xmlns='jabber:client'>"
            + "<retract xmlns='urn:xmpp:call-invites:0' id='call-to-retract'/>"
            + "</message>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? retract = node.get_subnode("retract", Xep.CallInvites.NS_URI);
            fail_if(retract == null, "XEP-0482: <retract> element MUST be present");
            if (retract != null) {
                string? id = retract.get_attribute("id");
                fail_if(id == null, "XEP-0482: <retract> MUST have 'id' attribute");
                fail_if_not_eq_str(id, "call-to-retract",
                    "XEP-0482: retract id MUST match original call id");
            }
            cb();
        });
    }

    /**
     * XEP-0482: <accept> for MUJI call MUST contain <muji room='...'/>.
     */
    private void test_cim_accept_muji(Gee.TestFinishedCallback cb) {
        string xml = "<message xmlns='jabber:client'>"
            + "<accept xmlns='urn:xmpp:call-invites:0' id='call-accept-1'>"
            + "<muji xmlns='urn:xmpp:jingle:muji:0' room='room1@conference.example.com'/>"
            + "</accept>"
            + "</message>";
        parse_and_check.begin(xml, (obj, res) => {
            StanzaNode? node = parse_and_check.end(res);
            if (node == null) { cb(); return; }

            StanzaNode? accept = node.get_subnode("accept", Xep.CallInvites.NS_URI);
            fail_if(accept == null, "XEP-0482: <accept> element MUST be present");
            if (accept != null) {
                StanzaNode? muji = accept.get_subnode("muji", Xep.Muji.NS_URI);
                fail_if(muji == null, "XEP-0482: <accept> for MUJI call MUST contain <muji>");
                if (muji != null) {
                    fail_if_not_eq_str(muji.get_attribute("room"), "room1@conference.example.com",
                        "XEP-0482: accept <muji> room attribute MUST match the call room");
                }
            }
            cb();
        });
    }

    // ===================== RFC 4566: Payload ID Range =====================

    /**
     * RFC 4566 S6: Static payload type IDs range from 0-95,
     * dynamic from 96-127. PayloadType.id is uint8 so can hold 0-255,
     * but valid RTP payload IDs are 0-127.
     */
    private void test_payload_id_range() {
        // Static audio
        var pcmu = new Xep.JingleRtp.PayloadType();
        pcmu.id = 0; pcmu.name = "PCMU";
        fail_if(pcmu.id > 127, "RFC 4566 S6: PCMU id=0 MUST be in [0,127]");

        // Dynamic
        var opus = new Xep.JingleRtp.PayloadType();
        opus.id = 111; opus.name = "opus";
        fail_if(opus.id < 96 || opus.id > 127,
            "RFC 4566 S6: Opus id=111 MUST be in dynamic range [96,127]");

        // Boundary
        var tel = new Xep.JingleRtp.PayloadType();
        tel.id = 101; tel.name = "telephone-event";
        fail_if(tel.id > 127,
            "RFC 4566 S6: telephone-event MUST be in [0,127]");
    }

    private static Xep.JingleRtp.PayloadType parse_payload_with_wire_id(
            string? raw_id) {
        var node = new StanzaNode.build(
            "payload-type", Xep.JingleRtp.NS_URI)
            .put_attribute("name", "opus")
            .put_attribute("clockrate", "48000")
            .put_attribute("channels", "2");
        if (raw_id != null) node.put_attribute("id", (!) raw_id);
        return Xep.JingleRtp.PayloadType.parse(node);
    }

    private static void assert_invalid_wire_payload_id(
            string? raw_id, string label) {
        Xep.JingleRtp.PayloadType payload =
            parse_payload_with_wire_id(raw_id);
        fail_if(payload.id_valid,
            @"RFC 4566: $label payload ID must be rejected while parsing");
        var payloads = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        payloads.add(payload);
        fail_if(Xep.Muji.CodecNegotiation.payload_map_is_well_formed(
                payloads),
            @"RFC 4566: $label payload ID must never enter a conference map");
    }

    private void test_payload_id_parse_fail_closed() {
        Xep.JingleRtp.PayloadType minimum =
            parse_payload_with_wire_id("0");
        Xep.JingleRtp.PayloadType maximum =
            parse_payload_with_wire_id("127");
        fail_if(!minimum.id_valid || minimum.id != 0,
            "RFC 4566: payload ID 0 must parse without coercion");
        fail_if(!maximum.id_valid || maximum.id != 127,
            "RFC 4566: payload ID 127 must parse without coercion");

        assert_invalid_wire_payload_id(null, "missing");
        assert_invalid_wire_payload_id("-1", "negative");
        assert_invalid_wire_payload_id("bogus", "non-numeric");
        assert_invalid_wire_payload_id("128", "out-of-range");
        assert_invalid_wire_payload_id("256", "overflowing");
    }

    // ===================== XEP-0272: Payload Intersection =====================

    /**
     * XEP-0272 S5: If two peers have no common codecs, intersection is empty.
     */
    private void test_intersection_no_common() {
        var list_a = new ArrayList<Xep.JingleRtp.PayloadType>(Xep.JingleRtp.PayloadType.equals_func);
        var opus = new Xep.JingleRtp.PayloadType();
        opus.id = 111; opus.name = "opus"; opus.clockrate = 48000; opus.channels = 2;
        list_a.add(opus);

        var list_b = new ArrayList<Xep.JingleRtp.PayloadType>(Xep.JingleRtp.PayloadType.equals_func);
        var pcmu = new Xep.JingleRtp.PayloadType();
        pcmu.id = 0; pcmu.name = "PCMU"; pcmu.clockrate = 8000; pcmu.channels = 1;
        list_b.add(pcmu);

        // Manual intersection (same logic as compute_payload_intersection)
        var intersection = new ArrayList<Xep.JingleRtp.PayloadType>(Xep.JingleRtp.PayloadType.equals_func);
        foreach (var pt in list_a) {
            if (list_b.contains(pt)) intersection.add(pt);
        }
        fail_if(!intersection.is_empty,
            "XEP-0272 S5: Intersection of disjoint codec sets MUST be empty");
    }

    /**
     * XEP-0272 S5: Common codecs remain in the intersection.
     */
    private void test_intersection_keeps_common() {
        var opus_a = new Xep.JingleRtp.PayloadType();
        opus_a.id = 111; opus_a.name = "opus"; opus_a.clockrate = 48000; opus_a.channels = 2;
        var pcmu_a = new Xep.JingleRtp.PayloadType();
        pcmu_a.id = 0; pcmu_a.name = "PCMU"; pcmu_a.clockrate = 8000; pcmu_a.channels = 1;

        var list_a = new ArrayList<Xep.JingleRtp.PayloadType>(Xep.JingleRtp.PayloadType.equals_func);
        list_a.add(opus_a); list_a.add(pcmu_a);

        var opus_b = new Xep.JingleRtp.PayloadType();
        opus_b.id = 111; opus_b.name = "opus"; opus_b.clockrate = 48000; opus_b.channels = 2;
        var vp8_b = new Xep.JingleRtp.PayloadType();
        vp8_b.id = 96; vp8_b.name = "VP8"; vp8_b.clockrate = 90000; vp8_b.channels = 1;

        var list_b = new ArrayList<Xep.JingleRtp.PayloadType>(Xep.JingleRtp.PayloadType.equals_func);
        list_b.add(opus_b); list_b.add(vp8_b);

        // Intersection
        var intersection = new ArrayList<Xep.JingleRtp.PayloadType>(Xep.JingleRtp.PayloadType.equals_func);
        foreach (var pt in list_a) {
            if (list_b.contains(pt)) intersection.add(pt);
        }
        fail_if_not_eq_int(intersection.size, 1,
            "XEP-0272 S5: Intersection MUST contain exactly 1 common codec (opus)");
        if (!intersection.is_empty) {
            fail_if_not_eq_str(intersection[0].name, "opus",
                "XEP-0272 S5: Common codec MUST be opus");
        }
    }

    private void test_common_content_name_preserved() {
        try {
            var presences = new ArrayList<Presence.Stanza>();
            presences.add(build_muji_presence(
                "call@conference.example.com/one", false, true, false,
                "voice"));
            presences.add(build_muji_presence(
                "call@conference.example.com/two", false, true, false,
                "voice"));

            string? selected =
                Xep.Muji.Module.common_content_name_for_ready_presences(
                    "audio", presences);
            fail_if_not_eq_str(selected, "voice",
                "XEP-0272: an existing conference audio content name must be preserved");
            Gee.List<Xep.JingleRtp.PayloadType> payloads =
                Xep.Muji.Module.payload_intersection_for_ready_presences(
                    "audio", presences, selected);
            fail_if_not_eq_int(payloads.size, 1,
                "XEP-0272: codecs must intersect inside the selected conference content");
        } catch (Error e) {
            fail_if_reached(@"Unexpected content-name selection error: $(e.message)");
        }
    }

    private void test_different_content_names_do_not_intersect() {
        try {
            var presences = new ArrayList<Presence.Stanza>();
            presences.add(build_muji_presence(
                "call@conference.example.com/one", false, true, false,
                "voice"));
            presences.add(build_muji_presence(
                "call@conference.example.com/two", false, true, false,
                "audio"));

            Gee.List<string> names =
                Xep.Muji.Module.content_names_for_ready_presences(
                    "audio", presences);
            fail_if_not_eq_int(names.size, 2,
                "XEP-0272: same-media contents with different names must remain distinct candidates");
            fail_if_not_eq_str(names[0], "audio",
                "XEP-0272: content candidates must use stable byte ordering");
            fail_if_not_eq_str(names[1], "voice",
                "XEP-0272: different conference content names must never merge");
            fail_if_not_eq_int(
                Xep.Muji.Module.payload_intersection_for_ready_presences(
                    "audio", presences, "audio").size, 1,
                "XEP-0272: only participants advertising audio contribute to that content");
            fail_if_not_eq_int(
                Xep.Muji.Module.payload_intersection_for_ready_presences(
                    "audio", presences, "voice").size, 1,
                "XEP-0272: omission means non-participation, not an empty global mapping");
            fail_if(Xep.Muji.Module.presence_has_content(
                    "audio", "voice", presences[1]),
                "XEP-0272: a peer using another content identity must not join the frozen content");
        } catch (Error e) {
            fail_if_reached(@"Unexpected mismatched-content error: $(e.message)");
        }
    }

    private void test_duplicate_content_identity_is_fail_closed() {
        try {
            Presence.Stanza presence = build_muji_presence(
                "call@conference.example.com/duplicate", false, true,
                false, "voice");
            StanzaNode muji = (!) presence.stanza.get_subnode(
                "muji", Xep.Muji.NS_URI);
            var duplicate_description = new StanzaNode.build(
                "description", Xep.JingleRtp.NS_URI).add_self_xmlns()
                .put_attribute("media", "audio")
                .put_node(AuditMujiCodecProvider.make_payload(
                    "audio").to_xml().add_self_xmlns());
            muji.put_node(new StanzaNode.build(
                "content", Xep.Muji.NS_URI).add_self_xmlns()
                .put_attribute("creator", "initiator")
                .put_attribute("name", "voice")
                .put_node(duplicate_description));

            var presences = new ArrayList<Presence.Stanza>();
            presences.add(presence);
            fail_if(Xep.Muji.Module.common_content_name_for_ready_presences(
                    "audio", presences) != null,
                "XEP-0272/XEP-0166: duplicate creator/name content must be ambiguous");
            fail_if(Xep.Muji.Module.presence_has_content(
                    "audio", "voice", presence),
                "XEP-0272/XEP-0166: ambiguous content must not be negotiable");
        } catch (Error e) {
            fail_if_reached(@"Unexpected duplicate-content error: $(e.message)");
        }
    }

    private void test_content_name_accepts_xs_string_whitespace() {
        fail_if(!Xep.Muji.Module.is_valid_content_name("main voice\tstream"),
            "XEP-0166: content name is xs:string and may contain spaces or tabs");
        try {
            var group_call = new Xep.Muji.GroupCall(
                new Jid("xs-string@conference.example.com"),
                new AuditMujiCodecProvider(), false);
            var names = new HashMap<string, string>();
            names["audio"] = "main voice\tstream";
            fail_if(!group_call.commit_content_names(names),
                "XEP-0166: GroupCall must preserve legal xs:string content names");
            fail_if_not_eq_str(group_call.get_content_name("audio"),
                "main voice\tstream",
                "XEP-0166: content name whitespace must be preserved exactly");
        } catch (Error e) {
            fail_if_reached(@"Unexpected xs:string content-name error: $(e.message)");
        }
    }

    private void test_content_without_creator_is_not_negotiable() {
        try {
            var presences = new ArrayList<Presence.Stanza>();
            presences.add(build_muji_presence(
                "call@conference.example.com/no-creator", false, true,
                false, "voice", "video", null));
            fail_if(Xep.Muji.Module.common_content_name_for_ready_presences(
                    "audio", presences) != null,
                "XEP-0272/XEP-0166: content without required creator must not select a conference identity");
            fail_if(!Xep.Muji.Module.payload_intersection_for_ready_presences(
                    "audio", presences).is_empty,
                "XEP-0272/XEP-0166: content without required creator must not contribute codecs");
        } catch (Error e) {
            fail_if_reached(@"Unexpected creator-validation error: $(e.message)");
        }
    }

    private void test_group_content_names_are_frozen() {
        try {
            var group_call = new Xep.Muji.GroupCall(
                new Jid("names@conference.example.com"),
                new AuditMujiCodecProvider(), true);
            var selected = new HashMap<string, string>();
            selected["audio"] = "voice";
            selected["video"] = "camera";
            fail_if(!group_call.commit_content_names(selected),
                "MUJI group must atomically accept valid audio/video identities");
            fail_if_not_eq_str(group_call.get_content_name("audio"), "voice",
                "MUJI group must preserve the selected audio identity");

            Gee.Map<string, string> copy =
                group_call.copy_content_names_by_media();
            copy["audio"] = "changed-outside";
            fail_if_not_eq_str(group_call.get_content_name("audio"), "voice",
                "MUJI content-name access must not expose mutable group state");

            var changed = new HashMap<string, string>();
            changed["audio"] = "other";
            changed["video"] = "camera";
            fail_if(group_call.commit_content_names(changed),
                "MUJI content identities must be immutable after publication");
        } catch (Error e) {
            fail_if_reached(@"Unexpected GroupCall content-name error: $(e.message)");
        }
    }

    private void test_codec_provider_get_error(Gee.TestFinishedCallback cb) {
        var provider = new AuditMujiCodecProvider() { fail_get = true };
        Xep.Muji.CodecNegotiation.select.begin(provider, "audio", null, (_, result) => {
            bool failed = false;
            try {
                Xep.Muji.CodecNegotiation.select.end(result);
            } catch (Error e) {
                failed = e is AuditMujiCodecError.PROVIDER_FAILURE;
            }
            fail_if(!failed,
                "XEP-0272: codec enumeration errors MUST propagate and fail the join closed");
            cb();
        });
    }

    private void test_codec_provider_check_error(Gee.TestFinishedCallback cb) {
        var provider = new AuditMujiCodecProvider() { fail_check = true };
        var remote = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        remote.add(AuditMujiCodecProvider.make_payload("audio"));
        Xep.Muji.CodecNegotiation.select.begin(provider, "audio", remote, (_, result) => {
            bool failed = false;
            try {
                Xep.Muji.CodecNegotiation.select.end(result);
            } catch (Error e) {
                failed = e is AuditMujiCodecError.PROVIDER_FAILURE;
            }
            fail_if(!failed,
                "XEP-0272: codec support-check errors MUST propagate and fail the join closed");
            cb();
        });
    }

    private void test_empty_audio_required(Gee.TestFinishedCallback cb) {
        var provider = new AuditMujiCodecProvider() { audio_available = false };
        Xep.Muji.CodecNegotiation.select.begin(provider, "audio", null, (_, result) => {
            try {
                Xep.Muji.CodecSelection selection =
                    Xep.Muji.CodecNegotiation.select.end(result);
                fail_if(selection.availability !=
                    Xep.Muji.CodecAvailability.REQUIRED_UNAVAILABLE,
                    "XEP-0272: empty audio capabilities MUST abort MUJI readiness");
                fail_if(!selection.payload_types.is_empty,
                    "XEP-0272: unavailable audio selection MUST not contain payloads");
            } catch (Error e) {
                fail_if_reached(@"Unexpected codec selection error: $(e.message)");
            }
            cb();
        });
    }

    private void test_empty_video_optional(Gee.TestFinishedCallback cb) {
        var provider = new AuditMujiCodecProvider() { video_available = false };
        Xep.Muji.CodecNegotiation.select.begin(provider, "video", null, (_, result) => {
            try {
                Xep.Muji.CodecSelection selection =
                    Xep.Muji.CodecNegotiation.select.end(result);
                fail_if(selection.availability !=
                    Xep.Muji.CodecAvailability.OPTIONAL_UNAVAILABLE,
                    "XEP-0272: empty video capabilities MUST downgrade MUJI to audio-only");
                fail_if(!selection.payload_types.is_empty,
                    "XEP-0272: unavailable video selection MUST not contain payloads");
            } catch (Error e) {
                fail_if_reached(@"Unexpected codec selection error: $(e.message)");
            }
            cb();
        });
    }

    private static Xep.JingleRtp.PayloadType make_video_payload(
            uint8 id, string name, string? apt = null) {
        var payload = new Xep.JingleRtp.PayloadType() {
            id = id,
            name = name,
            clockrate = 90000,
            channels = 1
        };
        if (apt != null) payload.parameters["apt"] = (!) apt;
        return payload;
    }

    private void test_payload_map_filters_unsupported_rtx_pair(
            Gee.TestFinishedCallback cb) {
        test_payload_map_filters_unsupported_rtx_pair_async.begin(
            (_, result) => {
                try {
                    test_payload_map_filters_unsupported_rtx_pair_async.end(
                        result);
                } catch (Error e) {
                    fail_if_reached(@"Unexpected RTX-pair selection error: $(e.message)");
                }
                cb();
            });
    }

    private async void test_payload_map_filters_unsupported_rtx_pair_async()
            throws Error {
        var provider = new AuditMujiPayloadSetProvider();
        provider.local_payloads.add(make_video_payload(96, "VP8"));
        provider.local_payloads.add(make_video_payload(97, "rtx", "96"));

        var remote = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        remote.add(make_video_payload(100, "H264"));
        remote.add(make_video_payload(101, "rtx", "100"));
        remote.add(make_video_payload(120, "VP8"));
        remote.add(make_video_payload(121, "rtx", "120"));
        Xep.Muji.CodecSelection selection =
            yield Xep.Muji.CodecNegotiation.select(
                provider, "video", remote);
        fail_if(selection.availability != Xep.Muji.CodecAvailability.AVAILABLE,
            "XEP-0272: a valid VP8/RTX pair must remain available");
        fail_if_not_eq_int(selection.payload_types.size, 2,
            "XEP-0272: unsupported primary plus dependent RTX must be removed atomically");
        fail_if_not_eq_int(selection.payload_types[0].id, 120,
            "XEP-0272: the supported remote primary ID must be preserved");
        fail_if_not_eq_int(selection.payload_types[1].id, 121,
            "XEP-0272: only RTX paired with the supported primary may remain");
        fail_if_not_eq_str(selection.payload_types[1].parameters["apt"], "120",
            "RFC 4588: selected RTX must retain its remote primary reference");
    }

    private void test_duplicate_payload_ids_fail_closed(
            Gee.TestFinishedCallback cb) {
        test_malformed_payload_map_fail_closed_async.begin(true, (_, result) => {
            try {
                test_malformed_payload_map_fail_closed_async.end(result);
            } catch (Error e) {
                fail_if_reached(@"Unexpected duplicate-PT selection error: $(e.message)");
            }
            cb();
        });
    }

    private void test_rtx_without_apt_fails_closed(
            Gee.TestFinishedCallback cb) {
        test_malformed_payload_map_fail_closed_async.begin(false, (_, result) => {
            try {
                test_malformed_payload_map_fail_closed_async.end(result);
            } catch (Error e) {
                fail_if_reached(@"Unexpected missing-apt selection error: $(e.message)");
            }
            cb();
        });
    }

    private async void test_malformed_payload_map_fail_closed_async(
            bool duplicate_id) throws Error {
        var provider = new AuditMujiPayloadSetProvider();
        provider.local_payloads.add(make_video_payload(96, "VP8"));
        provider.local_payloads.add(make_video_payload(97, "rtx", "96"));
        var remote = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        remote.add(make_video_payload(120, "VP8"));
        remote.add(duplicate_id
            ? make_video_payload(120, "VP8")
            : make_video_payload(121, "rtx"));
        Xep.Muji.CodecSelection selection =
            yield Xep.Muji.CodecNegotiation.select(
                provider, "video", remote);
        fail_if(selection.availability !=
                Xep.Muji.CodecAvailability.OPTIONAL_UNAVAILABLE ||
                !selection.payload_types.is_empty,
            duplicate_id
                ? "XEP-0272: duplicate PT IDs must fail closed before Ready presence"
                : "RFC 4588: RTX without apt must fail closed before Ready presence");
    }

    private void test_late_ready_malformed_full_payload_map_fails_closed() {
        try {
            Presence.Stanza presence = build_muji_presence(
                "call@conference.example.com/malformed-late", false,
                false, true, "voice", "camera");
            StanzaNode muji = (!) presence.stanza.get_subnode(
                "muji", Xep.Muji.NS_URI);
            StanzaNode content = (!) muji.get_subnode(
                "content", Xep.Muji.NS_URI);
            StanzaNode description = (!) content.get_subnode(
                "description", Xep.JingleRtp.NS_URI);
            description.put_node(make_video_payload(97, "rtx").to_xml()
                .add_self_xmlns());

            var presences = new ArrayList<Presence.Stanza>();
            presences.add(presence);
            Gee.List<Xep.JingleRtp.PayloadType> intersection =
                Xep.Muji.Module.payload_intersection_for_ready_presences(
                    "video", presences, "camera");
            fail_if(!intersection.is_empty,
                "XEP-0272/RFC 4588: a late Ready presence with a valid primary plus malformed RTX must invalidate the full advertised map");
        } catch (Error e) {
            fail_if_reached(
                @"Unexpected malformed late-Ready payload error: $(e.message)");
        }
    }

    private void test_late_ready_uses_frozen_payload_map_synchronously() {
        var frozen = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        frozen.add(make_video_payload(96, "VP8"));
        frozen.add(make_video_payload(97, "rtx", "96"));
        var remote = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        remote.add(make_video_payload(96, "VP8"));
        remote.add(make_video_payload(97, "rtx", "96"));

        Xep.Muji.CodecSelection selection =
            Xep.Muji.CodecNegotiation.select_from_frozen_payload_map(
                "video", frozen, remote);
        fail_if(selection.availability !=
                Xep.Muji.CodecAvailability.AVAILABLE ||
                selection.payload_types.size != 2,
            "XEP-0272: a late Ready peer must be selected synchronously from the already validated frozen map");

        remote.remove_at(1);
        selection = Xep.Muji.CodecNegotiation.select_from_frozen_payload_map(
            "video", frozen, remote);
        fail_if(selection.availability !=
                Xep.Muji.CodecAvailability.AVAILABLE ||
                selection.payload_types.size != 1 ||
                Xep.Muji.CodecNegotiation.is_rtx_payload(
                    selection.payload_types[0]),
            "XEP-0272: optional RTX omission must retain the frozen primary without an async provider roundtrip");
    }

    private void test_late_join_video_downgrade(Gee.TestFinishedCallback cb) {
        test_late_join_video_downgrade_async.begin((_, result) => {
            try {
                test_late_join_video_downgrade_async.end(result);
            } catch (Error e) {
                fail_if_reached(@"Unexpected late-join codec error: $(e.message)");
            }
            cb();
        });
    }

    private async void test_late_join_video_downgrade_async() throws Error {
        var initial_provider = new AuditMujiCodecProvider() {
            audio_available = true,
            video_available = true
        };
        var group_call = new Xep.Muji.GroupCall(
            new Jid("late-video@conference.example.com"), initial_provider, true);
        int update_count = 0;
        group_call.media_availability_changed.connect((media, availability, payloads) => {
            update_count++;
        });

        Xep.Muji.CodecSelection audio = yield Xep.Muji.CodecNegotiation.select(
            initial_provider, "audio");
        group_call.record_codec_selection("audio", audio);
        Xep.Muji.CodecSelection video = yield Xep.Muji.CodecNegotiation.select(
            initial_provider, "video");
        group_call.record_codec_selection("video", video);
        fail_if(!group_call.video_available,
            "XEP-0272: group video MUST initially be available with a codec");
        var names = new HashMap<string, string>();
        names["audio"] = "voice";
        names["video"] = "camera";
        fail_if(!group_call.commit_content_names(names),
            "XEP-0272: initial media must freeze before late peers are processed");

        update_count = 0;
        var incompatible_late_peer = new AuditMujiCodecProvider() {
            audio_available = true,
            video_available = false
        };
        Xep.Muji.CodecSelection no_video = yield Xep.Muji.CodecNegotiation.select(
            incompatible_late_peer, "video");
        Xep.Muji.CodecSelection frozen =
            group_call.record_codec_selection("video", no_video);
        fail_if(!group_call.video_available,
            "XEP-0272: a late audio-only peer must not downgrade existing video legs");
        fail_if_not_eq_int(update_count, 0,
            "XEP-0272: the frozen conference payload map must not emit a late global update");
        fail_if(frozen.availability != Xep.Muji.CodecAvailability.AVAILABLE,
            "XEP-0272: record_codec_selection must return the frozen video selection");
        fail_if(group_call.current_media_availability["audio"] !=
            Xep.Muji.CodecAvailability.AVAILABLE,
            "XEP-0272: per-peer video omission must keep group audio available");

        var selections = new HashMap<string, Xep.Muji.CodecSelection>();
        selections["audio"] = audio;
        selections["video"] = no_video;
        Jid occupant = new Jid(
            "late-video@conference.example.com/audio-only");
        Jid real_jid = new Jid("audio-only@example.com/Phone");
        fail_if(!group_call.complete_ready_peer(
                occupant, real_jid, selections),
            "XEP-0272: audio-capable late peer must get an audio-only leg");
        fail_if(group_call.peer_supports_video(real_jid),
            "XEP-0272: video capability must remain scoped to the late peer");
        fail_if(!group_call.video_available ||
                group_call.current_payload_intersection["video"].is_empty,
            "XEP-0272: existing group video and its global payload map must remain frozen");
    }

    private void test_preparing_peer_excluded() {
        try {
            var presences = new ArrayList<Presence.Stanza>();
            presences.add(build_muji_presence(
                "call@conference.example.com/ready", false, true, false));
            Presence.Stanza preparing = build_muji_presence(
                "call@conference.example.com/preparing", true, false, false);
            presences.add(preparing);

            fail_if(Xep.Muji.Module.is_ready_muji_presence(preparing),
                "XEP-0272: <preparing/> presence MUST not be treated as codec-ready");
            Gee.List<Xep.JingleRtp.PayloadType> audio =
                Xep.Muji.Module.payload_intersection_for_ready_presences(
                    "audio", presences);
            fail_if_not_eq_int(audio.size, 1,
                "XEP-0272: preparing peer without codecs MUST not empty ready audio intersection");
            fail_if_not_eq_str(audio[0].name, "opus",
                "XEP-0272: ready peer audio codec MUST survive parallel preparing peer");
        } catch (Error e) {
            fail_if_reached(@"Unexpected preparing-presence error: $(e.message)");
        }
    }

    private void test_ready_peer_missing_expected_content(
            Gee.TestFinishedCallback cb) {
        test_ready_peer_missing_expected_content_async.begin((_, result) => {
            try {
                test_ready_peer_missing_expected_content_async.end(result);
            } catch (Error e) {
                fail_if_reached(@"Unexpected ready-presence codec error: $(e.message)");
            }
            cb();
        });
    }

    private async void test_ready_peer_missing_expected_content_async()
            throws Error {
        var presences = new ArrayList<Presence.Stanza>();
        presences.add(build_muji_presence(
            "call@conference.example.com/full", false, true, true));
        presences.add(build_muji_presence(
            "call@conference.example.com/audio-only", false, true, false));

        var provider = new AuditMujiCodecProvider() {
            audio_available = true,
            video_available = true
        };
        Gee.List<Xep.JingleRtp.PayloadType> audio_intersection =
            Xep.Muji.Module.payload_intersection_for_ready_presences(
                "audio", presences);
        Xep.Muji.CodecSelection audio = yield Xep.Muji.CodecNegotiation.select(
            provider, "audio", audio_intersection);
        fail_if(audio.availability != Xep.Muji.CodecAvailability.AVAILABLE,
            "XEP-0272: audio-only late peer MUST keep common audio available");

        Gee.List<Xep.JingleRtp.PayloadType> video_intersection =
            Xep.Muji.Module.payload_intersection_for_ready_presences(
                "video", presences);
        Xep.Muji.CodecSelection video = yield Xep.Muji.CodecNegotiation.select(
            provider, "video", video_intersection);
        fail_if(video.availability != Xep.Muji.CodecAvailability.AVAILABLE,
            "XEP-0272: participants may omit video without emptying that conference content");

        var group_call = new Xep.Muji.GroupCall(
            new Jid("presence-order@conference.example.com"), provider, true);
        var event_order = new ArrayList<string>();
        group_call.peer_joined.connect((_real_jid) => {
            event_order.add("peer-joined");
        });
        Xep.Muji.CodecSelection no_peer_video =
            yield Xep.Muji.CodecNegotiation.select(
                new AuditMujiCodecProvider() { video_available = false },
                "video");
        var selections = new HashMap<string, Xep.Muji.CodecSelection>();
        selections["audio"] = audio;
        selections["video"] = no_peer_video;
        Jid occupant = new Jid(
            "presence-order@conference.example.com/audio-only");
        Jid real_jid = new Jid("audio-only@example.com/Phone");
        uint generation = group_call.mark_presence_update(occupant);
        fail_if(!group_call.is_current_presence_update(occupant, generation),
            "XEP-0272: current ready-presence generation MUST be accepted");
        fail_if(!group_call.complete_ready_peer(occupant, real_jid, selections),
            "XEP-0272: audio-capable ready peer MUST complete after video downgrade");
        fail_if_not_eq_int(event_order.size, 1,
            "XEP-0272: ready audio-only peer must emit only its peer event");
        fail_if_not_eq_str(event_order[0], "peer-joined",
            "XEP-0272: peer_joined must be emitted after per-peer media is stored");
        fail_if(group_call.peer_supports_video(real_jid),
            "XEP-0272: missing video content must create an audio-only peer leg");
        group_call.invalidate_presence_update(occupant);
        fail_if(group_call.is_current_presence_update(occupant, generation),
            "XEP-0272: unavailable/newer presence MUST invalidate pending ready work");

        var missing_audio = new ArrayList<Presence.Stanza>();
        missing_audio.add(build_muji_presence(
            "call@conference.example.com/video-only", false, false, true));
        Gee.List<Xep.JingleRtp.PayloadType> missing_audio_intersection =
            Xep.Muji.Module.payload_intersection_for_ready_presences(
                "audio", missing_audio);
        Xep.Muji.CodecSelection required_audio =
            yield Xep.Muji.CodecNegotiation.select(
                provider, "audio", missing_audio_intersection);
        fail_if(required_audio.availability !=
            Xep.Muji.CodecAvailability.REQUIRED_UNAVAILABLE,
            "XEP-0272: ready peer missing audio content MUST abort the call");
        var rejected_selections = new HashMap<string, Xep.Muji.CodecSelection>();
        rejected_selections["audio"] = required_audio;
        fail_if(group_call.complete_ready_peer(
                new Jid("presence-order@conference.example.com/no-audio"),
                new Jid("no-audio@example.com/Phone"), rejected_selections),
            "XEP-0272: required-audio failure MUST not expose peer_joined");
    }

    private Presence.Stanza build_muji_presence(
            string from,
            bool preparing,
            bool audio,
            bool video,
            string audio_content_name = "audio",
            string video_content_name = "video",
            string? creator = "initiator") throws Error {
        var presence = new Presence.Stanza();
        presence.from = new Jid(from);
        var muji = new StanzaNode.build("muji", Xep.Muji.NS_URI).add_self_xmlns();
        if (preparing) {
            muji.put_node(new StanzaNode.build("preparing", Xep.Muji.NS_URI));
        }
        foreach (string media in audio && video
                ? new string[] { "audio", "video" }
                : audio
                    ? new string[] { "audio" }
                    : video
                        ? new string[] { "video" }
                        : new string[] {}) {
            var description = new StanzaNode.build(
                "description", Xep.JingleRtp.NS_URI)
                .add_self_xmlns()
                .put_attribute("media", media)
                .put_node(AuditMujiCodecProvider.make_payload(media).to_xml()
                    .add_self_xmlns());
            var content = new StanzaNode.build("content", Xep.Muji.NS_URI)
                .add_self_xmlns()
                .put_attribute("name", media == "audio"
                    ? audio_content_name : video_content_name)
                .put_node(description);
            if (creator != null) {
                content.put_attribute("creator", (!) creator);
            }
            muji.put_node(content);
        }
        presence.stanza.put_node(muji);
        return presence;
    }

    private void test_membership_change_invalidates_all_codec_snapshots() {
        try {
            var group_call = new Xep.Muji.GroupCall(
                new Jid("membership@conference.example.com"),
                new AuditMujiCodecProvider(), true);
            Jid first = new Jid(
                "membership@conference.example.com/first");
            Jid second = new Jid(
                "membership@conference.example.com/second");

            uint first_presence = group_call.mark_presence_update(first);
            uint first_membership =
                group_call.capture_ready_membership_generation();
            fail_if(!group_call.is_current_ready_snapshot(first,
                    first_presence, first_membership),
                "A freshly captured ready-membership snapshot must be current");

            uint second_presence = group_call.mark_presence_update(second);
            uint second_membership =
                group_call.capture_ready_membership_generation();
            fail_if(!group_call.is_current_presence_update(first,
                    first_presence) ||
                    group_call.is_current_ready_snapshot(first,
                        first_presence, first_membership),
                "A second occupant update must stale the first global codec snapshot without rewriting that occupant");
            fail_if(!group_call.is_current_ready_snapshot(second,
                    second_presence, second_membership),
                "The newest occupant update must own the current global codec snapshot");

            group_call.invalidate_presence_update(first);
            fail_if(group_call.is_current_ready_snapshot(second,
                    second_presence, second_membership),
                "An unavailable occupant must invalidate every in-flight codec snapshot");
        } catch (Error e) {
            fail_if_reached(@"Unexpected membership-generation error: $(e.message)");
        }
    }

    private void test_available_presence_without_muji_removes_participant() {
        try {
            var group_call = new Xep.Muji.GroupCall(
                new Jid("leave@conference.example.com"),
                new AuditMujiCodecProvider(), true);
            Jid occupant = new Jid(
                "leave@conference.example.com/participant");
            Jid real_jid = new Jid("participant@example.com/Phone");
            uint presence_generation =
                group_call.mark_presence_update(occupant);
            group_call.track_muji_participant(occupant, real_jid);
            group_call.peers_to_connect_to.add(real_jid);
            uint membership_generation =
                group_call.capture_ready_membership_generation();
            int peer_left_count = 0;
            group_call.peer_left.connect((left_jid) => {
                if (left_jid.equals(real_jid)) peer_left_count++;
            });

            var without_muji = new Presence.Stanza() {
                from = occupant,
                type_ = Presence.Stanza.TYPE_AVAILABLE
            };
            fail_if(!Xep.Muji.Module.is_muji_leave_presence(
                    group_call, without_muji),
                "An available replacement presence without MUJI must be recognized as leaving the call");

            Jid? removed_real_jid;
            fail_if(!group_call.forget_muji_participant(
                    occupant, out removed_real_jid) ||
                    removed_real_jid == null ||
                    !((!) removed_real_jid).equals(real_jid),
                "Removing the MUJI facet must resolve the exact real JID");
            fail_if(group_call.has_muji_participant(occupant) ||
                    group_call.is_current_presence_update(
                        occupant, presence_generation) ||
                    group_call.is_current_ready_membership_generation(
                        membership_generation) ||
                    group_call.peers_to_connect_to.contains(real_jid) ||
                    peer_left_count != 1,
                "MUJI leave must invalidate codec work, remove the pending leg, and emit one peer-left event");
            fail_if(group_call.forget_muji_participant(
                    occupant, out removed_real_jid) || peer_left_count != 1,
                "A repeated non-MUJI presence must be idempotent");

            var unknown_presence = new Presence.Stanza() {
                from = new Jid("leave@conference.example.com/spectator"),
                type_ = Presence.Stanza.TYPE_AVAILABLE
            };
            fail_if(Xep.Muji.Module.is_muji_leave_presence(
                    group_call, unknown_presence),
                "A normal non-MUJI room occupant must not be treated as leaving this call");
        } catch (Error e) {
            fail_if_reached(@"Unexpected MUJI leave-presence error: $(e.message)");
        }
    }

    private void test_initial_muji_snapshot_tracks_before_any_await() {
        try {
            var group_call = new Xep.Muji.GroupCall(
                new Jid("initial@conference.example.com"),
                new AuditMujiCodecProvider(), true);
            Presence.Stanza ready = build_muji_presence(
                "initial@conference.example.com/participant",
                false, true, true);
            Presence.Stanza preparing = build_muji_presence(
                "initial@conference.example.com/preparing",
                true, false, false);
            var muji_presences = new ArrayList<Presence.Stanza>();
            muji_presences.add(ready);
            muji_presences.add(preparing);

            uint before_discovery =
                group_call.capture_ready_membership_generation();
            uint membership_generation =
                group_call.capture_muji_membership_snapshot(
                    muji_presences);
            fail_if(group_call.is_current_ready_membership_generation(
                    before_discovery) ||
                    !group_call.is_current_ready_membership_generation(
                        membership_generation),
                "Discovering cached MUJI members must invalidate older codec snapshots atomically");
            var without_muji = new Presence.Stanza() {
                from = ready.from,
                type_ = Presence.Stanza.TYPE_AVAILABLE
            };
            fail_if(!Xep.Muji.Module.is_muji_leave_presence(
                    group_call, without_muji),
                "A cached ready participant must be tracked before the first join await");
            without_muji.from = preparing.from;
            fail_if(!Xep.Muji.Module.is_muji_leave_presence(
                    group_call, without_muji),
                "A cached preparing participant must be tracked before the first join await");

            Jid? removed_real_jid;
            fail_if(!group_call.forget_muji_participant(
                    ready.from, out removed_real_jid) ||
                    removed_real_jid != null ||
                    group_call.is_current_ready_membership_generation(
                        membership_generation),
                "Leaving during initial codec probing must stale the captured snapshot without exposing a peer leg");
        } catch (Error e) {
            fail_if_reached(@"Unexpected initial membership-snapshot error: $(e.message)");
        }
    }

    private void test_nick_election_utf16() {
        try {
            // Expected Java/Monocles String.compareTo order, not UTF-8 order:
            // supplementary-plane emoji sorts before a BMP CJK character.
            string[] nicks = { "Alice", "alice", "alice/phone", "bob", "Борис", "Яна", "😀", "﨎" };
            for (int i = 0; i < nicks.length; i++) {
                for (int j = 0; j < nicks.length; j++) {
                    bool initiate = Xep.Muji.Module.should_initiate_peer_session(
                        nicks[i], new Jid("Room@conference.example/" + nicks[j]));
                    fail_if(initiate != (i > j),
                        "MUJI initiator must follow UTF-16 nick order, including Cyrillic and emoji");
                }
            }
            fail_if(Xep.Muji.Module.should_initiate_peer_session(
                "alice", new Jid("room@conference.example")),
                "A bare room JID cannot elect a peer");
        } catch (Error e) {
            fail_if_reached(@"Unexpected nick election error: $(e.message)");
        }
    }

    private void test_nick_election_three_participants() {
        try {
            string[] nicks = { "alice", "bob", "carol" };
            // Every arrival permutation must elect one sender per pair. This
            // covers both a pre-existing room and a direct call's third peer.
            for (int first = 0; first < 3; first++) {
                for (int second = 0; second < 3; second++) {
                    if (first == second) continue;
                    int third = 3 - first - second;
                    int[] arrivals = { first, second, third };
                    int initiated = 0;
                    for (int a = 0; a < 3; a++) {
                        for (int b = a + 1; b < 3; b++) {
                            string left = nicks[arrivals[a]];
                            string right = nicks[arrivals[b]];
                            bool left_starts = Xep.Muji.Module.should_initiate_peer_session(
                                left, new Jid("room@conference.example/" + right));
                            bool right_starts = Xep.Muji.Module.should_initiate_peer_session(
                                right, new Jid("room@conference.example/" + left));
                            fail_if(left_starts == right_starts,
                                "Every MUJI pair must have exactly one initiator");
                            initiated += (left_starts ? 1 : 0) + (right_starts ? 1 : 0);
                        }
                    }
                    fail_if_not_eq_int(initiated, 3,
                        "Three participants must elect three distinct mesh legs");
                }
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected three-party election error: $(e.message)");
        }
    }

    // ===================== Helper: Parse XML via StanzaReader =====================

    /**
     * Parse real XML via StanzaReader (Golden Rule #3).
     * Returns the root StanzaNode, or null if parse failed (test fails).
     */
    private async StanzaNode? parse_and_check(string xml) {
        var reader = new StanzaReader.for_string(xml);
        try {
            StanzaNode node = yield reader.read_node();
            return node;
        } catch (Error e) {
            fail_if_reached(@"XEP-0272: XML parse error: $(e.message) for: $xml");
            return null;
        }
    }
}

private class MujiExistingRoomAuditStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_presences =
        new Gee.ArrayList<StanzaNode>();
    public int muc_enter_presence_count { get; private set; default=0; }
    public int preparing_presence_count { get; private set; default=0; }
    public int unavailable_presence_count { get; private set; default=0; }
    public int muji_cleanup_presence_count { get; private set; default=0; }
    public bool correct_echo_sent { get; private set; default=false; }
    public bool suppress_correct_echo { get; set; default=false; }
    public bool omit_correct_echo_id { get; set; default=false; }
    public bool omit_correct_echo_generation { get; set; default=false; }

    public MujiExistingRoomAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (node.name != "presence") return;
        written_presences.add(node);

        if (node.get_attribute("type") == Presence.Stanza.TYPE_UNAVAILABLE) {
            unavailable_presence_count++;
            return;
        }
        if (node.get_subnode("x", "http://jabber.org/protocol/muc") != null) {
            muc_enter_presence_count++;
        }

        StanzaNode? muji = node.get_subnode("muji", Xep.Muji.NS_URI);
        if (muji == null) {
            muji_cleanup_presence_count++;
            return;
        }
        if (((!) muji).get_subnode("preparing", Xep.Muji.NS_URI) == null) {
            return;
        }
        preparing_presence_count++;

        string? target = node.get_attribute("to");
        if (target == null) return;
        string? expected_id = node.get_attribute("id");
        StanzaNode? generation = ((!) muji).get_subnode(
            "generation", Xep.Muji.LIVENESS_NS_URI);
        string? expected_generation = generation != null
            ? ((!) generation).get_attribute("id") : null;
        string[] target_parts = ((!) target).split("/", 2);
        string room = target_parts[0];
        string nick = target_parts.length > 1
            ? target_parts[1] : "existing-nick";
        string wrong_nick = room + "/other-occupant";
        StanzaNode wrong_room_echo = build_preparing_echo(
            "unrelated@conference.example.test/" + nick,
            "server-wrong-room-id",
            expected_generation);
        StanzaNode wrong_nick_echo = build_preparing_echo(
            wrong_nick, "server-wrong-nick-id", expected_generation);
        StanzaNode stale_echo = build_preparing_echo((!) target,
            expected_id, "stale-generation");
        StanzaNode wrong_legacy_echo = build_preparing_echo((!) target,
            "wrong-legacy-id", null);
        StanzaNode malformed_generation_echo =
            build_malformed_generation_echo((!) target, expected_id);

        // Keep every negative case ahead of the valid echo. If any of them
        // releases the join, correct_echo_sent remains false and the caller's
        // assertion fails deterministically.
        received_presence_stanza(this, wrong_room_echo);
        received_presence_stanza(this, wrong_nick_echo);
        received_presence_stanza(this, build_unavailable(wrong_nick));
        received_presence_stanza(this, stale_echo);
        received_presence_stanza(this, wrong_legacy_echo);
        received_presence_stanza(this, malformed_generation_echo);
        if (suppress_correct_echo) return;
        Idle.add(() => {
            correct_echo_sent = true;
            received_presence_stanza(this, build_preparing_echo(
                (!) target,
                omit_correct_echo_id ? null :
                    (omit_correct_echo_generation
                        ? expected_id : "server-generated-id"),
                omit_correct_echo_generation ? null : expected_generation));
            return Source.REMOVE;
        });
    }

    private StanzaNode build_preparing_echo(string from, string? id,
            string? generation) {
        StanzaNode muji = new StanzaNode.build("muji", Xep.Muji.NS_URI)
            .add_self_xmlns()
            .put_node(new StanzaNode.build(
                "preparing", Xep.Muji.NS_URI));
        if (generation != null) {
            muji.put_node(new StanzaNode.build(
                    "generation", Xep.Muji.LIVENESS_NS_URI)
                .add_self_xmlns()
                .put_attribute("id", (!) generation));
        }
        StanzaNode echo = new StanzaNode.build("presence")
            .put_attribute("from", from)
            .put_attribute("to", get_flag(Bind.Flag.IDENTITY).my_jid.to_string())
            .put_node(muji);
        if (id != null) echo.put_attribute("id", (!) id);
        return echo;
    }

    private StanzaNode build_malformed_generation_echo(
            string from, string? id) {
        StanzaNode echo = build_preparing_echo(from, id, null);
        StanzaNode? muji = echo.get_subnode("muji", Xep.Muji.NS_URI);
        ((!) muji).put_node(new StanzaNode.build(
                "generation", Xep.Muji.LIVENESS_NS_URI)
            .add_self_xmlns());
        return echo;
    }

    private StanzaNode build_unavailable(string from) {
        return new StanzaNode.build("presence")
            .put_attribute("from", from)
            .put_attribute("to", get_flag(Bind.Flag.IDENTITY).my_jid.to_string())
            .put_attribute("type", Presence.Stanza.TYPE_UNAVAILABLE);
    }

    public override async void setup() throws IOError {
    }
}

} // namespace Xmpp.Test
