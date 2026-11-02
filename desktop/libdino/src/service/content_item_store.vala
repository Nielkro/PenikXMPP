using Gee;

using Dino.Entities;
using Qlite;
using Xmpp;

namespace Dino {

public class ContentItemStore : StreamInteractionModule, Object {
    public static ModuleIdentity<ContentItemStore> IDENTITY = new ModuleIdentity<ContentItemStore>("content_item_store");
    public string id { get { return IDENTITY.id; } }

    public signal void new_item(ContentItem item, Conversation conversation);
    // A historical trust decision is a visibility change, not a new message.
    public signal void item_visibility_changed(ContentItem item, Conversation conversation, bool hidden);

    private StreamInteractor stream_interactor;
    private Database db;
    private HashMap<Conversation, ContentItemCollection> collection_conversations = new HashMap<Conversation, ContentItemCollection>(Conversation.hash_func, Conversation.equals_func);

    public static void start(StreamInteractor stream_interactor, Database db) {
        ContentItemStore m = new ContentItemStore(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    public ContentItemStore(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;

        stream_interactor.get_module<FileManager>(FileManager.IDENTITY).received_file.connect(insert_file_transfer);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).message_received.connect(announce_message);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).message_sent.connect(announce_message);
        stream_interactor.get_module<Calls>(Calls.IDENTITY).call_incoming.connect(insert_call);
        stream_interactor.get_module<Calls>(Calls.IDENTITY).call_outgoing.connect(insert_call);
    }

    internal ContentItemStore.for_tests(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
    }

    /** Apply a trust projection without treating history as a new message. */
    public void apply_trust_visibility(Account account, int item_id, bool hidden) throws Error {
        Row? row = db.content_item.select().with(db.content_item.id, "=", item_id)
            .single().iterator().get_next_checked();
        if (row == null) return;
        int conversation_id = ((!) row)[db.content_item.conversation_id];
        Row? owner = db.conversation.select().with(db.conversation.id, "=", conversation_id)
            .with(db.conversation.account_id, "=", account.id)
            .single().iterator().get_next_checked();
        if (owner == null) return;
        int64? cleared = ((!) owner)[db.conversation.history_cleared_at];
        if (!hidden && cleared != null && ((!) row)[db.content_item.time] < (!) cleared) return;
        Conversation? conversation = null;
        foreach (Conversation registered in collection_conversations.keys) {
            if (registered.id == conversation_id && registered.account.id == account.id) {
                conversation = registered;
                break;
            }
        }
        if (conversation == null) {
            ConversationManager? manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            if (manager != null) conversation = ((!) manager).get_conversation_by_id(conversation_id);
        }
        if (conversation != null) {
            ContentItem? item = get_item_by_id((!) conversation, item_id);
            if (item != null) set_item_hide_checked((!) item, hidden);
        } else {
            db.content_item.update().with(db.content_item.id, "=", item_id)
                .with(db.content_item.conversation_id, "=", conversation_id)
                .set(db.content_item.hide, hidden).perform_checked();
        }
    }

    public void init(Conversation conversation, ContentItemCollection item_collection) {
        collection_conversations[conversation] = item_collection;
    }

    public void uninit(Conversation conversation, ContentItemCollection item_collection) {
        collection_conversations.unset(conversation);
    }

    private Gee.List<ContentItem> get_items_from_query(QueryBuilder select, Conversation conversation) {
        Gee.TreeSet<ContentItem> items = new Gee.TreeSet<ContentItem>(ContentItem.compare_func);

        foreach (var row in select) {
            try {
                ContentItem content_item = get_item_from_row(row, conversation);
                items.add(content_item);
            } catch (GLib.Error e) {
                warning("Failed to get content item from row: %s", e.message);
            }
        }

        Gee.List<ContentItem> ret = new ArrayList<ContentItem>();
        foreach (ContentItem item in items) {
            ret.add(item);
        }
        return ret;
    }

    public ContentItem get_item_from_row(Row row, Conversation conversation) throws Error {
        int id = row[db.content_item.id];
        int content_type = row[db.content_item.content_type];
        int foreign_id = row[db.content_item.foreign_id];
        DateTime time = new DateTime.from_unix_utc(row[db.content_item.time]);
        return get_item(conversation, id, content_type, foreign_id, time);
    }

    private ContentItem get_item(Conversation conversation, int id, int content_type, int foreign_id, DateTime time) throws Error {
        switch (content_type) {
            case 1:
                Message? message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_id(foreign_id, conversation);
                if (message != null) {
                    var message_item = new MessageItem(message, conversation, id);
                    message_item.time = time; // In case of message corrections, the original time should be used
                    return message_item;
                }
                break;
            case 2:
                FileTransfer? file_transfer = stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY).get_file_by_id(foreign_id, conversation);
                if (file_transfer != null) {
                    Message? message = get_message_for_file_transfer(
                        conversation, (!) file_transfer);
                    var file_item = new FileItem(file_transfer, conversation, id, message);
                    return file_item;
                }
                break;
            case 3:
                Call? call = stream_interactor.get_module<CallStore>(CallStore.IDENTITY).get_call_by_id(foreign_id, conversation);
                if (call != null) {
                    var call_item = new CallItem(call, conversation, id);
                    return call_item;
                }
                break;
            default:
                warning("Unknown content item type: %i", content_type);
                break;
        }
        throw new Error(-1, 0, "Bad content type %i or non existing content item %i", content_type, foreign_id);
    }

    public ContentItem? get_item_by_foreign(Conversation conversation, int type, int foreign_id) {
        QueryBuilder select = db.content_item.select()
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.content_type, "=", type)
            .with(db.content_item.foreign_id, "=", foreign_id);

        Gee.List<ContentItem> item = get_items_from_query(select, conversation);

        return item.size > 0 ? item[0] : null;
    }

    public ContentItem? get_item_by_id(Conversation conversation, int id) {
        QueryBuilder select = db.content_item.select()
                .with(db.content_item.id, "=", id)
                .with(db.content_item.conversation_id, "=",
                    conversation.id);

        Gee.List<ContentItem> item = get_items_from_query(select, conversation);

        return item.size > 0 ? item[0] : null;
    }

    /** Resolve a fresh row-backed item for security-sensitive operations. */
    internal ContentItem? get_persisted_item_by_id(Conversation conversation,
            int id) {
        RowOption row = db.content_item.select()
            .with(db.content_item.id, "=", id)
            .with(db.content_item.conversation_id, "=", conversation.id)
            .single().row();
        if (!row.is_present()) return null;

        int content_type = row[db.content_item.content_type];
        int foreign_id = row[db.content_item.foreign_id];
        DateTime time = new DateTime.from_unix_utc(
            row[db.content_item.time]);
        if (content_type == 1) {
            Message? message = stream_interactor.get_module<MessageStorage>(
                MessageStorage.IDENTITY).get_persisted_message_by_id(
                    foreign_id, conversation);
            if (message == null) return null;
            var item = new MessageItem((!) message, conversation, id);
            item.time = time;
            return item;
        }
        if (content_type == 2) {
            FileTransfer? file_transfer = stream_interactor.get_module<
                FileTransferStorage>(FileTransferStorage.IDENTITY)
                .get_persisted_file_by_id(foreign_id, conversation);
            if (file_transfer == null) return null;
            Message? message = get_message_for_file_transfer(conversation,
                (!) file_transfer, true);
            return new FileItem((!) file_transfer, conversation, id, message);
        }
        return null;
    }

    /** Resolve a protocol reference atomically from one physical revision. */
    public bool try_get_message_reference_for_content_item(
            Conversation conversation, ContentItem content_item,
            out string? message_id, out Jid? sender) {
        message_id = null;
        sender = null;
        Message? message = get_message_for_content_item(conversation, content_item);
        if (message == null) return false;

        MessageStorage message_storage = stream_interactor
            .get_module<MessageStorage>(MessageStorage.IDENTITY);
        Gee.List<Message> revisions = message_storage.get_revision_chain(
            conversation, (!) message);
        if (revisions.is_empty) return false;
        Message reference_message = revisions[0];
        sender = reference_message.from;
        if (sender == null) return false;

        // XEP-0461 and XEP-0444 must not use a sender-controlled message id
        // in a groupchat.  The logical target of a corrected message remains
        // its original stanza. Select both id and sender from that same
        // physical root revision so a valid correction after a MUC nick or
        // direct-chat resource change cannot produce a mismatched tuple.
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            message_id = MessageStorage.get_groupchat_reference_id(
                reference_message, conversation);
        } else {
            message_id = MessageStorage.get_reference_id(reference_message);
        }
        if (message_id == null || ((!) message_id).strip().length == 0) {
            message_id = null;
            sender = null;
            return false;
        }
        return true;
    }

    public string? get_message_id_for_content_item(Conversation conversation,
            ContentItem content_item) {
        string? message_id;
        Jid? sender;
        return try_get_message_reference_for_content_item(conversation,
            content_item, out message_id, out sender) ? message_id : null;
    }

    public Message? get_message_for_content_item(Conversation conversation,
            ContentItem content_item, bool persisted_only = false) {
        FileItem? file_item = content_item as FileItem;
        if (file_item != null) {
            return get_message_for_file_transfer(conversation,
                ((!) file_item).file_transfer, persisted_only);
        }
        MessageItem? message_item = content_item as MessageItem;
        if (message_item != null) {
            return persisted_only
                ? stream_interactor.get_module<MessageStorage>(
                    MessageStorage.IDENTITY).get_persisted_message_by_id(
                        message_item.message.id, conversation)
                : message_item.message;
        }
        return null;
    }

    public ContentItem? get_content_item_for_message(Conversation conversation, Message message) {
        Row? row = get_content_item_row_for_message(conversation, message);

        if (row != null) {
            try {
                return get_item_from_row(row, conversation);
            } catch (GLib.Error e) {
                warning("Failed to get content item from row: %s", e.message);
                return null;
            }
        }
        return null;
    }

    public ContentItem? get_content_item_for_referencing_id(Conversation conversation, string referencing_id) {
        Message? message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_referencing_id(referencing_id, conversation);
        if (message == null) return null;

        Row? row = get_content_item_row_for_message(conversation, message);

        if (row != null) {
            try {
                return get_item_from_row(row, conversation);
            } catch (GLib.Error e) {
                warning("Failed to get content item from row: %s", e.message);
                return null;
            }
        }
        return null;
    }

    public int get_content_item_id_for_referencing_id(Conversation conversation, string referencing_id) {
        Message? message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_referencing_id(referencing_id, conversation);
        if (message == null) return -1;

        Row? row = get_content_item_row_for_message(conversation, message);
        if (row != null) {
            return row[db.content_item.id];
        }
        return -1;
    }

    public Row? get_content_item_row_for_message(Conversation conversation, Message message) {
        if (message.account.id != conversation.account.id ||
                message.type_ != Util.get_message_type_for_conversation(conversation)) {
            return null;
        }
        var content_item_row = db.content_item.select()
                .with(db.content_item.conversation_id, "=", conversation.id);

        RowOption file_transfer_row = db.file_transfer.select()
                .with(db.file_transfer.account_id, "=", conversation.account.id)
                .with(db.file_transfer.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
                .with(db.file_transfer.message_id, "=", message.id)
                .order_by(db.file_transfer.time, "DESC")
                .single().row();

        if (!file_transfer_row.is_present()) {
            foreach (int legacy_provider in new int[] {
                    FileManager.HTTP_PROVIDER_ID,
                    FileManager.SFS_PROVIDER_ID }) {
                file_transfer_row = db.file_transfer.select()
                        .with(db.file_transfer.account_id, "=", conversation.account.id)
                        .with(db.file_transfer.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
                        .with(db.file_transfer.info, "=", message.id.to_string())
                        .with(db.file_transfer.message_id, "<=", 0)
                        .with(db.file_transfer.provider, "=", legacy_provider)
                        .order_by(db.file_transfer.time, "DESC")
                        .single().row();
                if (file_transfer_row.is_present()) break;
            }
        }

        if (file_transfer_row.is_present()) {
            content_item_row.with(db.content_item.foreign_id, "=", file_transfer_row[db.file_transfer.id])
                    .with(db.content_item.content_type, "=", 2);
        } else {
            // Outgoing corrections move the row to a physical revision. Its
            // timestamp need not agree with the latest correction query, so
            // resolve the actual row from the sender-scoped persisted chain.
            Gee.List<Message> revisions = stream_interactor.get_module<
                MessageStorage>(MessageStorage.IDENTITY).get_revision_chain(
                    conversation, message, false, true);
            if (revisions.is_empty) return null;

            string[] placeholders = {};
            string[] revision_ids = {};
            foreach (Message revision in revisions) {
                placeholders += "?";
                revision_ids += revision.id.to_string();
            }
            content_item_row.with(db.content_item.content_type, "=", 1)
                .where("foreign_id IN (" + string.joinv(",", placeholders) + ")",
                    revision_ids);

            Row? matching_row = null;
            foreach (Row row in content_item_row) {
                if (matching_row != null) return null;
                matching_row = row;
            }
            return matching_row;
        }
        RowOption content_item_row_option = content_item_row.single().row();
        if (content_item_row_option.is_present()) {
            return content_item_row_option.inner;
        }
        return null;
    }

    public ContentItem? get_latest(Conversation conversation) {
        Gee.List<ContentItem> items = get_n_latest(conversation, 1);
        if (items.size > 0) {
            return items.get(0);
        }
        return null;
    }

    public Gee.List<ContentItem> get_n_latest(Conversation conversation, int count) {
        QueryBuilder select = db.content_item.select()
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.hide, "=", false)
            .order_by(db.content_item.time, "DESC")
            .order_by(db.content_item.id, "DESC")
            .limit(count);

        return get_items_from_query(select, conversation);
    }

    public Gee.List<ContentItem> get_before(Conversation conversation, ContentItem item, int count) {
        long time = (long) item.time.to_unix();
        QueryBuilder select = db.content_item.select()
            .where(@"time < ? OR (time = ? AND id < ?)", { time.to_string(), time.to_string(), item.id.to_string() })
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.hide, "=", false)
            .order_by(db.content_item.time, "DESC")
            .order_by(db.content_item.id, "DESC")
            .limit(count);

        return get_items_from_query(select, conversation);
    }

    public Gee.List<ContentItem> get_after(Conversation conversation, ContentItem item, int count) {
        long time = (long) item.time.to_unix();
        QueryBuilder select = db.content_item.select()
            .where(@"time > ? OR (time = ? AND id > ?)", { time.to_string(), time.to_string(), item.id.to_string() })
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.hide, "=", false)
            .order_by(db.content_item.time, "ASC")
            .order_by(db.content_item.id, "ASC")
            .limit(count);

        return get_items_from_query(select, conversation);
    }

    /** Skip classified non-mentions without loading their messages into UI. */
    internal Gee.List<ContentItem> get_unread_mention_candidates(
            Conversation conversation, ContentItem? cursor, int count,
            bool classified_mentions) {
        QueryBuilder select = db.content_item.select()
            .join_with<int>(db.message, db.message.id,
                db.content_item.foreign_id)
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.content_type, "=", 1)
            .with(db.content_item.hide, "=", false)
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=",
                (int) Util.get_message_type_for_conversation(conversation))
            .with(db.message.direction, "=", Message.DIRECTION_RECEIVED)
            .with(db.message.decryption_failed, "=", false)
            .with(db.message.mention_state, "=", (int) (classified_mentions
                ? Message.MentionState.MENTIONED : Message.MentionState.UNKNOWN))
            .order_by(db.content_item.time, "ASC")
            .order_by(db.content_item.id, "ASC")
            .limit(count);
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart == null) {
                select.with_null(db.message.counterpart_resource);
            } else {
                select.with(db.message.counterpart_resource, "=",
                    conversation.counterpart.resourcepart);
            }
        }
        if (cursor != null) {
            string time = ((!) cursor).time.to_unix().to_string();
            string id = ((!) cursor).id.to_string();
            select.where(@"content_item.time > ? OR (content_item.time = ? AND content_item.id > ?)",
                { time, time, id });
        }
        return get_items_from_query(select, conversation);
    }

    public Gee.List<ContentItem> get_items_older_than(Conversation conversation, DateTime cutoff_time, int limit = 500) {
        long cutoff_unix = (long) cutoff_time.to_unix();
        QueryBuilder select = db.content_item.select()
            .where("time < ?", { cutoff_unix.to_string() })
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.hide, "=", false)
            .order_by(db.content_item.time, "ASC")
            .limit(limit);

        return get_items_from_query(select, conversation);
    }

    public void insert_message(Message message, Conversation conversation, bool hide = false) {
        MessageItem item = new MessageItem(message, conversation, -1);
        item.id = db.add_content_item(conversation, message.time, message.local_time, 1, message.id, hide);
    }

    private void announce_message(Message message, Conversation conversation) {
        QueryBuilder select = db.content_item.select();
        select.with(db.content_item.foreign_id, "=", message.id);
        select.with(db.content_item.content_type, "=", 1);
        select.with(db.content_item.hide, "=", false);
        foreach (Row row in select) {
            MessageItem item = new MessageItem(message, conversation, row[db.content_item.id]);
            if (collection_conversations.has_key(conversation)) {
                collection_conversations.get(conversation).insert_item(item);
            }
            new_item(item, conversation);
            break;
        }
    }

    private void insert_file_transfer(FileTransfer file_transfer, Conversation conversation) {
        Message? message = get_message_for_file_transfer(conversation,
            file_transfer);
        FileItem item = new FileItem(file_transfer, conversation, -1,
            message);
        item.id = db.add_content_item(conversation, file_transfer.time, file_transfer.local_time, 2, file_transfer.id, false);
        if (collection_conversations.has_key(conversation)) {
            collection_conversations.get(conversation).insert_item(item);
        }
        new_item(item, conversation);
    }

    private Message? get_message_for_file_transfer(Conversation conversation,
            FileTransfer file_transfer, bool persisted_only = false) {
        int message_db_id = file_transfer.resolve_message_db_id();
        if (message_db_id <= 0) return null;
        if (!file_transfer.account.equals(conversation.account) ||
                !file_transfer.counterpart.equals_bare(
                    conversation.counterpart) ||
                (conversation.type_ == Conversation.Type.GROUPCHAT_PM &&
                    !file_transfer.counterpart.equals(
                        conversation.counterpart))) {
            return null;
        }

        MessageStorage message_storage = stream_interactor.get_module<
            MessageStorage>(MessageStorage.IDENTITY);
        Message? message = persisted_only
            ? message_storage.get_persisted_message_by_id(message_db_id,
                conversation)
            : message_storage.get_message_by_id(message_db_id, conversation);
        if (message == null || ((!) message).direction !=
                file_transfer.direction || ((!) message).from == null ||
                file_transfer.from == null ||
                !((!) message).from.equals((!) file_transfer.from)) {
            return null;
        }
        return message;
    }

    /** Return every visible file row backed by the same physical message. */
    internal Gee.List<FileItem> get_file_items_for_message(
            Conversation conversation, Message message) {
        var items = new ArrayList<FileItem>();
        var seen_transfer_ids = new HashSet<int>();

        var explicit_query = db.file_transfer.select({db.file_transfer.id})
            .with(db.file_transfer.account_id, "=", conversation.account.id)
            .with(db.file_transfer.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.file_transfer.message_id, "=", message.id);
        collect_file_items_for_message(conversation, message, explicit_query,
            seen_transfer_ids, items);

        foreach (int legacy_provider in new int[] {
                FileManager.HTTP_PROVIDER_ID,
                FileManager.SFS_PROVIDER_ID }) {
            var legacy_query = db.file_transfer.select({db.file_transfer.id})
                .with(db.file_transfer.account_id, "=",
                    conversation.account.id)
                .with(db.file_transfer.counterpart_id, "=",
                    db.get_jid_id(conversation.counterpart))
                .with(db.file_transfer.message_id, "<=", 0)
                .with(db.file_transfer.provider, "=", legacy_provider)
                .with(db.file_transfer.info, "=", message.id.to_string());
            collect_file_items_for_message(conversation, message,
                legacy_query, seen_transfer_ids, items);
        }
        return items;
    }

    private void collect_file_items_for_message(Conversation conversation,
            Message message, QueryBuilder transfer_query,
            HashSet<int> seen_transfer_ids, ArrayList<FileItem> items) {
        foreach (Row transfer_row in transfer_query) {
            int transfer_id = transfer_row[db.file_transfer.id];
            if (seen_transfer_ids.contains(transfer_id)) continue;

            RowOption item_row = db.content_item.select()
                .with(db.content_item.conversation_id, "=", conversation.id)
                .with(db.content_item.content_type, "=", 2)
                .with(db.content_item.foreign_id, "=", transfer_id)
                .with(db.content_item.hide, "=", false)
                .single().row();
            if (!item_row.is_present()) continue;

            try {
                FileItem? file_item = get_item_from_row(
                    item_row.inner, conversation) as FileItem;
                if (file_item == null) continue;
                Message? related = get_message_for_file_transfer(conversation,
                    ((!) file_item).file_transfer);
                if (related == null || ((!) related).id != message.id) continue;
                seen_transfer_ids.add(transfer_id);
                items.add((!) file_item);
            } catch (Error e) {
                warning("Failed to resolve related file item: %s", e.message);
            }
        }
    }

    private void insert_call(Call call, CallState call_state, Conversation conversation) {
        insert_replayed_call(call, conversation);
    }

    /** Insert a completed archive projection without creating a live CallState. */
    internal void insert_replayed_call(Call call, Conversation conversation) {
        RowOption existing = db.content_item.select()
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.content_type, "=", 3)
            .with(db.content_item.foreign_id, "=", call.id)
            .single().row();
        if (existing.is_present()) return;

        CallItem item = new CallItem(call, conversation, -1);
        item.id = db.add_content_item(conversation, call.time, call.local_time, 3, call.id, false);
        if (collection_conversations.has_key(conversation)) {
            collection_conversations.get(conversation).insert_item(item);
        }
        new_item(item, conversation);
    }

    public void set_item_hide(ContentItem content_item, bool hide) {
        try { set_item_hide_checked(content_item, hide); }
        catch (Error e) { warning("Could not update content item visibility: %s", e.message); }
    }

    public void set_item_hide_checked(ContentItem content_item, bool hide) throws Error {
        Conversation? conversation = null;
        if (content_item is MessageItem) conversation = ((MessageItem) content_item).conversation;
        else if (content_item is FileItem) conversation = ((FileItem) content_item).conversation;
        else if (content_item is CallItem) conversation = ((CallItem) content_item).conversation;
        if (conversation == null) throw new IOError.INVALID_ARGUMENT("Content item has no conversation");
        Row? row = db.content_item.select().with(db.content_item.id, "=", content_item.id)
            .with(db.content_item.conversation_id, "=", ((!) conversation).id)
            .single().iterator().get_next_checked();
        if (row == null) throw new IOError.NOT_FOUND("Content item is no longer in this conversation");
        if (((!) row)[db.content_item.hide] == hide) return;
        if (!hide && ((!) conversation).history_cleared_at != null &&
                content_item.time.compare(((!) conversation).history_cleared_at) < 0) return;
        db.content_item.update().with(db.content_item.id, "=", content_item.id)
            .with(db.content_item.conversation_id, "=", ((!) conversation).id)
            .set(db.content_item.hide, hide).perform_checked();
        if (db.changes() != 1) throw new IOError.NOT_FOUND("Content item changed while updating visibility");
        item_visibility_changed(content_item, (!) conversation, hide);
    }

}

public interface ContentItemCollection : Object {
    public abstract void insert_item(ContentItem item);
    public abstract void remove_item(ContentItem item);
}

public abstract class ContentItem : Object {
    public int id { get; set; }
    public string type_ { get; set; }
    public Jid jid { get; set; }
    public DateTime time { get; set; }
    public Encryption encryption { get; set; }
    public Entities.Message.Marked mark { get; set; }

    ContentItem(int id, string ty, Jid jid, DateTime time, Encryption encryption, Entities.Message.Marked mark) {
        this.id = id;
        this.type_ = ty;
        this.jid = jid;
        this.time = time;
        this.encryption = encryption;
        this.mark = mark;
    }

    public static bool is_own(ContentItem content_item) {
        if (content_item is MessageItem) {
            return ((MessageItem) content_item).message.direction == Entities.Message.DIRECTION_SENT;
        } else if (content_item is FileItem) {
            return ((FileItem) content_item).file_transfer.direction == FileTransfer.DIRECTION_SENT;
        }
        return false;
    }

    public int compare(ContentItem c) {
        return compare_func(this, c);
    }

    public static int compare_func(ContentItem a, ContentItem b) {
        int res = a.time.compare(b.time);
        if (res == 0) {
            res = a.id > b.id ? 1 : (a.id < b.id ? -1 : 0);
        }
        return res;
    }
}

public class MessageItem : ContentItem {
    public const string TYPE = "message";

    public Message message;
    public Conversation conversation;
    private Binding? mark_binding = null;

    public MessageItem(Message message, Conversation conversation, int id) {
        base(id, TYPE, message.from, message.time, message.encryption, message.marked);

        this.message = message;
        this.conversation = conversation;
        mark_binding = message.bind_property("marked", this, "mark");
    }

    public override void dispose() {
        if (mark_binding != null) { mark_binding.unbind(); mark_binding = null; }
        base.dispose();
    }
}

public class FileItem : ContentItem {
    public const string TYPE = "file";

    public FileTransfer file_transfer;
    public Conversation conversation;
    private Binding? encryption_binding = null;
    private Binding? mark_binding = null;
    private Binding? state_binding = null;

    public FileItem(FileTransfer file_transfer, Conversation conversation, int id, Message? message = null) {
        Entities.Message.Marked mark = Entities.Message.Marked.NONE;
        if (message != null) {
            mark = message.marked;
        } else if (file_transfer.direction == FileTransfer.DIRECTION_SENT) {
            mark = file_to_message_state(file_transfer.state);
        }
        base(id, TYPE, file_transfer.from, file_transfer.time, file_transfer.encryption, mark);

        this.file_transfer = file_transfer;
        this.conversation = conversation;

        // Keep encryption icon in sync when the file decryptor updates
        // the encryption after download (e.g. PGP file decryption)
        encryption_binding = file_transfer.bind_property("encryption", this, "encryption");

        // TODO those don't work
        if (message != null) {
            mark_binding = message.bind_property("marked", this, "mark");
        } else if (file_transfer.direction == FileTransfer.DIRECTION_SENT) {
            state_binding = file_transfer.bind_property("state", this, "mark", BindingFlags.DEFAULT, (_, from_value, ref to_value) => {
                to_value = file_to_message_state((FileTransfer.State)from_value.get_enum());
                return true;
            });
        }
    }

    public override void dispose() {
        if (encryption_binding != null) { encryption_binding.unbind(); encryption_binding = null; }
        if (mark_binding != null) { mark_binding.unbind(); mark_binding = null; }
        if (state_binding != null) { state_binding.unbind(); state_binding = null; }
        base.dispose();
    }

    private static Entities.Message.Marked file_to_message_state(FileTransfer.State state) {
        switch (state) {
            case FileTransfer.State.IN_PROGRESS:
                return Entities.Message.Marked.UNSENT;
            case FileTransfer.State.COMPLETE:
                return Entities.Message.Marked.NONE;
            case FileTransfer.State.NOT_STARTED:
                return Entities.Message.Marked.UNSENT;
            case FileTransfer.State.FAILED:
                return Entities.Message.Marked.WONTSEND;
        }
        assert_not_reached();
    }
}

public class CallItem : ContentItem {
    public const string TYPE = "call";

    public Call call;
    public Conversation conversation;
    private Binding? encryption_binding = null;

    public CallItem(Call call, Conversation conversation, int id) {
        base(id, TYPE, call.proposer, call.time, call.encryption, Message.Marked.NONE);

        this.call = call;
        this.conversation = conversation;

        encryption_binding = call.bind_property("encryption", this, "encryption");
    }

    public override void dispose() {
        if (encryption_binding != null) { encryption_binding.unbind(); encryption_binding = null; }
        base.dispose();
    }
}

}
