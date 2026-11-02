/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

using Xmpp.Xep;

namespace Dino.Ui.Util {

// Presentation only: the server-provided node, fields and permitted actions
// remain authoritative. Unknown commands keep their server-provided title.
public class ServerAdministrationLabels : Object {
    public string title { get; private set; }
    public string? description { get; private set; }
    public string submit_label { get; private set; }
    public bool destructive { get; private set; }
    private bool conditional_roster_deletion;

    private ServerAdministrationLabels(string title, string? description,
            string submit_label, bool destructive = false, bool conditional_roster_deletion = false) {
        this.title = title;
        this.description = description;
        this.submit_label = submit_label;
        this.destructive = destructive;
        this.conditional_roster_deletion = conditional_roster_deletion;
    }

    public string action_label(string action) {
        // A next/previous step must never promise that the final operation
        // has already been performed, even for destructive commands.
        if (action == "next") return _("Next");
        if (action == "prev") return _("Previous");
        return submit_label;
    }

    public bool requires_confirmation(string action, DataForms.DataForm? form = null) {
        if (action != "complete" && action != "") return false;
        if (destructive) return true;
        if (conditional_roster_deletion && form != null) {
            foreach (DataForms.DataForm.Field field in ((!) form).fields) {
                if (field.var == "action" && field.get_values().contains("delete")) return true;
            }
        }
        return false;
    }

    public static bool executes_immediately(AdHocCommands.CommandItem command) {
        // This stock command reloads configuration on the initial execute
        // request. It has no later server form at which to show an action.
        return command.node == "http://prosody.im/protocol/config#reload";
    }

    public static AdHocCommands.CommandItem? find_command_at_target(
            Gee.List<AdHocCommands.CommandItem> commands, string node, Xmpp.Jid target) {
        foreach (AdHocCommands.CommandItem command in commands) {
            if (command.node == node && command.jid.equals(target)) return command;
        }
        return null;
    }

    public static string? source_name(AdHocCommands.CommandItem command) {
        switch (ServerAdministrationManager.get_command_source(command)) {
            case ServerAdministrationCommandSource.XEP_0133:
                return _("Standard administration");
            case ServerAdministrationCommandSource.EJABBERD_API:
                return _("ejabberd API");
            case ServerAdministrationCommandSource.PROSODY_ADHOC:
                return _("Prosody administration");
            case ServerAdministrationCommandSource.COMMON_INVITE:
                return _("Invitations");
            case ServerAdministrationCommandSource.EJABBERD_ADHOC:
                return _("ejabberd administration");
            default: return null;
        }
    }

    public static string available_interfaces(Gee.List<AdHocCommands.CommandItem> commands) {
        var names = new Gee.ArrayList<string>();
        bool ejabberd = false;
        bool prosody = false;
        foreach (AdHocCommands.CommandItem command in commands) {
            var source = ServerAdministrationManager.get_command_source(command);
            ejabberd |= source == ServerAdministrationCommandSource.EJABBERD_API ||
                source == ServerAdministrationCommandSource.EJABBERD_ADHOC;
            prosody |= source == ServerAdministrationCommandSource.PROSODY_ADHOC;
            string? name = source_name(command);
            if (name != null && !names.contains((!) name)) names.add((!) name);
        }
        string[] interface_names = new string[names.size];
        for (int i = 0; i < names.size; i++) interface_names[i] = names[i];
        string interfaces = string.joinv(" · ", interface_names);
        if (names.is_empty) return _("Administration of advertised services");
        // These are the capabilities advertised for the selected account's
        // own server. Standard-only discovery cannot identify its software.
        if (ejabberd != prosody) {
            return _("Server: %s\nAdministration: %s").printf(ejabberd ? "ejabberd" : "Prosody", interfaces);
        }
        return _("Available administration: %s").printf(interfaces);
    }

    public static string list_subtitle(AdHocCommands.CommandItem command) {
        string? source = source_name(command);
        string? description = for_command(command).description;
        if (source == null) return description ?? "";
        string origin = "%s · %s".printf((!) source, command.jid.to_string());
        if (description == null) return origin;
        return "%s · %s".printf(origin, (!) description);
    }

    public static Gee.Map<AdHocCommands.CommandItem, string> list_titles(
            Gee.List<AdHocCommands.CommandItem> commands) {
        var titles = new Gee.HashMap<AdHocCommands.CommandItem, string>();
        var counts = new Gee.HashMap<string, int>();
        foreach (AdHocCommands.CommandItem command in commands) {
            string title = for_command(command).title;
            titles[command] = title;
            counts[title] = counts.has_key(title) ? counts[title] + 1 : 1;
        }
        var qualified_counts = new Gee.HashMap<string, int>();
        foreach (AdHocCommands.CommandItem command in commands) {
            string title = titles[command];
            if (counts[title] > 1) {
                title = _("%s (%s)").printf(title, source_name(command) ?? _("Server command"));
                titles[command] = title;
            }
            qualified_counts[title] = qualified_counts.has_key(title) ? qualified_counts[title] + 1 : 1;
        }
        foreach (AdHocCommands.CommandItem command in commands) {
            string title = titles[command];
            if (qualified_counts[title] > 1) {
                // Distinct extension commands can have the same server name.
                // Keep their actual target and node visible, never merge by label.
                titles[command] = _("%s (%s)").printf(title,
                    "%s / %s".printf(command.jid.to_string(), command.node));
            }
        }
        return titles;
    }

    public static string? submission_error(AdHocCommands.CommandItem command, DataForms.DataForm form) {
        if (command.node == "xmpp:prosody.im/mod_invites_adhoc#password-reset") {
            foreach (DataForms.DataForm.Field field in form.fields) {
                if (field.var != "accountjid") continue;
                var values = field.get_values();
                try {
                    var jid = new Xmpp.Jid(values.is_empty ? "" : values[0]);
                    if (jid.localpart != null && jid.domain_jid.equals(command.jid.domain_jid)) return null;
                } catch (Xmpp.InvalidJidError e) {
                    // The same scoped guidance applies to invalid and foreign JIDs.
                }
                return _("Enter an account address on %s. This reset command applies only to that server.")
                    .printf(command.jid.domain_jid.to_string());
            }
        }
        // Current ejabberd policy=user APIs can repeat user/host input fields.
        // Do not rewrite that server schema or submit ambiguous arguments.
        if (command.node == "api-commands/get_roster" || command.node == "api-commands/get_roster_count" ||
                command.node == "api-commands/get_mam_count" || command.node == "api-commands/get_offline_count") {
            var variables = new Gee.HashSet<string>();
            foreach (DataForms.DataForm.Field field in form.fields) {
                if (field.type_ == DataForms.DataForm.Type.FIXED || field.var == null) continue;
                if (!variables.add((!) field.var)) {
                    return _("The server supplied duplicate input fields (%s). This command cannot be submitted.")
                        .printf((!) field.var);
                }
            }
        }
        return null;
    }

    public static ServerAdministrationLabels for_command(AdHocCommands.CommandItem command) {
        if (ServerAdministrationManager.get_command_source(command) == ServerAdministrationCommandSource.EJABBERD_ADHOC) {
            return for_cluster_command(command);
        }
        string node = command.node;
        switch (node) {
            case "urn:xmpp:invite#invite":
                return new ServerAdministrationLabels(_("Create Contact Invitation"),
                    _("Create an invitation link to add a contact"), _("Create invitation"));
            case "urn:xmpp:invite#create-account":
                return new ServerAdministrationLabels(_("Create Account Invitation"),
                    _("Create an invitation link for registering an account"), _("Create invitation"));
            case "xmpp:prosody.im/mod_invites_adhoc#password-reset":
                return new ServerAdministrationLabels(_("Create Password Reset Link"),
                    _("Create a link to reset an account password on the selected server"), _("Create reset link"));
            case "http://prosody.im/protocol/muc#destroy":
                return new ServerAdministrationLabels(_("Delete Group Chats"),
                    _("Permanently delete the selected rooms on this group chat service"), _("Delete rooms"), true);
            case "http://prosody.im/protocol/muc#set-affiliation":
                return new ServerAdministrationLabels(_("Change Group Chat Membership"),
                    _("Set the selected user's membership or administration rights in the room"), _("Save membership"));
            case "api-commands/generate_invite":
                return new ServerAdministrationLabels(_("Create Account Invitation"),
                    _("Create an invitation for the chosen XMPP domain"), _("Create invitation"));
            case "api-commands/generate_invite_with_username":
                return new ServerAdministrationLabels(_("Create Invitation for a Username"),
                    _("Create an account invitation for the specified username and XMPP domain"), _("Create invitation"));
            case "api-commands/generate_reset_token":
                return new ServerAdministrationLabels(_("Create Password Reset Link"),
                    _("Create a reset token and link for the specified account"), _("Create reset link"));
            case "api-commands/list_invites":
                return new ServerAdministrationLabels(_("List Invitations"),
                    _("Show invitation and password reset tokens for the chosen XMPP domain"), _("Show invitations"));
            case "api-commands/cleanup_expired_invite_tokens":
                return new ServerAdministrationLabels(_("Delete Expired Invitation Tokens"),
                    _("Remove expired invitation tokens from storage"), _("Delete tokens"), true);
            case "api-commands/delete_invite_by_token":
                return new ServerAdministrationLabels(_("Delete One Invitation Token"),
                    _("Remove the specified invitation token from storage"), _("Delete token"), true);
            case "api-commands/expire_invite_tokens":
                return new ServerAdministrationLabels(_("Expire Invitation Tokens for an Account"),
                    _("Expire invitation tokens belonging to the specified account"), _("Expire tokens"), true);
            case "api-commands/expire_invite_by_token":
                return new ServerAdministrationLabels(_("Expire One Invitation Token"),
                    _("Expire the specified invitation token"), _("Expire token"), true);
            case "http://jabber.org/protocol/admin#add-user": case "api-commands/register":
                return new ServerAdministrationLabels(_("Create User Account"),
                    _("Create a new account on the selected server"), _("Create account"));
            case "http://jabber.org/protocol/admin#delete-user": case "api-commands/unregister":
                return new ServerAdministrationLabels(_("Delete User Accounts"),
                    _("Permanently delete the selected accounts and their server data"), _("Delete accounts"), true);
            case "http://jabber.org/protocol/admin#disable-user": case "api-commands/ban_account":
                return new ServerAdministrationLabels(_("Disable User Accounts"),
                    _("Prevent the selected accounts from signing in"), _("Disable accounts"), true);
            case "http://jabber.org/protocol/admin#reenable-user": case "api-commands/unban_account":
                return new ServerAdministrationLabels(_("Enable User Accounts"),
                    _("Allow disabled accounts to sign in again"), _("Enable accounts"));
            case "http://jabber.org/protocol/admin#change-user-password": case "api-commands/change_password":
                return new ServerAdministrationLabels(_("Change User Password"),
                    _("Set a new password for a user account"), _("Change password"));
            case "http://jabber.org/protocol/admin#end-user-session":
                return new ServerAdministrationLabels(_("Disconnect Users"),
                    _("End the selected users' current connections"), _("Disconnect users"), true);
            case "api-commands/kick_user":
                return new ServerAdministrationLabels(_("Disconnect One User"),
                    _("End all current connections of the selected account"), _("Disconnect user"), true);
            case "api-commands/kick_users":
                return new ServerAdministrationLabels(_("Disconnect All Users of a Domain"),
                    _("End all user connections for the selected XMPP domain"), _("Disconnect users"), true);
            case "api-commands/kick_session":
                return new ServerAdministrationLabels(_("Disconnect One Connection"),
                    _("End the selected account's connection for one resource"), _("Disconnect connection"), true);
            case "api-commands/delete_old_users":
                return new ServerAdministrationLabels(_("Delete Inactive Accounts Across All Domains"),
                    _("Permanently delete inactive accounts across all XMPP domains on this server"), _("Delete accounts"), true);
            case "api-commands/delete_old_users_vhost":
                return new ServerAdministrationLabels(_("Delete Inactive Accounts of a Domain"),
                    _("Permanently delete inactive accounts for the selected XMPP domain"), _("Delete accounts"), true);
            case "http://jabber.org/protocol/admin#get-user-roster": case "api-commands/get_roster":
                return new ServerAdministrationLabels(_("View User Roster"),
                    _("Show all contacts in a user's roster"), _("Show contacts"));
            case "api-commands/add_rosteritem":
                return new ServerAdministrationLabels(_("Add Contact to Roster"),
                    _("Add or update a contact in a user's roster"), _("Add contact"));
            case "api-commands/delete_rosteritem":
                return new ServerAdministrationLabels(_("Remove Contact from Roster"),
                    _("Remove a contact from a user's roster"), _("Remove contact"));
            case "http://jabber.org/protocol/admin#get-registered-users-list": case "api-commands/registered_users":
                return new ServerAdministrationLabels(_("List User Accounts"),
                    _("Show the accounts registered on the selected server"), _("Show accounts"));
            case "http://jabber.org/protocol/admin#get-disabled-users-list":
                return new ServerAdministrationLabels(_("List Disabled Accounts"),
                    _("Show accounts that cannot sign in"), _("Show accounts"));
            case "http://jabber.org/protocol/admin#get-disabled-users-num":
                return new ServerAdministrationLabels(_("Count Disabled Accounts"), null, _("Show count"));
            case "http://jabber.org/protocol/admin#get-active-users":
                return new ServerAdministrationLabels(_("List Available Users"),
                    _("Show users whose presence is available, chat or do not disturb"), _("Show users"));
            case "http://jabber.org/protocol/admin#get-idle-users":
                return new ServerAdministrationLabels(_("List Away Users"),
                    _("Show users whose presence is away or extended away"), _("Show users"));
            case "http://jabber.org/protocol/admin#get-active-users-num":
                return new ServerAdministrationLabels(_("Count Available Connections"), null, _("Show count"));
            case "http://jabber.org/protocol/admin#get-idle-users-num":
                return new ServerAdministrationLabels(_("Count Away Connections"), null, _("Show count"));
            case "http://jabber.org/protocol/admin#get-user-lastlogin":
                return new ServerAdministrationLabels(_("View Last Account Activity"), null, _("Show information"));
            case "http://jabber.org/protocol/admin#announce": case "api-commands/announce_send_online":
                return new ServerAdministrationLabels(_("Announce to Online Users"),
                    _("Send an announcement to online users of the chosen domain"), _("Send announcement"));
            case "http://jabber.org/protocol/admin#announce-all": case "api-commands/announce_send_all":
                return new ServerAdministrationLabels(_("Announce to All Users of a Domain"),
                    _("Send an announcement to all registered users of the chosen domain"), _("Send announcement"));
            case "http://jabber.org/protocol/admin#announce-allhosts":
                return new ServerAdministrationLabels(_("Announce to Online Users Across All Domains"), null, _("Send announcement"));
            case "http://jabber.org/protocol/admin#announce-all-allhosts":
                return new ServerAdministrationLabels(_("Announce to All Users Across All Domains"), null, _("Send announcement"));
            case "http://jabber.org/protocol/admin#set-motd": case "api-commands/announce_motd_set_online":
                return new ServerAdministrationLabels(_("Set Login Message for a Domain"),
                    _("Set the login message and send it to online users of the chosen domain"), _("Set message"));
            case "http://jabber.org/protocol/admin#edit-motd": case "api-commands/announce_motd_update":
                return new ServerAdministrationLabels(_("Edit Login Message for a Domain"), null, _("Save message"));
            case "http://jabber.org/protocol/admin#delete-motd": case "api-commands/announce_motd_delete":
                return new ServerAdministrationLabels(_("Delete Login Message for a Domain"), null, _("Delete message"), true);
            case "http://jabber.org/protocol/admin#set-motd-allhosts":
                return new ServerAdministrationLabels(_("Set Login Message Across All Domains"), null, _("Set message"));
            case "http://jabber.org/protocol/admin#edit-motd-allhosts":
                return new ServerAdministrationLabels(_("Edit Login Message Across All Domains"), null, _("Save message"));
            case "http://jabber.org/protocol/admin#delete-motd-allhosts":
                return new ServerAdministrationLabels(_("Delete Login Message Across All Domains"), null, _("Delete message"), true);
            case "api-commands/announce_motd_get":
                return new ServerAdministrationLabels(_("View Login Message for a Domain"), null, _("Show message"));
            case "http://jabber.org/protocol/admin#get-online-users-list":
                return new ServerAdministrationLabels(_("List Online Users"),
                    _("Show users who are currently connected"), _("Show users"));
            case "api-commands/connected_users":
                return new ServerAdministrationLabels(_("List Online Connections Across All Domains"),
                    _("Show established user connections across all XMPP domains on this server"), _("Show connections"));
            case "api-commands/connected_users_vhost":
                return new ServerAdministrationLabels(_("List Online Connections of a Domain"),
                    _("Show established user connections for the selected XMPP domain"), _("Show connections"));
            case "http://jabber.org/protocol/admin#get-registered-users-num":
                return new ServerAdministrationLabels(_("Count User Accounts"),
                    _("Show how many accounts are registered"), _("Show count"));
            case "http://jabber.org/protocol/admin#get-online-users-num":
                return new ServerAdministrationLabels(_("Count Online Connections of a Domain"),
                    _("Show how many user connections are currently established"), _("Show count"));
            case "api-commands/connected_users_number":
                return new ServerAdministrationLabels(_("Count Online Connections Across All Domains"),
                    _("Show how many user connections are currently established"), _("Show count"));
            case "http://jabber.org/protocol/admin#user-stats":
                return new ServerAdministrationLabels(_("View User Information"),
                    _("Show information about the selected user account"), _("Show information"));
            case "api-commands/user_sessions_info":
                return new ServerAdministrationLabels(_("View User Connections"),
                    _("Show connection details for the selected account"), _("Show connections"));
            case "api-commands/muc_online_rooms":
                return new ServerAdministrationLabels(_("List Group Chats"),
                    _("Show existing rooms currently loaded by the server"), _("Show rooms"));
            case "api-commands/create_room":
                return new ServerAdministrationLabels(_("Create Group Chat"),
                    _("Create a room on a group chat service"), _("Create room"));
            case "api-commands/create_room_with_opts":
                return new ServerAdministrationLabels(_("Create Group Chat with Settings"),
                    _("Create a room using the settings supplied in the form"), _("Create room"));
            case "api-commands/create_rooms_file":
                return new ServerAdministrationLabels(_("Create Group Chats from a File"),
                    _("Create the rooms listed in the server-side file"), _("Create rooms"));
            case "api-commands/change_room_option":
                return new ServerAdministrationLabels(_("Change Group Chat Settings"),
                    _("Change the selected room setting"), _("Save setting"));
            case "api-commands/set_room_affiliation":
                return new ServerAdministrationLabels(_("Change Group Chat Membership"),
                    _("Set the selected user's membership or administration rights in the room"), _("Save membership"));
            case "api-commands/destroy_room":
                return new ServerAdministrationLabels(_("Delete Group Chat"),
                    _("Permanently delete a room from the server"), _("Delete room"), true);
            case "api-commands/rooms_empty_list":
                return new ServerAdministrationLabels(_("List Group Chats with Empty Archives"),
                    _("Show rooms with message archiving enabled and no archived messages"), _("Show rooms"));
            case "api-commands/rooms_unused_list":
                return new ServerAdministrationLabels(_("List Unused Group Chats"),
                    _("Show rooms that have not been used within the chosen period"), _("Show rooms"));
            case "api-commands/rooms_empty_destroy":
                return new ServerAdministrationLabels(_("Delete Group Chats with Empty Archives"),
                    _("Permanently delete rooms with message archiving enabled and no archived messages; participants may still be present"), _("Delete rooms"), true);
            case "api-commands/rooms_unused_destroy":
                return new ServerAdministrationLabels(_("Delete Unused Group Chats"),
                    _("Permanently delete all rooms matching the chosen criteria"), _("Delete rooms"), true);
            case "api-commands/rooms_unused_destroy_skip_notifications":
                return new ServerAdministrationLabels(_("Delete Unused Group Chats Without Notifications"),
                    _("Permanently delete matching rooms without sending notifications"), _("Delete rooms"), true);
            case "api-commands/destroy_rooms_file":
                return new ServerAdministrationLabels(_("Delete Group Chats from a File"),
                    _("Permanently delete the rooms listed in the server-side file"), _("Delete rooms"), true);
            case "api-commands/srg_list":
                return new ServerAdministrationLabels(_("List Shared Contact Groups"),
                    _("Show shared contact groups managed by the server"), _("Show groups"));
            case "api-commands/srg_create":
                return new ServerAdministrationLabels(_("Create Shared Contact Group"),
                    _("Create a contact group shared between user accounts"), _("Create group"));
            case "api-commands/srg_add":
                return new ServerAdministrationLabels(_("Add Shared Contact Group"), null, _("Add group"));
            case "api-commands/srg_set_info":
                return new ServerAdministrationLabels(_("Change Shared Contact Group Settings"), null, _("Save settings"));
            case "api-commands/srg_add_displayed":
                return new ServerAdministrationLabels(_("Show Shared Contact Group"),
                    _("Add a shared group to the selected group's displayed contacts"), _("Add group"));
            case "api-commands/srg_del_displayed":
                return new ServerAdministrationLabels(_("Hide Shared Contact Group"),
                    _("Remove a shared group from the selected group's displayed contacts"), _("Remove group"));
            case "api-commands/srg_delete":
                return new ServerAdministrationLabels(_("Delete Shared Contact Group"),
                    _("Remove a shared contact group from the server"), _("Delete group"), true);
            case "api-commands/srg_user_add":
                return new ServerAdministrationLabels(_("Add User to Shared Contact Group"), null, _("Add user"));
            case "api-commands/srg_user_del":
                return new ServerAdministrationLabels(_("Remove User from Shared Contact Group"), null, _("Remove user"));
            case "api-commands/process_rosteritems":
                return new ServerAdministrationLabels(_("List or Remove Matching Contacts"),
                    _("Apply the server's contact filters using the selected list or delete action"),
                    _("Run selected action"), false, true);
            case "api-commands/delete_expired_messages":
                return new ServerAdministrationLabels(_("Delete Expired Offline Messages"),
                    _("Permanently remove expired offline messages from the database"), _("Delete messages"), true);
            case "api-commands/delete_old_messages":
                return new ServerAdministrationLabels(_("Delete Old Offline Messages Across All Domains"),
                    _("Permanently delete offline messages older than the specified number of days"), _("Delete messages"), true);
            case "api-commands/delete_old_messages_batch":
                return new ServerAdministrationLabels(_("Delete Old Offline Messages of a Domain in Batches"),
                    _("Start a background task to permanently delete matching messages for the specified domain"), _("Start deletion"), true);
            case "api-commands/delete_old_mam_messages":
                return new ServerAdministrationLabels(_("Delete Old Archived Messages Across All Domains"),
                    _("Permanently delete archived messages matching the specified age and chat type"), _("Delete messages"), true);
            case "api-commands/delete_old_mam_messages_batch":
                return new ServerAdministrationLabels(_("Delete Old Archived Messages of a Domain in Batches"),
                    _("Start a background task to permanently delete matching archived messages for the specified domain"), _("Start deletion"), true);
            case "api-commands/remove_mam_for_user":
                return new ServerAdministrationLabels(_("Delete an Account's Message Archive"),
                    _("Permanently delete the archived messages of the specified account"), _("Delete archive"), true);
            case "api-commands/remove_mam_for_user_with_peer":
                return new ServerAdministrationLabels(_("Delete an Account's Archive with One Contact"),
                    _("Permanently delete archived messages between the specified account and contact"), _("Delete archive"), true);
            case "api-commands/delete_expired_pubsub_items":
                return new ServerAdministrationLabels(_("Delete Expired PubSub Items"),
                    _("Permanently remove expired PubSub items"), _("Delete items"), true);
            case "api-commands/delete_old_pubsub_items":
                return new ServerAdministrationLabels(_("Limit Stored PubSub Items"),
                    _("Keep only the specified number of items per node and permanently delete older items"), _("Delete items"), true);
            case "api-commands/delete_old_push_sessions":
                return new ServerAdministrationLabels(_("Delete Old Push Notification Registrations"),
                    _("Remove push notification registrations older than the specified number of days"), _("Delete registrations"), true);
            case "api-commands/delete_mnesia":
                return new ServerAdministrationLabels(_("Delete Domain Data from Mnesia"),
                    _("Permanently delete Mnesia database records for the specified XMPP domain"), _("Delete data"), true);
            case "api-commands/oauth_remove_client":
                return new ServerAdministrationLabels(_("Remove OAuth Client"),
                    _("Remove the specified OAuth client registration"), _("Remove client"), true);
            case "api-commands/oauth_revoke_token":
                return new ServerAdministrationLabels(_("Revoke OAuth Token"),
                    _("Invalidate the specified OAuth authorization token"), _("Revoke token"), true);
            case "api-commands/revoke_certificate":
                return new ServerAdministrationLabels(_("Revoke Server Certificate"),
                    _("Revoke the specified ACME certificate"), _("Revoke certificate"), true);
            case "api-commands/module_uninstall":
                return new ServerAdministrationLabels(_("Uninstall Contributed Module"),
                    _("Remove the selected module and its installed code from the server"), _("Uninstall module"), true);
            case "api-commands/module_install":
                return new ServerAdministrationLabels(_("Install Contributed Module"),
                    _("Compile, install and start the selected module on the server"), _("Install module"), true);
            case "api-commands/module_upgrade":
                return new ServerAdministrationLabels(_("Upgrade Contributed Module"),
                    _("Replace the running code of the selected module"), _("Upgrade module"), true);
            case "api-commands/compile":
                return new ServerAdministrationLabels(_("Compile and Load Server Code"),
                    _("Compile the specified Erlang source file and load its code into the running server"), _("Load code"), true);
            case "api-commands/update":
                return new ServerAdministrationLabels(_("Update Running Server Module"),
                    _("Load the updated code of the specified module"), _("Update module"), true);
            case "api-commands/update_sql":
                return new ServerAdministrationLabels(_("Convert SQL Database to Multiple Domains"),
                    _("Change the SQL database schema from single-domain to multi-domain storage"), _("Convert database"), true);
            case "api-commands/convert_to_scram":
                return new ServerAdministrationLabels(_("Convert Stored Passwords to SCRAM"),
                    _("Convert stored account passwords for the specified domain to SCRAM"), _("Convert passwords"), true);
            case "api-commands/restore":
                return new ServerAdministrationLabels(_("Restore Database Backup"),
                    _("Restore the Mnesia database from the specified binary backup file on the server"), _("Restore backup"), true);
            case "api-commands/load":
                return new ServerAdministrationLabels(_("Restore Database from Text File"),
                    _("Restore the Mnesia database from the specified text dump on the server"), _("Restore database"), true);
            case "api-commands/install_fallback":
                return new ServerAdministrationLabels(_("Install Database Fallback Backup"),
                    _("Install the specified Mnesia backup for recovery when the server next starts"), _("Install backup"), true);
            case "api-commands/import_file":
                return new ServerAdministrationLabels(_("Import jabberd14 User Data from a File"), null, _("Import data"), true);
            case "api-commands/import_dir":
                return new ServerAdministrationLabels(_("Import jabberd14 User Data from a Directory"), null, _("Import data"), true);
            case "api-commands/import_piefxis":
                return new ServerAdministrationLabels(_("Import User Data from PIEFXIS"),
                    _("Import accounts and their data from the specified XEP-0227 file on the server"), _("Import data"), true);
            case "api-commands/import_prosody":
                return new ServerAdministrationLabels(_("Import User Data from Prosody"),
                    _("Import accounts and their data from the specified Prosody data directory on the server"), _("Import data"), true);
            case "api-commands/import_db":
                return new ServerAdministrationLabels(_("Import Database Records for a Domain"),
                    _("Import database records from the specified directory into the chosen domain"), _("Import data"), true);
            case "api-commands/mnesia_table_change_storage":
                return new ServerAdministrationLabels(_("Change Database Table Storage"),
                    _("Change the storage type of the specified Mnesia table"), _("Change storage"), true);
            case "api-commands/mnesia_change_nodename":
                return new ServerAdministrationLabels(_("Change Node Name in a Database Backup"),
                    _("Rewrite the specified node name in a Mnesia backup into a new backup file"), _("Rewrite backup"));
            case "api-commands/set_master":
                return new ServerAdministrationLabels(_("Set Database Master Node"),
                    _("Set the master node for clustered Mnesia tables"), _("Set master node"), true);
            case "api-commands/join_cluster":
                return new ServerAdministrationLabels(_("Join This Node to a Cluster"),
                    _("Join this server node to the cluster managed by the specified node"), _("Join cluster"), true);
            case "api-commands/join_cluster_here":
                return new ServerAdministrationLabels(_("Add a Remote Node to This Cluster"),
                    _("Join the specified remote server node to this cluster"), _("Add node"), true);
            case "api-commands/leave_cluster":
                return new ServerAdministrationLabels(_("Remove and Shut Down a Cluster Node"),
                    _("Remove the specified node from the running cluster and shut it down"), _("Remove node"), true);
            case "api-commands/evacuate_kindly":
                return new ServerAdministrationLabels(_("Disconnect Users and Prevent New Logins"),
                    _("Announce the evacuation, wait for the specified delay, then disconnect users and prevent new logins"), _("Evacuate server"), true);
            case "api-commands/muc_register_nick":
                return new ServerAdministrationLabels(_("Register a Group Chat Nickname"), null, _("Register nickname"));
            case "api-commands/muc_unregister_nick":
                return new ServerAdministrationLabels(_("Unregister a Group Chat Nickname"), null, _("Unregister nickname"));
            case "api-commands/unsubscribe_room":
                return new ServerAdministrationLabels(_("Unsubscribe an Account from a Group Chat"), null, _("Unsubscribe account"));
            case "api-commands/status":
                return new ServerAdministrationLabels(_("View Server Status"),
                    _("Show the server's current status"), _("Show status"));
            case "api-commands/stats":
                return new ServerAdministrationLabels(_("View Server Statistics"),
                    _("Show the server statistics requested in the form"), _("Show statistics"));
            case "api-commands/reload_config": case "http://prosody.im/protocol/config#reload":
                return new ServerAdministrationLabels(_("Reload Server Configuration"),
                    _("Apply the configuration currently stored on the server"), _("Reload configuration"));
            case "http://jabber.org/protocol/admin#restart": case "api-commands/restart":
                return new ServerAdministrationLabels(_("Restart Server"),
                    _("Restart the server; current connections may be interrupted"), _("Restart server"), true);
            case "api-commands/restart_kindly":
                return new ServerAdministrationLabels(_("Restart Server with Announcement"),
                    _("Announce the restart and wait for the chosen delay"), _("Restart server"), true);
            case "api-commands/stop_kindly":
                return new ServerAdministrationLabels(_("Stop Server with Announcement"),
                    _("Announce the shutdown and wait for the chosen delay"), _("Stop server"), true);
            case "api-commands/halt":
                return new ServerAdministrationLabels(_("Stop Server Immediately"),
                    _("Terminate the server process immediately"), _("Stop server"), true);
            case "http://jabber.org/protocol/admin#shutdown": case "api-commands/stop":
                return new ServerAdministrationLabels(_("Stop Server"),
                    _("Stop the server and disconnect its users"), _("Stop server"), true);
            case "api-commands/get_loglevel":
                return new ServerAdministrationLabels(_("View Server Logging Level"), null, _("Show logging level"));
            case "api-commands/set_loglevel":
                return new ServerAdministrationLabels(_("Change Server Logging Level"), null, _("Set logging level"));
            case "api-commands/restart_module":
                return new ServerAdministrationLabels(_("Restart Server Module"),
                    _("Restart the selected server module"), _("Restart module"), true);
            case "api-commands/stop_s2s_connections":
                return new ServerAdministrationLabels(_("Disconnect Server Connections"),
                    _("End connections to other XMPP servers"), _("Disconnect connections"), true);
            case "http://prosody.im/protocol/s2s#list":
                return new ServerAdministrationLabels(_("List Server Connections"),
                    _("Show connections to other XMPP servers"), _("Show connections"));
            case "http://prosody.im/protocol/modules#list":
                return new ServerAdministrationLabels(_("List Server Modules"),
                    _("Show modules currently loaded by the server"), _("Show modules"));
            case "http://prosody.im/protocol/modules#load":
                return new ServerAdministrationLabels(_("Load Server Module"), null, _("Load module"));
            case "http://prosody.im/protocol/modules#global-load":
                return new ServerAdministrationLabels(_("Load Server Module Globally"),
                    _("Load the module for all server hosts"), _("Load module"));
            case "http://prosody.im/protocol/modules#reload":
                return new ServerAdministrationLabels(_("Reload Server Modules"), null, _("Reload modules"));
            case "http://prosody.im/protocol/modules#global-reload":
                return new ServerAdministrationLabels(_("Reload Server Module Globally"),
                    _("Reload the module for all server hosts"), _("Reload module"));
            case "http://prosody.im/protocol/modules#unload":
                return new ServerAdministrationLabels(_("Unload Server Modules"),
                    _("Disable the selected server modules"), _("Unload modules"), true);
            case "http://prosody.im/protocol/modules#global-unload":
                return new ServerAdministrationLabels(_("Unload Server Module Globally"),
                    _("Disable the module for all server hosts"), _("Unload module"), true);
            case "http://prosody.im/protocol/hosts#activate":
                return new ServerAdministrationLabels(_("Activate Server Host"), null, _("Activate host"));
            case "http://prosody.im/protocol/hosts#deactivate":
                return new ServerAdministrationLabels(_("Deactivate Server Host"),
                    _("Disconnect users and disable the selected server host"), _("Deactivate host"), true);
            default:
                return new ServerAdministrationLabels(command.name, null, _("Run command"));
        }
    }

    private static ServerAdministrationLabels for_cluster_command(AdHocCommands.CommandItem command) {
        string[] parts = command.node.split("/");
        string description = _("Cluster node: %s").printf(parts[1]);
        switch (string.joinv("/", parts[2:parts.length])) {
            case "DB":
                return new ServerAdministrationLabels(_("Configure Database Tables"), description, _("Save settings"), true);
            case "backup/backup":
                return new ServerAdministrationLabels(_("Create Database Backup"), description, _("Create backup"));
            case "backup/restore":
                return new ServerAdministrationLabels(_("Restore Database Backup"), description, _("Restore backup"), true);
            case "backup/textfile":
                return new ServerAdministrationLabels(_("Export Database to Text File"), description, _("Export database"));
            case "import/file":
                return new ServerAdministrationLabels(_("Import Data from a File"), description, _("Import data"), true);
            case "import/dir":
                return new ServerAdministrationLabels(_("Import Data from a Directory"), description, _("Import data"), true);
            case "restart":
                return new ServerAdministrationLabels(_("Restart Cluster Node"), description, _("Restart node"), true);
            case "shutdown":
                return new ServerAdministrationLabels(_("Stop Cluster Node"), description, _("Stop node"), true);
            default:
                return new ServerAdministrationLabels(command.name, null, _("Run command"));
        }
    }
}
}
