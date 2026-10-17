package eu.siacs.conversations.entities;

import androidx.annotation.Nullable;
import org.json.JSONException;
import org.json.JSONObject;

public record Sticker(
        String packId,
        String stickerId,
        String emoji,
        int width,
        int height,
        String format,
        String url
) {
    public static final String FORMAT_STATIC = "static";
    public static final String FORMAT_ANIMATED = "animated";
    public static final String FORMAT_ANIMATED_WEBP = "animated_webp";

    public String toJson() {
        JSONObject json = new JSONObject();
        try {
            json.put("pack_id", packId != null ? packId : "");
            json.put("sticker_id", stickerId != null ? stickerId : "");
            json.put("emoji", emoji != null ? emoji : "");
            json.put("width", width);
            json.put("height", height);
            json.put("format", format != null ? format : FORMAT_STATIC);
            json.put("url", url != null ? url : "");
            return json.toString();
        } catch (JSONException e) {
            return "{}";
        }
    }

    @Nullable
    public static Sticker fromJson(String jsonStr) {
        if (jsonStr == null || !jsonStr.startsWith("{")) {
            return null;
        }
        try {
            JSONObject json = new JSONObject(jsonStr);
            if (!json.has("pack_id") && !json.has("sticker_id")) {
                return null;
            }
            return new Sticker(
                    json.optString("pack_id", ""),
                    json.optString("sticker_id", ""),
                    json.optString("emoji", ""),
                    json.optInt("width", 512),
                    json.optInt("height", 512),
                    json.optString("format", FORMAT_STATIC),
                    json.optString("url", "")
            );
        } catch (JSONException e) {
            return null;
        }
    }
}
