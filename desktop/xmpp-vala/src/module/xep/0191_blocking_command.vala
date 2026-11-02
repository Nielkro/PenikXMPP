using Gee;

namespace Xmpp.Xep.BlockingCommand {

private const string NS_URI = "urn:xmpp:blocking";

public class Module : XmppStreamModule, Iq.Handler {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0191_blocking_command");

    public signal void block_push_received(XmppStream stream, Gee.List<string> jids);
    public signal void unblock_push_received(XmppStream stream, Gee.List<string> jids);
    public signal void unblock_all_received(XmppStream stream);

    public bool is_blocked(XmppStream stream, string jid) {
        if (is_supported(stream)) {
            return stream.get_flag(Flag.IDENTITY).blocklist.contains(jid);
        } else {
            return false;
        }
    }

    public async bool block_checked(XmppStream stream, string[] jids) throws GLib.Error {
        if (jids.length == 0) {
            throw new IOError.INVALID_ARGUMENT("A blocking command requires at least one JID");
        }
        if (!stream.has_flag(Flag.IDENTITY)) {
            throw new IOError.NOT_SUPPORTED("The server does not support blocking commands");
        }

        StanzaNode block_node = new StanzaNode.build("block", NS_URI).add_self_xmlns();
        fill_node_with_items(block_node, jids);
        Iq.Stanza iq = new Iq.Stanza.set(block_node);
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        throw_if_unexpected_server_iq_sender(stream, result, "block JID");
        throw_if_iq_error(result, "block JID");

        bool changed = false;
        Flag flag = stream.get_flag(Flag.IDENTITY);
        foreach (string jid in jids) {
            if (!flag.blocklist.contains(jid)) {
                flag.blocklist.add(jid);
                changed = true;
            }
        }
        return changed;
    }

    public async bool unblock_checked(XmppStream stream, string[] jids) throws GLib.Error {
        if (jids.length == 0) {
            throw new IOError.INVALID_ARGUMENT("An empty unblock command would unblock every JID");
        }
        if (!stream.has_flag(Flag.IDENTITY)) {
            throw new IOError.NOT_SUPPORTED("The server does not support blocking commands");
        }

        StanzaNode unblock_node = new StanzaNode.build("unblock", NS_URI).add_self_xmlns();
        fill_node_with_items(unblock_node, jids);
        Iq.Stanza iq = new Iq.Stanza.set(unblock_node);
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        throw_if_unexpected_server_iq_sender(stream, result, "unblock JID");
        throw_if_iq_error(result, "unblock JID");

        bool changed = false;
        Flag flag = stream.get_flag(Flag.IDENTITY);
        foreach (string jid in jids) {
            if (flag.blocklist.remove(jid)) changed = true;
        }
        return changed;
    }

    public bool block(XmppStream stream, string[] jids) {
        if (jids.length == 0) return false;
        block_checked.begin(stream, jids, (_, res) => {
            try {
                block_checked.end(res);
            } catch (GLib.Error e) {
                warning("Failed to block JID: %s", e.message);
            }
        });
        return true;
    }

    public bool unblock(XmppStream stream, string[] jids) {
        if (jids.length == 0) return false;
        unblock_checked.begin(stream, jids, (_, res) => {
            try {
                unblock_checked.end(res);
            } catch (GLib.Error e) {
                warning("Failed to unblock JID: %s", e.message);
            }
        });
        return true;
    }

    public void unblock_all(XmppStream stream) {
        StanzaNode unblock_node = new StanzaNode.build("unblock", NS_URI).add_self_xmlns();
        Iq.Stanza iq = new Iq.Stanza.set(unblock_node);
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq(stream, iq, null);
    }

    public bool is_supported(XmppStream stream) {
        return stream.has_flag(Flag.IDENTITY);
    }

    private async void on_iq_set(XmppStream stream, Iq.Stanza iq) {
        // Block/unblock pushes MUST come from the user's own bare JID (server)
        Jid? my_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        if (my_jid != null && iq.from != null && !iq.from.equals_bare(my_jid)) {
            return;
        }
        StanzaNode? block_node = iq.stanza.get_subnode("block", NS_URI);
        StanzaNode? unblock_node = iq.stanza.get_subnode("unblock", NS_URI);
        Gee.List<string> jids;
        if (block_node != null) {
            jids = get_jids_from_items(block_node);
            Gee.List<string> changed_jids = new ArrayList<string>();
            foreach (string jid in jids) {
                if (!stream.get_flag(Flag.IDENTITY).blocklist.contains(jid)) {
                    stream.get_flag(Flag.IDENTITY).blocklist.add(jid);
                    changed_jids.add(jid);
                }
            }
            if (changed_jids.size > 0) block_push_received(stream, changed_jids);
        } else if (unblock_node != null) {
            jids = get_jids_from_items(unblock_node);
            if (jids.size > 0) {
                Gee.List<string> changed_jids = new ArrayList<string>();
                foreach (string jid in jids) {
                    if (stream.get_flag(Flag.IDENTITY).blocklist.remove(jid)) {
                        changed_jids.add(jid);
                    }
                }
                if (changed_jids.size > 0) unblock_push_received(stream, changed_jids);
            } else {
                if (stream.get_flag(Flag.IDENTITY).blocklist.size > 0) {
                    stream.get_flag(Flag.IDENTITY).blocklist.clear();
                    unblock_all_received(stream);
                }
            }
        }
    }

    public override void attach(XmppStream stream) {
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).register_for_namespace(NS_URI, this);
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
        stream.stream_negotiated.connect(on_stream_negotiated);
    }

    public override void detach(XmppStream stream) {
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).unregister_from_namespace(NS_URI, this);
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
        stream.stream_negotiated.disconnect(on_stream_negotiated);
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    private void on_stream_negotiated(XmppStream stream) {
        query_blocking_support.begin(stream, (_, res) => {
            query_blocking_support.end(res);
        });
    }

    private async void query_blocking_support(XmppStream stream) {
        bool has_feature = yield stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).has_entity_feature(stream, stream.remote_name, NS_URI);
        if (has_feature) {
            stream.add_flag(new Flag());
            stream.get_flag(Flag.IDENTITY).blocklist = yield get_blocklist(stream);
        }
    }

    private async Gee.List<string> get_blocklist(XmppStream stream) {
        StanzaNode blocklist_node = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        Iq.Stanza iq = new Iq.Stanza.get(blocklist_node);

        Iq.Stanza result_iq;
        try {
            result_iq = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        } catch (IOError.CANCELLED e) {
            debug("Blocklist request cancelled: %s", e.message);
            return new ArrayList<string>();
        } catch (GLib.Error e) {
            warning("Failed to get blocklist: %s", e.message);
            return new ArrayList<string>();
        }
        StanzaNode? node = result_iq.stanza.get_subnode("blocklist", NS_URI);
        if (node != null) {
            return get_jids_from_items(node);
        }
        return new ArrayList<string>();
    }

    private Gee.List<string> get_jids_from_items(StanzaNode node) {
        Gee.List<StanzaNode> item_nodes = node.get_subnodes("item", NS_URI);
        Gee.List<string> jids = new ArrayList<string>();
        foreach (StanzaNode item_node in item_nodes) {
            string? jid = item_node.get_attribute("jid", NS_URI);
            if (jid != null && jid.length > 0) {
                jids.add(jid);
            }
        }
        return jids;
    }

    private void fill_node_with_items(StanzaNode node, string[] jids) {
        foreach (string jid in jids) {
            StanzaNode item_node = new StanzaNode.build("item", NS_URI).add_self_xmlns();
            item_node.set_attribute("jid", jid, NS_URI);
            node.put_node(item_node);
        }
    }

    private static void throw_if_iq_error(Iq.Stanza result,
            string context) throws GLib.Error {
        if (!result.is_error()) return;

        ErrorStanza? stanza_error = result.get_error();
        string detail = "unknown stanza error";
        if (stanza_error != null) {
            detail = ((!) stanza_error).condition;
            if (((!) stanza_error).text != null && ((!) stanza_error).text != "") {
                detail += ": " + ((!) stanza_error).text;
            }
        }
        throw new IOError.FAILED("Server rejected %s: %s".printf(context, detail));
    }

    private static void throw_if_unexpected_server_iq_sender(XmppStream stream,
            Iq.Stanza result, string context) throws GLib.Error {
        string? from = result.stanza.get_attribute("from");
        // XEP-0191 commands have no 'to' address. RFC 6120 permits the
        // account server's response to omit 'from'; an explicit sender must
        // therefore be the user's own bare JID.
        if (from == null) return;

        Bind.Flag? bind_flag = stream.get_flag(Bind.Flag.IDENTITY);
        if (bind_flag == null || ((!) bind_flag).my_jid == null) {
            throw new IOError.FAILED(
                "Cannot validate %s response without a bound account JID".printf(context));
        }
        try {
            Jid sender = new Jid((!) from);
            if (!sender.equals(((!) ((!) bind_flag).my_jid).bare_jid)) {
                throw new IOError.FAILED(
                    "Ignoring %s response from unexpected JID %s".printf(
                        context, sender.to_string()));
            }
        } catch (InvalidJidError e) {
            throw new IOError.FAILED(
                "Ignoring %s response with invalid sender JID".printf(context));
        }
    }
}

public class Flag : XmppStreamFlag {
    public static FlagIdentity<Flag> IDENTITY = new FlagIdentity<Flag>(NS_URI, "blocking_command");

    public Gee.List<string> blocklist = new ArrayList<string>();

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

}
