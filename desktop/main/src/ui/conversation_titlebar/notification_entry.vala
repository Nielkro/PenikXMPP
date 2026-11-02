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

namespace Dino.Ui {

class NotificationEntry : Plugins.ConversationTitlebarEntry, Object {
    public string id { get { return "notification"; } }
    public double order { get { return 0.5; } }

    private StreamInteractor stream_interactor;
    private Conversation? conversation;
    private ulong conversation_notify_setting_handler_id = 0;
    private PopoverMenu? popover_menu;
    private bool menu_supports_highlight = false;

    private MenuButton button = new MenuButton() {
        icon_name = "dino-bell-large-symbolic",
        visible = false
    };
    private SimpleAction notification_action = new SimpleAction.stateful(
        "setting",
        VariantType.INT32,
        new Variant.int32(Conversation.NotifySetting.DEFAULT)
    );

    public NotificationEntry(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        SimpleActionGroup action_group = new SimpleActionGroup();
        notification_action.activate.connect((parameter) => {
            if (conversation == null || parameter == null) return;

            conversation.notify_setting = (Conversation.NotifySetting) parameter.get_int32();
            notification_action.set_state(parameter);
            update_button_state();
        });
        action_group.add_action(notification_action);
        button.insert_action_group("notification", action_group);

        var app = GLib.Application.get_default() as Dino.Application;
        app.settings.notify["notifications"].connect(() => {
            update_button_state();
        });

        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).room_info_updated.connect((account, muc_jid) => {
            if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;
            if (conversation.account.equals(account) && conversation.counterpart.equals_bare(muc_jid)) {
                update_button_state();
            }
        });
    }

    public new void set_conversation(Conversation conversation) {
        if (this.conversation != conversation) button.popdown();
        clear_conversation_handler();

        this.conversation = conversation;
        conversation_notify_setting_handler_id = conversation.notify["notify-setting"].connect(() => {
            update_button_state();
        });

        button.visible = true;
        update_menu();
        update_button_state();
    }

    public new void unset_conversation() {
        button.popdown();
        clear_conversation_handler();
        conversation = null;
        button.visible = false;
        notification_action.set_state(new Variant.int32(Conversation.NotifySetting.DEFAULT));
    }

    public Object? get_widget(Plugins.WidgetType type) {
        if (type != Plugins.WidgetType.GTK4) return null;
        return button;
    }

    private void clear_conversation_handler() {
        if (conversation != null && conversation_notify_setting_handler_id != 0) {
            SignalHandler.disconnect(conversation, conversation_notify_setting_handler_id);
            conversation_notify_setting_handler_id = 0;
        }
    }

    private void update_menu() {
        if (conversation == null) return;
        bool highlight = supports_highlight();
        // Selection and notification state are updated separately; changing
        // chats does not require replacing an unchanged native menu.
        if (popover_menu != null && menu_supports_highlight == highlight) return;

        Menu menu_model = new Menu();
        if (highlight) {
            append_setting_item(menu_model, _("Notify for all messages"), Conversation.NotifySetting.ON);
            append_setting_item(menu_model, _("Notify only for mentions"), Conversation.NotifySetting.HIGHLIGHT);
        } else {
            append_setting_item(menu_model, _("Enable notifications"), Conversation.NotifySetting.ON);
        }
        append_setting_item(menu_model, _("Disable notifications"), Conversation.NotifySetting.OFF);
        append_setting_item(menu_model, _("Reset to default"), Conversation.NotifySetting.DEFAULT);

        if (popover_menu == null) {
            popover_menu = new PopoverMenu.from_model(menu_model);
            Util.set_menu_button_popover(button, popover_menu);
        } else {
            popover_menu.menu_model = menu_model;
        }
        menu_supports_highlight = highlight;
    }

    private void append_setting_item(Menu menu_model, string label, Conversation.NotifySetting setting) {
        MenuItem item = new MenuItem(label, null);
        item.set_action_and_target_value("notification.setting", new Variant.int32(setting));
        menu_model.append_item(item);
    }

    private bool supports_highlight() {
        return conversation != null && conversation.type_ == Conversation.Type.GROUPCHAT;
    }

    private void update_button_state() {
        if (conversation == null) {
            button.visible = false;
            return;
        }

        notification_action.set_state(new Variant.int32(conversation.notify_setting));

        Conversation.NotifySetting effective_setting = get_effective_notification_setting();
        button.set_icon_name(effective_setting == Conversation.NotifySetting.OFF ?
                "dino-bell-large-none-symbolic" : "dino-bell-large-symbolic");
        button.tooltip_text = Util.string_if_tooltips_active(get_tooltip_text(effective_setting));
    }

    private Conversation.NotifySetting get_effective_notification_setting() {
        var app = GLib.Application.get_default() as Dino.Application;
        if (app != null && !app.settings.notifications) return Conversation.NotifySetting.OFF;
        return conversation.get_notification_setting(stream_interactor);
    }

    private string get_tooltip_text(Conversation.NotifySetting effective_setting) {
        var app = GLib.Application.get_default() as Dino.Application;
        if (app != null && !app.settings.notifications) return _("Notifications are disabled globally");

        switch (effective_setting) {
            case Conversation.NotifySetting.ON:
                return _("Notifications enabled");
            case Conversation.NotifySetting.HIGHLIGHT:
                return _("Notifications for mentions");
            case Conversation.NotifySetting.OFF:
                return _("Notifications disabled");
            case Conversation.NotifySetting.DEFAULT:
                assert_not_reached();
        }
        return _("Notifications disabled");
    }
}

}
