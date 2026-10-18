package im.conversations.android.xmpp.model.jingle.apps.rtp;

import eu.siacs.conversations.xmpp.jingle.Media;
import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.jingle.Description;

@XmlElement(name = "description")
public class RtpDescription extends Description {
    public RtpDescription() {
        super(RtpDescription.class);
    }

    public void setMedia(final Media media) {
        this.setAttribute("media", media);
    }
}
