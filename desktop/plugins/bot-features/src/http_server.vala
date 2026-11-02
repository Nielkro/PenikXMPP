using Gee;

namespace Dino.Plugins.BotFeatures {

public class HttpServer : Object {

    private Soup.Server? server;
    private BotRegistry registry;
    private TokenManager token_manager;
    private MessageRouter message_router;
    private SessionPool session_pool;
    private AuthMiddleware auth;
    private RateLimiter rate_limiter;
    private EjabberdApi ejabberd_api;
    private bool running = false;
    private string current_mode = "local";
    private uint16 current_port = 7842;

    public HttpServer(BotRegistry registry, TokenManager token_manager,
                      MessageRouter message_router, SessionPool session_pool,
                      EjabberdApi? ejabberd_api = null) {
        this.registry = registry;
        this.token_manager = token_manager;
        this.message_router = message_router;
        this.session_pool = session_pool;
        this.rate_limiter = new RateLimiter(30, 1);
        this.auth = new AuthMiddleware(token_manager, rate_limiter);
        this.ejabberd_api = ejabberd_api ?? new EjabberdApi(registry);
    }

    public void start(uint16 port, string mode = "local", string tls_cert_path = "", string tls_key_path = "") throws Error {
        // Release routes owned by an earlier successful or failed bind.
        stop();
        server = new Soup.Server("server-header", "DinoX-BotAPI/1.0", null);
        current_mode = mode;
        current_port = port;

        // Register all API routes
        server.add_handler("/bot/getMe", handle_get_me);
        server.add_handler("/bot/sendMessage", handle_send_message);
        server.add_handler("/bot/getUpdates", handle_get_updates);
        server.add_handler("/bot/setWebhook", handle_set_webhook);
        server.add_handler("/bot/deleteWebhook", handle_delete_webhook);
        server.add_handler("/bot/sendFile", handle_send_file);
        server.add_handler("/bot/setCommands", handle_set_commands);
        server.add_handler("/bot/getCommands", handle_get_commands);
        server.add_handler("/bot/joinRoom", handle_join_room);
        server.add_handler("/bot/leaveRoom", handle_leave_room);
        server.add_handler("/bot/sendReaction", handle_send_reaction);
        server.add_handler("/bot/getInfo", handle_get_info);
        server.add_handler("/bot/create", handle_create_bot);
        server.add_handler("/bot/list", handle_list_bots);
        server.add_handler("/bot/delete", handle_delete_bot);
        server.add_handler("/bot/activate", handle_activate_bot);
        server.add_handler("/bot/token", handle_regenerate_token);
        server.add_handler("/bot/revoke", handle_revoke_token);
        server.add_handler("/bot/permissions", handle_permissions);
        server.add_handler("/bot/targets", handle_targets);
        server.add_handler("/bot/webhook", handle_webhook_management);
        server.add_handler("/bot/avatar", handle_avatar_management);
        server.add_handler("/bot/cloud/tokens", handle_cloudbot_tokens);
        server.add_handler("/bot/testSend", handle_test_send);
        server.add_handler("/bot/testJoinRoom", handle_test_join_room);
        server.add_handler("/bot/testLeaveRoom", handle_test_leave_room);
        server.add_handler("/bot/account/status", handle_account_status);
        server.add_handler("/bot/ejabberd/settings", handle_ejabberd_settings);
        server.add_handler("/bot/ejabberd/test", handle_ejabberd_test);
        server.add_handler("/bot/telegram/manage", handle_telegram_management);
        server.add_handler("/bot/telegram/setup", handle_telegram_setup);
        server.add_handler("/bot/telegram/status", handle_telegram_status);
        server.add_handler("/bot/telegram/enable", handle_telegram_enable);
        server.add_handler("/bot/telegram/send", handle_telegram_send);
        server.add_handler("/bot/telegram/test", handle_telegram_test);
        server.add_handler("/bot/ai/testAsk", handle_ai_test_ask);
        server.add_handler("/bot/ai/manage", handle_ai_management);
        server.add_handler("/bot/ai/setup", handle_ai_setup);
        server.add_handler("/bot/ai/status", handle_ai_status);
        server.add_handler("/bot/ai/enable", handle_ai_enable);
        server.add_handler("/bot/ai/ask", handle_ai_ask);
        server.add_handler("/health", handle_health);

        if (mode == "network") {
            // Network mode: TLS required, listen on all interfaces
            string cert_path = tls_cert_path;
            string key_path = tls_key_path;

            // Auto-generate self-signed certificate if no paths provided
            if (cert_path == "" || key_path == "") {
                string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
                cert_path = Path.build_filename(cert_dir, "server.crt");
                key_path = Path.build_filename(cert_dir, "server.key");

                // Generate if missing or expired
                if (CertGen.check_cert_valid(cert_path) == 0) {
                    message("Botmother: Generating self-signed TLS certificate...");
                    int ret = CertGen.generate_self_signed_cert(cert_path, key_path, "DinoX API Server");
                    if (ret < 0) {
                        throw new IOError.FAILED("Failed to generate TLS certificate (error %d). Falling back to localhost.", ret);
                    }
                    message("Botmother: Self-signed certificate created at %s", cert_path);
                }
            }

            // Load TLS certificate
            var tls_cert = new TlsCertificate.from_files(cert_path, key_path);
            server.set_tls_certificate(tls_cert);

            // Listen on all interfaces with HTTPS
            server.listen(new InetSocketAddress(new InetAddress.any(SocketFamily.IPV4), port), Soup.ServerListenOptions.HTTPS);
            running = true;
            message("Botmother: HTTPS API running on 0.0.0.0:%u (TLS)", port);
        } else {
            // Local mode (default): HTTP on localhost only
            server.listen_local(port, Soup.ServerListenOptions.IPV4_ONLY);
            running = true;
        }
    }

    public uint16 get_port() {
        return current_port;
    }

    public bool is_running() {
        return running;
    }

    public void stop() {
        if (server != null) {
            server.disconnect();
            server = null;
        }
        running = false;
    }

    // Check whether a request comes from localhost (127.0.0.1 or ::1)
    private bool is_localhost(Soup.ServerMessage msg) {
        return is_loopback_host(msg.get_remote_host());
    }

    internal static bool is_loopback_host(string? remote) {
        if (remote == null) return false;

        string host = remote.strip().ascii_down();
        if (host == "localhost") return true;
        if (host.has_prefix("[") && host.has_suffix("]") && host.length > 2) {
            host = host.substring(1, host.length - 2);
        }

        InetAddress? address = new InetAddress.from_string(host);
        return address != null && address.is_loopback;
    }

    // Enforce localhost-only access for admin endpoints in network mode
    private bool require_localhost(Soup.ServerMessage msg) {
        if (current_mode == "network" && !is_localhost(msg)) {
            AuthMiddleware.send_error(msg, 403, "forbidden",
                "Admin endpoints are only accessible from localhost");
            return false;
        }
        return true;
    }

    private bool require_permission(Soup.ServerMessage msg, BotInfo bot, string scope) {
        if (bot_has_permission(bot, scope)) return true;

        AuthMiddleware.send_error(msg, 403, "forbidden",
            "Bot token is missing required permission: %s".printf(scope));
        return false;
    }

    private bool require_target(Soup.ServerMessage msg, BotInfo bot, string to_jid) {
        if (bot_target_allowed(bot, to_jid)) return true;

        AuthMiddleware.send_error(msg, 403, "forbidden",
            "Bot target is not allowed: %s".printf(to_jid));
        return false;
    }

    private bool require_local_bot_runtime_allowed(Soup.ServerMessage msg, BotInfo bot) {
        if (bot.status != "active") {
            AuthMiddleware.send_error(msg, 409, "inactive", "Bot is not active");
            return false;
        }
        if (!BotUtils.is_owner_account_enabled(bot, registry)) {
            AuthMiddleware.send_error(msg, 403, "inactive", "Botmother is disabled for this account");
            return false;
        }
        return true;
    }

    private bool can_refresh_dedicated_bot_metadata(BotInfo bot) {
        return bot.mode == "dedicated" &&
            bot.status == "active" &&
            BotUtils.is_owner_account_enabled(bot, registry);
    }

    private bool reject_invalid_jid(Soup.ServerMessage msg, string jid_str, string field_name) {
        if (!is_valid_jid_string(jid_str)) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid JID in field: %s".printf(field_name));
            return true;
        }
        return false;
    }

    private bool reject_invalid_account_jid(Soup.ServerMessage msg, string jid_str, string field_name) {
        if (!is_valid_bare_account_jid(jid_str)) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid account JID in field: %s".printf(field_name));
            return true;
        }
        return false;
    }

    private bool reject_invalid_domain_target(Soup.ServerMessage msg, string domain, string field_name) {
        if (!is_valid_domain_target(domain)) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid domain in field: %s".printf(field_name));
            return true;
        }
        return false;
    }

    private bool is_valid_jid_string(string jid_str) {
        string jid = jid_str.strip();
        if (jid == "") return false;

        for (int i = 0; i < jid.length; i++) {
            char c = jid[i];
            if (c <= 0x20 || c == 0x7f) return false;
        }

        string bare = jid;
        int slash = jid.index_of("/");
        if (slash >= 0) {
            if (slash == jid.length - 1) return false;
            bare = jid.substring(0, slash);
        }
        if (bare == "") return false;

        int at = bare.index_of("@");
        if (at >= 0) {
            if (at == 0 || at == bare.length - 1) return false;
            if (bare.index_of("@", at + 1) >= 0) return false;
        }
        return true;
    }

    private bool is_valid_bare_account_jid(string jid_str) {
        string jid = jid_str.strip();
        if (!is_valid_jid_string(jid)) return false;
        if (jid.index_of("/") >= 0) return false;

        int at = jid.index_of("@");
        return at > 0 && at < jid.length - 1;
    }

    private bool is_valid_cloudbot_management_token(string token) {
        string trimmed = token.strip();
        if (trimmed == "" || trimmed.length > 512) return false;
        for (int i = 0; i < trimmed.length; i++) {
            char c = trimmed[i];
            if (c <= 0x20 || c == 0x7f) return false;
        }
        return true;
    }

    private bool is_valid_target_entry(string target) {
        string part = target.strip();
        if (part == "" || part == "*") return part == "*";

        if (part.has_prefix("@")) {
            string domain = part.substring(1);
            return is_valid_domain_target(domain);
        }
        if (part.has_prefix("domain:")) {
            string domain = part.substring(7);
            return is_valid_domain_target(domain);
        }

        int at = part.index_of("@");
        return at > 0 && at < part.length - 1 && is_valid_jid_string(part);
    }

    private bool is_valid_domain_target(string domain) {
        string value = domain.strip();
        return value != "" &&
            value.index_of("@") < 0 &&
            value.index_of("/") < 0 &&
            is_valid_jid_string(value);
    }

    private bool validate_targets(string targets, out string invalid_target) {
        invalid_target = "";
        string[] parts = targets.replace("\n", ",").replace(";", ",").replace(" ", ",").split(",");
        foreach (string raw_part in parts) {
            string part = raw_part.strip();
            if (part == "") continue;
            if (!is_valid_target_entry(part)) {
                invalid_target = part;
                return false;
            }
        }
        return true;
    }

    private void sync_receive_update_runtime(BotInfo? bot) {
        if (bot == null) return;
        if (!message_router.telegram.is_enabled(bot.id)) return;

        if (BotUtils.can_receive_updates_for_enabled_account(bot, registry)) {
            message_router.telegram.start_polling(bot.id, bot.owner_jid ?? "");
        } else {
            message_router.telegram.stop_polling(bot.id);
        }
    }

    private void start_telegram_polling_if_updates_allowed(BotInfo bot) {
        if (BotUtils.can_receive_updates_for_enabled_account(bot, registry)) {
            message_router.telegram.start_polling(bot.id, bot.owner_jid ?? "");
        } else {
            message_router.telegram.stop_polling(bot.id);
        }
    }

    private void sync_account_receive_update_runtime(string account_jid) {
        foreach (BotInfo bot in registry.get_bots_by_owner(account_jid.strip())) {
            sync_receive_update_runtime(bot);
        }
    }

    private void stop_deleted_bot_runtime(BotInfo bot) {
        message_router.telegram.stop_polling(bot.id);
    }

    private async void wait_ms(uint interval) {
        SourceFunc callback = wait_ms.callback;
        Timeout.add(interval, () => {
            callback();
            return false;
        });
        yield;
    }

    private string target_setting_key(int bot_id) {
        return "bot_allowed_targets:%d".printf(bot_id);
    }

    private string target_mode_setting_key(int bot_id) {
        return "bot_target_mode:%d".printf(bot_id);
    }

    private string normalize_target_mode(string? mode, string targets = "") {
        string normalized = mode != null ? mode.strip().ascii_down() : "";
        switch (normalized) {
            case "all":
            case "allow":
            case "block":
                return normalized;
            default:
                return targets == "" ? "all" : "allow";
        }
    }

    private bool is_valid_target_mode(string mode) {
        switch (mode.strip().ascii_down()) {
            case "all":
            case "allow":
            case "block":
                return true;
            default:
                return false;
        }
    }

    private string normalize_targets(string? targets) {
        if (targets == null) return "";

        var seen = new HashSet<string>();
        var normalized = new ArrayList<string>();
        string[] parts = targets.replace("\n", ",").replace(";", ",").replace(" ", ",").split(",");
        foreach (string raw_part in parts) {
            string part = raw_part.strip();
            if (part == "") continue;
            if (!seen.contains(part)) {
                seen.add(part);
                normalized.add(part);
            }
        }
        return BotUtils.join_strings(",", normalized);
    }

    private bool bot_target_allowed(BotInfo bot, string to_jid_str) {
        string targets = normalize_targets(registry.get_setting(target_setting_key(bot.id)));
        string mode = normalize_target_mode(registry.get_setting(target_mode_setting_key(bot.id)), targets);
        if (mode == "all") return true;

        string full = to_jid_str.strip();
        string bare = full.split("/", 2)[0];
        string domain = "";
        int at_pos = bare.index_of("@");
        if (at_pos >= 0 && at_pos + 1 < bare.length) {
            domain = bare.substring(at_pos + 1);
        }

        bool listed = false;
        foreach (string raw_part in targets.split(",")) {
            string part = raw_part.strip();
            if (part == "" || part == "*") {
                listed = true;
                break;
            }
            if (part == bare || part == full) {
                listed = true;
                break;
            }
            if (domain != "" && part.has_prefix("domain:") && part.substring(7) == domain) {
                listed = true;
                break;
            }
            if (domain != "" && part.has_prefix("@") && part.substring(1) == domain) {
                listed = true;
                break;
            }
        }
        return mode == "allow" ? listed : !listed;
    }

    private bool bot_has_permission(BotInfo bot, string scope) {
        return BotUtils.has_permission(bot, scope);
    }

    private string dedicated_provisioning_for_bot(BotInfo bot) {
        if (bot.mode != "dedicated") return "";
        return registry.get_setting("bot_dedicated_provisioning:%d".printf(bot.id)) ?? "ejabberd";
    }

    private string normalize_bot_purpose(string? purpose) {
        string normalized = purpose != null ? purpose.strip().ascii_down() : "";
        switch (normalized) {
            case "ai":
            case "telegram":
            case "webhook":
            case "advanced":
                return normalized;
            default:
                return "advanced";
        }
    }

    private bool is_valid_bot_purpose(string purpose) {
        switch (purpose.strip().ascii_down()) {
            case "ai":
            case "telegram":
            case "webhook":
            case "advanced":
                return true;
            default:
                return false;
        }
    }

    private string bot_purpose_for_bot(BotInfo bot) {
        string? stored = registry.get_setting("bot_%d_purpose".printf(bot.id));
        if (stored != null && stored.strip() != "") return normalize_bot_purpose(stored);

        bool ai_configured = registry.get_setting("bot_%d_ai_endpoint".printf(bot.id)) != null;
        bool telegram_configured = registry.get_secret_setting("bot_%d_tg_token".printf(bot.id)) != null;
        bool webhook_configured = bot.webhook_enabled || (bot.webhook_url != null && bot.webhook_url.strip() != "");

        int configured_count = 0;
        if (ai_configured) configured_count++;
        if (telegram_configured) configured_count++;
        if (webhook_configured) configured_count++;

        if (configured_count > 1) return "advanced";
        if (ai_configured) return "ai";
        if (telegram_configured) return "telegram";
        if (webhook_configured) return "webhook";
        return "advanced";
    }

    private bool parse_permissions(string? permissions, out string normalized, out string invalid_permission) {
        invalid_permission = "";
        if (permissions == null || permissions.strip() == "") {
            normalized = "all";
            return true;
        }

        var seen = new HashSet<string>();
        var normalized_list = new ArrayList<string>();
        foreach (string raw_part in permissions.split(",")) {
            string part = raw_part.strip();
            if (part == "") continue;
            if (!is_valid_permission(part)) {
                invalid_permission = part;
                normalized = "";
                return false;
            }
            if (!seen.contains(part)) {
                seen.add(part);
                normalized_list.add(part);
            }
        }

        if (normalized_list.size == 0 || seen.contains("all")) {
            normalized = "all";
            return true;
        }

        normalized = BotUtils.join_strings(",", normalized_list);
        return true;
    }

    private string normalize_permissions(string? permissions) {
        string normalized;
        string invalid_permission;
        if (!parse_permissions(permissions, out normalized, out invalid_permission)) return "all";
        return normalized;
    }

    private bool is_valid_permission(string permission) {
        switch (permission) {
            case "all":
            case "send_message":
            case "receive_updates":
            case "webhook":
            case "file_send":
            case "muc_join":
            case "muc_send":
            case "admin":
                return true;
            default:
                return false;
        }
    }

    // --- POST /bot/create --- (no token needed, localhost only)
    private void handle_create_bot(Soup.Server srv, Soup.ServerMessage msg,
                                   string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;
        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body. Example: {\"name\":\"MeinBot\",\"account\":\"user@server.tld\"}");
            return;
        }

        string? name = json_get_string(body, "name");
        // Accept both "account" (UI) and "owner" (legacy) fields
        string? owner = json_get_string(body, "account");
        if (owner == null) owner = json_get_string(body, "owner");
        string? mode = json_get_string(body, "mode");
        if (mode == null) mode = "personal";
        string? avatar_data = json_get_string(body, "avatar");
        string? avatar_type = json_get_string(body, "avatar_type");
        string? webhook_url = json_get_string(body, "webhook_url");
        string? bot_jid = json_get_string(body, "bot_jid");
        string? bot_password = json_get_string(body, "bot_password");
        string? provisioning = json_get_string(body, "provisioning");
        string? purpose = json_get_string(body, "purpose");
        if (reject_invalid_string_members(msg, body,
                new string[] { "name", "account", "owner", "mode", "avatar", "avatar_type", "webhook_url", "permissions",
                    "bot_jid", "bot_password", "provisioning", "purpose" },
                "bot create")) {
            return;
        }
        string permissions;
        string invalid_permission;
        if (!parse_permissions(json_get_string(body, "permissions"), out permissions, out invalid_permission)) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid permission: %s".printf(invalid_permission));
            return;
        }

        if (name == null || name.strip().length == 0) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: name");
            return;
        }
        if (owner == null || owner.strip().length == 0) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: account (your JID)");
            return;
        }
        if (reject_invalid_account_jid(msg, owner, "account")) return;
        string owner_jid = owner.strip();
        mode = mode.strip().ascii_down();
        if (webhook_url != null && webhook_url.strip() != "" && !is_local_webhook_url(webhook_url.strip())) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid webhook_url. Use http:// or https://");
            return;
        }
        provisioning = provisioning != null ? provisioning.strip().ascii_down() : "";
        if (purpose != null && purpose.strip() != "" && !is_valid_bot_purpose(purpose)) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid purpose. Must be: ai, telegram, webhook, or advanced");
            return;
        }
        purpose = normalize_bot_purpose(purpose);

        // Validate mode
        if (mode != "personal" && mode != "dedicated" && mode != "cloud") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid mode. Must be: personal, dedicated, or cloud");
            return;
        }

        if (mode == "cloud") {
            AuthMiddleware.send_error(msg, 501, "not_implemented",
                "Cloud bot mode needs the persistent DinoX bot server and is not available in the local API yet.");
            return;
        }

        if (mode != "dedicated") {
            provisioning = "";
        } else {
            bool has_manual_account = bot_jid != null && bot_jid.strip() != "";
            if (provisioning == "") provisioning = has_manual_account ? "manual" : "ejabberd";
            if (provisioning != "manual" && provisioning != "ejabberd") {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid provisioning. Must be: manual or ejabberd");
                return;
            }
            if (provisioning == "manual") {
                if (bot_jid == null || bot_jid.strip() == "" ||
                        bot_password == null || bot_password.strip() == "") {
                    AuthMiddleware.send_error(msg, 400, "bad_request",
                        "Manual dedicated bot mode requires bot_jid and bot_password");
                    return;
                }
                if (reject_invalid_account_jid(msg, bot_jid, "bot_jid")) return;
            } else if (!ejabberd_api.is_configured()) {
                AuthMiddleware.send_error(msg, 400, "not_configured",
                    "Dedicated bot provisioning requires ejabberd API settings. Configure them in Botmother settings or use a manual bot account.");
                return;
            }
        }

        // Check bot limit per owner
        var existing = registry.get_bots_by_owner(owner_jid);
        if (existing.size >= 20) {
            AuthMiddleware.send_error(msg, 429, "limit_reached", "Maximum 20 bots per owner");
            return;
        }

        if (mode == "dedicated" && provisioning == "ejabberd") {
            // Async: register XMPP account via ejabberd
            msg.pause();
            do_create_dedicated_bot.begin(msg, name.strip(), owner_jid, mode, purpose, avatar_data, avatar_type, webhook_url, permissions);
        } else {
            int bot_id = registry.create_bot(name.strip(), owner_jid,
                TokenManager.create_inactive_token_marker("pending"), mode,
                mode == "dedicated" ? bot_jid.strip() : null);
            registry.update_bot_permissions(bot_id, permissions);
            registry.set_setting("bot_%d_purpose".printf(bot_id), purpose);
            if (mode == "dedicated") {
                registry.update_bot_password(bot_id, bot_password.strip());
                registry.set_setting("bot_dedicated_provisioning:%d".printf(bot_id), "manual");
            }
            string raw_token = token_manager.generate_token(bot_id);
            // Store avatar if provided
            if (avatar_data != null && avatar_data.length > 0) {
                registry.set_setting("bot_avatar:%d".printf(bot_id), avatar_data);
                registry.set_setting("bot_avatar_type:%d".printf(bot_id), avatar_type ?? "image/png");
            }
            string? webhook_secret = null;
            if (webhook_url != null && is_local_webhook_url(webhook_url.strip())) {
                webhook_secret = TokenManager.generate_webhook_secret();
                registry.set_webhook(bot_id, webhook_url.strip(), webhook_secret, true);
            }
            registry.log_action(bot_id, "created", "owner=%s mode=%s purpose=%s via=http".printf(owner_jid, mode, purpose));

            string json = "{\"id\":%d,\"name\":\"%s\",\"token\":\"%s\",\"mode\":\"%s\",\"purpose\":\"%s\",\"permissions\":\"%s\",\"api_url\":\"%s\",\"hint\":\"Use token as Bearer in Authorization header\"}".printf(
                bot_id, escape_json(name.strip()), escape_json(raw_token), escape_json(mode), escape_json(purpose),
                escape_json(permissions), escape_json(get_base_api_url()));
            if (mode == "dedicated") {
                json = "{\"id\":%d,\"name\":\"%s\",\"token\":\"%s\",\"mode\":\"%s\",\"purpose\":\"%s\",\"jid\":\"%s\",\"provisioning\":\"manual\",\"permissions\":\"%s\",\"api_url\":\"%s\",\"hint\":\"Use token as Bearer in Authorization header\"}".printf(
                    bot_id, escape_json(name.strip()), escape_json(raw_token), escape_json(mode),
                    escape_json(purpose), escape_json(bot_jid.strip()), escape_json(permissions), escape_json(get_base_api_url()));
            }
            if (webhook_secret != null) {
                if (mode == "dedicated") {
                    json = "{\"id\":%d,\"name\":\"%s\",\"token\":\"%s\",\"mode\":\"%s\",\"purpose\":\"%s\",\"jid\":\"%s\",\"provisioning\":\"manual\",\"permissions\":\"%s\",\"api_url\":\"%s\",\"webhook_secret\":\"%s\",\"hint\":\"Use token as Bearer in Authorization header\"}".printf(
                        bot_id, escape_json(name.strip()), escape_json(raw_token), escape_json(mode),
                        escape_json(purpose), escape_json(bot_jid.strip()), escape_json(permissions), escape_json(get_base_api_url()), escape_json(webhook_secret));
                } else {
                    json = "{\"id\":%d,\"name\":\"%s\",\"token\":\"%s\",\"mode\":\"%s\",\"purpose\":\"%s\",\"permissions\":\"%s\",\"api_url\":\"%s\",\"webhook_secret\":\"%s\",\"hint\":\"Use token as Bearer in Authorization header\"}".printf(
                        bot_id, escape_json(name.strip()), escape_json(raw_token), escape_json(mode),
                        escape_json(purpose), escape_json(permissions), escape_json(get_base_api_url()), escape_json(webhook_secret));
                }
            }
            AuthMiddleware.send_success(msg, json);
            if (mode == "dedicated") {
                BotInfo? new_bot = registry.get_bot_by_id(bot_id);
                if (new_bot != null) {
                    session_pool.connect_dedicated.begin(new_bot);
                }
            }
        }
    }

    // Async handler for creating a dedicated bot with ejabberd account registration
    private async void do_create_dedicated_bot(Soup.ServerMessage msg, string name, string owner, string mode, string purpose,
                                                string? avatar_data, string? avatar_type, string? webhook_url,
                                                string permissions) {
        string? username = null;
        string? bot_jid = null;
        string? password = null;
        string host = ejabberd_api.get_host();

        for (int i = 0; i < 8; i++) {
            string candidate = EjabberdApi.generate_bot_username(name);
            var check = yield ejabberd_api.check_account(candidate);
            if (check.success) {
                bool exists = false;
                if (EjabberdApi.parse_check_account_response(check.response_body, out exists) && exists) {
                    continue;
                }
            }
            if (check.status_code == 0) {
                AuthMiddleware.send_error(msg, 502, "account_check_failed",
                    "Failed to check generated XMPP account: %s".printf(check.error_message ?? "Unknown error"));
                msg.unpause();
                return;
            }

            string candidate_password = EjabberdApi.generate_bot_password();
            var result = yield ejabberd_api.register_account(candidate, candidate_password);
            if (!result.success) {
                if (EjabberdApi.registration_error_means_account_exists(result)) {
                    continue;
                }
                AuthMiddleware.send_error(msg, 502, "registration_failed",
                    "Failed to register XMPP account: %s".printf(result.error_message ?? "Unknown error"));
                msg.unpause();
                return;
            }

            username = candidate;
            bot_jid = "%s@%s".printf(candidate, host);
            password = candidate_password;
            break;
        }

        if (username == null || bot_jid == null || password == null) {
            AuthMiddleware.send_error(msg, 409, "jid_collision",
                "Could not generate a free bot JID. Please try again.");
            msg.unpause();
            return;
        }

        string verify_error = yield session_pool.verify_dedicated_credentials(bot_jid, password);
        if (verify_error != "") {
            var cleanup = yield ejabberd_api.unregister_account(username);
            string cleanup_detail = cleanup.success ? "server account removed" :
                "server cleanup failed: %s".printf(cleanup.error_message ?? "Unknown error");
            AuthMiddleware.send_error(msg, 502, "registration_verification_failed",
                "Registered XMPP account failed login verification: %s (%s)".printf(verify_error, cleanup_detail));
            msg.unpause();
            return;
        }

        // Create bot in local DB
        int bot_id = registry.create_bot(name, owner, TokenManager.create_inactive_token_marker("pending"), mode, bot_jid);
        registry.update_bot_permissions(bot_id, permissions);
        registry.update_bot_password(bot_id, password);
        registry.set_setting("bot_dedicated_provisioning:%d".printf(bot_id), "ejabberd");
        registry.set_setting("bot_%d_purpose".printf(bot_id), purpose);
        string raw_token = token_manager.generate_token(bot_id);
        // Store avatar if provided
        if (avatar_data != null && avatar_data.length > 0) {
            registry.set_setting("bot_avatar:%d".printf(bot_id), avatar_data);
            registry.set_setting("bot_avatar_type:%d".printf(bot_id), avatar_type ?? "image/png");
        }
        registry.log_action(bot_id, "created", "owner=%s mode=%s purpose=%s jid=%s via=http".printf(owner, mode, purpose, bot_jid));

        string? webhook_secret = null;
        if (webhook_url != null && is_local_webhook_url(webhook_url.strip())) {
            webhook_secret = TokenManager.generate_webhook_secret();
            registry.set_webhook(bot_id, webhook_url.strip(), webhook_secret, true);
        }

        string json = "{\"id\":%d,\"name\":\"%s\",\"token\":\"%s\",\"mode\":\"%s\",\"purpose\":\"%s\",\"jid\":\"%s\",\"permissions\":\"%s\",\"api_url\":\"%s\",\"hint\":\"Use token as Bearer in Authorization header\"}".printf(
            bot_id, escape_json(name), escape_json(raw_token), escape_json(mode), escape_json(purpose), escape_json(bot_jid),
            escape_json(permissions), escape_json(get_base_api_url()));
        if (webhook_secret != null) {
            json = "{\"id\":%d,\"name\":\"%s\",\"token\":\"%s\",\"mode\":\"%s\",\"purpose\":\"%s\",\"jid\":\"%s\",\"permissions\":\"%s\",\"api_url\":\"%s\",\"webhook_secret\":\"%s\",\"hint\":\"Use token as Bearer in Authorization header\"}".printf(
                bot_id, escape_json(name), escape_json(raw_token), escape_json(mode), escape_json(purpose), escape_json(bot_jid),
                escape_json(permissions), escape_json(get_base_api_url()), escape_json(webhook_secret));
        }
        AuthMiddleware.send_success(msg, json);
        msg.unpause();

        // Connect the new dedicated bot immediately
        BotInfo? new_bot = registry.get_bot_by_id(bot_id);
        if (new_bot != null) {
            session_pool.connect_dedicated.begin(new_bot);
        }
    }

    // --- GET /bot/list --- (no token needed, localhost only)
    private void handle_list_bots(Soup.Server srv, Soup.ServerMessage msg,
                                  string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }

        // Optional filter by account
        string? account_filter = null;
        if (query != null && query.contains("account")) {
            account_filter = query.get("account").strip();
        }

        var bots = registry.get_all_bots();
        var sb = new StringBuilder("{\"bots\":[");
        bool first = true;
        foreach (BotInfo bot in bots) {
            // Filter by account if specified
            if (account_filter != null && bot.owner_jid != account_filter) continue;
            if (!first) sb.append(",");
            sb.append(bot_to_json(bot));
            first = false;
        }
        sb.append("]}");
        msg.set_status(200, null);
        BotUtils.set_json_response(msg, sb.str);
    }

    // --- POST or DELETE /bot/delete --- (no token needed, localhost only)
    private void handle_delete_bot(Soup.Server srv, Soup.ServerMessage msg,
                                   string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;
        string method = msg.get_method();
        int bot_id = -1;

        if (method == "DELETE" && query != null && query.contains("id")) {
            // DELETE /bot/delete?id=123
            if (!parse_positive_int(query.get("id"), out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid bot id");
                return;
            }
        } else if (method == "POST") {
            // POST /bot/delete with JSON body {"id":123}
            var body = get_request_body(msg);
            if (body == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
                return;
            }
            if (!get_positive_int_member(body, "id", out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: id");
                return;
            }
        } else {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST or DELETE");
            return;
        }

        if (bot_id <= 0) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid bot id");
            return;
        }

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Botmother not found");
            return;
        }

        stop_deleted_bot_runtime(bot);

        string provisioning = dedicated_provisioning_for_bot(bot);

        // Only unregister accounts created by DinoX through ejabberd provisioning.
        if (bot.mode == "dedicated" && provisioning == "ejabberd" && bot.jid != null && bot.jid.contains("@")) {
            string username = bot.jid.split("@")[0];
            msg.pause();
            do_delete_dedicated_bot.begin(msg, bot, username);
        } else {
            registry.delete_bot(bot_id);
            registry.log_action(bot_id, "deleted", "via=http");
            AuthMiddleware.send_success(msg, "{\"deleted\":true,\"id\":%d}".printf(bot_id));
        }
    }

    // Async handler for deleting a dedicated bot with ejabberd account removal
    private async void do_delete_dedicated_bot(Soup.ServerMessage msg, BotInfo bot, string username) {
        // First clean bot-owned PubSub nodes while the dedicated stream/account still exists.
        // Then use ejabberd unregister so server-owned account data is removed as well.
        session_pool.prepare_for_account_unregister(bot.id);
        yield wait_ms(700);

        // Try to unregister from ejabberd, but delete locally regardless.
        var result = yield ejabberd_api.unregister_account(username);
        if (!result.success) {
            warning("Botmother: Failed to unregister %s from ejabberd: %s", username, result.error_message ?? "?");
        }
        registry.delete_bot(bot.id);
        registry.log_action(bot.id, "deleted", "dedicated_account_removed=%s via=http".printf(
            result.success ? "true" : "false"));
        AuthMiddleware.send_success(msg, "{\"deleted\":true,\"id\":%d,\"account_removed\":%s}".printf(
            bot.id, result.success ? "true" : "false"));
        msg.unpause();
    }

    // --- POST /bot/activate --- (no token needed, localhost only)
    // Sets bot status to "active", "paused", or "disabled".
    // Compatibility: {"active":true/false} still maps to active/disabled.
    private void handle_activate_bot(Soup.Server srv, Soup.ServerMessage msg,
                                     string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;
        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body. Example: {\"id\":1,\"active\":true}");
            return;
        }

        int bot_id = 0;
        if (!get_positive_int_member(body, "id", out bot_id)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
            return;
        }

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
            return;
        }

        string old_status = bot.status ?? "active";
        string new_status;
        string log_action;
        if (body.has_member("status")) {
            string? requested_status = json_get_string(body, "status");
            if (reject_invalid_string_members(msg, body, new string[] { "status" }, "bot status")) return;
            if (requested_status == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Status must be a string");
                return;
            }
            new_status = requested_status.strip().ascii_down();
            switch (new_status) {
                case "active":
                    log_action = "activated";
                    break;
                case "paused":
                    log_action = "paused";
                    break;
                case "disabled":
                    log_action = "deactivated";
                    break;
                default:
                    AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid status. Must be: active, paused, or disabled");
                    return;
            }
        } else {
            bool new_active;
            if (!get_bool_member(body, "active", out new_active)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: active (true/false) or status");
                return;
            }
            new_status = new_active ? "active" : "disabled";
            log_action = new_active ? "activated" : "deactivated";
        }

        registry.update_bot_status(bot_id, new_status);
        bot.status = new_status;
        if (old_status == "paused" && new_status == "active") {
            registry.set_setting("bot_ignore_delayed_before:%d".printf(bot_id),
                ((long) new DateTime.now_utc().to_unix()).to_string());
        }
        sync_receive_update_runtime(bot);
        registry.log_action(bot_id, log_action, "via=http");

        // Notify plugin to sync runtime and conversation handling.
        registry.bot_status_changed(bot_id, new_status);

        string json = "{\"id\":%d,\"status\":\"%s\"}".printf(bot_id, new_status);
        AuthMiddleware.send_success(msg, json);
    }

    // --- POST /bot/token --- (no token needed, localhost only)
    // Regenerates the token for a bot and returns the new token
    private void handle_regenerate_token(Soup.Server srv, Soup.ServerMessage msg,
                                         string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;
        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        int bot_id = 0;
        if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
            return;
        }

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
            return;
        }

        string raw_token = token_manager.regenerate_token(bot_id);
        registry.log_action(bot_id, "token_regenerated", "via=http");

        string json = "{\"id\":%d,\"token\":\"%s\"}".printf(bot_id, escape_json(raw_token));
        AuthMiddleware.send_success(msg, json);
    }

    // --- POST /bot/revoke --- (no token needed, localhost only)
    // Revokes the token for a bot (disables the bot)
    private void handle_revoke_token(Soup.Server srv, Soup.ServerMessage msg,
                                     string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;
        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        int bot_id = 0;
        if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
            return;
        }

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
            return;
        }

        token_manager.revoke_token(bot_id);
        registry.update_bot_status(bot_id, "disabled");
        bot.status = "disabled";
        sync_receive_update_runtime(bot);
        registry.bot_status_changed(bot_id, "disabled");

        string json = "{\"id\":%d,\"revoked\":true,\"status\":\"disabled\"}".printf(bot_id);
        AuthMiddleware.send_success(msg, json);
    }

    // --- GET/POST /bot/permissions --- (no token needed, localhost only)
    private void handle_permissions(Soup.Server srv, Soup.ServerMessage msg,
                                    string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() == "GET") {
            string? id_str = query != null ? query.lookup("id") : null;
            if (id_str == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing ?id= parameter");
                return;
            }
            int bot_id = 0;
            if (!parse_positive_int(id_str, out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid bot id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            AuthMiddleware.send_success(msg, "{\"id\":%d,\"permissions\":\"%s\"}".printf(
                bot_id, escape_json(normalize_permissions(bot.permissions))));
            return;
        }

        if (msg.get_method() == "POST") {
            var body = get_request_body(msg);
            int bot_id = 0;
            if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string? permissions = json_get_string(body, "permissions");
            if (reject_invalid_string_members(msg, body, new string[] { "permissions" }, "permissions")) return;
            if (permissions == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: permissions");
                return;
            }

            string normalized;
            string invalid_permission;
            if (!parse_permissions(permissions, out normalized, out invalid_permission)) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid permission: %s".printf(invalid_permission));
                return;
            }
            registry.update_bot_permissions(bot_id, normalized);
            bot.permissions = normalized;
            sync_receive_update_runtime(bot);
            registry.log_action(bot_id, "permissions_updated", normalized);
            AuthMiddleware.send_success(msg, "{\"id\":%d,\"permissions\":\"%s\"}".printf(
                bot_id, escape_json(normalized)));
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    // --- GET/POST /bot/targets --- (no token needed, localhost only)
    private void handle_targets(Soup.Server srv, Soup.ServerMessage msg,
                                string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() == "GET") {
            string? id_str = query != null ? query.lookup("id") : null;
            if (id_str == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing ?id= parameter");
                return;
            }
            int bot_id = 0;
            if (!parse_positive_int(id_str, out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid bot id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string targets = normalize_targets(registry.get_setting(target_setting_key(bot_id)));
            string mode = normalize_target_mode(registry.get_setting(target_mode_setting_key(bot_id)), targets);
            AuthMiddleware.send_success(msg, "{\"id\":%d,\"target_mode\":\"%s\",\"target_list\":\"%s\",\"allowed_targets\":\"%s\"}".printf(
                bot_id, escape_json(mode), escape_json(targets), escape_json(targets)));
            return;
        }

        if (msg.get_method() == "POST") {
            var body = get_request_body(msg);
            int bot_id = 0;
            if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string? targets = json_get_string(body, "target_list");
            if (targets == null) targets = json_get_string(body, "allowed_targets");
            if (reject_invalid_string_members(msg, body,
                    new string[] { "target_list", "allowed_targets", "target_mode" },
                    "target")) {
                return;
            }
            if (targets == null) targets = "";
            string invalid_target;
            if (!validate_targets(targets, out invalid_target)) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid target entry: %s".printf(invalid_target));
                return;
            }
            string normalized = normalize_targets(targets);
            string? requested_mode = json_get_string(body, "target_mode");
            if (requested_mode != null && requested_mode.strip() != "" && !is_valid_target_mode(requested_mode)) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid target_mode. Must be: all, allow, or block");
                return;
            }
            string mode = normalize_target_mode(requested_mode, normalized);

            if (mode == "all") {
                normalized = "";
                registry.delete_setting(target_setting_key(bot_id));
            } else {
                registry.set_setting(target_mode_setting_key(bot_id), mode);
                if (normalized == "") {
                    registry.delete_setting(target_setting_key(bot_id));
                } else {
                    registry.set_setting(target_setting_key(bot_id), normalized);
                }
            }
            if (mode == "all") registry.delete_setting(target_mode_setting_key(bot_id));
            registry.log_action(bot_id, "targets_updated", "%s:%s".printf(mode, normalized));
            AuthMiddleware.send_success(msg, "{\"id\":%d,\"target_mode\":\"%s\",\"target_list\":\"%s\",\"allowed_targets\":\"%s\"}".printf(
                bot_id, escape_json(mode), escape_json(normalized), escape_json(normalized)));
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    // --- GET/POST /bot/webhook --- (local Bot Manager management endpoint)
    private void handle_webhook_management(Soup.Server srv, Soup.ServerMessage msg,
                                           string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() == "GET") {
            string? id_str = query != null ? query.lookup("id") : null;
            if (id_str == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing ?id= parameter");
                return;
            }
            int bot_id = 0;
            if (!parse_positive_int(id_str, out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid bot id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string webhook_url = bot.webhook_url ?? "";
            AuthMiddleware.send_success(msg,
                "{\"id\":%d,\"enabled\":%s,\"webhook_url\":\"%s\",\"secret_available\":%s}".printf(
                    bot_id,
                    bot.webhook_enabled ? "true" : "false",
                    escape_json(webhook_url),
                    bot.webhook_secret != null && bot.webhook_secret != "" ? "true" : "false"));
            return;
        }

        if (msg.get_method() == "POST") {
            var body = get_request_body(msg);
            int bot_id = 0;
            if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string? url = json_get_string(body, "url");
            if (url == null) url = json_get_string(body, "webhook_url");
            if (reject_invalid_string_members(msg, body, new string[] { "url", "webhook_url" }, "webhook")) return;

            bool enabled = true;
            if (body.has_member("enabled") && !get_bool_member(body, "enabled", out enabled)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Webhook enabled field must be a boolean");
                return;
            }

            if (!enabled || (url != null && url.strip() == "")) {
                registry.set_webhook(bot_id, null, null, false);
                registry.log_action(bot_id, "webhook_deleted", "via=local-ui");
                AuthMiddleware.send_success(msg, "{\"id\":%d,\"enabled\":false,\"webhook_url\":\"\"}".printf(bot_id));
                return;
            }
            if (url == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: url");
                return;
            }

            string webhook_url = url.strip();
            if (!is_local_webhook_url(webhook_url)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid webhook_url. Use http:// or https://");
                return;
            }

            string secret = TokenManager.generate_webhook_secret();
            registry.set_webhook(bot_id, webhook_url, secret, true);
            registry.log_action(bot_id, "webhook_set", WebhookDispatcher.sanitize_url_for_log(webhook_url));
            AuthMiddleware.send_success(msg,
                "{\"id\":%d,\"enabled\":true,\"webhook_url\":\"%s\",\"secret\":\"%s\"}".printf(
                    bot_id, escape_json(webhook_url), escape_json(secret)));
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    // --- GET/POST /bot/avatar --- (local Bot Manager management endpoint)
    private void handle_avatar_management(Soup.Server srv, Soup.ServerMessage msg,
                                          string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() == "GET") {
            string? id_str = query != null ? query.lookup("id") : null;
            if (id_str == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing ?id= parameter");
                return;
            }
            int bot_id = 0;
            if (!parse_positive_int(id_str, out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid bot id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string? avatar = registry.get_setting("bot_avatar:%d".printf(bot_id));
            string? avatar_type = registry.get_setting("bot_avatar_type:%d".printf(bot_id));
            AuthMiddleware.send_success(msg,
                "{\"id\":%d,\"configured\":%s,\"avatar_type\":\"%s\"}".printf(
                    bot_id, avatar != null && avatar != "" ? "true" : "false",
                    escape_json(avatar_type ?? "")));
            return;
        }

        if (msg.get_method() == "POST") {
            var body = get_request_body(msg);
            int bot_id = 0;
            if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }
            if (reject_invalid_string_members(msg, body, new string[] { "avatar", "avatar_type" }, "avatar")) return;

            bool remove = false;
            if (body.has_member("remove") && !get_bool_member(body, "remove", out remove)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Avatar remove field must be a boolean");
                return;
            }

            if (remove) {
                registry.delete_setting("bot_avatar:%d".printf(bot_id));
                registry.delete_setting("bot_avatar_type:%d".printf(bot_id));
                registry.log_action(bot_id, "avatar_removed", "via=local-ui");
                if (can_refresh_dedicated_bot_metadata(bot)) {
                    session_pool.refresh_bot_metadata(bot);
                }
                AuthMiddleware.send_success(msg, "{\"id\":%d,\"configured\":false}".printf(bot_id));
                return;
            }

            string? avatar_data = json_get_string(body, "avatar");
            string? avatar_type = json_get_string(body, "avatar_type");
            if (avatar_data == null || avatar_data.strip() == "") {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: avatar");
                return;
            }
            if (avatar_type == null || avatar_type.strip() == "") avatar_type = "image/png";
            registry.set_setting("bot_avatar:%d".printf(bot_id), avatar_data.strip());
            registry.set_setting("bot_avatar_type:%d".printf(bot_id), avatar_type.strip());
            registry.log_action(bot_id, "avatar_updated", "type=%s via=local-ui".printf(avatar_type.strip()));
            if (can_refresh_dedicated_bot_metadata(bot)) {
                session_pool.refresh_bot_metadata(bot);
            }
            AuthMiddleware.send_success(msg,
                "{\"id\":%d,\"configured\":true,\"avatar_type\":\"%s\"}".printf(
                    bot_id, escape_json(avatar_type.strip())));
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    // --- GET/POST/DELETE /bot/cloud/tokens --- (local Bot Manager CloudBot token persistence)
    private void handle_cloudbot_tokens(Soup.Server srv, Soup.ServerMessage msg,
                                        string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        string method = msg.get_method();
        if (method == "GET") {
            string? account = query != null ? query.lookup("account") : null;
            if (account == null || reject_invalid_account_jid(msg, account, "account")) return;

            var tokens = registry.get_cloudbot_management_tokens(account.strip());
            var sb = new StringBuilder("{\"account\":\"%s\",\"tokens\":[".printf(escape_json(account.strip())));
            bool first = true;
            foreach (string token in tokens) {
                if (!first) sb.append(",");
                sb.append("\"%s\"".printf(escape_json(token)));
                first = false;
            }
            sb.append("]}");
            AuthMiddleware.send_success(msg, sb.str);
            return;
        }

        if (method == "POST" || method == "DELETE") {
            var body = get_request_body(msg);
            if (body == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
                return;
            }
            if (reject_invalid_string_members(msg, body, new string[] { "account", "token" }, "cloud token")) {
                return;
            }
            string? account = json_get_string(body, "account");
            string? token = json_get_string(body, "token");
            if (account == null || reject_invalid_account_jid(msg, account, "account")) return;
            if (token == null || !is_valid_cloudbot_management_token(token)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid cloud bot management token");
                return;
            }

            if (method == "POST") {
                registry.add_cloudbot_management_token(account.strip(), token.strip());
                registry.log_action(0, "cloudbot_token_saved", "account=%s".printf(account.strip()));
                AuthMiddleware.send_success(msg, "{\"saved\":true}");
            } else {
                registry.remove_cloudbot_management_token(account.strip(), token.strip());
                registry.log_action(0, "cloudbot_token_removed", "account=%s".printf(account.strip()));
                AuthMiddleware.send_success(msg, "{\"removed\":true}");
            }
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET, POST or DELETE");
    }

    // --- GET/POST /bot/account/status ---
    // GET: returns {"account":"jid","enabled":true/false}
    // POST: {"account":"jid","enabled":true/false} -> sets the per-account toggle
    private void handle_account_status(Soup.Server srv, Soup.ServerMessage msg,
                                       string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        string method = msg.get_method();

        if (method == "GET") {
            string? account = query != null ? query.lookup("account") : null;
            if (account == null || account.strip().length == 0) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing ?account= parameter");
                return;
            }
            if (reject_invalid_account_jid(msg, account, "account")) return;
            string key = "botmother_account_enabled:" + account.strip();
            string? val = registry.get_setting(key);
            bool is_enabled = (val == null || val == "true"); // default: enabled
            string json = "{\"account\":\"%s\",\"enabled\":%s}".printf(
                escape_json(account.strip()), is_enabled ? "true" : "false");
            AuthMiddleware.send_success(msg, json);
            return;
        }

        if (method == "POST") {
            var body = get_request_body(msg);
            if (body == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
                return;
            }
            string? account = json_get_string(body, "account");
            if (reject_invalid_string_members(msg, body, new string[] { "account" }, "account status")) return;
            if (account == null || account.strip().length == 0) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing 'account' field");
                return;
            }
            if (reject_invalid_account_jid(msg, account, "account")) return;
            bool new_enabled = false;
            if (!get_bool_member(body, "enabled", out new_enabled)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid field: enabled (true/false)");
                return;
            }
            string key = "botmother_account_enabled:" + account.strip();
            registry.set_setting(key, new_enabled ? "true" : "false");

            sync_account_receive_update_runtime(account.strip());

            // Emit signal so the plugin can react (pin/unpin)
            registry.account_toggled(account.strip(), new_enabled);

            string json = "{\"account\":\"%s\",\"enabled\":%s}".printf(
                escape_json(account.strip()), new_enabled ? "true" : "false");
            AuthMiddleware.send_success(msg, json);
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    // --- GET/POST /bot/ejabberd/settings ---
    // GET: returns current ejabberd API settings (password masked)
    // POST: saves ejabberd API settings
    private void handle_ejabberd_settings(Soup.Server srv, Soup.ServerMessage msg,
                                          string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        string method = msg.get_method();

        if (method == "GET") {
            string? url = registry.get_setting(EjabberdApi.KEY_API_URL);
            string? admin_jid = registry.get_setting(EjabberdApi.KEY_ADMIN_JID);
            string? admin_pw = registry.get_secret_setting(EjabberdApi.KEY_ADMIN_PASSWORD);
            string? host = registry.get_setting(EjabberdApi.KEY_HOST);
            bool configured = ejabberd_api.is_configured();

            // Mask password
            string pw_display = (admin_pw != null && admin_pw.strip() != "") ? "********" : "";

            string json = "{\"api_url\":\"%s\",\"admin_jid\":\"%s\",\"admin_password\":\"%s\",\"host\":\"%s\",\"configured\":%s}".printf(
                escape_json(url ?? ""),
                escape_json(admin_jid ?? ""),
                escape_json(pw_display),
                escape_json(host ?? ""),
                configured ? "true" : "false");
            AuthMiddleware.send_success(msg, json);
            return;
        }

        if (method == "POST") {
            var body = get_request_body(msg);
            if (body == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
                return;
            }

            string? url = json_get_string(body, "api_url");
            string? admin_jid = json_get_string(body, "admin_jid");
            string? admin_pw = json_get_string(body, "admin_password");
            string? host = json_get_string(body, "host");

            if (has_invalid_string_member(body, "api_url") ||
                    has_invalid_string_member(body, "admin_jid") ||
                    has_invalid_string_member(body, "admin_password") ||
                    has_invalid_string_member(body, "host")) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "ejabberd settings fields must be strings");
                return;
            }
            if (url != null && url.strip() != "" && !is_http_url(url.strip())) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid api_url. Use http:// or https://");
                return;
            }
            if (admin_jid != null && admin_jid.strip() != "" &&
                    reject_invalid_account_jid(msg, admin_jid, "admin_jid")) {
                return;
            }
            if (host != null && host.strip() != "" &&
                    reject_invalid_domain_target(msg, host, "host")) {
                return;
            }

            if (url != null) registry.set_setting(EjabberdApi.KEY_API_URL, url.strip());
            if (admin_jid != null) registry.set_setting(EjabberdApi.KEY_ADMIN_JID, admin_jid.strip());
            // Only update password if not masked
            if (admin_pw != null && admin_pw != "********") {
                registry.set_secret_setting(EjabberdApi.KEY_ADMIN_PASSWORD, admin_pw.strip());
            }
            if (host != null) registry.set_setting(EjabberdApi.KEY_HOST, host.strip());

            registry.log_action(0, "ejabberd_settings_updated", "via=http");
            AuthMiddleware.send_success(msg, "{\"saved\":true,\"configured\":%s}".printf(
                ejabberd_api.is_configured() ? "true" : "false"));
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    // --- POST /bot/ejabberd/test ---
    // Tests connectivity to ejabberd API
    private void handle_ejabberd_test(Soup.Server srv, Soup.ServerMessage msg,
                                      string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        msg.pause();
        do_ejabberd_test.begin(msg);
    }

    private async void do_ejabberd_test(Soup.ServerMessage msg) {
        // Check if request body contains inline credentials (test-before-save)
        ApiResult result;
        Json.Object? body = get_request_body(msg);
        if (body != null) {
            string? api_url = json_get_string(body, "api_url");
            string? host = json_get_string(body, "host");
            string? admin_jid = json_get_string(body, "admin_jid");
            string? admin_pw = json_get_string(body, "admin_password");

            if (has_invalid_string_member(body, "api_url") ||
                    has_invalid_string_member(body, "admin_jid") ||
                    has_invalid_string_member(body, "admin_password") ||
                    has_invalid_string_member(body, "host")) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "ejabberd test fields must be strings");
                msg.unpause();
                return;
            }
            if (api_url != null && api_url.strip() != "" && !is_http_url(api_url.strip())) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid api_url. Use http:// or https://");
                msg.unpause();
                return;
            }
            if (admin_jid != null && admin_jid.strip() != "" && !is_valid_bare_account_jid(admin_jid)) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid account JID in field: admin_jid");
                msg.unpause();
                return;
            }
            if (host != null && host.strip() != "" && !is_valid_domain_target(host)) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "Invalid domain in field: host");
                msg.unpause();
                return;
            }

            // If password not provided in body, fall back to saved password
            if (admin_pw == null || admin_pw.strip() == "") {
                admin_pw = registry.get_secret_setting(EjabberdApi.KEY_ADMIN_PASSWORD);
            }

            if (api_url != null && api_url.strip() != "" &&
                host != null && host.strip() != "" &&
                admin_jid != null && admin_jid.strip() != "" &&
                admin_pw != null && admin_pw.strip() != "") {
                result = yield ejabberd_api.test_connection_with_params(api_url, host, admin_jid, admin_pw);
            } else {
                result = yield ejabberd_api.test_connection();
            }
        } else {
            result = yield ejabberd_api.test_connection();
        }

        if (result.success) {
            string json = "{\"connected\":true,\"response\":\"%s\"}".printf(
                escape_json(result.response_body ?? "ok"));
            AuthMiddleware.send_success(msg, json);
        } else {
            AuthMiddleware.send_error(msg, 502, "connection_failed", result.error_message ?? "Unknown error");
        }
        msg.unpause();
    }

    // --- GET /health ---
    private void handle_health(Soup.Server srv, Soup.ServerMessage msg,
                               string path, HashTable<string, string>? query) {
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }

        string json = "{\"status\":\"ok\",\"version\":\"1.0.0\",\"active_bots\":%d}".printf(
            registry.get_all_active_bots().size);
        msg.set_status(200, null);
        BotUtils.set_json_response(msg, json);
    }

    // --- GET /bot/getMe ---
    private void handle_get_me(Soup.Server srv, Soup.ServerMessage msg,
                               string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }

        string json = bot_to_json(bot);
        AuthMiddleware.send_success(msg, json);
    }

    // --- POST /bot/sendMessage ---
    private void handle_send_message(Soup.Server srv, Soup.ServerMessage msg,
                                     string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        string? to_jid = json_get_string(body, "to");
        string? text = json_get_string(body, "text");
        string? msg_type = json_get_string(body, "type");
        if (reject_invalid_string_members(msg, body, new string[] { "to", "text", "type" }, "message")) return;

        if (to_jid == null || to_jid.strip() == "" || text == null || text.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: to, text");
            return;
        }

        if (msg_type == null || msg_type.strip() == "") msg_type = "chat";
        msg_type = msg_type.strip().ascii_down();
        if (!is_valid_message_type(msg_type)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid type. Must be: chat or groupchat");
            return;
        }
        if (reject_invalid_jid(msg, to_jid, "to")) return;
        if (!require_permission(msg, bot, msg_type == "groupchat" ? "muc_send" : "send_message")) return;
        if (!require_target(msg, bot, to_jid.strip())) return;
        // Send via message router
        string? message_id = message_router.send_message(bot, to_jid.strip(), text, msg_type);
        if (message_id != null) {
            AuthMiddleware.send_success(msg, "{\"message_id\":\"%s\"}".printf(escape_json(message_id)));
        } else {
            AuthMiddleware.send_error(msg, 500, "send_failed", "Failed to send message");
        }
    }

    // --- POST /bot/testSend --- (local Bot Manager console, no raw token required)
    private void handle_test_send(Soup.Server srv, Soup.ServerMessage msg,
                                  string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        if (body == null || !body.has_member("id")) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: id");
            return;
        }

        int bot_id = 0;
        if (!get_positive_int_member(body, "id", out bot_id)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
            return;
        }
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
            return;
        }
        if (!require_local_bot_runtime_allowed(msg, bot)) return;

        string? to_jid = json_get_string(body, "to");
        string? text = json_get_string(body, "text");
        string? msg_type = json_get_string(body, "type");
        if (reject_invalid_string_members(msg, body, new string[] { "to", "text", "type" }, "test message")) return;
        if (to_jid == null || to_jid.strip() == "" || text == null || text.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: to, text");
            return;
        }

        if (msg_type == null || msg_type.strip() == "") msg_type = "chat";
        msg_type = msg_type.strip().ascii_down();
        if (!is_valid_message_type(msg_type)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid type. Must be: chat or groupchat");
            return;
        }
        if (reject_invalid_jid(msg, to_jid, "to")) return;
        if (!require_permission(msg, bot, msg_type == "groupchat" ? "muc_send" : "send_message")) return;
        if (!require_target(msg, bot, to_jid)) return;
        string? message_id = message_router.send_message(bot, to_jid.strip(), text, msg_type);
        if (message_id != null) {
            AuthMiddleware.send_success(msg, "{\"message_id\":\"%s\"}".printf(escape_json(message_id)));
        } else {
            AuthMiddleware.send_error(msg, 500, "send_failed", "Failed to send message");
        }
    }

    // --- POST /bot/testJoinRoom --- (local Bot Manager room join, no raw token required)
    private void handle_test_join_room(Soup.Server srv, Soup.ServerMessage msg,
                                       string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        if (body == null || !body.has_member("id")) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: id");
            return;
        }

        int bot_id = 0;
        if (!get_positive_int_member(body, "id", out bot_id)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
            return;
        }
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
            return;
        }
        if (!require_local_bot_runtime_allowed(msg, bot)) return;

        string? room_jid = json_get_string(body, "room");
        string? nick = json_get_string(body, "nick");
        if (reject_invalid_string_members(msg, body, new string[] { "room", "nick" }, "room join")) return;
        if (room_jid == null || room_jid.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: room");
            return;
        }
        if (reject_invalid_jid(msg, room_jid, "room")) return;
        if (!require_permission(msg, bot, "muc_join")) return;
        if (!require_target(msg, bot, room_jid.strip())) return;

        string? clean_nick = nick != null && nick.strip() != "" ? nick.strip() : null;
        msg.pause();
        do_test_join_room.begin(msg, bot, room_jid.strip(), clean_nick);
    }

    private async void do_test_join_room(Soup.ServerMessage msg, BotInfo bot, string room_jid, string? nick) {
        bool result = yield message_router.join_room(bot, room_jid, nick);
        if (result) {
            if (bot.mode == "dedicated") {
                BotUtils.remember_muc_room(registry, bot.id, room_jid, nick ?? bot.name ?? "");
            }
            AuthMiddleware.send_success(msg, "true");
        } else {
            AuthMiddleware.send_error(msg, 500, "join_failed", "Failed to join room");
        }
        msg.unpause();
    }

    // --- POST /bot/testLeaveRoom --- (local Bot Manager room leave, no raw token required)
    private void handle_test_leave_room(Soup.Server srv, Soup.ServerMessage msg,
                                        string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        if (body == null || !body.has_member("id")) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: id");
            return;
        }

        int bot_id = 0;
        if (!get_positive_int_member(body, "id", out bot_id)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
            return;
        }
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
            return;
        }
        if (!require_local_bot_runtime_allowed(msg, bot)) return;

        string? room_jid = json_get_string(body, "room");
        if (reject_invalid_string_members(msg, body, new string[] { "room" }, "room leave")) return;
        if (room_jid == null || room_jid.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: room");
            return;
        }
        if (reject_invalid_jid(msg, room_jid, "room")) return;
        if (!require_permission(msg, bot, "muc_join")) return;
        if (!require_target(msg, bot, room_jid.strip())) return;

        bool result = message_router.leave_room(bot, room_jid.strip());
        if (result) {
            if (bot.mode == "dedicated") {
                BotUtils.forget_muc_room(registry, bot.id, room_jid.strip());
            }
            AuthMiddleware.send_success(msg, "true");
        } else {
            AuthMiddleware.send_error(msg, 500, "leave_failed", "Failed to leave room");
        }
    }

    // --- GET /bot/getUpdates ---
    private void handle_get_updates(Soup.Server srv, Soup.ServerMessage msg,
                                    string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }
        if (!require_permission(msg, bot, "receive_updates")) return;

        int offset = 0;
        int limit = 100;
        int timeout = 0;

        if (query != null) {
            string? off_str = query.lookup("offset");
            string? lim_str = query.lookup("limit");
            string? timeout_str = query.lookup("timeout");
            if (off_str != null && !parse_nonnegative_int(off_str, out offset)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid offset");
                return;
            }
            if (lim_str != null) {
                if (!parse_positive_int(lim_str, out limit)) {
                    AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid limit");
                    return;
                }
                limit = limit.clamp(1, 100);
            }
            if (timeout_str != null) {
                if (!parse_nonnegative_int(timeout_str, out timeout)) {
                    AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid timeout");
                    return;
                }
                timeout = timeout.clamp(0, 30);
            }
        }

        var updates = registry.get_updates(bot.id, offset, limit);
        if (offset > 0) {
            registry.delete_updates_up_to(bot.id, offset - 1);
        }

        if (updates.size == 0 && timeout > 0) {
            msg.pause();
            do_get_updates_long_poll.begin(msg, bot.id, offset, limit, timeout);
            return;
        }

        send_updates_response(msg, updates);
    }

    private async void do_get_updates_long_poll(Soup.ServerMessage msg, int bot_id, int offset, int limit, int timeout_seconds) {
        Gee.List<UpdateInfo> updates = registry.get_updates(bot_id, offset, limit);
        int waited_ms = 0;
        int timeout_ms = timeout_seconds * 1000;

        while (updates.size == 0 && waited_ms < timeout_ms) {
            yield delay_ms(250);
            waited_ms += 250;
            updates = registry.get_updates(bot_id, offset, limit);
        }

        send_updates_response(msg, updates);
        msg.unpause();
    }

    private void send_updates_response(Soup.ServerMessage msg, Gee.List<UpdateInfo> updates) {
        var sb = new StringBuilder("[");
        bool first = true;
        foreach (UpdateInfo update in updates) {
            if (!first) sb.append(",");
            sb.append("{\"update_id\":%d,\"type\":\"%s\",\"data\":%s}".printf(
                update.id, update.update_type, update.payload));
            first = false;
        }
        sb.append("]");

        AuthMiddleware.send_success(msg, sb.str);
    }

    private async void delay_ms(int ms) {
        GLib.Timeout.add(ms, () => {
            delay_ms.callback();
            return GLib.Source.REMOVE;
        });
        yield;
    }

    // --- POST /bot/setWebhook ---
    private void handle_set_webhook(Soup.Server srv, Soup.ServerMessage msg,
                                    string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "webhook")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        string? url = json_get_string(body, "url");
        if (reject_invalid_string_members(msg, body, new string[] { "url" }, "webhook")) return;
        if (url == null || !is_local_webhook_url(url.strip())) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid 'url' field");
            return;
        }
        string webhook_url = url.strip();

        string secret = TokenManager.generate_webhook_secret();
        registry.set_webhook(bot.id, webhook_url, secret, true);
        registry.log_action(bot.id, "webhook_set", WebhookDispatcher.sanitize_url_for_log(webhook_url));

        AuthMiddleware.send_success(msg, "{\"webhook_url\":\"%s\",\"secret\":\"%s\"}".printf(
            escape_json(webhook_url), escape_json(secret)));
    }

    // --- POST /bot/deleteWebhook ---
    private void handle_delete_webhook(Soup.Server srv, Soup.ServerMessage msg,
                                       string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "webhook")) return;

        registry.set_webhook(bot.id, null, null, false);
        registry.log_action(bot.id, "webhook_deleted");
        AuthMiddleware.send_success(msg, "true");
    }

    // --- POST /bot/sendFile ---
    private void handle_send_file(Soup.Server srv, Soup.ServerMessage msg,
                                  string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "file_send")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        string? to_jid = json_get_string(body, "to");
        string? file_url = json_get_string(body, "url");
        string? caption = json_get_string(body, "caption");
        if (reject_invalid_string_members(msg, body, new string[] { "to", "url", "caption" }, "file")) return;

        if (to_jid == null || to_jid.strip() == "" || file_url == null || !is_http_url(file_url.strip())) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: to, url");
            return;
        }
        string target_jid = to_jid.strip();
        string target_url = file_url.strip();
        if (reject_invalid_jid(msg, target_jid, "to")) return;
        if (!require_target(msg, bot, target_jid)) return;

        // Send file URL as an out-of-band message (XEP-0066 style)
        string? message_id = message_router.send_file(bot, target_jid, target_url, caption);
        if (message_id != null) {
            AuthMiddleware.send_success(msg, "{\"message_id\":\"%s\"}".printf(escape_json(message_id)));
        } else {
            AuthMiddleware.send_error(msg, 500, "send_failed", "Failed to send file");
        }
    }

    // --- POST /bot/setCommands ---
    private void handle_set_commands(Soup.Server srv, Soup.ServerMessage msg,
                                     string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "admin")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        // Parse commands array from JSON
        var commands = parse_commands_array(body);
        if (commands == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid 'commands' array");
            return;
        }

        registry.set_bot_commands(bot.id, commands);
        AuthMiddleware.send_success(msg, "true");
    }

    // --- GET /bot/getCommands ---
    private void handle_get_commands(Soup.Server srv, Soup.ServerMessage msg,
                                     string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }
        if (!require_permission(msg, bot, "receive_updates")) return;

        var commands = registry.get_bot_commands(bot.id);
        var sb = new StringBuilder("[");
        bool first = true;
        foreach (CommandInfo cmd in commands) {
            if (!first) sb.append(",");
            sb.append("{\"command\":\"%s\",\"description\":\"%s\"}".printf(
                escape_json(cmd.command),
                escape_json(cmd.description ?? "")
            ));
            first = false;
        }
        sb.append("]");
        AuthMiddleware.send_success(msg, sb.str);
    }

    // --- POST /bot/joinRoom ---
    private void handle_join_room(Soup.Server srv, Soup.ServerMessage msg,
                                  string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "muc_join")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        string? room_jid = json_get_string(body, "room");
        string? nick = json_get_string(body, "nick");
        if (reject_invalid_string_members(msg, body, new string[] { "room", "nick" }, "room join")) return;
        if (room_jid == null || room_jid.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: room");
            return;
        }
        if (reject_invalid_jid(msg, room_jid, "room")) return;
        if (!require_target(msg, bot, room_jid.strip())) return;
        string? clean_nick = nick != null && nick.strip() != "" ? nick.strip() : null;
        msg.pause();
        do_join_room.begin(msg, bot, room_jid.strip(), clean_nick);
    }

    private async void do_join_room(Soup.ServerMessage msg, BotInfo bot, string room_jid, string? nick) {
        bool result = yield message_router.join_room(bot, room_jid, nick);
        if (result) {
            if (bot.mode == "dedicated") {
                BotUtils.remember_muc_room(registry, bot.id, room_jid, nick ?? bot.name ?? "");
            }
            AuthMiddleware.send_success(msg, "true");
        } else {
            AuthMiddleware.send_error(msg, 500, "join_failed", "Failed to join room");
        }
        msg.unpause();
    }

    // --- POST /bot/leaveRoom ---
    private void handle_leave_room(Soup.Server srv, Soup.ServerMessage msg,
                                   string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "muc_join")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        string? room_jid = json_get_string(body, "room");
        if (reject_invalid_string_members(msg, body, new string[] { "room" }, "room leave")) return;
        if (room_jid == null || room_jid.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: room");
            return;
        }
        if (reject_invalid_jid(msg, room_jid, "room")) return;
        if (!require_target(msg, bot, room_jid.strip())) return;
        bool result = message_router.leave_room(bot, room_jid.strip());
        if (result) {
            if (bot.mode == "dedicated") {
                BotUtils.forget_muc_room(registry, bot.id, room_jid.strip());
            }
            AuthMiddleware.send_success(msg, "true");
        } else {
            AuthMiddleware.send_error(msg, 500, "leave_failed", "Failed to leave room");
        }
    }

    // --- POST /bot/sendReaction ---
    private void handle_send_reaction(Soup.Server srv, Soup.ServerMessage msg,
                                      string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "send_message")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        string? to_jid = json_get_string(body, "to");
        string? message_id = json_get_string(body, "message_id");
        string? reaction = json_get_string(body, "reaction");
        if (reject_invalid_string_members(msg, body,
                new string[] { "to", "message_id", "reaction" },
                "reaction")) {
            return;
        }

        if (to_jid == null || to_jid.strip() == "" ||
            message_id == null || message_id.strip() == "" ||
            reaction == null || reaction.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: to, message_id, reaction");
            return;
        }
        if (reject_invalid_jid(msg, to_jid, "to")) return;
        if (!require_target(msg, bot, to_jid.strip())) return;

        bool result = message_router.send_reaction(bot, to_jid.strip(), message_id.strip(), reaction.strip());
        if (result) {
            AuthMiddleware.send_success(msg, "true");
        } else {
            AuthMiddleware.send_error(msg, 500, "reaction_failed", "Failed to send reaction");
        }
    }

    // --- GET /bot/getInfo ---
    private void handle_get_info(Soup.Server srv, Soup.ServerMessage msg,
                                 string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }

        var commands = registry.get_bot_commands(bot.id);
        var sb = new StringBuilder();
        sb.append("{");
        sb.append("\"bot\":%s,".printf(bot_to_json(bot)));
        sb.append("\"commands\":[");
        bool first = true;
        foreach (CommandInfo cmd in commands) {
            if (!first) sb.append(",");
            sb.append("{\"command\":\"%s\",\"description\":\"%s\"}".printf(
                escape_json(cmd.command),
                escape_json(cmd.description ?? "")
            ));
            first = false;
        }
        sb.append("],\"active_sessions\":%d".printf(0));
        sb.append("}");

        AuthMiddleware.send_success(msg, sb.str);
    }

    // ════════════════════════════════════════════════════════════
    // Telegram API Endpoints
    // ════════════════════════════════════════════════════════════

    // --- POST /bot/telegram/setup --- Configure Telegram bridge
    private void handle_telegram_setup(Soup.Server srv, Soup.ServerMessage msg,
                                       string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "admin")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid JSON body. Example: {\"token\":\"123:ABC\",\"chat_id\":\"987654321\",\"mode\":\"bridge\"}");
            return;
        }

        string? tg_token = json_get_string(body, "token");
        string? chat_id = json_get_string(body, "chat_id");
        string? mode = json_get_string(body, "mode");
        if (reject_invalid_string_members(msg, body,
                new string[] { "token", "chat_id", "mode" },
                "telegram setup")) {
            return;
        }
        if (mode == null) mode = "bridge";

        if (tg_token == null || tg_token.strip() == "" || chat_id == null || chat_id.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: token, chat_id");
            return;
        }
        tg_token = tg_token.strip();
        chat_id = chat_id.strip();
        mode = mode.strip().ascii_down();

        if (!BotUtils.is_valid_telegram_mode(mode)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid mode. Must be: bridge or forward");
            return;
        }

        configure_telegram_bridge(bot, tg_token, chat_id, mode, true);
        start_telegram_polling_if_updates_allowed(bot);
        registry.log_action(bot.id, "telegram_setup", "chat_id=%s mode=%s via=http".printf(chat_id, mode));

        string json = "{\"configured\":true,\"chat_id\":\"%s\",\"mode\":\"%s\"}".printf(
            escape_json(chat_id), escape_json(mode));
        AuthMiddleware.send_success(msg, json);
    }

    // --- GET /bot/telegram/status --- Get Telegram bridge status
    private void handle_telegram_status(Soup.Server srv, Soup.ServerMessage msg,
                                        string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }
        if (!require_permission(msg, bot, "receive_updates")) return;

        AuthMiddleware.send_success(msg, telegram_status_json(bot));
    }

    // --- POST /bot/telegram/enable --- Enable or disable Telegram bridge
    private void handle_telegram_enable(Soup.Server srv, Soup.ServerMessage msg,
                                        string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "admin")) return;

        var body = get_request_body(msg);
        bool new_enabled = false;
        if (body == null || !get_bool_member(body, "enabled", out new_enabled)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: enabled (true/false)");
            return;
        }

        if (new_enabled) {
            string? token = registry.get_secret_setting("bot_%d_tg_token".printf(bot.id));
            if (token == null) {
                AuthMiddleware.send_error(msg, 400, "not_configured",
                    "Telegram not configured. Use /bot/telegram/setup first.");
                return;
            }
            registry.set_setting("bot_%d_tg_enabled".printf(bot.id), "true");
            start_telegram_polling_if_updates_allowed(bot);
        } else {
            disable_telegram_bridge(bot.id);
        }

        registry.log_action(bot.id, new_enabled ? "telegram_enabled" : "telegram_disabled", "via=http");
        string json = "{\"enabled\":%s}".printf(new_enabled ? "true" : "false");
        AuthMiddleware.send_success(msg, json);
    }

    // --- POST /bot/telegram/send --- Send a message to Telegram
    private void handle_telegram_send(Soup.Server srv, Soup.ServerMessage msg,
                                      string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "send_message")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid JSON body");
            return;
        }

        string? text = json_get_string(body, "text");
        if (reject_invalid_string_members(msg, body, new string[] { "text" }, "telegram send")) return;
        if (text == null || text.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: text");
            return;
        }

        if (!message_router.telegram.is_enabled(bot.id)) {
            AuthMiddleware.send_error(msg, 400, "not_enabled", "Telegram bridge is not enabled for this bot");
            return;
        }

        msg.pause();
        do_telegram_send.begin(msg, bot, text.strip());
    }

    private async void do_telegram_send(Soup.ServerMessage msg, BotInfo bot, string text) {
        bool ok = yield message_router.telegram.forward_to_telegram(bot.id, "API", text);
        if (ok) {
            AuthMiddleware.send_success(msg, "{\"sent\":true}");
        } else {
            AuthMiddleware.send_error(msg, 500, "send_failed", "Failed to send message to Telegram");
        }
        msg.unpause();
    }

    // --- POST /bot/telegram/test --- Test Telegram connection
    private void handle_telegram_test(Soup.Server srv, Soup.ServerMessage msg,
                                      string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "admin")) return;

        msg.pause();
        do_telegram_test.begin(msg, bot);
    }

    private async void do_telegram_test(Soup.ServerMessage msg, BotInfo bot) {
        ApiResult result = yield message_router.telegram.test_connection_result(bot.id);
        if (result.success) {
            AuthMiddleware.send_success(msg, "{\"connected\":true,\"info\":\"%s\"}".printf(
                escape_json(result.response_body ?? "ok")));
        } else {
            AuthMiddleware.send_error(msg, 502, "connection_failed", result.error_message ?? "Unknown error");
        }
        msg.unpause();
    }

    // --- GET/POST /bot/telegram/manage --- (local Bot Manager management endpoint)
    private void handle_telegram_management(Soup.Server srv, Soup.ServerMessage msg,
                                            string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() == "GET") {
            string? id_str = query != null ? query.lookup("id") : null;
            if (id_str == null) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing ?id= parameter");
                return;
            }
            int bot_id = 0;
            if (!parse_positive_int(id_str, out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid bot id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            AuthMiddleware.send_success(msg, telegram_status_json(bot));
            return;
        }

        if (msg.get_method() == "POST") {
            var body = get_request_body(msg);
            int bot_id = 0;
            if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string? tg_token = json_get_string(body, "token");
            string? chat_id = json_get_string(body, "chat_id");
            string? mode = json_get_string(body, "mode");
            if (reject_invalid_string_members(msg, body,
                    new string[] { "token", "chat_id", "mode" },
                    "telegram management")) {
                return;
            }

            bool has_enabled = body.has_member("enabled");
            bool new_enabled = false;
            if (has_enabled && !get_bool_member(body, "enabled", out new_enabled)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Telegram enabled field must be a boolean");
                return;
            }

            bool has_setup = (tg_token != null && tg_token.strip() != "") ||
                             (chat_id != null && chat_id.strip() != "") ||
                             (mode != null && mode.strip() != "");
            if (has_setup) {
                string? stored_token = registry.get_secret_setting("bot_%d_tg_token".printf(bot.id));
                string? stored_chat_id = registry.get_setting("bot_%d_tg_chat_id".printf(bot.id));
                string? stored_mode = registry.get_setting("bot_%d_tg_mode".printf(bot.id));

                string final_token = tg_token != null && tg_token.strip() != "" ? tg_token.strip() : (stored_token ?? "");
                string final_chat_id = chat_id != null && chat_id.strip() != "" ? chat_id.strip() : (stored_chat_id ?? "");
                string final_mode = mode != null && mode.strip() != "" ? mode.strip().ascii_down() : (stored_mode ?? "bridge");

                if (final_token == "" || final_chat_id == "") {
                    AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: token, chat_id");
                    return;
                }
                if (!BotUtils.is_valid_telegram_mode(final_mode)) {
                    AuthMiddleware.send_error(msg, 400, "bad_request", "Invalid mode. Must be: bridge or forward");
                    return;
                }

                configure_telegram_bridge(bot, final_token, final_chat_id, final_mode, false);
                registry.log_action(bot.id, "telegram_setup", "chat_id=%s mode=%s via=local-ui".printf(final_chat_id, final_mode));
            }

            if (has_enabled) {
                if (new_enabled) {
                    string? stored_token = registry.get_secret_setting("bot_%d_tg_token".printf(bot.id));
                    if (stored_token == null) {
                        AuthMiddleware.send_error(msg, 400, "not_configured", "Telegram not configured");
                        return;
                    }
                    registry.set_setting("bot_%d_tg_enabled".printf(bot.id), "true");
                    start_telegram_polling_if_updates_allowed(bot);
                } else {
                    disable_telegram_bridge(bot.id);
                }
                registry.log_action(bot.id, new_enabled ? "telegram_enabled" : "telegram_disabled", "via=local-ui");
            } else if (has_setup && is_telegram_bridge_enabled(bot.id)) {
                start_telegram_polling_if_updates_allowed(bot);
            }

            AuthMiddleware.send_success(msg, telegram_status_json(bot));
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    private void configure_telegram_bridge(BotInfo bot, string token, string chat_id, string mode, bool enable_telegram) {
        string prefix = "bot_%d_tg".printf(bot.id);
        if (enable_telegram) {
            registry.set_setting(prefix + "_enabled", "true");
        }
        registry.set_secret_setting(prefix + "_token", token);
        registry.set_setting(prefix + "_chat_id", chat_id);
        registry.set_setting(prefix + "_mode", mode);
        message_router.telegram.configure(bot.id, token, chat_id, mode, enable_telegram);
    }

    private void disable_telegram_bridge(int bot_id) {
        registry.set_setting("bot_%d_tg_enabled".printf(bot_id), "false");
        message_router.telegram.disable(bot_id);
    }

    private bool is_telegram_bridge_enabled(int bot_id) {
        return registry.get_setting("bot_%d_tg_enabled".printf(bot_id)) == "true";
    }

    // ════════════════════════════════════════════════════════════
    // AI API Endpoints
    // ════════════════════════════════════════════════════════════

    // --- POST /bot/ai/setup --- Configure AI provider
    private void handle_ai_setup(Soup.Server srv, Soup.ServerMessage msg,
                                 string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "admin")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid JSON body. Example: {\"provider\":\"openai\",\"api_key\":\"sk-...\",\"model\":\"gpt-4o\"}");
            return;
        }

        string? provider = json_get_string(body, "provider");
        string? api_key = json_get_string(body, "api_key");
        string? model = json_get_string(body, "model");
        if (reject_invalid_string_members(msg, body, new string[] { "provider", "api_key", "model" }, "ai setup")) return;

        if (provider == null || provider.strip() == "" || model == null || model.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: provider, model");
            return;
        }
        provider = provider.strip().ascii_down();
        model = model.strip();
        if (api_key == null) api_key = "-";
        api_key = api_key.strip();

        if (!message_router.ai.has_provider_preset(provider)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Unknown AI provider");
            return;
        }
        if (message_router.ai.provider_requires_api_key(provider) && (api_key == "" || api_key == "-")) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "api_key is required for this provider");
            return;
        }

        configure_ai_preset(bot, provider, api_key, model, true);
        registry.log_action(bot.id, "ai_setup", "provider=%s model=%s via=http".printf(provider, model));

        AuthMiddleware.send_success(msg, "{\"configured\":true,\"provider\":\"%s\",\"model\":\"%s\"}".printf(
            escape_json(provider), escape_json(model)));
    }

    // --- GET /bot/ai/status --- Get AI config status
    private void handle_ai_status(Soup.Server srv, Soup.ServerMessage msg,
                                  string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;
        if (msg.get_method() != "GET") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET");
            return;
        }
        if (!require_permission(msg, bot, "receive_updates")) return;

        AuthMiddleware.send_success(msg, ai_status_json(bot));
    }

    // --- POST /bot/ai/enable --- Enable or disable AI
    private void handle_ai_enable(Soup.Server srv, Soup.ServerMessage msg,
                                  string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "admin")) return;

        var body = get_request_body(msg);
        bool new_enabled = false;
        if (body == null || !get_bool_member(body, "enabled", out new_enabled)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: enabled (true/false)");
            return;
        }

        if (new_enabled) {
            string? endpoint = registry.get_setting("bot_%d_ai_endpoint".printf(bot.id));
            if (endpoint == null) {
                AuthMiddleware.send_error(msg, 400, "not_configured",
                    "AI not configured. Use /bot/ai/setup first.");
                return;
            }
            registry.set_setting("bot_%d_ai_enabled".printf(bot.id), "true");
        } else {
            disable_ai_integration(bot.id);
        }

        registry.log_action(bot.id, new_enabled ? "ai_enabled" : "ai_disabled", "via=http");
        string json = "{\"enabled\":%s}".printf(new_enabled ? "true" : "false");
        AuthMiddleware.send_success(msg, json);
    }

    // --- POST /bot/ai/ask --- Send a question to the AI
    private void handle_ai_ask(Soup.Server srv, Soup.ServerMessage msg,
                               string path, HashTable<string, string>? query) {
        BotInfo? bot = auth.authenticate(msg);
        if (bot == null) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }
        if (!require_permission(msg, bot, "send_message")) return;

        var body = get_request_body(msg);
        if (body == null) {
            AuthMiddleware.send_error(msg, 400, "bad_request",
                "Invalid JSON body. Example: {\"message\":\"Hello, how are you?\"}");
            return;
        }

        string? question = json_get_string(body, "message");
        if (question == null) question = json_get_string(body, "text");
        if (reject_invalid_string_members(msg, body, new string[] { "message", "text" }, "ai ask")) return;
        if (question == null || question.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: message");
            return;
        }

        if (!is_ai_integration_enabled(bot.id)) {
            AuthMiddleware.send_error(msg, 400, "not_enabled", "AI is not enabled for this bot");
            return;
        }

        string from = "api-client";
        if (query != null && query.contains("from")) {
            from = query.get("from");
        }

        msg.pause();
        do_ai_ask.begin(msg, bot, from, question.strip());
    }

    private async void do_ai_ask(Soup.ServerMessage msg, BotInfo bot, string from, string question) {
        string? answer = yield message_router.ai.ask(bot.id, from, question);
        if (answer != null) {
            AuthMiddleware.send_success(msg, "{\"response\":\"%s\"}".printf(escape_json(answer)));
        } else {
            AuthMiddleware.send_error(msg, 500, "ai_error", "AI returned no response");
        }
        msg.unpause();
    }

    // --- POST /bot/ai/testAsk --- (local Bot Manager AI console, no raw token required)
    private void handle_ai_test_ask(Soup.Server srv, Soup.ServerMessage msg,
                                    string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() != "POST") {
            AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use POST");
            return;
        }

        var body = get_request_body(msg);
        int bot_id = 0;
        if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
            return;
        }
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null) {
            AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
            return;
        }
        if (!require_local_bot_runtime_allowed(msg, bot)) return;

        string? question = json_get_string(body, "message");
        if (question == null) question = json_get_string(body, "text");
        if (reject_invalid_string_members(msg, body, new string[] { "message", "text" }, "ai test ask")) return;
        if (question == null || question.strip() == "") {
            AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required field: message");
            return;
        }
        if (!is_ai_integration_enabled(bot.id)) {
            AuthMiddleware.send_error(msg, 400, "not_enabled", "AI is not enabled for this bot");
            return;
        }

        msg.pause();
        do_ai_test_ask.begin(msg, bot, question.strip());
    }

    private async void do_ai_test_ask(Soup.ServerMessage msg, BotInfo bot, string question) {
        string? answer = yield message_router.ai.ask(bot.id, "local-ui", question);
        if (answer != null) {
            AuthMiddleware.send_success(msg, "{\"response\":\"%s\"}".printf(escape_json(answer)));
        } else {
            AuthMiddleware.send_error(msg, 500, "ai_error", "AI returned no response");
        }
        msg.unpause();
    }

    // --- GET/POST /bot/ai/manage --- (local Bot Manager management endpoint)
    private void handle_ai_management(Soup.Server srv, Soup.ServerMessage msg,
                                      string path, HashTable<string, string>? query) {
        if (!require_localhost(msg)) return;

        if (msg.get_method() == "GET") {
            string? id_str = query != null ? query.lookup("id") : null;
            int bot_id = 0;
            if (id_str == null || !parse_positive_int(id_str, out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid bot id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }
            AuthMiddleware.send_success(msg, ai_status_json(bot));
            return;
        }

        if (msg.get_method() == "POST") {
            var body = get_request_body(msg);
            int bot_id = 0;
            if (body == null || !get_positive_int_member(body, "id", out bot_id)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "Missing or invalid required field: id");
                return;
            }
            BotInfo? bot = registry.get_bot_by_id(bot_id);
            if (bot == null) {
                AuthMiddleware.send_error(msg, 404, "not_found", "Bot not found");
                return;
            }

            string? provider = json_get_string(body, "provider");
            string? api_key = json_get_string(body, "api_key");
            string? model = json_get_string(body, "model");
            string? system_prompt = json_get_string(body, "system_prompt");
            string? muc_owner_notify = json_get_string(body, "muc_owner_notify");
            string? muc_ai_mode = json_get_string(body, "muc_ai_mode");
            if (reject_invalid_string_members(msg, body,
                    new string[] { "provider", "api_key", "model", "system_prompt", "muc_owner_notify", "muc_ai_mode" },
                    "ai management")) {
                return;
            }

            bool has_enabled = body.has_member("enabled");
            bool new_enabled = false;
            if (has_enabled && !get_bool_member(body, "enabled", out new_enabled)) {
                AuthMiddleware.send_error(msg, 400, "bad_request", "AI enabled field must be a boolean");
                return;
            }

            string? notify_mode = null;
            if (muc_owner_notify != null) {
                notify_mode = muc_owner_notify.strip();
                if (notify_mode != "off" && notify_mode != "mentions" && notify_mode != "mentions_when_owner_absent") {
                    AuthMiddleware.send_error(msg, 400, "bad_request",
                        "Invalid muc_owner_notify. Must be: off, mentions, or mentions_when_owner_absent");
                    return;
                }
            }

            string? reply_mode = null;
            if (muc_ai_mode != null) {
                reply_mode = muc_ai_mode.strip();
                if (!BotUtils.is_valid_muc_ai_mode(reply_mode)) {
                    AuthMiddleware.send_error(msg, 400, "bad_request",
                        "Invalid muc_ai_mode. Must be: mention_only, support_questions, or active_support");
                    return;
                }
            }

            bool has_setup = (provider != null && provider.strip() != "") ||
                             (api_key != null && api_key.strip() != "") ||
                             (model != null && model.strip() != "");
            if (has_setup) {
                string final_provider = provider != null && provider.strip() != ""
                    ? provider.strip().ascii_down()
                    : (registry.get_setting("bot_%d_ai_provider".printf(bot.id)) ?? registry.get_setting("bot_%d_ai_type".printf(bot.id)) ?? "");
                string final_model = model != null && model.strip() != ""
                    ? model.strip()
                    : (registry.get_setting("bot_%d_ai_model".printf(bot.id)) ?? "");
                string final_key = api_key != null && api_key.strip() != ""
                    ? api_key.strip()
                    : (registry.get_secret_setting("bot_%d_ai_key".printf(bot.id)) ?? "");

                if (final_provider == "" || final_model == "") {
                    AuthMiddleware.send_error(msg, 400, "bad_request", "Missing required fields: provider, model");
                    return;
                }
                if (!message_router.ai.has_provider_preset(final_provider)) {
                    AuthMiddleware.send_error(msg, 400, "bad_request", "Unknown AI provider");
                    return;
                }
                if (message_router.ai.provider_requires_api_key(final_provider) && (final_key == "" || final_key == "-")) {
                    AuthMiddleware.send_error(msg, 400, "bad_request", "api_key is required for this provider");
                    return;
                }
                if (!message_router.ai.provider_requires_api_key(final_provider)) {
                    final_key = "-";
                }

                configure_ai_preset(bot, final_provider, final_key == "" ? "-" : final_key, final_model, false);
                registry.log_action(bot.id, "ai_setup", "provider=%s model=%s via=local-ui".printf(final_provider, final_model));
            }

            if (system_prompt != null) {
                string prompt = system_prompt.strip();
                if (prompt == "") {
                    registry.delete_setting("bot_%d_ai_system".printf(bot.id));
                    registry.log_action(bot.id, "ai_system_reset", "via=local-ui");
                } else {
                    registry.set_setting("bot_%d_ai_system".printf(bot.id), prompt);
                    registry.log_action(bot.id, "ai_system_updated", "via=local-ui");
                }
            }

            if (notify_mode != null) {
                if (notify_mode == "off") {
                    registry.delete_setting("bot_%d_muc_owner_notify".printf(bot.id));
                } else {
                    registry.set_setting("bot_%d_muc_owner_notify".printf(bot.id), notify_mode);
                }
                registry.log_action(bot.id, "muc_owner_notify_updated", "mode=%s via=local-ui".printf(notify_mode));
            }

            if (reply_mode != null) {
                if (reply_mode == "mention_only") {
                    registry.delete_setting("bot_%d_muc_ai_mode".printf(bot.id));
                } else {
                    registry.set_setting("bot_%d_muc_ai_mode".printf(bot.id), reply_mode);
                }
                registry.log_action(bot.id, "muc_ai_mode_updated", "mode=%s via=local-ui".printf(reply_mode));
            }

            if (has_enabled) {
                if (new_enabled) {
                    string? endpoint = registry.get_setting("bot_%d_ai_endpoint".printf(bot.id));
                    if (endpoint == null) {
                        AuthMiddleware.send_error(msg, 400, "not_configured", "AI not configured");
                        return;
                    }
                    registry.set_setting("bot_%d_ai_enabled".printf(bot.id), "true");
                } else {
                    disable_ai_integration(bot.id);
                }
                registry.log_action(bot.id, new_enabled ? "ai_enabled" : "ai_disabled", "via=local-ui");
            }

            AuthMiddleware.send_success(msg, ai_status_json(bot));
            return;
        }

        AuthMiddleware.send_error(msg, 405, "method_not_allowed", "Use GET or POST");
    }

    private void configure_ai_preset(BotInfo bot, string provider, string api_key, string model, bool enable_ai) {
        string normalized = provider.strip().ascii_down();
        string ai_type = message_router.ai.provider_ai_type(normalized) ?? normalized;
        string endpoint = message_router.ai.provider_endpoint(normalized) ?? "";
        string prefix = "bot_%d_ai".printf(bot.id);
        if (enable_ai) {
            registry.set_setting(prefix + "_enabled", "true");
        }
        registry.set_setting(prefix + "_provider", normalized);
        registry.set_setting(prefix + "_type", ai_type);
        registry.set_setting(prefix + "_endpoint", endpoint);
        registry.set_secret_setting(prefix + "_key", api_key == "-" ? "" : api_key);
        registry.set_setting(prefix + "_model", model);
        message_router.ai.configure_preset(bot.id, normalized, api_key, model, enable_ai);
    }

    private void disable_ai_integration(int bot_id) {
        registry.set_setting("bot_%d_ai_enabled".printf(bot_id), "false");
        message_router.ai.disable(bot_id);
    }

    private bool is_ai_integration_enabled(int bot_id) {
        return registry.get_setting("bot_%d_ai_enabled".printf(bot_id)) == "true";
    }

    // --- JSON Helpers ---

    private string bot_to_json(BotInfo bot) {
        var sb = new StringBuilder();
        sb.append("{\"id\":%d".printf(bot.id));
        sb.append(",\"name\":\"%s\"".printf(escape_json(bot.name ?? "")));
        sb.append(",\"jid\":\"%s\"".printf(escape_json(bot.jid ?? "")));
        sb.append(",\"mode\":\"%s\"".printf(escape_json(bot.mode ?? "personal")));
        sb.append(",\"purpose\":\"%s\"".printf(escape_json(bot_purpose_for_bot(bot))));
        if (bot.mode == "dedicated") {
            sb.append(",\"provisioning\":\"%s\"".printf(escape_json(dedicated_provisioning_for_bot(bot))));
        }
        sb.append(",\"status\":\"%s\"".printf(escape_json(bot.status ?? "active")));
        sb.append(",\"permissions\":\"%s\"".printf(escape_json(normalize_permissions(bot.permissions))));
        string targets = normalize_targets(registry.get_setting(target_setting_key(bot.id)));
        string mode = normalize_target_mode(registry.get_setting(target_mode_setting_key(bot.id)), targets);
        sb.append(",\"target_mode\":\"%s\"".printf(escape_json(mode)));
        sb.append(",\"target_list\":\"%s\"".printf(escape_json(targets)));
        sb.append(",\"allowed_targets\":\"%s\"".printf(escape_json(targets)));
        sb.append(",\"webhook_enabled\":%s".printf(bot.webhook_enabled ? "true" : "false"));
        sb.append(",\"webhook_url\":\"%s\"".printf(escape_json(bot.webhook_url ?? "")));
        string? avatar = registry.get_setting("bot_avatar:%d".printf(bot.id));
        string? avatar_type = registry.get_setting("bot_avatar_type:%d".printf(bot.id));
        sb.append(",\"avatar_configured\":%s".printf(avatar != null && avatar != "" ? "true" : "false"));
        sb.append(",\"avatar_type\":\"%s\"".printf(escape_json(avatar_type ?? "")));
        sb.append(",\"telegram\":%s".printf(telegram_status_json(bot)));
        sb.append(",\"ai\":%s".printf(ai_status_json(bot)));
        sb.append(",\"muc_rooms\":\"%s\"".printf(escape_json(muc_rooms_summary(bot.id))));
        sb.append(",\"muc_rooms_list\":%s".printf(muc_rooms_json(bot.id)));
        sb.append(",\"description\":\"%s\"".printf(escape_json(bot.description ?? "")));
        sb.append(",\"created_at\":%ld".printf(bot.created_at));
        // BUG-02 fix: Never expose token_raw in list responses
        sb.append("}");
        return sb.str;
    }

    private string telegram_status_json(BotInfo bot) {
        bool enabled = is_telegram_bridge_enabled(bot.id);
        string? chat_id = registry.get_setting("bot_%d_tg_chat_id".printf(bot.id));
        string? mode = registry.get_setting("bot_%d_tg_mode".printf(bot.id));
        bool configured = registry.get_secret_setting("bot_%d_tg_token".printf(bot.id)) != null;

        return "{\"enabled\":%s,\"configured\":%s,\"chat_id\":\"%s\",\"mode\":\"%s\"}".printf(
            enabled ? "true" : "false",
            configured ? "true" : "false",
            escape_json(chat_id ?? ""),
            escape_json(mode ?? "bridge"));
    }

    private string ai_status_json(BotInfo bot) {
        string prefix = "bot_%d_ai".printf(bot.id);
        bool enabled = registry.get_setting(prefix + "_enabled") == "true";
        string? provider = registry.get_setting(prefix + "_provider");
        string? ai_type = registry.get_setting(prefix + "_type");
        string? model = registry.get_setting(prefix + "_model");
        string? endpoint = registry.get_setting(prefix + "_endpoint");
        string? system_prompt = registry.get_setting(prefix + "_system");
        string? muc_owner_notify = registry.get_setting("bot_%d_muc_owner_notify".printf(bot.id)) ?? "off";
        string? muc_ai_mode = registry.get_setting("bot_%d_muc_ai_mode".printf(bot.id)) ?? "mention_only";
        bool configured = endpoint != null;

        return "{\"enabled\":%s,\"configured\":%s,\"provider\":\"%s\",\"type\":\"%s\",\"model\":\"%s\",\"endpoint\":\"%s\",\"system_prompt\":\"%s\",\"muc_owner_notify\":\"%s\",\"muc_ai_mode\":\"%s\"}".printf(
            enabled ? "true" : "false",
            configured ? "true" : "false",
            escape_json(provider ?? ""),
            escape_json(ai_type ?? ""),
            escape_json(model ?? ""),
            escape_json(endpoint ?? ""),
            escape_json(system_prompt ?? ""),
            escape_json(muc_owner_notify),
            escape_json(muc_ai_mode));
    }

    private string muc_rooms_summary(int bot_id) {
        var rooms = BotUtils.get_muc_rooms(registry, bot_id);
        var values = new Gee.ArrayList<string>();
        foreach (BotUtils.BotMucRoom room in rooms) {
            values.add(room.nick != "" ? "%s (%s)".printf(room.room_jid, room.nick) : room.room_jid);
        }
        return BotUtils.join_strings(", ", values);
    }

    private string muc_rooms_json(int bot_id) {
        var rooms = BotUtils.get_muc_rooms(registry, bot_id);
        var sb = new StringBuilder();
        sb.append("[");
        bool first = true;
        foreach (BotUtils.BotMucRoom room in rooms) {
            if (!first) sb.append(",");
            sb.append("{\"room\":\"%s\",\"nick\":\"%s\"}".printf(
                escape_json(room.room_jid), escape_json(room.nick)));
            first = false;
        }
        sb.append("]");
        return sb.str;
    }

    private string get_base_api_url() {
        string scheme = current_mode == "network" ? "https" : "http";
        return "%s://localhost:%u/bot/".printf(scheme, current_port);
    }

    private bool is_http_url(string url) {
        try {
            Uri uri = Uri.parse(url, UriFlags.NONE);
            string? scheme = uri.get_scheme();
            string? host = uri.get_host();
            return (scheme == "http" || scheme == "https") && host != null && host.strip() != "";
        } catch (Error e) {
            return false;
        }
    }

    private bool is_local_webhook_url(string url) {
        if (!is_http_url(url)) return false;
        return !is_cloudbot_management_url(url);
    }

    private bool is_cloudbot_management_url(string url) {
        try {
            Uri uri = Uri.parse(url, UriFlags.NONE);
            string? host = uri.get_host();
            string path = uri.get_path();
            return host != null
                && host.ascii_down() == "cloud.dinox.im"
                && path.has_prefix("/api/v1/bot");
        } catch (Error e) {
            return false;
        }
    }

    private bool is_valid_message_type(string msg_type) {
        return msg_type == "chat" || msg_type == "groupchat";
    }

    // Simple JSON parser - extract string value by key from JSON body
    private Json.Object? get_request_body(Soup.ServerMessage msg) {
        var body = msg.get_request_body();
        if (body == null) return null;
        Bytes? bytes = body.flatten();
        if (bytes == null || bytes.get_size() == 0) return null;

        unowned uint8[] raw = bytes.get_data();
        if (request_json_contains_nul(raw)) return null;

        try {
            var parser = new Json.Parser();
            parser.load_from_data((string) raw, (ssize_t) raw.length);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
            return root.get_object();
        } catch (Error e) {
            return null;
        }
    }

    private static bool request_json_contains_nul(uint8[] raw) {
        bool in_string = false;
        int backslash_run = 0;

        for (int i = 0; i < raw.length; i++) {
            uint8 current = raw[i];
            if (current == 0) return true;

            if (!in_string) {
                if (current == '"') {
                    in_string = true;
                    backslash_run = 0;
                }
                continue;
            }

            if (current == '\\') {
                backslash_run++;
                continue;
            }

            bool escaped = (backslash_run % 2) == 1;
            if (current == 'u' && escaped && i + 4 < raw.length &&
                    raw[i + 1] == '0' && raw[i + 2] == '0' &&
                    raw[i + 3] == '0' && raw[i + 4] == '0') {
                return true;
            }

            if (current == '"' && !escaped) in_string = false;
            backslash_run = 0;
        }

        return false;
    }

    private string? json_get_string(Json.Object obj, string key) {
        if (!obj.has_member(key)) return null;
        var node = obj.get_member(key);
        if (node.get_node_type() != Json.NodeType.VALUE) return null;
        if (node.get_value_type() != typeof(string)) return null;
        return node.get_string();
    }

    private bool has_invalid_string_member(Json.Object obj, string key) {
        return obj.has_member(key) && json_get_string(obj, key) == null;
    }

    private bool reject_invalid_string_members(Soup.ServerMessage msg, Json.Object obj, string[] keys, string context) {
        foreach (string key in keys) {
            if (has_invalid_string_member(obj, key)) {
                AuthMiddleware.send_error(msg, 400, "bad_request",
                    "%s fields must be strings".printf(context));
                return true;
            }
        }
        return false;
    }

    private bool get_positive_int_member(Json.Object obj, string key, out int value) {
        value = 0;
        if (!obj.has_member(key)) return false;
        var node = obj.get_member(key);
        if (node.get_node_type() != Json.NodeType.VALUE) return false;
        if (node.get_value_type() != typeof(int64)) return false;
        int64 raw = node.get_int();
        if (raw < 1 || raw > 2147483647) return false;
        value = (int) raw;
        return true;
    }

    private bool get_bool_member(Json.Object obj, string key, out bool value) {
        value = false;
        if (!obj.has_member(key)) return false;
        var node = obj.get_member(key);
        if (node.get_node_type() != Json.NodeType.VALUE) return false;
        if (node.get_value_type() != typeof(bool)) return false;
        value = node.get_boolean();
        return true;
    }

    private bool parse_positive_int(string? raw, out int value) {
        if (!parse_nonnegative_int(raw, out value)) return false;
        return value > 0;
    }

    private bool parse_nonnegative_int(string? raw, out int value) {
        value = 0;
        if (raw == null) return false;

        string text = raw.strip();
        if (text == "") return false;
        if (text.length > 10) return false;
        for (int i = 0; i < text.length; i++) {
            char c = text[i];
            if (c < '0' || c > '9') return false;
        }

        int64 parsed = int64.parse(text);
        if (parsed < 0 || parsed > 2147483647) return false;
        value = (int) parsed;
        return true;
    }

    private Gee.List<CommandInfo>? parse_commands_array(Json.Object obj) {
        if (!obj.has_member("commands")) return null;
        var node = obj.get_member("commands");
        if (node.get_node_type() != Json.NodeType.ARRAY) return null;

        var arr = node.get_array();
        var commands = new ArrayList<CommandInfo>();
        for (uint i = 0; i < arr.get_length(); i++) {
            var elem = arr.get_element(i);
            if (elem.get_node_type() != Json.NodeType.OBJECT) return null;
            var cmd_obj = elem.get_object();
            if (has_invalid_string_member(cmd_obj, "command") ||
                    has_invalid_string_member(cmd_obj, "description")) {
                return null;
            }
            string? command = json_get_string(cmd_obj, "command");
            string? description = json_get_string(cmd_obj, "description");
            if (command == null || command.strip() == "") return null;
            commands.add(new CommandInfo(command.strip(), description != null ? description.strip() : null));
        }
        return commands;
    }

    // Delegate to shared BotUtils (BUG-05 fix)
    private static string escape_json(string s) {
        return BotUtils.escape_json(s);
    }
}

}
