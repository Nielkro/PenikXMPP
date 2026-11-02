namespace Xmpp.Test {

/**
 * Security audit tests for XEP-0363 (HTTP File Upload).
 *
 * HTTP File Upload allows clients to request upload/download URLs from the
 * server. Security concerns:
 * - Server may return non-HTTPS URLs (downgrade attack)
 * - Server may return malformed URLs
 * - Server may inject malicious custom headers
 * - Max file size parsing from disco#info forms
 * - Slot response parsing with missing/empty attributes
 *
 * DinoX rejects non-HTTPS URLs and only allows Authorization, Cookie and
 * Expires headers through HttpFileUpload.Module.parse_slot_result().
 *
 * References:
 *   - XEP-0363 §4      Requesting a slot
 *   - XEP-0363 §5.1    Slot response
 *   - XEP-0363 §7      Security considerations
 */
class HttpUploadAudit : Gee.TestCase {

    private const string NS_0 = "urn:xmpp:http:upload:0";
    private const string NS_LEGACY = "urn:xmpp:http:upload";
    private const string NS_DISCO_INFO = "http://jabber.org/protocol/disco#info";
    private const string NS_DATA_FORMS = "jabber:x:data";

    public HttpUploadAudit() {
        base("HttpUploadAudit");

        // --- Slot response parsing ---
        add_test("XEP0363_slot_response_v0_url_attributes", test_slot_response_v0_url_attrs);
        add_test("XEP0363_slot_response_v0_url_content", test_slot_response_v0_url_content);
        add_test("XEP0363_slot_response_missing_get_url", test_slot_missing_get);
        add_test("XEP0363_slot_response_missing_put_url", test_slot_missing_put);
        add_test("XEP0363_slot_response_empty_urls", test_slot_empty_urls);

        // --- HTTPS enforcement (CRITICAL security) ---
        add_test("XEP0363_https_urls_accepted", test_https_accepted);
        add_test("XEP0363_https_token_port_ipv6_urls_accepted", test_https_token_port_ipv6_accepted);
        add_test("XEP0363_http_url_rejected", test_http_rejected);
        add_test("XEP0363_ftp_url_rejected", test_ftp_rejected);
        add_test("XEP0363_javascript_url_rejected", test_javascript_rejected);
        add_test("XEP0363_data_url_rejected", test_data_url_rejected);
        add_test("XEP0363_empty_url_rejected", test_empty_url_rejected);
        add_test("XEP0363_get_url_without_authority_rejected", test_get_without_authority_rejected);
        add_test("XEP0363_put_url_without_authority_rejected", test_put_without_authority_rejected);
        add_test("XEP0363_url_with_whitespace_host_rejected", test_whitespace_host_rejected);
        add_test("XEP0363_url_with_encoded_whitespace_host_rejected", test_encoded_whitespace_host_rejected);
        add_test("XEP0363_url_with_encoded_host_delimiter_rejected", test_encoded_host_delimiter_rejected);
        add_test("XEP0363_url_with_backslash_host_rejected", test_backslash_host_rejected);
        add_test("XEP0363_url_with_libsoup_incompatible_host_rejected", test_libsoup_incompatible_host_rejected);

        // --- Header filtering (security) ---
        add_test("XEP0363_allowed_headers_authorization", test_header_authorization);
        add_test("XEP0363_allowed_headers_cookie", test_header_cookie);
        add_test("XEP0363_allowed_headers_expires", test_header_expires);
        add_test("XEP0363_disallowed_header_host", test_header_host_denied);
        add_test("XEP0363_disallowed_header_xforwarded", test_header_xforwarded_denied);
        add_test("XEP0363_header_crlf_injection", test_header_crlf_injection);
        add_test("XEP0363_header_oversized", test_header_oversized);

        // --- request_slot() async IQ boundary ---
        add_async_test("XEP0363_request_slot_v0_sends_iq_and_parses_result", test_request_slot_v0_sends_iq_and_parses_result);
        add_async_test("XEP0363_request_slot_legacy_sends_iq_and_parses_result", test_request_slot_legacy_sends_iq_and_parses_result);
        add_async_test("XEP0363_request_slot_non_https_result_fails", test_request_slot_non_https_result_fails);
        add_async_test("XEP0363_request_slot_cancel_resumes_without_response", test_request_slot_cancel_resumes_without_response);
        add_async_test("XEP0363_request_slot_stream_detach_resumes_without_response", test_request_slot_stream_detach_resumes_without_response);

        // --- Max file size parsing ---
        add_test("XEP0363_max_file_size_normal", test_max_file_size_normal);
        add_test("XEP0363_max_file_size_missing", test_max_file_size_missing);
        add_test("XEP0363_max_file_size_zero", test_max_file_size_zero);
        add_test("XEP0363_max_file_size_negative", test_max_file_size_negative);
        add_test("XEP0363_max_file_size_non_numeric", test_max_file_size_non_numeric);

        // --- Flag ---
        add_test("XEP0363_flag_stores_jid_and_version", test_flag);
    }

    // ========== Slot response parsing ==========

    private void test_slot_response_v0_url_attrs() {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get/file123", "https://upload.example.com/put/file123");
        assert_slot_urls(slot, NS_0, "https://upload.example.com/get/file123", "https://upload.example.com/put/file123");
    }

    private void test_slot_response_v0_url_content() {
        var slot = new StanzaNode.build("slot", NS_LEGACY).add_self_xmlns();
        var get_node = new StanzaNode.build("get", NS_LEGACY)
            .put_node(new StanzaNode.text("https://upload.example.com/get/file123"));
        var put_node = new StanzaNode.build("put", NS_LEGACY)
            .put_node(new StanzaNode.text("https://upload.example.com/put/file123"));
        slot.put_node(get_node);
        slot.put_node(put_node);

        assert_slot_urls(slot, NS_LEGACY, "https://upload.example.com/get/file123", "https://upload.example.com/put/file123");
    }

    private void test_slot_missing_get() {
        var slot = build_slot_with_url_attributes(NS_0, null, "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_slot_missing_put() {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get", null);
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_slot_empty_urls() {
        var slot = build_slot_with_url_attributes(NS_0, "", "");
        assert_slot_parse_fails(slot, NS_0);
    }

    // ========== HTTPS enforcement ==========

    private void test_https_accepted() {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get", "https://upload.example.com/put");
        assert_slot_urls(slot, NS_0, "https://upload.example.com/get", "https://upload.example.com/put");
    }

    private void test_https_token_port_ipv6_accepted() {
        const string get_url = "https://upload.example.com:5443/get/file.bin?token=a%2Fb&expires=42";
        const string put_url = "https://[2001:db8::1]:7443/put/file.bin?signature=abc%2Bdef";
        var slot = build_slot_with_url_attributes(NS_0, get_url, put_url);
        assert_slot_urls(slot, NS_0, get_url, put_url);
    }

    private void test_http_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "http://upload.example.com/get", "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_ftp_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get", "ftp://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_javascript_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "javascript:alert('xss')", "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_data_url_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get", "data:text/html,<script>alert(1)</script>");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_empty_url_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "", "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_get_without_authority_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "https:///get", "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_put_without_authority_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get", "https:///put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_whitespace_host_rejected() {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get", "https://upload example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_encoded_whitespace_host_rejected() {
        var slot = build_slot_with_url_attributes(NS_0,
            "https://upload%20host.example.com/get",
            "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);

        slot = build_slot_with_url_attributes(NS_0,
            "https://upload.example.com/get",
            "https://upload%09host.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_encoded_host_delimiter_rejected() {
        var slot = build_slot_with_url_attributes(NS_0,
            "https://upload%2Fhost.example.com/get",
            "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_backslash_host_rejected() {
        var slot = build_slot_with_url_attributes(NS_0,
            "https://good.test\\evil/get",
            "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);

        slot = build_slot_with_url_attributes(NS_0,
            "https://good.test\\@evil.test/get",
            "https://upload.example.com/put");
        assert_slot_parse_fails(slot, NS_0);
    }

    private void test_libsoup_incompatible_host_rejected() {
        string[] invalid_get_urls = {
            "https://good|evil.test/get",
            "https://good^evil.test/get",
            "https://good%3Aevil.test/get",
            "https://good%3Cevil.test/get",
            "https://good%3Eevil.test/get"
        };
        foreach (string url in invalid_get_urls) {
            var slot = build_slot_with_url_attributes(NS_0, url,
                "https://upload.example.com/put");
            assert_slot_parse_fails(slot, NS_0);
        }
    }

    // ========== Header filtering ==========

    private void test_header_authorization() {
        assert_parsed_header("Authorization", "Bearer token", "Bearer token");
    }

    private void test_header_cookie() {
        assert_parsed_header("Cookie", "session=abc", "session=abc");
    }

    private void test_header_expires() {
        assert_parsed_header("Expires", "Wed, 21 Oct 2026 07:28:00 GMT", "Wed, 21 Oct 2026 07:28:00 GMT");
    }

    private void test_header_host_denied() {
        assert_header_dropped("Host", "evil.example.com");
    }

    private void test_header_xforwarded_denied() {
        assert_header_dropped("X-Forwarded-For", "127.0.0.1");
    }

    private void test_header_crlf_injection() {
        assert_parsed_header("Authorization", "Bearer token\r\nHost: evil.com", "Bearer tokenHost: evil.com");
    }

    private void test_header_oversized() {
        var sb = new GLib.StringBuilder();
        for (int i = 0; i < 9000; i++) sb.append("A");
        assert_header_dropped("Authorization", sb.str);
    }

    // ========== request_slot() async IQ boundary ==========

    private void test_request_slot_v0_sends_iq_and_parses_result(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_request_slot_stream(NS_0);
            var module = new Xep.HttpFileUpload.Module();

            module.request_slot.begin(stream, "photo.jpg", 1234, "image/jpeg", (_, res) => {
                try {
                    var result = module.request_slot.end(res);
                    fail_if_not_eq_str("https://upload.example.test/get/photo.jpg", result.url_get);
                    fail_if_not_eq_str("https://upload.example.test/put/photo.jpg", result.url_put);
                    fail_if_not_eq_str("Bearer tokenHost: bad.example", result.headers["Authorization"]);
                    fail_if(result.headers.has_key("Host"), "Host header must be filtered from request_slot() results");
                } catch (Error e) {
                    fail_if_reached(@"request_slot should parse v0 slot result: $(e.message)");
                }
                cb();
            });

            respond_when_written(stream, (outgoing) => {
                assert_v0_request_iq(outgoing, "photo.jpg", "1234", "image/jpeg");
                StanzaNode result_iq = build_slot_result_for_request(
                    outgoing,
                    NS_0,
                    "https://upload.example.test/get/photo.jpg",
                    "https://upload.example.test/put/photo.jpg",
                    true
                );
                append_slot_header(result_iq, NS_0, "Authorization", "Bearer token\r\nHost: bad.example");
                append_slot_header(result_iq, NS_0, "Host", "bad.example");
                stream.emit_iq_result(result_iq);
            });
        } catch (Error e) {
            fail_if_reached(@"request_slot test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_request_slot_legacy_sends_iq_and_parses_result(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_request_slot_stream(NS_LEGACY);
            var module = new Xep.HttpFileUpload.Module();

            module.request_slot.begin(stream, "archive.zip", 4096, "application/zip", (_, res) => {
                try {
                    var result = module.request_slot.end(res);
                    fail_if_not_eq_str("https://upload.example.test/get/archive.zip", result.url_get);
                    fail_if_not_eq_str("https://upload.example.test/put/archive.zip", result.url_put);
                } catch (Error e) {
                    fail_if_reached(@"request_slot should parse legacy slot result: $(e.message)");
                }
                cb();
            });

            respond_when_written(stream, (outgoing) => {
                assert_legacy_request_iq(outgoing, "archive.zip", "4096", "application/zip");
                stream.emit_iq_result(build_slot_result_for_request(
                    outgoing,
                    NS_LEGACY,
                    "https://upload.example.test/get/archive.zip",
                    "https://upload.example.test/put/archive.zip",
                    false
                ));
            });
        } catch (Error e) {
            fail_if_reached(@"legacy request_slot test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_request_slot_non_https_result_fails(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_request_slot_stream(NS_0);
            var module = new Xep.HttpFileUpload.Module();

            module.request_slot.begin(stream, "plain.txt", 12, "text/plain", (_, res) => {
                try {
                    var result = module.request_slot.end(res);
                    fail_if_reached(@"request_slot should reject non-HTTPS URL but parsed $(result.url_get)");
                } catch (Xep.HttpFileUpload.HttpFileTransferError e) {
                    // Expected.
                }
                cb();
            });

            respond_when_written(stream, (outgoing) => {
                assert_v0_request_iq(outgoing, "plain.txt", "12", "text/plain");
                stream.emit_iq_result(build_slot_result_for_request(
                    outgoing,
                    NS_0,
                    "http://upload.example.test/get/plain.txt",
                    "https://upload.example.test/put/plain.txt",
                    true
                ));
            });
        } catch (Error e) {
            fail_if_reached(@"non-HTTPS request_slot test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_request_slot_cancel_resumes_without_response(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_request_slot_stream(NS_0);
            var module = new Xep.HttpFileUpload.Module();
            var cancellable = new Cancellable();
            int completion_count = 0;

            module.request_slot_with_cancellable.begin(stream, "cancel.txt", 23, "text/plain", cancellable, (_, res) => {
                completion_count++;
                try {
                    module.request_slot_with_cancellable.end(res);
                    fail_if_reached("cancelled request_slot must not return a slot");
                } catch (IOError.CANCELLED e) {
                    // Expected: Vala async methods expose their Cancellable as IOError.CANCELLED.
                } catch (Error e) {
                    fail_if_reached(@"cancelled request_slot returned the wrong error: $(e.message)");
                }

                StanzaNode? outgoing = stream.last_written;
                fail_if(outgoing == null, "cancelled request_slot must have written its IQ before cancellation");
                if (outgoing != null) {
                    stream.emit_iq_result(build_slot_result_for_request(
                        (!) outgoing,
                        NS_0,
                        "https://upload.example.test/get/cancel.txt",
                        "https://upload.example.test/put/cancel.txt",
                        true
                    ));
                }

                Idle.add(() => {
                    fail_if(completion_count != 1, "a late slot response must not complete a cancelled request twice");
                    cb();
                    return false;
                });
            });

            respond_when_written(stream, (outgoing) => {
                assert_v0_request_iq(outgoing, "cancel.txt", "23", "text/plain");
                cancellable.cancel();
            });
        } catch (Error e) {
            fail_if_reached(@"cancel request_slot test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_request_slot_stream_detach_resumes_without_response(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_request_slot_stream(NS_0);
            var module = new Xep.HttpFileUpload.Module();

            module.request_slot.begin(stream, "detach.txt", 31, "text/plain", (_, res) => {
                try {
                    module.request_slot.end(res);
                    fail_if_reached("detached request_slot must not return a slot");
                } catch (Xep.HttpFileUpload.HttpFileTransferError e) {
                    string message = e.message.down();
                    fail_if(!message.contains("upload slot"), @"detached request_slot must be classified as an upload-slot failure: $(e.message)");
                    fail_if(!message.contains("detached"), @"detached request_slot must preserve its transport reason: $(e.message)");
                }
                cb();
            });

            respond_when_written(stream, (outgoing) => {
                assert_v0_request_iq(outgoing, "detach.txt", "31", "text/plain");
                stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
            });
        } catch (Error e) {
            fail_if_reached(@"detach request_slot test setup failed: $(e.message)");
            cb();
        }
    }

    // ========== Max file size parsing ==========

    private void test_max_file_size_normal() {
        // Normal disco#info form with max-file-size field
        var x_node = build_disco_form("104857600"); // 100 MB
        string? max_str = extract_max_file_size_str(x_node);
        assert_nonnull(max_str);
        long parsed = long.parse(max_str);
        assert_true(parsed == 104857600);
    }

    private void test_max_file_size_missing() {
        // No max-file-size field in form
        var x_node = new StanzaNode.build("x", NS_DATA_FORMS).add_self_xmlns();
        string? max_str = extract_max_file_size_str(x_node);
        assert_null(max_str);
        // DinoX: `if (max_file_size_str != null)` → returns long.MAX when missing ✓
    }

    private void test_max_file_size_zero() {
        var x_node = build_disco_form("0");
        string? max_str = extract_max_file_size_str(x_node);
        assert_nonnull(max_str);
        long parsed = long.parse(max_str);
        assert_true(parsed == 0);
        // Zero file size means... no uploads? The server should reject, not the client.
    }

    private void test_max_file_size_negative() {
        var x_node = build_disco_form("-1");
        string? max_str = extract_max_file_size_str(x_node);
        assert_nonnull(max_str);
        long parsed = long.parse(max_str);
        assert_true(parsed == -1);
        // Negative file size → long.parse returns -1 at parse level
        // FIX applied: extract_max_file_size() now validates parsed > 0
        // and returns long.MAX for invalid values (negative, zero, non-numeric)
        // This prevents bypass of size limits via malicious server response
    }

    private void test_max_file_size_non_numeric() {
        var x_node = build_disco_form("not_a_number");
        string? max_str = extract_max_file_size_str(x_node);
        assert_nonnull(max_str);
        long parsed = long.parse(max_str);
        assert_true(parsed == 0); // long.parse returns 0 for non-numeric
    }

    // ========== Flag ==========

    private void test_flag() {
        try {
            var jid = new Jid("upload.example.com");
            var flag = new Xep.HttpFileUpload.Flag(jid, NS_0);
            assert_true(flag.file_store_jid.to_string() == "upload.example.com");
            assert_true(flag.ns_ver == NS_0);
            assert_true(flag.get_ns() == NS_LEGACY); // get_ns returns the base NS_URI
            assert_true(flag.get_id() == "http_file_upload");
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    // ========== Helpers ==========

    private StanzaNode build_slot_with_url_attributes(string ns_ver, string? url_get, string? url_put) {
        var slot = new StanzaNode.build("slot", ns_ver).add_self_xmlns();
        if (url_get != null) {
            slot.put_node(new StanzaNode.build("get", ns_ver).put_attribute("url", (!)url_get));
        }
        if (url_put != null) {
            slot.put_node(new StanzaNode.build("put", ns_ver).put_attribute("url", (!)url_put));
        }
        return slot;
    }

    private StanzaNode build_slot_with_header(string header_name, string header_value) {
        var slot = build_slot_with_url_attributes(NS_0, "https://upload.example.com/get", "https://upload.example.com/put");
        StanzaNode? put_node = slot.get_subnode("put", NS_0);
        assert_nonnull(put_node);
        var header = new StanzaNode.build("header", NS_0)
            .put_attribute("name", header_name)
            .put_node(new StanzaNode.text(header_value));
        put_node.put_node(header);
        return slot;
    }

    private StanzaNode build_iq_with_slot(StanzaNode slot) {
        return new StanzaNode.build("iq").put_node(slot);
    }

    private TestXmppStream create_request_slot_stream(string ns_ver) throws InvalidJidError {
        var stream = new TestXmppStream(new Jid("example.test"));
        var iq_module = new Iq.Module();
        stream.add_module(iq_module);
        iq_module.attach(stream);
        stream.add_flag(new Xep.HttpFileUpload.Flag(new Jid("upload.example.test"), ns_ver));
        return stream;
    }

    private void respond_when_written(TestXmppStream stream, owned WrittenIqHandler handler) {
        Idle.add(() => {
            StanzaNode? outgoing = stream.last_written;
            if (outgoing == null) return true;
            handler((!) outgoing);
            return false;
        });
    }

    private void assert_v0_request_iq(StanzaNode iq, string filename, string size, string content_type) {
        fail_if_not_eq_str("iq", iq.name);
        fail_if_not_eq_str(Iq.Stanza.TYPE_GET, iq.get_attribute("type"));
        fail_if_not_eq_str("upload.example.test", iq.get_attribute("to"));
        fail_if(iq.get_attribute("id") == null, "request_slot IQ must have an id");

        StanzaNode? request = iq.get_subnode("request", NS_0);
        fail_if(request == null, "v0 request_slot IQ must contain upload request node");
        if (request == null) return;
        fail_if_not_eq_str(filename, request.get_attribute("filename"));
        fail_if_not_eq_str(size, request.get_attribute("size"));
        fail_if_not_eq_str(content_type, request.get_attribute("content-type"));
    }

    private void assert_legacy_request_iq(StanzaNode iq, string filename, string size, string content_type) {
        fail_if_not_eq_str("iq", iq.name);
        fail_if_not_eq_str(Iq.Stanza.TYPE_GET, iq.get_attribute("type"));
        fail_if_not_eq_str("upload.example.test", iq.get_attribute("to"));
        fail_if(iq.get_attribute("id") == null, "legacy request_slot IQ must have an id");

        StanzaNode? request = iq.get_subnode("request", NS_LEGACY);
        fail_if(request == null, "legacy request_slot IQ must contain upload request node");
        if (request == null) return;
        fail_if_not_eq_str(filename, get_required_child_text(request, "filename", NS_LEGACY));
        fail_if_not_eq_str(size, get_required_child_text(request, "size", NS_LEGACY));
        fail_if_not_eq_str(content_type, get_required_child_text(request, "content-type", NS_LEGACY));
    }

    private string? get_required_child_text(StanzaNode parent, string name, string ns_ver) {
        StanzaNode? child = parent.get_subnode(name, ns_ver);
        fail_if(child == null, @"missing child: $(name)");
        return child == null ? null : child.get_string_content();
    }

    private StanzaNode build_slot_result_for_request(StanzaNode request_iq, string ns_ver, string url_get, string url_put, bool url_attributes) {
        var result_iq = new StanzaNode.build("iq").put_attribute("type", Iq.Stanza.TYPE_RESULT);
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? to = request_iq.get_attribute("to");
        if (to != null) result_iq.put_attribute("from", (!) to);

        var slot = new StanzaNode.build("slot", ns_ver).add_self_xmlns();
        if (url_attributes) {
            slot.put_node(new StanzaNode.build("get", ns_ver).put_attribute("url", url_get));
            slot.put_node(new StanzaNode.build("put", ns_ver).put_attribute("url", url_put));
        } else {
            slot.put_node(new StanzaNode.build("get", ns_ver).put_node(new StanzaNode.text(url_get)));
            slot.put_node(new StanzaNode.build("put", ns_ver).put_node(new StanzaNode.text(url_put)));
        }
        result_iq.put_node(slot);
        return result_iq;
    }

    private void append_slot_header(StanzaNode result_iq, string ns_ver, string name, string value) {
        StanzaNode? slot = result_iq.get_subnode("slot", ns_ver);
        fail_if(slot == null, "slot result must contain slot node");
        if (slot == null) return;

        StanzaNode? put = slot.get_subnode("put", ns_ver);
        fail_if(put == null, "slot result must contain put node");
        if (put == null) return;

        put.put_node(new StanzaNode.build("header", ns_ver)
            .put_attribute("name", name)
            .put_node(new StanzaNode.text(value)));
    }

    private void assert_slot_urls(StanzaNode slot, string ns_ver, string expected_get, string expected_put) {
        try {
            var result = Xep.HttpFileUpload.Module.parse_slot_result(build_iq_with_slot(slot), ns_ver);
            fail_if_not_eq_str(expected_get, result.url_get);
            fail_if_not_eq_str(expected_put, result.url_put);
            assert_nonnull(result.headers);
        } catch (Xep.HttpFileUpload.HttpFileTransferError e) {
            fail_if_reached(@"slot response should parse: $(e.message)");
        }
    }

    private void assert_slot_parse_fails(StanzaNode slot, string ns_ver) {
        try {
            var result = Xep.HttpFileUpload.Module.parse_slot_result(build_iq_with_slot(slot), ns_ver);
            fail_if_reached(@"slot response should fail but parsed $(result.url_get)");
        } catch (Xep.HttpFileUpload.HttpFileTransferError e) {
            // Expected.
        }
    }

    private void assert_parsed_header(string header_name, string header_value, string expected_value) {
        try {
            var result = Xep.HttpFileUpload.Module.parse_slot_result(build_iq_with_slot(build_slot_with_header(header_name, header_value)), NS_0);
            fail_if_not_eq_str(expected_value, result.headers[header_name]);
        } catch (Xep.HttpFileUpload.HttpFileTransferError e) {
            fail_if_reached(@"slot response should parse header: $(e.message)");
        }
    }

    private void assert_header_dropped(string header_name, string header_value) {
        try {
            var result = Xep.HttpFileUpload.Module.parse_slot_result(build_iq_with_slot(build_slot_with_header(header_name, header_value)), NS_0);
            fail_if(result.headers.has_key(header_name), @"header should be dropped: $(header_name)");
        } catch (Xep.HttpFileUpload.HttpFileTransferError e) {
            fail_if_reached(@"slot response should parse while dropping header: $(e.message)");
        }
    }

    private StanzaNode build_disco_form(string max_size_value) {
        var x_node = new StanzaNode.build("x", NS_DATA_FORMS).add_self_xmlns();
        var field = new StanzaNode.build("field", NS_DATA_FORMS)
            .put_attribute("var", "max-file-size");
        var value_node = new StanzaNode.build("value", NS_DATA_FORMS)
            .put_node(new StanzaNode.text(max_size_value));
        field.put_node(value_node);
        x_node.put_node(field);
        return x_node;
    }

    private string? extract_max_file_size_str(StanzaNode x_node) {
        // Mirrors DinoX's extract_max_file_size logic
        Gee.List<StanzaNode> field_nodes = x_node.get_subnodes("field", NS_DATA_FORMS);
        foreach (StanzaNode node in field_nodes) {
            string? var_attr = node.get_attribute("var");
            if (var_attr == "max-file-size") {
                StanzaNode? value_node = node.get_subnode("value", NS_DATA_FORMS);
                if (value_node != null) return value_node.get_string_content();
            }
        }
        return null;
    }
}

private delegate void WrittenIqHandler(StanzaNode outgoing);

private class TestXmppStream : XmppStream {
    public StanzaNode? last_written { get; private set; default = null; }

    public TestXmppStream(Jid remote_name) {
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
        last_written = node;
    }

    public override async void setup() throws IOError {
    }

    public void emit_iq_result(StanzaNode node) {
        received_iq_stanza(this, node);
    }
}

}
