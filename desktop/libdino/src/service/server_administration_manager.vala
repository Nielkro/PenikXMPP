/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino {

public enum ServerAdministrationCommandSource {
    NONE,
    XEP_0133,
    EJABBERD_API,
    PROSODY_ADHOC,
    COMMON_INVITE,
    EJABBERD_ADHOC
}

public enum ServerAdministrationCommandCategory {
    ACCOUNTS,
    ROSTER,
    MUC,
    SERVER,
    OTHER
}

public class ServerAdministrationManager : StreamInteractionModule, Object {
    public static ModuleIdentity<ServerAdministrationManager> IDENTITY =
        new ModuleIdentity<ServerAdministrationManager>("server_administration_manager");
    public const string ADMIN_COMMAND_PREFIX = "http://jabber.org/protocol/admin#";
    public const string EJABBERD_API_COMMAND_PREFIX = "api-commands/";
    private const uint DISCOVERY_RETRY_DELAY_MS = 250;
    private const string MUC_FEATURE = "http://jabber.org/protocol/muc";

    public string id { get { return IDENTITY.id; } }

    public signal void commands_changed(Account account);

    private StreamInteractor stream_interactor;
    private ServerAdministrationState state = new ServerAdministrationState();
    private HashMap<Account, XmppStream> same_stream_rediscovery_pending =
        new HashMap<Account, XmppStream>(Account.hash_func,
            Account.equals_func);

    public static void start(StreamInteractor stream_interactor) {
        stream_interactor.add_module(new ServerAdministrationManager(stream_interactor));
    }

    private ServerAdministrationManager(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        stream_interactor.stream_negotiated.connect(on_stream_available);
        stream_interactor.stream_resumed.connect(on_stream_available);
        stream_interactor.account_removed.connect((account) => {
            same_stream_rediscovery_pending.unset(account);
            clear_account(account);
        });
        stream_interactor.connection_manager.connection_state_changed.connect(
            on_connection_state_changed);
    }

    private void on_stream_available(Account account, XmppStream stream) {
        if (stream_interactor.get_stream(account) != stream) return;
        same_stream_rediscovery_pending.unset(account);
        discover.begin(account, stream, state.begin_discovery(account));
    }

    private void on_connection_state_changed(Account account,
            ConnectionManager.ConnectionState connection_state) {
        if (connection_state == ConnectionManager.ConnectionState.DISCONNECTED) {
            XmppStream? retained = stream_interactor.connection_manager
                .get_provisionally_retained_stream(account);
            if (retained != null) {
                same_stream_rediscovery_pending[account] = (!) retained;
            } else {
                same_stream_rediscovery_pending.unset(account);
            }
            clear_account(account);
            return;
        }

        if (connection_state != ConnectionManager.ConnectionState.CONNECTED ||
                !same_stream_rediscovery_pending.has_key(account)) return;

        XmppStream retained = same_stream_rediscovery_pending[account];
        same_stream_rediscovery_pending.unset(account);
        XmppStream? current = stream_interactor.get_stream(account);
        if (current == retained) on_stream_available(account, (!) current);
    }

    public Gee.List<Account> get_admin_accounts() {
        return state.get_admin_accounts();
    }

    public Gee.List<AdHocCommands.CommandItem> get_commands(Account account) {
        return state.get_commands(account);
    }

    public bool has_admin_accounts() {
        return state.has_admin_accounts();
    }

    public ServerAdministrationCommandSession? create_session(Account account,
                                                               AdHocCommands.CommandItem command) {
        if (!state.has_command(account, command)) return null;
        return new ServerAdministrationCommandSession(this, account, command);
    }

    public void refresh(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) {
            clear_account(account);
            return;
        }
        discover.begin(account, stream, state.begin_discovery(account));
    }

    public static bool is_admin_command(AdHocCommands.CommandItem command) {
        ServerAdministrationCommandSource source = get_command_source(command);
        return source != ServerAdministrationCommandSource.NONE &&
            source != ServerAdministrationCommandSource.COMMON_INVITE;
    }

    public static ServerAdministrationCommandSource get_command_source(AdHocCommands.CommandItem command) {
        if (command.node.has_prefix(ADMIN_COMMAND_PREFIX) &&
                command.node.length > ADMIN_COMMAND_PREFIX.length) {
            return ServerAdministrationCommandSource.XEP_0133;
        }
        if (command.node.has_prefix(EJABBERD_API_COMMAND_PREFIX) &&
                command.node.length > EJABBERD_API_COMMAND_PREFIX.length) {
            return ServerAdministrationCommandSource.EJABBERD_API;
        }
        if (is_ejabberd_node_administration(command.node)) {
            return ServerAdministrationCommandSource.EJABBERD_ADHOC;
        }
        // Exact bundled provider nodes, with shared self-service invitations
        // kept separate. A namespace alone is not an administrator permission.
        switch (command.node) {
            case "urn:xmpp:invite#invite":
            case "urn:xmpp:invite#create-account":
                // Both servers offer these nodes. Some deployments permit
                // ordinary local users, so they are not an admin-access seed.
                return ServerAdministrationCommandSource.COMMON_INVITE;
            case "xmpp:prosody.im/mod_invites_adhoc#password-reset":
            case "http://prosody.im/protocol/muc#destroy":
            case "http://prosody.im/protocol/muc#set-affiliation":
            case "http://prosody.im/protocol/config#reload":
            case "http://prosody.im/protocol/s2s#list":
            case "http://prosody.im/protocol/modules#list":
            case "http://prosody.im/protocol/modules#load":
            case "http://prosody.im/protocol/modules#global-load":
            case "http://prosody.im/protocol/modules#reload":
            case "http://prosody.im/protocol/modules#global-reload":
            case "http://prosody.im/protocol/modules#unload":
            case "http://prosody.im/protocol/modules#global-unload":
            case "http://prosody.im/protocol/hosts#activate":
            case "http://prosody.im/protocol/hosts#deactivate":
                return ServerAdministrationCommandSource.PROSODY_ADHOC;
        }
        return ServerAdministrationCommandSource.NONE;
    }

    private static bool is_ejabberd_node_administration(string node) {
        const string prefix = "running nodes/";
        if (!node.has_prefix(prefix)) return false;
        string[] parts = node.substring(prefix.length).split("/");
        if (parts.length < 2 || parts[0].strip() == "") return false;
        if (parts.length == 2) {
            return parts[1] == "DB" || parts[1] == "restart" || parts[1] == "shutdown";
        }
        if (parts.length != 3) return false;
        return (parts[1] == "backup" &&
                (parts[2] == "backup" || parts[2] == "restore" || parts[2] == "textfile")) ||
            (parts[1] == "import" && (parts[2] == "file" || parts[2] == "dir"));
    }

    public static ServerAdministrationCommandCategory get_command_category(AdHocCommands.CommandItem command) {
        ServerAdministrationCommandSource source = get_command_source(command);
        if (source == ServerAdministrationCommandSource.EJABBERD_ADHOC) {
            return ServerAdministrationCommandCategory.SERVER;
        }
        if (source == ServerAdministrationCommandSource.COMMON_INVITE ||
                command.node == "xmpp:prosody.im/mod_invites_adhoc#password-reset") {
            return ServerAdministrationCommandCategory.ACCOUNTS;
        }
        if (source == ServerAdministrationCommandSource.PROSODY_ADHOC) {
            if (command.node == "http://prosody.im/protocol/muc#destroy" ||
                    command.node == "http://prosody.im/protocol/muc#set-affiliation") {
                return ServerAdministrationCommandCategory.MUC;
            }
            return ServerAdministrationCommandCategory.SERVER;
        }
        string name;
        if (source == ServerAdministrationCommandSource.XEP_0133) {
            name = command.node.substring(ADMIN_COMMAND_PREFIX.length);
            if (name == "get-user-roster") return ServerAdministrationCommandCategory.ROSTER;
            if (name.contains("user") || name.contains("account")) {
                return ServerAdministrationCommandCategory.ACCOUNTS;
            }
            return ServerAdministrationCommandCategory.SERVER;
        }
        if (source != ServerAdministrationCommandSource.EJABBERD_API) {
            return ServerAdministrationCommandCategory.OTHER;
        }

        return get_ejabberd_api_category(command.node.substring(EJABBERD_API_COMMAND_PREFIX.length));
    }

    private static ServerAdministrationCommandCategory get_ejabberd_api_category(string name) {
        // Exact public catalogue of official ejabberd 26.09 (224 names).
        // Grouping is presentation only: it never establishes access or
        // substitutes an XEP-0133 node for an API name. Future extensions
        // remain in OTHER until their actual semantics are reviewed.
        switch (name) {
            case "ban_account":
            case "bookmarks_to_pep":
            case "change_password":
            case "check_account":
            case "check_password":
            case "check_password_hash":
            case "connected_users":
            case "connected_users_info":
            case "connected_users_number":
            case "connected_users_vhost":
            case "count_banned":
            case "delete_invite_by_token":
            case "delete_old_users":
            case "delete_old_users_vhost":
            case "expire_invite_by_token":
            case "expire_invite_tokens":
            case "generate_invite":
            case "generate_invite_with_username":
            case "generate_reset_token":
            case "get_ban_details":
            case "get_last":
            case "get_mam_count":
            case "get_offline_count":
            case "get_presence":
            case "get_vcard":
            case "get_vcard2":
            case "get_vcard2_multi":
            case "kick_session":
            case "kick_user":
            case "kick_users":
            case "list_banned":
            case "list_invites":
            case "num_resources":
            case "privacy_set":
            case "private_get":
            case "private_set":
            case "register":
            case "registered_users":
            case "remove_mam_for_user":
            case "remove_mam_for_user_with_peer":
            case "resource_num":
            case "send_stanza_c2s":
            case "set_last":
            case "set_nickname":
            case "set_presence":
            case "set_vcard":
            case "set_vcard2":
            case "set_vcard2_multi":
            case "unban_account":
            case "unregister":
            case "user_resources":
            case "user_sessions_info":
                return ServerAdministrationCommandCategory.ACCOUNTS;
            case "add_rosteritem":
            case "delete_rosteritem":
            case "get_roster":
            case "get_roster_count":
            case "process_rosteritems":
            case "push_alltoall":
            case "push_roster":
            case "push_roster_all":
            case "srg_add":
            case "srg_add_displayed":
            case "srg_create":
            case "srg_del_displayed":
            case "srg_delete":
            case "srg_get_displayed":
            case "srg_get_info":
            case "srg_get_members":
            case "srg_list":
            case "srg_set_info":
            case "srg_user_add":
            case "srg_user_del":
                return ServerAdministrationCommandCategory.ROSTER;
            case "change_room_option":
            case "create_room":
            case "create_room_with_opts":
            case "create_rooms_file":
            case "destroy_room":
            case "destroy_rooms_file":
            case "get_room_affiliation":
            case "get_room_affiliations":
            case "get_room_history":
            case "get_room_occupants":
            case "get_room_occupants_number":
            case "get_room_options":
            case "get_subscribers":
            case "get_user_rooms":
            case "get_user_subscriptions":
            case "muc_get_registered_nick":
            case "muc_get_registered_nicks":
            case "muc_online_rooms":
            case "muc_online_rooms_by_regex":
            case "muc_online_rooms_count":
            case "muc_register_nick":
            case "muc_unregister_nick":
            case "rooms_empty_destroy":
            case "rooms_empty_list":
            case "rooms_unused_destroy":
            case "rooms_unused_destroy_skip_notifications":
            case "rooms_unused_list":
            case "send_direct_invitation":
            case "set_room_affiliation":
            case "subscribe_room":
            case "subscribe_room_many":
            case "unsubscribe_room":
                return ServerAdministrationCommandCategory.MUC;
            case "abort_delete_old_mam_messages":
            case "abort_delete_old_messages":
            case "add_blocked_domain":
            case "add_to_spam_filter_cache":
            case "announce_motd_delete":
            case "announce_motd_get":
            case "announce_motd_set_online":
            case "announce_motd_update":
            case "announce_send_all":
            case "announce_send_online":
            case "backup":
            case "cleanup_expired_invite_tokens":
            case "clear_cache":
            case "compile":
            case "convert_to_scram":
            case "convert_to_yaml":
            case "delete_expired_messages":
            case "delete_expired_pubsub_items":
            case "delete_mnesia":
            case "delete_old_mam_messages":
            case "delete_old_mam_messages_batch":
            case "delete_old_mam_messages_status":
            case "delete_old_messages":
            case "delete_old_messages_batch":
            case "delete_old_messages_status":
            case "delete_old_pubsub_items":
            case "delete_old_push_sessions":
            case "drop_from_spam_filter_cache":
            case "dump":
            case "dump_config":
            case "dump_table":
            case "evacuate_kindly":
            case "expire_spam_filter_cache":
            case "export2sql":
            case "export_db":
            case "export_db_abort":
            case "export_db_ext":
            case "export_db_status":
            case "export_piefxis":
            case "export_piefxis_host":
            case "gc":
            case "gen_html_doc_for_commands":
            case "gen_markdown_doc_for_commands":
            case "gen_markdown_doc_for_tags":
            case "get_blocked_domains":
            case "get_cookie":
            case "get_loglevel":
            case "get_master":
            case "get_spam_filter_cache":
            case "halt":
            case "help":
            case "import_db":
            case "import_db_abort":
            case "import_db_status":
            case "import_dir":
            case "import_file":
            case "import_piefxis":
            case "import_prosody":
            case "incoming_s2s_number":
            case "install_fallback":
            case "join_cluster":
            case "join_cluster_here":
            case "leave_cluster":
            case "list_certificates":
            case "list_cluster":
            case "list_cluster_detailed":
            case "load":
            case "man":
            case "mnesia_change":
            case "mnesia_change_nodename":
            case "mnesia_info":
            case "mnesia_info_ctl":
            case "mnesia_list_tables":
            case "mnesia_table_change_storage":
            case "mnesia_table_info":
            case "module_check":
            case "module_install":
            case "module_uninstall":
            case "module_upgrade":
            case "modules_available":
            case "modules_installed":
            case "modules_update_specs":
            case "oauth_add_client_implicit":
            case "oauth_add_client_password":
            case "oauth_issue_token":
            case "oauth_list_tokens":
            case "oauth_remove_client":
            case "oauth_revoke_token":
            case "outgoing_s2s_number":
            case "print_sql_schema":
            case "registered_vhosts":
            case "reload_config":
            case "reload_spam_filter_files":
            case "remove_blocked_domain":
            case "reopen_log":
            case "request_certificate":
            case "restart":
            case "restart_kindly":
            case "restart_module":
            case "restore":
            case "revoke_certificate":
            case "rotate_log":
            case "send_message":
            case "send_stanza":
            case "set_loglevel":
            case "set_master":
            case "stats":
            case "stats_host":
            case "status":
            case "status_list":
            case "status_list_host":
            case "status_num":
            case "status_num_host":
            case "stop":
            case "stop_kindly":
            case "stop_s2s_connections":
            case "unban_ip":
            case "update":
            case "update_list":
            case "update_sql":
                return ServerAdministrationCommandCategory.SERVER;
            default: return ServerAdministrationCommandCategory.OTHER;
        }
    }

    public static bool establishes_admin_access(AdHocCommands.CommandItem command) {
        ServerAdministrationCommandSource source = get_command_source(command);
        if (source == ServerAdministrationCommandSource.XEP_0133 ||
                source == ServerAdministrationCommandSource.PROSODY_ADHOC ||
                source == ServerAdministrationCommandSource.EJABBERD_ADHOC) return true;
        if (source != ServerAdministrationCommandSource.EJABBERD_API) return false;

        return is_ejabberd_management_mutation(command.node.substring(EJABBERD_API_COMMAND_PREFIX.length));
    }

    private static bool is_ejabberd_management_mutation(string name) {
        // Finite, source-reviewed restricted/admin management mutations
        // from ejabberd 26.09. An advertised seed opens this account's UI
        // only; discovery and execution still use the server's permissions.
        // Query-onlys (also admin-policy/credential queries), shared native
        // invitations, CLI-only stubs and documentation/file-conversion
        // tools never establish management access on their own.
        switch (name) {
            case "abort_delete_old_mam_messages":
            case "abort_delete_old_messages":
            case "add_blocked_domain":
            case "add_rosteritem":
            case "add_to_spam_filter_cache":
            case "announce_motd_delete":
            case "announce_motd_set_online":
            case "announce_motd_update":
            case "announce_send_all":
            case "announce_send_online":
            case "backup":
            case "ban_account":
            case "bookmarks_to_pep":
            case "change_password":
            case "change_room_option":
            case "cleanup_expired_invite_tokens":
            case "clear_cache":
            case "compile":
            case "convert_to_scram":
            case "create_room":
            case "create_room_with_opts":
            case "create_rooms_file":
            case "delete_expired_messages":
            case "delete_expired_pubsub_items":
            case "delete_invite_by_token":
            case "delete_mnesia":
            case "delete_old_mam_messages":
            case "delete_old_mam_messages_batch":
            case "delete_old_messages":
            case "delete_old_messages_batch":
            case "delete_old_pubsub_items":
            case "delete_old_push_sessions":
            case "delete_old_users":
            case "delete_old_users_vhost":
            case "delete_rosteritem":
            case "destroy_room":
            case "destroy_rooms_file":
            case "drop_from_spam_filter_cache":
            case "dump":
            case "dump_config":
            case "dump_table":
            case "evacuate_kindly":
            case "expire_invite_by_token":
            case "expire_invite_tokens":
            case "expire_spam_filter_cache":
            case "export2sql":
            case "export_db":
            case "export_db_abort":
            case "export_db_ext":
            case "export_piefxis":
            case "export_piefxis_host":
            case "gc":
            case "generate_invite":
            case "generate_invite_with_username":
            case "generate_reset_token":
            case "halt":
            case "import_db":
            case "import_db_abort":
            case "import_dir":
            case "import_file":
            case "import_piefxis":
            case "import_prosody":
            case "install_fallback":
            case "join_cluster":
            case "join_cluster_here":
            case "kick_session":
            case "kick_user":
            case "kick_users":
            case "leave_cluster":
            case "load":
            case "mnesia_change_nodename":
            case "mnesia_table_change_storage":
            case "module_check":
            case "module_install":
            case "module_uninstall":
            case "module_upgrade":
            case "modules_update_specs":
            case "muc_register_nick":
            case "muc_unregister_nick":
            case "oauth_add_client_implicit":
            case "oauth_add_client_password":
            case "oauth_issue_token":
            case "oauth_remove_client":
            case "oauth_revoke_token":
            case "privacy_set":
            case "private_set":
            case "process_rosteritems":
            case "push_alltoall":
            case "push_roster":
            case "push_roster_all":
            case "register":
            case "reload_config":
            case "reload_spam_filter_files":
            case "remove_blocked_domain":
            case "remove_mam_for_user":
            case "remove_mam_for_user_with_peer":
            case "reopen_log":
            case "request_certificate":
            case "restart":
            case "restart_kindly":
            case "restart_module":
            case "restore":
            case "revoke_certificate":
            case "rooms_empty_destroy":
            case "rooms_unused_destroy":
            case "rooms_unused_destroy_skip_notifications":
            case "rotate_log":
            case "send_direct_invitation":
            case "send_message":
            case "send_stanza":
            case "send_stanza_c2s":
            case "set_last":
            case "set_loglevel":
            case "set_master":
            case "set_nickname":
            case "set_presence":
            case "set_room_affiliation":
            case "set_vcard":
            case "set_vcard2":
            case "set_vcard2_multi":
            case "srg_add":
            case "srg_add_displayed":
            case "srg_create":
            case "srg_del_displayed":
            case "srg_delete":
            case "srg_set_info":
            case "srg_user_add":
            case "srg_user_del":
            case "stop":
            case "stop_kindly":
            case "stop_s2s_connections":
            case "subscribe_room":
            case "subscribe_room_many":
            case "unban_account":
            case "unban_ip":
            case "unregister":
            case "unsubscribe_room":
            case "update":
            case "update_sql":
                return true;
            default: return false;
        }
    }

    internal async ServerAdministrationTransportResult execute_command(
            Account account, AdHocCommands.CommandItem command) {
        AdHocCommands.Module? module = get_command_module(account, command);
        if (module == null) return new ServerAdministrationTransportResult.failed(get_transport_error(account, command));

        XmppStream stream = (!) stream_interactor.get_stream(account);
        AdHocCommands.Command? result = yield ((!) module).execute(stream, command.jid, command.node);
        if (result == null) {
            return new ServerAdministrationTransportResult.failed(((!) module).last_error ?? "command-execute-failed");
        }
        return new ServerAdministrationTransportResult.completed(result);
    }

    internal async ServerAdministrationTransportResult proceed_command(
            Account account, AdHocCommands.CommandItem command, string sessionid, string action,
            DataForms.DataForm? form) {
        AdHocCommands.Module? module = get_command_module(account, command);
        if (module == null) return new ServerAdministrationTransportResult.failed(get_transport_error(account, command));

        XmppStream stream = (!) stream_interactor.get_stream(account);
        // Freeze the submitted room before yielding. Commands may run while
        // this account is not an occupant, so no destruction presence arrives.
        Jid? destroyed_room = get_submitted_destroy_room(command.node, form);
        MucManager? muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        MucManager.RoomDestructionContext? destruction = destroyed_room != null && muc != null && action != "cancel"
            ? muc.prepare_administrative_room_destruction(account, destroyed_room) : null;
        AdHocCommands.Command? result = yield ((!) module).proceed(
            stream, command.jid, command.node, sessionid, action, form);
        if (result == null) {
            return new ServerAdministrationTransportResult.failed(((!) module).last_error ?? "command-proceed-failed");
        }
        if (destruction != null && result.node == command.node && result.sessionid == sessionid &&
                result.completed_successfully())
            muc.complete_administrative_room_destruction(account, destruction);
        return new ServerAdministrationTransportResult.completed(result);
    }

    private static Jid? get_submitted_destroy_room(string node, DataForms.DataForm? form) {
        if (node != EJABBERD_API_COMMAND_PREFIX + "destroy_room" || form == null) return null;
        string? room = null;
        string? service = null;
        foreach (DataForms.DataForm.Field field in form.fields) {
            if (field.var != "room" && field.var != "service") continue;
            var values = field.get_values();
            if (values.size != 1) return null;
            if (field.var == "room") {
                if (room != null) return null;
                room = values[0];
            } else {
                if (service != null) return null;
                service = values[0];
            }
        }
        if (room == null || service == null || room.length == 0 || service.length == 0) return null;
        if (room.contains("@") || room.contains("/")) return null;
        try {
            Jid host = new Jid(service);
            if (host.localpart != null || host.resourcepart != null) return null;
            Jid jid = new Jid(room + "@" + service);
            if (jid.resourcepart != null || jid.localpart == null) return null;
            return jid;
        } catch (InvalidJidError e) {
            return null;
        }
    }

    internal async ServerAdministrationTransportResult cancel_command(
            Account account, AdHocCommands.CommandItem command, string sessionid) {
        AdHocCommands.Module? module = get_command_module(account, command);
        if (module == null) return new ServerAdministrationTransportResult.failed(get_transport_error(account, command));

        XmppStream stream = (!) stream_interactor.get_stream(account);
        bool success = yield ((!) module).cancel(stream, command.jid, command.node, sessionid);
        if (!success) return new ServerAdministrationTransportResult.failed("command-cancel-failed");
        return new ServerAdministrationTransportResult.completed();
    }

    private async void discover(Account account, XmppStream stream,
                                uint generation, bool retry_allowed = true) {
        if (!is_current_discovery(account, stream, generation)) return;
        AdHocCommands.Module? module = stream.get_module<AdHocCommands.Module>(AdHocCommands.Module.IDENTITY);
        if (module == null) {
            apply_discovery(account, stream, generation, null);
            return;
        }

        Gee.List<AdHocCommands.CommandItem>? commands = yield ((!) module).list_commands(
            stream, account.bare_jid.domain_jid);
        if (!is_current_discovery(account, stream, generation)) return;
        if (commands == null && retry_allowed &&
                stream_interactor.get_stream(account) == stream &&
                state.is_current_discovery(account, generation)) {
            Timeout.add(DISCOVERY_RETRY_DELAY_MS, () => {
                if (stream_interactor.get_stream(account) != stream ||
                        !state.is_current_discovery(account, generation)) {
                    return Source.REMOVE;
                }
                discover.begin(account, stream, generation, false);
                return Source.REMOVE;
            });
            return;
        }
        // Publish a working primary administration list immediately. With
        // component-only rights, an empty primary list must not close the
        // existing dialog halfway through a refresh; resolve the whole list.
        bool primary_admin_access = false;
        if (commands != null) {
            foreach (AdHocCommands.CommandItem command in (!) commands) {
                if (establishes_admin_access(command)) primary_admin_access = true;
            }
        }
        if (primary_admin_access) apply_discovery(account, stream, generation, commands);
        yield discover_component_commands(account, stream, generation, (!) module, commands);
    }

    private bool is_current_discovery(Account account, XmppStream stream, uint generation) {
        return stream_interactor.get_stream(account) == stream &&
            state.is_current_discovery(account, generation);
    }

    private async void pause_discovery_retry() {
        Timeout.add(DISCOVERY_RETRY_DELAY_MS, () => {
            pause_discovery_retry.callback();
            return Source.REMOVE;
        });
        yield;
    }

    private static bool is_discovery_result_from(Iq.Stanza iq, Jid target) {
        return iq.type_ == Iq.Stanza.TYPE_RESULT && iq.from != null &&
            Jid.equals_func((!) iq.from, target);
    }

    private async void discover_component_commands(Account account, XmppStream stream,
            uint generation, AdHocCommands.Module commands_module,
            Gee.List<AdHocCommands.CommandItem>? primary_commands) {
        if (!is_current_discovery(account, stream, generation)) return;
        ServiceDiscovery.Module? disco = stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY);
        if (disco == null) {
            apply_discovery(account, stream, generation, primary_commands);
            return;
        }
        Jid parent = account.bare_jid.domain_jid;

        // MucManager's cached default service has no authenticated parent-IQ
        // provenance and covers only one component. Do not infer administration
        // targets from bookmarks, rooms, contacts, or that single cached JID.
        ServiceDiscovery.ItemsResult? services = yield ((!) disco).request_items(stream, parent);
        if (!is_current_discovery(account, stream, generation)) return;
        if (services == null) {
            yield pause_discovery_retry();
            if (!is_current_discovery(account, stream, generation)) return;
            services = yield ((!) disco).request_items(stream, parent);
            if (!is_current_discovery(account, stream, generation)) return;
        }
        if (services == null || !is_discovery_result_from(((!) services).iq, parent)) {
            apply_discovery(account, stream, generation, primary_commands);
            return;
        }
        StanzaNode? parent_query = ((!) services).iq.stanza.get_subnode("query", ServiceDiscovery.NS_URI_ITEMS);
        string? parent_node = parent_query != null ? ((!) parent_query).get_attribute("node") : null;
        if (parent_node != null && parent_node != "") {
            apply_discovery(account, stream, generation, primary_commands);
            return;
        }

        var all_commands = new ArrayList<AdHocCommands.CommandItem>();
        if (primary_commands != null) all_commands.add_all((!) primary_commands);
        var seen_services = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        foreach (ServiceDiscovery.Item service in ((!) services).items) {
            Jid target = service.jid;
            if (target.localpart != null || target.resourcepart != null ||
                    target.equals(parent) || (service.node != null && service.node != "") ||
                    !seen_services.add(target)) continue;

            ServiceDiscovery.InfoResult? info = yield ((!) disco).request_info(stream, target);
            if (!is_current_discovery(account, stream, generation)) return;
            if (info == null) {
                yield pause_discovery_retry();
                if (!is_current_discovery(account, stream, generation)) return;
                info = yield ((!) disco).request_info(stream, target);
                if (!is_current_discovery(account, stream, generation)) return;
            }
            if (info == null || !is_discovery_result_from(((!) info).iq, target)) continue;
            StanzaNode? info_query = ((!) info).iq.stanza.get_subnode("query", ServiceDiscovery.NS_URI_INFO);
            string? info_node = info_query != null ? ((!) info_query).get_attribute("node") : null;
            if (info_node != null && info_node != "") continue;
            if (!((!) info).features.contains(MUC_FEATURE) ||
                    !((!) info).features.contains(AdHocCommands.NS_URI)) continue;
            bool conference = false;
            foreach (ServiceDiscovery.Identity identity in ((!) info).identities) {
                if (identity.category == ServiceDiscovery.Identity.CATEGORY_CONFERENCE) {
                    conference = true;
                    break;
                }
            }
            if (!conference) continue;

            Gee.List<AdHocCommands.CommandItem>? component_commands = yield commands_module.list_commands(stream, target);
            if (!is_current_discovery(account, stream, generation)) return;
            if (component_commands == null) {
                yield pause_discovery_retry();
                if (!is_current_discovery(account, stream, generation)) return;
                component_commands = yield commands_module.list_commands(stream, target);
                if (!is_current_discovery(account, stream, generation)) return;
            }
            if (component_commands != null && !((!) component_commands).is_empty) {
                all_commands.add_all((!) component_commands);
            }
        }
        apply_discovery(account, stream, generation, all_commands);
    }

    private void apply_discovery(Account account, XmppStream stream, uint generation,
                                 Gee.List<AdHocCommands.CommandItem>? commands) {
        if (stream_interactor.get_stream(account) != stream) return;
        if (state.complete_discovery(account, generation, commands)) {
            commands_changed(account);
        }
    }

    private void clear_account(Account account) {
        if (state.clear(account)) {
            commands_changed(account);
        }
    }

    private AdHocCommands.Module? get_command_module(Account account, AdHocCommands.CommandItem command) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !state.has_command(account, command)) return null;
        return ((!) stream).get_module<AdHocCommands.Module>(AdHocCommands.Module.IDENTITY);
    }

    private string get_transport_error(Account account, AdHocCommands.CommandItem command) {
        if (stream_interactor.get_stream(account) == null) return "account-not-connected";
        if (!state.has_command(account, command)) return "command-not-available";
        return "ad-hoc-commands-unavailable";
    }
}

internal class ServerAdministrationState : Object {
    private HashMap<Account, uint> generations =
        new HashMap<Account, uint>(Account.hash_func, Account.equals_func);
    private HashMap<Account, ArrayList<AdHocCommands.CommandItem>> commands_by_account =
        new HashMap<Account, ArrayList<AdHocCommands.CommandItem>>(Account.hash_func, Account.equals_func);

    public uint begin_discovery(Account account) {
        uint generation = generations.has_key(account) ? generations[account] + 1 : 1;
        generations[account] = generation;
        return generation;
    }

    public bool complete_discovery(Account account, uint generation,
                                   Gee.List<AdHocCommands.CommandItem>? discovered_commands) {
        if (!generations.has_key(account) || generations[account] != generation) return false;

        var admin_commands = new ArrayList<AdHocCommands.CommandItem>();
        bool has_admin_access = false;
        if (discovered_commands != null) {
            foreach (AdHocCommands.CommandItem command in discovered_commands) {
                if ((ServerAdministrationManager.is_admin_command(command) ||
                        ServerAdministrationManager.get_command_source(command) ==
                            ServerAdministrationCommandSource.COMMON_INVITE) &&
                        !contains_command(admin_commands, command)) {
                    admin_commands.add(command);
                }
                if (ServerAdministrationManager.establishes_admin_access(command)) {
                    has_admin_access = true;
                }
            }
        }

        if (!has_admin_access || admin_commands.is_empty) {
            commands_by_account.unset(account);
        } else {
            commands_by_account[account] = admin_commands;
        }
        return true;
    }

    public bool is_current_discovery(Account account, uint generation) {
        return generations.has_key(account) &&
            generations[account] == generation;
    }

    public bool clear(Account account) {
        begin_discovery(account);
        return commands_by_account.unset(account);
    }

    public bool has_admin_accounts() {
        return !commands_by_account.is_empty;
    }

    public Gee.List<Account> get_admin_accounts() {
        var accounts = new ArrayList<Account>();
        accounts.add_all(commands_by_account.keys);
        return accounts;
    }

    public Gee.List<AdHocCommands.CommandItem> get_commands(Account account) {
        var commands = new ArrayList<AdHocCommands.CommandItem>();
        if (commands_by_account.has_key(account)) {
            commands.add_all(commands_by_account[account]);
        }
        return commands;
    }

    public bool has_command(Account account, AdHocCommands.CommandItem candidate) {
        if (!commands_by_account.has_key(account)) return false;
        return contains_command(commands_by_account[account], candidate);
    }

    private static bool contains_command(Gee.List<AdHocCommands.CommandItem> commands,
                                         AdHocCommands.CommandItem candidate) {
        // Discovery identity and execution authorization use the same exact
        // node and semantic target JID, independent of a display name.
        foreach (AdHocCommands.CommandItem command in commands) {
            if (command.node == candidate.node && Jid.equals_func(command.jid, candidate.jid)) return true;
        }
        return false;
    }
}

}
