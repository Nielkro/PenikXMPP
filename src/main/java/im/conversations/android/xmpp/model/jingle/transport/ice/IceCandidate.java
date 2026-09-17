package im.conversations.android.xmpp.model.jingle.transport.ice;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement(name = "candidate")
public class IceCandidate extends Extension {

    public IceCandidate() {
        super(IceCandidate.class);
    }
}
