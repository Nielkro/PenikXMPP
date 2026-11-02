using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino {

// XEP-0425 archive tombstones are records of an already executed retraction,
// not live control messages. Keep their identity even when no text was stored
// locally, so older revisions cannot reappear during reverse MAM pagination.
internal class ArchiveRetractionListener : MessageListener {
    private StreamInteractor interactor;
    private Database db;
    private string[] after_actions_const = {"MUC", "DELETE"};
    public override string action_group { get { return "ARCHIVE_RETRACTION"; } }
    public override string[] after_actions { get { return after_actions_const; } }

    internal ArchiveRetractionListener(StreamInteractor interactor, Database db) {
        this.interactor = interactor;
        this.db = db;
    }

    internal static bool is_room_tombstone(MessageStanza stanza, Conversation conversation) {
        var mam = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza);
        if (conversation.type_ != Conversation.Type.GROUPCHAT || mam == null ||
                !mam.sender_jid.equals(conversation.counterpart.bare_jid) ||
                stanza.type_ != MessageStanza.TYPE_GROUPCHAT || stanza.from == null ||
                !stanza.from.is_full() || !stanza.from.equals_bare(conversation.counterpart) ||
                stanza.body != null) return false;
        var tombstone = stanza.stanza.get_subnode("retracted", Xep.MessageRetraction.NS_URI);
        if (tombstone == null || tombstone.get_subnode("moderated", Xep.MessageModeration.NS_URI) == null) return false;
        string? stamp = tombstone.get_attribute("stamp");
        return stamp != null && new DateTime.from_iso8601(stamp, null) != null;
    }

    public override async bool run(Message message, MessageStanza stanza, Conversation conversation) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT ||
                message.type_ != Message.Type.GROUPCHAT ||
                !message.account.equals(conversation.account) || message.from == null ||
                !message.from.equals_bare(conversation.counterpart)) return false;
        bool has_sender_id = message.stanza_id != null && message.stanza_id.strip().length > 0;
        bool has_room_id = message.stable_id != null && message.stable_id_by != null &&
            message.stable_id_by.equals(conversation.counterpart.bare_jid);
        if (!has_sender_id && !has_room_id) return false;

        bool tombstone = is_room_tombstone(stanza, conversation);
        if (!tombstone && !db.message.select({db.message.id})
                .with(db.message.account_id, "=", conversation.account.id)
                .with(db.message.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
                .with(db.message.type_, "=", (int) Message.Type.GROUPCHAT)
                .with(db.message.archive_retracted, "=", true).limit(1).single().row().is_present()) return false;
        var storage = interactor.get_module<MessageStorage>(MessageStorage.IDENTITY);
        string? previous_stanza_id = message.stanza_id;
        Message? stable_match = null;
        if (message.stable_id != null && message.stable_id_by != null &&
                message.stable_id_by.equals(conversation.counterpart.bare_jid)) {
            stable_match = storage.get_message_by_stable_reference(message.stable_id,
                message.stable_id_by, conversation);
            if (stable_match != null && !MessageStorage.revision_sender_matches(message, stable_match)) {
                // After a nickname change, parsing history can classify our old
                // room messages as received. The room-authoritative id and the
                // original author's identity must both match before reusing the
                // stored direction; never relax sender checks for live payloads.
                if (!tombstone || !same_room_author(message, stable_match)) return tombstone;
                message.counterpart = stable_match.counterpart;
                message.ourpart = stable_match.ourpart;
                message.direction = stable_match.direction;
            }
        }
        string? previous_edit_to = message.edit_to;
        string? replace = Xep.LastMessageCorrection.get_replace_id(stanza);
        if (replace != null && (replace.strip().length == 0 || replace == message.stanza_id)) replace = null;
        if (replace != null) replace = resolve_original_id(message, conversation, replace);
        // A tombstone may retain the sender's id but omit its origin-id. The
        // room's authenticated stable id still identifies the existing row.
        if (stable_match != null) {
            message.stanza_id = stable_match.stanza_id;
            replace = stable_match.edit_to ?? replace;
        }
        message.edit_to = replace;
        var revisions = storage.get_revision_chain(conversation, message, false);
        // An original arriving after its tombstone corrections may still carry
        // an origin-id different from the message id referenced by <replace>.
        if (replace == null && message.sender_stanza_id != null &&
                message.sender_stanza_id != message.stanza_id) {
            string? id = message.stanza_id;
            message.stanza_id = message.sender_stanza_id;
            var wire_revisions = storage.get_revision_chain(conversation, message, false);
            message.stanza_id = id;
            foreach (Message revision in wire_revisions) {
                if (revision.id > 0 && revision.archive_retracted) revisions.add(revision);
            }
        }

        // XEP-0308 references an original, never another correction. Do not let
        // malformed archive links pull an unrelated logical message into a chain.
        foreach (Message revision in revisions) {
            if (replace != null && revision.stanza_id == replace && revision.edit_to != null) {
                message.edit_to = null;
                break;
            }
        }
        if (message.edit_to != replace) revisions = storage.get_revision_chain(conversation, message, false);
        bool removed = tombstone || (stable_match != null && stable_match.archive_retracted);
        foreach (Message revision in revisions) removed = removed || revision.archive_retracted;
        if (!removed || revisions.is_empty) {
            message.edit_to = previous_edit_to;
            message.stanza_id = previous_stanza_id;
            return tombstone;
        }

        Message? canonical = stable_match;
        foreach (Message revision in revisions) {
            if (revision.id > 0 && revision.stanza_id == message.stanza_id) {
                if (canonical != null && canonical.id != revision.id) return true;
                canonical = revision;
            }
        }
        bool inserted = canonical == null;
        if (inserted) {
            message.body = "";
            message.archive_retracted = true;
            message.markable = false;
            message.marked = Message.Marked.READ;
            storage.add_message(message, conversation);
            canonical = message;
        }
        if (message.edit_to != null && (inserted || canonical.edit_to == null)) {
            db.message_correction.insert()
                .value(db.message_correction.message_id, canonical.id)
                .value(db.message_correction.to_stanza_id, message.edit_to).perform();
            canonical.edit_to = message.edit_to;
        }
        revisions = storage.get_revision_chain(conversation, canonical, false);
        foreach (Message revision in revisions) {
            // The marker lives in the ordinary message row, so account/history
            // deletion and backups retain their existing ownership and cleanup.
            db.message.update().with(db.message.id, "=", revision.id)
                .with(db.message.account_id, "=", conversation.account.id)
                .set(db.message.archive_retracted, true).set(db.message.body, "")
                .set(db.message.markable, false)
                .set(db.message.mention_state, (int) Message.MentionState.NONE).perform();
            revision.body = "";
            revision.archive_retracted = true;
            revision.markable = false;
            revision.mention_state = Message.MentionState.NONE;
            var store = interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            ContentItem? item = store.get_item_by_foreign(conversation, 1, revision.id);
            var deletion = interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY);
            if (item != null && deletion != null) deletion.delete_locally(conversation, item, conversation.counterpart);
            if (deletion != null) {
                foreach (FileItem file_item in store.get_file_items_for_message(conversation, revision)) {
                    deletion.delete_locally(conversation, file_item, conversation.counterpart);
                }
            }
        }
        return true;
    }

    private static bool same_room_author(Message message, Message stored) {
        if (message.from == null || stored.from == null) return false;
        if (message.occupant_db_id != -1 && stored.occupant_db_id != -1) {
            return message.occupant_db_id == stored.occupant_db_id;
        }
        return message.from.equals(stored.from);
    }

    private string? resolve_original_id(Message message, Conversation conversation, string reference) {
        var storage = interactor.get_module<MessageStorage>(MessageStorage.IDENTITY);
        Message? match = null;
        var query = db.message.select({db.message.id})
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=", (int) Message.Type.GROUPCHAT)
            .where("(message.stanza_id = ? OR message.sender_stanza_id = ?)", {reference, reference});
        foreach (var row in query) {
            var candidate = storage.get_message_by_id(row[db.message.id], conversation);
            if (candidate == null || !MessageStorage.revision_sender_matches(message, candidate)) continue;
            if (match != null || candidate.edit_to != null) return null;
            match = candidate;
        }
        return match != null ? match.stanza_id : reference;
    }
}
}
