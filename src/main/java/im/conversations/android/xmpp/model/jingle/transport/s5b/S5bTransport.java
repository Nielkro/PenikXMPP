package im.conversations.android.xmpp.model.jingle.transport.s5b;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.jingle.Transport;

@XmlElement(name = "transport")
public class S5bTransport extends Transport {
    public S5bTransport() {
        super(S5bTransport.class);
    }
}
