using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {
public class CounterpartInteractionManager : StreamInteractionModule, Object {
    public static ModuleIdentity<CounterpartInteractionManager> IDENTITY = new ModuleIdentity<CounterpartInteractionManager>("counterpart_interaction_manager");
    public string id { get { return IDENTITY.id; } }

    public signal void received_state(Conversation conversation, string state);
    public signal void received_message_received(Account account, Jid jid, Entities.Message message);
    public signal void received_message_displayed(Account account, Jid jid, Entities.Message message);

    private StreamInteractor stream_interactor;
    private HashMap<Conversation, HashMap<Jid, DateTime>> typing_since = new HashMap<Conversation, HashMap<Jid, DateTime>>(Conversation.hash_func, Conversation.equals_func);
    private PendingMessageStateQueue pending_delivery_receipts =
        new PendingMessageStateQueue();

    public static void start(StreamInteractor stream_interactor) {
        CounterpartInteractionManager m = new CounterpartInteractionManager(stream_interactor);
        stream_interactor.add_module(m);
    }

    private CounterpartInteractionManager(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(clear_account_state);
        MessageProcessor message_processor = stream_interactor.get_module<
            MessageProcessor>(MessageProcessor.IDENTITY);
        message_processor.message_received.connect((message, conversation) =>
            clear_chat_state(conversation, message.from));
        message_processor.message_sent_or_received.connect(
            replay_pending_delivery_receipts);
        stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).received_offline_presence.connect((jid, account) => {
            foreach (Conversation conversation in stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversations(jid, account)) {
                clear_chat_state(conversation, jid);
            }
        });
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_cleared.connect(clear_conversation_state);
        stream_interactor.get_module<DisplayedStateManager>(DisplayedStateManager.IDENTITY).received_message_displayed.connect((account, jid, message) => {
            received_message_displayed(account, jid, message);
        });
        stream_interactor.stream_negotiated.connect((account) => {
            clear_all_chat_states(account);
            pending_delivery_receipts.clear_account(account);
        });

        Timeout.add_seconds(60, () => {
            var one_min_ago = new DateTime.now_utc().add_seconds(-60);

            foreach (Conversation conversation in typing_since.keys) {
                ArrayList<Jid> to_remove = new ArrayList<Jid>();
                foreach (Jid jid in typing_since[conversation].keys) {
                    if (typing_since[conversation][jid].compare(one_min_ago) < 0) {
                        to_remove.add(jid);
                    }
                }
                foreach (Jid jid in to_remove) {
                    clear_chat_state(conversation, jid);
                }
            }
            return true;
        });
    }

    public Gee.List<Jid>? get_typing_jids(Conversation conversation) {
        if (stream_interactor.connection_manager.get_state(conversation.account) != ConnectionManager.ConnectionState.CONNECTED) return null;
        if (!typing_since.has_key(conversation) || typing_since[conversation].size == 0) return null;

        var jids = new ArrayList<Jid>();
        foreach (Jid jid in typing_since[conversation].keys) {
            jids.add(jid);
        }
        return jids;
    }

    private void on_account_added(Account account) {
        stream_interactor.module_manager.get_module<Xep.ChatMarkers.Module>(account, Xep.ChatMarkers.Module.IDENTITY).legacy_received.connect((stream, jid, id, stanza) => {
            on_delivery_receipt_received(account, stream, jid, id, stanza);
        });
        stream_interactor.module_manager.get_module<Xep.MessageDeliveryReceipts.Module>(account, Xep.MessageDeliveryReceipts.Module.IDENTITY).receipt_received.connect((stream, jid, id, stanza) => {
            on_delivery_receipt_received(account, stream, jid, id, stanza);
        });
        stream_interactor.module_manager.get_module<Xep.ChatStateNotifications.Module>(account, Xep.ChatStateNotifications.Module.IDENTITY).chat_state_received.connect((stream, jid, state, stanza) => {
            on_chat_state_received(account, stream, jid, state, stanza);
        });
    }

    private void clear_chat_state(Conversation conversation, Jid jid) {
        if (!(typing_since.has_key(conversation) && typing_since[conversation].has_key(jid))) return;

        typing_since[conversation].unset(jid);
        received_state(conversation, Xmpp.Xep.ChatStateNotifications.STATE_ACTIVE);
    }

    private void clear_all_chat_states(Account account) {
        foreach (Conversation conversation in typing_since.keys) {
            if (conversation.account.equals(account)) {
                received_state(conversation, Xmpp.Xep.ChatStateNotifications.STATE_ACTIVE);
                typing_since[conversation].clear();
            }
        }
    }

    private void on_chat_state_received(Account account, XmppStream stream,
            Jid jid, string state, MessageStanza stanza) {
        if (stream_interactor.get_stream(account) != stream) return;

        // Don't show our own (other devices) typing notification
        if (jid.equals_bare(account.bare_jid)) return;

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).approx_conversation_for_stanza(stanza.from, stanza.to, account, stanza.type_);
        if (conversation == null) return;

        // Don't show our own typing notification in MUCs
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            Jid? own_muc_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(jid.bare_jid, account);
            if (own_muc_jid != null && own_muc_jid.equals(jid)) {
                return;
            }
        }

        if (!typing_since.has_key(conversation)) {
            typing_since[conversation] = new HashMap<Jid, DateTime>(Jid.hash_func, Jid.equals_func);
        }
        if (state == Xmpp.Xep.ChatStateNotifications.STATE_COMPOSING) {
            typing_since[conversation][jid] = new DateTime.now_utc();
            received_state(conversation, state);
        } else {
            clear_chat_state(conversation, jid);
        }
    }

    private void on_delivery_receipt_received(Account account,
            XmppStream stream, Jid sender, string message_id,
            MessageStanza stanza) {
        if (stream_interactor.get_stream(account) != stream) return;

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).approx_conversation_for_stanza(stanza.from, stanza.to, account, stanza.type_);
        if (conversation == null) return;

        if (!try_apply_delivery_receipt((!) conversation, sender,
                message_id)) {
            pending_delivery_receipts.offer((!) conversation, sender,
                message_id);
        }
    }

    private bool try_apply_delivery_receipt(Conversation conversation,
            Jid sender, string message_id) {
        if (is_own_sender(conversation, sender)) return true;
        // Delivery state for anonymous room broadcasts cannot be attributed safely.
        if (conversation.type_ == Conversation.Type.GROUPCHAT) return true;

        Entities.Message? message = stream_interactor.get_module<
            MessageStorage>(MessageStorage.IDENTITY)
            .get_message_by_sender_stanza_id(message_id, conversation,
                Entities.Message.DIRECTION_SENT);
        if (message == null) return false;

        received_message_received(conversation.account, sender, message);
        message.marked = Entities.Message.Marked.RECEIVED;
        return true;
    }

    private void replay_pending_delivery_receipts(Entities.Message message,
            Conversation conversation) {
        if (message.direction != Entities.Message.DIRECTION_SENT ||
                message.sender_stanza_id == null) return;

        foreach (PendingMessageState pending in pending_delivery_receipts.take(
                conversation, (!) message.sender_stanza_id)) {
            try_apply_delivery_receipt(conversation, pending.sender,
                pending.message_id);
        }
    }

    private bool is_own_sender(Conversation conversation, Jid sender) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT && conversation.account.bare_jid.equals_bare(sender)) return true;

        Jid? own_muc_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(sender.bare_jid, conversation.account);
        return own_muc_jid != null && own_muc_jid.equals(sender);
    }

    private void clear_conversation_state(Conversation conversation) {
        typing_since.unset(conversation);
        pending_delivery_receipts.clear_conversation(conversation);
    }

    private void clear_account_state(Account account) {
        ArrayList<Conversation> to_remove = new ArrayList<Conversation>();
        foreach (Conversation conversation in typing_since.keys) {
            if (conversation.account.equals(account)) to_remove.add(conversation);
        }
        foreach (Conversation conversation in to_remove) {
            clear_conversation_state(conversation);
        }
        pending_delivery_receipts.clear_account(account);
    }
}

}
