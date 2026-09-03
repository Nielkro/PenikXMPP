package eu.siacs.conversations.entities;

import android.util.Log;
import com.google.common.base.Strings;
import com.google.gson.JsonSyntaxException;
import com.google.gson.annotations.SerializedName;
import com.google.gson.reflect.TypeToken;
import eu.siacs.conversations.Config;
import im.conversations.android.json.Services;
import java.time.Instant;
import java.util.Collections;
import java.util.List;

public record Edit(
        String id,
        @SerializedName("server_msg_id") String serverMsgId,
        Instant sentAt,
        String body,
        Integer encryption,
        String fingerprint) {

    static boolean wasPreviouslyEditedRemoteMsgId(
            final List<Edit> edits, final String remoteMsgId) {
        for (final var edit : edits) {
            if (edit.id != null && edit.id.equals(remoteMsgId)) {
                return true;
            }
        }
        return false;
    }

    static boolean wasPreviouslyEditedServerMsgId(
            final List<Edit> edits, final String serverMsgId) {
        for (final var edit : edits) {
            if (edit.serverMsgId != null && edit.serverMsgId.equals(serverMsgId)) {
                return true;
            }
        }
        return false;
    }

    public static List<Edit> ofString(final String string) {
        if (Strings.isNullOrEmpty(string)) {
            return Collections.emptyList();
        }
        try {
            return Services.GSON.fromJson(string, new TypeToken<List<Edit>>() {}.getType());
        } catch (final JsonSyntaxException e) {
            Log.w(Config.LOGTAG, "could not parse edits");
            return Collections.emptyList();
        }
    }

    public Message.BodyVersion asBodyVersion() {
        return new Message.BodyVersion(
                body, encryption == null ? Message.ENCRYPTION_NONE : encryption, fingerprint);
    }

    public Edit withBody(final Message.BodyVersion body) {
        return new Edit(
                this.id,
                this.serverMsgId,
                this.sentAt,
                body.body(),
                body.encryption(),
                body.fingerprint());
    }
}
