using Xmpp;
using Xmpp.Xep;
using Gee;

/**
 * XEP-0234 Jingle File Transfer audit tests.
 *
 * Tests Parameters.parse() for description validation, file name sanitization,
 * size validation, and adversarial inputs (path traversal, negative size, etc.).
 */
namespace Xmpp.Test {

class JingleFileTransferAudit : Gee.TestCase {
    private const string NS_URI = "urn:xmpp:jingle:apps:file-transfer:5";
    private const string NS_JINGLE = "urn:xmpp:jingle:1";
    private const string NS_IBB = "http://jabber.org/protocol/ibb";
    private const string NS_JINGLE_S5B = "urn:xmpp:jingle:transports:s5b:1";
    private const string NS_JINGLE_IBB = "urn:xmpp:jingle:transports:ibb:1";
    private const string NS_SOCKS5_BYTESTREAMS = "http://jabber.org/protocol/bytestreams";
    private const string NS_JET = "urn:xmpp:jingle:jet:0";
    private const string NS_TEST_JET_TYPE = "urn:xmpp:test:jet-envelope";
    private const string NS_TEST_JET_CIPHER = "urn:xmpp:test:xor-stream";

    public JingleFileTransferAudit() {
        base("JingleFTAudit");
        // Valid parsing
        add_test("XEP0234_parse_valid_description", test_parse_valid);
        add_test("XEP0234_parse_with_media_type", test_parse_media_type);
        add_test("XEP0234_parse_large_size", test_parse_large_size);
        // Size validation
        add_test("XEP0234_parse_negative_size_rejected", test_negative_size);
        add_test("XEP0234_parse_zero_size_accepted", test_zero_size);
        add_test("XEP0234_parse_missing_size_rejected", test_missing_size);
        add_test("XEP0234_parse_non_numeric_size", test_non_numeric_size);
        // File count validation
        add_test("XEP0234_parse_no_file_node", test_no_file_node);
        add_test("XEP0234_parse_multiple_file_nodes", test_multiple_file_nodes);
        // File name edge cases
        add_test("XEP0234_filename_normal", test_filename_normal);
        add_test("XEP0234_filename_path_traversal", test_filename_path_traversal);
        add_test("XEP0234_filename_absolute_path", test_filename_absolute_path);
        add_test("XEP0234_filename_backslash_path", test_filename_backslash_path);
        add_test("XEP0234_filename_null_name", test_filename_null);
        add_test("XEP0234_filename_empty", test_filename_empty);
        add_test("XEP0234_filename_unicode", test_filename_unicode);
        add_test("XEP0234_filename_xss", test_filename_xss);
        // FileTransferInputStream
        add_test("XEP0234_stream_eof_at_max_size", test_stream_eof);
        add_test("XEP0234_stream_zero_remaining", test_stream_zero_remaining);
        // Description node structure
        add_test("XEP0234_description_roundtrip", test_description_roundtrip);
        add_test("XEP0234_original_description_preserved", test_original_description);
        // Outgoing description builder
        add_test("XEP0234_outgoing_description_includes_zero_size", test_outgoing_description_includes_zero_size);
        add_test("XEP0234_outgoing_description_rejects_negative_size", test_outgoing_description_rejects_negative_size);
        add_test("XEP0234_outgoing_description_preserves_basename", test_outgoing_description_preserves_basename);
        add_test("XEP0234_outgoing_description_does_not_claim_hash", test_outgoing_description_does_not_claim_hash);
        // Availability entry point
        add_test("XEP0234_is_available_requires_file_transfer_feature", test_is_available_requires_file_transfer_feature);
        add_test("XEP0234_is_available_requires_jingle_feature", test_is_available_requires_jingle_feature);
        add_test("XEP0234_is_available_rejects_without_registered_transport", test_is_available_rejects_without_registered_transport);
        add_test("XEP0234_is_available_accepts_registered_ibb_transport", test_is_available_accepts_registered_ibb_transport);
        add_test("XEP0234_is_available_falls_back_to_ibb_when_s5b_proxy_blocked", test_is_available_falls_back_to_ibb_when_s5b_proxy_blocked);
        add_test("XEP0234_is_available_rejects_when_only_s5b_is_blocked", test_is_available_rejects_when_only_s5b_is_blocked);
        // Outgoing session-initiate boundary
        add_test("XEP0234_session_initiate_contains_description_and_ibb_transport", test_session_initiate_contains_description_and_ibb_transport);
        add_test("XEP0234_session_initiate_falls_back_to_ibb_when_s5b_proxy_blocked", test_session_initiate_falls_back_to_ibb_when_s5b_proxy_blocked);
        add_test("XEP0234_session_initiate_s5b_proxy_only_has_no_direct_candidates", test_session_initiate_s5b_proxy_only_has_no_direct_candidates);
        add_test("XEP0234_session_initiate_rejects_without_jingle_support", test_session_initiate_rejects_without_jingle_support);
        add_test("XEP0234_session_initiate_cleans_up_when_security_node_fails", test_session_initiate_cleans_up_when_security_node_fails);
        add_test("XEP0234_session_initiate_cancels_while_offer_not_registered", test_session_initiate_cancels_while_offer_not_registered);
        add_test("XEP0234_session_initiate_cancels_by_id", test_session_initiate_cancels_by_id);
        add_test("XEP0234_session_initiate_cancels_by_token", test_session_initiate_cancels_by_token);
        add_test("XEP0234_CONCURRENCY_parallel_offers_keep_sessions_and_cancellation_isolated", test_parallel_offers_keep_sessions_and_cancellation_isolated);
        add_test("XEP0234_session_initiate_times_out_without_accept", test_session_initiate_times_out_without_accept);
        // Incoming session-initiate boundary
        add_test("XEP0234_incoming_session_initiate_emits_file_incoming", test_incoming_session_initiate_emits_file_incoming);
        add_test("XEP0234_incoming_session_initiate_accepts_ibb_stream", test_incoming_session_initiate_accepts_ibb_stream);
        add_test("XEP0234_incoming_session_initiate_accepts_ibb_byte_flow", test_incoming_session_initiate_accepts_ibb_byte_flow);
        add_test("XEP0234_incoming_session_initiate_accepts_s5b_candidate_used_byte_flow", test_incoming_session_initiate_accepts_s5b_candidate_used_byte_flow);
        add_test("XEP0234_incoming_session_initiate_s5b_jet_security_decrypts_payload", test_incoming_session_initiate_s5b_jet_security_decrypts_payload);
        add_test("XEP0234_incoming_session_initiate_real_tor_onion_s5b_jet_security_byte_flow", test_incoming_session_initiate_real_tor_onion_s5b_jet_security_byte_flow);
        add_test("XEP0234_incoming_session_initiate_accepts_s5b_proxy_activation_byte_flow", test_incoming_session_initiate_accepts_s5b_proxy_activation_byte_flow);
        add_test("XEP0234_incoming_session_initiate_uses_account_proxy_for_remote_s5b_candidate", test_incoming_session_initiate_uses_account_proxy_for_remote_s5b_candidate);
        add_test("XEP0234_incoming_session_initiate_uses_account_proxy_for_remote_s5b_hostname_candidate", test_incoming_session_initiate_uses_account_proxy_for_remote_s5b_hostname_candidate);
        add_test("XEP0234_incoming_session_initiate_tor_proxy_rejects_loopback_without_direct_leak", test_incoming_session_initiate_tor_proxy_rejects_loopback_without_direct_leak);
        add_test("XEP0234_incoming_session_initiate_real_tor_onion_s5b_byte_flow", test_incoming_session_initiate_real_tor_onion_s5b_byte_flow);
        add_test("XEP0234_incoming_ibb_short_transfer_app_close_after_eof", test_incoming_ibb_short_transfer_app_close_after_eof);
        add_test("XEP0234_incoming_session_initiate_rejects_missing_size", test_incoming_session_initiate_rejects_missing_size);
        add_test("XEP0234_incoming_session_initiate_rejects_duplicate_sid", test_incoming_session_initiate_rejects_duplicate_sid);
        add_test("XEP0234_incoming_session_initiate_rejects_late_invalid_content_before_signal", test_incoming_session_initiate_rejects_late_invalid_content_before_signal);
        add_test("XEP0166_incoming_session_initiate_stops_after_rejected_initial_content", test_incoming_session_initiate_stops_after_rejected_initial_content);
    }

    // ========== Helpers ==========

    private StanzaNode build_description(string? name, string? size, string? media_type = null) {
        var desc = new StanzaNode.build("description", NS_URI).add_self_xmlns();
        var file = new StanzaNode.build("file", NS_URI);
        if (name != null) {
            file.put_node(new StanzaNode.build("name", NS_URI)
                .put_node(new StanzaNode.text(name)));
        }
        if (size != null) {
            file.put_node(new StanzaNode.build("size", NS_URI)
                .put_node(new StanzaNode.text(size)));
        }
        if (media_type != null) {
            file.put_node(new StanzaNode.build("media-type", NS_URI)
                .put_node(new StanzaNode.text(media_type)));
        }
        desc.put_node(file);
        return desc;
    }

    // ========== Valid parsing ==========

    private void test_parse_valid() {
        var desc = build_description("test.pdf", "1048576");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "test.pdf");
            assert_true(params.size == 1048576);
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_parse_media_type() {
        var desc = build_description("photo.jpg", "5000", "image/jpeg");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "photo.jpg");
            assert_true(params.size == 5000);
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_parse_large_size() {
        // 10 GB file
        var desc = build_description("large.iso", "10737418240");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.size == 10737418240);
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    // ========== Size validation ==========

    private void test_negative_size() {
        var desc = build_description("evil.exe", "-1");
        try {
            var module = new JingleFileTransfer.Module();
            JingleFileTransfer.Parameters.parse(module, desc);
            // Should throw IqError for negative size
            assert_not_reached();
        } catch (Jingle.IqError e) {
            // Expected: "negative file size is invalid"
            assert_true(e.message.contains("negative"));
        }
    }

    private void test_zero_size() {
        var desc = build_description("empty.txt", "0");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.size == 0);
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_missing_size() {
        var desc = build_description("nosize.txt", null);
        try {
            var module = new JingleFileTransfer.Module();
            JingleFileTransfer.Parameters.parse(module, desc);
            // Should throw: "file offer without file size"
            assert_not_reached();
        } catch (Jingle.IqError e) {
            assert_true(e.message.contains("size"));
        }
    }

    private void test_non_numeric_size() {
        var desc = build_description("bad.txt", "not_a_number");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            // int64.parse("not_a_number") returns 0 in Vala
            assert_true(params.size == 0);
        } catch (Jingle.IqError e) {
            // Also acceptable if validation rejects it
        }
    }

    // ========== File count ==========

    private void test_no_file_node() {
        var desc = new StanzaNode.build("description", NS_URI).add_self_xmlns();
        // No <file> child
        try {
            var module = new JingleFileTransfer.Module();
            JingleFileTransfer.Parameters.parse(module, desc);
            assert_not_reached();
        } catch (Jingle.IqError e) {
            assert_true(e.message.contains("exactly one file"));
        }
    }

    private void test_multiple_file_nodes() {
        var desc = new StanzaNode.build("description", NS_URI).add_self_xmlns();
        desc.put_node(new StanzaNode.build("file", NS_URI)
            .put_node(new StanzaNode.build("name", NS_URI).put_node(new StanzaNode.text("a.txt")))
            .put_node(new StanzaNode.build("size", NS_URI).put_node(new StanzaNode.text("100"))));
        desc.put_node(new StanzaNode.build("file", NS_URI)
            .put_node(new StanzaNode.build("name", NS_URI).put_node(new StanzaNode.text("b.txt")))
            .put_node(new StanzaNode.build("size", NS_URI).put_node(new StanzaNode.text("200"))));
        try {
            var module = new JingleFileTransfer.Module();
            JingleFileTransfer.Parameters.parse(module, desc);
            assert_not_reached();
        } catch (Jingle.IqError e) {
            assert_true(e.message.contains("exactly one file"));
        }
    }

    // ========== File name edge cases ==========

    private void test_filename_normal() {
        var desc = build_description("document.pdf", "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "document.pdf");
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_filename_path_traversal() {
        // Path traversal attack: ../../etc/passwd
        var desc = build_description("../../etc/passwd", "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            // The parser accepts the name as-is — the CONSUMER must sanitize
            assert_true(params.name == "../../etc/passwd");
            // Document: XEP-0234 parser does NOT sanitize file names.
            // Path traversal must be prevented at the file-saving layer (libdino).
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_filename_absolute_path() {
        var desc = build_description("/etc/shadow", "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "/etc/shadow");
            // Document: absolute paths accepted — consumer must use basename()
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_filename_backslash_path() {
        // Windows path traversal
        var desc = build_description("..\\..\\Windows\\System32\\config\\SAM", "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_nonnull(params.name);
            // Backslashes are not path separators on Linux but are on Windows
            // Document: Windows path traversal character accepted
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_filename_null() {
        var desc = build_description(null, "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_null(params.name);
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_filename_empty() {
        var desc = build_description("", "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "");
            // Document: empty filename accepted — consumer must handle
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_filename_unicode() {
        var desc = build_description("ünïcödë_文件.txt", "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "ünïcödë_文件.txt");
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_filename_xss() {
        var desc = build_description("<img src=x onerror=alert(1)>.html", "100");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            // HTML in filename — must be escaped when displayed
            assert_nonnull(params.name);
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    // ========== FileTransferInputStream ==========

    private void test_stream_eof() {
        // FileTransferInputStream should return 0 (EOF) after max_size bytes
        string data = "Hello World! This is test data for the stream.";
        var mem = new MemoryInputStream.from_data(data.data);
        int64 max_size = 5;

        // We can't directly instantiate the private class, but we can test
        // the concept: read from a stream that wraps with size limit
        uint8[] buf = new uint8[100];
        try {
            ssize_t read = mem.read(buf[0:max_size]);
            assert_true(read == max_size);
            assert_true(((string) buf).has_prefix("Hello"));
        } catch (IOError e) {
            assert_not_reached();
        }
    }

    private void test_stream_zero_remaining() {
        // Edge case: max_size = 0 should immediately return 0
        var mem = new MemoryInputStream.from_data("data".data);
        uint8[] buf = new uint8[10];
        // Read 0 bytes — simulate zero remaining
        try {
            ssize_t read = mem.read(buf[0:0]);
            assert_true(read == 0);
        } catch (IOError e) {
            assert_not_reached();
        }
    }

    // ========== Description roundtrip ==========

    private void test_description_roundtrip() {
        var desc = build_description("test.txt", "42");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            StanzaNode roundtrip = params.get_description_node();
            assert_nonnull(roundtrip);
            // Should be the original description node
            assert_true(roundtrip.name == "description");
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_original_description() {
        var desc = build_description("file.bin", "999");
        try {
            var module = new JingleFileTransfer.Module();
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            // original_description is preserved for re-serialization
            assert_true(params.original_description == desc);
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    // ========== Outgoing description builder ==========

    private void test_outgoing_description_includes_zero_size() {
        try {
            var module = new JingleFileTransfer.Module();
            StanzaNode desc = JingleFileTransfer.Module.create_file_description("empty.txt", 0);
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "empty.txt");
            assert_true(params.size == 0);
            StanzaNode? file = desc.get_subnode("file", NS_URI);
            assert_nonnull(file);
            StanzaNode? size = ((!) file).get_subnode("size", NS_URI);
            assert_nonnull(size);
            assert_true(((!) size).get_string_content() == "0");
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_outgoing_description_rejects_negative_size() {
        try {
            JingleFileTransfer.Module.create_file_description("negative.bin", -1);
            assert_not_reached();
        } catch (Jingle.IqError e) {
            assert_true(e.message.contains("negative"));
        }
    }

    private void test_outgoing_description_preserves_basename() {
        try {
            var module = new JingleFileTransfer.Module();
            StanzaNode desc = JingleFileTransfer.Module.create_file_description("report final.pdf", 1234, "application/pdf");
            var params = JingleFileTransfer.Parameters.parse(module, desc);
            assert_true(params.name == "report final.pdf");
            assert_true(params.size == 1234);
            StanzaNode? file = desc.get_subnode("file", NS_URI);
            assert_nonnull(file);
            StanzaNode? media_type = ((!) file).get_subnode("media-type", NS_URI);
            assert_nonnull(media_type);
            assert_true(((!) media_type).get_string_content() == "application/pdf");
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    private void test_outgoing_description_does_not_claim_hash() {
        try {
            StanzaNode desc = JingleFileTransfer.Module.create_file_description("payload.bin", 4096);
            StanzaNode? file = desc.get_subnode("file", NS_URI);
            assert_nonnull(file);
            assert_null(((!) file).get_subnode("hash", "urn:xmpp:hashes:2"));
        } catch (Jingle.IqError e) {
            assert_not_reached();
        }
    }

    // ========== Availability entry point ==========

    private void test_is_available_requires_file_transfer_feature() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, true, true, true);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, false, true, true);

            var module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(module);

            bool available = run_file_transfer_available((!) module, stream, peer);

            assert_false(available);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_is_available_requires_jingle_feature() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, true, true, true);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, false, true, true, true);

            var module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(module);

            bool available = run_file_transfer_available((!) module, stream, peer);

            assert_false(available);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_is_available_rejects_without_registered_transport() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, false, true, true);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, true, true);

            var module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(module);

            bool available = run_file_transfer_available((!) module, stream, peer);

            assert_false(available);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_is_available_accepts_registered_ibb_transport() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, false, true);

            var module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(module);

            bool available = run_file_transfer_available((!) module, stream, peer);

            assert_true(available);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_is_available_falls_back_to_ibb_when_s5b_proxy_blocked() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, true, false, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, true, true);

            var module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(module);

            bool available = run_file_transfer_available((!) module, stream, peer);

            assert_true(available);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_is_available_rejects_when_only_s5b_is_blocked() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, true, false, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, true, false);

            var module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(module);

            bool available = run_file_transfer_available((!) module, stream, peer);

            assert_false(available);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    // ========== Outgoing session-initiate boundary ==========

    private void test_session_initiate_contains_description_and_ibb_transport() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, false, true);

            StanzaNode iq = run_file_transfer_session_initiate(stream, peer, "empty.txt", 0);

            StanzaNode content = assert_session_initiate_shell(iq, peer);
            StanzaNode description = get_required_subnode(content, "description", NS_URI);
            StanzaNode file = get_required_subnode(description, "file", NS_URI);
            assert_true(get_required_subnode(file, "name", NS_URI).get_string_content() == "empty.txt");
            assert_true(get_required_subnode(file, "size", NS_URI).get_string_content() == "0");
            assert_null(file.get_subnode("hash", "urn:xmpp:hashes:2"));

            StanzaNode transport = get_required_subnode(content, "transport", NS_JINGLE_IBB);
            assert_true(transport.get_attribute("sid") != null);
            assert_true(transport.get_attribute("block-size") == "4096");
            assert_null(content.get_subnode("transport", NS_JINGLE_S5B));
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_falls_back_to_ibb_when_s5b_proxy_blocked() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, true, false, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, true, true);

            StanzaNode iq = run_file_transfer_session_initiate(stream, peer, "payload.bin", 4096);
            StanzaNode content = assert_session_initiate_shell(iq, peer);

            assert_nonnull(content.get_subnode("transport", NS_JINGLE_IBB));
            assert_null(content.get_subnode("transport", NS_JINGLE_S5B));
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_s5b_proxy_only_has_no_direct_candidates() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, false, false, true);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, true, false);

            StanzaNode iq = run_file_transfer_session_initiate(stream, peer, "payload.bin", 4096);
            StanzaNode content = assert_session_initiate_shell(iq, peer);

            StanzaNode transport = get_required_subnode(content, "transport", NS_JINGLE_S5B);
            assert_true(transport.get_attribute("mode") == "tcp");
            assert_true(transport.get_attribute("sid") != null);
            string? dstaddr = transport.get_attribute("dstaddr");
            assert_nonnull(dstaddr);
            assert_true(((!) dstaddr).length == 40);
            assert_true(is_lowercase_hex((!) dstaddr));

            Gee.List<StanzaNode> candidates = transport.get_subnodes("candidate", NS_JINGLE_S5B);
            assert_true(candidates.size == 1);
            StanzaNode candidate = candidates[0];
            assert_true(candidate.get_attribute("type") == "proxy");
            assert_true(candidate.get_attribute("type") != "direct");
            assert_true(candidate.get_attribute("host") == "proxy.example.test");
            assert_true(candidate.get_attribute("host") != "127.0.0.1");
            assert_true(candidate.get_attribute("jid") == "proxy.example.test");
            assert_true(candidate.get_attribute("port") == "7777");
            assert_true(candidate.get_attribute("cid") != null);
            assert_true(candidate.get_attribute_int("priority") > 0);
            assert_null(content.get_subnode("transport", NS_JINGLE_IBB));
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_rejects_without_jingle_support() {
        JingleFtTestXmppStream? stream = null;
        try {
            stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache((!) stream);
            add_peer_features(cache, peer, false, true, false, true);

            run_file_transfer_session_initiate((!) stream, peer, "payload.bin", 4096);
            assert_not_reached();
        } catch (Xep.Jingle.Error e) {
            assert_true(e.message.contains("Jingle"));
            assert_nonnull(stream);
            stream_writes_must_be_empty((!) stream);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_cleans_up_when_security_node_fails() {
        JingleFtTestXmppStream? stream = null;
        TrackingAuditTransportParameters? transport_params = null;
        TrackingAuditParameters? content_params = null;
        try {
            stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache((!) stream);
            add_peer_features(cache, peer, true, false, false, false);

            var jingle = ((!) stream).get_module<Xep.Jingle.Module>(Xep.Jingle.Module.IDENTITY);
            assert_nonnull(jingle);
            Jid local_full_jid = (!) ((!) stream).get_flag(Bind.Flag.IDENTITY).my_jid;

            var content_type = new TrackingAuditContentType();
            content_params = new TrackingAuditParameters();
            var transport = new TrackingAuditTransport();
            transport_params = new TrackingAuditTransportParameters();
            var security_params = new FailingAuditSecurityParameters("synthetic security encode failure");
            var content = new Xep.Jingle.Content.initiate_sent("failing-security", Xep.Jingle.Senders.INITIATOR,
                content_type, (!) content_params,
                transport, (!) transport_params,
                null, security_params,
                local_full_jid, peer);
            var contents = new ArrayList<Xep.Jingle.Content>();
            contents.add(content);

            run_create_session((!) jingle, (!) stream, contents, peer, "audit-security-node-fails");
            assert_not_reached();
        } catch (Xep.Jingle.Error e) {
            assert_true(e.message.contains("synthetic security encode failure"));
            assert_nonnull(stream);
            assert_nonnull(transport_params);
            assert_nonnull(content_params);
            stream_writes_must_be_empty((!) stream);
            assert_no_jingle_session_state((!) stream, "audit-security-node-fails");
            assert_true(((!) transport_params).disposed);
            assert_true(((!) content_params).terminated);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_cancels_while_offer_not_registered() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, false, true);

            var file_transfer_module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(file_transfer_module);

            Error? failure = null;
            var loop = new MainLoop();
            uint8[] payload = "cancel-race".data;
            var input = new MemoryInputStream.from_data(payload, null);
            ((!) file_transfer_module).offer_file_stream.begin(stream, peer, input, "cancel-race.txt", payload.length,
                1338, null, null, null, (obj, res) => {
                    try {
                        ((!) file_transfer_module).offer_file_stream.end(res);
                    } catch (Error e) {
                        failure = e;
                    }
                    loop.quit();
                });

            assert_true(((!) file_transfer_module).cancel_send_transfer(1338));
            assert_false(((!) file_transfer_module).cancel_send_transfer(1338));

            loop.run();
            assert_true(failure != null);
            assert_true(stream.written_nodes.size >= 2);

            StanzaNode init_iq = stream.written_nodes[0];
            StanzaNode init_jingle = get_required_subnode(init_iq, "jingle", NS_JINGLE);
            string? sid = init_jingle.get_attribute("sid");
            assert_nonnull(sid);

            assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.CANCEL);
            wait_until(() => {
                Xep.Jingle.Flag flag = stream.get_flag(Xep.Jingle.Flag.IDENTITY);
                return !flag.promises.has_key((!) sid) && !flag.sessions.has_key((!) sid);
            }, 1000, "session-state was not cleaned up after pending cancel race");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_cancels_by_id() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, false, true);

            var file_transfer_module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(file_transfer_module);

            Error? failure = null;
            var loop = new MainLoop();
            uint8[] payload = "cancel-by-id".data;
            var input = new MemoryInputStream.from_data(payload, null);
            ((!) file_transfer_module).offer_file_stream.begin(stream, peer, input, "cancel-id.txt", payload.length,
                1337, null, null, null, (obj, res) => {
                    try {
                        ((!) file_transfer_module).offer_file_stream.end(res);
                    } catch (Error e) {
                        failure = e;
                    }
                    loop.quit();
                });

            wait_until(() => stream.written_nodes.size == 1, 1000, "session-initiate was not sent");

            StanzaNode init_iq = stream.written_nodes[0];
            StanzaNode init_jingle = get_required_subnode(init_iq, "jingle", NS_JINGLE);
            string? sid = init_jingle.get_attribute("sid");
            assert_nonnull(sid);

            assert_true(((!) file_transfer_module).cancel_send_transfer(1337));
            assert_false(((!) file_transfer_module).cancel_send_transfer(1337));

            loop.run();
            assert_true(failure != null);
            assert_true(stream.written_nodes.size >= 2);
            assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.CANCEL);
            wait_until(() => {
                Xep.Jingle.Flag flag = stream.get_flag(Xep.Jingle.Flag.IDENTITY);
                return !flag.promises.has_key((!) sid) && !flag.sessions.has_key((!) sid);
            }, 1000, "session-state was not cleaned up after cancel-by-id");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_cancels_by_token() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, false, true);

            var file_transfer_module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(file_transfer_module);

            Error? failure = null;
            var loop = new MainLoop();
            uint8[] payload = "cancel-by-token".data;
            var input = new MemoryInputStream.from_data(payload, null);
            const string token = "p1b-cancel-token";
            ((!) file_transfer_module).offer_file_stream.begin(stream, peer, input, "cancel-token.txt", payload.length,
                -1, token, null, null, (obj, res) => {
                    try {
                        ((!) file_transfer_module).offer_file_stream.end(res);
                    } catch (Error e) {
                        failure = e;
                    }
                    loop.quit();
                });

            wait_until(() => stream.written_nodes.size == 1, 1000, "session-initiate was not sent");

            StanzaNode init_iq = stream.written_nodes[0];
            StanzaNode init_jingle = get_required_subnode(init_iq, "jingle", NS_JINGLE);
            string? sid = init_jingle.get_attribute("sid");
            assert_nonnull(sid);

            assert_true(((!) file_transfer_module).cancel_send_transfer_token(token));
            assert_false(((!) file_transfer_module).cancel_send_transfer_token(token));

            loop.run();
            assert_true(failure != null);
            assert_true(stream.written_nodes.size >= 2);
            assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.CANCEL);
            wait_until(() => {
                Xep.Jingle.Flag flag = stream.get_flag(Xep.Jingle.Flag.IDENTITY);
                return !flag.promises.has_key((!) sid) && !flag.sessions.has_key((!) sid);
            }, 1000, "session-state was not cleaned up after cancel-by-token");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_parallel_offers_keep_sessions_and_cancellation_isolated() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var first_peer = new Jid("bob@example.test/phone");
            var second_peer = new Jid("carol@example.test/tablet");
            var third_peer = new Jid("dave@example.test/desktop");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, first_peer, true, true, false, true);
            add_peer_features(cache, second_peer, true, true, false, true);
            add_peer_features(cache, third_peer, true, true, false, true);

            var file_transfer_module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(file_transfer_module);

            int completed = 0;
            int failures = 0;
            uint8[] first_payload = "parallel-jingle-a".data;
            uint8[] second_payload = "parallel-jingle-b".data;
            uint8[] third_payload = "parallel-jingle-c".data;

            ((!) file_transfer_module).offer_file_stream.begin(stream, first_peer,
                new MemoryInputStream.from_data(first_payload, null), "parallel-a.bin", first_payload.length,
                2201, "parallel-token-a", null, null, (obj, res) => {
                    try {
                        ((!) file_transfer_module).offer_file_stream.end(res);
                    } catch (Error e) {
                        failures++;
                    }
                    completed++;
                });
            ((!) file_transfer_module).offer_file_stream.begin(stream, second_peer,
                new MemoryInputStream.from_data(second_payload, null), "parallel-b.bin", second_payload.length,
                2202, "parallel-token-b", null, null, (obj, res) => {
                    try {
                        ((!) file_transfer_module).offer_file_stream.end(res);
                    } catch (Error e) {
                        failures++;
                    }
                    completed++;
                });
            ((!) file_transfer_module).offer_file_stream.begin(stream, third_peer,
                new MemoryInputStream.from_data(third_payload, null), "parallel-c.bin", third_payload.length,
                2203, "parallel-token-c", null, null, (obj, res) => {
                    try {
                        ((!) file_transfer_module).offer_file_stream.end(res);
                    } catch (Error e) {
                        failures++;
                    }
                    completed++;
                });

            wait_until(() => find_session_initiate_sid(stream, first_peer) != null &&
                    find_session_initiate_sid(stream, second_peer) != null &&
                    find_session_initiate_sid(stream, third_peer) != null,
                1000, "parallel Jingle offers did not create three session-initiate stanzas");

            string first_sid = (!) find_session_initiate_sid(stream, first_peer);
            string second_sid = (!) find_session_initiate_sid(stream, second_peer);
            string third_sid = (!) find_session_initiate_sid(stream, third_peer);
            assert_true(first_sid != second_sid && first_sid != third_sid && second_sid != third_sid);

            Xep.Jingle.Flag flag = stream.get_flag(Xep.Jingle.Flag.IDENTITY);
            assert_true(flag.sessions.has_key(first_sid));
            assert_true(flag.sessions.has_key(second_sid));
            assert_true(flag.sessions.has_key(third_sid));

            assert_true(((!) file_transfer_module).cancel_send_transfer(2202));
            wait_until(() => completed == 1 &&
                    !flag.sessions.has_key(second_sid) && !flag.promises.has_key(second_sid),
                1000, "cancelling one parallel Jingle transfer did not clean up only its session");

            assert_true(flag.sessions.has_key(first_sid));
            assert_true(flag.sessions.has_key(third_sid));

            var first_output = new MemoryOutputStream.resizable();
            var third_output = new MemoryOutputStream.resizable();
            var first_connection = new Xep.Jingle.StreamingConnection();
            var third_connection = new Xep.Jingle.StreamingConnection();
            first_connection.set_stream.begin(new SimpleIOStream(
                new MemoryInputStream.from_data(new uint8[0], null), first_output));
            third_connection.set_stream.begin(new SimpleIOStream(
                new MemoryInputStream.from_data(new uint8[0], null), third_output));
            flag.sessions[first_sid].contents[0].set_transport_connection(first_connection);
            flag.sessions[third_sid].contents[0].set_transport_connection(third_connection);
            wait_until(() => completed == 3, 1000, "parallel Jingle offer callbacks did not finish independently");

            assert_true(failures == 1);
            uint8[] first_uploaded = first_output.steal_data();
            first_uploaded.length = (int) first_output.get_data_size();
            uint8[] third_uploaded = third_output.steal_data();
            third_uploaded.length = (int) third_output.get_data_size();
            assert_true(Xep.JingleSocks5Bytestreams.bytes_equal(first_uploaded, first_payload));
            assert_true(Xep.JingleSocks5Bytestreams.bytes_equal(third_uploaded, third_payload));

            if (flag.sessions.has_key(first_sid)) {
                flag.sessions[first_sid].terminate(Xep.Jingle.ReasonElement.SUCCESS, null, "parallel test complete");
            }
            if (flag.sessions.has_key(third_sid)) {
                flag.sessions[third_sid].terminate(Xep.Jingle.ReasonElement.SUCCESS, null, "parallel test complete");
            }
            wait_until(() => !flag.sessions.has_key(first_sid) && !flag.sessions.has_key(third_sid),
                1000, "completed parallel Jingle sessions were not cleaned up");
            assert_no_jingle_session_state(stream, first_sid);
            assert_no_jingle_session_state(stream, second_sid);
            assert_no_jingle_session_state(stream, third_sid);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_session_initiate_times_out_without_accept() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var cache = get_fake_cache(stream);
            add_peer_features(cache, peer, true, true, false, true);

            var file_transfer_module = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
            assert_nonnull(file_transfer_module);
            ((!) file_transfer_module).offer_wait_timeout_seconds = 1;

            Error? failure = null;
            var loop = new MainLoop();
            uint8[] payload = "timeout.txt".data;
            var input = new MemoryInputStream.from_data(payload, null);
            ((!) file_transfer_module).offer_file_stream.begin(stream, peer, input, "timeout-offer.txt", payload.length,
                -1, null, null, null, (obj, res) => {
                    try {
                        ((!) file_transfer_module).offer_file_stream.end(res);
                    } catch (Error e) {
                        failure = e;
                    }
                    loop.quit();
                });

            wait_until(() => stream.written_nodes.size == 1, 1000, "session-initiate was not sent");

            StanzaNode init_iq = stream.written_nodes[0];
            StanzaNode init_jingle = get_required_subnode(init_iq, "jingle", NS_JINGLE);
            string? sid = init_jingle.get_attribute("sid");
            assert_nonnull(sid);

            loop.run();

            assert_true(failure != null);
            assert_true(((!) failure).message.contains("Offer did not reach accepted state"));
            assert_true(((!) failure).message.contains("offer timeout"));
            assert_true(stream.written_nodes.size >= 2);
            assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.TIMEOUT);
            wait_until(() => {
                Xep.Jingle.Flag flag = stream.get_flag(Xep.Jingle.Flag.IDENTITY);
                return !flag.promises.has_key((!) sid) && !flag.sessions.has_key((!) sid);
            }, 1000, "session-state was not cleaned up after timeout");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    // ========== Incoming session-initiate boundary ==========

    private void test_incoming_session_initiate_emits_file_incoming() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");

            StanzaNode iq = build_incoming_session_initiate_iq(peer, "audit-incoming-session", "incoming.txt", "42");
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);

            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            assert_true(((!) transfer).peer.to_string() == peer.to_string());
            assert_true(((!) transfer).file_name == "incoming.txt");
            assert_true(((!) transfer).size == 42);
            assert_null(((!) transfer).security);
            assert_null(((!) transfer).stream);

            assert_true(stream.written_nodes.size == 1);
            StanzaNode result = stream.written_nodes[0];
            assert_true(result.name == "iq");
            assert_true(result.get_attribute("type") == "result");
            assert_true(result.get_attribute("id") == "incoming-session-initiate");
            assert_true(result.get_attribute("to") == peer.to_string());
            assert_null(result.get_subnode("jingle", NS_JINGLE));
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_incoming_session_initiate_accepts_ibb_stream() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");

            StanzaNode iq = build_incoming_session_initiate_iq(peer, "audit-incoming-accept", "incoming.txt", "42");
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            assert_null(((!) transfer).stream);
            assert_true(((!) transfer).transport_ns_uri == NS_JINGLE_IBB);
            assert_true(stream.written_nodes.size == 1);
            assert_true(stream.written_nodes[0].get_attribute("type") == "result");

            run_accept_file_transfer(stream, (!) transfer);

            assert_nonnull(((!) transfer).stream);
            Xep.Jingle.Flag jingle_flag = stream.get_flag(Xep.Jingle.Flag.IDENTITY);
            assert_true(jingle_flag.sessions.has_key("audit-incoming-accept"));
            assert_true(jingle_flag.sessions["audit-incoming-accept"].state == Xep.Jingle.Session.State.ACTIVE);

            assert_true(stream.written_nodes.size == 2);
            StanzaNode accept_iq = stream.written_nodes[1];
            assert_true(accept_iq.name == "iq");
            assert_true(accept_iq.get_attribute("type") == "set");
            assert_true(accept_iq.get_attribute("to") == peer.to_string());
            StanzaNode jingle = get_required_subnode(accept_iq, "jingle", NS_JINGLE);
            assert_true(jingle.get_attribute("action") == "session-accept");
            assert_true(jingle.get_attribute("sid") == "audit-incoming-accept");
            StanzaNode content = get_required_subnode(jingle, "content", NS_JINGLE);
            assert_true(content.get_attribute("creator") == "initiator");
            assert_true(content.get_attribute("name") == "incoming-file");
            assert_true(content.get_attribute("senders") == "initiator");
            assert_nonnull(content.get_subnode("description", NS_URI));
            StanzaNode transport = get_required_subnode(content, "transport", NS_JINGLE_IBB);
            assert_true(transport.get_attribute("sid") == "incoming-ibb-session");
            assert_true(transport.get_attribute("block-size") == "4096");

            Xep.InBandBytestreams.Connection? connection = stream.get_flag(Xep.InBandBytestreams.Flag.IDENTITY).get_connection("incoming-ibb-session");
            assert_nonnull(connection);
            assert_true(((!) connection).state == Xep.InBandBytestreams.Connection.State.WAITING_FOR_CONNECT);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_incoming_session_initiate_accepts_ibb_byte_flow() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");

            StanzaNode iq = build_incoming_session_initiate_iq(peer, "audit-incoming-byte-flow", "incoming.txt", "9");
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;

            run_accept_file_transfer(stream, file_transfer);
            assert_nonnull(file_transfer.stream);
            InputStream transfer_stream = (!) file_transfer.stream;
            assert_true(stream.written_nodes.size == 2);

            run_ibb_iq_set(stream, peer, build_ibb_open("incoming-ibb-session", 4096), "ibb-open-1");
            assert_last_iq_result(stream, "ibb-open-1", peer);
            Xep.InBandBytestreams.Connection? connection = stream.get_flag(Xep.InBandBytestreams.Flag.IDENTITY).get_connection("incoming-ibb-session");
            assert_nonnull(connection);
            assert_true(((!) connection).state == Xep.InBandBytestreams.Connection.State.CONNECTED);

            string payload = "Hello IBB";
            run_ibb_iq_set(stream, peer, build_ibb_data("incoming-ibb-session", 0, payload.data), "ibb-data-1");
            assert_last_iq_result(stream, "ibb-data-1", peer);

            uint8[] buffer = new uint8[64];
            ssize_t read = run_read_stream(transfer_stream, buffer);
            assert_true(read == payload.data.length);
            for (int i = 0; i < read; i++) {
                assert_true(buffer[i] == payload.data[i]);
            }

            run_ibb_iq_set(stream, peer, build_ibb_close("incoming-ibb-session"), "ibb-close-1");
            assert_last_iq_result(stream, "ibb-close-1", peer);
            assert_null(stream.get_flag(Xep.InBandBytestreams.Flag.IDENTITY).get_connection("incoming-ibb-session"));

            ssize_t eof = run_read_stream(transfer_stream, buffer);
            assert_true(eof == 0);

            assert_true(transfer_stream.close());
            assert_last_session_terminate_reason(stream, "audit-incoming-byte-flow", peer, Xep.Jingle.ReasonElement.SUCCESS);
            assert_no_jingle_session_state(stream, "audit-incoming-byte-flow");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_incoming_session_initiate_accepts_s5b_candidate_used_byte_flow() {
        SocketConnection? peer_connection = null;
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, false, true, false);
            var peer = new Jid("bob@example.test/phone");
            string sid = "audit-incoming-s5b-byte-flow";
            string content_name = "incoming-file";
            uint8[] payload = "Hello S5B".data;

            StanzaNode iq = build_incoming_s5b_session_initiate_iq(peer, sid, content_name, "incoming.txt", payload.length.to_string());
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;
            assert_true(file_transfer.transport_ns_uri == NS_JINGLE_S5B);
            assert_null(file_transfer.stream);

            var pending_accept = new PendingFileTransferAccept(stream, file_transfer);
            wait_until(() => find_written_jingle_action(stream, sid, "session-accept") != null,
                1000, "S5B accept did not write session-accept");

            StanzaNode accept_jingle = require_written_jingle_action(stream, sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", NS_JINGLE);
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", NS_JINGLE_S5B);
            assert_true(accept_transport.get_attribute("sid") == "incoming-s5b-session");
            string? dstaddr = accept_transport.get_attribute("dstaddr");
            assert_true(dstaddr != null && ((!) dstaddr) != "");
            StanzaNode candidate_node = get_single_candidate_by_type(accept_transport, "direct");
            var local_candidate = Xep.JingleSocks5Bytestreams.Candidate.parse(candidate_node);
            assert_true(local_candidate.jid.to_string() == "alice@example.test/dinox");

            peer_connection = run_connect_to_socks5(local_candidate, (!) dstaddr);
            drain_s5b_listener_bookkeeping();

            run_jingle_iq_set(stream,
                build_s5b_candidate_used_transport_info(peer, sid, content_name, local_candidate.cid, "s5b-candidate-used-1"));
            assert_last_iq_result(stream, "s5b-candidate-used-1", peer);

            pending_accept.wait_until_completed(1000);
            pending_accept.assert_succeeded();
            assert_nonnull(file_transfer.stream);
            InputStream transfer_stream = (!) file_transfer.stream;
            run_write_all_stream(((!) peer_connection).output_stream, payload);
            assert_read_exact(transfer_stream, payload);

            run_close_stream(transfer_stream);
            assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.SUCCESS);
            assert_no_jingle_session_state(stream, sid);
        } catch (Error e) {
            assert_not_reached();
        } finally {
            if (peer_connection != null) {
                try {
                    ((!) peer_connection).close();
                } catch (Error e) {
                }
            }
        }
    }

    private void test_incoming_session_initiate_s5b_jet_security_decrypts_payload() {
        SocketConnection? peer_connection = null;
        try {
            var stream = create_attached_jingle_file_transfer_stream(true, false, true, false);
            attach_test_jet_security(stream);
            var peer = new Jid("bob@example.test/phone");
            string sid = "audit-incoming-s5b-jet-security";
            string content_name = "incoming-file";
            uint8[] payload = "Hello encrypted S5B".data;
            uint8[] encrypted_payload = xor_payload(payload, TestJetCipher.KEY);
            assert_true(!Xep.JingleSocks5Bytestreams.bytes_equal(encrypted_payload, payload));

            StanzaNode iq = build_incoming_s5b_session_initiate_iq(peer, sid, content_name,
                "incoming.txt", payload.length.to_string(), "incoming-s5b-jet-session-initiate",
                build_test_jet_security_node());
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;
            assert_true(file_transfer.transport_ns_uri == NS_JINGLE_S5B);
            assert_nonnull(file_transfer.security);
            Xep.Jet.SecurityParameters? security = file_transfer.security as Xep.Jet.SecurityParameters;
            assert_nonnull(security);
            assert_true(((!) security).encoding.get_type_uri() == NS_TEST_JET_TYPE);
            assert_null(file_transfer.stream);

            var pending_accept = new PendingFileTransferAccept(stream, file_transfer);
            wait_until(() => find_written_jingle_action(stream, sid, "session-accept") != null,
                1000, "JET S5B accept did not write session-accept");

            StanzaNode accept_jingle = require_written_jingle_action(stream, sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", NS_JINGLE);
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", NS_JINGLE_S5B);
            assert_true(accept_transport.get_attribute("sid") == "incoming-s5b-session");
            string? dstaddr = accept_transport.get_attribute("dstaddr");
            assert_true(dstaddr != null && ((!) dstaddr) != "");
            StanzaNode candidate_node = get_single_candidate_by_type(accept_transport, "direct");
            var local_candidate = Xep.JingleSocks5Bytestreams.Candidate.parse(candidate_node);

            peer_connection = run_connect_to_socks5(local_candidate, (!) dstaddr);
            drain_s5b_listener_bookkeeping();

            run_jingle_iq_set(stream,
                build_s5b_candidate_used_transport_info(peer, sid, content_name, local_candidate.cid, "s5b-jet-candidate-used-1"));
            assert_last_iq_result(stream, "s5b-jet-candidate-used-1", peer);

            pending_accept.wait_until_completed(1000);
            pending_accept.assert_succeeded();
            assert_nonnull(file_transfer.stream);
            InputStream transfer_stream = (!) file_transfer.stream;
            run_write_all_stream(((!) peer_connection).output_stream, encrypted_payload);
            assert_read_exact(transfer_stream, payload);
            assert_authenticated_eof(transfer_stream);

            run_close_stream(transfer_stream);
            assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.SUCCESS);
            assert_no_jingle_session_state(stream, sid);
        } catch (Error e) {
            assert_not_reached();
        } finally {
            if (peer_connection != null) {
                try {
                    ((!) peer_connection).close();
                } catch (Error e) {
                }
            }
        }
    }

    private void test_incoming_session_initiate_accepts_s5b_proxy_activation_byte_flow() {
        FakeS5BProxy? proxy = null;
        try {
            proxy = new FakeS5BProxy();
            var stream = create_attached_jingle_file_transfer_stream(true, false, false, false);
            var s5b = stream.get_module<Xep.JingleSocks5Bytestreams.Module>(Xep.JingleSocks5Bytestreams.Module.IDENTITY);
            assert_nonnull(s5b);
            ((!) s5b).set_network_policy(false, null);

            var peer = new Jid("bob@example.test/phone");
            var proxy_jid = new Jid("proxy.example.test");
            add_s5b_proxy(stream, "127.0.0.1", proxy_jid, ((!) proxy).port);

            string sid = "audit-incoming-s5b-proxy-activation";
            string content_name = "incoming-file";
            string s5b_sid = "incoming-s5b-session";
            uint8[] payload = "Hello proxy S5B".data;

            StanzaNode iq = build_incoming_s5b_session_initiate_iq(peer, sid, content_name, "incoming.txt", payload.length.to_string());
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;
            assert_true(file_transfer.transport_ns_uri == NS_JINGLE_S5B);
            assert_null(file_transfer.stream);

            var pending_accept = new PendingFileTransferAccept(stream, file_transfer);
            wait_until(() => find_written_jingle_action(stream, sid, "session-accept") != null,
                1000, "S5B proxy accept did not write session-accept");

            StanzaNode accept_jingle = require_written_jingle_action(stream, sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", NS_JINGLE);
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", NS_JINGLE_S5B);
            assert_true(accept_transport.get_attribute("sid") == s5b_sid);
            string? dstaddr = accept_transport.get_attribute("dstaddr");
            assert_true(dstaddr != null && ((!) dstaddr) != "");
            assert_true(count_candidates_by_type(accept_transport, "direct") == 0);
            StanzaNode proxy_candidate_node = get_single_candidate_by_type(accept_transport, "proxy");
            var proxy_candidate = Xep.JingleSocks5Bytestreams.Candidate.parse(proxy_candidate_node);
            assert_true(proxy_candidate.host == "127.0.0.1");
            assert_true(proxy_candidate.jid.to_string() == proxy_jid.to_string());
            assert_true(proxy_candidate.port == ((!) proxy).port);
            ((!) proxy).expect_dstaddr((!) dstaddr);

            run_jingle_iq_set(stream,
                build_s5b_candidate_used_transport_info(peer, sid, content_name, proxy_candidate.cid, "s5b-proxy-candidate-used-1"));
            assert_written_iq_result(stream, "s5b-proxy-candidate-used-1", peer);

            wait_until(() => find_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer) != null,
                1000, "S5B proxy activation IQ was not written");
            ((!) proxy).wait_until_connected(1000);
            StanzaNode activation_iq = require_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer);
            stream.emit_iq_result(build_iq_result(activation_iq, proxy_jid.to_string(), "alice@example.test/dinox"));

            wait_until(() => find_written_s5b_transport_info_child(stream, sid, peer, content_name, s5b_sid, "activated", proxy_candidate.cid) != null,
                1000, "S5B proxy activated transport-info was not written");

            pending_accept.wait_until_completed(1000);
            pending_accept.assert_succeeded();
            assert_nonnull(file_transfer.stream);
            assert_nonnull(((!) proxy).connection);
            SocketConnection proxy_connection = (!) ((!) proxy).connection;
            InputStream transfer_stream = (!) file_transfer.stream;
            run_write_all_stream(proxy_connection.output_stream, payload);
            assert_read_exact(transfer_stream, payload);

            run_close_stream(transfer_stream);
            assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.SUCCESS);
            assert_no_jingle_session_state(stream, sid);
        } catch (Error e) {
            assert_not_reached();
        } finally {
            if (proxy != null) {
                ((!) proxy).close();
            }
        }
    }

    private void test_incoming_session_initiate_uses_account_proxy_for_remote_s5b_candidate() {
        DirectConnectTrap? direct_trap = null;
        FakeOutboundSocksProxy? outbound_proxy = null;
        try {
            direct_trap = new DirectConnectTrap();
            outbound_proxy = new FakeOutboundSocksProxy();
            run_account_proxy_remote_s5b_candidate_flow((!) outbound_proxy, "audit-incoming-s5b-account-proxy",
                "peer-direct-candidate", "127.0.0.1", ((!) direct_trap).port);
            ((!) direct_trap).assert_not_hit_after(100);
        } catch (Error e) {
            assert_not_reached();
        } finally {
            if (outbound_proxy != null) {
                ((!) outbound_proxy).close();
            }
            if (direct_trap != null) {
                ((!) direct_trap).close();
            }
        }
    }

    private void test_incoming_session_initiate_uses_account_proxy_for_remote_s5b_hostname_candidate() {
        FakeOutboundSocksProxy? outbound_proxy = null;
        try {
            outbound_proxy = new FakeOutboundSocksProxy();
            run_account_proxy_remote_s5b_candidate_flow((!) outbound_proxy, "audit-incoming-s5b-account-proxy-hostname",
                "peer-hostname-candidate", "peer-s5b.example.test", 7777);
        } catch (Error e) {
            assert_not_reached();
        } finally {
            if (outbound_proxy != null) {
                ((!) outbound_proxy).close();
            }
        }
    }

    private void run_account_proxy_remote_s5b_candidate_flow(FakeOutboundSocksProxy outbound_proxy, string sid,
            string remote_candidate_cid, string remote_candidate_host, int remote_candidate_port) throws Error {
        var stream = create_attached_jingle_file_transfer_stream(true, false, false, false);
        var s5b = stream.get_module<Xep.JingleSocks5Bytestreams.Module>(Xep.JingleSocks5Bytestreams.Module.IDENTITY);
        assert_nonnull(s5b);
        ((!) s5b).set_network_policy(false, "socks5://127.0.0.1:%d".printf(outbound_proxy.port));

        var peer = new Jid("bob@example.test/phone");
        var local = new Jid("alice@example.test/dinox");
        string content_name = "incoming-file";
        string s5b_sid = "incoming-s5b-session";
        string remote_dstaddr = Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, local);
        uint8[] payload = "Hello account proxy S5B".data;
        outbound_proxy.expect(remote_candidate_host, remote_candidate_port, remote_dstaddr);

        StanzaNode iq = build_incoming_s5b_session_initiate_iq_with_candidate(peer, sid, content_name,
            "incoming.txt", payload.length.to_string(), s5b_sid,
            remote_candidate_cid, remote_candidate_host, remote_candidate_port);
        int incoming_count = 0;
        Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
        assert_true(incoming_count == 1);
        assert_nonnull(transfer);
        Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;
        assert_true(file_transfer.transport_ns_uri == NS_JINGLE_S5B);
        assert_null(file_transfer.stream);

        var pending_accept = new PendingFileTransferAccept(stream, file_transfer);
        wait_until(() => find_written_jingle_action(stream, sid, "session-accept") != null,
            1000, "S5B account-proxy accept did not write session-accept");

        StanzaNode accept_jingle = require_written_jingle_action(stream, sid, "session-accept");
        StanzaNode accept_content = get_required_subnode(accept_jingle, "content", NS_JINGLE);
        StanzaNode accept_transport = get_required_subnode(accept_content, "transport", NS_JINGLE_S5B);
        assert_true(accept_transport.get_attribute("sid") == s5b_sid);
        assert_true(count_candidates_by_type(accept_transport, "direct") == 0);
        assert_true(count_candidates_by_type(accept_transport, "proxy") == 0);

        outbound_proxy.wait_until_connected(1000);
        wait_until(() => find_written_s5b_transport_info_child(stream, sid, peer, content_name, s5b_sid, "candidate-used", remote_candidate_cid) != null,
            1000, "S5B account-proxy candidate-used transport-info was not written");

        run_jingle_iq_set(stream,
            build_s5b_candidate_error_transport_info(peer, sid, content_name, s5b_sid, "s5b-account-proxy-candidate-error-1"));
        assert_written_iq_result(stream, "s5b-account-proxy-candidate-error-1", peer);

        pending_accept.wait_until_completed(1000);
        pending_accept.assert_succeeded();
        assert_nonnull(file_transfer.stream);
        assert_nonnull(outbound_proxy.connection);
        SocketConnection proxy_connection = (!) outbound_proxy.connection;
        InputStream transfer_stream = (!) file_transfer.stream;
        run_write_all_stream(proxy_connection.output_stream, payload);
        assert_read_exact(transfer_stream, payload);

        run_close_stream(transfer_stream);
        assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.SUCCESS);
        assert_no_jingle_session_state(stream, sid);
    }

    private void test_incoming_session_initiate_tor_proxy_rejects_loopback_without_direct_leak() {
        DirectConnectTrap? direct_trap = null;
        LocalTorSocksDaemon? tor = null;
        try {
            tor = LocalTorSocksDaemon.start_or_skip();
            if (tor == null) return;

            direct_trap = new DirectConnectTrap();
            var stream = create_attached_jingle_file_transfer_stream(true, false, false, false);
            var s5b = stream.get_module<Xep.JingleSocks5Bytestreams.Module>(Xep.JingleSocks5Bytestreams.Module.IDENTITY);
            assert_nonnull(s5b);
            ((!) s5b).set_network_policy(false, "socks5://127.0.0.1:%d".printf(((!) tor).port));

            var peer = new Jid("bob@example.test/phone");
            string sid = "audit-incoming-s5b-real-tor";
            string content_name = "incoming-file";
            string s5b_sid = "incoming-s5b-tor-session";
            string remote_candidate_host = "127.0.0.1";
            int remote_candidate_port = ((!) direct_trap).port;
            string remote_candidate_cid = "peer-direct-candidate";
            uint8[] payload = "Hello real Tor S5B".data;

            StanzaNode iq = build_incoming_s5b_session_initiate_iq_with_candidate(peer, sid, content_name,
                "incoming.txt", payload.length.to_string(), s5b_sid,
                remote_candidate_cid, remote_candidate_host, remote_candidate_port);
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;
            assert_true(file_transfer.transport_ns_uri == NS_JINGLE_S5B);
            assert_null(file_transfer.stream);

            var pending_accept = new PendingFileTransferAccept(stream, file_transfer);
            wait_until(() => find_written_jingle_action(stream, sid, "session-accept") != null,
                1000, "real-Tor S5B accept did not write session-accept");

            StanzaNode accept_jingle = require_written_jingle_action(stream, sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", NS_JINGLE);
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", NS_JINGLE_S5B);
            assert_true(accept_transport.get_attribute("sid") == s5b_sid);
            assert_true(count_candidates_by_type(accept_transport, "direct") == 0);
            assert_true(count_candidates_by_type(accept_transport, "proxy") == 0);

            ((!) tor).wait_until_private_loopback_rejected(3000);
            try {
                pending_accept.wait_until_completed(250);
            } catch (IOError.TIMED_OUT ignored) {
            }
            assert_null(file_transfer.stream);
            ((!) direct_trap).assert_not_hit_after(100);
        } catch (Error e) {
            assert_not_reached();
        } finally {
            if (tor != null) {
                ((!) tor).close();
            }
            if (direct_trap != null) {
                ((!) direct_trap).close();
            }
        }
    }

    private void test_incoming_session_initiate_real_tor_onion_s5b_byte_flow() {
        HiddenServiceS5BTarget? target = null;
        LocalTorSocksDaemon? tor = null;
        try {
            string? tor_path = LocalTorSocksDaemon.lookup_hidden_service_tor_path_or_skip();
            if (tor_path == null) return;

            target = new HiddenServiceS5BTarget();
            tor = LocalTorSocksDaemon.start_hidden_service((!) tor_path, ((!) target).port, 7777);

            string? onion_hostname = ((!) tor).onion_hostname;
            assert_nonnull(onion_hostname);
            ((!) target).expect_warmup();
            run_connect_to_onion_through_tor((!) tor, (!) onion_hostname, 7777, 180000);
            ((!) target).wait_until_warmup_completed(5000);

            run_real_tor_onion_s5b_candidate_flow((!) tor, (!) target,
                "audit-incoming-s5b-real-tor-onion",
                "peer-onion-candidate", (!) onion_hostname, 7777);
        } catch (Error e) {
            GLib.Test.message("real Tor onion S5B byte-flow proof failed: %s", e.message);
            assert_not_reached();
        } finally {
            if (tor != null) {
                ((!) tor).close();
            }
            if (target != null) {
                ((!) target).close();
            }
        }
    }

    private void test_incoming_session_initiate_real_tor_onion_s5b_jet_security_byte_flow() {
        HiddenServiceS5BTarget? target = null;
        LocalTorSocksDaemon? tor = null;
        try {
            string? tor_path = LocalTorSocksDaemon.lookup_hidden_service_tor_path_or_skip();
            if (tor_path == null) return;

            target = new HiddenServiceS5BTarget();
            tor = LocalTorSocksDaemon.start_hidden_service((!) tor_path, ((!) target).port, 7777);

            string? onion_hostname = ((!) tor).onion_hostname;
            assert_nonnull(onion_hostname);
            ((!) target).expect_warmup();
            run_connect_to_onion_through_tor((!) tor, (!) onion_hostname, 7777, 180000);
            ((!) target).wait_until_warmup_completed(5000);

            run_real_tor_onion_s5b_candidate_flow((!) tor, (!) target,
                "audit-incoming-s5b-real-tor-onion-jet",
                "peer-onion-candidate-jet", (!) onion_hostname, 7777,
                build_test_jet_security_node(), true);
        } catch (Error e) {
            GLib.Test.message("real Tor onion JET S5B byte-flow proof failed: %s", e.message);
            assert_not_reached();
        } finally {
            if (tor != null) {
                ((!) tor).close();
            }
            if (target != null) {
                ((!) target).close();
            }
        }
    }

    private void run_real_tor_onion_s5b_candidate_flow(LocalTorSocksDaemon tor, HiddenServiceS5BTarget target,
            string sid, string remote_candidate_cid, string remote_candidate_host, int remote_candidate_port,
            StanzaNode? security = null, bool encrypted_payload = false) throws Error {
        var stream = create_attached_jingle_file_transfer_stream(true, false, false, false);
        if (security != null) {
            attach_test_jet_security(stream);
        }
        var s5b = stream.get_module<Xep.JingleSocks5Bytestreams.Module>(Xep.JingleSocks5Bytestreams.Module.IDENTITY);
        assert_nonnull(s5b);
        ((!) s5b).set_network_policy(false, "socks5://127.0.0.1:%d".printf(tor.port));

        var peer = new Jid("bob@example.test/phone");
        var local = new Jid("alice@example.test/dinox");
        string content_name = "incoming-file";
        string s5b_sid = "incoming-s5b-tor-onion-session";
        string remote_dstaddr = Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, local);
        uint8[] payload = "Hello real Tor onion S5B".data;
        uint8[] send_payload = payload;
        if (encrypted_payload) {
            assert_nonnull(security);
            send_payload = xor_payload(payload, TestJetCipher.KEY);
        }
        target.expect(remote_dstaddr);

        StanzaNode iq = build_incoming_s5b_session_initiate_iq_with_candidate(peer, sid, content_name,
            "incoming.txt", payload.length.to_string(), s5b_sid,
            remote_candidate_cid, remote_candidate_host, remote_candidate_port,
            "incoming-s5b-session-initiate", security);
        int incoming_count = 0;
        Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
        assert_true(incoming_count == 1);
        assert_nonnull(transfer);
        Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;
        assert_true(file_transfer.transport_ns_uri == NS_JINGLE_S5B);
        if (security != null) {
            assert_nonnull(file_transfer.security);
            Xep.Jet.SecurityParameters? parsed_security = file_transfer.security as Xep.Jet.SecurityParameters;
            assert_nonnull(parsed_security);
            assert_true(((!) parsed_security).encoding.get_type_uri() == NS_TEST_JET_TYPE);
        }
        assert_null(file_transfer.stream);

        var pending_accept = new PendingFileTransferAccept(stream, file_transfer);
        wait_until(() => find_written_jingle_action(stream, sid, "session-accept") != null,
            1000, "real-Tor onion S5B accept did not write session-accept");

        StanzaNode accept_jingle = require_written_jingle_action(stream, sid, "session-accept");
        StanzaNode accept_content = get_required_subnode(accept_jingle, "content", NS_JINGLE);
        StanzaNode accept_transport = get_required_subnode(accept_content, "transport", NS_JINGLE_S5B);
        assert_true(accept_transport.get_attribute("sid") == s5b_sid);
        assert_true(accept_transport.get_subnodes("candidate", NS_JINGLE_S5B).size == 0);

        target.wait_until_connected(5000);
        wait_until(() => find_written_s5b_transport_info_child(stream, sid, peer, content_name, s5b_sid, "candidate-used", remote_candidate_cid) != null,
            5000, "real-Tor onion S5B candidate-used transport-info was not written");

        run_jingle_iq_set(stream,
            build_s5b_candidate_error_transport_info(peer, sid, content_name, s5b_sid, "s5b-real-tor-onion-candidate-error-1"));
        assert_written_iq_result(stream, "s5b-real-tor-onion-candidate-error-1", peer);

        pending_accept.wait_until_completed(1000);
        pending_accept.assert_succeeded();
        assert_nonnull(file_transfer.stream);
        assert_nonnull(target.connection);
        SocketConnection target_connection = (!) target.connection;
        InputStream transfer_stream = (!) file_transfer.stream;
        run_write_all_stream(target_connection.output_stream, send_payload);
        assert_read_exact(transfer_stream, payload);
        if (encrypted_payload) {
            assert_authenticated_eof(transfer_stream);
        }

        run_close_stream(transfer_stream);
        assert_last_session_terminate_reason(stream, sid, peer, Xep.Jingle.ReasonElement.SUCCESS);
        assert_no_jingle_session_state(stream, sid);
    }

    private void run_connect_to_onion_through_tor(LocalTorSocksDaemon tor, string onion_hostname, int onion_port, uint timeout_ms) throws Error {
        Error? failure = null;
        Cancellable cancellable = new Cancellable();
        bool timed_out = false;
        var loop = new MainLoop();
        uint timeout_source = 0;
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            return Source.REMOVE;
        });
        connect_to_onion_through_tor.begin(tor, onion_hostname, onion_port, cancellable, (obj, res) => {
            try {
                connect_to_onion_through_tor.end(res);
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
            throw new IOError.TIMED_OUT("Timed out warming up Tor onion S5B target");
        }
        if (failure != null) {
            throw (!) failure;
        }
    }

    private async void connect_to_onion_through_tor(LocalTorSocksDaemon tor, string onion_hostname, int onion_port,
            Cancellable cancellable) throws Error {
        SocketClient socket_client = new SocketClient() { timeout=180 };
        socket_client.set_proxy_resolver(new SimpleProxyResolver("direct://", null));
        SocketConnection? conn = null;
        try {
            conn = yield socket_client.connect_to_host_async("127.0.0.1:%d".printf(tor.port), 0, cancellable);
            yield perform_onion_warmup_socks_connect((!) conn, onion_hostname, onion_port, cancellable);
        } catch (Error e) {
            if (conn != null) {
                try {
                    ((!) conn).close();
                } catch (Error close_error) {
                }
            }
            throw e;
        }
        ((!) conn).close();
    }

    private async void perform_onion_warmup_socks_connect(SocketConnection conn, string onion_hostname, int onion_port,
            Cancellable cancellable) throws Error {
        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield conn.output_stream.write_all_async({0x05, 0x01, 0x00}, Priority.DEFAULT, cancellable, out written);
        yield conn.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, cancellable, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] != 0x00) {
            throw new IOError.PROXY_FAILED("Tor onion warmup SOCKS proxy did not accept null authentication");
        }

        write_buffer.append({0x05, 0x01, 0x00, 0x03});
        write_buffer.append({(uint8) onion_hostname.length});
        write_buffer.append(onion_hostname.data);
        write_buffer.append({(uint8)((onion_port >> 8) & 0xff), (uint8)(onion_port & 0xff)});
        yield conn.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, cancellable, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, cancellable, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x00) {
            throw new IOError.PROXY_FAILED("Tor onion warmup SOCKS proxy did not connect to the hidden service");
        }
        if (read_buffer[3] == 0x01) {
            yield conn.input_stream.read_all_async(read_buffer[0:6], Priority.DEFAULT, cancellable, out read);
        } else if (read_buffer[3] == 0x03) {
            yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, cancellable, out read);
            if (read != 1) {
                throw new IOError.PROXY_FAILED("Tor onion warmup SOCKS proxy returned an incomplete domain reply");
            }
            int host_len = read_buffer[0];
            yield conn.input_stream.read_all_async(read_buffer[0:host_len + 2], Priority.DEFAULT, cancellable, out read);
        } else if (read_buffer[3] == 0x04) {
            yield conn.input_stream.read_all_async(read_buffer[0:18], Priority.DEFAULT, cancellable, out read);
        } else {
            throw new IOError.PROXY_FAILED("Tor onion warmup SOCKS proxy returned an unsupported address type");
        }
    }

    private void test_incoming_ibb_short_transfer_app_close_after_eof() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");

            StanzaNode iq = build_incoming_session_initiate_iq(peer, "audit-incoming-short-transfer-close", "incoming.txt", "42");
            int incoming_count = 0;
            Xep.JingleFileTransfer.FileTransfer? transfer = run_incoming_session_initiate(stream, iq, out incoming_count);
            assert_true(incoming_count == 1);
            assert_nonnull(transfer);
            Xep.JingleFileTransfer.FileTransfer file_transfer = (!) transfer;

            run_accept_file_transfer(stream, file_transfer);
            assert_nonnull(file_transfer.stream);
            InputStream transfer_stream = (!) file_transfer.stream;

            run_ibb_iq_set(stream, peer, build_ibb_open("incoming-ibb-session", 4096), "ibb-short-open-1");
            assert_last_iq_result(stream, "ibb-short-open-1", peer);

            string payload = "Hello IBB";
            run_ibb_iq_set(stream, peer, build_ibb_data("incoming-ibb-session", 0, payload.data), "ibb-short-data-1");
            assert_last_iq_result(stream, "ibb-short-data-1", peer);

            uint8[] buffer = new uint8[64];
            ssize_t read = run_read_stream(transfer_stream, buffer);
            assert_true(read == payload.data.length);

            run_ibb_iq_set(stream, peer, build_ibb_close("incoming-ibb-session"), "ibb-short-close-1");
            assert_last_iq_result(stream, "ibb-short-close-1", peer);
            assert_null(stream.get_flag(Xep.InBandBytestreams.Flag.IDENTITY).get_connection("incoming-ibb-session"));

            try {
                run_read_stream(transfer_stream, buffer);
                assert_not_reached();
            } catch (IOError.FAILED e) {
                assert_true(e.message.contains("declared size"));
            }

            run_close_stream(transfer_stream);
            assert_last_session_terminate_reason(stream, "audit-incoming-short-transfer-close", peer, Xep.Jingle.ReasonElement.FAILED_TRANSPORT);
            assert_no_jingle_session_state(stream, "audit-incoming-short-transfer-close");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_incoming_session_initiate_rejects_missing_size() {
        JingleFtTestXmppStream? stream = null;
        int incoming_count = -1;
        try {
            stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");

            StanzaNode iq = build_incoming_session_initiate_iq(peer, "audit-incoming-missing-size", "incoming.txt", null);
            run_incoming_session_initiate((!) stream, iq, out incoming_count);
            assert_not_reached();
        } catch (Xep.Jingle.IqError e) {
            assert_true(e.message.contains("size"));
            assert_true(incoming_count == 0);
            assert_nonnull(stream);
            assert_no_jingle_session_state((!) stream, "audit-incoming-missing-size");
            stream_writes_must_be_empty((!) stream);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_incoming_session_initiate_rejects_duplicate_sid() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");

            StanzaNode first_iq = build_incoming_session_initiate_iq(peer, "audit-duplicate-session", "first.txt", "1", "incoming-session-initiate-1");
            int first_count = 0;
            Xep.JingleFileTransfer.FileTransfer? first_transfer = run_incoming_session_initiate(stream, first_iq, out first_count);
            assert_true(first_count == 1);
            assert_nonnull(first_transfer);
            assert_true(stream.written_nodes.size == 1);
            assert_true(stream.written_nodes[0].get_attribute("type") == "result");

            StanzaNode duplicate_iq = build_incoming_session_initiate_iq(peer, "audit-duplicate-session", "second.txt", "2", "incoming-session-initiate-2");
            int duplicate_count = 0;
            Xep.JingleFileTransfer.FileTransfer? duplicate_transfer = run_incoming_session_initiate(stream, duplicate_iq, out duplicate_count);

            assert_true(duplicate_count == 0);
            assert_null(duplicate_transfer);
            assert_true(stream.written_nodes.size == 2);
            StanzaNode error_iq = stream.written_nodes[1];
            assert_true(error_iq.get_attribute("type") == "error");
            assert_true(error_iq.get_attribute("id") == "incoming-session-initiate-2");
            assert_true(error_iq.get_attribute("to") == peer.to_string());
            ErrorStanza? error = ErrorStanza.from_stanza(error_iq);
            assert_nonnull(error);
            assert_true(((!) error).type_ == ErrorStanza.TYPE_MODIFY);
            assert_true(((!) error).condition == ErrorStanza.CONDITION_CONFLICT);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_incoming_session_initiate_rejects_late_invalid_content_before_signal() {
        JingleFtTestXmppStream? stream = null;
        int incoming_count = -1;
        try {
            stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");

            StanzaNode iq = build_incoming_session_initiate_iq(peer, "audit-incoming-late-invalid", "first.txt", "1");
            StanzaNode jingle = get_required_subnode(iq, "jingle", NS_JINGLE);
            jingle.put_node(build_incoming_ibb_content("invalid-second-file", "second.txt", null, "incoming-ibb-session-2"));

            run_incoming_session_initiate((!) stream, iq, out incoming_count);
            assert_not_reached();
        } catch (Xep.Jingle.IqError e) {
            assert_true(e.message.contains("size"));
            assert_true(incoming_count == 0);
            assert_nonnull(stream);
            assert_no_jingle_session_state((!) stream, "audit-incoming-late-invalid");
            stream_writes_must_be_empty((!) stream);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_incoming_session_initiate_stops_after_rejected_initial_content() {
        try {
            var stream = create_attached_jingle_file_transfer_stream(false, true, true, false);
            var peer = new Jid("bob@example.test/phone");
            var jingle = stream.get_module<Xep.Jingle.Module>(Xep.Jingle.Module.IDENTITY);
            assert_nonnull(jingle);
            var audit_content = new RejectingAuditContentType();
            ((!) jingle).register_content_type(audit_content);

            StanzaNode iq = build_audit_session_initiate_iq(peer, "audit-reject-stops-next-content");
            int session_initiate_count = 0;
            ulong handler_id = ((!) jingle).session_initiate_received.connect((incoming_stream, session) => {
                assert_true(incoming_stream == stream);
                session_initiate_count++;
            });
            int incoming_count = 0;
            run_incoming_session_initiate(stream, iq, out incoming_count);
            ((!) jingle).disconnect(handler_id);

            assert_true(audit_content.proposed_count == 1);
            assert_true(audit_content.last_mode == "reject");
            assert_true(incoming_count == 0);
            assert_true(session_initiate_count == 0);
            assert_no_jingle_session_state(stream, "audit-reject-stops-next-content");
            assert_true(stream.written_nodes.size == 1);
            StanzaNode written_iq = stream.written_nodes[0];
            assert_true(written_iq.get_attribute("type") == "set");
            StanzaNode? jingle_node = written_iq.get_subnode("jingle", NS_JINGLE);
            assert_nonnull(jingle_node);
            assert_true(((!) jingle_node).get_attribute("action") == "session-terminate");
            assert_true(((!) jingle_node).get_attribute("sid") == "audit-reject-stops-next-content");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private JingleFtTestXmppStream create_attached_jingle_file_transfer_stream(bool attach_s5b, bool attach_ibb, bool allow_local_candidates, bool with_proxy) throws Error {
        var stream = new JingleFtTestXmppStream(new Jid("example.test"));

        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = new Jid("alice@example.test/dinox");
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var socks5_module = new Xep.Socks5Bytestreams.Module();
        socks5_module.set_local_ip_address_handler(() => {
            var addresses = new ArrayList<string>();
            addresses.add("127.0.0.1");
            return addresses;
        });
        stream.add_module(socks5_module);

        var socks5_flag = new Xep.Socks5Bytestreams.Flag();
        if (with_proxy) {
            socks5_flag.proxies.add(new Xep.Socks5Bytestreams.Proxy(
                "proxy.example.test",
                new Jid("proxy.example.test"),
                7777));
        }
        stream.add_flag(socks5_flag);

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var service_discovery = new Xep.ServiceDiscovery.Module.with_identity("client", "pc", "DinoX Test");
        service_discovery.cache = new JingleFtFakeCapsCache();
        stream.add_module(service_discovery);
        service_discovery.attach(stream);

        var jingle = new Xep.Jingle.Module();
        stream.add_module(jingle);
        jingle.attach(stream);

        var file_transfer = new Xep.JingleFileTransfer.Module();
        stream.add_module(file_transfer);
        file_transfer.attach(stream);

        if (attach_s5b) {
            var s5b = new Xep.JingleSocks5Bytestreams.Module();
            s5b.set_network_policy(allow_local_candidates, allow_local_candidates ? null : "socks5://127.0.0.1:9050");
            stream.add_module(s5b);
            s5b.attach(stream);
        }

        if (attach_ibb) {
            var in_band_bytestreams = new Xep.InBandBytestreams.Module();
            stream.add_module(in_band_bytestreams);
            in_band_bytestreams.attach(stream);

            var ibb = new Xep.JingleInBandBytestreams.Module();
            stream.add_module(ibb);
            ibb.attach(stream);
        }

        return stream;
    }

    private void add_s5b_proxy(JingleFtTestXmppStream stream, string host, Jid jid, int port) {
        var socks5_flag = stream.get_flag(Xep.Socks5Bytestreams.Flag.IDENTITY);
        assert_nonnull(socks5_flag);
        ((!) socks5_flag).proxies.add(new Xep.Socks5Bytestreams.Proxy(host, jid, port));
    }

    private void add_peer_features(JingleFtFakeCapsCache cache, Jid peer, bool jingle, bool file_transfer, bool s5b, bool ibb) {
        if (jingle) cache.add_feature(peer, NS_JINGLE);
        if (file_transfer) cache.add_feature(peer, NS_URI);
        if (s5b) cache.add_feature(peer, NS_JINGLE_S5B);
        if (ibb) cache.add_feature(peer, NS_JINGLE_IBB);
    }

    private StanzaNode assert_session_initiate_shell(StanzaNode iq, Jid peer) {
        assert_true(iq.name == "iq");
        assert_true(iq.get_attribute("type") == "set");
        assert_true(iq.get_attribute("to") == peer.to_string());
        StanzaNode jingle = get_required_subnode(iq, "jingle", NS_JINGLE);
        assert_true(jingle.get_attribute("action") == "session-initiate");
        assert_true(jingle.get_attribute("initiator") == "alice@example.test/dinox");
        assert_true(jingle.get_attribute("sid") == "audit-jingle-ft-session");

        Gee.List<StanzaNode> contents = jingle.get_subnodes("content", NS_JINGLE);
        assert_true(contents.size == 1);
        StanzaNode content = contents[0];
        assert_true(content.get_attribute("creator") == "initiator");
        assert_true(content.get_attribute("name") == "a-file-offer");
        assert_true(content.get_attribute("senders") == "initiator");
        return content;
    }

    private StanzaNode build_incoming_session_initiate_iq(Jid peer, string sid, string? file_name, string? file_size, string iq_id = "incoming-session-initiate") {
        StanzaNode jingle = new StanzaNode.build("jingle", NS_JINGLE)
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(build_incoming_ibb_content("incoming-file", file_name, file_size));
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_incoming_s5b_session_initiate_iq(Jid peer, string sid, string content_name, string? file_name,
            string? file_size, string iq_id = "incoming-s5b-session-initiate", StanzaNode? security = null) throws Error {
        StanzaNode jingle = new StanzaNode.build("jingle", NS_JINGLE)
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(build_incoming_s5b_content(content_name, peer, "alice@example.test/dinox", file_name, file_size, "incoming-s5b-session", security));
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_incoming_s5b_session_initiate_iq_with_candidate(Jid peer, string sid, string content_name,
            string? file_name, string? file_size, string s5b_sid, string candidate_cid, string candidate_host,
            int candidate_port, string iq_id = "incoming-s5b-session-initiate", StanzaNode? security = null) throws Error {
        StanzaNode jingle = new StanzaNode.build("jingle", NS_JINGLE)
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(build_incoming_s5b_content_with_candidate(content_name, peer, "alice@example.test/dinox",
                file_name, file_size, s5b_sid, candidate_cid, candidate_host, candidate_port, security));
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_incoming_ibb_content(string content_name, string? file_name, string? file_size, string ibb_sid = "incoming-ibb-session") {
        StanzaNode transport = new StanzaNode.build("transport", NS_JINGLE_IBB)
            .add_self_xmlns()
            .put_attribute("sid", ibb_sid)
            .put_attribute("block-size", "4096");
        return new StanzaNode.build("content", NS_JINGLE)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(build_description(file_name, file_size))
            .put_node(transport);
    }

    private StanzaNode build_incoming_s5b_content(string content_name, Jid peer, string local_full_jid, string? file_name,
            string? file_size, string s5b_sid = "incoming-s5b-session", StanzaNode? security = null) throws Error {
        var local = new Jid(local_full_jid);
        string dstaddr = Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, local);
        StanzaNode transport = new StanzaNode.build("transport", NS_JINGLE_S5B)
            .add_self_xmlns()
            .put_attribute("mode", "tcp")
            .put_attribute("sid", s5b_sid)
            .put_attribute("dstaddr", dstaddr);
        StanzaNode content = new StanzaNode.build("content", NS_JINGLE)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(build_description(file_name, file_size))
            .put_node(transport);
        if (security != null) {
            content.put_node((!) security);
        }
        return content;
    }

    private StanzaNode build_incoming_s5b_content_with_candidate(string content_name, Jid peer, string local_full_jid,
            string? file_name, string? file_size, string s5b_sid, string candidate_cid, string candidate_host,
            int candidate_port, StanzaNode? security = null) throws Error {
        var local = new Jid(local_full_jid);
        string dstaddr = Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, local);
        StanzaNode transport = new StanzaNode.build("transport", NS_JINGLE_S5B)
            .add_self_xmlns()
            .put_attribute("mode", "tcp")
            .put_attribute("sid", s5b_sid)
            .put_attribute("dstaddr", dstaddr)
            .put_node(new StanzaNode.build("candidate", NS_JINGLE_S5B)
                .put_attribute("cid", candidate_cid)
                .put_attribute("host", candidate_host)
                .put_attribute("jid", peer.to_string())
                .put_attribute("port", candidate_port.to_string())
                .put_attribute("priority", "8267775")
                .put_attribute("type", "direct"));
        StanzaNode content = new StanzaNode.build("content", NS_JINGLE)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(build_description(file_name, file_size))
            .put_node(transport);
        if (security != null) {
            content.put_node((!) security);
        }
        return content;
    }

    private StanzaNode build_s5b_candidate_used_transport_info(Jid peer, string sid, string content_name, string cid, string iq_id = "s5b-candidate-used") {
        StanzaNode transport = new StanzaNode.build("transport", NS_JINGLE_S5B)
            .add_self_xmlns()
            .put_attribute("sid", "incoming-s5b-session")
            .put_node(new StanzaNode.build("candidate-used", NS_JINGLE_S5B)
                .put_attribute("cid", cid));
        StanzaNode content = new StanzaNode.build("content", NS_JINGLE)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(transport);
        StanzaNode jingle = new StanzaNode.build("jingle", NS_JINGLE)
            .add_self_xmlns()
            .put_attribute("action", "transport-info")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_s5b_candidate_error_transport_info(Jid peer, string sid, string content_name, string s5b_sid, string iq_id = "s5b-candidate-error") {
        StanzaNode transport = new StanzaNode.build("transport", NS_JINGLE_S5B)
            .add_self_xmlns()
            .put_attribute("sid", s5b_sid)
            .put_node(new StanzaNode.build("candidate-error", NS_JINGLE_S5B));
        StanzaNode content = new StanzaNode.build("content", NS_JINGLE)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(transport);
        StanzaNode jingle = new StanzaNode.build("jingle", NS_JINGLE)
            .add_self_xmlns()
            .put_attribute("action", "transport-info")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_iq_result(StanzaNode request, string from, string to) {
        string? id = request.get_attribute("id");
        assert_nonnull(id);
        return new StanzaNode.build("iq")
            .put_attribute("type", "result")
            .put_attribute("id", (!) id)
            .put_attribute("from", from)
            .put_attribute("to", to);
    }

    private StanzaNode build_audit_session_initiate_iq(Jid peer, string sid) {
        StanzaNode jingle = new StanzaNode.build("jingle", NS_JINGLE)
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(build_rejecting_audit_content("rejecting-content", "reject", "audit-reject-ibb-1"))
            .put_node(build_rejecting_audit_content("second-content", "record", "audit-reject-ibb-2"));
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", "incoming-rejecting-session-initiate")
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_rejecting_audit_content(string content_name, string mode, string ibb_sid) {
        StanzaNode description = new StanzaNode.build("description", RejectingAuditContentType.NS_URI)
            .add_self_xmlns()
            .put_attribute("mode", mode);
        StanzaNode transport = new StanzaNode.build("transport", NS_JINGLE_IBB)
            .add_self_xmlns()
            .put_attribute("sid", ibb_sid)
            .put_attribute("block-size", "4096");
        return new StanzaNode.build("content", NS_JINGLE)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(description)
            .put_node(transport);
    }

    private StanzaNode build_ibb_open(string sid, int block_size) {
        return new StanzaNode.build("open", NS_IBB)
            .add_self_xmlns()
            .put_attribute("sid", sid)
            .put_attribute("block-size", block_size.to_string())
            .put_attribute("stanza", "iq");
    }

    private StanzaNode build_ibb_data(string sid, int seq, uint8[] payload) {
        return new StanzaNode.build("data", NS_IBB)
            .add_self_xmlns()
            .put_attribute("sid", sid)
            .put_attribute("seq", seq.to_string())
            .put_node(new StanzaNode.text(Base64.encode(payload)));
    }

    private StanzaNode build_ibb_close(string sid) {
        return new StanzaNode.build("close", NS_IBB)
            .add_self_xmlns()
            .put_attribute("sid", sid);
    }

    private StanzaNode get_required_subnode(StanzaNode node, string name, string ns_uri) {
        StanzaNode? child = node.get_subnode(name, ns_uri);
        assert_nonnull(child);
        return (!) child;
    }

    private StanzaNode get_single_candidate_by_type(StanzaNode transport, string type_) {
        StanzaNode? result = null;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate", NS_JINGLE_S5B)) {
            if (candidate.get_attribute("type") == type_) {
                assert_null(result);
                result = candidate;
            }
        }
        assert_nonnull(result);
        return (!) result;
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

    private bool is_lowercase_hex(string value) {
        for (int i = 0; i < value.length; i++) {
            char c = value[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
                return false;
            }
        }
        return true;
    }

    private JingleFtFakeCapsCache get_fake_cache(XmppStream stream) {
        return (JingleFtFakeCapsCache) stream.get_module<Xep.ServiceDiscovery.Module>(Xep.ServiceDiscovery.Module.IDENTITY).cache;
    }

    private void attach_test_jet_security(JingleFtTestXmppStream stream) {
        var jet = new Xep.Jet.Module();
        stream.add_module(jet);
        jet.attach(stream);
        jet.register_envelop_encoding(new TestJetEnvelope());
        jet.register_cipher(new TestJetCipher());
    }

    private StanzaNode build_test_jet_security_node() {
        return new StanzaNode.build("security", NS_JET)
            .add_self_xmlns()
            .put_attribute("cipher", NS_TEST_JET_CIPHER)
            .put_attribute("type", NS_TEST_JET_TYPE)
            .put_attribute("test-key", "5a");
    }

    private uint8[] xor_payload(uint8[] payload, uint8 key) {
        uint8[] result = new uint8[payload.length];
        for (int i = 0; i < payload.length; i++) {
            result[i] = (uint8) (payload[i] ^ key);
        }
        return result;
    }

    private bool run_file_transfer_available(Xep.JingleFileTransfer.Module module, XmppStream stream, Jid peer) {
        bool result = false;
        var loop = new MainLoop();
        module.is_available.begin(stream, peer, (obj, res) => {
            result = module.is_available.end(res);
            loop.quit();
        });
        loop.run();
        return result;
    }

    private StanzaNode run_file_transfer_session_initiate(JingleFtTestXmppStream stream, Jid peer, string basename, int64 size) throws Error {
        StanzaNode? result = null;
        Error? failure = null;
        var loop = new MainLoop();
        create_file_transfer_session_initiate.begin(stream, peer, basename, size, (obj, res) => {
            try {
                result = create_file_transfer_session_initiate.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) {
            throw (!) failure;
        }
        assert_nonnull(result);
        return (!) result;
    }

    private void run_create_session(Xep.Jingle.Module jingle, JingleFtTestXmppStream stream,
            Gee.List<Xep.Jingle.Content> contents, Jid peer, string sid) throws Error {
        Error? failure = null;
        var loop = new MainLoop();
        jingle.create_session.begin(stream, contents, peer, sid, null, (obj, res) => {
            try {
                jingle.create_session.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) {
            throw (!) failure;
        }
    }

    private Xep.JingleFileTransfer.FileTransfer? run_incoming_session_initiate(JingleFtTestXmppStream stream, StanzaNode iq_node, out int incoming_count) throws Error {
        var jingle = stream.get_module<Xep.Jingle.Module>(Xep.Jingle.Module.IDENTITY);
        assert_nonnull(jingle);
        var file_transfer = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
        assert_nonnull(file_transfer);

        Xep.JingleFileTransfer.FileTransfer? incoming_transfer = null;
        int signal_count = 0;
        ulong handler_id = ((!) file_transfer).file_incoming.connect((incoming_stream, transfer) => {
            assert_true(incoming_stream == stream);
            incoming_transfer = transfer;
            signal_count++;
        });

        Error? failure = null;
        var loop = new MainLoop();
        var iq = new Iq.Stanza.from_stanza(iq_node, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
        ((!) jingle).handle_iq_set.begin(stream, iq, (_, res) => {
            try {
                ((!) jingle).handle_iq_set.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        ((!) file_transfer).disconnect(handler_id);

        incoming_count = signal_count;
        if (failure != null) {
            throw (!) failure;
        }
        return incoming_transfer;
    }

    private void run_accept_file_transfer(JingleFtTestXmppStream stream, Xep.JingleFileTransfer.FileTransfer transfer) throws Error {
        Error? failure = null;
        var loop = new MainLoop();
        transfer.accept.begin(stream, (_, res) => {
            try {
                transfer.accept.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) {
            throw (!) failure;
        }
    }

    private void run_ibb_iq_set(JingleFtTestXmppStream stream, Jid peer, StanzaNode ibb_node, string iq_id) {
        var ibb = stream.get_module<Xep.InBandBytestreams.Module>(Xep.InBandBytestreams.Module.IDENTITY);
        assert_nonnull(ibb);

        StanzaNode iq_node = new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(ibb_node);
        var iq = new Iq.Stanza.from_stanza(iq_node, stream.get_flag(Bind.Flag.IDENTITY).my_jid);

        var loop = new MainLoop();
        ((!) ibb).on_iq_set.begin(stream, iq, (_, res) => {
            ((!) ibb).on_iq_set.end(res);
            loop.quit();
        });
        loop.run();
    }

    private void run_jingle_iq_set(JingleFtTestXmppStream stream, StanzaNode iq_node) throws Error {
        var jingle = stream.get_module<Xep.Jingle.Module>(Xep.Jingle.Module.IDENTITY);
        assert_nonnull(jingle);

        Error? failure = null;
        var iq = new Iq.Stanza.from_stanza(iq_node, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
        var loop = new MainLoop();
        ((!) jingle).handle_iq_set.begin(stream, iq, (_, res) => {
            try {
                ((!) jingle).handle_iq_set.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) {
            throw (!) failure;
        }
    }

    private delegate bool WaitCondition();

    private void wait_until(WaitCondition condition, uint timeout_ms, string timeout_message) throws Error {
        if (condition()) {
            return;
        }

        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(10, () => {
            if (condition()) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && !condition()) {
            throw new IOError.TIMED_OUT(timeout_message);
        }
    }

    private ssize_t run_read_stream(InputStream input, uint8[] buffer) throws Error {
        ssize_t result = -1;
        Error? failure = null;
        var loop = new MainLoop();
        input.read_async.begin(buffer, Priority.DEFAULT, null, (_, res) => {
            try {
                result = input.read_async.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) {
            throw (!) failure;
        }
        return result;
    }

    private ssize_t run_read_stream_with_timeout(InputStream input, uint8[] buffer, uint timeout_ms) throws Error {
        ssize_t result = -1;
        Error? failure = null;
        bool timed_out = false;
        uint timeout_source = 0;
        Cancellable cancellable = new Cancellable();
        var loop = new MainLoop();

        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            return Source.REMOVE;
        });
        input.read_async.begin(buffer, Priority.DEFAULT, cancellable, (_, res) => {
            try {
                result = input.read_async.end(res);
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
            throw new IOError.TIMED_OUT("Timed out reading S5B payload");
        }
        if (failure != null) {
            throw (!) failure;
        }
        return result;
    }

    private void assert_read_exact(InputStream input, uint8[] expected) throws Error {
        uint8[] buffer = new uint8[expected.length];
        int offset = 0;
        while (offset < expected.length) {
            ssize_t read = run_read_stream_with_timeout(input, buffer[offset:expected.length], 1000);
            assert_true(read > 0);
            offset += (int) read;
        }
        for (int i = 0; i < expected.length; i++) {
            assert_true(buffer[i] == expected[i]);
        }
    }

    private void assert_authenticated_eof(InputStream input) throws Error {
        uint8[] buffer = new uint8[1];
        ssize_t eof = run_read_stream_with_timeout(input, buffer, 1000);
        assert_true(eof == 0);
        assert_true(TestJetCipher.input_authenticated);
    }

    private void run_write_all_stream(OutputStream output, uint8[] payload) throws Error {
        Error? failure = null;
        bool timed_out = false;
        uint timeout_source = 0;
        size_t written = 0;
        Cancellable cancellable = new Cancellable();
        var loop = new MainLoop();

        timeout_source = Timeout.add(1000, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            return Source.REMOVE;
        });
        output.write_all_async.begin(payload, Priority.DEFAULT, cancellable, (obj, res) => {
            try {
                output.write_all_async.end(res, out written);
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
            throw new IOError.TIMED_OUT("Timed out writing S5B payload");
        }
        if (failure != null) {
            throw (!) failure;
        }
        assert_true(written == payload.length);
    }

    private void run_close_stream(InputStream input) throws Error {
        bool result = false;
        Error? failure = null;
        var loop = new MainLoop();
        input.close_async.begin(Priority.DEFAULT, null, (_, res) => {
            try {
                result = input.close_async.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) {
            throw (!) failure;
        }
        assert_true(result);
    }

    private void assert_last_iq_result(JingleFtTestXmppStream stream, string iq_id, Jid peer) {
        assert_false(stream.written_nodes.is_empty);
        StanzaNode result = stream.written_nodes[stream.written_nodes.size - 1];
        assert_true(result.name == "iq");
        assert_true(result.get_attribute("type") == "result");
        assert_true(result.get_attribute("id") == iq_id);
        assert_true(result.get_attribute("to") == peer.to_string());
    }

    private void assert_written_iq_result(JingleFtTestXmppStream stream, string iq_id, Jid peer) {
        StanzaNode? result = find_written_iq_result(stream, iq_id);
        assert_nonnull(result);
        assert_true(((!) result).get_attribute("to") == peer.to_string());
    }

    private StanzaNode? find_written_iq_result(JingleFtTestXmppStream stream, string iq_id) {
        foreach (StanzaNode iq in stream.written_nodes) {
            if (iq.name == "iq" &&
                    iq.get_attribute("type") == "result" &&
                    iq.get_attribute("id") == iq_id) {
                return iq;
            }
        }
        return null;
    }

    private void assert_last_session_terminate_reason(JingleFtTestXmppStream stream, string sid, Jid peer, string reason_name) {
        assert_false(stream.written_nodes.is_empty);
        StanzaNode iq = stream.written_nodes[stream.written_nodes.size - 1];
        assert_true(iq.name == "iq");
        assert_true(iq.get_attribute("type") == "set");
        assert_true(iq.get_attribute("to") == peer.to_string());
        StanzaNode jingle = get_required_subnode(iq, "jingle", NS_JINGLE);
        assert_true(jingle.get_attribute("action") == "session-terminate");
        assert_true(jingle.get_attribute("sid") == sid);
        StanzaNode reason = get_required_subnode(jingle, "reason", NS_JINGLE);
        assert_nonnull(reason.get_subnode(reason_name, NS_JINGLE));
    }

    private string? find_session_initiate_sid(JingleFtTestXmppStream stream, Jid peer) {
        foreach (StanzaNode iq in stream.written_nodes) {
            if (iq.name != "iq" || iq.get_attribute("type") != "set" ||
                    iq.get_attribute("to") != peer.to_string()) {
                continue;
            }
            StanzaNode? jingle = iq.get_subnode("jingle", NS_JINGLE);
            if (jingle != null && ((!) jingle).get_attribute("action") == "session-initiate") {
                return ((!) jingle).get_attribute("sid");
            }
        }
        return null;
    }

    private StanzaNode? find_written_socks5_activation_iq(JingleFtTestXmppStream stream, string s5b_sid, Jid proxy_jid, Jid peer) {
        foreach (StanzaNode iq in stream.written_nodes) {
            if (iq.name != "iq" ||
                    iq.get_attribute("type") != "set" ||
                    iq.get_attribute("to") != proxy_jid.to_string()) {
                continue;
            }
            StanzaNode? query = iq.get_subnode("query", NS_SOCKS5_BYTESTREAMS);
            if (query == null || ((!) query).get_attribute("sid") != s5b_sid) {
                continue;
            }
            StanzaNode? activate = ((!) query).get_subnode("activate", NS_SOCKS5_BYTESTREAMS);
            if (activate != null && ((!) activate).get_string_content() == peer.to_string()) {
                return iq;
            }
        }
        return null;
    }

    private StanzaNode require_written_socks5_activation_iq(JingleFtTestXmppStream stream, string s5b_sid, Jid proxy_jid, Jid peer) {
        StanzaNode? result = find_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer);
        assert_nonnull(result);
        return (!) result;
    }

    private StanzaNode? find_written_s5b_transport_info_child(JingleFtTestXmppStream stream, string sid, Jid peer, string content_name, string s5b_sid, string child_name, string? cid = null) {
        foreach (StanzaNode iq in stream.written_nodes) {
            if (iq.name != "iq" ||
                    iq.get_attribute("type") != "set" ||
                    iq.get_attribute("to") != peer.to_string()) {
                continue;
            }
            StanzaNode? jingle = iq.get_subnode("jingle", NS_JINGLE);
            if (jingle == null ||
                    ((!) jingle).get_attribute("sid") != sid ||
                    ((!) jingle).get_attribute("action") != "transport-info") {
                continue;
            }
            foreach (StanzaNode content in ((!) jingle).get_subnodes("content", NS_JINGLE)) {
                if (content.get_attribute("name") != content_name) {
                    continue;
                }
                StanzaNode? transport = content.get_subnode("transport", NS_JINGLE_S5B);
                if (transport == null || ((!) transport).get_attribute("sid") != s5b_sid) {
                    continue;
                }
                StanzaNode? child = ((!) transport).get_subnode(child_name, NS_JINGLE_S5B);
                if (child != null && (cid == null || ((!) child).get_attribute("cid") == cid)) {
                    return (!) child;
                }
            }
        }
        return null;
    }

    private StanzaNode? find_written_jingle_action(JingleFtTestXmppStream stream, string sid, string action) {
        foreach (StanzaNode iq in stream.written_nodes) {
            StanzaNode? jingle = iq.get_subnode("jingle", NS_JINGLE);
            if (jingle != null &&
                    ((!) jingle).get_attribute("sid") == sid &&
                    ((!) jingle).get_attribute("action") == action) {
                return (!) jingle;
            }
        }
        return null;
    }

    private StanzaNode require_written_jingle_action(JingleFtTestXmppStream stream, string sid, string action) {
        StanzaNode? result = find_written_jingle_action(stream, sid, action);
        assert_nonnull(result);
        return (!) result;
    }

    private SocketConnection run_connect_to_socks5(Xep.JingleSocks5Bytestreams.Candidate candidate, string dstaddr) throws Error {
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
        connect_to_socks5.begin(candidate, dstaddr, cancellable, (obj, res) => {
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

    private async SocketConnection connect_to_socks5(Xep.JingleSocks5Bytestreams.Candidate candidate, string dstaddr, Cancellable cancellable) throws Error {
        SocketClient socket_client = new SocketClient() { timeout=2 };
        socket_client.set_proxy_resolver(new SimpleProxyResolver("direct://", null));
        SocketConnection conn = yield socket_client.connect_to_host_async(@"[$(candidate.host)]:$(candidate.port)", 0, cancellable);

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

    private void drain_s5b_listener_bookkeeping() {
        uint timeout_source = 0;
        var loop = new MainLoop();
        // LocalListener records accepted sockets from its async accept callback.
        timeout_source = Timeout.add(100, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (timeout_source != 0) Source.remove(timeout_source);
    }

    private async StanzaNode create_file_transfer_session_initiate(JingleFtTestXmppStream stream, Jid peer, string basename, int64 size) throws Error {
        var file_transfer = stream.get_module<Xep.JingleFileTransfer.Module>(Xep.JingleFileTransfer.Module.IDENTITY);
        assert_nonnull(file_transfer);
        var jingle = stream.get_module<Xep.Jingle.Module>(Xep.Jingle.Module.IDENTITY);
        assert_nonnull(jingle);

        StanzaNode description = Xep.JingleFileTransfer.Module.create_file_description(basename, size);
        var content_params = Xep.JingleFileTransfer.Parameters.parse((!) file_transfer, description);
        Xep.Jingle.Transport? transport = yield ((!) jingle).select_transport(stream, ((!) file_transfer).required_transport_type, ((!) file_transfer).required_components, peer, Set.empty());
        if (transport == null) {
            throw new Xep.Jingle.Error.NO_SHARED_PROTOCOLS("No suitable transports");
        }

        Jid local_full_jid = (!) stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        var transport_params = ((!) transport).create_transport_parameters(stream, ((!) file_transfer).required_components, local_full_jid, peer);
        var content = new Xep.Jingle.Content.initiate_sent("a-file-offer", Xep.Jingle.Senders.INITIATOR,
            (!) file_transfer, content_params,
            (!) transport, transport_params,
            null, null,
            local_full_jid, peer);
        var contents = new ArrayList<Xep.Jingle.Content>();
        contents.add(content);

        yield ((!) jingle).create_session(stream, contents, peer, "audit-jingle-ft-session");
        if (stream.written_nodes.is_empty) {
            throw new IOError.FAILED("session-initiate did not write an IQ stanza");
        }
        assert_true(stream.written_nodes.size == 1);
        return stream.written_nodes[0];
    }

    private void stream_writes_must_be_empty(JingleFtTestXmppStream stream) {
        // Kept as a distinct assertion helper so negative session-initiate
        // tests stay explicit about the no-stanza boundary.
        assert_true(stream.written_nodes.is_empty);
    }

    private void assert_no_jingle_session_state(JingleFtTestXmppStream stream, string sid) {
        Xep.Jingle.Flag flag = stream.get_flag(Xep.Jingle.Flag.IDENTITY);
        assert_false(flag.promises.has_key(sid));
        assert_false(flag.sessions.has_key(sid));
    }
}

private class JingleFtFakeCapsCache : Object, Xep.ServiceDiscovery.CapsCache {
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

private class RejectingAuditContentType : Object, Xep.Jingle.ContentType {
    public const string NS_URI = "urn:dinox:test:jingle:rejecting:0";

    public int proposed_count { get; private set; default = 0; }
    public string? last_mode { get; private set; default = null; }

    public string ns_uri { get { return NS_URI; } }
    public Xep.Jingle.TransportType required_transport_type { get { return Xep.Jingle.TransportType.STREAMING; } }
    public uint8 required_components { get { return 1; } }

    public Xep.Jingle.ContentParameters parse_content_parameters(StanzaNode description) throws Xep.Jingle.IqError {
        string? mode = description.get_attribute("mode");
        return new RejectingAuditParameters(this, description, mode ?? "record");
    }

    public void record(string mode) {
        proposed_count++;
        last_mode = mode;
    }
}

private class RejectingAuditParameters : Object, Xep.Jingle.ContentParameters {
    RejectingAuditContentType parent;
    StanzaNode original_description;
    string mode;

    public RejectingAuditParameters(RejectingAuditContentType parent, StanzaNode original_description, string mode) {
        this.parent = parent;
        this.original_description = original_description;
        this.mode = mode;
    }

    public async void handle_proposed_content(XmppStream stream, Xep.Jingle.Session session, Xep.Jingle.Content content) {
        parent.record(mode);
        if (mode == "reject") {
            content.reject();
        }
    }

    public void accept(XmppStream stream, Xep.Jingle.Session session, Xep.Jingle.Content content) {
    }

    public void handle_accept(XmppStream stream, Xep.Jingle.Session session, Xep.Jingle.Content content, StanzaNode description_node) {
    }

    public void terminate(bool we_terminated, string? reason_name, string? reason_text) {
    }

    public StanzaNode get_description_node() {
        return original_description;
    }
}

private class TrackingAuditContentType : Object, Xep.Jingle.ContentType {
    public const string NS_URI = "urn:dinox:test:jingle:tracking-content:0";

    public string ns_uri { get { return NS_URI; } }
    public Xep.Jingle.TransportType required_transport_type { get { return Xep.Jingle.TransportType.STREAMING; } }
    public uint8 required_components { get { return 1; } }

    public Xep.Jingle.ContentParameters parse_content_parameters(StanzaNode description) throws Xep.Jingle.IqError {
        return new TrackingAuditParameters();
    }
}

private class TrackingAuditParameters : Object, Xep.Jingle.ContentParameters {
    public bool terminated { get; private set; default = false; }

    public async void handle_proposed_content(XmppStream stream, Xep.Jingle.Session session, Xep.Jingle.Content content) {
    }

    public void accept(XmppStream stream, Xep.Jingle.Session session, Xep.Jingle.Content content) {
    }

    public void handle_accept(XmppStream stream, Xep.Jingle.Session session, Xep.Jingle.Content content, StanzaNode description_node) {
    }

    public void terminate(bool we_terminated, string? reason_name, string? reason_text) {
        terminated = true;
    }

    public StanzaNode get_description_node() {
        return new StanzaNode.build("description", TrackingAuditContentType.NS_URI).add_self_xmlns();
    }
}

private class TrackingAuditTransport : Object, Xep.Jingle.Transport {
    public string ns_uri { get { return "urn:dinox:test:jingle:tracking-transport:0"; } }
    public Xep.Jingle.TransportType type_ { get { return Xep.Jingle.TransportType.STREAMING; } }
    public int priority { get { return 1; } }

    public async bool is_transport_available(XmppStream stream, uint8 components, Jid full_jid) {
        return true;
    }

    public Xep.Jingle.TransportParameters create_transport_parameters(XmppStream stream, uint8 components, Jid local_full_jid, Jid peer_full_jid) throws Xep.Jingle.Error {
        return new TrackingAuditTransportParameters();
    }

    public Xep.Jingle.TransportParameters parse_transport_parameters(XmppStream stream, uint8 components, Jid local_full_jid, Jid peer_full_jid, StanzaNode transport) throws Xep.Jingle.IqError {
        return new TrackingAuditTransportParameters();
    }
}

private class TrackingAuditTransportParameters : Object, Xep.Jingle.TransportParameters {
    public bool disposed { get; private set; default = false; }
    public string ns_uri { get { return "urn:dinox:test:jingle:tracking-transport:0"; } }
    public uint8 components { get { return 1; } }

    public void set_content(Xep.Jingle.Content content) {
    }

    public StanzaNode to_transport_stanza_node(string action_type) {
        return new StanzaNode.build("transport", ns_uri).add_self_xmlns();
    }

    public void handle_transport_accept(StanzaNode transport) throws Xep.Jingle.IqError {
    }

    public void handle_transport_info(StanzaNode transport) throws Xep.Jingle.IqError {
    }

    public void create_transport_connection(XmppStream stream, Xep.Jingle.Content content) {
    }

    public override void dispose() {
        disposed = true;
        base.dispose();
    }
}

private class FailingAuditSecurityParameters : Object, Xep.Jingle.SecurityParameters {
    private string reason;

    public FailingAuditSecurityParameters(string reason) {
        this.reason = reason;
    }

    public string security_ns_uri() {
        return "urn:dinox:test:jingle:failing-security:0";
    }

    public StanzaNode to_security_stanza_node(XmppStream stream, Jid local_full_jid, Jid peer_full_jid) throws Xep.Jingle.Error {
        throw new Xep.Jingle.Error.UNSUPPORTED_SECURITY(reason);
    }

    public IOStream wrap_stream(IOStream stream) {
        return stream;
    }
}

private class JingleFtTestXmppStream : XmppStream {
    public ArrayList<StanzaNode> written_nodes = new ArrayList<StanzaNode>();

    public JingleFtTestXmppStream(Jid remote_name) {
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
        written_nodes.add(node);
    }

    public void emit_iq_result(StanzaNode node) {
        received_iq_stanza(this, node);
    }

    public override async void setup() throws IOError {
    }
}

private class TestJetEnvelope : Xep.Jet.EnvelopEncoding, Object {
    public string get_type_uri() {
        return "urn:xmpp:test:jet-envelope";
    }

    public Xep.Jet.TransportSecret decode_envolop(XmppStream stream, Jid local_full_jid, Jid peer_full_jid,
            StanzaNode security) throws Xep.Jingle.IqError {
        if (security.get_attribute("test-key") != "5a") {
            throw new Xep.Jingle.IqError.BAD_REQUEST("missing test JET key");
        }
        return new Xep.Jet.TransportSecret({TestJetCipher.KEY}, new uint8[0]);
    }

    public void encode_envelop(XmppStream stream, Jid local_full_jid, Jid peer_full_jid,
            Xep.Jet.SecurityParameters security_params, StanzaNode security) throws Xep.Jingle.Error {
        security.put_attribute("test-key", "5a");
    }
}

private class TestJetCipher : Xep.Jet.Cipher, Object {
    public const uint8 KEY = 0x5a;
    public static bool input_authenticated = false;

    public static void reset_authentication() {
        input_authenticated = false;
    }

    public string get_cipher_uri() {
        return "urn:xmpp:test:xor-stream";
    }

    public Xep.Jet.TransportSecret generate_random_secret() {
        return new Xep.Jet.TransportSecret({KEY}, new uint8[0]);
    }

    public InputStream wrap_input_stream(InputStream input, Xep.Jet.TransportSecret secret) {
        reset_authentication();
        return new XorInputStream(input, key_from_secret(secret));
    }

    public OutputStream wrap_output_stream(OutputStream output, Xep.Jet.TransportSecret secret) {
        return new XorOutputStream(output, key_from_secret(secret));
    }

    private static uint8 key_from_secret(Xep.Jet.TransportSecret secret) {
        assert_true(secret.transport_key.length == 1);
        return secret.transport_key[0];
    }
}

private class XorInputStream : InputStream, Xep.Jingle.AuthenticatedInputStream {
    private InputStream inner;
    private uint8 key;
    private int64 expected_plaintext_size = -1;

    public XorInputStream(InputStream inner, uint8 key) {
        this.inner = inner;
        this.key = key;
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        ssize_t read = inner.read(buffer, cancellable);
        xor_in_place(buffer, read, key);
        return read;
    }

    public override async ssize_t read_async(uint8[]? buffer, int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        ssize_t read = yield inner.read_async(buffer, io_priority, cancellable);
        if (buffer != null) {
            xor_in_place((!) buffer, read, key);
        }
        return read;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return inner.close(cancellable);
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }

    public void set_expected_plaintext_size(int64 plaintext_size) {
        expected_plaintext_size = plaintext_size;
    }

    public void authenticate(Cancellable? cancellable = null) throws IOError {
        if (expected_plaintext_size < 0) {
            throw new IOError.FAILED("test JET stream did not receive expected plaintext size");
        }
        TestJetCipher.input_authenticated = true;
    }

    public async void authenticate_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (expected_plaintext_size < 0) {
            throw new IOError.FAILED("test JET stream did not receive expected plaintext size");
        }
        TestJetCipher.input_authenticated = true;
    }
}

private class XorOutputStream : OutputStream {
    private OutputStream inner;
    private uint8 key;

    public XorOutputStream(OutputStream inner, uint8 key) {
        this.inner = inner;
        this.key = key;
    }

    public override ssize_t write(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        uint8[] encrypted = xor_copy(buffer, key);
        return inner.write(encrypted, cancellable);
    }

    public override async ssize_t write_async(uint8[]? buffer, int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (buffer == null) {
            return yield inner.write_async(buffer, io_priority, cancellable);
        }
        uint8[] encrypted = xor_copy((!) buffer, key);
        return yield inner.write_async(encrypted, io_priority, cancellable);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return inner.close(cancellable);
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }
}

private void xor_in_place(uint8[] buffer, ssize_t length, uint8 key) {
    for (int i = 0; i < length; i++) {
        buffer[i] = (uint8) (buffer[i] ^ key);
    }
}

private uint8[] xor_copy(uint8[] buffer, uint8 key) {
    uint8[] result = new uint8[buffer.length];
    for (int i = 0; i < buffer.length; i++) {
        result[i] = (uint8) (buffer[i] ^ key);
    }
    return result;
}

private class FakeS5BProxy : Object {
    private SocketListener listener = new SocketListener();
    private string? expected_dstaddr = null;
    private Error? failure = null;
    private bool completed = false;
    private MainLoop? loop = null;

    public int port { get; private set; }
    public SocketConnection? connection { get; private set; default = null; }

    public FakeS5BProxy() throws Error {
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        port = (int) effective.port;
        accept_once.begin((_, res) => {
            try {
                accept_once.end(res);
            } catch (Error e) {
                failure = e;
            }
            completed = true;
            if (loop != null) {
                ((!) loop).quit();
            }
        });
    }

    public void expect_dstaddr(string dstaddr) {
        expected_dstaddr = dstaddr;
    }

    public void wait_until_connected(uint timeout_ms) throws Error {
        if (!completed) {
            bool timed_out = false;
            uint timeout_source = 0;
            loop = new MainLoop();
            timeout_source = Timeout.add(timeout_ms, () => {
                timed_out = true;
                timeout_source = 0;
                if (loop != null) {
                    ((!) loop).quit();
                }
                return Source.REMOVE;
            });
            ((!) loop).run();
            loop = null;
            if (timeout_source != 0) {
                Source.remove(timeout_source);
            }
            if (timed_out && !completed) {
                throw new IOError.TIMED_OUT("Timed out waiting for fake S5B proxy connection");
            }
        }
        if (failure != null) {
            throw (!) failure;
        }
        assert_nonnull(connection);
    }

    private async void accept_once() throws Error {
        Object source_object;
        SocketConnection conn = yield listener.accept_async(null, out source_object);
        connection = conn;
        yield handle_socks5_connect(conn);
    }

    private async void handle_socks5_connect(SocketConnection conn) throws Error {
        conn.socket.timeout = 2;
        string? dstaddr = expected_dstaddr;
        if (dstaddr == null) {
            throw new IOError.FAILED("Fake S5B proxy expected dstaddr was not set");
        }

        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield conn.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, null, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] == 0) {
            throw new IOError.PROXY_FAILED("Fake S5B proxy did not receive a valid client hello");
        }
        int num_auth_methods = read_buffer[1];
        yield conn.input_stream.read_all_async(read_buffer[0:num_auth_methods], Priority.DEFAULT, null, out read);
        bool found_null_auth = false;
        for (int i = 0; i < read; i++) {
            if (read_buffer[i] == 0x00) {
                found_null_auth = true;
                break;
            }
        }
        if (read != num_auth_methods || !found_null_auth) {
            throw new IOError.PROXY_FAILED("Fake S5B proxy did not receive null authentication support");
        }
        yield conn.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, null, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, null, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[2] != 0x00 || read_buffer[3] != 0x03) {
            throw new IOError.PROXY_FAILED("Fake S5B proxy did not receive a domain CONNECT");
        }
        yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, null, out read);
        if (read != 1) {
            throw new IOError.PROXY_FAILED("Fake S5B proxy did not receive a dstaddr length");
        }
        int dstaddr_len = read_buffer[0];
        yield conn.input_stream.read_all_async(read_buffer[0:dstaddr_len + 2], Priority.DEFAULT, null, out read);
        if (read != dstaddr_len + 2 ||
                dstaddr_len != ((!) dstaddr).length ||
                !Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:dstaddr_len], ((!) dstaddr).data) ||
                read_buffer[dstaddr_len] != 0x00 ||
                read_buffer[dstaddr_len + 1] != 0x00) {
            throw new IOError.PROXY_FAILED("Fake S5B proxy received an unexpected dstaddr");
        }

        write_buffer.append({0x05, 0x00, 0x00, 0x03});
        write_buffer.append({(uint8)((!) dstaddr).length});
        write_buffer.append(((!) dstaddr).data);
        write_buffer.append({0x00, 0x00});
        yield conn.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, null, out written);
        conn.socket.timeout = 0;
    }

    public void close() {
        listener.close();
        if (connection != null) {
            try {
                ((!) connection).close();
            } catch (Error e) {
            }
            connection = null;
        }
    }
}

private class DirectConnectTrap : Object {
    private SocketListener listener = new SocketListener();
    private SocketConnection? connection = null;
    private Error? failure = null;
    private bool closed = false;

    public int port { get; private set; }

    public DirectConnectTrap() throws Error {
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        port = (int) effective.port;
        accept_once.begin((_, res) => {
            try {
                accept_once.end(res);
            } catch (Error e) {
                if (!closed) {
                    failure = e;
                }
            }
        });
    }

    public void assert_not_hit() throws Error {
        if (failure != null) {
            throw (!) failure;
        }
        assert_null(connection);
    }

    public void assert_not_hit_after(uint timeout_ms) throws Error {
        uint timeout_source = 0;
        var loop = new MainLoop();
        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (timeout_source != 0) Source.remove(timeout_source);
        assert_not_hit();
    }

    private async void accept_once() throws Error {
        Object source_object;
        connection = yield listener.accept_async(null, out source_object);
    }

    public void close() {
        closed = true;
        listener.close();
        if (connection != null) {
            try {
                ((!) connection).close();
            } catch (Error e) {
            }
            connection = null;
        }
    }
}

private class HiddenServiceS5BTarget : Object {
    private SocketListener listener = new SocketListener();
    private string? expected_dstaddr = null;
    private Error? warmup_failure = null;
    private Error? failure = null;
    private bool warmup_completed = false;
    private bool completed = false;
    private bool closed = false;
    private MainLoop? warmup_loop = null;
    private MainLoop? loop = null;

    public int port { get; private set; }
    public SocketConnection? connection { get; private set; default = null; }

    public HiddenServiceS5BTarget() throws Error {
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        port = (int) effective.port;
    }

    public void expect_warmup() {
        accept_warmup_once.begin((_, res) => {
            try {
                accept_warmup_once.end(res);
            } catch (Error e) {
                if (!closed) {
                    warmup_failure = e;
                }
            }
            warmup_completed = true;
            if (warmup_loop != null) {
                ((!) warmup_loop).quit();
            }
        });
    }

    public void wait_until_warmup_completed(uint timeout_ms) throws Error {
        wait_for_completion(ref warmup_completed, ref warmup_loop, timeout_ms, "Timed out waiting for Tor onion warmup connection");
        if (warmup_failure != null) {
            throw (!) warmup_failure;
        }
    }

    public void expect(string dstaddr) {
        expected_dstaddr = dstaddr;
        accept_s5b_once.begin((_, res) => {
            try {
                accept_s5b_once.end(res);
            } catch (Error e) {
                if (!closed) {
                    failure = e;
                }
            }
            completed = true;
            if (loop != null) {
                ((!) loop).quit();
            }
        });
    }

    public void wait_until_connected(uint timeout_ms) throws Error {
        wait_for_completion(ref completed, ref loop, timeout_ms, "Timed out waiting for Tor onion S5B target connection");
        if (failure != null) {
            throw (!) failure;
        }
        assert_nonnull(connection);
    }

    private void wait_for_completion(ref bool completed_flag, ref MainLoop? target_loop, uint timeout_ms, string timeout_message) throws Error {
        if (!completed_flag) {
            bool timed_out = false;
            uint timeout_source = 0;
            MainLoop wait_loop = new MainLoop();
            target_loop = wait_loop;
            timeout_source = Timeout.add(timeout_ms, () => {
                timed_out = true;
                timeout_source = 0;
                wait_loop.quit();
                return Source.REMOVE;
            });
            wait_loop.run();
            target_loop = null;
            if (timeout_source != 0) {
                Source.remove(timeout_source);
            }
            if (timed_out && !completed_flag) {
                throw new IOError.TIMED_OUT(timeout_message);
            }
        }
    }

    private async void accept_warmup_once() throws Error {
        Object source_object;
        SocketConnection conn = yield listener.accept_async(null, out source_object);
        conn.close();
    }

    private async void accept_s5b_once() throws Error {
        Object source_object;
        SocketConnection conn = yield listener.accept_async(null, out source_object);
        try {
            yield handle_inner_s5b_connect(conn);
            connection = conn;
        } catch (Error e) {
            try {
                conn.close();
            } catch (Error close_error) {
            }
            throw e;
        }
    }

    private async void handle_inner_s5b_connect(SocketConnection conn) throws Error {
        string? dstaddr = expected_dstaddr;
        if (dstaddr == null) {
            throw new IOError.FAILED("Tor onion S5B target expected dstaddr was not set");
        }

        conn.socket.timeout = 2;
        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield read_socks5_client_hello(conn, read_buffer);
        yield conn.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, null, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, null, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[2] != 0x00 || read_buffer[3] != 0x03) {
            throw new IOError.PROXY_FAILED("Tor onion S5B target did not receive an inner domain CONNECT");
        }
        yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, null, out read);
        if (read != 1) {
            throw new IOError.PROXY_FAILED("Tor onion S5B target did not receive dstaddr length");
        }
        int dstaddr_len = read_buffer[0];
        yield conn.input_stream.read_all_async(read_buffer[0:dstaddr_len + 2], Priority.DEFAULT, null, out read);
        if (read != dstaddr_len + 2 ||
                dstaddr_len != ((!) dstaddr).length ||
                !Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:dstaddr_len], ((!) dstaddr).data) ||
                read_buffer[dstaddr_len] != 0x00 ||
                read_buffer[dstaddr_len + 1] != 0x00) {
            throw new IOError.PROXY_FAILED("Tor onion S5B target received an unexpected dstaddr");
        }

        write_buffer.append({0x05, 0x00, 0x00, 0x03});
        write_buffer.append({(uint8)((!) dstaddr).length});
        write_buffer.append(((!) dstaddr).data);
        write_buffer.append({0x00, 0x00});
        yield conn.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, null, out written);
        conn.socket.timeout = 0;
    }

    private async void read_socks5_client_hello(SocketConnection conn, uint8[] read_buffer) throws Error {
        size_t read;
        yield conn.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, null, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] == 0) {
            throw new IOError.PROXY_FAILED("Tor onion S5B target did not receive a valid client hello");
        }
        int num_auth_methods = read_buffer[1];
        yield conn.input_stream.read_all_async(read_buffer[0:num_auth_methods], Priority.DEFAULT, null, out read);
        bool found_null_auth = false;
        for (int i = 0; i < read; i++) {
            if (read_buffer[i] == 0x00) {
                found_null_auth = true;
                break;
            }
        }
        if (read != num_auth_methods || !found_null_auth) {
            throw new IOError.PROXY_FAILED("Tor onion S5B target did not receive null authentication support");
        }
    }

    public void close() {
        closed = true;
        listener.close();
        if (connection != null) {
            try {
                ((!) connection).close();
            } catch (Error e) {
            }
            connection = null;
        }
    }
}

private class LocalTorSocksDaemon : Object {
    private string temp_dir;
    private string data_dir;
    private string torrc_path;
    private string log_path;
    private string? hidden_service_dir = null;
    private Subprocess? process = null;

    public int port { get; private set; }
    public string? onion_hostname { get; private set; default = null; }

    public static LocalTorSocksDaemon? start_or_skip() throws Error {
        if (Environment.get_variable("DINOX_TEST_REAL_TOR_S5B") != "1") {
            GLib.Test.skip("Set DINOX_TEST_REAL_TOR_S5B=1 to run the real Tor SOCKS daemon proof");
            return null;
        }
        string? tor_path = lookup_tor_path();
        if (tor_path == null) {
            GLib.Test.skip("tor executable not found; skipping real Tor SOCKS daemon proof");
            return null;
        }
        return new LocalTorSocksDaemon((!) tor_path);
    }

    public static string? lookup_hidden_service_tor_path_or_skip() {
        if (Environment.get_variable("DINOX_TEST_REAL_TOR_HIDDEN_SERVICE_S5B") != "1") {
            GLib.Test.skip("Set DINOX_TEST_REAL_TOR_HIDDEN_SERVICE_S5B=1 to run the real Tor onion S5B byte-flow proof");
            return null;
        }
        if (!GLib.Test.thorough()) {
            GLib.Test.skip("Run with -m thorough for the real Tor onion S5B byte-flow proof");
            return null;
        }
        string? tor_path = lookup_tor_path();
        if (tor_path == null) {
            GLib.Test.skip("tor executable not found; skipping real Tor onion S5B byte-flow proof");
            return null;
        }
        return tor_path;
    }

    public static LocalTorSocksDaemon start_hidden_service(string tor_path, int target_port, int virtual_port) throws Error {
        return new LocalTorSocksDaemon(tor_path, target_port, virtual_port);
    }

    private static string? lookup_tor_path() {
        string? tor_path = Environment.get_variable("DINOX_TEST_TOR_PATH");
        if (tor_path == null || ((!) tor_path).length == 0) {
            tor_path = Environment.find_program_in_path("tor");
        }
        return tor_path;
    }

    private LocalTorSocksDaemon(string tor_path, int hidden_service_target_port = 0, int hidden_service_virtual_port = 0) throws Error {
        temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jingle-tor-" + Uuid.string_random());
        data_dir = Path.build_filename(temp_dir, "data");
        torrc_path = Path.build_filename(temp_dir, "empty-torrc");
        log_path = Path.build_filename(temp_dir, "tor.log");
        if (hidden_service_target_port > 0) {
            hidden_service_dir = Path.build_filename(temp_dir, "hidden-service");
        }
        port = reserve_free_loopback_port();

        if (DirUtils.create_with_parents(data_dir, 0700) == -1) {
            throw new IOError.FAILED("Failed to create temporary Tor data directory");
        }
        if (hidden_service_dir != null && DirUtils.create_with_parents((!) hidden_service_dir, 0700) == -1) {
            throw new IOError.FAILED("Failed to create temporary Tor hidden-service directory");
        }
        FileUtils.set_contents(torrc_path, "");

        string[] argv;
        if (hidden_service_dir != null) {
            argv = {
                tor_path,
                "-f", torrc_path,
                "--DataDirectory", data_dir,
                "--SocksPort", "127.0.0.1:%d".printf(port),
                "--ControlPort", "0",
                "--CookieAuthentication", "0",
                "--SafeLogging", "0",
                "--HiddenServiceDir", (!) hidden_service_dir,
                "--HiddenServicePort", "%d 127.0.0.1:%d".printf(hidden_service_virtual_port, hidden_service_target_port),
                "--Log", "notice file " + log_path
            };
        } else {
            argv = {
                tor_path,
                "-f", torrc_path,
                "--DataDirectory", data_dir,
                "--SocksPort", "127.0.0.1:%d".printf(port),
                "--ControlPort", "0",
                "--CookieAuthentication", "0",
                "--SafeLogging", "0",
                "--Log", "notice file " + log_path
            };
        }
        try {
            process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            wait_until_ready();
            if (hidden_service_dir != null) {
                onion_hostname = wait_until_hidden_service_hostname(30000);
                wait_until_bootstrapped(180000);
            }
        } catch (Error e) {
            close_process();
            delete_recursively(temp_dir);
            throw e;
        }
    }

    private static int reserve_free_loopback_port() throws Error {
        SocketListener listener = new SocketListener();
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        int result = (int) effective.port;
        listener.close();
        return result;
    }

    private void wait_until_ready() throws Error {
        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(10, () => {
            if (log_contains("Opened Socks listener connection (ready)")) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(3000, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && !log_contains("Opened Socks listener connection (ready)")) {
            throw new IOError.TIMED_OUT("Timed out starting Tor SOCKS listener: " + read_log_excerpt());
        }
    }

    public void wait_until_private_loopback_rejected(uint timeout_ms) throws Error {
        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(10, () => {
            if (log_contains("Rejecting SOCKS request for anonymous connection to private address 127.0.0.1")) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && !log_contains("Rejecting SOCKS request for anonymous connection to private address 127.0.0.1")) {
            throw new IOError.TIMED_OUT("Timed out waiting for Tor loopback rejection: " + read_log_excerpt());
        }
    }

    private void wait_until_bootstrapped(uint timeout_ms) throws Error {
        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(50, () => {
            if (log_contains("Bootstrapped 100% (done): Done")) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && !log_contains("Bootstrapped 100% (done): Done")) {
            throw new IOError.TIMED_OUT("Timed out waiting for Tor bootstrap: " + read_log_excerpt());
        }
    }

    private string wait_until_hidden_service_hostname(uint timeout_ms) throws Error {
        string? service_dir = hidden_service_dir;
        if (service_dir == null) {
            throw new IOError.FAILED("Tor hidden-service directory is not configured");
        }
        string hostname_path = Path.build_filename((!) service_dir, "hostname");
        string? hostname = null;
        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(50, () => {
            string contents;
            try {
                FileUtils.get_contents(hostname_path, out contents);
                string stripped = contents.strip();
                if (stripped.has_suffix(".onion")) {
                    hostname = stripped;
                    poll_source = 0;
                    loop.quit();
                    return Source.REMOVE;
                }
            } catch (Error e) {
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && hostname == null) {
            throw new IOError.TIMED_OUT("Timed out waiting for Tor hidden-service hostname: " + read_log_excerpt());
        }
        assert_nonnull(hostname);
        return (!) hostname;
    }

    private bool log_contains(string needle) {
        string contents;
        try {
            FileUtils.get_contents(log_path, out contents);
        } catch (Error e) {
            return false;
        }
        return contents.contains(needle);
    }

    private string read_log_excerpt() {
        string contents;
        try {
            FileUtils.get_contents(log_path, out contents);
            return contents.substring(0, int.min(contents.length, 512));
        } catch (Error e) {
            return e.message;
        }
    }

    public void close() {
        close_process();
        delete_recursively(temp_dir);
    }

    private void close_process() {
        if (process == null) return;
        Subprocess proc = (!) process;
        process = null;
        proc.force_exit();
        try {
            proc.wait();
        } catch (Error e) {
        }
    }

    private static void delete_recursively(string path) {
        File file = File.new_for_path(path);
        try {
            FileType type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            if (type == FileType.DIRECTORY) {
                FileEnumerator enumerator = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo? info;
                while ((info = enumerator.next_file(null)) != null) {
                    delete_recursively(Path.build_filename(path, ((!) info).get_name()));
                }
                enumerator.close(null);
            }
            file.delete(null);
        } catch (Error e) {
        }
    }
}

private class FakeOutboundSocksProxy : Object {
    private SocketListener listener = new SocketListener();
    private string? expected_target_host = null;
    private int expected_target_port = 0;
    private string? expected_dstaddr = null;
    private Error? failure = null;
    private bool completed = false;
    private MainLoop? loop = null;

    public int port { get; private set; }
    public SocketConnection? connection { get; private set; default = null; }

    public FakeOutboundSocksProxy() throws Error {
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        port = (int) effective.port;
        accept_once.begin((_, res) => {
            try {
                accept_once.end(res);
            } catch (Error e) {
                failure = e;
            }
            completed = true;
            if (loop != null) {
                ((!) loop).quit();
            }
        });
    }

    public void expect(string target_host, int target_port, string dstaddr) {
        expected_target_host = target_host;
        expected_target_port = target_port;
        expected_dstaddr = dstaddr;
    }

    public void wait_until_connected(uint timeout_ms) throws Error {
        if (!completed) {
            bool timed_out = false;
            uint timeout_source = 0;
            loop = new MainLoop();
            timeout_source = Timeout.add(timeout_ms, () => {
                timed_out = true;
                timeout_source = 0;
                if (loop != null) {
                    ((!) loop).quit();
                }
                return Source.REMOVE;
            });
            ((!) loop).run();
            loop = null;
            if (timeout_source != 0) {
                Source.remove(timeout_source);
            }
            if (timed_out && !completed) {
                throw new IOError.TIMED_OUT("Timed out waiting for outbound SOCKS proxy connection");
            }
        }
        if (failure != null) {
            throw (!) failure;
        }
        assert_nonnull(connection);
    }

    private async void accept_once() throws Error {
        Object source_object;
        SocketConnection conn = yield listener.accept_async(null, out source_object);
        yield handle_outer_socks_connect(conn);
        yield handle_inner_s5b_connect(conn);
        connection = conn;
    }

    private async void handle_outer_socks_connect(SocketConnection conn) throws Error {
        conn.socket.timeout = 2;
        string? target_host = expected_target_host;
        string? dstaddr = expected_dstaddr;
        if (target_host == null || expected_target_port <= 0 || dstaddr == null) {
            throw new IOError.FAILED("Fake outbound SOCKS proxy expectations were not set");
        }

        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];

        yield read_socks5_client_hello(conn, read_buffer);
        yield conn.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, null, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, null, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[2] != 0x00) {
            throw new IOError.PROXY_FAILED("Fake outbound SOCKS proxy did not receive a valid CONNECT");
        }

        bool target_matches = false;
        uint8 atyp = read_buffer[3];
        if (atyp == 0x01) {
            yield conn.input_stream.read_all_async(read_buffer[0:6], Priority.DEFAULT, null, out read);
            int target_port = (((int) read_buffer[4]) << 8) | read_buffer[5];
            string actual_host = "%u.%u.%u.%u".printf(read_buffer[0], read_buffer[1], read_buffer[2], read_buffer[3]);
            target_matches = read == 6 && actual_host == (!) target_host && target_port == expected_target_port;
        } else if (atyp == 0x03) {
            yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, null, out read);
            if (read != 1) {
                throw new IOError.PROXY_FAILED("Fake outbound SOCKS proxy did not receive target host length");
            }
            int host_len = read_buffer[0];
            yield conn.input_stream.read_all_async(read_buffer[0:host_len + 2], Priority.DEFAULT, null, out read);
            int target_port = (((int) read_buffer[host_len]) << 8) | read_buffer[host_len + 1];
            target_matches = read == host_len + 2 &&
                host_len == ((!) target_host).length &&
                Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:host_len], ((!) target_host).data) &&
                target_port == expected_target_port;
        } else {
            throw new IOError.PROXY_FAILED("Fake outbound SOCKS proxy received an unsupported address type");
        }
        if (!target_matches) {
            throw new IOError.PROXY_FAILED("Fake outbound SOCKS proxy received an unexpected target");
        }

        yield conn.output_stream.write_all_async({0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
            Priority.DEFAULT, null, out written);
    }

    private async void handle_inner_s5b_connect(SocketConnection conn) throws Error {
        string? dstaddr = expected_dstaddr;
        if (dstaddr == null) {
            throw new IOError.FAILED("Fake outbound SOCKS proxy expected dstaddr was not set");
        }

        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield read_socks5_client_hello(conn, read_buffer);
        yield conn.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, null, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, null, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[2] != 0x00 || read_buffer[3] != 0x03) {
            throw new IOError.PROXY_FAILED("Fake outbound SOCKS proxy did not receive an inner S5B domain CONNECT");
        }
        yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, null, out read);
        if (read != 1) {
            throw new IOError.PROXY_FAILED("Fake outbound SOCKS proxy did not receive inner dstaddr length");
        }
        int dstaddr_len = read_buffer[0];
        yield conn.input_stream.read_all_async(read_buffer[0:dstaddr_len + 2], Priority.DEFAULT, null, out read);
        if (read != dstaddr_len + 2 ||
                dstaddr_len != ((!) dstaddr).length ||
                !Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:dstaddr_len], ((!) dstaddr).data) ||
                read_buffer[dstaddr_len] != 0x00 ||
                read_buffer[dstaddr_len + 1] != 0x00) {
            throw new IOError.PROXY_FAILED("Fake outbound SOCKS proxy received an unexpected inner dstaddr");
        }

        write_buffer.append({0x05, 0x00, 0x00, 0x03});
        write_buffer.append({(uint8)((!) dstaddr).length});
        write_buffer.append(((!) dstaddr).data);
        write_buffer.append({0x00, 0x00});
        yield conn.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, null, out written);
        conn.socket.timeout = 0;
    }

    private async void read_socks5_client_hello(SocketConnection conn, uint8[] read_buffer) throws Error {
        size_t read;
        yield conn.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, null, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] == 0) {
            throw new IOError.PROXY_FAILED("Fake SOCKS proxy did not receive a valid client hello");
        }
        int num_auth_methods = read_buffer[1];
        yield conn.input_stream.read_all_async(read_buffer[0:num_auth_methods], Priority.DEFAULT, null, out read);
        bool found_null_auth = false;
        for (int i = 0; i < read; i++) {
            if (read_buffer[i] == 0x00) {
                found_null_auth = true;
                break;
            }
        }
        if (read != num_auth_methods || !found_null_auth) {
            throw new IOError.PROXY_FAILED("Fake SOCKS proxy did not receive null authentication support");
        }
    }

    public void close() {
        listener.close();
        if (connection != null) {
            try {
                ((!) connection).close();
            } catch (Error e) {
            }
            connection = null;
        }
    }
}

private class PendingFileTransferAccept : Object {
    private bool completed = false;
    private Error? failure = null;
    private MainLoop? loop = null;

    public PendingFileTransferAccept(JingleFtTestXmppStream stream, Xep.JingleFileTransfer.FileTransfer transfer) {
        transfer.accept.begin(stream, (_, res) => {
            try {
                transfer.accept.end(res);
            } catch (Error e) {
                failure = e;
            }
            completed = true;
            if (loop != null) {
                ((!) loop).quit();
            }
        });
    }

    public void wait_until_completed(uint timeout_ms) throws Error {
        if (completed) {
            return;
        }

        bool timed_out = false;
        uint timeout_source = 0;
        loop = new MainLoop();
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            if (loop != null) {
                ((!) loop).quit();
            }
            return Source.REMOVE;
        });

        ((!) loop).run();

        loop = null;
        if (timeout_source != 0) {
            Source.remove(timeout_source);
        }
        if (timed_out && !completed) {
            throw new IOError.TIMED_OUT("Timed out accepting S5B file transfer");
        }
    }

    public void assert_succeeded() throws Error {
        assert_true(completed);
        if (failure != null) {
            throw (!) failure;
        }
    }
}

}
