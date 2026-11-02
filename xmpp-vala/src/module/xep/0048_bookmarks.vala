using Gee;

namespace Xmpp.Xep.Bookmarks {
private const string NS_URI = "storage:bookmarks";

public class Module : BookmarksProvider, XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0048_bookmarks_module");

    public async Set<Conference>? get_conferences(XmppStream stream) {
        StanzaNode get_node = new StanzaNode.build("storage", NS_URI).add_self_xmlns();
        PrivateXmlStorage.Module? private_xml_module = stream.get_module<PrivateXmlStorage.Module>(PrivateXmlStorage.Module.IDENTITY);
        if (private_xml_module == null) {
            warning("Cannot retrieve legacy bookmarks without Private XML Storage module");
            return null;
        }

        StanzaNode? result_node = yield ((!) private_xml_module).retrieve(stream, get_node);
        if (result_node == null) return null;

        Set<Conference> ret = new HashSet<Conference>(Conference.hash_func, Conference.equals_func);
        StanzaNode? storage_node = result_node.get_subnode("storage", NS_URI);
        if (storage_node == null) return ret;
        Gee.List<StanzaNode> conferences_node = storage_node.get_subnodes("conference", NS_URI);
        foreach (StanzaNode conference_node in conferences_node) {
            Conference? conference = Bookmarks1Conference.create_from_stanza_node(conference_node);
            if (conference == null || conference.jid == null) continue;
            ret.add(conference);
        }
        return ret;
    }

    private async bool set_conferences(XmppStream stream, Set<Conference> conferences) {
        PrivateXmlStorage.Module? private_xml_module = stream.get_module<PrivateXmlStorage.Module>(PrivateXmlStorage.Module.IDENTITY);
        if (private_xml_module == null) {
            warning("Cannot store legacy bookmarks without Private XML Storage module");
            return false;
        }

        StanzaNode storage_node = (new StanzaNode.build("storage", NS_URI)).add_self_xmlns();
        foreach (Conference conference in conferences) {
            if (conference.jid == null) continue;
            Bookmarks1Conference? bookmarks1conference = conference as Bookmarks1Conference;
            if (bookmarks1conference != null) {
                storage_node.put_node(bookmarks1conference.stanza_node);
            } else {
                StanzaNode conference_node = new StanzaNode.build("conference", NS_URI)
                    .put_attribute("jid", conference.jid.to_string())
                    .put_attribute("autojoin", conference.autojoin ? "true" : "false");
                if (conference.name != null) {
                    conference_node.put_attribute("name", conference.name);
                }
                if (conference.nick != null) {
                    conference_node.put_node(new StanzaNode.build("nick", NS_URI)
                        .put_node(new StanzaNode.text(conference.nick)));
                }
                // TODO (?) Bookmarks 2 currently doesn't define a password
                storage_node.put_node(conference_node);
            }
        }
        bool stored = yield ((!) private_xml_module).store(stream, storage_node);
        if (!stored) return false;

        Module? bookmarks_module = stream.get_module<Module>(Module.IDENTITY);
        if (bookmarks_module != null) {
            ((!) bookmarks_module).received_conferences(stream, conferences);
        }
        return true;
    }

    public async bool add_conference(XmppStream stream, Conference conference) {
        Set<Conference>? conferences = yield get_conferences(stream);
        if (conferences == null) return false;
        conferences.add(conference);
        return yield set_conferences(stream, conferences);
    }

    public async bool replace_conference(XmppStream stream, Jid muc_jid, Conference modified_conference) {
        Set<Conference>? conferences = yield get_conferences(stream);
        if (conferences == null) return false;
        bool found = false;
        foreach (Conference conference in conferences) {
            if (conference.jid.equals(muc_jid)) {
                conference.autojoin = modified_conference.autojoin;
                conference.name = modified_conference.name;
                conference.nick = modified_conference.nick;
                conference.password = modified_conference.password;
                found = true;
            }
        }
        if (!found) return false;
        return yield set_conferences(stream, conferences);
    }

    public async bool remove_conference(XmppStream stream, Conference conference_remove) {
        Set<Conference>? conferences = yield get_conferences(stream);
        if (conferences == null) return false;
        conferences.remove(conference_remove);
        return yield set_conferences(stream, conferences);
    }

    public override void attach(XmppStream stream) { }

    public override void detach(XmppStream stream) { }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

}
