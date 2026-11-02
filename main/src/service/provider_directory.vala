/*
 * Copyright (C) 2026 DinoX Team <contact@dinox.im>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Ui {

public errordomain ProviderDirectoryError {
    INVALID_JSON,
    INVALID_SCHEMA,
    NETWORK,
    IO,
    PROXY_UNAVAILABLE
}

public enum ProviderDirectoryLoadSource {
    CACHE,
    BUNDLED
}

public class ProviderDirectoryProvider : Object {
    public string jid { get; private set; }
    public string category { get; private set; }
    public bool in_band_registration { get; private set; }
    public bool in_band_registration_email_address_required { get; private set; }
    public bool in_band_registration_captcha_required { get; private set; }
    public bool free_of_charge { get; private set; }
    public int64 maximum_http_file_upload_file_size { get; private set; }
    public int64 maximum_http_file_upload_total_size { get; private set; }
    public int64 maximum_http_file_upload_storage_time { get; private set; }
    public int64 maximum_message_archive_management_storage_time { get; private set; }
    public Gee.List<string> server_locations { get; private set; }
    public Gee.Map<string, string> registration_web_pages { get; private set; }
    public Gee.Map<string, string> websites { get; private set; }

    public bool has_web_registration {
        get { return registration_web_pages.size > 0; }
    }

    internal ProviderDirectoryProvider(
            string jid,
            string category,
            bool in_band_registration,
            bool in_band_registration_email_address_required,
            bool in_band_registration_captcha_required,
            bool free_of_charge,
            int64 maximum_http_file_upload_file_size,
            int64 maximum_http_file_upload_total_size,
            int64 maximum_http_file_upload_storage_time,
            int64 maximum_message_archive_management_storage_time,
            Gee.Collection<string> server_locations,
            Gee.Map<string, string> registration_web_pages,
            Gee.Map<string, string> websites) {
        this.jid = jid;
        this.category = category;
        this.in_band_registration = in_band_registration;
        this.in_band_registration_email_address_required = in_band_registration_email_address_required;
        this.in_band_registration_captcha_required = in_band_registration_captcha_required;
        this.free_of_charge = free_of_charge;
        this.maximum_http_file_upload_file_size = maximum_http_file_upload_file_size;
        this.maximum_http_file_upload_total_size = maximum_http_file_upload_total_size;
        this.maximum_http_file_upload_storage_time = maximum_http_file_upload_storage_time;
        this.maximum_message_archive_management_storage_time = maximum_message_archive_management_storage_time;
        this.server_locations = new Gee.ArrayList<string>();
        this.registration_web_pages = new Gee.HashMap<string, string>();
        this.websites = new Gee.HashMap<string, string>();

        foreach (string server_location in server_locations) {
            this.server_locations.add(server_location);
        }
        foreach (var entry in registration_web_pages.entries) {
            this.registration_web_pages.set(entry.key, entry.value);
        }
        foreach (var entry in websites.entries) {
            this.websites.set(entry.key, entry.value);
        }
    }
}

public class ProviderDirectoryParser : Object {
    public const size_t MAX_PAYLOAD_BYTES = 256 * 1024;

    public static Gee.List<ProviderDirectoryProvider> parse_bytes(Bytes data) throws ProviderDirectoryError {
        size_t size = data.get_size();
        if (size == 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory payload is empty");
        }
        if (size > MAX_PAYLOAD_BYTES) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory payload is too large");
        }

        uint8[] raw = data.get_data();
        uint8[] nul_terminated = new uint8[size + 1];
        GLib.Memory.copy(nul_terminated, raw, size);
        nul_terminated[size] = 0;
        return parse_string((string) nul_terminated);
    }

    public static Gee.List<ProviderDirectoryProvider> parse_string(string data) throws ProviderDirectoryError {
        if (data.length == 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory payload is empty");
        }
        if ((size_t) data.length > MAX_PAYLOAD_BYTES) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory payload is too large");
        }

        var parser = new Json.Parser();
        try {
            parser.load_from_data(data, (ssize_t) data.length);
        } catch (Error error) {
            throw new ProviderDirectoryError.INVALID_JSON("Provider directory payload is not valid JSON: %s", error.message);
        }

        unowned Json.Node? root = parser.get_root();
        if (root == null || root.get_node_type() != Json.NodeType.ARRAY) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory root must be an array");
        }

        unowned Json.Array? array = root.get_array();
        if (array == null || array.get_length() == 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory must not be empty");
        }

        var providers = new Gee.ArrayList<ProviderDirectoryProvider>();
        var seen_jids = new Gee.HashSet<string>();

        for (uint i = 0; i < array.get_length(); i++) {
            unowned Json.Node provider_node = array.get_element(i);
            if (provider_node.get_node_type() != Json.NodeType.OBJECT || provider_node.get_object() == null) {
                throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u] must be an object", i);
            }

            ProviderDirectoryProvider provider = parse_provider((!) provider_node.get_object(), i);
            if (!seen_jids.add(provider.jid)) {
                throw new ProviderDirectoryError.INVALID_SCHEMA("Duplicate provider JID: %s", provider.jid);
            }
            providers.add(provider);
        }

        return providers;
    }

    private static ProviderDirectoryProvider parse_provider(Json.Object object, uint index) throws ProviderDirectoryError {
        string jid = normalize_domain(require_string_member(object, "jid", index));
        string category = require_string_member(object, "category", index);
        if (category != "A" && category != "B") {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].category must be A or B", index);
        }

        bool in_band_registration = require_bool_member(object, "inBandRegistration", index);
        Gee.Map<string, string> registration_web_pages = require_https_url_map(object, "registrationWebPage", index);
        Gee.Map<string, string> websites = require_https_url_map(object, "website", index);

        if (!in_band_registration && registration_web_pages.size == 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u] has no in-band registration and no registration web page", index);
        }

        return new ProviderDirectoryProvider(
            jid,
            category,
            in_band_registration,
            optional_bool_member(object, "inBandRegistrationEmailAddressRequired", index, false),
            optional_bool_member(object, "inBandRegistrationCaptchaRequired", index, false),
            optional_bool_member(object, "freeOfCharge", index, false),
            optional_non_negative_int_member(object, "maximumHttpFileUploadFileSize", index, -1),
            optional_non_negative_int_member(object, "maximumHttpFileUploadTotalSize", index, -1),
            optional_non_negative_int_member(object, "maximumHttpFileUploadStorageTime", index, -1),
            optional_non_negative_int_member(object, "maximumMessageArchiveManagementStorageTime", index, -1),
            optional_string_array_member(object, "serverLocations", index),
            registration_web_pages,
            websites
        );
    }

    private static unowned Json.Node require_member(Json.Object object, string member, uint index) throws ProviderDirectoryError {
        unowned Json.Node? node = object.get_member(member);
        if (node == null || node.is_null()) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s is required", index, member);
        }
        return (!) node;
    }

    private static string require_string_member(Json.Object object, string member, uint index) throws ProviderDirectoryError {
        unowned Json.Node node = require_member(object, member, index);
        if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(string) || node.get_string() == null) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be a string", index, member);
        }
        return (!) node.get_string();
    }

    private static bool require_bool_member(Json.Object object, string member, uint index) throws ProviderDirectoryError {
        unowned Json.Node node = require_member(object, member, index);
        if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(bool)) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be a boolean", index, member);
        }
        return node.get_boolean();
    }

    private static bool optional_bool_member(Json.Object object, string member, uint index, bool fallback) throws ProviderDirectoryError {
        unowned Json.Node? node = object.get_member(member);
        if (node == null) return fallback;
        if (node.is_null() || node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(bool)) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be a boolean", index, member);
        }
        return node.get_boolean();
    }

    private static int64 optional_non_negative_int_member(Json.Object object, string member, uint index, int64 fallback) throws ProviderDirectoryError {
        unowned Json.Node? node = object.get_member(member);
        if (node == null) return fallback;
        if (node.is_null() || node.get_node_type() != Json.NodeType.VALUE) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be a non-negative number", index, member);
        }

        int64 value;
        if (node.get_value_type() == typeof(int64)) {
            value = node.get_int();
        } else if (node.get_value_type() == typeof(double)) {
            double double_value = node.get_double();
            value = (int64) double_value;
            if ((double) value != double_value) {
                throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be an integer number", index, member);
            }
        } else {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be a non-negative number", index, member);
        }

        if (value < 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be a non-negative number", index, member);
        }
        return value;
    }

    private static Gee.List<string> optional_string_array_member(Json.Object object, string member, uint index) throws ProviderDirectoryError {
        var values = new Gee.ArrayList<string>();
        unowned Json.Node? node = object.get_member(member);
        if (node == null) return values;
        if (node.is_null() || node.get_node_type() != Json.NodeType.ARRAY || node.get_array() == null) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be an array", index, member);
        }

        unowned Json.Array array = (!) node.get_array();
        for (uint i = 0; i < array.get_length(); i++) {
            unowned Json.Node item = array.get_element(i);
            if (item.get_node_type() != Json.NodeType.VALUE || item.get_value_type() != typeof(string) || item.get_string() == null || ((!) item.get_string()).strip() == "") {
                throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s[%u] must be a non-empty string", index, member, i);
            }
            values.add((!) item.get_string());
        }
        return values;
    }

    private static Gee.Map<string, string> require_https_url_map(Json.Object object, string member, uint index) throws ProviderDirectoryError {
        unowned Json.Node node = require_member(object, member, index);
        if (node.get_node_type() != Json.NodeType.OBJECT || node.get_object() == null) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s must be an object", index, member);
        }

        var values = new Gee.HashMap<string, string>();
        Json.ObjectIter iter = Json.ObjectIter();
        iter.init((!) node.get_object());
        unowned string language;
        unowned Json.Node url_node;
        while (iter.next(out language, out url_node)) {
            if (language.strip() == "") {
                throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s contains an empty language key", index, member);
            }
            if (url_node.get_node_type() != Json.NodeType.VALUE || url_node.get_value_type() != typeof(string) || url_node.get_string() == null) {
                throw new ProviderDirectoryError.INVALID_SCHEMA("provider[%u].%s.%s must be a string", index, member, language);
            }
            string url = (!) url_node.get_string();
            validate_https_url(url, "provider[%u].%s.%s".printf(index, member, language));
            values.set(language, url);
        }
        return values;
    }

    private static string normalize_domain(string raw) throws ProviderDirectoryError {
        string domain = raw.strip().down();
        if (domain == "" || domain != raw) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider domain must be normalized: %s", raw);
        }
        if (domain.index_of("@") >= 0 || domain.index_of("/") >= 0 || domain.index_of(":") >= 0 || domain.index_of(" ") >= 0 || domain.index_of("\t") >= 0 || domain.index_of("\n") >= 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider domain contains invalid characters: %s", raw);
        }

        string[] labels = domain.split(".");
        if (labels.length < 2) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("Provider domain must contain at least two labels: %s", raw);
        }
        foreach (string label in labels) {
            if (label == "" || label.has_prefix("-") || label.has_suffix("-")) {
                throw new ProviderDirectoryError.INVALID_SCHEMA("Provider domain contains an invalid label: %s", raw);
            }
        }
        return domain;
    }

    internal static void validate_https_url(string url, string context) throws ProviderDirectoryError {
        if (!url.has_prefix("https://")) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("%s must be an HTTPS URL", context);
        }
        if (url.index_of(" ") >= 0 || url.index_of("\t") >= 0 || url.index_of("\n") >= 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("%s must not contain whitespace", context);
        }

        string rest = url.substring(8);
        int slash_index = rest.index_of("/");
        string authority = slash_index >= 0 ? rest.substring(0, slash_index) : rest;
        if (authority == "" || authority.index_of("@") >= 0) {
            throw new ProviderDirectoryError.INVALID_SCHEMA("%s must contain a host and no credentials", context);
        }
    }
}

public class ProviderDirectoryStore : Object {
    public const string DEFAULT_MIRROR_URL = "https://dinox.im/data/providers/v2/providers-B.json";
    public const string BUNDLED_RESOURCE_PATH = "/im/dinox/dinox/providers-v2-B.json";

    private string mirror_url;
    private string cache_path;
    private Soup.Session? provided_session;

    public ProviderDirectoryStore(string mirror_url = DEFAULT_MIRROR_URL, string? cache_path = null, Soup.Session? session = null) {
        this.mirror_url = mirror_url;
        this.cache_path = cache_path ?? default_cache_path();
        this.provided_session = session;
    }

    public static string default_cache_path() {
        return Path.build_filename(Environment.get_user_cache_dir(), "dinox", "providers", "v2", "providers-B.json");
    }

    public Gee.List<ProviderDirectoryProvider> load_initial() throws ProviderDirectoryError {
        ProviderDirectoryLoadSource source;
        return load_initial_with_source(out source);
    }

    public Gee.List<ProviderDirectoryProvider> load_initial_with_source(out ProviderDirectoryLoadSource source) throws ProviderDirectoryError {
        Gee.List<ProviderDirectoryProvider>? cached = try_load_cache();
        if (cached != null) {
            source = ProviderDirectoryLoadSource.CACHE;
            return (!) cached;
        }
        source = ProviderDirectoryLoadSource.BUNDLED;
        return load_bundled();
    }

    public Gee.List<ProviderDirectoryProvider> load_bundled() throws ProviderDirectoryError {
        try {
            Bytes data = resources_lookup_data(BUNDLED_RESOURCE_PATH, ResourceLookupFlags.NONE);
            return ProviderDirectoryParser.parse_bytes(data);
        } catch (ProviderDirectoryError error) {
            throw error;
        } catch (Error error) {
            throw new ProviderDirectoryError.IO("Bundled provider snapshot could not be loaded: %s", error.message);
        }
    }

    public Gee.List<ProviderDirectoryProvider>? try_load_cache() {
        try {
            string contents;
            FileUtils.get_contents(cache_path, out contents);
            return ProviderDirectoryParser.parse_string(contents);
        } catch (Error error) {
            return null;
        }
    }

    public DateTime? get_cache_modified_time() {
        try {
            File cache_file = File.new_for_path(cache_path);
            FileInfo info = cache_file.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE, null);
            return info.get_modification_date_time();
        } catch (Error error) {
            return null;
        }
    }

    internal static string? runtime_proxy_uri(Dino.Plugins.AccountProxyProvider? provider) throws ProviderDirectoryError {
        if (provider == null || !provider.proxy_enabled) return null;
        // Desired Tor state matters even before its SOCKS listener is ready.
        // Never let startup/failure silently select the ordinary resolver.
        if (!provider.proxy_ready) {
            throw new ProviderDirectoryError.PROXY_UNAVAILABLE("Enabled provider proxy is not ready");
        }
        string host = provider.proxy_host;
        if ((provider.proxy_type != "tor" && provider.proxy_type != "socks5") ||
                provider.proxy_port < 1 || provider.proxy_port > 65535 || host == "" ||
                host.strip() != host || host.index_of("/") >= 0 || host.index_of("@") >= 0 ||
                host.index_of("?") >= 0 || host.index_of("#") >= 0 || host.index_of("\\") >= 0) {
            throw new ProviderDirectoryError.PROXY_UNAVAILABLE("Enabled provider proxy has an invalid endpoint");
        }
        if (host.index_of(":") >= 0 && !host.has_prefix("[")) host = "[" + host + "]";
        // GIO's socks5 resolver sends hostnames through SOCKS, without local DNS.
        return "socks5://%s:%d".printf(host, provider.proxy_port);
    }

    internal Soup.Session create_refresh_session(string? proxy_uri) {
        // An in-flight session must keep its route. In particular, never mutate
        // a shared/injected session when Tor is enabled or restarted.
        Soup.Session session = proxy_uri == null && provided_session != null ?
                (!) provided_session : new Soup.Session();
        if (proxy_uri != null) {
            session.proxy_resolver = new SimpleProxyResolver(proxy_uri, null);
        }
        session.set_timeout(20);
        session.set_idle_timeout(20);
        session.set_user_agent("DinoX provider directory");
        return session;
    }

    private static void ensure_runtime_route(Dino.Plugins.AccountProxyProvider? provider,
            string? expected_uri) throws ProviderDirectoryError {
        if (runtime_proxy_uri(provider) != expected_uri) {
            throw new ProviderDirectoryError.PROXY_UNAVAILABLE("Provider proxy changed during refresh");
        }
    }

    // GTask can return IOError.CANCELLED from .end() independently of the
    // errors normalized below. Cancellable async APIs must expose GLib.Error.
    public async Gee.List<ProviderDirectoryProvider> refresh_from_mirror(Cancellable? cancellable = null,
            Dino.Plugins.AccountProxyProvider? proxy_provider = null) throws Error {
        ProviderDirectoryParser.validate_https_url(mirror_url, "provider mirror URL");
        string? proxy_uri = runtime_proxy_uri(proxy_provider);
        Soup.Session session = create_refresh_session(proxy_uri);
        var request_cancel = new Cancellable();
        ulong cancel_handler = 0;
        ulong proxy_handler = 0;
        if (cancellable != null) {
            cancel_handler = cancellable.connect(() => request_cancel.cancel());
        }
        if (proxy_provider != null) {
            proxy_handler = proxy_provider.notify.connect(() => {
                try {
                    ensure_runtime_route(proxy_provider, proxy_uri);
                } catch (ProviderDirectoryError error) {
                    request_cancel.cancel();
                }
            });
        }

        var message = new Soup.Message("GET", mirror_url);
        message.request_headers.append("Accept", "application/json");

        InputStream? response_stream = null;
        Bytes? response = null;
        try {
            ensure_runtime_route(proxy_provider, proxy_uri);
            try {
                response_stream = yield session.send_async(message, Priority.DEFAULT, request_cancel);
            } catch (Error error) {
                throw new ProviderDirectoryError.NETWORK("Provider mirror request failed: %s", error.message);
            }
            ensure_runtime_route(proxy_provider, proxy_uri);
            ProviderDirectoryParser.validate_https_url(
                    message.get_uri().to_string(), "provider mirror response URL");
            if (message.status_code != 200) {
                throw new ProviderDirectoryError.NETWORK("Provider mirror returned HTTP %u", message.status_code);
            }

            int64 content_length = message.response_headers.get_content_length();
            if (content_length > (int64) ProviderDirectoryParser.MAX_PAYLOAD_BYTES) {
                throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory payload is too large");
            }

            response = yield read_stream_limited((!) response_stream, ProviderDirectoryParser.MAX_PAYLOAD_BYTES, request_cancel);
            ensure_runtime_route(proxy_provider, proxy_uri);
            Gee.List<ProviderDirectoryProvider> providers = ProviderDirectoryParser.parse_bytes((!) response);
            yield write_cache((!) response, request_cancel);
            ensure_runtime_route(proxy_provider, proxy_uri);
            return providers;
        } finally {
            if (cancel_handler != 0) ((!) cancellable).disconnect(cancel_handler);
            if (proxy_handler != 0) proxy_provider.disconnect(proxy_handler);
            if (response_stream != null) {
                try {
                    ((!) response_stream).close(null);
                } catch (Error error) {
                    // The response has already been consumed or rejected.
                }
            }
            if (session != provided_session) session.abort();
        }
    }

    internal static async Bytes read_stream_limited(InputStream stream, size_t maximum_bytes,
            Cancellable? cancellable = null) throws Error {
        var collected = new ByteArray();
        size_t total = 0;

        try {
            while (true) {
                Bytes chunk = yield stream.read_bytes_async(8192, Priority.DEFAULT, cancellable);
                size_t chunk_size = chunk.get_size();
                if (chunk_size == 0) break;
                if (chunk_size > maximum_bytes || total > maximum_bytes - chunk_size) {
                    throw new ProviderDirectoryError.INVALID_SCHEMA("Provider directory payload is too large");
                }

                unowned uint8[] chunk_data = chunk.get_data();
                collected.append(chunk_data);
                total += chunk_size;
            }
        } catch (ProviderDirectoryError error) {
            throw error;
        } catch (IOError.CANCELLED error) {
            throw new ProviderDirectoryError.NETWORK("Provider mirror request was cancelled");
        } catch (Error error) {
            throw new ProviderDirectoryError.NETWORK("Provider mirror response could not be read: %s", error.message);
        }

        return ByteArray.free_to_bytes((owned) collected);
    }

    internal async void write_cache(Bytes data, Cancellable? cancellable) throws Error {
        if (cancellable != null && ((!) cancellable).is_cancelled()) {
            throw new ProviderDirectoryError.NETWORK("Provider mirror request was cancelled");
        }

        try {
            File cache_file = File.new_for_path(cache_path);
            File? parent = cache_file.get_parent();
            if (parent != null) {
                try {
                    ((!) parent).make_directory_with_parents(cancellable);
                } catch (IOError.EXISTS error) {
                    // Directory already exists.
                }
            }

            string? new_etag;
            yield cache_file.replace_contents_bytes_async(
                    data, null, false, FileCreateFlags.PRIVATE, cancellable, out new_etag);
        } catch (IOError.CANCELLED error) {
            throw new ProviderDirectoryError.NETWORK("Provider mirror request was cancelled");
        } catch (Error error) {
            throw new ProviderDirectoryError.IO("Provider directory cache could not be updated: %s", error.message);
        }
    }
}

}
