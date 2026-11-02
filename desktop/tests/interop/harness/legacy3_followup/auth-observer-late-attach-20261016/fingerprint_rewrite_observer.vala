// IQ metadata only. This observer never decrypts, writes, rejects or edits IQs.
using Gee;
using Xmpp;

namespace LocalInterop {

class FingerprintShape : Object {
    internal int wrapped = 0;
    internal int plain = 0;
    internal int sender_device = 0;
    internal bool unambiguous = true;
    internal string signature = "";
    internal Json.Array contents = new Json.Array();

    internal FingerprintShape(StanzaNode jingle) {
        var seen = new HashSet<string>();
        var signature_builder = new StringBuilder();
        foreach (StanzaNode content in jingle.get_subnodes("content", Xep.Jingle.NS_URI)) {
            string name = content.get_attribute("name") ?? "";
            string creator = content.get_attribute("creator") ?? "";
            if (!FingerprintRewriteObserver.token(name) || !seen.add(name) || seen.size > 16) unambiguous = false;
            var transports = content.get_subnodes("transport", Xep.JingleIceUdp.NS_URI);
            int w = 0, p = 0, header_count = 0, key_count = 0;
            signature_builder.append_printf("%d:%s|%d:%s|%d|", name.length, name, creator.length, creator, transports.size);
            foreach (StanzaNode transport in transports) {
                foreach (StanzaNode node in transport.sub_nodes) {
                    if (node.name != "fingerprint") continue;
                    if (node.ns_uri != ObserverScope.DRAFT && node.ns_uri != Xep.JingleIceUdp.DTLS_NS_URI) {
                        unambiguous = false; continue;
                    }
                    string hash = node.get_attribute("hash") ?? "";
                    string setup = node.get_attribute("setup") ?? "";
                    signature_builder.append_printf("%d:%s|%d:%s|", hash.length, hash, setup.length, setup);
                    if (node.ns_uri == Xep.JingleIceUdp.DTLS_NS_URI) { p++; continue; }
                    w++;
                    var encrypted = node.get_subnodes("encrypted", ObserverScope.LEGACY);
                    if (encrypted.size != 1) { unambiguous = false; continue; }
                    var headers = encrypted[0].get_subnodes("header", ObserverScope.LEGACY);
                    header_count += headers.size;
                    if (headers.size != 1) { unambiguous = false; continue; }
                    int device = ObserverScope.device_number(headers[0].get_attribute("sid"));
                    if (device <= 0 || sender_device != 0 && sender_device != device) unambiguous = false;
                    if (sender_device == 0) sender_device = device;
                    // Counts only: never read/log key, iv, payload, ciphertext or FP body.
                    key_count += headers[0].get_subnodes("key", ObserverScope.LEGACY).size;
                }
                signature_builder.append(";");
            }
            wrapped += w; plain += p;
            signature_builder.append_printf("fp=%d;", w + p);
            var row = new Json.Object(); row.set_string_member("name", name); row.set_string_member("creator", creator);
            row.set_int_member("ice_transports", transports.size);
            row.set_int_member("draft_fingerprints", w); row.set_int_member("normal_dtls_fingerprints", p);
            row.set_int_member("omemo_headers", header_count); row.set_int_member("encrypted_key_nodes", key_count);
            contents.add_object_element(row);
        }
        signature = signature_builder.str;
        if (contents.get_length() == 0) unambiguous = false;
    }
}

// Only copied scalars/JSON metadata; never retain mutable XML/StanzaNode references.
class PendingFingerprintObservation : Object {
    internal string key;
    internal string shape;
    internal string sid;
    internal string peer;
    internal int device;
    internal int fingerprints;
    internal uint generation;
    internal int64 started_us;
    internal string? before_peer_public;
    internal string? before_own_public;
    internal int64 before_own_device;
    internal PendingFingerprintObservation(string key, string shape, string sid, string peer,
            int device, int count, uint generation, Json.Object? public_before, Json.Object? own_before) {
        this.key = key; this.shape = shape; this.sid = sid; this.peer = peer;
        this.device = device; this.fingerprints = count; this.generation = generation;
        started_us = get_monotonic_time();
        if (public_before != null) {
            before_peer_public = public_before.get_string_member("peer_public_identity_hex");
        }
        if (own_before != null) {
            before_own_public = own_before.get_string_member("own_public_identity_hex");
            before_own_device = own_before.get_int_member("own_device_id");
        }
    }
}

class FingerprintRewriteObserver : Object, Iq.IncomingRequestFilter {
    private weak ObserverScope scope;
    private ulong preprocess_handler;
    private HashMap<string, PendingFingerprintObservation> pending = new HashMap<string, PendingFingerprintObservation>();
    private HashSet<string> collisions = new HashSet<string>();
    public FingerprintRewriteObserver(ObserverScope scope) { this.scope = scope; }

    public void attach(XmppStream stream) {
        var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
        preprocess_handler = iq.preprocess_incoming_iq_set_get.connect(before_filters);
        iq.add_incoming_request_filter(this); // negotiated/resumed: real draft attached already.
    }

    public void detach(XmppStream stream) {
        var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
        if (iq != null) {
            if (preprocess_handler != 0) SignalHandler.disconnect(iq, preprocess_handler);
            iq.remove_incoming_request_filter(this);
        }
        preprocess_handler = 0; pending.clear(); collisions.clear();
    }

    internal static bool token(string? value) {
        if (value == null || value.length == 0 || value.length > 256) return false;
        for (int i = 0; i < value.length; i++) if (value[i] < 0x20 || value[i] == 0x7f) return false;
        return true;
    }

    private void expire() {
        var stale = new ArrayList<string>();
        foreach (var item in pending.entries)
            if (get_monotonic_time() - item.value.started_us > 30 * 1000000L) stale.add(item.key);
        foreach (string key in stale) pending.unset(key);
    }

    private Json.Object? envelope(XmppStream stream, Iq.Stanza iq, out StanzaNode? jingle, out string? key) {
        jingle = null; key = null;
        if (!scope.current(stream) || iq.type_ != Iq.Stanza.TYPE_SET || iq.from == null ||
                !scope.peer_allowed(iq.from) || !scope.local_recipient(iq.to) || !token(iq.id)) return null;
        var nodes = iq.stanza.get_subnodes("jingle", Xep.Jingle.NS_URI);
        if (nodes.size != 1) return null;
        jingle = nodes[0];
        string? sid = jingle.get_attribute("sid"), action = jingle.get_attribute("action");
        if (!token(sid) || !token(action) || action == "session-terminate") return null;
        var muji = jingle.get_subnodes("muji", Xep.Muji.NS_URI);
        if (muji.size > 1) return null;
        string? room_text = muji.size == 1 ? muji[0].get_attribute("room") : null;
        Jid? room = null;
        try {
            if (room_text != null) {
                room = new Jid((!) room_text);
                if (room.resourcepart != null || !scope.driver.observer_room_allowed(room)) return null;
            }
        } catch (InvalidJidError e) { return null; }
        if (!scope.driver.observer_call_allowed(iq.from, (!) sid, room)) return null;
        var row = new Json.Object();
        row.set_string_member("iq_id", iq.id); row.set_string_member("sid", (!) sid);
        row.set_string_member("action", (!) action); row.set_string_member("from", iq.from.to_string());
        row.set_string_member("to", iq.to != null ? iq.to.to_string() : "");
        row.set_string_member("raw_to", iq.stanza.get_attribute("to") ?? "");
        row.set_string_member("room", room != null ? room.to_string() : "");
        row.set_int_member("stream_generation", scope.generation);
        var node = new Json.Node(Json.NodeType.OBJECT); node.set_object(row);
        var generator = new Json.Generator(); generator.set_root(node); key = generator.to_data(null);
        return row;
    }

    private void before_filters(XmppStream stream, Iq.Stanza iq) {
        try {
            expire(); StanzaNode? jingle; string? key;
            Json.Object? row = envelope(stream, iq, out jingle, out key);
            if (row == null || jingle == null || key == null) return;
            var shape = new FingerprintShape((!) jingle);
            if (shape.wrapped + shape.plain == 0) return;
            row.set_string_member("event", "incoming_fingerprint_metadata_BEFORE_FILTERS");
            row.set_array_member("contents", shape.contents);
            row.set_int_member("draft_fingerprint_count", shape.wrapped);
            row.set_int_member("normal_dtls_fingerprint_count", shape.plain);
            row.set_int_member("omemo_header_sender_device", shape.sender_device);
            row.set_boolean_member("unambiguous_metadata", shape.unambiguous);
            row.set_boolean_member("decryption_success_claimed", false);
            scope.emit(row);
            if (!scope.current(stream)) return;
            if (!shape.unambiguous || shape.wrapped <= 0 || shape.plain != 0 || shape.sender_device <= 0) return;
            if (pending.has_key((!) key)) { pending.unset((!) key); collisions.add((!) key); return; }
            if (pending.size >= 64 || collisions.size >= 64 || collisions.contains((!) key)) return;
            Json.Object? public_before = scope.public_binding(stream, iq.from, shape.sender_device);
            Json.Object? own_before = scope.own_public_binding(stream);
            pending[(!) key] = new PendingFingerprintObservation((!) key, shape.signature,
                row.get_string_member("sid"), iq.from.to_string(), shape.sender_device,
                shape.wrapped, scope.generation, public_before, own_before);
        } catch (Error e) { scope.note_unavailable("pre-filter public observation unavailable"); }
    }

    public void prepare_receive(XmppStream stream, Iq.Stanza iq) throws Error {
        // Always observational: errors are caught, no IQ mutation or security veto.
        try {
            expire(); StanzaNode? jingle; string? key;
            Json.Object? row = envelope(stream, iq, out jingle, out key);
            if (row == null || jingle == null || key == null) return;
            PendingFingerprintObservation? before = pending[(!) key];
            if (before == null) return;
            pending.unset((!) key);
            var after = new FingerprintShape((!) jingle);
            if (before.generation != scope.generation || before.peer != iq.from.to_string() ||
                    before.sid != jingle.get_attribute("sid") || !after.unambiguous ||
                    after.wrapped != 0 || after.plain != before.fingerprints ||
                    after.signature != before.shape || !scope.current(stream)) return;
            Json.Object? public_after = scope.public_binding(stream, iq.from, before.device);
            bool public_bound = public_after != null && before.before_own_public != null && before.before_own_device > 0;
            if (public_after != null && (public_after.get_boolean_member("peer_identity_changed") ||
                    (public_after.get_int_member("peer_trust") != (int) Dino.Plugins.Omemo.TrustLevel.TRUSTED &&
                     public_after.get_int_member("peer_trust") != (int) Dino.Plugins.Omemo.TrustLevel.VERIFIED))) public_bound = false;
            if (public_after != null && before.before_peer_public != null &&
                    public_after.get_string_member("peer_public_identity_hex") != before.before_peer_public) public_bound = false;
            if (public_after != null && before.before_own_public != null &&
                    (public_after.get_string_member("own_public_identity_hex") != before.before_own_public ||
                     public_after.get_int_member("own_device_id") != before.before_own_device)) public_bound = false;
            if (!scope.current(stream) || before.generation != scope.generation) return;
            row.set_string_member("event", "incoming_encrypted_DTLS_fingerprint_rewrite_succeeded");
            row.set_boolean_member("encrypted_to_normal_namespace_rewrite_observed", true);
            row.set_int_member("omemo_header_sender_device", before.device);
            row.set_int_member("rewritten_fingerprints", after.plain);
            row.set_array_member("contents_after", after.contents);
            row.set_boolean_member("public_identity_bound", public_bound);
            if (public_after != null) row.set_object_member("public_identity_observation", public_after);
            row.set_boolean_member("engine_DTLS_media_binding_proven_by_this_event", false);
            row.set_string_member("scope", "incoming real draft filter passed and rewrote exact scoped IQ; engine/SID/media audit remains separate");
            scope.emit(row);
        } catch (Error e) { scope.note_unavailable("post-filter public observation unavailable"); }
    }
}

}
