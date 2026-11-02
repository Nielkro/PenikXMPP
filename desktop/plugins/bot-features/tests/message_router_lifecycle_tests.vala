using Dino;
using Dino.Entities;
using Dino.Plugins.BotFeatures;
using Xmpp;

class RouterAuditApplication : GLib.Application, Dino.Application {
    public Database db { get; set; }
    public string? db_key { get; set; }
    public Security.FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
    public SearchPathGenerator? search_path_generator { get; set; }
    public RouterAuditApplication(Database db, StreamInteractor si) {
        Object(application_id: "im.dinox.bot-router-audit", flags: ApplicationFlags.NON_UNIQUE);
        this.db = db;
        db_key = "disposable-router-test-key";
        file_encryption = new Security.FileEncryption((!) db_key);
        settings = new Dino.Entities.Settings.from_db(db);
        stream_interactor = si;
    }
    public void handle_uri(string jid, string query, Gee.Map<string, string> options) {}
}

class RouterAuditStream : XmppStream {
    public RouterAuditStream() throws Error {
        base(new Jid("example.test"));
        // ConnectionManager.disconnect_all() sends an unavailable presence
        // during fixture teardown. Writes remain inert in this fake stream.
        add_module(new Xmpp.Presence.Module());
    }
    public override async void connect() throws IOError {}
    public override async void disconnect() throws IOError {}
    public override async StanzaNode read() throws IOError { throw new IOError.NOT_CONNECTED("No reader"); }
    public override async void write_async(StanzaNode node, int priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {}
    public override async void setup() throws IOError {}
}

class RouterAuditPipeline : MessageListenerHolder {
    public int count { get { return listeners.size; } }
    public MessageListener? last { owned get { return listeners.size == 0 ? null : listeners[listeners.size - 1] as MessageListener; } }
}

class LoopbackTelegramBridge : TelegramBridge {
    private string loopback_base;

    public LoopbackTelegramBridge(BotRegistry registry, string loopback_base) {
        base(registry);
        this.loopback_base = loopback_base;
    }

    protected override async Bytes send_http_request(Soup.Message request) throws Error {
        string path = request.get_uri().get_path();
        request.set_uri(Uri.parse(loopback_base + path, UriFlags.NONE));
        return yield base.send_http_request(request);
    }
}

void run_listener(MessageListener listener, Dino.Entities.Message message, Conversation conversation) {
    bool done = false;
    bool consumed = true;
    listener.run.begin(message, new MessageStanza(), conversation, (obj, result) => {
        consumed = listener.run.end(result);
        done = true;
    });
    while (!done) MainContext.default().iteration(true);
    assert(!consumed);
}

void spin_until(ref int actual, int expected) {
    bool timed_out = false;
    uint timer = Timeout.add_seconds(3, () => { timed_out = true; return Source.REMOVE; });
    while (actual < expected && !timed_out) MainContext.default().iteration(true);
    if (!timed_out) Source.remove(timer);
    assert(actual == expected);
}

void drain() {
    bool done = false;
    Timeout.add(60, () => { done = true; return Source.REMOVE; });
    while (!done) MainContext.default().iteration(true);
}

void pause_request(Soup.Server server, Soup.ServerMessage request) {
#if SOUP_SERVER_MESSAGE_PAUSE
    request.pause();
#else
    server.pause_message(request);
#endif
}

void resume_request(Soup.Server server, Soup.ServerMessage request) {
#if SOUP_SERVER_MESSAGE_PAUSE
    request.unpause();
#else
    server.unpause_message(request);
#endif
}

void test_router_shutdown() {
    try {
        var db = new Database(":memory:", "disposable-router-test-key");
        var si = new StreamInteractor.for_tests(db);
        var app = new RouterAuditApplication(db, si);
        app.settings.bot_features_enabled = true;
        var account = new Account(new Jid("owner@example.test"), "unused-test-password");
        account.enabled = true;
        si.connection_manager.set_connected_stream_for_tests(account, new RouterAuditStream());
        MessageProcessor.start(si, db);
        var pipeline = new RouterAuditPipeline();
        si.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline = pipeline;
        var registry = new BotRegistry(":memory:", "disposable-router-test-key");
        new TokenManager(registry);
        int bot_id = registry.create_bot("Local test", "owner@example.test", "test-token-hash");
        int dedicated_id = registry.create_bot("Dedicated test", "owner@example.test", "dedicated-test-token-hash", "dedicated", "bot@example.test");
        var pool = new SessionPool(app);
        pool.set_registry(registry);
        var server = new Soup.Server("server-header", "DinoX-lifecycle-test", null);
        int webhooks = 0;
        server.add_handler("/hook", (server, request, path, query) => {
            webhooks++;
            request.set_status(200, null);
        });
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        registry.set_webhook(bot_id, server.get_uris().data.to_string() + "hook", "test-secret", true);
        registry.set_webhook(dedicated_id, server.get_uris().data.to_string() + "hook", "test-secret", true);
        var dispatcher = new WebhookDispatcher();
        var incoming = new Dino.Entities.Message("Local isolated inbound test") {
            counterpart = new Jid("contact@example.test/device"),
            ourpart = account.bare_jid,
            direction = Dino.Entities.Message.DIRECTION_RECEIVED
        };
        var conversation = new Conversation(incoming.counterpart, account, Conversation.Type.CHAT);
        var dedicated_message = new MessageStanza() {
            from = incoming.counterpart, to = new Jid("bot@example.test"), body = "Local dedicated inbound test"
        };
        MessageRouter? old = new MessageRouter(app, registry, pool, dispatcher);
        assert(pipeline.count == 1);
        MessageListener old_snapshot = (!) pipeline.last;
        run_listener(old_snapshot, incoming, conversation);
        assert(registry.get_updates(bot_id).size == 1);
        spin_until(ref webhooks, 1);
        old.shutdown();
        old.shutdown();
        assert(pipeline.count == 0);
        old.on_message_received(incoming, conversation);
        run_listener(old_snapshot, incoming, conversation);
        pool.dedicated_message_received(dedicated_id, dedicated_message);
        drain();
        assert(registry.get_updates(bot_id).size == 1);
        assert(registry.get_updates(dedicated_id).size == 0);
        assert(webhooks == 1);
        WeakRef old_ref = WeakRef(old);
        old = null;
        assert(old_ref.get() == null);
        run_listener(old_snapshot, incoming, conversation);
        for (int cycle = 0; cycle < 5; cycle++) {
            var current = new MessageRouter(app, registry, pool, dispatcher);
            assert(pipeline.count == 1);
            run_listener(old_snapshot, incoming, conversation);
            run_listener((!) pipeline.last, incoming, conversation);
            assert(registry.get_updates(bot_id).size == cycle + 2);
            spin_until(ref webhooks, cycle + 2);
            current.shutdown();
            assert(pipeline.count == 0);
        }
        dispatcher.shutdown();
        server.disconnect();
        pool.disconnect_all();
        si.connection_manager.disconnect_all();
        registry.close();
        db.close();
    } catch (Error e) {
        Test.message("Unexpected fixture failure: %s", e.message);
        Test.fail();
    }
}

void test_webhook_shutdown_during_backoff() {
    try {
        var server = new Soup.Server("server-header", "DinoX-lifecycle-test", null);
        int deliveries = 0;
        server.add_handler("/hook", (server, request, path, query) => {
            deliveries++;
            request.set_status(500, null);
        });
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        string url = server.get_uris().data.to_string() + "hook";
        WebhookDispatcher? dispatcher = new WebhookDispatcher();
        Test.expect_message("bot-features", LogLevelFlags.LEVEL_WARNING, "*returned status 500 (attempt 1/3)*");
        dispatcher.dispatch(url, "test-secret", "{}");
        spin_until(ref deliveries, 1);
        drain();
        Test.assert_expected_messages();
        dispatcher.shutdown();
        dispatcher.shutdown();
        dispatcher.dispatch(url, "test-secret", "{}");
        WeakRef weak_dispatcher = WeakRef(dispatcher);
        dispatcher = null;
        drain();
        // The cancelled delay must release its coroutine and dispatcher now,
        // rather than keeping it alive until a future retry timer fires.
        assert(weak_dispatcher.get() == null);
        assert(deliveries == 1);
        server.disconnect();
    } catch (Error e) {
        Test.message("Unexpected webhook fixture failure: %s", e.message);
        Test.fail();
    }
}

void telegram_shutdown_case(bool during_poll) {
    try {
        var registry = new BotRegistry(":memory:", "disposable-telegram-test-key");
        new TokenManager(registry);
        int bot_id = registry.create_bot("Telegram test", "owner@example.test", "test-token-hash");
        var server = new Soup.Server("server-header", "DinoX-lifecycle-test", null);
        int delete_requests = 0;
        int poll_requests = 0;
        int received_messages = 0;
        Soup.ServerMessage? held = null;
        server.add_handler(null, (server, request, path, query) => {
            if (path.has_suffix("/deleteWebhook")) {
                delete_requests++;
                request.set_status(200, null);
                BotUtils.set_json_response(request, "{\"ok\":true,\"result\":true}");
                if (!during_poll) {
                    held = request;
                    pause_request(server, request);
                }
            } else if (path.has_suffix("/getUpdates")) {
                poll_requests++;
                request.set_status(200, null);
                BotUtils.set_json_response(request,
                    "{\"ok\":true,\"result\":[{\"update_id\":1,\"message\":{\"text\":\"do not emit after shutdown\"}}]}");
                held = request;
                pause_request(server, request);
            } else {
                assert_not_reached();
            }
        });
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        string base_url = server.get_uris().data.to_string();
        base_url = base_url.substring(0, base_url.length - 1);
        LoopbackTelegramBridge? bridge = new LoopbackTelegramBridge(registry, base_url);
        bridge.telegram_message_received.connect((id, sender, text) => { received_messages++; });
        bridge.configure(bot_id, "disposable-test-token", "test-chat", "bridge", true);
        bridge.start_polling(bot_id, "owner@example.test");
        if (during_poll) spin_until(ref poll_requests, 1);
        else spin_until(ref delete_requests, 1);
        assert(held != null);
        bridge.shutdown();
        bridge.shutdown();
        bridge.start_polling(bot_id, "owner@example.test");
        bool done = false;
        bridge.forward_to_telegram.begin(bot_id, "contact@example.test", "not sent", (obj, result) => {
            assert(!bridge.forward_to_telegram.end(result));
            done = true;
        });
        while (!done) MainContext.default().iteration(true);
        resume_request(server, held);
        held = null;
        drain();
        assert(delete_requests == 1);
        assert(poll_requests == (during_poll ? 1 : 0));
        assert(received_messages == 0);
        assert(registry.get_setting("bot_%d_tg_enabled".printf(bot_id)) == "true");
        WeakRef weak_bridge = WeakRef(bridge);
        bridge = null;
        drain();
        assert(weak_bridge.get() == null);
        server.disconnect();
        registry.close();
    } catch (Error e) {
        Test.message("Unexpected Telegram fixture failure: %s", e.message);
        Test.fail();
    }
}

void test_telegram_shutdown_during_delete_webhook() {
    telegram_shutdown_case(false);
}

void test_telegram_shutdown_during_poll() {
    telegram_shutdown_case(true);
}

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    Test.init(ref args);
    Test.add_func("/botmother/lifecycle/router-shutdown-and-enable-cycles", test_router_shutdown);
    Test.add_func("/botmother/lifecycle/webhook-shutdown-during-backoff", test_webhook_shutdown_during_backoff);
    Test.add_func("/botmother/lifecycle/telegram-shutdown-during-delete-webhook", test_telegram_shutdown_during_delete_webhook);
    Test.add_func("/botmother/lifecycle/telegram-shutdown-during-poll", test_telegram_shutdown_during_poll);
    return Test.run();
}
