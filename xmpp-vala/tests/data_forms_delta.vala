using Xmpp;
using Xmpp.Xep;
using Gee;

namespace Xmpp.Test {

class DataFormsDeltaTest : Gee.TestCase {

    public DataFormsDeltaTest() {
        base("DataFormsDelta");
        add_test("baseline_scalar_changes", test_baseline_scalar_changes);
        add_test("multi_value_semantics", test_multi_value_semantics);
        add_test("canonical_delta_submit", test_canonical_delta_submit);
        add_test("programmatic_form_type_is_preserved",
            test_programmatic_form_type_is_preserved);
        add_test("fresh_form_value_match", test_fresh_form_value_match);
        add_test("accept_current_values", test_accept_current_values);
        add_test("accept_server_roundtrip", test_accept_server_roundtrip);
        add_test("required_boolean_default_is_submitted",
            test_required_boolean_default_is_submitted);
        add_test("server_roundtrip_replaces_field_schema",
            test_server_roundtrip_replaces_field_schema);
        add_test("empty_result_value_is_present",
            test_empty_result_value_is_present);
        add_test("empty_error_value_has_no_message",
            test_empty_error_value_has_no_message);
        add_test("empty_multiline_values_preserve_order_and_whitespace",
            test_empty_multiline_values_preserve_order_and_whitespace);
    }

    private void test_baseline_scalar_changes() {
        DataForms.DataForm form = parse_form(new StanzaNode[] {
            build_field("enabled", "boolean", new string[] { "true" }),
            build_field("name", "text-single", new string[] { "Before" }),
            build_field("whois", "list-single", new string[] { "moderators" })
        });

        fail_if_not_eq_int(0, form.get_changed_field_vars().size);

        // Re-serialization from true to 1 is not a semantic change.
        ((DataForms.DataForm.BooleanField) find_field(form, "enabled")).value = true;
        fail_if(form.has_changed_field("enabled"));

        ((DataForms.DataForm.BooleanField) find_field(form, "enabled")).value = false;
        ((DataForms.DataForm.TextSingleField) find_field(form, "name")).value = "";
        ((DataForms.DataForm.ListSingleField) find_field(form, "whois")).value = "anyone";

        fail_if_not(form.has_changed_field("enabled"));
        fail_if_not(form.has_changed_field("name"));
        fail_if_not(form.has_changed_field("whois"));
        fail_if_not_eq_int(3, form.get_changed_field_vars().size);
    }

    private void test_multi_value_semantics() {
        DataForms.DataForm form = parse_form(new StanzaNode[] {
            build_field("presence", "list-multi", new string[] { "moderator", "participant" }),
            build_field("owners", "jid-multi", new string[] { "one@example.test", "two@example.test" })
        });

        ((DataForms.DataForm.ListMultiField) find_field(form, "presence")).value =
                string_list(new string[] { "participant", "moderator" });
        ((DataForms.DataForm.JidMultiField) find_field(form, "owners")).value =
                string_list(new string[] { "two@example.test", "one@example.test" });

        fail_if_not(form.has_changed_field("presence"),
            "list-multi selection order may be significant under XEP-0004");
        fail_if(form.has_changed_field("owners"), "jid-multi ordering must not count as a change");

        ((DataForms.DataForm.ListMultiField) find_field(form, "presence")).value =
                string_list(new string[] { "moderator" });
        ((DataForms.DataForm.JidMultiField) find_field(form, "owners")).value =
                string_list(new string[] { "one@example.test", "three@example.test" });
        fail_if_not(form.has_changed_field("presence"));
        fail_if_not(form.has_changed_field("owners"));
    }

    private void test_canonical_delta_submit() {
        StanzaNode token = build_field("server-token", "hidden", new string[] { "opaque" });
        StanzaNode required = build_field("required-name", "text-single", new string[] { "Keep" }, true);
        required.put_attribute("label", "Required label");
        required.put_node(new StanzaNode.build("desc", DataForms.NS_URI)
                .put_node(new StanzaNode.text("Must not be submitted")));
        StanzaNode choice = build_field("whois", "list-single", new string[] { "moderators" });
        choice.put_node(new StanzaNode.build("option", DataForms.NS_URI)
                .put_attribute("label", "Anybody")
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text("anyone"))));

        DataForms.DataForm form = parse_form(new StanzaNode[] {
            build_field("FORM_TYPE", "hidden", new string[] { "http://jabber.org/protocol/muc#roomconfig" }),
            token,
            required,
            build_field("enabled", "boolean", new string[] { "1" }),
            build_field("description", "text-single", new string[] { "Before" }),
            choice,
            build_field("presence", "list-multi", new string[] { "moderator", "participant" }),
            build_field("owners", "jid-multi", new string[] { "one@example.test" }),
            build_field("unchanged", "text-single", new string[] { "Same" }),
            build_field("notice", "fixed", new string[] { "Read only" })
        });

        ((DataForms.DataForm.BooleanField) find_field(form, "enabled")).value = false;
        ((DataForms.DataForm.TextSingleField) find_field(form, "description")).value = "";
        ((DataForms.DataForm.ListSingleField) find_field(form, "whois")).value = "anyone";
        ((DataForms.DataForm.ListMultiField) find_field(form, "presence")).value =
                new ArrayList<string>();
        ((DataForms.DataForm.JidMultiField) find_field(form, "owners")).value =
                string_list(new string[] { "two@example.test", "one@example.test" });
        find_field(form, "notice").set_value_string("Changed but fixed");

        StanzaNode submit = form.get_delta_submit_node();
        fail_if_not_eq_str("submit", submit.get_attribute("type", DataForms.NS_URI));
        fail_if(submit.get_subnode("title", DataForms.NS_URI) != null);
        fail_if(submit.get_subnode("instructions", DataForms.NS_URI) != null);

        Gee.List<StanzaNode> fields = submit.get_subnodes("field", DataForms.NS_URI);
        fail_if_not_eq_int(8, fields.size);
        assert_value(fields, "FORM_TYPE", "http://jabber.org/protocol/muc#roomconfig");
        assert_value(fields, "server-token", "opaque");
        assert_value(fields, "required-name", "Keep");
        assert_value(fields, "enabled", "0");
        assert_value(fields, "description", "");
        assert_value(fields, "whois", "anyone");
        StanzaNode presence = find_node(fields, "presence");
        fail_if_not_eq_int(0, presence.get_subnodes("value", DataForms.NS_URI).size,
                "an emptied list-multi must remain an explicit field");
        assert_values(fields, "owners", new string[] { "two@example.test", "one@example.test" });

        fail_if(find_node_or_null(fields, "unchanged") != null);
        fail_if(find_node_or_null(fields, "notice") != null);
        foreach (StanzaNode field in fields) {
            string? var_name = field.get_attribute("var", DataForms.NS_URI);
            fail_if(field.get_attribute("label", DataForms.NS_URI) != null);
            fail_if(field.get_subnode("desc", DataForms.NS_URI) != null);
            fail_if(field.get_subnode("option", DataForms.NS_URI) != null);
            fail_if(field.get_subnode("required", DataForms.NS_URI) != null);
            string? type = field.get_attribute("type", DataForms.NS_URI);
            if (var_name == "FORM_TYPE" || var_name == "server-token") {
                fail_if_not_eq_str("hidden", type);
            } else {
                fail_if(type != null, "non-hidden submit fields must not carry presentation type metadata");
            }
        }
    }

    private void test_fresh_form_value_match() {
        DataForms.DataForm submitted = parse_form(new StanzaNode[] {
            build_field("enabled", "boolean", new string[] { "0" }),
            build_field("presence", "list-multi", new string[] { "moderator", "participant" }),
            build_field("owners", "jid-multi", new string[] { "one@example.test", "two@example.test" }),
            build_field("whois", "list-single", new string[] { "anyone" })
        });
        ((DataForms.DataForm.BooleanField) find_field(submitted, "enabled")).value = true;

        DataForms.DataForm fresh = parse_form(new StanzaNode[] {
            build_field("enabled", "boolean", new string[] { "true" }),
            build_field("presence", "list-multi", new string[] { "moderator", "participant" }),
            build_field("owners", "jid-multi", new string[] { "two@example.test", "one@example.test" }),
            build_field("whois", "list-single", new string[] { "anyone" })
        });
        Gee.List<string> vars = string_list(new string[] { "enabled", "presence", "owners", "whois" });
        fail_if_not(submitted.matches_field_values(fresh, vars));

        ((DataForms.DataForm.ListSingleField) find_field(fresh, "whois")).value = "moderators";
        fail_if(submitted.matches_field_values(fresh, vars));
    }

    private void test_programmatic_form_type_is_preserved() {
        var form = new DataForms.DataForm();
        var form_type = new DataForms.DataForm.HiddenField() {
            var = "FORM_TYPE"
        };
        form_type.set_value_string(
            "http://jabber.org/protocol/muc#roomconfig");
        form.add_field(form_type);

        StanzaNode submit = form.get_delta_submit_node();
        Gee.List<StanzaNode> fields = submit.get_subnodes("field",
            DataForms.NS_URI);
        assert_value(fields, "FORM_TYPE",
            "http://jabber.org/protocol/muc#roomconfig");
        fail_if_not_eq_int(1, fields.size,
            "an explicit programmatic FORM_TYPE must be submitted exactly once");

        form.accept_current_values();
        fail_if(form.has_changed_field("FORM_TYPE"));
    }

    private void test_accept_current_values() {
        DataForms.DataForm form = parse_form(new StanzaNode[] {
            build_field("enabled", "boolean", new string[] { "0" }),
            build_field("name", "text-single", new string[] { "Before" })
        });
        ((DataForms.DataForm.BooleanField) find_field(form, "enabled")).value = true;
        ((DataForms.DataForm.TextSingleField) find_field(form, "name")).value = "After";
        fail_if_not_eq_int(2, form.get_changed_field_vars().size);

        form.accept_current_values();
        fail_if_not_eq_int(0, form.get_changed_field_vars().size);
        fail_if(form.has_changed_field("enabled"));
        fail_if(form.has_changed_field("name"));
    }

    private void test_accept_server_roundtrip() {
        DataForms.DataForm form = parse_form(new StanzaNode[] {
            build_field("FORM_TYPE", "hidden", new string[] { "room-config-v1" }),
            build_field("old-token", "hidden", new string[] { "remove-me" }),
            build_field("persistent-token", "hidden", new string[] { "old-token" }),
            build_field("required-name", "text-single", new string[] { "Before" }, true),
            build_field("enabled", "boolean", new string[] { "0" })
        });
        ((DataForms.DataForm.BooleanField) find_field(form, "enabled")).value = true;

        DataForms.DataForm fresh = parse_form(new StanzaNode[] {
            build_field("FORM_TYPE", "hidden", new string[] { "room-config-v2" }),
            build_field("persistent-token", "hidden", new string[] { "new-token" }),
            build_field("required-name", "text-single", new string[] { "Normalized" }, true),
            build_field("rotated-token", "hidden", new string[] { "added-token" }),
            build_field("enabled", "boolean", new string[] { "1" })
        });

        form.accept_server_roundtrip(fresh);
        fail_if_not_eq_int(0, form.get_changed_field_vars().size);

        StanzaNode submit = form.get_delta_submit_node();
        Gee.List<StanzaNode> fields = submit.get_subnodes("field",
            DataForms.NS_URI);
        assert_value(fields, "FORM_TYPE", "room-config-v2");
        assert_value(fields, "persistent-token", "new-token");
        assert_value(fields, "required-name", "Normalized");
        assert_value(fields, "rotated-token", "added-token");
        fail_if(find_node_or_null(fields, "old-token") != null,
            "a hidden field removed by the server must not be resubmitted");
        fail_if(find_node_or_null(fields, "enabled") != null,
            "the confirmed optional value must not be resubmitted");
    }

    private void test_required_boolean_default_is_submitted() {
        DataForms.DataForm form = parse_form(new StanzaNode[] {
            build_field("required-flag", "boolean", new string[] {}, true)
        });

        fail_if_not_eq_int(0, form.get_missing_required_fields().size,
            "an empty boolean has the XEP-0004 default value false");
        Gee.List<StanzaNode> fields = form.get_delta_submit_node()
            .get_subnodes("field", DataForms.NS_URI);
        fail_if_not_eq_int(1, fields.size);
        assert_value(fields, "required-flag", "0");
    }

    private void test_server_roundtrip_replaces_field_schema() {
        DataForms.DataForm form = parse_form(new StanzaNode[] {
            build_field("required-to-optional", "text-single",
                new string[] { "old-required" }, true),
            build_field("hidden-to-visible", "hidden",
                new string[] { "old-hidden" }),
            build_field("optional-to-required", "text-single",
                new string[] { "old-optional" }),
            build_field("visible-to-hidden", "text-single",
                new string[] { "old-visible" })
        });
        DataForms.DataForm fresh = parse_form(new StanzaNode[] {
            build_field("required-to-optional", "text-single",
                new string[] { "server-optional" }),
            build_field("hidden-to-visible", "text-single",
                new string[] { "server-visible" }),
            build_field("optional-to-required", "text-single",
                new string[] { "server-required" }, true),
            build_field("visible-to-hidden", "hidden",
                new string[] { "server-hidden" })
        });

        form.accept_server_roundtrip(fresh);
        DataForms.DataForm.Field required_to_optional = find_field(form,
            "required-to-optional");
        DataForms.DataForm.Field hidden_to_visible = find_field(form,
            "hidden-to-visible");
        DataForms.DataForm.Field optional_to_required = find_field(form,
            "optional-to-required");
        DataForms.DataForm.Field visible_to_hidden = find_field(form,
            "visible-to-hidden");
        fail_if(required_to_optional.required ||
                required_to_optional.type_ != DataForms.DataForm.Type.TEXT_SINGLE ||
                required_to_optional.get_value_string() != "server-optional");
        fail_if(hidden_to_visible.type_ != DataForms.DataForm.Type.TEXT_SINGLE ||
                hidden_to_visible.get_value_string() != "server-visible");
        fail_if(!optional_to_required.required ||
                optional_to_required.get_value_string() != "server-required");
        fail_if(visible_to_hidden.type_ != DataForms.DataForm.Type.HIDDEN ||
                visible_to_hidden.get_value_string() != "server-hidden");

        Gee.List<StanzaNode> submitted = form.get_delta_submit_node()
            .get_subnodes("field", DataForms.NS_URI);
        fail_if_not_eq_int(2, submitted.size,
            "only the fresh required and hidden fields must survive an unchanged delta");
        assert_value(submitted, "optional-to-required", "server-required");
        assert_value(submitted, "visible-to-hidden", "server-hidden");
        fail_if(find_node_or_null(submitted, "required-to-optional") != null ||
                find_node_or_null(submitted, "hidden-to-visible") != null,
            "old required/hidden metadata must not survive the server roundtrip");
    }

    private void test_empty_result_value_is_present() {
        var x = new StanzaNode.build("x", DataForms.NS_URI)
                .put_attribute("type", "result");
        x.put_node(new StanzaNode.build("reported", DataForms.NS_URI)
                .put_node(build_field("result", "text-single", new string[] {})));
        var item_field = new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "result")
                .put_node(new StanzaNode.build("value", DataForms.NS_URI));
        x.put_node(new StanzaNode.build("item", DataForms.NS_URI)
                .put_node(item_field));
        DataForms.DataForm? form = DataForms.DataForm.create_from_node(x);
        assert_nonnull(form);
        fail_if_not_eq_int(1, ((!) form).items.size);
        DataForms.DataForm.Field field = ((!) form).items[0][0];
        fail_if_not_eq_int(1, field.get_values().size);
        fail_if_not_eq_str("", field.get_values()[0]);
        fail_if_not_eq_str("", field.get_value_string());

        var absent = new DataForms.DataForm.Field.from_node(
            new StanzaNode.build("field", DataForms.NS_URI));
        fail_if_not_eq_int(0, absent.get_values().size,
            "a missing value must remain absent rather than becoming one empty value");
        fail_if_not_eq_str("", absent.get_value_string());
    }

    private void test_empty_error_value_has_no_message() {
        var empty = new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "error")
                .put_node(new StanzaNode.build("value", DataForms.NS_URI));
        DataForms.DataForm form = parse_form(new StanzaNode[] { empty });
        fail_if(form.get_error_message() != null);
        fail_if_not_eq_int(1, form.fields[0].get_values().size);
        fail_if_not_eq_str("", form.fields[0].get_values()[0]);

        empty.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text(" first ")));
        empty.put_node(new StanzaNode.build("value", DataForms.NS_URI));
        empty.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("second")));
        fail_if_not_eq_str(" first \nsecond", form.get_error_message());
    }

    private void test_empty_multiline_values_preserve_order_and_whitespace() {
        var node = new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "lines")
                .put_attribute("type", "text-multi")
                .put_node(new StanzaNode.build("value", DataForms.NS_URI))
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(" first ")))
                .put_node(new StanzaNode.build("value", DataForms.NS_URI))
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text("\tsecond\t")))
                .put_node(new StanzaNode.build("value", DataForms.NS_URI));
        DataForms.DataForm form = parse_form(new StanzaNode[] { node });
        Gee.List<string> values = form.fields[0].get_values();
        string[] expected = { "", " first ", "", "\tsecond\t", "" };
        fail_if_not_eq_int(expected.length, values.size);
        var joined = new StringBuilder();
        for (int i = 0; i < values.size; i++) {
            fail_if_not_eq_str(expected[i], values[i]);
            if (i > 0) joined.append_c('\n');
            joined.append(values[i]);
        }
        fail_if_not_eq_str("\n first \n\n\tsecond\t\n", joined.str);
        fail_if(form.has_changed_field("lines"),
            "normalizing an empty XML value must not change the parsed baseline");
    }

    private DataForms.DataForm parse_form(StanzaNode[] field_nodes) {
        var x = new StanzaNode.build("x", DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form");
        x.put_node(new StanzaNode.build("title", DataForms.NS_URI)
                .put_node(new StanzaNode.text("Server form")));
        foreach (StanzaNode field_node in field_nodes) x.put_node(field_node);
        DataForms.DataForm? form = DataForms.DataForm.create_from_node(x);
        assert_nonnull(form);
        return (!) form;
    }

    private StanzaNode build_field(string var_name, string type, string[] values,
            bool required = false) {
        var field = new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", var_name)
                .put_attribute("type", type);
        foreach (string value in values) {
            field.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(value)));
        }
        if (required) field.put_node(new StanzaNode.build("required", DataForms.NS_URI));
        return field;
    }

    private Gee.List<string> string_list(string[] values) {
        var result = new ArrayList<string>();
        foreach (string value in values) result.add(value);
        return result;
    }

    private DataForms.DataForm.Field find_field(DataForms.DataForm form, string var_name) {
        foreach (DataForms.DataForm.Field field in form.fields) {
            if (field.var == var_name) return field;
        }
        assert_not_reached();
    }

    private StanzaNode find_node(Gee.List<StanzaNode> fields, string var_name) {
        StanzaNode? node = find_node_or_null(fields, var_name);
        assert_nonnull(node);
        return (!) node;
    }

    private StanzaNode? find_node_or_null(Gee.List<StanzaNode> fields, string var_name) {
        foreach (StanzaNode field in fields) {
            if (field.get_attribute("var", DataForms.NS_URI) == var_name) return field;
        }
        return null;
    }

    private void assert_value(Gee.List<StanzaNode> fields, string var_name, string expected) {
        StanzaNode node = find_node(fields, var_name);
        StanzaNode? value = node.get_subnode("value", DataForms.NS_URI);
        assert_nonnull(value);
        fail_if_not_eq_str(expected, ((!) value).get_string_content());
    }

    private void assert_values(Gee.List<StanzaNode> fields, string var_name, string[] expected) {
        Gee.List<StanzaNode> values = find_node(fields, var_name).get_subnodes("value", DataForms.NS_URI);
        fail_if_not_eq_int(expected.length, values.size);
        for (int i = 0; i < expected.length; i++) {
            fail_if_not_eq_str(expected[i], values[i].get_string_content());
        }
    }
}

}
