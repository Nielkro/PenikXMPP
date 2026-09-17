package im.conversations.android.xmpp.model.jingle.transport.datachannel;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.jingle.Transport;

@XmlElement(name = "transport")
public class DataChannelTransport extends Transport {
    public DataChannelTransport() {
        super(DataChannelTransport.class);
    }
}
