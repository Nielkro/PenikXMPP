using Gee;

namespace Xmpp.Test {

/**
 * XEP-0167/XEP-0176 to SDP bridge tests for the Google/libwebrtc migration.
 *
 * These tests intentionally cover pure string conversion only. They do not
 * change the production RTP call path and do not instantiate libwebrtc.
 */
class JingleSdpBridgeAudit : Gee.TestCase {

    public JingleSdpBridgeAudit() {
        base("JingleSdpBridgeAudit");

        add_test("XEP0167_opus_payload_maps_to_stable_sdp", test_opus_payload_maps_to_stable_sdp);
        add_test("XEP0167_opus_fmtp_filters_non_opus_parameters", test_opus_fmtp_filters_non_opus_parameters);
        add_test("LOCALE_fmtp_tokens_keep_ascii_case_rules", test_fmtp_locale);
        add_test("XEP0167_vp8_rtcp_feedback_maps_to_sdp", test_vp8_rtcp_feedback_maps_to_sdp);
        add_test("XEP0176_ice_candidate_maps_to_sdp", test_ice_candidate_maps_to_sdp);
        add_test("DTLS_fingerprint_and_setup_map_to_sdp", test_dtls_fingerprint_and_setup_map_to_sdp);
        add_test("SDP_bridge_rejects_newline_injection", test_rejects_newline_injection);
        add_test("SDP_rtpmap_and_fmtp_parse_to_payload", test_rtpmap_and_fmtp_parse_to_payload);
        add_test("SDP_rtcp_feedback_parse", test_rtcp_feedback_parse);
        add_test("SDP_rtp_header_extension_roundtrip", test_rtp_header_extension_roundtrip);
        add_test("SDP_candidate_parse_to_jingle_candidate", test_candidate_parse_to_jingle_candidate);
        add_test("SDP_fingerprint_and_setup_parse", test_fingerprint_and_setup_parse);
        add_test("SDP_parser_rejects_invalid_values", test_parser_rejects_invalid_values);
        add_test("SDP_media_section_audio_roundtrip", test_media_section_audio_roundtrip);
        add_test("SDP_media_section_rejects_invalid_ice_shape", test_media_section_rejects_invalid_ice_shape);
        add_test("SDP_session_audio_video_bundle_roundtrip", test_session_audio_video_bundle_roundtrip);
        add_test("SDP_session_rejects_missing_required_lines", test_session_rejects_missing_required_lines);
        add_test("SDP_bundle_policy_is_explicit", test_bundle_policy_is_explicit);
        add_test("SDP_bundle_policy_rejects_invalid_mids", test_bundle_policy_rejects_invalid_mids);
        add_test("SDP_libwebrtc_bundle_fixture_parse", test_libwebrtc_bundle_fixture_parse);
        add_test("libwebrtc_adapter_local_sdp_maps_to_jingle_contents", test_libwebrtc_adapter_local_sdp_maps_to_jingle_contents);
        add_test("libwebrtc_adapter_low_bandwidth_opus_uses_negotiated_payload", test_libwebrtc_adapter_low_bandwidth_opus_uses_negotiated_payload);
        add_test("libwebrtc_adapter_remote_jingle_maps_to_sdp", test_libwebrtc_adapter_remote_jingle_maps_to_sdp);
        add_test("libwebrtc_adapter_direct_answer_preserves_offer_order", test_direct_answer_preserves_offer_order);
        add_test("libwebrtc_adapter_direct_answer_rejects_changed_identity", test_direct_answer_rejects_changed_identity);
        add_test("libwebrtc_adapter_maps_ice_candidates", test_libwebrtc_adapter_maps_ice_candidates);
        add_test("libwebrtc_adapter_muji_offer_maps_internal_mids", test_libwebrtc_adapter_muji_offer_maps_internal_mids);
        add_test("libwebrtc_adapter_muji_preparation_preserves_native_sources", test_muji_preparation_preserves_native_sources);
        add_test("libwebrtc_adapter_muji_projects_native_receiver_reference_time", test_muji_projects_native_receiver_reference_time);
        add_test("libwebrtc_adapter_muji_feedback_set_projection_preserves_frozen_map", test_muji_feedback_set_projection);
        add_test("libwebrtc_adapter_muji_feedback_set_rejects_capability_changes", test_muji_feedback_set_rejects_changes);
        add_test("libwebrtc_adapter_muji_committed_timing_is_verified", test_muji_committed_timing_is_verified);
        add_test("libwebrtc_adapter_muji_rtx_uses_media_timing", test_muji_rtx_uses_media_timing);
        add_test("libwebrtc_adapter_muji_prepared_timing_bounds", test_muji_prepared_timing_bounds);
        add_test("libwebrtc_adapter_muji_audio_payload_ids_roundtrip", test_libwebrtc_adapter_muji_audio_payload_ids_roundtrip);
        add_test("libwebrtc_adapter_muji_rtx_payload_ids_roundtrip", test_libwebrtc_adapter_muji_rtx_payload_ids_roundtrip);
        add_test("libwebrtc_adapter_muji_remote_answer_may_omit_rtx", test_libwebrtc_adapter_muji_remote_answer_may_omit_rtx);
        add_test("libwebrtc_adapter_muji_local_answer_may_omit_rtx", test_libwebrtc_adapter_muji_local_answer_may_omit_rtx);
        add_test("libwebrtc_adapter_muji_local_answer_rejects_orphan_rtx", test_libwebrtc_adapter_muji_local_answer_rejects_orphan_rtx);
        add_test("libwebrtc_adapter_muji_rejects_invalid_payload_maps", test_libwebrtc_adapter_muji_rejects_invalid_payload_maps);
        add_test("libwebrtc_adapter_muji_rejects_unrepresentable_content_names", test_libwebrtc_adapter_muji_rejects_unrepresentable_content_names);
        add_test("libwebrtc_adapter_direct_payload_ids_are_isolated", test_libwebrtc_adapter_direct_payload_ids_are_isolated);
        add_test("libwebrtc_adapter_muji_incoming_offer_preserves_conference_names", test_libwebrtc_adapter_muji_incoming_offer_preserves_conference_names);
        add_test("libwebrtc_adapter_muji_filters_pairwise_native_payloads", test_libwebrtc_adapter_muji_filters_pairwise_native_payloads);
        add_test("libwebrtc_adapter_muji_rejects_changed_receiving_parameters", test_libwebrtc_adapter_muji_rejects_changed_receiving_parameters);
        add_test("libwebrtc_adapter_muji_rejects_malformed_payload_metadata", test_libwebrtc_adapter_muji_rejects_malformed_payload_metadata);
        add_test("libwebrtc_adapter_muji_rejects_wrong_content_identity", test_libwebrtc_adapter_muji_rejects_wrong_content_identity);
        add_test("Jingle_nodes_audio_section_roundtrip", test_jingle_nodes_audio_section_roundtrip);
        add_test("Jingle_nodes_reject_invalid_shape", test_jingle_nodes_reject_invalid_shape);
        add_test("Jingle_content_node_pairs_session_roundtrip", test_jingle_content_node_pairs_session_roundtrip);
        add_test("Jingle_content_node_pairs_reject_invalid_shape", test_jingle_content_node_pairs_reject_invalid_shape);
        add_test("Jingle_dinox_style_content_pair_fixture_parse", test_dinox_style_content_pair_fixture_parse);
        add_test("Jingle_mobile_style_trickle_fixture_parse", test_mobile_style_trickle_fixture_parse);
    }

    private void test_fmtp_locale() {
        string? previous = Intl.setlocale(LocaleCategory.CTYPE, null);
        Intl.setlocale(LocaleCategory.CTYPE, "");
        try {
            var opus = new Xep.JingleRtp.PayloadType() { id = 111, name = "OPUS", clockrate = 48000, channels = 2 };
            opus.parameters["MINPTIME"] = "10";
            opus.parameters["USEINBANDFEC"] = "TRUE";
            fail_if_not_eq_str("a=fmtp:111 minptime=10;useinbandfec=1",
                Xep.JingleRtp.SdpBridge.payload_type_to_fmtp(opus));
        } catch (Error error) { fail_if_reached(error.message); }
        finally { Intl.setlocale(LocaleCategory.CTYPE, previous); }
    }

    private void test_opus_payload_maps_to_stable_sdp() {
        var opus = new Xep.JingleRtp.PayloadType() {
            id = 111,
            name = "opus",
            clockrate = 48000,
            channels = 2,
        };
        opus.parameters["useinbandfec"] = "1";
        opus.parameters["minptime"] = "10";

        try {
            Gee.List<string> lines = Xep.JingleRtp.SdpBridge.payload_type_to_sdp_attributes(opus);
            fail_if_not_eq_int(lines.size, 2, "Opus should map to rtpmap and fmtp");
            fail_if_not_eq_str(lines[0], "a=rtpmap:111 opus/48000/2", "Opus rtpmap should include stereo channels");
            fail_if_not_eq_str(lines[1], "a=fmtp:111 minptime=10;useinbandfec=1", "fmtp parameters must be deterministic");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"Opus payload conversion should not fail: $(e.message)");
        }
    }

    private void test_opus_fmtp_filters_non_opus_parameters() {
        var opus = new Xep.JingleRtp.PayloadType() {
            id = 111,
            name = "opus",
            clockrate = 48000,
            channels = 2,
        };
        opus.parameters["minptime"] = "10";
        opus.parameters["profile_level_id"] = "4325392";
        opus.parameters["useinbandfec"] = "true";

        try {
            string? fmtp = Xep.JingleRtp.SdpBridge.payload_type_to_fmtp(opus);
            fail_if_not_eq_str(fmtp, "a=fmtp:111 minptime=10;useinbandfec=1",
                "Opus SDP fmtp must filter foreign codec parameters and normalize booleans");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"Opus fmtp filtering should not fail: $(e.message)");
        }
    }

    private void test_vp8_rtcp_feedback_maps_to_sdp() {
        var vp8 = new Xep.JingleRtp.PayloadType() {
            id = 98,
            name = "VP8",
            clockrate = 90000,
        };
        vp8.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("nack", "pli"));
        vp8.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("goog-remb"));

        try {
            Gee.List<string> lines = Xep.JingleRtp.SdpBridge.payload_type_to_sdp_attributes(vp8);
            fail_if_not_eq_int(lines.size, 3, "VP8 should map to rtpmap and two rtcp-fb lines");
            fail_if_not_eq_str(lines[0], "a=rtpmap:98 VP8/90000", "VP8 rtpmap should omit channels");
            fail_if_not_eq_str(lines[1], "a=rtcp-fb:98 nack pli", "RTCP PLI feedback should map to SDP");
            fail_if_not_eq_str(lines[2], "a=rtcp-fb:98 goog-remb", "RTCP REMB feedback should map to SDP");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"VP8 payload conversion should not fail: $(e.message)");
        }
    }

    private void test_ice_candidate_maps_to_sdp() {
        var candidate = new Xep.JingleIceUdp.Candidate();
        candidate.component = 1;
        candidate.foundation = "1";
        candidate.generation = 0;
        candidate.id = "candidate-1";
        candidate.ip = "203.0.113.10";
        candidate.network = 0;
        candidate.port = 5000;
        candidate.priority = 1000;
        candidate.protocol = "UDP";
        candidate.rel_addr = "10.0.0.2";
        candidate.rel_port = 5001;
        candidate.type_ = Xep.JingleIceUdp.Candidate.Type.SRFLX;

        try {
            string line = Xep.JingleRtp.SdpBridge.candidate_to_sdp(candidate);
            fail_if_not_eq_str(line,
                "a=candidate:1 1 udp 1000 203.0.113.10 5000 typ srflx raddr 10.0.0.2 rport 5001 generation 0",
                "ICE candidate should map to libwebrtc-style SDP syntax");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"ICE candidate conversion should not fail: $(e.message)");
        }
    }

    private void test_dtls_fingerprint_and_setup_map_to_sdp() {
        uint8[] fingerprint = { 0x01, 0xab, 0xff };

        try {
            fail_if_not_eq_str(
                Xep.JingleRtp.SdpBridge.fingerprint_to_sdp("SHA-256", fingerprint),
                "a=fingerprint:sha-256 01:AB:FF",
                "DTLS fingerprint should be uppercase colon-separated hex");
            fail_if_not_eq_str(
                Xep.JingleRtp.SdpBridge.setup_to_sdp("actpass"),
                "a=setup:actpass",
                "DTLS setup should map to SDP setup attribute");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"DTLS conversion should not fail: $(e.message)");
        }
    }

    private void test_rejects_newline_injection() {
        var opus = new Xep.JingleRtp.PayloadType() {
            id = 111,
            name = "opus",
            clockrate = 48000,
            channels = 2,
        };
        opus.parameters["useinbandfec"] = "1\na=ice-lite";

        try {
            Xep.JingleRtp.SdpBridge.payload_type_to_fmtp(opus);
            fail_if_reached("SDP bridge must reject newline injection in generated SDP");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private void test_rtpmap_and_fmtp_parse_to_payload() {
        try {
            Xep.JingleRtp.PayloadType opus = Xep.JingleRtp.SdpBridge.payload_type_from_rtpmap(
                "a=rtpmap:111 opus/48000/2");
            Xep.JingleRtp.SdpBridge.apply_fmtp_to_payload(opus,
                "a=fmtp:111 minptime=10; useinbandfec=1");

            fail_if_not_eq_uint(opus.id, 111, "rtpmap parser should preserve payload id");
            fail_if_not_eq_str(opus.name, "opus", "rtpmap parser should preserve codec name");
            fail_if_not_eq_uint(opus.clockrate, 48000, "rtpmap parser should preserve clockrate");
            fail_if_not_eq_uint(opus.channels, 2, "rtpmap parser should preserve channels");
            fail_if_not_eq_str(opus.parameters["minptime"], "10", "fmtp parser should preserve minptime");
            fail_if_not_eq_str(opus.parameters["useinbandfec"], "1", "fmtp parser should preserve FEC");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"RTP payload parse should not fail: $(e.message)");
        }
    }

    private void test_rtcp_feedback_parse() {
        try {
            uint8 payload_id;
            Xep.JingleRtp.RtcpFeedback feedback = Xep.JingleRtp.SdpBridge.rtcp_feedback_from_sdp(
                "a=rtcp-fb:98 nack pli", out payload_id);

            fail_if_not_eq_uint(payload_id, 98, "rtcp-fb parser should preserve payload id");
            fail_if_not_eq_str(feedback.type_, "nack", "rtcp-fb parser should preserve type");
            fail_if_not_eq_str(feedback.subtype, "pli", "rtcp-fb parser should preserve subtype");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"RTCP feedback parse should not fail: $(e.message)");
        }
    }

    private void test_rtp_header_extension_roundtrip() {
        try {
            Xep.JingleRtp.SdpHeaderExtension extension =
                Xep.JingleRtp.SdpBridge.header_extension_from_sdp(
                    "a=extmap:5/recvonly urn:ietf:params:rtp-hdrext:toffset mode=fast bare");
            fail_if_not_eq_uint(extension.id, 5, "extmap parser should preserve the extension id");
            fail_if_not_eq_str(extension.uri, "urn:ietf:params:rtp-hdrext:toffset",
                "extmap parser should preserve the extension URI");
            fail_if_not(extension.direction == Xep.JingleRtp.SdpMediaDirection.RECV_ONLY,
                "extmap parser should preserve the extension direction");
            fail_if_not_eq_int(extension.parameters.size, 2,
                "extmap parser should preserve keyed and bare parameters");
            fail_if_not_eq_str(extension.parameters[0].name, "mode",
                "extmap parser should preserve the keyed parameter name");
            fail_if_not_eq_str(extension.parameters[0].value, "fast",
                "extmap parser should preserve the keyed parameter value");
            fail_if_not_eq_str(extension.parameters[1].name, "bare",
                "extmap parser should preserve a bare parameter");
            fail_if(extension.parameters[1].value != null,
                "bare extmap parameters must not gain a value");
            fail_if_not_eq_str(
                Xep.JingleRtp.SdpBridge.header_extension_to_sdp(extension),
                "a=extmap:5/recvonly urn:ietf:params:rtp-hdrext:toffset mode=fast bare",
                "extmap serialization should roundtrip deterministically");

            try {
                Xep.JingleRtp.SdpBridge.header_extension_from_sdp(
                    "a=extmap:0 urn:ietf:params:rtp-hdrext:toffset");
                fail_if_reached("extmap id zero must be rejected");
            } catch (Xep.Jingle.IqError e) {
                // Expected.
            }
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"RTP header extension roundtrip should not fail: $(e.message)");
        }
    }

    private void test_candidate_parse_to_jingle_candidate() {
        try {
            Xep.JingleIceUdp.Candidate candidate = Xep.JingleRtp.SdpBridge.candidate_from_sdp(
                "a=candidate:1 1 udp 1000 203.0.113.10 5000 typ srflx raddr 10.0.0.2 rport 5001 generation 0",
                "candidate-1");

            fail_if_not_eq_str(candidate.id, "candidate-1", "candidate parser should use supplied id");
            fail_if_not_eq_str(candidate.foundation, "1", "candidate parser should preserve foundation");
            fail_if_not_eq_uint(candidate.component, 1, "candidate parser should preserve component");
            fail_if_not_eq_str(candidate.protocol, "udp", "candidate parser should normalize protocol");
            fail_if_not_eq_uint(candidate.priority, 1000, "candidate parser should preserve priority");
            fail_if_not_eq_str(candidate.ip, "203.0.113.10", "candidate parser should preserve IP");
            fail_if_not_eq_uint(candidate.port, 5000, "candidate parser should preserve port");
            fail_if_not(candidate.type_ == Xep.JingleIceUdp.Candidate.Type.SRFLX, "candidate parser should preserve type");
            fail_if_not_eq_str(candidate.rel_addr, "10.0.0.2", "candidate parser should preserve related address");
            fail_if_not_eq_uint(candidate.rel_port, 5001, "candidate parser should preserve related port");
            fail_if_not_eq_uint(candidate.generation, 0, "candidate parser should preserve generation");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"ICE candidate parse should not fail: $(e.message)");
        }
    }

    private void test_fingerprint_and_setup_parse() {
        try {
            Xep.JingleRtp.SdpFingerprint fingerprint = Xep.JingleRtp.SdpBridge.fingerprint_from_sdp(
                "a=fingerprint:sha-256 01:AB:ff");
            fail_if_not_eq_str(fingerprint.hash, "sha-256", "fingerprint parser should normalize hash");
            fail_if_not_eq_int(fingerprint.fingerprint.length, 3, "fingerprint parser should preserve octet count");
            fail_if_not_eq_uint(fingerprint.fingerprint[0], 0x01, "fingerprint parser should parse first octet");
            fail_if_not_eq_uint(fingerprint.fingerprint[1], 0xab, "fingerprint parser should parse second octet");
            fail_if_not_eq_uint(fingerprint.fingerprint[2], 0xff, "fingerprint parser should parse third octet");

            fail_if_not_eq_str(
                Xep.JingleRtp.SdpBridge.setup_from_sdp("a=setup:passive"),
                "passive",
                "setup parser should preserve valid setup value");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"DTLS parse should not fail: $(e.message)");
        }
    }

    private void test_parser_rejects_invalid_values() {
        var invalid_outgoing_payload = new Xep.JingleRtp.PayloadType() {
            id = 128,
            name = "opus",
            clockrate = 48000,
            channels = 2,
        };
        try {
            Xep.JingleRtp.SdpBridge.payload_type_to_rtpmap(invalid_outgoing_payload);
            fail_if_reached("Outgoing RTP payload ids outside 0-127 must be rejected");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            Xep.JingleRtp.SdpBridge.payload_type_from_rtpmap("a=rtpmap:128 opus/48000/2");
            fail_if_reached("RTP payload ids outside 0-127 must be rejected");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            Xep.JingleRtp.SdpBridge.payload_type_from_rtpmap("a=rtpmap:111 opus/0/2");
            fail_if_reached("RTP clockrate 0 must be rejected");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            Xep.JingleRtp.SdpBridge.candidate_from_sdp(
                "a=candidate:1 1 udp bad-priority 203.0.113.10 5000 typ host");
            fail_if_reached("Invalid numeric candidate priority must be rejected");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            Xep.JingleRtp.SdpBridge.fingerprint_from_sdp("a=fingerprint:sha-256 01:XX");
            fail_if_reached("Invalid fingerprint hex must be rejected");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            Xep.JingleRtp.SdpBridge.setup_from_sdp("a=setup:invalid");
            fail_if_reached("Invalid DTLS setup must be rejected");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private Xep.JingleRtp.PayloadType create_opus_payload() {
        var opus = new Xep.JingleRtp.PayloadType() {
            id = 111,
            name = "opus",
            clockrate = 48000,
            channels = 2,
        };
        opus.parameters["useinbandfec"] = "1";
        opus.parameters["minptime"] = "10";
        opus.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("nack", "pli"));
        return opus;
    }

    private Xep.JingleIceUdp.Candidate create_srflx_candidate() {
        var candidate = new Xep.JingleIceUdp.Candidate();
        candidate.component = 1;
        candidate.foundation = "1";
        candidate.generation = 0;
        candidate.id = "candidate-1";
        candidate.ip = "203.0.113.10";
        candidate.network = 0;
        candidate.port = 5000;
        candidate.priority = 1000;
        candidate.protocol = "UDP";
        candidate.rel_addr = "10.0.0.2";
        candidate.rel_port = 5001;
        candidate.type_ = Xep.JingleIceUdp.Candidate.Type.SRFLX;
        return candidate;
    }

    private Xep.JingleRtp.PayloadType create_vp8_payload() {
        var vp8 = new Xep.JingleRtp.PayloadType() {
            id = 98,
            name = "VP8",
            clockrate = 90000,
        };
        vp8.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("nack", "pli"));
        return vp8;
    }

    private Xep.JingleRtp.PayloadType create_h264_payload() {
        var h264 = new Xep.JingleRtp.PayloadType() {
            id = 102,
            name = "H264",
            clockrate = 90000,
        };
        h264.parameters["packetization-mode"] = "1";
        h264.parameters["profile-level-id"] = "42e01f";
        h264.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("nack", "pli"));
        return h264;
    }

    private StanzaNode create_jingle_description_node(string media, Gee.List<Xep.JingleRtp.PayloadType> payloads, bool rtcp_mux = true) {
        var description = new StanzaNode.build("description", Xep.JingleRtp.NS_URI)
                .add_self_xmlns()
                .put_attribute("media", media);
        foreach (Xep.JingleRtp.PayloadType payload in payloads) {
            description.put_node(payload.to_xml());
        }
        if (rtcp_mux) {
            description.put_node(new StanzaNode.build("rtcp-mux", Xep.JingleRtp.NS_URI));
        }
        return description;
    }

    private StanzaNode create_jingle_transport_node(string ufrag, string pwd, string setup, string fingerprint_text, bool with_candidate) {
        var transport = new StanzaNode.build("transport", Xep.JingleIceUdp.NS_URI)
                .add_self_xmlns()
                .put_attribute("ufrag", ufrag)
                .put_attribute("pwd", pwd)
                .put_node(new StanzaNode.build("fingerprint", Xep.JingleIceUdp.DTLS_NS_URI)
                    .add_self_xmlns()
                    .put_attribute("hash", "sha-256")
                    .put_attribute("setup", setup)
                    .put_node(new StanzaNode.text(fingerprint_text)));
        if (with_candidate) {
            transport.put_node(create_srflx_candidate().to_xml());
        }
        return transport;
    }

    private void test_media_section_audio_roundtrip() {
        uint8[] fingerprint = { 0x01, 0xab, 0xff };
        var section = new Xep.JingleRtp.SdpMediaSection("audio");
        section.mid = "0";
        section.ice_ufrag = "ufrag123";
        section.ice_pwd = "pwd456789";
        section.fingerprint = new Xep.JingleRtp.SdpFingerprint("sha-256", fingerprint);
        section.setup = "actpass";
        section.rtcp_mux = true;
        section.payload_types.add(create_opus_payload());
        section.candidates.add(create_srflx_candidate());

        try {
            Gee.List<string> lines = Xep.JingleRtp.SdpBridge.media_section_to_sdp_lines(section);
            fail_if_not_eq_int(lines.size, 11, "media section should produce stable line count");
            fail_if_not_eq_str(lines[0], "m=audio 9 UDP/TLS/RTP/SAVPF 111", "media line should carry payload id");
            fail_if_not_eq_str(lines[1], "a=mid:0", "media section should carry MID");
            fail_if_not_eq_str(lines[2], "a=ice-ufrag:ufrag123", "media section should carry ICE ufrag");
            fail_if_not_eq_str(lines[3], "a=ice-pwd:pwd456789", "media section should carry ICE pwd");
            fail_if_not_eq_str(lines[4], "a=fingerprint:sha-256 01:AB:FF", "media section should carry fingerprint");
            fail_if_not_eq_str(lines[5], "a=setup:actpass", "media section should carry setup");
            fail_if_not_eq_str(lines[6], "a=rtcp-mux", "media section should carry rtcp-mux");
            fail_if_not_eq_str(lines[7], "a=rtpmap:111 opus/48000/2", "media section should carry rtpmap");
            fail_if_not_eq_str(lines[8], "a=fmtp:111 minptime=10;useinbandfec=1", "media section should carry fmtp");
            fail_if_not_eq_str(lines[9], "a=rtcp-fb:111 nack pli", "media section should carry rtcp feedback");
            fail_if_not_eq_str(lines[10],
                "a=candidate:1 1 udp 1000 203.0.113.10 5000 typ srflx raddr 10.0.0.2 rport 5001 generation 0",
                "media section should carry ICE candidate");

            string sdp = Xep.JingleRtp.SdpBridge.media_section_to_sdp(section);
            fail_if(!sdp.has_suffix("\r\n"), "serialized media section should use SDP CRLF line endings");

            Xep.JingleRtp.SdpMediaSection parsed = Xep.JingleRtp.SdpBridge.media_section_from_sdp_lines(lines);
            fail_if_not_eq_str(parsed.media, "audio", "parsed section should preserve media");
            fail_if_not_eq_uint(parsed.port, 9, "parsed section should preserve port");
            fail_if_not_eq_str(parsed.protocol, "UDP/TLS/RTP/SAVPF", "parsed section should preserve protocol");
            fail_if_not_eq_str(parsed.mid, "0", "parsed section should preserve MID");
            fail_if_not_eq_str(parsed.ice_ufrag, "ufrag123", "parsed section should preserve ICE ufrag");
            fail_if_not_eq_str(parsed.ice_pwd, "pwd456789", "parsed section should preserve ICE pwd");
            fail_if(parsed.fingerprint == null, "parsed section should preserve fingerprint");
            if (parsed.fingerprint != null) {
                fail_if_not_eq_str(((!) parsed.fingerprint).hash, "sha-256", "parsed section should preserve fingerprint hash");
                fail_if_not_eq_int(((!) parsed.fingerprint).fingerprint.length, 3, "parsed section should preserve fingerprint size");
            }
            fail_if_not_eq_str(parsed.setup, "actpass", "parsed section should preserve setup");
            fail_if_not(parsed.rtcp_mux, "parsed section should preserve rtcp-mux");
            fail_if_not_eq_int(parsed.payload_types.size, 1, "parsed section should preserve payload count");
            fail_if_not_eq_str(parsed.payload_types[0].name, "opus", "parsed section should preserve payload name");
            fail_if_not_eq_str(parsed.payload_types[0].parameters["useinbandfec"], "1", "parsed section should preserve fmtp");
            fail_if_not_eq_int(parsed.payload_types[0].rtcp_fbs.size, 1, "parsed section should preserve rtcp feedback");
            fail_if_not_eq_int(parsed.candidates.size, 1, "parsed section should preserve candidate count");
            fail_if_not_eq_str(parsed.candidates[0].ip, "203.0.113.10", "parsed section should preserve candidate IP");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"Media section roundtrip should not fail: $(e.message)");
        }
    }

    private void test_media_section_rejects_invalid_ice_shape() {
        var section = new Xep.JingleRtp.SdpMediaSection("audio");
        section.ice_ufrag = "ufrag-only";
        section.payload_types.add(create_opus_payload());

        try {
            Xep.JingleRtp.SdpBridge.media_section_to_sdp_lines(section);
            fail_if_reached("Media section serialization must reject half-present ICE credentials");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        var lines = new ArrayList<string>();
        lines.add("m=audio 9 UDP/TLS/RTP/SAVPF 111");
        lines.add("a=ice-ufrag:ufrag-only");
        lines.add("a=rtpmap:111 opus/48000/2");

        try {
            Xep.JingleRtp.SdpBridge.media_section_from_sdp_lines(lines);
            fail_if_reached("Media section parsing must reject half-present ICE credentials");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private Xep.JingleRtp.SdpMediaSection create_audio_media_section() {
        uint8[] fingerprint = { 0x01, 0xab, 0xff };
        var section = new Xep.JingleRtp.SdpMediaSection("audio");
        section.mid = "0";
        section.ice_ufrag = "audio-ufrag";
        section.ice_pwd = "audio-pwd";
        section.fingerprint = new Xep.JingleRtp.SdpFingerprint("sha-256", fingerprint);
        section.setup = "actpass";
        section.rtcp_mux = true;
        section.payload_types.add(create_opus_payload());
        section.candidates.add(create_srflx_candidate());
        return section;
    }

    private Xep.JingleRtp.SdpMediaSection create_video_media_section() {
        uint8[] fingerprint = { 0xaa, 0xbb, 0xcc };
        var section = new Xep.JingleRtp.SdpMediaSection("video");
        section.mid = "1";
        section.ice_ufrag = "video-ufrag";
        section.ice_pwd = "video-pwd";
        section.fingerprint = new Xep.JingleRtp.SdpFingerprint("sha-256", fingerprint);
        section.setup = "actpass";
        section.rtcp_mux = true;
        section.payload_types.add(create_vp8_payload());
        return section;
    }

    private void test_session_audio_video_bundle_roundtrip() {
        var session = new Xep.JingleRtp.SdpSession();
        session.origin_session_id = "123456789";
        session.origin_session_version = "2";
        session.bundle_mids.add("0");
        session.bundle_mids.add("1");
        session.media_sections.add(create_audio_media_section());
        session.media_sections.add(create_video_media_section());

        try {
            Gee.List<string> lines = Xep.JingleRtp.SdpBridge.session_to_sdp_lines(session);
            fail_if_not_eq_str(lines[0], "v=0", "session should start with SDP version");
            fail_if_not_eq_str(lines[1], "o=- 123456789 2 IN IP4 0.0.0.0", "session should carry origin");
            fail_if_not_eq_str(lines[2], "s=-", "session should carry session name");
            fail_if_not_eq_str(lines[3], "t=0 0", "session should carry zero timing");
            fail_if_not_eq_str(lines[4], "a=group:BUNDLE 0 1", "session should carry BUNDLE group");
            fail_if(lines.index_of("m=audio 9 UDP/TLS/RTP/SAVPF 111") < 0,
                "session should contain audio media section");
            fail_if(lines.index_of("m=video 9 UDP/TLS/RTP/SAVPF 98") < 0,
                "session should contain video media section");

            string sdp = Xep.JingleRtp.SdpBridge.session_to_sdp(session);
            fail_if(!sdp.has_prefix("v=0\r\n"), "serialized session should use SDP CRLF line endings");
            fail_if(!sdp.has_suffix("\r\n"), "serialized session should end with CRLF");

            Xep.JingleRtp.SdpSession parsed = Xep.JingleRtp.SdpBridge.session_from_sdp(sdp);
            fail_if_not_eq_str(parsed.origin_session_id, "123456789", "parsed session should preserve origin id");
            fail_if_not_eq_str(parsed.origin_session_version, "2", "parsed session should preserve origin version");
            fail_if_not_eq_int(parsed.bundle_mids.size, 2, "parsed session should preserve BUNDLE mids");
            fail_if_not_eq_str(parsed.bundle_mids[0], "0", "parsed session should preserve first BUNDLE mid");
            fail_if_not_eq_str(parsed.bundle_mids[1], "1", "parsed session should preserve second BUNDLE mid");
            fail_if_not_eq_int(parsed.media_sections.size, 2, "parsed session should preserve media section count");
            fail_if_not_eq_str(parsed.media_sections[0].media, "audio", "parsed session should preserve audio section");
            fail_if_not_eq_str(parsed.media_sections[1].media, "video", "parsed session should preserve video section");
            fail_if_not_eq_str(parsed.media_sections[1].payload_types[0].name, "VP8",
                "parsed session should preserve video payload");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"SDP session roundtrip should not fail: $(e.message)");
        }
    }

    private void test_session_rejects_missing_required_lines() {
        var no_media = new Xep.JingleRtp.SdpSession();
        try {
            Xep.JingleRtp.SdpBridge.session_to_sdp_lines(no_media);
            fail_if_reached("Session serialization must reject empty media set");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        var missing_timing = new ArrayList<string>();
        missing_timing.add("v=0");
        missing_timing.add("o=- 1 1 IN IP4 0.0.0.0");
        missing_timing.add("s=-");
        missing_timing.add("m=audio 9 UDP/TLS/RTP/SAVPF 111");
        missing_timing.add("a=rtpmap:111 opus/48000/2");

        try {
            Xep.JingleRtp.SdpBridge.session_from_sdp_lines(missing_timing);
            fail_if_reached("Session parsing must reject missing timing line");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        var unsupported_version = new ArrayList<string>();
        unsupported_version.add("v=1");
        unsupported_version.add("o=- 1 1 IN IP4 0.0.0.0");
        unsupported_version.add("s=-");
        unsupported_version.add("t=0 0");
        unsupported_version.add("m=audio 9 UDP/TLS/RTP/SAVPF 111");
        unsupported_version.add("a=rtpmap:111 opus/48000/2");

        try {
            Xep.JingleRtp.SdpBridge.session_from_sdp_lines(unsupported_version);
            fail_if_reached("Session parsing must reject unsupported SDP version");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private void test_bundle_policy_is_explicit() {
        var session = new Xep.JingleRtp.SdpSession();
        session.media_sections.add(create_audio_media_section());
        session.media_sections.add(create_video_media_section());

        try {
            Xep.JingleRtp.SdpBridge.apply_bundle_policy(session, Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_not_eq_int(session.bundle_mids.size, 2, "BUNDLE-all policy should add every media MID");
            fail_if_not_eq_str(session.bundle_mids[0], "0", "BUNDLE-all policy should preserve audio MID");
            fail_if_not_eq_str(session.bundle_mids[1], "1", "BUNDLE-all policy should preserve video MID");

            string bundled_sdp = Xep.JingleRtp.SdpBridge.session_to_sdp(session);
            fail_if(!bundled_sdp.contains("a=group:BUNDLE 0 1\r\n"),
                "BUNDLE-all policy should serialize explicit BUNDLE group");

            Xep.JingleRtp.SdpBridge.apply_bundle_policy(session, Xep.JingleRtp.SdpBundlePolicy.NONE);
            fail_if_not_eq_int(session.bundle_mids.size, 0, "BUNDLE-none policy should clear BUNDLE mids");

            string unbundled_sdp = Xep.JingleRtp.SdpBridge.session_to_sdp(session);
            fail_if(unbundled_sdp.contains("a=group:BUNDLE"),
                "BUNDLE-none policy must not serialize a BUNDLE group");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"BUNDLE policy should not fail for valid MIDs: $(e.message)");
        }
    }

    private void test_bundle_policy_rejects_invalid_mids() {
        var missing_mid_session = new Xep.JingleRtp.SdpSession();
        var missing_mid = create_audio_media_section();
        missing_mid.mid = null;
        missing_mid_session.media_sections.add(missing_mid);

        try {
            Xep.JingleRtp.SdpBridge.apply_bundle_policy(
                missing_mid_session,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_reached("BUNDLE-all policy must reject media sections without MID");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        var duplicate_mid_session = new Xep.JingleRtp.SdpSession();
        var audio = create_audio_media_section();
        var video = create_video_media_section();
        video.mid = audio.mid;
        duplicate_mid_session.media_sections.add(audio);
        duplicate_mid_session.media_sections.add(video);

        try {
            Xep.JingleRtp.SdpBridge.apply_bundle_policy(
                duplicate_mid_session,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_reached("BUNDLE-all policy must reject duplicate MIDs");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private string create_libwebrtc_bundle_sdp_fixture() {
        return "v=0\r\n" +
            "o=- 46117327 2 IN IP4 127.0.0.1\r\n" +
            "s=-\r\n" +
            "t=0 0\r\n" +
            "a=group:BUNDLE 0 1\r\n" +
            "a=extmap-allow-mixed\r\n" +
            "a=msid-semantic: WMS stream1\r\n" +
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 63\r\n" +
            "c=IN IP4 0.0.0.0\r\n" +
            "a=rtcp:9 IN IP4 0.0.0.0\r\n" +
            "a=ice-ufrag:libaudio\r\n" +
            "a=ice-pwd:audioPassword0123456789\r\n" +
            "a=ice-options:trickle\r\n" +
            "a=fingerprint:sha-256 01:23:45:67:89:AB:CD:EF\r\n" +
            "a=setup:actpass\r\n" +
            "a=mid:0\r\n" +
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n" +
            "a=sendrecv\r\n" +
            "a=msid:stream1 audioTrack1\r\n" +
            "a=rtcp-mux\r\n" +
            "a=rtcp-rsize\r\n" +
            "a=rtpmap:111 opus/48000/2\r\n" +
            "a=fmtp:111 minptime=10;useinbandfec=1\r\n" +
            "a=rtcp-fb:111 transport-cc\r\n" +
            "a=rtpmap:63 red/48000/2\r\n" +
            "a=fmtp:63 111/111\r\n" +
            "a=ssrc:1234 cname:audioCname\r\n" +
            "a=candidate:1 1 udp 2122260223 192.0.2.10 54321 typ host generation 0 network-id 1 network-cost 10\r\n" +
            "a=end-of-candidates\r\n" +
            "m=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n" +
            "c=IN IP4 0.0.0.0\r\n" +
            "a=rtcp:9 IN IP4 0.0.0.0\r\n" +
            "a=ice-ufrag:libvideo\r\n" +
            "a=ice-pwd:videoPassword0123456789\r\n" +
            "a=ice-options:trickle\r\n" +
            "a=fingerprint:sha-256 FE:DC:BA:98:76:54:32:10\r\n" +
            "a=setup:actpass\r\n" +
            "a=mid:1\r\n" +
            "a=extmap:3 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n" +
            "a=sendrecv\r\n" +
            "a=msid:stream1 videoTrack1\r\n" +
            "a=rtcp-mux\r\n" +
            "a=rtcp-rsize\r\n" +
            "a=rtpmap:96 VP8/90000\r\n" +
            "a=rtcp-fb:96 goog-remb\r\n" +
            "a=rtcp-fb:96 transport-cc\r\n" +
            "a=rtcp-fb:96 ccm fir\r\n" +
            "a=rtcp-fb:96 nack\r\n" +
            "a=rtcp-fb:96 nack pli\r\n" +
            "a=rtpmap:97 rtx/90000\r\n" +
            "a=fmtp:97 apt=96\r\n" +
            "a=ssrc:5678 cname:videoCname\r\n" +
            "a=candidate:2 1 udp 2122260222 192.0.2.11 54322 typ host generation 0 network-id 1 network-cost 10\r\n" +
            "a=end-of-candidates\r\n";
    }

    private string create_muji_local_answer_sdp_fixture() {
        // A real PeerConnection answer contains only codecs from the remote
        // conference offer. Keep the broader parser fixture reusable while
        // modelling that negotiated subset here.
        return create_libwebrtc_bundle_sdp_fixture()
            .replace("m=audio 9 UDP/TLS/RTP/SAVPF 111 63\r\n",
                "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n")
            .replace("a=rtpmap:63 red/48000/2\r\n", "")
            .replace("a=fmtp:63 111/111\r\n", "")
            .replace("m=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n",
                "m=video 9 UDP/TLS/RTP/SAVPF 98\r\n")
            .replace("a=rtpmap:96 VP8/90000\r\n",
                "a=rtpmap:98 VP8/90000\r\n")
            .replace("a=rtcp-fb:96", "a=rtcp-fb:98")
            .replace("a=rtpmap:97 rtx/90000\r\n", "")
            .replace("a=fmtp:97 apt=96\r\n", "");
    }

    private void test_libwebrtc_bundle_fixture_parse() {
        try {
            Xep.JingleRtp.SdpSession parsed = Xep.JingleRtp.SdpBridge.session_from_sdp(
                create_libwebrtc_bundle_sdp_fixture());

            fail_if_not_eq_str(parsed.origin_session_id, "46117327",
                "libwebrtc fixture should preserve origin session id");
            fail_if_not_eq_str(parsed.origin_session_version, "2",
                "libwebrtc fixture should preserve origin version");
            fail_if_not_eq_int(parsed.bundle_mids.size, 2,
                "libwebrtc fixture should preserve BUNDLE mids");
            fail_if_not_eq_str(parsed.bundle_mids[0], "0",
                "libwebrtc fixture should preserve audio BUNDLE mid");
            fail_if_not_eq_str(parsed.bundle_mids[1], "1",
                "libwebrtc fixture should preserve video BUNDLE mid");
            fail_if_not_eq_int(parsed.media_sections.size, 2,
                "libwebrtc fixture should preserve media section count");

            Xep.JingleRtp.SdpMediaSection audio = parsed.media_sections[0];
            fail_if_not_eq_str(audio.media, "audio", "libwebrtc fixture should preserve audio media");
            fail_if_not_eq_str(audio.mid, "0", "libwebrtc fixture should preserve audio MID");
            fail_if_not_eq_str(audio.ice_ufrag, "libaudio", "libwebrtc fixture should preserve audio ICE ufrag");
            fail_if_not_eq_str(audio.ice_pwd, "audioPassword0123456789", "libwebrtc fixture should preserve audio ICE pwd");
            fail_if_not(audio.rtcp_mux, "libwebrtc fixture should preserve audio rtcp-mux");
            fail_if(audio.fingerprint == null, "libwebrtc fixture should preserve audio fingerprint");
            fail_if_not_eq_str(audio.setup, "actpass", "libwebrtc fixture should preserve audio setup");
            fail_if(audio.direction == null, "libwebrtc fixture should preserve audio direction");
            if (audio.direction != null) {
                fail_if_not(((!) audio.direction) == Xep.JingleRtp.SdpMediaDirection.SEND_RECV,
                    "libwebrtc fixture should preserve audio sendrecv direction");
            }
            fail_if_not_eq_int(audio.payload_types.size, 2, "libwebrtc fixture should preserve audio payload count");
            fail_if_not_eq_str(audio.payload_types[0].name, "opus", "libwebrtc fixture should preserve Opus");
            fail_if_not_eq_str(audio.payload_types[0].parameters["useinbandfec"], "1",
                "libwebrtc fixture should preserve Opus fmtp");
            fail_if_not_eq_int(audio.payload_types[0].rtcp_fbs.size, 1,
                "libwebrtc fixture should preserve audio rtcp-fb");
            fail_if_not_eq_str(audio.payload_types[0].rtcp_fbs[0].type_, "transport-cc",
                "libwebrtc fixture should preserve audio transport-cc feedback");
            fail_if_not_eq_str(audio.payload_types[1].name, "red", "libwebrtc fixture should tolerate RED payload");
            fail_if_not_eq_int(audio.payload_types[1].parameters.size, 0,
                "bare libwebrtc RED fmtp should be ignored because Jingle RTP parameters require name/value shape");
            fail_if_not(audio.extmap_allow_mixed,
                "session-level extmap-allow-mixed should apply to the audio media section");
            fail_if_not_eq_int(audio.header_extensions.size, 1,
                "libwebrtc audio extmap must become first-class bridge data");
            fail_if_not_eq_str(audio.header_extensions[0].uri,
                "urn:ietf:params:rtp-hdrext:ssrc-audio-level",
                "libwebrtc audio-level extmap URI should survive parsing");
            fail_if_not_eq_int(audio.candidates.size, 1,
                "libwebrtc fixture should preserve audio ICE candidate");
            fail_if_not_eq_str(audio.candidates[0].ip, "192.0.2.10",
                "libwebrtc fixture should preserve audio candidate IP");

            Xep.JingleRtp.SdpMediaSection video = parsed.media_sections[1];
            fail_if_not_eq_str(video.media, "video", "libwebrtc fixture should preserve video media");
            fail_if_not_eq_str(video.mid, "1", "libwebrtc fixture should preserve video MID");
            fail_if_not_eq_str(video.ice_ufrag, "libvideo", "libwebrtc fixture should preserve video ICE ufrag");
            fail_if_not(video.rtcp_mux, "libwebrtc fixture should preserve video rtcp-mux");
            fail_if_not_eq_int(video.payload_types.size, 2, "libwebrtc fixture should preserve VP8 and RTX");
            fail_if_not_eq_str(video.payload_types[0].name, "VP8", "libwebrtc fixture should preserve VP8");
            fail_if_not_eq_int(video.payload_types[0].rtcp_fbs.size, 5,
                "libwebrtc fixture should preserve VP8 feedback lines");
            fail_if_not_eq_str(video.payload_types[1].name, "rtx", "libwebrtc fixture should preserve RTX");
            fail_if_not_eq_str(video.payload_types[1].parameters["apt"], "96",
                "libwebrtc fixture should preserve RTX apt fmtp");
            fail_if_not(video.extmap_allow_mixed,
                "session-level extmap-allow-mixed should apply to the video media section");
            fail_if_not_eq_int(video.header_extensions.size, 1,
                "libwebrtc video extmap must become first-class bridge data");
            fail_if_not_eq_str(video.header_extensions[0].uri,
                "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
                "libwebrtc absolute-send-time extmap URI should survive parsing");
            fail_if_not_eq_int(video.candidates.size, 1,
                "libwebrtc fixture should preserve video ICE candidate");

            string roundtrip = Xep.JingleRtp.SdpBridge.session_to_sdp(parsed);
            fail_if(!roundtrip.contains("a=extmap-allow-mixed\r\n"),
                "libwebrtc SDP roundtrip should preserve extmap-allow-mixed");
            fail_if(!roundtrip.contains(
                    "a=extmap:3 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n"),
                "libwebrtc SDP roundtrip should preserve the video extmap");

            Gee.List<Xep.JingleRtp.SdpJingleContentNodePair> pairs =
                Xep.JingleRtp.SdpBridge.jingle_content_node_pairs_from_session(parsed);
            fail_if_not_eq_int(pairs.size, 2, "libwebrtc fixture should convert to Jingle node pairs");
            fail_if_not_eq_str(pairs[0].content_name, "0",
                "libwebrtc fixture should use audio MID as Jingle content name");
            fail_if_not_eq_str(pairs[1].content_name, "1",
                "libwebrtc fixture should use video MID as Jingle content name");
            fail_if_not_eq_str(pairs[0].description.get_attribute("media"), "audio",
                "libwebrtc fixture should create audio RTP description");
            fail_if_not_eq_str(pairs[1].description.get_attribute("media"), "video",
                "libwebrtc fixture should create video RTP description");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"libwebrtc-style SDP fixture should parse: $(e.message)");
        }
    }

    private ArrayList<Xep.JingleRtp.LibwebrtcJingleContent>
            create_adapter_jingle_contents(
                string audio_content_name = "audio",
                string video_content_name = "video")
                throws Xep.Jingle.IqError {
        var audio_payloads = new ArrayList<Xep.JingleRtp.PayloadType>();
        Xep.JingleRtp.PayloadType opus = create_opus_payload();
        opus.parameters["profile_level_id"] = "4325392";
        opus.parameters["useinbandfec"] = "true";
        audio_payloads.add(opus);
        var video_payloads = new ArrayList<Xep.JingleRtp.PayloadType>();
        video_payloads.add(create_vp8_payload());

        var contents = new ArrayList<Xep.JingleRtp.LibwebrtcJingleContent>();
        contents.add(new Xep.JingleRtp.LibwebrtcJingleContent(
            audio_content_name,
            Xep.Jingle.Senders.BOTH,
            create_jingle_description_node("audio", audio_payloads),
            create_jingle_transport_node("adapter-audio", "adapter-audio-password", "actpass", "01:AB:FF", true)));
        contents.add(new Xep.JingleRtp.LibwebrtcJingleContent(
            video_content_name,
            Xep.Jingle.Senders.INITIATOR,
            create_jingle_description_node("video", video_payloads),
            create_jingle_transport_node("adapter-video", "adapter-video-password", "actpass", "AA:BB:CC", false)));
        return contents;
    }

    private ArrayList<Xep.JingleRtp.LibwebrtcJingleContent>
            create_conference_jingle_contents(
                Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> payloads,
                string audio_content_name = "voice",
                string video_content_name = "camera")
                throws Xep.Jingle.IqError {
        Gee.List<Xep.JingleRtp.PayloadType>? audio_payloads =
            payloads["audio"];
        Gee.List<Xep.JingleRtp.PayloadType>? video_payloads =
            payloads["video"];
        if (audio_payloads == null || video_payloads == null) {
            throw new Xep.Jingle.IqError.BAD_REQUEST(
                "conference Jingle fixture requires audio and video payloads");
        }
        var contents = new ArrayList<Xep.JingleRtp.LibwebrtcJingleContent>();
        contents.add(new Xep.JingleRtp.LibwebrtcJingleContent(
            audio_content_name,
            Xep.Jingle.Senders.BOTH,
            create_jingle_description_node("audio", (!) audio_payloads),
            create_jingle_transport_node("adapter-audio",
                "adapter-audio-password", "actpass", "01:AB:FF", true)));
        contents.add(new Xep.JingleRtp.LibwebrtcJingleContent(
            video_content_name,
            Xep.Jingle.Senders.INITIATOR,
            create_jingle_description_node("video", (!) video_payloads),
            create_jingle_transport_node("adapter-video",
                "adapter-video-password", "actpass", "AA:BB:CC", false)));
        return contents;
    }

    private void test_libwebrtc_adapter_local_sdp_maps_to_jingle_contents() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            Xep.JingleRtp.LibwebrtcJingleDescription mapped = adapter.local_description_to_jingle(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_libwebrtc_bundle_sdp_fixture(),
                Xep.Jingle.Role.INITIATOR);

            fail_if_not(adapter.has_local_content_map, "adapter should remember local content map after local SDP");
            fail_if_not(mapped.sdp_type == Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                "adapter should preserve local description type");
            fail_if_not_eq_str(mapped.sdp_type.to_c_abi_name(), "DINOX_WEBRTC_SDP_TYPE_OFFER",
                "adapter should expose the matching C ABI SDP type name");
            fail_if_not_eq_str(mapped.sdp_type.to_jingle_action_name(), "session-initiate",
                "adapter should expose the matching Jingle action");
            fail_if_not_eq_int(mapped.contents.size, 2,
                "adapter should map libwebrtc audio/video SDP to two Jingle contents");
            fail_if_not_eq_str(mapped.contents[0].content_name, "0",
                "adapter should use audio MID as content name");
            fail_if_not_eq_str(mapped.contents[1].content_name, "1",
                "adapter should use video MID as content name");
            fail_if_not(mapped.contents[0].senders == Xep.Jingle.Senders.BOTH,
                "sendrecv audio should map to Jingle senders=both");
            fail_if_not_eq_str(mapped.contents[0].description.get_attribute("media"), "audio",
                "adapter should create an audio RTP description");
            fail_if_not_eq_str(mapped.contents[1].description.get_attribute("media"), "video",
                "adapter should create a video RTP description");

            Gee.List<StanzaNode> audio_extensions = mapped.contents[0].description.get_subnodes(
                Xep.JingleRtp.HeaderExtension.NAME, Xep.JingleRtp.HeaderExtension.NS_URI);
            Gee.List<StanzaNode> video_extensions = mapped.contents[1].description.get_subnodes(
                Xep.JingleRtp.HeaderExtension.NAME, Xep.JingleRtp.HeaderExtension.NS_URI);
            fail_if_not_eq_int(audio_extensions.size, 1,
                "adapter should map libwebrtc audio extmaps to XEP-0294");
            fail_if_not_eq_str(audio_extensions[0].get_attribute("id"), "1",
                "adapter should preserve the audio extmap id in Jingle");
            fail_if_not_eq_int(video_extensions.size, 1,
                "adapter should map libwebrtc video extmaps to XEP-0294");
            fail_if_not_eq_str(video_extensions[0].get_attribute("uri"),
                "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
                "adapter should preserve the video extmap URI in Jingle");
            fail_if(mapped.contents[0].description.get_subnode(
                    "extmap-allow-mixed", Xep.JingleRtp.HeaderExtension.NS_URI) == null,
                "adapter should map session-level extmap-allow-mixed to each Jingle description");

            Gee.List<Xep.JingleRtp.SdpJingleContentNodePair> pairs = mapped.to_content_pairs();
            fail_if_not_eq_int(pairs.size, 2, "adapter should expose bridge-compatible content pairs");
            fail_if_not_eq_str(pairs[0].content_name, "0", "adapter content pair should preserve audio MID");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"libwebrtc local SDP adapter mapping should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_low_bandwidth_opus_uses_negotiated_payload() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            string arbitrary_payload_sdp = create_libwebrtc_bundle_sdp_fixture().replace("111", "109");
            Xep.JingleRtp.LibwebrtcJingleDescription mapped = adapter.local_description_to_jingle(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                arbitrary_payload_sdp,
                Xep.Jingle.Role.INITIATOR,
                true);

            Xep.JingleRtp.PayloadType opus = mapped.session.media_sections[0].payload_types[0];
            fail_if_not_eq_uint(opus.id, 109,
                "low-bandwidth mode must use the negotiated Opus payload id");
            fail_if_not_eq_str(opus.parameters["maxaveragebitrate"], "16000",
                "low-bandwidth Jingle must advertise the Opus average bitrate cap");
            fail_if_not_eq_str(opus.parameters["maxplaybackrate"], "16000",
                "low-bandwidth Jingle must advertise the Opus playback rate");
            fail_if_not_eq_str(opus.parameters["sprop-maxcapturerate"], "16000",
                "low-bandwidth Jingle must advertise the Opus capture rate");
            fail_if_not_eq_str(opus.parameters["stereo"], "0",
                "low-bandwidth Jingle must disable stereo");
            fail_if_not_eq_str(opus.parameters["usedtx"], "1",
                "low-bandwidth Jingle must enable DTX");
            fail_if_not_eq_str(opus.parameters["useinbandfec"], "1",
                "low-bandwidth Jingle must keep in-band FEC enabled");

            StanzaNode description = mapped.contents[0].description;
            Gee.List<StanzaNode> payload_nodes = description.get_subnodes(
                "payload-type", Xep.JingleRtp.NS_URI);
            fail_if_not_eq_int(payload_nodes.size, 2,
                "typed Jingle output must preserve the audio payload count");
            fail_if_not_eq_str(payload_nodes[0].get_attribute("id"), "109",
                "low-bandwidth parameters must be emitted for the negotiated payload id");
            bool found_average_bitrate = false;
            foreach (StanzaNode parameter in payload_nodes[0].get_subnodes(
                    "parameter", Xep.JingleRtp.NS_URI)) {
                if (parameter.get_attribute("name") == "maxaveragebitrate" &&
                        parameter.get_attribute("value") == "16000") {
                    found_average_bitrate = true;
                }
            }
            fail_if(!found_average_bitrate,
                "typed Jingle output must contain the low-bandwidth Opus parameters");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"low-bandwidth Opus adapter mapping should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_remote_jingle_maps_to_sdp() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            Gee.List<Xep.JingleRtp.LibwebrtcJingleContent> contents = create_adapter_jingle_contents();
            var extension = new Xep.JingleRtp.HeaderExtension(
                3,
                "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
                Xep.Jingle.Senders.INITIATOR);
            extension.parameters.add(new Xep.JingleRtp.HeaderExtensionParameter("mode", "fast"));
            contents[1].description.put_node(extension.to_xml());
            contents[1].description.put_node(new StanzaNode.build(
                    "extmap-allow-mixed", Xep.JingleRtp.HeaderExtension.NS_URI)
                .add_self_xmlns());
            Xep.JingleRtp.LibwebrtcJingleDescription mapped = adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                contents,
                Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);

            fail_if_not(adapter.has_remote_content_map, "adapter should remember remote content map after remote Jingle");
            fail_if_not(mapped.sdp_type == Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                "adapter should preserve remote description type");
            fail_if_not_eq_int(mapped.session.media_sections.size, 2,
                "remote Jingle should map to audio/video SDP media sections");
            fail_if_not_eq_str(mapped.session.media_sections[0].mid, "audio",
                "remote audio content name should become SDP MID");
            fail_if_not_eq_str(mapped.session.media_sections[1].mid, "video",
                "remote video content name should become SDP MID");
            fail_if(mapped.session.media_sections[0].direction == null,
                "remote audio direction should be explicit for libwebrtc");
            fail_if(mapped.session.media_sections[1].direction == null,
                "remote video direction should be explicit for libwebrtc");
            if (mapped.session.media_sections[0].direction != null) {
                fail_if_not(((!) mapped.session.media_sections[0].direction) == Xep.JingleRtp.SdpMediaDirection.SEND_RECV,
                    "Jingle senders=both should become remote SDP sendrecv");
            }
            if (mapped.session.media_sections[1].direction != null) {
                fail_if_not(((!) mapped.session.media_sections[1].direction) == Xep.JingleRtp.SdpMediaDirection.SEND_ONLY,
                    "incoming initiator-only media should become remote SDP sendonly for a local responder");
            }
            fail_if(!mapped.sdp.contains("a=group:BUNDLE audio video\r\n"),
                "remote SDP should include explicit BUNDLE when requested");
            fail_if(!mapped.sdp.contains("a=mid:audio\r\n"),
                "remote SDP should include audio MID");
            fail_if(mapped.sdp.contains("profile_level_id"),
                "remote SDP should not leak non-Opus fmtp into Opus");
            fail_if(!mapped.sdp.contains("a=fmtp:111 minptime=10;useinbandfec=1\r\n"),
                "remote SDP should normalize Opus fmtp before libwebrtc receives it");
            fail_if_not_eq_str(mapped.session.media_sections[0].payload_types[0].parameters["useinbandfec"], "1",
                "returned mapped session should match normalized SDP fmtp");
            fail_if(mapped.session.media_sections[0].payload_types[0].parameters.has_key("profile_level_id"),
                "returned mapped session should not expose filtered Opus fmtp");
            fail_if(!mapped.sdp.contains("a=sendrecv\r\n"),
                "remote SDP should include sendrecv direction");
            fail_if(!mapped.sdp.contains("a=mid:video\r\n"),
                "remote SDP should include video MID");
            fail_if(!mapped.sdp.contains("a=sendonly\r\n"),
                "remote SDP should include sendonly direction");
            fail_if(!mapped.sdp.contains(
                    "a=extmap:3/sendonly http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time mode=fast\r\n"),
                "remote XEP-0294 senders must map relative to the described initiator");
            fail_if(!mapped.sdp.contains("a=extmap-allow-mixed\r\n"),
                "remote Jingle extmap-allow-mixed should reach libwebrtc SDP");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"remote Jingle adapter mapping should not fail: $(e.message)");
        }
    }

    private void test_direct_answer_preserves_offer_order() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.local_description_to_jingle(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_libwebrtc_bundle_sdp_fixture(), Xep.Jingle.Role.INITIATOR);
            var answer = create_adapter_jingle_contents("0", "1");
            foreach (var content in answer) {
                content.transport.get_subnode("fingerprint", Xep.JingleIceUdp.DTLS_NS_URI)
                    .set_attribute("setup", "active");
            }
            var reversed = new ArrayList<Xep.JingleRtp.LibwebrtcJingleContent>();
            reversed.add(answer[1]);
            reversed.add(answer[0]);
            var mapped = adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.ANSWER, reversed, Xep.Jingle.Role.INITIATOR);
            fail_if_not_eq_str(mapped.session.media_sections[0].media, "audio",
                "a Jingle answer must preserve the offered SDP audio m-line position");
            fail_if_not_eq_str(mapped.session.media_sections[0].mid, "0",
                "the audio MID must remain bound to the offered content name");
            fail_if_not_eq_str(mapped.session.media_sections[1].media, "video",
                "a Jingle answer must preserve the offered SDP video m-line position");
            fail_if_not_eq_str(mapped.session.media_sections[1].mid, "1",
                "the video MID must remain bound to the offered content name");
            var audio_ice = adapter.remote_jingle_candidate_to_webrtc("0", create_srflx_candidate());
            var video_ice = adapter.remote_jingle_candidate_to_webrtc("1", create_srflx_candidate());
            fail_if_not_eq_int(audio_ice.sdp_mline_index, 0,
                "audio ICE must target the original offered m-line");
            fail_if_not_eq_int(video_ice.sdp_mline_index, 1,
                "video ICE must target the original offered m-line");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"a reordered direct answer should remain valid: $(e.message)");
        }
    }

    private void test_direct_answer_rejects_changed_identity() {
        for (int mutation = 0; mutation < 3; mutation++) {
            try {
                var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
                adapter.local_description_to_jingle(
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                    create_libwebrtc_bundle_sdp_fixture(), Xep.Jingle.Role.INITIATOR);
                var answer = create_adapter_jingle_contents(mutation == 0 ? "unknown" : "0", "1");
                foreach (var content in answer) {
                    content.transport.get_subnode("fingerprint", Xep.JingleIceUdp.DTLS_NS_URI)
                        .set_attribute("setup", "active");
                }
                if (mutation == 1) answer[0].description.set_attribute("media", "video");
                if (mutation == 2) answer.remove_at(1);
                try {
                    adapter.remote_description_from_jingle_contents(
                        Xep.JingleRtp.LibwebrtcSdpType.ANSWER, answer, Xep.Jingle.Role.INITIATOR);
                    fail_if_reached("an answer must not rename, change or silently omit offered contents");
                } catch (Xep.Jingle.IqError e) {
                    fail_if_not(e is Xep.Jingle.IqError.BAD_REQUEST,
                        "a changed answer content identity must return bad-request");
                }
            } catch (Xep.Jingle.IqError e) {
                fail_if_reached(@"direct answer test setup failed: $(e.message)");
            }
        }
    }

    private void test_libwebrtc_adapter_maps_ice_candidates() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.local_description_to_jingle(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_libwebrtc_bundle_sdp_fixture(),
                Xep.Jingle.Role.INITIATOR);

            Xep.JingleRtp.LibwebrtcJingleIceCandidate local_candidate =
                adapter.local_ice_candidate_to_jingle(
                    "0",
                    0,
                    "candidate:9 1 udp 1000 203.0.113.20 5002 typ host generation 0");
            fail_if_not_eq_str(local_candidate.content_name, "0",
                "local libwebrtc ICE should map by SDP MID to Jingle content name");
            fail_if_not_eq_str(local_candidate.candidate,
                "candidate:9 1 udp 1000 203.0.113.20 5002 typ host generation 0",
                "local libwebrtc ICE candidate should stay in C ABI candidate syntax");
            fail_if_not_eq_str(local_candidate.jingle_candidate.ip, "203.0.113.20",
                "local libwebrtc ICE should parse to a Jingle candidate");
            fail_if_not_eq_str(local_candidate.ice_ufrag, "libaudio",
                "local libwebrtc ICE should keep the matching Jingle ICE ufrag");
            fail_if_not_eq_str(local_candidate.ice_pwd, "audioPassword0123456789",
                "local libwebrtc ICE should keep the matching Jingle ICE pwd");

            var waiting_adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            try {
                waiting_adapter.remote_jingle_candidate_to_webrtc("audio", create_srflx_candidate());
                fail_if_reached("remote Jingle ICE must wait until the remote content map is known");
            } catch (Xep.Jingle.IqError e) {
                // Expected.
            }

            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_adapter_jingle_contents(),
                Xep.Jingle.Role.RESPONDER);
            Xep.JingleRtp.LibwebrtcRemoteIceCandidate remote_candidate =
                adapter.remote_jingle_candidate_to_webrtc("audio", create_srflx_candidate());
            fail_if_not_eq_str(remote_candidate.sdp_mid, "audio",
                "remote Jingle ICE should use content name as SDP MID");
            fail_if_not_eq_int(remote_candidate.sdp_mline_index, 0,
                "remote Jingle ICE should map content order to SDP m-line index");
            fail_if(remote_candidate.candidate.has_prefix("a="),
                "remote Jingle ICE candidate passed to the C ABI must not include the a= prefix");
            fail_if(!remote_candidate.candidate.has_prefix("candidate:1 1 udp"),
                "remote Jingle ICE candidate should use SDP candidate syntax");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"libwebrtc ICE adapter mapping should not fail: $(e.message)");
        }
    }

    private HashMap<string, string> create_muji_content_names() {
        var names = new HashMap<string, string>();
        names["audio"] = "voice";
        names["video"] = "camera";
        return names;
    }

    private HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
            create_muji_payload_types() {
        var payloads = new HashMap<string,
            Gee.List<Xep.JingleRtp.PayloadType>>();
        var audio_payloads = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        Xep.JingleRtp.PayloadType opus = create_opus_payload();
        opus.parameters["profile_level_id"] = "4325392";
        opus.parameters["useinbandfec"] = "true";
        audio_payloads.add(opus);
        payloads["audio"] = audio_payloads;
        var video_payloads = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        video_payloads.add(create_vp8_payload());
        payloads["video"] = video_payloads;
        return payloads;
    }

    private HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
            create_muji_payload_types_with_ids(
                uint8 audio_id, uint8 video_id,
                bool include_rtx = false, uint8 rtx_id = 0) {
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> payloads =
            create_muji_payload_types();
        Gee.List<Xep.JingleRtp.PayloadType> audio_payloads =
            (!) payloads["audio"];
        Gee.List<Xep.JingleRtp.PayloadType> video_payloads =
            (!) payloads["video"];
        audio_payloads[0].id = audio_id;
        video_payloads[0].id = video_id;
        if (include_rtx) {
            var rtx = new Xep.JingleRtp.PayloadType() {
                id = rtx_id,
                name = "rtx",
                clockrate = 90000
            };
            rtx.parameters["apt"] = video_id.to_string();
            video_payloads.add(rtx);
        }
        return payloads;
    }


    private void test_muji_preparation_preserves_native_sources() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            var configured = create_muji_payload_types();
            ((!) configured["audio"])[0].ptime = 20;
            ((!) configured["audio"])[0].maxptime = 60;
            adapter.configure_conference_media(create_muji_content_names(), configured);
            string native_sdp = create_libwebrtc_bundle_sdp_fixture() +
                "a=ssrc:42 cname:primary\r\na=ssrc:43 cname:repair\r\n" +
                "a=ssrc-group:FID 42 43\r\na=msid:stream track\r\n";
            string projected = adapter.prepare_conference_local_description(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER, native_sdp);
            fail_if(adapter.has_local_content_map,
                "SDP preparation must not expose ICE or initial offer maps before native commit");
            fail_if(!projected.contains("a=ssrc:42 cname:primary\r\n") ||
                    !projected.contains("a=msid:stream track\r\n"),
                "native source and stream lines must survive conference projection");
            fail_if(projected.contains("a=ssrc:43") || projected.contains("a=ssrc-group:FID"),
                "omitted RTX must remove its FID and repair source independent of SDP line order");
            fail_if(!projected.contains("a=ptime:20\r\n") || !projected.contains("a=maxptime:60\r\n"),
                "frozen RTP timing must be projected into actual native SDP");
            fail_if(!projected.contains("a=group:BUNDLE voice camera\r\n"),
                "native BUNDLE mids must use the conference content names");
            adapter.local_description_to_jingle(Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                projected, Xep.Jingle.Role.INITIATOR);
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"native conference projection should succeed: $(e.message)");
        }
    }

    private void test_muji_projects_native_receiver_reference_time() {
        foreach (bool retain_rrtr in new bool[] { false, true }) {
            try {
                var configured = create_muji_payload_types();
                if (retain_rrtr) {
                    foreach (Gee.List<Xep.JingleRtp.PayloadType> payloads in configured.values) {
                        foreach (Xep.JingleRtp.PayloadType payload in payloads) {
                            payload.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("rrtr"));
                        }
                    }
                }
                var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
                adapter.configure_conference_media(create_muji_content_names(), configured);
                string native_sdp = create_libwebrtc_bundle_sdp_fixture()
                    .replace("a=mid:0\r\n", "a=mid:0\r\na=rtcp-xr:rcvr-rtt=all\r\n")
                    .replace("a=mid:1\r\n",
                        "a=mid:1\r\na=rtcp-xr:stat-summary=loss,dup rcvr-rtt=sender:1000\r\n")
                    .replace("a=rtcp-fb:111 transport-cc\r\n",
                        "a=rtcp-fb:111 transport-cc\r\na=rtcp-fb:111 rrtr\r\n");
                string projected = adapter.prepare_conference_local_description(
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER, native_sdp);
                fail_if(projected.contains("rcvr-rtt="),
                    "native XR receiver-reference-time capability must not override the frozen feedback map");
                fail_if(!projected.contains("a=rtcp-xr:stat-summary=loss,dup\r\n"),
                    "projecting receiver-reference-time must preserve unrelated XR formats");
                fail_if(projected.contains("a=rtcp-fb:111 rrtr\r\n") != retain_rrtr ||
                        projected.contains("a=rtcp-fb:98 rrtr\r\n") != retain_rrtr,
                    "receiver-reference-time feedback must come only from the frozen payload map");

                string changed = retain_rrtr
                    ? projected.replace("a=rtcp-fb:111 rrtr\r\n", "")
                    : projected.replace("a=mid:voice\r\n",
                        "a=mid:voice\r\na=rtcp-fb:111 rrtr\r\n");
                bool rejected = false;
                try {
                    adapter.local_description_to_jingle(Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                        changed, Xep.Jingle.Role.INITIATOR);
                } catch (Xep.Jingle.IqError e) { rejected = true; }
                fail_if(!rejected || adapter.has_local_content_map,
                    "native addition or loss of frozen rrtr must fail before publishing Jingle");

                // M152 may serialize the projected legacy rrtr feedback back
                // as both media-level XR and per-payload rrtr. M150 retains
                // the per-payload form. The frozen payload map is unchanged.
                string committed = retain_rrtr
                    ? projected.replace("a=mid:voice\r\n",
                        "a=mid:voice\r\na=rtcp-xr:rcvr-rtt=all\r\n")
                    : projected;
                var description = adapter.local_description_to_jingle(
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER, committed, Xep.Jingle.Role.INITIATOR);
                fail_if_not_eq_uint(description.session.media_sections[0].payload_types[0].id,
                    111, "Opus must retain its frozen payload identity");
                fail_if_not_eq_uint(description.session.media_sections[1].payload_types[0].id,
                    98, "VP8 must retain its frozen payload identity");
            } catch (Xep.Jingle.IqError e) {
                fail_if_reached(@"conference receiver-reference-time projection should succeed: $(e.message)");
            }
        }
    }

    private HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> create_muji_duplicate_feedback_map() {
        var configured = create_muji_payload_types();
        foreach (var payloads in configured.values) {
            foreach (var payload in payloads) {
                payload.rtcp_fbs.add(payload.rtcp_fbs[0]);
                var rrtr = new Xep.JingleRtp.RtcpFeedback("rrtr");
                payload.rtcp_fbs.add(rrtr);
                payload.rtcp_fbs.add(rrtr);
                payload.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("trr-int", "0100"));
                payload.rtcp_fbs.add(new Xep.JingleRtp.RtcpFeedback("trr-int", "100"));
            }
        }
        return configured;
    }

    private HashMap<string, string> snapshot_muji_payloads(
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> configured) {
        var snapshot = new HashMap<string, string>();
        foreach (var payloads in configured.values) {
            foreach (var payload in payloads) snapshot[payload.id.to_string()] = payload.to_xml().to_string();
        }
        return snapshot;
    }

    private void assert_muji_payload_snapshot(
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> configured,
            Gee.Map<string, string> snapshot) {
        foreach (var payloads in configured.values) {
            foreach (var payload in payloads) {
                fail_if_not_eq_int(payload.rtcp_fbs.size, 6,
                    "Normalization must not edit the caller's frozen feedback list");
                fail_if_not_eq_str(payload.to_xml().to_string(), snapshot[payload.id.to_string()],
                    "Projection must not mutate shared feedback objects or other frozen parameters");
            }
        }
    }

    private void test_muji_feedback_set_projection() {
        var configured = create_muji_duplicate_feedback_map();
        ((!) configured["audio"])[0].ptime = 20;
        ((!) configured["audio"])[0].maxptime = 60;
        var snapshot = snapshot_muji_payloads(configured);
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(create_muji_content_names(), configured);
            string projected = adapter.prepare_conference_local_description(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER, create_libwebrtc_bundle_sdp_fixture());
            fail_if(adapter.has_local_content_map, "Preparation must still wait for the native commit");
            fail_if_not_eq_int(projected.split("a=rtcp-fb:111 nack pli\r\n").length - 1, 1,
                "A duplicated frozen capability must produce one native feedback attribute");
            fail_if_not(projected.contains("a=rtcp-fb:111 rrtr\r\n") &&
                projected.contains("a=rtcp-fb:98 rrtr\r\n"), "Frozen RRTR must survive projection");
            string committed = projected.replace(" trr-int 0100\r\n", " trr-int 100\r\n");
            var published = adapter.local_description_to_jingle(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER, committed, Xep.Jingle.Role.INITIATOR);
            fail_if_not(adapter.has_local_content_map, "Equivalent native feedback must commit its content map");
            foreach (var section in published.session.media_sections) {
                var payload = section.payload_types[0];
                fail_if_not_eq_int(payload.rtcp_fbs.size, 3, "Frozen feedback is a capability set");
                fail_if_not(payload.rtcp_fbs.any_match((fb) => fb.type_ == "rrtr"));
                fail_if_not(payload.rtcp_fbs.any_match((fb) => fb.type_ == "trr-int" && fb.subtype == "0100"),
                    "Numeric comparison must preserve the frozen feedback object's interval spelling");
            }

            // A peer's pairwise Jingle may deduplicate the same ready-presence
            // capabilities and serialize an equivalent decimal interval differently.
            var contents = create_conference_jingle_contents(configured);
            foreach (var content in contents) {
                foreach (var payload in content.description.get_subnodes(Xep.JingleRtp.PayloadType.NAME)) {
                    foreach (var interval in payload.get_subnodes(
                            Xep.JingleRtp.RtcpFeedback.TRR_INT_NAME, Xep.JingleRtp.RtcpFeedback.NS_URI)) {
                        interval.set_attribute("value", "100");
                    }
                }
            }
            var incoming = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            incoming.configure_conference_media(create_muji_content_names(), configured);
            var mapped = incoming.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER, contents, Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_not(incoming.has_remote_content_map);
            fail_if_not_eq_int(mapped.session.media_sections[0].payload_types[0].rtcp_fbs.size, 3);
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"Equivalent frozen MUJI feedback must pass both gates: $(e.message)");
        }
        assert_muji_payload_snapshot(configured, snapshot);
    }

    private void test_muji_feedback_set_rejects_changes() {
        var configured = create_muji_duplicate_feedback_map();
        var snapshot = snapshot_muji_payloads(configured);
        for (int mutation = 0; mutation < 3; mutation++) {
            try {
                var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
                adapter.configure_conference_media(create_muji_content_names(), configured);
                string projected = adapter.prepare_conference_local_description(
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER, create_libwebrtc_bundle_sdp_fixture());
                string changed;
                if (mutation == 0) {
                    changed = projected.replace("a=rtcp-fb:111 rrtr\r\n", "");
                } else if (mutation == 1) {
                    changed = projected.replace("a=mid:voice\r\n", "a=mid:voice\r\na=rtcp-fb:111 ccm fir\r\n");
                } else {
                    changed = projected.replace("a=rtcp-fb:111 trr-int 0100\r\n", "a=rtcp-fb:111 trr-int 200\r\n");
                }
                try {
                    adapter.local_description_to_jingle(
                        Xep.JingleRtp.LibwebrtcSdpType.OFFER, changed, Xep.Jingle.Role.INITIATOR);
                    fail_if_reached("Native commit must reject missing, added or changed frozen feedback");
                } catch (Xep.Jingle.IqError e) {
                    fail_if_not(e is Xep.Jingle.IqError.BAD_REQUEST);
                }
                fail_if(adapter.has_local_content_map, "Failed native feedback validation must not publish maps");

                var contents = create_conference_jingle_contents(configured);
                var audio = contents[0].description.get_subnodes(Xep.JingleRtp.PayloadType.NAME)[0];
                if (mutation == 0) {
                    foreach (var feedback in audio.get_subnodes(
                            Xep.JingleRtp.RtcpFeedback.NAME, Xep.JingleRtp.RtcpFeedback.NS_URI)) {
                        if (feedback.get_attribute("type") == "rrtr") audio.sub_nodes.remove(feedback);
                    }
                } else if (mutation == 1) {
                    audio.put_node(new Xep.JingleRtp.RtcpFeedback("ccm", "fir").to_xml());
                } else {
                    foreach (var interval in audio.get_subnodes(
                            Xep.JingleRtp.RtcpFeedback.TRR_INT_NAME, Xep.JingleRtp.RtcpFeedback.NS_URI)) {
                        interval.set_attribute("value", "200");
                    }
                }
                var incoming = new Xep.JingleRtp.LibwebrtcJingleAdapter();
                incoming.configure_conference_media(create_muji_content_names(), configured);
                try {
                    incoming.remote_description_from_jingle_contents(
                        Xep.JingleRtp.LibwebrtcSdpType.OFFER, contents, Xep.Jingle.Role.RESPONDER,
                        Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
                    fail_if_reached("Peer Jingle must reject missing, added or changed frozen feedback");
                } catch (Xep.Jingle.IqError e) {
                    fail_if_not(e is Xep.Jingle.IqError.BAD_REQUEST);
                }
                fail_if(incoming.has_remote_content_map, "Rejected pairwise feedback must not publish maps");
            } catch (Xep.Jingle.IqError e) {
                fail_if_reached(@"Feedback rejection test setup failed: $(e.message)");
            }
        }
        assert_muji_payload_snapshot(configured, snapshot);
    }

    private void test_muji_committed_timing_is_verified() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            var configured = create_muji_payload_types();
            ((!) configured["audio"])[0].ptime = 20;
            ((!) configured["audio"])[0].maxptime = 60;
            adapter.configure_conference_media(create_muji_content_names(), configured);
            string projected = adapter.prepare_conference_local_description(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER, create_libwebrtc_bundle_sdp_fixture());
            foreach (string invalid in new string[] {
                    projected.replace("a=ptime:20\r\n", ""),
                    projected.replace("a=ptime:20\r\n", "a=ptime:30\r\n") }) {
                bool rejected = false;
                try {
                    adapter.local_description_to_jingle(Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                        invalid, Xep.Jingle.Role.INITIATOR);
                } catch (Xep.Jingle.IqError e) { rejected = true; }
                fail_if(!rejected, "native timing loss/change must fail before publishing Jingle");
                fail_if(adapter.has_local_content_map, "failed native confirmation must not publish maps");
            }
            var local = adapter.local_description_to_jingle(Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                projected, Xep.Jingle.Role.INITIATOR);
            var remote = adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.ANSWER, local.contents, Xep.Jingle.Role.INITIATOR);
            string rebundled = adapter.session_to_native_sdp(remote.session);
            fail_if(!rebundled.contains("a=ptime:20\r\n") || !rebundled.contains("a=maxptime:60\r\n"),
                "re-serializing the native remote description must preserve conference timing");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"conference timing verification should succeed: $(e.message)");
        }
    }


    private void test_muji_prepared_timing_bounds() {
        foreach (bool maximum_only in new bool[] { true, false }) {
            try {
                var configured = create_muji_payload_types();
                if (maximum_only) ((!) configured["audio"])[0].maxptime = 60;
                else ((!) configured["audio"])[0].ptime = 20;
                var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
                adapter.configure_conference_media(create_muji_content_names(), configured);
                string invalid = create_libwebrtc_bundle_sdp_fixture().replace("a=mid:0\r\n",
                    maximum_only ? "a=mid:0\r\na=ptime:80\r\n" : "a=mid:0\r\na=maxptime:10\r\n");
                bool rejected = false;
                try {
                    adapter.prepare_conference_local_description(Xep.JingleRtp.LibwebrtcSdpType.OFFER, invalid);
                } catch (Xep.Jingle.IqError e) { rejected = true; }
                fail_if(!rejected, "native timing must respect the opposite frozen media bound");
                fail_if(adapter.has_local_content_map, "failed native preparation must not publish a map");
            } catch (Xep.Jingle.IqError e) {
                fail_if_reached(@"valid conference timing fixture should configure: $(e.message)");
            }
        }
        var invalid_map = create_muji_payload_types();
        ((!) invalid_map["audio"])[0].ptime = 80;
        ((!) invalid_map["audio"])[0].maxptime = 60;
        fail_if(Xep.JingleRtp.LibwebrtcJingleAdapter.has_supported_conference_timing((!) invalid_map["audio"]),
            "frozen ptime exceeding maxptime must be rejected before READY");
    }

    private void test_muji_rtx_uses_media_timing() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            var configured = create_muji_payload_types_with_ids(111, 120, true, 121);
            ((!) configured["video"])[0].ptime = 20;
            ((!) configured["video"])[0].maxptime = 60;
            adapter.configure_conference_media(create_muji_content_names(), configured);
            var local = muji_local_description(adapter, Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_libwebrtc_bundle_sdp_fixture(), Xep.Jingle.Role.INITIATOR);
            fail_if_not_eq_int(local.session.media_sections[1].payload_types.size, 2,
                "RTX without per-payload timing inherits native media timing without changing the frozen map");
            fail_if_not_eq_uint(local.session.media_sections[1].payload_types[1].ptime, 0,
                "native media timing must not invent an RTX attribute in the frozen Jingle mapping");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"conference RTX media timing should succeed: $(e.message)");
        }
    }

    private Xep.JingleRtp.LibwebrtcJingleDescription muji_local_description(
            Xep.JingleRtp.LibwebrtcJingleAdapter adapter,
            Xep.JingleRtp.LibwebrtcSdpType type, string sdp, Xep.Jingle.Role role)
            throws Xep.Jingle.IqError {
        string projected = adapter.prepare_conference_local_description(type, sdp);
        fail_if(adapter.has_local_content_map, "Preparing SDP must not publish a local content map");
        return adapter.local_description_to_jingle(type, projected, role);
    }

    private void test_libwebrtc_adapter_muji_offer_maps_internal_mids() {
        try {
            HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> configured =
                create_muji_payload_types();
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            Xep.JingleRtp.LibwebrtcJingleDescription local_offer =
                muji_local_description(adapter,
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                    create_libwebrtc_bundle_sdp_fixture(),
                    Xep.Jingle.Role.INITIATOR);
            fail_if_not_eq_str(local_offer.contents[0].content_name, "voice",
                "MUJI audio Jingle content must expose the conference identity");
            fail_if_not_eq_str(local_offer.contents[1].content_name, "camera",
                "MUJI video Jingle content must expose the conference identity");
            fail_if_not_eq_str(local_offer.session.media_sections[0].mid, "voice",
                "native local SDP must use the conference audio MID");
            fail_if_not_eq_uint(
                local_offer.session.media_sections[1].payload_types[0].id, 98,
                "MUJI Jingle offer must publish the frozen conference video payload ID");

            Xep.JingleRtp.LibwebrtcJingleIceCandidate local_ice =
                adapter.local_ice_candidate_to_jingle(
                    "voice", 0,
                    "candidate:9 1 udp 1000 203.0.113.20 5002 typ host generation 0");
            fail_if_not_eq_str(local_ice.content_name, "voice",
                "native audio ICE MID must map to the MUJI conference content");
            fail_if_not_eq_str(local_ice.sdp_mid, "voice",
                "mapped local ICE must preserve the native MID separately");

            ArrayList<Xep.JingleRtp.LibwebrtcJingleContent> answer =
                create_conference_jingle_contents(configured);
            var reversed_answer =
                new ArrayList<Xep.JingleRtp.LibwebrtcJingleContent>();
            reversed_answer.add(answer[1]);
            reversed_answer.add(answer[0]);
            Xep.JingleRtp.LibwebrtcJingleDescription remote_answer =
                adapter.remote_description_from_jingle_contents(
                    Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                    reversed_answer,
                    Xep.Jingle.Role.INITIATOR,
                    Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if(!remote_answer.sdp.contains("a=group:BUNDLE voice camera\r\n"),
                "MUJI answer must preserve committed conference BUNDLE MIDs in offer order");
            fail_if_not_eq_str(remote_answer.session.media_sections[0].mid, "voice",
                "MUJI answer must keep the committed audio MID voice");
            fail_if_not_eq_str(remote_answer.session.media_sections[1].mid, "camera",
                "MUJI answer must keep the committed video MID camera");
            fail_if_not_eq_uint(
                remote_answer.session.media_sections[1].payload_types[0].id, 98,
                "MUJI native answer must retain the committed conference video payload ID");

            Xep.JingleRtp.LibwebrtcRemoteIceCandidate remote_ice =
                adapter.remote_jingle_candidate_to_webrtc(
                    "voice", create_srflx_candidate());
            fail_if_not_eq_str(remote_ice.sdp_mid, "voice",
                "MUJI remote audio ICE must map from conference name to native MID");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"MUJI outgoing MID mapping should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_audio_payload_ids_roundtrip() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(),
                create_muji_payload_types_with_ids(96, 98));
            Xep.JingleRtp.LibwebrtcJingleDescription local_offer =
                muji_local_description(adapter,
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                    create_libwebrtc_bundle_sdp_fixture(),
                    Xep.Jingle.Role.INITIATOR);

            fail_if_not_eq_uint(
                local_offer.session.media_sections[0].payload_types[0].id, 96,
                "MUJI offer must rewrite native Opus PT 111 to conference PT 96");
            Gee.List<StanzaNode> audio_payload_nodes =
                local_offer.contents[0].description.get_subnodes(
                    "payload-type", Xep.JingleRtp.NS_URI);
            fail_if_not_eq_str(audio_payload_nodes[0].get_attribute("id"), "96",
                "MUJI wire offer must carry conference Opus PT 96");

            Xep.JingleRtp.LibwebrtcJingleDescription remote_answer =
                adapter.remote_description_from_jingle_contents(
                    Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                    local_offer.contents,
                    Xep.Jingle.Role.INITIATOR,
                    Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_not_eq_uint(
                remote_answer.session.media_sections[0].payload_types[0].id,
                96,
                "MUJI answer must retain committed conference Opus PT 96");
            fail_if(!remote_answer.sdp.contains(
                    "m=audio 9 UDP/TLS/RTP/SAVPF 96\r\n"),
                "remote SDP must expose committed conference Opus PT 96");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"MUJI audio payload translation should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_rtx_payload_ids_roundtrip() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(),
                create_muji_payload_types_with_ids(111, 120, true, 121));
            Xep.JingleRtp.LibwebrtcJingleDescription local_offer =
                muji_local_description(adapter,
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                    create_libwebrtc_bundle_sdp_fixture(),
                    Xep.Jingle.Role.INITIATOR);
            Gee.List<Xep.JingleRtp.PayloadType> conference_video =
                local_offer.session.media_sections[1].payload_types;
            fail_if_not_eq_uint(conference_video[0].id, 120,
                "MUJI offer must rewrite native VP8 PT 96 to conference PT 120");
            fail_if_not_eq_uint(conference_video[1].id, 121,
                "MUJI offer must rewrite native RTX PT 97 to conference PT 121");
            fail_if_not_eq_str(conference_video[1].parameters["apt"], "120",
                "MUJI wire RTX apt must target the conference VP8 payload ID");

            Xep.JingleRtp.LibwebrtcJingleDescription remote_answer =
                adapter.remote_description_from_jingle_contents(
                    Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                    local_offer.contents,
                    Xep.Jingle.Role.INITIATOR,
                    Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            Gee.List<Xep.JingleRtp.PayloadType> native_video =
                remote_answer.session.media_sections[1].payload_types;
            fail_if_not_eq_uint(native_video[0].id, 120,
                "MUJI answer must keep committed conference VP8 PT 120");
            fail_if_not_eq_uint(native_video[1].id, 121,
                "MUJI answer must keep committed conference RTX PT 121");
            fail_if_not_eq_str(native_video[1].parameters["apt"], "120",
                "committed RTX apt must target conference VP8 PT 120");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"MUJI RTX payload translation should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_remote_answer_may_omit_rtx() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(create_muji_content_names(),
                create_muji_payload_types_with_ids(111, 120, true, 121));
            muji_local_description(adapter,
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_libwebrtc_bundle_sdp_fixture(), Xep.Jingle.Role.INITIATOR);
            var answer = adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                create_conference_jingle_contents(
                    create_muji_payload_types_with_ids(111, 120)),
                Xep.Jingle.Role.INITIATOR,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            var video = answer.session.media_sections[1].payload_types;
            fail_if_not_eq_int(video.size, 1,
                "XEP-0167: an answer may omit optional RTX while retaining VP8");
            fail_if_not_eq_uint(video[0].id, 120,
                "the accepted VP8 subset must retain its committed conference payload ID");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"MUJI primary-only answer should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_local_answer_may_omit_rtx() {
        try {
            var configured = create_muji_payload_types_with_ids(111, 98, true, 99);
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(create_muji_content_names(), configured);
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_conference_jingle_contents(configured),
                Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            var answer = muji_local_description(adapter,
                Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                create_muji_local_answer_sdp_fixture(), Xep.Jingle.Role.RESPONDER);
            fail_if_not_eq_int(answer.session.media_sections[1].payload_types.size, 1,
                "MUJI must not add an RTX codec omitted by the native answer");
            fail_if_not_eq_uint(answer.session.media_sections[1].payload_types[0].id, 98,
                "MUJI native answer must preserve the offered VP8 payload identity");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"MUJI local primary-only answer should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_local_answer_rejects_orphan_rtx() {
        try {
            var configured = create_muji_payload_types_with_ids(111, 98, true, 99);
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(create_muji_content_names(), configured);
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_conference_jingle_contents(configured),
                Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            var native_answer = Xep.JingleRtp.SdpBridge.session_from_sdp(
                create_muji_local_answer_sdp_fixture());
            native_answer.media_sections[1].payload_types.clear();
            native_answer.media_sections[1].payload_types.add(
                ((!) configured["video"])[1].clone());
            string invalid_sdp = Xep.JingleRtp.SdpBridge.session_to_sdp(native_answer);
            bool rejected = false;
            try {
                muji_local_description(adapter,
                    Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                    invalid_sdp, Xep.Jingle.Role.RESPONDER);
            } catch (Xep.Jingle.IqError e) {
                rejected = true;
            }
            fail_if(!rejected,
                "MUJI native answer must reject RTX when its primary codec is absent");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"MUJI orphan RTX fixture should be representable: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_rejects_invalid_payload_maps() {
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> duplicate =
            create_muji_payload_types_with_ids(96, 120);
        ((!) duplicate["audio"]).add(new Xep.JingleRtp.PayloadType() {
            id = 96,
            name = "PCMU",
            clockrate = 8000
        });
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), duplicate);
            fail_if_reached(
                "MUJI conference payload IDs must be unique per content");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> invalid_apt =
            create_muji_payload_types_with_ids(111, 120, true, 121);
        ((!) invalid_apt["video"])[1].parameters["apt"] = "122";
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), invalid_apt);
            fail_if_reached(
                "MUJI RTX apt must target a payload in the same content");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private void test_libwebrtc_adapter_muji_rejects_unrepresentable_content_names() {
        foreach (string name in new string[] { "voice channel\tmain", "camera channel", "12345678901234567" }) {
            try {
                var names = create_muji_content_names();
                names["audio"] = name;
                var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
                adapter.configure_conference_media(names, create_muji_payload_types());
                fail_if_reached("A native MUJI MID must be a supported SDP token");
            } catch (Xep.Jingle.IqError e) {
                // The XEP string remains valid, but this native engine cannot represent it.
            }
        }
    }

    private void test_libwebrtc_adapter_direct_payload_ids_are_isolated() {
        try {
            var muji_adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            muji_adapter.configure_conference_media(
                create_muji_content_names(),
                create_muji_payload_types_with_ids(96, 120, true, 121));
            muji_local_description(muji_adapter,
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_libwebrtc_bundle_sdp_fixture(),
                Xep.Jingle.Role.INITIATOR);

            var direct_adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            Xep.JingleRtp.LibwebrtcJingleDescription direct_offer =
                direct_adapter.local_description_to_jingle(
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                    create_libwebrtc_bundle_sdp_fixture(),
                    Xep.Jingle.Role.INITIATOR);
            fail_if_not_eq_str(direct_offer.contents[0].content_name, "0",
                "direct 1:1 audio content identity must remain native");
            fail_if_not_eq_str(direct_offer.contents[1].content_name, "1",
                "direct 1:1 video content identity must remain native");
            fail_if_not_eq_uint(
                direct_offer.session.media_sections[0].payload_types[0].id,
                111,
                "direct 1:1 Opus PT must remain native after MUJI mapping");
            fail_if_not_eq_uint(
                direct_offer.session.media_sections[1].payload_types[0].id,
                96,
                "direct 1:1 VP8 PT must remain native after MUJI mapping");
            fail_if_not_eq_uint(
                direct_offer.session.media_sections[1].payload_types[1].id,
                97,
                "direct 1:1 RTX PT must remain native after MUJI mapping");
            fail_if_not_eq_str(
                direct_offer.session.media_sections[1].payload_types[1]
                    .parameters["apt"],
                "96",
                "direct 1:1 RTX apt must remain bound to native VP8 PT");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"direct adapter isolation should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_incoming_offer_preserves_conference_names() {
        try {
            HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> configured =
                create_muji_payload_types();
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            Xep.JingleRtp.LibwebrtcJingleDescription remote_offer =
                adapter.remote_description_from_jingle_contents(
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                    create_conference_jingle_contents(configured),
                    Xep.Jingle.Role.RESPONDER,
                    Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if(!remote_offer.sdp.contains("a=group:BUNDLE voice camera\r\n"),
                "incoming MUJI offer must retain the conference BUNDLE MIDs");
            fail_if(!remote_offer.sdp.contains("a=mid:voice\r\n") ||
                    !remote_offer.sdp.contains("a=mid:camera\r\n"),
                "incoming MUJI native SDP must retain the conference names");

            Xep.JingleRtp.LibwebrtcRemoteIceCandidate remote_ice =
                adapter.remote_jingle_candidate_to_webrtc(
                    "camera", create_srflx_candidate());
            fail_if_not_eq_str(remote_ice.sdp_mid, "camera",
                "incoming MUJI video ICE must target native conference MID camera");

            Xep.JingleRtp.LibwebrtcJingleDescription local_answer =
                muji_local_description(adapter,
                    Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                    create_muji_local_answer_sdp_fixture(),
                    Xep.Jingle.Role.RESPONDER);
            fail_if_not_eq_str(local_answer.contents[0].content_name, "voice",
                "incoming MUJI answer must restore the audio conference identity");
            fail_if_not_eq_str(local_answer.contents[1].content_name, "camera",
                "incoming MUJI answer must restore the video conference identity");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"MUJI incoming MID mapping should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_filters_pairwise_native_payloads() {
        try {
            var configured = new HashMap<string,
                Gee.List<Xep.JingleRtp.PayloadType>>();
            var audio = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            audio.add(new Xep.JingleRtp.PayloadType() {
                id = 111,
                name = "opus",
                clockrate = 48000,
                channels = 2
            });
            configured["audio"] = audio;
            var video = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            video.add(new Xep.JingleRtp.PayloadType() {
                id = 98,
                name = "VP8",
                clockrate = 90000
            });
            configured["video"] = video;

            ArrayList<Xep.JingleRtp.LibwebrtcJingleContent> contents =
                create_conference_jingle_contents(configured);
            contents[0].description.put_node(
                new Xep.JingleRtp.PayloadType() {
                    id = 0,
                    name = "PCMU",
                    clockrate = 8000
                }.to_xml());
            contents[1].description.put_node(create_h264_payload().to_xml());

            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            Xep.JingleRtp.LibwebrtcJingleDescription remote_offer =
                adapter.remote_description_from_jingle_contents(
                    Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                    contents,
                    Xep.Jingle.Role.RESPONDER,
                    Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);

            fail_if_not_eq_int(
                remote_offer.session.media_sections[0].payload_types.size, 1,
                "MUJI audio must keep only the ready-presence payload map");
            fail_if_not_eq_int(
                remote_offer.session.media_sections[1].payload_types.size, 1,
                "MUJI video must keep only the ready-presence payload map");
            fail_if_not_eq_uint(
                remote_offer.session.media_sections[0].payload_types[0].id,
                111,
                "MUJI audio must retain the global Opus payload ID");
            fail_if_not_eq_uint(
                remote_offer.session.media_sections[1].payload_types[0].id,
                98,
                "MUJI video must retain the global VP8 payload ID");
            fail_if(remote_offer.sdp.contains("PCMU") ||
                    remote_offer.sdp.contains("H264"),
                "pairwise native codecs must not escape the MUJI conference map");
            fail_if_not_eq_int(
                remote_offer.session.media_sections[0]
                    .payload_types[0].parameters.size,
                0,
                "pairwise Opus parameters must normalize to the ready presence");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(
                @"MUJI pairwise payload filtering should not fail: $(e.message)");
        }
    }

    private void test_libwebrtc_adapter_muji_rejects_changed_receiving_parameters() {
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> configured =
            create_muji_payload_types();
        try {
            ArrayList<Xep.JingleRtp.LibwebrtcJingleContent> contents =
                create_conference_jingle_contents(configured);
            StanzaNode? audio_payload = contents[0].description.get_subnode(
                "payload-type", Xep.JingleRtp.NS_URI);
            if (audio_payload == null) {
                fail_if_reached("conference audio fixture has no payload");
                return;
            }
            Gee.List<StanzaNode> parameters = ((!) audio_payload).get_subnodes(
                "parameter", Xep.JingleRtp.NS_URI);
            bool changed = false;
            foreach (StanzaNode parameter in parameters) {
                if (parameter.get_attribute("name") == "useinbandfec") {
                    parameter.set_attribute("value", "false");
                    changed = true;
                }
            }
            if (!changed) {
                fail_if_reached(
                    "conference audio fixture has no useinbandfec parameter");
                return;
            }
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                contents,
                Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_reached(
                "MUJI must reject changed receiving parameters for a global PT");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            ArrayList<Xep.JingleRtp.LibwebrtcJingleContent> contents =
                create_conference_jingle_contents(configured);
            StanzaNode? video_payload = contents[1].description.get_subnode(
                "payload-type", Xep.JingleRtp.NS_URI);
            if (video_payload == null) {
                fail_if_reached("conference video fixture has no payload");
                return;
            }
            ((!) video_payload).put_node(
                new Xep.JingleRtp.RtcpFeedback("ccm", "fir").to_xml());
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            muji_local_description(adapter,
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_libwebrtc_bundle_sdp_fixture(),
                Xep.Jingle.Role.INITIATOR);
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.ANSWER,
                contents,
                Xep.Jingle.Role.INITIATOR,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_reached(
                "MUJI must reject changed RTCP feedback for a global PT");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private void test_libwebrtc_adapter_muji_rejects_malformed_payload_metadata() {
        assert_muji_rejects_payload_id(null, "missing payload ID");
        assert_muji_rejects_payload_id("-1", "negative payload ID");
        assert_muji_rejects_payload_id("128", "out-of-range payload ID");

        assert_muji_rejects_feedback_attribute(
            "type", null, "missing rtcp-fb type");
        assert_muji_rejects_feedback_attribute(
            "type", "", "empty rtcp-fb type");
        assert_muji_rejects_feedback_attribute(
            "type", "nack\r\ninvalid", "newline in rtcp-fb type");
        assert_muji_rejects_feedback_attribute(
            "subtype", "", "empty rtcp-fb subtype");
        assert_muji_rejects_feedback_attribute(
            "subtype", "pli\r\ninvalid", "newline in rtcp-fb subtype");

        assert_muji_accepts_feedback_without_subtype();
    }

    private void assert_muji_rejects_feedback_attribute(
            string attribute, string? value, string label) {
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> configured =
            create_muji_payload_types();
        try {
            ArrayList<Xep.JingleRtp.LibwebrtcJingleContent> contents =
                create_conference_jingle_contents(configured);
            StanzaNode? payload = contents[0].description.get_subnode(
                "payload-type", Xep.JingleRtp.NS_URI);
            StanzaNode? feedback = payload != null
                ? ((!) payload).get_subnode(
                    Xep.JingleRtp.RtcpFeedback.NAME,
                    Xep.JingleRtp.RtcpFeedback.NS_URI)
                : null;
            if (feedback == null) {
                fail_if_reached("conference payload fixture has no rtcp-fb");
                return;
            }
            if (value == null) {
                StanzaAttribute? existing =
                    ((!) feedback).get_attribute_raw(attribute);
                if (existing == null) {
                    fail_if_reached(
                        @"conference rtcp-fb fixture has no $(attribute)");
                    return;
                }
                ((!) feedback).attributes.remove((!) existing);
            } else {
                ((!) feedback).set_attribute(attribute, (!) value);
            }

            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                contents,
                Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_reached(@"MUJI must reject $(label)");
        } catch (Xep.Jingle.IqError e) {
            fail_if(e.code != Xep.Jingle.IqError.BAD_REQUEST,
                @"$(label) must produce bad-request");
        }
    }

    private void assert_muji_accepts_feedback_without_subtype() {
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> configured =
            create_muji_payload_types();
        Gee.List<Xep.JingleRtp.PayloadType>? audio = configured["audio"];
        if (audio == null || ((!) audio).is_empty) {
            fail_if_reached("conference audio fixture is empty");
            return;
        }
        ((!) audio)[0].rtcp_fbs.clear();
        ((!) audio)[0].rtcp_fbs.add(
            new Xep.JingleRtp.RtcpFeedback("transport-cc"));
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_conference_jingle_contents(configured),
                Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(
                @"MUJI must accept rtcp-fb without optional subtype: $(e.message)");
        }
    }

    private void assert_muji_rejects_payload_id(
            string? raw_id, string label) {
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> configured =
            create_muji_payload_types();
        try {
            ArrayList<Xep.JingleRtp.LibwebrtcJingleContent> contents =
                create_conference_jingle_contents(configured);
            StanzaNode? payload = contents[0].description.get_subnode(
                "payload-type", Xep.JingleRtp.NS_URI);
            if (payload == null) {
                fail_if_reached("conference audio fixture has no payload");
                return;
            }
            if (raw_id == null) {
                StanzaAttribute? id_attribute =
                    ((!) payload).get_attribute_raw("id");
                if (id_attribute == null) {
                    fail_if_reached("conference payload fixture has no ID");
                    return;
                }
                ((!) payload).attributes.remove((!) id_attribute);
            } else {
                ((!) payload).set_attribute("id", (!) raw_id);
            }

            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), configured);
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                contents,
                Xep.Jingle.Role.RESPONDER,
                Xep.JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
            fail_if_reached(@"MUJI must reject $(label)");
        } catch (Xep.Jingle.IqError e) {
            fail_if(e.code != Xep.Jingle.IqError.BAD_REQUEST,
                @"$(label) must produce bad-request");
        }
    }

    private void test_libwebrtc_adapter_muji_rejects_wrong_content_identity() {
        try {
            var adapter = new Xep.JingleRtp.LibwebrtcJingleAdapter();
            adapter.configure_conference_media(
                create_muji_content_names(), create_muji_payload_types());
            adapter.remote_description_from_jingle_contents(
                Xep.JingleRtp.LibwebrtcSdpType.OFFER,
                create_adapter_jingle_contents(),
                Xep.Jingle.Role.RESPONDER);
            fail_if_reached(
                "MUJI adapter must reject same-media Jingle with a different content name");
        } catch (Xep.Jingle.IqError e) {
            // Expected: XEP-0272 content identity is exact.
        }
    }

    private void test_jingle_nodes_audio_section_roundtrip() {
        var section = create_audio_media_section();

        try {
            StanzaNode description = Xep.JingleRtp.SdpBridge.media_section_to_jingle_description_node(section);
            StanzaNode transport = Xep.JingleRtp.SdpBridge.media_section_to_jingle_transport_node(section);

            fail_if_not_eq_str(description.name, "description", "Jingle description node name should be stable");
            fail_if_not_eq_str(description.ns_uri, Xep.JingleRtp.NS_URI, "Jingle description namespace should be RTP");
            fail_if_not_eq_str(description.get_attribute("media"), "audio", "Jingle description should preserve media");
            fail_if_not_eq_int(description.get_subnodes(Xep.JingleRtp.PayloadType.NAME).size, 1,
                "Jingle description should preserve payload types");
            fail_if(description.get_subnode("rtcp-mux") == null, "Jingle description should preserve rtcp-mux");

            fail_if_not_eq_str(transport.name, "transport", "Jingle transport node name should be stable");
            fail_if_not_eq_str(transport.ns_uri, Xep.JingleIceUdp.NS_URI, "Jingle transport namespace should be ICE-UDP");
            fail_if_not_eq_str(transport.get_attribute("ufrag"), "audio-ufrag", "Jingle transport should preserve ICE ufrag");
            fail_if_not_eq_str(transport.get_attribute("pwd"), "audio-pwd", "Jingle transport should preserve ICE pwd");
            fail_if_not_eq_int(transport.get_subnodes("candidate").size, 1,
                "Jingle transport should preserve candidates");

            StanzaNode? fingerprint = transport.get_subnode("fingerprint", Xep.JingleIceUdp.DTLS_NS_URI);
            fail_if(fingerprint == null, "Jingle transport should include DTLS fingerprint");
            if (fingerprint != null) {
                fail_if_not_eq_str(((!) fingerprint).get_attribute("hash"), "sha-256",
                    "Jingle fingerprint should preserve hash");
                fail_if_not_eq_str(((!) fingerprint).get_attribute("setup"), "actpass",
                    "Jingle fingerprint should preserve setup");
                fail_if_not_eq_str(((!) fingerprint).get_string_content(), "01:AB:FF",
                    "Jingle fingerprint should use XEP-0176 text format");
            }

            Xep.JingleRtp.SdpMediaSection parsed = Xep.JingleRtp.SdpBridge.media_section_from_jingle_nodes(
                "0", description, transport);
            fail_if_not_eq_str(parsed.mid, "0", "Jingle node parser should use content name as MID");
            fail_if_not_eq_str(parsed.media, "audio", "Jingle node parser should preserve media");
            fail_if_not_eq_str(parsed.ice_ufrag, "audio-ufrag", "Jingle node parser should preserve ICE ufrag");
            fail_if_not_eq_str(parsed.ice_pwd, "audio-pwd", "Jingle node parser should preserve ICE pwd");
            fail_if_not(parsed.rtcp_mux, "Jingle node parser should preserve rtcp-mux");
            fail_if_not_eq_int(parsed.payload_types.size, 1, "Jingle node parser should preserve payload count");
            fail_if_not_eq_str(parsed.payload_types[0].name, "opus", "Jingle node parser should preserve payload name");
            fail_if_not_eq_int(parsed.candidates.size, 1, "Jingle node parser should preserve candidate count");
            fail_if_not_eq_str(parsed.candidates[0].ip, "203.0.113.10", "Jingle node parser should preserve candidate IP");
            fail_if(parsed.fingerprint == null, "Jingle node parser should preserve fingerprint");
            if (parsed.fingerprint != null) {
                fail_if_not_eq_str(((!) parsed.fingerprint).hash, "sha-256",
                    "Jingle node parser should preserve fingerprint hash");
                fail_if_not_eq_int(((!) parsed.fingerprint).fingerprint.length, 3,
                    "Jingle node parser should preserve fingerprint size");
            }
            fail_if_not_eq_str(parsed.setup, "actpass", "Jingle node parser should preserve DTLS setup");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"Jingle node roundtrip should not fail: $(e.message)");
        }
    }

    private void test_jingle_nodes_reject_invalid_shape() {
        var no_payload = new Xep.JingleRtp.SdpMediaSection("audio");
        no_payload.ice_ufrag = "ufrag";
        no_payload.ice_pwd = "pwd";
        try {
            Xep.JingleRtp.SdpBridge.media_section_to_jingle_description_node(no_payload);
            fail_if_reached("Jingle description serialization must reject empty payload set");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        var missing_pwd = create_audio_media_section();
        missing_pwd.ice_pwd = null;
        try {
            Xep.JingleRtp.SdpBridge.media_section_to_jingle_transport_node(missing_pwd);
            fail_if_reached("Jingle transport serialization must reject incomplete ICE credentials");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            var wrong_description = new StanzaNode.build("description", "urn:example:wrong").add_self_xmlns();
            StanzaNode transport = Xep.JingleRtp.SdpBridge.media_section_to_jingle_transport_node(
                create_audio_media_section());
            Xep.JingleRtp.SdpBridge.media_section_from_jingle_nodes("0", wrong_description, transport);
            fail_if_reached("Jingle node parser must reject non-RTP descriptions");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            var empty_description = new StanzaNode.build("description", Xep.JingleRtp.NS_URI)
                    .add_self_xmlns()
                    .put_attribute("media", "audio");
            StanzaNode transport = Xep.JingleRtp.SdpBridge.media_section_to_jingle_transport_node(
                create_audio_media_section());
            Xep.JingleRtp.SdpBridge.media_section_from_jingle_nodes("0", empty_description, transport);
            fail_if_reached("Jingle node parser must reject descriptions without payloads");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            StanzaNode description = Xep.JingleRtp.SdpBridge.media_section_to_jingle_description_node(
                create_audio_media_section());
            var empty_transport = new StanzaNode.build("transport", Xep.JingleIceUdp.NS_URI).add_self_xmlns();
            Xep.JingleRtp.SdpBridge.media_section_from_jingle_nodes("0", description, empty_transport);
            fail_if_reached("Jingle node parser must reject transports without ICE credentials");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private void test_jingle_content_node_pairs_session_roundtrip() {
        try {
            var audio = create_audio_media_section();
            var video = create_video_media_section();
            var content_pairs = new ArrayList<Xep.JingleRtp.SdpJingleContentNodePair>();
            content_pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair(
                "audio",
                Xep.JingleRtp.SdpBridge.media_section_to_jingle_description_node(audio),
                Xep.JingleRtp.SdpBridge.media_section_to_jingle_transport_node(audio)));
            content_pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair(
                "video",
                Xep.JingleRtp.SdpBridge.media_section_to_jingle_description_node(video),
                Xep.JingleRtp.SdpBridge.media_section_to_jingle_transport_node(video)));

            Xep.JingleRtp.SdpSession session = Xep.JingleRtp.SdpBridge.session_from_jingle_content_node_pairs(
                content_pairs);
            fail_if_not_eq_int(session.media_sections.size, 2, "Jingle pair collector should preserve section count");
            fail_if_not_eq_int(session.bundle_mids.size, 0, "Jingle pair collector must not invent BUNDLE policy");
            fail_if_not_eq_str(session.media_sections[0].mid, "audio", "Jingle content name should become audio MID");
            fail_if_not_eq_str(session.media_sections[0].media, "audio", "Jingle pair collector should preserve audio media");
            fail_if_not_eq_str(session.media_sections[1].mid, "video", "Jingle content name should become video MID");
            fail_if_not_eq_str(session.media_sections[1].media, "video", "Jingle pair collector should preserve video media");

            string sdp = Xep.JingleRtp.SdpBridge.session_to_sdp(session);
            fail_if(!sdp.contains("a=mid:audio\r\n"), "Jingle pair session should serialize audio MID");
            fail_if(!sdp.contains("a=mid:video\r\n"), "Jingle pair session should serialize video MID");

            Gee.List<Xep.JingleRtp.SdpJingleContentNodePair> parsed_pairs =
                Xep.JingleRtp.SdpBridge.jingle_content_node_pairs_from_session(session);
            fail_if_not_eq_int(parsed_pairs.size, 2, "Session splitter should preserve content pair count");
            fail_if_not_eq_str(parsed_pairs[0].content_name, "audio", "Session splitter should preserve audio name");
            fail_if_not_eq_str(parsed_pairs[1].content_name, "video", "Session splitter should preserve video name");
            fail_if_not_eq_str(parsed_pairs[0].description.get_attribute("media"), "audio",
                "Session splitter should preserve audio description");
            fail_if_not_eq_str(parsed_pairs[1].description.get_attribute("media"), "video",
                "Session splitter should preserve video description");
            fail_if_not_eq_str(parsed_pairs[0].transport.get_attribute("ufrag"), "audio-ufrag",
                "Session splitter should preserve audio transport");
            fail_if_not_eq_str(parsed_pairs[1].transport.get_attribute("ufrag"), "video-ufrag",
                "Session splitter should preserve video transport");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"Jingle content pair session roundtrip should not fail: $(e.message)");
        }
    }

    private void test_jingle_content_node_pairs_reject_invalid_shape() {
        try {
            var empty_pairs = new ArrayList<Xep.JingleRtp.SdpJingleContentNodePair>();
            Xep.JingleRtp.SdpBridge.session_from_jingle_content_node_pairs(empty_pairs);
            fail_if_reached("Jingle pair collector must reject empty content lists");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            var section = create_audio_media_section();
            StanzaNode description = Xep.JingleRtp.SdpBridge.media_section_to_jingle_description_node(section);
            StanzaNode transport = Xep.JingleRtp.SdpBridge.media_section_to_jingle_transport_node(section);
            var duplicate_pairs = new ArrayList<Xep.JingleRtp.SdpJingleContentNodePair>();
            duplicate_pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair("dup", description, transport));
            duplicate_pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair("dup", description, transport));
            Xep.JingleRtp.SdpBridge.session_from_jingle_content_node_pairs(duplicate_pairs);
            fail_if_reached("Jingle pair collector must reject duplicate content names");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }

        try {
            var duplicate_session = new Xep.JingleRtp.SdpSession();
            var audio = create_audio_media_section();
            audio.mid = "dup";
            var video = create_video_media_section();
            video.mid = "dup";
            duplicate_session.media_sections.add(audio);
            duplicate_session.media_sections.add(video);
            Xep.JingleRtp.SdpBridge.jingle_content_node_pairs_from_session(duplicate_session);
            fail_if_reached("Session splitter must reject duplicate content names");
        } catch (Xep.Jingle.IqError e) {
            // Expected.
        }
    }

    private void test_dinox_style_content_pair_fixture_parse() {
        try {
            var audio_payloads = new ArrayList<Xep.JingleRtp.PayloadType>();
            audio_payloads.add(create_opus_payload());
            var video_payloads = new ArrayList<Xep.JingleRtp.PayloadType>();
            video_payloads.add(create_vp8_payload());

            var pairs = new ArrayList<Xep.JingleRtp.SdpJingleContentNodePair>();
            pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair(
                "audio",
                create_jingle_description_node("audio", audio_payloads),
                create_jingle_transport_node("dinox-audio", "dinox-audio-password", "actpass", "01:AB:FF", true)));
            pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair(
                "video",
                create_jingle_description_node("video", video_payloads),
                create_jingle_transport_node("dinox-video", "dinox-video-password", "actpass", "AA:BB:CC", true)));

            Xep.JingleRtp.SdpSession session = Xep.JingleRtp.SdpBridge.session_from_jingle_content_node_pairs(pairs);
            fail_if_not_eq_int(session.media_sections.size, 2,
                "DinoX-style fixture should preserve audio/video content count");
            fail_if_not_eq_str(session.media_sections[0].mid, "audio",
                "DinoX-style fixture should preserve audio content name");
            fail_if_not_eq_str(session.media_sections[1].mid, "video",
                "DinoX-style fixture should preserve video content name");
            fail_if_not_eq_str(session.media_sections[0].payload_types[0].name, "opus",
                "DinoX-style fixture should preserve Opus payload");
            fail_if_not_eq_str(session.media_sections[1].payload_types[0].name, "VP8",
                "DinoX-style fixture should preserve VP8 payload");
            fail_if_not_eq_int(session.media_sections[0].candidates.size, 1,
                "DinoX-style fixture should preserve audio candidate");
            fail_if_not_eq_int(session.media_sections[1].candidates.size, 1,
                "DinoX-style fixture should preserve video candidate");

            string sdp = Xep.JingleRtp.SdpBridge.session_to_sdp(session);
            fail_if(!sdp.contains("a=mid:audio\r\n"), "DinoX-style fixture should serialize audio MID");
            fail_if(!sdp.contains("a=mid:video\r\n"), "DinoX-style fixture should serialize video MID");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"DinoX-style Jingle fixture should parse: $(e.message)");
        }
    }

    private void test_mobile_style_trickle_fixture_parse() {
        try {
            var audio_payloads = new ArrayList<Xep.JingleRtp.PayloadType>();
            audio_payloads.add(create_opus_payload());
            var video_payloads = new ArrayList<Xep.JingleRtp.PayloadType>();
            video_payloads.add(create_vp8_payload());
            video_payloads.add(create_h264_payload());

            var pairs = new ArrayList<Xep.JingleRtp.SdpJingleContentNodePair>();
            pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair(
                "0",
                create_jingle_description_node("audio", audio_payloads),
                create_jingle_transport_node("mobile-audio", "mobile-audio-password", "active",
                    "10:20:30:40:50:60", false)));
            pairs.add(new Xep.JingleRtp.SdpJingleContentNodePair(
                "1",
                create_jingle_description_node("video", video_payloads),
                create_jingle_transport_node("mobile-video", "mobile-video-password", "active",
                    "AA:BB:CC:DD:EE:FF", false)));

            Xep.JingleRtp.SdpSession session = Xep.JingleRtp.SdpBridge.session_from_jingle_content_node_pairs(pairs);
            fail_if_not_eq_int(session.media_sections.size, 2,
                "mobile-style fixture should preserve audio/video content count");
            fail_if_not_eq_str(session.media_sections[0].mid, "0",
                "mobile-style fixture should preserve numeric audio content name");
            fail_if_not_eq_str(session.media_sections[1].mid, "1",
                "mobile-style fixture should preserve numeric video content name");
            fail_if_not_eq_str(session.media_sections[0].setup, "active",
                "mobile-style fixture should preserve audio DTLS setup");
            fail_if_not_eq_str(session.media_sections[1].setup, "active",
                "mobile-style fixture should preserve video DTLS setup");
            fail_if_not_eq_int(session.media_sections[0].candidates.size, 0,
                "mobile-style fixture should allow initial trickle shape without candidates");
            fail_if_not_eq_int(session.media_sections[1].payload_types.size, 2,
                "mobile-style fixture should preserve VP8 and H264 alternatives");
            fail_if_not_eq_str(session.media_sections[1].payload_types[1].name, "H264",
                "mobile-style fixture should preserve H264 alternative");
            fail_if_not_eq_str(session.media_sections[1].payload_types[1].parameters["profile-level-id"], "42e01f",
                "mobile-style fixture should preserve H264 profile-level-id");

            Gee.List<Xep.JingleRtp.SdpJingleContentNodePair> parsed_pairs =
                Xep.JingleRtp.SdpBridge.jingle_content_node_pairs_from_session(session);
            fail_if_not_eq_int(parsed_pairs.size, 2,
                "mobile-style fixture should split back into content pairs");
            fail_if_not_eq_str(parsed_pairs[0].content_name, "0",
                "mobile-style fixture should keep numeric audio content name");
            fail_if_not_eq_str(parsed_pairs[1].content_name, "1",
                "mobile-style fixture should keep numeric video content name");
            fail_if_not_eq_int(parsed_pairs[1].description.get_subnodes(Xep.JingleRtp.PayloadType.NAME).size, 2,
                "mobile-style fixture should preserve video payload alternatives in Jingle");
            fail_if_not_eq_int(parsed_pairs[1].transport.get_subnodes("candidate").size, 0,
                "mobile-style fixture should keep candidate-less initial transport");
        } catch (Xep.Jingle.IqError e) {
            fail_if_reached(@"mobile-style Jingle fixture should parse: $(e.message)");
        }
    }
}

}
