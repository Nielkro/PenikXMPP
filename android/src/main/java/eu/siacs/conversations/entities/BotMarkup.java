package eu.siacs.conversations.entities;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class BotMarkup {
    public static class Button {
        private final String text;
        private final String data;
        private final String url;

        public Button(String text, String data, String url) {
            this.text = text;
            this.data = data;
            this.url = url;
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

    private final List<List<Button>> rows;

    public BotMarkup(List<List<Button>> rows) {
        this.rows = rows != null ? rows : Collections.emptyList();
    }

    public List<List<Button>> getRows() {
        return rows;
    }

    public boolean isEmpty() {
        return rows.isEmpty();
    }

    public String toJson() {
        try {
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
            return rowsArr.toString();
        } catch (Exception e) {
            return null;
        }
    }

    public static BotMarkup fromJson(String json) {
        if (json == null || json.trim().isEmpty()) {
            return null;
        }
        try {
            JSONArray rowsArr = new JSONArray(json);
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
        } catch (Exception e) {
            return null;
        }
    }
}
