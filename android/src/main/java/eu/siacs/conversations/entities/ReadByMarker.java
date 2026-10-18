package eu.siacs.conversations.entities;

import android.util.Log;
import com.google.common.base.Strings;
import com.google.common.collect.ImmutableSet;
import com.google.gson.JsonSyntaxException;
import com.google.gson.annotations.SerializedName;
import com.google.gson.reflect.TypeToken;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.xmpp.Jid;
import im.conversations.android.json.Services;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArraySet;

public record ReadByMarker(
        @SerializedName("occupantId") String occupantId,
        @SerializedName("fullJid") Jid fullJid,
        @SerializedName("realJid") Jid realJid)
        implements MucOptions.IdentifiableUser {

    public static ReadByMarker from(final Message message) {
        return new ReadByMarker(
                message.getOccupantId(), message.getCounterpart(), message.getTrueCounterpart());
    }

    public static ReadByMarker from(final MucOptions.User user) {
        return new ReadByMarker(user.getOccupantId(), user.getFullJid(), user.getRealJid());
    }

    public static Set<ReadByMarker> from(Collection<MucOptions.User> users) {
        final Set<ReadByMarker> markers = new CopyOnWriteArraySet<>();
        for (MucOptions.User user : users) {
            markers.add(from(user));
        }
        return markers;
    }

    public static Set<ReadByMarker> fromJsonString(final String json) {
        if (Strings.isNullOrEmpty(json)) {
            return Collections.emptySet();
        }
        final List<ReadByMarker> markers;
        try {
            markers =
                    Services.GSON.fromJson(json, new TypeToken<List<ReadByMarker>>() {}.getType());
        } catch (final JsonSyntaxException e) {
            Log.e(Config.LOGTAG, "could not parse read marker from json", e);
            return Collections.emptySet();
        }
        return ImmutableSet.copyOf(markers);
    }

    public static boolean contains(
            final ReadByMarker needle, final Set<ReadByMarker> readByMarkers) {
        for (final ReadByMarker marker : readByMarkers) {
            if (marker.occupantId != null && needle.occupantId != null) {
                if (marker.occupantId.equals(needle.occupantId)) {
                    return true;
                }
            } else if (marker.realJid != null && needle.realJid != null) {
                if (marker.realJid.asBareJid().equals(needle.realJid.asBareJid())) {
                    return true;
                }
            } else if (marker.fullJid != null && needle.fullJid != null) {
                if (marker.fullJid.equals(needle.fullJid)) {
                    return true;
                }
            }
        }
        return false;
    }

    public static boolean allUsersRepresented(
            final Collection<MucOptions.User> users, final Set<ReadByMarker> markers) {
        for (final var user : users) {
            if (!contains(from(user), markers)) {
                return false;
            }
        }
        return true;
    }

    public static boolean allUsersRepresented(
            final Collection<MucOptions.User> users,
            final Set<ReadByMarker> markers,
            final ReadByMarker marker) {
        final Set<ReadByMarker> markersCopy = new CopyOnWriteArraySet<>(markers);
        markersCopy.add(marker);
        return allUsersRepresented(users, markersCopy);
    }

    @Override
    public Jid mucUserAddress() {
        return this.fullJid;
    }

    @Override
    public Jid mucUserRealAddress() {
        final var address = this.realJid;
        return address == null ? null : address.asBareJid();
    }

    @Override
    public String mucUserOccupantId() {
        return this.occupantId;
    }
}
