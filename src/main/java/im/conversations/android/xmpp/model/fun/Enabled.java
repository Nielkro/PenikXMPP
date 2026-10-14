package im.conversations.android.xmpp.model.fun;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamElement;

@XmlElement
public class Enabled extends StreamElement {

    public Enabled() {
        super(Enabled.class);
    }
}
