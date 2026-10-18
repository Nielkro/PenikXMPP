package im.conversations.android.xmpp.model.vcard;

import eu.siacs.conversations.xml.Element;
import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;

@XmlElement(name = "vCard")
public class VCard extends Extension {

    public VCard() {
        super(VCard.class);
    }

    public Photo getPhoto() {
        return this.getExtension(Photo.class);
    }

    public String getPhoneNumber() {
        final Element tel = findChild("TEL");
        if (tel != null) {
            final String number = tel.findChildContent("NUMBER");
            if (number != null && !number.trim().isEmpty()) {
                return number.trim();
            }
            final String content = tel.getContent();
            if (content != null && !content.trim().isEmpty()) {
                return content.trim();
            }
        }
        return null;
    }

    public void setPhoneNumber(final String number) {
        final Element tel = findChild("TEL");
        if (tel != null) {
            this.children.remove(tel);
        }
        if (number != null && !number.trim().isEmpty()) {
            final Element newTel = new Element("TEL");
            final Element numElem = new Element("NUMBER");
            numElem.setContent(number.trim());
            newTel.addChild(numElem);
            this.addChild(newTel);
        }
    }
}
