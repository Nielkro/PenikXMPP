using Dino.Entities;
using Dino.Ui.ConversationSummary;
using Xmpp;

namespace Dino.Ui.Test {

class MucStatusMessagesTest : Gee.TestCase {
    public MucStatusMessagesTest() {
        base("MucStatusMessages");
        add_test("groupchat_default_is_off", test_groupchat_default_is_off);
        add_test("groupchat_can_opt_in", test_groupchat_can_opt_in);
        add_test("non_room_conversations_never_show_room_status",
            test_non_room_conversations_never_show_room_status);
    }

    private void test_groupchat_default_is_off() {
        Conversation conversation = make_conversation(
            "room@conference.example.test", Conversation.Type.GROUPCHAT);
        assert_true(StatusPopulator.is_muc_room_conversation(conversation),
            "a MUC room timeline must be recognized as the status destination");
        assert_false(StatusPopulator.should_show_muc_status_messages(
            conversation), "MUC ChatView status messages must default to off");
    }

    private void test_groupchat_can_opt_in() {
        Conversation conversation = make_conversation(
            "room@conference.example.test", Conversation.Type.GROUPCHAT);
        conversation.show_muc_status_messages = true;
        assert_true(StatusPopulator.should_show_muc_status_messages(
            conversation), "an enabled MUC must show future ChatView status messages");
    }

    private void test_non_room_conversations_never_show_room_status() {
        Conversation direct_chat = make_conversation(
            "bob@example.test", Conversation.Type.CHAT);
        direct_chat.show_muc_status_messages = true;
        assert_false(StatusPopulator.is_muc_room_conversation(direct_chat),
            "a direct chat is not a MUC room status destination");
        assert_false(StatusPopulator.should_show_muc_status_messages(
            direct_chat), "a direct chat must never show MUC status messages");

        Conversation private_message = make_conversation(
            "room@conference.example.test/bob",
            Conversation.Type.GROUPCHAT_PM);
        private_message.show_muc_status_messages = true;
        assert_false(StatusPopulator.is_muc_room_conversation(private_message),
            "a MUC private message is not the room status destination");
        assert_false(StatusPopulator.should_show_muc_status_messages(
            private_message), "a MUC private message must not inherit room status messages");
    }

    private Conversation make_conversation(string jid, Conversation.Type type) {
        try {
            var account = new Account(new Jid("alice@example.test"), "secret");
            return new Conversation(new Jid(jid), account, type);
        } catch (InvalidJidError error) {
            assert_not_reached();
        }
    }
}

}
