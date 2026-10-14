package im.conversations.android.xmpp.model.compress;

import eu.siacs.conversations.xml.Element;
import eu.siacs.conversations.xml.Namespace;
import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamFeature;

@XmlElement(name = "compression", namespace = Namespace.COMPRESS_FEATURE)
public class Compression extends StreamFeature {

    public Compression() {
        super(Compression.class);
    }

    public boolean supportsMethod(final String method) {
        for (final Element child : this.children) {
            if ("method".equals(child.getName()) && method.equals(child.getContent())) {
                return true;
            }
        }
        return false;
    }
}
