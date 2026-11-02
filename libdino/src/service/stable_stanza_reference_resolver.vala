using Xmpp;
using Dino.Entities;

namespace Dino {

internal class StableStanzaReference : Object {
    public string id { get; private set; }
    public Jid by { get; private set; }

    public StableStanzaReference(string id, Jid by) {
        this.id = id;
        this.by = by;
    }
}

/** Resolves only server-authoritative references used by XEP-0490. */
internal class StableStanzaReferenceResolver : Object {
    public static Jid expected_authority(Conversation conversation) {
        return conversation.type_ == Conversation.Type.GROUPCHAT
            ? conversation.counterpart.bare_jid
            : conversation.account.bare_jid;
    }

    public static Jid? get_chat_item_id(Conversation conversation) {
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            return conversation.counterpart.is_full()
                ? conversation.counterpart : null;
        }
        return conversation.counterpart.bare_jid;
    }

    public static StableStanzaReference? for_message(
            Conversation conversation, Entities.Message message) {
        if (!message_is_in_conversation(conversation, message) ||
                message.stable_id == null || message.stable_id_by == null) {
            return null;
        }

        string id = (!) message.stable_id;
        Jid by = (!) message.stable_id_by;
        Jid expected_by = expected_authority(conversation);
        if (id.strip().length == 0 || !by.is_bare() ||
                !by.equals(expected_by)) {
            return null;
        }
        return new StableStanzaReference(id, by);
    }

    public static Entities.Message? resolve(StreamInteractor stream_interactor,
            Conversation conversation, string id, Jid by) {
        if (id.strip().length == 0 || !by.is_bare() ||
                !by.equals(expected_authority(conversation))) {
            return null;
        }

        Entities.Message? message = stream_interactor.get_module<
            MessageStorage>(MessageStorage.IDENTITY)
            .get_message_by_stable_reference(id, by, conversation);
        if (message == null || for_message(conversation, (!) message) == null) {
            return null;
        }
        return message;
    }

    private static bool message_is_in_conversation(Conversation conversation,
            Entities.Message message) {
        if (!message.account.equals(conversation.account) ||
                message.counterpart == null ||
                !((!) message.counterpart).equals_bare(
                    conversation.counterpart)) {
            return false;
        }

        switch (conversation.type_) {
            case Conversation.Type.CHAT:
                return message.type_ == Entities.Message.Type.CHAT;
            case Conversation.Type.GROUPCHAT:
                return message.type_ == Entities.Message.Type.GROUPCHAT;
            case Conversation.Type.GROUPCHAT_PM:
                return message.type_ == Entities.Message.Type.GROUPCHAT_PM &&
                    ((!) message.counterpart).equals(conversation.counterpart);
            default:
                return false;
        }
    }
}

}
