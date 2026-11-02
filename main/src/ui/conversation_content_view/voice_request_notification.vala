/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Dino.Entities;

namespace Dino.Ui.ConversationSummary {

/** Persistent in-chat presentation of all pending voice requests. */
public class VoiceRequestNotification : Object {
    private MucVoiceRequestManager manager;
    private Conversation? conversation;
    private ConversationView? conversation_view;
    private Widget? current_notification;
    private ulong changed_handler_id = 0;

    public VoiceRequestNotification(StreamInteractor stream_interactor) {
        this.manager = stream_interactor.get_module<MucVoiceRequestManager>(
            MucVoiceRequestManager.IDENTITY);
        changed_handler_id = manager.requests_changed.connect(
            on_requests_changed);
    }

    public void init(Conversation conversation,
            ConversationView conversation_view) {
        remove_current_notification();
        this.conversation = conversation;
        this.conversation_view = conversation_view;
        rebuild();
    }

    private void on_requests_changed(Account account, Xmpp.Jid room_jid) {
        if (!is_current_room(account, room_jid)) return;
        rebuild();
    }

    private bool is_current_room(Account account, Xmpp.Jid room_jid) {
        if (conversation == null || conversation_view == null ||
                ((!) conversation_view).conversation != conversation ||
                ((!) conversation).type_ != Conversation.Type.GROUPCHAT) {
            return false;
        }
        return account.id == ((!) conversation).account.id &&
            account.bare_jid.equals(
                ((!) conversation).account.bare_jid) &&
            room_jid.bare_jid.equals(
                ((!) conversation).counterpart.bare_jid);
    }

    private void rebuild() {
        remove_current_notification();
        if (conversation == null || conversation_view == null ||
                ((!) conversation).type_ != Conversation.Type.GROUPCHAT ||
                ((!) conversation_view).conversation != conversation) return;

        Gee.List<PendingMucVoiceRequest> requests =
            manager.get_pending_requests(((!) conversation).account,
                ((!) conversation).counterpart);
        if (requests.is_empty) return;

        var container = new Box(Orientation.VERTICAL, 6) {
            margin_start = 10,
            margin_end = 10,
            margin_top = 8,
            margin_bottom = 8
        };
        var heading = new Label(_("Requests for permission to write")) {
            xalign = 0,
            hexpand = true
        };
        heading.add_css_class("heading");
        container.append(heading);

        foreach (PendingMucVoiceRequest request in requests) {
            var row = new Box(Orientation.HORIZONTAL, 8);
            row.append(new Image.from_icon_name("dialog-question-symbolic"));
            var label = new Label(
                _("%s would like permission to write.").printf(request.nick)) {
                xalign = 0,
                hexpand = true,
                wrap = true,
                max_width_chars = 42
            };
            row.append(label);

            var deny_button = new Button.with_label(_("Deny"));
            var accept_button = new Button.with_label(_("Allow writing"));
            accept_button.add_css_class("suggested-action");
            string request_id = request.id;
            deny_button.clicked.connect(() => {
                GLib.Application.get_default().activate_action(
                    "deny-voice-request", new Variant.string(request_id));
            });
            accept_button.clicked.connect(() => {
                GLib.Application.get_default().activate_action(
                    "accept-voice-request", new Variant.string(request_id));
            });
            row.append(deny_button);
            row.append(accept_button);
            container.append(row);
        }

        current_notification = container;
        ((!) conversation_view).add_notification(container);
    }

    private void remove_current_notification() {
        if (current_notification != null && conversation_view != null) {
            ((!) conversation_view).remove_notification(
                (!) current_notification);
        }
        current_notification = null;
    }

    public override void dispose() {
        remove_current_notification();
        if (changed_handler_id != 0) {
            SignalHandler.disconnect(manager, changed_handler_id);
            changed_handler_id = 0;
        }
        conversation = null;
        conversation_view = null;
        base.dispose();
    }
}

}
