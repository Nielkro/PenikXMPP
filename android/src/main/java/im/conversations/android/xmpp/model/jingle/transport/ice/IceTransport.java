package im.conversations.android.xmpp.model.jingle.transport.ice;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.jingle.Transport;

@XmlElement(name = "transport")
public class IceTransport extends Transport {
    public IceTransport() {
        super(IceTransport.class);
    }
}
