using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

    public class GNotificationsNotifier : NotificationProvider, Object {

        public signal void conversation_selected(Conversation conversation);

        private StreamInteractor stream_interactor;
        private HashMap<Conversation, Notification> notifications = new HashMap<Conversation, Notification>(Conversation.hash_func, Conversation.equals_func);
        private Set<string>? active_conversation_ids = null;
        private Set<string>? active_ids = new HashSet<string>();

        public GNotificationsNotifier(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public double get_priority() {
            return 0;
        }

        public async void notify_message(Message message, Conversation conversation, string conversation_display_name, string? participant_display_name) {
            string text = message.body;
            if (participant_display_name != null) {
                text = @"$participant_display_name: $text";
            }
            yield notify_content_item(conversation, conversation_display_name, text);
        }

        public async void notify_file(FileTransfer file_transfer, Conversation conversation, bool is_image, string conversation_display_name, string? participant_display_name) {
            string text = "";
            if (file_transfer.direction == Message.DIRECTION_SENT) {
                text = is_image ? _("Image sent") : _("File sent");
            } else {
                text = is_image ? _("Image received") : _("File received");
            }

            if (participant_display_name != null) {
                text = @"$participant_display_name: $text";
            }

            yield notify_content_item(conversation, conversation_display_name, text);
        }

        private async void notify_content_item(Conversation conversation, string title, string body) {
            if (!notifications.has_key(conversation)) {
                notifications[conversation] = new Notification("");
                notifications[conversation].set_default_action_and_target_value("app.open-conversation", new Variant.int32(conversation.id));
            }
            Notification notification = notifications[conversation];

            notification.set_title(title);
            notification.set_body(body);
            try {
                notification.set_icon(yield get_conversation_icon(conversation));
            } catch (Error e) {
                warning("NotifierGNotifications: Failed to get icon for conversation: %s", e.message);
            }

            send_notification_safe(conversation.id.to_string(), notifications[conversation]);

            if (active_conversation_ids != null) {
                active_conversation_ids.add(conversation.id.to_string());
            }
        }

        public async void notify_call(Call call, Conversation conversation, bool video, bool multiparty, string conversation_display_name) {
            Notification notification = new Notification(conversation_display_name);
            string body =  video ? _("Incoming video call") : _("Incoming call");
            if (multiparty) {
                body = video ? _("Incoming video group call") : _("Incoming group call");
            }
            notification.set_body(body);
            notification.set_priority(GLib.NotificationPriority.URGENT);

            notification.set_icon(new ThemedIcon.from_names(new string[] {"call-start-symbolic"}));

            notification.set_default_action_and_target_value("app.open-conversation", new Variant.int32(conversation.id));
            notification.add_button_with_target_value(_("Reject"), "app.reject-call", new Variant.int32(call.id));
            notification.add_button_with_target_value(_("Accept"), "app.accept-call", new Variant.int32(call.id));

            send_notification_safe(call.id.to_string(), notification);
        }

        private async void retract_call_notification(Call call, Conversation conversation) {
            withdraw_notification_safe(call.id.to_string());
        }

        public async void notify_subscription_request(Conversation conversation) {
            Notification notification = new Notification(_("Subscription request"));
            notification.set_body(conversation.counterpart.to_string());
            try {
                notification.set_icon(yield get_conversation_icon(conversation));
            } catch (Error e) {
                warning("NotifierGNotifications: Failed to get icon for subscription request: %s", e.message);
            }
            notification.set_default_action_and_target_value("app.open-conversation", new Variant.int32(conversation.id));
            notification.add_button_with_target_value(_("Accept"), "app.accept-subscription", conversation.id);
            notification.add_button_with_target_value(_("Deny"), "app.deny-subscription", conversation.id);
            send_notification_safe(conversation.id.to_string() + "-subscription", notification);
            active_ids.add(conversation.id.to_string() + "-subscription");
        }

        public async void notify_connection_error(Account account, ConnectionManager.ConnectionError error) {
            // "Reconnecting..." sounds less alarming than "Could not connect" during temporary Tor startup glitches.
            Notification notification = new Notification(_("Reconnecting to %s...").printf(account.bare_jid.domainpart));
            notification.set_default_action_and_target_value("app.preferences-account", new Variant.int32(account.id));
            switch (error.source) {
                case ConnectionManager.ConnectionError.Source.SASL:
                    notification.set_body(Util.sasl_error_message(error.identifier, account.domainpart));
                    break;
                case ConnectionManager.ConnectionError.Source.TLS:
                    notification.set_body("Invalid TLS certificate");
                    break;
                case ConnectionManager.ConnectionError.Source.DNS_SECURITY:
                    notification.set_title(_("Connection to %s was stopped").printf(account.bare_jid.domainpart));
                    notification.set_body(_("DNSSEC or DANE verification failed. Open this account's connection settings to retry or change its policy."));
                    break;
                default:
                    break;
            }
            send_notification_safe(account.id.to_string() + "-connection-error", notification);
        }

        public async void notify_muc_invite(int invite_id, Account account, Jid room_jid, Jid from_jid, string inviter_display_name) {
            Conversation direct_conversation = new Conversation(from_jid, account, Conversation.Type.CHAT);

            string display_room = room_jid.bare_jid.to_string();
            Notification notification = new Notification(_("Invitation to %s").printf(display_room));
            string body = _("%s invited you to %s").printf(inviter_display_name, display_room);
            notification.set_body(body);

            try {
                notification.set_icon(yield get_conversation_icon(direct_conversation));
            } catch (Error e) {
                warning("NotifierGNotifications: Failed to get icon for MUC invite: %s", e.message);
            }

            notification.set_default_action_and_target_value("app.open-muc-invite", new Variant.int32(invite_id));
            notification.add_button_with_target_value(_("Deny"), "app.deny-muc-invite", new Variant.int32(invite_id));
            notification.add_button_with_target_value(_("Accept"), "app.open-muc-invite", new Variant.int32(invite_id));
            send_notification_safe("muc-invite-%d".printf(invite_id), notification);
        }

        public async void notify_voice_request(Conversation conversation,
                PendingMucVoiceRequest request) {
            string display_name = request.nick;
            string display_room = Util.get_conversation_display_name(stream_interactor, conversation);
            Notification notification = new Notification(_("Permission request"));
            string body = _("%s requests the permission to write in %s").printf(display_name, display_room);
            notification.set_body(body);

            try {
                notification.set_icon(yield get_conversation_icon(conversation));
            } catch (Error e) {
                warning("NotifierGNotifications: Failed to get icon for voice request: %s", e.message);
            }

            notification.add_button_with_target_value(_("Deny"),
                "app.deny-voice-request", new Variant.string(request.id));
            notification.add_button_with_target_value(_("Accept"),
                "app.accept-voice-request", new Variant.string(request.id));
            send_notification_safe("voice-" + request.id, notification);
        }

        public async void retract_voice_request(string request_id) {
            withdraw_notification_safe("voice-" + request_id);
        }

        public async void retract_content_item_notifications() {
            if (active_conversation_ids == null) {
                Gee.List<Conversation> conversations = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations();
                foreach (Conversation conversation in conversations) {
                    withdraw_notification_safe(conversation.id.to_string());
                }
                active_conversation_ids = new HashSet<string>();
            } else {
                foreach (string id in active_conversation_ids) {
                    withdraw_notification_safe(id);
                }
                active_conversation_ids.clear();
            }
        }

        public async void retract_conversation_notifications(Conversation conversation) {
            string content_id = conversation.id.to_string();
            withdraw_notification_safe(content_id);
            notifications.unset(conversation);
            if (active_conversation_ids != null) {
                active_conversation_ids.remove(content_id);
            }

            string subscription_id = conversation.id.to_string() + "-subscription";
            if (active_ids.contains(subscription_id)) {
                withdraw_notification_safe(subscription_id);
                active_ids.remove(subscription_id);
            }
        }

        private async Icon get_conversation_icon(Conversation conversation) throws Error {
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
            var texture = new Gdk.MemoryTexture(width, height, Gdk.MemoryFormat.R8G8B8A8, new Bytes(rgba), rowstride);
            return new BytesIcon(texture.save_to_png_bytes());
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

        private void send_notification_safe(string? id, Notification notification) {
#if !WINDOWS
            GLib.Application.get_default().send_notification(id, notification);
#endif
        }

        private void withdraw_notification_safe(string id) {
#if !WINDOWS
            GLib.Application.get_default().withdraw_notification(id);
#endif
        }
    }
}
