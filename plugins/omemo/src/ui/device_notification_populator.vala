using Dino.Entities;
using Xmpp;
using Gtk;

namespace Dino.Plugins.Omemo {

public class DeviceNotificationPopulator : NotificationPopulator, Object {

    public string id { get { return "device_notification"; } }

    private StreamInteractor? stream_interactor;
    private Plugin plugin;
    private Conversation? current_conversation;
    private NotificationCollection? notification_collection;
    private ConversationNotification notification;

    public DeviceNotificationPopulator(Plugin plugin, StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        this.plugin = plugin;

        stream_interactor.account_added.connect(on_account_added);
        plugin.trust_manager.bad_message_state_updated.connect((account, jid, device_id) => {
            if (current_conversation == null) return;
            if (!current_conversation.account.equals(account) ||
                    !current_conversation.counterpart.equals_bare(jid)) return;
            refresh_notification();
        });
    }

    public void init(Conversation conversation, NotificationCollection notification_collection, Plugins.WidgetType type) {
        current_conversation = conversation;
        this.notification_collection = notification_collection;
        if (plugin.has_new_devices(conversation.account, conversation.counterpart) && conversation.type_ == Conversation.Type.CHAT) {
            display_notification();
        }
    }

    public void close(Conversation conversation) {
        if (notification != null && notification_collection != null) {
            notification_collection.remove_meta_notification(notification);
            notification = null;
        }
        current_conversation = null;
        notification_collection = null;
    }

    private void display_notification() {
        if (notification == null && notification_collection != null && current_conversation != null) {
            notification = new ConversationNotification(plugin, current_conversation);
            notification_collection.add_meta_notification(notification);
        }
    }

    private void refresh_notification() {
        if (notification != null && notification_collection != null) {
            notification_collection.remove_meta_notification(notification);
            notification = null;
        }
        if (current_conversation != null &&
                current_conversation.type_ == Conversation.Type.CHAT &&
                plugin.has_new_devices(current_conversation.account,
                    current_conversation.counterpart)) {
            display_notification();
        }
    }

    private void on_account_added(Account account) {
        stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY).bundle_fetched.connect_after((jid, device_id, bundle) => {
            if (current_conversation != null &&
                    current_conversation.account.equals(account) &&
                    jid.equals_bare(current_conversation.counterpart)) {
                refresh_notification();
            }
        });
    }
}

private class ConversationNotification : MetaConversationNotification {
    private Widget widget;
    private Plugin plugin;
    private Jid jid;
    private Account account;

    public ConversationNotification(Plugin plugin, Conversation conversation) {
        this.plugin = plugin;
        this.jid = conversation.counterpart;
        this.account = conversation.account;

        bool has_changed_keys = plugin.has_changed_keys(account, jid);
        Box box = new Box(Orientation.HORIZONTAL, 5);
        Button manage_button = new Button.with_label(has_changed_keys
            ? _("Review key") : _("Manage")) {
                valign = Gtk.Align.CENTER
            };
        manage_button.clicked.connect(() => {
            var variant = new Variant.tuple(new Variant[] {new Variant.int32(conversation.id), new Variant.string("encryption")});
            GLib.Application.get_default().activate_action("open-conversation-details", variant);
        });
        string message = has_changed_keys
            ? _("A device for this contact has a new encryption key. DinoX will use it only after your review.")
            : _("This contact has new devices");
        box.append(new Label(message) {
            margin_end = 10,
            wrap = true,
            xalign = 0,
            hexpand = true
        });
        box.append(manage_button);
        widget = box;
    }

    public override Object? get_widget(WidgetType type) {
        return widget;
    }
}

}
