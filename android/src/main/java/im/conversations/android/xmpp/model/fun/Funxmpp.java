package im.conversations.android.xmpp.model.fun;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamFeature;

@XmlElement
public class Funxmpp extends StreamFeature {

    public Funxmpp() {
        super(Funxmpp.class);
    }

    public String getDict() {
        return this.getAttribute("dict");
    }

    public String getVersion() {
        return this.getAttribute("version");
    }
}
