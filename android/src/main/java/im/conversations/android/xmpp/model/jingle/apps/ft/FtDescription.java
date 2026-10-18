package im.conversations.android.xmpp.model.jingle.apps.ft;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.jingle.Description;

@XmlElement(name = "description")
public class FtDescription extends Description {

    public FtDescription() {
        super(FtDescription.class);
    }
}
