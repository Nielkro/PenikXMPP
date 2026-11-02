using Xmpp;

namespace Dino.Test {

class ConversationSettingsTest : Gee.TestCase {
    public ConversationSettingsTest() {
        base("ConversationSettings");
        add_test("muc_status_messages_are_off_by_default_and_persist_per_room",
            test_muc_status_messages_are_off_by_default_and_persist_per_room);
        add_test("message_send_mode_defaults_to_enter_and_survives_reopen", test_message_send_mode);
    }

    private void test_message_send_mode() {
        string root = Path.build_filename(Environment.get_tmp_dir(), "dinox-send-mode-" + Uuid.string_random());
        string path = Path.build_filename(root, "settings.db");
        Database? db = null;
        try {
            DirUtils.create_with_parents(root, 0700);
            db = new Database(path, "isolated send mode test");
            var settings = new Entities.Settings.from_db(db);
            fail_if(settings.send_on_ctrl_enter, "a profile without this setting must keep Enter to send");
            settings.send_on_ctrl_enter = true;
            db.close();
            db = new Database(path, "isolated send mode test");
            settings = new Entities.Settings.from_db(db);
            fail_if_not(settings.send_on_ctrl_enter, "Ctrl+Enter must survive a database reopen");
            settings.send_on_ctrl_enter = false;
            db.close();
            db = new Database(path, "isolated send mode test");
            fail_if(new Entities.Settings.from_db(db).send_on_ctrl_enter,
                "switching back to Enter must also survive a database reopen");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (db != null) db.close();
            foreach (string suffix in new string[] {"", "-wal", "-shm"}) FileUtils.remove(path + suffix);
            DirUtils.remove(root);
        }
    }

    private void test_muc_status_messages_are_off_by_default_and_persist_per_room() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-conversation-settings-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        const string db_key = "conversation-settings-test";
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, db_key);

            var account = new Entities.Account(
                new Jid("alice@example.test"), "secret");
            account.persist((!) db);

            var enabled_room = new Entities.Conversation(
                new Jid("enabled@conference.example.test"), account,
                Entities.Conversation.Type.GROUPCHAT);
            enabled_room.persist((!) db);
            var default_room = new Entities.Conversation(
                new Jid("default@conference.example.test"), account,
                Entities.Conversation.Type.GROUPCHAT);
            default_room.persist((!) db);
            var second_account = new Entities.Account(
                new Jid("carol@example.test"), "secret");
            second_account.persist((!) db);
            var same_room_second_account = new Entities.Conversation(
                new Jid("enabled@conference.example.test"), second_account,
                Entities.Conversation.Type.GROUPCHAT);
            same_room_second_account.persist((!) db);
            var direct_chat = new Entities.Conversation(
                new Jid("bob@example.test"), account,
                Entities.Conversation.Type.CHAT);
            direct_chat.persist((!) db);

            fail_if(enabled_room.show_muc_status_messages,
                "new MUC conversations must hide status messages by default");
            fail_if(default_room.show_muc_status_messages,
                "the default must be off independently for every room");
            fail_if(same_room_second_account.show_muc_status_messages,
                "the default must be off independently for every account");

            enabled_room.show_muc_status_messages = true;
            int enabled_room_id = enabled_room.id;
            int default_room_id = default_room.id;
            int second_account_room_id = same_room_second_account.id;
            int direct_chat_id = direct_chat.id;
            direct_chat.show_muc_status_messages = true;
            fail_if(((!) db).conversation_settings.get_value(direct_chat_id,
                    "show_muc_status_messages") != null,
                "a non-MUC conversation must not persist the MUC-only setting");

            ((!) db).close();
            db = new Database(db_path, db_key);
            Entities.Account? reopened_account = find_account(
                ((!) db).get_accounts(), "alice@example.test");
            Entities.Account? reopened_second_account = find_account(
                ((!) db).get_accounts(), "carol@example.test");
            fail_if(reopened_account == null || reopened_second_account == null,
                "both account scopes must survive a database reopen");
            Entities.Conversation? reopened_enabled = find_conversation(
                ((!) db).get_conversations((!) reopened_account), enabled_room_id);
            Entities.Conversation? reopened_default = find_conversation(
                ((!) db).get_conversations((!) reopened_account), default_room_id);
            Entities.Conversation? reopened_direct_chat = find_conversation(
                ((!) db).get_conversations((!) reopened_account), direct_chat_id);
            Entities.Conversation? reopened_same_room_second_account =
                find_conversation(
                    ((!) db).get_conversations((!) reopened_second_account),
                    second_account_room_id);

            fail_if(reopened_enabled == null ||
                    !((!) reopened_enabled).show_muc_status_messages,
                "the enabled MUC setting must survive a database reopen");
            fail_if(reopened_default == null ||
                    ((!) reopened_default).show_muc_status_messages,
                "enabling one MUC must not enable another room");
            fail_if(reopened_direct_chat == null ||
                    ((!) reopened_direct_chat).show_muc_status_messages,
                "a non-MUC conversation must always reload with the setting off");
            fail_if(reopened_same_room_second_account == null ||
                    ((!) reopened_same_room_second_account)
                        .show_muc_status_messages,
                "the same room JID on another account must remain disabled");

            ((!) reopened_enabled).show_muc_status_messages = false;
            string? stored_value = ((!) db).conversation_settings.get_value(
                enabled_room_id, "show_muc_status_messages");
            fail_if_not_eq_str("false", stored_value,
                "disabling the switch must be persisted explicitly");

            ((!) db).close();
            db = new Database(db_path, db_key);
            reopened_account = find_account(
                ((!) db).get_accounts(), "alice@example.test");
            fail_if(reopened_account == null,
                "the original account must survive a second reopen");
            reopened_enabled = find_conversation(
                ((!) db).get_conversations((!) reopened_account), enabled_room_id);
            fail_if(reopened_enabled == null ||
                    ((!) reopened_enabled).show_muc_status_messages,
                "the disabled MUC setting must survive a second reopen");
        } catch (Error error) {
            fail_if_reached("Unexpected conversation setting error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private Entities.Conversation? find_conversation(
            Gee.List<Entities.Conversation> conversations, int id) {
        foreach (Entities.Conversation conversation in conversations) {
            if (conversation.id == id) return conversation;
        }
        return null;
    }

    private Entities.Account? find_account(
            Gee.List<Entities.Account> accounts, string bare_jid) {
        foreach (Entities.Account account in accounts) {
            if (account.bare_jid.to_string() == bare_jid) return account;
        }
        return null;
    }
}

}
