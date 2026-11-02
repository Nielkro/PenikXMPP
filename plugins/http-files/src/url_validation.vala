/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Plugins.HttpFiles {

internal class HttpFileUrl : Object {
    public static bool is_valid_network_url(string? url) {
        if (url == null || ((!) url).length == 0) return false;

        if (has_unsafe_character((!) url, false)) return false;

        try {
            Uri parsed = Uri.parse((!) url, UriFlags.NONE);
            string scheme = parsed.get_scheme().ascii_down();
            string? host = parsed.get_host();
            return (scheme == "http" || scheme == "https") &&
                    host != null && ((!) host).length > 0 &&
                    !has_unsafe_character((!) host, true);
        } catch (UriError e) {
            return false;
        }
    }

    private static bool has_unsafe_character(string value, bool decoded_host) {
        bool host_is_ip_address = decoded_host && Hostname.is_ip_address(value);
        int byte_index = 0;
        unichar character;
        while (value.get_next_char(ref byte_index, out character)) {
            UnicodeType type = character.type();
            if (character == '\\' || character.isspace() ||
                    type == UnicodeType.CONTROL ||
                    type == UnicodeType.FORMAT ||
                    type == UnicodeType.LINE_SEPARATOR ||
                    type == UnicodeType.PARAGRAPH_SEPARATOR) {
                return true;
            }
            if (decoded_host && (character == '/' ||
                    character == '?' || character == '#' || character == '@' ||
                    character == '[' || character == ']' || character == '<' ||
                    character == '>' || character == '^' || character == '|' ||
                    (character == ':' && !host_is_ip_address))) {
                return true;
            }
        }
        return false;
    }

    public static Soup.Message? create_message(string method, string url) {
        if (!is_valid_network_url(url)) return null;
        return new Soup.Message(method, url);
    }
}

}
