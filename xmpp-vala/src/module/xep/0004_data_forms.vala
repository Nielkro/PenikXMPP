using Gee;

namespace Xmpp.Xep.DataForms {

public const string NS_URI = "jabber:x:data";

public class DataForm {

    public StanzaNode stanza_node { get; set; }
    public Gee.List<Field> fields = new ArrayList<Field>();
    public Gee.List<Field> reported_fields = new ArrayList<Field>();
    private Gee.Map<string, Gee.List<string>> baseline_values = new HashMap<string, Gee.List<string>>();
    public string? form_type = null;
    public string? instructions = null;
    public string? title = null;
    public string kind {
        owned get { return stanza_node.get_attribute("type", NS_URI) ?? "form"; }
    }
    public bool is_result { get { return kind == "result"; } }

    public StanzaNode get_submit_node() {
        stanza_node.set_attribute("type", "submit");
        return stanza_node;
    }

    /**
     * Returns whether the current value of a field differs semantically from
     * the value received with the form. Boolean spellings are normalized and
     * JID multi-value fields are compared without regard to ordering.
     */
    public bool has_changed_field(string var_name) {
        if (var_name == "FORM_TYPE") {
            bool had_baseline = baseline_values.has_key(var_name);
            Gee.List<string>? current_values = get_effective_form_type_values();
            bool has_current = current_values != null;
            if (had_baseline != has_current) return true;
            if (!has_current) return false;
            return !values_equal(Type.HIDDEN, (!) current_values, Type.HIDDEN,
                    (!) baseline_values.get(var_name));
        }

        Field? field = get_field_by_var(var_name);
        bool had_baseline = baseline_values.has_key(var_name);
        if (field == null) return had_baseline;
        if (!had_baseline) return true;

        return !values_equal(field.type_, field.get_values(), field.type_,
                (!) baseline_values.get(var_name));
    }

    /** Returns changed field vars in form order. */
    public Gee.List<string> get_changed_field_vars() {
        var changed = new ArrayList<string>();
        var seen = new HashSet<string>();

        if (has_changed_field("FORM_TYPE")) {
            changed.add("FORM_TYPE");
            seen.add("FORM_TYPE");
        }

        foreach (Field field in fields) {
            string? var_name = field.var;
            if (var_name == null || !seen.add(var_name)) continue;
            if (has_changed_field(var_name)) changed.add(var_name);
        }

        // Keep removals observable even though a removed field cannot be
        // represented in a value-only submit without its field metadata.
        foreach (string var_name in baseline_values.keys) {
            if (!seen.add(var_name)) continue;
            if (has_changed_field(var_name)) changed.add(var_name);
        }
        return changed;
    }

    /**
     * Builds a canonical XEP-0004 delta submission. It deliberately does not
     * mutate or reuse the server-provided form node. Only FORM_TYPE/hidden,
     * required and actually changed non-fixed fields are submitted, and field
     * presentation metadata is omitted.
     */
    public StanzaNode get_delta_submit_node() {
        var submit = new StanzaNode.build("x", NS_URI).add_self_xmlns();
        submit.set_attribute("type", "submit");

        Gee.List<string>? effective_form_type =
            get_effective_form_type_values();
        if (effective_form_type != null) {
            var form_type_field = new StanzaNode.build("field", NS_URI)
                    .put_attribute("var", "FORM_TYPE")
                    .put_attribute("type", "hidden");
            put_values(form_type_field, (!) effective_form_type);
            submit.put_node(form_type_field);
        }

        var submitted_vars = new HashSet<string>();
        if (effective_form_type != null) submitted_vars.add("FORM_TYPE");
        foreach (Field field in fields) {
            string? var_name = field.var;
            if (var_name == null || !submitted_vars.add(var_name)) continue;
            if (field.type_ == Type.FIXED) continue;
            if (field.type_ != Type.HIDDEN && !field.required && !has_changed_field(var_name)) continue;

            var submit_field = new StanzaNode.build("field", NS_URI)
                    .put_attribute("var", var_name);
            if (field.type_ == Type.HIDDEN) {
                submit_field.put_attribute("type", "hidden");
            }
            put_values(submit_field, get_submission_values(field));
            submit.put_node(submit_field);
        }
        return submit;
    }

    /**
     * Compares selected current values with a freshly fetched server form.
     * The comparison is semantic for booleans and JID multi-value fields.
     */
    public bool matches_field_values(DataForm other, Gee.Collection<string> vars) {
        foreach (string var_name in vars) {
            if (var_name == "FORM_TYPE") {
                Gee.List<string>? own_values =
                    get_effective_form_type_values();
                Gee.List<string>? other_values =
                    other.get_effective_form_type_values();
                if (own_values == null || other_values == null) {
                    if (own_values != other_values) return false;
                    continue;
                }
                if (!values_equal(Type.HIDDEN, (!) own_values, Type.HIDDEN,
                        (!) other_values)) return false;
                continue;
            }

            Field? field = get_field_by_var(var_name);
            Field? other_field = other.get_field_by_var(var_name);
            if (field == null || other_field == null) return false;
            if (!values_equal(field.type_, field.get_values(), other_field.type_,
                    other_field.get_values())) return false;
        }
        return true;
    }

    /** Accepts all current values as the new change-detection baseline. */
    public void accept_current_values() {
        baseline_values.clear();
        Gee.List<string>? effective_form_type =
            get_effective_form_type_values();
        if (effective_form_type != null) {
            baseline_values.set("FORM_TYPE",
                copy_values((!) effective_form_type));
        }
        foreach (Field field in fields) {
            string? var_name = field.var;
            if (var_name == null || baseline_values.has_key(var_name)) continue;
            baseline_values.set(var_name, copy_values(field.get_values()));
        }
    }

    /**
     * Replace a successfully submitted form with the authoritative form
     * returned by the server. Values, field types, required markers and
     * options may all change between SET and GET; retaining any part of the
     * pre-submit schema would make a later delta capable of resubmitting stale
     * values. Callers that keep the form open must rebuild their field views.
     */
    public void accept_server_roundtrip(DataForm server_form) {
        stanza_node = server_form.stanza_node;
        fields = server_form.fields;
        reported_fields = server_form.reported_fields;
        items = server_form.items;
        form_type = server_form.form_type;
        instructions = server_form.instructions;
        title = server_form.title;
        accept_current_values();
    }

    private Field? get_field_by_var(string var_name) {
        foreach (Field field in fields) {
            if (field.var == var_name) return field;
        }
        return null;
    }

    private Gee.List<string> form_type_values() {
        var values = new ArrayList<string>();
        if (form_type != null) values.add((!) form_type);
        return values;
    }

    private Gee.List<string>? get_effective_form_type_values() {
        if (form_type != null) return form_type_values();
        Field? explicit_field = get_field_by_var("FORM_TYPE");
        return explicit_field != null ? ((!) explicit_field).get_values() : null;
    }

    private static Gee.List<string> copy_values(Gee.Collection<string> values) {
        var copy = new ArrayList<string>();
        foreach (string value in values) copy.add(value);
        return copy;
    }

    private static void put_values(StanzaNode field_node, Gee.Collection<string> values) {
        foreach (string value in values) {
            field_node.put_node(new StanzaNode.build("value", NS_URI)
                    .put_node(new StanzaNode.text(value)));
        }
    }

    private static Gee.List<string> get_submission_values(Field field) {
        Gee.List<string> values = field.get_values();
        // XEP-0004 defines false as the default for an empty boolean field.
        // A required submit must still carry that effective value explicitly
        // so the receiver cannot interpret the field as absent/unset.
        if (field.type_ == Type.BOOLEAN && values.is_empty) {
            values.add("0");
        }
        return values;
    }

    private static bool values_equal(Type? left_type, Gee.List<string> left,
            Type? right_type, Gee.List<string> right) {
        if (left_type == Type.BOOLEAN || right_type == Type.BOOLEAN) {
            return normalize_boolean(left) == normalize_boolean(right);
        }
        if (is_unordered_multi_type(left_type) ||
                is_unordered_multi_type(right_type)) {
            var left_set = new HashSet<string>();
            var right_set = new HashSet<string>();
            left_set.add_all(left);
            right_set.add_all(right);
            if (left_set.size != right_set.size) return false;
            foreach (string value in left_set) {
                if (!right_set.contains(value)) return false;
            }
            return true;
        }
        if (left.size != right.size) return false;
        for (int i = 0; i < left.size; i++) {
            if (left[i] != right[i]) return false;
        }
        return true;
    }

    private static bool is_unordered_multi_type(Type? type) {
        // XEP-0004 requires list-multi selections to retain the order in which
        // the options were received because that order may be significant.
        // JID-multi is a set of unique addresses, so only that type is
        // deliberately order-insensitive here.
        return type == Type.JID_MULTI;
    }

    private static string normalize_boolean(Gee.List<string> values) {
        if (values.size == 0) return "0";
        string value = values[0].down();
        if (value == "1" || value == "true") return "1";
        if (value == "0" || value == "false" || value == "") return "0";
        return value;
    }

    public enum Type {
        BOOLEAN,
        FIXED,
        HIDDEN,
        JID_MULTI,
        LIST_SINGLE,
        LIST_MULTI,
        TEXT_PRIVATE,
        TEXT_MULTI,
        TEXT_SINGLE,
    }

    public class Option {
        public string label { get; set; }
        public string value { get; set; }

        public Option(string label, string value) {
            this.label = label;
            this.value = value;
        }
    }

    public class Field : Object {
        public StanzaNode node { get; set; }
        public string? label {
            get { return node.get_attribute("label", NS_URI); }
            set { node.set_attribute("label", value); }
        }
        public Type? type_ = null;
        public string? description {
            owned get {
                StanzaNode? desc_node = node.get_subnode("desc", NS_URI);
                return desc_node != null ? desc_node.get_string_content() : null;
            }
        }
        public bool required {
            get { return node.get_subnode("required", NS_URI) != null; }
        }
        public string? var {
            get { return node.get_attribute("var", NS_URI); }
            set { node.set_attribute("var", value); }
        }

        public Field() {
            this.node = new StanzaNode.build("field", NS_URI);
        }

        public Field.from_node(StanzaNode node) {
            this.node = node;
        }

        public Gee.List<string> get_values() {
            Gee.List<string> ret = new ArrayList<string>();
            Gee.List<StanzaNode> value_nodes = node.get_subnodes("value", NS_URI);
            foreach (StanzaNode node in value_nodes) {
                ret.add(node.get_string_content() ?? "");
            }
            return ret;
        }

        public string get_value_string() {
            Gee.List<string> values = get_values();
            return values.size > 0 ? values[0] : "";
        }

        public void set_value_string(string val) {
            StanzaNode? value_node = node.get_subnode("value", NS_URI);
            if (value_node == null) {
                value_node = new StanzaNode.build("value", NS_URI);
                node.put_node(value_node);
            }
            value_node.sub_nodes.clear();
            value_node.put_node(new StanzaNode.text(val));
        }

        public void set_values(Gee.List<string> values) {
            Gee.List<StanzaNode> value_nodes = node.get_subnodes("value", NS_URI);
            foreach (StanzaNode value_node in value_nodes) {
                node.sub_nodes.remove(value_node);
            }
            foreach (string val in values) {
                if (val == null) continue;
                node.put_node(new StanzaNode.build("value", NS_URI).put_node(new StanzaNode.text(val)));
            }
        }

        public bool has_value() {
            foreach (string value in get_values()) {
                if (value != "") return true;
            }
            return false;
        }

        internal Gee.List<Option>? get_options() {
            Gee.List<Option> ret = new ArrayList<Option>();
            Gee.List<StanzaNode> option_nodes = node.get_subnodes("option", NS_URI);
            foreach (StanzaNode node in option_nodes) {
                StanzaNode? value_node = node.get_subnode("value");
                if (value_node == null) continue;
                string value = value_node.get_string_content() ?? "";
                string label = node.get_attribute("label", NS_URI) ?? value;
                Option option = new Option(label, value);
                ret.add(option);
            }
            return ret;
        }

        public string? get_media_uri() {
            StanzaNode? media_node = node.get_subnode("media", "urn:xmpp:media-element");
            if (media_node != null) {
                StanzaNode? uri_node = media_node.get_subnode("uri", "urn:xmpp:media-element");
                if (uri_node != null) {
                    return uri_node.get_string_content();
                }
            }
            return null;
        }
    }

    public class BooleanField : Field {
        public bool value {
            get {
                string serialized = get_value_string().down();
                return serialized == "1" || serialized == "true";
            }
            set { set_value_string(value ? "1" : "0"); }
        }
        public BooleanField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.BOOLEAN;
        }
    }

    public class FixedField : Field {
        public string value {
            owned get { return get_value_string(); }
            set { set_value_string(value); }
        }
        public FixedField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.FIXED;
        }
    }

    public class HiddenField : Field {
        public HiddenField() {
            base();
            type_ = Type.HIDDEN;
            node.put_attribute("type", "hidden");
        }
        public HiddenField.from_node(StanzaNode node) {
            base.from_node(node);
            type_ = Type.HIDDEN;
        }
    }

    public class JidMultiField : Field {
        public Gee.List<Option> options { owned get { return get_options(); } }
        public Gee.List<string> value {
            owned get { return get_values(); }
            set { set_values(value); }
        }
        public JidMultiField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.JID_MULTI;
        }
    }

    public class ListSingleField : Field {
        public Gee.List<Option> options { owned get { return get_options(); } }
        public string value {
            owned get { return get_value_string(); }
            set { set_value_string(value); }
        }
        public ListSingleField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.LIST_SINGLE;
            node.set_attribute("type", "list-single");
        }
    }

    public class ListMultiField : Field {
        public Gee.List<Option> options { owned get { return get_options(); } }
        public Gee.List<string> value {
            owned get { return get_values(); }
            set { set_values(value); }
        }
        public ListMultiField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.LIST_MULTI;
        }
    }

    public class TextMultiField : Field {
        public Gee.List<string> value {
            owned get { return get_values(); }
            set { set_values(value); }
        }
        public TextMultiField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.TEXT_MULTI;
        }
    }

    public class TextPrivateField : Field {
        public string value {
            owned get { return get_value_string(); }
            set { set_value_string(value); }
        }
        public TextPrivateField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.TEXT_PRIVATE;
        }
    }

    public class TextSingleField : Field {
        public string value {
            owned get { return get_value_string(); }
            set { set_value_string(value); }
        }
        public TextSingleField(StanzaNode node) {
            base.from_node(node);
            type_ = Type.TEXT_SINGLE;
        }
    }

    // TODO text-multi

    public Gee.List<Gee.List<Field>> items = new ArrayList<Gee.List<Field>>();

    internal DataForm.from_node(StanzaNode node) {
        this.stanza_node = node;

        Gee.List<StanzaNode> field_nodes = node.get_subnodes("field", NS_URI);
        foreach (StanzaNode field_node in field_nodes) {
            parse_field(field_node, fields);
        }

        StanzaNode? reported_node = node.get_subnode("reported", NS_URI);
        if (reported_node != null) {
            foreach (StanzaNode field_node in reported_node.get_subnodes("field", NS_URI)) {
                parse_field(field_node, reported_fields);
            }
        }

        Gee.List<StanzaNode> item_nodes = node.get_subnodes("item", NS_URI);
        foreach (StanzaNode item_node in item_nodes) {
            var item_fields = new ArrayList<Field>();
            Gee.List<StanzaNode> item_field_nodes = item_node.get_subnodes("field", NS_URI);
            foreach (StanzaNode field_node in item_field_nodes) {
                inherit_reported_field_metadata(field_node);
                parse_field(field_node, item_fields);
            }
            items.add(item_fields);
        }

        StanzaNode? instructions_node = node.get_subnode("instructions", NS_URI);
        if (instructions_node != null) {
            instructions = instructions_node.get_string_content();
        }

        StanzaNode? title_node = node.get_subnode("title", NS_URI);
        if (title_node != null) {
            title = title_node.get_string_content();
        }

        accept_current_values();
    }

    private void inherit_reported_field_metadata(StanzaNode item_field_node) {
        string? item_var = item_field_node.get_attribute("var", NS_URI);
        if (item_var == null) return;

        foreach (Field reported_field in reported_fields) {
            if (reported_field.var != item_var) continue;
            if (item_field_node.get_attribute("type", NS_URI) == null) {
                string? reported_type = reported_field.node.get_attribute("type", NS_URI);
                if (reported_type != null) item_field_node.put_attribute("type", reported_type);
            }
            if (item_field_node.get_attribute("label", NS_URI) == null && reported_field.label != null) {
                item_field_node.put_attribute("label", reported_field.label);
            }
            break;
        }
    }

    private void parse_field(StanzaNode field_node, Gee.List<Field> target_list) {
        string? type = field_node.get_attribute("type", NS_URI);
        // If type is missing, it's text-single by default usually, or we infer?
        // For items, type might be missing.
        if (type == null) type = "text-single"; 

        switch (type) {
            case "boolean":
                target_list.add(new BooleanField(field_node)); break;
            case "fixed":
                target_list.add(new FixedField(field_node)); break;
            case "hidden":
                HiddenField field = new HiddenField.from_node(field_node);
                if (field.var == "FORM_TYPE") {
                    this.form_type = field.get_value_string();
                    break;
                }
                target_list.add(field); break;
            case "jid-multi":
                target_list.add(new JidMultiField(field_node)); break;
            case "list-single":
                target_list.add(new ListSingleField(field_node)); break;
            case "list-multi":
                target_list.add(new ListMultiField(field_node)); break;
            case "text-multi":
                target_list.add(new TextMultiField(field_node)); break;
            case "text-private":
                target_list.add(new TextPrivateField(field_node)); break;
            case "text-single":
                target_list.add(new TextSingleField(field_node)); break;
            case "jid-single": // Add jid-single support as it's common in search results
                target_list.add(new TextSingleField(field_node)); break; 
            default:
                target_list.add(new TextSingleField(field_node)); break;
        }
    }

    public DataForm(string type = "form") {
        this.stanza_node = new StanzaNode.build("x", NS_URI).add_self_xmlns();
        this.stanza_node.set_attribute("type", type);
    }

    public static DataForm? create_from_node(StanzaNode node) {
        return new DataForm.from_node(node);
    }

    public void add_field(Field field) {
        fields.add(field);
        stanza_node.put_node(field.node);
    }

    public Gee.List<Field> get_missing_required_fields() {
        var missing = new ArrayList<Field>();
        foreach (Field field in fields) {
            if (field.required && field.type_ != Type.BOOLEAN &&
                    !field.has_value()) missing.add(field);
        }
        return missing;
    }

    public string? get_error_message() {
        foreach (Field field in fields) {
            if (field.var != "error") continue;

            var message = new StringBuilder();
            foreach (string value in field.get_values()) {
                if (value == "") continue;
                if (message.len > 0) message.append_c('\n');
                message.append(value);
            }
            if (message.len > 0) return message.str;
        }
        return null;
    }
}

}
