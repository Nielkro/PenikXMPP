package eu.siacs.conversations.xmpp.mam;

public record MamReference(long timestamp, String reference) {

    public MamReference(long timestamp) {
        this(timestamp, null);
    }

    public boolean greaterThan(MamReference b) {
        return timestamp > b.timestamp();
    }

    public boolean greaterThan(long b) {
        return timestamp > b;
    }

    public static MamReference max(final MamReference a, final MamReference b) {
        if (a != null && b != null) {
            return a.timestamp > b.timestamp ? a : b;
        } else if (a != null) {
            return a;
        } else {
            return b;
        }
    }

    public static MamReference max(MamReference a, long b) {
        return max(a, new MamReference(b));
    }

    public MamReference timeOnly() {
        return reference == null ? this : new MamReference(timestamp);
    }
}
