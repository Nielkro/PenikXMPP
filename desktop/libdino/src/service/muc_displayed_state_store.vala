using Qlite;

using Xmpp;
using Dino.Entities;

namespace Dino {

/** Persists one monotonic XEP-0333 pointer per private-MUC reader. */
internal class MucDisplayedStateStore : Object {
    private Database db;

    public MucDisplayedStateStore(Database db) {
        this.db = db;
    }

    /** Returns true only when this reader's pointer moved forward. */
    public bool advance(Conversation conversation, Jid reader,
            Entities.Message target) {
        if (!is_valid_target(conversation, target) ||
                reader.equals_bare(conversation.account.bare_jid)) {
            return false;
        }

        long target_time = (long) ((!) target.local_time).to_unix();
        int reader_jid_id = db.get_jid_id(reader.bare_jid);
        RowOption current = db.muc_displayed_state.select({
                db.muc_displayed_state.target_message_id,
                db.message.local_time })
            .join_with(db.message, db.message.id,
                db.muc_displayed_state.target_message_id)
            .with(db.muc_displayed_state.conversation_id, "=",
                conversation.id)
            .with(db.muc_displayed_state.reader_jid_id, "=", reader_jid_id)
            .single().row();
        if (current.is_present()) {
            long current_time = current[db.message.local_time];
            int current_id = current[db.muc_displayed_state.target_message_id];
            if (current_time > target_time ||
                    (current_time == target_time && current_id >= target.id)) {
                return false;
            }
        }

        db.muc_displayed_state.upsert()
            .value(db.muc_displayed_state.conversation_id,
                conversation.id, true)
            .value(db.muc_displayed_state.reader_jid_id, reader_jid_id, true)
            .value(db.muc_displayed_state.target_message_id, target.id, false)
            .perform();
        return true;
    }

    /** Number of distinct verified participants displayed through target. */
    public int get_reader_count(Conversation conversation,
            Entities.Message target) {
        if (!is_valid_target(conversation, target)) return 0;

        long target_time = (long) ((!) target.local_time).to_unix();
        int64 count = db.muc_displayed_state.select()
            .join_with(db.message, db.message.id,
                db.muc_displayed_state.target_message_id)
            .with(db.muc_displayed_state.conversation_id, "=",
                conversation.id)
            .with(db.message.direction, "=",
                Entities.Message.DIRECTION_SENT)
            .where("(message.local_time > ? OR (message.local_time = ? AND message.id >= ?))",
                { target_time.to_string(), target_time.to_string(),
                    target.id.to_string() })
            .count();
        return count > int.MAX ? int.MAX : (int) count;
    }

    public void clear_conversation(Conversation conversation) {
        if (conversation.id < 0) return;
        db.muc_displayed_state.delete()
            .with(db.muc_displayed_state.conversation_id, "=",
                conversation.id)
            .perform();
    }

    private static bool is_valid_target(Conversation conversation,
            Entities.Message target) {
        return conversation.type_ == Conversation.Type.GROUPCHAT &&
            conversation.id >= 0 && target.id >= 0 &&
            target.local_time != null &&
            target.direction == Entities.Message.DIRECTION_SENT &&
            target.type_ == Entities.Message.Type.GROUPCHAT &&
            target.account.equals(conversation.account) &&
            target.counterpart != null &&
            ((!) target.counterpart).equals_bare(conversation.counterpart);
    }
}

}
