using Gee;

namespace Xmpp.Test {

/**
 * XEP-0260 / RFC 1928: SOCKS5 Bytestreams protocol logic
 *
 * Tests protocol helpers and local listener lifecycle from the Jingle SOCKS5 Bytestreams module:
 *   - calculate_dstaddr(): SHA1(sid + jid1 + jid2) per XEP-0260 §4
 *   - bytes_equal(): byte array comparison (used in handshake validation)
 *   - Candidate.parse() / to_xml(): XML ↔ object roundtrip
 *   - CandidateType.to_string(): enum → string serialization
 *   - Proxy URI construction for Tor/SOCKS5 (starttls_xmpp_stream.vala)
 */
class Socks5Audit : Gee.TestCase {
    private const string NS_JINGLE_S5B = "urn:xmpp:jingle:transports:s5b:1";
    private const string NS_JINGLE_IBB = "urn:xmpp:jingle:transports:ibb:1";

    public Socks5Audit() {
        base("Socks5Audit");

        // --- calculate_dstaddr (XEP-0260 §4) ---
        add_test("XEP0260_dstaddr_sha1_deterministic", test_dstaddr_deterministic);
        add_test("XEP0260_dstaddr_order_matters", test_dstaddr_order_matters);
        add_test("XEP0260_dstaddr_is_sha1_hex_lowercase", test_dstaddr_is_sha1_hex);
        add_test("XEP0260_dstaddr_different_sid_different_hash", test_dstaddr_different_sid);

        // --- bytes_equal ---
        add_test("RFC1928_bytes_equal_same", test_bytes_equal_same);
        add_test("RFC1928_bytes_equal_different_content", test_bytes_equal_diff_content);
        add_test("RFC1928_bytes_equal_different_length", test_bytes_equal_diff_length);
        add_test("RFC1928_bytes_equal_empty", test_bytes_equal_empty);

        // --- CandidateType.to_string roundtrip ---
        add_test("XEP0260_candidate_type_roundtrip_all", test_candidate_type_roundtrip);

        // --- Candidate XML roundtrip ---
        add_test("XEP0260_candidate_parse_xml_roundtrip", test_candidate_xml_roundtrip);
        add_test("XEP0260_candidate_parse_missing_cid_throws", test_candidate_parse_missing_cid);
        add_test("XEP0260_candidate_parse_default_type_direct", test_candidate_parse_default_type);
        add_test("XEP0260_candidate_parse_default_port_1080", test_candidate_parse_default_port);
        add_test("XEP0260_candidate_priority_includes_type", test_candidate_priority_type);

        // --- Jingle S5B network policy ---
        add_test("XEP0260_network_policy_blocks_direct_candidates_without_proxy", test_network_policy_blocks_direct_candidates_without_proxy);
        add_test("XEP0260_network_policy_keeps_proxy_candidates_when_direct_blocked", test_network_policy_keeps_proxy_candidates_when_direct_blocked);
        add_test("XEP0260_network_policy_unavailable_when_direct_blocked_without_proxy", test_network_policy_unavailable_when_direct_blocked_without_proxy);
        add_test("XEP0260_transport_selection_prefers_s5b_when_direct_allowed", test_transport_selection_prefers_s5b_when_direct_allowed);
        add_test("XEP0260_transport_selection_falls_back_to_ibb_when_s5b_proxy_blocked", test_transport_selection_falls_back_to_ibb_when_s5b_proxy_blocked);
        add_test("XEP0260_attached_transport_selection_falls_back_to_ibb_when_s5b_proxy_blocked", test_attached_transport_selection_falls_back_to_ibb_when_s5b_proxy_blocked);
        add_test("XEP0260_direct_listener_accepts_socks5_and_dispose_closes_connection", test_direct_listener_accepts_socks5_and_dispose_closes_connection);
        add_test("XEP0260_direct_candidate_override_publishes_public_endpoint_and_listens_locally", test_direct_candidate_override_publishes_public_endpoint_and_listens_locally);
        add_test("XEP0260_direct_candidate_override_respects_no_direct_policy", test_direct_candidate_override_respects_no_direct_policy);
    }

    // ===================== calculate_dstaddr =====================

    /**
     * XEP-0260 §4: dstaddr = SHA1(sid + initiator_jid + responder_jid)
     * Same inputs MUST produce same output (deterministic).
     */
    private void test_dstaddr_deterministic() {
        string sid = "test-session-123";
        try {
            Jid jid1 = new Jid("alice@example.com/res1");
            Jid jid2 = new Jid("bob@example.com/res2");

            string h1 = Xep.JingleSocks5Bytestreams.calculate_dstaddr(sid, jid1, jid2);
            string h2 = Xep.JingleSocks5Bytestreams.calculate_dstaddr(sid, jid1, jid2);

            fail_if_not_eq_str(h1, h2);
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0260 §4: SHA1(sid + jid1 + jid2) != SHA1(sid + jid2 + jid1)
     * Argument order MUST matter.
     */
    private void test_dstaddr_order_matters() {
        string sid = "session-order";
        try {
            Jid jid1 = new Jid("alice@example.com/r1");
            Jid jid2 = new Jid("bob@example.com/r2");

            string h1 = Xep.JingleSocks5Bytestreams.calculate_dstaddr(sid, jid1, jid2);
            string h2 = Xep.JingleSocks5Bytestreams.calculate_dstaddr(sid, jid2, jid1);

            fail_if(h1 == h2, "XEP-0260 §4: dstaddr MUST differ when JID order is swapped");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * SHA1 hex output MUST be 40 lowercase hex characters.
     */
    private void test_dstaddr_is_sha1_hex() {
        try {
            Jid jid1 = new Jid("user@host.tld/res");
            Jid jid2 = new Jid("peer@other.tld/dev");

            string h = Xep.JingleSocks5Bytestreams.calculate_dstaddr("s1", jid1, jid2);

            fail_if(h.length != 40, @"SHA1 hex MUST be 40 chars, got $(h.length)");

            // Must be all lowercase hex
            for (int i = 0; i < h.length; i++) {
                char c = h[i];
                bool valid = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                fail_if(!valid, @"SHA1 hex char at pos $i MUST be lowercase hex, got '$(c)'");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * Different session IDs MUST produce different dstaddr hashes.
     */
    private void test_dstaddr_different_sid() {
        try {
            Jid jid1 = new Jid("a@b.c/d");
            Jid jid2 = new Jid("e@f.g/h");

            string h1 = Xep.JingleSocks5Bytestreams.calculate_dstaddr("session-alpha", jid1, jid2);
            string h2 = Xep.JingleSocks5Bytestreams.calculate_dstaddr("session-beta", jid1, jid2);

            fail_if(h1 == h2, "XEP-0260: different SID MUST produce different dstaddr");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    // ===================== bytes_equal =====================

    private void test_bytes_equal_same() {
        uint8[] a = { 0x05, 0x01, 0x00 };
        uint8[] b = { 0x05, 0x01, 0x00 };
        fail_if_not(Xep.JingleSocks5Bytestreams.bytes_equal(a, b),
                    "RFC 1928: identical byte arrays MUST be equal");
    }

    private void test_bytes_equal_diff_content() {
        uint8[] a = { 0x05, 0x01, 0x00 };
        uint8[] b = { 0x05, 0x01, 0x01 };
        fail_if(Xep.JingleSocks5Bytestreams.bytes_equal(a, b),
                "RFC 1928: differing byte arrays MUST NOT be equal");
    }

    private void test_bytes_equal_diff_length() {
        uint8[] a = { 0x05, 0x01 };
        uint8[] b = { 0x05, 0x01, 0x00 };
        fail_if(Xep.JingleSocks5Bytestreams.bytes_equal(a, b),
                "RFC 1928: different-length arrays MUST NOT be equal");
    }

    private void test_bytes_equal_empty() {
        uint8[] a = {};
        uint8[] b = {};
        fail_if_not(Xep.JingleSocks5Bytestreams.bytes_equal(a, b),
                    "RFC 1928: two empty arrays MUST be equal");
    }

    // ===================== CandidateType.to_string roundtrip =====================

    /**
     * All 4 CandidateType values MUST roundtrip through to_string() → parse().
     */
    private void test_candidate_type_roundtrip() {
        try {
            var types = new Xep.JingleSocks5Bytestreams.CandidateType[] {
                Xep.JingleSocks5Bytestreams.CandidateType.ASSISTED,
                Xep.JingleSocks5Bytestreams.CandidateType.DIRECT,
                Xep.JingleSocks5Bytestreams.CandidateType.PROXY,
                Xep.JingleSocks5Bytestreams.CandidateType.TUNNEL
            };
            foreach (var t in types) {
                string s = t.to_string();
                var parsed = Xep.JingleSocks5Bytestreams.CandidateType.parse(s);
                fail_if(parsed != t,
                        @"XEP-0260: CandidateType.$(s) MUST roundtrip through to_string()/parse()");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    // ===================== Candidate XML roundtrip =====================

    /**
     * XEP-0260: Candidate.parse(node) → to_xml() MUST preserve all attributes.
     */
    private void test_candidate_xml_roundtrip() {
        try {
            string xml = "<candidate xmlns='urn:xmpp:jingle:transports:s5b:1' " +
                         "cid='c1' host='192.168.1.1' jid='proxy@example.com' " +
                         "port='5086' priority='8257636' type='direct'/>";

            var reader = new StanzaReader.for_string(xml);
            var node = yield_stanza_node(reader);

            var candidate = Xep.JingleSocks5Bytestreams.Candidate.parse(node);

            fail_if_not_eq_str(candidate.cid, "c1");
            fail_if_not_eq_str(candidate.host, "192.168.1.1");
            fail_if_not_eq_str(candidate.jid.to_string(), "proxy@example.com");
            fail_if_not_eq_int(candidate.port, 5086);
            fail_if_not_eq_int(candidate.priority, 8257636);
            fail_if_not(candidate.type_ == Xep.JingleSocks5Bytestreams.CandidateType.DIRECT,
                        "XEP-0260: type MUST be DIRECT");

            // Serialize back and verify
            var out_node = candidate.to_xml();
            fail_if_not_eq_str(out_node.get_attribute("cid"), "c1");
            fail_if_not_eq_str(out_node.get_attribute("host"), "192.168.1.1");
            fail_if_not_eq_str(out_node.get_attribute("jid"), "proxy@example.com");
            fail_if_not_eq_str(out_node.get_attribute("port"), "5086");
            fail_if_not_eq_str(out_node.get_attribute("priority"), "8257636");
            fail_if_not_eq_str(out_node.get_attribute("type"), "direct");
        } catch (Error e) {
            fail_if_reached(@"XML roundtrip error: $(e.message)");
        }
    }

    /**
     * XEP-0260: Missing cid attribute MUST throw IqError.BAD_REQUEST.
     */
    private void test_candidate_parse_missing_cid() {
        // Missing cid attribute
        string xml = "<candidate xmlns='urn:xmpp:jingle:transports:s5b:1' " +
                     "host='1.2.3.4' jid='j@ex.com' port='1080' priority='100' type='direct'/>";

        var reader = new StanzaReader.for_string(xml);
        var node = yield_stanza_node(reader);

        try {
            Xep.JingleSocks5Bytestreams.Candidate.parse(node);
            fail_if(true, "XEP-0260: missing cid MUST throw IqError");
        } catch (Xep.Jingle.IqError e) {
            // Expected
            assert_true(true);
        }
    }

    /**
     * XEP-0260: Missing type attribute MUST default to DIRECT.
     */
    private void test_candidate_parse_default_type() {
        try {
            string xml = "<candidate xmlns='urn:xmpp:jingle:transports:s5b:1' " +
                         "cid='c2' host='1.2.3.4' jid='j@ex.com' port='1080' priority='100'/>";

            var reader = new StanzaReader.for_string(xml);
            var node = yield_stanza_node(reader);

            var candidate = Xep.JingleSocks5Bytestreams.Candidate.parse(node);
            fail_if_not(candidate.type_ == Xep.JingleSocks5Bytestreams.CandidateType.DIRECT,
                        "XEP-0260: missing type MUST default to DIRECT");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0260: Missing port attribute MUST default to 1080.
     */
    private void test_candidate_parse_default_port() {
        try {
            string xml = "<candidate xmlns='urn:xmpp:jingle:transports:s5b:1' " +
                         "cid='c3' host='1.2.3.4' jid='j@ex.com' priority='100' type='proxy'/>";

            var reader = new StanzaReader.for_string(xml);
            var node = yield_stanza_node(reader);

            var candidate = Xep.JingleSocks5Bytestreams.Candidate.parse(node);
            fail_if_not_eq_int(candidate.port, 1080);
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    /**
     * XEP-0260: Candidate.build() priority MUST include type_preference.
     * direct (126<<16) > assisted (120<<16) > tunnel (110<<16) > proxy (10<<16)
     */
    private void test_candidate_priority_type() {
        try {
            var jid = new Jid("p@ex.com");
            int local_prio = 500;

            var direct = new Xep.JingleSocks5Bytestreams.Candidate.build(
                "d1", "1.2.3.4", jid, 1080, local_prio,
                Xep.JingleSocks5Bytestreams.CandidateType.DIRECT);
            var proxy = new Xep.JingleSocks5Bytestreams.Candidate.build(
                "p1", "5.6.7.8", jid, 1080, local_prio,
                Xep.JingleSocks5Bytestreams.CandidateType.PROXY);

            fail_if(direct.priority <= proxy.priority,
                    @"XEP-0260: DIRECT priority ($(direct.priority)) MUST be > PROXY priority ($(proxy.priority))");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    // ===================== Jingle S5B network policy =====================

    private void test_network_policy_blocks_direct_candidates_without_proxy() {
        try {
            var stream = create_s5b_test_stream(false);
            var module = new Xep.JingleSocks5Bytestreams.Module();
            module.set_network_policy(false, "socks5://127.0.0.1:9050");

            Xep.Jingle.TransportParameters parameters = module.create_transport_parameters(
                stream,
                1,
                new Jid("alice@example.test/dinox"),
                new Jid("bob@example.test/phone"));
            StanzaNode transport = parameters.to_transport_stanza_node("session-initiate");

            fail_if(count_candidates(transport) != 0,
                "Proxy/Tor policy without a discovered S5B proxy must not publish direct candidates");
            fail_if(count_candidates_by_type(transport, "direct") != 0,
                "Proxy/Tor policy must not publish local DIRECT Jingle S5B candidates");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    private void test_network_policy_keeps_proxy_candidates_when_direct_blocked() {
        try {
            var stream = create_s5b_test_stream(true);
            var module = new Xep.JingleSocks5Bytestreams.Module();
            module.set_network_policy(false, "socks5://127.0.0.1:9050");

            Xep.Jingle.TransportParameters parameters = module.create_transport_parameters(
                stream,
                1,
                new Jid("alice@example.test/dinox"),
                new Jid("bob@example.test/phone"));
            StanzaNode transport = parameters.to_transport_stanza_node("session-initiate");

            fail_if(count_candidates_by_type(transport, "direct") != 0,
                "Proxy/Tor policy must not add local DIRECT candidates when proxy candidates exist");
            fail_if(count_candidates_by_type(transport, "proxy") != 1,
                "Proxy/Tor policy should keep discovered S5B proxy candidates instead of disabling Jingle S5B globally");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    private void test_network_policy_unavailable_when_direct_blocked_without_proxy() {
        try {
            var stream = create_s5b_test_stream(false);
            var module = new Xep.JingleSocks5Bytestreams.Module();
            module.set_network_policy(false, "socks5://127.0.0.1:9050");

            bool available = run_transport_available(
                module,
                stream,
                new Jid("bob@example.test/phone"));

            fail_if(available,
                "Jingle S5B must not be advertised as available when both direct candidates and proxy candidates are unavailable");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    private void test_transport_selection_prefers_s5b_when_direct_allowed() {
        try {
            var stream = create_jingle_transport_selection_stream(true);
            var peer = new Jid("bob@example.test/phone");
            var cache = (FakeCapsCache) stream.get_module<Xep.ServiceDiscovery.Module>(Xep.ServiceDiscovery.Module.IDENTITY).cache;
            cache.add_feature(peer, NS_JINGLE_S5B);
            cache.add_feature(peer, NS_JINGLE_IBB);

            var s5b = new Xep.JingleSocks5Bytestreams.Module();
            s5b.set_network_policy(true, null);
            var ibb = new Xep.JingleInBandBytestreams.Module();
            var jingle = new Xep.Jingle.Module();
            jingle.register_transport(s5b);
            jingle.register_transport(ibb);

            Xep.Jingle.Transport? selected = run_select_transport(jingle, stream, peer);

            fail_if(selected == null, "Jingle should select a streaming transport when S5B and IBB are both available");
            fail_if(((!) selected).ns_uri != NS_JINGLE_S5B,
                "Jingle should prefer higher-priority S5B over IBB when direct candidates are allowed");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    private void test_transport_selection_falls_back_to_ibb_when_s5b_proxy_blocked() {
        try {
            var stream = create_jingle_transport_selection_stream(false);
            var peer = new Jid("bob@example.test/phone");
            var cache = (FakeCapsCache) stream.get_module<Xep.ServiceDiscovery.Module>(Xep.ServiceDiscovery.Module.IDENTITY).cache;
            cache.add_feature(peer, NS_JINGLE_S5B);
            cache.add_feature(peer, NS_JINGLE_IBB);

            var s5b = new Xep.JingleSocks5Bytestreams.Module();
            s5b.set_network_policy(false, "socks5://127.0.0.1:9050");
            var ibb = new Xep.JingleInBandBytestreams.Module();
            var jingle = new Xep.Jingle.Module();
            jingle.register_transport(s5b);
            jingle.register_transport(ibb);

            Xep.Jingle.Transport? selected = run_select_transport(jingle, stream, peer);

            fail_if(selected == null, "Jingle should fall back to IBB when S5B is blocked by proxy policy and no S5B proxy exists");
            fail_if(((!) selected).ns_uri != NS_JINGLE_IBB,
                "Jingle should choose IBB instead of S5B direct candidates under proxy/Tor without discovered S5B proxies");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    private void test_attached_transport_selection_falls_back_to_ibb_when_s5b_proxy_blocked() {
        try {
            var stream = create_attached_jingle_transport_selection_stream(false, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = (FakeCapsCache) stream.get_module<Xep.ServiceDiscovery.Module>(Xep.ServiceDiscovery.Module.IDENTITY).cache;
            cache.add_feature(peer, NS_JINGLE_S5B);
            cache.add_feature(peer, NS_JINGLE_IBB);

            var jingle = stream.get_module<Xep.Jingle.Module>(Xep.Jingle.Module.IDENTITY);
            fail_if(jingle == null, "attached transport selection test requires a Jingle module");
            fail_if(((!) jingle).get_transport(NS_JINGLE_S5B) == null,
                "JingleSocks5Bytestreams.attach() must register S5B with the Jingle module");
            fail_if(((!) jingle).get_transport(NS_JINGLE_IBB) == null,
                "JingleInBandBytestreams.attach() must register IBB with the Jingle module");

            Xep.Jingle.Transport? selected = run_select_transport((!) jingle, stream, peer);

            fail_if(selected == null, "Attached Jingle modules should fall back to IBB when S5B is blocked by proxy policy");
            fail_if(((!) selected).ns_uri != NS_JINGLE_IBB,
                "Attached Jingle transport selection should choose IBB under proxy/Tor without discovered S5B proxies");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error: $(e.message)");
        }
    }

    private void test_direct_listener_accepts_socks5_and_dispose_closes_connection() {
        Xep.Jingle.TransportParameters? parameters = null;
        SocketConnection? connection = null;
        try {
            var stream = create_s5b_test_stream(false);
            var module = new Xep.JingleSocks5Bytestreams.Module();
            module.set_network_policy(true, null);

            var local_jid = new Jid("alice@example.test/dinox");
            var peer_jid = new Jid("bob@example.test/phone");
            parameters = module.create_transport_parameters(
                stream,
                1,
                local_jid,
                peer_jid);
            StanzaNode transport = ((!) parameters).to_transport_stanza_node("session-initiate");
            StanzaNode candidate_node = get_single_candidate_by_type(transport, "direct");
            var candidate = Xep.JingleSocks5Bytestreams.Candidate.parse(candidate_node);
            string? dstaddr = transport.get_attribute("dstaddr");
            fail_if(dstaddr == null || ((!) dstaddr) == "",
                "S5B direct listener transport must publish the local dstaddr");

            connection = run_connect_to_socks5(candidate, (!) dstaddr);
            drain_listener_accept_bookkeeping();

            ((!) parameters).dispose();

            fail_if(!wait_for_socket_eof_after_close((!) connection, 1000),
                "S5B transport parameter disposal must close accepted direct listener connections");
            fail_if(can_connect_to_socks5(candidate, (!) dstaddr),
                "S5B transport parameter disposal must close the prepared direct listener");
            parameters = null;
        } catch (Error e) {
            fail_if_reached(@"Unexpected direct S5B listener error: $(e.message)");
        } finally {
            if (parameters != null) {
                ((!) parameters).dispose();
            }
            if (connection != null) {
                try {
                    ((!) connection).close();
                } catch (Error e) {
                }
            }
        }
    }

    private void test_direct_candidate_override_publishes_public_endpoint_and_listens_locally() {
        Xep.Jingle.TransportParameters? parameters = null;
        SocketConnection? connection = null;
        try {
            int port = reserve_free_loopback_port();
            var stream = create_s5b_test_stream(false);
            var module = new Xep.JingleSocks5Bytestreams.Module();
            module.set_network_policy(true, null);
            module.set_direct_candidate_override_for_tests("127.0.0.1", "198.51.100.24", port);

            var local_jid = new Jid("alice@example.test/dinox");
            var peer_jid = new Jid("bob@example.test/phone");
            parameters = module.create_transport_parameters(
                stream,
                1,
                local_jid,
                peer_jid);
            StanzaNode transport = ((!) parameters).to_transport_stanza_node("session-initiate");
            StanzaNode candidate_node = get_single_candidate_by_type(transport, "direct");
            fail_if(candidate_node.get_attribute("host") != "198.51.100.24",
                "S5B direct override must publish the configured public host");
            fail_if(candidate_node.get_attribute_int("port") != port,
                "S5B direct override must publish the configured public port");
            fail_if(candidate_node.get_attribute("jid") != local_jid.to_string(),
                "S5B direct override must keep the sender full JID");
            string? dstaddr = transport.get_attribute("dstaddr");
            fail_if(dstaddr == null || ((!) dstaddr) == "",
                "S5B direct override transport must publish the local dstaddr");

            connection = run_connect_to_socks5_endpoint("127.0.0.1", port, (!) dstaddr);
            drain_listener_accept_bookkeeping();

            ((!) parameters).dispose();
            fail_if(!wait_for_socket_eof_after_close((!) connection, 1000),
                "S5B direct override disposal must close accepted listener connections");
            parameters = null;
        } catch (Error e) {
            fail_if_reached(@"Unexpected S5B direct override error: $(e.message)");
        } finally {
            if (parameters != null) {
                ((!) parameters).dispose();
            }
            if (connection != null) {
                try {
                    ((!) connection).close();
                } catch (Error e) {
                }
            }
        }
    }

    private void test_direct_candidate_override_respects_no_direct_policy() {
        Xep.Jingle.TransportParameters? parameters = null;
        try {
            int port = reserve_free_loopback_port();
            var stream = create_s5b_test_stream(false);
            var module = new Xep.JingleSocks5Bytestreams.Module();
            module.set_network_policy(false, null);
            module.set_direct_candidate_override_for_tests("127.0.0.1", "198.51.100.24", port);

            parameters = module.create_transport_parameters(
                stream,
                1,
                new Jid("alice@example.test/dinox"),
                new Jid("bob@example.test/phone"));
            StanzaNode transport = ((!) parameters).to_transport_stanza_node("session-initiate");
            fail_if(count_candidates_by_type(transport, "direct") != 0,
                "S5B direct override must not bypass disabled direct-candidate policy");
            fail_if(count_candidates(transport) != 0,
                "S5B direct override with direct policy disabled and no proxy must publish no candidates");
        } catch (Error e) {
            fail_if_reached(@"Unexpected S5B direct override policy error: $(e.message)");
        } finally {
            if (parameters != null) {
                ((!) parameters).dispose();
            }
        }
    }

    // ===================== Helpers =====================

    /** Synchronously read a StanzaNode from XML string. */
    private StanzaNode? yield_stanza_node(StanzaReader reader) {
        StanzaNode? result = null;
        var loop = new MainLoop();
        read_node_async.begin(reader, (obj, res) => {
            try {
                result = read_node_async.end(res);
            } catch (Error e) {
                warning("yield_stanza_node error: %s", e.message);
            }
            loop.quit();
        });
        loop.run();
        return result;
    }

    private async StanzaNode read_node_async(StanzaReader reader) throws Error {
        return yield reader.read_node();
    }

    private Socks5TestXmppStream create_s5b_test_stream(bool with_proxy) throws Error {
        var stream = new Socks5TestXmppStream(new Jid("example.test"));
        var socks5_module = new Xep.Socks5Bytestreams.Module();
        socks5_module.set_local_ip_address_handler(() => {
            var addresses = new ArrayList<string>();
            addresses.add("127.0.0.1");
            return addresses;
        });
        stream.add_module(socks5_module);
        var flag = new Xep.Socks5Bytestreams.Flag();
        if (with_proxy) {
            flag.proxies.add(new Xep.Socks5Bytestreams.Proxy(
                "proxy.example.test",
                new Jid("proxy.example.test"),
                7777));
        }
        stream.add_flag(flag);
        return stream;
    }

    private int count_candidates(StanzaNode transport) {
        return transport.get_subnodes("candidate", NS_JINGLE_S5B).size;
    }

    private int count_candidates_by_type(StanzaNode transport, string type_) {
        int count = 0;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate", NS_JINGLE_S5B)) {
            if (candidate.get_attribute("type") == type_) {
                count++;
            }
        }
        return count;
    }

    private StanzaNode get_single_candidate_by_type(StanzaNode transport, string type_) {
        StanzaNode? result = null;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate", NS_JINGLE_S5B)) {
            if (candidate.get_attribute("type") == type_) {
                fail_if(result != null, @"expected exactly one S5B $type_ candidate");
                result = candidate;
            }
        }
        fail_if(result == null, @"expected one S5B $type_ candidate");
        return (!) result;
    }

    private bool run_transport_available(Xep.JingleSocks5Bytestreams.Module module, XmppStream stream, Jid peer) {
        bool result = false;
        var loop = new MainLoop();
        module.is_transport_available.begin(stream, 1, peer, (obj, res) => {
            result = module.is_transport_available.end(res);
            loop.quit();
        });
        loop.run();
        return result;
    }

    private Socks5TestXmppStream create_jingle_transport_selection_stream(bool with_proxy) throws Error {
        var stream = create_s5b_test_stream(with_proxy);
        var service_discovery = new Xep.ServiceDiscovery.Module.with_identity("client", "pc", "DinoX Test");
        service_discovery.cache = new FakeCapsCache();
        stream.add_module(service_discovery);
        return stream;
    }

    private Socks5TestXmppStream create_attached_jingle_transport_selection_stream(bool with_proxy, bool allow_local_candidates) throws Error {
        var stream = create_jingle_transport_selection_stream(with_proxy);

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var service_discovery = stream.get_module<Xep.ServiceDiscovery.Module>(Xep.ServiceDiscovery.Module.IDENTITY);
        ((!) service_discovery).attach(stream);

        var jingle = new Xep.Jingle.Module();
        stream.add_module(jingle);
        jingle.attach(stream);

        var s5b = new Xep.JingleSocks5Bytestreams.Module();
        s5b.set_network_policy(allow_local_candidates, allow_local_candidates ? null : "socks5://127.0.0.1:9050");
        stream.add_module(s5b);
        s5b.attach(stream);

        var ibb = new Xep.JingleInBandBytestreams.Module();
        stream.add_module(ibb);
        ibb.attach(stream);

        return stream;
    }

    private Xep.Jingle.Transport? run_select_transport(Xep.Jingle.Module module, XmppStream stream, Jid peer) {
        Xep.Jingle.Transport? result = null;
        var loop = new MainLoop();
        module.select_transport.begin(stream, Xep.Jingle.TransportType.STREAMING, 1, peer, Set.empty(), (obj, res) => {
            result = module.select_transport.end(res);
            loop.quit();
        });
        loop.run();
        return result;
    }

    private SocketConnection run_connect_to_socks5(Xep.JingleSocks5Bytestreams.Candidate candidate, string dstaddr) throws Error {
        return run_connect_to_socks5_endpoint(candidate.host, candidate.port, dstaddr);
    }

    private SocketConnection run_connect_to_socks5_endpoint(string host, int port, string dstaddr) throws Error {
        SocketConnection? result = null;
        Error? failure = null;
        Cancellable cancellable = new Cancellable();
        bool timed_out = false;
        var loop = new MainLoop();
        uint timeout_source = 0;
        timeout_source = Timeout.add(1000, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            return Source.REMOVE;
        });
        connect_to_socks5.begin(host, port, dstaddr, cancellable, (obj, res) => {
            try {
                result = connect_to_socks5.end(res);
            } catch (Error e) {
                failure = e;
            }
            if (timeout_source != 0) {
                Source.remove(timeout_source);
                timeout_source = 0;
            }
            loop.quit();
        });
        loop.run();
        if (timeout_source != 0) {
            Source.remove(timeout_source);
        }
        if (timed_out) {
            if (result != null) {
                try {
                    ((!) result).close();
                } catch (Error e) {
                }
            }
            throw new IOError.TIMED_OUT("Timed out completing S5B listener handshake");
        }
        if (failure != null) {
            throw (!) failure;
        }
        return (!) result;
    }

    private bool can_connect_to_socks5(Xep.JingleSocks5Bytestreams.Candidate candidate, string dstaddr) {
        SocketConnection? connection = null;
        try {
            connection = run_connect_to_socks5(candidate, dstaddr);
            return true;
        } catch (Error e) {
            return false;
        } finally {
            if (connection != null) {
                try {
                    ((!) connection).close();
                } catch (Error e) {
                }
            }
        }
    }

    private async SocketConnection connect_to_socks5(string host, int port, string dstaddr, Cancellable cancellable) throws Error {
        SocketClient socket_client = new SocketClient() { timeout=2 };
        socket_client.set_proxy_resolver(new SimpleProxyResolver("direct://", null));
        SocketConnection conn = yield socket_client.connect_to_host_async("[%s]:%d".printf(host, port), 0, cancellable);

        size_t written;
        size_t read;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield conn.output_stream.write_all_async({0x05, 0x01, 0x00}, GLib.Priority.DEFAULT, cancellable, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:2], GLib.Priority.DEFAULT, cancellable, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] != 0x00) {
            throw new IOError.PROXY_FAILED("S5B listener did not accept null authentication");
        }

        write_buffer.append({0x05, 0x01, 0x00, 0x03});
        write_buffer.append({(uint8)dstaddr.length});
        write_buffer.append(dstaddr.data);
        write_buffer.append({0x00, 0x00});
        yield conn.output_stream.write_all_async(write_buffer.data, GLib.Priority.DEFAULT, cancellable, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:write_buffer.len], GLib.Priority.DEFAULT, cancellable, out read);
        if (read != write_buffer.len || read_buffer[0] != 0x05 || read_buffer[1] != 0x00 || read_buffer[3] != 0x03) {
            throw new IOError.PROXY_FAILED("S5B listener did not complete the connect handshake");
        }
        if (read_buffer[4] != (uint8)dstaddr.length ||
                !Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[5:5+dstaddr.length], dstaddr.data) ||
                read_buffer[5+dstaddr.length] != 0x00 ||
                read_buffer[5+dstaddr.length+1] != 0x00) {
            throw new IOError.PROXY_FAILED("S5B listener returned an unexpected dstaddr success response");
        }

        return conn;
    }

    private void drain_listener_accept_bookkeeping() {
        const uint timeout_ms = 100;
        uint timeout_source = 0;
        var loop = new MainLoop();
        // LocalListener records accepted sockets from its async accept callback.
        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (timeout_source != 0) Source.remove(timeout_source);
    }

    private bool wait_for_socket_eof_after_close(SocketConnection connection, uint timeout_ms) {
        uint8[] buffer = new uint8[1];
        bool closed = false;
        uint timeout_source = 0;
        Cancellable cancellable = new Cancellable();
        bool completed = false;
        var loop = new MainLoop();

        connection.input_stream.read_async.begin(buffer, Priority.DEFAULT, cancellable, (obj, res) => {
            completed = true;
            try {
                ssize_t bytes_read = connection.input_stream.read_async.end(res);
                closed = bytes_read == 0;
            } catch (IOError.CANCELLED e) {
                closed = false;
            } catch (IOError.CLOSED e) {
                closed = true;
            } catch (Error e) {
                closed = false;
            }
            if (timeout_source != 0) {
                Source.remove(timeout_source);
                timeout_source = 0;
            }
            loop.quit();
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            cancellable.cancel();
            return Source.REMOVE;
        });

        loop.run();
        return completed && closed;
    }

    private static int reserve_free_loopback_port() throws Error {
        SocketListener listener = new SocketListener();
        SocketAddress effective_any;
        listener.add_address(
            new InetSocketAddress.from_string("127.0.0.1", 0),
            SocketType.STREAM,
            SocketProtocol.DEFAULT,
            null,
            out effective_any);
        int port = (int)((InetSocketAddress)effective_any).port;
        listener.close();
        return port;
    }
}

private class FakeCapsCache : Object, Xep.ServiceDiscovery.CapsCache {
    private HashMap<Jid, HashSet<string>> features = new HashMap<Jid, HashSet<string>>(Jid.hash_func, Jid.equals_func);

    public void add_feature(Jid jid, string feature) {
        if (!features.has_key(jid)) {
            features[jid] = new HashSet<string>();
        }
        features[jid].add(feature);
    }

    public async bool has_entity_feature(Jid jid, string feature) {
        return features.has_key(jid) && features[jid].contains(feature);
    }

    public async Gee.Set<Xep.ServiceDiscovery.Identity> get_entity_identities(Jid jid) {
        return new HashSet<Xep.ServiceDiscovery.Identity>(
            Xep.ServiceDiscovery.Identity.hash_func,
            Xep.ServiceDiscovery.Identity.equals_func);
    }
}

private class Socks5TestXmppStream : XmppStream {
    public Socks5TestXmppStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
    }

    public override async void setup() throws IOError {
    }
}

}
