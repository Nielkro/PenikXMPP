using Gee;

namespace Xmpp.Xep.JingleMessageInitiation {
    public const string NS_URI = "urn:xmpp:jingle-message:0";
    private const string HINTS_NS_URI = "urn:xmpp:hints";

    public enum Action {
        PROPOSE,
        RINGING,
        RETRACT,
        LEGACY_ACCEPT,
        PROCEED,
        REJECT,
        FINISH
    }

    public enum Delivery {
        LIVE,
        CARBON_RECEIVED,
        CARBON_SENT,
        MAM,
        DELAYED
    }

    public class JmiReason : Object {
        public string? condition { get; private set; }
        public string? text { get; private set; }

        public JmiReason(string? condition = null, string? text = null) {
            this.condition = condition;
            this.text = text;
        }
    }

    /**
     * Side-effect-free representation of one validated JMI message.
     *
     * Account and call ownership deliberately remain in libdino. The XMPP
     * module only exposes the addresses, delivery provenance and protocol
     * metadata needed by that later lifecycle layer.
     */
    public class JmiEvent : Object {
        public Action action { get; private set; }
        public string sid { get; private set; }
        public Jid from { get; private set; }
        public Jid to { get; private set; }
        public Delivery delivery { get; private set; }
        public DateTime? timestamp { get; private set; }
        public Gee.List<StanzaNode> descriptions { get; private set; }
        public JmiReason? reason { get; private set; }
        public bool tie_break { get; private set; }
        public string? migrated_to_sid { get; private set; }
        public bool legacy_migrated_namespace { get; private set; }
        public bool has_store_hint { get; private set; }

        internal JmiEvent(Action action, string sid, Jid from, Jid to,
                Delivery delivery, DateTime? timestamp,
                Gee.List<StanzaNode> descriptions, JmiReason? reason,
                bool tie_break, string? migrated_to_sid,
                bool legacy_migrated_namespace, bool has_store_hint) {
            this.action = action;
            this.sid = sid;
            this.from = from;
            this.to = to;
            this.delivery = delivery;
            this.timestamp = timestamp;
            this.descriptions = descriptions;
            this.reason = reason;
            this.tie_break = tie_break;
            this.migrated_to_sid = migrated_to_sid;
            this.legacy_migrated_namespace = legacy_migrated_namespace;
            this.has_store_hint = has_store_hint;
        }
    }

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0353_jingle_message_initiation");

        // Compatibility signals for existing live consumers. MAM events never
        // reach these signals and therefore cannot ring or start media.
        public signal void session_proposed(Jid from, Jid to, string sid, Gee.List<StanzaNode> descriptions);
        public signal void session_retracted(Jid from, Jid to, string sid);
        public signal void session_accepted(Jid from, Jid to, string sid);
        public signal void session_proceeded(Jid from, Jid to, string sid);
        public signal void session_rejected(Jid from, Jid to, string sid);

        // Keep new signals after the existing ABI surface so old class signal
        // slots retain their generated C layout.
        public signal void event_received(XmppStream stream, JmiEvent event);

        public void send_session_propose_to_peer(XmppStream stream, Jid to,
                string sid, Gee.List<StanzaNode> descriptions) {
            send_message(stream, build_message(to, Action.PROPOSE, sid,
                descriptions));
        }

        public void send_session_ringing_to_peer(XmppStream stream, Jid to,
                string sid) {
            send_message(stream, build_message(to, Action.RINGING, sid));
        }

        public void send_session_retract_to_peer(XmppStream stream, Jid to,
                string sid) {
            send_session_retract_with_reason_to_peer(stream, to, sid,
                Jingle.ReasonElement.CANCEL, null, false);
        }

        public void send_session_retract_with_reason_to_peer(
                XmppStream stream, Jid to, string sid, string? reason_name,
                string? reason_text, bool tie_break) {
            send_message(stream, build_message(to, Action.RETRACT, sid, null,
                new JmiReason(reason_name, reason_text), tie_break));
        }

        /** Compatibility action used by existing multi-device call handling. */
        public void send_session_accept_to_self(XmppStream stream,
                string sid) {
            send_message(stream, build_message(
                Bind.Flag.get_my_jid(stream).bare_jid,
                Action.LEGACY_ACCEPT, sid));
        }

        public void send_session_reject_to_self(XmppStream stream,
                string sid) {
            send_message(stream, build_message(
                Bind.Flag.get_my_jid(stream).bare_jid, Action.REJECT, sid,
                null, new JmiReason(Jingle.ReasonElement.BUSY)));
        }

        public void send_session_proceed_to_peer(XmppStream stream, Jid to,
                string sid) {
            send_message(stream, build_message(to, Action.PROCEED, sid));
        }

        public void send_session_reject_to_peer(XmppStream stream, Jid to,
                string sid) {
            send_session_reject_with_reason_to_peer(stream, to, sid,
                Jingle.ReasonElement.BUSY, null, false);
        }

        public void send_session_reject_with_reason_to_peer(
                XmppStream stream, Jid to, string sid, string? reason_name,
                string? reason_text, bool tie_break) {
            send_message(stream, build_message(to, Action.REJECT, sid, null,
                new JmiReason(reason_name, reason_text), tie_break));
        }

        public void send_session_finish_to_peer(XmppStream stream, Jid to,
                string sid, string? reason_name = Jingle.ReasonElement.SUCCESS,
                string? reason_text = null, string? migrated_to_sid = null) {
            send_message(stream, build_message(to, Action.FINISH, sid, null,
                new JmiReason(reason_name, reason_text), false,
                migrated_to_sid));
        }

        /**
         * Build one canonical XEP-0353 message.
         *
         * LEGACY_ACCEPT remains buildable only so the existing compatibility
         * wrapper can retain its current multi-device behaviour. New
         * standards-track code should use PROCEED and Carbons instead.
         */
        public static MessageStanza build_message(Jid to, Action action,
                string sid, Gee.List<StanzaNode>? descriptions = null,
                JmiReason? reason = null, bool tie_break = false,
                string? migrated_to_sid = null) {
            MessageStanza message = new MessageStanza() {
                to = to,
                type_ = MessageStanza.TYPE_CHAT
            };
            StanzaNode action_node = new StanzaNode.build(
                action_to_name(action), NS_URI).add_self_xmlns()
                    .put_attribute("id", sid, NS_URI);

            if (action == Action.PROPOSE && descriptions != null) {
                foreach (StanzaNode description in (!) descriptions) {
                    action_node.put_node(description);
                }
            }

            if (reason != null && ((!) reason).condition != null &&
                    is_valid_reason_condition(
                        (!) ((!) reason).condition)) {
                StanzaNode reason_node = new StanzaNode.build("reason",
                    Jingle.NS_URI).add_self_xmlns();
                if (((!) reason).condition != null) {
                    reason_node.put_node(new StanzaNode.build(
                        (!) ((!) reason).condition, Jingle.NS_URI));
                }
                if (((!) reason).text != null) {
                    reason_node.put_node(new StanzaNode.build("text",
                        Jingle.NS_URI).put_node(
                            new StanzaNode.text((!) ((!) reason).text)));
                }
                action_node.put_node(reason_node);
            }

            if (tie_break) {
                action_node.put_node(new StanzaNode.build("tie-break",
                    NS_URI));
            }
            if (migrated_to_sid != null) {
                action_node.put_node(new StanzaNode.build("migrated", NS_URI)
                    .put_attribute("to", (!) migrated_to_sid));
            }

            message.stanza.put_node(action_node);
            MessageProcessingHints.set_message_hint(message,
                MessageProcessingHints.HINT_STORE);
            return message;
        }

        /** Parse one message without changing call, UI or media state. */
        public static JmiEvent? parse_message(MessageStanza message) {
            // Current XEP-0353 requires type='chat'. Older DinoX versions
            // accepted an omitted type (represented as 'normal'), so retain
            // that input compatibility while always emitting canonical chat.
            if (message.type_ != MessageStanza.TYPE_CHAT &&
                    message.type_ != MessageStanza.TYPE_NORMAL) return null;

            Jid? from = message.from;
            Jid? to = message.to;
            if (from == null || to == null) return null;

            bool found_action = false;
            Action action = Action.PROPOSE;
            StanzaNode? action_node = null;
            foreach (StanzaNode node in message.stanza.sub_nodes) {
                Action candidate = Action.PROPOSE;
                if (node.ns_uri != NS_URI ||
                        !try_parse_action(node.name, out candidate)) continue;
                if (found_action) return null;
                found_action = true;
                action = candidate;
                action_node = node;
            }
            if (!found_action || action_node == null) return null;

            string? raw_sid = ((!) action_node).get_attribute("id");
            if (raw_sid == null || ((!) raw_sid).strip() == "") return null;
            string sid = ((!) raw_sid).strip();

            var descriptions = new ArrayList<StanzaNode>();
            if (action == Action.PROPOSE) {
                foreach (StanzaNode child in ((!) action_node).sub_nodes) {
                    if (child.name == "description" &&
                            child.ns_uri != null && child.ns_uri != NS_URI) {
                        descriptions.add(child);
                    }
                }
                if (descriptions.is_empty) return null;
            }

            JmiReason? reason = null;
            Gee.List<StanzaNode> reason_nodes = ((!) action_node).get_subnodes(
                "reason", Jingle.NS_URI);
            if (reason_nodes.size > 1) return null;
            if (reason_nodes.size == 1) {
                string? reason_condition;
                string? reason_text;
                if (!parse_reason(reason_nodes[0], out reason_condition,
                        out reason_text)) return null;
                reason = new JmiReason(reason_condition, reason_text);
            }

            Gee.List<StanzaNode> tie_break_nodes =
                ((!) action_node).get_subnodes("tie-break", NS_URI);
            if (tie_break_nodes.size > 1) return null;
            bool tie_break = tie_break_nodes.size == 1;
            if (tie_break && action != Action.REJECT &&
                    action != Action.RETRACT) return null;

            Gee.List<StanzaNode> standard_migrated_nodes =
                ((!) action_node).get_subnodes("migrated", NS_URI);
            Gee.List<StanzaNode> legacy_migrated_nodes =
                ((!) action_node).get_subnodes("migrated", Jingle.NS_URI);
            if (standard_migrated_nodes.size +
                    legacy_migrated_nodes.size > 1) return null;
            bool legacy_migrated_namespace =
                legacy_migrated_nodes.size == 1;
            StanzaNode? migrated_node = standard_migrated_nodes.size == 1
                ? standard_migrated_nodes[0]
                : legacy_migrated_namespace
                    ? legacy_migrated_nodes[0] : null;
            string? migrated_to_sid = null;
            if (migrated_node != null) {
                if (action != Action.FINISH) return null;
                migrated_to_sid = ((!) migrated_node).get_attribute("to");
                if (migrated_to_sid == null ||
                        ((!) migrated_to_sid).strip() == "") return null;
                migrated_to_sid = ((!) migrated_to_sid).strip();
            }

            if (reason != null && action != Action.RETRACT &&
                    action != Action.REJECT && action != Action.FINISH) {
                return null;
            }

            Delivery delivery = Delivery.LIVE;
            DateTime? timestamp = null;
            MessageArchiveManagement.MessageFlag? mam_flag =
                MessageArchiveManagement.MessageFlag.get_flag(message);
            if (mam_flag != null) {
                delivery = Delivery.MAM;
                timestamp = ((!) mam_flag).server_time;
            } else {
                MessageCarbons.MessageFlag? carbon_flag =
                    MessageCarbons.MessageFlag.get_flag(message);
                if (carbon_flag != null) {
                    if (((!) carbon_flag).is_received()) {
                        delivery = Delivery.CARBON_RECEIVED;
                    } else if (((!) carbon_flag).is_sent()) {
                        delivery = Delivery.CARBON_SENT;
                    } else {
                        return null;
                    }
                } else {
                    DelayedDelivery.MessageFlag? delayed_flag =
                        DelayedDelivery.MessageFlag.get_flag(message);
                    if (delayed_flag != null) {
                        delivery = Delivery.DELAYED;
                        timestamp = ((!) delayed_flag).datetime;
                    }
                }
            }

            bool has_store_hint = message.stanza.get_subnode("store",
                HINTS_NS_URI) != null;
            return new JmiEvent(action, sid, (!) from, (!) to, delivery,
                timestamp, descriptions, reason, tie_break,
                migrated_to_sid, legacy_migrated_namespace,
                has_store_hint);
        }

        private static bool parse_reason(StanzaNode reason_node,
                out string? condition, out string? text) {
            condition = null;
            text = null;
            foreach (StanzaNode child in reason_node.sub_nodes) {
                if (child.ns_uri != Jingle.NS_URI) continue;
                if (child.name == "text") {
                    if (text != null) return false;
                    text = child.get_string_content();
                } else {
                    if (condition != null) return false;
                    condition = child.name;
                }
            }
            return condition != null &&
                is_valid_reason_condition((!) condition);
        }

        private static bool is_valid_reason_condition(string condition) {
            switch (condition) {
                case Jingle.ReasonElement.ALTERNATIVE_SESSION:
                case Jingle.ReasonElement.BUSY:
                case Jingle.ReasonElement.CANCEL:
                case Jingle.ReasonElement.CONNECTIVITY_ERROR:
                case Jingle.ReasonElement.DECLINE:
                case Jingle.ReasonElement.EXPIRED:
                case Jingle.ReasonElement.FAILED_APPLICATION:
                case Jingle.ReasonElement.FAILED_TRANSPORT:
                case Jingle.ReasonElement.GENERAL_ERROR:
                case Jingle.ReasonElement.GONE:
                case Jingle.ReasonElement.INCOMPATIBLE_PARAMETERS:
                case Jingle.ReasonElement.MEDIA_ERROR:
                case Jingle.ReasonElement.SECURITY_ERROR:
                case Jingle.ReasonElement.SUCCESS:
                case Jingle.ReasonElement.TIMEOUT:
                case Jingle.ReasonElement.UNSUPPORTED_APPLICATIONS:
                case Jingle.ReasonElement.UNSUPPORTED_TRANSPORTS:
                    return true;
                default:
                    return false;
            }
        }

        private static string action_to_name(Action action) {
            switch (action) {
                case Action.PROPOSE: return "propose";
                case Action.RINGING: return "ringing";
                case Action.RETRACT: return "retract";
                case Action.LEGACY_ACCEPT: return "accept";
                case Action.PROCEED: return "proceed";
                case Action.REJECT: return "reject";
                case Action.FINISH: return "finish";
            }
            assert_not_reached();
        }

        private static bool try_parse_action(string name, out Action action) {
            switch (name) {
                case "propose": action = Action.PROPOSE; return true;
                case "ringing": action = Action.RINGING; return true;
                case "retract": action = Action.RETRACT; return true;
                case "accept": action = Action.LEGACY_ACCEPT; return true;
                case "proceed": action = Action.PROCEED; return true;
                case "reject": action = Action.REJECT; return true;
                case "finish": action = Action.FINISH; return true;
                default: action = Action.PROPOSE; return false;
            }
        }

        private void send_message(XmppStream stream, MessageStanza message) {
            stream.get_module<MessageModule>(MessageModule.IDENTITY)
                .send_message.begin(stream, message);
        }

        private void on_received_message(XmppStream stream,
                MessageStanza message) {
            JmiEvent? parsed = parse_message(message);
            if (parsed == null) return;
            JmiEvent event = (!) parsed;

            event_received(stream, event);
            if (event.delivery == Delivery.MAM ||
                    event.delivery == Delivery.DELAYED) return;

            switch (event.action) {
                case Action.PROPOSE:
                    session_proposed(event.from, event.to, event.sid,
                        event.descriptions);
                    break;
                case Action.RETRACT:
                    session_retracted(event.from, event.to, event.sid);
                    break;
                case Action.LEGACY_ACCEPT:
                    session_accepted(event.from, event.to, event.sid);
                    break;
                case Action.PROCEED:
                    session_proceeded(event.from, event.to, event.sid);
                    break;
                case Action.REJECT:
                    session_rejected(event.from, event.to, event.sid);
                    break;
                case Action.RINGING:
                case Action.FINISH:
                    break;
            }
        }

        public override void attach(XmppStream stream) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(on_received_message);
        }

        public override void detach(XmppStream stream) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(on_received_message);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }
}
