using Dino.Ui;

namespace Dino.Ui.Test {

class ProviderDirectoryProxy : Object, Dino.Plugins.AccountProxyProvider {
    public string id { get { return "tor-manager"; } }
    public string proxy_type { get { return "tor"; } }
    public string proxy_host { owned get { return "127.0.0.1"; } }
    public int port { get; set; default = 9050; }
    public bool enabled { get; set; default = false; }
    public bool ready { get; set; default = false; }
    public int proxy_port { get { return port; } }
    public bool proxy_enabled { get { return enabled; } }
    public bool proxy_ready { get { return ready; } }
}

class ProviderDirectoryTest : Gee.TestCase {

    private Gee.ArrayList<string> temporary_directories = new Gee.ArrayList<string>();

    public ProviderDirectoryTest() {
        base("ProviderDirectory");

        add_test("Providers_v2_bundled_snapshot_resource_parses", test_bundled_snapshot_resource_parses);
        add_test("Providers_v2_valid_ibr_and_web_only", test_valid_ibr_and_web_only);
        add_test("Providers_v2_unknown_fields_are_ignored", test_unknown_fields_are_ignored);
        add_test("Providers_v2_rejects_malformed_json", test_rejects_malformed_json);
        add_test("Providers_v2_rejects_non_array_root", test_rejects_non_array_root);
        add_test("Providers_v2_rejects_duplicate_jids", test_rejects_duplicate_jids);
        add_test("Providers_v2_rejects_wrong_required_type", test_rejects_wrong_required_type);
        add_test("Providers_v2_rejects_http_registration_url", test_rejects_http_registration_url);
        add_test("Providers_v2_rejects_web_only_without_registration_url", test_rejects_web_only_without_registration_url);
        add_test("Providers_v2_rejects_invalid_domain", test_rejects_invalid_domain);
        add_test("Providers_v2_store_loads_bundled_snapshot", test_store_loads_bundled_snapshot);
        add_test("Providers_v2_store_uses_valid_cache_first", test_store_uses_valid_cache_first);
        add_test("Providers_v2_store_invalid_cache_falls_back_to_bundle", test_store_invalid_cache_falls_back_to_bundle);
        add_test("Providers_v2_store_writes_cache_and_timestamp", test_store_writes_cache_and_timestamp);
        add_test("Providers_v2_store_surfaces_cache_write_failure", test_store_surfaces_cache_write_failure);
        add_test("Providers_v2_stream_reader_accepts_bounded_payload", test_stream_reader_accepts_bounded_payload);
        add_test("Providers_v2_stream_reader_rejects_oversized_payload", test_stream_reader_rejects_oversized_payload);
        add_test("Providers_v2_enabled_unready_proxy_blocks_refresh", test_enabled_unready_proxy_blocks_refresh);
        add_test("Providers_v2_invalid_proxy_blocks_refresh", test_invalid_proxy_blocks_refresh);
        add_test("Providers_v2_ready_proxy_routes_hostnames_without_direct_fallback", test_ready_proxy_route);
        add_test("Providers_v2_proxy_session_does_not_modify_injected_session", test_proxy_session_isolation);
        add_test("Providers_v2_disabled_proxy_preserves_system_resolver", test_disabled_proxy_preserves_system_resolver);
        add_test("Providers_v2_https_host_reaches_real_socks_handshake_without_dns", () => { test_refresh_runtime_route("reject"); });
        add_test("Providers_v2_running_request_is_cancelled_when_tor_becomes_unready", () => { test_refresh_runtime_route("unready"); });
        add_test("Providers_v2_running_request_is_cancelled_when_tor_port_changes", () => { test_refresh_runtime_route("port-change"); });
        add_test("Providers_v2_direct_request_is_cancelled_when_tor_is_enabled", () => { test_refresh_runtime_route("tor-enable"); });
        add_test("Providers_v2_cancelled_refresh_releases_signal_handlers", () => { test_refresh_runtime_route("caller-cancel"); });

        if (Environment.get_variable("DINOX_PROVIDER_DIRECTORY_TEST_JSON") != null) {
            add_test("Providers_v2_external_snapshot_parses", test_external_snapshot_parses);
        }
    }

    private void test_bundled_snapshot_resource_parses() {
        try {
            Bytes data = resources_lookup_data("/im/dinox/dinox/providers-v2-B.json", ResourceLookupFlags.NONE);
            Gee.List<ProviderDirectoryProvider> providers = ProviderDirectoryParser.parse_bytes(data);
            assert_true(providers.size > 0, "bundled provider snapshot should contain providers");
        } catch (Error error) {
            GLib.Test.message("Bundled provider snapshot should parse: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_external_snapshot_parses() {
        string? path = Environment.get_variable("DINOX_PROVIDER_DIRECTORY_TEST_JSON");
        assert_true(path != null && (!) path != "", "external snapshot path should be set");

        try {
            string payload;
            FileUtils.get_contents((!) path, out payload);
            Gee.List<ProviderDirectoryProvider> providers = ProviderDirectoryParser.parse_string(payload);
            assert_true(providers.size > 0, "external provider snapshot should contain providers");
        } catch (Error error) {
            GLib.Test.message("External provider snapshot should parse: %s", error.message);
            GLib.Test.fail();
        }
    }

    private string valid_payload() {
        return """
[
  {
    "jid": "example.org",
    "category": "A",
    "website": { "en": "https://example.org" },
    "inBandRegistration": true,
    "inBandRegistrationEmailAddressRequired": true,
    "inBandRegistrationCaptchaRequired": false,
    "registrationWebPage": {},
    "serverLocations": [ "de", "nl" ],
    "freeOfCharge": true,
    "maximumHttpFileUploadFileSize": 1234,
    "maximumHttpFileUploadTotalSize": 5678,
    "maximumHttpFileUploadStorageTime": 30,
    "maximumMessageArchiveManagementStorageTime": 365,
    "unknownFutureField": { "keptByMirror": true }
  },
  {
    "jid": "web.example",
    "category": "B",
    "website": { "en": "https://web.example" },
    "inBandRegistration": false,
    "registrationWebPage": {
      "en": "https://web.example/register",
      "de": "https://web.example/registrieren"
    },
    "serverLocations": [],
    "freeOfCharge": false
  }
]
""";
    }

    private void test_valid_ibr_and_web_only() {
        Gee.List<ProviderDirectoryProvider> providers = parse_valid(valid_payload());
        fail_if_not_eq_int(2, providers.size);

        ProviderDirectoryProvider ibr = providers[0];
        fail_if_not_eq_str("example.org", ibr.jid);
        fail_if_not_eq_str("A", ibr.category);
        assert_true(ibr.in_band_registration, "IBR provider should route to XEP-0077");
        assert_false(ibr.has_web_registration, "IBR provider should not need a web registration page");
        assert_true(ibr.in_band_registration_email_address_required, "email requirement should parse");
        assert_false(ibr.in_band_registration_captcha_required, "captcha requirement should parse");
        assert_true(ibr.free_of_charge, "freeOfCharge should parse");
        fail_if_not_eq_int(2, ibr.server_locations.size);
        fail_if_not_eq_str("de", ibr.server_locations[0]);
        fail_if_not_eq_int(1234, (int) ibr.maximum_http_file_upload_file_size);
        fail_if_not_eq_int(5678, (int) ibr.maximum_http_file_upload_total_size);
        fail_if_not_eq_int(30, (int) ibr.maximum_http_file_upload_storage_time);
        fail_if_not_eq_int(365, (int) ibr.maximum_message_archive_management_storage_time);
        fail_if_not_eq_str("https://example.org", ibr.websites["en"]);

        ProviderDirectoryProvider web = providers[1];
        fail_if_not_eq_str("web.example", web.jid);
        fail_if_not_eq_str("B", web.category);
        assert_false(web.in_band_registration, "web-only provider must not route to XEP-0077");
        assert_true(web.has_web_registration, "web-only provider should expose a registration URL");
        fail_if_not_eq_str("https://web.example/register", web.registration_web_pages["en"]);
        fail_if_not_eq_str("https://web.example/registrieren", web.registration_web_pages["de"]);
    }

    private void test_unknown_fields_are_ignored() {
        Gee.List<ProviderDirectoryProvider> providers = parse_valid("""
[
  {
    "jid": "future.example",
    "category": "B",
    "website": { "en": "https://future.example" },
    "inBandRegistration": true,
    "registrationWebPage": {},
    "unknown": { "nested": [ 1, 2, 3 ] }
  }
]
""");
        fail_if_not_eq_int(1, providers.size);
        fail_if_not_eq_str("future.example", providers[0].jid);
    }

    private void test_rejects_malformed_json() {
        expect_invalid("{", ProviderDirectoryError.INVALID_JSON);
    }

    private void test_rejects_non_array_root() {
        expect_invalid("""{ "providers": [] }""", ProviderDirectoryError.INVALID_SCHEMA);
    }

    private void test_rejects_duplicate_jids() {
        expect_invalid("""
[
  {
    "jid": "dup.example",
    "category": "B",
    "website": { "en": "https://dup.example" },
    "inBandRegistration": true,
    "registrationWebPage": {}
  },
  {
    "jid": "dup.example",
    "category": "B",
    "website": { "en": "https://dup.example" },
    "inBandRegistration": true,
    "registrationWebPage": {}
  }
]
""", ProviderDirectoryError.INVALID_SCHEMA);
    }

    private void test_rejects_wrong_required_type() {
        expect_invalid("""
[
  {
    "jid": "badtype.example",
    "category": "B",
    "website": { "en": "https://badtype.example" },
    "inBandRegistration": "yes",
    "registrationWebPage": {}
  }
]
""", ProviderDirectoryError.INVALID_SCHEMA);
    }

    private void test_rejects_http_registration_url() {
        expect_invalid("""
[
  {
    "jid": "http.example",
    "category": "B",
    "website": { "en": "https://http.example" },
    "inBandRegistration": false,
    "registrationWebPage": { "en": "http://http.example/register" }
  }
]
""", ProviderDirectoryError.INVALID_SCHEMA);
    }

    private void test_rejects_web_only_without_registration_url() {
        expect_invalid("""
[
  {
    "jid": "noweb.example",
    "category": "B",
    "website": { "en": "https://noweb.example" },
    "inBandRegistration": false,
    "registrationWebPage": {}
  }
]
""", ProviderDirectoryError.INVALID_SCHEMA);
    }

    private void test_rejects_invalid_domain() {
        expect_invalid("""
[
  {
    "jid": "bad domain.example",
    "category": "B",
    "website": { "en": "https://bad.example" },
    "inBandRegistration": true,
    "registrationWebPage": {}
  }
]
""", ProviderDirectoryError.INVALID_SCHEMA);
    }

    private void test_store_loads_bundled_snapshot() {
        try {
            var store = new ProviderDirectoryStore(
                    "http://127.0.0.1:9/must-never-be-requested",
                    temp_cache_path("missing-cache"));
            ProviderDirectoryLoadSource source;
            Gee.List<ProviderDirectoryProvider> providers = store.load_initial_with_source(out source);
            assert_true(source == ProviderDirectoryLoadSource.BUNDLED,
                    "initial load without a cache must use the bundled snapshot and stay offline");
            assert_true(providers.size > 0, "store should load bundled snapshot without cache");
        } catch (ProviderDirectoryError error) {
            GLib.Test.message("Store should load bundled snapshot: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_store_uses_valid_cache_first() {
        string cache_path = temp_cache_path("valid-cache");
        try {
            FileUtils.set_contents(cache_path, """
[
  {
    "jid": "cache.example",
    "category": "B",
    "website": { "en": "https://cache.example" },
    "inBandRegistration": true,
    "registrationWebPage": {}
  }
]
""");
            var store = new ProviderDirectoryStore(ProviderDirectoryStore.DEFAULT_MIRROR_URL, cache_path);
            Gee.List<ProviderDirectoryProvider> providers = store.load_initial();
            fail_if_not_eq_int(1, providers.size);
            fail_if_not_eq_str("cache.example", providers[0].jid);
        } catch (Error error) {
            GLib.Test.message("Store should load valid cache first: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_store_invalid_cache_falls_back_to_bundle() {
        string cache_path = temp_cache_path("invalid-cache");
        try {
            FileUtils.set_contents(cache_path, "{");
            var store = new ProviderDirectoryStore(ProviderDirectoryStore.DEFAULT_MIRROR_URL, cache_path);
            Gee.List<ProviderDirectoryProvider> providers = store.load_initial();
            assert_true(providers.size > 1, "invalid cache should fall back to bundled snapshot");
        } catch (Error error) {
            GLib.Test.message("Store should fall back from invalid cache to bundle: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_store_writes_cache_and_timestamp() {
        string cache_path = temp_cache_path("written-cache");
        string payload = valid_payload();
        try {
            var store = new ProviderDirectoryStore(ProviderDirectoryStore.DEFAULT_MIRROR_URL, cache_path);
            Error? write_error = write_cache_sync(store, new Bytes(payload.data), null);
            if (write_error != null) throw (!) write_error;

            ProviderDirectoryLoadSource source;
            Gee.List<ProviderDirectoryProvider> providers = store.load_initial_with_source(out source);
            assert_true(source == ProviderDirectoryLoadSource.CACHE, "written cache should become the initial source");
            fail_if_not_eq_int(2, providers.size);
            assert_true(store.get_cache_modified_time() != null, "written cache should expose its modification time");
        } catch (Error error) {
            GLib.Test.message("Store should write and reload a valid cache: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_store_surfaces_cache_write_failure() {
        string blocking_file = temp_cache_path("not-a-directory");
        string payload = valid_payload();
        try {
            FileUtils.set_contents(blocking_file, "blocking file");
            var store = new ProviderDirectoryStore(
                    ProviderDirectoryStore.DEFAULT_MIRROR_URL,
                    Path.build_filename(blocking_file, "providers-B.json"));
            Error? write_error = write_cache_sync(store, new Bytes(payload.data), null);
            if (write_error != null) throw (!) write_error;
        } catch (ProviderDirectoryError error) {
            assert_true(error.code == ProviderDirectoryError.IO, "cache write failure should be surfaced as IO");
            return;
        } catch (Error error) {
            GLib.Test.message("Unexpected cache write error: %s", error.message);
            GLib.Test.fail();
            return;
        }

        GLib.Test.message("Expected an invalid cache path to fail");
        GLib.Test.fail();
    }

    private Error? write_cache_sync(ProviderDirectoryStore store, Bytes data,
            Cancellable? cancellable) {
        Error? async_error = null;
        var loop = new MainLoop();

        store.write_cache.begin(data, cancellable, (obj, res) => {
            try {
                store.write_cache.end(res);
            } catch (Error error) {
                async_error = error;
            }
            loop.quit();
        });
        loop.run();

        return async_error;
    }

    private void assert_proxy_refresh_blocked(ProviderDirectoryProxy proxy) {
        string cache_path = temp_cache_path("proxy-cache");
        try {
            string original = valid_payload();
            FileUtils.set_contents(cache_path, original);
            var store = new ProviderDirectoryStore("https://provider.invalid/list.json", cache_path);
            Error? caught = null;
            bool completed = false;
            var loop = new MainLoop();
            store.refresh_from_mirror.begin(null, proxy, (obj, res) => {
                try {
                    store.refresh_from_mirror.end(res);
                } catch (Error error) {
                    caught = error;
                }
                completed = true;
                loop.quit();
            });
            if (!completed) loop.run();
            assert_true(caught != null && ((!) caught).code == ProviderDirectoryError.PROXY_UNAVAILABLE,
                    "enabled unavailable proxy must fail before any network request");
            string unchanged;
            FileUtils.get_contents(cache_path, out unchanged);
            fail_if_not_eq_str(original, unchanged);
        } catch (Error error) {
            GLib.Test.message("Proxy refresh test failed: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_enabled_unready_proxy_blocks_refresh() {
        var proxy = new ProviderDirectoryProxy();
        proxy.enabled = true;
        assert_proxy_refresh_blocked(proxy);
    }

    private void test_invalid_proxy_blocks_refresh() {
        var proxy = new ProviderDirectoryProxy();
        proxy.enabled = true;
        proxy.ready = true;
        proxy.port = 0;
        assert_proxy_refresh_blocked(proxy);
    }

    private void test_ready_proxy_route() {
        try {
            var proxy = new ProviderDirectoryProxy();
            proxy.enabled = true;
            proxy.ready = true;
            var store = new ProviderDirectoryStore();
            Soup.Session session = store.create_refresh_session(ProviderDirectoryStore.runtime_proxy_uri(proxy));
            string[] routes = session.proxy_resolver.lookup("https://provider.invalid/list.json", null);
            fail_if_not_eq_int(1, routes.length);
            fail_if_not_eq_str("socks5://127.0.0.1:9050", routes[0]);
            assert_true(Proxy.get_default_for_protocol("socks5").supports_hostname(),
                    "SOCKS5 forwards hostnames instead of resolving provider DNS locally");
        } catch (Error error) {
            GLib.Test.message("Ready proxy route failed: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_proxy_session_isolation() {
        var injected = new Soup.Session();
        injected.proxy_resolver = new SimpleProxyResolver("http://system-proxy.invalid:3128", null);
        var store = new ProviderDirectoryStore(ProviderDirectoryStore.DEFAULT_MIRROR_URL, null, injected);
        Soup.Session routed = store.create_refresh_session("socks5://127.0.0.1:9050");
        assert_true(routed != injected, "Tor refresh needs a separate session");
        try {
            string[] routes = injected.proxy_resolver.lookup("https://provider.invalid", null);
            fail_if_not_eq_str("http://system-proxy.invalid:3128", routes[0]);
        } catch (Error error) {
            GLib.Test.message("Injected route changed: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_disabled_proxy_preserves_system_resolver() {
        try {
            var proxy = new ProviderDirectoryProxy();
            var store = new ProviderDirectoryStore();
            string? uri = ProviderDirectoryStore.runtime_proxy_uri(proxy);
            assert_true(uri == null, "disabled Tor should not override the system proxy");
            Soup.Session session = store.create_refresh_session(uri);
            assert_true(session.proxy_resolver == ProxyResolver.get_default(), "system resolver should remain selected");
        } catch (Error error) {
            GLib.Test.message("System resolver check failed: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_refresh_runtime_route(string mode) {
        // The mock resolver forbids every DNS lookup. Even a regression which
        // retries the HTTPS hostname directly cannot contact external DNS.
        Resolver previous_resolver = Resolver.get_default();
        var no_dns = new ProviderDirectoryNoDnsResolver();
        no_dns.set_default();
        ProviderDirectoryLoopbackServer? server = null;
        try {
            bool direct = mode == "tor-enable";
            server = new ProviderDirectoryLoopbackServer(!direct, mode == "reject");
            var fixture = (!) server;
            var proxy = new ProviderDirectoryProxy();
            proxy.port = fixture.port;
            proxy.enabled = !direct;
            proxy.ready = !direct;
            var cancelled = new Cancellable();
            var injected = new Soup.Session();
            injected.proxy_resolver = new SimpleProxyResolver(null, null);
            string mirror = direct ? "https://127.0.0.1:%u/list.json".printf(fixture.port) :
                    "https://provider.invalid/list.json";
            string cache_path = temp_cache_path("runtime-route");
            string original = valid_payload();
            FileUtils.set_contents(cache_path, original);
            var store = new ProviderDirectoryStore(mirror, cache_path, injected);
            bool completed = false;
            bool expired = false;
            Error? caught = null;
            var loop = new MainLoop();
            ulong observed_handler = fixture.request_observed.connect(() => {
                switch (mode) {
                    case "unready": proxy.ready = false; break;
                    case "port-change": proxy.port = proxy.port == 65535 ? 65534 : proxy.port + 1; break;
                    case "tor-enable": proxy.enabled = true; break;
                    case "caller-cancel": cancelled.cancel(); break;
                }
            });
            ulong closed_handler = fixture.client_closed.connect(() => {
                if (completed) loop.quit();
            });
            var timeout = new TimeoutSource(3000);
            timeout.set_callback(() => {
                expired = true;
                cancelled.cancel();
                fixture.close();
                loop.quit();
                return Source.REMOVE;
            });
            timeout.attach(null);
            store.refresh_from_mirror.begin(cancelled, proxy, (obj, res) => {
                try {
                    store.refresh_from_mirror.end(res);
                } catch (Error error) {
                    caught = error;
                }
                completed = true;
                if (mode == "reject" || fixture.peer_closed) loop.quit();
            });
            if (!completed || (mode != "reject" && !fixture.peer_closed)) loop.run();
            timeout.destroy();
            SignalHandler.disconnect(fixture, observed_handler);
            SignalHandler.disconnect(fixture, closed_handler);
            assert_false(expired, "route changes must abort the request rather than wait for the network timeout");
            assert_true(completed && caught != null, "refused or cancelled network request must fail");
            fail_if_not_eq_int(1, fixture.connections_seen);
            assert_true(fixture.failure == null, "loopback SOCKS fixture must complete its expected protocol");
            if (!direct) {
                fail_if_not_eq_str("provider.invalid", fixture.target_hostname);
                fail_if_not_eq_int(443, fixture.target_port);
            }
            if (mode != "reject") assert_true(fixture.peer_closed, "cancellation must close the active socket");
            fail_if_not_eq_int(0, no_dns.lookups);
            string unchanged;
            FileUtils.get_contents(cache_path, out unchanged);
            fail_if_not_eq_str(original, unchanged);
            assert_true(SignalHandler.find(proxy, SignalMatchType.ID,
                    Signal.lookup("notify", typeof(ProviderDirectoryProxy)), 0, null, null, null) == 0,
                    "finished refresh must disconnect proxy notifications");
            assert_true(SignalHandler.find(cancelled, SignalMatchType.ID,
                    Signal.lookup("cancelled", typeof(Cancellable)), 0, null, null, null) == 0,
                    "finished refresh must disconnect caller cancellation");
            injected.abort();
        } catch (Error error) {
            GLib.Test.message("Loopback provider refresh failed: %s", error.message);
            GLib.Test.fail();
        } finally {
            if (server != null) ((!) server).close();
            previous_resolver.set_default();
        }
    }

    private void test_stream_reader_accepts_bounded_payload() {
        uint8[] payload = new uint8[32];
        var stream = new MemoryInputStream.from_data(payload);
        Error? caught_error;
        Bytes? result = read_stream_limited_sync(stream, 32, null, out caught_error);

        assert_true(caught_error == null, "bounded stream should be accepted");
        assert_true(result != null && ((!) result).get_size() == 32, "bounded stream should remain complete");
    }

    private void test_stream_reader_rejects_oversized_payload() {
        uint8[] payload = new uint8[33];
        var stream = new MemoryInputStream.from_data(payload);
        Error? caught_error;
        Bytes? result = read_stream_limited_sync(stream, 32, null, out caught_error);

        assert_true(result == null, "oversized stream must not produce a payload");
        assert_true(caught_error != null && ((!) caught_error).code == ProviderDirectoryError.INVALID_SCHEMA,
                "oversized stream should be rejected before parsing");
    }

    private Bytes? read_stream_limited_sync(InputStream stream, size_t maximum_bytes,
            Cancellable? cancellable, out Error? caught_error) {
        Bytes? result = null;
        Error? async_error = null;
        var loop = new MainLoop();

        ProviderDirectoryStore.read_stream_limited.begin(stream, maximum_bytes, cancellable, (obj, res) => {
            try {
                result = ProviderDirectoryStore.read_stream_limited.end(res);
            } catch (Error error) {
                async_error = error;
            }
            loop.quit();
        });
        loop.run();

        caught_error = async_error;
        return result;
    }

    private Gee.List<ProviderDirectoryProvider> parse_valid(string payload) {
        try {
            return ProviderDirectoryParser.parse_string(payload);
        } catch (ProviderDirectoryError error) {
            GLib.Test.message("Unexpected provider parser error: %s", error.message);
            GLib.Test.fail();
            return new Gee.ArrayList<ProviderDirectoryProvider>();
        }
    }

    private void expect_invalid(string payload, int expected_code) {
        try {
            ProviderDirectoryParser.parse_string(payload);
        } catch (ProviderDirectoryError error) {
            assert_true(error.code == expected_code, "unexpected provider directory error code");
            return;
        }
        GLib.Test.message("Expected provider directory parser to reject payload");
        GLib.Test.fail();
    }

    private string temp_cache_path(string name) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-provider-directory-" + Uuid.string_random());
        DirUtils.create_with_parents(temp_dir, 0700);
        temporary_directories.add(temp_dir);
        return Path.build_filename(temp_dir, name + ".json");
    }

    public override void tear_down() {
        foreach (string temp_dir in temporary_directories) {
            try {
                Dir directory = Dir.open(temp_dir);
                string? child_name;
                while ((child_name = directory.read_name()) != null) {
                    FileUtils.remove(Path.build_filename(temp_dir, (!) child_name));
                }
            } catch (FileError error) {
                // A test may fail before it creates its cache artifact.
            }
            DirUtils.remove(temp_dir);
        }
        temporary_directories.clear();
    }
}

// A real SOCKS5 listener on IPv4 loopback only. It either refuses CONNECT or
// keeps it pending until the production refresh cancels the connection.
private class ProviderDirectoryLoopbackServer : Object {
    public uint16 port { get; private set; }
    public int connections_seen { get; private set; default = 0; }
    public string? target_hostname { get; private set; }
    public int target_port { get; private set; }
    public string? failure { get; private set; }
    public bool peer_closed { get; private set; default = false; }
    public signal void request_observed();
    public signal void client_closed();

    private SocketService service;
    private Cancellable cancelled = new Cancellable();
    private Gee.ArrayList<SocketConnection> connections = new Gee.ArrayList<SocketConnection>();
    private ulong incoming_handler;
    private bool socks;
    private bool reject;
    private bool stopped = false;

    public ProviderDirectoryLoopbackServer(bool socks, bool reject) throws Error {
        this.socks = socks;
        this.reject = reject;
        service = new SocketService();
        SocketAddress bound;
        service.add_address(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0),
                SocketType.STREAM, SocketProtocol.TCP, null, out bound);
        port = (uint16) ((InetSocketAddress) bound).port;
        incoming_handler = service.incoming.connect((connection, source_object) => {
            connections_seen++;
            connections.add(connection);
            serve.begin(connection);
            return true;
        });
        service.start();
    }

    private async uint8[] read_exact(InputStream input, int length) throws Error {
        uint8[] data = new uint8[length];
        size_t count;
        yield input.read_all_async(data, Priority.DEFAULT, cancelled, out count);
        if (count != length) throw new IOError.INVALID_DATA("Incomplete mock SOCKS request");
        return data;
    }

    private async void serve(SocketConnection connection) {
        try {
            if (socks) {
                uint8[] greeting = yield read_exact(connection.input_stream, 2);
                if (greeting[0] != 5 || greeting[1] == 0) throw new IOError.INVALID_DATA("Unexpected SOCKS greeting");
                yield read_exact(connection.input_stream, greeting[1]);
                size_t written;
                yield connection.output_stream.write_all_async(new uint8[] { 5, 0 }, Priority.DEFAULT, cancelled, out written);
                uint8[] header = yield read_exact(connection.input_stream, 4);
                if (header[0] != 5 || header[1] != 1 || header[3] != 3) {
                    throw new IOError.INVALID_DATA("Provider hostname was not forwarded as SOCKS CONNECT domain");
                }
                uint8[] size = yield read_exact(connection.input_stream, 1);
                uint8[] hostname = yield read_exact(connection.input_stream, size[0]);
                var name = new StringBuilder();
                foreach (uint8 value in hostname) name.append_c((char) value);
                target_hostname = name.str;
                uint8[] address_port = yield read_exact(connection.input_stream, 2);
                target_port = address_port[0] * 256 + address_port[1];
            }
            request_observed();
            if (reject) {
                size_t written;
                yield connection.output_stream.write_all_async(
                        new uint8[] { 5, 4, 0, 1, 127, 0, 0, 1, 0, 0 }, Priority.DEFAULT, cancelled, out written);
            } else {
                while (true) {
                    Bytes remaining = yield connection.input_stream.read_bytes_async(1024, Priority.DEFAULT, cancelled);
                    if (remaining.get_size() == 0) break;
                }
                peer_closed = true;
                client_closed();
            }
        } catch (Error error) {
            if (!stopped) failure = error.message;
        } finally {
            try {
                connection.close(null);
            } catch (Error error) { }
        }
    }

    public void close() {
        if (stopped) return;
        stopped = true;
        cancelled.cancel();
        SignalHandler.disconnect(service, incoming_handler);
        service.stop();
        service.close();
        foreach (var connection in connections) {
            try {
                connection.close(null);
            } catch (Error error) { }
        }
        connections.clear();
    }
}

private class ProviderDirectoryNoDnsResolver : Resolver {
    public int lookups { get; private set; default = 0; }

    public override GLib.List<InetAddress> lookup_by_name(string hostname, Cancellable? cancellable = null) throws Error {
        lookups++;
        throw new ResolverError.NOT_FOUND("DNS is forbidden in this loopback fixture");
    }

    public override async GLib.List<InetAddress> lookup_by_name_async(string hostname, Cancellable? cancellable = null) throws Error {
        lookups++;
        throw new ResolverError.NOT_FOUND("DNS is forbidden in this loopback fixture");
    }

    public override GLib.List<InetAddress> lookup_by_name_with_flags(string hostname, ResolverNameLookupFlags flags,
            Cancellable? cancellable = null) throws Error {
        lookups++;
        throw new ResolverError.NOT_FOUND("DNS is forbidden in this loopback fixture");
    }

    public override async GLib.List<InetAddress> lookup_by_name_with_flags_async(string hostname, ResolverNameLookupFlags flags,
            Cancellable? cancellable = null) throws Error {
        lookups++;
        throw new ResolverError.NOT_FOUND("DNS is forbidden in this loopback fixture");
    }
}

}
