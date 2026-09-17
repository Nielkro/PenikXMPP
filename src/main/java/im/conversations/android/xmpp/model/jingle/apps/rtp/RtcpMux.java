package im.conversations.android.xmpp.model.jingle.apps.rtp;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement
public class RtcpMux extends Extension {
    public RtcpMux() {
        super(RtcpMux.class);
    }
}
