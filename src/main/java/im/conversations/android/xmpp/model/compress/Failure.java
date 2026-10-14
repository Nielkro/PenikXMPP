package im.conversations.android.xmpp.model.compress;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamElement;

@XmlElement(name = "failure")
public class Failure extends StreamElement {

    public Failure() {
        super(Failure.class);
    }
}
