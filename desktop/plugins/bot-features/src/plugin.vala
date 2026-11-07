using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino.Plugins.BotFeatures {

public class Plugin : RootInterface, AccountRemovalProvider, Object {

    private const string CLOUD_BOT_BASE_URL = "https://cloud.dinox.im";

    public Dino.Application app;
    public string id { get { return "bot-features"; } }
    private BotRegistry? registry;
    private TokenManager? token_manager;
    private HttpServer? http_server;
    private SessionPool? session_pool;
    private MessageRouter? message_router;
    private WebhookDispatcher? webhook_dispatcher;
    private EjabberdApi? ejabberd_api;
    private Soup.Session? cloud_http;
    // Runtime ownership is independent of whether the HTTP bind succeeded.
    private bool runtime_active = false;
    private uint runtime_generation = 0;
    private uint cleanup_timeout_id = 0;
    private uint fix_conversations_timeout_id = 0;
    private uint connect_bots_timeout_id = 0;
    private uint legacy_conversations_timeout_id = 0;
    private ulong runtime_account_added_id = 0;
    private ulong subscription_request_id = 0;
    private ulong dedicated_ready_id = 0;
    private ulong bot_deleted_id = 0;
    private ulong account_toggled_id = 0;
    private ulong bot_status_changed_id = 0;
    private uint api_restart_timeout_id = 0;
    private bool feature_setting_watcher_connected = false;
    private bool api_setting_watchers_connected = false;
    private bool account_removal_handler_connected = false;
    private HashSet<int> local_only_dedicated_deletions = new HashSet<int>();
    private HashSet<string> explicit_account_removals = new HashSet<string>();

    public void registered(Dino.Application app) {
        this.app = app;
        app.plugin_registry.register_account_removal_provider(this);
        connect_account_removal_handler();
        connect_feature_setting_watcher();
        connect_api_setting_watchers();

        // Check if bot features are enabled in settings
        if (!app.settings.bot_features_enabled) {
            message("Botmother: Disabled in settings, skipping initialization");
            // Watch for setting changes to enable later
            connect_feature_setting_watcher();
            return;
        }

        initialize();
    }

    private void connect_feature_setting_watcher() {
        if (feature_setting_watcher_connected) return;
        app.settings.notify["bot-features-enabled"].connect(on_setting_changed);
        feature_setting_watcher_connected = true;
    }

    private void connect_api_setting_watchers() {
        if (api_setting_watchers_connected) return;
        app.settings.notify["api-mode"].connect(on_api_setting_changed);
        app.settings.notify["api-port"].connect(on_api_setting_changed);
        app.settings.notify["api-tls-cert"].connect(on_api_setting_changed);
        app.settings.notify["api-tls-key"].connect(on_api_setting_changed);
        api_setting_watchers_connected = true;
    }

    private void on_setting_changed() {
        if (app.settings.bot_features_enabled && !runtime_active) {
            initialize();
        } else if (!app.settings.bot_features_enabled) {
            shutdown();
        }
    }

    private bool runtime_is_current(uint generation) {
        return runtime_active && app.settings.bot_features_enabled &&
            runtime_generation == generation;
    }

    protected virtual SessionPool create_session_pool() {
        return new SessionPool(app);
    }

    private void initialize() {
        if (runtime_active || !app.settings.bot_features_enabled) return;

        // Account removal may already have opened the registry while disabled.
        // Reuse that database without creating a second connection.
        // Initialize core components
        string db_path = GLib.Path.build_filename(
            GLib.Environment.get_user_data_dir(), "dinox", "bot_registry.db"
        );
        try {
            if (registry == null) registry = new BotRegistry(db_path, app.db_key);
        } catch (Error e) {
            warning("Botmother: Failed to open bot registry: %s", e.message);
            return;
        }

        CertGen.init();
        token_manager = new TokenManager(registry);
        session_pool = create_session_pool();
        session_pool.set_registry(registry);

        // OMEMO manager for bot streams
        var bot_omemo = new BotOmemoManager(registry);
        session_pool.set_bot_omemo(bot_omemo);

        webhook_dispatcher = new WebhookDispatcher();
        message_router = new MessageRouter(app, registry, session_pool, webhook_dispatcher);
        http_server = new HttpServer(registry, token_manager, message_router, session_pool);
        ejabberd_api = new EjabberdApi(registry);
        message_router.set_ejabberd_api((!) ejabberd_api);
        runtime_active = true;
        uint generation = ++runtime_generation;

        // Start HTTP API on configured port and mode
        var app_settings = app.settings;
        uint16 port = (uint16) app_settings.api_port;
        string mode = app_settings.api_mode;
        string tls_cert = app_settings.api_tls_cert;
        string tls_key = app_settings.api_tls_key;
        try {
            http_server.start(port, mode, tls_cert, tls_key);
            if (mode == "network") {
                message("Botmother: HTTPS API running on 0.0.0.0:%u (TLS)", port);
            } else {
                message("Botmother: HTTP API running on localhost:%u", port);
            }
        } catch (Error e) {
            // If network mode fails (cert error etc.), fall back to localhost
            if (mode == "network") {
                warning("Botmother: Network mode failed (%s), falling back to localhost", e.message);
                try {
                    http_server.start(port, "local", "", "");
                    message("Botmother: HTTP API running on localhost:%u (fallback)", port);
                } catch (Error e2) {
                    warning("Botmother: Failed to start HTTP server: %s", e2.message);
                }
            } else {
                warning("Botmother: Failed to start HTTP server: %s", e.message);
            }
        }

        // Legacy migration only: older builds auto-opened/pinned a Botmother
        // self-chat for personal bots. Current personal bot management is UI/API
        // based, so startup must close leftovers instead of creating new chats.
        ensure_botmother_conversations();

        // Suppress subscription notifications for all known dedicated bot JIDs
        suppress_bot_subscriptions();

        // Clean up orphaned conversations after accounts are loaded (2s delay)
        cleanup_timeout_id = GLib.Timeout.add(2000, () => {
            if (!runtime_is_current(generation)) return Source.REMOVE;
            cleanup_timeout_id = 0;
            cleanup_orphaned_bot_conversations();
            return Source.REMOVE;
        });
        runtime_account_added_id = app.stream_interactor.account_added.connect((account) => {
            if (runtime_is_current(generation)) cleanup_orphaned_bot_conversations();
        });

        // Fix encryption + subscriptions for existing dedicated bot conversations
        // Run after accounts and conversations are loaded
        // BUG-10 fix: Single timer instead of duplicate 1s + 2.5s
        fix_conversations_timeout_id = GLib.Timeout.add(2500, () => {
            if (!runtime_is_current(generation)) return Source.REMOVE;
            fix_conversations_timeout_id = 0;
            fix_dedicated_bot_conversations();
            return Source.REMOVE;
        });

        // Connect dedicated bots after a short delay (so main accounts connect first)
        connect_bots_timeout_id = GLib.Timeout.add(5000, () => {
            if (!runtime_is_current(generation)) return Source.REMOVE;
            connect_bots_timeout_id = 0;
            if (session_pool != null) session_pool.connect_all_dedicated();
            return Source.REMOVE;
        });

        // When a dedicated bot is ready, set roster name and disable OMEMO
        dedicated_ready_id = session_pool.dedicated_bot_ready.connect((bot_id, bot) => {
            if (runtime_is_current(generation)) on_dedicated_bot_ready(bot_id, bot);
        });

        // Auto-approve subscription requests from dedicated bot JIDs
        var presence_mgr = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        subscription_request_id = presence_mgr.received_subscription_request.connect((jid, account) => {
            if (runtime_is_current(generation)) on_subscription_request(jid, account);
        });

        // When a bot is deleted, check if account has 0 bots left -> unpin
        bot_deleted_id = registry.bot_deleted.connect((owner, bot_id, jid, mode) => {
            if (runtime_is_current(generation)) on_bot_deleted(owner, bot_id, jid, mode);
        });

        // When per-account toggle changes -> pin or unpin, close/open bot chats
        account_toggled_id = registry.account_toggled.connect((jid, active) => {
            if (runtime_is_current(generation)) on_account_toggled(jid, active);
        });

        // When a bot status changes -> sync stream/runtime and close only disabled chats
        bot_status_changed_id = registry.bot_status_changed.connect((bot_id, status) => {
            if (runtime_is_current(generation)) on_bot_status_changed(bot_id, status);
        });

        connect_account_removal_handler();

        // Watch for setting changes
        connect_feature_setting_watcher();

        // Watch API server settings and auto-restart on change
        connect_api_setting_watchers();
    }

    // Auto-approve incoming subscription requests from known dedicated bot JIDs
    private void on_subscription_request(Jid jid, Account account) {
        if (registry == null) return;
        if (!is_dedicated_bot_jid_for_account(jid.bare_jid.to_string(), account)) return;

        message("Botmother: Auto-approving subscription request from bot %s", jid.to_string());
        var pm = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        pm.approve_subscription(account, jid);
        pm.request_subscription(account, jid);
    }

    // Check if a JID belongs to a known dedicated bot owned by the account receiving the request.
    private bool is_dedicated_bot_jid_for_account(string jid_str, Account account) {
        if (registry == null) return false;
        var all_bots = registry.get_all_bots();
        foreach (BotInfo bot in all_bots) {
            if (bot.mode != "dedicated" || bot.jid == null || bot.owner_jid == null || bot.jid != jid_str) continue;

            try {
                Jid owner_jid = new Jid(bot.owner_jid);
                if (account.bare_jid.equals_bare(owner_jid)) return true;
            } catch (Error e) {
                warning("Botmother: Ignoring bot %d with invalid owner JID: %s", bot.id, bot.owner_jid);
            }
        }
        return false;
    }

    // Called when a dedicated bot's XMPP stream is fully ready
    private void on_dedicated_bot_ready(int bot_id, BotInfo bot) {
        if (bot.jid == null || bot.name == null) return;

        try {
            Xmpp.Jid bot_jid = new Xmpp.Jid(bot.jid);

            // Suppress subscription notification for this bot JID
            var presence_mgr = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            if (bot.owner_jid != null) {
                Xmpp.Jid owner_account_jid = new Xmpp.Jid(bot.owner_jid);
                presence_mgr.suppress_subscription_notification_for_account_jid(owner_account_jid, bot_jid);
            }

            // Find the owner account for this bot
            Xmpp.Jid? owner_jid = null;
            if (bot.owner_jid != null) {
                try {
                    owner_jid = new Xmpp.Jid(bot.owner_jid);
                } catch (Error e) {
                    warning("Botmother: Invalid owner JID for bot %d: %s", bot_id, bot.owner_jid);
                }
            }

            // Find the matching owner account - bot conversations only appear for the owner
            var accounts = app.stream_interactor.get_accounts();
            Account? target_account = null;
            foreach (Account account in accounts) {
                if (owner_jid != null && account.bare_jid.equals(owner_jid)) {
                    target_account = account;
                    break;
                }
            }
            if (target_account == null) {
                message("Botmother: Owner account '%s' not active in DinoX for bot %d - conversation will appear when owner logs in",
                    bot.owner_jid ?? "(null)", bot_id);
                return;
            }

            // Set roster handle: show bot name instead of raw JID
            var roster_mgr = app.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
            var existing_item = roster_mgr.get_roster_item(target_account, bot_jid);
            if (existing_item != null) {
                roster_mgr.set_jid_handle(target_account, bot_jid, bot.name);
            } else {
                roster_mgr.add_jid(target_account, bot_jid, bot.name);
            }
            message("Botmother: Set roster name '%s' for bot JID %s (account %s)",
                bot.name, bot.jid, target_account.bare_jid.to_string());

            // Create/get conversation with bot JID and set encryption to NONE
            var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            Conversation conversation = cm.create_conversation(bot_jid, target_account, Conversation.Type.CHAT);
            conversation.encryption = Entities.Encryption.NONE;
            message("Botmother: Set encryption=NONE for bot conversation %s", bot.jid);

            // Approve any pending subscription FROM the bot + send our subscription TO the bot
            presence_mgr.approve_subscription(target_account, bot_jid);
            presence_mgr.request_subscription(target_account, bot_jid);
            message("Botmother: Approved + requested subscription for bot %s", bot.jid);
        } catch (Error e) {
            warning("Botmother: Error setting up bot conversation for %d: %s", bot_id, e.message);
        }

        // Start Telegram polling if configured for this bot
        if (message_router != null && message_router.telegram.is_enabled(bot_id)) {
            string owner = bot.owner_jid ?? "";
            message_router.telegram.start_polling(bot_id, owner);
            message("Botmother: Started Telegram polling for bot %d", bot_id);
        }

        if (session_pool != null) {
            session_pool.rejoin_saved_mucs_for_bot.begin(bot);
        }
    }

    // Fix encryption and subscription for ALL known dedicated bot conversations at startup
    // This prevents OMEMO errors and subscription bars when opening a bot chat
    private void fix_dedicated_bot_conversations() {
        if (registry == null) return;
        var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        var presence_mgr = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        var all_bots = registry.get_all_bots();

        foreach (BotInfo bot in all_bots) {
            if (bot.mode != "dedicated" || bot.jid == null) continue;

            try {
                Xmpp.Jid bot_jid = new Xmpp.Jid(bot.jid);

                // Find the owner account; fall back to first available if owner not found
                Xmpp.Jid? owner_jid = null;
                if (bot.owner_jid != null) {
                    try {
                        owner_jid = new Xmpp.Jid(bot.owner_jid);
                    } catch (Error e) { /* ignore */ }
                }

                // Only create/fix conversation if owner account is active
                var accounts = app.stream_interactor.get_accounts();
                Account? target_account = null;
                foreach (Account account in accounts) {
                    if (owner_jid != null && account.bare_jid.equals(owner_jid)) {
                        target_account = account;
                        break;
                    }
                }
                if (target_account == null) continue;

                // Check if conversation exists and fix encryption
                Conversation? conv = cm.get_conversation(bot_jid, target_account, Conversation.Type.CHAT);
                if (conv != null && conv.encryption != Entities.Encryption.NONE) {
                    conv.encryption = Entities.Encryption.NONE;
                    message("Botmother: Fixed encryption=NONE for bot conversation %s", bot.jid);
                }

                // Auto-approve any pending subscription from the bot
                if (presence_mgr.exists_subscription_request(target_account, bot_jid)) {
                    message("Botmother: Auto-approving pending subscription from bot %s at startup", bot.jid);
                    presence_mgr.approve_subscription(target_account, bot_jid);
                    presence_mgr.request_subscription(target_account, bot_jid);
                }

                // Also set roster name if available (preserve subscription state)
                if (bot.name != null) {
                    var roster_mgr = app.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
                    var item = roster_mgr.get_roster_item(target_account, bot_jid);
                    if (item == null) {
                        roster_mgr.add_jid(target_account, bot_jid, bot.name);
                        message("Botmother: Set roster name '%s' for bot %s at startup", bot.name, bot.jid);
                    } else if (item.name == null || item.name == "") {
                        roster_mgr.set_jid_handle(target_account, bot_jid, bot.name);
                        message("Botmother: Updated roster name '%s' for bot %s at startup", bot.name, bot.jid);
                    }
                }
            } catch (Error e) {
                warning("Botmother: Error fixing bot conversation for %d: %s", bot.id, e.message);
            }
        }
    }

    // Legacy migration only. Do not reintroduce personal-bot self-chat behavior;
    // this only closes old pinned "Botmother" self-chats after upgrading.
    private void ensure_botmother_conversations() {
        // Wait a moment for accounts to be loaded.
        uint generation = runtime_generation;
        legacy_conversations_timeout_id = GLib.Timeout.add(2000, () => {
            if (!runtime_is_current(generation)) return Source.REMOVE;
            legacy_conversations_timeout_id = 0;
            foreach (Account account in app.stream_interactor.get_accounts()) {
                string jid_str = account.bare_jid.to_string();
                unpin_botmother_conversation(jid_str);
            }
            return false; // Don't repeat
        });
    }

    // Called when a bot is deleted. Dedicated bots have real XMPP conversations
    // that must be closed and cleaned up. Personal bots have no bot chat.
    private void on_bot_deleted(string owner_jid, int bot_id, string? bot_jid, string? bot_mode) {
        if (registry == null) return;

        // For dedicated bots: close the conversation with the bot JID
        if (bot_mode == "dedicated" && bot_jid != null) {
            try {
                Xmpp.Jid jid = new Xmpp.Jid(bot_jid);
                Xmpp.Jid owner = new Xmpp.Jid(owner_jid);
                var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
                var roster_mgr = app.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
                foreach (Account account in app.stream_interactor.get_accounts()) {
                    if (!account.bare_jid.equals_bare(owner)) continue;

                    // Close the conversation
                    Conversation? conv = cm.get_conversation(jid, account, Conversation.Type.CHAT);
                    if (conv != null) {
                        if (conv.pinned > 0) {
                            conv.pinned = 0;
                            conv.notify_property("pinned");
                        }
                        cm.close_conversation(conv);
                        message("Botmother: Closed bot conversation %s for %s", bot_jid, owner_jid);
                    }
                    // Remove from roster. If no stream is available, also drop
                    // the local cache so deleted bots do not stay in the sidebar.
                    roster_mgr.remove_jid(account, jid);
                    roster_mgr.remove_jid_locally(account, jid);
                }
            } catch (Error e) {
                warning("Botmother: Error closing bot conversation %s: %s", bot_jid, e.message);
            }

            bool keep_server_account = local_only_dedicated_deletions.remove(bot_id);
            if (keep_server_account) {
                if (session_pool != null) {
                    session_pool.disconnect_dedicated(bot_id);
                }
                message("Botmother: Removed local dedicated bot data for %s without touching its server account", bot_jid);
            } else {
                // Clean up OMEMO state (in-memory + persisted keys)
                uint32 device_id = 0;
                if (session_pool != null && session_pool.bot_omemo != null) {
                    device_id = session_pool.bot_omemo.get_device_id(bot_id);
                    session_pool.bot_omemo.cleanup_bot(bot_id);
                }

                // Delete PubSub nodes (device list, bundle, avatar) then disconnect
                if (session_pool != null) {
                    session_pool.cleanup_pubsub_and_disconnect(bot_id, device_id);
                }
            }

            // Store deleted JID for cleanup on next startup (in case close didn't persist)
            string deleted_entry = "%s|%s".printf(owner_jid, bot_jid);
            string deleted_list = registry.get_setting("deleted_bot_jids") ?? "";
            if (deleted_list.length > 0) {
                deleted_list += "," + deleted_entry;
            } else {
                deleted_list = deleted_entry;
            }
            registry.set_setting("deleted_bot_jids", deleted_list);
        }

        // Clean up runtime state for both personal and dedicated bots. Persistent
        // bot-scoped settings are already removed by BotRegistry.delete_bot().
        if (message_router != null) {
            message_router.ai.cleanup(bot_id);
            message_router.telegram.cleanup(bot_id);
        }
        if (session_pool != null && bot_mode != "dedicated") {
            session_pool.unbind(bot_id);
        }

        // A legacy self-chat may still exist after upgrade; make deletion another
        // chance to remove it, regardless of remaining personal bots.
        unpin_botmother_conversation(owner_jid);
    }

    private void on_account_removed(Account account) {
        string owner = account.bare_jid.to_string().strip();
        if (owner != "" && explicit_account_removals.remove(owner)) return;

        cleanup_removed_account_internal.begin(account, AccountRemovalMode.LOCAL_ONLY, false, false);
    }

    public AccountRemovalImpact get_account_removal_impact(Account account) {
        var impact = new AccountRemovalImpact();
        if (!ensure_registry_for_account_removal()) return impact;

        string owner = account.bare_jid.to_string().strip();
        if (owner == "") return impact;

        var bots = registry.get_bots_by_owner(owner);
        impact.local_bots = bots.size;
        foreach (BotInfo bot in bots) {
            if (bot.mode != "dedicated") continue;
            if (should_unregister_dedicated_bot(bot)) {
                impact.server_managed_bots++;
            } else {
                impact.manual_dedicated_bots++;
            }
        }
        impact.cloudbot_tokens = registry.get_cloudbot_management_tokens(owner).size;
        return impact;
    }

    public async void cleanup_removed_account(Account account, AccountRemovalMode mode, bool delete_managed_bots) {
        yield cleanup_removed_account_internal(account, mode, delete_managed_bots, true);
    }

    private async void cleanup_removed_account_internal(Account account, AccountRemovalMode mode, bool delete_managed_bots, bool mark_signal_handled) {
        if (!ensure_registry_for_account_removal()) return;

        string owner = account.bare_jid.to_string().strip();
        if (owner == "") return;

        if (mode == AccountRemovalMode.SERVER && delete_managed_bots) {
            yield deprovision_cloudbots_for_removed_account(owner);
        }

        var bots = registry.get_bots_by_owner(owner);
        foreach (BotInfo bot in bots) {
            if (bot.mode != "dedicated") continue;

            bool unregister_server_account = delete_managed_bots && should_unregister_dedicated_bot(bot);
            if (!unregister_server_account) {
                local_only_dedicated_deletions.add(bot.id);
                continue;
            }

            if (session_pool != null) {
                session_pool.prepare_for_account_unregister(bot.id);
                yield wait_ms(700);
            }

            string username = ((!) bot.jid).split("@")[0];
            var result = yield ((!) ejabberd_api).unregister_account(username);
            if (!result.success) {
                var check = yield ((!) ejabberd_api).check_account(username);
                if (!check.success && check.status_code == 1) {
                    message("Botmother: Dedicated bot account %s was already missing while removing owner %s",
                        (!) bot.jid, owner);
                } else {
                    warning("Botmother: Failed to unregister dedicated bot account %s while removing owner %s: %s",
                        (!) bot.jid, owner, result.error_message ?? "?");
                }
            }
        }

        int deleted = registry.delete_account_owner_data(owner);
        if (mark_signal_handled) {
            explicit_account_removals.add(owner);
        }
        message("Botmother: Removed %d local bot(s) and owner settings for deleted account %s (mode=%s, managed_bots=%s)",
            deleted, owner, mode == AccountRemovalMode.SERVER ? "server" : "local", delete_managed_bots ? "delete" : "keep");
    }

    private async void deprovision_cloudbots_for_removed_account(string owner) {
        var tokens = registry.get_cloudbot_management_tokens(owner);
        if (tokens.size == 0) return;

        foreach (string token in tokens) {
            string trimmed = token.strip();
            if (trimmed == "") continue;

            try {
                string bot_jid = yield deprovision_cloudbot(trimmed);
                if (bot_jid != "") {
                    message("Botmother: Deprovisioned CloudBot %s while removing account %s", bot_jid, owner);
                } else {
                    message("Botmother: Deprovisioned CloudBot while removing account %s", owner);
                }
            } catch (Error e) {
                warning("Botmother: Failed to deprovision CloudBot while removing account %s: %s", owner, e.message);
            }
        }
    }

    private async string deprovision_cloudbot(string token) throws Error {
        if (cloud_http == null) {
            cloud_http = new Soup.Session();
        }

        var msg = new Soup.Message("POST", "%s/api/v1/bot/deprovision".printf(CLOUD_BOT_BASE_URL));
        msg.request_headers.append("Authorization", "Bearer %s".printf(token));
        msg.set_request_body_from_bytes("application/json", new Bytes("{\"delete_owner_metadata\":true}".data));
        Bytes response = yield ((!) cloud_http).send_and_read_async(msg, GLib.Priority.DEFAULT, null);
        if (msg.status_code != 200) {
            throw new IOError.FAILED("CloudBot deprovision failed with status %u: %s".printf(
                msg.status_code, parse_cloud_api_error(response)));
        }

        return parse_cloudbot_jid(response);
    }

    private string parse_cloudbot_jid(Bytes response) {
        try {
            var parser = new Json.Parser();
            parser.load_from_data((string) response.get_data(), (ssize_t) response.get_size());
            var root = parser.get_root().get_object();
            if (root.has_member("bot_jid")) return root.get_string_member("bot_jid");
        } catch (Error e) {
            // Keep deprovision success even if the optional response body changes.
        }
        return "";
    }

    private string parse_cloud_api_error(Bytes response) {
        try {
            var parser = new Json.Parser();
            parser.load_from_data((string) response.get_data(), (ssize_t) response.get_size());
            var root = parser.get_root().get_object();
            if (root.has_member("description")) return root.get_string_member("description");
            if (root.has_member("error")) return root.get_string_member("error");
        } catch (Error e) {
            // Fall through to generic text.
        }
        return "unknown error";
    }

    private bool should_unregister_dedicated_bot(BotInfo bot) {
        if (registry == null || ejabberd_api == null) return false;
        if (bot.mode != "dedicated" || bot.jid == null || !bot.jid.contains("@")) return false;

        string provisioning = registry.get_setting("bot_dedicated_provisioning:%d".printf(bot.id)) ?? "ejabberd";
        if (provisioning != "ejabberd") return false;

        return ((!) ejabberd_api).is_configured();
    }

    private void connect_account_removal_handler() {
        if (account_removal_handler_connected) return;
        app.stream_interactor.account_removed.connect(on_account_removed);
        account_removal_handler_connected = true;
    }

    private bool ensure_registry_for_account_removal() {
        if (registry != null) {
            if (ejabberd_api == null) {
                ejabberd_api = new EjabberdApi(registry);
            }
            return true;
        }

        string db_path = GLib.Path.build_filename(
            GLib.Environment.get_user_data_dir(), "dinox", "bot_registry.db"
        );
        try {
            registry = new BotRegistry(db_path, app.db_key);
            ejabberd_api = new EjabberdApi(registry);
            return true;
        } catch (Error e) {
            warning("Botmother: Failed to open bot registry for account removal: %s", e.message);
            return false;
        }
    }

    private async void wait_ms(uint interval) {
        SourceFunc callback = wait_ms.callback;
        Timeout.add(interval, () => {
            callback();
            return false;
        });
        yield;
    }

    // Suppress subscription notifications for all known dedicated bot JIDs
    private void suppress_bot_subscriptions() {
        if (registry == null) return;
        var presence_mgr = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        var all_bots = registry.get_all_bots();
        foreach (BotInfo bot in all_bots) {
            if (bot.mode == "dedicated" && bot.jid != null) {
                try {
                    Xmpp.Jid bot_jid = new Xmpp.Jid(bot.jid);
                    if (bot.owner_jid != null) {
                        Xmpp.Jid owner_jid = new Xmpp.Jid(bot.owner_jid);
                        presence_mgr.suppress_subscription_notification_for_account_jid(owner_jid, bot_jid);
                        message("Botmother: Suppressed subscription notification for bot %s", bot.jid);
                    }
                } catch (Error e) {
                    // ignore
                }
            }
        }
    }

    // Clean up conversations and roster entries for previously deleted bots
    private void cleanup_orphaned_bot_conversations() {
        if (registry == null) return;
        string? deleted_list = registry.get_setting("deleted_bot_jids");
        if (deleted_list == null || deleted_list.strip() == "") return;

        var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        var roster_mgr = app.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        var remaining_entries = new ArrayList<string>();
        string[] jids = deleted_list.split(",");
        foreach (string jid_str in jids) {
            string trimmed = jid_str.strip();
            if (trimmed == "") continue;
            try {
                string[] parts = trimmed.split("|", 2);
                if (parts.length != 2 || parts[0].strip() == "" || parts[1].strip() == "") {
                    warning("Botmother: Ignoring legacy unscoped deleted bot cleanup entry %s", trimmed);
                    continue;
                }

                Xmpp.Jid owner = new Xmpp.Jid(parts[0].strip());
                Xmpp.Jid jid = new Xmpp.Jid(parts[1].strip());
                bool processed_entry = false;
                foreach (Account account in app.stream_interactor.get_accounts()) {
                    if (!account.bare_jid.equals_bare(owner)) continue;

                    processed_entry = true;
                    // Close conversation
                    Conversation? conv = cm.get_conversation(jid, account, Conversation.Type.CHAT);
                    if (conv != null) {
                        if (conv.pinned > 0) {
                            conv.pinned = 0;
                            conv.notify_property("pinned");
                        }
                        cm.close_conversation(conv);
                        message("Botmother: Cleaned up orphaned bot conversation %s for %s", jid.to_string(), owner.to_string());
                    }
                    // Remove from roster / contact list
                    roster_mgr.remove_jid(account, jid);
                    roster_mgr.remove_jid_locally(account, jid);
                    message("Botmother: Removed orphaned bot %s from roster for %s", jid.to_string(), owner.to_string());
                }
                if (!processed_entry) remaining_entries.add(trimmed);
            } catch (Error e) {
                // ignore
            }
        }
        string remaining_list = "";
        foreach (string entry in remaining_entries) {
            if (remaining_list != "") remaining_list += ",";
            remaining_list += entry;
        }
        registry.set_setting("deleted_bot_jids", remaining_list);
    }

    // Called when per-account Botmother is toggled on/off via the API
    private void on_account_toggled(string account_jid, bool account_enabled) {
        if (registry == null) return;
        var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);

        if (account_enabled) {
            unpin_botmother_conversation(account_jid);

            // Reconnect dedicated bot streams
            var bots = registry.get_bots_by_owner(account_jid);
            if (session_pool != null) {
                foreach (BotInfo b in bots) {
                    if (b.mode == "dedicated" && b.status == "active") {
                        session_pool.connect_dedicated.begin(b);
                    }
                }
            }
        } else {
            // Legacy cleanup only: account toggles should not leave old self-chats.
            unpin_botmother_conversation(account_jid);

            // Close all dedicated bot conversations for this account
            var bots = registry.get_bots_by_owner(account_jid);
            foreach (BotInfo b in bots) {
                if (b.mode == "dedicated" && b.jid != null) {
                    try {
                        Xmpp.Jid bot_jid = new Xmpp.Jid(b.jid);
                        foreach (Account account in app.stream_interactor.get_accounts()) {
                            if (account.bare_jid.to_string() != account_jid) continue;
                            Conversation? c = cm.get_conversation(bot_jid, account, Conversation.Type.CHAT);
                            if (c != null) {
                                cm.close_conversation(c);
                                message("Botmother: Closed bot chat %s (account disabled)", b.jid);
                            }
                        }
                    } catch (Error e) { /* ignore */ }
                }
            }

            // Disconnect dedicated bot streams for this account
            if (session_pool != null) {
                foreach (BotInfo b in bots) {
                    if (b.mode == "dedicated") {
                        session_pool.disconnect_dedicated(b.id);
                    }
                }
            }
        }
    }

    // Called when a bot's status changes (active/disabled)
    private void on_bot_status_changed(int bot_id, string new_status) {
        if (registry == null) return;
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null || bot.mode != "dedicated" || bot.jid == null) return;

        var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);

        if (new_status == "active") {
            if (session_pool != null) {
                session_pool.connect_dedicated.begin(bot);
            }
            message("Botmother: Bot %d activated", bot_id);
        } else if (new_status == "paused") {
            if (session_pool != null) {
                session_pool.disconnect_dedicated(bot_id);
            }
            message("Botmother: Bot %d paused", bot_id);
        } else {
            // Close conversation and disconnect stream
            try {
                Xmpp.Jid bot_jid = new Xmpp.Jid(bot.jid);
                Xmpp.Jid? owner_jid = bot.owner_jid != null ? new Xmpp.Jid(bot.owner_jid) : null;
                foreach (Account account in app.stream_interactor.get_accounts()) {
                    if (owner_jid == null || !account.bare_jid.equals_bare((!) owner_jid)) continue;

                    Conversation? c = cm.get_conversation(bot_jid, account, Conversation.Type.CHAT);
                    if (c != null) {
                        cm.close_conversation(c);
                    }
                }
            } catch (Error e) { /* ignore */ }
            if (session_pool != null) {
                session_pool.disconnect_dedicated(bot_id);
            }
            message("Botmother: Bot %d deactivated, conversation closed", bot_id);
        }
    }

    // Legacy cleanup only: unpin and close old Botmother self-chats.
    private void unpin_botmother_conversation(string jid_str) {
        var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        foreach (Account account in app.stream_interactor.get_accounts()) {
            if (account.bare_jid.to_string() != jid_str) continue;
            foreach (Conversation conversation in cm.get_active_conversations(account)) {
                if (!is_botmother_self_chat(conversation)) continue;
                if (conversation.pinned > 0) {
                    conversation.pinned = 0;
                    conversation.notify_property("pinned");
                }
                cm.close_conversation(conversation);
                message("Botmother: Closed self-chat for %s", jid_str);
            }
        }
    }

    private bool is_botmother_self_chat(Conversation conversation) {
        return conversation.type_ == Conversation.Type.CHAT
            && conversation.counterpart.equals_bare(conversation.account.bare_jid)
            && conversation.nickname == "Botmother";
    }

    // Legacy cleanup only: unpin and close old Botmother self-chats for all accounts.
    private void unpin_all_botmother_conversations() {
        var cm = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        foreach (Account account in app.stream_interactor.get_accounts()) {
            foreach (Conversation conversation in cm.get_active_conversations(account)) {
                if (!is_botmother_self_chat(conversation)) continue;
                if (conversation.pinned > 0) {
                    conversation.pinned = 0;
                    conversation.notify_property("pinned");
                }
                cm.close_conversation(conversation);
                message("Botmother: Closed self-chat for %s (global shutdown)", account.bare_jid.to_string());
            }
        }
    }

    // Debounced restart of the HTTP API server when settings change
    private void on_api_setting_changed() {
        if (!app.settings.bot_features_enabled) return;
        if (!runtime_active || http_server == null) {
            initialize();
            return;
        }
        // Debounce: wait 500ms so multiple rapid changes (mode+port) combine
        if (api_restart_timeout_id != 0) {
            GLib.Source.remove(api_restart_timeout_id);
        }
        uint generation = runtime_generation;
        api_restart_timeout_id = GLib.Timeout.add(500, () => {
            if (!runtime_is_current(generation)) return Source.REMOVE;
            api_restart_timeout_id = 0;
            restart_http_server();
            return false;
        });
    }

    private void restart_http_server() {
        if (!runtime_active || !app.settings.bot_features_enabled || http_server == null) return;

        http_server.stop();

        var s = app.settings;
        uint16 port = (uint16) s.api_port;
        string mode = s.api_mode;
        string tls_cert = s.api_tls_cert;
        string tls_key = s.api_tls_key;

        try {
            http_server.start(port, mode, tls_cert, tls_key);
            if (mode == "network") {
                message("Botmother: API restarted - HTTPS on 0.0.0.0:%u (TLS)", port);
            } else {
                message("Botmother: API restarted - HTTP on localhost:%u", port);
            }
        } catch (Error e) {
            if (mode == "network") {
                warning("Botmother: Network mode failed (%s), falling back to localhost", e.message);
                try {
                    http_server.start(port, "local", "", "");
                    message("Botmother: API restarted - HTTP on localhost:%u (fallback)", port);
                } catch (Error e2) {
                    warning("Botmother: Failed to restart HTTP server: %s", e2.message);
                }
            } else {
                warning("Botmother: Failed to restart HTTP server: %s", e.message);
            }
        }
    }

    public void shutdown() {
        // Cancel pending API restart
        if (api_restart_timeout_id != 0) {
            GLib.Source.remove(api_restart_timeout_id);
            api_restart_timeout_id = 0;
        }

        if (!runtime_active) return;
        runtime_active = false;
        runtime_generation++;
        cancel_startup_sources();
        disconnect_runtime_handlers();

        // Unpin all Botmother self-chats when globally disabled
        unpin_all_botmother_conversations();

        if (http_server != null) {
            http_server.stop();
        }
        if (session_pool != null) {
            session_pool.shutdown();
        }
        if (message_router != null) {
            message_router.shutdown();
        }
        if (webhook_dispatcher != null) {
            webhook_dispatcher.shutdown();
        }

        // BUG-18 fix: Deinitialize GnuTLS at plugin shutdown
        CertGen.deinit();
    }

    private void cancel_startup_sources() {
        if (cleanup_timeout_id != 0) Source.remove(cleanup_timeout_id);
        if (fix_conversations_timeout_id != 0) Source.remove(fix_conversations_timeout_id);
        if (connect_bots_timeout_id != 0) Source.remove(connect_bots_timeout_id);
        if (legacy_conversations_timeout_id != 0) Source.remove(legacy_conversations_timeout_id);
        cleanup_timeout_id = 0;
        fix_conversations_timeout_id = 0;
        connect_bots_timeout_id = 0;
        legacy_conversations_timeout_id = 0;
    }

    private void disconnect_runtime_handlers() {
        if (runtime_account_added_id != 0) {
            SignalHandler.disconnect(app.stream_interactor, runtime_account_added_id);
            runtime_account_added_id = 0;
        }
        if (subscription_request_id != 0) {
            var presence = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            SignalHandler.disconnect(presence, subscription_request_id);
            subscription_request_id = 0;
        }
        if (dedicated_ready_id != 0 && session_pool != null) {
            SignalHandler.disconnect(session_pool, dedicated_ready_id);
            dedicated_ready_id = 0;
        }
        if (registry != null) {
            if (bot_deleted_id != 0) SignalHandler.disconnect(registry, bot_deleted_id);
            if (account_toggled_id != 0) SignalHandler.disconnect(registry, account_toggled_id);
            if (bot_status_changed_id != 0) SignalHandler.disconnect(registry, bot_status_changed_id);
        }
        bot_deleted_id = 0;
        account_toggled_id = 0;
        bot_status_changed_id = 0;
    }

    public void rekey_database(string new_key) throws Error {
        if (registry != null) {
            registry.rekey(new_key);
        }
    }

    public void checkpoint_database() {
        if (registry != null) {
            try {
                registry.exec("PRAGMA wal_checkpoint(TRUNCATE)");
            } catch (Error e) {
                warning("BotFeatures: WAL checkpoint failed: %s", e.message);
            }
        }
    }

    public void backup_database(string directory, Cancellable? cancellable = null) throws Error {
        string destination = Path.build_filename(directory, "bot_registry.db");
        if (registry != null) {
            registry.backup_to(destination, () => cancellable != null && cancellable.is_cancelled());
            return;
        }
        string source = Path.build_filename(Dino.Application.get_storage_dir(), "bot_registry.db");
        if (!File.new_for_path(source).query_exists(cancellable)) return;
        // Do not initialize the feature or migrate a closed registry to back it up.
        Qlite.Database.backup_existing(source, app.db_key, destination, true,
            () => cancellable != null && cancellable.is_cancelled());
    }
}

}
