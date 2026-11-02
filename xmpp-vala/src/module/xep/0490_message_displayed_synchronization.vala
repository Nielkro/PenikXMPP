using Gee;

namespace Xmpp.Xep.MessageDisplayedSynchronization {

public const string NS_URI = "urn:xmpp:mds:displayed:0";
public const string PUBLISH_OPTIONS_FEATURE =
    Pubsub.NS_URI + "#publish-options";
public const string SERVER_ASSIST_FEATURE =
    "urn:xmpp:mds:server-assist:0";

public class DisplayedItem : Object {
    public Jid chat { get; private set; }
    public string stanza_id { get; private set; }
    public Jid by { get; private set; }

    public DisplayedItem(Jid chat, string stanza_id, Jid by) {
        this.chat = chat;
        this.stanza_id = stanza_id;
        this.by = by;
    }
}

public class FetchResult : Object {
    public bool ok { get; private set; }
    public Gee.List<DisplayedItem> items { get; private set; }
    public string? error_condition { get; private set; }

    public FetchResult(bool ok, Gee.List<DisplayedItem> items,
            string? error_condition = null) {
        this.ok = ok;
        this.items = items;
        this.error_condition = error_condition;
    }
}

public class PublishResult : Object {
    public bool ok { get; private set; }
    public bool unsupported { get; private set; }
    public bool ambiguous { get; private set; }
    public string? error_condition { get; private set; }

    public PublishResult(bool ok, bool unsupported = false,
            bool ambiguous = false, string? error_condition = null) {
        this.ok = ok;
        this.unsupported = unsupported;
        this.ambiguous = ambiguous;
        this.error_condition = error_condition;
    }
}

/** XEP-0490 wire format and PEP transport.
 *
 * Chat classification, forward-only ordering, and local read state belong to
 * libdino. Keeping those decisions out of this module makes the XMPP layer
 * reusable and prevents PubSub from acquiring protocol-specific policy.
 */
public class Module : XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY =
        new ModuleIdentity<Module>(NS_URI, "0490_message_displayed_sync");

    public signal void displayed_received(XmppStream stream,
        DisplayedItem item);

    public override void attach(XmppStream stream) {
        stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY)
            .add_filtered_raw_notification(stream, NS_URI, on_pubsub_item);
    }

    public override void detach(XmppStream stream) {
        stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY)
            .remove_filtered_notification(stream, NS_URI);
    }

    private void on_pubsub_item(XmppStream stream, Jid sender,
            StanzaNode item_node) {
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        if (bind == null ||
                !is_trusted_pep_sender((!) bind.my_jid.bare_jid, sender)) {
            return;
        }

        DisplayedItem? item = parse_item(item_node);
        if (item != null) displayed_received(stream, (!) item);
    }

    /**
     * MDS is private account state. A notification from another bare JID is
     * never authoritative, even though generic PubSub also supports services
     * and other publishers.
     */
    public static bool is_trusted_pep_sender(Jid own_bare_jid, Jid sender) {
        return own_bare_jid.is_bare() && sender.is_bare() &&
            sender.equals(own_bare_jid);
    }

    public static DisplayedItem? parse_item(StanzaNode item) {
        if (item.name != "item" ||
                (item.ns_uri != Pubsub.NS_URI &&
                    item.ns_uri != Pubsub.NS_URI_EVENT) ||
                item.sub_nodes.size != 1) {
            return null;
        }
        return parse_payload(item.get_attribute("id"), item.sub_nodes[0]);
    }

    public static DisplayedItem? parse_payload(string? item_id,
            StanzaNode payload) {
        if (item_id == null || payload.name != "displayed" ||
                payload.ns_uri != NS_URI || payload.sub_nodes.size != 1) {
            return null;
        }

        StanzaNode stanza_id_node = payload.sub_nodes[0];
        if (stanza_id_node.name != "stanza-id" ||
                stanza_id_node.ns_uri != UniqueStableStanzaIDs.NS_URI ||
                !stanza_id_node.sub_nodes.is_empty) {
            return null;
        }

        string? id = stanza_id_node.get_attribute("id");
        string? by_string = stanza_id_node.get_attribute("by");
        if (id == null || ((!) id).strip().length == 0 ||
                by_string == null) {
            return null;
        }

        try {
            Jid chat = new Jid((!) item_id);
            Jid by = new Jid((!) by_string);
            // The shared JID parser intentionally runs in compatibility mode.
            // PEP item ids are wire input, so reject unsafe raw characters in
            // the local/domain address while still allowing spaces in a MUC
            // nick resource.
            if (has_unsafe_address_character(chat.domainpart) ||
                    (chat.localpart != null &&
                        has_unsafe_address_character((!) chat.localpart)) ||
                    !by.is_bare() ||
                    has_unsafe_address_character(by.domainpart) ||
                    (by.localpart != null &&
                        has_unsafe_address_character((!) by.localpart))) {
                return null;
            }
            return new DisplayedItem(chat, (!) id, by);
        } catch (InvalidJidError error) {
            return null;
        }
    }

    public static StanzaNode? build_payload(string stanza_id, Jid by) {
        if (stanza_id.strip().length == 0 || !by.is_bare()) return null;

        return new StanzaNode.build("displayed", NS_URI).add_self_xmlns()
            .put_node(new StanzaNode.build("stanza-id",
                    UniqueStableStanzaIDs.NS_URI).add_self_xmlns()
                .put_attribute("id", stanza_id)
                .put_attribute("by", by.to_string()));
    }

    /**
     * Build the single stanza permitted by XEP-0490 server assist: an
     * otherwise non-empty XEP-0333 displayed marker plus the server-visible
     * MDS payload. Full-JID item IDs intentionally stay on regular PubSub.
     */
    public static MessageStanza? build_server_assisted_message(Jid chat,
            string marker_id, string message_type, string stanza_id,
            Jid by) {
        if (!chat.is_bare() ||
                (message_type != MessageStanza.TYPE_CHAT &&
                    message_type != MessageStanza.TYPE_GROUPCHAT)) {
            return null;
        }

        StanzaNode? marker = ChatMarkers.Module.build_displayed_node(
            marker_id);
        StanzaNode? payload = build_payload(stanza_id, by);
        if (marker == null || payload == null) return null;

        var message = new MessageStanza();
        message.to = chat;
        message.type_ = message_type;
        message.stanza.put_node((!) marker);
        message.stanza.put_node((!) payload);
        return message;
    }

    public async bool supports_server_assist(XmppStream stream) {
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        if (bind == null) return false;

        ServiceDiscovery.Module? discovery = stream.get_module<
            ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY);
        if (discovery == null) return false;
        return yield ((!) discovery).has_entity_feature(stream,
            ((!) bind).my_jid.bare_jid, SERVER_ASSIST_FEATURE);
    }

    /** Rechecks SERVER_ASSIST_FEATURE before putting the payload on the wire. */
    public async bool send_server_assisted_displayed(XmppStream stream,
            Jid chat, string marker_id, string message_type,
            string stanza_id, Jid by) {
        MessageStanza? message = build_server_assisted_message(chat,
            marker_id, message_type, stanza_id, by);
        if (message == null) return false;
        if (!(yield supports_server_assist(stream))) return false;

        try {
            yield stream.get_module<MessageModule>(MessageModule.IDENTITY)
                .send_message(stream, (!) message);
            return true;
        } catch (IOError error) {
            debug("XEP-0490 server-assisted marker was not sent: %s",
                error.message);
            return false;
        }
    }

    private static bool has_unsafe_address_character(string value) {
        int byte_index = 0;
        unichar character;
        while (value.get_next_char(ref byte_index, out character)) {
            UnicodeType type = character.type();
            if (character.isspace() || type == UnicodeType.CONTROL ||
                    type == UnicodeType.FORMAT ||
                    type == UnicodeType.LINE_SEPARATOR ||
                    type == UnicodeType.PARAGRAPH_SEPARATOR) {
                return true;
            }
        }
        return false;
    }

    public static Pubsub.PublishOptions required_publish_options() {
        return new Pubsub.PublishOptions()
            .set_persist_items(true)
            .set_max_items("max")
            .set_send_last_published_item("never")
            .set_access_model(Pubsub.ACCESS_MODEL_WHITELIST);
    }

    public async FetchResult fetch_all(XmppStream stream,
            Cancellable? cancellable = null) {
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        if (bind == null) {
            return new FetchResult(false, new ArrayList<DisplayedItem>(),
                "not-authorized");
        }
        Jid own_bare_jid = ((!) bind).my_jid.bare_jid;
        Pubsub.RequestAllResult? result = yield stream.get_module<
            Pubsub.Module>(Pubsub.Module.IDENTITY)
            .request_all_with_result_cancellable(stream, own_bare_jid,
                NS_URI, -1, Pubsub.RequestPurpose.STATE_SYNC, cancellable);

        var items = new ArrayList<DisplayedItem>();
        if (result == null) return new FetchResult(false, items);
        if (result.is_item_not_found()) return new FetchResult(true, items);
        if (result.items == null) {
            return new FetchResult(false, items, result.error_condition);
        }

        foreach (StanzaNode item_node in (!) result.items) {
            DisplayedItem? item = parse_item(item_node);
            if (item != null) items.add((!) item);
        }
        return new FetchResult(true, items);
    }

    public async PublishResult publish_displayed(XmppStream stream,
            Jid chat, string stanza_id, Jid by,
            Cancellable? cancellable = null) {
        StanzaNode? payload = build_payload(stanza_id, by);
        if (payload == null) return new PublishResult(false);

        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        if (bind == null) return new PublishResult(false);
        Jid own_bare_jid = ((!) bind).my_jid.bare_jid;
        bool supports_publish_options = yield stream.get_module<
            ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY)
            .has_entity_feature(stream, own_bare_jid,
                PUBLISH_OPTIONS_FEATURE);
        if (!supports_publish_options ||
                (cancellable != null && ((!) cancellable).is_cancelled())) {
            return new PublishResult(false, !supports_publish_options);
        }

        Pubsub.PublishResult? result = yield stream.get_module<Pubsub.Module>(
            Pubsub.Module.IDENTITY).publish_with_result_cancellable(stream,
                own_bare_jid, NS_URI, chat.to_string(), (!) payload,
                required_publish_options(), true, false, cancellable);
        if (result == null) return new PublishResult(false, false, true);
        return new PublishResult(result.ok, false, result.ambiguous,
            result.error_condition);
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

}
