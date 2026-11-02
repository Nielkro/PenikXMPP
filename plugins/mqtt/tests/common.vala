int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    GLib.Test.init(ref args);
    GLib.Test.set_nonfatal_assertions();

    /* MQTT 3.1.1 §4.7 — Topic filter matching (wildcards +, #) */
    TestSuite.get_root().add_suite(new MqttTopicMatchTest().get_suite());

    /* Prosody mod_pubsub_mqtt — Topic display format conversion */
    TestSuite.get_root().add_suite(new ProsodyFormatTest().get_suite());

    /* Contract — Numeric value extraction from payloads */
    TestSuite.get_root().add_suite(new NumericExtractTest().get_suite());

    /* Contract — Unicode sparkline chart generation */
    TestSuite.get_root().add_suite(new SparklineTest().get_suite());

    /* Contract — Sparkline character set */
    TestSuite.get_root().add_suite(new SparkCharsTest().get_suite());

    /* Contract — Bridge message formatting */
    TestSuite.get_root().add_suite(new BridgeFormatTest().get_suite());

    /* Contract — String truncation */
    TestSuite.get_root().add_suite(new TruncateTest().get_suite());

    /* Contract — Local host detection (TLS warning) */
    TestSuite.get_root().add_suite(new LocalHostTest().get_suite());

    /* Contract — MqttConnectionConfig model */
    TestSuite.get_root().add_suite(new ConnectionConfigTest().get_suite());

    /* ── Audit-driven tests (commit 030cc9d9) ──────────────────── */

    /* Audit — Port validation (clamp 1–65535 in config setter) */
    TestSuite.get_root().add_suite(new PortValidationTest().get_suite());

    /* Audit — truncate_string() edge cases (max_len <= 3) */
    TestSuite.get_root().add_suite(new TruncateEdgeCaseTest().get_suite());

    /* NOTE: MqttPriority, AlertOperator, AlertRule tests would need
     * alert_manager.vala which depends on the full Plugin class.
     * Those types are verified via manual/integration testing. */

    /* Audit — Alias map parsing, CRUD, wildcard resolve */
    TestSuite.get_root().add_suite(new AliasMapTest().get_suite());

    return GLib.Test.run();
}
