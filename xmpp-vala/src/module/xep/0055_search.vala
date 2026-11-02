using Gee;

namespace Xmpp.Xep.Search {

public const string NS_URI = "jabber:iq:search";

public class Module : XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0055_search_module");

    public override void attach(XmppStream stream) { }
    public override void detach(XmppStream stream) { }
    public override string get_ns() { return IDENTITY.ns; }
    public override string get_id() { return IDENTITY.id; }

    public async Form get_fields(XmppStream stream, Jid jid,
            Cancellable? cancellable = null) throws Error {
        var query = new StanzaNode.build("query", NS_URI).add_self_xmlns();
        var iq = new Iq.Stanza.get(query) { to = jid };
        Iq.Stanza response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                .send_iq_async(stream, iq, Priority.DEFAULT, cancellable);
        return new Form.from_query(get_result_query(response, jid));
    }

    public async Gee.List<Item> search(XmppStream stream, Jid jid, Form form,
            Cancellable? cancellable = null) throws Error {
        var iq = new Iq.Stanza.set(form.get_submit_query_node()) { to = jid };
        Iq.Stanza response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                .send_iq_async(stream, iq, Priority.DEFAULT, cancellable);
        return parse_results(get_result_query(response, jid));
    }

    private StanzaNode get_result_query(Iq.Stanza response, Jid jid) throws Error {
        if (response.from == null || !((!) response.from).equals(jid)) {
            throw new IOError.INVALID_DATA("Search response has an unexpected sender");
        }
        if (response.is_error()) {
            ErrorStanza? error = response.get_error();
            throw new IOError.FAILED("Search service returned %s".printf(
                    error != null ? ((!) error).condition : "unknown-error"));
        }
        StanzaNode? query = response.stanza.get_subnode("query", NS_URI);
        if (response.type_ != Iq.Stanza.TYPE_RESULT || query == null) {
            throw new IOError.INVALID_DATA("Search response has no search payload");
        }
        return (!) query;
    }

    private Gee.List<Item> parse_results(StanzaNode query) throws Error {
        var items = new ArrayList<Item>();
        StanzaNode? x = query.get_subnode("x", DataForms.NS_URI);
        if (x != null) {
            if (((!) x).get_attribute("type") != "result") {
                throw new IOError.INVALID_DATA("Search data form is not a result");
            }
            var result_form = new DataForms.DataForm.from_node((!) x);
            foreach (Gee.List<DataForms.DataForm.Field> item_fields in result_form.items) {
                Jid? item_jid = null;
                var fields = new HashMap<string, string>();
                foreach (DataForms.DataForm.Field field in item_fields) {
                    string? name = field.var;
                    var values = field.get_values();
                    if (name == null || values.is_empty) continue;
                    if (name == "jid") {
                        try {
                            item_jid = new Jid(values[0]);
                        } catch (InvalidJidError e) {
                            // Ignore an unusable record, preserving the remaining results.
                        }
                    } else {
                        fields[(!) name] = values[0];
                    }
                }
                if (item_jid == null) continue;
                items.add(new Item() { jid = (!) item_jid, fields = fields });
            }
            if (!result_form.items.is_empty && items.is_empty) {
                throw new IOError.INVALID_DATA("Search response contains no usable result records");
            }
            return items;
        }

        var legacy_records = query.get_subnodes("item", NS_URI);
        if (legacy_records.is_empty) {
            foreach (StanzaNode node in query.sub_nodes) {
                if (node.name != "#text" || (node.val != null && ((!) node.val).strip() != "")) {
                    throw new IOError.INVALID_DATA("Search response is not a legacy result list");
                }
            }
        }
        foreach (StanzaNode node in legacy_records) {
            string? address = node.get_attribute("jid");
            if (address == null) continue;
            Jid jid;
            try {
                jid = new Jid((!) address);
            } catch (InvalidJidError e) {
                continue;
            }
            var item = new Item() { jid = jid };
            foreach (StanzaNode field in node.sub_nodes) {
                if (field.ns_uri != NS_URI) continue;
                string? value = field.get_string_content();
                if (value != null) item.fields[field.name] = (!) value;
            }
            items.add(item);
        }
        if (!legacy_records.is_empty && items.is_empty) {
            throw new IOError.INVALID_DATA("Search response contains no usable result records");
        }
        // XEP-0055: an empty query is a successful search with no matches.
        return items;
    }
}

public class Form : DataForms.DataForm {
    public bool is_legacy_form { get; private set; default = false; }

    public Form.from_query(StanzaNode query) throws Error {
        StanzaNode? x = query.get_subnode("x", DataForms.NS_URI);
        base.from_node(x ?? new StanzaNode.build("x", DataForms.NS_URI)
                .add_self_xmlns().put_attribute("type", "form"));
        if (query.name != "query" || query.ns_uri != NS_URI) {
            throw new IOError.INVALID_DATA("Invalid search form payload");
        }
        if (x != null) {
            if (((!) x).get_attribute("type") != "form") {
                throw new IOError.INVALID_DATA("Search data form is not a form");
            }
            return;
        }

        is_legacy_form = true;
        instructions = query.get_deep_string_content("instructions");
        foreach (StanzaNode node in query.sub_nodes) {
            if (node.ns_uri != NS_URI || !is_legacy_field(node.name)) continue;
            var field_node = new StanzaNode.build("field", DataForms.NS_URI)
                    .put_attribute("var", node.name)
                    .put_attribute("type", "text-single");
            string? value = node.get_string_content();
            if (value != null && value != "") {
                field_node.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                        .put_node(new StanzaNode.text((!) value)));
            }
            add_field(new DataForms.DataForm.TextSingleField(field_node));
        }
        if (fields.is_empty) {
            throw new IOError.INVALID_DATA("Search service returned no search fields");
        }
    }

    public StanzaNode get_submit_query_node() throws Error {
        if (!get_missing_required_fields().is_empty) {
            throw new IOError.INVALID_ARGUMENT("Required search fields are missing");
        }
        var query = new StanzaNode.build("query", NS_URI).add_self_xmlns();
        if (is_legacy_form) {
            foreach (DataForms.DataForm.Field field in fields) {
                string? name = field.var;
                if (name == null || !is_legacy_field((!) name)) continue;
                string value = field.get_value_string();
                if (value == "") continue;
                query.put_node(new StanzaNode.build((!) name, NS_URI)
                        .put_node(new StanzaNode.text(value)));
            }
            return query;
        }

        // Build a value-only submit without mutating the service's form schema.
        var submit = new StanzaNode.build("x", DataForms.NS_URI)
                .add_self_xmlns().put_attribute("type", "submit");
        if (form_type != null) {
            var form_type_node = new StanzaNode.build("field", DataForms.NS_URI)
                    .put_attribute("var", "FORM_TYPE").put_attribute("type", "hidden");
            form_type_node.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text((!) form_type)));
            submit.put_node(form_type_node);
        }
        foreach (DataForms.DataForm.Field field in fields) {
            if (field.var == null || field.type_ == DataForms.DataForm.Type.FIXED) continue;
            var node = new StanzaNode.build("field", DataForms.NS_URI)
                    .put_attribute("var", (!) field.var);
            if (field.type_ == DataForms.DataForm.Type.HIDDEN) {
                node.put_attribute("type", "hidden");
            }
            var values = field.get_values();
            if (field.type_ == DataForms.DataForm.Type.BOOLEAN && values.is_empty) {
                values.add("0");
            }
            foreach (string value in values) {
                node.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                        .put_node(new StanzaNode.text(value)));
            }
            submit.put_node(node);
        }
        query.put_node(submit);
        return query;
    }

    private static bool is_legacy_field(string name) {
        return name == "first" || name == "last" || name == "nick" || name == "email";
    }
}

public class Item {
    public Jid jid;
    public HashMap<string, string> fields = new HashMap<string, string>();
}

}
