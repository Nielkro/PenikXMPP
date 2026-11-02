using Gee;

namespace Xmpp {

public string random_uuid() {
    uint32 b1 = Random.next_int();
    uint16 b2 = (uint16)Random.next_int();
    uint16 b3 = (uint16)(Random.next_int() | 0x4000u) & ~0xb000u;
    uint16 b4 = (uint16)(Random.next_int() | 0x8000u) & ~0x4000u;
    uint16 b5_1 = (uint16)Random.next_int();
    uint32 b5_2 = Random.next_int();
    return "%08x-%04x-%04x-%04x-%04x%08x".printf(b1, b2, b3, b4, b5_1, b5_2);
}

public Bytes? get_data_for_uri(string uri) {
    string? media_type;
    return get_data_for_uri_with_media_type(uri, out media_type);
}

internal Bytes? get_data_for_uri_with_media_type(string uri, out string? media_type) {
    media_type = null;
    if (uri.has_prefix("cid:") && uri.has_suffix("@bob.xmpp.org")) {
        return Xep.BitsOfBinary.known_bobs == null ? null : Xep.BitsOfBinary.known_bobs[uri.substring(4)];
    }

    // RFC 2397 encodes bytes independently of their media type. Whether those
    // bytes can be displayed (e.g. a ThumbHash instead of a PNG) is up to the UI.
    // Unsupported remote URIs are normal optional metadata, not parser warnings;
    // never log their contents, which can contain private inline image data.
    if (uri.length < 5 || uri.substring(0, 5).ascii_casecmp("data:") != 0) return null;
    int separator = uri.index_of_char(',');
    if (separator < 0) return null;

    string metadata = uri.substring(5, separator - 5);
    bool base64 = metadata.length >= 7 && metadata.substring(metadata.length - 7).ascii_casecmp(";base64") == 0;
    if (base64) metadata = metadata.substring(0, metadata.length - 7);
    string? decoded_metadata = decode_data_uri_media_type(metadata);
    if (decoded_metadata == null) return null;

    string payload = uri.substring(separator + 1);
    Bytes? data;
    if (base64) {
        string? encoded = Uri.unescape_string(payload);
        if (encoded == null) return null;
        // GLib's decoder silently ignores arbitrary invalid bytes. Require a
        // complete Base64 value, retaining support for MIME whitespace.
        var normalized = new StringBuilder();
        for (int i = 0; i < encoded.length; i++) {
            if (!encoded[i].isspace()) normalized.append_c(encoded[i]);
        }
        uint8[] decoded = Base64.decode(normalized.str);
        if (Base64.encode(decoded) != normalized.str) return null;
        data = new Bytes.take((owned) decoded);
    } else {
        try {
            data = Uri.unescape_bytes(payload);
        } catch (UriError e) {
            return null;
        }
    }
    media_type = decoded_metadata;
    return data;
}

// Split before unescaping: an escaped semicolon belongs to a parameter value,
// not to the MIME metadata structure. Use quoted MIME values where necessary.
internal string? decode_data_uri_media_type(string metadata) {
    if (metadata == "") return "text/plain;charset=US-ASCII";
    string[] fields = metadata.split(";");
    string? type = Uri.unescape_string(fields[0]);
    if (type == null) return null;
    if (type == "") type = "text/plain";
    string[] mime_parts = type.split("/");
    if (mime_parts.length != 2 || !is_mime_token(mime_parts[0]) || !is_mime_token(mime_parts[1])) return null;
    var result = new StringBuilder(type);
    for (int i = 1; i < fields.length; i++) {
        int equals = fields[i].index_of_char('=');
        if (equals <= 0) return null;
        string? name = Uri.unescape_string(fields[i].substring(0, equals));
        string? value = Uri.unescape_string(fields[i].substring(equals + 1));
        if (name == null || value == null || !is_mime_token(name) || !value.validate()) return null;
        for (int j = 0; j < value.length; j++) {
            if ((value[j] >= 0 && value[j] < ' ' && value[j] != '\t') || value[j] == 127) return null;
        }
        result.append(";").append(name).append("=");
        if (is_mime_token(value)) {
            result.append(value);
        } else {
            result.append("\"").append(value.replace("\\", "\\\\").replace("\"", "\\\"")).append("\"");
        }
    }
    return result.str;
}

internal string? encode_data_uri_media_type(string media_type) {
    if (!media_type.validate()) return null;
    var result = new StringBuilder();
    bool quoted = false;
    bool escaped = false;
    for (int i = 0; i < media_type.length; i++) {
        char c = media_type[i];
        if (quoted && !escaped && c == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped && c == '"') {
            quoted = !quoted;
            continue;
        }
        result.append(Uri.escape_string(media_type.substring(i, 1), quoted || escaped ? null : "/;=", false));
        escaped = false;
    }
    if (quoted || escaped || media_type == "" || decode_data_uri_media_type(result.str) == null) return null;
    return result.str;
}

private bool is_mime_token(string value) {
    if (value == "") return false;
    for (int i = 0; i < value.length; i++) {
        char c = value[i];
        if (c <= ' ' || c >= 127 || "()<>@,;:\\\"/[]?=".index_of_char(c) >= 0) return false;
    }
    return true;
}

public abstract class StanzaListener<T> : OrderedListener {

    public abstract async bool run(XmppStream stream, T stanza);
}

public class StanzaListenerHolder<T> : ListenerHolder {

    public async bool run(XmppStream stream, T stanza) {

        // listeners can change e.g. when switching to another stream
        ArrayList<OrderedListener> listeners_copy = new ArrayList<OrderedListener>();
        listeners_copy.add_all(listeners);

        foreach (OrderedListener ol in listeners_copy) {
            StanzaListener<T> l = ol as StanzaListener<T>;
            bool stop = yield l.run(stream, stanza);
            if (stop) return true;
        }
        return false;
    }
}

public abstract class OrderedListener : Object {
    public abstract string action_group { get; }
    public abstract string[] after_actions { get; }
}

public abstract class ListenerHolder : Object {
    protected ArrayList<OrderedListener> listeners = new ArrayList<OrderedListener>();

    public new void connect(OrderedListener listener) {
        listeners.add(listener);
        resort_list();
    }

    public new void disconnect(OrderedListener listener) {
        listeners.remove(listener);
        resort_list();
    }

    private bool set_contains_action(Gee.List<OrderedListener> s, string[] actions) {
        foreach(OrderedListener l in s) {
            if (l.action_group in actions) {
                return true;
            }
        }
        return false;
    }

    private void resort_list() {
        ArrayList<OrderedListener> new_list = new ArrayList<OrderedListener>();
        ArrayList<OrderedListener> remaining = new ArrayList<OrderedListener>();
        remaining.add_all(listeners);
        while (remaining.size > 0) {
            bool changed = false;
            Gee.Iterator<OrderedListener> iter = remaining.iterator();
            while (iter.has_next()) {
                iter.next();
                OrderedListener l = iter.get();
                if (!set_contains_action(remaining, l.after_actions)) {
                    new_list.add(l);
                    iter.remove();
                    changed = true;
                }
            }
            if (!changed) error("Can't sort listeners");
        }
        listeners = new_list;
    }
}

}
