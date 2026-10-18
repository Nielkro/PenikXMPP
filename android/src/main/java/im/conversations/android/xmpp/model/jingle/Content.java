package im.conversations.android.xmpp.model.jingle;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement
public class Content extends Extension {

    public Content() {
        super(Content.class);
    }

    public Transport getTransport() {
        return this.getOnlyExtension(Transport.class);
    }

    public Description getDescription() {
        return this.getOnlyExtension(Description.class);
    }
}
