using Dino.Entities;
using Xmpp;

namespace Dino.Test {

// Exercise the real FileManager transport state machine across held async
// sender stages. The sender records a dispatch without any network/profile.
class FileSendTargetScopeTest : Gee.TestCase {
    private enum Change { NONE, PROMOTE, REBIND, REBIND_AND_RETURN, ACCOUNT_ROW, DIRECT_HISTORY, ORDINARY_CANCEL }

    public FileSendTargetScopeTest() {
        base("FileSendTargetScopeTest");
        add_test("unchanged_private_target_survives_slot_preparation", test_unchanged);
        add_test("same_person_identity_promotion_survives_slot_preparation", test_promotion);
        add_test("peer_rebind_during_sender_selection_blocks_slot_and_dispatch", test_selection_rebind);
        add_test("peer_rebind_during_slot_preparation_blocks_dispatch", test_prepare_rebind);
        add_test("peer_rebind_then_return_cannot_revive_original_transfer", test_rebind_return);
        add_test("account_row_replacement_blocks_late_dispatch", test_account_row);
        add_test("direct_chat_history_clear_preserves_authorized_transfer", test_direct_history);
        add_test("jingle_scope_cancellation_handles_a_manager_without_streams", test_jingle_cancellation);
        add_test("ordinary_cancel_can_retry_with_a_fresh_cancellable", test_ordinary_cancel);
        add_test("completed_attachment_rebind_keeps_local_playback_available", test_completed_attachment);
        add_test("private_retry_without_original_provenance_fails_before_source_read", test_missing_retry_provenance);
    }

    private class HeldSender : Object, Dino.FileSender {
        public string held_stage;
        public bool entered_hold = false;
        public int prepare_calls = 0;
        public int dispatch_calls = 0;
        public string? dispatched_peer;
        private SourceFunc? resume;
        private int sender_id;

        public HeldSender(string stage, int id = 777) {
            held_stage = stage;
            sender_id = id;
        }

        private async void hold(string stage) {
            if (stage != held_stage) return;
            entered_hold = true;
            resume = hold.callback;
            yield;
        }

        public void release() {
            SourceFunc? callback = (owned) resume;
            if (callback != null) ((!) callback)();
        }

        public async bool is_upload_available(Conversation conversation) { return true; }
        public async long get_file_size_limit(Conversation conversation) { return long.MAX; }
        public async bool can_send(Conversation conversation, FileTransfer transfer) {
            yield hold("select");
            return true;
        }
        public async bool can_encrypt(Conversation conversation, FileTransfer transfer) { return false; }
        public int get_id() { return sender_id; }
        public float get_priority() { return 1; }

        public async Dino.FileSendData? prepare_send_file(Conversation conversation,
                FileTransfer transfer, Dino.FileMeta metadata) throws Dino.FileSendError {
            prepare_calls++;
            yield hold("prepare");
            return new Dino.FileSendData();
        }

        public async void send_file(Conversation conversation, FileTransfer transfer,
                Dino.FileSendData data, Dino.FileMeta metadata) throws Dino.FileSendError {
            dispatch_calls++;
            dispatched_peer = conversation.muc_pm_peer_identity;
        }
    }

    private void test_unchanged() { run_case("prepare", Change.NONE, false); }
    private void test_promotion() { run_case("prepare", Change.PROMOTE, false); }
    private void test_selection_rebind() { run_case("select", Change.REBIND, true); }
    private void test_prepare_rebind() { run_case("prepare", Change.REBIND, true); }
    private void test_rebind_return() { run_case("prepare", Change.REBIND_AND_RETURN, true); }
    private void test_account_row() { run_case("prepare", Change.ACCOUNT_ROW, true); }
    private void test_direct_history() { run_case("prepare", Change.DIRECT_HISTORY, false); }
    private void test_jingle_cancellation() { run_case("prepare", Change.REBIND, true, 1); }
    private void test_ordinary_cancel() { run_case("prepare", Change.ORDINARY_CANCEL, true); }
    private void test_completed_attachment() { run_case("prepare", Change.NONE, false, 777, true); }

    private void change_target(Conversation target, Change change, FileTransfer transfer) {
        switch (change) {
            case Change.NONE: break;
            case Change.PROMOTE:
                // ConversationManager does not clear the thread when stronger
                // evidence identifies the same continuously-live occupant.
                target.muc_pm_peer_identity = "real-jid:person-a@example.test";
                break;
            case Change.REBIND:
            case Change.REBIND_AND_RETURN:
                target.history_cleared_at = new DateTime.now_utc();
                target.muc_pm_peer_identity = "occupant:person-b";
                if (change == Change.REBIND_AND_RETURN) {
                    target.muc_pm_peer_identity = "occupant:person-a";
                }
                break;
            case Change.ACCOUNT_ROW:
                target.account.id++;
                break;
            case Change.DIRECT_HISTORY:
                target.history_cleared_at = new DateTime.now_utc();
                break;
            case Change.ORDINARY_CANCEL:
                transfer.cancellable.cancel();
                break;
        }
    }

    private void run_case(string stage, Change change, bool expected_blocked,
            int sender_id = 777, bool rebind_completed = false) {
        try {
            var account = new Account(new Jid("sender@example.test"), "unused") {
                id = 1, enabled = true
            };
            bool direct = change == Change.DIRECT_HISTORY;
            var target = new Conversation(new Jid(direct ? "peer@example.test" : "room@example.test/Bob"),
                account, direct ? Conversation.Type.CHAT : Conversation.Type.GROUPCHAT_PM) {
                id = 1, encryption = Encryption.NONE,
                muc_pm_peer_identity = direct ? null : "occupant:person-a"
            };
            var transfer = new FileTransfer() {
                account = account, counterpart = target.counterpart,
                ourpart = account.full_jid, file_name = "scope-fixture.bin",
                mime_type = "application/octet-stream", size = 1,
                encryption = Encryption.NONE, direction = FileTransfer.DIRECTION_SENT,
                time = new DateTime.now_utc(), local_time = new DateTime.now_utc(),
                input_stream = new MemoryInputStream.from_data(new uint8[] { 42 }, null)
            };
            var manager = Dino.FileManager.create_for_tests();
            var sender = new HeldSender(stage, sender_id);
            manager.add_sender(sender);
            var loop = new MainLoop();
            bool completed = false;
            bool changed = false;
            Error? operation_error = null;
            manager.send_file_transport_pipeline_for_tests.begin(target, transfer, (obj, result) => {
                try { manager.send_file_transport_pipeline_for_tests.end(result); }
                catch (Error error) { operation_error = error; }
                completed = true;
                loop.quit();
            });
            uint change_source = Timeout.add(1, () => {
                if (!sender.entered_hold) return Source.CONTINUE;
                change_target(target, change, transfer);
                changed = true;
                sender.release();
                return Source.REMOVE;
            });
            uint deadline = Timeout.add_seconds(3, () => {
                loop.quit();
                return Source.REMOVE;
            });
            if (!completed) loop.run();
            if (!changed) Source.remove(change_source);
            if (completed) Source.remove(deadline);
            fail_if_not(completed && changed, "the actual async pipeline must reach and resume its held sender stage");
            if (expected_blocked) {
                fail_if(operation_error == null, "a replaced account/person must fail before final dispatch");
                fail_if(sender.dispatch_calls != 0, "the previous person's bytes must not be handed to a new recipient");
                if (stage == "select") fail_if(sender.prepare_calls != 0,
                    "an invalid target must be rejected before requesting an upload slot");
            } else {
                fail_if(operation_error != null,
                    operation_error != null ? ((!) operation_error).message : "");
                fail_if(sender.dispatch_calls != 1 || transfer.phase != FileTransfer.Phase.COMPLETE,
                    "an unchanged or safely promoted target must retain ordinary transfer behavior");
                if (change == Change.PROMOTE) fail_if_not_eq_str(
                    "real-jid:person-a@example.test", sender.dispatched_peer);
            }
            if (change == Change.ORDINARY_CANCEL) {
                Cancellable old_cancellable = transfer.cancellable;
                if (!transfer.input_stream.is_closed()) transfer.input_stream.close();
                transfer.prepare_transfer_attempt();
                transfer.input_stream = new MemoryInputStream.from_data("x".data);
                sender.held_stage = "";
                completed = false;
                operation_error = null;
                manager.send_file_transport_pipeline_for_tests.begin(target, transfer, (obj, result) => {
                    try { manager.send_file_transport_pipeline_for_tests.end(result); }
                    catch (Error error) { operation_error = error; }
                    completed = true;
                    loop.quit();
                });
                if (!completed) loop.run();
                fail_if(operation_error != null || sender.dispatch_calls != 1,
                    "a user cancellation must not invalidate the unchanged recipient for a later attempt");
                fail_if(transfer.cancellable == old_cancellable || transfer.cancellable.is_cancelled(),
                    "ordinary retry must use a fresh uncancelled token");
            }
            if (rebind_completed) {
                change_target(target, Change.REBIND, transfer);
                fail_if(transfer.cancellable.is_cancelled() || transfer.phase != FileTransfer.Phase.COMPLETE,
                    "a later nickname owner must not cancel local playback of an already completed attachment");
            }
            if (!transfer.input_stream.is_closed()) transfer.input_stream.close();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_missing_retry_provenance() {
        try {
            var account = new Account(new Jid("sender@example.test"), "unused") { id = 1, enabled = true };
            var target = new Conversation(new Jid("room@example.test/Bob"), account,
                Conversation.Type.GROUPCHAT_PM) { id = 1, muc_pm_peer_identity = "occupant:person-a" };
            var transfer = new FileTransfer() {
                account = account, counterpart = target.counterpart, ourpart = account.full_jid,
                direction = FileTransfer.DIRECTION_SENT, file_name = "scope-fixture.bin",
                state = FileTransfer.State.FAILED, phase = FileTransfer.Phase.FAILED,
                input_stream = new MemoryInputStream.from_data("x".data), next_retry_time = 99
            };
            var manager = Dino.FileManager.create_for_tests();
            var sender = new HeldSender("");
            manager.add_sender(sender);
            var loop = new MainLoop();
            bool completed = false;
            manager.retry_send_file_for_tests.begin(target, transfer, (obj, result) => {
                manager.retry_send_file_for_tests.end(result);
                completed = true;
                loop.quit();
            });
            if (!completed) loop.run();
            fail_if(!transfer.cancellable.is_cancelled() || transfer.next_retry_time != 0 ||
                sender.prepare_calls != 0 || sender.dispatch_calls != 0 ||
                transfer.phase != FileTransfer.Phase.FAILED || transfer.phase_error == null,
                "a restored PM attachment has no safe original-person provenance and must fail before file access");
            if (!transfer.input_stream.is_closed()) transfer.input_stream.close();
        } catch (Error error) { fail_if_reached(error.message); }
    }

}

}
