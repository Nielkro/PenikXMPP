package im.conversations.android.xmpp.model.limits;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement
public class MaxBytes extends Extension {

    public MaxBytes() {
        super(MaxBytes.class);
    }
}
