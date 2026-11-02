using Gee;

namespace Xmpp.Roster {

public class Item {

    public const string SUBSCRIPTION_NONE = "none";
    /** the user has a subscription to the contact's presence, but the contact does not have a subscription to the user's presence */
    public const string SUBSCRIPTION_TO = "to";
    /** the contact has a subscription to the user's presence, but the user does not have a subscription to the contact's presence */
    public const string SUBSCRIPTION_FROM = "from";
    public const string SUBSCRIPTION_BOTH = "both";
    public const string SUBSCRIPTION_REMOVE = "remove";

    public StanzaNode stanza_node;

    private Jid jid_;
    public Jid? jid {
        get {
            try {
                return jid_ ?? (jid_ = new Jid(stanza_node.get_attribute("jid")));
            } catch (InvalidJidError e) {
                warning("Ignoring invalid Jid in roster entry: %s", e.message);
                return null;
            }
        }
        set { stanza_node.set_attribute("jid", value.to_string()); }
    }

    public string? name {
        get { return stanza_node.get_attribute("name"); }
        set { set_optional_attribute("name", value); }
    }

    public string? subscription {
        get { return stanza_node.get_attribute("subscription"); }
        set { set_optional_attribute("subscription", value); }
    }

    public string? ask {
        get { return stanza_node.get_attribute("ask"); }
    }

    public Gee.List<string> groups {
        owned get {
            var ret = new ArrayList<string>();
            foreach (StanzaNode group_node in stanza_node.sub_nodes) {
                if (group_node.name != "group") continue;

                string? group = group_node.get_string_content();
                if (group != null && group != "") {
                    ret.add(group);
                }
            }
            return ret;
        }
        set { replace_groups(value); }
    }

    public bool subscription_requested {
        get { return this.ask != null; }
    }

    public Item() {
        stanza_node = new StanzaNode.build("item", NS_URI);
    }

    public Item.from_stanza_node(StanzaNode stanza_node) {
        this.stanza_node = stanza_node;
    }

    public void replace_groups(Collection<string> groups) {
        var old_group_nodes = new ArrayList<StanzaNode>();
        foreach (StanzaNode node in stanza_node.sub_nodes) {
            if (node.name == "group") {
                old_group_nodes.add(node);
            }
        }
        foreach (StanzaNode node in old_group_nodes) {
            stanza_node.sub_nodes.remove(node);
        }

        foreach (string group in groups) {
            if (group == "") continue;

            stanza_node.put_node(new StanzaNode.build("group", NS_URI)
                .put_node(new StanzaNode.text(group)));
        }
    }

    private void set_optional_attribute(string name, string? value) {
        if (value != null) {
            stanza_node.set_attribute(name, value);
            return;
        }

        var old_attributes = new ArrayList<StanzaAttribute>();
        foreach (StanzaAttribute attr in stanza_node.attributes) {
            if (attr.ns_uri == stanza_node.ns_uri && attr.name == name) {
                old_attributes.add(attr);
            }
        }
        foreach (StanzaAttribute attr in old_attributes) {
            stanza_node.attributes.remove(attr);
        }
    }
}

}
