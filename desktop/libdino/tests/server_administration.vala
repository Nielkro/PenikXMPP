using Gee;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

public class ServerAdministrationTest : Gee.TestCase {
    public ServerAdministrationTest() {
        base("ServerAdministration");
        add_test("admin_command_classification", test_admin_command_classification);
        add_test("ejabberd_api_command_classification", test_ejabberd_api_command_classification);
        add_test("account_management_api_grouping", test_account_management_api_grouping);
        add_test("server_operations_and_queries_grouping", test_server_operations_and_queries_grouping);
        add_test("prosody_admin_command_classification", test_prosody_admin_command_classification);
        add_test("prosody_only_server_commands_are_account_scoped", test_prosody_only_server_commands_are_account_scoped);
        add_test("single_prosody_admin_command_is_retained", test_single_prosody_admin_command_is_retained);
        add_test("normal_commands_do_not_grant_admin", test_normal_commands_do_not_grant_admin);
        add_test("read_only_api_commands_do_not_grant_admin", test_read_only_api_commands_do_not_grant_admin);
        add_test("single_management_api_command_is_retained", test_single_management_api_command_is_retained);
        add_test("other_read_only_and_unknown_api_commands_do_not_grant_admin", test_other_read_only_and_unknown_api_commands_do_not_grant_admin);
        add_test("latest_management_subsets_preserve_account_isolation", test_latest_management_subsets_preserve_account_isolation);
        add_test("known_queries_tools_and_future_aliases_do_not_grant_admin", test_known_queries_tools_and_future_aliases_do_not_grant_admin);
        add_test("latest_api_domains_are_exact_and_independent_of_access", test_latest_api_domains_are_exact_and_independent_of_access);
        add_test("admin_api_commands_are_retained", test_admin_api_commands_are_retained);
        add_test("xep0133_only_server_is_supported", test_xep0133_only_server_is_supported);
        add_test("commands_are_account_scoped", test_commands_are_account_scoped);
        add_test("discovery_deduplicates_only_command_identity", test_discovery_deduplicates_only_command_identity);
        add_test("shared_invite_nodes_require_independent_admin_access", test_shared_invite_nodes_require_independent_admin_access);
        add_test("remaining_prosody_core_admin_nodes", test_remaining_prosody_core_admin_nodes);
        add_test("ejabberd_native_node_administration_is_exact", test_ejabberd_native_node_administration_is_exact);
        add_test("restricted_invite_api_management", test_restricted_invite_api_management);
        add_test("authenticated_components_are_discovered_without_crawling", test_authenticated_components_are_discovered_without_crawling);
        add_test("component_discovery_rejects_unproven_services", test_component_discovery_rejects_unproven_services);
        add_test("component_discovery_retries_once", test_component_discovery_retries_once);
        add_test("component_discovery_discards_old_generation_and_stream", test_component_discovery_discards_old_generation_and_stream);
        add_test("stale_discovery_is_ignored", test_stale_discovery_is_ignored);
        add_test("clear_invalidates_pending_discovery", test_clear_invalidates_pending_discovery);
        add_test("fresh_resumed_and_same_stream_recover_admin_discovery",
            test_fresh_resumed_and_same_stream_recover_admin_discovery);
        add_test("command_state_validates_server_response", test_command_state_validates_server_response);
        add_test("command_state_handles_multistep_actions", test_command_state_handles_multistep_actions);
        add_test("command_state_marks_canceled", test_command_state_marks_canceled);
    }

    private void test_admin_command_classification() {
        var admin = command("http://jabber.org/protocol/admin#get-online-users", "Get Online Users");
        var empty_admin = command("http://jabber.org/protocol/admin#", "Administration");
        var invite = command("urn:xmpp:invite#invite", "Create Invitation");

        fail_if(!ServerAdministrationManager.is_admin_command(admin), "XEP-0133 command must be administrative");
        fail_if(ServerAdministrationManager.is_admin_command(empty_admin), "empty XEP-0133 command node must be rejected");
        fail_if(ServerAdministrationManager.is_admin_command(invite), "normal ad-hoc command must not be administrative");
    }

    private void test_ejabberd_api_command_classification() {
        var roster = command("api-commands/add_rosteritem", "Add Rosteritem");
        var muc = command("api-commands/create_room", "Create Room");
        var server = command("api-commands/reload_config", "Reload Config");
        var invalid = command("api-commands/", "API Commands");

        fail_if(ServerAdministrationManager.get_command_source(roster) !=
            ServerAdministrationCommandSource.EJABBERD_API, "ejabberd API origin must be retained");
        fail_if(ServerAdministrationManager.get_command_category(roster) !=
            ServerAdministrationCommandCategory.ROSTER, "roster API command must be categorized as roster");
        fail_if(ServerAdministrationManager.get_command_category(muc) !=
            ServerAdministrationCommandCategory.MUC, "MUC API command must be categorized as MUC");
        fail_if(ServerAdministrationManager.get_command_category(server) !=
            ServerAdministrationCommandCategory.SERVER, "server API command must be categorized as server");
        fail_if(ServerAdministrationManager.is_admin_command(invalid), "empty API command node must be rejected");
    }

    private void test_normal_commands_do_not_grant_admin() {
        var state = new ServerAdministrationState();
        Account account = account("user@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add(command("urn:xmpp:invite#invite", "Create Invitation"));

        uint generation = state.begin_discovery(account);
        fail_if(!state.complete_discovery(account, generation, commands), "current discovery must be accepted");
        fail_if(state.has_admin_accounts(), "normal commands must not expose server administration");
        fail_if(state.get_commands(account).size != 0, "normal commands must not be stored as admin commands");
    }

    private void test_account_management_api_grouping() {
        foreach (string name in new string[] {
            "unban_account", "delete_old_users", "delete_old_users_vhost",
            "kick_user", "kick_users", "kick_session", "user_sessions_info",
            "user_resources", "num_resources", "resource_num"
        }) {
            fail_if(ServerAdministrationManager.get_command_category(command("api-commands/" + name, name)) !=
                ServerAdministrationCommandCategory.ACCOUNTS,
                "account and session operations must appear in the account group: " + name);
        }
    }

    private void test_server_operations_and_queries_grouping() {
        foreach (string name in new string[] {
            "restart_kindly", "stop_kindly", "restart_module", "stop_s2s_connections",
            "get_loglevel", "set_loglevel", "reopen_log", "rotate_log", "stats", "stats_host",
            "status_list", "status_list_host", "status_num", "status_num_host"
        }) {
            fail_if(ServerAdministrationManager.get_command_category(command("api-commands/" + name, name)) !=
                ServerAdministrationCommandCategory.SERVER,
                "server operations, logging and statistics must appear in the server group: " + name);
        }
        foreach (string name in new string[] { "get_loglevel", "stats", "stats_host" }) {
            fail_if(ServerAdministrationManager.establishes_admin_access(command("api-commands/" + name, name)),
                "grouping a read-only query must not itself grant administrator access: " + name);
        }
    }

    private string[] prosody_admin_nodes() {
        // The eleven server-specific nodes advertised by official Prosody
        // 13.0.7 mod_admin_adhoc, independent of its ten XEP-0133 nodes.
        return new string[] {
            "http://prosody.im/protocol/config#reload",
            "http://prosody.im/protocol/s2s#list",
            "http://prosody.im/protocol/modules#list",
            "http://prosody.im/protocol/modules#load",
            "http://prosody.im/protocol/modules#global-load",
            "http://prosody.im/protocol/modules#reload",
            "http://prosody.im/protocol/modules#global-reload",
            "http://prosody.im/protocol/modules#unload",
            "http://prosody.im/protocol/modules#global-unload",
            "http://prosody.im/protocol/hosts#activate",
            "http://prosody.im/protocol/hosts#deactivate"
        };
    }

    private void test_prosody_admin_command_classification() {
        foreach (string node in prosody_admin_nodes()) {
            var item = command(node, node);
            fail_if(ServerAdministrationManager.get_command_source(item) !=
                ServerAdministrationCommandSource.PROSODY_ADHOC, "known Prosody administrator node must retain its source: " + node);
            fail_if(ServerAdministrationManager.get_command_category(item) !=
                ServerAdministrationCommandCategory.SERVER, "Prosody server command must be in the server category: " + node);
            fail_if(!ServerAdministrationManager.establishes_admin_access(item),
                "known Prosody administrator node must establish access: " + node);
        }

        foreach (string node in new string[] {
            "http://prosody.im/protocol/modules#",
            "http://prosody.im/protocol/modules#help",
            "http://prosody.im/protocol/modules#list/other",
            "http://prosody.im/protocol/hosts#unknown",
            "urn:xmpp:invite#invite"
        }) {
            var item = command(node, node);
            fail_if(ServerAdministrationManager.is_admin_command(item),
                "unknown and ordinary nodes must not acquire administrator status by prefix: " + node);
            var state = new ServerAdministrationState();
            Account user = account("user@example.test");
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            commands.add(item);
            state.complete_discovery(user, state.begin_discovery(user), commands);
            fail_if(state.has_admin_accounts(), "ordinary command must not expose the administration entry: " + node);
        }
    }

    private void test_prosody_only_server_commands_are_account_scoped() {
        var state = new ServerAdministrationState();
        Account admin = account("admin@example.test");
        Account user = account("user@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        foreach (string node in prosody_admin_nodes()) commands.add(command(node, node));
        foreach (string name in new string[] {
            "add-user", "change-user-password", "delete-user", "disable-user",
            "reenable-user", "end-user-session", "get-user-roster", "user-stats",
            "get-online-users-list", "shutdown"
        }) commands.add(command("http://jabber.org/protocol/admin#" + name, name));
        commands.add(command("http://prosody.im/protocol/modules#help", "Ordinary command"));

        fail_if(!state.complete_discovery(admin, state.begin_discovery(admin), commands),
            "Prosody discovery must be accepted");
        fail_if(state.get_commands(admin).size != 21,
            "all twenty-one official Prosody admin commands, without the unknown command, must remain available");
        fail_if(state.get_admin_accounts().size != 1, "only the authorized account must acquire administration");
        foreach (AdHocCommands.CommandItem item in commands) {
            bool expected = item.node != "http://prosody.im/protocol/modules#help";
            fail_if(state.has_command(admin, item) != expected, "only advertised administration commands must be executable");
            fail_if(state.has_command(user, item), "Prosody command must not leak to another account on the same host");
        }

        var normal_commands = new ArrayList<AdHocCommands.CommandItem>();
        normal_commands.add(command("http://prosody.im/protocol/modules#help", "Ordinary command"));
        state.complete_discovery(user, state.begin_discovery(user), normal_commands);
        fail_if(state.get_commands(user).size != 0, "ordinary discovery must not acquire the other account's commands");
        state.clear(user);
        fail_if(state.get_commands(admin).size != 21, "clearing another account must preserve the administrator's commands");
    }

    private void test_single_prosody_admin_command_is_retained() {
        foreach (string node in prosody_admin_nodes()) {
            var state = new ServerAdministrationState();
            Account admin = account("admin@example.test");
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            var item = command(node, node);
            commands.add(item);
            state.complete_discovery(admin, state.begin_discovery(admin), commands);
            fail_if(!state.has_admin_accounts(), "a role allowed just one Prosody administration operation must remain available: " + node);
            fail_if(state.get_commands(admin).size != 1 || !state.has_command(admin, item),
                "the single authorized Prosody operation must be executable: " + node);
        }
    }

    private void test_single_management_api_command_is_retained() {
        foreach (string name in new string[] {
            "register", "unregister", "ban_account", "unban_account", "change_password",
            "delete_old_users", "delete_old_users_vhost", "kick_user", "kick_users", "kick_session",
            "add_rosteritem", "delete_rosteritem", "srg_create", "srg_add", "srg_delete",
            "srg_set_info", "srg_add_displayed", "srg_del_displayed", "srg_user_add", "srg_user_del",
            "create_room", "create_room_with_opts", "create_rooms_file", "destroy_room", "destroy_rooms_file",
            "rooms_empty_destroy", "rooms_unused_destroy", "rooms_unused_destroy_skip_notifications",
            "change_room_option", "set_room_affiliation", "reload_config",
            "restart", "stop", "restart_kindly", "stop_kindly", "restart_module", "stop_s2s_connections"
        }) {
            var state = new ServerAdministrationState();
            Account admin = account("admin@example.test");
            Account user = account("user@example.test");
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            var item = command("api-commands/" + name, name);
            commands.add(item);
            state.complete_discovery(admin, state.begin_discovery(admin), commands);
            fail_if(!state.has_admin_accounts(), "a role allowed just one management API operation must remain available: " + name);
            fail_if(state.get_commands(admin).size != 1 || !state.has_command(admin, item),
                "the single authorized management operation must be executable: " + name);
            fail_if(state.has_command(user, item), "API operation must remain scoped to its authorized account: " + name);
        }
    }

    private void test_other_read_only_and_unknown_api_commands_do_not_grant_admin() {
        foreach (string name in new string[] {
            "check_account", "rooms_empty_list", "rooms_unused_list", "srg_list",
            "srg_get_info", "srg_get_members", "muc_online_rooms_count", "modules_installed",
            "get_roster", "unknown_management_command"
        }) {
            var state = new ServerAdministrationState();
            Account user = account("user@example.test");
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            commands.add(command("api-commands/" + name, name));
            state.complete_discovery(user, state.begin_discovery(user), commands);
            fail_if(state.has_admin_accounts(), "read-only or unknown API operation must not establish administrator access: " + name);
            fail_if(state.get_commands(user).size != 0, "a query-only API subset must not expose administration: " + name);
        }
    }

    private void test_latest_management_subsets_preserve_account_isolation() {
        // These server-authorized subsets were previously hidden because none
        // of their genuine management operations matched the narrow seed list.
        foreach (string name in new string[] {
            "backup", "restore", "export_db", "export_piefxis_host", "import_db", "import_prosody",
            "join_cluster", "leave_cluster", "set_master", "module_install", "module_uninstall",
            "delete_mnesia", "delete_old_messages", "remove_mam_for_user", "revoke_certificate",
            "oauth_issue_token", "private_set", "muc_register_nick", "announce_send_online",
            "abort_delete_old_messages", "export_db_abort", "clear_cache", "gc"
        }) {
            var state = new ServerAdministrationState();
            Account admin = account("admin@example.test");
            Account other = account("other@example.test");
            var item = command("api-commands/" + name, "Same server title");
            var advertised = new ArrayList<AdHocCommands.CommandItem>();
            advertised.add(item);
            fail_if(!ServerAdministrationManager.establishes_admin_access(item),
                "known management mutation must be an exact entry seed: " + name);
            state.complete_discovery(admin, state.begin_discovery(admin), advertised);
            fail_if(state.get_commands(admin).size != 1 || !state.has_command(admin, item),
                "a role allowed only this mutation must retain its original command: " + name);
            fail_if(state.has_command(other, item) || state.get_commands(other).size != 0,
                "a granted mutation must never leak to another account on the same host");
            var queries = new ArrayList<AdHocCommands.CommandItem>();
            queries.add(command("api-commands/status", "Status"));
            state.complete_discovery(other, state.begin_discovery(other), queries);
            fail_if(state.has_command(other, item) || state.get_commands(other).size != 0,
                "another account's query-only refresh must not acquire management access");
            fail_if(!state.has_command(admin, item), "another account's discovery must preserve the grant owner");
            state.clear(other);
            fail_if(!state.has_command(admin, item), "clearing another account must preserve the grant owner");
        }
    }

    private void test_known_queries_tools_and_future_aliases_do_not_grant_admin() {
        foreach (string node in new string[] {
            "api-commands/muc_online_rooms", "api-commands/connected_users", "api-commands/status_list",
            "api-commands/check_password", "api-commands/check_password_hash", "api-commands/get_cookie",
            "api-commands/oauth_list_tokens", "api-commands/list_invites", "api-commands/get_mam_count",
            "api-commands/get_offline_count", "api-commands/get_roster_count", "api-commands/modules_available",
            "api-commands/help", "api-commands/mnesia_change", "api-commands/mnesia_info_ctl",
            "api-commands/print_sql_schema", "api-commands/gen_html_doc_for_commands",
            "api-commands/gen_markdown_doc_for_commands", "api-commands/gen_markdown_doc_for_tags",
            "api-commands/man", "api-commands/convert_to_yaml",
            "api-commands/backup_future", "api-commands/register_future", "api-commands/rooms_future_delete",
            "api-commands/delete-user", "backup", "urn:xmpp:invite#invite", "urn:xmpp:invite#create-account"
        }) {
            var state = new ServerAdministrationState();
            Account user = account("user@example.test");
            var item = command(node, "Delete account");
            var advertised = new ArrayList<AdHocCommands.CommandItem>();
            advertised.add(item);
            fail_if(ServerAdministrationManager.establishes_admin_access(item),
                "query, utility, unreviewed alias or self-service invitation must not open administration: " + node);
            state.complete_discovery(user, state.begin_discovery(user), advertised);
            fail_if(state.has_admin_accounts() || state.get_commands(user).size != 0,
                "a non-management subset must not populate the administrative account cache: " + node);
        }
    }

    private void test_latest_api_domains_are_exact_and_independent_of_access() {
        foreach (string name in new string[] {
            "get_mam_count", "get_offline_count", "private_get", "private_set", "get_vcard2_multi",
            "get_last", "get_ban_details", "check_password", "list_invites", "bookmarks_to_pep"
        }) {
            fail_if(ServerAdministrationManager.get_command_category(command("api-commands/" + name, name)) !=
                ServerAdministrationCommandCategory.ACCOUNTS, "account data must be grouped by actual scope: " + name);
        }
        foreach (string name in new string[] { "get_roster_count", "process_rosteritems", "srg_get_displayed", "push_roster_all" }) {
            fail_if(ServerAdministrationManager.get_command_category(command("api-commands/" + name, name)) !=
                ServerAdministrationCommandCategory.ROSTER, "known contact operations must be grouped as rosters: " + name);
        }
        foreach (string name in new string[] { "get_subscribers", "send_direct_invitation", "get_user_rooms", "muc_unregister_nick", "subscribe_room_many" }) {
            fail_if(ServerAdministrationManager.get_command_category(command("api-commands/" + name, name)) !=
                ServerAdministrationCommandCategory.MUC, "known room operations must be grouped as group chats: " + name);
        }
        foreach (string name in new string[] { "backup", "join_cluster", "oauth_issue_token", "unban_ip", "delete_old_messages", "cleanup_expired_invite_tokens", "help" }) {
            fail_if(ServerAdministrationManager.get_command_category(command("api-commands/" + name, name)) !=
                ServerAdministrationCommandCategory.SERVER, "server storage/security/tools must be grouped as server operations: " + name);
        }
        foreach (string name in new string[] { "rooms_future_delete", "registered_users_future", "srg_future", "delete-user", "get-user-roster" }) {
            var item = command("api-commands/" + name, "Known-looking title");
            fail_if(ServerAdministrationManager.get_command_category(item) != ServerAdministrationCommandCategory.OTHER,
                "unknown extensions and XEP-name aliases must not inherit an API category: " + name);
            fail_if(ServerAdministrationManager.establishes_admin_access(item), "unknown naming must not establish access");
        }
    }

    private void test_read_only_api_commands_do_not_grant_admin() {
        var state = new ServerAdministrationState();
        Account account = account("user@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add(command("api-commands/status", "Status"));
        commands.add(command("api-commands/connected_users_number", "Connected Users Number"));

        uint generation = state.begin_discovery(account);
        state.complete_discovery(account, generation, commands);

        fail_if(state.has_admin_accounts(), "read-only API commands must not expose server administration");
        fail_if(state.get_commands(account).size != 0, "read-only API commands must not be retained without admin access");
    }

    private void test_admin_api_commands_are_retained() {
        var state = new ServerAdministrationState();
        Account account = account("admin@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add(command("api-commands/create_room", "Create Room"));
        commands.add(command("api-commands/muc_online_rooms", "Muc Online Rooms"));
        commands.add(command("api-commands/status", "Status"));
        commands.add(command("urn:xmpp:invite#invite", "Create Invitation"));

        uint generation = state.begin_discovery(account);
        state.complete_discovery(account, generation, commands);

        fail_if(!state.has_admin_accounts(), "authorized management API command must expose server administration");
        fail_if(state.get_commands(account).size != 4, "all authorized API and shared invitation commands must be retained");
        foreach (AdHocCommands.CommandItem item in commands) {
            fail_if(!state.has_command(account, item), "every exact advertised identity must remain available behind management access");
        }
    }

    private void test_xep0133_only_server_is_supported() {
        var state = new ServerAdministrationState();
        Account account = account("admin@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add(command("http://jabber.org/protocol/admin#get-online-users", "Get Online Users"));
        commands.add(command("http://jabber.org/protocol/admin#get-user-roster", "Get User Roster"));

        uint generation = state.begin_discovery(account);
        state.complete_discovery(account, generation, commands);

        fail_if(!state.has_admin_accounts(), "XEP-0133 commands must expose server administration without ejabberd API commands");
        fail_if(state.get_commands(account).size != 2, "all available XEP-0133 commands must be retained");
        foreach (AdHocCommands.CommandItem command_item in state.get_commands(account)) {
            fail_if(ServerAdministrationManager.get_command_source(command_item) !=
                ServerAdministrationCommandSource.XEP_0133, "server-neutral commands must remain classified as XEP-0133");
        }
    }

    private void test_commands_are_account_scoped() {
        var state = new ServerAdministrationState();
        Account first = account("admin@example.test");
        Account second = account("user@example.org");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add(command("http://jabber.org/protocol/admin#add-user", "Add User"));

        uint generation = state.begin_discovery(first);
        state.complete_discovery(first, generation, commands);

        fail_if(!state.has_admin_accounts(), "admin command must expose server administration");
        fail_if(state.get_admin_accounts().size != 1, "only the admin account must be exposed");
        fail_if(state.get_commands(first).size != 1, "admin account must retain its command");
        fail_if(state.get_commands(second).size != 0, "commands must not leak to another account");
    }

    private void test_discovery_deduplicates_only_command_identity() {
        try {
            var state = new ServerAdministrationState();
            Account first = account("admin@example.test");
            Account second = account("other-admin@example.test");
            var first_item = command("api-commands/change_password", "Manage account");
            var duplicate = command(first_item.node, "A different server-provided label");
            var distinct_node = command("api-commands/unregister", first_item.name);
            var distinct_target = new AdHocCommands.CommandItem(new Jid("other.test"),
                first_item.node, first_item.name);
            var distinct_resource = new AdHocCommands.CommandItem(new Jid("example.test/resource"),
                first_item.node, first_item.name);
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            commands.add(first_item);
            commands.add(duplicate);
            commands.add(distinct_node);
            commands.add(distinct_target);
            commands.add(distinct_resource);

            fail_if(!state.complete_discovery(first, state.begin_discovery(first), commands),
                "current command discovery must be accepted");
            Gee.List<AdHocCommands.CommandItem> retained = state.get_commands(first);
            fail_if(retained.size != 4, "only the repeated target JID and exact node must be deduplicated");
            if (retained.size == 4) {
                fail_if_not_eq_str(first_item.name, retained[0].name);
                fail_if_not_eq_str(distinct_node.node, retained[1].node);
                fail_if(!Jid.equals_func(distinct_target.jid, retained[2].jid), "different target domain must remain intact");
                fail_if(!Jid.equals_func(distinct_resource.jid, retained[3].jid), "different target resource must remain intact");
            }
            foreach (AdHocCommands.CommandItem item in commands) {
                fail_if(!state.has_command(first, item), "deduplication must preserve the existing execution identity");
                fail_if(state.has_command(second, item), "discovery must not grant commands to another account");
            }

            var second_commands = new ArrayList<AdHocCommands.CommandItem>();
            second_commands.add(duplicate);
            second_commands.add(first_item);
            state.complete_discovery(second, state.begin_discovery(second), second_commands);
            retained = state.get_commands(second);
            fail_if(retained.size != 1, "the same command must be independently retained once for another account");
            if (retained.size == 1) fail_if_not_eq_str(duplicate.name, retained[0].name);
            fail_if(state.get_commands(first).size != 4, "another account's discovery must not change the first account");
            fail_if(state.has_command(second, distinct_node), "another node must not leak across accounts");
            fail_if(state.has_command(second, distinct_target), "another target must not leak across accounts");
            state.clear(second);
            fail_if(state.get_commands(first).size != 4, "clearing one account must preserve the other account's deduplicated list");
        } catch (InvalidJidError e) {
            fail_if_reached("Invalid duplicate-command test JID: " + e.message);
        }
    }

    private void test_shared_invite_nodes_require_independent_admin_access() {
        var state = new ServerAdministrationState();
        Account user = account("user@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        foreach (string node in new string[] { "urn:xmpp:invite#invite", "urn:xmpp:invite#create-account" }) {
            var item = command(node, "Create invitation");
            commands.add(item);
            fail_if(ServerAdministrationManager.get_command_source(item) != ServerAdministrationCommandSource.COMMON_INVITE,
                "shared invitation must be identified without a vendor assumption");
            fail_if(ServerAdministrationManager.is_admin_command(item) || ServerAdministrationManager.establishes_admin_access(item),
                "a server may permit ordinary users to invoke either shared invitation");
            fail_if(ServerAdministrationManager.get_command_category(item) != ServerAdministrationCommandCategory.ACCOUNTS,
                "shared invitations belong to accounts");
        }
        state.complete_discovery(user, state.begin_discovery(user), commands);
        fail_if(state.has_admin_accounts(), "self-service invitations must not expose server administration");
        commands.add(command("http://jabber.org/protocol/admin#add-user", "Create account"));
        state.complete_discovery(user, state.begin_discovery(user), commands);
        fail_if(state.get_commands(user).size != 3, "independently authorized administrators must retain shared invitations");
        foreach (AdHocCommands.CommandItem item in commands) fail_if(!state.has_command(user, item), "admin list must retain exact advertised invite targets");
    }

    private void test_remaining_prosody_core_admin_nodes() {
        foreach (string node in new string[] {
            "xmpp:prosody.im/mod_invites_adhoc#password-reset",
            "http://prosody.im/protocol/muc#destroy",
            "http://prosody.im/protocol/muc#set-affiliation"
        }) {
            var item = command(node, node);
            var state = new ServerAdministrationState();
            Account admin = account("admin@example.test");
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            commands.add(item);
            state.complete_discovery(admin, state.begin_discovery(admin), commands);
            fail_if(!state.has_command(admin, item), "the remaining explicit Prosody core admin operation must be usable");
            fail_if(ServerAdministrationManager.get_command_source(item) != ServerAdministrationCommandSource.PROSODY_ADHOC,
                "vendor-specific reset and component nodes must retain their source");
            ServerAdministrationCommandCategory expected = node.has_prefix("http://prosody.im/protocol/muc#") ?
                ServerAdministrationCommandCategory.MUC : ServerAdministrationCommandCategory.ACCOUNTS;
            fail_if(ServerAdministrationManager.get_command_category(item) != expected, "reset and room commands must appear in their correct group");
        }
        fail_if(ServerAdministrationManager.is_admin_command(command("uptime", "Get uptime")), "public Prosody uptime must not be an administrator seed");
        fail_if(!ServerAdministrationManager.is_admin_command(command("http://jabber.org/protocol/admin#announce", "Announce")),
            "the additional core announcement is a standard administrative command");
    }

    private void test_ejabberd_native_node_administration_is_exact() {
        foreach (string suffix in new string[] {
            "DB", "backup/backup", "backup/restore", "backup/textfile",
            "import/file", "import/dir", "restart", "shutdown"
        }) {
            var item = command("running nodes/ejabberd@example.test/" + suffix, "Node operation");
            fail_if(ServerAdministrationManager.get_command_source(item) != ServerAdministrationCommandSource.EJABBERD_ADHOC,
                "an actual native node command must be separate from API and admin# commands: " + suffix);
            fail_if(ServerAdministrationManager.get_command_category(item) != ServerAdministrationCommandCategory.SERVER,
                "native node administration must belong to the server group");
            var state = new ServerAdministrationState();
            Account admin = account("admin@example.test");
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            commands.add(item);
            state.complete_discovery(admin, state.begin_discovery(admin), commands);
            fail_if(!state.has_command(admin, item), "a single advertised configure-ACL node operation must be usable");
        }
        foreach (string node in new string[] {
            "running nodes", "running nodes/", "running nodes/ejabberd@example.test",
            "running nodes//restart", "running nodes/ /restart", "running nodes/node/",
            "running nodes/node/DB/extra", "running nodes/node/db", "running nodes/node/backup",
            "running nodes/node/backup/unknown", "running nodes/node/backup/backup/extra",
            "running nodes/node/import", "running nodes/node/import/unknown", "running nodes/node/import/file/extra",
            "running nodes/node//restart", "running nodes/node/restart/", "stopped nodes/node/restart",
            "config", "config/unknown", "ping", "uptime"
        }) {
            var item = command(node, "Navigation or unknown");
            fail_if(ServerAdministrationManager.is_admin_command(item) || ServerAdministrationManager.establishes_admin_access(item),
                "navigation, public and malformed nodes must not establish administration: " + node);
        }
    }

    private void test_restricted_invite_api_management() {
        foreach (string name in new string[] {
            "generate_invite", "generate_invite_with_username", "generate_reset_token",
            "delete_invite_by_token", "expire_invite_tokens", "expire_invite_by_token", "cleanup_expired_invite_tokens"
        }) {
            var state = new ServerAdministrationState();
            Account admin = account("admin@example.test");
            var commands = new ArrayList<AdHocCommands.CommandItem>();
            var item = command("api-commands/" + name, name);
            commands.add(item);
            state.complete_discovery(admin, state.begin_discovery(admin), commands);
            fail_if(!state.has_command(admin, item), "a single restricted invitation-management API must remain available: " + name);
            ServerAdministrationCommandCategory expected = name == "cleanup_expired_invite_tokens" ?
                ServerAdministrationCommandCategory.SERVER : ServerAdministrationCommandCategory.ACCOUNTS;
            fail_if(ServerAdministrationManager.get_command_category(item) != expected, "invitation API must be grouped by its actual scope");
        }
        var state = new ServerAdministrationState();
        Account user = account("user@example.test");
        var read_only = new ArrayList<AdHocCommands.CommandItem>();
        read_only.add(command("api-commands/list_invites", "List invitations"));
        state.complete_discovery(user, state.begin_discovery(user), read_only);
        fail_if(state.has_admin_accounts(), "listing invitations alone must not establish management access");
    }

    private delegate void ComponentDiscoveryCheck(ServerAdministrationManager manager,
        StreamInteractor interactor, Account account, ServerAdministrationComponentAuditStream stream);

    private void with_component_discovery_test(owned ComponentDiscoveryCheck check) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-server-admin-component-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "server-admin-component-test");
            var interactor = new StreamInteractor.for_tests((!) db);
            ServerAdministrationManager.start(interactor);
            var manager = (!) interactor.get_module<ServerAdministrationManager>(ServerAdministrationManager.IDENTITY);
            Account admin = account("admin@example.test");
            var stream = new ServerAdministrationComponentAuditStream(new Jid("example.test"));
            interactor.connection_manager.set_connected_stream_for_tests(admin, stream);
            check(manager, interactor, admin, stream);
        } catch (Error e) {
            fail_if_reached("Component discovery test failed: " + e.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_authenticated_components_are_discovered_without_crawling() {
        with_component_discovery_test((manager, interactor, admin, stream) => {
            stream.delay_parent_next = true;
            interactor.stream_negotiated(admin, stream);
            wait_for_server_admin(() => stream.has_delayed_response && manager.get_commands(admin).size == 1);
            fail_if(manager.get_commands(admin).size != 1, "primary commands must be available before component discovery finishes");
            stream.release_delayed_response();
            wait_for_server_admin(() => manager.get_commands(admin).size == 5);
            fail_if(manager.get_commands(admin).size != 5, "two distinct conference targets must each retain both management nodes");
            fail_if(stream.parent_items_requests != 1 || stream.info_requests != 3 || stream.component_command_requests != 2,
                "only unique parent-advertised domain services may be probed; users, rooms, resources and node items must not be crawled");
            fail_if(stream.unexpected_requests != 0, "component command discovery must never enumerate a room list or recurse");
            Account other = account("other@example.test");
            fail_if(manager.get_commands(other).size != 0, "component commands must remain scoped to the authenticating account");
            int component_count = 0;
            foreach (AdHocCommands.CommandItem item in manager.get_commands(admin)) {
                if (!item.jid.equals(admin.bare_jid.domain_jid)) component_count++;
            }
            fail_if(component_count != 4, "component provenance must retain its real target for source display and execution");
        });
        with_component_discovery_test((manager, interactor, admin, stream) => {
            stream.primary_has_admin = false;
            interactor.stream_negotiated(admin, stream);
            wait_for_server_admin(() => manager.get_commands(admin).size == 4);
            fail_if(manager.get_commands(admin).size != 4, "an account authorized only on its advertised components must also work");
            stream.delay_parent_next = true;
            manager.refresh(admin);
            wait_for_server_admin(() => stream.has_delayed_response);
            fail_if(manager.get_commands(admin).size != 4,
                "a component-only refresh must not temporarily hide administration after its empty primary result");
            stream.advertise_services = false;
            stream.release_delayed_response();
            wait_for_server_admin(() => stream.component_command_requests == 4);
            // The delayed response was materialized before changing the fixture;
            // it still contains the two services from this valid discovery.
            fail_if(manager.get_commands(admin).size != 4, "component-only refresh must complete its valid service snapshot");
            manager.refresh(admin);
            wait_for_server_admin(() => !manager.has_admin_accounts());
            fail_if(manager.has_admin_accounts(), "completed discovery with no remaining services must revoke stale component commands");
        });
    }

    private void test_component_discovery_rejects_unproven_services() {
        for (int scenario = 0; scenario < 9; scenario++) {
            int selected = scenario;
            with_component_discovery_test((manager, interactor, admin, stream) => {
                switch (selected) {
                    case 0: stream.parent_sender = "forged.test"; break;
                    case 1: stream.parent_sender = ""; break;
                    case 2: stream.info_sender = "forged.test"; break;
                    case 3: stream.conference_identity = false; break;
                    case 4: stream.muc_feature = false; break;
                    case 5: stream.adhoc_feature = false; break;
                    case 6: stream.info_sender = ""; break;
                    case 7: stream.wrong_parent_node = true; break;
                    case 8: stream.wrong_info_node = true; break;
                }
                interactor.stream_negotiated(admin, stream);
                wait_for_server_admin(() => stream.parent_items_requests == 1 && manager.has_admin_accounts());
                while (MainContext.default().iteration(false)) {}
                fail_if(manager.get_commands(admin).size != 1, "unproven components must not change the primary command list");
                fail_if(stream.component_command_requests != 0, "commands must not be requested without authenticated parent and component capabilities");
                if (selected < 2 || selected == 7) fail_if(stream.info_requests != 0, "an unauthenticated or wrong-node parent must not trigger any service probe");
            });
        }
    }

    private void test_component_discovery_retries_once() {
        with_component_discovery_test((manager, interactor, admin, stream) => {
            stream.parent_failures_remaining = 1;
            stream.info_failures_remaining = 1;
            stream.component_failures_remaining = 1;
            interactor.stream_negotiated(admin, stream);
            wait_for_server_admin(() => manager.get_commands(admin).size == 5);
            fail_if(manager.get_commands(admin).size != 5, "one transient failure at each discovery phase must recover");
            fail_if(stream.parent_items_requests != 2 || stream.info_requests != 4 || stream.component_command_requests != 3,
                "each failed request must retry once without duplicating retained commands");
        });
        with_component_discovery_test((manager, interactor, admin, stream) => {
            stream.parent_failures_remaining = 3;
            interactor.stream_negotiated(admin, stream);
            wait_for_server_admin(() => stream.parent_items_requests == 2);
            while (MainContext.default().iteration(false)) {}
            fail_if(stream.parent_items_requests != 2 || stream.info_requests != 0,
                "persistent parent failure must stop after the single retry");
            fail_if(manager.get_commands(admin).size != 1, "service-discovery failure must preserve working primary commands");
        });
    }

    private void test_component_discovery_discards_old_generation_and_stream() {
        with_component_discovery_test((manager, interactor, admin, stream) => {
            stream.delay_component_next = true;
            interactor.stream_negotiated(admin, stream);
            wait_for_server_admin(() => stream.has_delayed_response);
            stream.advertise_services = false;
            manager.refresh(admin);
            wait_for_server_admin(() => stream.parent_items_requests == 2 && stream.primary_command_requests == 2);
            while (MainContext.default().iteration(false)) {}
            stream.release_delayed_response();
            while (MainContext.default().iteration(false)) {}
            fail_if(manager.get_commands(admin).size != 1, "a late component reply must not restore commands after a newer discovery");
            fail_if(stream.component_command_requests != 1, "old discovery must stop before probing the next component");
        });
        with_component_discovery_test((manager, interactor, admin, stream) => {
            stream.delay_parent_next = true;
            interactor.stream_negotiated(admin, stream);
            wait_for_server_admin(() => stream.has_delayed_response);
            try {
                var replacement = new ServerAdministrationComponentAuditStream(new Jid("example.test"));
                replacement.advertise_services = false;
                interactor.connection_manager.set_connected_stream_for_tests(admin, replacement);
                interactor.stream_negotiated(admin, replacement);
                wait_for_server_admin(() => replacement.parent_items_requests == 1 && manager.get_commands(admin).size == 1);
                stream.release_delayed_response();
                while (MainContext.default().iteration(false)) {}
                fail_if(stream.info_requests != 0, "the old stream's delayed parent must not initiate component requests");
                fail_if(manager.get_commands(admin).size != 1, "old transport discovery must not alter the replacement stream's state");
            } catch (InvalidJidError e) {
                fail_if_reached("Invalid replacement stream JID: " + e.message);
            }
        });
    }

    private void test_stale_discovery_is_ignored() {
        var state = new ServerAdministrationState();
        Account account = account("admin@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add(command("http://jabber.org/protocol/admin#delete-user", "Delete User"));

        uint stale_generation = state.begin_discovery(account);
        uint current_generation = state.begin_discovery(account);

        fail_if(state.complete_discovery(account, stale_generation, commands), "stale discovery must be rejected");
        fail_if(state.has_admin_accounts(), "stale discovery must not expose server administration");
        fail_if(!state.complete_discovery(account, current_generation, commands), "current discovery must be accepted");
        fail_if(!state.has_admin_accounts(), "current discovery must expose server administration");
    }

    private void test_clear_invalidates_pending_discovery() {
        var state = new ServerAdministrationState();
        Account account = account("admin@example.test");
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add(command("http://jabber.org/protocol/admin#restart", "Restart Service"));

        uint generation = state.begin_discovery(account);
        state.clear(account);

        fail_if(state.complete_discovery(account, generation, commands), "disconnect must invalidate pending discovery");
        fail_if(state.has_admin_accounts(), "late result after disconnect must not restore admin state");
    }

    private void test_fresh_resumed_and_same_stream_recover_admin_discovery() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-server-admin-resume-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "server-admin-resume-test");
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            ServerAdministrationManager.start(stream_interactor);
            ServerAdministrationManager manager = (!) stream_interactor
                .get_module<ServerAdministrationManager>(
                    ServerAdministrationManager.IDENTITY);
            Account admin_account = account("admin@example.test");
            var stream = new ServerAdministrationAuditStream(
                new Jid("example.test"));
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                admin_account, stream);

            stream.fail_next_response = true;
            stream_interactor.stream_negotiated(admin_account, stream);
            wait_for_server_admin(() => manager.has_admin_accounts() &&
                stream.command_discovery_requests == 2);
            fail_if(!manager.has_admin_accounts(),
                "fresh negotiation must recover from one failed command discovery");
            fail_if(stream.command_discovery_requests != 2,
                "fresh negotiation must retry command discovery exactly once");

            // Keep one same-stream discovery in flight across disconnect. Its
            // empty result must not overwrite the later resume generation.
            stream.delay_next_response = true;
            manager.refresh(admin_account);
            wait_for_server_admin(() =>
                stream.command_discovery_requests == 3);
            fail_if(stream.command_discovery_requests != 3,
                "pre-disconnect refresh must be pending before resume");

            stream_interactor.connection_manager
                .set_provisional_disconnected_for_tests(admin_account);
            fail_if(manager.has_admin_accounts(),
                "disconnect must hide stale server administration");

            // A real XEP-0198 resume is negotiated on a replacement transport,
            // not by changing the retained transport back to CONNECTED. Model
            // that boundary so the later same-stream ping path remains a
            // distinct case.
            stream_interactor.connection_manager
                .set_stream_replacement_pending_for_tests(admin_account);
            var resumed_stream = new ServerAdministrationAuditStream(
                new Jid("example.test"));
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                admin_account, resumed_stream);
            fail_if(!stream_interactor.connection_manager
                    .mark_stream_session_resolved(admin_account,
                        resumed_stream),
                "the resumed audit stream must own the current session");
            stream_interactor.stream_resumed(admin_account, resumed_stream);
            wait_for_server_admin(() => manager.has_admin_accounts() &&
                resumed_stream.command_discovery_requests == 1);
            fail_if(!manager.has_admin_accounts(),
                "confirmed stream resume must rediscover server administration");
            fail_if(resumed_stream.command_discovery_requests != 1,
                "confirmed stream resume must issue one new command discovery");

            stream.release_delayed_response();
            wait_for_server_admin(() => !stream.has_delayed_response);
            fail_if(!manager.has_admin_accounts(),
                "late pre-disconnect discovery must not overwrite resume state");

            // NetworkMonitor recovery can prove that the exact retained
            // transport is still usable with a ping. That path emits only
            // CONNECTED, not stream_resumed, and must still restore the
            // commands which DISCONNECTED deliberately hid.
            stream_interactor.connection_manager
                .set_provisional_disconnected_for_tests(admin_account);
            fail_if(manager.has_admin_accounts(),
                "same-stream disconnect must hide stale server administration");

            stream_interactor.connection_manager.set_connection_state_for_tests(
                admin_account, ConnectionManager.ConnectionState.CONNECTED);
            wait_for_server_admin(() => manager.has_admin_accounts() &&
                resumed_stream.command_discovery_requests == 2);
            fail_if(!manager.has_admin_accounts(),
                "same-stream CONNECTED recovery must rediscover server administration");
            fail_if(resumed_stream.command_discovery_requests != 2,
                "same-stream CONNECTED recovery must issue exactly one command discovery");
        } catch (Error error) {
            fail_if_reached("Unexpected server administration resume error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void wait_for_server_admin(owned SourceFunc condition) {
        int64 deadline = GLib.get_monotonic_time() + 2 * TimeSpan.SECOND;
        while (!condition() && GLib.get_monotonic_time() < deadline) {
            while (MainContext.default().iteration(false)) {}
            Thread.usleep(1000);
        }
        while (MainContext.default().iteration(false)) {}
    }

    private void test_command_state_validates_server_response() {
        var item = command("http://jabber.org/protocol/admin#add-user", "Add User");
        var state = new ServerAdministrationCommandState(item);

        var wrong_node = result("http://jabber.org/protocol/admin#delete-user", "session-1",
            AdHocCommands.Command.Status.EXECUTING);
        fail_if_not_eq_str("command-node-mismatch", state.accept(wrong_node));
        fail_if(state.command != null, "invalid response must not replace command state");

        var missing_session = result(item.node, null, AdHocCommands.Command.Status.EXECUTING);
        fail_if_not_eq_str("command-sessionid-missing", state.accept(missing_session));
        fail_if(state.command != null, "executing response without session id must be rejected");
    }

    private void test_command_state_handles_multistep_actions() {
        var item = command("http://jabber.org/protocol/admin#add-user", "Add User");
        var state = new ServerAdministrationCommandState(item);
        var executing = result(item.node, "session-1", AdHocCommands.Command.Status.EXECUTING);
        executing.actions.add("prev");
        executing.actions.add("next");
        executing.actions.add("complete");
        executing.execute_action = "next";

        fail_if(state.accept(executing) != null, "valid executing response must be accepted");
        fail_if_not_eq_str("next", state.get_default_action());
        fail_if(!state.can_proceed("prev"), "advertised previous action must be accepted");
        fail_if(!state.can_proceed("complete"), "advertised complete action must be accepted");
        fail_if(state.can_proceed("execute"), "initial execute action must not be accepted for continuation");
        fail_if(state.can_proceed("unknown"), "unknown action must be rejected");

        var completed = result(item.node, "session-1", AdHocCommands.Command.Status.COMPLETED);
        fail_if(state.accept(completed) != null, "completed response must be accepted");
        fail_if(state.can_proceed(""), "completed command must not allow another step");
    }

    private void test_command_state_marks_canceled() {
        var item = command("http://jabber.org/protocol/admin#add-user", "Add User");
        var state = new ServerAdministrationCommandState(item);
        var executing = result(item.node, "session-1", AdHocCommands.Command.Status.EXECUTING);
        state.accept(executing);

        fail_if(!state.has_active_session(), "executing command must have an active session");
        state.mark_canceled();
        fail_if(state.has_active_session(), "canceled command must not remain active");
        fail_if(state.command.status != AdHocCommands.Command.Status.CANCELED, "command must be marked canceled");
    }

    private Account account(string jid) {
        try {
            return new Account(new Jid(jid), "secret");
        } catch (InvalidJidError e) {
            error("Invalid account JID in server administration test: %s", e.message);
        }
    }

    private AdHocCommands.CommandItem command(string node, string name) {
        try {
            return new AdHocCommands.CommandItem(new Jid("example.test"), node, name);
        } catch (InvalidJidError e) {
            error("Invalid command JID in server administration test: %s", e.message);
        }
    }

    private AdHocCommands.Command result(string node, string? sessionid, AdHocCommands.Command.Status status) {
        return new AdHocCommands.Command() {
            node = node,
            sessionid = sessionid,
            status = status
        };
    }
}

private class ServerAdministrationAuditStream : XmppStream {
    public int command_discovery_requests { get; private set; default = 0; }
    public bool delay_next_response { get; set; default = false; }
    public bool fail_next_response { get; set; default = false; }
    public bool has_delayed_response { get { return delayed_response != null; } }

    private StanzaNode? delayed_response = null;

    public ServerAdministrationAuditStream(Jid remote_name) {
        base(remote_name);

        var iq = new Iq.Module();
        add_module(iq);
        iq.attach(this);
        add_module(new ServiceDiscovery.Module.with_identity(
            "client", "pc", "DinoX Server Administration Test"));
        add_module(new AdHocCommands.Module());
    }

    public void release_delayed_response() {
        StanzaNode? response = delayed_response;
        delayed_response = null;
        if (response != null) received_iq_stanza(this, (!) response);
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
        StanzaNode? query = node.get_subnode("query",
            ServiceDiscovery.NS_URI_ITEMS);
        if (query != null && ((!) query).get_attribute("node") == null) {
            // Existing negotiation/resume tests have no advertised services.
            var empty_response = new StanzaNode.build("iq")
                .put_attribute("id", node.get_attribute("id"))
                .put_attribute("type", Iq.Stanza.TYPE_RESULT)
                .put_attribute("from", "example.test")
                .put_node(new StanzaNode.build("query", ServiceDiscovery.NS_URI_ITEMS).add_self_xmlns());
            Idle.add(() => {
                received_iq_stanza(this, empty_response);
                return Source.REMOVE;
            });
            return;
        }
        if (query == null || ((!) query).get_attribute("node") !=
                AdHocCommands.NS_URI) {
            throw new IOError.NOT_SUPPORTED(
                "test stream only supports command discovery");
        }

        command_discovery_requests++;
        bool delay_response = delay_next_response;
        delay_next_response = false;
        bool fail_response = fail_next_response;
        fail_next_response = false;
        var result_query = new StanzaNode.build("query",
            ServiceDiscovery.NS_URI_ITEMS).add_self_xmlns()
            .put_attribute("node", AdHocCommands.NS_URI);
        if (!delay_response && !fail_response) {
            result_query.put_node(new StanzaNode.build("item",
                ServiceDiscovery.NS_URI_ITEMS)
                .put_attribute("jid", "example.test")
                .put_attribute("node",
                    ServerAdministrationManager.ADMIN_COMMAND_PREFIX +
                    "get-online-users")
                .put_attribute("name", "Get Online Users"));
        }
        var response = new StanzaNode.build("iq")
            .put_attribute("id", node.get_attribute("id"))
            .put_attribute("type", fail_response ? Stanza.TYPE_ERROR :
                Iq.Stanza.TYPE_RESULT)
            .put_attribute("from", "example.test")
            .put_node(result_query);

        if (delay_response) {
            delayed_response = response;
        } else {
            Idle.add(() => {
                received_iq_stanza(this, response);
                return Source.REMOVE;
            });
        }
    }

    public override async void setup() throws IOError {
    }
}

private class ServerAdministrationComponentAuditStream : XmppStream {
    public bool primary_has_admin = true;
    public bool advertise_services = true;
    public string parent_sender = "example.test";
    public string? info_sender = null;
    public bool wrong_parent_node = false;
    public bool wrong_info_node = false;
    public bool conference_identity = true;
    public bool muc_feature = true;
    public bool adhoc_feature = true;
    public bool delay_parent_next = false;
    public bool delay_component_next = false;
    public int parent_failures_remaining = 0;
    public int info_failures_remaining = 0;
    public int component_failures_remaining = 0;
    public int parent_items_requests = 0;
    public int primary_command_requests = 0;
    public int info_requests = 0;
    public int component_command_requests = 0;
    public int unexpected_requests = 0;
    public bool has_delayed_response { get { return delayed_response != null; } }
    private StanzaNode? delayed_response = null;

    public ServerAdministrationComponentAuditStream(Jid remote_name) {
        base(remote_name);
        var iq = new Iq.Module();
        add_module(iq);
        iq.attach(this);
        add_module(new ServiceDiscovery.Module.with_identity("client", "pc", "Component Discovery Fixture"));
        add_module(new AdHocCommands.Module());
    }

    public void release_delayed_response() {
        StanzaNode? response = delayed_response;
        delayed_response = null;
        if (response != null) received_iq_stanza(this, (!) response);
    }

    public override async void connect() throws IOError {}
    public override async void disconnect() throws IOError {}
    public override async void setup() throws IOError {}
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("component fixture has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        string target = node.get_attribute("to") ?? "";
        StanzaNode? items = node.get_subnode("query", ServiceDiscovery.NS_URI_ITEMS);
        StanzaNode? info = node.get_subnode("query", ServiceDiscovery.NS_URI_INFO);
        StanzaNode result_query;
        string? sender = target;
        bool fail = false;
        bool delay = false;
        if (items != null && ((!) items).get_attribute("node") == null && target == "example.test") {
            parent_items_requests++;
            sender = parent_sender == "" ? null : parent_sender;
            fail = parent_failures_remaining > 0;
            if (fail) parent_failures_remaining--;
            delay = delay_parent_next;
            delay_parent_next = false;
            result_query = new StanzaNode.build("query", ServiceDiscovery.NS_URI_ITEMS).add_self_xmlns();
            if (wrong_parent_node) result_query.put_attribute("node", "unrelated-node");
            if (advertise_services) {
                foreach (string jid in new string[] {
                    "conference.example.test", "conference.example.test", "conference2.example.test", "upload.example.test",
                    "room@conference.example.test", "user@example.test", "conference.example.test/resource"
                }) result_query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS).put_attribute("jid", jid));
                result_query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                    .put_attribute("jid", "node-only.example.test").put_attribute("node", "unrelated-node"));
            }
        } else if (info != null && (target == "conference.example.test" || target == "conference2.example.test" || target == "upload.example.test")) {
            info_requests++;
            sender = info_sender == "" ? null : (info_sender ?? target);
            fail = info_failures_remaining > 0;
            if (fail) info_failures_remaining--;
            bool is_conference = target != "upload.example.test";
            result_query = new StanzaNode.build("query", ServiceDiscovery.NS_URI_INFO).add_self_xmlns();
            if (wrong_info_node) result_query.put_attribute("node", "unrelated-node");
            result_query.put_node(new StanzaNode.build("identity", ServiceDiscovery.NS_URI_INFO)
                .put_attribute("category", is_conference && conference_identity ? "conference" : "store")
                .put_attribute("type", "text"));
            result_query.put_node(new StanzaNode.build("feature", ServiceDiscovery.NS_URI_INFO)
                .put_attribute("var", ServiceDiscovery.NS_URI_INFO));
            if (is_conference && muc_feature) result_query.put_node(new StanzaNode.build("feature", ServiceDiscovery.NS_URI_INFO)
                .put_attribute("var", "http://jabber.org/protocol/muc"));
            if (is_conference && adhoc_feature) result_query.put_node(new StanzaNode.build("feature", ServiceDiscovery.NS_URI_INFO)
                .put_attribute("var", AdHocCommands.NS_URI));
        } else if (items != null && ((!) items).get_attribute("node") == AdHocCommands.NS_URI) {
            result_query = new StanzaNode.build("query", ServiceDiscovery.NS_URI_ITEMS).add_self_xmlns()
                .put_attribute("node", AdHocCommands.NS_URI);
            if (target == "example.test") {
                primary_command_requests++;
                if (primary_has_admin) result_query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                    .put_attribute("jid", target).put_attribute("node", "http://jabber.org/protocol/admin#get-online-users")
                    .put_attribute("name", "Manage"));
            } else if (target == "conference.example.test" || target == "conference2.example.test") {
                component_command_requests++;
                fail = component_failures_remaining > 0;
                if (fail) component_failures_remaining--;
                delay = delay_component_next;
                delay_component_next = false;
                foreach (string command_node in new string[] {
                    "http://prosody.im/protocol/muc#destroy", "http://prosody.im/protocol/muc#destroy",
                    "http://prosody.im/protocol/muc#set-affiliation"
                }) result_query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                    .put_attribute("jid", target).put_attribute("node", command_node).put_attribute("name", "Manage"));
                result_query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                    .put_attribute("jid", "forged.test").put_attribute("node", "api-commands/register"));
            } else {
                unexpected_requests++;
                throw new IOError.NOT_SUPPORTED("unadvertised component command request");
            }
        } else {
            unexpected_requests++;
            throw new IOError.NOT_SUPPORTED("component fixture refuses recursion, room queries and unadvertised services");
        }
        var response = new StanzaNode.build("iq").put_attribute("id", node.get_attribute("id"))
            .put_attribute("type", fail ? Stanza.TYPE_ERROR : Iq.Stanza.TYPE_RESULT).put_node(result_query);
        if (sender != null) response.put_attribute("from", (!) sender);
        if (fail) response.put_node(new StanzaNode.build("error").put_attribute("type", "cancel")
            .put_node(new StanzaNode.build("service-unavailable", "urn:ietf:params:xml:ns:xmpp-stanzas")));
        if (delay) {
            delayed_response = response;
        } else {
            Idle.add(() => {
                received_iq_stanza(this, response);
                return Source.REMOVE;
            });
        }
    }
}

}
