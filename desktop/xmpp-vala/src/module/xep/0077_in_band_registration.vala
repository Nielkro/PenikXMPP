using Gee;

namespace Xmpp.Xep.InBandRegistration {

public const string NS_URI = "jabber:iq:register";
public const string NS_URI_PARS = "urn:xmpp:pars:0";
public const string NS_URI_IBR_TOKEN = "urn:xmpp:ibr-token:0";
public const string NS_URI_INVITE_LEGACY = "urn:xmpp:invite";
public const string ERROR_NO_RESPONSE = "no-response";
public const string ERROR_INVALID_RESPONSE = "invalid-response";

public class Module : XmppStreamNegotiationModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0077_in_band_registration");

    public async Form? get_from_server(XmppStream stream, Jid jid) {
        string? error;
        return yield get_from_server_with_error(stream, jid, out error);
    }

    public async Form? get_from_server_with_error(XmppStream stream, Jid jid, out string? error) {
        error = null;
        StanzaNode query_node = new StanzaNode.build("query", NS_URI).add_self_xmlns();
        Iq.Stanza request_form_iq = new Iq.Stanza.get(query_node) { to=jid };
        request_form_iq.to = jid;

        Iq.Stanza iq_result;
        try {
            iq_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, request_form_iq);
        } catch (GLib.Error e) {
            warning("Failed to get registration form: %s", e.message);
            error = ERROR_NO_RESPONSE;
            return null;
        }
        if (iq_result.from != null && !((!) iq_result.from).equals(jid)) {
            error = ERROR_INVALID_RESPONSE;
            return null;
        }
        if (iq_result.is_error()) {
            ErrorStanza? stanza_error = iq_result.get_error();
            error = stanza_error != null ? ((!) stanza_error).condition : ERROR_INVALID_RESPONSE;
            return null;
        }
        if (iq_result.type_ != Iq.Stanza.TYPE_RESULT || iq_result.stanza.get_subnode("query", NS_URI) == null) {
            error = ERROR_INVALID_RESPONSE;
            return null;
        }
        return new Form.from_node(iq_result);
    }

    public bool supports_preauth(XmppStream stream) {
        return stream.features.get_subnode("register", NS_URI_IBR_TOKEN) != null ||
                stream.features.get_subnode("register", NS_URI_INVITE_LEGACY) != null;
    }

    public async string? preauthorize_registration(XmppStream stream, Jid jid, string token) {
        StanzaNode preauth_node = new StanzaNode.build("preauth", NS_URI_PARS)
                .add_self_xmlns()
                .put_attribute("token", token);
        Iq.Stanza iq = new Iq.Stanza.set(preauth_node) { to=jid.domain_jid };

        Iq.Stanza iq_result;
        try {
            iq_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        } catch (GLib.Error e) {
            warning("Failed to preauthorize registration: %s", e.message);
            return e.message;
        }
        if (iq_result.is_error()) {
            ErrorStanza? error_stanza = iq_result.get_error();
            return error_stanza.text ?? "Error";
        }

        return null;
    }

    public async string? submit_to_server(XmppStream stream, Jid jid, Form form) {
        StanzaNode query_node = form.get_submit_query_node();
        Iq.Stanza iq = new Iq.Stanza.set(query_node) { to=jid };

        Iq.Stanza iq_result;
        try {
            iq_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        } catch (GLib.Error e) {
            warning("Failed to submit registration form: %s", e.message);
            return e.message;
        }
        if (iq_result.is_error()) {
            ErrorStanza? error_stanza = iq_result.get_error();
            return error_stanza.text ?? "Error";
        }

        return null;
    }

    public async ErrorStanza? change_password(XmppStream stream, Jid jid, string new_pw) throws Error {
        if (new_pw == "") {
            throw new IOError.INVALID_ARGUMENT("Password change requires a non-empty password");
        }
        Jid target_server = jid.domain_jid;
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        bool allow_home_server_reply = stream.negotiation_complete && bind != null &&
                ((!) bind).my_jid != null && ((!) bind).my_jid.equals_bare(jid) &&
                stream.remote_name.equals(target_server);
        StanzaNode pw_change_node = new StanzaNode.build("query", NS_URI).add_self_xmlns();
        StanzaNode username_node = new StanzaNode.build("username", NS_URI);
        StanzaNode pw_node = new StanzaNode.build("password", NS_URI);
        username_node.put_node(new StanzaNode.text(jid.localpart));
        pw_node.put_node(new StanzaNode.text(new_pw));
        pw_change_node.put_node(username_node);
        pw_change_node.put_node(pw_node);
        Iq.Stanza set_password_iq = new Iq.Stanza.set(pw_change_node) { to=target_server };

        Iq.Stanza chpw_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                .send_iq_async(stream, set_password_iq);
        string? from = chpw_result.stanza.get_attribute("from");
        if (from != null) {
            if (!new Jid((!) from).equals(target_server)) {
                throw new IOError.INVALID_DATA("Password change response has an unexpected sender");
            }
        } else {
            // XEP-0077 permits an empty result without a from attribute from
            // the authenticated home server, not from an arbitrary service.
            if (!allow_home_server_reply) {
                throw new IOError.INVALID_DATA("Password change response has no verified home-server sender");
            }
        }
        if (chpw_result.is_error()) {
            ErrorStanza? error = chpw_result.get_error();
            if (error == null) {
                throw new IOError.INVALID_DATA("Password change response has no error condition");
            }
            return error;
        }
        if (chpw_result.type_ != Iq.Stanza.TYPE_RESULT) {
            throw new IOError.INVALID_DATA("Password change was not confirmed by the server");
        }

        return null;
    }

    // XEP-0077 §3.2: Cancel registration (delete account from server)
    public async string? cancel_registration(XmppStream stream) {
        StanzaNode query_node = new StanzaNode.build("query", NS_URI).add_self_xmlns();
        query_node.put_node(new StanzaNode.build("remove", NS_URI));
        Iq.Stanza iq = new Iq.Stanza.set(query_node);

        Iq.Stanza iq_result;
        try {
            iq_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        } catch (GLib.Error e) {
            warning("Failed to cancel registration: %s", e.message);
            return e.message;
        }
        if (!iq_result.is_error()) return null;

        ErrorStanza? error_stanza = iq_result.get_error();
        if (error_stanza == null) return "unknown-error";

        string description = ((!) error_stanza).condition;
        string? error_text = ((!) error_stanza).text;
        if (error_text != null && ((!) error_text).strip() != "") {
            description += ": " + ((!) error_text).strip();
        }
        return description;
    }

    public override bool mandatory_outstanding(XmppStream stream) { return false; }

    public override bool negotiation_active(XmppStream stream) { return false; }

    public override void attach(XmppStream stream) { }

    public override void detach(XmppStream stream) { }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

public class Form : DataForms.DataForm {
    public string? oob = null;
    public bool is_legacy_form { get; private set; default = false; }

    public Form.from_node(Iq.Stanza iq) {
        StanzaNode? query_node = iq.stanza.get_deep_subnode(NS_URI + ":query");
        StanzaNode? x_node = query_node != null ? ((!) query_node).get_subnode("x", DataForms.NS_URI) : null;
        base.from_node(x_node ?? new StanzaNode.build("x", DataForms.NS_URI).add_self_xmlns().put_attribute("type", "form"));

        oob = iq.stanza.get_deep_string_content(NS_URI + ":query", "jabber:x:oob:x", "url");
        if (query_node != null && x_node == null) {
            parse_legacy_query((!) query_node);
        }
    }

    public StanzaNode get_submit_query_node() {
        StanzaNode query_node = new StanzaNode.build("query", NS_URI).add_self_xmlns();
        if (!is_legacy_form) {
            query_node.put_node(get_submit_node());
            return query_node;
        }

        foreach (DataForms.DataForm.Field field in fields) {
            if (field.var == null || field.type_ == DataForms.DataForm.Type.FIXED || field.type_ == DataForms.DataForm.Type.HIDDEN) continue;
            StanzaNode field_node = new StanzaNode.build((!) field.var, NS_URI);
            string value = field.get_value_string();
            if (value != "") field_node.put_node(new StanzaNode.text(value));
            query_node.put_node(field_node);
        }
        return query_node;
    }

    private void parse_legacy_query(StanzaNode query_node) {
        is_legacy_form = true;

        string? instructions_text = query_node.get_deep_string_content("instructions");
        if (instructions_text != null && instructions_text != "") {
            instructions = instructions_text;
        }

        foreach (StanzaNode node in query_node.get_all_subnodes()) {
            if (node.ns_uri != NS_URI || !is_legacy_registration_field(node.name)) continue;

            string field_type = node.name == "password" ? "text-private" : "text-single";
            string label = legacy_registration_label(node.name);
            StanzaNode field_node = new StanzaNode.build("field", DataForms.NS_URI)
                    .put_attribute("var", node.name)
                    .put_attribute("label", label)
                    .put_attribute("type", field_type);
            string? value = node.get_string_content();
            if (value != null && value != "") {
                field_node.put_node(new StanzaNode.build("value", DataForms.NS_URI).put_node(new StanzaNode.text((!) value)));
            }

            if (node.name == "password") {
                add_field(new DataForms.DataForm.TextPrivateField(field_node));
            } else {
                add_field(new DataForms.DataForm.TextSingleField(field_node));
            }
        }
    }

    private static bool is_legacy_registration_field(string name) {
        switch (name) {
            case "username":
            case "nick":
            case "password":
            case "name":
            case "first":
            case "last":
            case "email":
            case "address":
            case "city":
            case "state":
            case "zip":
            case "phone":
            case "url":
            case "date":
            case "misc":
            case "text":
            case "key":
                return true;
            default:
                return false;
        }
    }

    private static string legacy_registration_label(string name) {
        switch (name) {
            case "username": return "Username";
            case "nick": return "Nickname";
            case "password": return "Password";
            case "name": return "Name";
            case "first": return "First name";
            case "last": return "Last name";
            case "email": return "Email";
            case "address": return "Address";
            case "city": return "City";
            case "state": return "State";
            case "zip": return "ZIP";
            case "phone": return "Phone";
            case "url": return "URL";
            case "date": return "Date";
            case "misc": return "Miscellaneous";
            case "text": return "Text";
            case "key": return "Key";
            default: return name;
        }
    }
}

}
