package im.conversations.android.xmpp.model.limits;

import com.google.common.base.Optional;
import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.StreamFeature;
import java.time.Duration;

@XmlElement
public class Limits extends StreamFeature {
    public Limits() {
        super(Limits.class);
    }

    public Optional<Duration> getIdleSeconds() {
        final var idleSeconds = this.getOnlyExtension(IdleSeconds.class);
        if (idleSeconds == null) {
            return Optional.absent();
        }
        return Optional.fromNullable(idleSeconds.asDuration());
    }
}
