using Gee;

namespace Xmpp.Xep.ChatMarkers {
public const string NS_URI = "urn:xmpp:chat-markers:0";

public const string MARKER_DISPLAYED = "displayed";
private const string LEGACY_MARKER_RECEIVED = "received";
private const string LEGACY_MARKER_ACKNOWLEDGED = "acknowledged";

public class Module : XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0333_chat_markers");

    public signal void displayed_received(XmppStream stream, Jid jid, string id,
            MessageStanza message);
    public signal void legacy_received(XmppStream stream, Jid jid, string id,
            MessageStanza message);

    private SendPipelineListener send_pipeline_listener = new SendPipelineListener();

    public async bool send_displayed(XmppStream stream, Jid jid,
            string message_id, string type_) {
        StanzaNode? displayed = build_displayed_node(message_id);
        if (displayed == null) return false;

        MessageStanza marker_message = new MessageStanza();
        marker_message.to = jid;
        marker_message.type_ = type_;
        marker_message.stanza.put_node((!) displayed);
        try {
            yield stream.get_module<MessageModule>(MessageModule.IDENTITY)
                .send_message(stream, marker_message);
            return true;
        } catch (IOError error) {
            debug("XEP-0333 displayed marker was not sent: %s",
                error.message);
            return false;
        }
    }

    public static bool requests_marking(MessageStanza message) {
        return message.stanza.get_subnodes("markable", NS_URI).size == 1 &&
            !contains_any_marker(message) &&
            !MessageDeliveryReceipts.Module.contains_receipt(message);
    }

    public static bool contains_markable(MessageStanza message) {
        return message.stanza.get_subnodes("markable", NS_URI).size > 0;
    }

    public static string? get_displayed_id(MessageStanza message) {
        Gee.List<StanzaNode> displayed = message.stanza.get_subnodes(
            MARKER_DISPLAYED, NS_URI);
        Gee.List<StanzaNode> acknowledged = message.stanza.get_subnodes(
            LEGACY_MARKER_ACKNOWLEDGED, NS_URI);
        Gee.List<StanzaNode> received = message.stanza.get_subnodes(
            LEGACY_MARKER_RECEIVED, NS_URI);
        if (received.size > 0 || displayed.size + acknowledged.size != 1) {
            return null;
        }
        StanzaNode marker = displayed.size == 1
            ? displayed[0] : acknowledged[0];
        return get_nonempty_marker_id(marker);
    }

    public static bool contains_any_marker(MessageStanza message) {
        return message.stanza.get_subnodes(MARKER_DISPLAYED, NS_URI).size > 0 ||
            message.stanza.get_subnodes(LEGACY_MARKER_RECEIVED,
                NS_URI).size > 0 ||
            message.stanza.get_subnodes(LEGACY_MARKER_ACKNOWLEDGED,
                NS_URI).size > 0;
    }

    public static StanzaNode? build_displayed_node(string? message_id) {
        if (message_id == null) return null;

        if (((!) message_id).strip().length == 0) return null;

        return new StanzaNode.build(MARKER_DISPLAYED, NS_URI)
            .add_self_xmlns()
            .put_attribute("id", (!) message_id);
    }

    public override void attach(XmppStream stream) {
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.connect(send_pipeline_listener);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(on_received_message);
    }

    public override void detach(XmppStream stream) {
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.disconnect(send_pipeline_listener);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(on_received_message);
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    private void on_received_message(XmppStream stream, MessageStanza message) {
        string? displayed_id = get_displayed_id(message);
        if (displayed_id != null) {
            displayed_received(stream, message.from, (!) displayed_id, message);
        }

        // XEP-0333 1.0 removed delivery markers in favour of XEP-0184. Keep
        // accepting old peers without exposing the legacy element in the
        // current outbound API.
        string? received_id = get_legacy_received_id(message);
        if (received_id != null) {
            legacy_received(stream, message.from, (!) received_id, message);
        }
    }

    private static string? get_nonempty_marker_id(StanzaNode marker) {
        string? id = marker.get_attribute("id", NS_URI);
        if (id == null || ((!) id).strip().length == 0) return null;
        return (!) id;
    }

    private static string? get_legacy_received_id(MessageStanza message) {
        Gee.List<StanzaNode> received = message.stanza.get_subnodes(
            LEGACY_MARKER_RECEIVED, NS_URI);
        int other_count = message.stanza.get_subnodes(MARKER_DISPLAYED,
            NS_URI).size + message.stanza.get_subnodes(
                LEGACY_MARKER_ACKNOWLEDGED, NS_URI).size;
        return received.size == 1 && other_count == 0
            ? get_nonempty_marker_id(received[0]) : null;
    }
}

public class SendPipelineListener : StanzaListener<MessageStanza> {

    private string[] after_actions_const = new string[] {};

    public override string action_group { get { return "ADD_NODES"; } }
    public override string[] after_actions { get { return after_actions_const; } }

    public override async bool run(XmppStream stream, MessageStanza message) {
        if (Module.contains_any_marker(message) ||
                MessageDeliveryReceipts.Module.contains_receipt(message)) {
            return false;
        }
        if (message.body == null) return false;
        if (message.type_ != MessageStanza.TYPE_CHAT &&
                message.type_ != MessageStanza.TYPE_GROUPCHAT) return false;
        if (Module.contains_markable(message)) return false;

        message.stanza.put_node(new StanzaNode.build("markable", NS_URI).add_self_xmlns());
        return false;
    }
}

}
