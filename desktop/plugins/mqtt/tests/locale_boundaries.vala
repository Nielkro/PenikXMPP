using Dino.Plugins.Mqtt;

// Real alert manager and settings database, with no registered plugin, broker,
// account or user profile. Numbers cross JSON -> rule evaluation -> history.
private class LocaleApplication : GLib.Application, Dino.Application {
    public Dino.Database db { get; set; }
    public string? db_key { get; set; }
    public Dino.Security.FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public Dino.StreamInteractor stream_interactor { get; set; }
    public Dino.Plugins.Registry plugin_registry { get; set; }
    public Dino.SearchPathGenerator? search_path_generator { get; set; }
    public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
}

private void check(bool condition, string reason) {
    if (!condition) { GLib.Test.message("%s", reason); GLib.Test.fail(); }
}

private int main(string[] args) {
    GLib.Test.init(ref args);
    check(Intl.setlocale(LocaleCategory.ALL, "") != null, "requested system locale must be available");
    GLib.Test.message("LC_NUMERIC=%s", Intl.setlocale(LocaleCategory.NUMERIC, null));
    GLib.Test.add_func("/MqttLocale/playlist_tokens_preserve_unicode_urls", () => {
        string url = "https://example.test/日本語/radio.mp3";
        check(MqttUtils.extract_stream_url("[PLAYLIST]\nFILE1=" + url) == url,
            "PLS FILE tokens must use ASCII case rules and preserve the URL");
        check(MqttUtils.extract_stream_url("#EXTINF:1,موسيقى\n" + url) == url,
            "M3U tokens must use ASCII case rules and preserve the URL");
        check(MqttUtils.is_html_payload("<!DOCTYPE HTML><TITLE>日本語</TITLE>"), "HTML tokens");
        check(MqttUtils.extract_stream_url("[PLAYLIST]\nFILE1=file:///etc/passwd") == null,
            "unsupported URL schemes remain rejected");
    });
    GLib.Test.add_func("/MqttLocale/priority_tokens_are_not_translated", () => {
        check(MqttPriority.from_string("CRITICAL") == MqttPriority.CRITICAL, "CRITICAL must keep its priority");
        check(MqttPriority.from_string("SILENT") == MqttPriority.SILENT, "SILENT must keep its priority");
        check(MqttPriority.from_string("critical").to_string_key() == "critical", "stored keys must remain ASCII");
    });
    GLib.Test.add_func("/MqttLocale/json_numbers_reach_real_threshold_evaluation", () => {
        try {
            var app = new LocaleApplication();
            app.db = new Dino.Database(":memory:", "isolated MQTT locale test");
            app.settings = new Dino.Entities.Settings.from_db(app.db);
            var plugin = new Plugin();
            plugin.app = app;
            var manager = new MqttAlertManager(plugin);
            var rule = new AlertRule() {
                topic = "sensor/日本語", field = "temperature", op = AlertOperator.GT,
                threshold = "12.5", cooldown_secs = 0
            };
            manager.add_rule(rule);
            var config = new MqttConnectionConfig();
            check(manager.evaluate("isolated", config, rule.topic, "{\"temperature\":12.75}").triggered_rules.size == 1,
                "a JSON fraction above the threshold must trigger in every numeric locale");
            check(manager.evaluate("isolated", config, rule.topic, "{\"temperature\":12.25}").triggered_rules.size == 0,
                "a JSON fraction below the threshold must not trigger");
            rule.threshold = "0.000000001";
            check(manager.evaluate("isolated", config, rule.topic, "{\"temperature\":0.000000002}").triggered_rules.size == 1,
                "converting a JSON number must not round away meaningful fractional digits");
            rule.threshold = "-1.5";
            check(manager.evaluate("isolated", config, rule.topic, "{\"temperature\":-1.25}").triggered_rules.size == 1,
                "signed JSON numbers must retain their value");
        } catch (Error error) { GLib.Test.message("%s", error.message); GLib.Test.fail(); }
    });
    return GLib.Test.run();
}
