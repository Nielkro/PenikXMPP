using Gee;
using Qlite;

using Xmpp;
using Xmpp.Xep;
using Dino.Entities;

public class Dino.Replies : StreamInteractionModule, Object {
    public static ModuleIdentity<Replies> IDENTITY = new ModuleIdentity<Replies>("reply");
    public string id { get { return IDENTITY.id; } }

    private StreamInteractor stream_interactor;
    private Database db;

    private ReceivedMessageListener received_message_listener;

    public static void start(StreamInteractor stream_interactor, Database db) {
        Replies m = new Replies(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    private Replies(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.received_message_listener = new ReceivedMessageListener(stream_interactor, this);

        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(received_message_listener);
    }

    internal Replies.for_tests(StreamInteractor stream_interactor,
            Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.received_message_listener = new ReceivedMessageListener(
            stream_interactor, this);
    }

    /**
     * Return the currently known direct reply rows for one ContentItem.
     *
     * The lookup is deliberately scoped by conversation_id and maps only the
     * physical message that currently backs a logical ContentItem. Thus reply
     * rows left behind by an old correction revision or a deleted message do
     * not duplicate or leak into the result.
     */
    public Gee.List<ContentItem> get_direct_replies(
            Conversation conversation, ContentItem quoted_content_item,
            bool include_hidden = false) {
        var replies = new ArrayList<ContentItem>();
        if (!content_item_is_in_conversation(conversation,
                quoted_content_item.id)) {
            return replies;
        }

        var seen_content_item_ids = new HashSet<int>();
        var authoritative_reply_message_ids = new HashMap<int, int>();
        var sorted_replies = new TreeSet<ContentItem>(ContentItem.compare_func);
        ContentItemStore? content_item_store = stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        if (content_item_store == null) return replies;

        foreach (Row reply_row in db.reply.select()
                .with(db.reply.quoted_content_item_id, "=",
                    quoted_content_item.id)) {
            int reply_message_id = reply_row[db.reply.message_id];
            Row? content_item_row = get_current_content_item_row_for_message(
                conversation, reply_message_id, include_hidden);
            if (content_item_row == null) continue;

            int content_item_id = ((!) content_item_row)[db.content_item.id];
            if (content_item_id == quoted_content_item.id ||
                    seen_content_item_ids.contains(content_item_id)) {
                continue;
            }

            int authoritative_message_id;
            if (authoritative_reply_message_ids.has_key(content_item_id)) {
                authoritative_message_id =
                    authoritative_reply_message_ids[content_item_id];
            } else {
                authoritative_message_id =
                    get_authoritative_reply_message_id(conversation,
                        (!) content_item_row, reply_message_id);
                authoritative_reply_message_ids[content_item_id] =
                    authoritative_message_id;
            }
            if (authoritative_message_id != reply_message_id) continue;

            try {
                ContentItem item = ((!) content_item_store).get_item_from_row(
                    (!) content_item_row, conversation);
                seen_content_item_ids.add(content_item_id);
                sorted_replies.add(item);
            } catch (GLib.Error e) {
                warning("Failed to materialize direct reply content item %i: %s",
                    content_item_id, e.message);
            }
        }

        replies.add_all(sorted_replies);
        return replies;
    }

    /** Compare a caller snapshot with the currently visible direct replies. */
    public bool direct_reply_snapshot_matches(Conversation conversation,
            ContentItem quoted_content_item,
            Gee.List<ContentItem> expected_replies) {
        Gee.List<ContentItem> current = get_direct_replies(conversation,
            quoted_content_item);
        if (current.size != expected_replies.size) return false;
        for (int i = 0; i < current.size; i++) {
            if (current[i].id != expected_replies[i].id) return false;
        }
        return true;
    }

    /**
     * Select the reply edge that currently belongs to a corrected logical
     * message.  A correction may omit XEP-0461, in which case the newest
     * historical edge is inherited.  If a later correction carries its own
     * reply payload, that edge is authoritative and the message must not
     * remain attached to both the old and the new parent.
     */
    private int get_authoritative_reply_message_id(
            Conversation conversation, Row current_content_item_row,
            int candidate_message_id) {
        if (current_content_item_row[db.content_item.content_type] != 1) {
            return candidate_message_id;
        }

        MessageStorage? message_storage = stream_interactor
            .get_module<MessageStorage>(MessageStorage.IDENTITY);
        if (message_storage == null) return 0;

        int current_message_id =
            current_content_item_row[db.content_item.foreign_id];
        Message? current_message = ((!) message_storage)
            .get_message_by_id(current_message_id, conversation);
        if (current_message == null) return 0;

        // An orphaned correction can still carry a complete, sender-checked
        // XEP-0461 edge of its own.  The stricter retraction-chain helper
        // intentionally returns an empty list when its original is missing;
        // that must not make the current reply disappear from reverse lookup.
        if (db.reply.select({db.reply.message_id})
                .with(db.reply.message_id, "=", current_message_id)
                .count() > 0) {
            return current_message_id;
        }

        Gee.List<Message> revisions = ((!) message_storage)
            .get_revision_chain(conversation, (!) current_message, false);
        for (int i = revisions.size - 1; i >= 0; i--) {
            if (db.reply.select({db.reply.message_id})
                    .with(db.reply.message_id, "=", revisions[i].id)
                    .count() > 0) {
                return revisions[i].id;
            }
        }
        return 0;
    }

    internal static bool reply_target_sender_matches(
            Conversation.Type conversation_type, Jid declared_sender,
            Jid actual_sender) {
        if (conversation_type == Conversation.Type.CHAT) {
            return declared_sender.resourcepart == null
                ? declared_sender.equals_bare(actual_sender)
                : declared_sender.equals(actual_sender);
        }
        return declared_sender.equals(actual_sender);
    }

    internal void process_incoming_for_tests(Entities.Message message,
            Xmpp.MessageStanza stanza, Conversation conversation) {
        on_incoming_message(message, stanza, conversation);
    }

    /**
     * Repair reply state for a stanza that was deduplicated before the normal
     * Replies listener. Existing metadata belongs to the already stored
     * immutable stanza and must not be replaced by a conflicting replay.
     */
    internal void process_duplicate_message(Entities.Message message,
            Xmpp.MessageStanza stanza, Conversation conversation) {
        resolve_pending_replies_to(message, conversation);
        if (db.reply.select({db.reply.message_id})
                .with(db.reply.message_id, "=", message.id)
                .count() > 0) {
            resolve_stored_reply_reference(message, conversation);
            return;
        }
        on_incoming_message(message, stanza, conversation);
    }

    private void on_incoming_message(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
        resolve_pending_replies_to(message, conversation);

        // Handle if this message is a reply
        Xep.Replies.ReplyTo? reply_to = Xep.Replies.get_reply_to(stanza);
        if (reply_to == null) return;

        // Persist the wire reference even when the parent is not in the local
        // cache yet. MAM frequently delivers a reply before its target.
        message.set_quoted_reference(reply_to.to_message_id,
            reply_to.to_jid);

        resolve_stored_reply_reference(message, conversation);
    }

    /** Resolve one already persisted raw id+sender edge, if unambiguous. */
    private void resolve_stored_reply_reference(Entities.Message message,
            Conversation conversation) {
        RowOption reply_row = db.reply.select()
            .with(db.reply.message_id, "=", message.id)
            .single().row();
        if (!reply_row.is_present() ||
                reply_row.get(db.reply.quoted_content_item_id, 0) > 0) {
            return;
        }
        string? target_id = reply_row.inner[
            db.reply.quoted_message_stanza_id];
        string? declared_sender_str = reply_row.inner[
            db.reply.quoted_message_from];
        if (target_id == null || declared_sender_str == null) return;

        Jid declared_sender;
        try {
            declared_sender = new Jid((!) declared_sender_str);
        } catch (InvalidJidError e) {
            return;
        }

        ContentItem? quoted_content_item = find_reply_target(
            conversation, (!) target_id, declared_sender);
        if (quoted_content_item == null) return;

        if (!content_item_is_in_conversation(conversation,
                ((!) quoted_content_item).id)) {
            return;
        }

        Row? reply_content_item_row = get_current_content_item_row_for_message(
            conversation, message.id, true);
        if (reply_content_item_row != null &&
                ((!) reply_content_item_row)[db.content_item.id] ==
                    ((!) quoted_content_item).id) {
            return;
        }

        message.set_quoted_item(((!) quoted_content_item).id,
            (!) target_id, declared_sender);
    }

    /**
     * Resolve every locally matching id candidate before applying the XEP-0461
     * declared-author fence. Message IDs are sender scoped and can collide;
     * taking MessageStorage's newest `.single()` first would let an unrelated
     * later row permanently shadow the correct, already present parent.
     */
    private ContentItem? find_reply_target(Conversation conversation,
            string target_id, Jid declared_sender) {
        bool ambiguous;
        if (conversation.type_ == Conversation.Type.CHAT) {
            ContentItem? by_stanza = find_reply_target_by_id_column(
                conversation, target_id, declared_sender, false,
                out ambiguous);
            if (ambiguous || by_stanza != null) return by_stanza;
            return find_reply_target_by_id_column(conversation, target_id,
                declared_sender, true, out ambiguous);
        }

        ContentItem? by_server = find_reply_target_by_id_column(
            conversation, target_id, declared_sender, true, out ambiguous);
        if (ambiguous || by_server != null) return by_server;
        return find_reply_target_by_id_column(conversation, target_id,
            declared_sender, false, out ambiguous);
    }

    private ContentItem? find_reply_target_by_id_column(
            Conversation conversation, string target_id,
            Jid declared_sender, bool use_server_id, out bool ambiguous) {
        ambiguous = false;
        ContentItemStore? content_item_store = stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        MessageStorage? message_storage = stream_interactor
            .get_module<MessageStorage>(MessageStorage.IDENTITY);
        if (content_item_store == null || message_storage == null) return null;

        var candidates = db.message.select({db.message.id})
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=",
                (int) Util.get_message_type_for_conversation(conversation))
            .order_by(db.message.time, "DESC");
        if (use_server_id) {
            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                candidates.where("((message.stable_id = ? AND message.stable_id_by = ?) OR ((message.stable_id IS NULL OR message.stable_id_by IS NULL) AND message.server_id = ?))",
                    { target_id,
                      conversation.counterpart.bare_jid.to_string(),
                      target_id });
            } else {
                candidates.with(db.message.server_id, "=", target_id);
            }
        } else {
            candidates.with(db.message.stanza_id, "=", target_id);
        }
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart != null) {
                candidates.with(db.message.counterpart_resource, "=",
                    conversation.counterpart.resourcepart);
            } else {
                candidates.with_null(db.message.counterpart_resource);
            }
        }

        int matching_physical_candidates = 0;
        var seen_content_item_ids = new HashSet<int>();
        ContentItem? matching_item = null;
        foreach (Row candidate_row in candidates) {
            Message? candidate_message = ((!) message_storage)
                .get_message_by_id(candidate_row[db.message.id],
                    conversation);
            if (candidate_message == null) continue;
            Jid? candidate_sender = ((!) candidate_message).from;
            if (candidate_sender == null ||
                    !reply_target_sender_matches(conversation.type_,
                        declared_sender, (!) candidate_sender)) {
                continue;
            }
            matching_physical_candidates++;
            if (matching_physical_candidates > 1) {
                // The reference names one physical stanza. Even if multiple
                // colliding rows currently project onto the same corrected
                // ContentItem, choosing one would make the id/sender tuple
                // ambiguous and could attach the reply to the wrong chain.
                ambiguous = true;
                return null;
            }
            ContentItem? candidate_item = ((!) content_item_store)
                .get_content_item_for_message(conversation,
                    (!) candidate_message);
            if (candidate_item == null ||
                    seen_content_item_ids.contains(((!) candidate_item).id) ||
                    !content_item_is_in_conversation(conversation,
                        ((!) candidate_item).id)) {
                continue;
            }
            seen_content_item_ids.add(((!) candidate_item).id);
            if (matching_item != null &&
                    ((!) matching_item).id != ((!) candidate_item).id) {
                // Message IDs are scoped by sender, but a malicious or
                // corrupted archive can still contain a collision within
                // that scope. Do not guess which logical item was meant.
                ambiguous = true;
                return null;
            }
            matching_item = candidate_item;
        }
        return matching_item;
    }

    internal void resolve_pending_replies_to(Entities.Message target_message,
            Conversation conversation) {
        ContentItemStore? content_item_store = stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        MessageStorage? message_storage = stream_interactor
            .get_module<MessageStorage>(MessageStorage.IDENTITY);
        if (content_item_store == null || message_storage == null) return;

        ContentItem? target_item = ((!) content_item_store)
            .get_content_item_for_message(conversation, target_message);
        if (target_item == null && target_message.edit_to == null) {
            // A duplicate physical root still has to invalidate earlier reply
            // links even when its logical correction chain is ambiguous.
            Message? stored_target = ((!) message_storage)
                .get_persisted_message_by_id(target_message.id, conversation);
            if (stored_target != null && stored_target.edit_to == null) {
                target_item = ((!) content_item_store).get_item_by_foreign(
                    conversation, 1, stored_target.id);
            }
        }
        if (target_item == null || !content_item_is_in_conversation(
                conversation, ((!) target_item).id)) {
            return;
        }

        var target_ids = new HashSet<string>();
        add_nonempty_id(target_ids, target_message.stanza_id);
        add_nonempty_id(target_ids,
            conversation.type_ == Conversation.Type.GROUPCHAT
                ? MessageStorage.get_groupchat_reference_id(target_message,
                    conversation) : target_message.server_id);
        add_nonempty_id(target_ids, target_message.edit_to);
        var seen_reply_message_ids = new HashSet<int>();

        foreach (string target_id in target_ids) {
            foreach (Row reply_row in db.reply.select()
                    .with(db.reply.quoted_message_stanza_id, "=", target_id)) {
                int reply_message_id = reply_row[db.reply.message_id];
                if (seen_reply_message_ids.contains(reply_message_id)) continue;
                seen_reply_message_ids.add(reply_message_id);

                if (!message_is_in_conversation(conversation,
                        reply_message_id)) {
                    continue;
                }

                string? declared_sender_str =
                    reply_row[db.reply.quoted_message_from];
                if (declared_sender_str == null) continue;

                Jid declared_sender;
                try {
                    declared_sender = new Jid((!) declared_sender_str);
                } catch (InvalidJidError e) {
                    continue;
                }
                // Only the physical message currently backing a logical item
                // may contribute an edge. Old correction rows and orphan rows
                // remain harmless historical data.
                Row? reply_item_row = get_current_content_item_row_for_message(
                    conversation, reply_message_id, true);
                if (reply_item_row == null ||
                        ((!) reply_item_row)[db.content_item.id] ==
                            ((!) target_item).id) {
                    continue;
                }

                Message? reply_message = ((!) message_storage)
                    .get_message_by_id(reply_message_id, conversation);
                if (reply_message != null) {
                    ContentItem? resolved_target = find_reply_target(
                        conversation, target_id, declared_sender);
                    if (resolved_target == null ||
                            ((!) resolved_target).id !=
                                ((!) target_item).id) {
                        // A second same-sender/id collision can arrive after
                        // an earlier candidate was tentatively linked. Restore
                        // the raw edge and fail closed instead of silently
                        // moving the reply between logical messages.
                        ((!) reply_message).set_quoted_reference(target_id,
                            declared_sender);
                        continue;
                    }
                    ((!) reply_message).set_quoted_item(
                        ((!) target_item).id, target_id, declared_sender);
                }
            }
        }
    }

    private static void add_nonempty_id(Set<string> ids, string? id) {
        if (id != null && ((!) id).strip().length > 0) {
            ids.add((!) id);
        }
    }

    private bool content_item_is_in_conversation(Conversation conversation,
            int content_item_id) {
        return db.content_item.select({db.content_item.id})
            .with(db.content_item.id, "=", content_item_id)
            .with(db.content_item.conversation_id, "=", conversation.id)
            .count() == 1;
    }

    private bool message_is_in_conversation(Conversation conversation,
            int message_id) {
        var query = db.message.select({db.message.id})
            .with(db.message.id, "=", message_id)
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=",
                (int) Util.get_message_type_for_conversation(conversation));
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart != null) {
                query.with(db.message.counterpart_resource, "=",
                    conversation.counterpart.resourcepart);
            } else {
                query.with_null(db.message.counterpart_resource);
            }
        }
        return query.count() == 1;
    }

    private Row? get_current_content_item_row_for_message(
            Conversation conversation, int message_id, bool include_hidden) {
        if (!message_is_in_conversation(conversation, message_id)) return null;

        // File messages are represented by their FileItem, not by a stale or
        // hidden MessageItem row. Prefer the explicit relation and retain the
        // numeric transport-info lookup for rows written before version 51.
        Row? file_item_row = find_file_item_row_for_message(conversation,
            message_id, include_hidden, false);
        if (file_item_row != null) return file_item_row;
        file_item_row = find_file_item_row_for_message(conversation,
            message_id, include_hidden, true);
        if (file_item_row != null) return file_item_row;

        var message_item_query = db.content_item.select()
            .with(db.content_item.conversation_id, "=", conversation.id)
            .with(db.content_item.content_type, "=", 1)
            .with(db.content_item.foreign_id, "=", message_id);
        if (!include_hidden) {
            message_item_query.with(db.content_item.hide, "=", false);
        }
        RowOption exact_message_item = message_item_query.single().row();
        if (exact_message_item.is_present()) {
            return exact_message_item.inner;
        }

        // XEP-0308 corrections are independent physical messages, and a
        // client is not required to repeat the XEP-0461 payload on every
        // correction.  The reply edge may therefore live on an older
        // revision while the logical ContentItem points at the newest one.
        // Resolve the historical revision through ContentItemStore, then
        // re-apply the conversation/visibility fence to the current row.
        ContentItemStore? content_item_store = stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        MessageStorage? message_storage = stream_interactor
            .get_module<MessageStorage>(MessageStorage.IDENTITY);
        if (content_item_store == null || message_storage == null) return null;

        Message? historical_message = ((!) message_storage)
            .get_message_by_id(message_id, conversation);
        if (historical_message == null) return null;
        Row? current_row = ((!) content_item_store)
            .get_content_item_row_for_message(conversation,
                (!) historical_message);
        if (current_row == null ||
                ((!) current_row)[db.content_item.conversation_id] !=
                    conversation.id ||
                ((!) current_row)[db.content_item.content_type] != 1 ||
                (!include_hidden &&
                    ((!) current_row)[db.content_item.hide])) {
            return null;
        }
        return current_row;
    }

    private Row? find_file_item_row_for_message(Conversation conversation,
            int message_id, bool include_hidden, bool legacy_info) {
        var file_query = db.file_transfer.select({
                db.file_transfer.id, db.file_transfer.provider })
            .with(db.file_transfer.account_id, "=", conversation.account.id)
            .with(db.file_transfer.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .order_by(db.file_transfer.id, "DESC");
        if (legacy_info) {
            file_query.with(db.file_transfer.info, "=",
                message_id.to_string())
                .with(db.file_transfer.message_id, "<=", 0);
        } else {
            file_query.with(db.file_transfer.message_id, "=", message_id);
        }
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart != null) {
                file_query.with(db.file_transfer.counterpart_resource, "=",
                    conversation.counterpart.resourcepart);
            } else {
                file_query.with_null(db.file_transfer.counterpart_resource);
            }
        }
        foreach (Row file_row in file_query) {
            if (legacy_info &&
                    file_row[db.file_transfer.provider] !=
                        FileManager.HTTP_PROVIDER_ID &&
                    file_row[db.file_transfer.provider] !=
                        FileManager.SFS_PROVIDER_ID) {
                continue;
            }
            var content_query = db.content_item.select()
                .with(db.content_item.conversation_id, "=", conversation.id)
                .with(db.content_item.content_type, "=", 2)
                .with(db.content_item.foreign_id, "=",
                    file_row[db.file_transfer.id]);
            if (!include_hidden) {
                content_query.with(db.content_item.hide, "=", false);
            }
            RowOption file_item_row = content_query.single().row();
            if (file_item_row.is_present()) return file_item_row.inner;
        }
        return null;
    }

    private class ReceivedMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "STORE", "STORE_CONTENT_ITEM" };
        public override string action_group { get { return "Quote"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private Replies outer;

        public ReceivedMessageListener(StreamInteractor stream_interactor, Replies outer) {
            this.outer = outer;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            outer.on_incoming_message(message, stanza, conversation);
            return false;
        }
    }
}

namespace Dino {
    public string message_body_without_reply_fallback(Message message) {
        string body = message.body;
        foreach (var fallback in message.get_fallbacks()) {
            if (fallback.ns_uri == Xep.Replies.NS_URI && message.quoted_item_id > 0) {
                if (fallback.locations.size == 0) {
                    continue;
                }

                int from_char = fallback.locations[0].from_char;
                int to_char = fallback.locations[0].to_char;
                if (from_char < 0 || to_char < 0 || to_char < from_char) {
                    continue;
                }

                int from_idx = body.index_of_nth_char(from_char);
                int to_idx = body.index_of_nth_char(to_char);
                if (from_idx < 0 || to_idx < 0 || from_idx > body.length || to_idx > body.length) {
                    continue;
                }

                body = body[0:from_idx] + body[to_idx:body.length];
            }
        }
        return body;
    }
}
