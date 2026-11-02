using Gee;

namespace Xmpp.Presence {
    private const string NS_URI = "jabber:client";

    public interface ReceivedPresenceAdmission : Object {
        public abstract bool admit_received_presence(XmppStream stream,
            Presence.Stanza presence);
    }

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "presence_module");

        public signal void received_presence(XmppStream stream, Presence.Stanza presence);
        public signal void pre_send_presence_stanza(XmppStream stream, Presence.Stanza presence);
        public signal void initial_presence_sent(XmppStream stream, Presence.Stanza presence);
        public signal void received_available(XmppStream stream, Presence.Stanza presence);
        public signal void received_available_show(XmppStream stream, Jid jid, string show);
        public signal void received_unavailable(XmppStream stream, Presence.Stanza presence);
        public signal void received_subscription_request(XmppStream stream, Jid jid);
        public signal void received_subscription_approval(XmppStream stream, Jid jid);
        public signal void received_unsubscription(XmppStream stream, Jid jid);

        public bool available_resource = true;
        private ArrayList<ReceivedPresenceAdmission> admission_handlers =
            new ArrayList<ReceivedPresenceAdmission>();
        private ArrayList<ReceivedPresenceAdmission> admission_handler_snapshot =
            new ArrayList<ReceivedPresenceAdmission>();

        public void add_received_presence_admission(
                ReceivedPresenceAdmission handler) {
            if (!admission_handlers.contains(handler)) {
                admission_handlers.add(handler);
                rebuild_admission_handler_snapshot();
            }
        }

        public void remove_received_presence_admission(
                ReceivedPresenceAdmission handler) {
            if (admission_handlers.remove(handler)) {
                rebuild_admission_handler_snapshot();
            }
        }

        private void rebuild_admission_handler_snapshot() {
            var snapshot = new ArrayList<ReceivedPresenceAdmission>();
            snapshot.add_all(admission_handlers);
            admission_handler_snapshot = snapshot;
        }

        public void request_subscription(XmppStream stream, Jid bare_jid) {
            Presence.Stanza presence = new Presence.Stanza();
            presence.to = bare_jid;
            presence.type_ = Presence.Stanza.TYPE_SUBSCRIBE;
            send_presence(stream, presence);
        }

        public void request_subscription_with_preauth(XmppStream stream, Jid bare_jid, string token) {
            Presence.Stanza presence = new Presence.Stanza();
            presence.to = bare_jid;
            presence.type_ = Presence.Stanza.TYPE_SUBSCRIBE;
            presence.stanza.put_node(new StanzaNode.build("preauth", Xep.InBandRegistration.NS_URI_PARS)
                    .add_self_xmlns()
                    .put_attribute("token", token));
            send_presence(stream, presence);
        }

        public void approve_subscription(XmppStream stream, Jid bare_jid) {
            Presence.Stanza presence = new Presence.Stanza();
            presence.to = bare_jid;
            presence.type_ = Presence.Stanza.TYPE_SUBSCRIBED;
            send_presence(stream, presence);
        }

        public void deny_subscription(XmppStream stream, Jid bare_jid) {
            cancel_subscription(stream, bare_jid);
        }

        public void cancel_subscription(XmppStream stream, Jid bare_jid) {
            Presence.Stanza presence = new Presence.Stanza();
            presence.to = bare_jid;
            presence.type_ = Presence.Stanza.TYPE_UNSUBSCRIBED;
            send_presence(stream, presence);
        }

        public void unsubscribe(XmppStream stream, Jid bare_jid) {
            Presence.Stanza presence = new Presence.Stanza();
            presence.to = bare_jid;
            presence.type_ = Presence.Stanza.TYPE_UNSUBSCRIBE;
            send_presence(stream, presence);
        }

        public void send_presence(XmppStream stream, Presence.Stanza presence) {
            pre_send_presence_stanza(stream, presence);
            stream.write_node(presence.stanza);
        }

        public async void send_presence_async(XmppStream stream,
                Presence.Stanza presence) throws IOError {
            pre_send_presence_stanza(stream, presence);
            yield stream.write_async(presence.stanza);
        }

        public bool supports_subscription_preapproval(XmppStream stream) {
            return stream.features != null && ((!) stream.features).get_subnode(
                "sub", "urn:xmpp:features:pre-approval") != null;
        }

        public override void attach(XmppStream stream) {
            stream.add_flag(new Flag());
            stream.received_presence_stanza.connect(on_received_presence_stanza);
            stream.stream_negotiated.connect(on_stream_negotiated);
        }

        public override void detach(XmppStream stream) {
            stream.received_presence_stanza.disconnect(on_received_presence_stanza);
            stream.stream_negotiated.disconnect(on_stream_negotiated);
        }

        private void on_received_presence_stanza(XmppStream stream, StanzaNode node) {
            Presence.Stanza presence = new Presence.Stanza.from_stanza(node, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
            // Keep a strong reference to the immutable snapshot. A handler may
            // register or remove another handler reentrantly without
            // invalidating this dispatch.
            ArrayList<ReceivedPresenceAdmission> handlers =
                admission_handler_snapshot;
            foreach (ReceivedPresenceAdmission handler in handlers) {
                if (!handler.admit_received_presence(stream, presence)) return;
            }
            received_presence(stream, presence);
            switch (presence.type_) {
                case Presence.Stanza.TYPE_AVAILABLE:
                    stream.get_flag(Flag.IDENTITY).add_presence(presence);
                    received_available(stream, presence);
                    received_available_show(stream, presence.from, presence.show ?? "online");
                    break;
                case Presence.Stanza.TYPE_UNAVAILABLE:
                    stream.get_flag(Flag.IDENTITY).remove_presence(presence.from);
                    received_unavailable(stream, presence);
                    break;
                case Presence.Stanza.TYPE_SUBSCRIBE:
                    received_subscription_request(stream, presence.from);
                    break;
                case Presence.Stanza.TYPE_SUBSCRIBED:
                    received_subscription_approval(stream, presence.from);
                    break;
                case Presence.Stanza.TYPE_UNSUBSCRIBE:
                    stream.get_flag(Flag.IDENTITY).remove_presence(presence.from);
                    received_unsubscription(stream, presence.from);
                    break;
                case Presence.Stanza.TYPE_UNSUBSCRIBED:
                    break;
            }
        }

        private void on_stream_negotiated(XmppStream stream) {
            if (available_resource) {
                Presence.Stanza presence = new Presence.Stanza();
                send_presence(stream, presence);
                initial_presence_sent(stream, presence);
            }
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }

}
