using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

/**
 * Short-lived replay buffer for control stanzas that overtake persistence.
 *
 * The queue is bounded and timer-free. Entries are pruned opportunistically,
 * so it never creates a worker or timeout per conversation.
 */
internal class PendingMessageState : Object {
    public Conversation conversation { get; private set; }
    public Jid sender { get; private set; }
    public string message_id { get; private set; }
    public int64 queued_at_us { get; private set; }

    public PendingMessageState(Conversation conversation, Jid sender,
            string message_id, int64 queued_at_us) {
        this.conversation = conversation;
        this.sender = sender;
        this.message_id = message_id;
        this.queued_at_us = queued_at_us;
    }
}

internal class PendingMessageStateQueue : Object {
    internal const int MAX_ENTRIES = 128;
    internal const int64 TTL_US = 30 * TimeSpan.SECOND;

    private ArrayList<PendingMessageState> entries =
        new ArrayList<PendingMessageState>();

    internal int size { get { return entries.size; } }

    public void offer(Conversation conversation, Jid sender,
            string message_id) {
        offer_at(conversation, sender, message_id,
            GLib.get_monotonic_time());
    }

    internal void offer_at(Conversation conversation, Jid sender,
            string message_id, int64 now_us) {
        if (message_id.strip() == "") return;
        prune(now_us);

        foreach (PendingMessageState entry in entries) {
            if (entry.conversation.equals(conversation) &&
                    entry.sender.equals(sender) &&
                    entry.message_id == message_id) {
                return;
            }
        }

        if (entries.size >= MAX_ENTRIES) entries.remove_at(0);
        entries.add(new PendingMessageState(conversation, sender,
            message_id, now_us));
    }

    public Gee.List<PendingMessageState> take(Conversation conversation,
            string message_id) {
        return take_at(conversation, message_id,
            GLib.get_monotonic_time());
    }

    internal Gee.List<PendingMessageState> take_at(
            Conversation conversation, string message_id, int64 now_us) {
        prune(now_us);
        var matches = new ArrayList<PendingMessageState>();
        for (int i = entries.size - 1; i >= 0; i--) {
            PendingMessageState entry = entries[i];
            if (entry.conversation.equals(conversation) &&
                    entry.message_id == message_id) {
                matches.insert(0, entry);
                entries.remove_at(i);
            }
        }
        return matches;
    }

    public void clear_conversation(Conversation conversation) {
        for (int i = entries.size - 1; i >= 0; i--) {
            if (entries[i].conversation.equals(conversation)) {
                entries.remove_at(i);
            }
        }
    }

    public void clear_account(Account account) {
        for (int i = entries.size - 1; i >= 0; i--) {
            if (entries[i].conversation.account.equals(account)) {
                entries.remove_at(i);
            }
        }
    }

    private void prune(int64 now_us) {
        for (int i = entries.size - 1; i >= 0; i--) {
            if (now_us - entries[i].queued_at_us >= TTL_US) {
                entries.remove_at(i);
            }
        }
    }
}

}
