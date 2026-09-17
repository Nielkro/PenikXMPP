package im.conversations.android.xmpp.model.jingle.apps.rtp;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement
public class PayloadType extends Extension {
    public PayloadType() {
        super(PayloadType.class);
    }
}
