using Gee;

namespace Dino.Plugins.BotFeatures {

public class SessionPool : Object {
    public int refresh_count = 0;
    public int? last_refresh_bot_id = null;
    public int prepare_unregister_count = 0;
    public int? last_prepare_unregister_bot_id = null;
    public int connect_count = 0;
    public int verify_count = 0;
    public string? last_verified_jid = null;
    public string? last_verified_password = null;
    public string verify_error = "";

    public async void connect_dedicated(BotInfo bot) {
        connect_count++;
    }

    public async string verify_dedicated_credentials(string jid_str, string password) {
        verify_count++;
        last_verified_jid = jid_str;
        last_verified_password = password;
        return verify_error;
    }

    public void refresh_bot_metadata(BotInfo bot) {
        refresh_count++;
        last_refresh_bot_id = bot.id;
    }

    public void prepare_for_account_unregister(int bot_id) {
        prepare_unregister_count++;
        last_prepare_unregister_bot_id = bot_id;
    }
}

public class FakeEjabberdApi : EjabberdApi {
    public bool configured = true;
    public string host = "example.test";
    public int check_count = 0;
    public int register_count = 0;
    public int unregister_count = 0;
    public string? last_checked_username = null;
    public string? last_registered_username = null;
    public string? last_registered_password = null;
    public string? last_unregistered_username = null;
    public bool account_exists = false;
    public bool register_success = true;
    public bool unregister_success = true;
    public int register_account_exists_failures = 0;

    public FakeEjabberdApi(BotRegistry registry) {
        base(registry);
    }

    public override bool is_configured() {
        return configured;
    }

    public override string get_host() {
        return host;
    }

    public override async ApiResult check_account(string username) {
        check_count++;
        last_checked_username = username;
        if (account_exists) {
            return ApiResult() { success = true, status_code = 200, response_body = "0" };
        }
        return ApiResult() { success = true, status_code = 200, response_body = "1" };
    }

    public override async ApiResult register_account(string username, string password) {
        register_count++;
        last_registered_username = username;
        last_registered_password = password;
        if (register_account_exists_failures > 0) {
            register_account_exists_failures--;
            return ApiResult() {
                success = false,
                status_code = 409,
                error_message = "account already exists",
                response_body = "already exists"
            };
        }
        return ApiResult() {
            success = register_success,
            status_code = register_success ? 200 : 500,
            error_message = register_success ? null : "register failed",
            response_body = register_success ? "registered" : "failed"
        };
    }

    public override async ApiResult unregister_account(string username) {
        unregister_count++;
        last_unregistered_username = username;
        return ApiResult() {
            success = unregister_success,
            status_code = unregister_success ? 200 : 500,
            error_message = unregister_success ? null : "unregister failed",
            response_body = unregister_success ? "unregistered" : "failed"
        };
    }
}

public class TelegramBridgeStub : Object {
    public bool enabled = false;
    public int start_count = 0;
    public int stop_count = 0;
    public bool send_success = false;
    public int forward_count = 0;
    public int? last_forward_bot_id = null;
    public string? last_forward_sender = null;
    public string? last_forward_text = null;
    public bool test_success = false;
    public string test_result = "Bot: Test (@test_bot)";
    public int configure_count = 0;
    public string? last_token = null;
    public string? last_chat_id = null;
    public string? last_mode = null;
    private Gee.HashSet<int> polling_bots = new Gee.HashSet<int>();

    public void configure(int bot_id, string token, string chat_id, string mode, bool enable_telegram) {
        if (enable_telegram) enabled = true;
        configure_count++;
        last_token = token;
        last_chat_id = chat_id;
        last_mode = mode;
    }

    public void start_polling(int bot_id, string owner_jid) {
        if (polling_bots.contains(bot_id)) return;
        polling_bots.add(bot_id);
        start_count++;
    }

    public void stop_polling(int bot_id) {
        polling_bots.remove(bot_id);
        stop_count++;
    }

    public bool is_enabled(int bot_id) {
        return enabled;
    }

    public void disable(int bot_id) {
        enabled = false;
        stop_polling(bot_id);
    }

    public async bool forward_to_telegram(int bot_id, string sender, string text) {
        forward_count++;
        last_forward_bot_id = bot_id;
        last_forward_sender = sender;
        last_forward_text = text;
        return send_success;
    }

    public async string? test_connection(int bot_id) {
        ApiResult result = yield test_connection_result(bot_id);
        return result.success ? result.response_body : result.error_message;
    }

    public async ApiResult test_connection_result(int bot_id) {
        if (test_success) {
            return ApiResult() { success = true, response_body = test_result };
        }
        return ApiResult() { success = false, error_message = "Telegram test failed" };
    }
}

public class AiIntegrationStub : Object {
    public string? answer = null;
    public int ask_count = 0;
    public int? last_ask_bot_id = null;
    public string? last_ask_from = null;
    public string? last_ask_question = null;
    public int configure_count = 0;
    public string? last_provider = null;
    public string? last_api_key = null;
    public string? last_model = null;

    public bool has_provider_preset(string provider) {
        switch (provider.down()) {
            case "ollama":
            case "openai":
            case "claude":
            case "gemini":
            case "groq":
            case "mistral":
            case "deepseek":
            case "perplexity":
            case "xai":
            case "openclaw":
                return true;
            default:
                return false;
        }
    }

    public bool provider_requires_api_key(string provider) {
        return provider.down() != "ollama";
    }

    public string? provider_ai_type(string provider) {
        switch (provider.down()) {
            case "ollama": return "ollama";
            case "openai": return "openai";
            case "claude": return "claude";
            case "groq":
            case "mistral":
            case "deepseek":
            case "perplexity":
                return "openai";
            case "xai": return "xai";
            case "gemini": return "gemini";
            case "openclaw": return "openclaw";
            default: return null;
        }
    }

    public string? provider_endpoint(string provider) {
        switch (provider.down()) {
            case "ollama": return "http://localhost:11434";
            case "openai": return "https://api.openai.com/v1/chat/completions";
            case "claude": return "https://api.anthropic.com/v1/messages";
            case "groq": return "https://api.groq.com/openai/v1/chat/completions";
            case "mistral": return "https://api.mistral.ai/v1/chat/completions";
            case "deepseek": return "https://api.deepseek.com/v1/chat/completions";
            case "perplexity": return "https://api.perplexity.ai/chat/completions";
            case "xai": return "https://api.x.ai/v1/responses";
            case "gemini": return "https://generativelanguage.googleapis.com/v1beta";
            case "openclaw": return "http://localhost:18789/hooks/agent";
            default: return null;
        }
    }

    public void configure_preset(int bot_id, string provider, string api_key, string model, bool enable_ai) {
        configure_count++;
        last_provider = provider;
        last_api_key = api_key;
        last_model = model;
    }

    public bool is_enabled(int bot_id) {
        return false;
    }

    public void disable(int bot_id) {
    }

    public async string? ask(int bot_id, string from, string question) {
        ask_count++;
        last_ask_bot_id = bot_id;
        last_ask_from = from;
        last_ask_question = question;
        return answer;
    }
}

public class MessageRouter : Object {
    public TelegramBridgeStub telegram { get; private set; default = new TelegramBridgeStub(); }
    public AiIntegrationStub ai { get; private set; default = new AiIntegrationStub(); }
    public bool dedicated_available = true;
    public int send_count = 0;
    public string? last_send_to = null;
    public string? last_send_text = null;
    public string? last_send_type = null;
    public int file_count = 0;
    public string? last_file_to = null;
    public string? last_file_url = null;
    public string? last_file_caption = null;
    public int join_count = 0;
    public string? last_join_room = null;
    public string? last_join_nick = null;
    public int leave_count = 0;
    public string? last_leave_room = null;
    public int reaction_count = 0;
    public string? last_reaction_to = null;
    public string? last_reaction_message_id = null;
    public string? last_reaction = null;

    public string? send_message(BotInfo bot, string to_jid, string text, string msg_type) {
        if (bot.mode == "dedicated" && !dedicated_available) return null;
        send_count++;
        last_send_to = to_jid;
        last_send_text = text;
        last_send_type = msg_type;
        return "test-message-id";
    }

    public string? send_file(BotInfo bot, string to_jid, string file_url, string? caption) {
        if (bot.mode == "dedicated" && !dedicated_available) return null;
        file_count++;
        last_file_to = to_jid;
        last_file_url = file_url;
        last_file_caption = caption;
        return "test-file-id";
    }

    public async bool join_room(BotInfo bot, string room_jid, string? nick) {
        join_count++;
        last_join_room = room_jid;
        last_join_nick = nick;
        return true;
    }

    public bool leave_room(BotInfo bot, string room_jid) {
        leave_count++;
        last_leave_room = room_jid;
        return true;
    }

    public bool send_reaction(BotInfo bot, string to_jid, string message_id, string reaction) {
        if (bot.mode == "dedicated" && !dedicated_available) return false;
        reaction_count++;
        last_reaction_to = to_jid;
        last_reaction_message_id = message_id;
        last_reaction = reaction;
        return true;
    }
}

}

namespace Dino.Plugins.BotFeatures.Test {

class HttpApiTest : Gee.TestCase {
    private static uint16 next_port = 28420;

    private bool http_tests_enabled = true;
    private string http_tests_skip_reason = "";
    private string? db_path = null;
    private uint16 port;
    private BotRegistry registry;
    private TokenManager token_manager;
    private MessageRouter router;
    private SessionPool session_pool;
    private FakeEjabberdApi ejabberd_api;
    private HttpServer server;
    private Soup.Session client;

    public HttpApiTest() {
        base("HTTP_API");

        string socket_error = "";
        if (!local_test_sockets_available(out socket_error)) {
            http_tests_enabled = false;
            http_tests_skip_reason = socket_error;
            add_test("HTTP_server_unavailable", test_http_server_unavailable);
            return;
        }

        add_test("CREATE_personal_with_webhook_returns_token_and_secret", test_create_personal_with_webhook);
        add_test("CREATE_unicode_name_roundtrips_through_getMe", test_create_unicode_name_roundtrip);
        add_test("CREATE_rejects_decoded_and_raw_NUL_without_persistence", test_create_rejects_nul_forms);
        add_test("CREATE_accepts_literal_backslash_u0000", test_create_accepts_literal_backslash_u0000);
        add_test("CREATE_dedicated_manual_account_without_ejabberd_api", test_create_dedicated_manual_account);
        add_test("CREATE_dedicated_ejabberd_provisioning_verifies_before_persisting", test_create_dedicated_ejabberd_provisioning);
        add_test("CREATE_dedicated_ejabberd_requires_config_before_registration", test_create_dedicated_ejabberd_requires_config);
        add_test("CREATE_dedicated_ejabberd_verification_failure_rolls_back", test_create_dedicated_ejabberd_verification_failure_rolls_back);
        add_test("CREATE_dedicated_ejabberd_registration_failure_does_not_persist", test_create_dedicated_ejabberd_registration_failure);
        add_test("CREATE_dedicated_ejabberd_registration_conflict_retries_new_jid", test_create_dedicated_ejabberd_registration_conflict_retries);
        add_test("CREATE_dedicated_ejabberd_jid_collisions_do_not_register", test_create_dedicated_ejabberd_jid_collisions);
        add_test("CREATE_purpose_validated_stored_and_listed", test_create_purpose_validated_stored_and_listed);
        add_test("CREATE_purpose_fallback_detects_single_and_mixed_integrations", test_purpose_fallback_detects_integrations);
        add_test("CREATE_cloud_rejected_without_persisting_bot", test_cloud_rejected_without_persisting_bot);
        add_test("CLOUD_tokens_are_account_scoped_and_stored_as_secret", test_cloud_tokens_account_scoped_secret_storage);
        add_test("CREATE_invalid_webhook_rejected_without_persisting_bot", test_invalid_webhook_rejected);
        add_test("STORAGE_webhook_secret_not_stored_in_bot_table", test_webhook_secret_not_stored_in_bot_table);
        add_test("STORAGE_dedicated_password_not_stored_in_bot_table", test_dedicated_password_not_stored_in_bot_table);
        add_test("STORAGE_delete_bot_removes_scoped_settings", test_delete_bot_removes_scoped_settings);
        add_test("DELETE_stops_runtime_before_removing_bot", test_delete_stops_runtime_before_removing_bot);
        add_test("DELETE_manual_dedicated_bot_only_deletes_local_state", test_delete_manual_dedicated_bot_only_deletes_local_state);
        add_test("DELETE_ejabberd_provisioned_bot_prepares_unregister_and_deletes_locally", test_delete_ejabberd_provisioned_bot);
        add_test("REVOKE_disables_token_and_allows_second_revoke_marker", test_revoke_token_marker);
        add_test("TOKEN_regenerate_replaces_token_without_changing_status", test_regenerate_token_replaces_token);
        add_test("AUTH_overlong_bearer_token_rejected_before_lookup", test_overlong_bearer_token_rejected_before_lookup);
        add_test("PERMISSIONS_denied_then_allowed_for_sendMessage", test_permissions_denied_then_allowed);
        add_test("PERMISSIONS_all_remains_compatibility_super_scope", test_all_permission_allows_send);
        add_test("PERMISSIONS_groupchat_requires_muc_send", test_groupchat_requires_muc_send);
        add_test("PERMISSIONS_invalid_scope_is_rejected", test_invalid_permission_rejected);
        add_test("TARGETS_allowlist_blocks_unlisted_jids", test_targets_allowlist_blocks_unlisted_jids);
        add_test("TARGETS_blocklist_blocks_only_listed_jids", test_targets_blocklist_blocks_only_listed_jids);
        add_test("TARGETS_wildcard_has_explicit_allow_and_block_semantics", test_targets_wildcard_semantics);
        add_test("CONSOLE_test_send_uses_local_management_endpoint", test_console_send_local_endpoint);
        add_test("CONSOLE_test_send_respects_status_permissions_and_targets", test_console_send_respects_guards);
        add_test("CONSOLE_room_join_leave_uses_local_management_endpoint", test_console_room_join_leave_local_endpoint);
        add_test("ADMIN_account_status_local_endpoint", test_account_status_local_endpoint);
        add_test("ADMIN_account_status_runtime_is_account_scoped", test_account_status_runtime_is_account_scoped);
        add_test("ADMIN_ejabberd_settings_local_endpoint_masks_password", test_ejabberd_settings_local_endpoint);
        add_test("ADMIN_webhook_management_local_endpoint", test_webhook_management_local_endpoint);
        add_test("ADMIN_avatar_management_local_endpoint", test_avatar_management_local_endpoint);
        add_test("ADMIN_telegram_management_local_endpoint", test_telegram_management_local_endpoint);
        add_test("ADMIN_ai_management_local_endpoint", test_ai_management_local_endpoint);
        add_test("ADMIN_ai_provider_presets_accept_supported_values", test_ai_provider_presets_accept_supported_values);
        add_test("API_ai_setup_accepts_supported_provider_presets", test_ai_setup_accepts_supported_provider_presets);
        add_test("ADMIN_ai_test_ask_local_endpoint", test_ai_test_ask_local_endpoint);
        add_test("INFO_getInfo_does_not_leak_secrets", test_get_info_does_not_leak_secrets);
        add_test("SCOPES_receive_updates_guards_updates_and_commands", test_receive_updates_scope_guards_updates_and_commands);
        add_test("SCOPES_webhook_requires_scope_and_post", test_webhook_requires_scope_and_post);
        add_test("SCOPES_file_send_respects_scope_and_targets", test_file_send_respects_scope_and_targets);
        add_test("SCOPES_admin_and_muc_join_guard_control_endpoints", test_admin_and_muc_join_guard_control_endpoints);
        add_test("SCOPES_reaction_respects_scope_and_targets", test_reaction_respects_scope_and_targets);
        add_test("SCOPES_bridge_endpoints_respect_status_admin_and_send_scopes", test_bridge_endpoints_respect_scopes);
        add_test("RUNTIME_permissions_and_status_sync_telegram_polling", test_runtime_syncs_telegram_polling);
        add_test("RUNTIME_paused_status_stops_runtime_without_disabling_token", test_paused_status_runtime);
        add_test("UPDATES_offset_returns_requested_id_and_acknowledges_older", test_updates_offset_semantics);
        add_test("UPDATES_long_poll_waits_for_new_update", test_updates_long_poll_waits_for_new_update);
        add_test("VALIDATION_invalid_ids_and_paging_return_bad_request", test_invalid_ids_and_paging_return_bad_request);
        add_test("VALIDATION_invalid_boolean_fields_return_bad_request", test_invalid_boolean_fields_return_bad_request);
        add_test("VALIDATION_invalid_string_fields_return_bad_request", test_invalid_string_fields_return_bad_request);
        add_test("VALIDATION_invalid_message_fields_return_bad_request", test_invalid_message_fields_return_bad_request);
        add_test("VALIDATION_get_endpoints_reject_wrong_methods", test_get_endpoints_reject_wrong_methods);
        add_test("VALIDATION_post_endpoints_reject_wrong_methods_before_scope", test_post_endpoints_reject_wrong_methods_before_scope);
        add_test("DEDICATED_muc_actions_use_dedicated_stream_path", test_dedicated_muc_actions_use_stream_path);
        add_test("DEDICATED_console_requires_available_stream_for_direct_send", test_dedicated_console_requires_stream);
        add_test("NETWORK_mode_https_keeps_loopback_management_available", test_network_mode_https_loopback_management);
        add_test("NETWORK_loopback_host_detection_accepts_canonical_forms", test_loopback_host_detection);
    }

    private static bool local_test_sockets_available(out string error_message) {
        error_message = "";
        Soup.Server? probe = null;
        try {
            probe = new Soup.Server("server-header", "DinoX-BotAPI-Test/1.0", null);
            probe.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            return true;
        } catch (Error e) {
            error_message = e.message;
            return false;
        } finally {
            if (probe != null) {
                probe.disconnect();
            }
        }
    }

    private void test_http_server_unavailable() {
        GLib.Test.skip("Local HTTP test sockets unavailable: %s".printf(http_tests_skip_reason));
    }

    public override void set_up() {
        if (!http_tests_enabled) return;

        string path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-api-test-%s.db".printf(Uuid.string_random()));
        db_path = path;
        try {
            registry = new BotRegistry(path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }
        token_manager = new TokenManager(registry, "test-server-key");
        router = new MessageRouter();
        session_pool = new SessionPool();
        ejabberd_api = new FakeEjabberdApi(registry);
        server = new HttpServer(registry, token_manager, router, session_pool, ejabberd_api);
        client = new Soup.Session();

        Error? last_error = null;
        for (int i = 0; i < 20; i++) {
            port = next_port++;
            try {
                server.start(port, "local");
                return;
            } catch (Error e) {
                last_error = e;
            }
        }

        GLib.Test.message("Unable to start test HTTP server: %s", last_error != null ? last_error.message : "unknown error");
        GLib.Test.fail();
    }

    public override void tear_down() {
        if (!http_tests_enabled) return;

        if (server != null) server.stop();
        if (client != null) client.abort();

        // GLib can tear down a listed case without first setting it up.
        // Clear the owned path before cleanup so a repeated teardown is safe.
        string? path = (owned) db_path;
        if (path == null) return;
        remove_if_exists((!) path);
        remove_if_exists((!) path + "-wal");
        remove_if_exists((!) path + "-shm");
    }

    private static void remove_if_exists(string path) {
        if (FileUtils.test(path, FileTest.EXISTS)) {
            FileUtils.remove(path);
        }
    }

    private ApiResponse request(string method, string path, string? body = null, string? token = null) {
        return request_url(method, "http://127.0.0.1:%u%s".printf(port, path), body, token);
    }

    private ApiResponse request_https(string method, string path, string? body = null, string? token = null) {
        return request_url(method, "https://127.0.0.1:%u%s".printf(port, path), body, token, true);
    }

    private ApiResponse request_url(string method, string url, string? body = null, string? token = null, bool accept_local_cert = false) {
        Bytes? request_body = null;
        if (body != null) request_body = new Bytes(body.data);
        return request_url_bytes(method, url, request_body, token, accept_local_cert);
    }

    private ApiResponse request_bytes(string method, string path, uint8[] body, string? token = null) {
        return request_url_bytes(method, "http://127.0.0.1:%u%s".printf(port, path),
            new Bytes(body), token, false);
    }

    private ApiResponse request_url_bytes(string method, string url, Bytes? request_body,
                                          string? token, bool accept_local_cert) {
        var response = new ApiResponse();
        var loop = new MainLoop();
        var msg = new Soup.Message(method, url);
        if (accept_local_cert) {
            msg.accept_certificate.connect((cert, errors) => {
                return true;
            });
        }

        if (request_body != null) {
            msg.set_request_body_from_bytes("application/json", (!) request_body);
        }
        if (token != null) {
            msg.request_headers.append("Authorization", "Bearer " + token);
        }

        client.send_and_read_async.begin(msg, Priority.DEFAULT, null, (obj, res) => {
            try {
                Bytes bytes = client.send_and_read_async.end(res);
                response.status_code = msg.status_code;
                response.body = (string) bytes.get_data();
            } catch (Error e) {
                response.error = e.message;
            }
            loop.quit();
        });
        loop.run();

        if (response.error != null) {
            GLib.Test.message("HTTP request failed: %s", response.error);
            GLib.Test.fail();
        }

        return response;
    }

    void test_network_mode_https_loopback_management() {
        server.stop();
        port = next_port++;

        string cert_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-api-cert-%s".printf(Uuid.string_random()));
        string cert_path = Path.build_filename(cert_dir, "server.crt");
        string key_path = Path.build_filename(cert_dir, "server.key");
        assert_true(DirUtils.create_with_parents(cert_dir, 0700) == 0);
        assert_true(CertGen.generate_self_signed_cert(cert_path, key_path, "DinoX API Test") == 0);

        try {
            server.start(port, "network", cert_path, key_path);
        } catch (Error e) {
            GLib.Test.message("Unable to start HTTPS API server: %s", e.message);
            GLib.Test.fail();
            return;
        }

        var health = request_https("GET", "/health");
        assert_true(health.status_code == 200);

        var create = request_https("POST", "/bot/create",
            "{\"name\":\"Network UI Bot\",\"account\":\"owner@example.test\",\"mode\":\"personal\"}");
        assert_true(create.status_code == 200);
        Json.Object create_body = parse_body(create);
        assert_true(create_body.get_boolean_member("ok"));
        assert_true(create_body.get_object_member("result").has_member("token"));

        remove_if_exists(cert_path);
        remove_if_exists(key_path);
        DirUtils.remove(cert_dir);
    }

    void test_loopback_host_detection() {
        assert_true(HttpServer.is_loopback_host("127.0.0.1"));
        assert_true(HttpServer.is_loopback_host("::1"));
        assert_true(HttpServer.is_loopback_host("[::1]"));
        assert_true(HttpServer.is_loopback_host("localhost"));
        assert_false(HttpServer.is_loopback_host("192.0.2.1"));
        assert_false(HttpServer.is_loopback_host("example.org"));
        assert_false(HttpServer.is_loopback_host(null));
    }

    private Json.Object parse_body(ApiResponse response) {
        try {
            var parser = new Json.Parser();
            parser.load_from_data(response.body);
            Json.Node? root = parser.get_root();
            assert_true(root != null);
            assert_true(root.get_node_type() == Json.NodeType.OBJECT);
            return root.get_object();
        } catch (Error e) {
            GLib.Test.message("Invalid JSON response: %s\n%s", e.message, response.body);
            GLib.Test.fail();
        }
        assert_not_reached();
    }

    private int create_bot_with_permissions(string permissions, out string raw_token) {
        int bot_id = registry.create_bot("Scoped Test Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, permissions);
        registry.update_bot_status(bot_id, "active");
        raw_token = token_manager.generate_token(bot_id);
        return bot_id;
    }

    private int create_dedicated_bot_with_permissions(string permissions, out string raw_token) {
        int bot_id = registry.create_bot("Dedicated Test Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "dedicated", "bot@example.test");
        registry.update_bot_permissions(bot_id, permissions);
        registry.update_bot_password(bot_id, "secret");
        registry.update_bot_status(bot_id, "active");
        raw_token = token_manager.generate_token(bot_id);
        return bot_id;
    }

    private string? legacy_webhook_secret_column(int bot_id) {
        Qlite.RowOption row = registry.bot.row_with(registry.bot.id, bot_id);
        assert_true(row.is_present());
        return registry.bot.webhook_secret.get(row.inner);
    }

    private string? legacy_bot_password_column(int bot_id) {
        Qlite.RowOption row = registry.bot.row_with(registry.bot.id, bot_id);
        assert_true(row.is_present());
        return registry.bot.bot_password.get(row.inner);
    }

    private string? raw_setting(string key) {
        return registry.get_setting(key);
    }

    private bool encrypted_setting_exists(string key) {
        string? value = raw_setting(key);
        return value != null && value.has_prefix("ENC:");
    }

    void test_create_personal_with_webhook() {
        var response = request("POST", "/bot/create",
            "{\"name\":\"Webhook Bot\",\"account\":\" owner@example.test \",\"mode\":\" personal \",\"webhook_url\":\"https://hook.example.test/bot\"}");
        assert_true(response.status_code == 200);

        Json.Object json = parse_body(response);
        assert_true(json.get_boolean_member("ok"));
        Json.Object result = json.get_object_member("result");
        assert_true(result.get_string_member("name") == "Webhook Bot");
        assert_true(result.get_string_member("mode") == "personal");
        assert_true(result.get_string_member("api_url") == "http://localhost:%u/bot/".printf(port));
        assert_true(result.has_member("token"));
        assert_true(result.get_string_member("token").has_prefix("bot"));
        assert_true(result.has_member("webhook_secret"));
        assert_true(result.get_string_member("webhook_secret").length == 64);

        int bot_id = (int) result.get_int_member("id");
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.owner_jid == "owner@example.test");
        assert_true(bot.webhook_enabled);
        assert_true(bot.webhook_url == "https://hook.example.test/bot");
        assert_true(bot.webhook_secret == result.get_string_member("webhook_secret"));
        assert_true(token_manager.validate_token(result.get_string_member("token")) != null);
    }

    void test_create_unicode_name_roundtrip() {
        string unicode_name = "Бот Игорь — äöü 漢字 😀";
        var response = request("POST", "/bot/create",
            "{\"name\":\"%s\",\"account\":\"owner@example.test\",\"mode\":\"personal\"}".printf(unicode_name));
        assert_true(response.status_code == 200);

        Json.Object create_result = parse_body(response).get_object_member("result");
        assert_true(create_result.get_string_member("name") == unicode_name);
        string raw_token = create_result.get_string_member("token");

        var get_me = request("GET", "/bot/getMe", null, raw_token);
        assert_true(get_me.status_code == 200);
        Json.Object get_me_result = parse_body(get_me).get_object_member("result");
        assert_true(get_me_result.get_string_member("name") == unicode_name);

        int bot_id = (int) create_result.get_int_member("id");
        BotInfo? persisted = registry.get_bot_by_id(bot_id);
        assert_true(persisted != null);
        assert_true(persisted.name == unicode_name);
    }

    void test_create_rejects_nul_forms() {
        string prefix = "{\"name\":\"Bad";
        string suffix = "Bot\",\"account\":\"owner@example.test\",\"mode\":\"personal\"}";

        string encoded_nul = prefix + "\\" + "u0000" + suffix;
        var encoded_response = request("POST", "/bot/create", encoded_nul);
        assert_true(encoded_response.status_code == 400);
        assert_true(registry.get_all_bots().size == 0);

        string odd_backslash_nul = prefix + string.nfill(3, '\\') + "u0000" + suffix;
        var odd_response = request("POST", "/bot/create", odd_backslash_nul);
        assert_true(odd_response.status_code == 400);
        assert_true(registry.get_all_bots().size == 0);

        string raw_prefix = "{\"name\":\"Raw";
        uint8[] raw_body = new uint8[raw_prefix.length + 1 + suffix.length];
        for (int i = 0; i < raw_prefix.length; i++) raw_body[i] = raw_prefix[i];
        raw_body[raw_prefix.length] = 0;
        for (int i = 0; i < suffix.length; i++) raw_body[raw_prefix.length + 1 + i] = suffix[i];

        var raw_response = request_bytes("POST", "/bot/create", raw_body);
        assert_true(raw_response.status_code == 400);
        assert_true(registry.get_all_bots().size == 0);
    }

    void test_create_accepts_literal_backslash_u0000() {
        string expected_name = "Literal\\u0000 Bot";
        string body = "{\"name\":\"Literal" + string.nfill(2, '\\') +
            "u0000 Bot\",\"account\":\"owner@example.test\",\"mode\":\"personal\"}";

        var response = request("POST", "/bot/create", body);
        assert_true(response.status_code == 200);
        Json.Object result = parse_body(response).get_object_member("result");
        assert_true(result.get_string_member("name") == expected_name);

        BotInfo? persisted = registry.get_bot_by_id((int) result.get_int_member("id"));
        assert_true(persisted != null);
        assert_true(persisted.name == expected_name);
    }

    void test_create_dedicated_manual_account() {
        var missing = request("POST", "/bot/create",
            "{\"name\":\"Manual Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"manual\",\"bot_jid\":\"bot@example.test\"}");
        assert_true(missing.status_code == 400);
        assert_true(registry.get_all_bots().size == 0);

        var invalid_mode = request("POST", "/bot/create",
            "{\"name\":\"Manual Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"magic\",\"bot_jid\":\"bot@example.test\",\"bot_password\":\"secret\"}");
        assert_true(invalid_mode.status_code == 400);
        assert_true(registry.get_all_bots().size == 0);

        var invalid_jid = request("POST", "/bot/create",
            "{\"name\":\"Manual Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"manual\",\"bot_jid\":\"not-a-jid\",\"bot_password\":\"secret\"}");
        assert_true(invalid_jid.status_code == 400);
        assert_true(registry.get_all_bots().size == 0);

        var response = request("POST", "/bot/create",
            "{\"name\":\"Manual Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"manual\",\"bot_jid\":\"bot@example.test\",\"bot_password\":\"secret\",\"permissions\":\"send_message\"}");
        assert_true(response.status_code == 200);

        Json.Object result = parse_body(response).get_object_member("result");
        assert_true(result.get_string_member("mode") == "dedicated");
        assert_true(result.get_string_member("jid") == "bot@example.test");
        assert_true(result.get_string_member("provisioning") == "manual");
        assert_true(result.get_string_member("permissions") == "send_message");
        assert_true(result.has_member("token"));

        int bot_id = (int) result.get_int_member("id");
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.mode == "dedicated");
        assert_true(bot.jid == "bot@example.test");
        assert_true(bot.bot_password == "secret");
        assert_true(legacy_bot_password_column(bot_id) == "");
        assert_true(encrypted_setting_exists("bot_secret_password:%d".printf(bot_id)));
        assert_true(raw_setting("bot_dedicated_provisioning:%d".printf(bot_id)) == "manual");

        var list = request("GET", "/bot/list");
        Json.Object listed = parse_body(list).get_array_member("bots").get_object_element(0);
        assert_true(listed.get_string_member("provisioning") == "manual");

        var deleted = request("DELETE", "/bot/delete?id=%d".printf(bot_id));
        assert_true(deleted.status_code == 200);
        Json.Object delete_result = parse_body(deleted).get_object_member("result");
        assert_false(delete_result.has_member("account_removed"));
        assert_true(registry.get_bot_by_id(bot_id) == null);
        assert_true(raw_setting("bot_dedicated_provisioning:%d".printf(bot_id)) == null);
    }

    void test_create_dedicated_ejabberd_provisioning() {
        var response = request("POST", "/bot/create",
            "{\"name\":\"API Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"ejabberd\",\"purpose\":\"ai\",\"permissions\":\"admin,send_message\"}");
        assert_true(response.status_code == 200);

        Json.Object result = parse_body(response).get_object_member("result");
        assert_true(result.get_string_member("mode") == "dedicated");
        assert_true(result.get_string_member("purpose") == "ai");
        assert_true(result.get_string_member("permissions") == "admin,send_message");
        assert_true(result.has_member("token"));

        string jid = result.get_string_member("jid");
        assert_true(jid.has_suffix("@example.test"));
        int bot_id = (int) result.get_int_member("id");

        assert_true(ejabberd_api.check_count == 1);
        assert_true(ejabberd_api.register_count == 1);
        assert_true(ejabberd_api.unregister_count == 0);
        assert_true(ejabberd_api.last_registered_username != null);
        assert_true(jid == "%s@example.test".printf(ejabberd_api.last_registered_username));
        assert_true(ejabberd_api.last_registered_password != null);
        assert_true(ejabberd_api.last_registered_password.length == 24);

        assert_true(session_pool.verify_count == 1);
        assert_true(session_pool.last_verified_jid == jid);
        assert_true(session_pool.last_verified_password == ejabberd_api.last_registered_password);
        assert_true(session_pool.connect_count == 1);

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.mode == "dedicated");
        assert_true(bot.jid == jid);
        assert_true(registry.get_secret_setting("bot_secret_password:%d".printf(bot_id)) == ejabberd_api.last_registered_password);
        assert_true(legacy_bot_password_column(bot_id) == "");
        assert_true(encrypted_setting_exists("bot_secret_password:%d".printf(bot_id)));
        assert_true(raw_setting("bot_dedicated_provisioning:%d".printf(bot_id)) == "ejabberd");
        assert_true(raw_setting("bot_%d_purpose".printf(bot_id)) == "ai");
    }

    void test_create_dedicated_ejabberd_requires_config() {
        ejabberd_api.configured = false;

        var response = request("POST", "/bot/create",
            "{\"name\":\"API Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"ejabberd\"}");
        assert_true(response.status_code == 400);

        Json.Object error = parse_body(response);
        assert_true(error.get_string_member("error") == "not_configured");
        assert_true(ejabberd_api.check_count == 0);
        assert_true(ejabberd_api.register_count == 0);
        assert_true(session_pool.verify_count == 0);
        assert_true(session_pool.connect_count == 0);
        assert_true(registry.get_all_bots().size == 0);
    }

    void test_create_dedicated_ejabberd_verification_failure_rolls_back() {
        session_pool.verify_error = "not-authorized";

        var response = request("POST", "/bot/create",
            "{\"name\":\"Broken API Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"ejabberd\"}");
        assert_true(response.status_code == 502);

        Json.Object error = parse_body(response);
        assert_true(error.get_string_member("error") == "registration_verification_failed");
        assert_true(error.get_string_member("description").contains("not-authorized"));
        assert_true(error.get_string_member("description").contains("server account removed"));

        assert_true(ejabberd_api.check_count == 1);
        assert_true(ejabberd_api.register_count == 1);
        assert_true(ejabberd_api.unregister_count == 1);
        assert_true(ejabberd_api.last_unregistered_username == ejabberd_api.last_registered_username);
        assert_true(session_pool.verify_count == 1);
        assert_true(session_pool.connect_count == 0);
        assert_true(registry.get_all_bots().size == 0);
    }

    void test_create_dedicated_ejabberd_registration_failure() {
        ejabberd_api.register_success = false;

        var response = request("POST", "/bot/create",
            "{\"name\":\"Register Fail Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"ejabberd\"}");
        assert_true(response.status_code == 502);

        Json.Object error = parse_body(response);
        assert_true(error.get_string_member("error") == "registration_failed");
        assert_true(error.get_string_member("description").contains("register failed"));

        assert_true(ejabberd_api.check_count == 1);
        assert_true(ejabberd_api.register_count == 1);
        assert_true(ejabberd_api.unregister_count == 0);
        assert_true(session_pool.verify_count == 0);
        assert_true(session_pool.connect_count == 0);
        assert_true(registry.get_all_bots().size == 0);
    }

    void test_create_dedicated_ejabberd_registration_conflict_retries() {
        ejabberd_api.register_account_exists_failures = 1;

        var response = request("POST", "/bot/create",
            "{\"name\":\"Race Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"ejabberd\"}");
        assert_true(response.status_code == 200);

        Json.Object result = parse_body(response).get_object_member("result");
        string jid = result.get_string_member("jid");
        int bot_id = (int) result.get_int_member("id");

        assert_true(ejabberd_api.check_count == 2);
        assert_true(ejabberd_api.register_count == 2);
        assert_true(ejabberd_api.unregister_count == 0);
        assert_true(session_pool.verify_count == 1);
        assert_true(session_pool.last_verified_jid == jid);
        assert_true(session_pool.connect_count == 1);

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.jid == jid);
        assert_true(registry.get_secret_setting("bot_secret_password:%d".printf(bot_id)) == ejabberd_api.last_registered_password);
    }

    void test_create_dedicated_ejabberd_jid_collisions() {
        ejabberd_api.account_exists = true;

        var response = request("POST", "/bot/create",
            "{\"name\":\"Collision Bot\",\"account\":\"owner@example.test\",\"mode\":\"dedicated\",\"provisioning\":\"ejabberd\"}");
        assert_true(response.status_code == 409);

        Json.Object error = parse_body(response);
        assert_true(error.get_string_member("error") == "jid_collision");

        assert_true(ejabberd_api.check_count == 8);
        assert_true(ejabberd_api.register_count == 0);
        assert_true(ejabberd_api.unregister_count == 0);
        assert_true(session_pool.verify_count == 0);
        assert_true(session_pool.connect_count == 0);
        assert_true(registry.get_all_bots().size == 0);
    }

    void test_create_purpose_validated_stored_and_listed() {
        var invalid = request("POST", "/bot/create",
            "{\"name\":\"Bad Purpose\",\"account\":\"owner@example.test\",\"mode\":\"personal\",\"purpose\":\"weather\"}");
        assert_true(invalid.status_code == 400);
        assert_true(registry.get_all_bots().size == 0);

        var response = request("POST", "/bot/create",
            "{\"name\":\"AI Purpose Bot\",\"account\":\"owner@example.test\",\"mode\":\"personal\",\"purpose\":\"ai\"}");
        assert_true(response.status_code == 200);
        Json.Object result = parse_body(response).get_object_member("result");
        int bot_id = (int) result.get_int_member("id");
        assert_true(result.get_string_member("purpose") == "ai");
        assert_true(raw_setting("bot_%d_purpose".printf(bot_id)) == "ai");

        var listed = request("GET", "/bot/list");
        assert_true(listed.status_code == 200);
        Json.Array bots = parse_body(listed).get_array_member("bots");
        assert_true(bots.get_length() == 1);
        assert_true(bots.get_object_element(0).get_string_member("purpose") == "ai");

        registry.delete_setting("bot_%d_purpose".printf(bot_id));
        registry.set_setting("bot_%d_ai_endpoint".printf(bot_id), "https://generativelanguage.googleapis.com/v1beta");

        var fallback = request("GET", "/bot/list");
        assert_true(fallback.status_code == 200);
        Json.Array fallback_bots = parse_body(fallback).get_array_member("bots");
        assert_true(fallback_bots.get_object_element(0).get_string_member("purpose") == "ai");
    }

    void test_purpose_fallback_detects_integrations() {
        int ai_bot = registry.create_bot("Legacy AI Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.set_setting("bot_%d_ai_endpoint".printf(ai_bot), "https://generativelanguage.googleapis.com/v1beta");

        int telegram_bot = registry.create_bot("Legacy Telegram Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.set_secret_setting("bot_%d_tg_token".printf(telegram_bot), "telegram-secret");

        int webhook_bot = registry.create_bot("Legacy Webhook Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.set_webhook(webhook_bot, "https://hook.example.test/bot", "webhook-secret", true);

        int mixed_bot = registry.create_bot("Legacy Mixed Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.set_setting("bot_%d_ai_endpoint".printf(mixed_bot), "https://generativelanguage.googleapis.com/v1beta");
        registry.set_secret_setting("bot_%d_tg_token".printf(mixed_bot), "telegram-secret");

        int plain_bot = registry.create_bot("Legacy Plain Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");

        var listed = request("GET", "/bot/list");
        assert_true(listed.status_code == 200);
        Json.Array bots = parse_body(listed).get_array_member("bots");
        assert_true(bots.get_length() == 5);

        for (uint i = 0; i < bots.get_length(); i++) {
            Json.Object bot = bots.get_object_element(i);
            int id = (int) bot.get_int_member("id");
            string purpose = bot.get_string_member("purpose");
            if (id == ai_bot) {
                assert_true(purpose == "ai");
            } else if (id == telegram_bot) {
                assert_true(purpose == "telegram");
            } else if (id == webhook_bot) {
                assert_true(purpose == "webhook");
            } else if (id == mixed_bot) {
                assert_true(purpose == "advanced");
            } else if (id == plain_bot) {
                assert_true(purpose == "advanced");
            } else {
                GLib.Test.fail();
            }
        }
    }

    void test_cloud_rejected_without_persisting_bot() {
        var response = request("POST", "/bot/create",
            "{\"name\":\"Cloud Bot\",\"account\":\"owner@example.test\",\"mode\":\"cloud\"}");
        assert_true(response.status_code == 501);

        Json.Object json = parse_body(response);
        assert_false(json.get_boolean_member("ok"));
        assert_true(json.get_string_member("error") == "not_implemented");
        assert_true(registry.get_all_bots().size == 0);
    }

    void test_cloud_tokens_account_scoped_secret_storage() {
        string token_a = "cbot_owner_a_1234567890";
        string token_b = "cbot_owner_b_1234567890";

        var empty = request("GET", "/bot/cloud/tokens?account=owner@example.test");
        assert_true(empty.status_code == 200);
        Json.Array empty_tokens = parse_body(empty).get_object_member("result").get_array_member("tokens");
        assert_true(empty_tokens.get_length() == 0);

        var invalid_account = request("GET", "/bot/cloud/tokens?account=owner");
        assert_true(invalid_account.status_code == 400);

        var invalid_token = request("POST", "/bot/cloud/tokens",
            "{\"account\":\"owner@example.test\",\"token\":\"bad token\"}");
        assert_true(invalid_token.status_code == 400);

        var add_a = request("POST", "/bot/cloud/tokens",
            "{\"account\":\"owner@example.test\",\"token\":\"%s\"}".printf(token_a));
        assert_true(add_a.status_code == 200);
        var add_a_duplicate = request("POST", "/bot/cloud/tokens",
            "{\"account\":\"owner@example.test\",\"token\":\"%s\"}".printf(token_a));
        assert_true(add_a_duplicate.status_code == 200);
        var add_b = request("POST", "/bot/cloud/tokens",
            "{\"account\":\"other@example.test\",\"token\":\"%s\"}".printf(token_b));
        assert_true(add_b.status_code == 200);

        var owner_list = request("GET", "/bot/cloud/tokens?account=owner@example.test");
        assert_true(owner_list.status_code == 200);
        Json.Array owner_tokens = parse_body(owner_list).get_object_member("result").get_array_member("tokens");
        assert_true(owner_tokens.get_length() == 1);
        assert_true(owner_tokens.get_string_element(0) == token_a);

        var other_list = request("GET", "/bot/cloud/tokens?account=other@example.test");
        assert_true(other_list.status_code == 200);
        Json.Array other_tokens = parse_body(other_list).get_object_member("result").get_array_member("tokens");
        assert_true(other_tokens.get_length() == 1);
        assert_true(other_tokens.get_string_element(0) == token_b);

        string? raw = registry.get_setting("cloudbot_management_tokens:owner@example.test");
        assert_true(raw != null);
        assert_true(raw.has_prefix("ENC:"));
        assert_false(raw.contains(token_a));

        var remove_a = request("DELETE", "/bot/cloud/tokens",
            "{\"account\":\"owner@example.test\",\"token\":\"%s\"}".printf(token_a));
        assert_true(remove_a.status_code == 200);

        var removed_list = request("GET", "/bot/cloud/tokens?account=owner@example.test");
        assert_true(removed_list.status_code == 200);
        Json.Array removed_tokens = parse_body(removed_list).get_object_member("result").get_array_member("tokens");
        assert_true(removed_tokens.get_length() == 0);
        assert_true(registry.get_setting("cloudbot_management_tokens:owner@example.test") == null);
    }

    void test_invalid_webhook_rejected() {
        var response = request("POST", "/bot/create",
            "{\"name\":\"Bad Hook\",\"account\":\"owner@example.test\",\"mode\":\"personal\",\"webhook_url\":\"ftp://hook.example.test/bot\"}");
        assert_true(response.status_code == 400);

        Json.Object json = parse_body(response);
        assert_false(json.get_boolean_member("ok"));
        assert_true(json.get_string_member("error") == "bad_request");
        assert_true(registry.get_all_bots().size == 0);
    }

    void test_webhook_secret_not_stored_in_bot_table() {
        string raw_token;
        int bot_id = create_bot_with_permissions("webhook", out raw_token);

        var set = request("POST", "/bot/setWebhook",
            "{\"url\":\"https://hook.example.test/bot\"}", raw_token);
        assert_true(set.status_code == 200);

        Json.Object json = parse_body(set);
        assert_true(json.get_boolean_member("ok"));
        string secret = json.get_object_member("result").get_string_member("secret");

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_secret == secret);
        assert_true(legacy_webhook_secret_column(bot_id) == "");
        assert_true(encrypted_setting_exists("bot_webhook_secret:%d".printf(bot_id)));

        registry.bot.update()
            .with(registry.bot.id, "=", bot_id)
            .set(registry.bot.webhook_secret, "legacy-secret")
            .perform();
        registry.delete_setting("bot_webhook_secret:%d".printf(bot_id));

        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_secret == "legacy-secret");
        registry.migrate_legacy_bot_secrets();
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_secret == "legacy-secret");
        assert_true(legacy_webhook_secret_column(bot_id) == "");
        assert_true(encrypted_setting_exists("bot_webhook_secret:%d".printf(bot_id)));
    }

    void test_dedicated_password_not_stored_in_bot_table() {
        string raw_token;
        int bot_id = create_dedicated_bot_with_permissions("send_message", out raw_token);

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.bot_password == "secret");
        assert_true(legacy_bot_password_column(bot_id) == "");
        assert_true(encrypted_setting_exists("bot_secret_password:%d".printf(bot_id)));

        registry.bot.update()
            .with(registry.bot.id, "=", bot_id)
            .set(registry.bot.bot_password, "legacy-password")
            .perform();
        registry.delete_setting("bot_secret_password:%d".printf(bot_id));

        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.bot_password == "legacy-password");
        registry.migrate_legacy_bot_secrets();
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.bot_password == "legacy-password");
        assert_true(legacy_bot_password_column(bot_id) == "");
        assert_true(encrypted_setting_exists("bot_secret_password:%d".printf(bot_id)));
    }

    void test_delete_bot_removes_scoped_settings() {
        string raw_token;
        int bot_id = create_bot_with_permissions("webhook", out raw_token);

        registry.update_bot_password(bot_id, "secret");
        registry.set_webhook(bot_id, "https://hook.example.test/bot", "webhook-secret", true);
        registry.set_setting("bot_avatar:%d".printf(bot_id), "avatar-data");
        registry.set_setting("bot_avatar_type:%d".printf(bot_id), "image/png");
        registry.set_setting("bot_allowed_targets:%d".printf(bot_id), "friend@example.test");
        registry.set_setting("bot_target_mode:%d".printf(bot_id), "allow");
        registry.set_setting("bot_dedicated_provisioning:%d".printf(bot_id), "manual");
        registry.set_setting("bot_%d_purpose".printf(bot_id), "ai");
        registry.set_setting("bot_%d_muc_rooms".printf(bot_id), "room@example.test");
        registry.set_setting("bot_%d_muc_ai_mode".printf(bot_id), "mention_only");
        registry.set_setting("bot_%d_muc_owner_notify".printf(bot_id), "mentions");
        registry.set_setting("bot_ignore_delayed_before:%d".printf(bot_id), "1770000000");
        registry.set_secret_setting("bot_%d_ai_key".printf(bot_id), "ai-secret");
        registry.set_setting("bot_%d_ai_enabled".printf(bot_id), "true");
        registry.set_setting("bot_%d_ai_provider".printf(bot_id), "gemini");
        registry.set_setting("bot_%d_ai_type".printf(bot_id), "google");
        registry.set_setting("bot_%d_ai_endpoint".printf(bot_id), "https://generativelanguage.googleapis.com");
        registry.set_setting("bot_%d_ai_model".printf(bot_id), "gemini-2.5-flash-lite");
        registry.set_setting("bot_%d_ai_system".printf(bot_id), "Be helpful.");
        registry.set_secret_setting("bot_%d_tg_token".printf(bot_id), "telegram-secret");
        registry.set_setting("bot_%d_tg_chat_id".printf(bot_id), "42");
        registry.set_setting("bot_%d_tg_enabled".printf(bot_id), "true");
        registry.set_setting("bot_%d_tg_mode".printf(bot_id), "bridge");

        assert_true(raw_setting("bot_secret_password:%d".printf(bot_id)) != null);
        assert_true(raw_setting("bot_webhook_secret:%d".printf(bot_id)) != null);
        assert_true(raw_setting("bot_%d_ai_key".printf(bot_id)) != null);
        assert_true(raw_setting("bot_%d_tg_token".printf(bot_id)) != null);

        registry.delete_bot(bot_id);

        assert_true(registry.get_bot_by_id(bot_id) == null);
        assert_true(raw_setting("bot_secret_password:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_webhook_secret:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_avatar:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_avatar_type:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_allowed_targets:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_target_mode:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_dedicated_provisioning:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_purpose".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_muc_ai_mode".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_muc_owner_notify".printf(bot_id)) == null);
        assert_true(raw_setting("bot_ignore_delayed_before:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_ai_key".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_ai_enabled".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_ai_provider".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_ai_type".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_ai_endpoint".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_ai_model".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_ai_system".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_tg_token".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_tg_chat_id".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_tg_enabled".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_tg_mode".printf(bot_id)) == null);
    }

    void test_delete_stops_runtime_before_removing_bot() {
        int bot_id = registry.create_bot("Delete Runtime Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        router.telegram.enabled = true;

        var deleted = request("DELETE", "/bot/delete?id=%d".printf(bot_id));
        assert_true(deleted.status_code == 200);
        assert_true(router.telegram.stop_count == 1);
        assert_true(registry.get_bot_by_id(bot_id) == null);
    }

    void test_delete_manual_dedicated_bot_only_deletes_local_state() {
        int bot_id = registry.create_bot("Delete Manual Dedicated Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "dedicated", "manual-bot@example.test");
        registry.update_bot_password(bot_id, "secret");
        registry.set_setting("bot_dedicated_provisioning:%d".printf(bot_id), "manual");

        var deleted = request("DELETE", "/bot/delete?id=%d".printf(bot_id));
        assert_true(deleted.status_code == 200);
        Json.Object result = parse_body(deleted).get_object_member("result");
        assert_true(result.get_int_member("id") == bot_id);
        assert_true(result.get_boolean_member("deleted"));
        assert_false(result.has_member("account_removed"));

        assert_true(ejabberd_api.unregister_count == 0);
        assert_true(session_pool.prepare_unregister_count == 0);
        assert_true(registry.get_bot_by_id(bot_id) == null);
        assert_true(raw_setting("bot_dedicated_provisioning:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_secret_password:%d".printf(bot_id)) == null);
    }

    void test_delete_ejabberd_provisioned_bot() {
        int bot_id = registry.create_bot("Delete Dedicated Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "dedicated", "delete-bot@example.test");
        registry.set_setting("bot_dedicated_provisioning:%d".printf(bot_id), "ejabberd");
        ejabberd_api.unregister_success = false;

        GLib.Test.expect_message("bot-features-test", GLib.LogLevelFlags.LEVEL_WARNING,
            "*Failed to unregister delete-bot from ejabberd*");
        var deleted = request("DELETE", "/bot/delete?id=%d".printf(bot_id));
        GLib.Test.assert_expected_messages();
        assert_true(deleted.status_code == 200);
        Json.Object result = parse_body(deleted).get_object_member("result");
        assert_true(result.get_int_member("id") == bot_id);
        assert_false(result.get_boolean_member("account_removed"));
        assert_true(session_pool.prepare_unregister_count == 1);
        assert_true(session_pool.last_prepare_unregister_bot_id == bot_id);
        assert_true(registry.get_bot_by_id(bot_id) == null);
        assert_true(raw_setting("bot_dedicated_provisioning:%d".printf(bot_id)) == null);
    }

    void test_revoke_token_marker() {
        int bot_id = registry.create_bot("Revoked Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        string raw_token = token_manager.generate_token(bot_id);
        assert_true(token_manager.validate_token(raw_token) != null);
        router.telegram.enabled = true;
        int status_signal_count = 0;
        registry.bot_status_changed.connect((changed_bot_id, new_status) => {
            if (changed_bot_id == bot_id && new_status == "disabled") {
                status_signal_count++;
            }
        });

        var first = request("POST", "/bot/revoke", "{\"id\":%d}".printf(bot_id));
        assert_true(first.status_code == 200);
        assert_true(token_manager.validate_token(raw_token) == null);
        assert_true(router.telegram.stop_count == 1);
        assert_true(status_signal_count == 1);
        assert_true(count_audit_action(bot_id, "token_revoked") == 1);
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.status == "disabled");
        string first_marker = bot.token_hash;
        assert_true(first_marker.has_prefix("revoked:%d:".printf(bot_id)));

        var second = request("POST", "/bot/revoke", "{\"id\":%d}".printf(bot_id));
        assert_true(second.status_code == 200);
        assert_true(router.telegram.stop_count == 2);
        assert_true(status_signal_count == 2);
        assert_true(count_audit_action(bot_id, "token_revoked") == 2);
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.token_hash.has_prefix("revoked:%d:".printf(bot_id)));
        assert_true(bot.token_hash != first_marker);
    }

    void test_regenerate_token_replaces_token() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);

        var regenerated = request("POST", "/bot/token", "{\"id\":%d}".printf(bot_id));
        assert_true(regenerated.status_code == 200);
        Json.Object result = parse_body(regenerated).get_object_member("result");
        string new_token = result.get_string_member("token");
        assert_true(new_token.has_prefix("bot%d:".printf(bot_id)));
        assert_true(new_token != raw_token);
        assert_true(token_manager.validate_token(raw_token) == null);
        assert_true(token_manager.validate_token(new_token) != null);
        assert_true(request("GET", "/bot/getMe", null, new_token).status_code == 200);
        assert_true(count_audit_action(bot_id, "token_revoked") == 1);
        assert_true(count_audit_action(bot_id, "token_regenerated") == 1);

        var disabled = request("POST", "/bot/activate",
            "{\"id\":%d,\"active\":false}".printf(bot_id));
        assert_true(disabled.status_code == 200);

        var regenerated_disabled = request("POST", "/bot/token", "{\"id\":%d}".printf(bot_id));
        assert_true(regenerated_disabled.status_code == 200);
        string disabled_token = parse_body(regenerated_disabled)
            .get_object_member("result")
            .get_string_member("token");
        assert_true(disabled_token != new_token);
        assert_true(token_manager.validate_token(new_token) == null);
        assert_true(token_manager.validate_token(disabled_token) != null);
        var disabled_me = request("GET", "/bot/getMe", null, disabled_token);
        assert_true(disabled_me.status_code == 403);
        assert_true(parse_body(disabled_me).get_string_member("error") == "inactive");
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.status == "disabled");
    }

    private int count_audit_action(int bot_id, string action) {
        int count = 0;
        foreach (Qlite.Row row in registry.audit_log.select()
                    .with(registry.audit_log.bot_id, "=", bot_id)
                    .with(registry.audit_log.action, "=", action)) {
            if (registry.audit_log.id.get(row) > 0) {
                count++;
            }
        }
        return count;
    }

    private string? latest_audit_details(int bot_id, string action) {
        string? details = null;
        foreach (Qlite.Row row in registry.audit_log.select()
                    .with(registry.audit_log.bot_id, "=", bot_id)
                    .with(registry.audit_log.action, "=", action)
                    .order_by(registry.audit_log.id, "ASC")) {
            details = registry.audit_log.details.get(row);
        }
        return details;
    }

    void test_overlong_bearer_token_rejected_before_lookup() {
        string overlong = "bot1:" + string.nfill(300, 'a');
        var response = request("GET", "/bot/getMe", null, overlong);
        assert_true(response.status_code == 401);
        Json.Object json = parse_body(response);
        assert_true(json.get_string_member("error") == "unauthorized");
    }

    void test_permissions_denied_then_allowed() {
        int bot_id = registry.create_bot("Scoped Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "receive_updates");
        string raw_token = token_manager.generate_token(bot_id);

        var denied = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(denied.status_code == 403);
        Json.Object denied_json = parse_body(denied);
        assert_false(denied_json.get_boolean_member("ok"));
        assert_true(denied_json.get_string_member("error") == "forbidden");

        var update = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":\"send_message\"}".printf(bot_id));
        assert_true(update.status_code == 200);

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(account_disabled.status_code == 403);
        assert_true(router.send_count == 0);

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var allowed = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(allowed.status_code == 200);
        Json.Object allowed_json = parse_body(allowed);
        assert_true(allowed_json.get_boolean_member("ok"));
        assert_true(router.send_count == 1);
        assert_true(router.last_send_to == "friend@example.test");
        assert_true(router.last_send_text == "hello");
        assert_true(router.last_send_type == "chat");
    }

    void test_all_permission_allows_send() {
        int bot_id = registry.create_bot("All Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "all");
        string raw_token = token_manager.generate_token(bot_id);

        var response = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(response.status_code == 200);
    }

    void test_groupchat_requires_muc_send() {
        int bot_id = registry.create_bot("MUC Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "send_message");
        string raw_token = token_manager.generate_token(bot_id);

        var denied = request("POST", "/bot/sendMessage",
            "{\"to\":\"room@conference.example.test\",\"text\":\"hello\",\"type\":\"groupchat\"}", raw_token);
        assert_true(denied.status_code == 403);

        var update = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":\"muc_send\"}".printf(bot_id));
        assert_true(update.status_code == 200);

        var allowed = request("POST", "/bot/sendMessage",
            "{\"to\":\"room@conference.example.test\",\"text\":\"hello\",\"type\":\"groupchat\"}", raw_token);
        assert_true(allowed.status_code == 200);
    }

    void test_invalid_permission_rejected() {
        var create = request("POST", "/bot/create",
            "{\"name\":\"Bad Scope\",\"account\":\"owner@example.test\",\"mode\":\"personal\",\"permissions\":\"send_message,unknown_scope\"}");
        assert_true(create.status_code == 400);
        Json.Object create_json = parse_body(create);
        assert_false(create_json.get_boolean_member("ok"));
        assert_true(create_json.get_string_member("error") == "bad_request");
        assert_true(registry.get_all_bots().size == 0);

        int bot_id = registry.create_bot("Scoped Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "send_message");

        var update = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":\"receive_updates,unknown_scope\"}".printf(bot_id));
        assert_true(update.status_code == 400);

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.permissions == "send_message");
    }

    void test_targets_allowlist_blocks_unlisted_jids() {
        int bot_id = registry.create_bot("Target Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "send_message");
        string raw_token = token_manager.generate_token(bot_id);

        var invalid_update = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"allow\",\"target_list\":\"badtarget\"}".printf(bot_id));
        assert_true(invalid_update.status_code == 400);

        var update = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"allow\",\"target_list\":\"friend@example.test,@trusted.example.test,domain:also-trusted.example.test\"}".printf(bot_id));
        assert_true(update.status_code == 200);
        Json.Object update_json = parse_body(update);
        Json.Object update_result = update_json.get_object_member("result");
        assert_true(update_result.get_string_member("target_mode") == "allow");

        var allowed = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(allowed.status_code == 200);

        var allowed_domain = request("POST", "/bot/sendMessage",
            "{\"to\":\"room@trusted.example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(allowed_domain.status_code == 200);

        var allowed_explicit_domain = request("POST", "/bot/sendMessage",
            "{\"to\":\"room@also-trusted.example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(allowed_explicit_domain.status_code == 200);

        var denied = request("POST", "/bot/sendMessage",
            "{\"to\":\"other@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(denied.status_code == 403);
        Json.Object denied_json = parse_body(denied);
        assert_false(denied_json.get_boolean_member("ok"));
        assert_true(denied_json.get_string_member("error") == "forbidden");

        var clear = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"all\",\"target_list\":\"\"}".printf(bot_id));
        assert_true(clear.status_code == 200);

        var unrestricted = request("POST", "/bot/sendMessage",
            "{\"to\":\"other@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(unrestricted.status_code == 200);
    }

    void test_targets_blocklist_blocks_only_listed_jids() {
        int bot_id = registry.create_bot("Block Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "send_message");
        string raw_token = token_manager.generate_token(bot_id);

        var update = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"block\",\"target_list\":\"blocked@example.test,@blocked-domain.example.test\"}".printf(bot_id));
        assert_true(update.status_code == 200);

        var allowed = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(allowed.status_code == 200);

        var denied_jid = request("POST", "/bot/sendMessage",
            "{\"to\":\"blocked@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(denied_jid.status_code == 403);

        var denied_domain = request("POST", "/bot/sendMessage",
            "{\"to\":\"room@blocked-domain.example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(denied_domain.status_code == 403);
    }

    void test_targets_wildcard_semantics() {
        int bot_id = registry.create_bot("Wildcard Target Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "send_message");
        string raw_token = token_manager.generate_token(bot_id);

        var allow_all = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"allow\",\"target_list\":\"*\"}".printf(bot_id));
        assert_true(allow_all.status_code == 200);

        var allowed = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(allowed.status_code == 200);

        var block_all = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"block\",\"target_list\":\"*\"}".printf(bot_id));
        assert_true(block_all.status_code == 200);

        var blocked = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\"}", raw_token);
        assert_true(blocked.status_code == 403);
    }

    void test_console_send_local_endpoint() {
        int bot_id = registry.create_bot("Console Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "send_message");
        registry.update_bot_status(bot_id, "active");

        var response = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello from console\"}".printf(bot_id));
        assert_true(response.status_code == 200);
        Json.Object json = parse_body(response);
        assert_true(json.get_boolean_member("ok"));
        Json.Object result = json.get_object_member("result");
        assert_true(result.get_string_member("message_id") == "test-message-id");
        assert_true(router.send_count == 1);
        assert_true(router.last_send_to == "friend@example.test");
        assert_true(router.last_send_text == "hello from console");
        assert_true(router.last_send_type == "chat");
    }

    void test_console_send_respects_guards() {
        int bot_id = registry.create_bot("Guarded Console Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(bot_id, "receive_updates");
        registry.update_bot_status(bot_id, "disabled");

        var inactive = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(inactive.status_code == 409);

        registry.update_bot_status(bot_id, "active");
        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(account_disabled.status_code == 403);
        assert_true(router.send_count == 0);

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var denied_permission = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(denied_permission.status_code == 403);

        registry.update_bot_permissions(bot_id, "send_message");
        var update = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"block\",\"target_list\":\"blocked@example.test\"}".printf(bot_id));
        assert_true(update.status_code == 200);

        var denied_target = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"blocked@example.test\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(denied_target.status_code == 403);

        var allowed = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(allowed.status_code == 200);
        assert_true(router.send_count == 1);
        assert_true(router.last_send_to == "friend@example.test");
        assert_true(router.last_send_text == "hello");
    }

    void test_console_room_join_leave_local_endpoint() {
        int bot_id = registry.create_bot("Room Console Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "dedicated", "room-bot@example.test");
        registry.update_bot_permissions(bot_id, "send_message");
        registry.update_bot_status(bot_id, "active");

        var denied_permission = request("POST", "/bot/testJoinRoom",
            "{\"id\":%d,\"room\":\"room@conference.example.test\",\"nick\":\"Bot\"}".printf(bot_id));
        assert_true(denied_permission.status_code == 403);

        registry.update_bot_permissions(bot_id, "muc_join");
        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled = request("POST", "/bot/testJoinRoom",
            "{\"id\":%d,\"room\":\"room@conference.example.test\",\"nick\":\"Bot\"}".printf(bot_id));
        assert_true(account_disabled.status_code == 403);
        assert_true(router.join_count == 0);

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var update_targets = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"block\",\"target_list\":\"blocked@conference.example.test\"}".printf(bot_id));
        assert_true(update_targets.status_code == 200);

        var denied_target = request("POST", "/bot/testJoinRoom",
            "{\"id\":%d,\"room\":\"blocked@conference.example.test\",\"nick\":\"Bot\"}".printf(bot_id));
        assert_true(denied_target.status_code == 403);

        var joined = request("POST", "/bot/testJoinRoom",
            "{\"id\":%d,\"room\":\"room@conference.example.test\",\"nick\":\"Bot\"}".printf(bot_id));
        assert_true(joined.status_code == 200);
        assert_true(router.join_count == 1);
        assert_true(router.last_join_room == "room@conference.example.test");
        assert_true(router.last_join_nick == "Bot");
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == "room@conference.example.test\tBot");

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var leave_account_disabled = request("POST", "/bot/testLeaveRoom",
            "{\"id\":%d,\"room\":\"room@conference.example.test\"}".printf(bot_id));
        assert_true(leave_account_disabled.status_code == 403);
        assert_true(router.leave_count == 0);
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == "room@conference.example.test\tBot");

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var left = request("POST", "/bot/testLeaveRoom",
            "{\"id\":%d,\"room\":\"room@conference.example.test\"}".printf(bot_id));
        assert_true(left.status_code == 200);
        assert_true(router.leave_count == 1);
        assert_true(router.last_leave_room == "room@conference.example.test");
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == null);

        registry.update_bot_status(bot_id, "paused");
        var inactive = request("POST", "/bot/testJoinRoom",
            "{\"id\":%d,\"room\":\"room@conference.example.test\",\"nick\":\"Bot\"}".printf(bot_id));
        assert_true(inactive.status_code == 409);
    }

    void test_account_status_local_endpoint() {
        var initial = request("GET", "/bot/account/status?account=owner@example.test");
        assert_true(initial.status_code == 200);
        Json.Object initial_json = parse_body(initial);
        Json.Object initial_result = initial_json.get_object_member("result");
        assert_true(initial_result.get_boolean_member("enabled"));

        var invalid_get_account = request("GET", "/bot/account/status?account=owner");
        assert_true(invalid_get_account.status_code == 400);

        var missing_enabled = request("POST", "/bot/account/status",
            "{\"account\":\"owner@example.test\"}");
        assert_true(missing_enabled.status_code == 400);

        var invalid_post_account = request("POST", "/bot/account/status",
            "{\"account\":\"owner\",\"enabled\":false}");
        assert_true(invalid_post_account.status_code == 400);

        var disabled = request("POST", "/bot/account/status",
            "{\"account\":\"owner@example.test\",\"enabled\":false}");
        assert_true(disabled.status_code == 200);
        Json.Object disabled_json = parse_body(disabled);
        Json.Object disabled_result = disabled_json.get_object_member("result");
        assert_false(disabled_result.get_boolean_member("enabled"));

        var after = request("GET", "/bot/account/status?account=owner@example.test");
        assert_true(after.status_code == 200);
        Json.Object after_json = parse_body(after);
        Json.Object after_result = after_json.get_object_member("result");
        assert_false(after_result.get_boolean_member("enabled"));
    }

    void test_account_status_runtime_is_account_scoped() {
        int owner_bot = registry.create_bot("Owner Runtime Bot", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(owner_bot, "receive_updates");
        int other_bot = registry.create_bot("Other Runtime Bot", "other@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        registry.update_bot_permissions(other_bot, "receive_updates");
        router.telegram.enabled = true;

        var disable_owner = request("POST", "/bot/account/status",
            "{\"account\":\"owner@example.test\",\"enabled\":false}");
        assert_true(disable_owner.status_code == 200);
        assert_true(router.telegram.stop_count == 1);
        assert_true(router.telegram.start_count == 0);

        var permissions_other = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":\"receive_updates\"}".printf(other_bot));
        assert_true(permissions_other.status_code == 200);
        assert_true(router.telegram.start_count == 1);

        var enable_owner = request("POST", "/bot/account/status",
            "{\"account\":\"owner@example.test\",\"enabled\":true}");
        assert_true(enable_owner.status_code == 200);
        assert_true(router.telegram.start_count == 2);
    }

    void test_ejabberd_settings_local_endpoint() {
        var saved = request("POST", "/bot/ejabberd/settings",
            "{\"api_url\":\"https://xmpp.example.test/api\",\"admin_jid\":\"admin@example.test\",\"admin_password\":\"secret\",\"host\":\"example.test\"}");
        assert_true(saved.status_code == 200);

        var loaded = request("GET", "/bot/ejabberd/settings");
        assert_true(loaded.status_code == 200);
        Json.Object loaded_json = parse_body(loaded);
        Json.Object loaded_result = loaded_json.get_object_member("result");
        assert_true(loaded_result.get_string_member("api_url") == "https://xmpp.example.test/api");
        assert_true(loaded_result.get_string_member("admin_jid") == "admin@example.test");
        assert_true(loaded_result.get_string_member("admin_password") == "********");
        assert_true(loaded_result.get_string_member("host") == "example.test");
        assert_true(registry.get_secret_setting("ejabberd_admin_password") == "secret");

        var resaved_masked = request("POST", "/bot/ejabberd/settings",
            "{\"api_url\":\"https://xmpp.example.test/api2\",\"admin_jid\":\"admin@example.test\",\"admin_password\":\"********\",\"host\":\"example.test\"}");
        assert_true(resaved_masked.status_code == 200);
        assert_true(registry.get_setting("ejabberd_api_url") == "https://xmpp.example.test/api2");
        assert_true(registry.get_secret_setting("ejabberd_admin_password") == "secret");

        var invalid_host = request("POST", "/bot/ejabberd/settings",
            "{\"host\":\"bad@example.test\"}");
        assert_true(invalid_host.status_code == 400);
        assert_true(registry.get_setting("ejabberd_host") == "example.test");
    }

    void test_webhook_management_local_endpoint() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message", out raw_token);

        var initial = request("GET", "/bot/webhook?id=%d".printf(bot_id));
        assert_true(initial.status_code == 200);
        Json.Object initial_result = parse_body(initial).get_object_member("result");
        assert_false(initial_result.get_boolean_member("enabled"));
        assert_false(initial_result.has_member("secret"));

        var invalid_url = request("POST", "/bot/webhook",
            "{\"id\":%d,\"url\":\"ftp://hook.example.test/bot\"}".printf(bot_id));
        assert_true(invalid_url.status_code == 400);

        var cloudbot_management_url = request("POST", "/bot/webhook",
            "{\"id\":%d,\"url\":\"https://cloud.dinox.im/api/v1/bot/me\"}".printf(bot_id));
        assert_true(cloudbot_management_url.status_code == 400);

        var invalid_enabled = request("POST", "/bot/webhook",
            "{\"id\":%d,\"url\":\"https://hook.example.test/bot\",\"enabled\":\"true\"}".printf(bot_id));
        assert_true(invalid_enabled.status_code == 400);

        var missing_url = request("POST", "/bot/webhook", "{\"id\":%d}".printf(bot_id));
        assert_true(missing_url.status_code == 400);

        var set = request("POST", "/bot/webhook",
            "{\"id\":%d,\"url\":\"https://hook.example.test/bot?token=secret#frag\"}".printf(bot_id));
        assert_true(set.status_code == 200);
        Json.Object set_result = parse_body(set).get_object_member("result");
        assert_true(set_result.get_boolean_member("enabled"));
        assert_true(set_result.get_string_member("secret").length == 64);
        assert_true(set_result.get_string_member("webhook_url") == "https://hook.example.test/bot?token=secret#frag");
        assert_true(latest_audit_details(bot_id, "webhook_set") == "https://hook.example.test/bot?...");
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_enabled);
        assert_true(bot.webhook_url == "https://hook.example.test/bot?token=secret#frag");

        var read_back = request("GET", "/bot/webhook?id=%d".printf(bot_id));
        assert_true(read_back.status_code == 200);
        Json.Object read_result = parse_body(read_back).get_object_member("result");
        assert_true(read_result.get_boolean_member("enabled"));
        assert_true(read_result.get_boolean_member("secret_available"));
        assert_false(read_result.has_member("secret"));

        var unset = request("POST", "/bot/webhook",
            "{\"id\":%d,\"enabled\":false}".printf(bot_id));
        assert_true(unset.status_code == 200);
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_false(bot.webhook_enabled);
        assert_true(bot.webhook_url == null || bot.webhook_url == "");
        assert_true(bot.webhook_secret == null || bot.webhook_secret == "");
    }

    void test_avatar_management_local_endpoint() {
        string raw_token;
        int bot_id = create_bot_with_permissions("admin", out raw_token);
        string dedicated_token;
        int dedicated_id = create_dedicated_bot_with_permissions("admin", out dedicated_token);

        var initial = request("GET", "/bot/avatar?id=%d".printf(bot_id));
        assert_true(initial.status_code == 200);
        Json.Object initial_result = parse_body(initial).get_object_member("result");
        assert_false(initial_result.get_boolean_member("configured"));

        var invalid = request("POST", "/bot/avatar",
            "{\"id\":%d,\"avatar\":123}".printf(bot_id));
        assert_true(invalid.status_code == 400);

        var set = request("POST", "/bot/avatar",
            "{\"id\":%d,\"avatar\":\"avatar-data\",\"avatar_type\":\"image/png\"}".printf(bot_id));
        assert_true(set.status_code == 200);
        assert_true(raw_setting("bot_avatar:%d".printf(bot_id)) == "avatar-data");
        assert_true(raw_setting("bot_avatar_type:%d".printf(bot_id)) == "image/png");

        var listed = request("GET", "/bot/list?account=owner@example.test");
        assert_true(listed.status_code == 200);
        assert_true(listed.body.index_of("\"avatar_configured\":true") >= 0);

        var removed = request("POST", "/bot/avatar",
            "{\"id\":%d,\"remove\":true}".printf(bot_id));
        assert_true(removed.status_code == 200);
        assert_true(raw_setting("bot_avatar:%d".printf(bot_id)) == null);
        assert_true(raw_setting("bot_avatar_type:%d".printf(bot_id)) == null);

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var dedicated_account_disabled = request("POST", "/bot/avatar",
            "{\"id\":%d,\"avatar\":\"avatar-data\",\"avatar_type\":\"image/png\"}".printf(dedicated_id));
        assert_true(dedicated_account_disabled.status_code == 200);
        assert_true(session_pool.refresh_count == 0);
        assert_true(raw_setting("bot_avatar:%d".printf(dedicated_id)) == "avatar-data");

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var dedicated_account_enabled = request("POST", "/bot/avatar",
            "{\"id\":%d,\"avatar\":\"avatar-data-2\",\"avatar_type\":\"image/png\"}".printf(dedicated_id));
        assert_true(dedicated_account_enabled.status_code == 200);
        assert_true(session_pool.refresh_count == 1);
        assert_true(session_pool.last_refresh_bot_id == dedicated_id);

        var dedicated_remove_enabled = request("POST", "/bot/avatar",
            "{\"id\":%d,\"remove\":true}".printf(dedicated_id));
        assert_true(dedicated_remove_enabled.status_code == 200);
        assert_true(session_pool.refresh_count == 2);
        assert_true(session_pool.last_refresh_bot_id == dedicated_id);
        assert_true(raw_setting("bot_avatar:%d".printf(dedicated_id)) == null);
        assert_true(raw_setting("bot_avatar_type:%d".printf(dedicated_id)) == null);

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var dedicated_remove_disabled = request("POST", "/bot/avatar",
            "{\"id\":%d,\"remove\":true}".printf(dedicated_id));
        assert_true(dedicated_remove_disabled.status_code == 200);
        assert_true(session_pool.refresh_count == 2);
    }

    void test_telegram_management_local_endpoint() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message,receive_updates", out raw_token);

        var initial = request("GET", "/bot/telegram/manage?id=%d".printf(bot_id));
        assert_true(initial.status_code == 200);
        Json.Object initial_result = parse_body(initial).get_object_member("result");
        assert_false(initial_result.get_boolean_member("configured"));
        assert_false(initial_result.get_boolean_member("enabled"));

        var missing = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"token\":\"123:ABC\"}".printf(bot_id));
        assert_true(missing.status_code == 400);

        var bad_mode = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"token\":\"123:ABC\",\"chat_id\":\"42\",\"mode\":\"bad\"}".printf(bot_id));
        assert_true(bad_mode.status_code == 400);

        var bad_enabled = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"enabled\":\"true\"}".printf(bot_id));
        assert_true(bad_enabled.status_code == 400);

        var enabled_unconfigured = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"enabled\":true}".printf(bot_id));
        assert_true(enabled_unconfigured.status_code == 400);

        var setup = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"token\":\"123:ABC\",\"chat_id\":\"42\",\"mode\":\"forward\"}".printf(bot_id));
        assert_true(setup.status_code == 200);
        Json.Object setup_result = parse_body(setup).get_object_member("result");
        assert_true(setup_result.get_boolean_member("configured"));
        assert_false(setup_result.get_boolean_member("enabled"));
        assert_true(setup_result.get_string_member("chat_id") == "42");
        assert_true(setup_result.get_string_member("mode") == "forward");
        assert_false(setup.body.contains("123:ABC"));
        assert_true(router.telegram.configure_count == 1);
        assert_true(router.telegram.last_token == "123:ABC");
        assert_true(router.telegram.last_chat_id == "42");
        assert_true(router.telegram.last_mode == "forward");
        assert_true(router.telegram.start_count == 0);

        var list = request("GET", "/bot/list");
        assert_true(list.status_code == 200);
        Json.Array bots = parse_body(list).get_array_member("bots");
        assert_true(bots.get_length() == 1);
        Json.Object listed_telegram = bots.get_object_element(0).get_object_member("telegram");
        assert_true(listed_telegram.get_boolean_member("configured"));
        assert_false(list.body.contains("123:ABC"));

        var enabled = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"enabled\":true}".printf(bot_id));
        assert_true(enabled.status_code == 200);
        assert_true(router.telegram.start_count == 1);
        Json.Object enabled_result = parse_body(enabled).get_object_member("result");
        assert_true(enabled_result.get_boolean_member("enabled"));

        var update_without_token = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"chat_id\":\"99\",\"mode\":\"bridge\"}".printf(bot_id));
        assert_true(update_without_token.status_code == 200);
        Json.Object updated_result = parse_body(update_without_token).get_object_member("result");
        assert_true(updated_result.get_boolean_member("configured"));
        assert_true(updated_result.get_boolean_member("enabled"));
        assert_true(updated_result.get_string_member("chat_id") == "99");
        assert_true(updated_result.get_string_member("mode") == "bridge");
        assert_false(update_without_token.body.contains("123:ABC"));
        assert_true(router.telegram.configure_count == 2);
        assert_true(router.telegram.last_token == "123:ABC");
        assert_true(router.telegram.last_chat_id == "99");
        assert_true(router.telegram.last_mode == "bridge");

        var disabled = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"enabled\":false}".printf(bot_id));
        assert_true(disabled.status_code == 200);
        assert_true(router.telegram.stop_count == 1);
        Json.Object disabled_result = parse_body(disabled).get_object_member("result");
        assert_false(disabled_result.get_boolean_member("enabled"));

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var enable_account_disabled = request("POST", "/bot/telegram/manage",
            "{\"id\":%d,\"enabled\":true}".printf(bot_id));
        assert_true(enable_account_disabled.status_code == 200);
        assert_true(router.telegram.start_count == 1);
        assert_true(parse_body(enable_account_disabled)
            .get_object_member("result")
            .get_boolean_member("enabled"));
    }

    void test_ai_management_local_endpoint() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message,receive_updates", out raw_token);

        var initial = request("GET", "/bot/ai/manage?id=%d".printf(bot_id));
        assert_true(initial.status_code == 200);
        Json.Object initial_result = parse_body(initial).get_object_member("result");
        assert_false(initial_result.get_boolean_member("configured"));
        assert_false(initial_result.get_boolean_member("enabled"));

        var missing = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"provider\":\"ollama\"}".printf(bot_id));
        assert_true(missing.status_code == 400);

        var bad_provider = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"provider\":\"unknown\",\"model\":\"llama3\"}".printf(bot_id));
        assert_true(bad_provider.status_code == 400);

        var missing_key = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"provider\":\"openai\",\"model\":\"gpt-4o\"}".printf(bot_id));
        assert_true(missing_key.status_code == 400);

        var bad_enabled = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"enabled\":\"true\"}".printf(bot_id));
        assert_true(bad_enabled.status_code == 400);

        var enabled_unconfigured = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"enabled\":true}".printf(bot_id));
        assert_true(enabled_unconfigured.status_code == 400);

        var setup = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"provider\":\" OLLAMA \",\"model\":\" llama3 \"}".printf(bot_id));
        assert_true(setup.status_code == 200);
        Json.Object setup_result = parse_body(setup).get_object_member("result");
        assert_true(setup_result.get_boolean_member("configured"));
        assert_false(setup_result.get_boolean_member("enabled"));
        assert_true(setup_result.get_string_member("provider") == "ollama");
        assert_true(setup_result.get_string_member("model") == "llama3");
        assert_true(router.ai.configure_count == 1);
        assert_true(router.ai.last_provider == "ollama");
        assert_true(router.ai.last_api_key == "-");
        assert_true(router.ai.last_model == "llama3");

        var update_without_key = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"model\":\"phi3\"}".printf(bot_id));
        assert_true(update_without_key.status_code == 200);
        Json.Object updated_result = parse_body(update_without_key).get_object_member("result");
        assert_true(updated_result.get_string_member("model") == "phi3");
        assert_false(updated_result.get_boolean_member("enabled"));
        assert_false(update_without_key.body.contains("sk-"));
        assert_true(router.ai.configure_count == 2);
        assert_true(router.ai.last_provider == "ollama");
        assert_true(router.ai.last_api_key == "-");
        assert_true(router.ai.last_model == "phi3");

        var gemini = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"provider\":\"gemini\",\"api_key\":\"AIza-test-key\",\"model\":\"gemini-2.5-flash-lite\"}".printf(bot_id));
        assert_true(gemini.status_code == 200);
        Json.Object gemini_result = parse_body(gemini).get_object_member("result");
        assert_true(gemini_result.get_string_member("provider") == "gemini");
        assert_true(gemini_result.get_string_member("model") == "gemini-2.5-flash-lite");
        assert_true(gemini_result.get_boolean_member("configured"));
        assert_false(gemini_result.get_boolean_member("enabled"));
        assert_false(gemini.body.contains("AIza-test-key"));
        assert_true(router.ai.configure_count == 3);
        assert_true(router.ai.last_provider == "gemini");
        assert_true(router.ai.last_api_key == "AIza-test-key");
        assert_true(router.ai.last_model == "gemini-2.5-flash-lite");
        assert_true(registry.get_secret_setting("bot_%d_ai_key".printf(bot_id)) == "AIza-test-key");

        var behavior = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"system_prompt\":\"Support only DinoX topics.\",\"muc_owner_notify\":\"mentions_when_owner_absent\",\"muc_ai_mode\":\"support_questions\"}".printf(bot_id));
        assert_true(behavior.status_code == 200);
        Json.Object behavior_result = parse_body(behavior).get_object_member("result");
        assert_true(behavior_result.get_string_member("system_prompt") == "Support only DinoX topics.");
        assert_true(behavior_result.get_string_member("muc_owner_notify") == "mentions_when_owner_absent");
        assert_true(behavior_result.get_string_member("muc_ai_mode") == "support_questions");
        assert_true(raw_setting("bot_%d_ai_system".printf(bot_id)) == "Support only DinoX topics.");
        assert_true(raw_setting("bot_%d_muc_owner_notify".printf(bot_id)) == "mentions_when_owner_absent");
        assert_true(raw_setting("bot_%d_muc_ai_mode".printf(bot_id)) == "support_questions");

        var reset_behavior = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"system_prompt\":\"   \",\"muc_owner_notify\":\"off\",\"muc_ai_mode\":\"mention_only\"}".printf(bot_id));
        assert_true(reset_behavior.status_code == 200);
        Json.Object reset_result = parse_body(reset_behavior).get_object_member("result");
        assert_true(reset_result.get_string_member("system_prompt") == "");
        assert_true(reset_result.get_string_member("muc_owner_notify") == "off");
        assert_true(reset_result.get_string_member("muc_ai_mode") == "mention_only");
        assert_true(raw_setting("bot_%d_ai_system".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_muc_owner_notify".printf(bot_id)) == null);
        assert_true(raw_setting("bot_%d_muc_ai_mode".printf(bot_id)) == null);

        var restore_behavior = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"system_prompt\":\"Support only DinoX topics.\",\"muc_owner_notify\":\"mentions_when_owner_absent\",\"muc_ai_mode\":\"support_questions\"}".printf(bot_id));
        assert_true(restore_behavior.status_code == 200);

        var bad_notify = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"system_prompt\":\"Should not be stored\",\"muc_owner_notify\":\"always\"}".printf(bot_id));
        assert_true(bad_notify.status_code == 400);
        assert_true(raw_setting("bot_%d_ai_system".printf(bot_id)) == "Support only DinoX topics.");
        assert_true(raw_setting("bot_%d_muc_owner_notify".printf(bot_id)) == "mentions_when_owner_absent");
        assert_true(raw_setting("bot_%d_muc_ai_mode".printf(bot_id)) == "support_questions");

        var bad_muc_ai_mode = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"muc_owner_notify\":\"off\",\"muc_ai_mode\":\"always\"}".printf(bot_id));
        assert_true(bad_muc_ai_mode.status_code == 400);
        assert_true(raw_setting("bot_%d_muc_owner_notify".printf(bot_id)) == "mentions_when_owner_absent");
        assert_true(raw_setting("bot_%d_muc_ai_mode".printf(bot_id)) == "support_questions");

        var list = request("GET", "/bot/list");
        assert_true(list.status_code == 200);
        Json.Array bots = parse_body(list).get_array_member("bots");
        assert_true(bots.get_length() == 1);
        Json.Object listed_ai = bots.get_object_element(0).get_object_member("ai");
        assert_true(listed_ai.get_boolean_member("configured"));
        assert_true(listed_ai.get_string_member("provider") == "gemini");
        assert_false(listed_ai.get_boolean_member("enabled"));
        assert_true(listed_ai.get_string_member("system_prompt") == "Support only DinoX topics.");
        assert_true(listed_ai.get_string_member("muc_owner_notify") == "mentions_when_owner_absent");
        assert_true(listed_ai.get_string_member("muc_ai_mode") == "support_questions");

        var enabled = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"enabled\":true}".printf(bot_id));
        assert_true(enabled.status_code == 200);
        Json.Object enabled_result = parse_body(enabled).get_object_member("result");
        assert_true(enabled_result.get_boolean_member("enabled"));

        var enabled_model_update = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"model\":\"gemini-2.5-flash\"}".printf(bot_id));
        assert_true(enabled_model_update.status_code == 200);
        Json.Object enabled_model_result = parse_body(enabled_model_update).get_object_member("result");
        assert_true(enabled_model_result.get_boolean_member("enabled"));
        assert_true(enabled_model_result.get_string_member("model") == "gemini-2.5-flash");

        var back_to_ollama = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"provider\":\"ollama\",\"model\":\"llama3.1\"}".printf(bot_id));
        assert_true(back_to_ollama.status_code == 200);
        Json.Object ollama_result = parse_body(back_to_ollama).get_object_member("result");
        assert_true(ollama_result.get_string_member("provider") == "ollama");
        assert_true(ollama_result.get_string_member("model") == "llama3.1");
        assert_true(ollama_result.get_boolean_member("enabled"));
        assert_true(registry.get_secret_setting("bot_%d_ai_key".printf(bot_id)) == "");
        assert_true(router.ai.configure_count == 5);
        assert_true(router.ai.last_provider == "ollama");
        assert_true(router.ai.last_api_key == "-");
        assert_true(router.ai.last_model == "llama3.1");

        var disabled = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"enabled\":false}".printf(bot_id));
        assert_true(disabled.status_code == 200);
        Json.Object disabled_result = parse_body(disabled).get_object_member("result");
        assert_false(disabled_result.get_boolean_member("enabled"));
    }

    void test_ai_provider_presets_accept_supported_values() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message", out raw_token);

        string[] providers = {
            "ollama",
            "openai",
            "claude",
            "gemini",
            "groq",
            "mistral",
            "deepseek",
            "perplexity",
            "xai",
            "openclaw"
        };
        string[] expected_types = {
            "ollama",
            "openai",
            "claude",
            "gemini",
            "openai",
            "openai",
            "openai",
            "openai",
            "xai",
            "openclaw"
        };

        for (int i = 0; i < providers.length; i++) {
            string provider = providers[i];
            string key = provider == "ollama" ? "-" : "test-api-key";
            string model = provider == "openclaw" ? "agent" : "test-model";
            var response = request("POST", "/bot/ai/manage",
                "{\"id\":%d,\"provider\":\"%s\",\"api_key\":\"%s\",\"model\":\"%s\"}".printf(
                    bot_id, provider, key, model));
            assert_true(response.status_code == 200);
            Json.Object result = parse_body(response).get_object_member("result");
            assert_true(result.get_string_member("provider") == provider);
            assert_true(result.get_string_member("type") == expected_types[i]);
            assert_true(result.get_string_member("model") == model);
            assert_false(response.body.contains("test-api-key"));
        }
    }

    void test_ai_setup_accepts_supported_provider_presets() {
        string raw_token;
        int bot_id = create_bot_with_permissions("admin", out raw_token);
        registry.set_setting("bot_%d_ai_system".printf(bot_id), "Keep this prompt.");

        string[] providers = {
            "ollama",
            "openai",
            "claude",
            "gemini",
            "groq",
            "mistral",
            "deepseek",
            "perplexity",
            "xai",
            "openclaw"
        };
        string[] expected_types = {
            "ollama",
            "openai",
            "claude",
            "gemini",
            "openai",
            "openai",
            "openai",
            "openai",
            "xai",
            "openclaw"
        };

        for (int i = 0; i < providers.length; i++) {
            string provider = providers[i];
            string key = provider == "ollama" ? "-" : "api-key-for-" + provider;
            string model = provider == "openclaw" ? "agent" : "test-model";
            var response = request("POST", "/bot/ai/setup",
                "{\"provider\":\"%s\",\"api_key\":\"%s\",\"model\":\"%s\"}".printf(
                    provider, key, model), raw_token);
            assert_true(response.status_code == 200);
            Json.Object result = parse_body(response).get_object_member("result");
            assert_true(result.get_boolean_member("configured"));
            assert_true(result.get_string_member("provider") == provider);
            assert_true(result.get_string_member("model") == model);
            assert_false(response.body.contains("api-key-for-"));

            assert_true(raw_setting("bot_%d_ai_provider".printf(bot_id)) == provider);
            assert_true(raw_setting("bot_%d_ai_type".printf(bot_id)) == expected_types[i]);
            assert_true(raw_setting("bot_%d_ai_model".printf(bot_id)) == model);
            assert_true(raw_setting("bot_%d_ai_enabled".printf(bot_id)) == "true");
            assert_true(raw_setting("bot_%d_ai_system".printf(bot_id)) == "Keep this prompt.");
        }

        var back_to_ollama = request("POST", "/bot/ai/setup",
            "{\"provider\":\"ollama\",\"model\":\"llama3.1\"}", raw_token);
        assert_true(back_to_ollama.status_code == 200);
        assert_true(registry.get_secret_setting("bot_%d_ai_key".printf(bot_id)) == "");
    }

    void test_ai_test_ask_local_endpoint() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message", out raw_token);

        var blank = request("POST", "/bot/ai/testAsk",
            "{\"id\":%d,\"message\":\"   \"}".printf(bot_id));
        assert_true(blank.status_code == 400);

        var not_configured = request("POST", "/bot/ai/testAsk",
            "{\"id\":%d,\"message\":\"hello\"}".printf(bot_id));
        assert_true(not_configured.status_code == 400);

        var setup = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"provider\":\"ollama\",\"model\":\"llama3\"}".printf(bot_id));
        assert_true(setup.status_code == 200);

        var disabled = request("POST", "/bot/ai/testAsk",
            "{\"id\":%d,\"message\":\"hello\"}".printf(bot_id));
        assert_true(disabled.status_code == 400);
        assert_true(router.ai.ask_count == 0);

        var enable = request("POST", "/bot/ai/manage",
            "{\"id\":%d,\"enabled\":true}".printf(bot_id));
        assert_true(enable.status_code == 200);

        var no_answer = request("POST", "/bot/ai/testAsk",
            "{\"id\":%d,\"message\":\"hello\"}".printf(bot_id));
        assert_true(no_answer.status_code == 500);
        assert_true(router.ai.ask_count == 1);

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled = request("POST", "/bot/ai/testAsk",
            "{\"id\":%d,\"message\":\"hello\"}".printf(bot_id));
        assert_true(account_disabled.status_code == 403);
        assert_true(router.ai.ask_count == 1);

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");

        router.ai.answer = "local answer";
        var asked = request("POST", "/bot/ai/testAsk",
            "{\"id\":%d,\"message\":\"hello\"}".printf(bot_id));
        assert_true(asked.status_code == 200);
        assert_true(router.ai.ask_count == 2);
        assert_true(router.ai.last_ask_bot_id == bot_id);
        assert_true(router.ai.last_ask_from == "local-ui");
        assert_true(router.ai.last_ask_question == "hello");
        assert_true(router.send_count == 0);
        Json.Object result = parse_body(asked).get_object_member("result");
        assert_true(result.get_string_member("response") == "local answer");
    }

    void test_get_info_does_not_leak_secrets() {
        string raw_token;
        int bot_id = create_dedicated_bot_with_permissions("all", out raw_token);
        registry.set_secret_setting("bot_%d_tg_token".printf(bot_id), "123:ABC-secret-token");
        registry.set_setting("bot_%d_tg_chat_id".printf(bot_id), "42");
        registry.set_setting("bot_%d_tg_mode".printf(bot_id), "bridge");
        registry.set_setting("bot_%d_tg_enabled".printf(bot_id), "true");
        registry.set_secret_setting("bot_%d_ai_key".printf(bot_id), "AIza-secret-key");
        registry.set_setting("bot_%d_ai_provider".printf(bot_id), "gemini");
        registry.set_setting("bot_%d_ai_type".printf(bot_id), "gemini");
        registry.set_setting("bot_%d_ai_endpoint".printf(bot_id), "https://generativelanguage.googleapis.com/v1beta");
        registry.set_setting("bot_%d_ai_model".printf(bot_id), "gemini-2.5-flash-lite");
        registry.set_setting("bot_%d_ai_enabled".printf(bot_id), "true");
        registry.set_webhook(bot_id, "https://hook.example.test/bot?token=url-visible-token", "webhook-secret-value", true);

        var info = request("GET", "/bot/getInfo", null, raw_token);
        assert_true(info.status_code == 200);
        Json.Object json = parse_body(info);
        assert_true(json.get_boolean_member("ok"));
        assert_true(json.get_object_member("result").has_member("bot"));
        assert_false(info.body.contains(raw_token));
        assert_true(info.body.contains("url-visible-token"));
        assert_false(info.body.contains("123:ABC"));
        assert_false(info.body.contains("AIza"));
        assert_false(info.body.contains("webhook-secret-value"));
        assert_false(info.body.contains("secret-token"));
        assert_false(info.body.contains("secret-key"));
        assert_false(info.body.contains("bot_password"));
        assert_false(info.body.contains("token_hash"));
    }

    void test_receive_updates_scope_guards_updates_and_commands() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message", out raw_token);
        registry.enqueue_update(bot_id, "message", "{\"body\":\"secret\"}");

        var denied_updates = request("GET", "/bot/getUpdates", null, raw_token);
        assert_true(denied_updates.status_code == 403);

        var denied_commands = request("GET", "/bot/getCommands", null, raw_token);
        assert_true(denied_commands.status_code == 403);

        registry.update_bot_permissions(bot_id, "receive_updates");

        var allowed_updates = request("GET", "/bot/getUpdates", null, raw_token);
        assert_true(allowed_updates.status_code == 200);
        Json.Object updates_json = parse_body(allowed_updates);
        assert_true(updates_json.get_boolean_member("ok"));
        assert_true(updates_json.get_array_member("result").get_length() == 1);

        var allowed_commands = request("GET", "/bot/getCommands", null, raw_token);
        assert_true(allowed_commands.status_code == 200);
    }

    void test_webhook_requires_scope_and_post() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);

        var denied = request("POST", "/bot/setWebhook",
            "{\"url\":\"https://hook.example.test/bot\"}", raw_token);
        assert_true(denied.status_code == 403);

        registry.update_bot_permissions(bot_id, "webhook");

        var invalid_scheme = request("POST", "/bot/setWebhook",
            "{\"url\":\"httpx://hook.example.test/bot\"}", raw_token);
        assert_true(invalid_scheme.status_code == 400);

        var cloudbot_management_url = request("POST", "/bot/setWebhook",
            "{\"url\":\"https://cloud.dinox.im/api/v1/bot/me\"}", raw_token);
        assert_true(cloudbot_management_url.status_code == 400);

        var set = request("POST", "/bot/setWebhook",
            "{\"url\":\"  https://hook.example.test/bot  \"}", raw_token);
        assert_true(set.status_code == 200);
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_enabled);
        assert_true(bot.webhook_url == "https://hook.example.test/bot");

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled_set = request("POST", "/bot/setWebhook",
            "{\"url\":\"https://hook.example.test/other\"}", raw_token);
        assert_true(account_disabled_set.status_code == 403);
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_enabled);
        assert_true(bot.webhook_url == "https://hook.example.test/bot");

        var account_disabled_delete = request("POST", "/bot/deleteWebhook", "{}", raw_token);
        assert_true(account_disabled_delete.status_code == 403);
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_enabled);
        assert_true(bot.webhook_url == "https://hook.example.test/bot");

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var wrong_method = request("GET", "/bot/deleteWebhook", null, raw_token);
        assert_true(wrong_method.status_code == 405);
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_true(bot.webhook_enabled);

        var deleted = request("POST", "/bot/deleteWebhook", "{}", raw_token);
        assert_true(deleted.status_code == 200);
        bot = registry.get_bot_by_id(bot_id);
        assert_true(bot != null);
        assert_false(bot.webhook_enabled);
    }

    void test_file_send_respects_scope_and_targets() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message", out raw_token);

        var denied_scope = request("POST", "/bot/sendFile",
            "{\"to\":\"friend@example.test\",\"url\":\"https://files.example.test/a.png\"}", raw_token);
        assert_true(denied_scope.status_code == 403);

        registry.update_bot_permissions(bot_id, "file_send");
        var update_targets = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"block\",\"target_list\":\"blocked@example.test\"}".printf(bot_id));
        assert_true(update_targets.status_code == 200);

        var denied_target = request("POST", "/bot/sendFile",
            "{\"to\":\"blocked@example.test\",\"url\":\"https://files.example.test/a.png\"}", raw_token);
        assert_true(denied_target.status_code == 403);

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled = request("POST", "/bot/sendFile",
            "{\"to\":\"friend@example.test\",\"url\":\"https://files.example.test/a.png\"}", raw_token);
        assert_true(account_disabled.status_code == 403);
        assert_true(router.file_count == 0);

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var allowed = request("POST", "/bot/sendFile",
            "{\"to\":\"friend@example.test\",\"url\":\"https://files.example.test/a.png\",\"caption\":\"preview\"}", raw_token);
        assert_true(allowed.status_code == 200);
        Json.Object allowed_json = parse_body(allowed);
        assert_true(allowed_json.get_boolean_member("ok"));
        assert_true(allowed_json.get_object_member("result").get_string_member("message_id") == "test-file-id");
        assert_true(router.file_count == 1);
        assert_true(router.last_file_to == "friend@example.test");
        assert_true(router.last_file_url == "https://files.example.test/a.png");
        assert_true(router.last_file_caption == "preview");
    }

    void test_admin_and_muc_join_guard_control_endpoints() {
        string raw_token;
        int bot_id = create_dedicated_bot_with_permissions("receive_updates", out raw_token);

        var denied_commands = request("POST", "/bot/setCommands",
            "{\"commands\":[{\"command\":\"/ping\",\"description\":\"Ping\"}]}", raw_token);
        assert_true(denied_commands.status_code == 403);

        var denied_telegram = request("POST", "/bot/telegram/setup",
            "{\"token\":\"123:ABC\",\"chat_id\":\"42\",\"mode\":\"bridge\"}", raw_token);
        assert_true(denied_telegram.status_code == 403);

        var denied_ai = request("POST", "/bot/ai/setup",
            "{\"provider\":\"ollama\",\"model\":\"llama3\"}", raw_token);
        assert_true(denied_ai.status_code == 403);

        registry.update_bot_permissions(bot_id, "admin");
        var invalid_commands = request("POST", "/bot/setCommands",
            "{\"commands\":[{\"description\":\"Missing command\"}]}", raw_token);
        assert_true(invalid_commands.status_code == 400);

        var invalid_command_description = request("POST", "/bot/setCommands",
            "{\"commands\":[{\"command\":\"/ping\",\"description\":123}]}", raw_token);
        assert_true(invalid_command_description.status_code == 400);

        var allowed_commands = request("POST", "/bot/setCommands",
            "{\"commands\":[{\"command\":\"/ping\",\"description\":\"Ping\"}]}", raw_token);
        assert_true(allowed_commands.status_code == 200);

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled_commands = request("POST", "/bot/setCommands",
            "{\"commands\":[{\"command\":\"/changed\",\"description\":\"Changed\"}]}", raw_token);
        assert_true(account_disabled_commands.status_code == 403);
        var commands_after_disabled = registry.get_bot_commands(bot_id);
        assert_true(commands_after_disabled.size == 1);
        assert_true(commands_after_disabled[0].command == "/ping");

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        registry.update_bot_permissions(bot_id, "send_message");
        var denied_join = request("POST", "/bot/joinRoom",
            "{\"room\":\"room@conference.example.test\",\"nick\":\"Bot\"}", raw_token);
        assert_true(denied_join.status_code == 403);

        registry.update_bot_permissions(bot_id, "muc_join");
        var update_targets = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"block\",\"target_list\":\"blocked@conference.example.test\"}".printf(bot_id));
        assert_true(update_targets.status_code == 200);

        var denied_target_join = request("POST", "/bot/joinRoom",
            "{\"room\":\"blocked@conference.example.test\",\"nick\":\"Bot\"}", raw_token);
        assert_true(denied_target_join.status_code == 403);

        var allowed_join = request("POST", "/bot/joinRoom",
            "{\"room\":\"room@conference.example.test\",\"nick\":\"Bot\"}", raw_token);
        assert_true(allowed_join.status_code == 200);
        assert_true(router.join_count == 1);
        assert_true(router.last_join_room == "room@conference.example.test");
        assert_true(router.last_join_nick == "Bot");
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == "room@conference.example.test\tBot");

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled_leave = request("POST", "/bot/leaveRoom",
            "{\"room\":\"room@conference.example.test\"}", raw_token);
        assert_true(account_disabled_leave.status_code == 403);
        assert_true(router.leave_count == 0);
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == "room@conference.example.test\tBot");

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var denied_target_leave = request("POST", "/bot/leaveRoom",
            "{\"room\":\"blocked@conference.example.test\"}", raw_token);
        assert_true(denied_target_leave.status_code == 403);

        var allowed_leave = request("POST", "/bot/leaveRoom",
            "{\"room\":\"room@conference.example.test\"}", raw_token);
        assert_true(allowed_leave.status_code == 200);
        assert_true(router.leave_count == 1);
        assert_true(router.last_leave_room == "room@conference.example.test");
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == null);
    }

    void test_reaction_respects_scope_and_targets() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);

        var denied_scope = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"m1\",\"reaction\":\"+1\"}", raw_token);
        assert_true(denied_scope.status_code == 403);

        registry.update_bot_permissions(bot_id, "send_message");
        var update_targets = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"block\",\"target_list\":\"blocked@example.test\"}".printf(bot_id));
        assert_true(update_targets.status_code == 200);

        var denied_target = request("POST", "/bot/sendReaction",
            "{\"to\":\"blocked@example.test\",\"message_id\":\"m1\",\"reaction\":\"+1\"}", raw_token);
        assert_true(denied_target.status_code == 403);

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"m1\",\"reaction\":\"+1\"}", raw_token);
        assert_true(account_disabled.status_code == 403);
        assert_true(router.reaction_count == 0);

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        var allowed = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"m1\",\"reaction\":\"+1\"}", raw_token);
        assert_true(allowed.status_code == 200);
        assert_true(router.reaction_count == 1);
        assert_true(router.last_reaction_to == "friend@example.test");
        assert_true(router.last_reaction_message_id == "m1");
        assert_true(router.last_reaction == "+1");
    }

    void test_bridge_endpoints_respect_scopes() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);

        var telegram_status = request("GET", "/bot/telegram/status", null, raw_token);
        assert_true(telegram_status.status_code == 200);

        var ai_status = request("GET", "/bot/ai/status", null, raw_token);
        assert_true(ai_status.status_code == 200);

        var denied_telegram_send = request("POST", "/bot/telegram/send",
            "{\"text\":\"hello\"}", raw_token);
        assert_true(denied_telegram_send.status_code == 403);

        var denied_ai_ask = request("POST", "/bot/ai/ask",
            "{\"message\":\"hello\"}", raw_token);
        assert_true(denied_ai_ask.status_code == 403);

        var denied_telegram_enable = request("POST", "/bot/telegram/enable",
            "{\"enabled\":true}", raw_token);
        assert_true(denied_telegram_enable.status_code == 403);

        var denied_ai_enable = request("POST", "/bot/ai/enable",
            "{\"enabled\":true}", raw_token);
        assert_true(denied_ai_enable.status_code == 403);

        registry.update_bot_permissions(bot_id, "admin");
        var invalid_telegram_setup = request("POST", "/bot/telegram/setup",
            "{\"token\":\"\",\"chat_id\":\"42\",\"mode\":\"bridge\"}", raw_token);
        assert_true(invalid_telegram_setup.status_code == 400);

        var telegram_setup = request("POST", "/bot/telegram/setup",
            "{\"token\":\" 123:ABC \",\"chat_id\":\" 42 \",\"mode\":\" bridge \"}", raw_token);
        assert_true(telegram_setup.status_code == 200);
        assert_false(telegram_setup.body.contains("123:ABC"));
        assert_true(router.telegram.start_count == 0);
        assert_true(router.telegram.stop_count == 1);

        router.telegram.test_success = true;
        router.telegram.test_result = "Bot: Local Test (@local_test_bot)";
        var telegram_test = request("POST", "/bot/telegram/test", "{}", raw_token);
        assert_true(telegram_test.status_code == 200);
        Json.Object telegram_test_json = parse_body(telegram_test);
        assert_true(telegram_test_json.get_boolean_member("ok"));
        assert_true(telegram_test_json.get_object_member("result").get_boolean_member("connected"));
        assert_true(telegram_test_json.get_object_member("result").get_string_member("info").contains("@local_test_bot"));

        registry.update_bot_permissions(bot_id, "admin,receive_updates");
        var telegram_setup_with_updates = request("POST", "/bot/telegram/setup",
            "{\"token\":\"123:ABC\",\"chat_id\":\"42\",\"mode\":\"bridge\"}", raw_token);
        assert_true(telegram_setup_with_updates.status_code == 200);
        assert_false(telegram_setup_with_updates.body.contains("123:ABC"));
        assert_true(router.telegram.start_count == 1);

        var telegram_status_after_setup = request("GET", "/bot/telegram/status", null, raw_token);
        assert_true(telegram_status_after_setup.status_code == 200);
        assert_false(telegram_status_after_setup.body.contains("123:ABC"));

        var telegram_enable = request("POST", "/bot/telegram/enable",
            "{\"enabled\":true}", raw_token);
        assert_true(telegram_enable.status_code == 200);

        var invalid_ai_setup = request("POST", "/bot/ai/setup",
            "{\"provider\":\"ollama\",\"model\":\"\"}", raw_token);
        assert_true(invalid_ai_setup.status_code == 400);

        var unknown_ai_setup = request("POST", "/bot/ai/setup",
            "{\"provider\":\"unknown\",\"model\":\"llama3\"}", raw_token);
        assert_true(unknown_ai_setup.status_code == 400);

        var missing_key_ai_setup = request("POST", "/bot/ai/setup",
            "{\"provider\":\"openai\",\"api_key\":\"-\",\"model\":\"gpt-4o\"}", raw_token);
        assert_true(missing_key_ai_setup.status_code == 400);

        var ai_setup = request("POST", "/bot/ai/setup",
            "{\"provider\":\" OLLAMA \",\"model\":\"llama3\"}", raw_token);
        assert_true(ai_setup.status_code == 200);
        Json.Object ai_setup_result = parse_body(ai_setup).get_object_member("result");
        assert_true(ai_setup_result.get_string_member("provider") == "ollama");
        assert_true(ai_setup_result.get_string_member("model") == "llama3");

        var gemini_setup = request("POST", "/bot/ai/setup",
            "{\"provider\":\"gemini\",\"api_key\":\"AIza-secret-public-api-key\",\"model\":\"gemini-2.5-flash-lite\"}", raw_token);
        assert_true(gemini_setup.status_code == 200);
        assert_false(gemini_setup.body.contains("AIza-secret-public-api-key"));

        var ai_status_after_setup = request("GET", "/bot/ai/status", null, raw_token);
        assert_true(ai_status_after_setup.status_code == 200);
        assert_false(ai_status_after_setup.body.contains("AIza-secret-public-api-key"));

        var ai_enable = request("POST", "/bot/ai/enable",
            "{\"enabled\":true}", raw_token);
        assert_true(ai_enable.status_code == 200);

        registry.update_bot_permissions(bot_id, "send_message");
        var blank_telegram_send = request("POST", "/bot/telegram/send",
            "{\"text\":\"   \"}", raw_token);
        assert_true(blank_telegram_send.status_code == 400);

        var telegram_send = request("POST", "/bot/telegram/send",
            "{\"text\":\"  hello  \"}", raw_token);
        assert_true(telegram_send.status_code == 500);
        assert_true(router.telegram.forward_count == 1);
        assert_true(router.telegram.last_forward_bot_id == bot_id);
        assert_true(router.telegram.last_forward_sender == "API");
        assert_true(router.telegram.last_forward_text == "hello");

        router.telegram.send_success = true;
        var telegram_send_success = request("POST", "/bot/telegram/send",
            "{\"text\":\"bridge ok\"}", raw_token);
        assert_true(telegram_send_success.status_code == 200);
        assert_true(router.telegram.forward_count == 2);
        assert_true(router.telegram.last_forward_text == "bridge ok");

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled_telegram_send = request("POST", "/bot/telegram/send",
            "{\"text\":\"must not forward\"}", raw_token);
        assert_true(account_disabled_telegram_send.status_code == 403);
        assert_true(router.telegram.forward_count == 2);

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");

        var blank_ai_ask = request("POST", "/bot/ai/ask",
            "{\"message\":\"   \"}", raw_token);
        assert_true(blank_ai_ask.status_code == 400);

        var ai_ask = request("POST", "/bot/ai/ask",
            "{\"message\":\"  hello  \"}", raw_token);
        assert_true(ai_ask.status_code == 500);
        assert_true(router.ai.ask_count == 1);
        assert_true(router.ai.last_ask_bot_id == bot_id);
        assert_true(router.ai.last_ask_from == "api-client");
        assert_true(router.ai.last_ask_question == "hello");

        router.ai.answer = "api answer";
        var ai_answer = request("POST", "/bot/ai/ask",
            "{\"message\":\"hello from api\"}", raw_token);
        assert_true(ai_answer.status_code == 200);
        assert_true(router.ai.ask_count == 2);
        assert_true(router.ai.last_ask_question == "hello from api");
        Json.Object ai_answer_result = parse_body(ai_answer).get_object_member("result");
        assert_true(ai_answer_result.get_string_member("response") == "api answer");

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        var account_disabled_ai_ask = request("POST", "/bot/ai/ask",
            "{\"message\":\"must not ask\"}", raw_token);
        assert_true(account_disabled_ai_ask.status_code == 403);
        assert_true(router.ai.ask_count == 2);
    }

    void test_runtime_syncs_telegram_polling() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);
        router.telegram.enabled = true;

        var remove_updates = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":\"send_message\"}".printf(bot_id));
        assert_true(remove_updates.status_code == 200);
        assert_true(router.telegram.stop_count == 1);
        assert_true(router.telegram.start_count == 0);

        var restore_updates = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":\"receive_updates\"}".printf(bot_id));
        assert_true(restore_updates.status_code == 200);
        assert_true(router.telegram.start_count == 1);

        var deactivate = request("POST", "/bot/activate",
            "{\"id\":%d,\"active\":false}".printf(bot_id));
        assert_true(deactivate.status_code == 200);
        assert_true(router.telegram.stop_count == 2);

        var disabled_me = request("GET", "/bot/getMe", null, raw_token);
        assert_true(disabled_me.status_code == 403);
        Json.Object disabled_json = parse_body(disabled_me);
        assert_true(disabled_json.get_string_member("error") == "inactive");

        var reactivate = request("POST", "/bot/activate",
            "{\"id\":%d,\"active\":true}".printf(bot_id));
        assert_true(reactivate.status_code == 200);
        assert_true(router.telegram.start_count == 2);

        var enabled_me = request("GET", "/bot/getMe", null, raw_token);
        assert_true(enabled_me.status_code == 200);

        var disable_account = request("POST", "/bot/account/status",
            "{\"account\":\"owner@example.test\",\"enabled\":false}");
        assert_true(disable_account.status_code == 200);
        assert_true(router.telegram.stop_count == 3);
        registry.bot.update().with(registry.bot.id, "=", bot_id)
            .set(registry.bot.last_active, 1)
            .perform();

        var disabled_account_me = request("GET", "/bot/getMe", null, raw_token);
        assert_true(disabled_account_me.status_code == 403);
        assert_true(parse_body(disabled_account_me).get_string_member("error") == "inactive");
        BotInfo? bot_after_disabled_auth = registry.get_bot_by_id(bot_id);
        assert_true(bot_after_disabled_auth != null);
        assert_true(bot_after_disabled_auth.last_active == 1);

        var permissions_while_account_disabled = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":\"receive_updates\"}".printf(bot_id));
        assert_true(permissions_while_account_disabled.status_code == 200);
        assert_true(router.telegram.start_count == 2);

        var enable_account = request("POST", "/bot/account/status",
            "{\"account\":\"owner@example.test\",\"enabled\":true}");
        assert_true(enable_account.status_code == 200);
        assert_true(router.telegram.start_count == 3);

        var enabled_account_me = request("GET", "/bot/getMe", null, raw_token);
        assert_true(enabled_account_me.status_code == 200);
        BotInfo? bot_after_enabled_auth = registry.get_bot_by_id(bot_id);
        assert_true(bot_after_enabled_auth != null);
        assert_true(bot_after_enabled_auth.last_active > 1);
    }

    void test_updates_offset_semantics() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);

        int first_id = registry.enqueue_update(bot_id, "message", "{\"body\":\"first\"}");
        int second_id = registry.enqueue_update(bot_id, "message", "{\"body\":\"second\"}");

        var response = request("GET", "/bot/getUpdates?offset=%d".printf(second_id), null, raw_token);
        assert_true(response.status_code == 200);
        Json.Object json = parse_body(response);
        assert_true(json.get_boolean_member("ok"));
        Json.Array result = json.get_array_member("result");
        assert_true(result.get_length() == 1);
        assert_true(result.get_object_element(0).get_int_member("update_id") == second_id);

        var remaining = registry.get_updates(bot_id, 0, 10);
        assert_true(remaining.size == 1);
        assert_true(remaining[0].id == second_id);
        assert_true(remaining[0].id != first_id);
    }

    void test_updates_long_poll_waits_for_new_update() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);

        Timeout.add(100, () => {
            registry.enqueue_update(bot_id, "message",
                "{\"body\":\"delayed\",\"from\":\"friend@example.test\"}");
            return Source.REMOVE;
        });

        var response = request("GET", "/bot/getUpdates?timeout=2", null, raw_token);
        assert_true(response.status_code == 200);
        Json.Object json = parse_body(response);
        assert_true(json.get_boolean_member("ok"));
        Json.Array result = json.get_array_member("result");
        assert_true(result.get_length() == 1);
        Json.Object update = result.get_object_element(0);
        assert_true(update.get_string_member("type") == "message");
        assert_true(update.get_object_member("data").get_string_member("body") == "delayed");
    }

    void test_invalid_ids_and_paging_return_bad_request() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates", out raw_token);

        var list_wrong_method = request("POST", "/bot/list", "{}");
        assert_true(list_wrong_method.status_code == 405);

        var delete_bad_id = request("DELETE", "/bot/delete?id=abc");
        assert_true(delete_bad_id.status_code == 400);

        var delete_negative_id = request("POST", "/bot/delete", "{\"id\":-1}");
        assert_true(delete_negative_id.status_code == 400);

        var delete_huge_id = request("DELETE", "/bot/delete?id=999999999999999999999999999999999999");
        assert_true(delete_huge_id.status_code == 400);

        var permissions_bad_id = request("GET", "/bot/permissions?id=abc");
        assert_true(permissions_bad_id.status_code == 400);

        var targets_bad_id = request("GET", "/bot/targets?id=abc");
        assert_true(targets_bad_id.status_code == 400);

        var bad_target_mode = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":\"sometimes\",\"target_list\":\"friend@example.test\"}".printf(bot_id));
        assert_true(bad_target_mode.status_code == 400);

        var bad_offset = request("GET", "/bot/getUpdates?offset=abc", null, raw_token);
        assert_true(bad_offset.status_code == 400);

        var huge_offset = request("GET", "/bot/getUpdates?offset=999999999999999999999999999999999999", null, raw_token);
        assert_true(huge_offset.status_code == 400);

        var bad_limit = request("GET", "/bot/getUpdates?limit=0", null, raw_token);
        assert_true(bad_limit.status_code == 400);

        var bad_timeout = request("GET", "/bot/getUpdates?timeout=abc", null, raw_token);
        assert_true(bad_timeout.status_code == 400);
    }

    void test_paused_status_runtime() {
        string raw_token;
        int bot_id = create_bot_with_permissions("receive_updates,send_message", out raw_token);
        router.telegram.enabled = true;
        int paused_signal_count = 0;
        int active_signal_count = 0;
        registry.bot_status_changed.connect((changed_bot_id, new_status) => {
            if (changed_bot_id == bot_id && new_status == "paused") {
                paused_signal_count++;
            } else if (changed_bot_id == bot_id && new_status == "active") {
                active_signal_count++;
            }
        });

        var pause = request("POST", "/bot/activate",
            "{\"id\":%d,\"status\":\"paused\"}".printf(bot_id));
        assert_true(pause.status_code == 200);
        assert_true(router.telegram.stop_count == 1);
        assert_true(paused_signal_count == 1);
        assert_true(active_signal_count == 0);
        assert_true(raw_setting("bot_ignore_delayed_before:%d".printf(bot_id)) == null);
        Json.Object pause_json = parse_body(pause).get_object_member("result");
        assert_true(pause_json.get_string_member("status") == "paused");

        var paused_me = request("GET", "/bot/getMe", null, raw_token);
        assert_true(paused_me.status_code == 403);
        Json.Object paused_json = parse_body(paused_me);
        assert_true(paused_json.get_string_member("error") == "inactive");

        var paused_telegram = request("POST", "/bot/telegram/send",
            "{\"text\":\"must not forward\"}", raw_token);
        assert_true(paused_telegram.status_code == 403);
        assert_true(router.telegram.forward_count == 0);

        var paused_ai = request("POST", "/bot/ai/ask",
            "{\"message\":\"must not ask\"}", raw_token);
        assert_true(paused_ai.status_code == 403);
        assert_true(router.ai.ask_count == 0);

        var resume = request("POST", "/bot/activate",
            "{\"id\":%d,\"status\":\"active\"}".printf(bot_id));
        assert_true(resume.status_code == 200);
        assert_true(router.telegram.start_count == 1);
        assert_true(paused_signal_count == 1);
        assert_true(active_signal_count == 1);
        assert_true(raw_setting("bot_ignore_delayed_before:%d".printf(bot_id)) != null);

        var active_me = request("GET", "/bot/getMe", null, raw_token);
        assert_true(active_me.status_code == 200);

        var invalid = request("POST", "/bot/activate",
            "{\"id\":%d,\"status\":\"sleeping\"}".printf(bot_id));
        assert_true(invalid.status_code == 400);
    }

    void test_invalid_boolean_fields_return_bad_request() {
        string raw_token;
        int bot_id = create_bot_with_permissions("admin", out raw_token);

        var bad_activate = request("POST", "/bot/activate",
            "{\"id\":%d,\"active\":\"true\"}".printf(bot_id));
        assert_true(bad_activate.status_code == 400);

        var bad_account_toggle = request("POST", "/bot/account/status",
            "{\"account\":\"owner@example.test\",\"enabled\":\"false\"}");
        assert_true(bad_account_toggle.status_code == 400);

        var bad_telegram_toggle = request("POST", "/bot/telegram/enable",
            "{\"enabled\":\"true\"}", raw_token);
        assert_true(bad_telegram_toggle.status_code == 400);

        var bad_ai_toggle = request("POST", "/bot/ai/enable",
            "{\"enabled\":\"true\"}", raw_token);
        assert_true(bad_ai_toggle.status_code == 400);
    }

    void test_invalid_string_fields_return_bad_request() {
        string raw_token;
        int bot_id = create_bot_with_permissions("all", out raw_token);

        var bad_create_name = request("POST", "/bot/create",
            "{\"name\":123,\"account\":\"owner@example.test\",\"mode\":\"personal\"}");
        assert_true(bad_create_name.status_code == 400);

        var bad_create_mode = request("POST", "/bot/create",
            "{\"name\":\"Mode Bot\",\"account\":\"owner@example.test\",\"mode\":123}");
        assert_true(bad_create_mode.status_code == 400);

        var bad_create_account = request("POST", "/bot/create",
            "{\"name\":\"Bad Account Bot\",\"account\":\"owner\",\"mode\":\"personal\"}");
        assert_true(bad_create_account.status_code == 400);
        assert_true(registry.get_all_bots().size == 1);

        var bad_permissions = request("POST", "/bot/permissions",
            "{\"id\":%d,\"permissions\":123}".printf(bot_id));
        assert_true(bad_permissions.status_code == 400);

        var bad_target_mode = request("POST", "/bot/targets",
            "{\"id\":%d,\"target_mode\":123,\"target_list\":\"friend@example.test\"}".printf(bot_id));
        assert_true(bad_target_mode.status_code == 400);

        var bad_send_to = request("POST", "/bot/sendMessage",
            "{\"to\":123,\"text\":\"hello\"}", raw_token);
        assert_true(bad_send_to.status_code == 400);

        var bad_send_type = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\",\"type\":123}", raw_token);
        assert_true(bad_send_type.status_code == 400);

        var bad_webhook_url = request("POST", "/bot/setWebhook",
            "{\"url\":123}", raw_token);
        assert_true(bad_webhook_url.status_code == 400);

        var bad_file_caption = request("POST", "/bot/sendFile",
            "{\"to\":\"friend@example.test\",\"url\":\"https://files.example.test/a.png\",\"caption\":123}", raw_token);
        assert_true(bad_file_caption.status_code == 400);

        var bad_join_nick = request("POST", "/bot/joinRoom",
            "{\"room\":\"room@conference.example.test\",\"nick\":123}", raw_token);
        assert_true(bad_join_nick.status_code == 400);

        var bad_telegram_token = request("POST", "/bot/telegram/setup",
            "{\"token\":123,\"chat_id\":\"42\",\"mode\":\"bridge\"}", raw_token);
        assert_true(bad_telegram_token.status_code == 400);

        var bad_telegram_mode = request("POST", "/bot/telegram/setup",
            "{\"token\":\"123:ABC\",\"chat_id\":\"42\",\"mode\":123}", raw_token);
        assert_true(bad_telegram_mode.status_code == 400);

        var bad_ai_provider = request("POST", "/bot/ai/setup",
            "{\"provider\":123,\"model\":\"llama3\"}", raw_token);
        assert_true(bad_ai_provider.status_code == 400);

        var bad_ai_key = request("POST", "/bot/ai/setup",
            "{\"provider\":\"ollama\",\"api_key\":123,\"model\":\"llama3\"}", raw_token);
        assert_true(bad_ai_key.status_code == 400);

        var bad_ejabberd_api_url = request("POST", "/bot/ejabberd/settings",
            "{\"api_url\":123,\"admin_jid\":\"admin@example.test\",\"admin_password\":\"secret\",\"host\":\"example.test\"}");
        assert_true(bad_ejabberd_api_url.status_code == 400);

        var bad_ejabberd_test_host = request("POST", "/bot/ejabberd/test",
            "{\"api_url\":\"https://xmpp.example.test/api\",\"admin_jid\":\"admin@example.test\",\"admin_password\":\"secret\",\"host\":123}");
        assert_true(bad_ejabberd_test_host.status_code == 400);

        var invalid_ejabberd_url = request("POST", "/bot/ejabberd/settings",
            "{\"api_url\":\"ftp://xmpp.example.test/api\",\"admin_jid\":\"admin@example.test\",\"admin_password\":\"secret\",\"host\":\"example.test\"}");
        assert_true(invalid_ejabberd_url.status_code == 400);

        var invalid_ejabberd_admin = request("POST", "/bot/ejabberd/settings",
            "{\"api_url\":\"https://xmpp.example.test/api\",\"admin_jid\":\"admin\",\"admin_password\":\"secret\",\"host\":\"example.test\"}");
        assert_true(invalid_ejabberd_admin.status_code == 400);

        var invalid_ejabberd_host = request("POST", "/bot/ejabberd/settings",
            "{\"api_url\":\"https://xmpp.example.test/api\",\"admin_jid\":\"admin@example.test\",\"admin_password\":\"secret\",\"host\":\"bad/host\"}");
        assert_true(invalid_ejabberd_host.status_code == 400);

        var invalid_ejabberd_test_admin = request("POST", "/bot/ejabberd/test",
            "{\"api_url\":\"https://xmpp.example.test/api\",\"admin_jid\":\"admin\",\"admin_password\":\"secret\",\"host\":\"example.test\"}");
        assert_true(invalid_ejabberd_test_admin.status_code == 400);

        var invalid_ejabberd_test_host = request("POST", "/bot/ejabberd/test",
            "{\"api_url\":\"https://xmpp.example.test/api\",\"admin_jid\":\"admin@example.test\",\"admin_password\":\"secret\",\"host\":\"bad/host\"}");
        assert_true(invalid_ejabberd_test_host.status_code == 400);
    }

    void test_invalid_message_fields_return_bad_request() {
        string raw_token;
        int bot_id = create_bot_with_permissions("send_message,file_send,muc_join", out raw_token);

        var blank_text = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"   \"}", raw_token);
        assert_true(blank_text.status_code == 400);

        var invalid_type = request("POST", "/bot/sendMessage",
            "{\"to\":\"friend@example.test\",\"text\":\"hello\",\"type\":\"headline\"}", raw_token);
        assert_true(invalid_type.status_code == 400);

        var invalid_message_jid = request("POST", "/bot/sendMessage",
            "{\"to\":\"not a jid\",\"text\":\"hello\"}", raw_token);
        assert_true(invalid_message_jid.status_code == 400);

        var invalid_console_type = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello\",\"type\":\"headline\"}".printf(bot_id));
        assert_true(invalid_console_type.status_code == 400);

        var invalid_console_jid = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"not a jid\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(invalid_console_jid.status_code == 400);

        var blank_file_target = request("POST", "/bot/sendFile",
            "{\"to\":\"   \",\"url\":\"https://files.example.test/a.png\"}", raw_token);
        assert_true(blank_file_target.status_code == 400);

        var invalid_file_target = request("POST", "/bot/sendFile",
            "{\"to\":\"not a jid\",\"url\":\"https://files.example.test/a.png\"}", raw_token);
        assert_true(invalid_file_target.status_code == 400);

        var invalid_file_url = request("POST", "/bot/sendFile",
            "{\"to\":\"friend@example.test\",\"url\":\"ftp://files.example.test/a.png\"}", raw_token);
        assert_true(invalid_file_url.status_code == 400);

        var blank_join_room = request("POST", "/bot/joinRoom",
            "{\"room\":\"   \",\"nick\":\"Bot\"}", raw_token);
        assert_true(blank_join_room.status_code == 400);

        var invalid_join_room = request("POST", "/bot/joinRoom",
            "{\"room\":\"not a jid\",\"nick\":\"Bot\"}", raw_token);
        assert_true(invalid_join_room.status_code == 400);

        var blank_leave_room = request("POST", "/bot/leaveRoom",
            "{\"room\":\"   \"}", raw_token);
        assert_true(blank_leave_room.status_code == 400);

        var invalid_leave_room = request("POST", "/bot/leaveRoom",
            "{\"room\":\"not a jid\"}", raw_token);
        assert_true(invalid_leave_room.status_code == 400);

        var blank_reaction = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"m1\",\"reaction\":\"   \"}", raw_token);
        assert_true(blank_reaction.status_code == 400);

        var blank_reaction_message_id = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"   \",\"reaction\":\"+1\"}", raw_token);
        assert_true(blank_reaction_message_id.status_code == 400);

        var invalid_reaction_message_id_type = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":123,\"reaction\":\"+1\"}", raw_token);
        assert_true(invalid_reaction_message_id_type.status_code == 400);

        var invalid_reaction_type = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"m1\",\"reaction\":123}", raw_token);
        assert_true(invalid_reaction_type.status_code == 400);

        var invalid_reaction_jid = request("POST", "/bot/sendReaction",
            "{\"to\":\"not a jid\",\"message_id\":\"m1\",\"reaction\":\"+1\"}", raw_token);
        assert_true(invalid_reaction_jid.status_code == 400);
    }

    void test_get_endpoints_reject_wrong_methods() {
        string raw_token;
        create_bot_with_permissions("all", out raw_token);

        var get_me = request("POST", "/bot/getMe", "{}", raw_token);
        assert_true(get_me.status_code == 405);

        var updates = request("POST", "/bot/getUpdates", "{}", raw_token);
        assert_true(updates.status_code == 405);

        var commands = request("POST", "/bot/getCommands", "{}", raw_token);
        assert_true(commands.status_code == 405);

        var info = request("POST", "/bot/getInfo", "{}", raw_token);
        assert_true(info.status_code == 405);

        var telegram_status = request("POST", "/bot/telegram/status", "{}", raw_token);
        assert_true(telegram_status.status_code == 405);

        var ai_status = request("POST", "/bot/ai/status", "{}", raw_token);
        assert_true(ai_status.status_code == 405);

        var health = request("POST", "/health", "{}");
        assert_true(health.status_code == 405);
    }

    void test_post_endpoints_reject_wrong_methods_before_scope() {
        string raw_token;
        create_bot_with_permissions("receive_updates", out raw_token);

        var webhook = request("GET", "/bot/setWebhook", null, raw_token);
        assert_true(webhook.status_code == 405);

        var file = request("GET", "/bot/sendFile", null, raw_token);
        assert_true(file.status_code == 405);

        var telegram_test = request("GET", "/bot/telegram/test", null, raw_token);
        assert_true(telegram_test.status_code == 405);

        var ai_setup = request("GET", "/bot/ai/setup", null, raw_token);
        assert_true(ai_setup.status_code == 405);
    }

    void test_dedicated_muc_actions_use_stream_path() {
        string raw_token;
        int bot_id = create_dedicated_bot_with_permissions("muc_send,muc_join", out raw_token);

        var api_send = request("POST", "/bot/sendMessage",
            "{\"to\":\"room@conference.example.test\",\"text\":\"hello\",\"type\":\"groupchat\"}", raw_token);
        assert_true(api_send.status_code == 200);

        var console_send = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"room@conference.example.test\",\"text\":\"hello\",\"type\":\"groupchat\"}".printf(bot_id));
        assert_true(console_send.status_code == 200);

        var join = request("POST", "/bot/joinRoom",
            "{\"room\":\"room@conference.example.test\",\"nick\":\"Bot\"}", raw_token);
        assert_true(join.status_code == 200);
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == "room@conference.example.test\tBot");

        var listed_after_join = request("GET", "/bot/list");
        assert_true(listed_after_join.status_code == 200);
        Json.Object listed_bot = parse_body(listed_after_join).get_array_member("bots").get_object_element(0);
        assert_true(listed_bot.get_string_member("muc_rooms") == "room@conference.example.test (Bot)");
        Json.Array listed_rooms = listed_bot.get_array_member("muc_rooms_list");
        assert_true(listed_rooms.get_length() == 1);
        assert_true(listed_rooms.get_object_element(0).get_string_member("room") == "room@conference.example.test");
        assert_true(listed_rooms.get_object_element(0).get_string_member("nick") == "Bot");

        var leave = request("POST", "/bot/leaveRoom",
            "{\"room\":\"room@conference.example.test\"}", raw_token);
        assert_true(leave.status_code == 200);
        assert_true(raw_setting("bot_%d_muc_rooms".printf(bot_id)) == null);

        var listed_after_leave = request("GET", "/bot/list");
        assert_true(listed_after_leave.status_code == 200);
        Json.Object listed_empty_bot = parse_body(listed_after_leave).get_array_member("bots").get_object_element(0);
        assert_true(listed_empty_bot.get_string_member("muc_rooms") == "");
        assert_true(listed_empty_bot.get_array_member("muc_rooms_list").get_length() == 0);
    }

    void test_dedicated_console_requires_stream() {
        string raw_token;
        int bot_id = create_dedicated_bot_with_permissions("send_message,file_send", out raw_token);

        router.dedicated_available = false;
        var failed = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(failed.status_code == 500);

        var failed_file = request("POST", "/bot/sendFile",
            "{\"to\":\"friend@example.test\",\"url\":\"https://files.example.test/a.png\"}", raw_token);
        assert_true(failed_file.status_code == 500);
        assert_true(router.file_count == 0);

        var failed_reaction = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"m1\",\"reaction\":\"+1\"}", raw_token);
        assert_true(failed_reaction.status_code == 500);
        assert_true(router.reaction_count == 0);

        router.dedicated_available = true;
        var sent = request("POST", "/bot/testSend",
            "{\"id\":%d,\"to\":\"friend@example.test\",\"text\":\"hello\"}".printf(bot_id));
        assert_true(sent.status_code == 200);

        var sent_file = request("POST", "/bot/sendFile",
            "{\"to\":\"friend@example.test\",\"url\":\"https://files.example.test/a.png\"}", raw_token);
        assert_true(sent_file.status_code == 200);

        var sent_reaction = request("POST", "/bot/sendReaction",
            "{\"to\":\"friend@example.test\",\"message_id\":\"m1\",\"reaction\":\"+1\"}", raw_token);
        assert_true(sent_reaction.status_code == 200);
    }
}

class ApiResponse {
    public uint status_code = 0;
    public string body = "";
    public string? error = null;
}

}
