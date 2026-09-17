package im.conversations.android.xmpp.model.jingle.grouping;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement
public class Content extends Extension {
    public Content() {
        super(Content.class);
    }
}
