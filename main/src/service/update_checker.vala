/*
 * Copyright (C) 2026 DinoX Team <contact@dinox.im>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Ui {

public errordomain UpdateCheckError {
    CANCELLED,
    NETWORK,
    INVALID_RESPONSE,
    INVALID_VERSION
}

public class UpdateRelease : Object {
    public string tag_name { get; private set; }
    public string version { get; private set; }
    public string release_url { get; private set; }

    internal UpdateRelease(string tag_name, string version, string release_url) {
        this.tag_name = tag_name;
        this.version = version;
        this.release_url = release_url;
    }
}

public class UpdateCheckResult : Object {
    public string current_version { get; private set; }
    public UpdateRelease latest_release { get; private set; }
    public bool update_available { get; private set; }

    internal UpdateCheckResult(string current_version, UpdateRelease latest_release,
            bool update_available) {
        this.current_version = current_version;
        this.latest_release = latest_release;
        this.update_available = update_available;
    }
}

/**
 * Performs the user-requested release check. Constructing this class does not
 * start network activity; check() is the only network entry point.
 */
public class UpdateChecker : Object {
    public const string LATEST_RELEASE_API_URL =
        "https://git.dinox.im/api/v1/repos/dinoxim/dinox/releases/latest";
    public const size_t MAX_RESPONSE_BYTES = 1024 * 1024;

    private const string RELEASE_HOST = "git.dinox.im";
    private const string RELEASE_PATH_PREFIX = "/dinoxim/dinox/releases/tag/";

    private Soup.Session session;

    public UpdateChecker(Soup.Session? session = null) {
        this.session = session ?? new Soup.Session();
        this.session.set_timeout(15);
        this.session.set_idle_timeout(15);
        this.session.set_user_agent("DinoX update checker");
    }

    public async UpdateCheckResult check(string current_version,
            Cancellable? cancellable = null) throws UpdateCheckError {
        // Reject an invalid local build version before contacting the server.
        string normalized_current = normalize_version(current_version, true);

        var message = new Soup.Message("GET", LATEST_RELEASE_API_URL);
        message.add_flags(Soup.MessageFlags.NO_REDIRECT);
        message.request_headers.append("Accept", "application/json");
        message.request_headers.append("Cache-Control", "no-cache");

        InputStream? response_stream = null;
        Bytes? response = null;
        try {
            response_stream = yield session.send_async(
                message, Priority.DEFAULT, cancellable);
        } catch (IOError.CANCELLED error) {
            throw new UpdateCheckError.CANCELLED("Update check was cancelled");
        } catch (Error error) {
            throw new UpdateCheckError.NETWORK(
                "Update check request failed: %s", error.message);
        }

        try {
            if (message.get_uri().to_string() != LATEST_RELEASE_API_URL) {
                throw new UpdateCheckError.INVALID_RESPONSE(
                    "Update check response came from an unexpected URL");
            }
            if (message.status_code != 200) {
                throw new UpdateCheckError.NETWORK(
                    "Update check returned HTTP %u", message.status_code);
            }

            int64 content_length = message.response_headers.get_content_length();
            if (content_length > (int64) MAX_RESPONSE_BYTES) {
                throw new UpdateCheckError.INVALID_RESPONSE(
                    "Update check response is too large");
            }

            response = yield read_stream_limited(
                (!) response_stream, MAX_RESPONSE_BYTES, cancellable);
        } finally {
            try {
                ((!) response_stream).close(null);
            } catch (Error error) {
                // The complete response has already been consumed or rejected.
            }
        }

        UpdateRelease release = parse_release_bytes((!) response);
        return evaluate(normalized_current, release);
    }

    internal static UpdateCheckResult evaluate(string current_version,
            UpdateRelease latest_release) throws UpdateCheckError {
        string normalized_current = normalize_version(current_version, true);
        bool available = compare_versions(
            normalized_current, latest_release.version) < 0;
        return new UpdateCheckResult(
            normalized_current, latest_release, available);
    }

    internal static UpdateRelease parse_release_bytes(Bytes data)
            throws UpdateCheckError {
        size_t size = data.get_size();
        if (size == 0) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response is empty");
        }
        if (size > MAX_RESPONSE_BYTES) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response is too large");
        }

        unowned uint8[] raw = data.get_data();
        uint8[] nul_terminated = new uint8[size + 1];
        GLib.Memory.copy(nul_terminated, raw, size);
        nul_terminated[size] = 0;
        return parse_release_json((string) nul_terminated);
    }

    internal static UpdateRelease parse_release_json(string data)
            throws UpdateCheckError {
        if (data.length == 0) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response is empty");
        }
        if ((size_t) data.length > MAX_RESPONSE_BYTES) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response is too large");
        }

        var parser = new Json.Parser();
        try {
            parser.load_from_data(data, (ssize_t) data.length);
        } catch (Error error) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response is not valid JSON: %s", error.message);
        }

        unowned Json.Node? root = parser.get_root();
        if (root == null || root.get_node_type() != Json.NodeType.OBJECT ||
                root.get_object() == null) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response root must be an object");
        }

        unowned Json.Object object = (!) root.get_object();
        string tag_name = require_string_member(object, "tag_name");
        string release_url = require_string_member(object, "html_url");
        bool draft = require_bool_member(object, "draft");
        bool prerelease = require_bool_member(object, "prerelease");

        if (tag_name != tag_name.strip()) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Release tag must not contain surrounding whitespace");
        }
        if (draft || prerelease) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Latest release response must describe a stable published release");
        }

        string version = normalize_version(tag_name, false);
        validate_release_url(release_url, tag_name);
        return new UpdateRelease(tag_name, version, release_url);
    }

    internal static int compare_versions(string left, string right)
            throws UpdateCheckError {
        string normalized_left;
        string normalized_right;
        uint[] left_parts = parse_version(left, true, out normalized_left);
        uint[] right_parts = parse_version(right, false, out normalized_right);
        int count = int.max(left_parts.length, right_parts.length);

        for (int i = 0; i < count; i++) {
            uint left_part = i < left_parts.length ? left_parts[i] : 0;
            uint right_part = i < right_parts.length ? right_parts[i] : 0;
            if (left_part < right_part) return -1;
            if (left_part > right_part) return 1;
        }
        return 0;
    }

    private static string normalize_version(string raw, bool allow_suffix)
            throws UpdateCheckError {
        string normalized;
        parse_version(raw, allow_suffix, out normalized);
        return normalized;
    }

    private static uint[] parse_version(string raw, bool allow_suffix,
            out string normalized) throws UpdateCheckError {
        normalized = raw.strip();
        if (normalized == "") {
            throw new UpdateCheckError.INVALID_VERSION("Version is empty");
        }
        if (normalized.has_prefix("v") || normalized.has_prefix("V")) {
            normalized = normalized.substring(1);
        }

        int suffix_index = -1;
        string[] suffix_markers = { "~", "+", "-" };
        foreach (string marker in suffix_markers) {
            int marker_index = normalized.index_of(marker);
            if (marker_index >= 0 &&
                    (suffix_index < 0 || marker_index < suffix_index)) {
                suffix_index = marker_index;
            }
        }
        if (suffix_index >= 0) {
            if (!allow_suffix) {
                throw new UpdateCheckError.INVALID_VERSION(
                    "Published release version must not contain a suffix");
            }
            normalized = normalized.substring(0, suffix_index);
        }

        string[] components = normalized.split(".");
        if (components.length < 3 || components.length > 4) {
            throw new UpdateCheckError.INVALID_VERSION(
                "Version must contain three or four numeric components");
        }

        uint[] parsed = new uint[components.length];
        for (int i = 0; i < components.length; i++) {
            string component = components[i];
            if (component == "") {
                throw new UpdateCheckError.INVALID_VERSION(
                    "Version component must not be empty");
            }
            for (int j = 0; j < component.length; j++) {
                if (component[j] < '0' || component[j] > '9') {
                    throw new UpdateCheckError.INVALID_VERSION(
                        "Version components must be numeric");
                }
            }

            uint value;
            if (!uint.try_parse(component, out value, null, 10)) {
                throw new UpdateCheckError.INVALID_VERSION(
                    "Version component is outside the supported range");
            }
            parsed[i] = value;
        }
        return parsed;
    }

    private static string require_string_member(Json.Object object, string member)
            throws UpdateCheckError {
        unowned Json.Node? node = object.get_member(member);
        if (node == null || node.is_null() ||
                node.get_node_type() != Json.NodeType.VALUE ||
                node.get_value_type() != typeof(string) ||
                node.get_string() == null || ((!) node.get_string()).strip() == "") {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response member '%s' must be a non-empty string",
                member);
        }
        return (!) node.get_string();
    }

    private static bool require_bool_member(Json.Object object, string member)
            throws UpdateCheckError {
        unowned Json.Node? node = object.get_member(member);
        if (node == null || node.is_null() ||
                node.get_node_type() != Json.NodeType.VALUE ||
                node.get_value_type() != typeof(bool)) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Update check response member '%s' must be a boolean", member);
        }
        return node.get_boolean();
    }

    private static void validate_release_url(string value, string tag_name)
            throws UpdateCheckError {
        GLib.Uri uri;
        try {
            uri = GLib.Uri.parse(value, GLib.UriFlags.NONE);
        } catch (UriError error) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Release URL is invalid: %s", error.message);
        }

        string? host = uri.get_host();
        int port = uri.get_port();
        if (uri.get_scheme().ascii_down() != "https" || host == null ||
                ((!) host).ascii_down() != RELEASE_HOST ||
                (port != -1 && port != 443) || uri.get_userinfo() != null ||
                uri.get_query() != null || uri.get_fragment() != null ||
                uri.get_path() != RELEASE_PATH_PREFIX + tag_name) {
            throw new UpdateCheckError.INVALID_RESPONSE(
                "Release URL does not point to the official DinoX release");
        }
    }

    private static async Bytes read_stream_limited(InputStream stream,
            size_t maximum_bytes, Cancellable? cancellable)
            throws UpdateCheckError {
        var collected = new ByteArray();
        size_t total = 0;

        try {
            while (true) {
                Bytes chunk = yield stream.read_bytes_async(
                    8192, Priority.DEFAULT, cancellable);
                size_t chunk_size = chunk.get_size();
                if (chunk_size == 0) break;
                if (chunk_size > maximum_bytes ||
                        total > maximum_bytes - chunk_size) {
                    throw new UpdateCheckError.INVALID_RESPONSE(
                        "Update check response is too large");
                }

                unowned uint8[] chunk_data = chunk.get_data();
                collected.append(chunk_data);
                total += chunk_size;
            }
        } catch (UpdateCheckError error) {
            throw error;
        } catch (IOError.CANCELLED error) {
            throw new UpdateCheckError.CANCELLED("Update check was cancelled");
        } catch (Error error) {
            throw new UpdateCheckError.NETWORK(
                "Update check response could not be read: %s", error.message);
        }

        return ByteArray.free_to_bytes((owned) collected);
    }
}

}
