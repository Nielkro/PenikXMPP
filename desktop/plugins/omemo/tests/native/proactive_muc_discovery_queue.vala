using Dino.Entities;
using Dino.Plugins.Omemo;
using Xmpp;

namespace Omemo.Test {

class ProactiveMucDiscoveryQueueTest : Gee.TestCase {
    public ProactiveMucDiscoveryQueueTest() {
        base("ProactiveMucDiscoveryQueue");
        add_test("bounds_and_deduplicates_without_dropping", test_bounded_fifo);
        add_test("account_cancel_preserves_other_accounts", test_account_cancel);
    }

    private void test_bounded_fifo() {
        try {
            var queue = new ProactiveMucDiscoveryQueue(2);
            var account = new Account(new Jid("alice@example.test"), "secret") {
                id = 7
            };
            Jid room = new Jid("room@conference.example.test");

            for (int i = 0; i < 100; i++) {
                fail_if_not(queue.enqueue(account, room,
                    new Jid("member%d@example.test".printf(i)), 1),
                    "every unique proactive recipient must remain queued");
            }
            fail_if(queue.enqueue(account,
                new Jid("other@conference.example.test"),
                new Jid("member0@example.test"), 1),
                "the same account, generation and real JID must be deduplicated across rooms");
            fail_if(queue.queued_count != 100 || queue.active_count != 0,
                "deduplication must not drop any unique recipient");

            ProactiveMucDiscoveryHint? first = queue.take();
            ProactiveMucDiscoveryHint? second = queue.take();
            fail_if(first == null || second == null || queue.take() != null,
                "the limiter must expose exactly two concurrent slots");
            fail_if(queue.active_count != 2 || queue.queued_count != 98,
                "taking work must move, not discard, pending recipients");

            queue.complete((!) first);
            ProactiveMucDiscoveryHint? third = queue.take();
            fail_if(third == null || queue.active_count != 2 ||
                    queue.queued_count != 97,
                "completing one request must release exactly one slot");

            int completed = 3;
            queue.complete((!) second);
            queue.complete((!) third);
            while (true) {
                ProactiveMucDiscoveryHint? hint = queue.take();
                if (hint == null) break;
                queue.complete((!) hint);
                completed++;
            }
            fail_if(completed != 100 || queue.queued_count != 0 ||
                    queue.active_count != 0,
                "all unique queued recipients must eventually be delivered");
        } catch (Error e) {
            fail_if_reached("unexpected JID error: %s".printf(e.message));
        }
    }

    private void test_account_cancel() {
        try {
            var queue = new ProactiveMucDiscoveryQueue(2);
            var first_account = new Account(new Jid("alice@example.test"),
                "secret") { id = 11 };
            var second_account = new Account(new Jid("bob@example.test"),
                "secret") { id = 12 };
            Jid room = new Jid("room@conference.example.test");
            Jid first_member = new Jid("one@example.test");

            queue.enqueue(first_account, room, first_member, 3);
            queue.enqueue(first_account, room,
                new Jid("two@example.test"), 3);
            queue.enqueue(second_account, room,
                new Jid("three@example.test"), 9);
            ProactiveMucDiscoveryHint? active = queue.take();
            fail_if(active == null || ((!) active).account.id !=
                    first_account.id,
                "test setup must activate the first account's oldest hint");

            queue.cancel_account(first_account.id);
            fail_if(queue.queued_count != 1 || queue.active_count != 1,
                "account cancellation must remove only pending work and let active completion stay balanced");
            fail_if_not(queue.enqueue(first_account, room, first_member, 4),
                "a new stream generation must not be blocked by an older active request");

            queue.complete((!) active);
            ProactiveMucDiscoveryHint? other_account = queue.take();
            ProactiveMucDiscoveryHint? new_generation = queue.take();
            fail_if(other_account == null || new_generation == null ||
                    ((!) other_account).account.id != second_account.id ||
                    ((!) new_generation).generation != 4,
                "surviving FIFO work and the new generation must both remain deliverable");
            queue.complete((!) other_account);
            queue.complete((!) new_generation);
            fail_if(queue.queued_count != 0 || queue.active_count != 0,
                "completion accounting must return the limiter to empty");
        } catch (Error e) {
            fail_if_reached("unexpected JID error: %s".printf(e.message));
        }
    }
}

}
