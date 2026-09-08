package im.conversations.android.xmpp.model.last;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement
public class Query extends Extension {

    public Query() {
        super(Query.class);
    }
}
