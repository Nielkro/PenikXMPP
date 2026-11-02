using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino {

public class NotificationEvents : StreamInteractionModule, Object {
    public static ModuleIdentity<NotificationEvents> IDENTITY = new ModuleIdentity<NotificationEvents>("notification_events");
    public string id { get { return IDENTITY.id; } }

    public signal void notify_content_item(ContentItem content_item, Conversation conversation);

    private StreamInteractor stream_interactor;
    private Future<NotificationProvider> notifier;
    private Promise<NotificationProvider> notifier_promise;
    private bool notifier_outstanding = true;
    private HashSet<string> active_voice_requests = new HashSet<string>();

    public static void start(StreamInteractor stream_interactor) {
        NotificationEvents m = new NotificationEvents(stream_interactor);
        stream_interactor.add_module(m);
    }

    public NotificationEvents(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).new_item.connect((item, conversation) => {
            on_content_item_received.begin(item, conversation, (_, res) => on_content_item_received.end(res));
        });
        stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).received_subscription_request.connect((jid, account) => {
            on_received_subscription_request.begin(jid, account, (_, res) => on_received_subscription_request.end(res));
        });

        stream_interactor.get_module<MucInviteManager>(MucInviteManager.IDENTITY).invite_received.connect((invite) => {
            on_invite_received.begin(invite, (_, res) => on_invite_received.end(res));
        });
        MucVoiceRequestManager voice_request_manager =
            stream_interactor.get_module<MucVoiceRequestManager>(
                MucVoiceRequestManager.IDENTITY);
        voice_request_manager.request_received.connect((request) => {
            active_voice_requests.add(request.id);
            on_voice_request_received.begin(request, (_, res) =>
                on_voice_request_received.end(res));
        });
        voice_request_manager.request_response_started.connect((request) => {
            // An answered request remains correlated until the server settles
            // it, but it is no longer actionable. If the response fails, the
            // in-chat request returns without creating another desktop popup.
            deactivate_voice_request(request.id);
        });
        voice_request_manager.request_removed.connect((request) => {
            deactivate_voice_request(request.id);
        });

        stream_interactor.get_module<Calls>(Calls.IDENTITY).call_incoming.connect((call, state, conversation, video, multiparty) => {
            on_call_incoming.begin(call, state, conversation, video, multiparty, (_, res) => on_call_incoming.end(res));
        });
        stream_interactor.connection_manager.connection_error.connect((account, error) => {
            on_connection_error.begin(account, error, (_, res) => on_connection_error.end(res));
        });
        stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).focused_in.connect((conversation) => {
            retract_conversation_notifications.begin(conversation,
                (_, res) => retract_conversation_notifications.end(res));
        });
        stream_interactor.get_module<DisplayedStateManager>(
                DisplayedStateManager.IDENTITY)
            .remote_read_state_advanced.connect((conversation,
                    read_up_to_item) => {
                retract_if_remote_read_covers_latest.begin(conversation,
                    read_up_to_item, (_, res) =>
                        retract_if_remote_read_covers_latest.end(res));
            });

        notifier_promise = new Promise<NotificationProvider>();
        notifier = notifier_promise.future;

        // Connect lazily: MessageDeletion is started after NotificationEvents,
        // so we defer the connection until the first provider is registered.
        Idle.add(() => {
            var deletion = stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY);
            if (deletion != null) {
                deletion.item_deleted.connect((item) => {
                    on_item_deleted.begin(item, (_, res) => on_item_deleted.end(res));
                });
            }
            return Source.REMOVE;
        });
    }

    private bool notifications_enabled() {
        return Application.get_default().settings.notifications;
    }

    public async void register_notification_provider(NotificationProvider notification_provider) {
        // If this is the first provider (notifier_outstanding is true), set it immediately
        if (notifier_outstanding) {
            notifier_outstanding = false;
            notifier_promise.set_value(notification_provider);
            return;
        }
        
        // Otherwise check if this provider has higher priority
        NotificationProvider? current_notifier = null;
        try {
            current_notifier = yield notifier.wait_async();
        } catch (Gee.FutureError e) {
            warning("Failed to wait for notifier: %s", e.message);
        }

        if (current_notifier != null && current_notifier.get_priority() < notification_provider.get_priority()) {
            notifier_promise = new Promise<NotificationProvider>();
            notifier = notifier_promise.future;
            notifier_promise.set_value(notification_provider);
        }
    }

    private async void on_content_item_received(ContentItem item, Conversation conversation) {
        ContentItem last_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_latest(conversation);
        bool active_focus = stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).is_active_focus(conversation);

        if (item.id != last_item.id) return;
        if (active_focus) return;
        if (item.id == conversation.read_up_to_item) return;

        bool visual_notifications = notifications_enabled();
        Conversation.NotifySetting notify = get_content_notification_setting(conversation);
        if (notify == Conversation.NotifySetting.OFF) return;

        string conversation_display_name = get_conversation_display_name(stream_interactor, conversation, null);
        string? participant_display_name = null;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            participant_display_name = get_participant_display_name(stream_interactor, conversation, item.jid);
        }

        switch (item.type_) {
            case MessageItem.TYPE:
                Message message = ((MessageItem) item).message;

                if (message.direction == Message.DIRECTION_SENT) return;

                if (notify == Conversation.NotifySetting.HIGHLIGHT) {
                    if (!MessageMentions.is_mentioned(stream_interactor,
                            conversation, message)) return;
                }

                notify_content_item(item, conversation);
                if (visual_notifications) {
                    try {
                        NotificationProvider provider = yield notifier.wait_async();
                        yield provider.notify_message(message, conversation, conversation_display_name, participant_display_name);
                    } catch (Gee.FutureError e) {
                        warning("Failed to notify message: %s", e.message);
                    }
                }
                break;
            case FileItem.TYPE:
                FileTransfer? file_transfer = ((FileItem) item).file_transfer;
                if (file_transfer == null) return;
                bool is_image = file_transfer.mime_type != null && file_transfer.mime_type.has_prefix("image");

                // Don't notify on file transfers in a groupchat set to "mention only"
                if (notify == Conversation.NotifySetting.HIGHLIGHT) return;
                if (file_transfer.direction == FileTransfer.DIRECTION_SENT) return;

                notify_content_item(item, conversation);
                if (visual_notifications) {
                    try {
                        NotificationProvider notifier = yield notifier.wait_async();
                        yield notifier.notify_file(file_transfer, conversation, is_image, conversation_display_name, participant_display_name);
                    } catch (Gee.FutureError e) {
                        warning("Failed to notify file: %s", e.message);
                    }
                }
                break;
            case CallItem.TYPE:
                // handled in `on_call_incoming`
                break;
        }
    }

    private Conversation.NotifySetting get_content_notification_setting(Conversation conversation) {
        return conversation.get_notification_setting(stream_interactor);
    }

    private async void on_voice_request_received(
            PendingMucVoiceRequest request) {
        if (!notifications_enabled()) return;
        if (!active_voice_requests.contains(request.id)) return;

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(
            request.room_jid, request.account, Conversation.Type.GROUPCHAT);
        if (conversation == null) return;

        try {
            NotificationProvider notifier = yield notifier.wait_async();
            if (!active_voice_requests.contains(request.id)) return;
            yield notifier.notify_voice_request(conversation, request);
            // Removal can race with icon loading or the platform notify call.
            // Retract a notification that completed after its request ended.
            if (!active_voice_requests.contains(request.id)) {
                yield notifier.retract_voice_request(request.id);
            }
        } catch (Gee.FutureError e) {
            warning("Failed to notify voice request: %s", e.message);
        }
    }

    private async void on_voice_request_removed(string request_id) {
        try {
            NotificationProvider notifier = yield notifier.wait_async();
            yield notifier.retract_voice_request(request_id);
        } catch (Gee.FutureError e) {
            warning("Failed to retract voice request notification: %s",
                e.message);
        }
    }

    private void deactivate_voice_request(string request_id) {
        if (!active_voice_requests.remove(request_id)) return;
        on_voice_request_removed.begin(request_id, (_, res) =>
            on_voice_request_removed.end(res));
    }

    private async void on_received_subscription_request(Jid jid, Account account) {
        // Skip desktop notification for bot JIDs (subscription is auto-approved)
        if (stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).is_subscription_suppressed(account, jid)) return;

        Conversation conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).create_conversation(jid, account, Conversation.Type.CHAT);
        if (stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).is_active_focus(conversation)) return;
        if (!notifications_enabled()) return;

        try {
            NotificationProvider notifier = yield notifier.wait_async();
            yield notifier.notify_subscription_request(conversation);
        } catch (Gee.FutureError e) {
            warning("Failed to notify subscription request: %s", e.message);
        }
    }

    private async void on_call_incoming(Call call, CallState call_state, Conversation conversation, bool video, bool multiparty) {
        if (!stream_interactor.get_module<Calls>(Calls.IDENTITY).can_we_do_call(call.account, video, multiparty)) return;
        if (!notifications_enabled()) return;

        string conversation_display_name = get_conversation_display_name(stream_interactor, conversation, null);

        try {
            NotificationProvider notifier = yield notifier.wait_async();
            yield notifier.notify_call(call, conversation, video, multiparty, conversation_display_name);
            call.notify["state"].connect(() => {
                if (call.state != Call.State.RINGING) {
                    notifier.retract_call_notification.begin(call, conversation, (_, res) => notifier.retract_call_notification.end(res));
                }
            });
        } catch (Gee.FutureError e) {
            warning("Failed to notify call: %s", e.message);
        }
    }

    private async void on_invite_received(PendingMucInvite invite) {
        if (!notifications_enabled()) return;

        string inviter_display_name;
        if (invite.room_jid.equals_bare(invite.from_jid)) {
            Conversation conversation = new Conversation(invite.room_jid, invite.account, Conversation.Type.GROUPCHAT);
            inviter_display_name = get_participant_display_name(stream_interactor, conversation, invite.from_jid);
        } else {
            Conversation direct_conversation = new Conversation(invite.from_jid, invite.account, Conversation.Type.CHAT);
            inviter_display_name = get_participant_display_name(stream_interactor, direct_conversation, invite.from_jid);
        }
        try {
            NotificationProvider notifier = yield notifier.wait_async();
            yield notifier.notify_muc_invite(invite.id, invite.account, invite.room_jid, invite.from_jid, inviter_display_name);
        } catch (Gee.FutureError e) {
            warning("Failed to notify muc invite: %s", e.message);
        }
    }

    private async void on_connection_error(Account account, ConnectionManager.ConnectionError error) {
        if (!notifications_enabled()) return;

        try {
            NotificationProvider notifier = yield notifier.wait_async();
            yield notifier.notify_connection_error(account, error);
        } catch (Gee.FutureError e) {
            warning("Failed to notify connection error: %s", e.message);
        }
    }

    private async void retract_conversation_notifications(
            Conversation conversation) {
        try {
            NotificationProvider notifier = yield notifier.wait_async();
            yield notifier.retract_conversation_notifications(conversation);
        } catch (Gee.FutureError e) {
            warning("Failed to retract notifications: %s", e.message);
        }
    }

    private async void retract_if_remote_read_covers_latest(
            Conversation conversation, int read_up_to_item) {
        try {
            NotificationProvider notifier = yield notifier.wait_async();
            if (!remote_read_covers_latest(conversation, read_up_to_item)) {
                return;
            }
            yield notifier.retract_conversation_notifications(conversation);
        } catch (Gee.FutureError e) {
            warning("Failed to retract remotely read notifications: %s",
                e.message);
        }
    }

    private bool remote_read_covers_latest(Conversation conversation,
            int read_up_to_item) {
        if (read_up_to_item < 0) return false;

        ContentItemStore store = stream_interactor.get_module<
            ContentItemStore>(ContentItemStore.IDENTITY);
        ContentItem? read_item = store.get_item_by_id(conversation,
            read_up_to_item);
        ContentItem? latest = store.get_latest(conversation);
        return read_item_covers_latest(read_item, latest);
    }

    internal static bool read_item_covers_latest(ContentItem? read_item,
            ContentItem? latest) {
        return read_item != null && latest != null &&
            ((!) read_item).compare((!) latest) >= 0;
    }

    private async void on_item_deleted(ContentItem item) {
        Conversation? conversation = null;
        if (item is MessageItem) {
            conversation = ((MessageItem) item).conversation;
        } else if (item is FileItem) {
            conversation = ((FileItem) item).conversation;
        }
        if (conversation == null) return;

        try {
            NotificationProvider notifier = yield notifier.wait_async();
            yield notifier.retract_conversation_notifications(conversation);
        } catch (Gee.FutureError e) {
            warning("Failed to retract notification for deleted item: %s", e.message);
        }
    }
}

public interface NotificationProvider : Object {
    public abstract double get_priority();

    public abstract async void notify_message(Message message, Conversation conversation, string conversation_display_name, string? participant_display_name);
    public abstract async void notify_file(FileTransfer file_transfer, Conversation conversation, bool is_image, string conversation_display_name, string? participant_display_name);
    public abstract async void notify_call(Call call, Conversation conversation, bool video, bool multiparty, string conversation_display_name);
    public abstract async void retract_call_notification(Call call, Conversation conversation);
    public abstract async void notify_subscription_request(Conversation conversation);
    public abstract async void notify_connection_error(Account account, ConnectionManager.ConnectionError error);
    public abstract async void notify_muc_invite(int invite_id, Account account, Jid room_jid, Jid from_jid, string inviter_display_name);
    public abstract async void notify_voice_request(Conversation conversation,
        PendingMucVoiceRequest request);
    public abstract async void retract_voice_request(string request_id);

    public abstract async void retract_content_item_notifications();
    public abstract async void retract_conversation_notifications(Conversation conversation);
}

}
