using Gee;

namespace Xmpp.Xep.MucAvatars {

public const string VCARD_NS_URI = "vcard-temp";
public const string ROOMINFO_FORM_TYPE =
    "http://jabber.org/protocol/muc#roominfo";
public const string AVATAR_HASH_FIELD = "muc#roominfo_avatarhash";

private const size_t MAX_ROOM_AVATAR_BYTES = 4 * 1024 * 1024;
private const int MAX_ROOM_AVATAR_BASE64_CHARS =
    ((int) MAX_ROOM_AVATAR_BYTES * 4 / 3) + 4096;
private const int MAX_ADVERTISED_HASH_VALUES = 16;
private const int MAX_ADVERTISED_HASHES = 8;
private const int MAX_ROOMINFO_FORMS = 8;
private const int MAX_ROOMINFO_FIELDS = 64;
private const int MAX_VCARD_PHOTOS = 8;
private const size_t MAX_TOTAL_DECODED_BYTES = 8 * 1024 * 1024;

/** Immutable XEP-0486 projection from one complete disco#info result. */
public class RoomAvatarInfo : Object {
    public bool roominfo_form_present { get; private set; }
    public bool hash_field_present { get; private set; }
    public bool hashes_valid { get; private set; }

    private string[] hashes_value;

    internal RoomAvatarInfo(bool roominfo_form_present,
            bool hash_field_present,
            bool hashes_valid, string[]? hashes = null) {
        this.roominfo_form_present = roominfo_form_present;
        this.hash_field_present = hash_field_present;
        this.hashes_valid = hashes_valid;
        this.hashes_value = copy_strings(hashes);
    }

    public int hash_count { get { return hashes_value.length; } }

    public string? hash_at(int index) {
        return index >= 0 && index < hashes_value.length
            ? hashes_value[index] : null;
    }

    public string[] dup_hashes() {
        return copy_strings(hashes_value);
    }

    private static string[] copy_strings(string[]? source) {
        if (source == null) return new string[0];
        string[] copy = new string[((!) source).length];
        for (int i = 0; i < copy.length; i++) copy[i] = ((!) source)[i];
        return copy;
    }
}

/** One hash-verified representation selected from a room vCard. */
public class FetchedRoomAvatar : Object {
    public string hash { get; private set; }
    public Bytes bytes { get; private set; }
    public string? media_type { get; private set; }

    internal FetchedRoomAvatar(string hash, Bytes bytes,
            string? media_type) {
        this.hash = hash;
        this.bytes = bytes;
        this.media_type = media_type;
    }
}

private class RoomAvatarDecodeJob : Object {
    public StanzaNode vcard { get; private set; }
    public RoomAvatarInfo info { get; private set; }
    public FetchedRoomAvatar? result { get; set; }

    public RoomAvatarDecodeJob(StanzaNode vcard, RoomAvatarInfo info) {
        this.vcard = vcard;
        this.info = info;
    }
}

/** Parse only the standardized roominfo form; unrelated data forms are ignored. */
public static RoomAvatarInfo parse_info_result(
        ServiceDiscovery.InfoResult info_result) {
    StanzaNode? query = info_result.iq.stanza.get_subnode("query",
        ServiceDiscovery.NS_URI_INFO);
    if (query == null) {
        return new RoomAvatarInfo(false, false, false);
    }

    int form_count = 0;
    foreach (StanzaNode form in ((!) query).sub_nodes) {
        if (form.name != "x" || form.ns_uri != DataForms.NS_URI) continue;
        form_count++;
        if (form_count > MAX_ROOMINFO_FORMS) {
            return new RoomAvatarInfo(false, false, false);
        }
        if (form.get_attribute("type") != "result" ||
                !is_roominfo_form(form)) continue;

        StanzaNode? hash_field = null;
        int field_count = 0;
        foreach (StanzaNode field in form.sub_nodes) {
            if (field.name != "field" ||
                    field.ns_uri != DataForms.NS_URI) continue;
            field_count++;
            if (field_count > MAX_ROOMINFO_FIELDS) {
                return new RoomAvatarInfo(true, true, false);
            }
            if (field.get_attribute("var") == AVATAR_HASH_FIELD) {
                if (hash_field != null) {
                    return new RoomAvatarInfo(true, true, false);
                }
                hash_field = field;
            }
        }
        if (hash_field == null) {
            return new RoomAvatarInfo(true, false, true);
        }

        var hashes = new ArrayList<string>();
        var unique_hashes = new HashSet<string>();
        bool valid = true;
        int value_count = 0;
        foreach (StanzaNode value in ((!) hash_field).sub_nodes) {
            if (value.name != "value" ||
                    value.ns_uri != DataForms.NS_URI) continue;
            value_count++;
            if (value_count > MAX_ADVERTISED_HASH_VALUES) {
                valid = false;
                break;
            }
            string? hash = normalize_sha1(value.get_string_content());
            if (hash == null) {
                valid = false;
                break;
            }
            if (unique_hashes.add((!) hash)) {
                if (hashes.size >= MAX_ADVERTISED_HASHES) {
                    valid = false;
                    break;
                }
                hashes.add((!) hash);
            }
        }
        if (hashes.is_empty) valid = false;
        return new RoomAvatarInfo(true, true, valid,
            valid ? hashes.to_array() : null);
    }

    return new RoomAvatarInfo(false, false, false);
}

public static bool service_supports_room_avatars(
        ServiceDiscovery.InfoResult info_result) {
    return info_result.features.contains(VCARD_NS_URI);
}

public static bool has_expected_sender(Iq.Stanza response, Jid expected) {
    string? from = response.stanza.get_attribute("from");
    if (from == null) return false;
    try {
        return new Jid((!) from).equals(expected.bare_jid);
    } catch (InvalidJidError error) {
        return false;
    }
}

/** A cancellable, low-priority disco request for background discovery. */
public static async ServiceDiscovery.InfoResult? request_info(
        XmppStream stream, Jid jid, Cancellable? cancellable = null)
        throws Error {
    Iq.Stanza request = new Iq.Stanza.get(new StanzaNode.build("query",
        ServiceDiscovery.NS_URI_INFO).add_self_xmlns()) { to = jid };
    Iq.Stanza response = yield stream.get_module<Iq.Module>(
        Iq.Module.IDENTITY).send_iq_async(stream, request, Priority.LOW,
            cancellable);
    if (!has_expected_sender(response, jid)) return null;
    return ServiceDiscovery.InfoResult.create_from_iq(response);
}

/**
 * Fetch all advertised vCard PHOTO representations in one IQ and select a
 * safe raster representation whose SHA-1 is present in roominfo.
 */
public static async FetchedRoomAvatar? fetch_advertised_avatar(
        XmppStream stream, Jid room, RoomAvatarInfo info,
        Cancellable? cancellable = null) throws Error {
    if (!info.roominfo_form_present || !info.hash_field_present ||
            !info.hashes_valid ||
            info.hash_count == 0) return null;

    Iq.Stanza request = new Iq.Stanza.get(new StanzaNode.build("vCard",
        VCARD_NS_URI).add_self_xmlns()) { to = room.bare_jid };
    Iq.Stanza response = yield stream.get_module<Iq.Module>(
        Iq.Module.IDENTITY).send_iq_async(stream, request, Priority.LOW,
            cancellable);
    if (response.is_error() || !has_expected_sender(response,
            room.bare_jid)) return null;

    StanzaNode? vcard = response.stanza.get_subnode("vCard",
        VCARD_NS_URI);
    if (vcard == null) return null;
    return yield select_advertised_avatar_async((!) vcard, info,
        cancellable);
}

/** Decode and hash bounded PHOTO payloads away from the caller's main loop. */
private static async FetchedRoomAvatar? select_advertised_avatar_async(
        StanzaNode vcard, RoomAvatarInfo info,
        Cancellable? cancellable = null) throws Error {
    SourceFunc callback = select_advertised_avatar_async.callback;
    var job = new RoomAvatarDecodeJob(vcard, info);
    var task = new GLib.Task(job, cancellable, (_, completed) => {
        callback();
    });
    task.set_priority(Priority.LOW);
    task.run_in_thread(room_avatar_decode_task);
    yield;
    task.propagate_boolean();
    return job.result;
}

private static void room_avatar_decode_task(GLib.Task task,
        Object source_object,
        void* task_data, Cancellable? cancellable) {
    if (task.return_error_if_cancelled()) return;
    RoomAvatarDecodeJob job = (RoomAvatarDecodeJob) source_object;
    job.result = select_advertised_avatar_internal(job.vcard, job.info,
        cancellable);
    if (task.return_error_if_cancelled()) return;
    task.return_boolean(true);
}

/** Pure parser used by the network path and protocol tests. */
public static FetchedRoomAvatar? select_advertised_avatar(
        StanzaNode vcard, RoomAvatarInfo info) {
    return select_advertised_avatar_internal(vcard, info, null);
}

private static FetchedRoomAvatar? select_advertised_avatar_internal(
        StanzaNode vcard, RoomAvatarInfo info, Cancellable? cancellable) {
    if (!info.hashes_valid || info.hash_count == 0) return null;

    var advertised = new HashSet<string>();
    foreach (string hash in info.dup_hashes()) advertised.add(hash);

    FetchedRoomAvatar? best = null;
    int best_priority = int.MAX;
    int photo_count = 0;
    size_t decoded_bytes = 0;
    foreach (StanzaNode photo in vcard.sub_nodes) {
        if (photo.name != "PHOTO" || photo.ns_uri != VCARD_NS_URI) continue;
        if (cancellable != null && ((!) cancellable).is_cancelled()) {
            return null;
        }
        photo_count++;
        if (photo_count > MAX_VCARD_PHOTOS) return null;
        string? media_type = photo.get_subnode("TYPE", VCARD_NS_URI)
            ?.get_string_content();
        int priority = media_type_priority(media_type);
        if (priority == int.MAX || priority >= best_priority) continue;

        string? encoded = photo.get_subnode("BINVAL", VCARD_NS_URI)
            ?.get_string_content();
        if (encoded == null) continue;
        if (((!) encoded).length > MAX_ROOM_AVATAR_BASE64_CHARS) continue;
        string clean = strip_base64_whitespace((!) encoded);
        if (clean == "" || clean.length > MAX_ROOM_AVATAR_BASE64_CHARS) {
            continue;
        }

        uint8[] decoded = Base64.decode(clean);
        if (cancellable != null && ((!) cancellable).is_cancelled()) {
            return null;
        }
        if (decoded.length == 0 ||
                ((size_t) decoded.length) > MAX_ROOM_AVATAR_BYTES) {
            continue;
        }
        decoded_bytes += (size_t) decoded.length;
        if (decoded_bytes > MAX_TOTAL_DECODED_BYTES) return null;
        Bytes bytes = new Bytes.take((owned) decoded);
        string hash = Checksum.compute_for_bytes(ChecksumType.SHA1, bytes);
        if (!advertised.contains(hash)) continue;

        best = new FetchedRoomAvatar(hash, bytes,
            normalize_media_type(media_type));
        best_priority = priority;
    }
    return best;
}

private static bool is_roominfo_form(StanzaNode form) {
    int field_count = 0;
    foreach (StanzaNode field in form.sub_nodes) {
        if (field.name != "field" || field.ns_uri != DataForms.NS_URI) {
            continue;
        }
        field_count++;
        if (field_count > MAX_ROOMINFO_FIELDS) return false;
        if (field.get_attribute("var") != "FORM_TYPE") continue;
        int value_count = 0;
        foreach (StanzaNode value in field.sub_nodes) {
            if (value.name != "value" ||
                    value.ns_uri != DataForms.NS_URI) continue;
            value_count++;
            if (value_count > 4) return false;
            if (value.get_string_content() == ROOMINFO_FORM_TYPE) return true;
        }
        return false;
    }
    return false;
}

private static string? normalize_sha1(string? value) {
    if (value == null) return null;
    string hash = ((!) value).strip().down();
    if (hash.length != 40) return null;
    for (int i = 0; i < hash.length; i++) {
        char c = hash[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return null;
        }
    }
    return hash;
}

private static string? normalize_media_type(string? value) {
    if (value == null) return null;
    string normalized = ((!) value).strip().down();
    return normalized != "" ? normalized : null;
}

private static int media_type_priority(string? value) {
    string? normalized = normalize_media_type(value);
    if (normalized == null) return int.MAX;
    switch ((!) normalized) {
        case "image/png": return 0;
        case "image/jpeg":
        case "image/jpg": return 1;
        case "image/gif": return 2;
        // SVG loading is deliberately excluded here. Some supported runtime
        // combinations do not provide a crash-safe SVG texture loader.
        default: return int.MAX;
    }
}

private static string strip_base64_whitespace(string value) {
    var clean = new StringBuilder();
    for (int i = 0; i < value.length; i++) {
        char c = value[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        clean.append_c(c);
    }
    return clean.str;
}

}
