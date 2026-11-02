using Dino.Entities;
using Dino.Ui.ConversationSummary;

namespace Dino.Ui.Test {

class MessageDiagnosticsTest : Gee.TestCase {
    internal MessageDiagnosticsTest() {
        base("MessageDiagnostics");
        add_test("local_omemo_diagnostic_is_presented_without_rewriting_history", test_local_error);
        add_test("plain_chat_and_public_muc_text_is_unchanged", test_plain_messages);
        add_test("other_encryption_and_bodyless_messages_are_unchanged", test_other_messages);
        add_test("blocked_private_room_reports_actionable_reason", test_blocked_room);
    }

    private void test_local_error() {
        string stored = "[This OMEMO message could not be decrypted]";
        var message = new Message(null) { encryption = Encryption.OMEMO, decryption_failed = true, body = stored };
        assert_true(MessageDiagnostics.is_local_decryption_failure(message));
        assert_true(MessageDiagnostics.body_for_display(message) != stored);
        var authenticated_text = new Message(stored) { encryption = Encryption.OMEMO };
        assert_true(!MessageDiagnostics.is_local_decryption_failure(authenticated_text));
        assert_true(MessageDiagnostics.body_for_display(authenticated_text) == stored,
            "Authenticated user text matching the old marker must remain unchanged");
        assert_true(message.body == stored,
            "Changing the UI language must not rewrite the persisted diagnostic");
    }

    private void test_plain_messages() {
        foreach (Message.Type type in new Message.Type[] { Message.Type.CHAT, Message.Type.GROUPCHAT }) {
            foreach (string body in new string[] { "hello <world> & everyone", "[This OMEMO message could not be decrypted]" }) {
                var message = new Message(null) { type_ = type, encryption = Encryption.NONE, body = body };
                assert_true(!MessageDiagnostics.is_local_decryption_failure(message));
                assert_true(MessageDiagnostics.body_for_display(message) == body,
                    "Plaintext user content must not be interpreted as an OMEMO diagnostic");
            }
        }
    }

    private void test_other_messages() {
        var message = new Message(null) {
            encryption = Encryption.PGP,
            body = "[This OMEMO message could not be decrypted]"
        };
        assert_true(MessageDiagnostics.body_for_display(message) == message.body);
        message.body = null;
        assert_true(MessageDiagnostics.body_for_display(message) == null);
    }

    private void test_blocked_room() {
        string raw = "OMEMO groupchat encryption requires live private members-only non-anonymous room features";
        string displayed = MessageDiagnostics.delivery_error_for_display(raw);
        assert_true(displayed != raw && displayed.length > 0,
            "Technical private-room diagnostics need readable localized feedback");
        assert_true(MessageDiagnostics.delivery_error_for_display(null).length > 0);
        assert_true(MessageDiagnostics.delivery_error_for_display("custom server reason").contains("custom server reason"));
    }
}

}
