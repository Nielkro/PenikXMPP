package im.conversations.android.xmpp.model.compress;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamElement;

@XmlElement(name = "compressed")
public class Compressed extends StreamElement {

    public Compressed() {
        super(Compressed.class);
    }
}
