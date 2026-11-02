using Gee;

namespace Dino {

public enum XmppUriKind {
    CHAT,
    MUC,
    REGISTER,
    PUBSUB,
    UNKNOWN
}

public class XmppUriInfo : Object {
    public string jid { get; private set; }
    public string query { get; private set; }
    public XmppUriKind kind { get; private set; }
    public Gee.Map<string, string> options { get; private set; }

    public bool has_preauth {
        get { return options.has_key("preauth") && options["preauth"] != ""; }
    }

    public XmppUriInfo(string jid, string query, XmppUriKind kind, Gee.Map<string, string> options) {
        this.jid = jid;
        this.query = query;
        this.kind = kind;
        this.options = options;
    }
}

public XmppUriInfo? parse_xmpp_uri(string uri) {
    if (!uri.has_prefix("xmpp:")) return null;
    if (!uri.contains(":")) return null;

    string raw = uri.split(":", 2)[1];
    string[] parts = raw.split("?", 2);
    string jid = parts[0];
    while (jid.length > 0 && jid[0] == '/') {
        jid = jid.substring(1);
    }

    string? decoded_jid = Uri.unescape_string(jid);
    if (decoded_jid == null || decoded_jid == "") return null;

    try {
        decoded_jid = new Xmpp.Jid(decoded_jid).to_string();
    } catch (Xmpp.InvalidJidError e) {
        return null;
    }

    string query = "message";
    Gee.Map<string, string> options = new Gee.HashMap<string, string>();
    if (parts.length == 2) {
        string[] commands = parts[1].split(";");
        if (commands.length > 0 && commands[0] != "") {
            query = commands[0];
        }
        for (int i = 1; i < commands.length; i++) {
            string[] option = commands[i].split("=", 2);
            string? key = Uri.unescape_string(option[0]);
            if (key == null || key == "") continue;
            string? value = "";
            if (option.length == 2) {
                value = Uri.unescape_string(option[1]);
                if (value == null) return null;
            }
            options[key] = value;
        }
    }

    return new XmppUriInfo(decoded_jid, query, classify_xmpp_uri_query(query), options);
}

private XmppUriKind classify_xmpp_uri_query(string query) {
    switch (query) {
        case "message":
        case "roster":
            return XmppUriKind.CHAT;
        case "join":
            return XmppUriKind.MUC;
        case "register":
            return XmppUriKind.REGISTER;
        case "pubsub":
            return XmppUriKind.PUBSUB;
        default:
            return XmppUriKind.UNKNOWN;
    }
}

}
