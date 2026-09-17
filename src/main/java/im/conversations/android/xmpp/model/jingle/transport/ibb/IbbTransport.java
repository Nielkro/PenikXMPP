package im.conversations.android.xmpp.model.jingle.transport.ibb;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.jingle.Transport;

@XmlElement(name = "transport")
public class IbbTransport extends Transport {
    public IbbTransport() {
        super(IbbTransport.class);
    }
}
