package im.conversations.android.xmpp.model.raa;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement
public class Info extends Extension {

    public Info() {
        super(Info.class);
    }
}
