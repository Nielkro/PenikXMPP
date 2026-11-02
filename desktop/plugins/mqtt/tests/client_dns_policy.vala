using Dino.Plugins.Mqtt;

private async void policy_delay(uint ms) {
    Timeout.add(ms, () => { policy_delay.callback(); return Source.REMOVE; });
    yield;
}

private async void run() {
    int port = int.parse(Environment.get_variable("DINOX_TEST_MQTT_PORT"));
    int proxy_port = int.parse(Environment.get_variable("DINOX_TEST_PROXY_PORT"));
    var first = new MqttClient();
    var second = new MqttClient();
    // All operations report success or failure as values, not exceptions.
    assert_true(yield first.connect_async("127.0.0.1", port));
    assert_true(first.is_connected);
    assert_false(yield second.connect_async("127.0.0.1", port, true,
        null, null, null, null, 0, null, null, "required"));
    assert_nonnull(second.security_error);
    assert_true(first.is_connected);
    assert_false(yield second.connect_async("127.0.0.1", port, false,
        null, null, null, null, 0, null, null, "corrupt-policy"));
    assert_nonnull(second.security_error);
    assert_false(yield second.connect_async("broker.example.org", port, false,
        null, null, null, null, 0, null, null, "when-available"));
    assert_nonnull(second.security_error);
    assert_false(yield second.connect_async("broker.example.org", port, true,
        null, null, "socks5", "127.0.0.1", proxy_port, null, null, "when-available"));
    assert_nonnull(second.security_error);
    stdout.printf("PASS client policies: required local target, corrupt policy, cleartext and missing proxy resolver rejected; other client stays connected\n");

    bool completed = false;
    bool connected = true;
    second.connect_async.begin("broker.example.org", port, true,
        null, null, "socks5", "127.0.0.1", proxy_port, null, null,
        "when-available", "https://resolver.invalid/dns-query", (obj, result) => {
            connected = second.connect_async.end(result);
            completed = true;
        });
    yield policy_delay(100);
    second.disconnect_sync();
    int64 deadline = get_monotonic_time() + 2 * TimeSpan.SECOND;
    while (!completed && get_monotonic_time() < deadline) yield policy_delay(10);
    assert_true(completed);
    assert_false(connected);
    assert_null(second.security_error);
    assert_true(first.is_connected);
    assert_true(yield second.connect_async("127.0.0.1", port));
    assert_true(first.is_connected);
    assert_true(second.is_connected);
    assert_null(second.security_error);
    stdout.printf("PASS client cancellation: pending proxy DNS cancelled; fresh connection succeeds without stale error or cross-client disconnect\n");
    first.disconnect_sync();
    second.disconnect_sync();
}

int main(string[] args) {
    var loop = new MainLoop();
    run.begin((obj, result) => {
        run.end(result);
        loop.quit();
    });
    loop.run(); return 0;
}
