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
using Xmpp;

namespace Dino.Ui.ConversationSummary {

/** Join-scoped warning while every room occupant may see real JIDs. */
public class RealJidVisibilityNotification : Object {
    private MucManager manager;
    private Conversation? conversation;
    private ConversationView? conversation_view;
    private Widget? current_notification;
    private Gee.HashSet<string> dismissed_room_keys =
        new Gee.HashSet<string>();
    private ulong visibility_changed_handler_id = 0;
    private ulong join_started_handler_id = 0;
    private ulong left_handler_id = 0;

    public RealJidVisibilityNotification(StreamInteractor stream_interactor) {
        manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        visibility_changed_handler_id =
            manager.room_real_jid_visibility_changed.connect(
                on_visibility_changed);
        join_started_handler_id = manager.room_initial_sync_started.connect(
            on_join_started);
        left_handler_id = manager.left_signal.connect(on_left);
    }

    public void init(Conversation conversation,
            ConversationView conversation_view) {
        remove_current_notification();
        this.conversation = conversation;
        this.conversation_view = conversation_view;
        rebuild();
    }

    private void on_visibility_changed(Account account, Jid room_jid,
            Xmpp.Xep.Muc.RealJidVisibility visibility) {
        dismissed_room_keys.remove(room_key(account, room_jid));
        if (!is_current_room(account, room_jid)) return;
        if (visibility == Xmpp.Xep.Muc.RealJidVisibility.ANYONE) {
            rebuild();
        } else {
            remove_current_notification();
        }
    }

    private void on_join_started(Account account, Jid room_jid) {
        dismissed_room_keys.remove(room_key(account, room_jid));
        if (is_current_room(account, room_jid)) rebuild();
    }

    private void on_left(Account account, Jid room_jid) {
        dismissed_room_keys.remove(room_key(account, room_jid));
        if (is_current_room(account, room_jid)) {
            remove_current_notification();
        }
    }

    private static string room_key(Account account, Jid room_jid) {
        return account.id.to_string() + "\n" +
            room_jid.bare_jid.to_string();
    }

    private bool is_current_room(Account account, Jid room_jid) {
        return conversation != null && conversation_view != null &&
            ((!) conversation_view).conversation == conversation &&
            ((!) conversation).type_ == Conversation.Type.GROUPCHAT &&
            ((!) conversation).account.equals(account) &&
            ((!) conversation).counterpart.equals_bare(room_jid);
    }

    private void rebuild() {
        remove_current_notification();
        if (conversation == null || conversation_view == null ||
                !is_current_room(((!) conversation).account,
                    ((!) conversation).counterpart) ||
                manager.get_room_real_jid_visibility(
                    ((!) conversation).account,
                    ((!) conversation).counterpart) !=
                    Xmpp.Xep.Muc.RealJidVisibility.ANYONE) {
            return;
        }

        Account warned_account = ((!) conversation).account;
        Jid warned_room = ((!) conversation).counterpart.bare_jid;
        string warning_key = room_key(warned_account, warned_room);
        if (dismissed_room_keys.contains(warning_key)) return;

        var container = new Box(Orientation.HORIZONTAL, 8) {
            margin_start = 10,
            margin_end = 10,
            margin_top = 8,
            margin_bottom = 8
        };
        container.append(new Image.from_icon_name(
            "dialog-warning-symbolic"));
        container.append(new Label(_(
            "This room is non-anonymous. Every participant can see your XMPP address.")) {
                xalign = 0,
                hexpand = true,
                wrap = true,
                max_width_chars = 58
            });
        var close_button = new Button.from_icon_name(
            "window-close-symbolic") {
                tooltip_text = _("Close"),
                valign = Align.CENTER
            };
        close_button.add_css_class("flat");
        close_button.update_property(
            AccessibleProperty.LABEL, _("Close"), -1);
        close_button.clicked.connect(() => {
            if (current_notification != container ||
                    !is_current_room(warned_account, warned_room)) return;
            dismissed_room_keys.add(warning_key);
            remove_current_notification();
        });
        container.append(close_button);

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
        if (visibility_changed_handler_id != 0) {
            SignalHandler.disconnect(manager,
                visibility_changed_handler_id);
            visibility_changed_handler_id = 0;
        }
        if (join_started_handler_id != 0) {
            SignalHandler.disconnect(manager, join_started_handler_id);
            join_started_handler_id = 0;
        }
        if (left_handler_id != 0) {
            SignalHandler.disconnect(manager, left_handler_id);
            left_handler_id = 0;
        }
        dismissed_room_keys.clear();
        conversation = null;
        conversation_view = null;
        base.dispose();
    }
}

}
