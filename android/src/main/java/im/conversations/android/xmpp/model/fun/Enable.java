package im.conversations.android.xmpp.model.fun;

import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamElement;

@XmlElement
public class Enable extends StreamElement {

    public Enable() {
        super(Enable.class);
    }

    public Enable(final String dict) {
        super(Enable.class);
        if (dict != null) {
            this.setAttribute("dict", dict);
        }
    }

    public String getDict() {
        return this.getAttribute("dict");
    }
}
