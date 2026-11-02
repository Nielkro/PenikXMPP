using Gee;

namespace Xmpp.Xep.Ping {
    private const string NS_URI = "urn:xmpp:ping";

    public class Module : XmppStreamModule, Iq.Handler {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0199_ping");

        public async Iq.Stanza? send_ping(XmppStream stream, Jid jid) {
            return yield send_ping_with_options(stream, jid, Priority.HIGH, false);
        }

        public async Iq.Stanza? send_ping_with_options(XmppStream stream, Jid jid, int io_priority, bool quiet_timeout) {
            StanzaNode ping_node = new StanzaNode.build("ping", NS_URI).add_self_xmlns();
            Iq.Stanza iq = new Iq.Stanza.get(ping_node) { to=jid };
            try {
                return yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq, io_priority);
            } catch (IOError.CANCELLED e) {
                debug("Ping cancelled: %s", e.message);
                return null;
            } catch (IOError.TIMED_OUT e) {
                if (quiet_timeout) {
                    debug("Ping timed out for %s: %s", jid.to_string(), e.message);
                } else {
                    warning("Failed to send ping: %s", e.message);
                }
                return null;
            } catch (GLib.Error e) {
                warning("Failed to send ping: %s", e.message);
                return null;
            }
        }

        public override void attach(XmppStream stream) {
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).register_for_namespace(NS_URI, this);
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
        }

        public override void detach(XmppStream stream) {
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).unregister_from_namespace(NS_URI, this);
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
        }

        public async void on_iq_get(XmppStream stream, Iq.Stanza iq) {
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq(stream, new Iq.Stanza.result(iq), null, Priority.HIGH);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }
}
