namespace Xmpp.Xep.MessageDeliveryReceipts {
    public const string NS_URI = "urn:xmpp:receipts";

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0184_message_delivery_receipts");

        public signal void receipt_received(XmppStream stream, Jid jid, string id, MessageStanza stanza);

        private SendPipelineListener send_pipeline_listener = new SendPipelineListener();

        public async bool send_received(XmppStream stream, Jid from,
                string message_id, string type_) {
            StanzaNode? received = build_received_node(message_id);
            if (received == null) return false;
            MessageStanza received_message = new MessageStanza();
            received_message.to = from;
            received_message.type_ = type_;
            received_message.stanza.put_node((!) received);
            try {
                yield stream.get_module<MessageModule>(MessageModule.IDENTITY)
                    .send_message(stream, received_message);
                return true;
            } catch (IOError error) {
                debug("XEP-0184 receipt was not sent: %s", error.message);
                return false;
            }
        }

        public static bool requests_receipt(MessageStanza message) {
            return message.stanza.get_subnodes("request", NS_URI).size == 1 &&
                !contains_receipt(message) &&
                !ChatMarkers.Module.contains_any_marker(message);
        }

        public static bool contains_receipt(MessageStanza message) {
            return message.stanza.get_subnodes("received", NS_URI).size > 0;
        }

        public static string? get_received_id(MessageStanza message) {
            Gee.List<StanzaNode> received = message.stanza.get_subnodes(
                "received", NS_URI);
            if (received.size != 1 ||
                    message.stanza.get_subnodes("request", NS_URI).size > 0) {
                return null;
            }
            string? id = received[0].get_attribute("id", NS_URI);
            if (id == null || ((!) id).strip().length == 0) return null;
            return (!) id;
        }

        public static StanzaNode? build_received_node(string? message_id) {
            if (message_id == null ||
                    ((!) message_id).strip().length == 0) return null;
            return new StanzaNode.build("received", NS_URI).add_self_xmlns()
                .put_attribute("id", (!) message_id);
        }

        public override void attach(XmppStream stream) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(received_message);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.connect(send_pipeline_listener);
        }

        public override void detach(XmppStream stream) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(received_message);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.disconnect(send_pipeline_listener);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }

        private void received_message(XmppStream stream, MessageStanza message) {
            string? id = get_received_id(message);
            if (id != null) receipt_received(stream, message.from, (!) id,
                message);
        }
    }

public class SendPipelineListener : StanzaListener<MessageStanza> {

    private string[] after_actions_const = new string[] {};

    public override string action_group { get { return "ADD_NODES"; } }
    public override string[] after_actions { get { return after_actions_const; } }

    public override async bool run(XmppStream stream, MessageStanza message) {
        if (Module.contains_receipt(message) ||
                ChatMarkers.Module.contains_any_marker(message)) return false;
        if (message.body == null) return false;
        if (message.type_ == MessageStanza.TYPE_GROUPCHAT) return false;
        if (Module.requests_receipt(message)) return false;
        message.stanza.put_node(new StanzaNode.build("request", NS_URI).add_self_xmlns());
        return false;
    }
}

}
