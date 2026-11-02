using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui.Test {

class DataFormViewModelTest : Gee.TestCase {

    public DataFormViewModelTest() {
        base("DataFormViewModel");
        add_test("boolean_updates_serialized_form", test_boolean_updates_serialized_form);
        add_test("text_updates_serialized_form", test_text_updates_serialized_form);
        add_test("list_single_updates_serialized_form", test_list_single_updates_serialized_form);
        add_test("list_multi_updates_serialized_form", test_list_multi_updates_serialized_form);
        add_test("text_multi_preserves_lines_and_whitespace",
            test_text_multi_preserves_lines_and_whitespace);
        add_test("jid_multi_normalizes_input_lines",
            test_jid_multi_normalizes_input_lines);
        add_test("boolean_roundtrip_is_semantically_clean",
            test_boolean_roundtrip_is_semantically_clean);
        add_test("jid_multi_reorder_is_semantically_clean",
            test_jid_multi_reorder_is_semantically_clean);
        add_test("room_config_semantics_are_explicit",
            test_room_config_semantics_are_explicit);
        add_test("api_password_input_preserves_wire_schema",
            test_api_password_input_preserves_wire_schema);
        add_test("api_password_input_scope_is_explicit",
            test_api_password_input_scope_is_explicit);
        add_test("private_results_hide_without_changing_form",
            test_private_results_hide_without_changing_form);
        add_test("reported_private_results_hide_untyped_values",
            test_reported_private_results_hide_untyped_values);
        add_test("ordinary_result_values_preserve_content_and_scope",
            test_ordinary_result_values_preserve_content_and_scope);
        add_test("server_field_help_preserves_original_xml_and_values",
            test_server_field_help_preserves_original_xml_and_values);
        add_test("multiline_server_help_keeps_empty_values_and_whitespace",
            test_multiline_server_help_keeps_empty_values_and_whitespace);
    }

    private void test_boolean_updates_serialized_form() {
        DataForms.DataForm form = parse_form(new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_changesubject")
            .put_attribute("type", "boolean")
            .put_attribute("label", "Allow subject changes")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("0"))));
        string baseline = form.stanza_node.to_string();

        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.Toggle;
        assert_true(row != null, "boolean field must create a toggle row");
        ((!) row).state = true;

        var field = form.fields[0] as DataForms.DataForm.BooleanField;
        assert_true(field != null && ((!) field).value,
            "toggle state must update the XEP-0004 boolean field");
        assert_true(baseline != form.stanza_node.to_string(),
            "toggle state must update the serialized form used by the save gate");
        assert_true(((!) field).get_value_string() == "1",
            "boolean room configuration values must use the XEP-0004 1 representation");
    }

    private void test_text_updates_serialized_form() {
        DataForms.DataForm form = parse_form(new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_roomdesc")
            .put_attribute("type", "text-single")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("Before"))));
        string baseline = form.stanza_node.to_string();

        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.Entry;
        assert_true(row != null, "text field must create an entry row");
        ((!) row).text = "After";

        var field = form.fields[0] as DataForms.DataForm.TextSingleField;
        assert_true(field != null && ((!) field).value == "After",
            "entry text must update the XEP-0004 text field");
        assert_true(baseline != form.stanza_node.to_string(),
            "entry text must update the serialized form used by the save gate");
    }

    private void test_list_single_updates_serialized_form() {
        var field_node = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_whois")
            .put_attribute("type", "list-single")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("moderators")));
        field_node.put_node(build_option("Moderators", "moderators"));
        field_node.put_node(build_option("Anyone", "anyone"));
        DataForms.DataForm form = parse_form(field_node);
        string baseline = form.stanza_node.to_string();

        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.ComboBox;
        assert_true(row != null, "list-single field must create a combo row");
        ((!) row).active_item = 1;

        var field = form.fields[0] as DataForms.DataForm.ListSingleField;
        assert_true(field != null && ((!) field).value == "anyone",
            "combo selection must update the XEP-0004 list field");
        assert_true(baseline != form.stanza_node.to_string(),
            "combo selection must update the serialized form used by the save gate");
    }

    private void test_list_multi_updates_serialized_form() {
        var field_node = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_presencebroadcast")
            .put_attribute("type", "list-multi")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("moderator")))
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("participant")));
        field_node.put_node(build_option("Moderators", "moderator"));
        field_node.put_node(build_option("Participants", "participant"));
        field_node.put_node(build_option("Visitors", "visitor"));
        DataForms.DataForm form = parse_form(field_node);
        string baseline = form.stanza_node.to_string();

        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.MultiCheck;
        assert_true(row != null && ((!) row).states.size == 3,
            "presencebroadcast list-multi must create one checkbox per role");
        assert_true(((!) row).states[0] && ((!) row).states[1] &&
                !((!) row).states[2],
            "presence-broadcast selections must reflect the server form");

        ((!) row).states[1] = false;
        ((!) row).state_changed(1, false);
        var field = form.fields[0] as DataForms.DataForm.ListMultiField;
        assert_true(field != null && ((!) field).value.size == 1 &&
                ((!) field).value[0] == "moderator",
            "changing a presence-broadcast checkbox must update the list-multi field");
        assert_true(baseline != form.stanza_node.to_string(),
            "presence-broadcast changes must reach the serialized owner form");
    }

    private void test_text_multi_preserves_lines_and_whitespace() {
        DataForms.DataForm form = parse_form(new StanzaNode.build("field",
                DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_multiline")
            .put_attribute("type", "text-multi")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("Before"))));
        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.MultiText;
        assert_true(row != null, "text-multi must create a multiline row");
        ((!) row).text = "\n  keep spaces  \n\nlast\n";
        ((!) row).changed();

        var field = form.fields[0] as DataForms.DataForm.TextMultiField;
        assert_true(field != null && ((!) field).value.size == 5,
            "text-multi must preserve leading, intermediate and trailing empty lines");
        assert_true(((!) field).value[0] == "" &&
                ((!) field).value[1] == "  keep spaces  " &&
                ((!) field).value[2] == "" &&
                ((!) field).value[3] == "last" &&
                ((!) field).value[4] == "",
            "text-multi must preserve line whitespace verbatim");
    }

    private void test_jid_multi_normalizes_input_lines() {
        DataForms.DataForm form = parse_form(new StanzaNode.build("field",
                DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_roomowners")
            .put_attribute("type", "jid-multi"));
        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.MultiText;
        assert_true(row != null, "jid-multi must create a multiline row");
        ((!) row).text = "  one@example.test  \n\n two@example.test ";
        ((!) row).changed();

        var field = form.fields[0] as DataForms.DataForm.JidMultiField;
        assert_true(field != null && ((!) field).value.size == 2 &&
                ((!) field).value[0] == "one@example.test" &&
                ((!) field).value[1] == "two@example.test",
            "jid-multi must trim JID lines and ignore empty input rows");
    }

    private void test_boolean_roundtrip_is_semantically_clean() {
        DataForms.DataForm form = parse_form(new StanzaNode.build("field",
                DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_changesubject")
            .put_attribute("type", "boolean")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("true"))));
        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.Toggle;
        assert_true(row != null);

        ((!) row).state = false;
        ((!) row).state = true;
        assert_true(form.get_changed_field_vars().is_empty,
            "true -> false -> true must not leave a semantic room-config change");
    }

    private void test_jid_multi_reorder_is_semantically_clean() {
        var field_node = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_roomowners")
            .put_attribute("type", "jid-multi")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("one@example.test")))
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("two@example.test")));
        DataForms.DataForm form = parse_form(field_node);
        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.MultiText;
        assert_true(row != null);

        ((!) row).text = "two@example.test\none@example.test";
        ((!) row).changed();
        assert_true(form.get_changed_field_vars().is_empty,
            "jid-multi line order alone must not leave a semantic room-config change");
    }

    private void test_room_config_semantics_are_explicit() {
        assert_toggle_copy("muc#roomconfig_allowinvites",
            "Allow additional room invitations", "room server");
        assert_toggle_copy("muc#roomconfig_allow_query_users",
            "Allow occupant IQ queries", "not member search");
        assert_toggle_copy("muc#roomconfig_enable_hats",
            "Enable hats", "room broadcasts refreshed occupant presence");
        assert_toggle_copy("muc#roomconfig_voice_request_min_interval",
            "Voice request interval", "rejects repeated requests");

        var field_node = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "muc#roomconfig_presencebroadcast")
            .put_attribute("type", "list-multi");
        field_node.put_node(build_option("Moderators", "moderator"));
        DataForms.DataForm presence_form = parse_form(field_node);
        var presence_row = Util.get_data_form_field_view_model(
            presence_form.fields[0]) as ViewModel.PreferencesRow.MultiCheck;
        assert_true(presence_row != null &&
                ((!) presence_row).title == "Broadcast presence for roles",
            "presencebroadcast must not be described as merely hiding role labels");
        assert_true(((!) presence_row).subtitle.contains(
                "a real leave and rejoin rebuilds the roster"),
            "presencebroadcast must not promise a non-standard roster refresh");
    }

    private void test_api_password_input_preserves_wire_schema() {
        foreach (string field_var in new string[] { "password", "newpass" }) {
            DataForms.DataForm form = parse_text_field(field_var, "text-single", " original ");
            var field = form.fields[0] as DataForms.DataForm.TextSingleField;
            var row = Util.get_data_form_field_view_model(form.fields[0], null,
                "api-commands/change_password") as ViewModel.PreferencesRow.PrivateText;
            assert_true(field != null && row != null,
                "ejabberd API password arguments must use a password entry");
            assert_true(((!) row).text == " original ");
            assert_true(((!) row).title == (field_var == "password" ?
                _("Password") : _("New Password")),
                "known API password inputs must use understandable translated labels");
            ((!) row).text = " new secret ";
            assert_true(((!) field).value == " new secret ",
                "password input must update the original text-single value");
            ((!) field).value = " server replacement ";
            assert_true(((!) row).text == " server replacement ",
                "the original field must retain its bidirectional binding");
            assert_true(form.fields[0].type_ == DataForms.DataForm.Type.TEXT_SINGLE &&
                form.fields[0].node.get_attribute("type") == "text-single",
                "display privacy must not change the command's XEP-0004 wire type");
        }
    }

    private void test_api_password_input_scope_is_explicit() {
        foreach (string field_var in new string[] { "password", "newpass" }) {
            DataForms.DataForm form = parse_text_field(field_var, "text-single", "ordinary");
            foreach (string command_node in new string[] {
                    "other/change_password", "api-commands-other/change_password" }) {
                var row = Util.get_data_form_field_view_model(form.fields[0], null,
                    command_node);
                assert_true(row is ViewModel.PreferencesRow.Entry,
                    "a field name alone must not change an unrelated command's input");
            }
            assert_true(Util.get_data_form_field_view_model(form.fields[0]) is
                ViewModel.PreferencesRow.Entry,
                "ordinary text-single fields remain ordinary entries without API scope");
        }
        DataForms.DataForm user_form = parse_text_field("user", "text-single", "alice");
        assert_true(Util.get_data_form_field_view_model(user_form.fields[0], null,
            "api-commands/register") is ViewModel.PreferencesRow.Entry,
            "non-secret API arguments must retain their ordinary input type");
        assert_field_title(user_form.fields[0], "api-commands/register", _("Username"));
        assert_field_title(user_form.fields[0], "api-commands/add_rosteritem", _("Contact username"));
        DataForms.DataForm host_form = parse_text_field("host", "text-single", "example.test");
        assert_field_title(host_form.fields[0], "api-commands/register", _("XMPP server"));
        assert_field_title(host_form.fields[0], "api-commands/add_rosteritem", _("Contact server"));
        var custom_form = parse_form(new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "custom_argument")
            .put_attribute("type", "text-single")
            .put_attribute("label", "Server supplied label"));
        assert_field_title(custom_form.fields[0], "api-commands/custom", "Server supplied label");
    }

    private void test_private_results_hide_without_changing_form() {
        foreach (string field_var in new string[] { "password", "newpass" }) {
            DataForms.DataForm form = parse_text_field(field_var, "text-single", " secret one ");
            form.fields[0].node.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("secret two")));
            string baseline = form.stanza_node.to_string();
            assert_true(Util.get_data_form_result_display_value(form.fields[0],
                "api-commands/change_password") == _("Hidden"),
                "API password results must not expose the echoed argument");
            foreach (string value in form.fields[0].get_values()) {
                assert_true(Util.get_data_form_result_display_value(form.fields[0],
                    "api-commands/change_password", value) == _("Hidden"),
                    "the single-column multiple-row path must hide every secret value");
            }
            assert_true(form.stanza_node.to_string() == baseline &&
                form.fields[0].get_values()[0] == " secret one " &&
                form.fields[0].get_values()[1] == "secret two",
                "result masking must leave the original XML and values untouched");
        }
        DataForms.DataForm private_form = parse_text_field("anything", "text-private", "private");
        string baseline = private_form.stanza_node.to_string();
        assert_true(Util.get_data_form_result_display_value(private_form.fields[0]) == _("Hidden") &&
            Util.get_data_form_result_display_value(private_form.fields[0],
                "other/command", "private") == _("Hidden"),
            "XEP-0004 text-private results must always be hidden regardless of command");
        assert_true(private_form.stanza_node.to_string() == baseline);
    }

    private void test_reported_private_results_hide_untyped_values() {
        DataForms.DataForm column_form = parse_text_field("secret", "text-private", "");
        DataForms.DataForm value_form = parse_form(new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "secret")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("untyped secret"))));
        string baseline = value_form.stanza_node.to_string();
        assert_true(Util.get_data_form_result_display_value(value_form.fields[0],
            "other/command", null, column_form.fields[0]) == _("Hidden") &&
            Util.get_data_form_result_display_value(value_form.fields[0],
                "other/command", "untyped secret", column_form.fields[0]) == _("Hidden"),
            "reported text-private metadata must hide even an untyped item value");
        assert_true(value_form.stanza_node.to_string() == baseline,
            "reported metadata must not be written into the original result field");
    }

    private void test_ordinary_result_values_preserve_content_and_scope() {
        DataForms.DataForm form = parse_text_field("password", "text-single", " first ");
        form.fields[0].node.put_node(new StanzaNode.build("value", DataForms.NS_URI));
        form.fields[0].node.put_node(new StanzaNode.build("value", DataForms.NS_URI)
            .put_node(new StanzaNode.text("\tlast\t")));
        string baseline = form.stanza_node.to_string();
        foreach (string command_node in new string[] {
                "other/command", "api-commands-other/command" }) {
            assert_true(Util.get_data_form_result_display_value(form.fields[0],
                command_node) == " first \n\n\tlast\t",
                "unrelated ordinary results must preserve order, whitespace and empty values");
        }
        assert_true(Util.get_data_form_result_display_value(form.fields[0]) == " first \n\n\tlast\t");
        assert_true(Util.get_data_form_result_display_value(form.fields[0], null, "") == "",
            "a single ordinary empty row must remain empty");
        assert_true(form.stanza_node.to_string() == baseline);
        DataForms.DataForm user_form = parse_text_field("user", "text-single", " alice ");
        assert_true(Util.get_data_form_result_display_value(user_form.fields[0],
            "api-commands/register") == " alice ",
            "ordinary API results must not be masked");
    }

    private void test_server_field_help_preserves_original_xml_and_values() {
        string help = "Помощь: use <value/> & keep <b>literal</b> text";
        string value = "  значение <value/> & unchanged  ";
        foreach (string field_type in new string[] {
                "text-single", "text-private", "list-single", "text-multi",
                "boolean", "list-multi" }) {
            string original_value = field_type == "boolean" ? "0" : value;
            var field_node = new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "server_argument")
                .put_attribute("type", field_type)
                .put_attribute("label", "Server argument")
                .put_node(new StanzaNode.build("desc", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(help)))
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(original_value)));
            if (field_type == "list-single" || field_type == "list-multi") {
                field_node.put_node(build_option("Selected option", original_value));
                field_node.put_node(build_option("Other option", "other"));
            }
            DataForms.DataForm form = parse_form(field_node);
            string baseline = form.stanza_node.to_string();
            var row = Util.get_data_form_field_view_model(form.fields[0]);
            assert_true(row != null && ((!) row).description == help,
                "every supported server field must retain its literal field help");
            assert_true(form.fields[0].description == help &&
                form.fields[0].get_values().size == 1 &&
                form.fields[0].get_values()[0] == original_value &&
                form.stanza_node.to_string() == baseline,
                "creating field help must not rewrite original XML, choices or values");
        }

        // ejabberd exposes these credentials as text-single; the display-only
        // password entry must retain the server's help and original schema.
        var password_node = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "newpass")
            .put_attribute("type", "text-single")
            .put_node(new StanzaNode.build("desc", DataForms.NS_URI)
                .put_node(new StanzaNode.text(help)))
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
        DataForms.DataForm password_form = parse_form(password_node);
        string baseline = password_form.stanza_node.to_string();
        var password_row = Util.get_data_form_field_view_model(
            password_form.fields[0], null, "api-commands/change_password")
            as ViewModel.PreferencesRow.PrivateText;
        assert_true(password_row != null && ((!) password_row).description == help &&
            ((!) password_row).text == value,
            "display-private API inputs must preserve server help and password bytes");
        assert_true(password_form.stanza_node.to_string() == baseline &&
            password_form.fields[0].node.get_attribute("type") == "text-single",
            "field help must not change the API password's wire type or XML");
    }

    private void test_multiline_server_help_keeps_empty_values_and_whitespace() {
        string help = "Описание <value/> & строка\nВторая строка";
        var field_node = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", "server_lines")
            .put_attribute("type", "text-multi")
            .put_attribute("label", "Server lines")
            .put_node(new StanzaNode.build("desc", DataForms.NS_URI)
                .put_node(new StanzaNode.text(help)))
            .put_node(new StanzaNode.build("value", DataForms.NS_URI))
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("  Привет <value/> &  ")))
            .put_node(new StanzaNode.build("value", DataForms.NS_URI));
        DataForms.DataForm form = parse_form(field_node);
        string baseline = form.stanza_node.to_string();
        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.MultiText;
        assert_true(row != null && ((!) row).description == help &&
            ((!) row).text == "\n  Привет <value/> &  \n",
            "help must remain separate from multiline values and their blank lines");
        ((!) row).description = "Display-only help replacement";
        assert_true(form.fields[0].description == help &&
            form.fields[0].get_values().size == 3 &&
            form.fields[0].get_values()[0] == "" &&
            form.fields[0].get_values()[1] == "  Привет <value/> &  " &&
            form.fields[0].get_values()[2] == "" &&
            form.stanza_node.to_string() == baseline,
            "display-help changes must not alter server descriptions or empty values");
    }

    private static void assert_field_title(DataForms.DataForm.Field field,
            string command_node, string expected_title) {
        var row = Util.get_data_form_field_view_model(field, null, command_node);
        assert_true(row != null && ((!) row).title == expected_title,
            "API defaults must preserve specific context labels and unknown server labels");
    }

    private static DataForms.DataForm parse_text_field(string field_var, string field_type,
            string value) {
        return parse_form(new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", field_var)
            .put_attribute("type", field_type)
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text(value))));
    }

    private static void assert_toggle_copy(string field_var,
            string expected_title, string subtitle_fragment) {
        DataForms.DataForm form = parse_form(new StanzaNode.build("field",
                DataForms.NS_URI)
            .put_attribute("var", field_var)
            .put_attribute("type", "boolean")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("0"))));
        var row = Util.get_data_form_field_view_model(form.fields[0])
            as ViewModel.PreferencesRow.Toggle;
        assert_true(row != null && ((!) row).title == expected_title,
            "%s must use the protocol-specific room-config title".printf(
                field_var));
        assert_true(((!) row).subtitle != null &&
                ((!) row).subtitle.contains(subtitle_fragment),
            "%s must explain its protocol scope".printf(field_var));
    }

    private static DataForms.DataForm parse_form(StanzaNode field_node) {
        var form_node = new StanzaNode.build("x", DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(field_node);
        DataForms.DataForm? form = DataForms.DataForm.create_from_node(form_node);
        assert_true(form != null, "test data form must parse");
        return (!) form;
    }

    private static StanzaNode build_option(string label, string value) {
        return new StanzaNode.build("option", DataForms.NS_URI)
            .put_attribute("label", label)
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
    }
}

}
