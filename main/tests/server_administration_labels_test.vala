using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui.Test {

class ServerAdministrationLabelsTest : Gee.TestCase {
    public ServerAdministrationLabelsTest() {
        base("ServerAdministrationLabels");
        add_test("multistep_destruction_is_only_confirmed_at_submission", test_steps);
        add_test("unknown_commands_preserve_server_name", test_unknown);
        add_test("bulk_and_non_room_destructive_commands_require_confirmation", test_destructive);
        add_test("all_prosody_core_commands_have_task_labels", test_prosody);
        add_test("same_task_from_different_interfaces_remains_distinguishable", test_interface_titles);
        add_test("domain_connection_and_scheduled_variants_have_distinct_labels", test_variants);
        add_test("unknown_same_name_commands_keep_their_identity_visible", test_same_name);
        add_test("server_interfaces_follow_only_the_selected_account_commands", test_interfaces);
        add_test("password_reset_cannot_target_another_server", test_reset_scope);
        add_test("ambiguous_api_forms_are_rejected_without_rewriting", test_duplicate_fields);
        add_test("persistent_deletion_and_recovery_actions_have_confirmation", test_data_actions);
        add_test("roster_filter_confirmation_depends_on_selected_action", test_roster_action);
        add_test("only_known_immediate_actions_wait_before_execute", test_immediate_action);
        add_test("user_picker_never_reads_a_list_from_another_target", test_user_list_target);
    }

    private void test_steps() {
        var labels = labels_for("api-commands/destroy_room");
        assert_false(labels.requires_confirmation("next"));
        assert_false(labels.requires_confirmation("prev"));
        assert_true(labels.requires_confirmation("complete"));
        assert_true(labels.requires_confirmation(""));
        fail_if_not_eq_str(_("Next"), labels.action_label("next"));
        fail_if_not_eq_str(_("Previous"), labels.action_label("prev"));
        assert_true(labels.action_label("complete") != labels.action_label("next"));
    }

    private void test_unknown() {
        var item = new AdHocCommands.CommandItem(server_jid(),
            "api-commands/future_plugin_command", "Custom command: Привет & <test>");
        var labels = Util.ServerAdministrationLabels.for_command(item);
        fail_if_not_eq_str(item.name, labels.title);
        assert_false(labels.destructive);
        assert_false(labels.requires_confirmation("complete"));
        fail_if_not_eq_str(_("Run command"), labels.action_label("complete"));
        var bare = new AdHocCommands.CommandItem(server_jid(), "restart", "Custom bare command");
        fail_if_not_eq_str(bare.name, Util.ServerAdministrationLabels.for_command(bare).title);
        var unknown_api = new AdHocCommands.CommandItem(server_jid(), "api-commands/add-user", "Custom API extension");
        fail_if_not_eq_str(unknown_api.name, Util.ServerAdministrationLabels.for_command(unknown_api).title);
        var unknown_standard = new AdHocCommands.CommandItem(server_jid(),
            "http://jabber.org/protocol/admin#register", "Custom standard extension");
        fail_if_not_eq_str(unknown_standard.name, Util.ServerAdministrationLabels.for_command(unknown_standard).title);
    }

    private void test_destructive() {
        string[] nodes = { "api-commands/rooms_empty_destroy", "api-commands/rooms_unused_destroy",
            "api-commands/destroy_rooms_file", "api-commands/delete_old_users", "api-commands/delete_old_users_vhost",
            "http://jabber.org/protocol/admin#delete-user",
            "api-commands/stop", "http://prosody.im/protocol/hosts#deactivate" };
        foreach (string node in nodes) {
            assert_true(labels_for(node).requires_confirmation("complete"), node);
            assert_false(labels_for(node).requires_confirmation("next"), node);
        }
        assert_false(labels_for("api-commands/status").requires_confirmation("complete"));
        assert_false(labels_for("api-commands/rooms_empty_list").requires_confirmation("complete"));
    }

    private void test_prosody() {
        string[] names = { "config#reload", "s2s#list", "modules#list", "modules#load",
            "modules#global-load", "modules#reload", "modules#global-reload", "modules#unload",
            "modules#global-unload", "hosts#activate", "hosts#deactivate" };
        foreach (string name in names) {
            string node = "http://prosody.im/protocol/" + name;
            assert_true(labels_for(node).title != "Server title", node);
        }
    }

    private void test_interface_titles() {
        var commands = new Gee.ArrayList<AdHocCommands.CommandItem>();
        var standard = new AdHocCommands.CommandItem(server_jid(),
            "http://jabber.org/protocol/admin#add-user", "Create user");
        var api = new AdHocCommands.CommandItem(server_jid(), "api-commands/register", "Register");
        commands.add(standard);
        commands.add(api);
        var titles = Util.ServerAdministrationLabels.list_titles(commands);
        assert_true(titles[standard] != titles[api]);
        assert_true(titles[standard].contains(_("Standard administration")));
        assert_true(titles[api].contains(_("ejabberd API")));
        // A server offering only one interface keeps the concise task title.
        commands.remove(api);
        titles = Util.ServerAdministrationLabels.list_titles(commands);
        fail_if_not_eq_str(labels_for(standard.node).title, titles[standard]);
        fail_if_not_eq_str("http://jabber.org/protocol/admin#add-user", standard.node);
        fail_if_not_eq_str("api-commands/register", api.node);
    }

    private void test_variants() {
        assert_distinct_labels({ "http://jabber.org/protocol/admin#get-online-users-list", "api-commands/connected_users", "api-commands/connected_users_vhost" });
        assert_distinct_labels({ "http://jabber.org/protocol/admin#get-online-users-num", "api-commands/connected_users_number" });
        assert_distinct_labels({ "api-commands/kick_user", "api-commands/kick_users", "api-commands/kick_session" });
        assert_distinct_labels({ "api-commands/delete_old_users", "api-commands/delete_old_users_vhost" });
        assert_distinct_labels({ "api-commands/restart", "api-commands/restart_kindly" });
        assert_distinct_labels({ "api-commands/stop", "api-commands/stop_kindly", "api-commands/halt" });
    }

    private void assert_distinct_labels(string[] nodes) {
        var titles = new Gee.HashSet<string>();
        foreach (string node in nodes) assert_true(titles.add(labels_for(node).title), node);
    }

    private void test_same_name() {
        var commands = new Gee.ArrayList<AdHocCommands.CommandItem>();
        string name = "Команды <test> & server";
        var first = new AdHocCommands.CommandItem(server_jid(), "api-commands/plugin_one", name);
        var second = new AdHocCommands.CommandItem(server_jid(), "api-commands/plugin_two", name);
        commands.add(first);
        commands.add(second);
        var titles = Util.ServerAdministrationLabels.list_titles(commands);
        assert_true(titles[first] != titles[second]);
        assert_true(titles[first].contains(name));
        assert_true(titles[first].contains(first.node));
        assert_true(titles[second].contains(second.node));
        fail_if_not_eq_str(name, Util.ServerAdministrationLabels.for_command(first).title);
    }

    private void test_interfaces() {
        var ejabberd_commands = new Gee.ArrayList<AdHocCommands.CommandItem>();
        ejabberd_commands.add(new AdHocCommands.CommandItem(server_jid(), "api-commands/register", "Create"));
        var prosody_commands = new Gee.ArrayList<AdHocCommands.CommandItem>();
        prosody_commands.add(new AdHocCommands.CommandItem(server_jid(), "http://prosody.im/protocol/modules#list", "Modules"));
        string ejabberd = Util.ServerAdministrationLabels.available_interfaces(ejabberd_commands);
        string prosody = Util.ServerAdministrationLabels.available_interfaces(prosody_commands);
        fail_if_not_eq_str(_("Server: %s\nAdministration: %s").printf("ejabberd", _("ejabberd API")), ejabberd);
        fail_if_not_eq_str(_("Server: %s\nAdministration: %s").printf("Prosody", _("Prosody administration")), prosody);
        assert_true(ejabberd.contains("ejabberd"));
        assert_false(ejabberd.contains("Prosody"));
        assert_true(prosody.contains("Prosody"));
        assert_false(prosody.contains("ejabberd"));
        fail_if_not_eq_str(ejabberd, Util.ServerAdministrationLabels.available_interfaces(ejabberd_commands));
        ejabberd_commands.add(new AdHocCommands.CommandItem(server_jid(), "http://jabber.org/protocol/admin#add-user", "Create"));
        fail_if_not_eq_str(_("Server: %s\nAdministration: %s").printf("ejabberd",
            _("ejabberd API") + " · " + _("Standard administration")),
            Util.ServerAdministrationLabels.available_interfaces(ejabberd_commands));
        ejabberd_commands.clear();
        ejabberd_commands.add(new AdHocCommands.CommandItem(server_jid(), "http://jabber.org/protocol/admin#add-user", "Create"));
        string standard_only = Util.ServerAdministrationLabels.available_interfaces(ejabberd_commands);
        assert_false(standard_only.contains("ejabberd"));
        assert_false(standard_only.contains("Prosody"));
        assert_true(standard_only.contains(_("Standard administration")));
        fail_if_not_eq_str(_("Available administration: %s").printf(_("Standard administration")), standard_only);
        ejabberd_commands.clear();
        fail_if_not_eq_str(_("Administration of advertised services"),
            Util.ServerAdministrationLabels.available_interfaces(ejabberd_commands));
    }

    private Util.ServerAdministrationLabels labels_for(string node) {
        return Util.ServerAdministrationLabels.for_command(
            new AdHocCommands.CommandItem(server_jid(), node, "Server title"));
    }

    private void test_reset_scope() {
        var command = new AdHocCommands.CommandItem(server_jid(),
            "xmpp:prosody.im/mod_invites_adhoc#password-reset", "Reset");
        foreach (string value in new string[] { "alice@other.test", "example.test", "" }) {
            var form = form_with_fields({ input_field("accountjid", value) });
            string before = form.stanza_node.to_string();
            assert_true(Util.ServerAdministrationLabels.submission_error(command, form) != null);
            fail_if_not_eq_str(before, form.stanza_node.to_string());
        }
        var own = form_with_fields({ input_field("accountjid", "alice@example.test") });
        string before = own.stanza_node.to_string();
        assert_true(Util.ServerAdministrationLabels.submission_error(command, own) == null);
        fail_if_not_eq_str(before, own.stanza_node.to_string());
        // Other commands retain their own server-defined account scope.
        command = new AdHocCommands.CommandItem(server_jid(), "api-commands/generate_reset_token", "Reset");
        var foreign = form_with_fields({ input_field("host", "other.test") });
        assert_true(Util.ServerAdministrationLabels.submission_error(command, foreign) == null);
    }

    private void test_duplicate_fields() {
        foreach (string name in new string[] { "get_roster", "get_roster_count", "get_mam_count", "get_offline_count" }) {
            var command = new AdHocCommands.CommandItem(server_jid(), "api-commands/" + name, "Query");
            var broken = form_with_fields({ input_field("user", "alice"), input_field("host", "example.test"),
                input_field("user", "bob"), input_field("host", "other.test") });
            string before = broken.stanza_node.to_string();
            assert_true(Util.ServerAdministrationLabels.submission_error(command, broken) != null);
            fail_if_not_eq_str(before, broken.stanza_node.to_string());
            var corrected = form_with_fields({ input_field("user", "alice"), input_field("host", "example.test") });
            assert_true(Util.ServerAdministrationLabels.submission_error(command, corrected) == null);
        }
        var extension = new AdHocCommands.CommandItem(server_jid(), "api-commands/custom_query", "Query");
        var form = form_with_fields({ input_field("user", "alice"), input_field("user", "bob") });
        assert_true(Util.ServerAdministrationLabels.submission_error(extension, form) == null);
    }

    private void test_data_actions() {
        fail_if_not_eq_str(_("List Group Chats with Empty Archives"), labels_for("api-commands/rooms_empty_list").title);
        fail_if_not_eq_str(_("Delete Group Chats with Empty Archives"), labels_for("api-commands/rooms_empty_destroy").title);
        foreach (string name in new string[] { "delete_expired_messages", "delete_old_messages", "delete_old_messages_batch",
            "delete_old_mam_messages", "delete_old_mam_messages_batch", "remove_mam_for_user", "remove_mam_for_user_with_peer",
            "delete_expired_pubsub_items", "delete_old_pubsub_items", "delete_old_push_sessions", "delete_mnesia",
            "oauth_remove_client", "oauth_revoke_token", "revoke_certificate", "module_uninstall", "module_install",
            "module_upgrade", "compile", "update", "update_sql", "convert_to_scram", "restore", "load", "install_fallback",
            "import_file", "import_dir", "import_piefxis", "import_prosody", "import_db", "mnesia_table_change_storage",
            "set_master", "join_cluster", "join_cluster_here", "leave_cluster", "evacuate_kindly" }) {
            var labels = labels_for("api-commands/" + name);
            assert_true(labels.requires_confirmation("complete"), name);
            assert_false(labels.requires_confirmation("next"), name);
            assert_false(labels.requires_confirmation("prev"), name);
            assert_true(labels.title != "Server title" && labels.submit_label != _("Run command"), name);
        }
        assert_false(labels_for("api-commands/list_invites").requires_confirmation("complete"));
        assert_false(labels_for("api-commands/registered_users").requires_confirmation("complete"));
        assert_false(labels_for("api-commands/delete_rosteritem").requires_confirmation("complete"));
    }

    private void test_roster_action() {
        var labels = labels_for("api-commands/process_rosteritems");
        var list = form_with_fields({ input_field("action", "list") });
        var delete = form_with_fields({ input_field("action", "delete") });
        assert_false(labels.requires_confirmation("complete", list));
        assert_true(labels.requires_confirmation("complete", delete));
        assert_false(labels.requires_confirmation("next", delete));
        assert_false(labels.requires_confirmation("prev", delete));
        assert_false(labels_for("api-commands/custom_query").requires_confirmation("complete", delete));
    }

    private void test_immediate_action() {
        assert_true(Util.ServerAdministrationLabels.executes_immediately(
            new AdHocCommands.CommandItem(server_jid(), "http://prosody.im/protocol/config#reload", "Reload")));
        foreach (string node in new string[] { "api-commands/reload_config", "http://prosody.im/protocol/modules#reload", "custom#reload" }) {
            assert_false(Util.ServerAdministrationLabels.executes_immediately(
                new AdHocCommands.CommandItem(server_jid(), node, "Reload")));
        }
    }

    private StanzaNode input_field(string variable, string value) {
        return new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", variable).put_attribute("type", "text-single")
            .put_node(new StanzaNode.build("value", DataForms.NS_URI).put_node(new StanzaNode.text(value)));
    }

    private void test_user_list_target() {
        try {
            string node = "http://jabber.org/protocol/admin#get-registered-users-list";
            var second_target = new Jid("conference.example.test");
            var commands = new Gee.ArrayList<AdHocCommands.CommandItem>();
            var primary = new AdHocCommands.CommandItem(server_jid(), node, "Accounts");
            var component = new AdHocCommands.CommandItem(second_target, node, "Accounts");
            commands.add(primary);
            assert_true(Util.ServerAdministrationLabels.find_command_at_target(commands, node, second_target) == null);
            commands.add(component);
            assert_true(Util.ServerAdministrationLabels.find_command_at_target(commands, node, second_target) == component);
            assert_true(Util.ServerAdministrationLabels.find_command_at_target(commands, node, server_jid()) == primary);
            assert_true(Util.ServerAdministrationLabels.find_command_at_target(commands,
                "http://jabber.org/protocol/admin#get-disabled-users-list", second_target) == null);
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private DataForms.DataForm form_with_fields(StanzaNode[] fields) {
        var node = new StanzaNode.build("x", DataForms.NS_URI).add_self_xmlns().put_attribute("type", "form");
        foreach (StanzaNode field in fields) node.put_node(field);
        var form = DataForms.DataForm.create_from_node(node);
        assert_true(form != null);
        return (!) form;
    }

    private Jid server_jid() {
        try {
            return new Jid("example.test");
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }
}
}
