/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Dino.Entities;
using Xmpp.Xep;

namespace Dino {

public class ServerAdministrationCommandSession : Object {
    public Account account { get; private set; }
    public AdHocCommands.CommandItem command_item { get; private set; }
    public AdHocCommands.Command? command { get { return state.command; } }
    public string? last_error { get; private set; }
    public bool busy { get; private set; default = false; }

    private ServerAdministrationManager manager;
    private ServerAdministrationCommandState state;

    internal ServerAdministrationCommandSession(ServerAdministrationManager manager, Account account,
                                                AdHocCommands.CommandItem command_item) {
        this.manager = manager;
        this.account = account;
        this.command_item = command_item;
        this.state = new ServerAdministrationCommandState(command_item);
    }

    public async bool execute() {
        if (busy) return fail("command-busy");
        if (command != null) return fail("command-already-started");

        busy = true;
        ServerAdministrationTransportResult result = yield manager.execute_command(account, command_item);
        busy = false;
        return accept(result);
    }

    public async bool proceed(string action, DataForms.DataForm? form = null) {
        if (busy) return fail("command-busy");
        if (!state.can_proceed(action)) return fail("invalid-command-action");

        AdHocCommands.Command current = (!) command;
        DataForms.DataForm? submit_form = form ?? current.form;

        busy = true;
        ServerAdministrationTransportResult result = yield manager.proceed_command(
            account, command_item, current.sessionid, action, submit_form);
        busy = false;
        return accept(result);
    }

    public async bool cancel() {
        if (busy) return fail("command-busy");
        if (!state.has_active_session()) return fail("no-active-command-session");

        AdHocCommands.Command current = (!) command;
        busy = true;
        ServerAdministrationTransportResult result = yield manager.cancel_command(
            account, command_item, current.sessionid);
        busy = false;

        if (!result.success) return fail(result.error ?? "command-cancel-failed");
        state.mark_canceled();
        last_error = null;
        return true;
    }

    public string get_default_action() {
        return state.get_default_action();
    }

    public bool can_proceed(string action) {
        return state.can_proceed(action);
    }

    private bool accept(ServerAdministrationTransportResult result) {
        if (!result.success || result.command == null) {
            return fail(result.error ?? "command-failed");
        }
        string? validation_error = state.accept((!) result.command);
        if (validation_error != null) return fail((!) validation_error);
        last_error = null;
        return true;
    }

    private bool fail(string error) {
        last_error = error;
        return false;
    }
}

internal class ServerAdministrationCommandState : Object {
    public AdHocCommands.Command? command { get; private set; }

    private AdHocCommands.CommandItem command_item;

    public ServerAdministrationCommandState(AdHocCommands.CommandItem command_item) {
        this.command_item = command_item;
    }

    public string? accept(AdHocCommands.Command result) {
        if (result.node == null || result.node != command_item.node) {
            return "command-node-mismatch";
        }
        if (result.status == AdHocCommands.Command.Status.EXECUTING &&
                (result.sessionid == null || result.sessionid == "")) {
            return "command-sessionid-missing";
        }
        command = result;
        return null;
    }

    public bool has_active_session() {
        return command != null &&
            ((!) command).status == AdHocCommands.Command.Status.EXECUTING &&
            ((!) command).sessionid != null && ((!) command).sessionid != "";
    }

    public string get_default_action() {
        if (!has_active_session()) return "";

        AdHocCommands.Command current = (!) command;
        if (current.execute_action != null && is_protocol_action((!) current.execute_action) &&
                (current.actions.is_empty || current.actions.contains((!) current.execute_action))) {
            return (!) current.execute_action;
        }
        if (current.actions.contains("next")) return "next";
        if (current.actions.contains("complete")) return "complete";
        return "";
    }

    public bool can_proceed(string action) {
        if (!has_active_session()) return false;
        if (action == "") return true;
        if (!is_protocol_action(action)) return false;

        AdHocCommands.Command current = (!) command;
        return current.actions.is_empty || current.actions.contains(action);
    }

    public void mark_canceled() {
        if (command != null) {
            ((!) command).status = AdHocCommands.Command.Status.CANCELED;
        }
    }

    private static bool is_protocol_action(string action) {
        return action == "next" || action == "prev" || action == "complete";
    }
}

internal class ServerAdministrationTransportResult : Object {
    public bool success { get; private set; }
    public AdHocCommands.Command? command { get; private set; }
    public string? error { get; private set; }

    public ServerAdministrationTransportResult.completed(AdHocCommands.Command? command = null) {
        success = true;
        this.command = command;
    }

    public ServerAdministrationTransportResult.failed(string error) {
        success = false;
        this.error = error;
    }
}

}
