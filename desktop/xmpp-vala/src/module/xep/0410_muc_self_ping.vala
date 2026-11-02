namespace Xmpp.Xep.MucSelfPing {

    public enum JoinState {
        JOINED,
        NOT_JOINED,
        UNKNOWN
    }

    public static async JoinState get_join_state(XmppStream stream, Jid jid) {
        Iq.Stanza? iq_result = yield stream.get_module<Xmpp.Xep.Ping.Module>(Xmpp.Xep.Ping.Module.IDENTITY).send_ping_with_options(stream, jid, Priority.DEFAULT, true);
        if (iq_result == null) return JoinState.UNKNOWN;

        if (!((!) iq_result).is_error()) {
            return JoinState.JOINED;
        } else {
            var error_stanza = ((!) iq_result).get_error();
            if (error_stanza != null) {
                switch (((!) error_stanza).condition) {
                    case ErrorStanza.CONDITION_SERVICE_UNAVAILABLE:
                    case ErrorStanza.CONDITION_FEATURE_NOT_IMPLEMENTED:
                    case ErrorStanza.CONDITION_ITEM_NOT_FOUND:
                        // The client is joined, but the pinged client does not implement XMPP Ping.
                        // item-not-found can also happen after a nick change while the room join is still valid.
                        return JoinState.JOINED;
                    case ErrorStanza.CONDITION_REMOTE_SERVER_NOT_FOUND:
                    case ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT:
                        return JoinState.UNKNOWN;
                    case ErrorStanza.CONDITION_NOT_ACCEPTABLE:
                        return JoinState.NOT_JOINED;
                    default:
                        break;
                }
            }
        }
        return JoinState.NOT_JOINED;
    }

    public static async bool is_joined(XmppStream stream, Jid jid) {
        return (yield get_join_state(stream, jid)) == JoinState.JOINED;
    }

}
