/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Xmpp;
using Gee;
using Qlite;

using Dino.Entities;

namespace Dino {

public class MessageStorage : StreamInteractionModule, Object {
    public static ModuleIdentity<MessageStorage> IDENTITY = new ModuleIdentity<MessageStorage>("message_cache");
    public string id { get { return IDENTITY.id; } }

    private StreamInteractor stream_interactor;
    private Database db;

    private WeakMap<int, Message> messages_by_db_id = new WeakMap<int, Message>();
    private HashMap<Conversation, WeakMap<string, Message>> messages_by_stanza_id = new HashMap<Conversation, WeakMap<string, Message>>(Conversation.hash_func, Conversation.equals_func);
    private HashMap<Conversation, WeakMap<string, Message>> messages_by_server_id = new HashMap<Conversation, WeakMap<string, Message>>(Conversation.hash_func, Conversation.equals_func);

    // This is to keep the last 300 messages such that we don't have to recreate the newest ones all the time
    private LinkedList<Message> message_refs = new LinkedList<Message>();

    public static void start(StreamInteractor stream_interactor, Database db) {
        MessageStorage m = new MessageStorage(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    private MessageStorage(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
    }

    public void add_message(Message message, Conversation conversation) {
        message.persist(db);
        cache_message(message, conversation);
    }

    public Gee.List<Message> get_messages(Conversation conversation, int count = 50) {
        var query = db.message.select()
                .with(db.message.account_id, "=", conversation.account.id)
                .with(db.message.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
                .with(db.message.type_, "=", (int) Util.get_message_type_for_conversation(conversation))
                .order_by(db.message.time, "DESC")
                .outer_join_with(db.message_occupant_id, db.message_occupant_id.message_id, db.message.id)
                .outer_join_with(db.message_correction, db.message_correction.message_id, db.message.id)
                .outer_join_with(db.reply, db.reply.message_id, db.message.id)
                .limit(count);

        // Private MUC threads share the room's bare JID and message type; the
        // occupant resource is part of their conversation identity.
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM &&
                conversation.counterpart.resourcepart != null) {
            query.with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        }

        Gee.List<Message> ret = new LinkedList<Message>(Message.equals_func);
        foreach (Row row in query) {
            Message? message = messages_by_db_id[row[db.message.id]];
            if (message == null) {
                message = create_message_from_row(row, conversation);
            }
            ret.insert(0, message);
        }

        return ret;
    }

    public Message? get_last_message(Conversation conversation) {
        Gee.List<Message> messages = get_messages(conversation, 1);

        if (messages.size > 0) {
            return messages[0];
        }

        return null;
    }

    internal Message? get_latest_received_message(Conversation conversation) {
        var query = db.message.select()
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=",
                (int) Util.get_message_type_for_conversation(conversation))
            .with(db.message.direction, "=", Message.DIRECTION_RECEIVED)
            .order_by(db.message.local_time, "DESC")
            .order_by(db.message.id, "DESC")
            .outer_join_with(db.message_occupant_id,
                db.message_occupant_id.message_id, db.message.id)
            .outer_join_with(db.message_correction,
                db.message_correction.message_id, db.message.id)
            .outer_join_with(db.reply, db.reply.message_id, db.message.id)
            .limit(1);
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart == null) return null;
            query.with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        }
        RowOption row = query.single().row();
        return create_message_from_row_opt(row, conversation);
    }

    public Gee.List<MessageItem> get_messages_before_message(Conversation? conversation, DateTime before, int id, int count = 20) {
        if (conversation == null) return new ArrayList<MessageItem>();
        Gee.List<Message> db_messages = db.get_messages(conversation.counterpart, conversation.account, Util.get_message_type_for_conversation(conversation), count, before, null, id);
        Gee.List<MessageItem> ret = new ArrayList<MessageItem>();
        foreach (Message message in db_messages) {
            ret.add(new MessageItem(message, conversation, -1));
        }
        return ret;
    }

    public Gee.List<MessageItem> get_messages_after_message(Conversation? conversation, DateTime after, int id, int count = 20) {
        if (conversation == null) return new ArrayList<MessageItem>();
        Gee.List<Message> db_messages = db.get_messages(conversation.counterpart, conversation.account, Util.get_message_type_for_conversation(conversation), count, null, after, id);
        Gee.List<MessageItem> ret = new ArrayList<MessageItem>();
        foreach (Message message in db_messages) {
            ret.add(new MessageItem(message, conversation, -1));
        }
        return ret;
    }

    public Message? get_message_by_id(int id, Conversation conversation) {
        Message? message = messages_by_db_id[id];
        if (message != null) {
            return message_is_in_conversation_scope((!) message,
                conversation) ? message : null;
        }

        var query = db.message.select()
                .with(db.message.id, "=", id)
                .with(db.message.account_id, "=", conversation.account.id)
                .with(db.message.counterpart_id, "=",
                    db.get_jid_id(conversation.counterpart))
                .with(db.message.type_, "=",
                    (int) Util.get_message_type_for_conversation(conversation))
                .outer_join_with(db.message_occupant_id, db.message_occupant_id.message_id, db.message.id)
                .outer_join_with(db.message_correction, db.message_correction.message_id, db.message.id)
                .outer_join_with(db.reply, db.reply.message_id, db.message.id);
        apply_private_muc_resource_scope(query, conversation);
        RowOption row_option = query.single().row();

        return create_message_from_row_opt(row_option, conversation);
    }

    /** Load an immutable protocol snapshot directly from the database. */
    internal Message? get_persisted_message_by_id(int id,
            Conversation conversation) {
        var query = db.message.select()
                .with(db.message.id, "=", id)
                .with(db.message.account_id, "=", conversation.account.id)
                .with(db.message.counterpart_id, "=",
                    db.get_jid_id(conversation.counterpart))
                .with(db.message.type_, "=",
                    (int) Util.get_message_type_for_conversation(conversation))
                .outer_join_with(db.message_occupant_id,
                    db.message_occupant_id.message_id, db.message.id)
                .outer_join_with(db.message_correction,
                    db.message_correction.message_id, db.message.id)
                .outer_join_with(db.reply, db.reply.message_id,
                    db.message.id);
        apply_private_muc_resource_scope(query, conversation);
        RowOption row_option = query.single().row();
        if (!row_option.is_present()) return null;

        try {
            return new Message.from_row(db, row_option.inner);
        } catch (InvalidJidError e) {
            warning("Got persisted message with invalid Jid: %s", e.message);
        }
        return null;
    }

    internal Message? update_server_id(int message_id, string server_id,
            Conversation conversation) {
        if (server_id.strip().length == 0) return null;

        Message? message = get_message_by_id(message_id, conversation);
        if (message == null) return null;

        string? previous_server_id = ((!) message).server_id;
        if (previous_server_id != null && previous_server_id.strip().length > 0) {
            if (previous_server_id != server_id) {
                debug("Ignoring conflicting server-id %s for message %i; keeping %s",
                    server_id, message_id, previous_server_id);
            }
            if (!messages_by_server_id.has_key(conversation)) {
                messages_by_server_id[conversation] = new WeakMap<string, Message>();
            }
            messages_by_server_id[conversation][previous_server_id] = (!) message;
            return message;
        }

        ((!) message).server_id = server_id;
        if (!messages_by_server_id.has_key(conversation)) {
            messages_by_server_id[conversation] = new WeakMap<string, Message>();
        }
        messages_by_server_id[conversation][server_id] = (!) message;
        return message;
    }

    internal Message? update_sender_stanza_id(int message_id,
            string sender_stanza_id, Conversation conversation) {
        if (sender_stanza_id.strip().length == 0) return null;

        Message? message = get_message_by_id(message_id, conversation);
        if (message == null) return null;
        if (((!) message).sender_stanza_id != null) {
            if (((!) message).sender_stanza_id != sender_stanza_id) {
                debug("Ignoring conflicting sender stanza id for message %i",
                    message_id);
            }
            return message;
        }

        ((!) message).sender_stanza_id = sender_stanza_id;
        return message;
    }

    /**
     * Return the physical messages that make up one XEP-0308 correction
     * chain. DinoX stores every correction with the original sender stanza
     * ID in message_correction.to_stanza_id, so the original and all of its
     * revisions can be recovered without following the currently displayed
     * ContentItem alone.
     *
     * The database query is scoped to the account, conversation counterpart
     * and message type. Candidates are additionally checked against the
     * selected message's sender identity so a colliding replace ID from a
     * different occupant/resource cannot enter the retraction chain.
     * Callers that only need the locally known revisions (for example reply
     * metadata inheritance) may set require_complete_root=false. Global
     * deletion keeps the default and therefore remains fail-closed when the
     * physical original is missing.
     */
    internal Gee.List<Message> get_revision_chain(Conversation conversation,
            Message selected_message, bool require_complete_root = true,
            bool persisted_only = false) {
        var revisions = new ArrayList<Message>();
        var seen_message_ids = new HashSet<int>();

        if (!message_is_in_conversation_scope(selected_message, conversation)) {
            return revisions;
        }

        bool selected_is_correction = selected_message.edit_to != null &&
            ((!) selected_message.edit_to).strip().length > 0;
        string? root_stanza_id = selected_message.edit_to;
        if (root_stanza_id == null || ((!) root_stanza_id).strip().length == 0) {
            root_stanza_id = selected_message.stanza_id;
        }

        if (root_stanza_id == null || ((!) root_stanza_id).strip().length == 0) {
            revisions.add(selected_message);
            return revisions;
        }

        var original_query = db.message.select({db.message.id})
                .with<int>(db.message.account_id, "=", conversation.account.id)
                .with<int>(db.message.counterpart_id, "=",
                    db.get_jid_id(conversation.counterpart))
                .with<int>(db.message.type_, "=",
                    (int) Util.get_message_type_for_conversation(conversation))
                .with<string>(db.message.stanza_id, "=", (!) root_stanza_id)
                .order_by(db.message.time, "ASC")
                .order_by(db.message.id, "ASC");
        apply_private_muc_resource_scope(original_query, conversation);

        // Stanza IDs are sender scoped, not globally unique. There must be
        // exactly one matching sender/root tuple. Two physical roots with the
        // same sender and id are ambiguous and must not form a partial or
        // attacker-selected correction/retraction chain.
        Message? matching_original = null;
        foreach (Row row in original_query) {
            Message? original_message = persisted_only
                ? get_persisted_message_by_id(row[db.message.id], conversation)
                : get_message_by_id(row[db.message.id], conversation);
            if (original_message == null || !revision_sender_matches(
                    selected_message, (!) original_message)) {
                continue;
            }
            if (matching_original != null &&
                    ((!) matching_original).id !=
                        ((!) original_message).id) {
                return revisions;
            }
            matching_original = original_message;
        }
        if (matching_original != null) {
            revisions.add((!) matching_original);
            seen_message_ids.add(((!) matching_original).id);
        }

        // A correction's edit_to explicitly identifies a physical original
        // stanza. If that root is missing from the sender-scoped local chain,
        // returning only the remaining corrections would make "delete for
        // everyone" look successful while the original stays visible on
        // other clients. Represent the chain as unavailable instead.
        if (require_complete_root && selected_is_correction &&
                revisions.is_empty) {
            return revisions;
        }

        var query = db.message_correction.select({db.message.id})
                .join_with<int>(db.message, db.message.id,
                    db.message_correction.message_id)
                .with<int>(db.message.account_id, "=", conversation.account.id)
                .with<int>(db.message.counterpart_id, "=",
                    db.get_jid_id(conversation.counterpart))
                .with<int>(db.message.type_, "=",
                    (int) Util.get_message_type_for_conversation(conversation))
                .with<string>(db.message_correction.to_stanza_id, "=",
                    (!) root_stanza_id)
                .order_by(db.message.time, "ASC")
                .order_by(db.message.id, "ASC");

        apply_private_muc_resource_scope(query, conversation);

        foreach (Row row in query) {
            int message_id = row[db.message.id];
            if (seen_message_ids.contains(message_id)) continue;

            Message? candidate = persisted_only
                ? get_persisted_message_by_id(message_id, conversation)
                : get_message_by_id(message_id, conversation);
            if (candidate == null ||
                    !revision_sender_matches(selected_message, (!) candidate)) {
                continue;
            }

            revisions.add((!) candidate);
            seen_message_ids.add(message_id);
        }

        // A live selected revision normally has a message_correction row. Keep
        // it retractable even if a legacy/incomplete database lacks that link.
        if (!seen_message_ids.contains(selected_message.id)) {
            revisions.add(selected_message);
        }

        return revisions;
    }

    private void apply_private_muc_resource_scope(QueryBuilder query,
            Conversation conversation) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT_PM) return;

        if (conversation.counterpart.resourcepart != null) {
            query.with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        } else {
            query.with_null(db.message.counterpart_resource);
        }
    }

    internal static bool revision_sender_matches(Message anchor,
            Message candidate) {
        if (anchor.direction != candidate.direction || anchor.from == null ||
                candidate.from == null) {
            return false;
        }

        if (anchor.type_.is_muc_semantic()) {
            if (anchor.occupant_db_id != -1 && candidate.occupant_db_id != -1) {
                return anchor.occupant_db_id == candidate.occupant_db_id;
            }
            return ((!) anchor.from).equals((!) candidate.from);
        }

        return anchor.type_ == Message.Type.CHAT &&
            ((!) anchor.from).equals_bare((!) candidate.from);
    }

    private static bool message_is_in_conversation_scope(Message message,
            Conversation conversation) {
        if (!message.account.equals(conversation.account) ||
                message.counterpart == null ||
                !((!) message.counterpart).equals_bare(conversation.counterpart) ||
                message.type_ != Util.get_message_type_for_conversation(conversation)) {
            return false;
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            return ((!) message.counterpart).resourcepart ==
                conversation.counterpart.resourcepart;
        }
        return true;
    }

    public Message? get_message_by_referencing_id(string id, Conversation conversation) {
        Message? message = null;
        if (conversation.type_ == Conversation.Type.CHAT) {
            message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_stanza_id(id, conversation);
            // Fallback for clients sending server_id in 1:1 chats (e.g. some MAM implementations)
            if (message == null) {
                message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_server_id(id, conversation);
            }
        } else {
            message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_server_id(id, conversation);
            // Fallback for clients sending stanza_id (origin-id) in MUCs (e.g. Conversations, XEP-0424 compliance)
            if (message == null) {
                message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_stanza_id(id, conversation);
            }
        }
        return message;
    }

    public Message? get_message_by_stanza_id(string stanza_id, Conversation conversation) {
        if (messages_by_stanza_id.has_key(conversation)) {
            Message? message = messages_by_stanza_id[conversation][stanza_id];
            if (message != null) {
                return message;
            }
        }

        var query = db.message.select()
                .with(db.message.account_id, "=", conversation.account.id)
                .with(db.message.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
                .with(db.message.type_, "=", (int) Util.get_message_type_for_conversation(conversation))
                .with(db.message.stanza_id, "=", stanza_id)
                .order_by(db.message.time, "DESC")
                .outer_join_with(db.message_occupant_id, db.message_occupant_id.message_id, db.message.id)
                .outer_join_with(db.message_correction, db.message_correction.message_id, db.message.id)
                .outer_join_with(db.reply, db.reply.message_id, db.message.id);

        if (conversation.counterpart.resourcepart != null) {
            query.with(db.message.counterpart_resource, "=", conversation.counterpart.resourcepart);
        }

        RowOption row_option = query.single().row();

        return create_message_from_row_opt(row_option, conversation);
    }

    public Message? get_message_by_server_id(string server_id, Conversation conversation) {
        // The scalar cache can contain account-MAM ids for groupchat rows.
        // Resolve room references through their authority-bound database pair.
        if (conversation.type_ != Conversation.Type.GROUPCHAT &&
                messages_by_server_id.has_key(conversation)) {
            Message? message = messages_by_server_id[conversation][server_id];
            if (message != null) {
                return message;
            }
        }

        var query = db.message.select()
                .with(db.message.account_id, "=", conversation.account.id)
                .with(db.message.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
                .with(db.message.type_, "=", (int) Util.get_message_type_for_conversation(conversation))
                .order_by(db.message.time, "DESC")
                .outer_join_with(db.message_occupant_id, db.message_occupant_id.message_id, db.message.id)
                .outer_join_with(db.message_correction, db.message_correction.message_id, db.message.id)
                .outer_join_with(db.reply, db.reply.message_id, db.message.id);

        if (conversation.counterpart.resourcepart != null) {
            query.with(db.message.counterpart_resource, "=", conversation.counterpart.resourcepart);
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            query.where("((message.stable_id = ? AND message.stable_id_by = ?) OR ((message.stable_id IS NULL OR message.stable_id_by IS NULL) AND message.server_id = ?))",
                { server_id, conversation.counterpart.bare_jid.to_string(),
                  server_id });
            Row? match = null;
            foreach (Row row in query) {
                if (match != null) {
                    warning("Ambiguous room stanza reference %s in %s",
                        server_id, conversation.counterpart.to_string());
                    return null;
                }
                match = row;
            }
            return match != null
                ? create_message_from_row((!) match, conversation) : null;
        }

        query.with(db.message.server_id, "=", server_id);
        RowOption row_option = query.single().row();

        return create_message_from_row_opt(row_option, conversation);
    }

    internal Message? get_message_by_stable_reference(string stable_id, Jid by,
            Conversation conversation) {
        var query = db.message.select()
                .with(db.message.account_id, "=", conversation.account.id)
                .with(db.message.counterpart_id, "=",
                    db.get_jid_id(conversation.counterpart))
                .with(db.message.type_, "=",
                    (int) Util.get_message_type_for_conversation(conversation))
                .with(db.message.stable_id, "=", stable_id)
                .with(db.message.stable_id_by, "=", by.to_string())
                .order_by(db.message.time, "DESC")
                .outer_join_with(db.message_occupant_id,
                    db.message_occupant_id.message_id, db.message.id)
                .outer_join_with(db.message_correction,
                    db.message_correction.message_id, db.message.id)
                .outer_join_with(db.reply, db.reply.message_id,
                    db.message.id);

        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart == null) return null;
            query.with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        }

        Row? match = null;
        foreach (Row row in query) {
            if (match != null) {
                warning("Ambiguous stable stanza reference %s by %s in %s",
                    stable_id, by.to_string(),
                    conversation.counterpart.to_string());
                return null;
            }
            match = row;
        }
        if (match == null) return null;
        return create_message_from_row((!) match, conversation);
    }

    /** Resolve the exact id copied by XEP-0184 and XEP-0333. */
    internal Message? get_message_by_sender_stanza_id(string sender_stanza_id,
            Conversation conversation, bool expected_direction) {
        bool ambiguous = false;
        Message? current = get_unique_sender_id_match(sender_stanza_id,
            conversation, expected_direction, false, out ambiguous);
        if (current != null) return current;
        if (ambiguous) return null;

        // Rows written before schema v49 have no dedicated wire-id field.
        // For our own outgoing messages stanza_id was the generated wire id;
        // never use this compatibility path for received messages.
        if (expected_direction != Message.DIRECTION_SENT) return null;
        return get_unique_sender_id_match(sender_stanza_id, conversation,
            expected_direction, true, out ambiguous);
    }

    private Message? get_unique_sender_id_match(string sender_stanza_id,
            Conversation conversation, bool expected_direction,
            bool legacy_outgoing,
            out bool ambiguous) {
        ambiguous = false;
        var query = db.message.select()
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=",
                (int) Util.get_message_type_for_conversation(conversation))
            .with(db.message.direction, "=", expected_direction)
            .outer_join_with(db.message_occupant_id,
                db.message_occupant_id.message_id, db.message.id)
            .outer_join_with(db.message_correction,
                db.message_correction.message_id, db.message.id)
            .outer_join_with(db.reply, db.reply.message_id, db.message.id);
        if (legacy_outgoing) {
            query.with_null(db.message.sender_stanza_id)
                .with(db.message.stanza_id, "=", sender_stanza_id);
        } else {
            query.with(db.message.sender_stanza_id, "=", sender_stanza_id);
        }
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart == null) return null;
            query.with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        }

        Row? match = null;
        foreach (Row row in query) {
            if (match != null) {
                ambiguous = true;
                return null;
            }
            match = row;
        }
        return match != null
            ? create_message_from_row((!) match, conversation) : null;
    }

    /** Mark every persisted outgoing message up to an exact displayed target. */
    internal bool mark_sent_messages_read_through(Conversation conversation,
            Message target) {
        if (target.direction != Message.DIRECTION_SENT ||
                target.local_time == null ||
                !message_belongs_to_conversation_scope(target,
                    conversation)) {
            return false;
        }

        int64 target_time = ((!) target.local_time).to_unix();
        string readable_states = "%i, %i, %i, %i, %i".printf(
            (int) Message.Marked.SENT,
            (int) Message.Marked.RECEIVED,
            (int) Message.Marked.ACKNOWLEDGED,
            (int) Message.Marked.SENDING,
            (int) Message.Marked.READ);
        var update = db.message.update()
            .where(@"(local_time < ? OR (local_time = ? AND id <= ?)) AND marked IN ($readable_states)",
                { target_time.to_string(), target_time.to_string(),
                    target.id.to_string() })
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=",
                (int) Util.get_message_type_for_conversation(conversation))
            .with(db.message.direction, "=", Message.DIRECTION_SENT)
            .set(db.message.marked, Message.Marked.READ);
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.counterpart.resourcepart == null) return false;
            update.with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        }
        update.perform();

        // MessageItem keeps its Message alive even after it leaves the
        // 300-entry strong cache. Walk every still-live weak-cache object so
        // an older, visible row receives the same state as the database.
        var cached_ids = new ArrayList<int>();
        cached_ids.add_all(messages_by_db_id.keys);
        foreach (int message_id in cached_ids) {
            Message? cached = messages_by_db_id[message_id];
            if (cached == null) continue;
            Message message = (!) cached;
            if (message.direction != Message.DIRECTION_SENT ||
                    !message_belongs_to_conversation_scope(message,
                        conversation) ||
                    compare_persisted_position(message, target) > 0 ||
                    !is_readable_sent_state(message.marked)) {
                continue;
            }
            message.set_marked_from_storage(Message.Marked.READ);
        }
        return true;
    }

    private static bool is_readable_sent_state(Message.Marked state) {
        return state == Message.Marked.SENT ||
            state == Message.Marked.RECEIVED ||
            state == Message.Marked.ACKNOWLEDGED ||
            state == Message.Marked.SENDING ||
            state == Message.Marked.READ;
    }

    private static int compare_persisted_position(Message left,
            Message right) {
        if (left.local_time != null && right.local_time != null) {
            int time_order = ((!) left.local_time).compare(
                (!) right.local_time);
            if (time_order != 0) return time_order;
        }
        if (left.id == right.id) return 0;
        return left.id > right.id ? 1 : -1;
    }

    private static bool message_belongs_to_conversation_scope(Message message,
            Conversation conversation) {
        if (!message.account.equals(conversation.account) ||
                message.counterpart == null ||
                !((!) message.counterpart).equals_bare(
                    conversation.counterpart) ||
                message.type_ !=
                    Util.get_message_type_for_conversation(conversation)) {
            return false;
        }
        return conversation.type_ != Conversation.Type.GROUPCHAT_PM ||
            ((!) message.counterpart).equals(conversation.counterpart);
    }

    internal Message? update_stable_reference(int message_id, string stable_id,
            Jid by, Conversation conversation) {
        if (stable_id.strip().length == 0 || !by.is_bare()) return null;

        Message? message = get_message_by_id(message_id, conversation);
        if (message == null) return null;

        if (((!) message).stable_id != null ||
                ((!) message).stable_id_by != null) {
            if (((!) message).stable_id != stable_id ||
                    ((!) message).stable_id_by == null ||
                    !((!) message).stable_id_by.equals(by)) {
                Jid? stored_by = ((!) message).stable_id_by;
                warning("Ignoring conflicting stable stanza reference for message %i (stored_id=%s, stored_by=%s, incoming_id=%s, incoming_by=%s, account_id=%i, conversation_type=%i)",
                    message_id, ((!) message).stable_id ?? "-",
                    stored_by != null ? ((!) stored_by).to_string() : "-",
                    stable_id, by.to_string(), conversation.account.id,
                    (int) conversation.type_);
            }
            return message;
        }

        ((!) message).set_stable_reference(stable_id, by);
        return message;
    }

    private Message? create_message_from_row_opt(RowOption row_option, Conversation conversation) {
        if (!row_option.is_present()) return null;
        return create_message_from_row(row_option.inner, conversation);
    }

    private Message? create_message_from_row(Row row, Conversation conversation) {
        Message? cached = messages_by_db_id[row[db.message.id]];
        if (cached != null) {
            return cached;
        }

        try {
            Message message = new Message.from_row(db, row);
            cache_message(message, conversation);
            return message;
        } catch (InvalidJidError e) {
            warning("Got message with invalid Jid: %s", e.message);
        }
        return null;
    }

    private void cache_message(Message message, Conversation conversation) {
        messages_by_db_id[message.id] = message;

        if (message.stanza_id != null) {
            if (!messages_by_stanza_id.has_key(conversation)) {
                messages_by_stanza_id[conversation] = new WeakMap<string, Message>();
            }
            messages_by_stanza_id[conversation][message.stanza_id] = message;
        }

        if (message.server_id != null) {
            if (!messages_by_server_id.has_key(conversation)) {
                messages_by_server_id[conversation] = new WeakMap<string, Message>();
            }
            messages_by_server_id[conversation][message.server_id] = message;
        }

        message_refs.insert(0, message);
        if (message_refs.size > 300) {
            message_refs.remove_at(message_refs.size - 1);
        }
    }

    public void clear_conversation_cache(Conversation conversation) {
        // Remove cached message lookup maps for this conversation only
        if (messages_by_stanza_id.has_key(conversation)) {
            messages_by_stanza_id.unset(conversation);
        }
        if (messages_by_server_id.has_key(conversation)) {
            messages_by_server_id.unset(conversation);
        }

        var retained_refs = new LinkedList<Message>();
        foreach (Message message in message_refs) {
            if (message_belongs_to_conversation(message, conversation)) {
                if (message.id >= 0) {
                    messages_by_db_id.unset(message.id);
                }
            } else {
                retained_refs.add(message);
            }
        }
        message_refs.clear();
        message_refs.add_all(retained_refs);
    }

    private bool message_belongs_to_conversation(Message message, Conversation conversation) {
        if (!message.account.equals(conversation.account)) return false;
        if (message.counterpart == null || !((!) message.counterpart).equals(conversation.counterpart)) return false;
        return message.type_ == Util.get_message_type_for_conversation(conversation);
    }

    /** Select a room reference independently of a personal archive's id. */
    internal static string? get_groupchat_reference_id(Message message,
            Conversation conversation) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return null;
        if (message.stable_id != null && message.stable_id_by != null) {
            return ((!) message.stable_id_by).equals(
                conversation.counterpart.bare_jid) ? message.stable_id : null;
        }
        return message.server_id;
    }

    public static string? get_reference_id(Message message) {
        if (message.edit_to != null) return message.edit_to;

        // XEP-0424/XEP-0359: Prefer using the Stable Stanza ID (Origin ID / UUID) if available,
        // as it is the most reliable way to identify the message across different clients/storage.
        // This fixes interoperability with clients like Conversations in MUCs that track messages by Origin ID.
        if (message.stanza_id != null && message.stanza_id != "") {
            return message.stanza_id;
        }
        
        // Fallback to Server ID (MAM ID) if no Origin ID is available (e.g. historical messages or server-side archives)
        return message.server_id;
    }
}

}
