using Dino.Entities;
using Xmpp;

namespace Dino.Test {

class MucVoiceRequestManagerAudit : Gee.TestCase {
    public MucVoiceRequestManagerAudit() {
        base("MucVoiceRequestManagerAudit");
        add_test("deduplicates_only_exact_request", test_exact_deduplication);
        add_test("keeps_requesters_accounts_and_rooms_isolated",
            test_scope_isolation);
        add_test("role_lifecycle_removes_only_stale_nickname",
            test_role_lifecycle);
        add_test("confirmed_unmute_allows_fresh_remute_request",
            test_confirmed_unmute_then_remute);
        add_test("room_reset_and_own_role_loss_are_scoped",
            test_room_reset_and_own_role_loss);
        add_test("response_lifecycle_is_correlated_and_remute_is_new",
            test_response_lifecycle);
        add_test("own_request_is_correlated_and_retries_are_fresh",
            test_own_request_correlation);
        add_test("own_request_lifecycle_is_account_and_room_scoped",
            test_own_request_lifecycle_scope);
    }

    private void test_exact_deduplication() {
        try {
            Account account = make_account(1, "mod@example.test");
            Jid room = new Jid("room@conference.example.test");
            Jid requester = new Jid("alice@example.test/phone");
            var manager = new MucVoiceRequestManager.for_tests();
            int received = 0;
            int changed = 0;
            int removed = 0;
            string? last_removed_id = null;
            manager.request_received.connect(() => { received++; });
            manager.requests_changed.connect(() => { changed++; });
            manager.request_removed.connect((request) => {
                removed++;
                last_removed_id = request.id;
            });

            PendingMucVoiceRequest first = manager.receive_for_tests(account,
                room, requester, "Alice", "request-1");
            PendingMucVoiceRequest duplicate = manager.receive_for_tests(
                account, room, requester.bare_jid, "Alice", "request-1");

            fail_if(first != duplicate,
                "An exact repeated request must refresh one stable object");
            fail_if(received != 1 || changed != 1,
                "Exact pending duplicate must not create a second notification");
            fail_if(manager.get_pending_requests(account, room).size != 1,
                "Exact duplicate must occupy one store entry");
            fail_if(first.from_jid.is_full(),
                "Requester identity must be normalized to a bare JID");
            fail_if_not(first.request_jid.equals(requester),
                "The exact form JID must remain available for the response");

            Jid newer_resource = new Jid("alice@example.test/tablet");
            PendingMucVoiceRequest refreshed = manager.receive_for_tests(
                account, room, newer_resource, "Alice", "request-1");
            fail_if(refreshed != first ||
                    !first.request_jid.equals(newer_resource),
                "A newer full form JID must refresh the same stable request");

            PendingMucVoiceRequest fresh = manager.receive_for_tests(account,
                room, newer_resource, "Alice", "request-2");
            fail_if(fresh == first || fresh.id == first.id || received != 2 ||
                    manager.get_request(first.id) != null ||
                    manager.get_request(fresh.id) == null,
                "The same requester with a new stanza id must notify as a fresh request");
            fail_if(removed != 1 || last_removed_id != first.id,
                "Replacing a pending request must retract its predecessor exactly once");

            manager.room_reset_for_tests(account, room);
            manager.room_reset_for_tests(account, room);
            fail_if(removed != 2 || last_removed_id != fresh.id,
                "Lifecycle cleanup must retract each live request exactly once");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request store error: $(e.message)");
        }
    }

    private void test_scope_isolation() {
        try {
            Account first_account = make_account(1, "one@example.test");
            Account second_account = make_account(2, "two@example.test");
            Jid first_room = new Jid("one@conference.example.test");
            Jid second_room = new Jid("two@conference.example.test");
            Jid alice = new Jid("alice@example.test");
            Jid bob = new Jid("bob@example.test");
            var manager = new MucVoiceRequestManager.for_tests();

            PendingMucVoiceRequest first = manager.receive_for_tests(
                first_account, first_room, alice, "Guest");
            PendingMucVoiceRequest other_requester = manager.receive_for_tests(
                first_account, first_room, bob, "Guest");
            PendingMucVoiceRequest other_nick = manager.receive_for_tests(
                first_account, first_room, alice, "Guest-2");
            PendingMucVoiceRequest other_room = manager.receive_for_tests(
                first_account, second_room, alice, "Guest");
            PendingMucVoiceRequest other_account = manager.receive_for_tests(
                second_account, first_room, alice, "Guest");

            fail_if(first.id == other_requester.id ||
                    first.id == other_nick.id || first.id == other_room.id ||
                    first.id == other_account.id,
                "Different identity scopes must never collapse into one request");
            fail_if(manager.get_pending_requests(first_account, first_room).size != 3,
                "Account and room query must return only its three requests");
            fail_if(manager.get_pending_requests(first_account, second_room).size != 1,
                "Second room must retain an independent request");
            fail_if(manager.get_pending_requests(second_account, first_room).size != 1,
                "Second account must retain an independent request");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request scope error: $(e.message)");
        }
    }

    private void test_role_lifecycle() {
        try {
            Account account = make_account(3, "mod@example.test");
            Jid room = new Jid("room@conference.example.test");
            var manager = new MucVoiceRequestManager.for_tests();
            PendingMucVoiceRequest alice = manager.receive_for_tests(account,
                room, new Jid("alice@example.test"), "Alice");
            PendingMucVoiceRequest bob = manager.receive_for_tests(account,
                room, new Jid("bob@example.test"), "Bob");

            manager.role_for_tests(account, room.with_resource("Alice"), null);
            manager.role_for_tests(account, room.with_resource("Alice"),
                Xep.Muc.Role.VISITOR);
            fail_if(manager.get_request(alice.id) == null,
                "Unknown or visitor role must preserve a pending request");

            manager.role_for_tests(account, room.with_resource("Alice"),
                Xep.Muc.Role.PARTICIPANT);
            fail_if(manager.get_request(alice.id) != null,
                "A non-visitor role must make that nickname request stale");
            fail_if(manager.get_request(bob.id) == null,
                "Role cleanup for one nickname must not remove another requester");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request role error: $(e.message)");
        }
    }

    private void test_room_reset_and_own_role_loss() {
        try {
            Account account = make_account(4, "mod@example.test");
            Jid first_room = new Jid("one@conference.example.test");
            Jid second_room = new Jid("two@conference.example.test");
            Jid requester = new Jid("guest@example.test");
            var manager = new MucVoiceRequestManager.for_tests();
            PendingMucVoiceRequest reset = manager.receive_for_tests(account,
                first_room, requester, "Guest-2");
            PendingMucVoiceRequest retained = manager.receive_for_tests(
                account, second_room, requester, "Guest");

            manager.room_reset_for_tests(account, first_room);
            fail_if(manager.get_request(reset.id) != null,
                "Room lifecycle reset must remove remaining room requests");
            fail_if(manager.get_request(retained.id) == null,
                "Room lifecycle reset must not affect another room");

            manager.role_for_tests(account,
                second_room.with_resource("Moderator"),
                Xep.Muc.Role.PARTICIPANT, true);
            fail_if(manager.get_request(retained.id) != null,
                "Losing the moderator role must remove every room request");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request cleanup error: $(e.message)");
        }
    }

    private void test_confirmed_unmute_then_remute() {
        try {
            Account account = make_account(6, "mod@example.test");
            Jid room = new Jid("room@conference.example.test");
            Jid requester = new Jid("guest@example.test/phone");
            var manager = new MucVoiceRequestManager.for_tests();
            int received = 0;
            manager.request_received.connect(() => { received++; });

            PendingMucVoiceRequest before_unmute =
                manager.receive_for_tests(account, room, requester, "Guest",
                    "before-unmute");
            manager.confirmed_role_for_tests(account,
                room.with_resource("Guest"), Xep.Muc.Role.PARTICIPANT);
            fail_if(manager.get_request(before_unmute.id) != null,
                "A successful local unmute must clear the pending request even without broadcast presence");

            PendingMucVoiceRequest after_remute =
                manager.receive_for_tests(account, room, requester, "Guest",
                    "after-remute");
            fail_if(after_remute.id == before_unmute.id || received != 2 ||
                    manager.get_request(after_remute.id) == null,
                "A later remute form must create and notify one fresh request");
        } catch (Error e) {
            fail_if_reached(@"Unexpected manual unmute/remute error: $(e.message)");
        }
    }

    private void test_response_lifecycle() {
        try {
            Account account = make_account(5, "mod@example.test");
            Jid room = new Jid("room@conference.example.test");
            var manager = new MucVoiceRequestManager.for_tests();
            int responses_started = 0;
            manager.request_response_started.connect((request) => {
                responses_started++;
            });
            PendingMucVoiceRequest rejected = manager.receive_for_tests(
                account, room, new Jid("guest@example.test/phone"), "Guest");
            manager.responding_for_tests(rejected);
            manager.responding_for_tests(rejected);
            fail_if(responses_started != 1,
                "A response transition must deactivate its desktop action exactly once");
            int failures = 0;
            manager.request_action_failed.connect((request, condition, text) => {
                if (request == rejected) failures++;
            });

            manager.response_failure_for_tests(account, room, rejected.id,
                ErrorStanza.CONDITION_FORBIDDEN, "role changed");
            fail_if(rejected.state != MucVoiceRequestState.PENDING ||
                    manager.get_request(rejected.id) == null || failures != 1,
                "Server rejection must reopen exactly the correlated request");

            PendingMucVoiceRequest accepted = manager.receive_for_tests(
                account, room, new Jid("other@example.test"), "Other");
            manager.responding_for_tests(accepted);
            manager.role_for_tests(account, room.with_resource("Other"),
                Xep.Muc.Role.PARTICIPANT);
            fail_if(manager.get_request(accepted.id) != null,
                "Participant presence must confirm and remove an accepting request");

            PendingMucVoiceRequest denied = manager.receive_for_tests(
                account, room, new Jid("deny@example.test"), "Denied");
            manager.responding_for_tests(denied);
            fail_if(denied.state != MucVoiceRequestState.RESPONDING ||
                    manager.get_pending_requests(account, room).contains(denied),
                "A sent denial must remain correlated but disappear from pending UI");
            manager.response_settled_for_tests(account, room, denied.id);
            fail_if(manager.get_request(denied.id) != null,
                "Protocol settlement must remove the correlated denial");

            PendingMucVoiceRequest old = manager.receive_for_tests(account,
                room, new Jid("again@example.test/phone"), "Again",
                "again-1");
            manager.responding_for_tests(old);
            PendingMucVoiceRequest response_retransmission =
                manager.receive_for_tests(account, room,
                    new Jid("again@example.test/tablet"), "Again",
                    "again-1");
            fail_if(response_retransmission != old ||
                    manager.get_request(old.id) == null,
                "An exact stanza retransmission while responding must not create a fresh request");
            PendingMucVoiceRequest fresh = manager.receive_for_tests(account,
                room, new Jid("again@example.test/tablet"), "Again",
                "again-2");
            fail_if(fresh == old || fresh.id == old.id ||
                    manager.get_request(old.id) != null ||
                    manager.get_request(fresh.id) == null,
                "A repeated room request while responding must be a fresh request");
            manager.response_failure_for_tests(account, room, old.id,
                ErrorStanza.CONDITION_FORBIDDEN, "old response");
            fail_if(fresh.state != MucVoiceRequestState.PENDING,
                "A late error for the old response must not mutate the remute request");
            fail_if(responses_started != 4,
                "Each distinct response transition must be announced exactly once");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice approval state error: $(e.message)");
        }
    }

    private void test_own_request_correlation() {
        try {
            Account account = make_account(7, "guest@example.test");
            Jid room = new Jid("room@conference.example.test");
            var manager = new MucVoiceRequestManager.for_tests();
            int failures = 0;
            manager.own_request_failed.connect(() => { failures++; });

            fail_if_not(manager.own_request_start_for_tests(account, room,
                "attempt-1"), "The first local request must start");
            fail_if(manager.own_request_start_for_tests(account, room,
                "double-click"),
                "A second activation while SENDING must not start");
            OwnMucVoiceRequest first = (!) manager.get_own_request(account,
                room);
            fail_if(first.id != "attempt-1" ||
                    first.state != OwnMucVoiceRequestState.SENDING,
                "The atomic SENDING fence must retain the first attempt");

            manager.own_request_sent_for_tests(account, room, "stale");
            manager.own_request_failure_for_tests(account, room, "stale",
                ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "old error");
            fail_if(first.state != OwnMucVoiceRequestState.SENDING ||
                    failures != 0,
                "A stale completion or error must not mutate the current attempt");

            manager.own_request_sent_for_tests(account, room, "attempt-1");
            fail_if(first.state != OwnMucVoiceRequestState.SENT,
                "The matching local completion must transition to SENT");
            fail_if_not(manager.own_request_start_for_tests(account, room,
                "attempt-2"),
                "A SENT attempt must allow one fresh request");
            OwnMucVoiceRequest second = (!) manager.get_own_request(account,
                room);
            fail_if(second == first || second.id != "attempt-2" ||
                    second.state != OwnMucVoiceRequestState.SENDING,
                "A retry must replace SENT with a fresh correlation ID");

            manager.own_request_failure_for_tests(account, room, "attempt-1",
                ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "late first");
            manager.own_request_sent_for_tests(account, room, "attempt-1");
            fail_if(second.state != OwnMucVoiceRequestState.SENDING ||
                    failures != 0,
                "Late events from the replaced attempt must remain stale");

            manager.own_request_sent_for_tests(account, room, "attempt-2");
            fail_if(second.state != OwnMucVoiceRequestState.SENT,
                "The current retry must transition to SENT after local completion");
            manager.own_request_failure_for_tests(account, room, "attempt-2",
                ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "Please wait");
            fail_if(second.state != OwnMucVoiceRequestState.FAILED ||
                    second.condition !=
                        ErrorStanza.CONDITION_RESOURCE_CONSTRAINT ||
                    second.text != "Please wait" || failures != 1,
                "Only the matching error must expose one FAILED attempt");
            fail_if_not(manager.own_request_start_for_tests(account, room,
                "attempt-3"),
                "A FAILED attempt must allow one fresh request");
            OwnMucVoiceRequest third = (!)
                manager.get_own_request(account, room);
            fail_if(third.id != "attempt-3",
                "Retry after FAILED must use a new correlation ID");
        } catch (Error e) {
            fail_if_reached(@"Unexpected own voice request correlation error: $(e.message)");
        }
    }

    private void test_own_request_lifecycle_scope() {
        try {
            Account first_account = make_account(8, "one@example.test");
            Account second_account = make_account(9, "two@example.test");
            Jid first_room = new Jid("one@conference.example.test");
            Jid second_room = new Jid("two@conference.example.test");
            var manager = new MucVoiceRequestManager.for_tests();

            manager.own_request_start_for_tests(first_account, first_room,
                "participant-clear");
            manager.own_request_start_for_tests(first_account, second_room,
                "other-room");
            manager.own_request_start_for_tests(second_account, first_room,
                "other-account");
            manager.role_for_tests(first_account,
                first_room.with_resource("Guest"),
                Xep.Muc.Role.PARTICIPANT, true);
            fail_if(manager.get_own_request(first_account, first_room) != null,
                "Own participant presence must clear the completed request");
            fail_if(manager.get_own_request(first_account, second_room) == null ||
                    manager.get_own_request(second_account, first_room) == null,
                "Role cleanup must stay scoped to one account and room");

            manager.role_for_tests(first_account,
                first_room.with_resource("Guest"), Xep.Muc.Role.VISITOR,
                true);
            fail_if(manager.get_own_request(first_account, first_room) != null,
                "A later remute to visitor must keep the cleared state READY");
            manager.own_request_start_for_tests(first_account, first_room,
                "moderator-clear");
            manager.role_for_tests(first_account,
                first_room.with_resource("Guest"),
                Xep.Muc.Role.MODERATOR, true);
            fail_if(manager.get_own_request(first_account, first_room) != null,
                "Own moderator presence must also clear the request state");

            manager.own_request_start_for_tests(first_account, first_room,
                "leave-clear");
            manager.left_for_tests(first_account, first_room);
            fail_if(manager.get_own_request(first_account, first_room) != null,
                "Leaving the room must clear its own request state");
            manager.own_request_start_for_tests(first_account, first_room,
                "join-clear");
            manager.joined_for_tests(first_account, first_room);
            fail_if(manager.get_own_request(first_account, first_room) != null,
                "Joining the room must start with READY request state");

            manager.disconnected_for_tests(first_account);
            fail_if(manager.get_own_request(first_account, second_room) != null,
                "Disconnect must clear every own request for that account");
            fail_if(manager.get_own_request(second_account, first_room) == null,
                "Disconnect must preserve another account's request");

            manager.own_request_start_for_tests(first_account, first_room,
                "account-removal");
            manager.account_removed_for_tests(first_account);
            fail_if(manager.get_own_request(first_account, first_room) != null ||
                    manager.get_own_request(second_account, first_room) == null,
                "Account removal must clear only the removed account");
        } catch (Error e) {
            fail_if_reached(@"Unexpected own voice request lifecycle error: $(e.message)");
        }
    }

    private static Account make_account(int id, string jid) throws Error {
        var account = new Account(new Jid(jid), "password");
        account.id = id;
        return account;
    }
}

}
