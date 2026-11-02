using Dino.Entities;
using Dino.Ui.ChatInput;
using Xmpp;

namespace Dino.Ui.Test {

class RecordingSendContextTest : Gee.TestCase {
    public RecordingSendContextTest() {
        base("RecordingSendContextTest");
        add_test("recording_keeps_original_private_muc_and_account", test_keeps_original_private_muc_and_account);
        add_test("cancelled_recording_discards_send_target", test_clear_discards_target);
        add_test("second_start_preserves_active_send_target", test_second_bind_preserves_target);
        add_test("private_muc_peer_rebind_discards_recording_target", test_peer_rebind);
        add_test("same_occupant_identity_promotion_keeps_recording_target", test_identity_promotion);
        add_test("identity_promotion_then_history_clear_keeps_recording_target", test_promoted_history_clear);
        add_test("peer_return_does_not_revive_discarded_recording_target", test_peer_return);
        add_test("account_row_change_discards_recording_target", test_account_row_change);
        add_test("same_jid_recreated_account_cannot_match_snapshot", test_recreated_account);
        add_test("changed_conversation_type_or_row_cannot_match_snapshot", test_changed_conversation);
    }

    private void test_keeps_original_private_muc_and_account() {
        try {
            var original_account = new Account(new Jid("alice@example.test"), "secret");
            var other_account = new Account(new Jid("alice@other.example.test"), "secret");
            var original_conversation = new Conversation(
                new Jid("private-room@example.test/Bob"),
                original_account,
                Conversation.Type.GROUPCHAT_PM);
            var currently_visible_conversation = new Conversation(
                new Jid("private-room@example.test/Bob"),
                other_account,
                Conversation.Type.GROUPCHAT_PM);
            var context = new RecordingSendContext();

            assert_true(context.try_bind(original_conversation));
            // The visible conversation may change while the recorder finalizes.
            assert_true(currently_visible_conversation != original_conversation);

            Conversation? target = context.take();
            assert_true(target == original_conversation,
                "recorded media must be sent to the exact conversation that started the recording");
            assert_true(((!) target).account == original_account,
                "recorded media must retain the originating account");
            assert_true(((!) target).counterpart.to_string() == "private-room@example.test/Bob",
                "private-MUC media must retain the full occupant JID");
            assert_true(((!) target).type_ == Conversation.Type.GROUPCHAT_PM,
                "private-MUC media must retain the private-message conversation type");
            assert_true(context.take() == null,
                "a completed recording target must only be consumed once");
        } catch (InvalidJidError e) {
            assert_true(false, @"recording context fixture contains an invalid JID: $(e.message)");
        }
    }

    private void test_clear_discards_target() {
        try {
            var account = new Account(new Jid("alice@example.test"), "secret");
            var conversation = new Conversation(
                new Jid("bob@example.test"), account, Conversation.Type.CHAT);
            var context = new RecordingSendContext();

            assert_true(context.try_bind(conversation));
            context.clear();

            assert_true(context.take() == null,
                "cancelled or failed recordings must not retain a send target");
        } catch (InvalidJidError e) {
            assert_true(false, @"recording context fixture contains an invalid JID: $(e.message)");
        }
    }

    private void test_second_bind_preserves_target() {
        try {
            var account = new Account(new Jid("alice@example.test"), "secret");
            var first = new Conversation(
                new Jid("first@example.test"), account, Conversation.Type.CHAT);
            var second = new Conversation(
                new Jid("second@example.test"), account, Conversation.Type.CHAT);
            var context = new RecordingSendContext();

            assert_true(context.try_bind(first),
                "the first recording attempt must bind its target");
            assert_false(context.try_bind(second),
                "a repeated start must not replace the target of an active recording");

            assert_true(context.take() == first,
                "a rejected repeated start must preserve the active recording target");
        } catch (InvalidJidError e) {
            assert_true(false, @"recording context fixture contains an invalid JID: $(e.message)");
        }
    }

    private Conversation private_thread(Account account) throws InvalidJidError {
        return new Conversation(new Jid("room@example.test/Bob"), account,
            Conversation.Type.GROUPCHAT_PM) {
            id = 9, muc_pm_peer_identity = "occupant:original"
        };
    }

    private void test_peer_rebind() {
        try {
            var account = new Account(new Jid("alice@example.test"), "unused") { id = 1 };
            var thread = private_thread(account);
            var context = new RecordingSendContext();
            assert_true(context.try_bind(thread));
            thread.history_cleared_at = new DateTime.now_utc();
            thread.muc_pm_peer_identity = "occupant:replacement";
            assert_true(context.take() == null,
                "a reused room nickname must not receive the old person's recording");
            assert_true(context.take() == null,
                "a rejected stale target must be consumed and cleared");
        } catch (InvalidJidError error) { assert_true(false, error.message); }
    }

    private void test_identity_promotion() {
        try {
            var account = new Account(new Jid("alice@example.test"), "unused") { id = 1 };
            var thread = private_thread(account);
            thread.history_cleared_at = new DateTime.now_utc().add_days(-1);
            var context = new RecordingSendContext();
            assert_true(context.try_bind(thread));
            // ConversationManager promotes continuously-live occupant evidence
            // without clearing that person's thread.
            thread.muc_pm_peer_identity = "real-jid:bob@example.test";
            assert_true(context.take() == thread,
                "stronger evidence for the same occupant must preserve the recording target");
        } catch (InvalidJidError error) { assert_true(false, error.message); }
    }

    private void test_account_row_change() {
        try {
            var account = new Account(new Jid("alice@example.test"), "unused") { id = 1 };
            var thread = private_thread(account);
            var context = new RecordingSendContext();
            assert_true(context.try_bind(thread));
            account.id = 2;
            assert_true(context.take() == null,
                "the same account object with a replaced database row is not the original send target");
        } catch (InvalidJidError error) { assert_true(false, error.message); }
    }

    private void test_promoted_history_clear() {
        try {
            var account = new Account(new Jid("alice@example.test"), "unused") { id = 1 };
            var thread = private_thread(account);
            var context = new RecordingSendContext();
            assert_true(context.try_bind(thread));
            thread.muc_pm_peer_identity = "real-jid:bob@example.test";
            thread.history_cleared_at = new DateTime.now_utc();
            assert_true(context.take() == thread,
                "clearing the same person's history must preserve an identity-promoted target");
        } catch (InvalidJidError error) { assert_true(false, error.message); }
    }

    private void test_peer_return() {
        try {
            var account = new Account(new Jid("alice@example.test"), "unused") { id = 1 };
            var thread = private_thread(account);
            var context = new RecordingSendContext();
            assert_true(context.try_bind(thread));
            thread.history_cleared_at = new DateTime.now_utc();
            thread.muc_pm_peer_identity = "occupant:replacement";
            thread.muc_pm_peer_identity = "occupant:original";
            assert_true(context.take() == null,
                "a real nickname rebind permanently invalidates the pending recording");
        } catch (InvalidJidError error) { assert_true(false, error.message); }
    }

    private void test_recreated_account() {
        try {
            var account = new Account(new Jid("alice@example.test"), "unused") { id = 1 };
            var original = private_thread(account);
            var snapshot = new InputTargetSnapshot(original);
            var replacement = new Account(new Jid("alice@example.test"), "unused") { id = 2 };
            assert_true(account.equals(replacement),
                "general account equality only compares their address");
            assert_false(snapshot.matches(private_thread(replacement)),
                "send snapshots must distinguish a deleted/recreated account at the same address");
        } catch (InvalidJidError error) { assert_true(false, error.message); }
    }

    private void test_changed_conversation() {
        try {
            var account = new Account(new Jid("alice@example.test"), "unused") { id = 1 };
            var thread = private_thread(account);
            var snapshot = new InputTargetSnapshot(thread);
            thread.type_ = Conversation.Type.CHAT;
            assert_false(snapshot.matches(thread),
                "a mutable conversation must preserve its original protocol type");
            thread.type_ = Conversation.Type.GROUPCHAT_PM;
            thread.id = 10;
            assert_false(snapshot.matches(thread),
                "a replacement conversation row cannot reuse the old send snapshot");
            // Counterpart is a non-null, privately-set model property. A
            // missing selected conversation is represented by take() == null,
            // covered by the cancellation/consumption cases above.
        } catch (InvalidJidError error) { assert_true(false, error.message); }
    }
}

}
