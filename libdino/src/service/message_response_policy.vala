using Xmpp;
using Dino.Entities;

namespace Dino {

/** Privacy gate for protocol responses that reveal message activity. */
internal class MessageResponsePolicy : Object {
    public static bool may_send_displayed(StreamInteractor stream_interactor,
            Conversation conversation, Entities.Message message) {
        return sender_may_see_presence(stream_interactor, conversation,
            message);
    }

    public static bool may_send_delivery_receipt(
            StreamInteractor stream_interactor, Conversation conversation,
            Entities.Message message) {
        return sender_may_see_presence(stream_interactor, conversation,
            message);
    }

    internal static bool allows_roster_subscription(string? subscription) {
        return subscription == Roster.Item.SUBSCRIPTION_FROM ||
            subscription == Roster.Item.SUBSCRIPTION_BOTH;
    }

    private static bool sender_may_see_presence(
            StreamInteractor stream_interactor, Conversation conversation,
            Entities.Message message) {
        if (message.direction != Entities.Message.DIRECTION_RECEIVED ||
                message.from == null) return false;

        Jid sender = (!) message.from;
        BlockingManager blocking = stream_interactor.get_module<
            BlockingManager>(BlockingManager.IDENTITY);
        if (blocking.is_blocked(conversation.account, sender.bare_jid)) {
            return false;
        }

        if (conversation.type_.is_muc_semantic()) {
            if (!sender.is_full() || !sender.equals_bare(
                    conversation.counterpart)) return false;

            MucManager muc_manager = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            if (!muc_manager.is_current_occupant(conversation.account,
                    conversation.counterpart.bare_jid, sender)) return false;
            if (conversation.type_ == Conversation.Type.GROUPCHAT_PM &&
                    (conversation.muc_pm_peer_identity == null ||
                        !muc_manager.private_message_peer_identity_matches(
                            conversation.account, sender,
                            (!) conversation.muc_pm_peer_identity))) {
                return false;
            }
            return true;
        }

        Roster.Item? roster_item = stream_interactor.get_module<RosterManager>(
            RosterManager.IDENTITY).get_roster_item(conversation.account,
                sender.bare_jid);
        return roster_item != null &&
            allows_roster_subscription(((!) roster_item).subscription);
    }
}

}
