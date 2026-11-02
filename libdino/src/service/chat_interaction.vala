using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

public class ChatInteraction : StreamInteractionModule, Object {
    public static ModuleIdentity<ChatInteraction> IDENTITY = new ModuleIdentity<ChatInteraction>("chat_interaction");
    public string id { get { return IDENTITY.id; } }

    public signal void focused_in(Conversation conversation);
    public signal void focused_out(Conversation conversation);

    private StreamInteractor stream_interactor;
    private Conversation? selected_conversation;

    private HashMap<Conversation, DateTime> last_input_interaction = new HashMap<Conversation, DateTime>(Conversation.hash_func, Conversation.equals_func);
    private HashMap<Conversation, DateTime> last_interface_interaction = new HashMap<Conversation, DateTime>(Conversation.hash_func, Conversation.equals_func);
    private bool focus_in = false;

    public static void start(StreamInteractor stream_interactor) {
        ChatInteraction m = new ChatInteraction(stream_interactor);
        stream_interactor.add_module(m);
    }

    private ChatInteraction(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        Timeout.add_seconds(30, update_interactions);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(new ReceivedMessageListener(stream_interactor));
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).message_sent.connect(on_message_sent);
        stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).new_item.connect(new_item);
        stream_interactor.account_removed.connect(clear_account_state);
        stream_interactor.get_module<ConversationManager>(
            ConversationManager.IDENTITY).conversation_cleared.connect(
                clear_conversation_state);
    }

    public int get_num_unread(Conversation conversation) {
        Database db = Dino.Application.get_default().db;

        Qlite.QueryBuilder query = db.content_item.select()
                .with(db.content_item.conversation_id, "=", conversation.id)
                .with(db.content_item.hide, "=", false);

        ContentItem? read_up_to_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_item_by_id(conversation, conversation.read_up_to_item);
        if (read_up_to_item != null) {
            string time = read_up_to_item.time.to_unix().to_string();
            string id = read_up_to_item.id.to_string();
            query.where(@"time > ? OR (time = ? AND id > ?)", { time, time, id });
        }
        // If it's a new conversation with read_up_to_item == null, all items are new.

        return (int) query.count();
    }

    public bool has_unread_mention(Conversation conversation) {
        return has_unread_mention_in_store(stream_interactor, conversation);
    }

    internal static bool has_unread_mention_in_store(
            StreamInteractor stream_interactor, Conversation conversation) {
        if (!conversation.type_.is_muc_semantic()) return false;

        ContentItemStore content_store = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        ContentItem? read_up_to_item = content_store.get_item_by_id(conversation, conversation.read_up_to_item);
        const int batch_size = 500;
        // Persisted positives are cheap to find even in a very large room.
        // Only legacy UNKNOWN rows need body matching; NONE rows stay in SQL.
        foreach (bool classified_mentions in new bool[] { true, false }) {
            ContentItem? cursor = read_up_to_item;
            while (true) {
                Gee.List<ContentItem> unread_items = content_store
                    .get_unread_mention_candidates(conversation, cursor,
                        batch_size, classified_mentions);
                foreach (ContentItem item in unread_items) {
                    MessageItem? message_item = item as MessageItem;
                    if (message_item != null && MessageMentions.is_mentioned(
                            stream_interactor, conversation,
                            ((!) message_item).message)) return true;
                }
                if (unread_items.size < batch_size) break;
                cursor = unread_items[unread_items.size - 1];
            }
        }
        return false;
    }

    public bool is_active_focus(Conversation? conversation = null) {
        if (conversation != null) {
            return focus_in && conversation.equals(this.selected_conversation);
        } else {
            return focus_in;
        }
    }

    public void on_window_focus_in(Conversation? conversation) {
        on_conversation_focused(conversation);
    }

    public void on_window_focus_out(Conversation? conversation) {
        on_conversation_unfocused(conversation);
    }

    public void on_message_entered(Conversation? conversation) {
        if (!last_input_interaction.has_key(conversation)) {
            send_chat_state_notification(conversation, Xep.ChatStateNotifications.STATE_COMPOSING);
        }
        last_input_interaction[conversation] = new DateTime.now_utc();
        last_interface_interaction[conversation] = new DateTime.now_utc();
    }

    public void on_message_cleared(Conversation? conversation) {
        if (last_input_interaction.has_key(conversation)) {
            last_input_interaction.unset(conversation);
            send_chat_state_notification(conversation, Xep.ChatStateNotifications.STATE_ACTIVE);
        }
    }

    public void on_conversation_selected(Conversation conversation) {
        on_conversation_unfocused(selected_conversation);
        selected_conversation = conversation;
        on_conversation_focused(conversation);
    }

    private void new_item(ContentItem item, Conversation conversation) {
        bool mark_read = is_active_focus(conversation);

        if (!mark_read) {
            MessageItem? message_item = item as MessageItem;
            if (message_item != null) {
                if (message_item.message.direction == Message.DIRECTION_SENT) {
                    mark_read = true;
                }
            }
            if (message_item == null) {
                FileItem? file_item = item as FileItem;
                if (file_item != null) {
                    if (file_item.file_transfer.direction == FileTransfer.DIRECTION_SENT) {
                        mark_read = true;
                    }
                }
            }
        }
        if (mark_read) {
            ContentItem? read_up_to = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_item_by_id(conversation, conversation.read_up_to_item);
            if (read_up_to != null) {
                if (read_up_to.compare(item) < 0) {
                    conversation.read_up_to_item = item.id;
                }
            } else {
                conversation.read_up_to_item = item.id;
            }
        }
    }

    private void on_message_sent(Entities.Message message, Conversation conversation) {
        last_input_interaction.unset(conversation);
        last_interface_interaction.unset(conversation);
    }

    private void clear_conversation_state(Conversation conversation) {
        last_input_interaction.unset(conversation);
        last_interface_interaction.unset(conversation);
    }

    private void clear_account_state(Account account) {
        var stale = new ArrayList<Conversation>(Conversation.equals_func);
        foreach (Conversation conversation in last_input_interaction.keys) {
            if (conversation.account.equals(account)) stale.add(conversation);
        }
        foreach (Conversation conversation in
                last_interface_interaction.keys) {
            if (conversation.account.equals(account) &&
                    !stale.contains(conversation)) {
                stale.add(conversation);
            }
        }
        foreach (Conversation conversation in stale) {
            clear_conversation_state(conversation);
        }

        if (selected_conversation != null &&
                ((!) selected_conversation).account.equals(account)) {
            // Account teardown is local cleanup, not a protocol transition.
            selected_conversation = null;
            focus_in = false;
        }
    }

    private void on_conversation_focused(Conversation? conversation) {
        focus_in = true;
        if (conversation == null) return;
        focused_in(conversation);
        check_send_read();

        ContentItem? latest_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_latest(conversation);
        if (latest_item != null) {
            conversation.read_up_to_item = latest_item.id;
        }
    }

    private void on_conversation_unfocused(Conversation? conversation) {
        focus_in = false;
        if (conversation == null) return;
        focused_out(conversation);
        if (last_input_interaction.has_key(conversation)) {
            send_chat_state_notification(conversation, Xep.ChatStateNotifications.STATE_PAUSED);
            last_input_interaction.unset(conversation);
        }
    }

    private void check_send_read() {
        if (selected_conversation == null) return;
        Entities.Message? message = stream_interactor.get_module<
            MessageStorage>(MessageStorage.IDENTITY)
            .get_latest_received_message(selected_conversation);
        if (message != null) {
            stream_interactor.get_module<DisplayedStateManager>(
                DisplayedStateManager.IDENTITY).mark_displayed(message,
                    selected_conversation);
        }
    }

    private bool update_interactions() {
        for (MapIterator<Conversation, DateTime> iter = last_input_interaction.map_iterator(); iter.next(); ) {
            Conversation conversation = iter.get_key();
            if (last_input_interaction.has_key(conversation) &&
                    (new DateTime.now_utc()).difference(last_input_interaction[conversation]) >= 15 *  TimeSpan.SECOND) {
                iter.unset();
                send_chat_state_notification(conversation, Xep.ChatStateNotifications.STATE_PAUSED);
            }
        }
        for (MapIterator<Conversation, DateTime> iter = last_interface_interaction.map_iterator(); iter.next(); ) {
            Conversation conversation = iter.get_key();
            if (last_interface_interaction.has_key(conversation) &&
                    (new DateTime.now_utc()).difference(last_interface_interaction[conversation]) >= 1.5 *  TimeSpan.MINUTE) {
                iter.unset();
                send_chat_state_notification(conversation, Xep.ChatStateNotifications.STATE_GONE);
            }
        }
        return true;
    }

    private class ReceivedMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "DEDUPLICATE", "FILTER_EMPTY", "STORE_CONTENT_ITEM" };
        public override string action_group { get { return "OTHER_NODES"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StreamInteractor stream_interactor;

        public ReceivedMessageListener(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            message.markable = Xep.ChatMarkers.Module.requests_marking(stanza);
            if (Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza) != null) return false;

            // A protocol response must never trigger another marker or
            // receipt, even if a malformed peer adds body/request elements.
            if (Xep.ChatMarkers.Module.contains_any_marker(stanza) ||
                    Xep.MessageDeliveryReceipts.Module.contains_receipt(
                        stanza)) return false;

            ChatInteraction outer = stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY);
            outer.send_delivery_receipt(message, stanza, conversation);

            if (message.direction == Entities.Message.DIRECTION_SENT) return false;
            if (outer.is_active_focus(conversation)) {
                stream_interactor.get_module<DisplayedStateManager>(
                    DisplayedStateManager.IDENTITY).mark_displayed(message,
                        conversation);
            }
            return false;
        }
    }

    private void send_delivery_receipt(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
        if (message.direction == Entities.Message.DIRECTION_SENT) return;
        if (!Xep.MessageDeliveryReceipts.Module.requests_receipt(stanza)) return;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) return;
        if (message.sender_stanza_id == null ||
                !MessageResponsePolicy.may_send_delivery_receipt(
                    stream_interactor, conversation, message)) return;

        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (stream != null) {
            Xep.MessageDeliveryReceipts.Module module = ((!) stream)
                .get_module<Xep.MessageDeliveryReceipts.Module>(
                    Xep.MessageDeliveryReceipts.Module.IDENTITY);
            module.send_received.begin((!) stream, (!) message.from,
                    (!) message.sender_stanza_id, message.get_type_string(),
                    (_, result) => {
                module.send_received.end(result);
            });
        }
    }

    private void send_chat_state_notification(Conversation conversation, string state) {
        if (conversation.get_send_typing_setting(stream_interactor) != Conversation.Setting.ON) return;

        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (stream != null) {
            string message_type = conversation.type_ == Conversation.Type.GROUPCHAT ? Xmpp.MessageStanza.TYPE_GROUPCHAT : Xmpp.MessageStanza.TYPE_CHAT;
            stream.get_module<Xep.ChatStateNotifications.Module>(Xep.ChatStateNotifications.Module.IDENTITY).send_state(stream, conversation.counterpart, message_type, state);
        }
    }
}

}
