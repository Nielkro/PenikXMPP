/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gtk;

using Dino.Entities;
using Xmpp.Xep;

namespace Dino.Ui.Util {
    public static GLib.ListStore get_data_form_view_model(DataForms.DataForm data_form,
                                                           Gee.List<string>? jid_multi_choices = null,
                                                           string? command_node = null) {
        var list_store = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));

        foreach (var field in data_form.fields) {
            var field_view_model = Util.get_data_form_field_view_model(
                field, jid_multi_choices, command_node);
            if (field_view_model != null) {
                list_store.append(field_view_model);
            }
        }
        return list_store;
    }

    public static Gtk.Widget get_data_form_result_table(DataForms.DataForm data_form,
                                                        string? command_node = null) {
        var columns = get_result_columns(data_form);
        var rows = new GLib.ListStore(typeof(DataFormResultRow));

        if (!data_form.items.is_empty) {
            foreach (Gee.List<DataForms.DataForm.Field> item in data_form.items) {
                rows.append(new DataFormResultRow(get_result_values(columns, item, command_node)));
            }
        } else if (!data_form.fields.is_empty) {
            if (columns.size == 1) {
                DataForms.DataForm.Field? value_field = find_result_field(columns[0], data_form.fields);
                if (value_field != null && ((!) value_field).get_values().size > 1) {
                    foreach (string value in ((!) value_field).get_values()) {
                        var values = new ArrayList<string>();
                        values.add(get_data_form_result_display_value(
                            (!) value_field, command_node, value, columns[0]));
                        rows.append(new DataFormResultRow(values));
                    }
                } else {
                    rows.append(new DataFormResultRow(get_result_values(columns, data_form.fields, command_node)));
                }
            } else {
                rows.append(new DataFormResultRow(get_result_values(columns, data_form.fields, command_node)));
            }
        }

        var selection = new Gtk.NoSelection(rows);
        var view = new Gtk.ColumnView(selection) {
            hexpand = true,
            vexpand = true,
            show_column_separators = true,
            show_row_separators = true
        };

        for (int i = 0; i < columns.size; i++) {
            int column_index = i;
            var factory = new Gtk.SignalListItemFactory();
            factory.setup.connect((obj) => {
                var list_item = obj as Gtk.ListItem;
                if (list_item == null) return;
                list_item.child = new Gtk.Label(null) {
                    xalign = 0,
                    selectable = true,
                    ellipsize = Pango.EllipsizeMode.END,
                    margin_top = 6,
                    margin_bottom = 6,
                    margin_start = 6,
                    margin_end = 6
                };
            });
            factory.bind.connect((obj) => {
                var list_item = obj as Gtk.ListItem;
                if (list_item == null) return;
                var label = list_item.child as Gtk.Label;
                var row = list_item.get_item() as DataFormResultRow;
                if (label == null || row == null) return;
                string value = column_index < row.values.size ? row.values[column_index] : "";
                label.label = value;
                label.tooltip_text = value;
            });

            DataForms.DataForm.Field field = columns[i];
            string title = get_result_column_title(command_node, field);
            var column = new Gtk.ColumnViewColumn(title, factory) {
                expand = true,
                resizable = true
            };
            view.append_column(column);
        }

        var scroller = new Gtk.ScrolledWindow() {
            hexpand = true,
            vexpand = true,
            propagate_natural_height = true,
            min_content_height = 160
        };
        scroller.set_child(view);
        return scroller;
    }

    private static Gee.List<DataForms.DataForm.Field> get_result_columns(DataForms.DataForm data_form) {
        var columns = new ArrayList<DataForms.DataForm.Field>();
        Gee.List<DataForms.DataForm.Field> candidates;
        if (!data_form.reported_fields.is_empty) {
            candidates = data_form.reported_fields;
        } else if (!data_form.items.is_empty) {
            candidates = data_form.items[0];
        } else {
            candidates = data_form.fields;
        }
        foreach (DataForms.DataForm.Field field in candidates) {
            if (field.type_ == DataForms.DataForm.Type.FIXED ||
                    field.type_ == DataForms.DataForm.Type.HIDDEN || field.var == "FORM_TYPE") {
                continue;
            }
            columns.add(field);
        }
        return columns;
    }

    private static Gee.List<string> get_result_values(Gee.List<DataForms.DataForm.Field> columns,
                                                       Gee.List<DataForms.DataForm.Field> fields,
                                                       string? command_node) {
        var values = new ArrayList<string>();
        for (int i = 0; i < columns.size; i++) {
            DataForms.DataForm.Field? value_field = find_result_field(columns[i], fields, i);
            values.add(value_field != null ? get_data_form_result_display_value(
                (!) value_field, command_node, null, columns[i]) : "");
        }
        return values;
    }

    // Display-only masking: preserve the server's field type and original values
    // so the submitted form still has the exact schema requested by the command.
    public static string get_data_form_result_display_value(DataForms.DataForm.Field field,
            string? command_node = null, string? single_value = null,
            DataForms.DataForm.Field? reported_field = null) {
        if (is_private_data_form_field(field, command_node) ||
                (reported_field != null &&
                    is_private_data_form_field((!) reported_field, command_node))) {
            return _("Hidden");
        }
        return single_value ?? join_multiline_values(field.get_values());
    }

    private static bool is_private_data_form_field(DataForms.DataForm.Field field,
            string? command_node) {
        return field.type_ == DataForms.DataForm.Type.TEXT_PRIVATE ||
            (command_node != null && command_node.has_prefix("api-commands/") &&
                (field.var == "password" || field.var == "newpass"));
    }

    private static DataForms.DataForm.Field? find_result_field(
            DataForms.DataForm.Field column, Gee.List<DataForms.DataForm.Field> fields,
            int fallback_index = 0) {
        if (column.var != null) {
            foreach (DataForms.DataForm.Field field in fields) {
                if (field.var == column.var) return field;
            }
        } else if (fallback_index < fields.size) {
            return fields[fallback_index];
        }
        return null;
    }

    private class DataFormResultRow : Object {
        public Gee.List<string> values { get; private set; }

        public DataFormResultRow(Gee.List<string> values) {
            this.values = values;
        }
    }

public static ViewModel.PreferencesRow.Any? get_data_form_field_view_model(
        DataForms.DataForm.Field field, Gee.List<string>? jid_multi_choices = null,
        string? command_node = null) {
    if (field.type_ == null) return null;

    ViewModel.PreferencesRow.Any? view_model = null;

    string? label = null;
    string? desc = translate_data_form_text(field.description);

    if (field.var != null) {
        if (is_ejabberd_roster_command(command_node)) {
            if (field.var == "localuser" ||
                    (command_node == "api-commands/get_roster" && field.var == "user")) {
                label = _("Roster owner username");
                desc = _("Username of the account whose roster will be managed");
            } else if (field.var == "localhost" ||
                    (command_node == "api-commands/get_roster" && field.var == "host")) {
                label = _("Roster owner server");
                desc = _("Server domain of the account whose roster will be managed");
            } else {
                switch (field.var) {
                    case "user":
                        label = _("Contact username");
                        desc = _("Username of the contact");
                        break;
                    case "host":
                        label = _("Contact server");
                        desc = _("Server domain of the contact");
                        break;
                    case "nick":
                        label = _("Display name");
                        break;
                    case "groups":
                        label = _("Groups");
                        desc = _("One group per line");
                        break;
                    case "subs":
                        label = _("Subscription");
                        desc = _("Presence subscription between the account and contact");
                        break;
                }
            }
        }
        if (is_ejabberd_muc_room_command(command_node)) {
            switch (field.var) {
                case "room":
                    label = _("Room name");
                    desc = _("Name without the group chat service domain");
                    break;
                case "service":
                    label = _("Group chat service");
                    desc = _("Domain of the group chat service");
                    break;
                case "host":
                    label = _("XMPP server");
                    desc = _("Domain of the XMPP server hosting the service");
                    break;
            }
        }
        if (command_node != null && command_node.has_prefix("api-commands/")) {
            switch (field.var) {
                case "password":
                    label = _("Password");
                    break;
                case "newpass":
                    label = _("New Password");
                    break;
                case "user":
                    if (label == null) label = _("Username");
                    break;
                case "host":
                    if (label == null) label = _("XMPP server");
                    break;
            }
        }
        switch (field.var) {
            case "muc#roomconfig_roomname":
                label = _("Display name");
                desc = _("A friendly name shown in room listings (does not change the room address)");
                break;
            case "muc#roomconfig_roomdesc":
                label = _("Description");
                desc = _("A description of the room shown in room listings");
                break;
            case "muc#roomconfig_persistentroom":
                label = _("Persistent");
                desc = _("The room will persist after the last occupant leaves");
                break;
            case "muc#roomconfig_publicroom":
                label = _("Publicly searchable");
                desc = _("The room will appear in public room listings");
                break;
            case "muc#roomconfig_changesubject":
                label = _("Occupants may change the subject");
                break;
            case "muc#roomconfig_whois":
                label = _("Permission to view JIDs");
                desc = _("Who is allowed to view the occupants' JIDs?");
                break;
            case "muc#roomconfig_roomsecret":
                label = _("Password");
//                desc = _("A password to restrict access to the room");
                break;
            case "muc#roomconfig_moderatedroom":
                label = _("Moderated");
                desc = _("Only occupants with voice may send messages");
                break;
            case "muc#roomconfig_membersonly":
                label = _("Members only");
                desc = _("Only members may enter. When enabled, DinoX grants membership to all currently visible occupants so they remain in the room.");
                break;
            case "muc#roomconfig_allowinvites":
                label = _("Allow additional room invitations");
                desc = _("Controls mediated invitations through the room. Owners and admins remain allowed. XEP-0045 normally grants moderators this privilege too, but the room server decides which additional occupants may invite. Direct invitations are not controlled here.");
                break;
            case "muc#roomconfig_enablelogging":
                label = _("Logging");
                desc = _("Log conversation history");
                break;
            case "muc#roomconfig_lang":
                label = _("Language");
                break;
            case "muc#roomconfig_passwordprotectedroom":
                label = _("Password protected");
                break;
            case "muc#roomconfig_maxusers":
                label = _("Maximum participants");
                break;
            case "muc#roomconfig_presencebroadcast":
                label = _("Broadcast presence for roles");
                desc = _("The room broadcasts presence only for the selected roles. This hides whole occupants, not just role labels. Existing lists update when the room sends presence; a real leave and rejoin rebuilds the roster.");
                break;
            case "muc#roomconfig_getmemberlist":
                label = _("Who may view the member list");
                break;
            case "muc#roomconfig_allow_query_users":
                label = _("Allow occupant IQ queries");
                desc = _("Allow XMPP IQ queries such as vCard, profile and avatar retrieval, time, or software version between room occupants. This is not member search or JID visibility.");
                break;
            case "muc#roomconfig_enable_hats":
                label = _("Enable hats");
                desc = _("Enable room support for hats. This does not create or assign hats. Assigned hats update when the room broadcasts refreshed occupant presence.");
                break;
            case "muc#roomconfig_voice_request_min_interval":
                label = _("Voice request interval");
                desc = _("Minimum time between voice requests in seconds. The server rejects repeated requests inside this interval.");
                break;
            case "muc#roomconfig_captcha_whitelist":
                label = _("CAPTCHA whitelist");
                desc = _("JIDs that may enter without solving a CAPTCHA, one per line");
                break;
            case "muc#roomconfig_historylength":
                label = _("Message history");
                desc = _("Maximum number of recent messages sent to a user when joining");
                break;
        }
    }

    if (label == null) label = translate_data_form_text(field.label);
    if (field.required && label != null && label != "") label = label + " *";

    switch (field.type_) {
        case DataForms.DataForm.Type.FIXED:
            var fixed_field = field as DataForms.DataForm.FixedField;
            string? fixed_text = translate_data_form_text(fixed_field.value);
            if (fixed_text == null || fixed_text == "") fixed_text = label ?? "";
            var fixed_model = new ViewModel.PreferencesRow.Text() { text = (!) fixed_text };
            view_model = fixed_model;
            break;
        case DataForms.DataForm.Type.BOOLEAN:
            DataForms.DataForm.BooleanField boolean_field = field as DataForms.DataForm.BooleanField;
            var toggle_model = new ViewModel.PreferencesRow.Toggle() { subtitle = desc, state = boolean_field.value };
            boolean_field.bind_property("value", toggle_model, "state", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            view_model = toggle_model;
            break;
        case DataForms.DataForm.Type.JID_MULTI:
            DataForms.DataForm.JidMultiField jid_multi_field = field as DataForms.DataForm.JidMultiField;
            if (jid_multi_choices != null) {
                var choice_model = new ViewModel.PreferencesRow.MultiCheck();
                var selected_values = new HashSet<string>();
                selected_values.add_all(jid_multi_field.value);
                foreach (string choice in (!) jid_multi_choices) {
                    choice_model.items.add(choice);
                    choice_model.states.add(selected_values.contains(choice));
                }
                choice_model.state_changed.connect((index, state) => {
                    var values = new ArrayList<string>();
                    for (int i = 0; i < choice_model.items.size; i++) {
                        if (choice_model.states[i]) values.add(choice_model.items[i]);
                    }
                    jid_multi_field.value = values;
                });
                view_model = choice_model;
            } else {
                var jid_multi_model = new ViewModel.PreferencesRow.MultiText() { text = join_multiline_values(jid_multi_field.value) };
                jid_multi_model.changed.connect(() => {
                    jid_multi_field.value = split_jid_multiline_values(
                        jid_multi_model.text);
                });
                view_model = jid_multi_model;
            }
            break;
        case DataForms.DataForm.Type.LIST_SINGLE:
            DataForms.DataForm.ListSingleField list_single_field = field as DataForms.DataForm.ListSingleField;
            var combobox_model = new ViewModel.PreferencesRow.ComboBox();
            for (int i = 0; i < list_single_field.options.size; i++) {
                DataForms.DataForm.Option option = list_single_field.options[i];
                combobox_model.items.add(get_data_form_option_label(field.var, option));
                if (option.value == list_single_field.value) combobox_model.active_item = i;
            }
            combobox_model.bind_property("active-item", list_single_field, "value", BindingFlags.DEFAULT, (binding, from, ref to) => {
                var active_item = (int) from;
                if (active_item < 0 ||
                        active_item >= list_single_field.options.size) {
                    return false;
                }
                to = list_single_field.options[active_item].value;
                return true;
            });
            view_model = combobox_model;
            break;
        case DataForms.DataForm.Type.LIST_MULTI:
            DataForms.DataForm.ListMultiField list_multi_field = field as DataForms.DataForm.ListMultiField;
            var multi_check_model = new ViewModel.PreferencesRow.MultiCheck() {
                subtitle = desc
            };
            var selected_values = new HashSet<string>();
            selected_values.add_all(list_multi_field.value);
            foreach (DataForms.DataForm.Option option in list_multi_field.options) {
                multi_check_model.items.add(get_data_form_option_label(field.var, option));
                multi_check_model.states.add(selected_values.contains(option.value));
            }
            multi_check_model.state_changed.connect((index, state) => {
                var values = new ArrayList<string>();
                for (int i = 0; i < list_multi_field.options.size; i++) {
                    if (multi_check_model.states[i]) {
                        values.add(list_multi_field.options[i].value);
                    }
                }
                list_multi_field.value = values;
            });
            view_model = multi_check_model;
            break;
        case DataForms.DataForm.Type.TEXT_MULTI:
            DataForms.DataForm.TextMultiField text_multi_field = field as DataForms.DataForm.TextMultiField;
            var text_multi_model = new ViewModel.PreferencesRow.MultiText() { text = join_multiline_values(text_multi_field.value) };
            text_multi_model.changed.connect(() => {
                text_multi_field.value = split_text_multiline_values(
                    text_multi_model.text);
            });
            view_model = text_multi_model;
            break;
        case DataForms.DataForm.Type.TEXT_PRIVATE:
            DataForms.DataForm.TextPrivateField text_private_field = field as DataForms.DataForm.TextPrivateField;
            var private_entry_model = new ViewModel.PreferencesRow.PrivateText() { text = text_private_field.value };
            text_private_field.bind_property("value", private_entry_model, "text", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            view_model = private_entry_model;
            break;
        case DataForms.DataForm.Type.TEXT_SINGLE:
            DataForms.DataForm.TextSingleField text_single_field = field as DataForms.DataForm.TextSingleField;
            if (is_private_data_form_field(field, command_node)) {
                var api_password_model = new ViewModel.PreferencesRow.PrivateText() { text = text_single_field.value };
                text_single_field.bind_property("value", api_password_model, "text", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
                view_model = api_password_model;
                break;
            }
            if (command_node == "api-commands/add_rosteritem" && field.var == "subs") {
                var subscription_model = new ViewModel.PreferencesRow.ComboBox();
                string[] subscription_values = { "none", "from", "to", "both" };
                subscription_model.items.add(_("No subscription"));
                subscription_model.items.add(_("Contact can see account presence"));
                subscription_model.items.add(_("Account can see contact presence"));
                subscription_model.items.add(_("Mutual subscription"));
                subscription_model.active_item = 0;
                for (int i = 0; i < subscription_values.length; i++) {
                    if (text_single_field.value == subscription_values[i]) {
                        subscription_model.active_item = i;
                        break;
                    }
                }
                subscription_model.notify["active-item"].connect(() => {
                    int active_item = subscription_model.active_item;
                    if (active_item >= 0 && active_item < subscription_values.length) {
                        text_single_field.value = subscription_values[active_item];
                    }
                });
                text_single_field.value = subscription_values[subscription_model.active_item];
                view_model = subscription_model;
                break;
            }
            var entry_model = new ViewModel.PreferencesRow.Entry() { text = text_single_field.value };
            text_single_field.bind_property("value", entry_model, "text", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            view_model = entry_model;
            break;
        default:
            return null;
    }

    var media_node = field.node.get_subnode("media", "urn:xmpp:media-element");
    if (media_node != null) {
        view_model.media_type = media_node.get_attribute("type", "urn:xmpp:media-element");
        view_model.media_uri = media_node.get_deep_string_content("uri");
    }

    view_model.title = label;
    view_model.description = desc;
    return view_model;
}

private static bool is_ejabberd_roster_command(string? command_node) {
    return command_node == "api-commands/add_rosteritem" ||
        command_node == "api-commands/delete_rosteritem" ||
        command_node == "api-commands/get_roster";
}

private static bool is_ejabberd_muc_room_command(string? command_node) {
    return command_node == "api-commands/muc_online_rooms" ||
        command_node == "api-commands/create_room" ||
        command_node == "api-commands/destroy_room";
}

private static string get_result_column_title(string? command_node,
                                               DataForms.DataForm.Field field) {
    if (command_node == "api-commands/muc_online_rooms" && field.var == "rooms") {
        return _("Group chat address");
    }
    if (command_node == "api-commands/get_roster" && field.var == "contacts") {
        return _("Contact");
    }
    return translate_data_form_text(field.label) ?? field.var ?? "";
}

private static string join_multiline_values(Gee.List<string> values) {
    var builder = new StringBuilder();
    bool first = true;
    foreach (string value in values) {
        if (!first) builder.append_c('\n');
        builder.append(value);
        first = false;
    }
    return builder.str;
}

private static Gee.List<string> split_jid_multiline_values(string? text) {
    var values = new ArrayList<string>();
    if (text == null || text == "") return values;
    foreach (string line in text.split("\n")) {
        string value = line.strip();
        if (value != "") values.add(value);
    }
    return values;
}

private static Gee.List<string> split_text_multiline_values(string? text) {
    var values = new ArrayList<string>();
    if (text == null) return values;
    // XEP-0004 text-multi values are ordered text lines. Preserve whitespace
    // and empty leading/trailing/intermediate lines exactly as entered.
    foreach (string line in text.split("\n")) values.add(line);
    return values;
}

private static string get_data_form_option_label(string? field_var, DataForms.DataForm.Option option) {
    switch (option.value) {
        case "anyone":
            return _("Anyone");
        case "moderator":
            return _("Moderator");
        case "moderators":
            return _("Moderators");
        case "participant":
            return _("Participant");
        case "participants":
            return _("Participants");
        case "visitor":
            return _("Visitor");
        case "visitors":
            return _("Visitors");
        case "none":
            return _("Nobody");
        case "owner":
            return _("Owner");
        case "owners":
            return _("Owners");
        case "admin":
            return _("Admin");
        case "admins":
            return _("Admins");
        case "member":
            return _("Member");
        case "members":
            return _("Members");
        case "outcast":
            return _("Banned user");
        case "outcasts":
            return _("Banned users");
    }
    if (option.label != null && option.label != "") return translate_data_form_text(option.label);
    return option.value;
}

private static string? translate_data_form_text(string? text) {
    if (text == null || text == "") return text;
    switch (text) {
        case "Room title":
            return _("Display name");
        case "Username":
            return _("Username");
        case "Nickname":
            return _("Nickname");
        case "Password":
            return _("Password");
        case "Name":
            return _("Name");
        case "Email":
            return _("Email");
        case "Address":
            return _("Address");
        case "City":
            return _("City");
        case "Phone":
            return _("Phone");
        case "URL":
            return _("URL");
        case "Room description":
            return _("Description");
        case "Make room persistent":
            return _("Persistent room");
        case "Make room public searchable":
            return _("Publicly searchable");
        case "Make participants list public":
        case "Make participant list public":
        case "Show participant List public":
        case "Show participant list public":
            return _("Show participant list publicly");
        case "Make room password protected":
            return _("Password protected");
        case "Maximum Number of Occupants":
        case "Maximum Participants":
        case "Maximum number of occupants":
        case "Maximum number of users":
        case "Maximum users":
            return _("Maximum participants");
        case "Present real JIDs to":
        case "Who May Discover Real JIDs?":
            return _("Show real JIDs to");
        case "Roles for which Presence is Broadcasted":
        case "Visible Roles":
        case "Roles for which presence is broadcast":
        case "Roles for which presence is broadcasted":
            return _("Broadcast presence for roles");
        case "Roles and Affiliations that May Retrieve Member List":
        case "Roles and affiliations that may retrieve member list":
            return _("Who may view the member list");
        case "Make room members-only":
            return _("Members only");
        case "Make room moderated":
            return _("Moderated");
        case "Default users as participants":
        case "New users are participants by default":
            return _("New users are participants by default");
        case "Default users as visitors":
        case "New users are visitors by default":
            return _("New users are visitors by default");
        case "Allow users to change the subject":
        case "Allow users to change subject":
            return _("Occupants may change the subject");
        case "Allow users to invite others":
            return _("Allow additional room invitations");
        case "Allow users to send private messages":
        case "Roles that May Send Private Messages":
        case "Roles that May Send Private Messages to":
            return _("Allow private messages");
        case "Allow visitors to send private messages to":
            return _("Allow visitors to send private messages to");
        case "Allow users to query other users":
        case "Allow user Lookup":
        case "Allow user lookup":
            return _("Allow occupant IQ queries");
        case "Allow visitors to send messages":
            return _("Visitors may send messages");
        case "Allow visitors to send status text in presence updates":
        case "Visitors may send status text":
            return _("Visitors may send status text");
        case "Allow visitors to change nickname":
        case "Visitors may change their nickname":
            return _("Visitors may change their nickname");
        case "Allow visitors to send voice requests":
        case "Visitors may request voice":
            return _("Visitors may request voice");
        case "Minimum interval between voice requests (in seconds)":
        case "Minimum interval between voice requests, in seconds":
        case "Voice request interval":
            return _("Voice request interval");
        case "Allow subscription":
        case "Allow subscriptions":
        case "Allow subscription?":
            return _("Allow subscriptions");
        case "XMPP URI of Associated Publish-Subscribe Node":
        case "Xmpp uri of Associated Publish-Subscribe Node":
            return _("Associated publish-subscribe node");
        case "Enable hats":
        case "Enable Hats":
            return _("Enable hats");
        case "Enable message archiving":
        case "Enable messages archiving":
            return _("Enable message archiving");
        case "Enable logging":
            return _("Logging");
        case "Maximum amount of history messages returned by room":
        case "Maximum amount of history messages returned by the room":
        case "Maximum number of history messages returned by room":
            return _("Message history");
        case "Room CAPTCHA whitelist":
            return _("CAPTCHA whitelist");
        case "Room admins":
            return _("Admins");
        case "Room owners":
            return _("Owners");
        case "Hat Title":
            return _("Hat title");
        case "Hat URI":
        case "Unique URI":
            return _("Hat URI");
        case "Hat Hue":
        case "Custom color":
            return _("Hat color");
        case "User Address":
        case "JID to which a hat is assigned":
            return _("User address");
        case "The role":
            return _("Hat");
        case "Moderator":
            return _("Moderator");
        case "Participant":
            return _("Participant");
        case "Visitor":
            return _("Visitor");
        case "Owner":
            return _("Owner");
        case "Admin":
            return _("Admin");
        case "Member":
            return _("Member");
        case "Outcast":
            return _("Banned user");
    }
    return text;
}
}
