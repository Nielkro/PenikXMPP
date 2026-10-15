package im.conversations.android.xmpp.model.fun;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamElement;

@XmlElement
public class Enabled extends StreamElement {

    public Enabled() {
        super(Enabled.class);
    }

    public Enabled(final String dict) {
        super(Enabled.class);
        if (dict != null) {
            this.setAttribute("dict", dict);
        }
    }

    public String getDict() {
        return this.getAttribute("dict");
    }
}
