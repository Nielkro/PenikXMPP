using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

internal class DisplayedMarkerTarget : Object {
    public Jid recipient { get; private set; }
    public string message_id { get; private set; }
    public string message_type { get; private set; }

    public DisplayedMarkerTarget(Jid recipient, string message_id,
            string message_type) {
        this.recipient = recipient;
        this.message_id = message_id;
        this.message_type = message_type;
    }
}

internal class PendingDisplayedMarker : Object {
    public Entities.Message message { get; private set; }
    public bool server_assist_candidate { get; private set; }

    public PendingDisplayedMarker(Entities.Message message,
            bool server_assist_candidate) {
        this.message = message;
        this.server_assist_candidate = server_assist_candidate;
    }
}

internal class DisplayedServerAssistTarget : Object {
    public Jid chat { get; private set; }
    public StableStanzaReference reference { get; private set; }

    public DisplayedServerAssistTarget(Jid chat,
            StableStanzaReference reference) {
        this.chat = chat;
        this.reference = reference;
    }
}

internal enum DisplayedMarkerApplyResult {
    APPLIED,
    UNKNOWN_TARGET,
    REJECTED
}

internal enum DisplayedStateSyncRoute {
    NONE,
    REGULAR_PEP,
    SERVER_ASSIST
}

/** Tracks one asynchronous operation per conversation without ABA races. */
internal class ConversationOperationTracker : Object {
    private HashMap<Conversation, uint64?> active =
        new HashMap<Conversation, uint64?>(Conversation.hash_func,
            Conversation.equals_func);
    private uint64 next_id = 1;

    public bool is_active(Conversation conversation) {
        return active.has_key(conversation);
    }

    public uint64 begin(Conversation conversation) {
        uint64 operation_id = next_id++;
        if (next_id == 0) next_id = 1;
        active[conversation] = operation_id;
        return operation_id;
    }

    public bool finish(Conversation conversation, uint64 operation_id) {
        if (!active.has_key(conversation) ||
                active[conversation] != operation_id) {
            return false;
        }
        active.unset(conversation);
        return true;
    }

    public void clear(Conversation conversation) {
        active.unset(conversation);
    }

    public Gee.List<Conversation> snapshot() {
        var conversations = new ArrayList<Conversation>(
            Conversation.equals_func);
        conversations.add_all(active.keys);
        return conversations;
    }
}

/** Owns the single local read pointer shared by XEP-0333 and XEP-0490. */
public class DisplayedStateManager : StreamInteractionModule, Object {
    public static ModuleIdentity<DisplayedStateManager> IDENTITY =
        new ModuleIdentity<DisplayedStateManager>("displayed_state_manager");
    public string id { get { return IDENTITY.id; } }

    public signal void received_message_displayed(Account account, Jid jid,
        Entities.Message message);
    public signal void groupchat_displayed_state_changed(
        Conversation conversation, Entities.Message target);
    public signal void remote_read_state_advanced(Conversation conversation,
        int read_up_to_item);

    private StreamInteractor stream_interactor;
    private Dino.Entities.Settings settings;
    private MucDisplayedStateStore? muc_displayed_state_store;
    private HashMap<Conversation, Entities.Message> last_contact_marker_sent =
        new HashMap<Conversation, Entities.Message>(
            Conversation.hash_func, Conversation.equals_func);
    private HashMap<Conversation, PendingDisplayedMarker>
        pending_contact_markers =
        new HashMap<Conversation, PendingDisplayedMarker>(
            Conversation.hash_func, Conversation.equals_func);
    private ConversationOperationTracker contact_marker_operations =
        new ConversationOperationTracker();
    private PendingMessageStateQueue pending_contact_marker_receipts =
        new PendingMessageStateQueue();
    private HashMap<Account, DisplayedStateSyncOwner> sync_owners =
        new HashMap<Account, DisplayedStateSyncOwner>(Account.hash_func,
            Account.equals_func);

    public static void start(StreamInteractor stream_interactor,
            Dino.Entities.Settings settings, Database db) {
        var manager = new DisplayedStateManager(stream_interactor, settings,
            db);
        stream_interactor.add_module(manager);
    }

    private DisplayedStateManager(StreamInteractor stream_interactor,
            Dino.Entities.Settings settings, Database db) {
        this.stream_interactor = stream_interactor;
        this.settings = settings;
        this.muc_displayed_state_store = new MucDisplayedStateStore(db);

        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(clear_account_state);
        stream_interactor.stream_attached_modules.connect((account, stream) => {
            DisplayedStateSyncOwner? owner = sync_owners[account];
            if (owner != null) ((!) owner).prepare_stream(stream);
        });
        stream_interactor.stream_negotiated.connect((account, stream) => {
            pending_contact_marker_receipts.clear_account(account);
            DisplayedStateSyncOwner? owner = sync_owners[account];
            if (owner != null) ((!) owner).begin_fresh_stream(stream);
        });
        stream_interactor.stream_resumed.connect((account, stream) => {
            DisplayedStateSyncOwner? owner = sync_owners[account];
            if (owner != null) ((!) owner).begin_resumed_stream(stream);
        });
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY)
            .history_sync.account_archive_sync_finished.connect(
                (account, stream, result) => {
            DisplayedStateSyncOwner? owner = sync_owners[account];
            if (owner != null) ((!) owner).mark_history_settled(stream);
        });
        stream_interactor.get_module<ConversationManager>(
            ConversationManager.IDENTITY).conversation_cleared.connect(
                clear_conversation_state);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY)
            .message_sent_or_received.connect(replay_pending_contact_markers);
        stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY)
            .new_item.connect(reconcile_new_content_item);
        settings.notify["sync-displayed-state"]
            .connect(update_device_sync_setting);
    }

    internal DisplayedStateManager.for_tests(
            StreamInteractor stream_interactor,
            Dino.Entities.Settings settings, Database? db = null) {
        this.stream_interactor = stream_interactor;
        this.settings = settings;
        if (db != null) {
            this.muc_displayed_state_store =
                new MucDisplayedStateStore((!) db);
        }
    }

    internal void queue_contact_marker_for_tests(Conversation conversation,
            Entities.Message message) {
        queue_contact_marker(conversation, message, false);
    }

    internal DisplayedMarkerApplyResult apply_contact_marker_for_tests(
            Conversation conversation, Jid sender, string message_id) {
        return try_apply_marker(conversation, sender, message_id);
    }

    /** Advance local read state and independently schedule XEP-0333. */
    public void mark_displayed(Entities.Message message,
            Conversation conversation) {
        if (message.direction != Entities.Message.DIRECTION_RECEIVED) return;
        bool local_advanced = advance_local_marker(conversation, message);

        DisplayedMarkerTarget? marker_target = null;
        if (conversation.get_send_marker_setting(stream_interactor) ==
                Conversation.Setting.ON &&
                (conversation.type_ == Conversation.Type.GROUPCHAT ||
                    message.markable) &&
                MessageResponsePolicy.may_send_displayed(stream_interactor,
                    conversation, message)) {
            marker_target = get_xep0333_target(conversation, message);
        }

        bool assist_available = marker_target != null &&
            may_use_server_assist(conversation, message,
                (!) marker_target);
        DisplayedStateSyncRoute sync_route = select_sync_route(
            local_advanced, device_sync_enabled(), marker_target != null,
            assist_available);
        bool server_assist_candidate = sync_route ==
            DisplayedStateSyncRoute.SERVER_ASSIST;
        if (sync_route == DisplayedStateSyncRoute.REGULAR_PEP) {
            // Contact-visible markers are optional. Device synchronization is
            // not, so every non-assisted path is queued immediately via PEP.
            queue_device_sync(conversation, message);
        }
        if (marker_target != null) {
            queue_contact_marker(conversation, message,
                server_assist_candidate);
        }
    }

    internal static DisplayedStateSyncRoute select_sync_route(
            bool local_advanced, bool device_sync_enabled,
            bool contact_marker_available, bool server_assist_available) {
        if (!local_advanced || !device_sync_enabled) {
            return DisplayedStateSyncRoute.NONE;
        }
        if (contact_marker_available && server_assist_available) {
            return DisplayedStateSyncRoute.SERVER_ASSIST;
        }
        return DisplayedStateSyncRoute.REGULAR_PEP;
    }

    internal static DisplayedMarkerTarget? get_xep0333_target(
            Conversation conversation, Entities.Message message) {
        Jid? recipient;
        string? message_id;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            recipient = conversation.counterpart.bare_jid;
            StableStanzaReference? reference =
                StableStanzaReferenceResolver.for_message(conversation,
                    message);
            message_id = reference != null ? ((!) reference).id : null;
        } else {
            recipient = message.from;
            message_id = message.sender_stanza_id;
        }
        if (recipient == null || message_id == null ||
                ((!) message_id).strip().length == 0) {
            return null;
        }
        return new DisplayedMarkerTarget((!) recipient,
            (!) message_id, message.get_type_string());
    }

    private void queue_contact_marker(Conversation conversation,
            Entities.Message message, bool server_assist_candidate) {
        Entities.Message? sent = last_contact_marker_sent[conversation];
        if (sent != null && !advances_read_pointer((!) sent, message)) return;

        PendingDisplayedMarker? pending =
            pending_contact_markers[conversation];
        if (pending == null || advances_read_pointer(((!) pending).message,
                message)) {
            pending_contact_markers[conversation] =
                new PendingDisplayedMarker(message,
                    server_assist_candidate);
        }
        start_next_contact_marker.begin(conversation);
    }

    private async void start_next_contact_marker(Conversation conversation) {
        if (contact_marker_operations.is_active(conversation) ||
                !pending_contact_markers.has_key(conversation)) return;

        PendingDisplayedMarker pending =
            pending_contact_markers[conversation];
        pending_contact_markers.unset(conversation);
        Entities.Message message = pending.message;
        DisplayedMarkerTarget? target = get_xep0333_target(conversation,
            message);
        XmppStream? stream = stream_interactor.get_stream(
            conversation.account);
        if (target == null || stream == null) {
            if (pending.server_assist_candidate) {
                queue_device_sync(conversation, message);
            }
            return;
        }

        DisplayedStateSyncOwner? owner = sync_owners[conversation.account];
        DisplayedServerAssistTarget? assist_target =
            get_server_assist_target(conversation, message, (!) target);
        bool use_server_assist = pending.server_assist_candidate &&
            owner != null && assist_target != null &&
            ((!) owner).can_use_server_assist((!) stream);
        bool regular_fallback_queued = false;
        if (pending.server_assist_candidate && !use_server_assist) {
            // Capability or stream changed while this marker was pending.
            queue_device_sync(conversation, message);
            regular_fallback_queued = true;
        }

        uint64 operation_id = contact_marker_operations.begin(conversation);
        Xep.ChatMarkers.Module? marker_module = ((!) stream).get_module<
            Xep.ChatMarkers.Module>(Xep.ChatMarkers.Module.IDENTITY);
        Xep.MessageDisplayedSynchronization.Module? sync_module =
            ((!) stream).get_module<
                Xep.MessageDisplayedSynchronization.Module>(
                    Xep.MessageDisplayedSynchronization.Module.IDENTITY);
        if (marker_module == null) {
            if (pending.server_assist_candidate &&
                    !regular_fallback_queued) {
                queue_device_sync(conversation, message);
            }
            contact_marker_operations.finish(conversation, operation_id);
            return;
        }
        if (use_server_assist && sync_module == null) {
            queue_device_sync(conversation, message);
            use_server_assist = false;
        }

        bool sent;
        if (use_server_assist) {
            DisplayedServerAssistTarget assisted = (!) assist_target;
            sent = yield ((!) sync_module).send_server_assisted_displayed(
                (!) stream, assisted.chat, ((!) target).message_id,
                ((!) target).message_type, assisted.reference.id,
                assisted.reference.by);
        } else {
            sent = yield ((!) marker_module).send_displayed((!) stream,
                ((!) target).recipient, ((!) target).message_id,
                ((!) target).message_type);
        }

        if (!contact_marker_operations.finish(conversation,
                operation_id)) return;
        if (use_server_assist && !sent) {
            // A failed combined stanza must not drop private device state.
            queue_device_sync(conversation, message);
        }
        if (sent && stream_interactor.get_stream(conversation.account) ==
                stream) {
            Entities.Message? previous =
                last_contact_marker_sent[conversation];
            if (previous == null || advances_read_pointer((!) previous,
                    message)) {
                last_contact_marker_sent[conversation] = message;
            }
        }
        start_next_contact_marker.begin(conversation);
    }

    private bool may_use_server_assist(Conversation conversation,
            Entities.Message message, DisplayedMarkerTarget marker_target) {
        if (!device_sync_enabled()) return false;

        XmppStream? stream = stream_interactor.get_stream(
            conversation.account);
        DisplayedStateSyncOwner? owner = sync_owners[conversation.account];
        return stream != null && owner != null &&
            ((!) owner).can_use_server_assist((!) stream) &&
            get_server_assist_target(conversation, message,
                marker_target) != null;
    }

    internal static DisplayedServerAssistTarget? get_server_assist_target(
            Conversation conversation, Entities.Message message,
            DisplayedMarkerTarget marker_target) {
        // A MUC PM uses a full occupant JID as its PEP item id. Keep that
        // interop-sensitive scope on the already-tested regular PubSub path.
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) return null;

        Jid? chat = StableStanzaReferenceResolver.get_chat_item_id(
            conversation);
        StableStanzaReference? reference =
            StableStanzaReferenceResolver.for_message(conversation, message);
        if (chat == null || reference == null || !((!) chat).is_bare() ||
                !((!) chat).equals(marker_target.recipient.bare_jid)) {
            return null;
        }
        return new DisplayedServerAssistTarget((!) chat, (!) reference);
    }

    private void on_account_added(Account account) {
        var owner = new DisplayedStateSyncOwner(stream_interactor, account);
        owner.set_device_sync_enabled(device_sync_enabled());
        owner.contact_marker_received.connect(
                (bound_account, sender, message_id, stanza) => {
            on_displayed_received(bound_account, sender, message_id, stanza);
        });
        owner.device_item_received.connect((bound_account, item) => {
            try_apply_device_item(bound_account, item);
        });
        owner.catchup_ready.connect((bound_account, items) => {
            foreach (Xep.MessageDisplayedSynchronization.DisplayedItem item in
                    items) {
                try_apply_device_item(bound_account, item);
            }
        });
        sync_owners[account] = owner;
    }

    private void queue_device_sync(Conversation conversation,
            Entities.Message message) {
        if (!device_sync_enabled()) return;
        DisplayedStateSyncOwner? owner = sync_owners[conversation.account];
        if (owner == null) return;

        Jid? chat = StableStanzaReferenceResolver.get_chat_item_id(
            conversation);
        StableStanzaReference? reference =
            StableStanzaReferenceResolver.for_message(conversation, message);
        if (chat == null || reference == null) return;
        ((!) owner).queue_publication((!) chat, (!) reference, message);
    }

    private bool try_apply_device_item(Account account,
            Xep.MessageDisplayedSynchronization.DisplayedItem item) {
        if (!device_sync_enabled()) return false;
        Conversation.Type? type = get_xep0490_conversation_type(account,
            item);
        if (type == null) return false;

        Conversation? conversation = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY)
            .get_conversation(item.chat, account, (!) type);
        if (conversation == null) return false;

        Entities.Message? message = StableStanzaReferenceResolver.resolve(
            stream_interactor, (!) conversation, item.stanza_id, item.by);
        if (message == null || !advance_local_marker((!) conversation,
                (!) message)) {
            return false;
        }

        remote_read_state_advanced((!) conversation,
            ((!) conversation).read_up_to_item);
        return true;
    }

    internal static Conversation.Type? get_xep0490_conversation_type(
            Account account,
        Xep.MessageDisplayedSynchronization.DisplayedItem item) {
        if (item.chat.is_full()) {
            if (item.by.equals(account.bare_jid)) {
                return Conversation.Type.GROUPCHAT_PM;
            }
            return null;
        }

        // If chat and authority both equal our own bare JID, the item is
        // ambiguous between a self-chat and a room and must not cross scopes.
        if (item.chat.equals(account.bare_jid) &&
                item.by.equals(account.bare_jid)) {
            return null;
        }
        if (item.by.equals(account.bare_jid)) {
            return Conversation.Type.CHAT;
        }
        if (item.by.equals(item.chat)) {
            return Conversation.Type.GROUPCHAT;
        }
        return null;
    }

    private void on_displayed_received(Account account, Jid sender,
            string message_id, MessageStanza stanza) {
        Conversation? conversation = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY)
            .approx_conversation_for_stanza(stanza.from, stanza.to, account,
                stanza.type_);
        if (conversation == null) return;

        if (try_apply_marker((!) conversation, sender, message_id) ==
                DisplayedMarkerApplyResult.UNKNOWN_TARGET) {
            pending_contact_marker_receipts.offer((!) conversation, sender,
                message_id);
        }
    }

    private DisplayedMarkerApplyResult try_apply_marker(
            Conversation conversation, Jid sender,
            string message_id) {
        if (is_own_marker(conversation, sender)) {
            Entities.Message? message = find_own_marker_target(conversation,
                message_id);
            if (message == null) {
                // A room/nick can later be reused by another participant.
                // XEP-0333 requires an unknown groupchat target to be ignored;
                // never defer only the transient occupant address.
                return conversation.type_ == Conversation.Type.GROUPCHAT
                    ? DisplayedMarkerApplyResult.REJECTED
                    : DisplayedMarkerApplyResult.UNKNOWN_TARGET;
            }
            if (((!) message).direction !=
                    Entities.Message.DIRECTION_RECEIVED) {
                return DisplayedMarkerApplyResult.REJECTED;
            }

            advance_local_marker(conversation, (!) message);
            return DisplayedMarkerApplyResult.APPLIED;
        }

        // Keep groupchat markers in their participant-scoped store; never
        // fold one reader into the room-wide Message.Marked boolean.
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            MucManager muc_manager = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            Jid? reader = muc_manager.get_verified_private_muc_participant(
                conversation.account, conversation.counterpart, sender);
            if (reader == null || ((!) reader).equals_bare(
                    conversation.account.bare_jid) ||
                    muc_displayed_state_store == null) {
                return DisplayedMarkerApplyResult.REJECTED;
            }

            Entities.Message? groupchat_target =
                StableStanzaReferenceResolver.resolve(stream_interactor,
                    conversation, message_id,
                    conversation.counterpart.bare_jid);
            if (groupchat_target == null) {
                return DisplayedMarkerApplyResult.REJECTED;
            }
            if (((!) groupchat_target).direction !=
                    Entities.Message.DIRECTION_SENT) {
                return DisplayedMarkerApplyResult.REJECTED;
            }

            bool advanced = ((!) muc_displayed_state_store).advance(
                conversation, (!) reader, (!) groupchat_target);
            if (advanced) {
                received_message_displayed(conversation.account, sender,
                    (!) groupchat_target);
                groupchat_displayed_state_changed(conversation,
                    (!) groupchat_target);
            }
            return DisplayedMarkerApplyResult.APPLIED;
        }

        Entities.Message? message = stream_interactor.get_module<
            MessageStorage>(MessageStorage.IDENTITY)
            .get_message_by_sender_stanza_id(message_id, conversation,
                Entities.Message.DIRECTION_SENT);
        if (message == null) {
            return DisplayedMarkerApplyResult.UNKNOWN_TARGET;
        }

        received_message_displayed(conversation.account, sender, (!) message);
        stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY)
            .mark_sent_messages_read_through(conversation, (!) message);
        return DisplayedMarkerApplyResult.APPLIED;
    }

    private void replay_pending_contact_markers(Entities.Message message,
            Conversation conversation) {
        if (message.sender_stanza_id != null) {
            replay_pending_contact_marker_id(conversation,
                (!) message.sender_stanza_id);
        }
        if (message.stable_id != null &&
                message.stable_id != message.sender_stanza_id) {
            replay_pending_contact_marker_id(conversation,
                (!) message.stable_id);
        }
    }

    private void replay_pending_contact_marker_id(Conversation conversation,
            string message_id) {
        foreach (PendingMessageState pending in
                pending_contact_marker_receipts.take(conversation,
                    message_id)) {
            try_apply_marker(conversation, pending.sender,
                pending.message_id);
        }
    }

    private Entities.Message? find_own_marker_target(Conversation conversation,
            string message_id) {
        MessageStorage storage = stream_interactor.get_module<MessageStorage>(
            MessageStorage.IDENTITY);

        // Only a room groupchat uses the MUC-assigned XEP-0359 id. A MUC PM
        // is a type='chat' exchange and therefore references the sender id.
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            return StableStanzaReferenceResolver.resolve(stream_interactor,
                conversation, message_id, conversation.counterpart.bare_jid);
        }
        return storage.get_message_by_sender_stanza_id(message_id,
            conversation, Entities.Message.DIRECTION_RECEIVED);
    }

    private bool is_own_marker(Conversation conversation, Jid sender) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT &&
                conversation.account.bare_jid.equals_bare(sender)) {
            return true;
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            Jid? participant = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY).get_verified_private_muc_participant(
                    conversation.account, conversation.counterpart, sender);
            if (participant != null && ((!) participant).equals_bare(
                    conversation.account.bare_jid)) {
                return true;
            }
        }

        Jid? own_muc_jid = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY).get_own_jid(sender.bare_jid,
                conversation.account);
        return own_muc_jid != null && ((!) own_muc_jid).equals(sender);
    }

    public int get_groupchat_reader_count(Conversation conversation,
            Entities.Message message) {
        if (muc_displayed_state_store == null) return 0;
        return ((!) muc_displayed_state_store).get_reader_count(conversation,
            message);
    }

    internal static bool advances_read_pointer(Entities.Message? current,
            Entities.Message candidate) {
        return current == null || compare_messages(candidate, (!) current) > 0;
    }

    private bool advance_local_marker(Conversation conversation,
            Entities.Message message) {
        if (!advances_read_pointer(conversation.read_up_to, message)) {
            return false;
        }

        ContentItemStore content_store = stream_interactor.get_module<
            ContentItemStore>(ContentItemStore.IDENTITY);
        ContentItem? target_item = content_store.get_content_item_for_message(
            conversation, message);
        ContentItem? current_item = content_store.get_item_by_id(conversation,
            conversation.read_up_to_item);

        int read_up_to_item = conversation.read_up_to_item;
        if (target_item != null && (current_item == null ||
                ((!) current_item).compare((!) target_item) < 0)) {
            read_up_to_item = ((!) target_item).id;
        }
        conversation.set_read_state(message, read_up_to_item);
        return true;
    }

    private void reconcile_new_content_item(ContentItem item,
            Conversation conversation) {
        if (conversation.read_up_to == null) return;

        ContentItemStore store = stream_interactor.get_module<
            ContentItemStore>(ContentItemStore.IDENTITY);
        Entities.Message? item_message = store.get_message_for_content_item(
            conversation, item);
        if (item_message == null || compare_messages((!) item_message,
                (!) conversation.read_up_to) > 0) {
            return;
        }

        ContentItem? current = store.get_item_by_id(conversation,
            conversation.read_up_to_item);
        if (current != null && ((!) current).compare(item) >= 0) return;

        // The message pointer may arrive before an HTTP/Jingle FileItem.
        // Persist the pair again before NotificationEvents observes new_item.
        conversation.set_read_state((!) conversation.read_up_to, item.id);
    }

    internal static int compare_messages(Entities.Message left,
            Entities.Message right) {
        if (left.local_time != null && right.local_time != null) {
            int time_order = ((!) left.local_time).compare((!) right.local_time);
            if (time_order != 0) return time_order;
        }
        if (left.id == right.id) return 0;
        return left.id > right.id ? 1 : -1;
    }

    private void clear_account_state(Account account) {
        DisplayedStateSyncOwner? owner = sync_owners[account];
        if (owner != null) {
            ((!) owner).shutdown();
            sync_owners.unset(account);
        }

        ArrayList<Conversation> stale = new ArrayList<Conversation>();
        foreach (Conversation conversation in last_contact_marker_sent.keys) {
            if (conversation.account.equals(account)) stale.add(conversation);
        }
        foreach (Conversation conversation in pending_contact_markers.keys) {
            if (conversation.account.equals(account) &&
                    !stale.contains(conversation)) stale.add(conversation);
        }
        foreach (Conversation conversation in
                contact_marker_operations.snapshot()) {
            if (conversation.account.equals(account) &&
                    !stale.contains(conversation)) stale.add(conversation);
        }
        foreach (Conversation conversation in stale) {
            clear_conversation_state(conversation);
        }
        pending_contact_marker_receipts.clear_account(account);
    }

    private bool device_sync_enabled() {
        return settings.sync_displayed_state;
    }

    private void update_device_sync_setting() {
        bool enabled = device_sync_enabled();
        foreach (DisplayedStateSyncOwner owner in sync_owners.values) {
            owner.set_device_sync_enabled(enabled);
        }
    }

    private void clear_conversation_state(Conversation conversation) {
        last_contact_marker_sent.unset(conversation);
        pending_contact_markers.unset(conversation);
        contact_marker_operations.clear(conversation);
        pending_contact_marker_receipts.clear_conversation(conversation);
        if (muc_displayed_state_store != null) {
            ((!) muc_displayed_state_store).clear_conversation(conversation);
        }
    }
}

}
