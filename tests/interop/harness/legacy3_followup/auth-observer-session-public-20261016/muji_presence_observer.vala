// Only scoped MUJI presence XML; no all-stanza/debug dump.
using Gee;
using Xmpp;

namespace LocalInterop {

class MujiPresenceObserver : Object {
    private const string MUC_USER = "http://jabber.org/protocol/muc#user";
    private const string XMLNS = "http://www.w3.org/2000/xmlns/";
    private const string XML = "http://www.w3.org/XML/1998/namespace";
    private weak ObserverScope scope;
    private ulong incoming_handler;
    private ulong outgoing_handler;
    public MujiPresenceObserver(ObserverScope scope) { this.scope = scope; }

    public void attach(XmppStream stream) {
        // received_node is emitted before the typed presence pipeline (core:152/169).
        incoming_handler = stream.received_node.connect(on_incoming);
        outgoing_handler = stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
            .pre_send_presence_stanza.connect_after((s, p) => { observe(s, p.stanza, false); });
    }

    public void detach(XmppStream stream) {
        if (incoming_handler != 0) SignalHandler.disconnect(stream, incoming_handler);
        var module = stream.get_module<Presence.Module>(Presence.Module.IDENTITY);
        if (module != null && outgoing_handler != 0) SignalHandler.disconnect(module, outgoing_handler);
        incoming_handler = outgoing_handler = 0;
    }

    private void on_incoming(XmppStream stream, StanzaNode node) {
        if (node.name == "presence" && node.ns_uri == "jabber:client") observe(stream, node, true);
    }

    private static bool no_sensitive_nodes(StanzaNode node, ref int nodes_left, ref int bytes_left, int depth = 0) {
        if (--nodes_left < 0 || depth > 12 || node.sub_nodes.size > 128 || node.attributes.size > 64) return false;
        bytes_left -= node.name.length + (node.ns_uri ?? "").length + (node.val ?? "").length;
        foreach (StanzaAttribute attr in node.attributes)
            bytes_left -= attr.name.length + (attr.ns_uri ?? "").length + (attr.val ?? "").length;
        if (bytes_left < 0) return false;
        foreach (string name in new string[] {"encrypted", "key", "iv", "payload", "private", "secret", "body", "auth", "password"})
            if (node.name == name) return false;
        foreach (StanzaNode child in node.sub_nodes)
            if (!no_sensitive_nodes(child, ref nodes_left, ref bytes_left, depth + 1)) return false;
        return true;
    }

    // XML serialization needs self-contained namespaces. Clone only private nodes;
    // never add declarations to the live received/prewrite presence.
    private static StanzaNode detached_xml_copy(StanzaNode original) {
        if (original.name == "#text") return new StanzaNode.text(original.val ?? "");
        var copy = new StanzaNode.build(original.name, original.ns_uri ?? "").add_self_xmlns();
        var reserved = new HashSet<string>();
        foreach (StanzaAttribute attr in original.attributes)
            if (attr.ns_uri == XMLNS) reserved.add(attr.name);
        var extra_namespaces = new HashSet<string>();
        int prefix = 0;
        foreach (StanzaAttribute attr in original.attributes) {
            if (attr.val == null || attr.ns_uri == XMLNS && attr.name == "xmlns") continue;
            string ns = attr.ns_uri ?? original.ns_uri ?? "";
            copy.attributes.add(new StanzaAttribute.build(ns, attr.name, (!) attr.val));
            if (ns != XMLNS && ns != XML && ns != copy.ns_uri && extra_namespaces.add(ns)) {
                string name = "";
                do { name = "observer_ns_" + (prefix++).to_string(); } while (reserved.contains(name));
                reserved.add(name);
                copy.attributes.add(new StanzaAttribute.build(XMLNS, name, ns));
            }
        }
        foreach (StanzaNode child in original.sub_nodes) copy.put_node(detached_xml_copy(child));
        copy.has_nodes = copy.sub_nodes.size > 0;
        return copy;
    }

    private void observe(XmppStream stream, StanzaNode node, bool incoming) {
        if (!scope.current(stream) || node.name != "presence") return;
        try {
            string? route = node.get_attribute(incoming ? "from" : "to");
            if (route == null || route.length > 512) return;
            Jid occupant = new Jid((!) route);
            if (occupant.resourcepart == null || !scope.driver.observer_room_allowed(occupant.bare_jid)) return;
            Jid real_peer;
            if (incoming) {
                var x = node.get_subnodes("x", MUC_USER);
                if (x.size != 1) return;
                var items = x[0].get_subnodes("item", MUC_USER);
                if (items.size != 1) return;
                string? real = items[0].get_attribute("jid");
                if (real == null || real.length > 512) return;
                real_peer = new Jid((!) real);
                if (!scope.peer_allowed(real_peer, true)) return;
            } else {
                real_peer = new Jid(scope.local_full);
                string? raw_from = node.get_attribute("from");
                if (!scope.local_recipient(raw_from != null ? new Jid((!) raw_from) : null)) return;
            }
            var nodes = node.get_subnodes("muji", Xep.Muji.NS_URI);
            if (nodes.size == 0 && node.get_attribute("type") != "unavailable") return;
            var row = new Json.Object();
            row.set_string_member("event", incoming ? "incoming_muji_presence_before_pipeline" : "outgoing_muji_presence_PREWRITE_ONLY");
            row.set_boolean_member("wire_send_claimed", false);
            row.set_string_member("room", occupant.bare_jid.to_string());
            row.set_string_member("occupant_full_jid", occupant.to_string());
            row.set_string_member("real_peer_full_jid", real_peer.to_string());
            row.set_string_member("raw_from", node.get_attribute("from") ?? "");
            row.set_string_member("raw_to", node.get_attribute("to") ?? "");
            row.set_string_member("presence_id", node.get_attribute("id") ?? "");
            row.set_string_member("presence_type", node.get_attribute("type") ?? "available");
            row.set_boolean_member("self_echo", incoming && real_peer.to_string() == scope.local_full);
            row.set_int_member("muji_nodes", nodes.size);
            var evidence = new Json.Array();
            foreach (StanzaNode muji in nodes) {
                if (evidence.get_length() >= 4) break;
                var item = new Json.Object();
                item.set_string_member("namespace", muji.ns_uri ?? "");
                item.set_string_member("attribute_device_raw", muji.get_attribute("device") ?? "");
                item.set_string_member("generation", muji.get_attribute("generation") ?? "");
                item.set_string_member("id", muji.get_attribute("id") ?? "");
                item.set_int_member("preparing_count", muji.get_subnodes("preparing", Xep.Muji.NS_URI).size);
                item.set_int_member("content_count", muji.get_subnodes("content", Xep.Muji.NS_URI).size);
                var ids = new Json.Array();
                foreach (StanzaNode device in muji.get_subnodes("device", ObserverScope.DRAFT))
                    if (ids.get_length() < 8) ids.add_string_element(device.get_attribute("id") ?? "");
                item.set_array_member("nested_draft_device_ids_raw", ids);
                int nodes_left = 256, bytes_left = 4096;
                if (no_sensitive_nodes(muji, ref nodes_left, ref bytes_left)) {
                    string xml = detached_xml_copy(muji).to_xml();
                    if (xml.length <= 4096) item.set_string_member("serialized_muji_xml", xml);
                    else item.set_string_member("xml_unavailable", "MUJI subtree exceeds 4096 bytes");
                } else item.set_string_member("xml_unavailable", "sensitive or excessive subtree omitted");
                evidence.add_object_element(item);
            }
            row.set_array_member("muji", evidence);
            if (incoming) {
                var x = node.get_subnode("x", MUC_USER);
                var item = x.get_subnode("item", MUC_USER);
                row.set_string_member("affiliation", item.get_attribute("affiliation") ?? "");
                row.set_string_member("role", item.get_attribute("role") ?? "");
                bool self_status = false;
                foreach (StanzaNode status in x.get_subnodes("status", MUC_USER))
                    if (status.get_attribute("code") == "110") self_status = true;
                row.set_boolean_member("status_110", self_status);
            }
            scope.emit(row);
        } catch (Error e) { scope.note_unavailable("scoped presence observation unavailable"); }
    }
}

}
