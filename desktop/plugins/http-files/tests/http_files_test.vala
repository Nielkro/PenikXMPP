using Dino.Plugins.HttpFiles;
using Xmpp;

// Force GObject class initialisation so that static Regex fields are populated.
// link_args-style linking (internal VAPI) does NOT trigger class_init automatically.
[CCode (cname = "g_type_class_ref", cheader_filename = "glib-object.h")]
extern unowned void* _force_class_init(GLib.Type type);

namespace Dino.Plugins.HttpFiles.Test {

[CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
private extern void set_server_message_response(Soup.ServerMessage msg, string? content_type, Soup.MemoryUse resp_use, string response_body, size_t response_length);

private void set_server_string_response(Soup.ServerMessage msg, string content_type, string response_body) {
    set_server_message_response(msg, content_type, Soup.MemoryUse.COPY, response_body, response_body.length);
}

/**
 * XEP-0363 HTTP File Upload — URL recognition regex tests.
 * The http_url_regex must accept valid HTTP(S) upload URLs and reject
 * anything that would break the download path (fragments, spaces, wrong scheme).
 *
 * The omemo_url_regex validates the aesgcm:// URL convention for OMEMO
 * encrypted file transfers (iv+key carried in fragment).
 */
class UrlRegexTest : Gee.TestCase {
    public UrlRegexTest() {
        base("UrlRegex");
        add_test("XEP0363_http_url_accepts_https", test_http_matches_https);
        add_test("XEP0363_http_url_accepts_http", test_http_matches_http);
        add_test("XEP0363_http_url_rejects_ftp_scheme", test_http_rejects_ftp);
        add_test("RFC3986_rejects_spaces_in_url", test_http_rejects_spaces);
        add_test("XEP0363_http_url_rejects_fragment", test_http_rejects_fragment);
        add_test("CONTRACT_http_url_rejects_empty", test_http_rejects_empty);
        add_test("XEP0363_http_url_accepts_port_path", test_http_matches_port_and_path);
        add_test("CONTRACT_network_url_validator_accepts_token_port_ipv6", test_network_validator_accepts_token_port_ipv6);
        add_test("CONTRACT_network_url_validator_rejects_missing_authority", test_network_validator_rejects_missing_authority);
        add_test("CONTRACT_network_url_validator_rejects_encoded_host_separators", test_network_validator_rejects_encoded_host_separators);
        add_test("CONTRACT_network_url_validator_rejects_libsoup_incompatible_hosts", test_network_validator_rejects_libsoup_incompatible_hosts);
        add_test("OMEMO_aesgcm_url_matches", test_omemo_matches_aesgcm);
        add_test("OMEMO_aesgcm_requires_fragment", test_omemo_requires_fragment);
        add_test("OMEMO_aesgcm_rejects_https_scheme", test_omemo_rejects_https);
        add_test("OMEMO_aesgcm_rejects_empty_fragment", test_omemo_rejects_empty_fragment);
        add_test("OMEMO_aesgcm_captures_host_and_secret", test_omemo_captures_host_and_secret);
        add_test("RFC3986_aesgcm_rejects_spaces_in_fragment", test_omemo_rejects_spaces_in_secret);
    }

    public override void set_up() {
        // Trigger GObject class_init so static Regex fields are populated
        _force_class_init(typeof(FileProvider));
    }

    void test_http_matches_https() {
        fail_if_not(FileProvider.http_url_regex.match("https://example.com/file.jpg"),
                    "XEP-0363: HTTPS upload URL MUST be recognized as valid download source");
    }

    void test_http_matches_http() {
        fail_if_not(FileProvider.http_url_regex.match("http://example.com/file.jpg"),
                    "XEP-0363: HTTP upload URL MUST be recognized (non-TLS allowed by spec)");
    }

    void test_http_rejects_ftp() {
        fail_if(FileProvider.http_url_regex.match("ftp://example.com/file.jpg"),
                "XEP-0363: only http/https schemes are valid; ftp MUST be rejected");
    }

    void test_http_rejects_spaces() {
        fail_if(FileProvider.http_url_regex.match("https://example.com/file name.jpg"),
                "RFC 3986 §3.3: spaces are not valid in URI path; MUST reject");
    }

    void test_http_rejects_fragment() {
        fail_if(FileProvider.http_url_regex.match("https://example.com/file.jpg#abc"),
                "XEP-0363: GET URL with fragment would lose data; MUST reject");
    }

    void test_http_rejects_empty() {
        fail_if(FileProvider.http_url_regex.match(""),
                "CONTRACT: empty string is not a valid URL; MUST reject");
    }

    void test_http_matches_port_and_path() {
        fail_if_not(FileProvider.http_url_regex.match("https://chat.example.com:5443/upload/abc123/file.webp"),
                    "XEP-0363: URL with port and multi-segment upload path MUST match");
    }

    void test_network_validator_accepts_token_port_ipv6() {
        const string url = "https://[2001:db8::1]:7443/files/photo.webp?token=a%2Fb&expires=42";
        fail_if_not(HttpFileUrl.is_valid_network_url(url),
            "HTTP transfer validation must preserve valid IPv6, port and query-token URLs");
        Soup.Message? message = HttpFileUrl.create_message("GET", url);
        fail_if(message == null,
            "libsoup must receive a valid tokenized IPv6 transfer URL");
    }

    void test_network_validator_rejects_missing_authority() {
        const string url = "https:///files/photo.webp";
        try {
            Uri.parse(url, UriFlags.NONE);
        } catch (Error e) {
            fail_if(true, "missing-authority regression fixture must remain parseable by GLib.Uri");
        }
        fail_if(HttpFileUrl.is_valid_network_url(url),
            "HTTP transfer validation must require a non-empty authority host");
        fail_if(HttpFileUrl.create_message("GET", url) != null,
            "malformed transfer URLs must not produce a libsoup message");
    }

    void test_network_validator_rejects_encoded_host_separators() {
        string[] invalid_urls = {
            "https://upload%20host.example.test/file",
            "https://upload%09host.example.test/file",
            "https://upload%2Fhost.example.test/file"
        };
        foreach (string url in invalid_urls) {
            try {
                Uri.parse(url, UriFlags.NONE);
            } catch (Error e) {
                fail_if(true, @"encoded-host regression fixture must remain parseable by GLib.Uri: $(url)");
            }
            fail_if(HttpFileUrl.is_valid_network_url(url),
                @"decoded host must reject unsafe encoded characters: $(url)");
            fail_if(HttpFileUrl.create_message("GET", url) != null,
                @"unsafe encoded host must not produce a libsoup message: $(url)");
        }
    }

    void test_network_validator_rejects_libsoup_incompatible_hosts() {
        string[] invalid_urls = {
            "https://good|evil.test/file",
            "https://good^evil.test/file",
            "https://good%3Aevil.test/file",
            "https://good%3Cevil.test/file",
            "https://good%3Eevil.test/file"
        };
        foreach (string url in invalid_urls) {
            fail_if(HttpFileUrl.is_valid_network_url(url),
                @"libsoup-incompatible host must fail structural validation: $(url)");
            fail_if(HttpFileUrl.create_message("GET", url) != null,
                @"libsoup-incompatible host must not produce an HTTP request: $(url)");
        }
    }

    void test_omemo_matches_aesgcm() {
        fail_if_not(FileProvider.omemo_url_regex.match("aesgcm://example.com/upload/file.jpg#aabbccdd1234"),
                    "OMEMO: aesgcm:// URL with fragment (iv+key) MUST be recognized");
    }

    void test_omemo_requires_fragment() {
        fail_if(FileProvider.omemo_url_regex.match("aesgcm://example.com/upload/file.jpg"),
                "OMEMO: aesgcm:// URL without fragment has no iv+key; MUST reject");
    }

    void test_omemo_rejects_https() {
        fail_if(FileProvider.omemo_url_regex.match("https://example.com/file.jpg#secret"),
                "OMEMO: https:// scheme MUST NOT match omemo regex (different code path)");
    }

    void test_omemo_rejects_empty_fragment() {
        fail_if(FileProvider.omemo_url_regex.match("aesgcm://example.com/file.jpg#"),
                "OMEMO: empty fragment contains no iv+key; MUST reject");
    }

    void test_omemo_captures_host_and_secret() {
        MatchInfo info;
        fail_if_not(FileProvider.omemo_url_regex.match("aesgcm://host.example:5443/upload/abc/file.webp#iv_hex_key_hex", 0, out info),
                    "OMEMO: aesgcm URL with port MUST match and capture groups");
        fail_if_not_eq_str("host.example:5443/upload/abc/file.webp", info.fetch(1));
        fail_if_not_eq_str("iv_hex_key_hex", info.fetch(2));
    }

    void test_omemo_rejects_spaces_in_secret() {
        fail_if(FileProvider.omemo_url_regex.match("aesgcm://example.com/file.jpg#sec ret"),
                "RFC 3986 §3.5: fragment MUST NOT contain spaces; would corrupt iv+key");
    }
}

/**
 * CONTRACT: extract_file_name_from_url() — strips fragment, URL-decodes,
 * and returns the filename portion after the last '/'.
 * This is critical for displaying the correct filename to users.
 */
class FileNameExtractionTest : Gee.TestCase {
    public FileNameExtractionTest() {
        base("FileNameExtraction");
        add_test("CONTRACT_simple_https_url", test_simple_https_url);
        add_test("OMEMO_aesgcm_strips_fragment", test_aesgcm_strips_fragment);
        add_test("RFC3986_url_decode_percent_encoding", test_url_encoded_name);
        add_test("CONTRACT_deep_path_last_segment", test_deep_path);
        add_test("CONTRACT_trailing_slash_empty", test_trailing_slash);
        add_test("XEP0363_real_upload_url", test_port_in_url);
    }

    // FileProvider.extract_file_name_from_url is an instance method
    // requiring StreamInteractor. We replicate the pure logic here.
    // The actual method: strip fragment, unescape, take after last '/'.
    private string extract_file_name(string url) {
        string ret = url;
        if (ret.contains("#")) {
            ret = ret.substring(0, ret.last_index_of("#"));
        }
        ret = Uri.unescape_string(ret.substring(ret.last_index_of("/") + 1));
        return ret;
    }

    void test_simple_https_url() {
        fail_if_not_eq_str("image.jpg", extract_file_name("https://example.com/upload/abc/image.jpg"));
    }

    void test_aesgcm_strips_fragment() {
        fail_if_not_eq_str("photo.webp",
            extract_file_name("aesgcm://chat.example.com:5443/upload/abc123/photo.webp#aabbccdd11223344"));
    }

    void test_url_encoded_name() {
        fail_if_not_eq_str("my file (1).png",
            extract_file_name("https://example.com/upload/my%20file%20%281%29.png"));
    }

    void test_deep_path() {
        fail_if_not_eq_str("doc.pdf",
            extract_file_name("https://host.example/a/b/c/d/doc.pdf"));
    }

    void test_trailing_slash() {
        // Edge case: trailing slash → empty name
        fail_if_not_eq_str("",
            extract_file_name("https://example.com/upload/"));
    }

    void test_port_in_url() {
        fail_if_not_eq_str("hose.webp",
            extract_file_name("https://chat.example.org:5443/upload/91cb74e9/4qlK2oPH/hose.webp"));
    }
}

/**
 * CONTRACT: sanitize_for_log() / sanitize_url_for_log() —
 * MUST strip secrets (fragments, query strings) from URLs before logging.
 * Prevents leaking OMEMO keys and upload tokens into log files.
 */
class SanitizeLogTest : Gee.TestCase {
    public SanitizeLogTest() {
        base("SanitizeLog");
        add_test("CONTRACT_null_safe", test_null_returns_null_string);
        add_test("CONTRACT_strips_fragment_secret", test_strips_fragment);
        add_test("CONTRACT_preserves_url_without_fragment", test_no_fragment_unchanged);
        add_test("CONTRACT_truncates_oversized_url", test_truncates_long_url);
        add_test("CONTRACT_sender_strips_query_token", test_sender_strips_query);
        add_test("CONTRACT_sender_null_safe", test_sender_null_returns_null_string);
    }

    void test_null_returns_null_string() {
        fail_if_not_eq_str("(null)", FileProvider.sanitize_for_log(null));
    }

    void test_strips_fragment() {
        string result = FileProvider.sanitize_for_log("aesgcm://host/path#secretkey");
        fail_if_not_eq_str("aesgcm://host/path#...", result);
    }

    void test_no_fragment_unchanged() {
        fail_if_not_eq_str("https://example.com/file.jpg",
            FileProvider.sanitize_for_log("https://example.com/file.jpg"));
    }

    void test_truncates_long_url() {
        var sb = new GLib.StringBuilder();
        sb.append("https://example.com/");
        for (int i = 0; i < 250; i++) sb.append_c('x');
        string result = FileProvider.sanitize_for_log(sb.str);
        fail_if_not(result.length <= 203,
                    "CONTRACT: sanitize_for_log MUST truncate URLs > 200 chars to prevent log flooding");
        fail_if_not(result.has_suffix("..."),
                    "CONTRACT: truncated URL MUST end with '...' to indicate truncation");
    }

    void test_sender_strips_query() {
        string result = HttpFileSender.sanitize_url_for_log("https://host/path?token=abc&sig=xyz");
        fail_if_not_eq_str("https://host/path?...", result);
    }

    void test_sender_null_returns_null_string() {
        fail_if_not_eq_str("(null)", HttpFileSender.sanitize_url_for_log(null));
    }
}

class AccountHttpSessionPoolTest : Gee.TestCase {
    public AccountHttpSessionPoolTest() {
        base("AccountHttpSessionPool");
        add_test("CONCURRENCY_sessions_are_immutable_per_account_proxy_generation", test_immutable_sessions_per_account_proxy_generation);
    }

    void test_immutable_sessions_per_account_proxy_generation() {
        Dino.AccountHttpSessionPool? pool = null;
        try {
            pool = new Dino.AccountHttpSessionPool("http-test");
            var first_account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var second_account = new Dino.Entities.Account(new Xmpp.Jid("carol@example.test"), "secret");

            Soup.Session first = (Soup.Session) ((!) pool).get_session(first_account);
            Soup.Session first_again = (Soup.Session) ((!) pool).get_session(first_account);
            Soup.Session second = (Soup.Session) ((!) pool).get_session(second_account);

            fail_if(first != first_again,
                "parallel requests for one account must reuse a configured session without mutating it");
            fail_if(first == second,
                "different accounts must not share HTTP authentication or proxy session state");

            ProxyResolver? original_resolver = first.proxy_resolver;
            first_account.proxy_type = "socks5";
            first_account.proxy_host = "127.0.0.1";
            first_account.proxy_port = 19050;

            Soup.Session changed_proxy = (Soup.Session) ((!) pool).get_session(first_account);
            fail_if(changed_proxy == first,
                "a live account proxy change must create a new configured session");
            fail_if(first.proxy_resolver != original_resolver,
                "a live proxy change must not mutate the session used by an in-flight request");
            fail_if_not(changed_proxy.proxy_resolver is SimpleProxyResolver,
                "the replacement account session must use the configured SOCKS5 resolver");
        } catch (Error e) {
            fail_if(true, @"Account HTTP session pool test failed: $(e.message)");
        } finally {
            if (pool != null) ((!) pool).shutdown();
        }
    }
}

class MetadataHeadCancellationTest : Gee.TestCase {
    public MetadataHeadCancellationTest() {
        base("MetadataHeadCancellation");
        add_test("CONTRACT_head_uses_transfer_cancellable", test_head_uses_transfer_cancellable_sync);
        add_test("CONTRACT_head_preserves_socket_timeout", test_head_preserves_socket_timeout);
    }

    public override void set_up() {
        _force_class_init(typeof(FileProvider));
    }

    void test_head_uses_transfer_cancellable_sync() {
        var loop = new MainLoop();
        test_head_uses_transfer_cancellable.begin((obj, res) => {
            test_head_uses_transfer_cancellable.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_head_uses_transfer_cancellable() {
        var session = new Soup.Session();
        var message = new Soup.Message("HEAD", "http://127.0.0.1:9/dinox-cancel-test.bin");
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.cancellable.cancel();

        bool cancelled = false;
        try {
            yield FileProvider.send_metadata_head(session, message, file_transfer);
            fail_if(true, "cancelled metadata HEAD must not complete");
        } catch (IOError.CANCELLED e) {
            cancelled = true;
        } catch (Error e) {
            fail_if(true, @"cancelled metadata HEAD must propagate IOError.CANCELLED, got $(e.message)");
        }

        fail_if(!cancelled,
            "metadata HEAD must use the transfer cancellable instead of starting an uncancellable request");
    }

    void test_head_preserves_socket_timeout() {
        var server = new Soup.Server("server-header", "DinoX-Timeout-Test", null);
        var session = new Soup.Session() {
            timeout = 1,
            proxy_resolver = new SimpleProxyResolver("direct://", null)
        };
        var transfer = new Dino.Entities.FileTransfer();
        Soup.ServerMessage? paused = null;
        uint guard = 0;
        Error? failure = null;
        bool completed = false;
        try {
            server.add_handler(null, (srv, msg, path, query) => {
                paused = msg;
                msg.pause();
            });
            server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            string url = server.get_uris().data.to_string();
            var message = new Soup.Message("HEAD", url);
            var loop = new MainLoop();
            guard = Timeout.add_seconds(5, () => {
                guard = 0;
                transfer.cancellable.cancel();
                return Source.REMOVE;
            });
            FileProvider.send_metadata_head.begin(session, message, transfer, (_, res) => {
                try {
                    FileProvider.send_metadata_head.end(res);
                } catch (Error e) {
                    failure = e;
                }
                completed = true;
                loop.quit();
            });
            loop.run();
        } catch (Error e) {
            failure = e;
        } finally {
            if (guard != 0) Source.remove(guard);
            if (paused != null) ((!) paused).unpause();
            session.abort();
            server.disconnect();
        }
        fail_if(!completed || paused == null, "the test server must receive and stall the metadata HEAD");
        fail_if(!(failure is IOError.TIMED_OUT),
            "metadata HEAD must preserve IOError.TIMED_OUT instead of replacing it with FAILED");
    }
}

class HttpDownloadCancellationTest : Gee.TestCase {
    public HttpDownloadCancellationTest() {
        base("HttpDownloadCancellation");
        add_test("CONTRACT_http_download_uses_transfer_cancellable", test_http_download_cancelled_transfer_reaches_cancelled_exception_sync);
        add_test("CONTRACT_http_download_missing_authority_fails_closed", test_http_download_missing_authority_fails_closed_sync);
        add_test("CONTRACT_http_provider_preserves_connection_error", test_http_provider_preserves_connection_error_sync);
    }

    public override void set_up() {
        _force_class_init(typeof(FileProvider));
    }

    void test_http_provider_preserves_connection_error_sync() {
        var loop = new MainLoop();
        test_http_provider_preserves_connection_error.begin((_, res) => {
            try {
                test_http_provider_preserves_connection_error.end(res);
            } catch (Error e) {
                fail_if(true, @"HTTP error propagation test failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    async void test_http_provider_preserves_connection_error() throws Error {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-http-errors-" + Uuid.string_random() + ".db");
        Dino.Database? db = null;
        FileProvider? provider = null;
        // Reserve a local TCP port without listening: connection attempts fail
        // without contacting a real upload service or relying on a fixed port.
        var socket = new Socket(SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
        socket.bind(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), false);
        uint port = ((InetSocketAddress) socket.get_local_address()).port;
        try {
            db = new Dino.Database(db_path, "http-error-test");
            var interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageProcessor.start(interactor, (!) db);
            provider = new FileProvider(interactor, (!) db);
            var transfer = new Dino.Entities.FileTransfer() {
                account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret")
            };
            var data = new Dino.HttpFileReceiveData() {
                url = @"http://127.0.0.1:$port/private-file.bin?token=secret-value"
            };
            var meta = new Dino.FileMeta();
            bool head_refused = false;
            bool get_refused = false;
            try {
                yield provider.get_meta_info(transfer, data, meta);
            } catch (IOError.CONNECTION_REFUSED e) {
                head_refused = true;
                assert_safe_transport_diagnostic(e);
            } catch (Error e) { }
            try {
                yield provider.download(transfer, data, meta);
            } catch (IOError.CONNECTION_REFUSED e) {
                get_refused = true;
                assert_safe_transport_diagnostic(e);
            } catch (Error e) { }
            fail_if(!head_refused, "metadata lookup must preserve the connection error code");
            fail_if(!get_refused, "GET must preserve the connection error code");
        } finally {
            try { socket.close(); } catch (Error e) { }
            if (provider != null) ((!) provider).shutdown();
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
        }
    }

    private void assert_safe_transport_diagnostic(Error error) {
        fail_if(!error.message.contains("127.0.0.1"), "transport diagnostics must identify the server");
        fail_if(error.message.contains("private-file") || error.message.contains("secret-value"),
            "transport diagnostics must not expose upload paths or access tokens");
    }

    void test_http_download_cancelled_transfer_reaches_cancelled_exception_sync() {
        var loop = new MainLoop();
        test_http_download_cancelled_transfer_reaches_cancelled_exception.begin((obj, res) => {
            try {
                test_http_download_cancelled_transfer_reaches_cancelled_exception.end(res);
            } catch (Error e) {
                fail_if(true, @"cancelled HTTP download regression test failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    async void test_http_download_cancelled_transfer_reaches_cancelled_exception() throws Error {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-download-cancel-" + Uuid.string_random() + ".db");
        Dino.Database? db = null;
        Dino.StreamInteractor? stream_interactor = null;
        FileProvider? provider = null;

        try {
            db = new Dino.Database(db_path, "http-files-download-cancel-test");
            stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageProcessor.start((!) stream_interactor, (!) db);
            provider = new FileProvider((!) stream_interactor, (!) db);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.account = account;
            file_transfer.counterpart = new Jid("bob@example.test");
            file_transfer.ourpart = account.full_jid;
            file_transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            file_transfer.file_name = "cancelled-download.bin";
            file_transfer.mime_type = "application/octet-stream";
            file_transfer.size = 1024;
            file_transfer.cancellable.cancel();

            var receive_data = new Dino.HttpFileReceiveData();
            receive_data.url = "http://127.0.0.1:9/dinox-cancel-test.bin";

            var file_meta = new Dino.FileMeta();
            file_meta.size = 1024;

            bool cancelled = false;
            try {
                yield provider.download(file_transfer, receive_data, file_meta);
                fail_if(true, "cancelled HTTP download must not return a stream");
            } catch (IOError.CANCELLED e) {
                cancelled = true;
            }
            fail_if(!cancelled, "cancelled HTTP download must propagate transfer cancellation as IOError.CANCELLED");
        } finally {
            if (provider != null) ((!) provider).shutdown();
            if (db != null) {
                ((!) db).close();
            }
            FileUtils.remove(db_path);
        }
    }

    void test_http_download_missing_authority_fails_closed_sync() {
        var loop = new MainLoop();
        test_http_download_missing_authority_fails_closed.begin((obj, res) => {
            try {
                test_http_download_missing_authority_fails_closed.end(res);
            } catch (Error e) {
                fail_if(true, @"malformed HTTP download regression test failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    async void test_http_download_missing_authority_fails_closed() throws Error {
        const string malformed_url = "https:///download.bin";
        Uri.parse(malformed_url, UriFlags.NONE);

        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-http-files-download-invalid-" + Uuid.string_random() + ".db");
        Dino.Database? db = null;
        FileProvider? provider = null;

        try {
            db = new Dino.Database(db_path, "http-files-download-invalid-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            provider = new FileProvider(stream_interactor, (!) db);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var file_transfer = new Dino.Entities.FileTransfer() {
                account = account,
                counterpart = new Xmpp.Jid("bob@example.test"),
                ourpart = account.full_jid,
                direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                file_name = "invalid-download.bin",
                mime_type = "application/octet-stream",
                size = 64
            };
            var receive_data = new Dino.HttpFileReceiveData() { url = malformed_url };
            var file_meta = new Dino.FileMeta() { size = 64 };

            bool download_failed = false;
            try {
                yield provider.download(file_transfer, receive_data, file_meta);
                fail_if(true, "a malformed download authority must not reach libsoup");
            } catch (IOError.INVALID_ARGUMENT e) {
                download_failed = true;
            }
            fail_if(!download_failed,
                "a GLib-parseable download URL without a host must fail closed");

            bool metadata_failed = false;
            try {
                yield provider.get_meta_info(file_transfer, receive_data, file_meta);
                fail_if(true, "a malformed metadata authority must not reach libsoup");
            } catch (Dino.FileReceiveError.GET_METADATA_FAILED e) {
                metadata_failed = true;
            }
            fail_if(!metadata_failed,
                "metadata lookup must reject a GLib-parseable URL without a host");
        } finally {
            if (provider != null) ((!) provider).shutdown();
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
        }
    }
}

/**
 * Regression for the account-session isolation introduced by 5b8981c3.
 * This proves HTTP request/response-stream overlap for two contacts on one
 * account. The separately bounded store/encryption worker is not measured here.
 */
class HttpDownloadTransportConcurrencyTest : Gee.TestCase {
    private const string BOB_PAYLOAD = "parallel download payload for Bob\n";
    private const string CAROL_PAYLOAD = "independent download payload for Carol\n";

    public HttpDownloadTransportConcurrencyTest() {
        base("HttpDownloadTransportConcurrency");
        add_test("CONCURRENCY_http_requests_for_same_account_contacts_overlap", test_parallel_download_requests);
    }

    public override void set_up() {
        _force_class_init(typeof(FileProvider));
    }

    void test_parallel_download_requests() {
        Soup.Server? server = null;
        Dino.Database? db = null;
        FileProvider? provider = null;
        InputStream? bob_stream = null;
        InputStream? carol_stream = null;
        uint timeout_id = 0;
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-http-files-download-parallel-" + Uuid.string_random() + ".db");

        try {
            var capture = new ParallelDownloadCapture();
            server = new Soup.Server("server-header", "DinoX-Parallel-HttpDownload-Test/1.0", null);
            ((!) server).add_handler("/download/bob.bin", (srv, msg, path, query) => {
                capture.handle_request(msg, BOB_PAYLOAD);
            });
            ((!) server).add_handler("/download/carol.bin", (srv, msg, path, query) => {
                capture.handle_request(msg, CAROL_PAYLOAD);
            });
            try {
                ((!) server).listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            } catch (Error e) {
                GLib.Test.skip("Local parallel HTTP download sockets unavailable: %s".printf(e.message));
                return;
            }

            string bob_url = get_server_url((!) server, "/download/bob.bin");
            string carol_url = get_server_url((!) server, "/download/carol.bin");

            db = new Dino.Database(db_path, "http-files-download-parallel-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            provider = new FileProvider(stream_interactor, (!) db);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var bob_transfer = create_receive_transfer(
                account, "bob@example.test", "bob.bin", BOB_PAYLOAD.length);
            var carol_transfer = create_receive_transfer(
                account, "carol@example.test", "carol.bin", CAROL_PAYLOAD.length);
            var bob_receive_data = new Dino.HttpFileReceiveData() { url = bob_url };
            var carol_receive_data = new Dino.HttpFileReceiveData() { url = carol_url };
            var bob_meta = new Dino.FileMeta() { size = BOB_PAYLOAD.length };
            var carol_meta = new Dino.FileMeta() { size = CAROL_PAYLOAD.length };

            int completed = 0;
            string? failure = null;
            var loop = new MainLoop();
            SourceFunc finish_one = () => {
                completed++;
                if (completed == 2) loop.quit();
                return Source.REMOVE;
            };

            ((!) provider).download.begin(bob_transfer, bob_receive_data, bob_meta, (_, res) => {
                try {
                    bob_stream = ((!) provider).download.end(res);
                } catch (Error e) {
                    failure = "Bob download failed: " + e.message;
                }
                finish_one();
            });
            ((!) provider).download.begin(carol_transfer, carol_receive_data, carol_meta, (_, res) => {
                try {
                    carol_stream = ((!) provider).download.end(res);
                } catch (Error e) {
                    failure = "Carol download failed: " + e.message;
                }
                finish_one();
            });

            timeout_id = Timeout.add_seconds(10, () => {
                timeout_id = 0;
                capture.release_paused_response();
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }

            fail_if(completed != 2, "parallel downloads must both return without hanging");
            fail_if(failure != null, (!) failure);
            fail_if(!capture.overlap_observed,
                "a second same-account contact request must start while the first response is paused");
            fail_if(bob_stream == null || carol_stream == null,
                "parallel downloads must return independent response streams");
            if (bob_stream != null) {
                assert_bytes_equal(copy_string_data(BOB_PAYLOAD), read_all((!) bob_stream),
                    "Bob download must retain its own response bytes");
                bob_stream = null;
            }
            if (carol_stream != null) {
                assert_bytes_equal(copy_string_data(CAROL_PAYLOAD), read_all((!) carol_stream),
                    "Carol download must retain its own response bytes");
                carol_stream = null;
            }
        } catch (Error e) {
            fail_if(true, @"Parallel multi-contact HTTP download test failed: $(e.message)");
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (bob_stream != null) try { ((!) bob_stream).close(); } catch (Error e) { }
            if (carol_stream != null) try { ((!) carol_stream).close(); } catch (Error e) { }
            if (provider != null) ((!) provider).shutdown();
            if (db != null) ((!) db).close();
            if (server != null) ((!) server).disconnect();
            FileUtils.remove(db_path);
        }
    }

    private Dino.Entities.FileTransfer create_receive_transfer(
            Dino.Entities.Account account, string counterpart,
            string file_name, int64 size) throws Xmpp.InvalidJidError {
        return new Dino.Entities.FileTransfer() {
            account = account,
            counterpart = new Xmpp.Jid(counterpart),
            ourpart = account.full_jid,
            direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
            file_name = file_name,
            mime_type = "application/octet-stream",
            size = size
        };
    }

    private string get_server_url(Soup.Server server, string path) {
        foreach (Uri uri in server.get_uris()) {
            string base_url = uri.to_string();
            if (base_url.has_suffix("/")) {
                base_url = base_url.substring(0, base_url.length - 1);
            }
            return base_url + path;
        }
        GLib.error("Local parallel HTTP download server did not expose a URI");
    }

    private static uint8[] copy_string_data(string text) {
        unowned uint8[] raw = text.data;
        uint8[] copy = new uint8[raw.length];
        for (int i = 0; i < raw.length; i++) copy[i] = raw[i];
        return copy;
    }

    private static uint8[] read_all(InputStream stream) throws Error {
        var data = new GLib.ByteArray();
        uint8[] chunk = new uint8[4096];
        while (true) {
            ssize_t read = stream.read(chunk);
            if (read <= 0) break;
            data.append(chunk[0:(int) read]);
        }
        stream.close();
        return data.data;
    }

    private static void assert_bytes_equal(uint8[] expected, uint8[] actual, string reason) {
        fail_if_not_eq_int(expected.length, actual.length, reason);
        int length = int.min(expected.length, actual.length);
        for (int i = 0; i < length; i++) {
            if (expected[i] != actual[i]) {
                fail_if(true, @"$(reason): byte $(i) expected $(expected[i]) got $(actual[i])");
                return;
            }
        }
    }

    private class ParallelDownloadCapture : Object {
        public bool overlap_observed = false;
        private Soup.ServerMessage? paused_response = null;
        private bool first_response_was_paused = false;

        public void handle_request(Soup.ServerMessage message, string payload) {
            message.set_status(200, null);
            set_server_string_response(message, "application/octet-stream", payload);

            if (!first_response_was_paused) {
                first_response_was_paused = true;
                paused_response = message;
                message.pause();
                return;
            }

            overlap_observed = true;
            release_paused_response();
        }

        public void release_paused_response() {
            if (paused_response == null) return;
            ((!) paused_response).unpause();
            paused_response = null;
        }
    }
}

class HttpUploadRequestTest : Gee.TestCase {
    public HttpUploadRequestTest() {
        base("HttpUploadRequest");
        add_test("CONTRACT_http_put_invalid_upload_url_raises_upload_failed", test_invalid_upload_url);
        add_test("CONTRACT_http_put_missing_authority_fails_closed", test_missing_authority_fails_closed);
        add_test("CONTRACT_http_put_whitespace_host_fails_closed", test_whitespace_host_fails_closed);
        add_test("CONTRACT_http_put_backslash_authority_fails_closed", test_backslash_authority_fails_closed);
        add_test("CONTRACT_http_slot_get_and_put_fail_closed_before_send", test_slot_get_and_put_fail_closed);
        add_test("CONTRACT_http_put_success_sends_plain_payload_and_headers", test_plain_put_success_sync);
        add_test("CONTRACT_http_put_status_failure_raises_upload_failed", test_status_failure_sync);
        add_test("CONTRACT_http_put_uses_transfer_cancellable", test_put_uses_transfer_cancellable_sync);
        add_test("CONTRACT_http_put_cancels_after_server_receives_request", test_put_cancels_after_server_receives_request_sync);
        add_test("CONTRACT_http_put_cancels_while_request_body_stream_blocks", test_put_cancels_while_request_body_stream_blocks_sync);
    }

    void test_invalid_upload_url() {
        bool failed = false;
        try {
            HttpFileSender.validate_upload_url("http://[::1");
            fail_if(true, "HTTP upload helper must reject invalid upload URLs before libsoup sees them");
        } catch (Dino.FileSendError.UPLOAD_FAILED e) {
            failed = true;
            fail_if(!e.message.contains("Invalid upload URL"),
                @"invalid upload URL must keep the stable FileSendError prefix, got: $(e.message)");
        } catch (Error e) {
            fail_if(true, @"Unexpected invalid upload URL failure type: $(e.message)");
        }

        fail_if(!failed, "invalid upload URL must fail closed");
    }

    void test_missing_authority_fails_closed() {
        const string malformed_url = "https:///upload";
        try {
            Uri.parse(malformed_url, UriFlags.NONE);
        } catch (Error e) {
            fail_if(true, "regression fixture must remain parseable by GLib.Uri");
        }

        assert_upload_message_creation_fails(malformed_url);
    }

    void test_whitespace_host_fails_closed() {
        assert_upload_message_creation_fails("https://upload example.test/file");
    }

    void test_backslash_authority_fails_closed() {
        assert_upload_message_creation_fails("https://good.test\\@evil.test/upload");
    }

    void test_slot_get_and_put_fail_closed() {
        assert_slot_validation_fails(
            "https://good.test\\evil/download",
            "https://upload.example.test/put");
        assert_slot_validation_fails(
            "https://good.test\\@evil.test/download",
            "https://upload.example.test/put");
        assert_slot_validation_fails(
            "https://download.example.test/get",
            "https://good.test%2Fevil/upload");

        try {
            HttpFileSender.validate_upload_slot_urls(
                "https://[2001:db8::1]:7443/get?token=a%2Fb",
                "https://upload.example.test:5443/put?signature=abc%2Bdef");
        } catch (Error e) {
            fail_if(true, @"valid tokenized slot URLs must remain accepted: $(e.message)");
        }
    }

    private void assert_slot_validation_fails(string url_down, string url_up) {
        bool failed = false;
        try {
            HttpFileSender.validate_upload_slot_urls(url_down, url_up);
            fail_if(true, "invalid GET or PUT slot URL must fail before any transfer announcement");
        } catch (Dino.FileSendError.UPLOAD_FAILED e) {
            failed = true;
            fail_if(!e.message.contains("Invalid upload slot URL"),
                @"invalid slot URL must retain the stable error prefix, got: $(e.message)");
        } catch (Error e) {
            fail_if(true, @"Unexpected slot URL validation failure type: $(e.message)");
        }
        fail_if(!failed, "invalid GET or PUT slot URL must fail closed");
    }

    private void assert_upload_message_creation_fails(string url) {
        bool failed = false;
        try {
            HttpFileSender.create_upload_message(url);
            fail_if(true, "malformed upload authority must be rejected before the HTTP request is used");
        } catch (Dino.FileSendError.UPLOAD_FAILED e) {
            failed = true;
            fail_if(!e.message.contains("Invalid upload URL"),
                @"malformed upload authority must keep the stable error prefix, got: $(e.message)");
        } catch (Error e) {
            fail_if(true, @"Unexpected malformed upload authority failure type: $(e.message)");
        }
        fail_if(!failed, "malformed upload authority must fail closed");
    }

    void test_plain_put_success_sync() {
        if (skip_if_local_sockets_unavailable()) return;

        var loop = new MainLoop();
        test_plain_put_success.begin((obj, res) => {
            test_plain_put_success.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_plain_put_success() {
        Soup.Server? server = null;
        var session = new Soup.Session();
        try {
            var capture = new UploadCapture();
            string upload_url;
            server = start_upload_server(201, capture, out upload_url);

            uint8[] payload = "plain upload payload".data;
            var send_data = create_upload_send_data(upload_url);
            send_data.headers["X-DinoX-Test-Token"] = "slot-token-123";
            var file_transfer = create_upload_transfer(payload);
            var file_meta = create_upload_meta(payload.length, "text/plain");

            yield HttpFileSender.send_upload_request(session, null, file_transfer, send_data, file_meta, file_transfer.input_stream, file_meta.size);

            fail_if(!capture.handled, "HTTP upload helper must reach the local PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method, "HTTP upload helper must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "", "HTTP upload helper must set the request content type");
            fail_if_not_eq_str("slot-token-123", capture.custom_header ?? "", "HTTP upload helper must forward slot headers");
            fail_if_not_eq_int(payload.length, (int) capture.content_length, "HTTP upload helper must set the final content length");
            assert_bytes_equal(payload, capture.body, "HTTP upload helper must send the exact plain payload");
        } catch (Error e) {
            fail_if(true, @"HTTP PUT success test failed unexpectedly: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            session.abort();
        }
    }

    void test_status_failure_sync() {
        if (skip_if_local_sockets_unavailable()) return;

        var loop = new MainLoop();
        test_status_failure.begin((obj, res) => {
            test_status_failure.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_status_failure() {
        Soup.Server? server = null;
        var session = new Soup.Session();
        try {
            var capture = new UploadCapture();
            string upload_url;
            server = start_upload_server(500, capture, out upload_url);

            uint8[] payload = "rejected upload".data;
            var send_data = create_upload_send_data(upload_url);
            var file_transfer = create_upload_transfer(payload);
            var file_meta = create_upload_meta(payload.length, "application/octet-stream");

            bool failed = false;
            try {
                yield HttpFileSender.send_upload_request(session, null, file_transfer, send_data, file_meta, file_transfer.input_stream, file_meta.size);
                fail_if(true, "HTTP upload helper must fail on non-2xx upload status");
            } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                failed = true;
                fail_if(!e.message.contains("HTTP status code 500"),
                    @"HTTP upload status failure must mention the server status, got: $(e.message)");
            } catch (Error e) {
                fail_if(true, @"Unexpected HTTP upload failure type: $(e.message)");
            }

            fail_if(!failed, "HTTP upload helper must report a FileSendError on non-2xx status");
            fail_if(!capture.handled, "HTTP status failure test must reach the local PUT endpoint");
        } catch (Error e) {
            fail_if(true, @"HTTP PUT failure test failed unexpectedly: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            session.abort();
        }
    }

    void test_put_uses_transfer_cancellable_sync() {
        var loop = new MainLoop();
        test_put_uses_transfer_cancellable.begin((obj, res) => {
            test_put_uses_transfer_cancellable.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_put_uses_transfer_cancellable() {
        var session = new Soup.Session();
        uint8[] payload = "cancelled upload".data;
        var send_data = create_upload_send_data("http://127.0.0.1:9/dinox-cancel-upload.bin");
        var file_transfer = create_upload_transfer(payload);
        var file_meta = create_upload_meta(payload.length, "application/octet-stream");
        file_transfer.cancellable.cancel();

        bool failed = false;
        try {
            yield HttpFileSender.send_upload_request(session, null, file_transfer, send_data, file_meta, file_transfer.input_stream, file_meta.size);
            fail_if(true, "cancelled HTTP upload helper must not complete");
        } catch (Dino.FileSendError.UPLOAD_FAILED e) {
            failed = true;
            assert_upload_cancelled(file_transfer.cancellable, e, "cancelled HTTP upload");
        } catch (Error e) {
            fail_if(true, @"Unexpected cancelled HTTP upload failure type: $(e.message)");
        }

        fail_if(!failed,
            "HTTP upload helper must use the transfer cancellable instead of starting an uncancellable request");
        session.abort();
    }

    void test_put_cancels_after_server_receives_request_sync() {
        if (skip_if_local_sockets_unavailable()) return;

        var loop = new MainLoop();
        test_put_cancels_after_server_receives_request.begin((obj, res) => {
            test_put_cancels_after_server_receives_request.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_put_cancels_after_server_receives_request() {
        Soup.Server? server = null;
        var session = new Soup.Session();
        try {
            var capture = new UploadCapture();
            string upload_url;
            uint8[] payload = "cancel after server receives request".data;
            var file_transfer = create_upload_transfer(payload);
            server = start_cancel_after_request_server(capture, file_transfer, out upload_url);

            var send_data = create_upload_send_data(upload_url);
            send_data.headers["X-DinoX-Test-Token"] = "slot-token-cancel";
            var file_meta = create_upload_meta(payload.length, "text/plain");

            bool failed = false;
            try {
                yield HttpFileSender.send_upload_request(session, null, file_transfer, send_data, file_meta, file_transfer.input_stream, file_meta.size);
                fail_if(true, "HTTP upload helper must not complete after cancellation once the server received the request");
            } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                failed = true;
                assert_upload_cancelled(file_transfer.cancellable, e, "cancel-after-request HTTP upload");
            } catch (Error e) {
                fail_if(true, @"Unexpected cancel-after-request HTTP upload failure type: $(e.message)");
            }

            fail_if(!failed,
                "HTTP upload helper must fail when the transfer is cancelled after the server receives the request");
            fail_if(!capture.handled,
                "cancel-after-request test must reach the local PUT endpoint before cancellation");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "cancel-after-request test must cancel the transfer cancellable");
            fail_if_not_eq_str("PUT", capture.method, "cancel-after-request path must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "", "cancel-after-request path must set the request content type");
            fail_if_not_eq_str("slot-token-cancel", capture.custom_header ?? "", "cancel-after-request path must forward slot headers before cancellation");
            fail_if_not_eq_int(payload.length, (int) capture.content_length, "cancel-after-request path must send the final content length");
            assert_bytes_equal(payload, capture.body, "cancel-after-request path must send the exact plain payload before cancellation");
        } catch (Error e) {
            fail_if(true, @"HTTP PUT cancel-after-request test failed unexpectedly: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            session.abort();
        }
    }

    void test_put_cancels_while_request_body_stream_blocks_sync() {
        if (skip_if_local_sockets_unavailable()) return;

        var loop = new MainLoop();
        test_put_cancels_while_request_body_stream_blocks.begin((obj, res) => {
            test_put_cancels_while_request_body_stream_blocks.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_put_cancels_while_request_body_stream_blocks() {
        Soup.Server? server = null;
        var session = new Soup.Session();
        uint timeout_id = 0;
        try {
            var capture = new StreamingUploadCapture();
            string upload_url;
            uint8[] first_chunk = "partial upload body".data;
            int64 upload_size = 1024 * 1024;
            var file_transfer = new Dino.Entities.FileTransfer();
            var stream = new BlockingUploadInputStream(first_chunk, file_transfer.cancellable, capture);
            file_transfer.input_stream = stream;
            server = start_body_stream_cancel_server(capture, out upload_url);

            var send_data = create_upload_send_data(upload_url);
            send_data.headers["X-DinoX-Test-Token"] = "slot-token-stream-cancel";
            var file_meta = create_upload_meta(upload_size, "application/octet-stream");

            bool timed_out = false;
            timeout_id = Timeout.add(5000, () => {
                timed_out = true;
                timeout_id = 0;
                file_transfer.cancellable.cancel();
                return Source.REMOVE;
            });

            bool failed = false;
            try {
                yield HttpFileSender.send_upload_request(session, null, file_transfer, send_data, file_meta, stream, file_meta.size);
                fail_if(true, "HTTP upload helper must not complete while a blocked request body is cancelled");
            } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                failed = true;
                assert_upload_cancelled(file_transfer.cancellable, e, "blocked-body HTTP upload");
            } catch (Error e) {
                fail_if(true, @"Unexpected blocked-body HTTP upload failure type: $(e.message)");
            }

            fail_if(!failed,
                "HTTP upload helper must fail when the transfer is cancelled during request-body streaming");
            fail_if(timed_out,
                "blocked-body HTTP upload cancellation must be driven by the controlled stream read, not the timeout guard");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "blocked-body test must cancel the transfer cancellable");
            fail_if(!capture.request_started,
                "blocked-body test must open a local HTTP request before cancellation");
            fail_if(!capture.headers_seen,
                "blocked-body test must prove the server received PUT headers before the body completed");
            fail_if(capture.request_read,
                "blocked-body test must cancel before libsoup considers the full request body read");
            fail_if(capture.handler_called,
                "blocked-body test must not reach the normal PUT handler after a full request body");
            fail_if(!stream.first_chunk_seen,
                "blocked-body stream must send an initial body chunk before cancellation");
            fail_if(!stream.blocking_read_seen,
                "blocked-body stream must reach the blocking read after the initial chunk");
            fail_if(!stream.blocking_read_saw_cancellable,
                "blocked-body stream reads must receive a cancellable that observes transfer cancellation");
            fail_if(stream.blocking_read_missing_cancellable,
                "blocked-body stream must not be read without a cancellable");
            fail_if(!stream.cancelled_after_headers_seen,
                "blocked-body stream must trigger cancellation only after the server sees request headers");
            fail_if(!stream.cancel_seen,
                "blocked-body stream must observe cancellation while blocked");
            fail_if_not_eq_str("PUT", capture.method, "blocked-body path must use PUT");
            fail_if_not_eq_str("application/octet-stream", capture.content_type ?? "", "blocked-body path must set the request content type");
            fail_if_not_eq_str("slot-token-stream-cancel", capture.custom_header ?? "", "blocked-body path must forward slot headers before cancellation");
            fail_if_not_eq_int((int) upload_size, (int) capture.content_length, "blocked-body path must send the declared content length");
        } catch (Error e) {
            fail_if(true, @"HTTP PUT blocked-body cancellation test failed unexpectedly: $(e.message)");
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (server != null) ((!) server).disconnect();
            session.abort();
        }
    }

    bool skip_if_local_sockets_unavailable() {
        string error_message;
        if (local_test_sockets_available(out error_message)) return false;

        GLib.Test.skip("Local HTTP upload test sockets unavailable: %s".printf(error_message));
        return true;
    }

    bool local_test_sockets_available(out string error_message) {
        error_message = "";
        Soup.Server? probe = null;
        try {
            probe = new Soup.Server("server-header", "DinoX-HttpUpload-Probe/1.0", null);
            probe.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            return true;
        } catch (Error e) {
            error_message = e.message;
            return false;
        } finally {
            if (probe != null) ((!) probe).disconnect();
        }
    }

    Soup.Server start_upload_server(uint response_status, UploadCapture capture, out string upload_url) throws Error {
        var server = new Soup.Server("server-header", "DinoX-HttpUpload-Test/1.0", null);
        server.add_handler("/upload/plain.bin", (srv, msg, path, query) => {
            capture.handled = true;
            capture.method = msg.get_method();
            capture.content_type = msg.get_request_headers().get_one("Content-Type");
            capture.custom_header = msg.get_request_headers().get_one("X-DinoX-Test-Token");
            capture.content_length = msg.get_request_headers().get_content_length();
            capture.body = copy_bytes(msg.get_request_body().flatten());
            msg.set_status(response_status, null);
            set_server_string_response(msg, "text/plain", "ok");
        });
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        upload_url = get_server_url(server, "/upload/plain.bin");
        return server;
    }

    Soup.Server start_cancel_after_request_server(UploadCapture capture, Dino.Entities.FileTransfer file_transfer, out string upload_url) throws Error {
        var server = new Soup.Server("server-header", "DinoX-HttpUpload-Cancel-Test/1.0", null);
        server.add_handler("/upload/cancel.bin", (srv, msg, path, query) => {
            capture.handled = true;
            capture.method = msg.get_method();
            capture.content_type = msg.get_request_headers().get_one("Content-Type");
            capture.custom_header = msg.get_request_headers().get_one("X-DinoX-Test-Token");
            capture.content_length = msg.get_request_headers().get_content_length();
            capture.body = copy_bytes(msg.get_request_body().flatten());
            file_transfer.cancellable.cancel();
            msg.set_status(201, null);
            set_server_string_response(msg, "text/plain", "cancelled");
        });
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        upload_url = get_server_url(server, "/upload/cancel.bin");
        return server;
    }

    Soup.Server start_body_stream_cancel_server(StreamingUploadCapture capture, out string upload_url) throws Error {
        var server = new Soup.Server("server-header", "DinoX-HttpUpload-Body-Cancel-Test/1.0", null);
        server.request_started.connect((msg) => {
            capture.mark_request_started();
            msg.got_headers.connect(() => {
                capture.mark_headers_seen(msg);
            });
        });
        server.request_read.connect((msg) => {
            capture.mark_request_read();
        });
        server.add_handler("/upload/blocking.bin", (srv, msg, path, query) => {
            capture.mark_handler_called();
            msg.set_status(500, null);
            set_server_string_response(msg, "text/plain", "unexpected complete body");
        });
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        upload_url = get_server_url(server, "/upload/blocking.bin");
        return server;
    }

    string get_server_url(Soup.Server server, string path) {
        foreach (var uri in server.get_uris()) {
            string base_url = uri.to_string();
            if (base_url.has_suffix("/")) {
                base_url = base_url.substring(0, base_url.length - 1);
            }
            return base_url + path;
        }
        GLib.error("Local HTTP upload test server did not expose a URI");
    }

    Dino.HttpFileSendData create_upload_send_data(string upload_url) {
        return new Dino.HttpFileSendData() {
            url_down = "http://127.0.0.1/download/plain.bin",
            url_up = upload_url,
            headers = new Gee.HashMap<string, string>(),
            encrypt_message = false
        };
    }

    Dino.Entities.FileTransfer create_upload_transfer(uint8[] payload) {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.input_stream = new MemoryInputStream.from_data(payload);
        return file_transfer;
    }

    private void assert_upload_cancelled(Cancellable cancellable, Dino.FileSendError error, string context) {
        // GIO translates its cancellation message using the system locale.
        // Check the actual cancellation state and preserved native message,
        // rather than assuming that the error contains the English "cancel".
        try {
            cancellable.set_error_if_cancelled();
            fail_if(true, @"$(context): transfer cancellable was not cancelled");
        } catch (IOError cause) {
            fail_if(!(cause is IOError.CANCELLED), @"$(context): expected GIO cancellation");
            fail_if(!error.message.contains(cause.message),
                @"$(context): cancellation cause was not preserved: $(error.message)");
        }
    }

    Dino.FileMeta create_upload_meta(int64 size, string mime_type) {
        var meta = new Dino.FileMeta();
        meta.size = size;
        meta.mime_type = mime_type;
        return meta;
    }

    uint8[] copy_bytes(Bytes bytes) {
        unowned uint8[]? raw_maybe = bytes.get_data();
        if (raw_maybe == null) return new uint8[0];

        unowned uint8[] raw = (!) raw_maybe;
        uint8[] copy = new uint8[raw.length];
        for (int i = 0; i < raw.length; i++) {
            copy[i] = raw[i];
        }
        return copy;
    }

    void assert_bytes_equal(uint8[] expected, uint8[] actual, string reason) {
        fail_if_not_eq_int(expected.length, actual.length, reason);
        int length = int.min(expected.length, actual.length);
        for (int i = 0; i < length; i++) {
            if (expected[i] != actual[i]) {
                fail_if(true, @"$(reason): byte $(i) expected $(expected[i]) got $(actual[i])");
                return;
            }
        }
    }

    class UploadCapture : Object {
        public bool handled = false;
        public string method = "";
        public string? content_type = null;
        public string? custom_header = null;
        public int64 content_length = -1;
        public uint8[] body = new uint8[0];
    }

    class StreamingUploadCapture : Object {
        private DinoTest.Mutex mutex = DinoTest.Mutex();

        public bool request_started = false;
        public bool headers_seen = false;
        public bool request_read = false;
        public bool handler_called = false;
        public string method = "";
        public string? content_type = null;
        public string? custom_header = null;
        public int64 content_length = -1;

        public void mark_request_started() {
            mutex.lock();
            request_started = true;
            mutex.unlock();
        }

        public void mark_headers_seen(Soup.ServerMessage msg) {
            mutex.lock();
            headers_seen = true;
            method = msg.get_method();
            content_type = msg.get_request_headers().get_one("Content-Type");
            custom_header = msg.get_request_headers().get_one("X-DinoX-Test-Token");
            content_length = msg.get_request_headers().get_content_length();
            mutex.unlock();
        }

        public void mark_request_read() {
            mutex.lock();
            request_read = true;
            mutex.unlock();
        }

        public void mark_handler_called() {
            mutex.lock();
            handler_called = true;
            mutex.unlock();
        }

        public bool headers_observed() {
            mutex.lock();
            bool result = headers_seen;
            mutex.unlock();
            return result;
        }
    }

    class BlockingUploadInputStream : DinoNative.InputStream {
        private uint8[] first_chunk;
        private Cancellable transfer_cancellable;
        private StreamingUploadCapture capture;
        private int first_chunk_offset = 0;
        private bool cancel_thread_started = false;

        public bool first_chunk_seen = false;
        public bool blocking_read_seen = false;
        public bool blocking_read_saw_cancellable = false;
        public bool blocking_read_missing_cancellable = false;
        public bool cancelled_after_headers_seen = false;
        public bool cancel_seen = false;
        public bool closed = false;
        public int read_count = 0;

        public BlockingUploadInputStream(uint8[] first_chunk, Cancellable transfer_cancellable, StreamingUploadCapture capture) {
            this.transfer_cancellable = transfer_cancellable;
            this.capture = capture;
            this.first_chunk = new uint8[first_chunk.length];
            for (int i = 0; i < first_chunk.length; i++) {
                this.first_chunk[i] = first_chunk[i];
            }
        }

        public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            read_count++;
            if (buffer.length == 0) return 0;

            if (first_chunk_offset < first_chunk.length) {
                first_chunk_seen = true;
                int to_copy = int.min(buffer.length, first_chunk.length - first_chunk_offset);
                for (int i = 0; i < to_copy; i++) {
                    ((uint8*) buffer)[i] = first_chunk[first_chunk_offset + i];
                }
                first_chunk_offset += to_copy;
                return to_copy;
            }

            blocking_read_seen = true;
            if (cancellable == null) {
                blocking_read_missing_cancellable = true;
                throw new IOError.FAILED("blocking upload stream read did not receive cancellable");
            }

            blocking_read_saw_cancellable = true;
            if (!cancel_thread_started) {
                cancel_thread_started = true;
                new Thread<void*>("http-upload-body-cancel", () => {
                    int64 header_deadline = get_monotonic_time() + 1000 * 1000;
                    while (!capture.headers_observed() && get_monotonic_time() < header_deadline) {
                        Thread.usleep(10 * 1000);
                    }
                    cancelled_after_headers_seen = capture.headers_observed();
                    transfer_cancellable.cancel();
                    return null;
                });
            }

            int64 deadline = get_monotonic_time() + 1000 * 1000;
            while (!cancellable.is_cancelled() && get_monotonic_time() < deadline) {
                Thread.usleep(10 * 1000);
            }
            if (!cancellable.is_cancelled()) {
                throw new IOError.FAILED("blocking upload stream read did not receive the transfer cancellable");
            }

            cancel_seen = true;
            cancellable.set_error_if_cancelled();
            assert_not_reached();
        }

        public override bool close(Cancellable? cancellable = null) throws IOError {
            closed = true;
            return true;
        }
    }
}

class HttpPrepareSendFileTest : Gee.TestCase {
    private const string NS_0 = "urn:xmpp:http:upload:0";
    // Local-only self-signed certificate for the HTTPS upload test server.
    private const string TEST_TLS_CERT_PEM =
        "-----BEGIN CERTIFICATE-----\n" +
        "MIIDJTCCAg2gAwIBAgIUAhF95gtnalr8y81Axt8frgTCgvkwDQYJKoZIhvcNAQEL\n" +
        "BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDUyMTExMTYxOVoXDTI2MDYy\n" +
        "MDExMTYxOVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF\n" +
        "AAOCAQ8AMIIBCgKCAQEAyQevtKaCNgbZHMvi27zJkn55fXRdy9XTN/xXH+Obonop\n" +
        "9P73QymYNst1MaUEmL9pSUOjzW6Iu7Ee/Jb1VqKGyW79WVobVpe8+b1j4Mr5BMTJ\n" +
        "nunYQSpQzmNQB8C9+WeVQ/PY6xZUth74fChZyDY73gAGzdeKdbQBLCxPNkyeD9Og\n" +
        "PSeva9p0jCpZRYqZ3VR6jADlIyTzVh5f2zRpH7bG9Dg0FURyi+wAH+7aWqA6arnE\n" +
        "ZjzAXGcEyqvZKsLcsTsOBw6ERdQkSi32okbx0wqnY0GZULQOED+9UrQPi0iklsgx\n" +
        "jqzB9uJoXPN7eT/l3FJec50umUovkeH0SzHYyIS0AwIDAQABo28wbTAdBgNVHQ4E\n" +
        "FgQUzJ8OLEvDkZIle0qvYkO8/jXP1fkwHwYDVR0jBBgwFoAUzJ8OLEvDkZIle0qv\n" +
        "YkO8/jXP1fkwDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SH\n" +
        "BH8AAAEwDQYJKoZIhvcNAQELBQADggEBAICTb927FYJeKDxfeSqxv5J7BuvoH2+B\n" +
        "JB0bD8Lt62p/d2wcHzSY52VTJN8jS6iLqy4sS+R2OVTRcYJoLy0edkmll36YHGpC\n" +
        "CqC31HoYoS+zzoyVTLoCvB/EMNUJVIdO5yaHOXLU3mhnKS4f77Gu24805jofkz7X\n" +
        "8OD5kAKEGhNDQXnMW/j61LD3KJ8Z4rcOd7/jwkQiTbI8Xw7pbV2dtZuq7i0pEjeO\n" +
        "USrSIlFc/PcBb1ZwEYQYziSJRx4F3KJudTt16WXMHJfILCGcMfNqzTQjP2zZ5a0P\n" +
        "ohhMeUAxA2dLsSyZixHPR2mD89hxS9VaAnDFXZLJkQP8HmgNYCPgUB4=\n" +
        "-----END CERTIFICATE-----\n";
    private const string TEST_TLS_KEY_PEM =
        "-----BEGIN PRIVATE KEY-----\n" +
        "MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDJB6+0poI2Btkc\n" +
        "y+LbvMmSfnl9dF3L1dM3/Fcf45uiein0/vdDKZg2y3UxpQSYv2lJQ6PNboi7sR78\n" +
        "lvVWoobJbv1ZWhtWl7z5vWPgyvkExMme6dhBKlDOY1AHwL35Z5VD89jrFlS2Hvh8\n" +
        "KFnINjveAAbN14p1tAEsLE82TJ4P06A9J69r2nSMKllFipndVHqMAOUjJPNWHl/b\n" +
        "NGkftsb0ODQVRHKL7AAf7tpaoDpqucRmPMBcZwTKq9kqwtyxOw4HDoRF1CRKLfai\n" +
        "RvHTCqdjQZlQtA4QP71StA+LSKSWyDGOrMH24mhc83t5P+XcUl5znS6ZSi+R4fRL\n" +
        "MdjIhLQDAgMBAAECggEAEeORHNv1jPXTPsiphKp9X3/JgA+P9zJG0pEUdn4ZHLGO\n" +
        "56idFTw8bNSlgztVhOHOCAFKY5IF/eAwyzZqjGdeSjEjv153pB8dms9IXFODkST3\n" +
        "2IajqIZ2j8WIdIaQATa/MoxRzcQV2enSOXr+JLhaxhJHiLkfYgKYjIQNSnfLJJcL\n" +
        "FLZY5hNK7NXdtMLbD2GPxV6boP20RjJ2G75QgAWBltwXNH5EIaSbkdwFIbJWA76H\n" +
        "BoDmTuKIW/sG+1PrrgLQajXLVD9HujTP8QUzyNA1SEFzAy4qd3xixr5O3f0TQY2v\n" +
        "ylAD93o+sBdQQZop4IIwIR4swxCgau6xxAUvj0IN5QKBgQD+6uRhKumk3kyIsno+\n" +
        "3xwfi9beR6a4adyu5kk7NaLDeSQ6FcQzQHQKxGltS5gNlBc0bppupZiXg/acA9oE\n" +
        "fMnyv0YPiwSdiqWceXQc4XREobrbQY5hrKOLP65NfLyC5kypSgckRcKjN8n9Odmg\n" +
        "E2zJR2y+eWQ47M4DnUbwgzN9hQKBgQDJ4jdCjwPuuvYPtIlhrUdHKrWnIMGEKOTH\n" +
        "mAu8SEVhDnLAKkVFbl51WRS8PQ3wMj7CuBageU9ZVDzJ3TvKgfw6AuMXNNeu9lys\n" +
        "TlKKKTNDZdw7dP4M446ueKggV566hKeHIHr4sIxtumR/KzXr6GugtnaHRhxWvG9H\n" +
        "svsjAJr95wKBgD2quSDAbtERbdZLxsLa2kTPYWVYU/6crWQqFWEbcopzDc53YYU8\n" +
        "fFX2ecKU3O27+3kVoIpPyQAuTkQjsmQPhBMTLnGoIa+y0KlvwCUUbToFHdzYmQcL\n" +
        "6mxPNW1NVZUc/UKew+eEcLdnUZfOnNTaniB7BNV3LEWRE61QKM8aDiS5AoGAZ/42\n" +
        "VvvSm8QFAlwONJmM0PUIM7ok1Q43ozUIPom/61oE9EYR/sz2rV4g10JgDq3jNGyd\n" +
        "gzZaEHrbAWUL6qoAomVgU1DuFXtki4Gg9Ph6JqquwpXmU/9YPTl76YUZB51TqsCp\n" +
        "d7eB7vgH0pYQpZ/I6TV0YwRTjr5sWDOzN/mU3VsCgYAX89eyEiaR8m/qZ/DooR9f\n" +
        "ltRlBftqOr5zeBNOwYUCwYLWRxEKjw2ZI0U2PC5qiw3gP1DaoQoyJOwlmBZzOjt0\n" +
        "7XYQGMGaC7zV+4fHZF5+eHWPGBwBKLi3oQiTrG0oGUXsuADHSElC2BdoUCPioU8I\n" +
        "QLGGyD3xP6tEjJJnA1idVw==\n" +
        "-----END PRIVATE KEY-----\n";
    private const string NS_OMEMO_LEGACY = "eu.siacs.conversations.axolotl";
    private const string NS_OPENPGP = "urn:xmpp:openpgp:0";
    private const string NS_OPENPGP_LEGACY = "jabber:x:encrypted";
    private const string FILE_PROTOCOL_XEP0027 = "openpgp:xep0027";
    private const string FILE_PROTOCOL_XEP0374 = "openpgp:xep0374";
    private const string PGP_MIME_TYPE = "application/pgp-encrypted";

    public HttpPrepareSendFileTest() {
        base("HttpPrepareSendFile");
        add_test("CONTRACT_prepare_send_file_requests_slot_and_returns_http_send_data", test_prepare_plain_success_sync);
        add_test("SECURITY_prepare_send_file_direct_encrypted_slot_includes_gcm_tag", test_prepare_direct_encrypted_success_sync);
        add_test("CONTRACT_prepare_send_file_maps_slot_error_to_file_send_error", test_prepare_slot_error_sync);
        add_test("CONTRACT_prepare_send_file_cancel_during_pending_slot", test_prepare_slot_cancel_sync);
        add_test("CONTRACT_prepare_send_file_stream_detach_is_transient_slot_failure", test_prepare_slot_detach_sync);
        add_test("CONTRACT_file_manager_send_file_rejects_invalid_slot_before_announcement", test_file_manager_real_sender_upload_validation_sync);
        add_test("CONTRACT_file_manager_send_file_uses_real_http_sender_https_put_and_complete", test_file_manager_real_sender_https_put_success_sync);
        add_test("CONCURRENCY_file_manager_sends_independent_sources_to_multiple_contacts", test_file_manager_parallel_multiple_contacts_sync);
        add_test("CONTRACT_file_manager_send_file_real_http_sender_https_put_status_failure", test_file_manager_real_sender_https_put_status_failure_sync);
        add_test("CONTRACT_file_manager_send_file_real_http_sender_cancel_after_sfs_share", test_file_manager_real_sender_cancel_after_sfs_share_sync);
        add_test("CONTRACT_file_manager_send_file_real_http_sender_cancel_after_put_request", test_file_manager_real_sender_cancel_after_put_request_sync);
        add_test("CONTRACT_file_manager_send_file_real_http_sender_cancel_while_request_body_stream_blocks", test_file_manager_real_sender_cancel_while_request_body_stream_blocks_sync);
        add_test("SECURITY_file_manager_real_http_sender_direct_omemo_https_put_body_only", test_file_manager_real_sender_direct_omemo_https_put_body_only_sync);
        add_test("SECURITY_file_manager_real_http_sender_pgp_xep0374_https_put_body_only", test_file_manager_real_sender_pgp_xep0374_https_put_body_only_sync);
        add_test("SECURITY_file_manager_real_http_sender_pgp_xep0027_https_put_body_only", test_file_manager_real_sender_pgp_xep0027_https_put_body_only_sync);
    }

    void test_prepare_plain_success_sync() {
        try {
            var setup = create_prepare_setup();
            var file_transfer = create_prepare_transfer(setup.account, Dino.Entities.Encryption.NONE, "plain-wire-name.txt");
            var file_meta = create_prepare_meta(321, "text/plain", false);
            var loop = new MainLoop();

            setup.sender.prepare_send_file.begin(setup.conversation, file_transfer, file_meta, (obj, res) => {
                try {
                    var data = setup.sender.prepare_send_file.end(res);
                    var send_data = data as Dino.HttpFileSendData;
                    fail_if(send_data == null,
                        "prepare_send_file must return HTTP send data after a successful slot request");
                    if (send_data != null) {
                        fail_if(send_data is EncryptedHttpFileSendData,
                            "plain transfers must not allocate direct encrypted HTTP send data");
                        fail_if_not_eq_str("https://upload.example.test/get/plain-wire-name.txt", send_data.url_down);
                        fail_if_not_eq_str("https://upload.example.test/put/plain-wire-name.txt", send_data.url_up);
                        fail_if_not_eq_str("Bearer slot-token", send_data.headers["Authorization"]);
                        fail_if(send_data.headers.has_key("Host"),
                            "prepare_send_file must keep the request_slot header allowlist result");
                    }
                } catch (Error e) {
                    fail_if(true, @"prepare_send_file plain success failed unexpectedly: $(e.message)");
                } finally {
                    setup.sender.shutdown();
                    loop.quit();
                }
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "plain-wire-name.txt", "321", "text/plain");
                var result_iq = build_slot_result_for_request(
                    outgoing,
                    "https://upload.example.test/get/plain-wire-name.txt",
                    "https://upload.example.test/put/plain-wire-name.txt"
                );
                append_slot_header(result_iq, "Authorization", "Bearer slot-token");
                append_slot_header(result_iq, "Host", "bad.example");
                setup.stream.emit_iq_result(result_iq);
            });

            loop.run();
        } catch (Error e) {
            fail_if(true, @"prepare_send_file plain setup failed: $(e.message)");
        }
    }

    void test_prepare_direct_encrypted_success_sync() {
        try {
            var setup = create_prepare_setup();
            var file_transfer = create_prepare_transfer(setup.account, Dino.Entities.Encryption.OMEMO, "secret-photo.jpg");
            var file_meta = create_prepare_meta(1024, "image/jpeg", false);
            var loop = new MainLoop();

            setup.sender.prepare_send_file.begin(setup.conversation, file_transfer, file_meta, (obj, res) => {
                try {
                    var data = setup.sender.prepare_send_file.end(res);
                    var send_data = data as EncryptedHttpFileSendData;
                    fail_if(send_data == null,
                        "direct encrypted transfers must allocate encrypted HTTP send data before upload");
                    if (send_data != null) {
                        fail_if_not_eq_int(32, send_data.key.length,
                            "direct encrypted HTTP send data must allocate a 256-bit AES key");
                        fail_if_not_eq_int(12, send_data.iv.length,
                            "direct encrypted HTTP send data must allocate a 96-bit GCM IV");
                        fail_if_not_eq_str("https://upload.example.test/get/secret-photo.jpg", send_data.url_down);
                        fail_if_not_eq_str("https://upload.example.test/put/secret-photo.jpg", send_data.url_up);
                    }
                } catch (Error e) {
                    fail_if(true, @"prepare_send_file encrypted success failed unexpectedly: $(e.message)");
                } finally {
                    setup.sender.shutdown();
                    loop.quit();
                }
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "secret-photo.jpg", "1040", "image/jpeg");
                setup.stream.emit_iq_result(build_slot_result_for_request(
                    outgoing,
                    "https://upload.example.test/get/secret-photo.jpg",
                    "https://upload.example.test/put/secret-photo.jpg"
                ));
            });

            loop.run();
        } catch (Error e) {
            fail_if(true, @"prepare_send_file encrypted setup failed: $(e.message)");
        }
    }

    void test_prepare_slot_error_sync() {
        try {
            var setup = create_prepare_setup();
            var file_transfer = create_prepare_transfer(setup.account, Dino.Entities.Encryption.NONE, "downgrade.txt");
            var file_meta = create_prepare_meta(12, "text/plain", false);
            var loop = new MainLoop();

            setup.sender.prepare_send_file.begin(setup.conversation, file_transfer, file_meta, (obj, res) => {
                try {
                    setup.sender.prepare_send_file.end(res);
                    fail_if(true, "prepare_send_file must reject an invalid slot result");
                } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                    fail_if(!e.message.contains("Http file upload XMPP error"),
                        @"slot failures must keep the FileSendError prefix, got: $(e.message)");
                } catch (Error e) {
                    fail_if(true, @"Unexpected prepare_send_file failure type: $(e.message)");
                } finally {
                    setup.sender.shutdown();
                    loop.quit();
                }
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "downgrade.txt", "12", "text/plain");
                setup.stream.emit_iq_result(build_slot_result_for_request(
                    outgoing,
                    "http://upload.example.test/get/downgrade.txt",
                    "https://upload.example.test/put/downgrade.txt"
                ));
            });

            loop.run();
        } catch (Error e) {
            fail_if(true, @"prepare_send_file error setup failed: $(e.message)");
        }
    }

    void test_prepare_slot_cancel_sync() {
        try {
            var setup = create_prepare_setup();
            var file_transfer = create_prepare_transfer(setup.account, Dino.Entities.Encryption.NONE, "cancel-slot.txt");
            var file_meta = create_prepare_meta(18, "text/plain", false);
            var loop = new MainLoop();

            setup.sender.prepare_send_file.begin(setup.conversation, file_transfer, file_meta, (obj, res) => {
                try {
                    setup.sender.prepare_send_file.end(res);
                    fail_if(true, "prepare_send_file must stop when its pending slot request is cancelled");
                } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                    fail_if(!file_transfer.cancellable.is_cancelled(), "the transfer cancellable must remain cancelled");
                    fail_if(!e.message.down().contains("upload slot"), @"slot cancellation must reach FileSendError through the upload-slot path: $(e.message)");
                } catch (Error e) {
                    fail_if(true, @"Unexpected prepare_send_file cancellation type: $(e.message)");
                } finally {
                    setup.sender.shutdown();
                    loop.quit();
                }
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "cancel-slot.txt", "18", "text/plain");
                file_transfer.cancellable.cancel();
            });

            loop.run();
        } catch (Error e) {
            fail_if(true, @"prepare_send_file cancellation setup failed: $(e.message)");
        }
    }

    void test_prepare_slot_detach_sync() {
        try {
            var setup = create_prepare_setup();
            var file_transfer = create_prepare_transfer(setup.account, Dino.Entities.Encryption.NONE, "detach-slot.txt");
            var file_meta = create_prepare_meta(22, "text/plain", false);
            var loop = new MainLoop();

            setup.sender.prepare_send_file.begin(setup.conversation, file_transfer, file_meta, (obj, res) => {
                try {
                    setup.sender.prepare_send_file.end(res);
                    fail_if(true, "prepare_send_file must stop when the XMPP stream detaches");
                } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                    fail_if(file_transfer.cancellable.is_cancelled(), "stream detach must not be classified as a user cancellation");
                    fail_if(!e.message.down().contains("upload slot"), @"stream detach must reach FileManager as a transient upload-slot failure: $(e.message)");
                } catch (Error e) {
                    fail_if(true, @"Unexpected prepare_send_file detach failure type: $(e.message)");
                } finally {
                    setup.sender.shutdown();
                    loop.quit();
                }
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "detach-slot.txt", "22", "text/plain");
                setup.stream.get_module<Xmpp.Iq.Module>(Xmpp.Iq.Module.IDENTITY).detach(setup.stream);
            });

            loop.run();
        } catch (Error e) {
            fail_if(true, @"prepare_send_file detach setup failed: $(e.message)");
        }
    }

    void test_file_manager_real_sender_upload_validation_sync() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider.txt");
        FileManagerSetup? setup_opt = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real-provider test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real-provider test must publish a stored outgoing path before transport");
                File? stored_file = file_transfer.get_file();
                fail_if(stored_file == null || !((!) stored_file).query_exists(),
                    "FileManager real-provider test must use the production storage path for the outgoing local copy");
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: Http file upload XMPP error: Error getting upload/download url: Received invalid HTTPS URL from server*");

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "real-provider.txt", payload.length.to_string(), "text/plain");
                var result_iq = build_slot_result_for_request(
                    outgoing,
                    "https://upload.example.test/get/real-provider.txt",
                    "https://["
                );
                append_slot_header(result_iq, "Authorization", "Bearer real-provider");
                setup.stream.emit_iq_result(result_iq);
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager real-provider send must publish the locally saved transfer before HTTP send failure");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.provider != setup.sender.get_id(),
                "FileManager must select the real HTTP sender for the unencrypted upload-capable path");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "invalid HTTP upload URL from a parsed slot must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "invalid HTTP upload URL must persist as failed transfer state");
            fail_if(file_transfer.phase_error == null ||
                    !((!) file_transfer.phase_error).contains("Received invalid HTTPS URL"),
                "invalid XEP-0363 slot error must surface on the FileManager transfer");
            fail_if(file_transfer.info != null,
                "an invalid slot must fail before linking an unusable SFS file-share message");
            fail_if(file_transfer.file_sharing_id != null,
                "an invalid slot must fail before assigning a file-sharing id");
            fail_if(has_written_sfs_share_message(setup.stream),
                "an invalid slot must not announce an unusable file-share stanza");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after invalid slot failure");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must store the local outgoing copy before the real HTTP sender requests a slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.FAILED,
                "invalid XEP-0363 slot validation must become the final failed phase");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING),
                "an invalid slot must fail before entering upload");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "an invalid slot must fail before entering announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "invalid slot validation must not emit COMPLETE");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist the invalid XEP-0363 slot failure");
        } catch (Error e) {
            fail_if(true, @"FileManager real HTTP sender upload-validation test failed: $(e.message)");
        } finally {
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_https_put_success_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-success.txt");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender HTTPS success payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;
            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, setup.stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager real-provider HTTPS success test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real-provider HTTPS success test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real-provider HTTPS success test must publish a stored outgoing path before transport");
            });

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-success.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "real-provider-success.txt", payload.length.to_string(), "text/plain");
                var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                append_slot_header(result_iq, "Authorization", "Bearer local-success");
                setup.stream.emit_iq_result(result_iq);
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager real-provider HTTPS send must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(!capture.handled, "real HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method, "real HTTP sender must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "", "real HTTP sender must set the request content type");
            fail_if_not_eq_str("Bearer local-success", capture.authorization ?? "", "real HTTP sender must forward allowed slot headers");
            fail_if_not_eq_int(payload.length, (int) capture.content_length, "real HTTP sender must send the final content length");
            assert_bytes_equal(payload, capture.body, "real HTTP sender must upload the original unencrypted payload bytes");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful real HTTP sender upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful real HTTP sender upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful real HTTP sender upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful real HTTP sender upload must link the SFS file-share message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful real HTTP sender upload must assign a file-sharing id");
            fail_if(capture.written_count_at_upload < 0,
                "real HTTP sender HTTPS success test must capture the stanza boundary at PUT time");
            assert_sfs_share_before_and_attachment_after(setup.stream, capture.written_count_at_upload, (!) file_transfer.file_sharing_id, download_url);
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful real HTTP sender upload");
            assert_single_http_source(file_transfer, download_url,
                "successful real HTTP sender upload must keep one local HTTP source on the sent transfer");
            assert_persisted_http_source(setup.db, file_transfer, download_url,
                "successful real HTTP sender upload must persist the SFS HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must store the local outgoing copy before the real HTTP sender requests a slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before real HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "the real unencrypted HTTP sender must announce the SFS share around upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful real HTTP sender upload must finish in COMPLETE after announcement");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful real HTTP sender upload as complete");
        } catch (Error e) {
            fail_if(true, @"FileManager real HTTP sender HTTPS success test failed: $(e.message)");
        } finally {
            if (server != null) {
                ((!) server).disconnect();
            }
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_parallel_multiple_contacts_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-parallel-" + Uuid.string_random());
        string first_input_path = Path.build_filename(temp_dir, "parallel-source-a.bin");
        string second_input_path = Path.build_filename(temp_dir, "parallel-source-b.bin");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        var stored_paths = new Gee.ArrayList<string>();
        uint timeout_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string first_payload_text = "parallel FileManager upload payload A\n";
            string second_payload_text = "independent parallel upload payload B\n";
            uint8[] first_payload = first_payload_text.data;
            uint8[] second_payload = second_payload_text.data;
            FileUtils.set_contents(first_input_path, first_payload_text);
            FileUtils.set_contents(second_input_path, second_payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;
            var second_conversation = new Dino.Entities.Conversation(
                new Xmpp.Jid("carol@example.test"), setup.account, Dino.Entities.Conversation.Type.CHAT);
            second_conversation.encryption = Dino.Entities.Encryption.NONE;
            second_conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            second_conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            var third_conversation = new Dino.Entities.Conversation(
                new Xmpp.Jid("dave@example.test"), setup.account, Dino.Entities.Conversation.Type.CHAT);
            third_conversation.encryption = Dino.Entities.Encryption.NONE;
            third_conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            third_conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            var capture = new ParallelHttpsUploadCapture();
            string first_upload_url;
            string first_download_url;
            string second_upload_url;
            string second_download_url;
            string third_upload_url;
            string third_download_url;
            TlsCertificate tls_cert;
            server = start_parallel_https_upload_server(capture,
                out first_upload_url, out first_download_url,
                out second_upload_url, out second_download_url,
                out third_upload_url, out third_download_url,
                out tls_cert);
            string? upload_host = Uri.parse(first_upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "parallel HTTPS upload test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var transfers = new Gee.ArrayList<Dino.Entities.FileTransfer>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                transfers.add(file_transfer);
                if (file_transfer.path != null) stored_paths.add((!) file_transfer.path);
            });

            int completed = 0;
            var send_loop = new MainLoop();
            SourceFunc finish_one = () => {
                completed++;
                if (completed == 3) send_loop.quit();
                return Source.REMOVE;
            };

            setup.manager.send_file.begin(File.new_for_path(first_input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "parallel-first.bin";
                file_transfer.mime_type = "application/octet-stream";
                file_transfer.size = (int64) first_payload.length;
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                finish_one();
            });
            setup.manager.send_file.begin(File.new_for_path(second_input_path), second_conversation, (file_transfer) => {
                file_transfer.server_file_name = "parallel-second.bin";
                file_transfer.mime_type = "application/octet-stream";
                file_transfer.size = (int64) second_payload.length;
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                finish_one();
            });
            // Reuse source A for a third contact as an additional collision guard.
            setup.manager.send_file.begin(File.new_for_path(first_input_path), third_conversation, (file_transfer) => {
                file_transfer.server_file_name = "parallel-third.bin";
                file_transfer.mime_type = "application/octet-stream";
                file_transfer.size = (int64) first_payload.length;
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                finish_one();
            });

            respond_to_matching_slot_request_when_written(setup.stream,
                "parallel-first.bin", first_payload.length.to_string(), "application/octet-stream", (outgoing) => {
                    setup.stream.emit_iq_result(build_slot_result_for_request(outgoing, first_download_url, first_upload_url));
                });
            respond_to_matching_slot_request_when_written(setup.stream,
                "parallel-second.bin", second_payload.length.to_string(), "application/octet-stream", (outgoing) => {
                    setup.stream.emit_iq_result(build_slot_result_for_request(outgoing, second_download_url, second_upload_url));
                });
            respond_to_matching_slot_request_when_written(setup.stream,
                "parallel-third.bin", first_payload.length.to_string(), "application/octet-stream", (outgoing) => {
                    setup.stream.emit_iq_result(build_slot_result_for_request(outgoing, third_download_url, third_upload_url));
                });

            if (completed < 3) {
                timeout_id = Timeout.add_seconds(15, () => {
                    timeout_id = 0;
                    capture.release_paused_response();
                    send_loop.quit();
                    return Source.REMOVE;
                });
                send_loop.run();
            }
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            drain_pending_events();

            fail_if(completed != 3, "all parallel sends must return without hanging");
            fail_if(!capture.overlap_observed,
                "another contact upload must start while the first request is still active");
            fail_if(transfers.size != 3, "parallel sends must publish three independent transfers");
            fail_if(stored_paths.size != 3 ||
                    stored_paths[0] == stored_paths[1] ||
                    stored_paths[0] == stored_paths[2] ||
                    stored_paths[1] == stored_paths[2],
                "parallel sends must use distinct stored copies for every transfer");
            assert_bytes_equal(first_payload, capture.first_body,
                "the first contact must receive the complete source payload");
            assert_bytes_equal(second_payload, capture.second_body,
                "the second contact must receive its independent source payload");
            assert_bytes_equal(first_payload, capture.third_body,
                "the third contact must receive the complete reused source payload");

            bool saw_bob = false;
            bool saw_carol = false;
            bool saw_dave = false;
            foreach (Dino.Entities.FileTransfer transfer in transfers) {
                fail_if(transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "each parallel transfer must complete independently");
                fail_if(!transfer.input_stream.is_closed(),
                    "each parallel transfer must close only its own input stream");
                if (transfer.counterpart.equals_bare(setup.conversation.counterpart)) saw_bob = true;
                if (transfer.counterpart.equals_bare(second_conversation.counterpart)) saw_carol = true;
                if (transfer.counterpart.equals_bare(third_conversation.counterpart)) saw_dave = true;
            }
            fail_if(!saw_bob || !saw_carol || !saw_dave,
                "parallel sends must remain assigned to their original conversations");
        } catch (Error e) {
            fail_if(true, @"Parallel multi-contact HTTP send test failed: $(e.message)");
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (server != null) ((!) server).disconnect();
            foreach (string stored_path in stored_paths) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), stored_path));
            }
            FileUtils.remove(first_input_path);
            FileUtils.remove(second_input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_https_put_status_failure_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-status-failure.txt");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender HTTPS status failure payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;
            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(503, capture, setup.stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager real-provider HTTPS status-failure test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real-provider HTTPS status-failure test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real-provider HTTPS status-failure test must publish a stored outgoing path before transport");
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Send file error: HTTP upload error: HTTP status code 503*");

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-status-failure.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "real-provider-status-failure.txt", payload.length.to_string(), "text/plain");
                var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                append_slot_header(result_iq, "Authorization", "Bearer local-status-failure");
                setup.stream.emit_iq_result(result_iq);
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager real-provider HTTPS status failure must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(!capture.handled, "real HTTP sender status-failure path must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method, "real HTTP sender status-failure path must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "", "real HTTP sender status-failure path must set the request content type");
            fail_if_not_eq_str("Bearer local-status-failure", capture.authorization ?? "", "real HTTP sender status-failure path must forward allowed slot headers");
            fail_if_not_eq_int(payload.length, (int) capture.content_length, "real HTTP sender status-failure path must send the final content length");
            assert_bytes_equal(payload, capture.body, "real HTTP sender status-failure path must upload the original unencrypted payload bytes before failing");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "non-2xx real HTTP sender upload status must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "non-2xx real HTTP sender upload status must persist FAILED state");
            fail_if(file_transfer.phase_error == null || !((!) file_transfer.phase_error).contains("HTTP status code 503"),
                "non-2xx real HTTP sender upload status must surface on the FileManager transfer");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "real HTTP sender status-failure path must link the SFS file-share message before PUT");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "real HTTP sender status-failure path must assign a file-sharing id before PUT");
            fail_if(capture.written_count_at_upload < 0,
                "real HTTP sender HTTPS status-failure test must capture the stanza boundary at PUT time");
            assert_sfs_share_before_without_attachment_after(setup.stream, capture.written_count_at_upload, (!) file_transfer.file_sharing_id);
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after real HTTP sender status failure");
            assert_no_http_sources(file_transfer,
                "failed real HTTP sender upload must not add a local SFS HTTP source");
            assert_no_persisted_sources(setup.db, file_transfer,
                "failed real HTTP sender upload must not persist an SFS HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must store the local outgoing copy before the real HTTP sender requests a slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before real HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "the real unencrypted HTTP sender must announce the SFS share before the status-failing PUT");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.FAILED,
                "real HTTP sender status failure must become the final failed phase");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "real HTTP sender status failure must not emit COMPLETE");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist real HTTP sender status failure as failed");
        } catch (Error e) {
            fail_if(true, @"FileManager real HTTP sender HTTPS status-failure test failed: $(e.message)");
        } finally {
            if (server != null) {
                ((!) server).disconnect();
            }
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_direct_omemo_https_put_body_only_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-omemo.txt");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;
        ulong pre_message_send_handler_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender synthetic OMEMO HTTPS payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;
            setup.conversation.encryption = Dino.Entities.Encryption.OMEMO;

            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, setup.stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager synthetic OMEMO HTTPS test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            string expected_aesgcm_prefix = "aesgcm://" + download_url.substring("https://".length) + "#";
            var omemo_capture = new SyntheticOmemoSendCapture();
            var processor = setup.stream_interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            fail_if(processor == null,
                "FileManager synthetic OMEMO HTTPS test must have a MessageProcessor");
            pre_message_send_handler_id = ((!) processor).pre_message_send.connect((message, stanza, conversation) => {
                if (conversation != setup.conversation) return;
                if (message.encryption != Dino.Entities.Encryption.OMEMO) return;
                string? body = stanza.body;
                if (body == null || !((!) body).has_prefix(expected_aesgcm_prefix)) return;

                omemo_capture.body_url = (!) body;
                omemo_capture.matched_messages++;
                stanza.body = "[This message is OMEMO encrypted]";
                stanza.stanza.put_node(new StanzaNode.build("encrypted", NS_OMEMO_LEGACY).add_self_xmlns());
            });

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager synthetic OMEMO HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager synthetic OMEMO HTTPS test must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(setup.stream, "real-provider-omemo.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer local-omemo");
                    setup.stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-omemo.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager synthetic OMEMO HTTPS send must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.provider != setup.sender.get_id(),
                "FileManager must select the real HTTP sender for the synthetic OMEMO upload-capable path");
            fail_if(!capture.handled,
                "synthetic OMEMO real HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method, "synthetic OMEMO real HTTP sender must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "", "synthetic OMEMO real HTTP sender must set the request content type");
            fail_if_not_eq_str("Bearer local-omemo", capture.authorization ?? "", "synthetic OMEMO real HTTP sender must forward allowed slot headers");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "synthetic OMEMO direct HTTP-GCM upload must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "synthetic OMEMO captured PUT body must include the 16-byte GCM tag");
            fail_if(bytes_equal(payload, capture.body),
                "synthetic OMEMO direct HTTP-GCM upload must not upload plaintext bytes");

            fail_if(omemo_capture.matched_messages != 1,
                "synthetic OMEMO hook must wrap exactly one aesgcm body-url message");
            fail_if(omemo_capture.body_url == null,
                "synthetic OMEMO hook must capture the direct encrypted aesgcm body URL");
            var url_parts = parse_aesgcm_url((!) omemo_capture.body_url);
            fail_if_not_eq_str(download_url, url_parts.https_url,
                "synthetic OMEMO aesgcm body URL must point to the HTTPS download URL before its secret fragment");
            uint8[] decrypted = decrypt_aesgcm_with_attached_tag(capture.body, url_parts.key, url_parts.iv);
            assert_bytes_equal(payload, decrypted,
                "synthetic OMEMO captured PUT body must decrypt with the key and IV carried in the encrypted body URL");

            StanzaNode? omemo_message = find_legacy_omemo_message(setup.stream);
            fail_if(omemo_message == null,
                "synthetic OMEMO send must write a legacy OMEMO payload stanza");
            if (omemo_message != null) {
                StanzaNode? body_node = ((!) omemo_message).get_subnode("body");
                fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is OMEMO encrypted]",
                    "synthetic OMEMO sent stanza must expose only the OMEMO fallback body outside the encrypted payload");
            }
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(setup.stream, download_url, (!) omemo_capture.body_url,
                "synthetic OMEMO body-only send must not expose file metadata outside the OMEMO payload");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful synthetic OMEMO real HTTP sender upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful synthetic OMEMO real HTTP sender upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful synthetic OMEMO real HTTP sender upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful synthetic OMEMO upload must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful synthetic OMEMO upload must assign a local file-sharing id");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful synthetic OMEMO upload");
            assert_single_http_source(file_transfer, download_url,
                "successful synthetic OMEMO upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(setup.db, file_transfer, download_url,
                "successful synthetic OMEMO upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must store the local outgoing copy before synthetic OMEMO slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before synthetic OMEMO HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "synthetic OMEMO direct HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful synthetic OMEMO direct HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful synthetic OMEMO real HTTP sender upload as complete");
        } catch (Error e) {
            fail_if(true, @"FileManager synthetic OMEMO real HTTP sender HTTPS test failed: $(e.message)");
        } finally {
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                if (pre_message_send_handler_id != 0) {
                    var processor = setup.stream_interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
                    if (processor != null) {
                        SignalHandler.disconnect((!) processor, pre_message_send_handler_id);
                    }
                }
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (server != null) {
                ((!) server).disconnect();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_pgp_xep0374_https_put_body_only_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-pgp.txt");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;
        ulong pre_message_send_handler_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender synthetic OpenPGP HTTPS payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;
            setup.conversation.encryption = Dino.Entities.Encryption.PGP;

            var encryptor = new SyntheticPgpFileEncryptor(FILE_PROTOCOL_XEP0374, PGP_MIME_TYPE, payload.length);
            setup.manager.add_file_encryptor(encryptor);

            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, setup.stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager synthetic OpenPGP HTTPS test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var pgp_capture = new SyntheticPgpSendCapture();
            var processor = setup.stream_interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            fail_if(processor == null,
                "FileManager synthetic OpenPGP HTTPS test must have a MessageProcessor");
            pre_message_send_handler_id = ((!) processor).pre_message_send.connect((message, stanza, conversation) => {
                if (conversation != setup.conversation) return;
                if (message.encryption != Dino.Entities.Encryption.PGP) return;
                string? body = stanza.body;
                if (body == null || ((!) body) != download_url) return;

                pgp_capture.body_url = (!) body;
                pgp_capture.matched_messages++;
                stanza.body = "[This message is encrypted with OpenPGP for XMPP (XEP-0373/0374)]";
                string synthetic_payload = "protocol=%s\nbody-url=%s\n".printf(FILE_PROTOCOL_XEP0374, (!) body);
                stanza.stanza.put_node(new StanzaNode.build("openpgp", NS_OPENPGP)
                    .add_self_xmlns()
                    .put_node(new StanzaNode.text(Base64.encode(synthetic_payload.data))));
                stanza.stanza.put_node(new StanzaNode.build("encryption", "urn:xmpp:eme:0")
                    .add_self_xmlns()
                    .put_attribute("namespace", NS_OPENPGP)
                    .put_attribute("name", "OpenPGP for XMPP"));
            });

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager synthetic OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager synthetic OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(setup.stream, "real-provider-pgp.txt.pgp",
                encryptor.encrypted_payload.length.to_string(), PGP_MIME_TYPE, (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer local-pgp");
                    setup.stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-pgp.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager synthetic OpenPGP HTTPS send must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(!encryptor.encrypt_called,
                "synthetic OpenPGP send must call the selected external file encryptor before requesting a slot");
            fail_if(!encryptor.preprocess_called,
                "synthetic OpenPGP send must preprocess HTTP send data so the body URL is encrypted in the message");
            fail_if_not_eq_int(payload.length, encryptor.observed_plaintext_length,
                "synthetic OpenPGP file encryptor must consume the original plaintext stream before upload");
            fail_if(file_transfer.provider != setup.sender.get_id(),
                "FileManager must select the real HTTP sender for the synthetic OpenPGP upload-capable path");
            fail_if(!capture.handled,
                "synthetic OpenPGP real HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method, "synthetic OpenPGP real HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, capture.content_type ?? "", "synthetic OpenPGP real HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-pgp", capture.authorization ?? "", "synthetic OpenPGP real HTTP sender must forward allowed slot headers");
            fail_if_not_eq_int(encryptor.encrypted_payload.length, (int) capture.content_length,
                "synthetic OpenPGP upload must use the encrypted payload size without an AES-GCM tag");
            fail_if_not_eq_int(encryptor.encrypted_payload.length, capture.body.length,
                "synthetic OpenPGP captured PUT body must match the encrypted payload length");
            assert_bytes_equal(encryptor.encrypted_payload, capture.body,
                "synthetic OpenPGP captured PUT body must be the pre-encrypted PGP payload");
            fail_if(bytes_equal(payload, capture.body),
                "synthetic OpenPGP real HTTP upload must not upload plaintext bytes");

            fail_if(pgp_capture.matched_messages != 1,
                "synthetic OpenPGP hook must wrap exactly one HTTPS body-url message");
            fail_if(pgp_capture.body_url == null,
                "synthetic OpenPGP hook must capture the HTTPS body URL");
            fail_if_not_eq_str(download_url, (!) pgp_capture.body_url,
                "synthetic OpenPGP body URL must be the HTTPS download URL before encryption");

            StanzaNode? openpgp_message = find_openpgp_message(setup.stream);
            fail_if(openpgp_message == null,
                "synthetic OpenPGP send must write an XEP-0374 OpenPGP payload stanza");
            if (openpgp_message != null) {
                StanzaNode? body_node = ((!) openpgp_message).get_subnode("body");
                fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is encrypted with OpenPGP for XMPP (XEP-0373/0374)]",
                    "synthetic OpenPGP sent stanza must expose only the OpenPGP fallback body outside the encrypted payload");
                StanzaNode? openpgp_node = ((!) openpgp_message).get_subnode("openpgp", NS_OPENPGP);
                fail_if(openpgp_node == null,
                    "synthetic OpenPGP sent stanza must carry an XEP-0374 payload node");
                if (openpgp_node != null) {
                    string synthetic_payload = (string) Base64.decode(((!) openpgp_node).get_string_content());
                    fail_if(!synthetic_payload.contains("protocol=" + FILE_PROTOCOL_XEP0374),
                        "synthetic OpenPGP payload must record the XEP-0374 protocol boundary");
                    fail_if(!synthetic_payload.contains("body-url=" + download_url),
                        "synthetic OpenPGP payload must contain the body URL inside the encoded payload");
                }
                fail_if(((!) openpgp_message).get_subnode("x", NS_OPENPGP_LEGACY) != null,
                    "synthetic XEP-0374 OpenPGP send must not fall back to legacy XEP-0027 payload markup");
            }
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(setup.stream, download_url, download_url,
                "synthetic OpenPGP body-only send must not expose file metadata outside the OpenPGP payload");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful synthetic OpenPGP real HTTP sender upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful synthetic OpenPGP real HTTP sender upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful synthetic OpenPGP real HTTP sender upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful synthetic OpenPGP upload must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful synthetic OpenPGP upload must assign a local file-sharing id");
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.PGP,
                "successful synthetic OpenPGP upload must keep the frozen transfer encryption");
            fail_if_not_eq_str(FILE_PROTOCOL_XEP0374, file_transfer.encryption_protocol ?? "",
                "successful synthetic OpenPGP upload must record the XEP-0374 file encryption protocol");
            fail_if_not_eq_str("real-provider-pgp.txt.pgp", file_transfer.server_file_name ?? "",
                "synthetic OpenPGP file encryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful synthetic OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful synthetic OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(setup.db, file_transfer, download_url,
                "successful synthetic OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before synthetic OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must finish synthetic OpenPGP file encryption before requesting the XEP-0363 slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before synthetic OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "synthetic OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful synthetic OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful synthetic OpenPGP real HTTP sender upload as complete");
        } catch (Error e) {
            fail_if(true, @"FileManager synthetic OpenPGP real HTTP sender HTTPS test failed: $(e.message)");
        } finally {
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                if (pre_message_send_handler_id != 0) {
                    var processor = setup.stream_interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
                    if (processor != null) {
                        SignalHandler.disconnect((!) processor, pre_message_send_handler_id);
                    }
                }
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (server != null) {
                ((!) server).disconnect();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_pgp_xep0027_https_put_body_only_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-pgp-legacy.txt");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;
        ulong pre_message_send_handler_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender synthetic legacy OpenPGP HTTPS payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;
            setup.conversation.encryption = Dino.Entities.Encryption.PGP;

            var encryptor = new SyntheticPgpFileEncryptor(FILE_PROTOCOL_XEP0027, PGP_MIME_TYPE, payload.length);
            setup.manager.add_file_encryptor(encryptor);

            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, setup.stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager synthetic legacy OpenPGP HTTPS test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var pgp_capture = new SyntheticPgpSendCapture();
            var processor = setup.stream_interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            fail_if(processor == null,
                "FileManager synthetic legacy OpenPGP HTTPS test must have a MessageProcessor");
            pre_message_send_handler_id = ((!) processor).pre_message_send.connect((message, stanza, conversation) => {
                if (conversation != setup.conversation) return;
                if (message.encryption != Dino.Entities.Encryption.PGP) return;
                string? body = stanza.body;
                if (body == null || ((!) body) != download_url) return;

                pgp_capture.body_url = (!) body;
                pgp_capture.matched_messages++;
                stanza.body = "[This message is OpenPGP encrypted (see XEP-0027)]";
                string synthetic_payload = "protocol=%s\nbody-url=%s\n".printf(FILE_PROTOCOL_XEP0027, (!) body);
                stanza.stanza.put_node(new StanzaNode.build("x", NS_OPENPGP_LEGACY)
                    .add_self_xmlns()
                    .put_node(new StanzaNode.text(Base64.encode(synthetic_payload.data))));
                stanza.stanza.put_node(new StanzaNode.build("encryption", "urn:xmpp:eme:0")
                    .add_self_xmlns()
                    .put_attribute("namespace", NS_OPENPGP_LEGACY)
                    .put_attribute("name", "OpenPGP legacy"));
            });

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager synthetic legacy OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager synthetic legacy OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(setup.stream, "real-provider-pgp-legacy.txt.pgp",
                encryptor.encrypted_payload.length.to_string(), PGP_MIME_TYPE, (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer local-pgp-legacy");
                    setup.stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-pgp-legacy.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager synthetic legacy OpenPGP HTTPS send must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(!encryptor.encrypt_called,
                "synthetic legacy OpenPGP send must call the selected external file encryptor before requesting a slot");
            fail_if(!encryptor.preprocess_called,
                "synthetic legacy OpenPGP send must preprocess HTTP send data so the body URL is encrypted in the message");
            fail_if_not_eq_int(payload.length, encryptor.observed_plaintext_length,
                "synthetic legacy OpenPGP file encryptor must consume the original plaintext stream before upload");
            fail_if(file_transfer.provider != setup.sender.get_id(),
                "FileManager must select the real HTTP sender for the synthetic legacy OpenPGP upload-capable path");
            fail_if(!capture.handled,
                "synthetic legacy OpenPGP real HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method, "synthetic legacy OpenPGP real HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, capture.content_type ?? "", "synthetic legacy OpenPGP real HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-pgp-legacy", capture.authorization ?? "", "synthetic legacy OpenPGP real HTTP sender must forward allowed slot headers");
            fail_if_not_eq_int(encryptor.encrypted_payload.length, (int) capture.content_length,
                "synthetic legacy OpenPGP upload must use the encrypted payload size without an AES-GCM tag");
            fail_if_not_eq_int(encryptor.encrypted_payload.length, capture.body.length,
                "synthetic legacy OpenPGP captured PUT body must match the encrypted payload length");
            assert_bytes_equal(encryptor.encrypted_payload, capture.body,
                "synthetic legacy OpenPGP captured PUT body must be the pre-encrypted PGP payload");
            fail_if(bytes_equal(payload, capture.body),
                "synthetic legacy OpenPGP real HTTP upload must not upload plaintext bytes");

            fail_if(pgp_capture.matched_messages != 1,
                "synthetic legacy OpenPGP hook must wrap exactly one HTTPS body-url message");
            fail_if(pgp_capture.body_url == null,
                "synthetic legacy OpenPGP hook must capture the HTTPS body URL");
            fail_if_not_eq_str(download_url, (!) pgp_capture.body_url,
                "synthetic legacy OpenPGP body URL must be the HTTPS download URL before encryption");

            StanzaNode? legacy_message = find_legacy_openpgp_message(setup.stream);
            fail_if(legacy_message == null,
                "synthetic legacy OpenPGP send must write an XEP-0027 payload stanza");
            if (legacy_message != null) {
                StanzaNode? body_node = ((!) legacy_message).get_subnode("body");
                fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is OpenPGP encrypted (see XEP-0027)]",
                    "synthetic legacy OpenPGP sent stanza must expose only the XEP-0027 fallback body outside the encrypted payload");
                StanzaNode? legacy_node = ((!) legacy_message).get_subnode("x", NS_OPENPGP_LEGACY);
                fail_if(legacy_node == null,
                    "synthetic legacy OpenPGP sent stanza must carry an XEP-0027 payload node");
                if (legacy_node != null) {
                    string synthetic_payload = (string) Base64.decode(((!) legacy_node).get_string_content());
                    fail_if(!synthetic_payload.contains("protocol=" + FILE_PROTOCOL_XEP0027),
                        "synthetic legacy OpenPGP payload must record the XEP-0027 protocol boundary");
                    fail_if(!synthetic_payload.contains("body-url=" + download_url),
                        "synthetic legacy OpenPGP payload must contain the body URL inside the encoded payload");
                }
                fail_if(((!) legacy_message).get_subnode("openpgp", NS_OPENPGP) != null,
                    "synthetic XEP-0027 OpenPGP send must not use XEP-0374 payload markup");
            }
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(setup.stream, download_url, download_url,
                "synthetic legacy OpenPGP body-only send must not expose file metadata outside the XEP-0027 payload");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful synthetic legacy OpenPGP real HTTP sender upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful synthetic legacy OpenPGP real HTTP sender upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful synthetic legacy OpenPGP real HTTP sender upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful synthetic legacy OpenPGP upload must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful synthetic legacy OpenPGP upload must assign a local file-sharing id");
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.PGP,
                "successful synthetic legacy OpenPGP upload must keep the frozen transfer encryption");
            fail_if_not_eq_str(FILE_PROTOCOL_XEP0027, file_transfer.encryption_protocol ?? "",
                "successful synthetic legacy OpenPGP upload must record the XEP-0027 file encryption protocol");
            fail_if_not_eq_str("real-provider-pgp-legacy.txt.pgp", file_transfer.server_file_name ?? "",
                "synthetic legacy OpenPGP file encryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful synthetic legacy OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful synthetic legacy OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(setup.db, file_transfer, download_url,
                "successful synthetic legacy OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before synthetic legacy OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must finish synthetic legacy OpenPGP file encryption before requesting the XEP-0363 slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before synthetic legacy OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "synthetic legacy OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful synthetic legacy OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful synthetic legacy OpenPGP real HTTP sender upload as complete");
        } catch (Error e) {
            fail_if(true, @"FileManager synthetic legacy OpenPGP real HTTP sender HTTPS test failed: $(e.message)");
        } finally {
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                if (pre_message_send_handler_id != 0) {
                    var processor = setup.stream_interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
                    if (processor != null) {
                        SignalHandler.disconnect((!) processor, pre_message_send_handler_id);
                    }
                }
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (server != null) {
                ((!) server).disconnect();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_cancel_after_sfs_share_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-cancel-after-share.txt");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;
        ulong wrote_node_handler_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender cancel-after-share payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;
            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, setup.stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager real-provider cancel-after-share test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            int cancel_boundary = -1;
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real-provider cancel-after-share test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real-provider cancel-after-share test must publish a stored outgoing path before transport");
            });

            wrote_node_handler_id = setup.stream.wrote_node.connect((node) => {
                if (cancel_boundary >= 0 || published_transfer == null) return;

                Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
                if (file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "") return;
                if (node.name != "message") return;

                StanzaNode? file_sharing_node = node.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI);
                if (file_sharing_node == null) return;
                if (((!) file_sharing_node).get_attribute("id", Xmpp.Xep.StatelessFileSharing.NS_URI) != (!) file_transfer.file_sharing_id) return;

                cancel_boundary = setup.stream.written_nodes.size;
                file_transfer.cancellable.cancel();
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-cancel-after-share.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "real-provider-cancel-after-share.txt", payload.length.to_string(), "text/plain");
                var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                append_slot_header(result_iq, "Authorization", "Bearer local-cancel");
                setup.stream.emit_iq_result(result_iq);
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager real-provider cancel-after-share send must publish the locally saved transfer before transport");
            var file_transfer = (!) published_transfer;
            fail_if(capture.handled,
                "cancel after the matching SFS share must not reach the local HTTPS PUT endpoint");
            fail_if(cancel_boundary < 0,
                "cancel-after-share test must cancel exactly after writing the matching SFS share");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "cancel after SFS share must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "cancel after SFS share must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "cancel after SFS share must surface as a stable cancelled transfer error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "cancel after SFS share must have linked the initial SFS file-share message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "cancel after SFS share must have assigned a file-sharing id before cancellation");
            assert_sfs_share_before_without_attachment_after(setup.stream, cancel_boundary, (!) file_transfer.file_sharing_id);
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after canceling the real HTTP sender");
            assert_no_http_sources(file_transfer,
                "cancelled real HTTP sender upload must not add a local SFS HTTP source");
            assert_no_persisted_sources(setup.db, file_transfer,
                "cancelled real HTTP sender upload must not persist an SFS HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must store the local outgoing copy before the real HTTP sender requests a slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before entering upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "the real unencrypted HTTP sender must announce the SFS share before canceling");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.FAILED,
                "cancel after SFS share must become the final failed phase");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "cancel after SFS share must not emit COMPLETE");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist cancel after SFS share as failed");
        } catch (Error e) {
            fail_if(true, @"FileManager real HTTP sender cancel-after-share test failed: $(e.message)");
        } finally {
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                if (wrote_node_handler_id != 0) {
                    SignalHandler.disconnect(setup.stream, wrote_node_handler_id);
                }
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (server != null) {
                ((!) server).disconnect();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_cancel_after_put_request_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-cancel-after-put.txt");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string payload_text = "public FileManager to real HttpFileSender cancel-after-PUT payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real-provider cancel-after-PUT test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real-provider cancel-after-PUT test must publish a stored outgoing path before transport");
            });

            var capture = new HttpsUploadCapture();
            TlsCertificate tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
            server = new Soup.Server("server-header", "DinoX-HttpUpload-HTTPS-Cancel-Test/1.0", null);
            ((!) server).set_tls_certificate(tls_cert);
            ((!) server).add_handler("/upload/cancel-after-put.bin", (srv, msg, path, query) => {
                capture.handled = true;
                capture.written_count_at_upload = setup.stream.written_nodes.size;
                capture.method = msg.get_method();
                capture.content_type = msg.get_request_headers().get_one("Content-Type");
                capture.authorization = msg.get_request_headers().get_one("Authorization");
                capture.content_length = msg.get_request_headers().get_content_length();
                capture.body = copy_bytes(msg.get_request_body().flatten());
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                msg.set_status(201, null);
                set_server_string_response(msg, "text/plain", "cancelled");
            });
            ((!) server).listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
            string upload_url = get_https_server_url((!) server, "/upload/cancel-after-put.bin");
            string download_url = get_https_server_url((!) server, "/download/cancel-after-put.bin");
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager real-provider cancel-after-PUT test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-cancel-after-put.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "real-provider-cancel-after-put.txt", payload.length.to_string(), "text/plain");
                var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                append_slot_header(result_iq, "Authorization", "Bearer local-cancel-after-put");
                setup.stream.emit_iq_result(result_iq);
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "FileManager real-provider cancel-after-PUT send must publish the locally saved transfer before transport");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.provider != setup.sender.get_id(),
                "FileManager must select the real HTTP sender for the cancel-after-PUT upload-capable path");
            fail_if(!capture.handled,
                "cancel-after-PUT test must reach the local HTTPS PUT endpoint before cancellation");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "cancel-after-PUT test must cancel the transfer after the local HTTPS server receives the PUT request");
            fail_if_not_eq_str("PUT", capture.method, "cancel-after-PUT path must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "", "cancel-after-PUT path must set the request content type");
            fail_if_not_eq_str("Bearer local-cancel-after-put", capture.authorization ?? "", "cancel-after-PUT path must forward allowed slot headers before cancellation");
            fail_if_not_eq_int(payload.length, (int) capture.content_length, "cancel-after-PUT path must send the final content length");
            assert_bytes_equal(payload, capture.body, "cancel-after-PUT path must send the exact plain payload before cancellation");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "cancel after the PUT request reaches the server must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "cancel after the PUT request reaches the server must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "cancel after the PUT request reaches the server must surface as stable cancelled transfer error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "cancel after the PUT request reaches the server must have linked the initial SFS file-share message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "cancel after the PUT request reaches the server must have assigned a file-sharing id before cancellation");
            fail_if(capture.written_count_at_upload < 0,
                "cancel-after-PUT test must capture the stanza boundary at PUT time");
            assert_sfs_share_before_without_attachment_after(setup.stream, capture.written_count_at_upload, (!) file_transfer.file_sharing_id);
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after canceling the real HTTP sender at PUT time");
            assert_no_http_sources(file_transfer,
                "cancelled real HTTP sender PUT must not add a local SFS HTTP source");
            assert_no_persisted_sources(setup.db, file_transfer,
                "cancelled real HTTP sender PUT must not persist an SFS HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must store the local outgoing copy before the real HTTP sender requests a slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before entering upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "the real unencrypted HTTP sender must announce the SFS share before the cancel-after-PUT boundary");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.FAILED,
                "cancel after PUT request must become the final failed phase");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "cancel after PUT request must not emit COMPLETE");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist cancel after PUT request as failed");
        } catch (Error e) {
            fail_if(true, @"FileManager real HTTP sender cancel-after-PUT test failed: $(e.message)");
        } finally {
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (server != null) {
                ((!) server).disconnect();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_file_manager_real_sender_cancel_while_request_body_stream_blocks_sync() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-provider-blocked-body-cancel.bin");
        FileManagerSetup? setup_opt = null;
        Soup.Server? server = null;
        string? stored_path = null;
        uint timeout_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            int upload_size = 256 * 1024;
            FileUtils.set_contents(input_path, string.nfill(upload_size, 'x'));

            setup_opt = create_file_manager_setup();
            FileManagerSetup setup = (!) setup_opt;

            Dino.Entities.FileTransfer? published_transfer = null;
            FileManagerBlockingUploadInputStream? blocking_stream = null;
            bool upload_stream_replaced = false;
            bool timed_out = false;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            setup.manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager blocked-body cancel test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager blocked-body cancel test must publish a stored outgoing path before transport");
            });

            var capture = new FileManagerStreamingUploadCapture();
            TlsCertificate tls_cert;
            string upload_url;
            string download_url;
            server = start_https_body_stream_cancel_server(capture, setup.stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "FileManager blocked-body cancel test must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db(setup.db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            timeout_id = Timeout.add(5000, () => {
                timed_out = true;
                timeout_id = 0;
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                return Source.REMOVE;
            });

            uint8[] first_chunk = "partial FileManager blocked upload body".data;
            var send_loop = new MainLoop();
            setup.manager.send_file.begin(File.new_for_path(input_path), setup.conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-provider-blocked-body-cancel.bin";
                file_transfer.mime_type = "application/octet-stream";
                file_transfer.size = upload_size;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => {
                    phases.add(file_transfer.phase);
                    if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.UPLOADING && !upload_stream_replaced) {
                        upload_stream_replaced = true;
                        blocking_stream = new FileManagerBlockingUploadInputStream(first_chunk, file_transfer.cancellable, capture);
                        file_transfer.input_stream = (!) blocking_stream;
                    }
                });
            }, (obj, res) => {
                setup.manager.send_file.end(res);
                send_loop.quit();
            });

            respond_when_written(setup.stream, (outgoing) => {
                assert_prepare_request_iq(outgoing, "real-provider-blocked-body-cancel.bin", upload_size.to_string(), "application/octet-stream");
                var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                append_slot_header(result_iq, "Authorization", "Bearer local-blocked-body-cancel");
                setup.stream.emit_iq_result(result_iq);
            });

            send_loop.run();
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(timed_out,
                "FileManager blocked-body cancellation must be driven by the controlled stream read, not the timeout guard");
            fail_if(published_transfer == null,
                "FileManager blocked-body cancel send must publish the locally saved transfer before transport");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.provider != setup.sender.get_id(),
                "FileManager must select the real HTTP sender for the blocked-body upload-capable path");
            fail_if(!upload_stream_replaced || blocking_stream == null,
                "FileManager blocked-body test must replace the transport upload stream at the UPLOADING boundary");
            FileManagerBlockingUploadInputStream stream = (!) blocking_stream;
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "blocked-body test must cancel the transfer cancellable while the request body is blocked");
            fail_if(!capture.request_started,
                "blocked-body FileManager test must open a local HTTPS request before cancellation");
            fail_if(!capture.headers_seen,
                "blocked-body FileManager test must prove the server received PUT headers before the body completed");
            fail_if(capture.request_read,
                "blocked-body FileManager test must cancel before libsoup considers the full request body read");
            fail_if(capture.handler_called,
                "blocked-body FileManager test must not reach the normal PUT handler after a full request body");
            fail_if(!stream.first_chunk_seen,
                "blocked-body FileManager stream must send an initial body chunk before cancellation");
            fail_if(!stream.blocking_read_seen,
                "blocked-body FileManager stream must reach the blocking read after the initial chunk");
            fail_if(!stream.blocking_read_saw_cancellable,
                "blocked-body FileManager stream reads must receive a cancellable that observes transfer cancellation");
            fail_if(stream.blocking_read_missing_cancellable,
                "blocked-body FileManager stream must not be read without a cancellable");
            fail_if(!stream.cancelled_after_headers_seen,
                "blocked-body FileManager stream must trigger cancellation only after the server sees request headers");
            fail_if(!stream.cancel_seen,
                "blocked-body FileManager stream must observe cancellation while blocked");
            fail_if_not_eq_str("PUT", capture.method, "blocked-body FileManager path must use PUT");
            fail_if_not_eq_str("application/octet-stream", capture.content_type ?? "", "blocked-body FileManager path must set the request content type");
            fail_if_not_eq_str("Bearer local-blocked-body-cancel", capture.authorization ?? "", "blocked-body FileManager path must forward allowed slot headers before cancellation");
            fail_if_not_eq_int(upload_size, (int) capture.content_length, "blocked-body FileManager path must send the declared content length");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "cancel while the PUT request body is blocked must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "cancel while the PUT request body is blocked must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "cancel while the PUT request body is blocked must surface as stable cancelled transfer error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "cancel while the PUT request body is blocked must have linked the initial SFS file-share message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "cancel while the PUT request body is blocked must have assigned a file-sharing id before cancellation");
            fail_if(capture.written_count_at_headers < 0,
                "blocked-body FileManager test must capture the stanza boundary at PUT header time");
            assert_sfs_share_before_without_attachment_after(setup.stream, capture.written_count_at_headers, (!) file_transfer.file_sharing_id);
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after canceling the real HTTP sender while the body is blocked");
            fail_if(!stream.closed,
                "FileManager must close the underlying blocked upload stream after cancellation");
            assert_no_http_sources(file_transfer,
                "cancelled blocked-body HTTP sender upload must not add a local SFS HTTP source");
            assert_no_persisted_sources(setup.db, file_transfer,
                "cancelled blocked-body HTTP sender upload must not persist an SFS HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "FileManager must store the local outgoing copy before the blocked-body sender requests a slot");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before entering blocked-body upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "the real unencrypted HTTP sender must announce the SFS share before the blocked-body cancellation boundary");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.FAILED,
                "cancel while request body is blocked must become the final failed phase");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "cancel while request body is blocked must not emit COMPLETE");
            assert_persisted_transfer_state(setup.db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist cancel while request body is blocked as failed");
        } catch (Error e) {
            fail_if(true, @"FileManager real HTTP sender blocked-body cancel test failed: $(e.message)");
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (setup_opt != null) {
                FileManagerSetup setup = (!) setup_opt;
                setup.sender.shutdown();
                setup.db.close();
                FileUtils.remove(setup.db_path);
            }
            if (server != null) {
                ((!) server).disconnect();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    PrepareSetup create_prepare_setup() throws Error {
        _force_class_init(typeof(Dino.MessageProcessor));
        _force_class_init(typeof(Dino.MessageStorage));
        _force_class_init(typeof(Dino.FileTransferStorage));
        _force_class_init(typeof(Dino.FileManager));
        _force_class_init(typeof(Xmpp.Iq.Module));
        _force_class_init(typeof(Xmpp.MessageModule));
        _force_class_init(typeof(Xmpp.Bind.Flag));
        _force_class_init(typeof(Xmpp.Xep.HttpFileUpload.Module));

        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-prepare-" + Uuid.string_random() + ".db");
        var db = new Dino.Database(db_path, "http-files-prepare-test");
        var stream_interactor = new Dino.StreamInteractor.for_tests(db);
        Dino.MessageProcessor.start(stream_interactor, db);

        var sender = new HttpFileSender(stream_interactor, db);
        var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
        var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
        var stream = create_connected_slot_stream(stream_interactor, account);

        return new PrepareSetup(db_path, db, stream_interactor, sender, account, conversation, stream);
    }

    FileManagerSetup create_file_manager_setup() throws Error {
        _force_class_init(typeof(Dino.MessageProcessor));
        _force_class_init(typeof(Dino.MessageStorage));
        _force_class_init(typeof(Dino.FileTransferStorage));
        _force_class_init(typeof(Dino.FileManager));
        _force_class_init(typeof(Xmpp.Iq.Module));
        _force_class_init(typeof(Xmpp.MessageModule));
        _force_class_init(typeof(Xmpp.Bind.Flag));
        _force_class_init(typeof(Xmpp.Xep.HttpFileUpload.Module));

        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-http-files-file-manager-" + Uuid.string_random() + ".db");
        var db = new Dino.Database(db_path, "http-files-file-manager-test");
        var stream_interactor = new Dino.StreamInteractor.for_tests(db);
        Dino.MessageStorage.start(stream_interactor, db);
        Dino.FileTransferStorage.start(stream_interactor, db);
        Dino.MessageProcessor.start(stream_interactor, db);
        var file_encryption = new Dino.Security.FileEncryption("http-files-file-manager-test");
        Dino.FileManager.start(stream_interactor, db, file_encryption);
        var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
        if (manager == null) {
            throw new IOError.FAILED("missing FileManager in real HTTP sender test setup");
        }

        var sender = new HttpFileSender(stream_interactor, db);
        ((!) manager).add_sender(sender);

        var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
        account.persist(db);
        var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
        conversation.encryption = Dino.Entities.Encryption.NONE;
        conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
        conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
        var stream = create_connected_slot_stream(stream_interactor, account);

        return new FileManagerSetup(db_path, db, stream_interactor, (!) manager, sender, account, conversation, stream);
    }

    TestXmppStream create_connected_slot_stream(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account) throws Error {
        var stream = new TestXmppStream(new Xmpp.Jid("example.test"));
        var iq_module = stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(account, Xmpp.Iq.Module.IDENTITY);
        if (iq_module == null) {
            throw new IOError.FAILED("missing IQ module in test setup");
        }
        stream.add_module((!) iq_module);
        ((!) iq_module).attach(stream);
        var message_module = stream_interactor.module_manager.get_module<Xmpp.MessageModule>(account, Xmpp.MessageModule.IDENTITY);
        if (message_module == null) {
            throw new IOError.FAILED("missing message module in test setup");
        }
        stream.add_module((!) message_module);
        ((!) message_module).attach(stream);
        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream.add_flag(new Xmpp.Xep.HttpFileUpload.Flag(new Xmpp.Jid("upload.example.test"), NS_0));
        stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        var upload_module = stream_interactor.module_manager.get_module<Xmpp.Xep.HttpFileUpload.Module>(account, Xmpp.Xep.HttpFileUpload.Module.IDENTITY);
        if (upload_module == null) {
            throw new IOError.FAILED("missing HTTP upload module in test setup");
        }
        stream.stream_negotiated(stream);
        ((!) upload_module).feature_available(stream, long.MAX);
        return stream;
    }

    Dino.Entities.FileTransfer create_prepare_transfer(Dino.Entities.Account account, Dino.Entities.Encryption encryption, string server_file_name) throws Error {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.account = account;
        file_transfer.counterpart = new Xmpp.Jid("bob@example.test");
        file_transfer.ourpart = account.full_jid;
        file_transfer.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        file_transfer.file_name = "local-name.bin";
        file_transfer.server_file_name = server_file_name;
        file_transfer.encryption = encryption;
        file_transfer.size = 1024;
        file_transfer.input_stream = new MemoryInputStream.from_data("payload".data);
        return file_transfer;
    }

    Dino.FileMeta create_prepare_meta(int64 size, string mime_type, bool upload_payload_is_encrypted) {
        var meta = new Dino.FileMeta();
        meta.size = size;
        meta.mime_type = mime_type;
        meta.upload_payload_is_encrypted = upload_payload_is_encrypted;
        return meta;
    }

    void respond_when_written(TestXmppStream stream, owned WrittenIqHandler handler) {
        Idle.add(() => {
            StanzaNode? outgoing = stream.last_written;
            if (outgoing == null) return true;
            handler((!) outgoing);
            return false;
        });
    }

    void respond_to_matching_slot_request_when_written(TestXmppStream stream, string filename, string size, string content_type, owned WrittenIqHandler handler) {
        ulong handler_id = 0;
        handler_id = stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            StanzaNode? request = outgoing.get_subnode("request", NS_0);
            if (request == null) return;
            if (((!) request).get_attribute("filename") != filename) return;
            if (((!) request).get_attribute("size") != size) return;
            if (((!) request).get_attribute("content-type") != content_type) return;

            SignalHandler.disconnect(stream, handler_id);
            assert_prepare_request_iq(outgoing, filename, size, content_type);
            handler(outgoing);
        });
    }

    void assert_prepare_request_iq(StanzaNode iq, string filename, string size, string content_type) {
        fail_if_not_eq_str("iq", iq.name);
        fail_if_not_eq_str(Xmpp.Iq.Stanza.TYPE_GET, iq.get_attribute("type"));
        fail_if_not_eq_str("upload.example.test", iq.get_attribute("to"));
        fail_if(iq.get_attribute("id") == null, "prepare_send_file slot request IQ must have an id");

        StanzaNode? request = iq.get_subnode("request", NS_0);
        fail_if(request == null, "prepare_send_file must send an XEP-0363 v0 request node");
        if (request == null) return;

        fail_if_not_eq_str(filename, request.get_attribute("filename"));
        fail_if_not_eq_str(size, request.get_attribute("size"));
        fail_if_not_eq_str(content_type, request.get_attribute("content-type"));
    }

    StanzaNode build_slot_result_for_request(StanzaNode request_iq, string url_get, string url_put) {
        var result_iq = new StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? to = request_iq.get_attribute("to");
        if (to != null) result_iq.put_attribute("from", (!) to);

        var slot = new StanzaNode.build("slot", NS_0).add_self_xmlns();
        slot.put_node(new StanzaNode.build("get", NS_0).put_attribute("url", url_get));
        slot.put_node(new StanzaNode.build("put", NS_0).put_attribute("url", url_put));
        result_iq.put_node(slot);
        return result_iq;
    }

    void append_slot_header(StanzaNode result_iq, string name, string value) {
        StanzaNode? slot = result_iq.get_subnode("slot", NS_0);
        fail_if(slot == null, "slot result must contain slot node");
        if (slot == null) return;

        StanzaNode? put = slot.get_subnode("put", NS_0);
        fail_if(put == null, "slot result must contain put node");
        if (put == null) return;

        put.put_node(new StanzaNode.build("header", NS_0)
            .put_attribute("name", name)
            .put_node(new StanzaNode.text(value)));
    }

    private delegate void WrittenIqHandler(StanzaNode outgoing);

    void drain_pending_events() {
        for (int i = 0; i < 8; i++) {
            while (MainContext.default().pending()) {
                MainContext.default().iteration(false);
            }
        }
    }

    bool has_written_sfs_share_message(TestXmppStream stream) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null) {
                return true;
            }
        }
        return false;
    }

    void assert_sfs_share_before_and_attachment_after(TestXmppStream stream, int boundary, string file_sharing_id, string source_url) {
        int safe_boundary = int.min(int.max(boundary, 0), stream.written_nodes.size);
        string? share_stanza_id = null;

        for (int i = 0; i < safe_boundary; i++) {
            StanzaNode node = stream.written_nodes[i];
            if (node.name != "message") continue;

            StanzaNode? file_sharing_node = node.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI);
            if (file_sharing_node == null) continue;
            if (((!) file_sharing_node).get_attribute("id", Xmpp.Xep.StatelessFileSharing.NS_URI) != file_sharing_id) continue;

            share_stanza_id = node.get_attribute("id");
            if (share_stanza_id != null && ((!) share_stanza_id) != "") {
                break;
            }
        }

        fail_if(share_stanza_id == null || ((!) share_stanza_id) == "",
            "successful real HTTP sender upload must write the matching SFS file-share message before PUT");

        for (int i = safe_boundary; i < stream.written_nodes.size; i++) {
            StanzaNode node = stream.written_nodes[i];
            if (node.name != "message") continue;

            StanzaNode? attach_to = node.get_subnode("attach-to", Xmpp.Xep.MessageAttaching.NS_URI);
            if (attach_to == null || ((!) attach_to).get_attribute("id", Xmpp.Xep.MessageAttaching.NS_URI) != (!) share_stanza_id) continue;

            StanzaNode? sources = node.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI);
            if (sources == null) continue;
            if (((!) sources).get_attribute("id", Xmpp.Xep.StatelessFileSharing.NS_URI) != file_sharing_id) continue;
            if (Xmpp.Xep.HttpSchemeForUrlData.get_url((!) sources) == source_url) return;
        }

        fail_if(true,
            "successful real HTTP sender upload must write a matching SFS source attachment after PUT");
    }

    StanzaNode? find_legacy_omemo_message(TestXmppStream stream) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("encrypted", NS_OMEMO_LEGACY) != null) {
                return node;
            }
        }
        return null;
    }

    StanzaNode? find_openpgp_message(TestXmppStream stream) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("openpgp", NS_OPENPGP) != null) {
                return node;
            }
        }
        return null;
    }

    StanzaNode? find_legacy_openpgp_message(TestXmppStream stream) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("x", NS_OPENPGP_LEGACY) != null) {
                return node;
            }
        }
        return null;
    }

    void assert_no_cleartext_transfer_url_or_outer_file_stanzas(TestXmppStream stream, string download_url, string sensitive_body_url, string reason) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name != "message") continue;

            fail_if(node.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null,
                @"$(reason): unexpected outer SFS file-sharing element");
            fail_if(node.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI) != null,
                @"$(reason): unexpected outer SFS sources attachment");
            fail_if(node.get_subnode("attach-to", Xmpp.Xep.MessageAttaching.NS_URI) != null,
                @"$(reason): unexpected outer message-attachment element");
            fail_if(node.get_subnode("x", Xmpp.Xep.OutOfBandData.NS_URI) != null,
                @"$(reason): unexpected outer OOB URL element");

            StanzaNode? body_node = node.get_subnode("body");
            if (body_node != null) {
                string body = ((!) body_node).get_string_content();
                fail_if(body.has_prefix("aesgcm://") || body.contains(download_url) || body.contains(sensitive_body_url),
                    @"$(reason): unexpected cleartext transfer URL in message body");
            }

            string wire = node.to_string();
            fail_if(wire.contains(download_url) || wire.contains(sensitive_body_url),
                @"$(reason): unexpected cleartext transfer URL in outer stanza XML");
        }
    }

    void assert_sfs_share_before_without_attachment_after(TestXmppStream stream, int boundary, string file_sharing_id) {
        int safe_boundary = int.min(int.max(boundary, 0), stream.written_nodes.size);
        bool found_share = false;

        for (int i = 0; i < safe_boundary; i++) {
            StanzaNode node = stream.written_nodes[i];
            if (node.name != "message") continue;

            StanzaNode? file_sharing_node = node.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI);
            if (file_sharing_node == null) continue;
            if (((!) file_sharing_node).get_attribute("id", Xmpp.Xep.StatelessFileSharing.NS_URI) == file_sharing_id) {
                found_share = true;
                break;
            }
        }

        fail_if(!found_share,
            "failed real HTTP sender upload must write the matching SFS file-share message before PUT");

        for (int i = safe_boundary; i < stream.written_nodes.size; i++) {
            StanzaNode node = stream.written_nodes[i];
            if (node.name != "message") continue;

            StanzaNode? sources = node.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI);
            if (sources == null) continue;
            fail_if(((!) sources).get_attribute("id", Xmpp.Xep.StatelessFileSharing.NS_URI) == file_sharing_id,
                "failed real HTTP sender upload must not write the SFS source attachment after PUT failure");
        }
    }

    bool skip_if_local_https_sockets_unavailable() {
        TlsCertificate tls_cert;
        try {
            tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        } catch (Error e) {
            fail_if(true, @"Local HTTPS upload test certificate fixture must parse: $(e.message)");
            return false;
        }

        string error_message;
        if (local_https_test_sockets_available(tls_cert, out error_message)) return false;

        GLib.Test.skip("Local HTTPS upload test sockets unavailable: %s".printf(error_message));
        return true;
    }

    bool local_https_test_sockets_available(TlsCertificate tls_cert, out string error_message) {
        error_message = "";
        Soup.Server? probe = null;
        try {
            probe = new Soup.Server("server-header", "DinoX-HttpUpload-HTTPS-Probe/1.0", null);
            ((!) probe).set_tls_certificate(tls_cert);
            ((!) probe).listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
            return true;
        } catch (Error e) {
            error_message = e.message;
            return false;
        } finally {
            if (probe != null) ((!) probe).disconnect();
        }
    }

    Soup.Server start_https_upload_server(uint response_status, HttpsUploadCapture capture, TestXmppStream stream, out string upload_url, out string download_url, out TlsCertificate tls_cert) throws Error {
        tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        var server = new Soup.Server("server-header", "DinoX-HttpUpload-HTTPS-Test/1.0", null);
        server.set_tls_certificate(tls_cert);
        server.add_handler("/upload/plain.bin", (srv, msg, path, query) => {
            capture.handled = true;
            capture.written_count_at_upload = stream.written_nodes.size;
            capture.method = msg.get_method();
            capture.content_type = msg.get_request_headers().get_one("Content-Type");
            capture.authorization = msg.get_request_headers().get_one("Authorization");
            capture.content_length = msg.get_request_headers().get_content_length();
            capture.body = copy_bytes(msg.get_request_body().flatten());
            msg.set_status(response_status, null);
            set_server_string_response(msg, "text/plain", "ok");
        });
        server.listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
        upload_url = get_https_server_url(server, "/upload/plain.bin");
        download_url = get_https_server_url(server, "/download/plain.bin");
        return server;
    }

    Soup.Server start_parallel_https_upload_server(ParallelHttpsUploadCapture capture,
            out string first_upload_url, out string first_download_url,
            out string second_upload_url, out string second_download_url,
            out string third_upload_url, out string third_download_url,
            out TlsCertificate tls_cert) throws Error {
        tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        var server = new Soup.Server("server-header", "DinoX-Parallel-HttpUpload-Test/1.0", null);
        server.set_tls_certificate(tls_cert);
        server.add_handler("/upload/first.bin", (srv, msg, path, query) => {
            capture.handle_request(srv, msg, 0, copy_bytes(msg.get_request_body().flatten()));
        });
        server.add_handler("/upload/second.bin", (srv, msg, path, query) => {
            capture.handle_request(srv, msg, 1, copy_bytes(msg.get_request_body().flatten()));
        });
        server.add_handler("/upload/third.bin", (srv, msg, path, query) => {
            capture.handle_request(srv, msg, 2, copy_bytes(msg.get_request_body().flatten()));
        });
        server.listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
        first_upload_url = get_https_server_url(server, "/upload/first.bin");
        first_download_url = get_https_server_url(server, "/download/first.bin");
        second_upload_url = get_https_server_url(server, "/upload/second.bin");
        second_download_url = get_https_server_url(server, "/download/second.bin");
        third_upload_url = get_https_server_url(server, "/upload/third.bin");
        third_download_url = get_https_server_url(server, "/download/third.bin");
        return server;
    }

    Soup.Server start_https_body_stream_cancel_server(FileManagerStreamingUploadCapture capture, TestXmppStream stream, out string upload_url, out string download_url, out TlsCertificate tls_cert) throws Error {
        tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        var server = new Soup.Server("server-header", "DinoX-HttpUpload-HTTPS-Body-Cancel-Test/1.0", null);
        server.set_tls_certificate(tls_cert);
        server.request_started.connect((msg) => {
            capture.mark_request_started();
            msg.got_headers.connect(() => {
                capture.mark_headers_seen(msg, stream);
            });
        });
        server.request_read.connect((msg) => {
            capture.mark_request_read();
        });
        server.add_handler("/upload/blocking.bin", (srv, msg, path, query) => {
            capture.mark_handler_called();
            msg.set_status(500, null);
            set_server_string_response(msg, "text/plain", "unexpected complete body");
        });
        server.listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
        upload_url = get_https_server_url(server, "/upload/blocking.bin");
        download_url = get_https_server_url(server, "/download/blocking.bin");
        return server;
    }

    string get_https_server_url(Soup.Server server, string path) {
        foreach (Uri uri in server.get_uris()) {
            string base_url = uri.to_string();
            if (base_url.has_suffix("/")) {
                base_url = base_url.substring(0, base_url.length - 1);
            }
            return base_url + path;
        }
        GLib.error("Local HTTPS upload test server did not expose a URI");
    }

    uint8[] copy_bytes(Bytes bytes) {
        unowned uint8[]? raw_maybe = bytes.get_data();
        if (raw_maybe == null) return new uint8[0];

        unowned uint8[] raw = (!) raw_maybe;
        uint8[] copy = new uint8[raw.length];
        for (int i = 0; i < raw.length; i++) {
            copy[i] = raw[i];
        }
        return copy;
    }

    void assert_bytes_equal(uint8[] expected, uint8[] actual, string reason) {
        fail_if_not_eq_int(expected.length, actual.length, reason);
        int length = int.min(expected.length, actual.length);
        for (int i = 0; i < length; i++) {
            if (expected[i] != actual[i]) {
                fail_if(true, @"$(reason): byte $(i) expected $(expected[i]) got $(actual[i])");
                return;
            }
        }
    }

    bool bytes_equal(uint8[] expected, uint8[] actual) {
        if (expected.length != actual.length) return false;
        for (int i = 0; i < expected.length; i++) {
            if (expected[i] != actual[i]) return false;
        }
        return true;
    }

    AesgcmUrlParts parse_aesgcm_url(string url) throws Error {
        if (!url.has_prefix("aesgcm://")) {
            throw new IOError.FAILED("aesgcm URL must use aesgcm:// scheme");
        }
        int fragment_index = url.index_of("#");
        if (fragment_index < 0) {
            throw new IOError.FAILED("aesgcm URL must carry IV and key in the fragment");
        }

        string url_without_scheme = url.substring("aesgcm://".length, fragment_index - "aesgcm://".length);
        string secret_hex = url.substring(fragment_index + 1);
        if (secret_hex.length != 88) {
            throw new IOError.FAILED("aesgcm URL secret must be 12-byte IV plus 32-byte key encoded as hex");
        }

        uint8[] secret = parse_hex_bytes(secret_hex);
        uint8[] iv = new uint8[12];
        uint8[] key = new uint8[32];
        for (int i = 0; i < 12; i++) iv[i] = secret[i];
        for (int i = 0; i < 32; i++) key[i] = secret[12 + i];

        return new AesgcmUrlParts("https://" + url_without_scheme, iv, key);
    }

    uint8[] parse_hex_bytes(string hex) throws Error {
        if (hex.length % 2 != 0) {
            throw new IOError.FAILED("hex string must have an even length");
        }
        uint8[] bytes = new uint8[hex.length / 2];
        for (int i = 0; i < bytes.length; i++) {
            int high = hex_nibble(hex[i * 2]);
            int low = hex_nibble(hex[i * 2 + 1]);
            if (high < 0 || low < 0) {
                throw new IOError.FAILED("hex string contains a non-hex character");
            }
            bytes[i] = (uint8) ((high << 4) | low);
        }
        return bytes;
    }

    int hex_nibble(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    uint8[] decrypt_aesgcm_with_attached_tag(uint8[] encrypted, uint8[] key, uint8[] iv) throws Error {
        var cipher = new Crypto.SymmetricCipher("AES256-GCM");
        cipher.set_key(key);
        cipher.set_iv(iv);
        var input = new MemoryInputStream.from_data(encrypted);
        var decrypted_stream = new ConverterInputStream(input, new Crypto.SymmetricCipherDecrypter((owned) cipher, 16));
        return read_all(decrypted_stream);
    }

    uint8[] read_all(InputStream stream) throws Error {
        var data = new GLib.ByteArray();
        uint8[] chunk = new uint8[4096];
        while (true) {
            ssize_t read = stream.read(chunk);
            if (read <= 0) break;
            data.append(chunk[0:(int) read]);
        }
        stream.close();
        return data.data;
    }

    void assert_phase_order(Gee.List<Dino.Entities.FileTransfer.Phase> phases, Dino.Entities.FileTransfer.Phase before, Dino.Entities.FileTransfer.Phase after, string reason) {
        int before_index = -1;
        int after_index = -1;
        for (int i = 0; i < phases.size; i++) {
            if (phases[i] == before && before_index < 0) before_index = i;
            if (phases[i] == after && after_index < 0) after_index = i;
        }
        fail_if(before_index < 0 || after_index < 0 || before_index >= after_index, reason);
    }

    void assert_persisted_transfer_state(Dino.Database db, Dino.Entities.FileTransfer file_transfer, Dino.Entities.FileTransfer.State expected_state, string reason) {
        Qlite.RowOption row = db.file_transfer.select()
                .with(db.file_transfer.id, "=", file_transfer.id)
                .single()
                .row();
        fail_if(!row.is_present(), "real HTTP sender transfer must be present in the database");
        var persisted_state = (Dino.Entities.FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        fail_if(persisted_state != expected_state, reason);
    }

    void assert_single_http_source(Dino.Entities.FileTransfer file_transfer, string expected_url, string reason) {
        fail_if(file_transfer.sfs_sources.size != 1, reason);
        var http_source = file_transfer.sfs_sources[0] as Xmpp.Xep.StatelessFileSharing.HttpSource;
        fail_if(http_source == null, reason);
        fail_if_not_eq_str(expected_url, ((!) http_source).url, reason);
    }

    void assert_persisted_http_source(Dino.Database db, Dino.Entities.FileTransfer file_transfer, string expected_url, string reason) {
        int matches = 0;
        foreach (Qlite.Row row in db.sfs_sources.select().with(db.sfs_sources.file_transfer_id, "=", file_transfer.id)) {
            if (row[db.sfs_sources.type] == "http" && row[db.sfs_sources.data] == expected_url) {
                matches++;
            }
        }
        fail_if(matches != 1, reason);
    }

    void assert_only_persisted_http_source_without_secret(Dino.Database db, Dino.Entities.FileTransfer file_transfer, string expected_url, string reason) {
        int rows = 0;
        foreach (Qlite.Row row in db.sfs_sources.select().with(db.sfs_sources.file_transfer_id, "=", file_transfer.id)) {
            rows++;
            string type = row[db.sfs_sources.type];
            string data = row[db.sfs_sources.data];
            fail_if(type != "http", @"$(reason): unexpected persisted source type $(type)");
            fail_if_not_eq_str(expected_url, data, reason);
            fail_if(data.has_prefix("aesgcm://") || data.contains("#"),
                @"$(reason): persisted local source must not carry aesgcm secrets or fragments");
        }
        fail_if(rows != 1, reason);
    }

    void assert_no_http_sources(Dino.Entities.FileTransfer file_transfer, string reason) {
        fail_if(file_transfer.sfs_sources.size != 0, reason);
    }

    void assert_no_persisted_sources(Dino.Database db, Dino.Entities.FileTransfer file_transfer, string reason) {
        foreach (Qlite.Row row in db.sfs_sources.select().with(db.sfs_sources.file_transfer_id, "=", file_transfer.id)) {
            fail_if(true, @"$(reason): unexpected persisted source type $(row[db.sfs_sources.type])");
        }
    }

    private class PrepareSetup : Object {
        public string db_path;
        public Dino.Database db;
        public Dino.StreamInteractor stream_interactor;
        public HttpFileSender sender;
        public Dino.Entities.Account account;
        public Dino.Entities.Conversation conversation;
        public TestXmppStream stream;

        public PrepareSetup(string db_path, Dino.Database db, Dino.StreamInteractor stream_interactor, HttpFileSender sender, Dino.Entities.Account account, Dino.Entities.Conversation conversation, TestXmppStream stream) {
            this.db_path = db_path;
            this.db = db;
            this.stream_interactor = stream_interactor;
            this.sender = sender;
            this.account = account;
            this.conversation = conversation;
            this.stream = stream;
        }
    }

    private class FileManagerSetup : Object {
        public string db_path;
        public Dino.Database db;
        public Dino.StreamInteractor stream_interactor;
        public Dino.FileManager manager;
        public HttpFileSender sender;
        public Dino.Entities.Account account;
        public Dino.Entities.Conversation conversation;
        public TestXmppStream stream;

        public FileManagerSetup(string db_path, Dino.Database db, Dino.StreamInteractor stream_interactor, Dino.FileManager manager, HttpFileSender sender, Dino.Entities.Account account, Dino.Entities.Conversation conversation, TestXmppStream stream) {
            this.db_path = db_path;
            this.db = db;
            this.stream_interactor = stream_interactor;
            this.manager = manager;
            this.sender = sender;
            this.account = account;
            this.conversation = conversation;
            this.stream = stream;
        }
    }

    private class HttpsUploadCapture : Object {
        public bool handled = false;
        public string method = "";
        public string? content_type = null;
        public string? authorization = null;
        public int64 content_length = -1;
        public int written_count_at_upload = -1;
        public uint8[] body = new uint8[0];
    }

    private class ParallelHttpsUploadCapture : Object {
        public bool overlap_observed = false;
        public uint8[] first_body = new uint8[0];
        public uint8[] second_body = new uint8[0];
        public uint8[] third_body = new uint8[0];
        private Soup.ServerMessage? paused_response = null;
        private bool first_response_was_paused = false;

        public void handle_request(Soup.Server server, Soup.ServerMessage message, int transfer_index, owned uint8[] body) {
            switch (transfer_index) {
                case 0: first_body = (owned) body; break;
                case 1: second_body = (owned) body; break;
                case 2: third_body = (owned) body; break;
            }
            message.set_status(201, null);
            set_server_string_response(message, "text/plain", "ok");

            if (!first_response_was_paused) {
                first_response_was_paused = true;
                paused_response = message;
                message.pause();
                return;
            }

            if (paused_response != null) {
                overlap_observed = true;
                release_paused_response();
            }
        }

        public void release_paused_response() {
            if (paused_response == null) return;
            ((!) paused_response).unpause();
            paused_response = null;
        }
    }

    private class FileManagerStreamingUploadCapture : Object {
        private DinoTest.Mutex mutex = DinoTest.Mutex();

        public bool request_started = false;
        public bool headers_seen = false;
        public bool request_read = false;
        public bool handler_called = false;
        public string method = "";
        public string? content_type = null;
        public string? authorization = null;
        public int64 content_length = -1;
        public int written_count_at_headers = -1;

        public void mark_request_started() {
            mutex.lock();
            request_started = true;
            mutex.unlock();
        }

        public void mark_headers_seen(Soup.ServerMessage msg, TestXmppStream stream) {
            mutex.lock();
            headers_seen = true;
            method = msg.get_method();
            content_type = msg.get_request_headers().get_one("Content-Type");
            authorization = msg.get_request_headers().get_one("Authorization");
            content_length = msg.get_request_headers().get_content_length();
            written_count_at_headers = stream.written_nodes.size;
            mutex.unlock();
        }

        public void mark_request_read() {
            mutex.lock();
            request_read = true;
            mutex.unlock();
        }

        public void mark_handler_called() {
            mutex.lock();
            handler_called = true;
            mutex.unlock();
        }

        public bool headers_observed() {
            mutex.lock();
            bool result = headers_seen;
            mutex.unlock();
            return result;
        }
    }

    private class FileManagerBlockingUploadInputStream : DinoNative.InputStream {
        private uint8[] first_chunk;
        private Cancellable transfer_cancellable;
        private FileManagerStreamingUploadCapture capture;
        private int first_chunk_offset = 0;
        private bool cancel_thread_started = false;

        public bool first_chunk_seen = false;
        public bool blocking_read_seen = false;
        public bool blocking_read_saw_cancellable = false;
        public bool blocking_read_missing_cancellable = false;
        public bool cancelled_after_headers_seen = false;
        public bool cancel_seen = false;
        public bool closed = false;

        public FileManagerBlockingUploadInputStream(uint8[] first_chunk, Cancellable transfer_cancellable, FileManagerStreamingUploadCapture capture) {
            this.transfer_cancellable = transfer_cancellable;
            this.capture = capture;
            this.first_chunk = new uint8[first_chunk.length];
            for (int i = 0; i < first_chunk.length; i++) {
                this.first_chunk[i] = first_chunk[i];
            }
        }

        public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (buffer.length == 0) return 0;

            if (first_chunk_offset < first_chunk.length) {
                first_chunk_seen = true;
                int to_copy = int.min(buffer.length, first_chunk.length - first_chunk_offset);
                for (int i = 0; i < to_copy; i++) {
                    ((uint8*) buffer)[i] = first_chunk[first_chunk_offset + i];
                }
                first_chunk_offset += to_copy;
                return to_copy;
            }

            blocking_read_seen = true;
            if (cancellable == null) {
                blocking_read_missing_cancellable = true;
                throw new IOError.FAILED("FileManager blocked upload stream read did not receive cancellable");
            }

            blocking_read_saw_cancellable = true;
            if (!cancel_thread_started) {
                cancel_thread_started = true;
                new Thread<void*>("http-file-manager-body-cancel", () => {
                    int64 header_deadline = get_monotonic_time() + 1000 * 1000;
                    while (!capture.headers_observed() && get_monotonic_time() < header_deadline) {
                        Thread.usleep(10 * 1000);
                    }
                    cancelled_after_headers_seen = capture.headers_observed();
                    transfer_cancellable.cancel();
                    return null;
                });
            }

            int64 deadline = get_monotonic_time() + 1000 * 1000;
            while (!cancellable.is_cancelled() && get_monotonic_time() < deadline) {
                Thread.usleep(10 * 1000);
            }
            if (!cancellable.is_cancelled()) {
                throw new IOError.FAILED("FileManager blocked upload stream read did not receive the transfer cancellable");
            }

            cancel_seen = true;
            throw new IOError.CANCELLED("transfer cancelled while FileManager upload request body was blocked");
        }

        public override bool close(Cancellable? cancellable = null) throws IOError {
            closed = true;
            return true;
        }
    }

    private class SyntheticOmemoSendCapture : Object {
        public string? body_url = null;
        public int matched_messages = 0;
    }

    private class SyntheticPgpSendCapture : Object {
        public string? body_url = null;
        public int matched_messages = 0;
    }

    private class SyntheticPgpFileEncryptor : Dino.FileEncryptor, Dino.FileEncryptorSenderRequirement, Object {
        public bool encrypt_called = false;
        public bool preprocess_called = false;
        public int observed_plaintext_length = -1;
        public uint8[] encrypted_payload;
        private string protocol;
        private string mime_type;

        public SyntheticPgpFileEncryptor(string protocol, string mime_type, int plaintext_size) {
            this.protocol = protocol;
            this.mime_type = mime_type;
            string payload_text =
                "-----BEGIN DINOX SYNTHETIC PGP FILE-----\n" +
                "protocol=%s\n".printf(protocol) +
                "plain-size=%d\n".printf(plaintext_size) +
                "-----END DINOX SYNTHETIC PGP FILE-----\n";
            encrypted_payload = copy_string_data(payload_text);
        }

        public bool can_encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
            return file_transfer.encryption == Dino.Entities.Encryption.PGP;
        }

        public int get_required_file_sender_id() {
            return Dino.FileManager.HTTP_PROVIDER_ID;
        }

        public async Dino.FileMeta encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) throws Dino.FileSendError {
            encrypt_called = true;
            try {
                uint8[] plaintext = read_all_stream(file_transfer.input_stream);
                observed_plaintext_length = plaintext.length;
            } catch (Error e) {
                throw new Dino.FileSendError.ENCRYPTION_FAILED("Synthetic OpenPGP file encryption failed: %s".printf(e.message));
            }

            string? base_name = file_transfer.server_file_name;
            if (base_name == null || ((!) base_name).strip() == "") {
                base_name = file_transfer.file_name;
            }
            if (base_name == null || ((!) base_name).strip() == "") {
                base_name = Xmpp.random_uuid();
            }
            file_transfer.server_file_name = ((!) base_name).has_suffix(".pgp") ? (!) base_name : (!) base_name + ".pgp";
            file_transfer.encryption_protocol = protocol;
            file_transfer.input_stream = new MemoryInputStream.from_data(encrypted_payload);

            var meta = new Dino.FileMeta();
            meta.size = encrypted_payload.length;
            meta.mime_type = mime_type;
            meta.encryption = Dino.Entities.Encryption.PGP;
            meta.encryption_protocol = protocol;
            meta.upload_payload_is_encrypted = true;
            return meta;
        }

        public Dino.FileSendData? preprocess_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
            preprocess_called = true;
            var send_data = file_send_data as Dino.HttpFileSendData;
            if (send_data == null) return null;
            ((!) send_data).encrypt_message = true;
            return send_data;
        }

        private static uint8[] copy_string_data(string text) {
            unowned uint8[] raw = text.data;
            uint8[] copy = new uint8[raw.length];
            for (int i = 0; i < raw.length; i++) {
                copy[i] = raw[i];
            }
            return copy;
        }

        private static uint8[] read_all_stream(InputStream stream) throws Error {
            var data = new GLib.ByteArray();
            uint8[] chunk = new uint8[4096];
            GLib.Error? stream_error = null;

            try {
                while (true) {
                    ssize_t read = stream.read(chunk);
                    if (read <= 0) break;
                    data.append(chunk[0:(int) read]);
                }
            } catch (GLib.Error e) {
                stream_error = e;
            }

            try {
                stream.close();
            } catch (GLib.Error e) {
                if (stream_error == null) stream_error = e;
            }

            if (stream_error != null) throw (!) stream_error;
            return data.data;
        }
    }

    private class AesgcmUrlParts : Object {
        public string https_url;
        public uint8[] iv;
        public uint8[] key;

        public AesgcmUrlParts(string https_url, owned uint8[] iv, owned uint8[] key) {
            this.https_url = https_url;
            this.iv = (owned) iv;
            this.key = (owned) key;
        }
    }

    private class TestXmppStream : Xmpp.XmppStream {
        public signal void wrote_node(StanzaNode node);

        public StanzaNode? last_written { get; private set; default = null; }
        public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode>();

        public TestXmppStream(Xmpp.Jid remote_name) {
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
            written_nodes.add(node);
            wrote_node(node);
        }

        public override async void setup() throws IOError {
        }

        public void emit_iq_result(StanzaNode node) {
            received_iq_stanza(this, node);
        }
    }
}

class ReceiveEncryptionClassificationTest : Gee.TestCase {
    public ReceiveEncryptionClassificationTest() {
        base("ReceiveEncryptionClassification");
        add_test("SECURITY_pgp_message_http_url_is_not_pgp_payload", test_pgp_message_http_url_is_not_pgp_payload);
        add_test("SECURITY_pgp_suffix_is_left_for_pgp_decryptor", test_pgp_suffix_is_left_for_pgp_decryptor);
        add_test("SECURITY_pgp_mime_is_left_for_pgp_decryptor", test_pgp_mime_is_left_for_pgp_decryptor);
        add_test("OMEMO_aesgcm_url_is_payload_encrypted", test_aesgcm_url_is_payload_encrypted);
        add_test("OMEMO_esfs_receive_data_is_payload_encrypted", test_esfs_receive_data_is_payload_encrypted);
    }

    public override void set_up() {
        _force_class_init(typeof(FileProvider));
    }

    void test_pgp_message_http_url_is_not_pgp_payload() {
        var meta = make_pgp_message_meta("report.pdf", "application/pdf");
        var receive_data = new HttpFileReceiveData() {
            url = "https://upload.example.test/report.pdf"
        };

        fail_if_not_eq_int((int) Dino.Entities.Encryption.NONE,
            (int) FileProvider.classify_receive_payload_encryption(receive_data, meta),
            "PGP message encryption must not classify a normal HTTP payload as PGP-encrypted");
        fail_if_not_eq_str("urn:xmpp:openpgp:0", (!) meta.encryption_protocol,
            "Message encryption_protocol must remain available as receive-side context");
    }

    void test_pgp_suffix_is_left_for_pgp_decryptor() {
        var meta = make_pgp_message_meta("report.pdf.pgp", "application/octet-stream");
        var receive_data = new HttpFileReceiveData() {
            url = "https://upload.example.test/report.pdf.pgp"
        };

        fail_if_not_eq_int((int) Dino.Entities.Encryption.NONE,
            (int) FileProvider.classify_receive_payload_encryption(receive_data, meta),
            "HTTP provider must leave .pgp/.gpg detection to the PGP file decryptor");
    }

    void test_pgp_mime_is_left_for_pgp_decryptor() {
        var meta = make_pgp_message_meta("uploaded-file", "application/pgp-encrypted");
        var receive_data = new HttpFileReceiveData() {
            url = "https://upload.example.test/uploaded-file"
        };

        fail_if_not_eq_int((int) Dino.Entities.Encryption.NONE,
            (int) FileProvider.classify_receive_payload_encryption(receive_data, meta),
            "HTTP provider must leave application/pgp-encrypted detection to the PGP file decryptor");
    }

    void test_aesgcm_url_is_payload_encrypted() {
        var meta = make_pgp_message_meta("photo.jpg", "image/jpeg");
        var receive_data = new HttpFileReceiveData() {
            url = "aesgcm://upload.example.test/photo.jpg#aabbccddeeff"
        };

        fail_if_not_eq_int((int) Dino.Entities.Encryption.OMEMO,
            (int) FileProvider.classify_receive_payload_encryption(receive_data, meta),
            "aesgcm:// receive URLs must stay classified as encrypted file payloads");
    }

    void test_esfs_receive_data_is_payload_encrypted() {
        var meta = make_pgp_message_meta("encrypted.bin", "application/octet-stream");
        var receive_data = new EsfsHttpFileReceiveData() {
            url = "https://upload.example.test/encrypted.bin",
            esfs_key = make_bytes(32, 1),
            esfs_iv = make_bytes(12, 64),
            esfs_cipher = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0"
        };

        fail_if_not_eq_int((int) Dino.Entities.Encryption.OMEMO,
            (int) FileProvider.classify_receive_payload_encryption(receive_data, meta),
            "ESFS receive data must stay classified as encrypted file payload");
    }

    private HttpFileMeta make_pgp_message_meta(string file_name, string mime_type) {
        var message = new Dino.Entities.Message("https://upload.example.test/" + file_name);
        message.encryption = Dino.Entities.Encryption.PGP;
        message.encryption_protocol = "urn:xmpp:openpgp:0";

        var meta = new HttpFileMeta();
        meta.message = message;
        meta.file_name = file_name;
        meta.mime_type = mime_type;
        meta.encryption_protocol = message.encryption_protocol;
        return meta;
    }

    private uint8[] make_bytes(int length, int seed) {
        uint8[] bytes = new uint8[length];
        for (int i = 0; i < length; i++) {
            bytes[i] = (uint8) ((seed + i) % 251);
        }
        return bytes;
    }
}

class SfsSourceSelectionTest : Gee.TestCase {
    public SfsSourceSelectionTest() {
        base("SfsSourceSelection");
        add_test("SECURITY_prefers_esfs_over_plain_http", test_prefers_esfs_over_plain_http);
        add_test("SECURITY_rejects_plain_http_for_encrypted_transfer", test_rejects_plain_http_for_encrypted_transfer);
        add_test("CONTRACT_accepts_plain_http_for_unencrypted_transfer", test_accepts_plain_http_for_unencrypted_transfer);
        add_test("SECURITY_accepts_valid_gcm_esfs", test_accepts_valid_gcm_esfs);
        add_test("SECURITY_rejects_esfs_wrong_key_length", test_rejects_esfs_wrong_key_length);
        add_test("SECURITY_rejects_esfs_wrong_iv_length", test_rejects_esfs_wrong_iv_length);
        add_test("SECURITY_rejects_cbc_without_hash_context", test_rejects_cbc_without_hash_context);
        add_test("SECURITY_rejects_unknown_and_substring_esfs_ciphers", test_rejects_unknown_and_substring_esfs_ciphers);
        add_test("SECURITY_rejects_invalid_esfs_for_encrypted_transfer", test_rejects_invalid_esfs_for_encrypted_transfer);
        add_test("CONTRACT_ignores_invalid_esfs_when_plain_http_is_allowed", test_ignores_invalid_esfs_when_plain_http_is_allowed);
        add_test("CONTRACT_attaches_sfs_for_unencrypted_message", test_attaches_sfs_for_unencrypted_message);
        add_test("SECURITY_skips_sfs_for_pgp_message", test_skips_sfs_for_pgp_message);
        add_test("SECURITY_skips_sfs_for_omemo_message", test_skips_sfs_for_omemo_message);
        add_test("CONTRACT_stanza_mutation_attaches_sfs_for_unencrypted_message", test_stanza_mutation_attaches_sfs_for_unencrypted_message);
        add_test("SECURITY_stanza_mutation_skips_sfs_for_pgp_message", test_stanza_mutation_skips_sfs_for_pgp_message);
        add_test("SECURITY_stanza_mutation_skips_sfs_for_omemo_message", test_stanza_mutation_skips_sfs_for_omemo_message);
        add_test("CONTRACT_routes_unencrypted_referenceable_as_sfs", test_routes_unencrypted_referenceable_as_sfs);
        add_test("CONTRACT_routes_unencrypted_non_referenceable_as_body_url", test_routes_unencrypted_non_referenceable_as_body_url);
        add_test("SECURITY_routes_pgp_as_body_url_even_if_referenceable", test_routes_pgp_as_body_url_even_if_referenceable);
        add_test("SECURITY_routes_omemo_as_body_url_even_if_referenceable", test_routes_omemo_as_body_url_even_if_referenceable);
        add_test("SECURITY_direct_http_encryption_uses_transfer_encryption", test_direct_http_encryption_uses_transfer_encryption);
        add_test("SECURITY_direct_encrypted_upload_slot_includes_gcm_tag", test_direct_encrypted_upload_slot_includes_gcm_tag);
        add_test("SECURITY_pre_encrypted_upload_slot_does_not_double_count_gcm_tag", test_pre_encrypted_upload_slot_does_not_double_count_gcm_tag);
        add_test("CONTRACT_plain_upload_slot_uses_plain_size", test_plain_upload_slot_uses_plain_size);
        add_test("SECURITY_direct_encrypted_upload_request_matches_slot_size", test_direct_encrypted_upload_request_matches_slot_size);
        add_test("CONTRACT_pre_encrypted_upload_request_uses_payload_size", test_pre_encrypted_upload_request_uses_payload_size);
        add_test("CONTRACT_upload_request_limit_accepts_exact_final_payload", test_upload_request_limit_accepts_exact_final_payload);
        add_test("SECURITY_can_send_size_includes_direct_gcm_tag", test_can_send_size_includes_direct_gcm_tag);
        add_test("CONTRACT_can_send_size_keeps_external_encryptor_size", test_can_send_size_keeps_external_encryptor_size);
        add_test("CONTRACT_can_send_accepts_exact_upload_limit", test_can_send_accepts_exact_upload_limit);
        add_test("SECURITY_can_send_limit_counts_direct_gcm_tag", test_can_send_limit_counts_direct_gcm_tag);
        add_test("SECURITY_can_send_external_encryptor_keeps_headroom", test_can_send_external_encryptor_keeps_headroom);
        add_test("CONTRACT_can_send_rejects_invalid_size_or_limit", test_can_send_rejects_invalid_size_or_limit);
        add_test("SECURITY_upload_requires_stream", test_upload_requires_stream);
        add_test("SECURITY_body_url_message_uses_transfer_encryption", test_body_url_message_uses_transfer_encryption);
        add_test("CONTRACT_encrypt_message_false_forces_none", test_encrypt_message_false_forces_none);
        add_test("SECURITY_direct_encrypted_body_url_finalizes_aesgcm_without_source_secret", test_direct_encrypted_body_url_finalizes_aesgcm_without_source_secret);
        add_test("SECURITY_pgp_body_url_finalization_keeps_https_body_and_source", test_pgp_body_url_finalization_keeps_https_body_and_source);
        add_test("CONTRACT_unencrypted_sfs_share_sets_transfer_linkage", test_unencrypted_sfs_share_sets_transfer_linkage);
        add_test("CONTRACT_unencrypted_sfs_attachment_contains_body_oob_and_sources", test_unencrypted_sfs_attachment_contains_body_oob_and_sources);
        add_test("CONTRACT_plain_body_url_fallback_does_not_create_sfs_source_attachment", test_plain_body_url_fallback_does_not_create_sfs_source_attachment);
    }

    private const string ESFS_GCM_CIPHER = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0";
    private const string ESFS_CBC_CIPHER = "urn:xmpp:ciphers:aes-256-cbc-pkcs7:0";
    private const string ESFS_SUBSTRING_GCM_CIPHER = "urn:xmpp:ciphers:not-aes-256-gcm:0";
    private const string ESFS_SUBSTRING_CBC_CIPHER = "urn:xmpp:ciphers:aes-256-cbc-unpadded:0";

    Dino.Entities.Message create_message_with_encryption(Dino.Entities.Encryption encryption) {
        var message = new Dino.Entities.Message("https://example.test/file.bin");
        message.encryption = encryption;
        return message;
    }

    void test_prefers_esfs_over_plain_http() {
        var sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
        sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });
        sources.add(make_gcm_esfs_source(12));

        var selected = FileProvider.get_preferred_sfs_source(sources, Dino.Entities.Encryption.OMEMO);
        fail_if_not(selected is Xmpp.Xep.StatelessFileSharing.EsfsHttpSource,
            "Encrypted SFS transfers must prefer ESFS over plain HTTP even if HTTP appears first");
    }

    void test_rejects_plain_http_for_encrypted_transfer() {
        var sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
        sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });

        var selected = FileProvider.get_preferred_sfs_source(sources, Dino.Entities.Encryption.OMEMO);
        fail_if(selected != null, "Encrypted SFS transfers must not use a plain HTTP source");
    }

    void test_accepts_plain_http_for_unencrypted_transfer() {
        var sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
        sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });

        var selected = FileProvider.get_preferred_sfs_source(sources, Dino.Entities.Encryption.NONE);
        fail_if_not(selected is Xmpp.Xep.StatelessFileSharing.HttpSource,
            "Unencrypted SFS transfers may use a plain HTTP source");
    }

    void test_accepts_valid_gcm_esfs() {
        assert_selected_esfs(make_gcm_esfs_source(12), Dino.Entities.Encryption.OMEMO,
            "AES-256-GCM ESFS with a 12-byte IV should be selectable");
        assert_selected_esfs(make_gcm_esfs_source(16), Dino.Entities.Encryption.OMEMO,
            "AES-256-GCM ESFS with a 16-byte IV should stay selectable for compatibility");
        assert_selected_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(12, 64), "  URN:XMPP:CIPHERS:AES-256-GCM-NOPADDING:0  "), Dino.Entities.Encryption.PGP,
            "AES-256-GCM ESFS should accept case and surrounding-space normalized cipher URIs");
    }

    void test_rejects_esfs_wrong_key_length() {
        assert_rejects_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_bytes(31, 1), make_bytes(12, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with a short key must not be selected");
        assert_rejects_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_bytes(33, 1), make_bytes(12, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with a long key must not be selected");
    }

    void test_rejects_esfs_wrong_iv_length() {
        assert_rejects_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(8, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with an unsupported IV length must not be selected");
        assert_rejects_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(17, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with a long IV must not be selected");
    }

    void test_rejects_cbc_without_hash_context() {
        assert_rejects_esfs(make_cbc_esfs_source(),
            "AES-256-CBC ESFS must not be selected without a supported hash context");
        assert_rejects_esfs_for(make_cbc_esfs_source(), Dino.Entities.Encryption.PGP,
            "AES-256-CBC ESFS must not be selected for PGP without a supported hash context");
    }

    void test_rejects_unknown_and_substring_esfs_ciphers() {
        assert_rejects_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(12, 64), "urn:xmpp:ciphers:aes-128-gcm-nopadding:0"),
            "ESFS with an unsupported cipher must not be selected");
        assert_rejects_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(12, 64), ESFS_SUBSTRING_GCM_CIPHER),
            "ESFS with a misleading GCM substring cipher must not be selected");
        assert_rejects_esfs(make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(16, 64), ESFS_SUBSTRING_CBC_CIPHER),
            "ESFS with a misleading CBC substring cipher must not be selected");
    }

    void test_rejects_invalid_esfs_for_encrypted_transfer() {
        var sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
        sources.add(make_custom_esfs_source("https://example.test/encrypted.bin", new uint8[0], make_bytes(12, 64), ESFS_GCM_CIPHER));
        sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });

        var selected = FileProvider.get_preferred_sfs_source(sources, Dino.Entities.Encryption.OMEMO);
        fail_if(selected != null,
            "Encrypted SFS transfers must reject invalid ESFS and must not fall back to plain HTTP");
    }

    void test_ignores_invalid_esfs_when_plain_http_is_allowed() {
        var sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
        sources.add(make_custom_esfs_source("https://example.test/encrypted.bin", new uint8[0], make_bytes(12, 64), ESFS_GCM_CIPHER));
        sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });

        var selected = FileProvider.get_preferred_sfs_source(sources, Dino.Entities.Encryption.NONE);
        fail_if_not(selected is Xmpp.Xep.StatelessFileSharing.HttpSource,
            "Unencrypted SFS transfers should ignore invalid ESFS and use the plain HTTP source");
    }

    void test_attaches_sfs_for_unencrypted_message() {
        var message = create_message_with_encryption(Dino.Entities.Encryption.NONE);

        fail_if_not(HttpFileSender.should_attach_sfs_metadata(message),
            "Unencrypted HTTP file messages may attach outer SFS metadata");
    }

    void test_skips_sfs_for_pgp_message() {
        var message = create_message_with_encryption(Dino.Entities.Encryption.PGP);

        fail_if(HttpFileSender.should_attach_sfs_metadata(message),
            "PGP HTTP file messages must keep metadata body-only");
    }

    void test_skips_sfs_for_omemo_message() {
        var message = create_message_with_encryption(Dino.Entities.Encryption.OMEMO);

        fail_if(HttpFileSender.should_attach_sfs_metadata(message),
            "OMEMO HTTP file messages must keep metadata body-only");
    }

    void test_stanza_mutation_attaches_sfs_for_unencrypted_message() {
        var message = create_message_with_encryption(Dino.Entities.Encryption.NONE);
        var stanza = new Xmpp.MessageStanza();
        var file_transfer = create_file_transfer_for_stanza();

        bool attached = HttpFileSender.apply_file_transfer_stanza_metadata(message, stanza, file_transfer);

        fail_if(!attached, "Unencrypted HTTP file message stanza must receive outer SFS metadata");
        assert_store_hint(stanza);

        var shares = Xmpp.Xep.StatelessFileSharing.get_file_shares(stanza);
        fail_if(shares == null || ((!) shares).size != 1,
            "Unencrypted HTTP file message stanza must contain exactly one SFS share");

        var share = ((!) shares)[0];
        fail_if_not_eq_str("share-id-1", share.id ?? "", "SFS share id");
        fail_if_not_eq_str("file.bin", share.metadata.name ?? "", "SFS metadata filename");
        fail_if_not_eq_str("application/octet-stream", share.metadata.mime_type ?? "", "SFS metadata MIME");
        fail_if_not_eq_int(42, (int) share.metadata.size, "SFS metadata size");

        fail_if(share.sources == null || ((!) share.sources).size != 1,
            "Unencrypted SFS stanza must include the HTTP source");
        var http_source = ((!) share.sources)[0] as Xmpp.Xep.StatelessFileSharing.HttpSource;
        fail_if(http_source == null, "Unencrypted SFS stanza source must parse as HTTP");
        fail_if_not_eq_str("https://example.test/file.bin", ((!) http_source).url, "SFS HTTP source URL");
    }

    void test_stanza_mutation_skips_sfs_for_pgp_message() {
        assert_encrypted_stanza_skips_sfs(Dino.Entities.Encryption.PGP,
            "PGP HTTP file messages must not attach cleartext SFS metadata");
    }

    void test_stanza_mutation_skips_sfs_for_omemo_message() {
        assert_encrypted_stanza_skips_sfs(Dino.Entities.Encryption.OMEMO,
            "OMEMO HTTP file messages must not attach cleartext SFS metadata");
    }

    void test_routes_unencrypted_referenceable_as_sfs() {
        fail_if_not(HttpFileSender.should_send_as_sfs(Dino.Entities.Encryption.NONE, true),
            "Unencrypted referenceable transfers may use SFS");
    }

    void test_routes_unencrypted_non_referenceable_as_body_url() {
        fail_if(HttpFileSender.should_send_as_sfs(Dino.Entities.Encryption.NONE, false),
            "Unencrypted non-referenceable transfers must use the body URL fallback");
    }

    void test_routes_pgp_as_body_url_even_if_referenceable() {
        fail_if(HttpFileSender.should_send_as_sfs(Dino.Entities.Encryption.PGP, true),
            "PGP transfers must stay body-only even when message references are available");
    }

    void test_routes_omemo_as_body_url_even_if_referenceable() {
        fail_if(HttpFileSender.should_send_as_sfs(Dino.Entities.Encryption.OMEMO, true),
            "OMEMO transfers must stay body-only even when message references are available");
    }

    void test_direct_http_encryption_uses_transfer_encryption() {
        assert_direct_http_encryption(Dino.Entities.Encryption.PGP, Dino.Entities.Encryption.OMEMO, false,
            "PGP transfers must not use direct HTTP encryption after the conversation toggled to OMEMO");
        assert_direct_http_encryption(Dino.Entities.Encryption.OMEMO, Dino.Entities.Encryption.PGP, true,
            "OMEMO transfers may use direct HTTP encryption after the conversation toggled to PGP");
        assert_direct_http_encryption(Dino.Entities.Encryption.NONE, Dino.Entities.Encryption.OMEMO, false,
            "Plain transfers must not use direct HTTP encryption after the conversation toggled to OMEMO");
        assert_direct_http_encryption(Dino.Entities.Encryption.DTLS_SRTP, Dino.Entities.Encryption.NONE, true,
            "Non-NONE non-PGP transfers keep the direct HTTP encryption contract");
    }

    void test_direct_encrypted_upload_slot_includes_gcm_tag() {
        var meta = create_file_meta(1024, false);

        fail_if(!HttpFileSender.should_encrypt_upload_payload(Dino.Entities.Encryption.OMEMO, meta),
            "Direct encrypted HTTP payloads must be encrypted by the HTTP sender");
        fail_if(HttpFileSender.get_upload_slot_size(Dino.Entities.Encryption.OMEMO, meta) != 1040,
            "Direct encrypted HTTP uploads must request room for the 16-byte GCM auth tag");
    }

    void test_pre_encrypted_upload_slot_does_not_double_count_gcm_tag() {
        var meta = create_file_meta(2048, true);

        fail_if(HttpFileSender.should_encrypt_upload_payload(Dino.Entities.Encryption.PGP, meta),
            "Pre-encrypted PGP uploads must not be encrypted again by the HTTP sender");
        fail_if(HttpFileSender.get_upload_slot_size(Dino.Entities.Encryption.PGP, meta) != 2048,
            "Pre-encrypted PGP uploads must request exactly the encrypted payload size");
        fail_if(HttpFileSender.should_encrypt_upload_payload(Dino.Entities.Encryption.OMEMO, meta),
            "Pre-encrypted OMEMO uploads must not be encrypted again by the HTTP sender");
        fail_if(HttpFileSender.get_upload_slot_size(Dino.Entities.Encryption.OMEMO, meta) != 2048,
            "Pre-encrypted OMEMO uploads must not double-count the GCM auth tag");
    }

    void test_plain_upload_slot_uses_plain_size() {
        var meta = create_file_meta(512, false);

        fail_if(HttpFileSender.should_encrypt_upload_payload(Dino.Entities.Encryption.NONE, meta),
            "Plain uploads must not be encrypted by the HTTP sender");
        fail_if(HttpFileSender.get_upload_slot_size(Dino.Entities.Encryption.NONE, meta) != 512,
            "Plain uploads must request exactly the plain file size");
    }

    void test_direct_encrypted_upload_request_matches_slot_size() {
        var meta = create_file_meta(1024, false);

        fail_if(HttpFileSender.get_upload_request_size(true, meta) != 1040,
            "Direct encrypted HTTP PUT requests must include the 16-byte GCM auth tag in Content-Length");
        fail_if(HttpFileSender.get_upload_request_size(true, meta) != HttpFileSender.get_upload_slot_size(Dino.Entities.Encryption.OMEMO, meta),
            "Direct encrypted HTTP PUT request size must match the earlier slot request size");
    }

    void test_pre_encrypted_upload_request_uses_payload_size() {
        var meta = create_file_meta(2048, true);

        fail_if(HttpFileSender.get_upload_request_size(false, meta) != 2048,
            "Pre-encrypted HTTP PUT requests must use the exact encrypted payload size");
        fail_if(HttpFileSender.get_upload_request_size(false, meta) != HttpFileSender.get_upload_slot_size(Dino.Entities.Encryption.PGP, meta),
            "Pre-encrypted PGP PUT request size must match the earlier slot request size");
    }

    void test_upload_request_limit_accepts_exact_final_payload() {
        fail_if(!HttpFileSender.is_upload_request_size_within_limit(2048, 2048),
            "The final HTTP upload request size may equal the server max-file-size");
        fail_if(HttpFileSender.is_upload_request_size_within_limit(2049, 2048),
            "The final HTTP upload request size must not exceed the server max-file-size");
    }

    void test_can_send_size_includes_direct_gcm_tag() {
        fail_if(HttpFileSender.get_can_send_upload_size(Dino.Entities.Encryption.OMEMO, 1024) != 1040,
            "HTTP can-send size checks must reserve room for direct AES-GCM auth tags");
        fail_if(HttpFileSender.get_can_send_upload_size(Dino.Entities.Encryption.NONE, 1024) != 1024,
            "Plain HTTP can-send size checks must use the plain file size");
    }

    void test_can_send_size_keeps_external_encryptor_size() {
        fail_if(HttpFileSender.get_can_send_upload_size(Dino.Entities.Encryption.PGP, 2048) != 2048,
            "PGP uses an external file encryptor, so HTTP can-send pre-check must not add the direct AES-GCM tag");
    }

    void test_can_send_accepts_exact_upload_limit() {
        fail_if(!HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.NONE, 512, 512),
            "HTTP upload max-file-size is an inclusive server limit, so an exact-size plain upload must be selectable");
        fail_if(HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.NONE, 513, 512),
            "Plain uploads larger than the server limit must not be selectable");
    }

    void test_can_send_limit_counts_direct_gcm_tag() {
        fail_if(!HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.OMEMO, 1024, 1040),
            "Direct encrypted HTTP uploads must be selectable when plaintext size plus GCM tag equals the server limit");
        fail_if(HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.OMEMO, 1024, 1039),
            "Direct encrypted HTTP uploads must reject a server limit that cannot fit the GCM auth tag");
    }

    void test_can_send_external_encryptor_keeps_headroom() {
        fail_if(!HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.PGP, 2047, 2048),
            "External encryptor prechecks may select HTTP when the plaintext size is below the server limit");
        fail_if(HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.PGP, 2048, 2048),
            "External encryptor prechecks must keep headroom because final encrypted payload size is not known yet");
    }

    void test_can_send_rejects_invalid_size_or_limit() {
        fail_if(HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.NONE, -1, 512),
            "Unknown or invalid outgoing sizes must not pass HTTP upload can-send checks");
        fail_if(HttpFileSender.can_send_file_size_with_limit(Dino.Entities.Encryption.NONE, 1, 0),
            "Invalid server max-file-size values must not pass HTTP upload can-send checks");
        fail_if(HttpFileSender.is_upload_request_size_within_limit(-1, 512),
            "Invalid final HTTP request sizes must not pass the server upload limit check");
    }

    void test_upload_requires_stream() {
        try {
            HttpFileSender.throw_if_upload_stream_unavailable(false);
            fail_if(true, "HTTP upload must fail closed when the XMPP stream disappears before PUT");
        } catch (Dino.FileSendError.UPLOAD_FAILED e) {
            assert_true(true);
        } catch (Error e) {
            fail_if(true, @"Unexpected missing-stream error: $(e.message)");
        }

        try {
            HttpFileSender.throw_if_upload_stream_unavailable(true);
        } catch (Error e) {
            fail_if(true, @"Available upload stream must not fail: $(e.message)");
        }
    }

    void test_body_url_message_uses_transfer_encryption() {
        fail_if_not(HttpFileSender.get_body_url_message_encryption(Dino.Entities.Encryption.PGP, true) == Dino.Entities.Encryption.PGP,
            "PGP body URL messages must use the frozen transfer encryption");
        fail_if_not(HttpFileSender.get_body_url_message_encryption(Dino.Entities.Encryption.OMEMO, true) == Dino.Entities.Encryption.OMEMO,
            "OMEMO body URL messages must use the frozen transfer encryption");
    }

    void test_encrypt_message_false_forces_none() {
        fail_if_not(HttpFileSender.get_body_url_message_encryption(Dino.Entities.Encryption.OMEMO, false) == Dino.Entities.Encryption.NONE,
            "send_data.encrypt_message=false must send a plaintext message even for encrypted transfer payloads");
        fail_if_not(HttpFileSender.get_body_url_message_encryption(Dino.Entities.Encryption.PGP, false) == Dino.Entities.Encryption.NONE,
            "send_data.encrypt_message=false must keep PGP transfer body messages unencrypted when requested");
    }

    void test_direct_encrypted_body_url_finalizes_aesgcm_without_source_secret() {
        var send_data = new EncryptedHttpFileSendData();
        send_data.url_down = "https://upload.example.test/path/photo.jpg";
        send_data.key = make_bytes(32, 0x10);
        send_data.iv = make_bytes(12, 0x80);
        send_data.encrypt_message = true;
        var file_transfer = create_body_url_transfer(Dino.Entities.Encryption.OMEMO);

        Dino.Entities.Encryption message_encryption = HttpFileSender.prepare_body_url_announcement(send_data, file_transfer);

        fail_if_not_eq_int((int) message_encryption, (int) Dino.Entities.Encryption.OMEMO,
            "direct encrypted body-url messages must use the transfer encryption");
        fail_if_not(send_data.url_down.has_prefix("aesgcm://upload.example.test/path/photo.jpg#"),
            "direct encrypted body URL must expose only an aesgcm body URL after HTTP upload");
        fail_if(send_data.url_down.contains("https://"),
            "direct encrypted body URL must not keep the clear HTTP scheme in the encrypted message body");
        fail_if(file_transfer.file_sharing_id == null || file_transfer.file_sharing_id == "",
            "body-url finalization must ensure a local file-sharing id exists");
        assert_single_local_source(file_transfer, "https://upload.example.test/path/photo.jpg",
            "local sent-transfer source must strip the aesgcm secret fragment");
    }

    void test_pgp_body_url_finalization_keeps_https_body_and_source() {
        var send_data = new Dino.HttpFileSendData();
        send_data.url_down = "https://upload.example.test/path/payload.bin.pgp";
        send_data.encrypt_message = true;
        var file_transfer = create_body_url_transfer(Dino.Entities.Encryption.PGP);

        Dino.Entities.Encryption message_encryption = HttpFileSender.prepare_body_url_announcement(send_data, file_transfer);

        fail_if_not_eq_int((int) message_encryption, (int) Dino.Entities.Encryption.PGP,
            "PGP body-url messages must use PGP message encryption");
        fail_if_not_eq_str(send_data.url_down, "https://upload.example.test/path/payload.bin.pgp",
            "PGP body-url finalization must keep the HTTP URL for OpenPGP body encryption");
        assert_single_local_source(file_transfer, "https://upload.example.test/path/payload.bin.pgp",
            "PGP local sent-transfer source must keep the transport URL without adding cleartext SFS metadata");
    }

    void test_unencrypted_sfs_share_sets_transfer_linkage() {
        var file_transfer = create_file_transfer_for_stanza();
        file_transfer.file_sharing_id = null;
        var file_share_message = create_file_share_message();

        HttpFileSender.prepare_unencrypted_sfs_share(file_transfer, file_share_message);

        fail_if_not_eq_str("123", file_transfer.info,
            "unencrypted SFS share preparation must link the transfer to the persisted file-share message");
        fail_if(file_transfer.message_db_id != 123,
            "unencrypted SFS share preparation must persist an explicit local message relation");
        fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
            "unencrypted SFS share preparation must assign a file-sharing id before the attachment stanza is built");
    }

    void test_unencrypted_sfs_attachment_contains_body_oob_and_sources() {
        var conversation = create_conversation(Dino.Entities.Conversation.Type.CHAT);
        var file_transfer = create_body_url_transfer(Dino.Entities.Encryption.NONE);
        var send_data = create_http_send_data("https://upload.example.test/path/plain.bin");
        var file_share_message = create_file_share_message();
        HttpFileSender.prepare_unencrypted_sfs_share(file_transfer, file_share_message);

        Xmpp.MessageStanza stanza = HttpFileSender.build_unencrypted_sfs_attachment_stanza(conversation, file_transfer, send_data, file_share_message);

        fail_if_not_eq_str(send_data.url_down, stanza.body ?? "",
            "unencrypted SFS attachment fallback body must keep the plain HTTP URL");
        fail_if_not_eq_str(send_data.url_down, Xmpp.Xep.OutOfBandData.get_url_from_message(stanza) ?? "",
            "unencrypted SFS attachment must include the OOB URL");
        fail_if_not_eq_str("bob@example.test", stanza.to.to_string(),
            "unencrypted SFS attachment must target the conversation counterpart");
        fail_if_not_eq_str(Xmpp.MessageStanza.TYPE_CHAT, stanza.type_,
            "1:1 unencrypted SFS attachment must use a chat stanza");

        var attachments = Xmpp.Xep.StatelessFileSharing.get_source_attachments(stanza);
        fail_if(attachments == null || ((!) attachments).size != 1,
            "unencrypted SFS attachment stanza must contain exactly one source attachment");
        var attachment = ((!) attachments)[0];
        fail_if_not_eq_str(file_share_message.stanza_id, attachment.to_message_id,
            "unencrypted SFS attachment must reference the file-share message origin id");
        fail_if_not_eq_str((!) file_transfer.file_sharing_id, attachment.to_file_transfer_id ?? "",
            "unencrypted SFS attachment must reference the transfer file-sharing id");
        fail_if(attachment.sources == null || ((!) attachment.sources).size != 1,
            "unencrypted SFS attachment must include one HTTP source");
        var attachment_source = ((!) attachment.sources)[0] as Xmpp.Xep.StatelessFileSharing.HttpSource;
        fail_if(attachment_source == null, "unencrypted SFS attachment source must parse as HTTP");
        fail_if_not_eq_str(send_data.url_down, ((!) attachment_source).url,
            "unencrypted SFS attachment HTTP source must use the uploaded file URL");

        assert_single_local_source(file_transfer, send_data.url_down,
            "unencrypted SFS attachment must add the uploaded URL to the local transfer sources");
    }

    void test_plain_body_url_fallback_does_not_create_sfs_source_attachment() {
        var send_data = create_http_send_data("https://upload.example.test/path/plain-body-url.bin");
        send_data.encrypt_message = false;
        var file_transfer = create_body_url_transfer(Dino.Entities.Encryption.NONE);

        Dino.Entities.Encryption message_encryption = HttpFileSender.prepare_body_url_announcement(send_data, file_transfer);
        var message = new Dino.Entities.Message(send_data.url_down);
        message.encryption = message_encryption;
        var stanza = new Xmpp.MessageStanza();

        bool attached = HttpFileSender.apply_file_transfer_stanza_metadata(message, stanza, file_transfer);

        fail_if(!attached,
            "plain body-url fallback may attach standalone SFS metadata for unencrypted messages");
        fail_if(Xmpp.Xep.StatelessFileSharing.get_source_attachments(stanza) != null,
            "plain body-url fallback must not create an SFS source attachment");
        fail_if(Xmpp.Xep.OutOfBandData.get_url_from_message(stanza) != null,
            "plain body-url fallback must not add OOB metadata in the body-url helper");
        fail_if_not_eq_int((int) Dino.Entities.Encryption.NONE, (int) message_encryption,
            "plain body-url fallback messages must stay unencrypted");
        assert_single_local_source(file_transfer, send_data.url_down,
            "plain body-url fallback may keep a local sent-transfer source without creating source attachment or OOB metadata");
    }

    void assert_direct_http_encryption(Dino.Entities.Encryption transfer_encryption, Dino.Entities.Encryption conversation_encryption, bool expected, string reason) {
        bool actual = HttpFileSender.can_encrypt_transfer_payload(transfer_encryption);
        fail_if(actual != expected, "%s (transfer=%d conversation=%d actual=%s expected=%s)".printf(
            reason,
            (int) transfer_encryption,
            (int) conversation_encryption,
            actual ? "true" : "false",
            expected ? "true" : "false"));
    }

    void assert_encrypted_stanza_skips_sfs(Dino.Entities.Encryption encryption, string reason) {
        var message = create_message_with_encryption(encryption);
        var stanza = new Xmpp.MessageStanza();
        var file_transfer = create_file_transfer_for_stanza();

        bool attached = HttpFileSender.apply_file_transfer_stanza_metadata(message, stanza, file_transfer);

        fail_if(attached, reason);
        assert_store_hint(stanza);
        fail_if(Xmpp.Xep.StatelessFileSharing.get_file_shares(stanza) != null, reason);
        fail_if(Xmpp.Xep.StatelessFileSharing.get_source_attachments(stanza) != null, reason);
        fail_if(stanza.stanza.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null, reason);
        fail_if(stanza.stanza.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI) != null, reason);
        fail_if(Xmpp.Xep.OutOfBandData.get_url_from_message(stanza) != null, reason);
        fail_if(stanza.stanza.to_string().contains("https://example.test/file.bin"),
            "Encrypted HTTP file stanza must not expose the transfer URL outside the encrypted message body");
    }

    Dino.Entities.FileTransfer create_file_transfer_for_stanza() {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.file_sharing_id = "share-id-1";
        file_transfer.file_name = "file.bin";
        file_transfer.mime_type = "application/octet-stream";
        file_transfer.size = 42;
        file_transfer.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/file.bin" });
        return file_transfer;
    }

    Dino.Entities.FileTransfer create_body_url_transfer(Dino.Entities.Encryption encryption) {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.encryption = encryption;
        file_transfer.file_name = "file.bin";
        file_transfer.mime_type = "application/octet-stream";
        file_transfer.size = 42;
        return file_transfer;
    }

    Dino.Entities.Conversation create_conversation(Dino.Entities.Conversation.Type type) {
        try {
            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            return new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, type);
        } catch (Xmpp.InvalidJidError e) {
            GLib.error("Invalid test JID: %s", e.message);
        }
    }

    Dino.Entities.Message create_file_share_message() {
        var message = new Dino.Entities.Message(null);
        message.id = 123;
        message.stanza_id = "origin-share-123";
        return message;
    }

    Dino.HttpFileSendData create_http_send_data(string url_down) {
        return new Dino.HttpFileSendData() {
            url_down = url_down,
            url_up = "https://upload.example.test/put/plain.bin",
            headers = new Gee.HashMap<string, string>(),
            encrypt_message = false
        };
    }

    Dino.FileMeta create_file_meta(int64 size, bool upload_payload_is_encrypted) {
        var meta = new Dino.FileMeta();
        meta.size = size;
        meta.upload_payload_is_encrypted = upload_payload_is_encrypted;
        return meta;
    }

    void assert_store_hint(Xmpp.MessageStanza stanza) {
        fail_if(stanza.stanza.get_subnode("store", "urn:xmpp:hints") == null,
            "File-transfer stanza decoration must preserve the message store hint");
    }

    void assert_single_local_source(Dino.Entities.FileTransfer file_transfer, string expected_url, string reason) {
        fail_if(file_transfer.sfs_sources.size != 1, reason);
        var http_source = file_transfer.sfs_sources[0] as Xmpp.Xep.StatelessFileSharing.HttpSource;
        fail_if(http_source == null, reason);
        fail_if_not_eq_str(((!) http_source).url, expected_url, reason);
        fail_if(((!) http_source).url.contains("#"),
            "local sent-transfer source must not persist URL fragments or encryption secrets");
    }

    void assert_selected_esfs(Xmpp.Xep.StatelessFileSharing.EsfsHttpSource source, Dino.Entities.Encryption encryption, string reason) {
        var sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
        sources.add(source);

        var selected = FileProvider.get_preferred_sfs_source(sources, encryption);
        fail_if_not(selected is Xmpp.Xep.StatelessFileSharing.EsfsHttpSource, reason);
    }

    void assert_rejects_esfs(Xmpp.Xep.StatelessFileSharing.EsfsHttpSource source, string reason) {
        assert_rejects_esfs_for(source, Dino.Entities.Encryption.OMEMO, reason);
    }

    void assert_rejects_esfs_for(Xmpp.Xep.StatelessFileSharing.EsfsHttpSource source, Dino.Entities.Encryption encryption, string reason) {
        var sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
        sources.add(source);

        var selected = FileProvider.get_preferred_sfs_source(sources, encryption);
        fail_if(selected != null, reason);
    }

    Xmpp.Xep.StatelessFileSharing.EsfsHttpSource make_gcm_esfs_source(int iv_length) {
        return make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(iv_length, 64), ESFS_GCM_CIPHER);
    }

    Xmpp.Xep.StatelessFileSharing.EsfsHttpSource make_cbc_esfs_source() {
        return make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(16, 64), ESFS_CBC_CIPHER);
    }

    Xmpp.Xep.StatelessFileSharing.EsfsHttpSource make_custom_esfs_source(string url, uint8[] key, uint8[] iv, string cipher_uri) {
        var source = new Xmpp.Xep.StatelessFileSharing.EsfsHttpSource();
        source.url = url;
        source.key = key;
        source.iv = iv;
        source.cipher_uri = cipher_uri;
        return source;
    }

    uint8[] make_esfs_key() {
        return make_bytes(32, 1);
    }

    uint8[] make_bytes(int length, int seed) {
        uint8[] bytes = new uint8[length];
        for (int i = 0; i < length; i++) {
            bytes[i] = (uint8) ((seed + i) % 251);
        }
        return bytes;
    }
}

}
