package eu.siacs.conversations.entities;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class BotMarkup {
    public enum Type {
        INLINE,
        REPLY,
        REMOVE
    }

    public static class Button {
        private final String text;
        private final String data;
        private final String url;

        public Button(String text, String data, String url) {
            this.text = text;
            this.data = data;
            this.url = url;
        }

        public Button(String text) {
            this(text, null, null);
        }

        public String getText() {
            return text;
        }

        public String getData() {
            return data;
        }

        public String getUrl() {
            return url;
        }
    }

    private final Type type;
    private final boolean resizeKeyboard;
    private final boolean oneTimeKeyboard;
    private final List<List<Button>> rows;

    public BotMarkup(List<List<Button>> rows) {
        this(Type.INLINE, rows, true, false);
    }

    public BotMarkup(Type type, List<List<Button>> rows, boolean resizeKeyboard, boolean oneTimeKeyboard) {
        this.type = type != null ? type : Type.INLINE;
        this.rows = rows != null ? rows : Collections.emptyList();
        this.resizeKeyboard = resizeKeyboard;
        this.oneTimeKeyboard = oneTimeKeyboard;
    }

    public BotMarkup(Type type) {
        this(type, Collections.emptyList(), true, false);
    }

    public Type getType() {
        return type;
    }

    public boolean isResizeKeyboard() {
        return resizeKeyboard;
    }

    public boolean isOneTimeKeyboard() {
        return oneTimeKeyboard;
    }

    public boolean isInline() {
        return type == Type.INLINE;
    }

    public boolean isReply() {
        return type == Type.REPLY;
    }

    public boolean isRemove() {
        return type == Type.REMOVE;
    }

    public List<List<Button>> getRows() {
        return rows;
    }

    public boolean isEmpty() {
        return rows.isEmpty();
    }

    public String toJson() {
        try {
            JSONObject root = new JSONObject();
            root.put("type", type.name().toLowerCase());
            root.put("resize", resizeKeyboard);
            root.put("one_time", oneTimeKeyboard);
            JSONArray rowsArr = new JSONArray();
            for (List<Button> row : rows) {
                JSONArray rowArr = new JSONArray();
                for (Button btn : row) {
                    JSONObject obj = new JSONObject();
                    obj.put("text", btn.text);
                    if (btn.data != null) {
                        obj.put("data", btn.data);
                    }
                    if (btn.url != null) {
                        obj.put("url", btn.url);
                    }
                    rowArr.put(obj);
                }
                rowsArr.put(rowArr);
            }
            root.put("rows", rowsArr);
            return root.toString();
        } catch (Exception e) {
            return null;
        }
    }

    public static BotMarkup fromJson(String json) {
        if (json == null || json.trim().isEmpty()) {
            return null;
        }
        try {
            String trimmed = json.trim();
            if (trimmed.startsWith("{")) {
                JSONObject root = new JSONObject(trimmed);
                String typeStr = root.optString("type", "inline").toUpperCase();
                Type type;
                try {
                    type = Type.valueOf(typeStr);
                } catch (Exception ignored) {
                    type = Type.INLINE;
                }
                boolean resize = root.optBoolean("resize", true);
                boolean oneTime = root.optBoolean("one_time", false);

                List<List<Button>> rows = new ArrayList<>();
                JSONArray rowsArr = root.optJSONArray("rows");
                if (rowsArr != null) {
                    for (int i = 0; i < rowsArr.length(); i++) {
                        JSONArray rowArr = rowsArr.getJSONArray(i);
                        List<Button> row = new ArrayList<>();
                        for (int j = 0; j < rowArr.length(); j++) {
                            JSONObject obj = rowArr.getJSONObject(j);
                            String text = obj.optString("text", "");
                            String data = obj.has("data") ? obj.optString("data") : null;
                            String url = obj.has("url") ? obj.optString("url") : null;
                            row.add(new Button(text, data, url));
                        }
                        if (!row.isEmpty()) {
                            rows.add(row);
                        }
                    }
                }
                return new BotMarkup(type, rows, resize, oneTime);
            } else if (trimmed.startsWith("[")) {
                JSONArray rowsArr = new JSONArray(trimmed);
                List<List<Button>> rows = new ArrayList<>();
                for (int i = 0; i < rowsArr.length(); i++) {
                    JSONArray rowArr = rowsArr.getJSONArray(i);
                    List<Button> row = new ArrayList<>();
                    for (int j = 0; j < rowArr.length(); j++) {
                        JSONObject obj = rowArr.getJSONObject(j);
                        String text = obj.optString("text", "");
                        String data = obj.has("data") ? obj.optString("data") : null;
                        String url = obj.has("url") ? obj.optString("url") : null;
                        row.add(new Button(text, data, url));
                    }
                    if (!row.isEmpty()) {
                        rows.add(row);
                    }
                }
                return new BotMarkup(rows);
            }
            return null;
        } catch (Exception e) {
            return null;
        }
    }
}
