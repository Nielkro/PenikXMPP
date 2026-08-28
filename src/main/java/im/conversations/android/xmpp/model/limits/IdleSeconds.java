package im.conversations.android.xmpp.model.limits;

import com.google.common.primitives.Ints;
import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;
import java.time.Duration;

@XmlElement
public class IdleSeconds extends Extension {

    public IdleSeconds() {
        super(IdleSeconds.class);
    }

    public Duration asDuration() {
        final var content = getContent();
        final var seconds = content == null ? null : Ints.tryParse(content);
        return seconds == null ? null : Duration.ofSeconds(seconds);
    }
}
