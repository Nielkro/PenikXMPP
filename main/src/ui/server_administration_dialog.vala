/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
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

namespace Dino.Ui {

public class ServerAdministrationDialog : Adw.Dialog {
    private const int INITIAL_COMMAND_ROW_COUNT = 8;
    private const int64 COMMAND_ROW_WORK_BUDGET_US = 2500;
    private const uint COMMAND_ROW_SLICE_DELAY_MS = 1;

    private ServerAdministrationManager administration_manager;
    private Adw.PreferencesGroup account_group;
    private Adw.ComboRow account_row;
    private Adw.PreferencesGroup accounts_commands_group;
    private Adw.PreferencesGroup roster_commands_group;
    private Adw.PreferencesGroup muc_commands_group;
    private Adw.PreferencesGroup server_commands_group;
    private Adw.PreferencesGroup other_commands_group;
    private Adw.ExpanderRow other_commands_expander;
    private ArrayList<Account> admin_accounts = new ArrayList<Account>();
    private ArrayList<Gtk.Widget> accounts_command_rows = new ArrayList<Gtk.Widget>();
    private ArrayList<Gtk.Widget> roster_command_rows = new ArrayList<Gtk.Widget>();
    private ArrayList<Gtk.Widget> muc_command_rows = new ArrayList<Gtk.Widget>();
    private ArrayList<Gtk.Widget> server_command_rows = new ArrayList<Gtk.Widget>();
    private ArrayList<Gtk.Widget> other_command_rows = new ArrayList<Gtk.Widget>();
    private ArrayList<AdHocCommands.CommandItem> pending_command_items = new ArrayList<AdHocCommands.CommandItem>();
    private ArrayList<AdHocCommands.CommandItem> pending_other_command_items = new ArrayList<AdHocCommands.CommandItem>();
    private Gee.Map<AdHocCommands.CommandItem, string> command_list_titles =
        new HashMap<AdHocCommands.CommandItem, string>();
    private ServerAdministrationCommandDialog? active_command_dialog = null;
    private ulong commands_changed_handler = 0;
    private Account? population_account = null;
    private uint population_source_id = 0;
    private uint population_generation = 0;
    private int pending_command_offset = 0;
    private int pending_other_command_offset = 0;
    private int64 population_started_us = 0;
    private int population_total_count = 0;
    private bool rebuilding = false;
    private bool dialog_closed = false;

    public ServerAdministrationDialog(ServerAdministrationManager administration_manager) {
        bool timing = UiTiming.enabled();
        int64 constructor_started_us = timing ? UiTiming.now_us() : 0;
        this.administration_manager = administration_manager;
        this.title = _("Server Administration");
        this.content_width = 700;
        this.content_height = 540;
        this.follows_content_size = false;

        var toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar();
        var refresh_button = new Gtk.Button.from_icon_name("view-refresh-symbolic") {
            tooltip_text = _("Refresh commands")
        };
        refresh_button.clicked.connect(() => {
            Account? account = get_selected_account();
            if (account != null) administration_manager.refresh((!) account);
        });
        header_bar.pack_end(refresh_button);
        toolbar_view.add_top_bar(header_bar);

        var page = new Adw.PreferencesPage();
        page.margin_top = 12;
        page.margin_bottom = 12;
        page.margin_start = 12;
        page.margin_end = 12;

        account_group = new Adw.PreferencesGroup() { title = _("Administrative Account") };
        account_row = new Adw.ComboRow() { title = _("Account") };
        account_group.add(account_row);
        page.add(account_group);

        accounts_commands_group = new Adw.PreferencesGroup() { title = _("User Accounts") };
        roster_commands_group = new Adw.PreferencesGroup() { title = _("Rosters") };
        muc_commands_group = new Adw.PreferencesGroup() { title = _("Group Chats") };
        server_commands_group = new Adw.PreferencesGroup() { title = _("Server") };
        other_commands_group = new Adw.PreferencesGroup();
        other_commands_expander = new Adw.ExpanderRow() {
            title = _("Other Commands"),
            expanded = false
        };
        other_commands_group.add(other_commands_expander);
        page.add(accounts_commands_group);
        page.add(roster_commands_group);
        page.add(muc_commands_group);
        page.add(server_commands_group);
        page.add(other_commands_group);

        toolbar_view.content = page;
        this.child = toolbar_view;

        account_row.notify["selected"].connect(() => {
            if (!rebuilding) rebuild_commands();
        });
        other_commands_expander.notify["expanded"].connect(() => {
            if (other_commands_expander.expanded) {
                if (UiTiming.enabled() && pending_command_offset >= pending_command_items.size &&
                        pending_other_command_offset == 0) {
                    population_started_us = UiTiming.now_us();
                }
                schedule_command_population();
            }
        });
        commands_changed_handler = administration_manager.commands_changed.connect((account) => rebuild_accounts());
        this.closed.connect(disconnect_manager);

        rebuild_accounts();
        if (timing) UiTiming.log_ms("ServerAdministrationDialog.constructor", constructor_started_us);
    }

    private void disconnect_manager() {
        dialog_closed = true;
        cancel_command_population();
        if (active_command_dialog != null) {
            ((!) active_command_dialog).close();
        }
        if (commands_changed_handler != 0) {
            administration_manager.disconnect(commands_changed_handler);
            commands_changed_handler = 0;
        }
    }

    private Account? get_selected_account() {
        uint selected = account_row.selected;
        if (selected >= admin_accounts.size) return null;
        return admin_accounts[(int) selected];
    }

    private void rebuild_accounts() {
        bool timing = UiTiming.enabled();
        int64 rebuild_started_us = timing ? UiTiming.now_us() : 0;
        string? selected_jid = null;
        Account? selected_account = get_selected_account();
        if (selected_account != null) {
            selected_jid = ((!) selected_account).bare_jid.to_string();
        }

        rebuilding = true;
        admin_accounts.clear();
        admin_accounts.add_all(administration_manager.get_admin_accounts());
        admin_accounts.sort((a, b) => a.bare_jid.to_string().collate(b.bare_jid.to_string()));

        if (admin_accounts.is_empty) {
            rebuilding = false;
            close();
            return;
        }

        var account_model = new Gtk.StringList(null);
        uint selected_index = 0;
        for (int i = 0; i < admin_accounts.size; i++) {
            string jid = admin_accounts[i].bare_jid.to_string();
            account_model.append(jid);
            if (selected_jid == jid) selected_index = (uint) i;
        }
        account_row.model = account_model;
        account_row.selected = selected_index;
        account_group.visible = true;
        account_row.sensitive = admin_accounts.size > 1;
        rebuilding = false;

        rebuild_commands();
        if (timing) {
            UiTiming.log_ms("ServerAdministrationDialog.rebuild_accounts: accounts=%d".printf(admin_accounts.size), rebuild_started_us);
        }
    }

    private void rebuild_commands() {
        bool timing = UiTiming.enabled();
        int64 rebuild_started_us = timing ? UiTiming.now_us() : 0;
        cancel_command_population();
        clear_command_rows(accounts_commands_group, accounts_command_rows);
        clear_command_rows(roster_commands_group, roster_command_rows);
        clear_command_rows(muc_commands_group, muc_command_rows);
        clear_command_rows(server_commands_group, server_command_rows);
        foreach (Gtk.Widget row in other_command_rows) other_commands_expander.remove(row);
        other_command_rows.clear();
        other_commands_expander.expanded = false;

        Account? account = get_selected_account();
        if (account == null) return;

        var commands = new ArrayList<AdHocCommands.CommandItem>();
        commands.add_all(administration_manager.get_commands((!) account));
        command_list_titles = Util.ServerAdministrationLabels.list_titles(commands);
        var server_commands = new ArrayList<AdHocCommands.CommandItem>();
        foreach (AdHocCommands.CommandItem command in commands) {
            if (command.jid.equals(((!) account).bare_jid.domain_jid)) server_commands.add(command);
        }
        account_group.description = Util.ServerAdministrationLabels.available_interfaces(server_commands);
        commands.sort((a, b) => {
            int category_order = get_command_category_order(a) - get_command_category_order(b);
            if (category_order != 0) return category_order;
            int name_order = command_list_titles[a].collate(command_list_titles[b]);
            return name_order != 0 ? name_order : a.node.collate(b.node);
        });

        bool has_accounts_commands = false;
        bool has_roster_commands = false;
        bool has_muc_commands = false;
        bool has_server_commands = false;
        foreach (AdHocCommands.CommandItem command in commands) {
            switch (ServerAdministrationManager.get_command_category(command)) {
                case ServerAdministrationCommandCategory.ACCOUNTS:
                    has_accounts_commands = true;
                    pending_command_items.add(command);
                    break;
                case ServerAdministrationCommandCategory.ROSTER:
                    has_roster_commands = true;
                    pending_command_items.add(command);
                    break;
                case ServerAdministrationCommandCategory.MUC:
                    has_muc_commands = true;
                    pending_command_items.add(command);
                    break;
                case ServerAdministrationCommandCategory.SERVER:
                    has_server_commands = true;
                    pending_command_items.add(command);
                    break;
                default:
                    pending_other_command_items.add(command);
                    break;
            }
        }

        population_account = account;
        population_total_count = commands.size;
        population_started_us = timing ? UiTiming.now_us() : 0;

        accounts_commands_group.visible = has_accounts_commands;
        roster_commands_group.visible = has_roster_commands;
        muc_commands_group.visible = has_muc_commands;
        server_commands_group.visible = has_server_commands;
        other_commands_group.visible = !pending_other_command_items.is_empty;

        int initial_rows = populate_command_rows(INITIAL_COMMAND_ROW_COUNT, 0);
        schedule_command_population();
        if (timing) {
            UiTiming.log_ms("ServerAdministrationDialog.rebuild_commands: commands=%d initial_rows=%d deferred_other=%d".printf(
                commands.size, initial_rows, pending_other_command_items.size), rebuild_started_us);
        }
    }

    private static int get_command_category_order(AdHocCommands.CommandItem command) {
        switch (ServerAdministrationManager.get_command_category(command)) {
            case ServerAdministrationCommandCategory.ACCOUNTS: return 0;
            case ServerAdministrationCommandCategory.ROSTER: return 1;
            case ServerAdministrationCommandCategory.MUC: return 2;
            case ServerAdministrationCommandCategory.SERVER: return 3;
            default: return 4;
        }
    }

    private int populate_command_rows(int maximum_rows, int64 work_budget_us) {
        Account? account = population_account;
        if (account == null || dialog_closed) return 0;

        int added = 0;
        int64 deadline_us = work_budget_us > 0 ? UiTiming.now_us() + work_budget_us : int64.MAX;
        while (pending_command_offset < pending_command_items.size &&
                added < maximum_rows && UiTiming.now_us() < deadline_us) {
            add_command_item_row((!) account, pending_command_items[pending_command_offset]);
            pending_command_offset++;
            added++;
        }
        while (other_commands_expander.expanded &&
                pending_command_offset >= pending_command_items.size &&
                pending_other_command_offset < pending_other_command_items.size &&
                added < maximum_rows && UiTiming.now_us() < deadline_us) {
            add_command_item_row((!) account, pending_other_command_items[pending_other_command_offset]);
            pending_other_command_offset++;
            added++;
        }
        return added;
    }

    private void add_command_item_row(Account account, AdHocCommands.CommandItem command) {
        AdHocCommands.CommandItem command_item = command;
        var labels = Util.ServerAdministrationLabels.for_command(command);
        var row = new Adw.ActionRow() {
            use_markup = false,
            title = command_list_titles[command] ?? labels.title,
            subtitle = Util.ServerAdministrationLabels.list_subtitle(command),
            subtitle_lines = 2,
            title_selectable = true,
            activatable = true
        };
        row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        row.activated.connect(() => open_command(account, command_item));
        add_command_row(ServerAdministrationManager.get_command_category(command), row);
    }

    private bool has_pending_visible_commands() {
        if (pending_command_offset < pending_command_items.size) return true;
        return other_commands_expander.expanded &&
            pending_other_command_offset < pending_other_command_items.size;
    }

    private void schedule_command_population() {
        if (dialog_closed || population_source_id != 0 || !has_pending_visible_commands()) return;

        uint scheduled_generation = population_generation;
        population_source_id = Timeout.add_full(command_population_priority(), COMMAND_ROW_SLICE_DELAY_MS, () => {
            population_source_id = 0;
            if (dialog_closed || scheduled_generation != population_generation) return Source.REMOVE;

            int64 slice_started_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
            int added = populate_command_rows(int.MAX, COMMAND_ROW_WORK_BUDGET_US);
            if (UiTiming.enabled()) {
                UiTiming.log_ms("ServerAdministrationDialog.populate_slice: rows=%d core=%d/%d other=%d/%d".printf(
                    added, pending_command_offset, pending_command_items.size,
                    pending_other_command_offset, pending_other_command_items.size), slice_started_us);
            }
            if (has_pending_visible_commands()) {
                schedule_command_population();
            } else if (UiTiming.enabled()) {
                int populated = pending_command_offset + pending_other_command_offset;
                string readiness = pending_other_command_offset < pending_other_command_items.size ?
                    "visible_rows_ready" : "all_rows_ready";
                UiTiming.log_ms("ServerAdministrationDialog.%s: rows=%d/%d".printf(
                    readiness, populated, population_total_count), population_started_us);
            }
            return Source.REMOVE;
        });
    }

    private void cancel_command_population() {
        population_generation++;
        if (population_source_id != 0) {
            Source.remove(population_source_id);
            population_source_id = 0;
        }
        pending_command_items.clear();
        pending_other_command_items.clear();
        command_list_titles.clear();
        pending_command_offset = 0;
        pending_other_command_offset = 0;
        population_account = null;
    }

    private int command_population_priority() {
#if WINDOWS
        // LOW/DEFAULT_IDLE sources can be starved for seconds by startup
        // presence processing on Windows. Each slice still has a strict budget.
        return GLib.Priority.DEFAULT;
#else
        return GLib.Priority.DEFAULT_IDLE;
#endif
    }

    private void clear_command_rows(Adw.PreferencesGroup group, ArrayList<Gtk.Widget> rows) {
        foreach (Gtk.Widget row in rows) group.remove(row);
        rows.clear();
    }

    private void add_command_row(ServerAdministrationCommandCategory category, Gtk.Widget row) {
        switch (category) {
            case ServerAdministrationCommandCategory.ACCOUNTS:
                accounts_commands_group.add(row);
                accounts_command_rows.add(row);
                break;
            case ServerAdministrationCommandCategory.ROSTER:
                roster_commands_group.add(row);
                roster_command_rows.add(row);
                break;
            case ServerAdministrationCommandCategory.MUC:
                muc_commands_group.add(row);
                muc_command_rows.add(row);
                break;
            case ServerAdministrationCommandCategory.SERVER:
                server_commands_group.add(row);
                server_command_rows.add(row);
                break;
            default:
                other_commands_expander.add_row(row);
                other_command_rows.add(row);
                break;
        }
    }

    private void open_command(Account account, AdHocCommands.CommandItem command) {
        if (active_command_dialog != null) {
            ((!) active_command_dialog).present(this);
            return;
        }

        ServerAdministrationCommandSession? session = administration_manager.create_session(account, command);
        if (session == null) {
            rebuild_accounts();
            return;
        }

        var dialog = new ServerAdministrationCommandDialog(administration_manager, (!) session);
        active_command_dialog = dialog;
        dialog.closed.connect(() => {
            if (active_command_dialog == dialog) active_command_dialog = null;
        });
#if WINDOWS
        dialog.presentation_mode = Adw.DialogPresentationMode.FLOATING;
#endif
        dialog.present(this);
    }
}

private class ServerAdministrationCommandDialog : Adw.Dialog {
    private ServerAdministrationManager administration_manager;
    private ServerAdministrationCommandSession session;
    private Adw.ToolbarView toolbar_view;
    private Gtk.Button previous_button;
    private Gtk.Button primary_button;
    private Gtk.Spinner spinner;
    private string primary_action = "";
    private bool operation_in_progress = false;
    private bool dialog_closed = false;
    private bool cancel_started = false;
    private Gee.List<string>? jid_multi_choices = null;
    private string? user_list_warning = null;
    private Util.ServerAdministrationLabels labels;

    public ServerAdministrationCommandDialog(ServerAdministrationManager administration_manager,
                                             ServerAdministrationCommandSession session) {
        this.administration_manager = administration_manager;
        this.session = session;
        labels = Util.ServerAdministrationLabels.for_command(session.command_item);
        this.title = labels.title;
        this.content_width = 620;
        this.content_height = 540;
        this.follows_content_size = false;

        toolbar_view = new Adw.ToolbarView();
        var header_bar = new Adw.HeaderBar();
        string? command_source = Util.ServerAdministrationLabels.source_name(session.command_item);
        string account_title = session.account.bare_jid.to_string();
        if (command_source != null) account_title = "%s · %s".printf(account_title, (!) command_source);
        header_bar.title_widget = new Adw.WindowTitle(this.title, account_title);

        previous_button = new Gtk.Button.with_label(_("Previous"));
        previous_button.visible = false;
        previous_button.clicked.connect(() => proceed.begin("prev"));
        header_bar.pack_start(previous_button);

        primary_button = new Gtk.Button();
        primary_button.add_css_class("suggested-action");
        primary_button.visible = false;
        primary_button.clicked.connect(on_primary_button_clicked);
        header_bar.pack_end(primary_button);

        spinner = new Gtk.Spinner();
        spinner.visible = false;
        header_bar.pack_end(spinner);

        toolbar_view.add_top_bar(header_bar);
        this.child = toolbar_view;
        this.closed.connect(on_closed);

        if (Util.ServerAdministrationLabels.executes_immediately(session.command_item)) {
            show_initial_action();
        } else {
            show_loading();
            execute.begin();
        }
    }

    private void show_initial_action() {
        var page = create_page();
        var group = new Adw.PreferencesGroup();
        group.add(new Adw.ActionRow() {
            use_markup = false,
            title = labels.description ?? labels.title,
            subtitle = _("Server: %s").printf(session.command_item.jid.to_string()),
            title_lines = 0
        });
        page.add(group);
        toolbar_view.content = page;
        primary_action = "execute";
        primary_button.label = labels.submit_label;
        primary_button.visible = true;
    }

    private async void execute() {
        if (operation_in_progress || dialog_closed) return;
        set_busy(true);
        bool success = yield session.execute();

        if (dialog_closed) {
            set_busy(false);
            cancel_after_close();
            return;
        }
        if (success) {
            yield load_jid_multi_choices();
        }
        set_busy(false);
        if (dialog_closed) {
            cancel_after_close();
            return;
        }
        render_command(success ? null : command_error_message());
    }

    private async void load_jid_multi_choices() {
        string? source_node = get_user_list_source_node();
        if (source_node == null) return;

        AdHocCommands.CommandItem? source_command = Util.ServerAdministrationLabels.find_command_at_target(
            administration_manager.get_commands(session.account), (!) source_node, session.command_item.jid);
        if (source_command == null) {
            user_list_warning = _("The user list could not be loaded. Enter addresses manually.");
            return;
        }

        ServerAdministrationCommandSession? source_session = administration_manager.create_session(
            session.account, (!) source_command);
        if (source_session == null || !yield ((!) source_session).execute()) {
            user_list_warning = _("The user list could not be loaded. Enter addresses manually.");
            return;
        }

        var choices = new ArrayList<string>();
        var seen = new HashSet<string>();
        AdHocCommands.Command? result = ((!) source_session).command;
        if (result != null && ((!) result).form != null) {
            foreach (DataForms.DataForm.Field field in ((!) ((!) result).form).fields) {
                foreach (string value in field.get_values()) {
                    string jid = value.strip();
                    if (jid != "" && seen.add(jid)) choices.add(jid);
                }
            }
        }
        choices.sort((a, b) => a.collate(b));

        if (result != null && ((!) result).status == AdHocCommands.Command.Status.EXECUTING) {
            yield ((!) source_session).cancel();
        }
        if (choices.is_empty) {
            user_list_warning = _("The user list could not be loaded. Enter addresses manually.");
            return;
        }
        jid_multi_choices = choices;
    }

    private string? get_user_list_source_node() {
        switch (session.command_item.node) {
            case ServerAdministrationManager.ADMIN_COMMAND_PREFIX + "delete-user":
            case ServerAdministrationManager.ADMIN_COMMAND_PREFIX + "disable-user":
                return ServerAdministrationManager.ADMIN_COMMAND_PREFIX + "get-registered-users-list";
            case ServerAdministrationManager.ADMIN_COMMAND_PREFIX + "reenable-user":
                return ServerAdministrationManager.ADMIN_COMMAND_PREFIX + "get-disabled-users-list";
            default:
                return null;
        }
    }

    private async void proceed(string action) {
        if (operation_in_progress || dialog_closed) return;

        AdHocCommands.Command? current = session.command;
        if (current == null) return;
        if (!validate_current_form(action)) return;

        set_busy(true);
        bool success = yield session.proceed(action, current.form);
        set_busy(false);

        if (dialog_closed) {
            cancel_after_close();
            return;
        }
        render_command(success ? null : command_error_message());
    }

    private void on_primary_button_clicked() {
        string action = primary_action;
        if (action == "close") {
            close();
            return;
        }
        if (action == "execute") {
            execute.begin();
            return;
        }
        if (operation_in_progress || dialog_closed || !validate_current_form(action)) return;

        if (!labels.requires_confirmation(action, session.command != null ? ((!) session.command).form : null)) {
            proceed.begin(action);
            return;
        }

        string heading = labels.title + "?";
        string body = labels.description ?? _("Check the selected values before continuing.");
        if (session.command_item.node == "api-commands/destroy_room") {
            heading = _("Delete Group Chat?");
            body = _("The room %s will be permanently deleted from the server. This action cannot be undone.")
                .printf(get_room_address_from_form());
        }
        body += "\n\n" + _("Server: %s").printf(session.command_item.jid.to_string());
        var confirmation = new Adw.AlertDialog(heading, body);
        confirmation.add_response("cancel", _("Cancel"));
        confirmation.add_response("confirm", labels.submit_label);
        confirmation.set_response_appearance("confirm", Adw.ResponseAppearance.DESTRUCTIVE);
        confirmation.default_response = "cancel";
        confirmation.close_response = "cancel";
        confirmation.response.connect((response) => {
            if (response == "confirm" && !dialog_closed) proceed.begin(action);
        });
        confirmation.present(this);
    }

    private bool validate_current_form(string action) {
        AdHocCommands.Command? current = session.command;
        if (current == null) return false;
        if (action != "prev" && ((!) current).form != null && !((!) ((!) current).form).is_result &&
                !((!) ((!) current).form).get_missing_required_fields().is_empty) {
            render_command(_("The required fields marked with * must be completed."));
            return false;
        }
        if (action != "prev" && ((!) current).form != null && !((!) ((!) current).form).is_result) {
            string? error = Util.ServerAdministrationLabels.submission_error(session.command_item, (!) ((!) current).form);
            if (error != null) {
                render_command((!) error);
                return false;
            }
        }
        return true;
    }

    private string get_room_address_from_form() {
        AdHocCommands.Command? current = session.command;
        if (current == null || ((!) current).form == null) return _("the selected room");

        string room = "";
        string service = "";
        foreach (DataForms.DataForm.Field field in ((!) ((!) current).form).fields) {
            string value = field.get_values().is_empty ? "" : field.get_values()[0].strip();
            if (field.var == "room") room = value;
            if (field.var == "service") service = value;
        }
        if (room != "" && service != "") return room + "@" + service;
        if (room != "") return room;
        return _("the selected room");
    }

    private void show_loading() {
        var page = create_page();
        var group = new Adw.PreferencesGroup();
        var row = new Adw.ActionRow() { title = _("Loading command…") };
        var loading_spinner = new Gtk.Spinner() { spinning = true, valign = Gtk.Align.CENTER };
        row.add_suffix(loading_spinner);
        group.add(row);
        page.add(group);
        toolbar_view.content = page;
    }

    private Adw.PreferencesPage create_page() {
        return new Adw.PreferencesPage() {
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
    }

    private void render_command(string? error_message = null) {
        var page = create_page();
        bool has_content = false;

        if (error_message != null) {
            var error_group = new Adw.PreferencesGroup() { title = _("Command failed") };
            error_group.add(new Adw.ActionRow() {
                use_markup = false,
                title = (!) error_message,
                title_selectable = true,
                title_lines = 0
            });
            page.add(error_group);
            has_content = true;
        }

        if (user_list_warning != null) {
            var warning_group = new Adw.PreferencesGroup() { title = _("User list unavailable") };
            warning_group.add(new Adw.ActionRow() {
                use_markup = false,
                title = (!) user_list_warning,
                title_lines = 0
            });
            page.add(warning_group);
            has_content = true;
        }

        AdHocCommands.Command? current = session.command;
        if (current != null && !((!) current).notes.is_empty) {
            var notes_group = new Adw.PreferencesGroup() { title = _("Server Response") };
            foreach (AdHocCommands.NoteItem note in ((!) current).notes) {
                var row = new Adw.ActionRow() {
                    use_markup = false,
                    title = note.text,
                    title_selectable = true,
                    title_lines = 0
                };
                row.add_prefix(new Gtk.Image.from_icon_name(note_icon_name(note.type_)));
                notes_group.add(row);
            }
            page.add(notes_group);
            has_content = true;
        }

        if (current != null && ((!) current).form != null) {
            DataForms.DataForm form = (!) ((!) current).form;
            if (form.is_result || ((!) current).status != AdHocCommands.Command.Status.EXECUTING) {
                string? form_error = form.get_error_message();
                if (form_error != null) {
                    var form_error_group = new Adw.PreferencesGroup() { title = _("Command failed") };
                    form_error_group.add(new Adw.ActionRow() {
                        use_markup = false,
                        title = (!) form_error,
                        title_selectable = true,
                        title_lines = 0
                    });
                    page.add(form_error_group);
                } else {
                    var result_group = new Adw.PreferencesGroup() {
                        title = Markup.escape_text(labels.title),
                        description = Markup.escape_text(form.instructions ?? "")
                    };
                    result_group.add(Util.get_data_form_result_table(form, session.command_item.node));
                    page.add(result_group);
                }
                has_content = true;
            } else {
                GLib.ListStore form_rows = Util.get_data_form_view_model(
                    form, jid_multi_choices, session.command_item.node);
                if (form_rows.get_n_items() > 0 || form.instructions != null || form.title != null) {
                    Gee.List<Adw.PreferencesGroup> form_groups =
                        Util.rows_to_preference_window_split_at_text(form_rows, false);
                    if (form_groups.is_empty) form_groups.add(new Adw.PreferencesGroup());
                    if (form_groups[0].title == "") {
                        form_groups[0].title = Markup.escape_text(labels.title);
                    }
                    form_groups[0].description = Markup.escape_text(form.instructions ?? "");
                    foreach (Adw.PreferencesGroup form_group in form_groups) page.add(form_group);
                    has_content = true;
                }
            }
        }

        if (!has_content) {
            var status_group = new Adw.PreferencesGroup();
            string status_text;
            if (current == null) {
                status_text = _("The server did not return a command response.");
            } else if (((!) current).status == AdHocCommands.Command.Status.COMPLETED) {
                status_text = _("Command completed successfully.");
            } else if (((!) current).status == AdHocCommands.Command.Status.CANCELED) {
                status_text = _("Command canceled.");
            } else {
                status_text = _("The command is waiting for confirmation.");
            }
            status_group.add(new Adw.ActionRow() { title = status_text });
            page.add(status_group);
        }

        toolbar_view.content = page;
        update_action_buttons();
    }

    private void update_action_buttons() {
        previous_button.visible = false;
        primary_button.visible = false;
        primary_button.remove_css_class("suggested-action");
        primary_button.remove_css_class("destructive-action");

        AdHocCommands.Command? current = session.command;
        if (current == null) return;
        if (((!) current).status != AdHocCommands.Command.Status.EXECUTING) {
            primary_action = "close";
            primary_button.label = _("Close");
            primary_button.visible = true;
            return;
        }

        previous_button.visible = session.can_proceed("prev");
        primary_action = session.get_default_action();
        if (!session.can_proceed(primary_action)) return;

        primary_button.label = labels.action_label(primary_action);
        if (labels.requires_confirmation(primary_action, ((!) current).form)) {
            primary_button.add_css_class("destructive-action");
        } else {
            primary_button.add_css_class("suggested-action");
        }
        primary_button.visible = true;
    }

    private void set_busy(bool busy) {
        operation_in_progress = busy;
        spinner.visible = busy;
        spinner.spinning = busy;
        previous_button.sensitive = !busy;
        primary_button.sensitive = !busy;
    }

    private string command_error_message() {
        if (session.last_error == "account-not-connected") {
            return _("The account is not connected. Reconnect and reopen this command.");
        }
        if (session.last_error == "command-not-available") {
            return _("This command is no longer available for this account. Refresh the command list.");
        }
        return _("The server did not accept the command: %s").printf(session.last_error ?? "unknown-error");
    }

    private static string note_icon_name(string type) {
        switch (type) {
            case "error": return "dialog-error-symbolic";
            case "warn": return "dialog-warning-symbolic";
            default: return "dialog-information-symbolic";
        }
    }

    private void on_closed() {
        dialog_closed = true;
        cancel_after_close();
    }

    private void cancel_after_close() {
        AdHocCommands.Command? current = session.command;
        if (cancel_started || session.busy || current == null ||
                ((!) current).status != AdHocCommands.Command.Status.EXECUTING) return;
        cancel_started = true;
        session.cancel.begin();
    }
}

}
