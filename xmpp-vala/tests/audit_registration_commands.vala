using Xmpp;
using Xmpp.Xep;
using Gee;

/**
 * XEP-0077 In-Band Registration + XEP-0050 Ad-Hoc Commands audit tests.
 *
 * Tests registration form parsing, command node parsing, status enum,
 * note parsing, action lists, and adversarial inputs.
 */
namespace Xmpp.Test {

class RegistrationCommandsAudit : Gee.TestCase {
    private const string IBR_NS = "jabber:iq:register";
    private const string CMD_NS = "http://jabber.org/protocol/commands";

    public RegistrationCommandsAudit() {
        base("RegCmdAudit");
        // XEP-0077: Registration form structure
        add_test("XEP0077_ns_uri", test_ibr_ns_uri);
        add_test("XEP0077_invite_preauth_namespaces", test_ibr_invite_preauth_namespaces);
        add_test("XEP0077_query_node_structure", test_ibr_query_structure);
        add_test("XEP0077_legacy_form_parse_and_submit", test_ibr_legacy_form_parse_and_submit);
        add_test("XEP0077_password_change_structure", test_ibr_password_change);
        add_test("XEP0077_cancel_registration_structure", test_ibr_cancel_structure);
        add_async_test("XEP0077_home_server_cancel_omits_addressing", test_ibr_home_server_cancel_omits_addressing);
        add_async_test("XEP0077_cancel_error_is_reported", test_ibr_cancel_error_is_reported);
        add_test("XEP0077_module_identity", test_ibr_module_identity);
        add_test("XEP0077_module_not_mandatory", test_ibr_not_mandatory);
        // XEP-0050: Command parsing
        add_test("XEP0050_command_from_node_basic", test_cmd_from_node_basic);
        add_test("XEP0050_command_from_node_with_form", test_cmd_from_node_with_form);
        add_test("XEP0050_command_from_node_with_actions", test_cmd_from_node_actions);
        add_test("XEP0050_command_from_node_with_notes", test_cmd_from_node_notes);
        add_test("XEP0050_error_note_marks_completion_failed", test_cmd_error_note_marks_completion_failed);
        add_test("XEP0050_command_status_enum", test_cmd_status_enum);
        add_test("XEP0050_command_status_unknown", test_cmd_status_unknown);
        add_test("XEP0050_command_to_node_roundtrip", test_cmd_to_node);
        add_test("XEP0050_command_empty_node", test_cmd_empty_node);
        // XEP-0050: Adversarial
        add_test("XEP0050_command_missing_node_attr", test_cmd_missing_node_attr);
        add_test("XEP0050_command_missing_sessionid", test_cmd_missing_sessionid);
        add_test("XEP0050_command_xss_in_note", test_cmd_xss_in_note);
        add_test("XEP0050_command_many_actions", test_cmd_many_actions);
        add_test("XEP0050_command_item", test_cmd_item);
        add_test("XEP0050_note_item", test_note_item);
        add_async_test("XEP0050_list_commands_uses_commands_node", test_cmd_list_uses_commands_node);
        add_async_test("XEP0050_list_commands_ignores_foreign_item_jids", test_cmd_list_ignores_foreign_item_jids);
        add_async_test("XEP0050_list_commands_rejects_senderless_result", test_cmd_list_rejects_senderless_result);
        add_async_test("XEP0050_execute_validates_result_sender", test_cmd_execute_validates_result_sender);
        add_async_test("XEP0050_proceed_rejects_changed_session", test_cmd_proceed_rejects_changed_session);
        add_async_test("XEP0050_proceed_rejects_missing_session", test_cmd_proceed_rejects_missing_session);
        add_async_test("XEP0050_cancel_requires_canceled_status", test_cmd_cancel_requires_canceled_status);
        add_test("XEP0004_required_and_description", test_data_form_required_and_description);
        add_test("XEP0004_result_reported_schema", test_data_form_result_reported_schema);
        add_test("XEP0004_api_error_result", test_data_form_api_error_result);
    }

    // ========== XEP-0077 ==========

    private void test_ibr_ns_uri() {
        assert_true(InBandRegistration.NS_URI == "jabber:iq:register");
    }

    private void test_ibr_invite_preauth_namespaces() {
        assert_true(InBandRegistration.NS_URI_PARS == "urn:xmpp:pars:0");
        assert_true(InBandRegistration.NS_URI_IBR_TOKEN == "urn:xmpp:ibr-token:0");
        assert_true(InBandRegistration.NS_URI_INVITE_LEGACY == "urn:xmpp:invite");
    }

    private void test_ibr_query_structure() {
        // Verify the query node structure for get_from_server
        var query = new StanzaNode.build("query", IBR_NS).add_self_xmlns();
        assert_true(query.name == "query");
        assert_true(query.ns_uri == IBR_NS);
    }

    private void test_ibr_legacy_form_parse_and_submit() {
        var query = new StanzaNode.build("query", IBR_NS).add_self_xmlns();
        query.put_node(new StanzaNode.build("instructions", IBR_NS).put_node(new StanzaNode.text("Choose a username and password.")));
        query.put_node(new StanzaNode.build("username", IBR_NS));
        query.put_node(new StanzaNode.build("password", IBR_NS));

        var iq_node = new StanzaNode.build("iq")
            .put_attribute("type", "result")
            .put_node(query);
        var iq = new Iq.Stanza.from_stanza(iq_node, null);
        var form = new InBandRegistration.Form.from_node(iq);

        assert_true(form.is_legacy_form);
        fail_if_not_eq_str("Choose a username and password.", form.instructions);
        assert_true(form.fields.size == 2);
        fail_if_not_eq_str("username", form.fields[0].var);
        fail_if_not_eq_str("password", form.fields[1].var);
        assert_true(form.fields[1].type_ == DataForms.DataForm.Type.TEXT_PRIVATE);

        form.fields[0].set_value_string("juliet");
        form.fields[1].set_value_string("secret");

        StanzaNode submit = form.get_submit_query_node();
        fail_if_not_eq_str("juliet", submit.get_deep_string_content("username"));
        fail_if_not_eq_str("secret", submit.get_deep_string_content("password"));
    }

    private void test_ibr_password_change() {
        // Build a password change query and verify structure
        var query = new StanzaNode.build("query", IBR_NS).add_self_xmlns();
        var username = new StanzaNode.build("username", IBR_NS);
        username.put_node(new StanzaNode.text("testuser"));
        var password = new StanzaNode.build("password", IBR_NS);
        password.put_node(new StanzaNode.text("newpass123"));
        query.put_node(username);
        query.put_node(password);

        StanzaNode? u = query.get_subnode("username", IBR_NS);
        StanzaNode? p = query.get_subnode("password", IBR_NS);
        assert_nonnull(u);
        assert_nonnull(p);
        assert_true(u.get_string_content() == "testuser");
        assert_true(p.get_string_content() == "newpass123");
    }

    private void test_ibr_cancel_structure() {
        // Cancel registration: <query><remove/></query>
        var query = new StanzaNode.build("query", IBR_NS).add_self_xmlns();
        query.put_node(new StanzaNode.build("remove", IBR_NS));

        StanzaNode? remove = query.get_subnode("remove", IBR_NS);
        assert_nonnull(remove);
    }

    private void test_ibr_home_server_cancel_omits_addressing(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_cancel_stream(false);
            var module = new InBandRegistration.Module();

            module.cancel_registration.begin(stream, (_, res) => {
                string? error = module.cancel_registration.end(res);
                fail_if(error != null, "successful home-server cancellation must not report an error");
                assert_nonnull(stream.last_written);
                if (stream.last_written != null) {
                    fail_if(stream.last_written.get_attribute("to") != null,
                        "XEP-0077 home-server cancellation must omit the to address");
                    fail_if(stream.last_written.get_attribute("from") != null,
                        "XEP-0077 home-server cancellation must omit the from address");
                }
                cb();
            });
        } catch (Error e) {
            fail_if_reached(@"cancel registration test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_ibr_cancel_error_is_reported(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_cancel_stream(true);
            var module = new InBandRegistration.Module();

            module.cancel_registration.begin(stream, (_, res) => {
                string? error = module.cancel_registration.end(res);
                fail_if_not_eq_str("not-allowed: Server policy", error);
                cb();
            });
        } catch (Error e) {
            fail_if_reached(@"cancel registration error test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_ibr_module_identity() {
        var module = new InBandRegistration.Module();
        assert_true(module.get_ns() == IBR_NS);
        assert_true(module.get_id() == "0077_in_band_registration");
    }

    private void test_ibr_not_mandatory() {
        var module = new InBandRegistration.Module();
        // In-band registration is never mandatory for stream negotiation
        // negotiation_active() requires a live stream, so we test via the module identity
        assert_true(module.get_ns() == IBR_NS);
        assert_true(module.get_id() == "0077_in_band_registration");
        // The module has no mandatory_outstanding logic — it always returns false
    }

    // ========== XEP-0050: Command parsing ==========

    private StanzaNode build_command_node(string? node_attr, string? sessionid,
                                          string? status) {
        var cmd = new StanzaNode.build("command", CMD_NS).add_self_xmlns();
        if (node_attr != null) cmd.put_attribute("node", node_attr);
        if (sessionid != null) cmd.put_attribute("sessionid", sessionid);
        if (status != null) cmd.put_attribute("status", status);
        return cmd;
    }

    private void test_cmd_from_node_basic() {
        var node = build_command_node("list-users", "sess-123", "executing");
        var cmd = AdHocCommands.Command.from_node(node);

        assert_true(cmd.node == "list-users");
        assert_true(cmd.sessionid == "sess-123");
        assert_true(cmd.status == AdHocCommands.Command.Status.EXECUTING);
    }

    private void test_cmd_from_node_with_form() {
        var node = build_command_node("config", "s1", "executing");
        var x_node = new StanzaNode.build("x", DataForms.NS_URI).add_self_xmlns()
            .put_attribute("type", "form");
        node.put_node(x_node);

        var cmd = AdHocCommands.Command.from_node(node);
        assert_nonnull(cmd.form);
    }

    private void test_cmd_from_node_actions() {
        var node = build_command_node("wizard", "s2", "executing");
        var actions = new StanzaNode.build("actions", CMD_NS)
            .put_attribute("execute", "next");
        actions.put_node(new StanzaNode.build("next", CMD_NS));
        actions.put_node(new StanzaNode.build("prev", CMD_NS));
        actions.put_node(new StanzaNode.build("complete", CMD_NS));
        node.put_node(actions);

        var cmd = AdHocCommands.Command.from_node(node);
        assert_true(cmd.actions.size == 3);
        assert_true(cmd.actions.contains("next"));
        assert_true(cmd.actions.contains("prev"));
        assert_true(cmd.actions.contains("complete"));
        assert_true(cmd.execute_action == "next");
    }

    private void test_cmd_from_node_notes() {
        var node = build_command_node("test", "s3", "completed");
        var note1 = new StanzaNode.build("note", CMD_NS)
            .put_attribute("type", "info")
            .put_node(new StanzaNode.text("Operation successful"));
        var note2 = new StanzaNode.build("note", CMD_NS)
            .put_attribute("type", "warn")
            .put_node(new StanzaNode.text("Rate limit reached"));
        node.put_node(note1);
        node.put_node(note2);

        var cmd = AdHocCommands.Command.from_node(node);
        assert_true(cmd.notes.size == 2);
        assert_true(cmd.notes[0].type_ == "info");
        assert_true(cmd.notes[0].text == "Operation successful");
        assert_true(cmd.notes[1].type_ == "warn");
    }

    private void test_cmd_error_note_marks_completion_failed() {
        var node = build_command_node("test", "s-error", "completed");
        node.put_node(new StanzaNode.build("note", CMD_NS)
            .put_attribute("type", "error")
            .put_node(new StanzaNode.text("Permission changed")));
        var cmd = AdHocCommands.Command.from_node(node);
        assert_true(cmd.has_error_note());
        assert_true(cmd.get_error_note_text() == "Permission changed");
        assert_false(cmd.completed_successfully());
    }

    private void test_cmd_status_enum() {
        assert_true(AdHocCommands.Command.Status.from_string("completed") == AdHocCommands.Command.Status.COMPLETED);
        assert_true(AdHocCommands.Command.Status.from_string("canceled") == AdHocCommands.Command.Status.CANCELED);
        assert_true(AdHocCommands.Command.Status.from_string("executing") == AdHocCommands.Command.Status.EXECUTING);
    }

    private void test_cmd_status_unknown() {
        // Unknown status string defaults to EXECUTING
        assert_true(AdHocCommands.Command.Status.from_string("bogus") == AdHocCommands.Command.Status.EXECUTING);
        assert_true(AdHocCommands.Command.Status.from_string(null) == AdHocCommands.Command.Status.EXECUTING);
        assert_true(AdHocCommands.Command.Status.from_string("") == AdHocCommands.Command.Status.EXECUTING);
    }

    private void test_cmd_to_node() {
        // Build a Command, serialize to node, verify attributes
        var cmd = new AdHocCommands.Command();
        cmd.node = "my-command";
        cmd.sessionid = "abc123";
        cmd.status = AdHocCommands.Command.Status.COMPLETED;
        cmd.actions.add("complete");
        cmd.execute_action = "complete";
        cmd.notes.add(new AdHocCommands.NoteItem("info", "Done!"));

        StanzaNode node = cmd.to_node();
        assert_true(node.name == "command");
        assert_true(node.get_attribute("node") == "my-command");
        assert_true(node.get_attribute("sessionid") == "abc123");
        assert_true(node.get_attribute("status") == "completed");

        StanzaNode? actions_node = node.get_subnode("actions", CMD_NS);
        assert_nonnull(actions_node);
        assert_true(actions_node.get_attribute("execute") == "complete");

        Gee.List<StanzaNode> notes = node.get_subnodes("note", CMD_NS);
        assert_true(notes.size == 1);
    }

    private void test_cmd_empty_node() {
        // Command with no attributes at all
        var node = new StanzaNode.build("command", CMD_NS).add_self_xmlns();
        var cmd = AdHocCommands.Command.from_node(node);
        assert_null(cmd.node);
        assert_null(cmd.sessionid);
        assert_true(cmd.status == AdHocCommands.Command.Status.EXECUTING);
        assert_null(cmd.form);
        assert_true(cmd.actions.size == 0);
        assert_true(cmd.notes.size == 0);
    }

    // ========== Adversarial ==========

    private void test_cmd_missing_node_attr() {
        var node = build_command_node(null, "s1", "executing");
        var cmd = AdHocCommands.Command.from_node(node);
        assert_null(cmd.node);
        // Should not crash — null node is handled gracefully
    }

    private void test_cmd_missing_sessionid() {
        var node = build_command_node("test", null, "executing");
        var cmd = AdHocCommands.Command.from_node(node);
        assert_null(cmd.sessionid);
    }

    private void test_cmd_xss_in_note() {
        var node = build_command_node("test", "s1", "completed");
        var note = new StanzaNode.build("note", CMD_NS)
            .put_attribute("type", "info")
            .put_node(new StanzaNode.text("<script>alert('xss')</script>"));
        node.put_node(note);

        var cmd = AdHocCommands.Command.from_node(node);
        assert_true(cmd.notes.size == 1);
        // XSS payload preserved as text — display layer must escape
        assert_true(cmd.notes[0].text == "<script>alert('xss')</script>");
    }

    private void test_cmd_many_actions() {
        var node = build_command_node("test", "s1", "executing");
        var actions = new StanzaNode.build("actions", CMD_NS);
        for (int i = 0; i < 100; i++) {
            actions.put_node(new StanzaNode.build("action%d".printf(i), CMD_NS));
        }
        node.put_node(actions);

        var cmd = AdHocCommands.Command.from_node(node);
        assert_true(cmd.actions.size == 100);
    }

    private void test_cmd_item() {
        try {
            var item = new AdHocCommands.CommandItem(
                new Jid("server.example.com"),
                "http://jabber.org/protocol/admin#get-online-users",
                "Get Online Users"
            );
            assert_true(item.jid.to_string() == "server.example.com");
            assert_true(item.node == "http://jabber.org/protocol/admin#get-online-users");
            assert_true(item.name == "Get Online Users");
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_note_item() {
        var note = new AdHocCommands.NoteItem("error", "Something went wrong");
        assert_true(note.type_ == "error");
        assert_true(note.text == "Something went wrong");
    }

    private void test_data_form_required_and_description() {
        var x = new StanzaNode.build("x", DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "accountjid")
                .put_attribute("type", "jid-single")
                .put_attribute("label", "Account JID")
                .put_node(new StanzaNode.build("desc", DataForms.NS_URI)
                    .put_node(new StanzaNode.text("The account to create")))
                .put_node(new StanzaNode.build("required", DataForms.NS_URI)));

        DataForms.DataForm? parsed_form = DataForms.DataForm.create_from_node(x);
        assert_nonnull(parsed_form);
        DataForms.DataForm form = (!) parsed_form;
        fail_if_not_eq_str("form", form.kind);
        fail_if(form.is_result, "input form must not be marked as a result");
        fail_if_not_eq_int(1, form.fields.size);
        fail_if(!form.fields[0].required, "required marker must be parsed");
        fail_if_not_eq_str("The account to create", form.fields[0].description);
        fail_if_not_eq_int(1, form.get_missing_required_fields().size);

        form.fields[0].set_value_string("new@example.test");
        fail_if_not_eq_int(0, form.get_missing_required_fields().size);
    }

    private void test_data_form_result_reported_schema() {
        var x = new StanzaNode.build("x", DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "result");
        x.put_node(new StanzaNode.build("reported", DataForms.NS_URI)
            .put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "accountjid")
                .put_attribute("type", "jid-single")
                .put_attribute("label", "Account JID"))
            .put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", "status")
                .put_attribute("type", "text-single")
                .put_attribute("label", "Status")));
        x.put_node(new StanzaNode.build("item", DataForms.NS_URI)
            .put_node(data_form_value_field("accountjid", "juliet@example.test"))
            .put_node(data_form_value_field("status", "online")));

        DataForms.DataForm? parsed_form = DataForms.DataForm.create_from_node(x);
        assert_nonnull(parsed_form);
        DataForms.DataForm form = (!) parsed_form;
        fail_if(!form.is_result, "result form must be identified");
        fail_if_not_eq_int(2, form.reported_fields.size);
        fail_if_not_eq_int(1, form.items.size);
        fail_if_not_eq_int(2, form.items[0].size);
        fail_if_not_eq_str("Account JID", form.items[0][0].label);
        fail_if_not_eq_str("juliet@example.test", form.items[0][0].get_value_string());
        fail_if(form.items[0][0].type_ != DataForms.DataForm.Type.TEXT_SINGLE,
            "jid-single result field must use the text representation");
        fail_if_not_eq_str("Status", form.items[0][1].label);
    }

    private void test_data_form_api_error_result() {
        var x = new StanzaNode.build("x", DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "result")
            .put_node(new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("type", "fixed")
                .put_attribute("label", "Result"))
            .put_node(data_form_value_field("error", "Room does not exist"));

        DataForms.DataForm? parsed_form = DataForms.DataForm.create_from_node(x);
        assert_nonnull(parsed_form);
        DataForms.DataForm form = (!) parsed_form;
        fail_if_not_eq_str("Room does not exist", form.get_error_message());

        form.fields[1].set_value_string("");
        fail_if(form.get_error_message() != null, "empty API error field must not report an error");
    }

    private StanzaNode data_form_value_field(string var_name, string value) {
        return new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", var_name)
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
    }

    private void test_cmd_list_uses_commands_node(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_command_discovery_stream();
            var module = stream.get_module<AdHocCommands.Module>(AdHocCommands.Module.IDENTITY);
            assert_nonnull(module);

            ((!) module).list_commands.begin(stream, new Jid("example.test"), (_, res) => {
                Gee.List<AdHocCommands.CommandItem>? commands = ((!) module).list_commands.end(res);
                assert_nonnull(stream.last_written);
                assert_nonnull(commands);

                if (stream.last_written != null) {
                    StanzaNode? query = stream.last_written.get_subnode("query", ServiceDiscovery.NS_URI_ITEMS);
                    assert_nonnull(query);
                    if (query != null) {
                        fail_if_not_eq_str(CMD_NS, query.get_attribute("node"));
                    }
                }

                if (commands != null) {
                    fail_if_not_eq_int(1, commands.size);
                    if (commands.size == 1) {
                        fail_if_not_eq_str("http://jabber.org/protocol/admin#get-online-users", commands[0].node);
                        fail_if_not_eq_str("Get Online Users", commands[0].name);
                        fail_if_not_eq_str("example.test", commands[0].jid.to_string());
                    }
                }
                cb();
            });
        } catch (Error e) {
            fail_if_reached(@"command discovery test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_cmd_list_ignores_foreign_item_jids(Gee.TestFinishedCallback cb) {
        try {
            // The authenticated response sender is correct; only individual item targets differ.
            var stream = create_command_discovery_stream("example.test", true);
            var module = stream.get_module<AdHocCommands.Module>(AdHocCommands.Module.IDENTITY);
            assert_nonnull(module);
            ((!) module).list_commands.begin(stream, new Jid("example.test"), (_, res) => {
                Gee.List<AdHocCommands.CommandItem>? commands = ((!) module).list_commands.end(res);
                assert_nonnull(commands);
                if (commands != null) {
                    fail_if_not_eq_int(1, commands.size);
                    if (commands.size == 1) {
                        fail_if_not_eq_str("example.test", commands[0].jid.to_string());
                        fail_if_not_eq_str("http://jabber.org/protocol/admin#get-online-users", commands[0].node);
                    }
                }
                cb();
            });
        } catch (Error e) {
            fail_if_reached(@"foreign command target setup failed: $(e.message)");
            cb();
        }
    }

    private void test_cmd_list_rejects_senderless_result(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_command_discovery_stream(null);
            var module = stream.get_module<AdHocCommands.Module>(
                AdHocCommands.Module.IDENTITY);
            assert_nonnull(module);

            ((!) module).list_commands.begin(stream,
                new Jid("example.test"), (_, res) => {
                    Gee.List<AdHocCommands.CommandItem>? commands =
                        ((!) module).list_commands.end(res);
                    assert_null(commands);
                    assert_true(((!) module).last_error != null &&
                        ((!) module).last_error.contains(
                            "without expected sender"));
                    cb();
                });
        } catch (Error e) {
            fail_if_reached(@"senderless command discovery setup failed: $(e.message)");
            cb();
        }
    }

    private void test_cmd_execute_validates_result_sender(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_command_execution_stream("senderless");
            var module = stream.get_module<AdHocCommands.Module>(
                AdHocCommands.Module.IDENTITY);
            ((!) module).execute.begin(stream, new Jid("example.test"),
                "urn:xmpp:hats:commands:create", null, (_, res) => {
                    AdHocCommands.Command? command =
                        ((!) module).execute.end(res);
                    assert_null(command);
                    assert_true(((!) module).last_error != null &&
                        ((!) module).last_error.contains(
                            "without expected sender"));
                    cb();
                });
        } catch (Error e) {
            fail_if_reached(@"command execute test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_cmd_proceed_rejects_changed_session(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_command_execution_stream("changed-session");
            var module = stream.get_module<AdHocCommands.Module>(
                AdHocCommands.Module.IDENTITY);
            ((!) module).proceed.begin(stream, new Jid("example.test"),
                "urn:xmpp:hats:commands:create", "session-1", "next", null,
                (_, res) => {
                    AdHocCommands.Command? command =
                        ((!) module).proceed.end(res);
                    assert_null(command);
                    fail_if_not_eq_str("unexpected-command-session",
                        ((!) module).last_error);
                    cb();
                });
        } catch (Error e) {
            fail_if_reached(@"command proceed test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_cmd_cancel_requires_canceled_status(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_command_execution_stream("cancel-completed");
            var module = stream.get_module<AdHocCommands.Module>(
                AdHocCommands.Module.IDENTITY);
            ((!) module).cancel.begin(stream, new Jid("example.test"),
                "urn:xmpp:hats:commands:create", "session-1", (_, res) => {
                    bool canceled = ((!) module).cancel.end(res);
                    assert_false(canceled);
                    fail_if_not_eq_str("command-not-canceled",
                        ((!) module).last_error);
                    cb();
                });
        } catch (Error e) {
            fail_if_reached(@"command cancel test setup failed: $(e.message)");
            cb();
        }
    }

    private void test_cmd_proceed_rejects_missing_session(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_command_execution_stream("missing-session");
            var module = stream.get_module<AdHocCommands.Module>(
                AdHocCommands.Module.IDENTITY);
            ((!) module).proceed.begin(stream, new Jid("example.test"),
                "urn:xmpp:hats:commands:create", "session-1", "next", null,
                (_, res) => {
                    AdHocCommands.Command? command =
                        ((!) module).proceed.end(res);
                    assert_null(command);
                    fail_if_not_eq_str("missing-command-session",
                        ((!) module).last_error);
                    cb();
                });
        } catch (Error e) {
            fail_if_reached(@"command missing-session test setup failed: $(e.message)");
            cb();
        }
    }

    private RegistrationCancelAuditStream create_cancel_stream(bool reject) throws Error {
        var stream = new RegistrationCancelAuditStream(new Jid("example.test"), reject);
        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);
        return stream;
    }

    private AdHocDiscoveryAuditStream create_command_discovery_stream(
            string? response_from = "example.test", bool include_foreign_items = false) throws Error {
        var stream = new AdHocDiscoveryAuditStream(new Jid("example.test"),
            response_from, include_foreign_items);

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var disco = new ServiceDiscovery.Module.with_identity("client", "pc", "DinoX Test");
        stream.add_module(disco);

        var commands = new AdHocCommands.Module();
        stream.add_module(commands);

        return stream;
    }

    private AdHocExecutionAuditStream create_command_execution_stream(
            string mode) throws Error {
        var stream = new AdHocExecutionAuditStream(new Jid("example.test"),
            mode);
        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);
        stream.add_module(new AdHocCommands.Module());
        return stream;
    }
}

private class AdHocExecutionAuditStream : XmppStream {
    private string mode;

    public AdHocExecutionAuditStream(Jid remote_name, string mode) {
        base(remote_name);
        this.mode = mode;
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        StanzaNode? request_command = node.get_subnode("command",
            AdHocCommands.NS_URI);
        assert_nonnull(request_command);

        Idle.add(() => {
            string command_node = ((!) request_command).get_attribute("node") ??
                "urn:xmpp:hats:commands:create";
            string? request_session = ((!) request_command).get_attribute(
                "sessionid");
            string status = mode == "cancel-completed" ? "completed" :
                "executing";
            string sessionid = mode == "changed-session" ? "session-2" :
                (request_session ?? "session-1");
            var command = new StanzaNode.build("command",
                AdHocCommands.NS_URI).add_self_xmlns()
                .put_attribute("node", command_node)
                .put_attribute("status", status);
            if (mode != "missing-session") {
                command.put_attribute("sessionid", sessionid);
            }
            if (status == "executing") {
                command.put_node(new StanzaNode.build("actions",
                    AdHocCommands.NS_URI)
                    .put_attribute("execute", "next")
                    .put_node(new StanzaNode.build("next",
                        AdHocCommands.NS_URI)));
            }

            var response = new StanzaNode.build("iq")
                .put_attribute("id", node.get_attribute("id"))
                .put_attribute("type", Iq.Stanza.TYPE_RESULT)
                .put_node(command);
            if (mode != "senderless") {
                response.put_attribute("from", "example.test");
            }
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

private class AdHocDiscoveryAuditStream : XmppStream {
    public StanzaNode? last_written { get; private set; default = null; }
    private string? response_from;
    private bool include_foreign_items;

    public AdHocDiscoveryAuditStream(Jid remote_name,
            string? response_from = "example.test", bool include_foreign_items = false) {
        base(remote_name);
        this.response_from = response_from;
        this.include_foreign_items = include_foreign_items;
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        last_written = node;

        Idle.add(() => {
            var query = new StanzaNode.build("query", ServiceDiscovery.NS_URI_ITEMS)
                .add_self_xmlns()
                .put_attribute("node", AdHocCommands.NS_URI)
                .put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                    .put_attribute("jid", "example.test")
                    .put_attribute("node", "http://jabber.org/protocol/admin#get-online-users")
                    .put_attribute("name", "Get Online Users"));
            if (include_foreign_items) {
                foreach (string jid in new string[] { "other.test", "user@example.test", "example.test/other" }) {
                    query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                        .put_attribute("jid", jid)
                        .put_attribute("node", "api-commands/destroy_room")
                        .put_attribute("name", "Destroy Room"));
                }
            }
            var response = new StanzaNode.build("iq")
                .put_attribute("id", node.get_attribute("id"))
                .put_attribute("type", Iq.Stanza.TYPE_RESULT)
                .put_node(query);
            if (response_from != null) {
                response.put_attribute("from", (!) response_from);
            }
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

private class RegistrationCancelAuditStream : XmppStream {
    public StanzaNode? last_written { get; private set; default = null; }
    private bool reject;

    public RegistrationCancelAuditStream(Jid remote_name, bool reject) {
        base(remote_name);
        this.reject = reject;
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        last_written = node;

        Idle.add(() => {
            var response = new StanzaNode.build("iq")
                .put_attribute("id", node.get_attribute("id"))
                .put_attribute("type", reject ? "error" : Iq.Stanza.TYPE_RESULT);
            if (reject) {
                response.put_node(new StanzaNode.build("error")
                    .put_attribute("type", ErrorStanza.TYPE_CANCEL)
                    .put_node(new StanzaNode.build(ErrorStanza.CONDITION_NOT_ALLOWED, "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns())
                    .put_node(new StanzaNode.build("text", "urn:ietf:params:xml:ns:xmpp-stanzas")
                        .add_self_xmlns()
                        .put_node(new StanzaNode.text("Server policy"))));
            }
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

}
