/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Gee;

using Dino.Entities;

namespace Dino.Ui {

class MenuEntry : Plugins.ConversationTitlebarEntry, Object {
    public string id { get { return "menu"; } }
    public double order { get { return 0; } }

    StreamInteractor stream_interactor;
    private Conversation? conversation;
    private PopoverMenu? popover_menu;
    private bool menu_is_groupchat = false;
    private bool menu_has_history = false;

    MenuButton button = new MenuButton() { icon_name="view-more-symbolic", visible=false };

    public MenuEntry(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        SimpleActionGroup action_group = new SimpleActionGroup();
        SimpleAction details_action = new SimpleAction("details", null);
        details_action.activate.connect((parameter) => {
            if (conversation == null) return;
            var variant = new Variant.tuple(new Variant[] {new Variant.int32(conversation.id), new Variant.string("about")});
            GLib.Application.get_default().activate_action("open-conversation-details", variant);
        });
        action_group.add_action(details_action);

        SimpleAction invite_action = new SimpleAction("invite", null);
        invite_action.activate.connect(on_invite_action);
        action_group.add_action(invite_action);
        
        SimpleAction clear_action = new SimpleAction("clear", null);
        clear_action.activate.connect((parameter) => {
            if (conversation == null) return;
            Util.show_clear_history_dialog(conversation, stream_interactor, button.get_root() as Gtk.Window);
        });
        action_group.add_action(clear_action);
        
        button.insert_action_group("conversation", action_group);
    }

    public new void set_conversation(Conversation conversation) {
        if (this.conversation != conversation) button.popdown();
        button.visible = true;
        button.sensitive = true;
        this.conversation = conversation;
        update_menu();
    }

    private void update_menu() {
        bool is_groupchat = conversation.type_ == Conversation.Type.GROUPCHAT;
        bool has_history = supports_history_refresh(conversation);
        // Actions resolve the current conversation when activated. Only the
        // available entries, not the selected account or JID, shape this menu.
        if (popover_menu != null && menu_is_groupchat == is_groupchat &&
                menu_has_history == has_history) return;

        Menu sections = new Menu();
        Menu details = new Menu();
        details.append(_("Conversation Details"), "conversation.details");
        sections.append_section(null, details);

        Menu history = new Menu();
        if (has_history) {
            history.append(_("Load messages now"),
                "app.load-current-conversation-history");
        }
        // Invite is available via the occupant menu (user icon)
        // if (conversation.type_ == Conversation.Type.GROUPCHAT) {
        //    menu_model.append(_("Invite Contact"), "conversation.invite");
        // }
        history.append(_("Delete Conversation History"), "conversation.clear");
        sections.append_section(null, history);

        Menu closing = new Menu();
        closing.append(_("Close Conversation"), "app.close-current-conversation");
        if (is_groupchat) {
            closing.append(_("Leave Conversation"), "app.leave-current-conversation");
            closing.append(_("Leave Permanently"), "app.leave-current-conversation-permanently");
        }
        sections.append_section(null, closing);
        if (has_history) {
            Menu sharing = new Menu();
            sharing.append(_("Share a feed article…"), "app.feeds");
            sections.append_section(null, sharing);
        }
        if (popover_menu == null) {
            popover_menu = new PopoverMenu.from_model(sections);
            Util.set_menu_button_popover(button, popover_menu);
        } else {
            popover_menu.menu_model = sections;
        }
        menu_is_groupchat = is_groupchat;
        menu_has_history = has_history;
    }

    private void on_invite_action(Variant? parameter) {
        if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;

        Util.show_muc_invite_dialog((!) conversation, stream_interactor, button.get_root() as Gtk.Window);
    }

    public new void unset_conversation() {
        button.popdown();
        conversation = null;
        button.visible = false;
    }

    internal static bool supports_history_refresh(Conversation? target) {
        return target != null && target.counterpart.domainpart != "mqtt.local" &&
            (target.type_ == Conversation.Type.CHAT ||
                target.type_ == Conversation.Type.GROUPCHAT);
    }


    public Object? get_widget(Plugins.WidgetType type) {
        if (type != Plugins.WidgetType.GTK4) return null;
        return button;
    }
}
}
