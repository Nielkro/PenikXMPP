/*
 * Windows notification provider.
 * Default: serialized native Shell_NotifyIcon notifications, with per-item
 * click actions and explicit cancellation. The DinoX sound plugin owns audio.
 * Optional: WinRT Toast notifications with rich UI and action buttons, enabled
 * through DINOX_ENABLE_WINRT_TOASTS=1. Unavailable WinRT falls back to native.
 */
using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

    public class WindowsNotifier : NotificationProvider, Object {

        private StreamInteractor stream_interactor;
        private bool toast_available = false;

        // Every native notification owns its own immutable action data.
        private class BalloonAction : Object {
            public string action;
            public Variant parameter;
            public BalloonAction(string action, Variant parameter) {
                this.action = action;
                this.parameter = parameter;
            }
        }

        public WindowsNotifier(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;

            /* The raw WinRT/COM toast bridge is kept opt-in for now.  The
             * normal Windows path uses Shell_NotifyIcon balloons, which avoids
             * registering native COM callbacks during startup. */
            bool enable_winrt_toasts = Environment.get_variable("DINOX_ENABLE_WINRT_TOASTS") == "1";
            if (enable_winrt_toasts) {
                toast_available = ToastWin32.init(
                    "DinoX",
                    "im.dinox.dinox",
                    on_toast_activated,
                    null
                );
            }
            if (toast_available) {
                message("WindowsNotifier: using WinRT Toast notifications");
            } else {
                message("WindowsNotifier: WinRT unavailable, using balloon tips");
            }
        }

        public double get_priority() {
            return 2;
        }

        /* ======= Notification methods ======= */

        public async void notify_message(Message message, Conversation conversation,
                                          string conversation_display_name,
                                          string? participant_display_name) {
            string text = message.body;
            if (participant_display_name != null) {
                text = @"$participant_display_name: $text";
            }
            if (toast_available) {
                string xml = build_simple_toast(conversation_display_name, text,
                    "open-conversation:%d".printf(conversation.id));
                ToastWin32.show(xml, "conv-%d".printf(conversation.id));
            } else {
                show_balloon(conversation_display_name, text, 1, conversation.id, "open-conversation");
            }
        }

        public async void notify_file(FileTransfer file_transfer, Conversation conversation,
                                       bool is_image, string conversation_display_name,
                                       string? participant_display_name) {
            string text;
            if (file_transfer.direction == Message.DIRECTION_SENT) {
                text = is_image ? _("Image sent") : _("File sent");
            } else {
                text = is_image ? _("Image received") : _("File received");
            }
            if (participant_display_name != null) {
                text = @"$participant_display_name: $text";
            }
            if (toast_available) {
                string xml = build_simple_toast(conversation_display_name, text,
                    "open-conversation:%d".printf(conversation.id));
                ToastWin32.show(xml, "conv-%d".printf(conversation.id));
            } else {
                show_balloon(conversation_display_name, text, 1, conversation.id, "open-conversation");
            }
        }

        public async void notify_call(Call call, Conversation conversation,
                                       bool video, bool multiparty,
                                       string conversation_display_name) {
            string body = video ? _("Incoming video call") : _("Incoming call");
            if (multiparty) {
                body = video ? _("Incoming video group call") : _("Incoming group call");
            }
            if (toast_available) {
                string xml = build_call_toast(conversation_display_name, body,
                    conversation.id, call.id);
                ToastWin32.show(xml, "call-%d".printf(call.id));
            } else {
                show_balloon(conversation_display_name, body, 2,
                    conversation.id, "open-conversation", call.id);
            }
        }

        public async void retract_call_notification(Call call, Conversation conversation) {
            if (toast_available) {
                ToastWin32.hide("call-%d".printf(call.id));
            } else {
                SystrayWin32.hide_balloon("call:%d".printf(call.id));
            }
        }

        public async void notify_subscription_request(Conversation conversation) {
            string body = conversation.counterpart.to_string();
            if (toast_available) {
                string xml = build_simple_toast(_("Subscription request"), body,
                    "open-conversation:%d".printf(conversation.id));
                ToastWin32.show(xml, "sub-%d".printf(conversation.id));
            } else {
                show_balloon(_("Subscription request"), body, 1, conversation.id, "open-conversation");
            }
        }

        public async void notify_connection_error(Account account,
                                                    ConnectionManager.ConnectionError error) {
            string title = _("Reconnecting to %s...").printf(account.bare_jid.domainpart);
            if (error.source == ConnectionManager.ConnectionError.Source.DNS_SECURITY) {
                title = _("Connection to %s was stopped").printf(account.bare_jid.domainpart);
            }
            string body = "";
            switch (error.source) {
                case ConnectionManager.ConnectionError.Source.SASL:
                    body = Util.sasl_error_message(error.identifier, account.domainpart);
                    break;
                case ConnectionManager.ConnectionError.Source.TLS:
                    body = "Invalid TLS certificate";
                    break;
                case ConnectionManager.ConnectionError.Source.DNS_SECURITY:
                    body = _("DNSSEC or DANE verification failed. Open this account's connection settings to retry or change its policy.");
                    break;
                default:
                    body = error.identifier ?? "Connection error";
                    break;
            }
            if (toast_available) {
                string xml = build_simple_toast(title, body,
                    "preferences-account:%d".printf(account.id));
                ToastWin32.show(xml, "conn-%d".printf(account.id));
            } else {
                show_balloon(title, body, 2, account.id,
                    "preferences-account");
            }
        }

        public async void notify_muc_invite(int invite_id, Account account, Jid room_jid,
                                              Jid from_jid, string inviter_display_name) {
            string display_room = room_jid.bare_jid.to_string();
            string body = _("%s invited you to %s").printf(inviter_display_name, display_room);

            if (toast_available) {
                string xml = build_simple_toast(
                    _("Invitation to %s").printf(display_room), body,
                    "open-muc-invite:%d".printf(invite_id));
                ToastWin32.show(xml, "muc-invite-%d".printf(invite_id));
            } else {
                show_balloon(_("Invitation to %s").printf(display_room), body,
                    1, invite_id, "open-muc-invite");
            }
        }

        public async void notify_voice_request(Conversation conversation,
                PendingMucVoiceRequest request) {
            string display_name = request.nick;
            string display_room = Util.get_conversation_display_name(stream_interactor, conversation);
            string body = _("%s requests the permission to write in %s").printf(display_name, display_room);

            if (toast_available) {
                string xml = build_voice_request_toast(body, conversation.id,
                    request.id);
                ToastWin32.show(xml, "voice-" + request.id);
            } else {
                show_balloon(_("Permission request"), body, 1,
                    conversation.id, "open-conversation", -1, request.id);
            }
        }

        public async void retract_voice_request(string request_id) {
            if (toast_available) {
                ToastWin32.hide("voice-" + request_id);
            } else {
                SystrayWin32.hide_balloon("voice:" + request_id);
            }
        }

        public async void retract_content_item_notifications() {
            if (toast_available) {
                /* Toast notifications are tagged per-conversation, no blanket hide needed.
                 * Individual toasts expire naturally or are removed per-conversation. */
            } else {
                SystrayWin32.hide_balloon("conv:", true);
            }
        }

        public async void retract_conversation_notifications(Conversation conversation) {
            if (toast_available) {
                ToastWin32.hide("conv-%d".printf(conversation.id));
            } else {
                SystrayWin32.hide_balloon("conv:%d".printf(conversation.id));
            }
        }

        /* ======= Toast XML builders ======= */

        /* Standard toast: title + body, click opens action */
        private static string build_simple_toast(string title, string body, string launch_args) {
            return "<toast launch=\"%s\"><visual><binding template=\"ToastGeneric\"><text>%s</text><text>%s</text></binding></visual><audio silent=\"true\"/></toast>".printf(
                Markup.escape_text(launch_args),
                Markup.escape_text(title),
                Markup.escape_text(body)
            );
        }

        /* Call toast: scenario=incomingCall, Accept/Reject buttons, looping call sound */
        private static string build_call_toast(string caller, string body,
                                                int conv_id, int call_id) {
            return ("<toast scenario=\"incomingCall\" launch=\"%s\">" +
                    "<visual><binding template=\"ToastGeneric\">" +
                    "<text>%s</text><text>%s</text>" +
                    "</binding></visual>" +
                    "<actions>" +
                    "<action content=\"%s\" arguments=\"%s\" activationType=\"foreground\"/>" +
                    "<action content=\"%s\" arguments=\"%s\" activationType=\"foreground\"/>" +
                    "</actions>" +
                    "<audio silent=\"true\"/>" +
                    "</toast>").printf(
                Markup.escape_text("open-conversation:%d".printf(conv_id)),
                Markup.escape_text(caller),
                Markup.escape_text(body),
                Markup.escape_text(_("Reject")),
                Markup.escape_text("reject-call:%d:%d".printf(conv_id, call_id)),
                Markup.escape_text(_("Accept")),
                Markup.escape_text("accept-call:%d:%d".printf(conv_id, call_id))
            );
        }

        /* Voice request toast: click opens the room; buttons answer the exact
         * request UUID so repeated requests cannot reuse an older action. */
        private static string build_voice_request_toast(string body,
                int conv_id, string request_id) {
            return ("<toast launch=\"%s\">" +
                    "<visual><binding template=\"ToastGeneric\">" +
                    "<text>%s</text><text>%s</text>" +
                    "</binding></visual>" +
                    "<actions>" +
                    "<action content=\"%s\" arguments=\"%s\" activationType=\"foreground\"/>" +
                    "<action content=\"%s\" arguments=\"%s\" activationType=\"foreground\"/>" +
                    "</actions>" +
                    "<audio silent=\"true\"/>" +
                    "</toast>").printf(
                Markup.escape_text("open-conversation:%d".printf(conv_id)),
                Markup.escape_text(_("Permission request")),
                Markup.escape_text(body),
                Markup.escape_text(_("Deny")),
                Markup.escape_text("deny-voice-request:" + request_id),
                Markup.escape_text(_("Accept")),
                Markup.escape_text("accept-voice-request:" + request_id)
            );
        }

        /* ======= Toast activation callback ======= */

        /* Called on GTK main thread when user clicks toast body or button.
         * Parses the action:arg1:arg2 string and dispatches to app actions. */
        private static void on_toast_activated(string action_args, void* user_data) {
            string[] parts = action_args.split(":");
            if (parts.length < 2) return;

            string action = parts[0];
            var app = GLib.Application.get_default();
            if (app == null) return;

            if (action == "accept-voice-request" ||
                    action == "deny-voice-request") {
                if (parts[1] != "") {
                    app.activate_action(action,
                        new Variant.string(parts[1]));
                }
                return;
            }

            int id1;
            if (!int.try_parse(parts[1], out id1)) return;

            switch (action) {
                case "open-conversation":
                case "open-muc-invite":
                case "accept-muc-invite":
                case "deny-muc-invite":
                case "preferences-account":
                    app.activate_action(action, new Variant.int32(id1));
                    break;
                case "accept-call":
                case "reject-call":
                    if (parts.length >= 3) {
                        int id2 = int.parse(parts[2]);
                        app.activate_action(action, new Variant.tuple(new Variant[]{
                            new Variant.int32(id1), new Variant.int32(id2)
                        }));
                    }
                    break;
            }
        }

        /* ======= Balloon fallback helpers ======= */

        private void show_balloon(string title, string body, int icon_type,
                                   int target_id, string action,
                                   int call_id = -1,
                                   string? voice_request_id = null) {
            string key;
            if (voice_request_id != null) key = "voice:" + voice_request_id;
            else if (call_id >= 0) key = "call:%d".printf(call_id);
            else if (action == "preferences-account") key = "account:%d".printf(target_id);
            else if (action == "open-muc-invite") key = "invite:%d".printf(target_id);
            else key = "conv:%d".printf(target_id);
            var data = new BalloonAction(action, new Variant.int32(target_id));
            // The native queue takes this reference and releases it exactly once.
            data.ref();
            SystrayWin32.show_balloon(title, body, icon_type, on_balloon_click,
                (void*) data, on_balloon_destroy, key);
        }

        private static void on_balloon_destroy(void* user_data) {
            if (user_data != null) ((BalloonAction) user_data).unref();
        }

        private static void on_balloon_click(void* user_data) {
            unowned BalloonAction data = (BalloonAction) user_data;
            // Copy both values before the queue invokes its destroy callback.
            string action = data.action;
            Variant parameter = data.parameter;
            Idle.add(() => {
                var app = GLib.Application.get_default();
                if (app != null) app.activate_action(action, parameter);
                return Source.REMOVE;
            });
        }

    }
}
