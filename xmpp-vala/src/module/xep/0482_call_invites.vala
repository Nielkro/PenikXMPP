using Gee;
namespace Xmpp.Xep.CallInvites {

    public const string NS_URI = "urn:xmpp:call-invites:0";
    public const string NS_URI_CUSTOM = "urn:xmpp:call-message:1";

    public enum Action {
        INVITE,
        ACCEPT,
        RETRACT,
        REJECT,
        LEFT
    }

    public class ParsedCallInvite : Object {
        public Action action { get; private set; }
        public string call_id { get; private set; }
        public bool video { get; private set; }
        public Gee.List<StanzaNode> join_methods { get; private set; }

        internal ParsedCallInvite(Action action, string call_id,
                bool video = false,
                Gee.List<StanzaNode>? join_methods = null) {
            this.action = action;
            this.call_id = call_id;
            this.video = video;
            this.join_methods = join_methods ?? new ArrayList<StanzaNode>();
        }
    }

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "call_invites");

        public signal void call_proposed(XmppStream stream, Jid from, Jid to, string call_id, bool video, Gee.List<StanzaNode> join_methods, MessageStanza message);
        public signal void call_retracted(Jid from, Jid to, string call_id, string message_type);
        public signal void call_accepted(Jid from, Jid to, string call_id, string message_type);
        public signal void call_rejected(Jid from, Jid to, string call_id, string message_type);
        public signal void call_left(Jid from, Jid to, string call_id, string message_type);

        public void send_jingle_propose(XmppStream stream, string call_id, Jid invitee, string sid, bool video, string message_type = MessageStanza.TYPE_CHAT) {
            StanzaNode method = new StanzaNode.build("jingle", CallInvites.NS_URI).put_attribute("sid", sid);
            StanzaNode legacy_method = new StanzaNode.build("jingle", CallInvites.NS_URI_CUSTOM).put_attribute("sid", sid);
            send_propose(stream, call_id, invitee, video, false, message_type, method, legacy_method);
        }

        public void send_muji_propose(XmppStream stream, string call_id, Jid invitee, Jid muc_jid, bool video, string message_type) {
            StanzaNode method = new StanzaNode.build("muji", Muji.NS_URI).add_self_xmlns().put_attribute("room", muc_jid.to_string());
            send_propose(stream, call_id, invitee, video, true, message_type, method, method);
        }

        public void send_propose(XmppStream stream, string call_id, Jid invitee, bool video, bool multi, string message_type, StanzaNode method, StanzaNode? legacy_method = null) {
            MessageStanza invite_message = build_propose_message(call_id,
                invitee, video, multi, message_type, method, legacy_method);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, invite_message);
        }

        public static MessageStanza build_propose_message(string call_id,
                Jid invitee, bool video, bool multi, string message_type,
                StanzaNode method, StanzaNode? legacy_method = null) {
            // XEP-0482 identifies an invite by the invite message, not by an
            // attribute on <invite/>.  Keep the caller-provided correlation ID
            // both as the stanza ID and as an XEP-0359 origin-id.  A MUC will
            // assign the authoritative stanza-id used by groupchat responses.
            MessageStanza invite_message = new MessageStanza(call_id) { to=invitee, type_=message_type };
            UniqueStableStanzaIDs.set_origin_id(invite_message, call_id);
            invite_message.stanza.put_node(
                    new StanzaNode.build("invite", NS_URI).add_self_xmlns()
                            .put_attribute("video", video.to_string())
                            .put_attribute("multi", multi.to_string())
                            .put_node(method)
            );
            if (legacy_method != null) {
                invite_message.stanza.put_node( // Custom legacy protocol
                        new StanzaNode.build("propose", NS_URI_CUSTOM).add_self_xmlns()
                                .put_attribute("id", call_id)
                                .put_attribute("video", video.to_string())
                                .put_attribute("multi", multi.to_string())
                                .put_node(legacy_method)
                );
            }
            MessageProcessingHints.set_message_hint(invite_message, MessageProcessingHints.HINT_STORE);
            return invite_message;
        }

        public void send_jingle_accept(XmppStream stream, Jid inviter, string call_id, string sid, string message_type) {
            StanzaNode method = new StanzaNode.build("jingle", NS_URI).put_attribute("sid", sid);
            StanzaNode legacy_method = new StanzaNode.build("jingle", NS_URI_CUSTOM).put_attribute("sid", sid);
            send_accept(stream, inviter, call_id, message_type, method, legacy_method);
        }

        public void send_muji_accept(XmppStream stream, Jid inviter, string call_id, Jid room, string message_type) {
            StanzaNode method = new StanzaNode.build("muji", Muji.NS_URI).add_self_xmlns().put_attribute("room", room.to_string());
            send_accept(stream, inviter, call_id, message_type, method, method);
        }

        public void send_accept(XmppStream stream, Jid inviter, string call_id, string message_type, StanzaNode method, StanzaNode? legacy_method = null) {
            MessageStanza invite_message = new MessageStanza() { to=inviter, type_=message_type };
            invite_message.stanza.put_node(
                    new StanzaNode.build("accept", NS_URI).add_self_xmlns()
                            .put_attribute("id", call_id)
                            .put_node(method)
            );
            if (legacy_method != null) {
                invite_message.stanza.put_node(
                        new StanzaNode.build("accept", NS_URI_CUSTOM).add_self_xmlns()
                                .put_attribute("id", call_id)
                                .put_node(legacy_method)
                );
            }
            MessageProcessingHints.set_message_hint(invite_message, MessageProcessingHints.HINT_STORE);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, invite_message);
        }

        public void send_retract(XmppStream stream, Jid to, string call_id, string message_type) {
            send_message(stream, to, call_id, "retract", message_type);
        }

        public void send_reject(XmppStream stream, Jid to, string call_id, string message_type) {
            send_message(stream, to, call_id, "reject", message_type);
        }

        public void send_left(XmppStream stream, Jid to, string call_id, string message_type) {
            MessageStanza message = new MessageStanza() { to=to, type_=message_type };

            StanzaNode inner_node = new StanzaNode.build("left", NS_URI).add_self_xmlns().put_attribute("id", call_id);
            message.stanza.put_node(inner_node);

            // Custom legacy protocol
            StanzaNode custom_node = new StanzaNode.build("finish", NS_URI_CUSTOM).add_self_xmlns().put_attribute("id", call_id);
            message.stanza.put_node(custom_node);

            MessageProcessingHints.set_message_hint(message, MessageProcessingHints.HINT_STORE);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, message);
        }

        private void send_message(XmppStream stream, Jid to, string call_id, string action, string message_type) {
            MessageStanza message = new MessageStanza() { to=to, type_=message_type };

            StanzaNode inner_node = new StanzaNode.build(action, NS_URI).add_self_xmlns().put_attribute("id", call_id);
            message.stanza.put_node(inner_node);

            // Custom legacy protocol
            StanzaNode custom_node = new StanzaNode.build(action, NS_URI_CUSTOM).add_self_xmlns().put_attribute("id", call_id);
            message.stanza.put_node(custom_node);

            MessageProcessingHints.set_message_hint(message, MessageProcessingHints.HINT_STORE);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, message);
        }

        private static string? nonempty_id(string? id) {
            return id != null && ((!) id).strip() != "" ? id : null;
        }

        /**
         * Resolve the standards-track XEP-0482 invite reference.
         *
         * Groupchat invitations are identified exclusively by the room's
         * XEP-0359 stanza-id.  Other messages prefer origin-id and otherwise
         * use message@id.  In particular, an undeclared invite@id attribute is
         * never authoritative for the standards namespace.
         */
        public static string? get_standard_invite_reference_id(
                MessageStanza message) {
            if (message.type_ == MessageStanza.TYPE_GROUPCHAT) {
                Jid? from = message.from;
                if (from == null) return null;
                return nonempty_id(UniqueStableStanzaIDs.get_stanza_id(
                    message, ((!) from).bare_jid));
            }

            string? origin_id = nonempty_id(
                UniqueStableStanzaIDs.get_origin_id(message));
            return origin_id ?? nonempty_id(message.id);
        }

        /** Correlate our outgoing groupchat echo before its room ID is bound. */
        public static string? get_outgoing_invite_correlation_id(
                MessageStanza message) {
            string? origin_id = nonempty_id(
                UniqueStableStanzaIDs.get_origin_id(message));
            return origin_id ?? nonempty_id(message.id);
        }

        private void on_received_message(XmppStream stream, MessageStanza message) {
            process_received_message(stream, message);
        }

        public static ParsedCallInvite? parse_call_invite(
                MessageStanza message) {
            StanzaNode? relevant_node = null;

            foreach (StanzaNode node in message.stanza.sub_nodes) {
                if (node.ns_uri == NS_URI) {
                    relevant_node = node;
                    break;
                }
            }
            if (relevant_node == null) {
                foreach (StanzaNode node in message.stanza.sub_nodes) {
                    if (node.ns_uri == NS_URI_CUSTOM) {
                        relevant_node = node;
                        break;
                    }
                }
            }
            if (relevant_node == null) return null;

            string? call_id;
            if (relevant_node.ns_uri == NS_URI &&
                    relevant_node.name == "invite") {
                call_id = get_standard_invite_reference_id(message);
            } else {
                call_id = nonempty_id(relevant_node.get_attribute("id"));
            }
            if (call_id == null) return null;

            if (relevant_node.name == "invite" ||
                    /* custom legacy */ relevant_node.name == "propose") {
                if (relevant_node.sub_nodes.is_empty) return null;

                // If there's also a JMI node, just use that one instead.
                foreach (StanzaNode node in message.stanza.sub_nodes) {
                    if (node.ns_uri == JingleMessageInitiation.NS_URI) {
                        return null;
                    }
                }
                return new ParsedCallInvite(Action.INVITE, (!) call_id,
                    relevant_node.get_attribute_bool("video", false),
                    relevant_node.sub_nodes);
            }

            switch (relevant_node.name) {
                case "accept":
                    return new ParsedCallInvite(Action.ACCEPT, (!) call_id);
                case "retract":
                    return new ParsedCallInvite(Action.RETRACT, (!) call_id);
                case "reject":
                    return new ParsedCallInvite(Action.REJECT, (!) call_id);
                case "left":
                case "finish":
                    return new ParsedCallInvite(Action.LEFT, (!) call_id);
            }
            return null;
        }

        private void process_received_message(XmppStream stream,
                MessageStanza message) {
            Xmpp.MessageArchiveManagement.MessageFlag? mam_flag = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message);
            if (mam_flag != null) return;

            ParsedCallInvite? parsed = parse_call_invite(message);
            if (parsed == null) return;
            switch (((!) parsed).action) {
                case Action.INVITE:
                    call_proposed(stream, message.from, message.to,
                        ((!) parsed).call_id, ((!) parsed).video,
                        ((!) parsed).join_methods, message);
                    break;
                case Action.ACCEPT:
                    call_accepted(message.from, message.to,
                        ((!) parsed).call_id, message.type_);
                    break;
                case Action.RETRACT:
                    call_retracted(message.from, message.to,
                        ((!) parsed).call_id, message.type_);
                    break;
                case Action.REJECT:
                    call_rejected(message.from, message.to,
                        ((!) parsed).call_id, message.type_);
                    break;
                case Action.LEFT:
                    call_left(message.from, message.to,
                        ((!) parsed).call_id, message.type_);
                    break;
            }
        }

        public override void attach(XmppStream stream) {
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(on_received_message);
        }

        public override void detach(XmppStream stream) {
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(on_received_message);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }
}
