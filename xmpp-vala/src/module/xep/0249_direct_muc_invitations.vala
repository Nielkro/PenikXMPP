namespace Xmpp.Xep.DirectMucInvitations {

    private const string NS_URI = "jabber:x:conference";

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0249_direct_muc_invitations");

        public signal void invite_received(XmppStream stream, Jid room_jid, Jid from_jid, string? password, string? reason);
        public signal void invite_received_with_context(XmppStream stream, Jid room_jid, Jid from_jid, string? password, string? reason, bool continue_thread, string? thread);

        public async void invite(XmppStream stream, Jid to_muc, Jid jid, string? password = null, string? reason = null, bool continue_thread = false, string? thread = null) throws IOError {
            MessageStanza message = new MessageStanza() { to=jid };
            StanzaNode invite_node = new StanzaNode.build("x", NS_URI).add_self_xmlns()
                    .put_attribute("jid", to_muc.bare_jid.to_string());
            if (password != null && password.strip() != "") {
                invite_node.put_attribute("password", password);
            }
            if (reason != null && reason.strip() != "") {
                invite_node.put_attribute("reason", reason);
            }
            bool has_thread = thread != null && thread.strip() != "";
            if (continue_thread || has_thread) {
                invite_node.put_attribute("continue", "true");
            }
            if (has_thread) {
                invite_node.put_attribute("thread", thread);
            }
            message.stanza.put_node(invite_node);
            yield stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message(stream, message);
        }

        private void received_message(XmppStream stream, MessageStanza message) {
            StanzaNode? x_node = message.stanza.get_subnode("x", NS_URI);
            if (x_node == null) return;

            if (Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message) != null) return;
            Bind.Flag? bind_flag = stream.get_flag(Bind.Flag.IDENTITY);
            if (bind_flag != null && message.from.bare_jid.equals(bind_flag.my_jid.bare_jid)) return;

            string? room_str = x_node.get_attribute("jid");
            if (room_str == null) room_str = x_node.get_attribute("jid", NS_URI);
            if (room_str == null) return;
            Jid? room_jid = null;
            try {
                room_jid = new Jid(room_str);
            } catch (Error e) {
                return;
            }
            if (room_jid == null) return;

            string? password = x_node.get_attribute("password");
            if (password == null) password = x_node.get_attribute("password", NS_URI);
            string? reason = x_node.get_attribute("reason");
            if (reason == null) reason = x_node.get_attribute("reason", NS_URI);
            string? continue_attr = x_node.get_attribute("continue");
            if (continue_attr == null) continue_attr = x_node.get_attribute("continue", NS_URI);
            bool continue_thread = continue_attr == "true" || continue_attr == "1";
            string? thread = x_node.get_attribute("thread");
            if (thread == null) thread = x_node.get_attribute("thread", NS_URI);
            if (!continue_thread) thread = null;

            invite_received(stream, room_jid, message.from, password, reason);
            invite_received_with_context(stream, room_jid, message.from, password, reason, continue_thread, thread);
        }

        public override void attach(XmppStream stream) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(received_message);
        }

        public override void detach(XmppStream stream) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(received_message);
        }

        public override string get_ns() {
            return NS_URI;
        }

        public override string get_id() {
            return IDENTITY.id;
        }
    }

}
