package im.conversations.android.xmpp.model.last;

import com.google.common.primitives.Longs;
import im.conversations.android.annotation.XmlElement;
import im.conversations.android.xmpp.model.Extension;
import java.time.Duration;
import java.time.Instant;

@XmlElement
public class Query extends Extension {

    public Query() {
        super(Query.class);
    }

    public Query(final long seconds) {
        this();
        this.setAttribute("seconds", String.valueOf(seconds));
    }

    public Long getSeconds() {
        final String seconds = this.getAttribute("seconds");
        return seconds != null ? Longs.tryParse(seconds) : null;
    }

    public Instant getInstant() {
        final Long seconds = getSeconds();
        if (seconds == null || seconds < 0) {
            return null;
        }
        return Instant.now().minus(Duration.ofSeconds(seconds));
    }
}
