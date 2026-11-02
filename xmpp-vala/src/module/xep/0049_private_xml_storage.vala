using Gee;

namespace Xmpp.Xep.PrivateXmlStorage {
    private const string NS_URI = "jabber:iq:private";

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0049_private_xml_storage");

        public async bool store(XmppStream stream, StanzaNode node) {
            StanzaNode queryNode = new StanzaNode.build("query", NS_URI).add_self_xmlns().put_node(node);
            Iq.Stanza iq = new Iq.Stanza.set(queryNode);
            Iq.Module? iq_module = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
            if (iq_module == null) {
                warning("Cannot store private XML without IQ module");
                return false;
            }

            try {
                Iq.Stanza iq_result = yield ((!) iq_module).send_iq_async(stream, iq);
                return !iq_result.is_error();
            } catch (GLib.Error e) {
                warning("Failed to store private XML: %s", e.message);
                return false;
            }
        }

        public async StanzaNode? retrieve(XmppStream stream, StanzaNode node) {
            StanzaNode queryNode = new StanzaNode.build("query", NS_URI).add_self_xmlns().put_node(node);
            Iq.Stanza iq = new Iq.Stanza.get(queryNode);
            Iq.Module? iq_module = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
            if (iq_module == null) {
                warning("Cannot retrieve private XML without IQ module");
                return null;
            }

            try {
                Iq.Stanza iq_result = yield ((!) iq_module).send_iq_async(stream, iq);
                if (iq_result.is_error()) {
                    warning("Failed to retrieve private XML: server returned an IQ error");
                    return null;
                }
                return iq_result.stanza.get_subnode("query", NS_URI);
            } catch (GLib.Error e) {
                warning("Failed to retrieve private XML: %s", e.message);
                return null;
            }
        }

        public override void attach(XmppStream stream) { }

        public override void detach(XmppStream stream) { }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }
}
