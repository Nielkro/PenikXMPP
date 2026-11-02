using Dino.Entities;
using Xmpp;

namespace Dino.Test {

class MessageDiagnosticsPersistenceTest : Gee.TestCase {
    public MessageDiagnosticsPersistenceTest() {
        base("MessageDiagnosticsPersistence");
        add_test("failure_provenance_survives_save_and_reload", () => exercise(false));
        add_test("version_53_upgrade_does_not_guess_from_user_text", () => exercise(true));
    }

    private void exercise(bool upgrade) {
        string? directory = null;
        try {
            directory = DirUtils.make_tmp("dinox-message-diagnostic-XXXXXX");
            string path = Path.build_filename((!) directory, "test.db");
            var db = new Database(path, "test-only");
            var account = new Account(new Jid("ours@example.test"), "test-only");
            account.persist(db);
            var message = new Message("[This OMEMO message could not be decrypted]") {
                account = account, counterpart = new Jid("peer@example.test"),
                ourpart = account.bare_jid, type_ = Message.Type.CHAT,
                direction = Message.DIRECTION_RECEIVED,
                time = new DateTime.now_utc(), local_time = new DateTime.now_utc(),
                encryption = Encryption.OMEMO, decryption_failed = !upgrade, encryption_time_mismatch = !upgrade
            };
            message.persist(db);
            int id = message.id;
            if (upgrade) {
                // Rebuild pre-v54 columns without DROP COLUMN, for older
                // supported SQLite/SQLCipher runtimes as well.
                db.exec("""
CREATE TABLE message_pre54_fixture AS SELECT
    id, stanza_id, server_id, sender_stanza_id, stable_id, stable_id_by,
    account_id, counterpart_id, counterpart_resource, our_resource,
    direction, type, time, local_time, body, encryption, encryption_protocol,
    marked, markable FROM message;
DROP TABLE message;
ALTER TABLE message_pre54_fixture RENAME TO message;
""");
                // Match the historical conversation schema too. Use the
                // real table definition to preserve keys and defaults on
                // SQLite versions without DROP COLUMN.
                db.exec("ALTER TABLE conversation RENAME TO conversation_post56_fixture");
                db.conversation.create_table_at_version(53);
                db.exec("""
INSERT INTO conversation (
    id, account_id, jid_id, resource, active, active_last_changed,
    last_active, type, encryption, read_up_to, read_up_to_item,
    notification, send_typing, send_marker, pinned, history_cleared_at,
    message_expiry_seconds, muc_pm_peer_identity)
SELECT id, account_id, jid_id, resource, active, active_last_changed,
    last_active, type, encryption, read_up_to, read_up_to_item,
    notification, send_typing, send_marker, pinned, history_cleared_at,
    message_expiry_seconds, muc_pm_peer_identity
FROM conversation_post56_fixture;
DROP TABLE conversation_post56_fixture;
""");
                rebuild_account_fixture_at_version(db, 53);
                db.exec("UPDATE _meta SET int_val=53 WHERE name='version'");
                db = new Database(path, "test-only");
            }
            Message? loaded = db.get_message_by_id(id);
            fail_if(loaded == null, "Schema upgrade must preserve the message");
            if (loaded != null) {
                fail_if(((!) loaded).decryption_failed != !upgrade,
                    "Old authenticated text must not be guessed to be a local failure");
                fail_if(((!) loaded).encryption_time_mismatch != !upgrade, "Timestamp alert provenance must survive reload without guessing old rows");
                fail_if_not_eq_str(((!) loaded).body, message.body);
                ((!) loaded).decryption_failed = upgrade;
                Message? updated = db.get_message_by_id(id);
                fail_if(updated == null || ((!) updated).decryption_failed != upgrade,
                    "Explicit provenance updates must persist");
            }
        } catch (Error error) { fail_if_reached(error.message); }
        if (directory != null) {
            foreach (string name in new string[] {"test.db", "test.db-wal", "test.db-shm"}) {
                FileUtils.unlink(Path.build_filename((!) directory, name));
            }
            DirUtils.remove((!) directory);
        }
    }
}

}
