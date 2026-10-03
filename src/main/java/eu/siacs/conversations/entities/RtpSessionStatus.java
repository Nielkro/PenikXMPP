package eu.siacs.conversations.entities;

import androidx.annotation.DrawableRes;

import com.google.common.base.Strings;

import eu.siacs.conversations.R;

public class RtpSessionStatus {

    public final boolean successful;
    public final long duration;
    public final String media;


    public RtpSessionStatus(boolean successful, long duration) {
        this(successful, duration, null);
    }

    public RtpSessionStatus(boolean successful, long duration, final String media) {
        this.successful = successful;
        this.duration = duration;
        this.media = media;
    }

    @Override
    public String toString() {
        return successful + ":" + duration + (media == null ? "" : ":" + media);
    }

    public static RtpSessionStatus of(final String body) {
        final String[] parts = Strings.nullToEmpty(body).split(":", 3);
        long duration = 0;
        if (parts.length >= 2) {
            try {
                duration = Long.parseLong(parts[1]);
            } catch (NumberFormatException e) {
                //do nothing
            }
        }
        boolean made;
        try {
            made = Boolean.parseBoolean(parts[0]);
        } catch (Exception e) {
            made = false;
        }
        final String media = parts.length >= 3 && !parts[2].isEmpty() ? parts[2] : null;
        return new RtpSessionStatus(made, duration, media);
    }

    public static @DrawableRes int getDrawable(final boolean received, final boolean successful) {
        if (received) {
            if (successful) {
                return R.drawable.ic_call_received_24dp;
            } else {
                return R.drawable.ic_call_missed_24db;
            }
        } else {
            if (successful) {
                return R.drawable.ic_call_made_24dp;
            } else {
                return R.drawable.ic_call_missed_outgoing_24dp;
            }
        }
    }
}
