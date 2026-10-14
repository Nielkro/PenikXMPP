package im.conversations.android.xmpp.model.compress;

import eu.siacs.conversations.xml.Element;
import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamElement;

@XmlElement(name = "compress")
public class Compress extends StreamElement {

    public Compress() {
        super(Compress.class);
    }

    public Compress(final String method) {
        super(Compress.class);
        final var methodElement = new Element("method");
        methodElement.setContent(method);
        this.addChild(methodElement);
    }
}
