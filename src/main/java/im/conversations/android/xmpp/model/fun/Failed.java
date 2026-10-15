package im.conversations.android.xmpp.model.fun;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamElement;

@XmlElement
public class Failed extends StreamElement {

    public Failed() {
        super(Failed.class);
    }
}
