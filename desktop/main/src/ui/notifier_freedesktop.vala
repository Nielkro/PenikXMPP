using Gee;

using Dino.Entities;
using Xmpp;

public class Dino.Ui.FreeDesktopNotifier : NotificationProvider, Object {

    public signal void conversation_selected(Conversation conversation);

    private StreamInteractor stream_interactor;
    private DBusNotifications dbus_notifications;
    private bool supports_body_markup = false;
    private bool supports_body_hyperlinks = false;

    private HashMap<Conversation, uint32> content_notifications = new HashMap<Conversation, uint32>(Conversation.hash_func, Conversation.equals_func);
    private HashMap<Conversation, Gee.List<uint32>> conversation_notifications = new HashMap<Conversation, Gee.List<uint32>>(Conversation.hash_func, Conversation.equals_func);
    private HashMap<uint32, HashMap<string, ListenerFuncWrapper>> action_listeners = new HashMap<uint32, HashMap<string, ListenerFuncWrapper>>();
    private HashMap<Call, uint32> call_notifications = new HashMap<Call, uint32>(Call.hash_func, Call.equals_func);
    private HashMap<string, uint32> voice_request_notifications =
        new HashMap<string, uint32>();

    public FreeDesktopNotifier(StreamInteractor stream_interactor, DBusNotifications dbus_notifications) {
        this.stream_interactor = stream_interactor;
        this.dbus_notifications = dbus_notifications;

        init_dbus_notifications.begin((obj, res) => {
            try {
                init_dbus_notifications.end(res);
            } catch (Error e) {
                warning("NotifierFreedesktop: Failed to initialize notifications: %s", e.message);
            }
        });
    }

    private async void init_dbus_notifications() throws Error {
        string[] caps;
        yield dbus_notifications.get_capabilities(out caps);
        foreach (string cap in caps) {
            switch (cap) {
                case "body-markup":
                    supports_body_markup = true;
                    break;
                case "body-hyperlinks":
                    supports_body_hyperlinks = true;
                    break;
            }
        }

        dbus_notifications.action_invoked.connect((id, action) => {
            if (action_listeners.has_key(id) && action_listeners[id].has_key(action)) {
                action_listeners[id][action].func();
            }
        });

        dbus_notifications.notification_closed.connect((id) => {
            // Defer cleanup: on KDE Plasma, notification_closed fires
            // before action_invoked when a button is clicked. Idle runs
            // at lower priority than DBus signals, so action_invoked
            // will be processed first.
            Idle.add(() => {
                action_listeners.unset(id);
                return Source.REMOVE;
            });
        });
    }

    public double get_priority() {
        return 1;
    }

    public async void notify_message(Message message, Conversation conversation, string conversation_display_name, string? participant_display_name) {
        string body  = "";
        if (supports_body_hyperlinks) {
            body = Util.parse_add_markup(message.body, null, true, false);
        } else if (supports_body_markup) {
            body = Markup.escape_text(message.body);
        } else {
            body = message.body;
        }
        yield notify_content_item(conversation, conversation_display_name, participant_display_name, body);
    }

    public async void notify_file(FileTransfer file_transfer, Conversation conversation, bool is_image, string conversation_display_name, string? participant_display_name) {
        string text = "";
        if (file_transfer.direction == Message.DIRECTION_SENT) {
            text = is_image ? _("Image sent") : _("File sent");
        } else {
            text = is_image ? _("Image received") : _("File received");
        }

        if (supports_body_markup) {
            text = "<i>" + text + "</i>";
        }

        yield notify_content_item(conversation, conversation_display_name, participant_display_name, text);
    }

    private async void notify_content_item(Conversation conversation, string conversation_display_name, string? participant_display_name, string body_) {
        string body = body_;
        if (participant_display_name != null) {
            if (supports_body_markup) {
                body = @"<b>$(Markup.escape_text(participant_display_name)):</b> $body";
            } else {
                body = @"$participant_display_name: $body";
            }
        }

        uint32 replace_id = content_notifications.has_key(conversation) ? content_notifications[conversation] : 0;
        HashTable<string, Variant> hash_table = new HashTable<string, Variant>(null, null);
        hash_table["image-data"] = yield get_conversation_icon(conversation);
        hash_table["desktop-entry"] = new Variant.string(Dino.Application.get_default().get_application_id());
        hash_table["category"] = new Variant.string("im.received");
        hash_table["suppress-sound"] = new Variant.boolean(true);
        string[] actions = new string[] {"default", "Open conversation"};
        try {
            uint32 notification_id = yield dbus_notifications.notify("Dino", replace_id, "", conversation_display_name, body, actions, hash_table, -1);
            content_notifications[conversation] = notification_id;

            add_action_listener(notification_id, "default", () => {
                GLib.Application.get_default().activate_action("open-conversation", new Variant.int32(conversation.id));
            });
        } catch (Error e) {
            if (e.message.contains("org.freedesktop.DBus.Error.ServiceUnknown")) {
                debug("Notification service disappeared before showing content item notification: %s", e.message);
            } else {
                warning("Failed showing content item notification: %s", e.message);
            }
        }
    }

    public async void notify_call(Call call, Conversation conversation, bool video, bool multiparty, string conversation_display_name) {
        debug("[%s] Call notification", call.account.bare_jid.to_string());
        string summary = Markup.escape_text(conversation_display_name);
        string body =  video ? _("Incoming video call") : _("Incoming call");
        if (multiparty) {
            body = video ? _("Incoming video group call") : _("Incoming group call");
        }

        HashTable<string, Variant> hash_table = new HashTable<string, Variant>(null, null);
        hash_table["image-path"] = "call-start-symbolic";
        hash_table["suppress-sound"] = new Variant.boolean(true);
        hash_table["urgency"] = new Variant.byte(2);
        hash_table["desktop-entry"] = new Variant.string(Dino.Application.get_default().get_application_id());
        hash_table["category"] = new Variant.string("call.incoming");
        string[] actions = new string[] {"default", "Open conversation", "reject", _("Reject"), "accept", _("Accept")};
        try {
            uint32 notification_id = yield dbus_notifications.notify("Dino", 0, "", summary, body, actions, hash_table, 0);
            call_notifications[call] = notification_id;

            add_action_listener(notification_id, "default", () => {
                GLib.Application.get_default().activate_action("open-conversation", new Variant.int32(conversation.id));
            });
            add_action_listener(notification_id, "reject", () => {
                var variant = new Variant.tuple(new Variant[] {new Variant.int32(conversation.id), new Variant.int32(call.id)});
                GLib.Application.get_default().activate_action("reject-call", variant);
            });
            add_action_listener(notification_id, "accept", () => {
                var variant = new Variant.tuple(new Variant[] {new Variant.int32(conversation.id), new Variant.int32(call.id)});
                GLib.Application.get_default().activate_action("accept-call", variant);
            });
        } catch (Error e) {
            if (e.message.contains("org.freedesktop.DBus.Error.ServiceUnknown")) {
                debug("Notification service disappeared before showing call notification: %s", e.message);
            } else {
                warning("Failed showing call notification: %s", e.message);
            }
        }
    }

    public async void retract_call_notification(Call call, Conversation conversation) {
        if (!call_notifications.has_key(call)) return;
        uint32 notification_id = call_notifications[call];
        try {
            yield dbus_notifications.close_notification(notification_id);
            action_listeners.unset(notification_id);
            call_notifications.unset(call);
        } catch (Error e) {
            warning("NotifierFreedesktop: Failed to retract call notification: %s", e.message);
        }
    }

    public async void notify_subscription_request(Conversation conversation) {
        string summary = _("Subscription request");
        string body = Markup.escape_text(conversation.counterpart.to_string());

        HashTable<string, Variant> hash_table = new HashTable<string, Variant>(null, null);
        hash_table["image-data"] = yield get_conversation_icon(conversation);
        hash_table["desktop-entry"] = new Variant.string(Dino.Application.get_default().get_application_id());
        hash_table["category"] = new Variant.string("im");
        string[] actions = new string[] {"default", "Open conversation", "accept", _("Accept"), "deny", _("Deny")};
        try {
            uint32 notification_id = yield dbus_notifications.notify("Dino", 0, "", summary, body, actions, hash_table, -1);

            if (!conversation_notifications.has_key(conversation)) {
                conversation_notifications[conversation] = new ArrayList<uint32>();
            }
            conversation_notifications[conversation].add(notification_id);

            add_action_listener(notification_id, "default", () => {
                GLib.Application.get_default().activate_action("open-conversation", new Variant.int32(conversation.id));
            });
            add_action_listener(notification_id, "accept", () => {
                GLib.Application.get_default().activate_action("accept-subscription", new Variant.int32(conversation.id));
            });
            add_action_listener(notification_id, "deny", () => {
                GLib.Application.get_default().activate_action("deny-subscription", new Variant.int32(conversation.id));
            });
        } catch (Error e) {
            warning("Failed showing subscription request notification: %s", e.message);
        }
    }

    public async void notify_connection_error(Account account, ConnectionManager.ConnectionError error) {
        string summary = _("Could not connect to %s").printf(account.bare_jid.domainpart);
        string body = "";
        switch (error.source) {
            case ConnectionManager.ConnectionError.Source.SASL:
                    body = Util.sasl_error_message(error.identifier, account.domainpart);
                    break;
                case ConnectionManager.ConnectionError.Source.TLS:
                body = _("Invalid TLS certificate");
                break;
            case ConnectionManager.ConnectionError.Source.DNS_SECURITY:
                summary = _("Connection to %s was stopped").printf(account.bare_jid.domainpart);
                body = _("DNSSEC or DANE verification failed. Open this account's connection settings to retry or change its policy.");
                break;
            default:
                break;
        }

        HashTable<string, Variant> hash_table = new HashTable<string, Variant>(null, null);
        hash_table["desktop-entry"] = new Variant.string(Dino.Application.get_default().get_application_id());
        hash_table["category"] = new Variant.string("im.error");
        string[] actions = new string[] {"default", "Open preferences"};
        try {
            uint32 notification_id = yield dbus_notifications.notify("DinoX", 0, "im.dinox.dinox", summary, body, actions, hash_table, -1);

            add_action_listener(notification_id, "default", () => {
                GLib.Application.get_default().activate_action("preferences-account", new Variant.int32(account.id));
            });
        } catch (Error e) {
            warning("Failed showing connection error notification: %s", e.message);
        }
    }

    public async void notify_muc_invite(int invite_id, Account account, Jid room_jid, Jid from_jid, string inviter_display_name) {
        Conversation direct_conversation = new Conversation(from_jid, account, Conversation.Type.CHAT);

        string display_room = room_jid.bare_jid.to_string();
        string summary = _("Invitation to %s").printf(display_room);
        string body = _("%s invited you to %s").printf(inviter_display_name, display_room);
        if (supports_body_markup) {
            body = Markup.escape_text(body);
        }

        HashTable<string, Variant> hash_table = new HashTable<string, Variant>(null, null);
        hash_table["image-data"] = yield get_conversation_icon(direct_conversation);
        hash_table["desktop-entry"] = new Variant.string(Dino.Application.get_default().get_application_id());
        hash_table["category"] = new Variant.string("im");
        string[] actions = new string[] {"default", "", "reject", _("Reject"), "accept", _("Accept")};

        try {
            uint32 notification_id = yield dbus_notifications.notify("Dino", 0, "", summary, body, actions, hash_table, -1);

            add_action_listener(notification_id, "default", () => {
                GLib.Application.get_default().activate_action("open-muc-invite", new Variant.int32(invite_id));
            });
            add_action_listener(notification_id, "accept", () => {
                GLib.Application.get_default().activate_action("open-muc-invite", new Variant.int32(invite_id));
            });
            add_action_listener(notification_id, "reject", () => {
                GLib.Application.get_default().activate_action("deny-muc-invite", new Variant.int32(invite_id));
            });
        } catch (Error e) {
            warning("Failed showing muc invite notification: %s", e.message);
        }
    }

    public async void notify_voice_request(Conversation conversation,
            PendingMucVoiceRequest request) {

        string display_name = request.nick;
        string display_room = Util.get_conversation_display_name(stream_interactor, conversation);
        string summary = _("Permission request");
        string body = _("%s requests the permission to write in %s").printf(display_name, display_room);
        if (supports_body_markup) {
            body = Markup.escape_text(body);
        }

        HashTable<string, Variant> hash_table = new HashTable<string, Variant>(null, null);
        hash_table["image-data"] = yield get_conversation_icon(conversation);
        hash_table["desktop-entry"] = new Variant.string(Dino.Application.get_default().get_application_id());
        hash_table["category"] = new Variant.string("im");
        string[] actions = new string[] {"deny", _("Deny"), "accept", _("Accept")};

        try {
            uint32 notification_id = yield dbus_notifications.notify("Dino", 0, "", summary, body, actions, hash_table, -1);
            voice_request_notifications[request.id] = notification_id;

            add_action_listener(notification_id, "accept", () => {
                GLib.Application.get_default().activate_action(
                    "accept-voice-request", new Variant.string(request.id));
            });
            add_action_listener(notification_id, "deny", () => {
                GLib.Application.get_default().activate_action(
                    "deny-voice-request", new Variant.string(request.id));
            });
        } catch (Error e) {
            warning("Failed showing voice request notification: %s", e.message);
        }
    }

    public async void retract_voice_request(string request_id) {
        if (!voice_request_notifications.has_key(request_id)) return;

        uint32 notification_id = voice_request_notifications[request_id];
        voice_request_notifications.unset(request_id);
        action_listeners.unset(notification_id);
        try {
            yield dbus_notifications.close_notification(notification_id);
        } catch (Error e) {
            debug("NotifierFreedesktop: Failed to retract voice request notification: %s",
                e.message);
        }
    }

    public async void retract_content_item_notifications() {
        foreach (uint32 id in content_notifications.values) {
            try {
                yield dbus_notifications.close_notification(id);
            } catch (Error e) {
                debug("NotifierFreedesktop: Failed to retract content notification: %s", e.message);
            }
        }
        content_notifications.clear();
    }

    public async void retract_conversation_notifications(Conversation conversation) {
        if (content_notifications.has_key(conversation)) {
            try {
                yield dbus_notifications.close_notification(content_notifications[conversation]);
            } catch (Error e) {
                debug("NotifierFreedesktop: Failed to retract content notification: %s", e.message);
            }
            content_notifications.unset(conversation);
        }

        if (conversation_notifications.has_key(conversation)) {
            foreach (var notification_id in conversation_notifications[conversation]) {
                try {
                    yield dbus_notifications.close_notification(notification_id);
                } catch (Error e) {
                    debug("NotifierFreedesktop: Failed to retract conversation notification: %s", e.message);
                }
            }
            conversation_notifications.unset(conversation);
        }
    }

    private async Variant get_conversation_icon(Conversation conversation) {
        CompatAvatarDrawer drawer = new CompatAvatarDrawer() {
            model = new ViewModel.CompatAvatarPictureModel(stream_interactor).set_conversation(conversation),
            width_request = 40,
            height_request = 40
        };
        Cairo.ImageSurface surface = drawer.draw_image_surface();

        int width;
        int height;
        int rowstride;
        uint8[] rgba = image_surface_to_rgba(surface, out width, out height, out rowstride);

        var bytes_builder = new VariantBuilder(new VariantType("ay"));
        foreach (uint8 b in rgba) {
            bytes_builder.add("y", b);
        }
        var image_bytes = bytes_builder.end();
        return new Variant("(iiibii@ay)", width, height, rowstride, true, 8, 4, image_bytes);
    }

    private uint8[] image_surface_to_rgba(Cairo.ImageSurface surface, out int width, out int height, out int rowstride) {
        surface.flush();
        width = surface.get_width();
        height = surface.get_height();
        rowstride = width * 4;

        unowned uint8[] src = surface.get_data();
        int src_stride = surface.get_stride();
        uint8[] rgba = new uint8[height * rowstride];

        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int src_index = y * src_stride + x * 4;
                int dst_index = y * rowstride + x * 4;
                uint8 b = src[src_index];
                uint8 g = src[src_index + 1];
                uint8 r = src[src_index + 2];
                uint8 a = src[src_index + 3];

                rgba[dst_index] = unpremultiply_channel(r, a);
                rgba[dst_index + 1] = unpremultiply_channel(g, a);
                rgba[dst_index + 2] = unpremultiply_channel(b, a);
                rgba[dst_index + 3] = a;
            }
        }

        return rgba;
    }

    private uint8 unpremultiply_channel(uint8 value, uint8 alpha) {
        if (alpha == 0 || alpha == 255) return value;
        int unpremultiplied = ((int) value * 255 + ((int) alpha / 2)) / (int) alpha;
        return (uint8) int.min(unpremultiplied, 255);
    }

    private void add_action_listener(uint32 id, string name, owned ListenerFunc func) {
        if (!action_listeners.has_key(id)) {
            action_listeners[id] = new HashMap<string, ListenerFuncWrapper>();
        }
        action_listeners[id][name] = new ListenerFuncWrapper((owned) func);
    }

    delegate void ListenerFunc();
    class ListenerFuncWrapper {
        public ListenerFunc func;

        public ListenerFuncWrapper(owned ListenerFunc func) {
            this.func = (owned) func;
        }
    }
}
