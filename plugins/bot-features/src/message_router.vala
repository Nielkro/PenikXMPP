using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino.Plugins.BotFeatures {

public class MessageRouter : Object {

    private Dino.Application app;
    private BotRegistry registry;
    private SessionPool session_pool;
    private WebhookDispatcher webhook_dispatcher;
    private EjabberdApi? ejabberd_api;
    public AiIntegration ai;
    public TelegramBridge telegram;
    private uint cleanup_timer_id = 0;
    private MessageListenerHolder? received_pipeline;
    private ReceivedMessageListener? received_message_listener;
    private bool stopped = false;

    public MessageRouter(Dino.Application app, BotRegistry registry,
                         SessionPool session_pool, WebhookDispatcher webhook_dispatcher) {
        this.app = app;
        this.registry = registry;
        this.session_pool = session_pool;
        this.webhook_dispatcher = webhook_dispatcher;
        this.ai = new AiIntegration(registry);
        this.telegram = new TelegramBridge(registry);

        // Handle incoming Telegram messages -> forward to XMPP
        telegram.telegram_message_received.connect(on_telegram_message);
        telegram.telegram_file_received.connect(on_telegram_file);

        // Listen for incoming messages on all accounts (for bot update queue + webhook)
        received_pipeline = app.stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY)
            .received_pipeline;
        received_message_listener = new ReceivedMessageListener(this);
        received_pipeline.connect(received_message_listener);

        // Listen for messages on dedicated bot streams
        session_pool.dedicated_message_received.connect(on_dedicated_bot_message);

        // Periodic cleanup of old updates
        cleanup_timer_id = GLib.Timeout.add_seconds(3600, () => {
            registry.cleanup_old_updates();
            return GLib.Source.CONTINUE;
        });
    }

    public void shutdown() {
        if (stopped) return;
        // A pipeline already suspended in another listener can retain the old
        // list. Mark this router stopped before detaching any event source.
        stopped = true;
        if (received_pipeline != null && received_message_listener != null) {
            received_pipeline.disconnect(received_message_listener);
        }
        received_message_listener = null;
        received_pipeline = null;
        session_pool.dedicated_message_received.disconnect(on_dedicated_bot_message);
        telegram.telegram_message_received.disconnect(on_telegram_message);
        telegram.telegram_file_received.disconnect(on_telegram_file);
        if (cleanup_timer_id != 0) {
            GLib.Source.remove(cleanup_timer_id);
            cleanup_timer_id = 0;
        }
        if (telegram != null) telegram.shutdown();
        if (ai != null) ai.shutdown();
        if (ejabberd_api != null) ejabberd_api.shutdown();
    }

    // Handle Telegram -> XMPP forwarding
    private void on_telegram_message(int bot_id, string from_name, string text) {
        if (stopped) return;
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (!BotUtils.can_receive_updates_for_enabled_account(bot, registry)) return;

        // Send to the bot owner via XMPP
        string? owner_jid = bot.owner_jid;
        if (owner_jid != null && owner_jid != "") {
            string msg = "[Telegram] %s:\n%s".printf(from_name, text);
            session_pool.send_message_for_bot(bot_id, owner_jid, msg);
        }
    }

    // Handle Telegram -> XMPP file forwarding (inline image/video/audio display)
    private void on_telegram_file(int bot_id, string from_name, string file_url, string? caption) {
        if (stopped) return;
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (!BotUtils.can_receive_updates_for_enabled_account(bot, registry)) return;

        string? owner_jid = bot.owner_jid;
        if (owner_jid == null || owner_jid == "") return;

        // Send sender info + optional caption as text message
        string info = "[Telegram] %s:".printf(from_name);
        if (caption != null && caption.length > 0) info += "\n" + caption;
        session_pool.send_message_for_bot(bot_id, owner_jid, info);

        // Send bare file URL as separate message -> Dino auto-detects and shows inline
        session_pool.send_message_for_bot(bot_id, owner_jid, file_url);
    }

    // --- Outbound: Bot -> XMPP ---

    public string? send_message(BotInfo bot, string to_jid_str, string text, string msg_type = "chat") {
        if (bot.mode == "personal") {
            return send_personal_message(bot, to_jid_str, text, msg_type);
        }

        if (bot.mode == "dedicated" && msg_type == "chat") {
            string message_id = Xmpp.random_uuid();
            if (session_pool.send_message_for_bot(bot.id, to_jid_str, text, message_id)) {
                registry.update_bot_last_active(bot.id);
                registry.log_action(bot.id, "send_message", "to=%s via=dedicated".printf(to_jid_str));
                return message_id;
            }
            warning("BotRouter: No dedicated stream available for bot %d", bot.id);
            return null;
        }

        if (bot.mode == "dedicated" && msg_type == "groupchat") {
            string message_id = Xmpp.random_uuid();
            if (session_pool.send_groupchat_for_bot(bot.id, to_jid_str, text, message_id)) {
                registry.update_bot_last_active(bot.id);
                registry.log_action(bot.id, "send_message", "to=%s type=groupchat via=dedicated".printf(to_jid_str));
                return message_id;
            }
            warning("BotRouter: Dedicated bot %d cannot send groupchat message to %s", bot.id, to_jid_str);
            return null;
        }

        XmppStream? stream = session_pool.get_stream(bot);
        if (stream == null) {
            warning("BotRouter: No stream available for bot %d", bot.id);
            return null;
        }

        try {
            Jid to_jid = new Jid(to_jid_str);
            string message_id = Xmpp.random_uuid();

            Xmpp.MessageStanza message = new Xmpp.MessageStanza(message_id);
            message.to = to_jid;
            message.type_ = msg_type == "groupchat" ? Xmpp.MessageStanza.TYPE_GROUPCHAT : Xmpp.MessageStanza.TYPE_CHAT;
            message.body = text;

            stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY).send_message.begin(stream, message);

            registry.update_bot_last_active(bot.id);
            registry.log_action(bot.id, "send_message", "to=%s".printf(to_jid_str));
            return message_id;
        } catch (Error e) {
            warning("BotRouter: Failed to send message: %s", e.message);
            return null;
        }
    }

    private string? send_personal_message(BotInfo bot, string to_jid_str, string text, string msg_type) {
        Account? account = session_pool.get_account_for_bot(bot);
        if (account == null) {
            warning("BotRouter: No owner account available for personal bot %d", bot.id);
            return null;
        }

        try {
            Jid to_jid = new Jid(to_jid_str);
            Conversation.Type conversation_type = msg_type == "groupchat"
                ? Conversation.Type.GROUPCHAT
                : Conversation.Type.CHAT;

            if (conversation_type == Conversation.Type.GROUPCHAT) {
                var muc_manager = app.stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
                if (muc_manager == null || !muc_manager.is_joined(to_jid.bare_jid, account)) {
                    warning("BotRouter: Personal bot %d cannot send to MUC %s because owner account is not joined", bot.id, to_jid.bare_jid.to_string());
                    return null;
                }
            }

            var conversation_manager = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            Conversation conversation = conversation_manager.create_conversation(to_jid, account, conversation_type);
            bool was_active = conversation.active;

            var message_processor = app.stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            Entities.Message out_message = message_processor.create_out_message(text, conversation);
            app.stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).insert_message(out_message, conversation);
            message_processor.send_xmpp_message(out_message, conversation);
            if (was_active) {
                message_processor.message_sent(out_message, conversation);
            }

            registry.update_bot_last_active(bot.id);
            registry.log_action(bot.id, "send_message", "to=%s via=personal".printf(to_jid_str));
            return out_message.stanza_id;
        } catch (Error e) {
            warning("BotRouter: Failed to send personal message: %s", e.message);
            return null;
        }
    }

    public string? send_file(BotInfo bot, string to_jid_str, string file_url, string? caption = null) {
        if (bot.mode == "dedicated") {
            string message_id = Xmpp.random_uuid();
            string body = caption != null && caption.length > 0
                ? "%s\n%s".printf(caption, file_url)
                : file_url;
            if (session_pool.send_message_for_bot(bot.id, to_jid_str, body, message_id)) {
                registry.update_bot_last_active(bot.id);
                registry.log_action(bot.id, "send_file", "to=%s url=%s via=dedicated".printf(
                    to_jid_str, WebhookDispatcher.sanitize_url_for_log(file_url)));
                return message_id;
            }
            warning("BotRouter: No dedicated stream available for file send from bot %d", bot.id);
            return null;
        }

        XmppStream? stream = session_pool.get_stream(bot);
        if (stream == null) return null;

        try {
            Jid to_jid = new Jid(to_jid_str);
            string message_id = Xmpp.random_uuid();

            Xmpp.MessageStanza message = new Xmpp.MessageStanza(message_id);
            message.to = to_jid;
            message.type_ = Xmpp.MessageStanza.TYPE_CHAT;

            // Include URL as body (XMPP clients will auto-detect as file)
            if (caption != null && caption.length > 0) {
                message.body = "%s\n%s".printf(caption, file_url);
            } else {
                message.body = file_url;
            }

            // Add OOB data (XEP-0066)
            StanzaNode x_node = new StanzaNode.build("x", "jabber:x:oob")
                .add_self_xmlns();
            StanzaNode url_node = new StanzaNode.build("url", "jabber:x:oob");
            url_node.put_node(new StanzaNode.text(file_url));
            x_node.put_node(url_node);
            if (caption != null) {
                StanzaNode desc_node = new StanzaNode.build("desc", "jabber:x:oob");
                desc_node.put_node(new StanzaNode.text(caption));
                x_node.put_node(desc_node);
            }
            message.stanza.put_node(x_node);

            stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY).send_message.begin(stream, message);

            registry.log_action(bot.id, "send_file", "to=%s url=%s".printf(
                to_jid_str, WebhookDispatcher.sanitize_url_for_log(file_url)));
            return message_id;
        } catch (Error e) {
            warning("BotRouter: Failed to send file: %s", e.message);
            return null;
        }
    }

    public bool send_reaction(BotInfo bot, string to_jid_str, string message_id, string reaction) {
        if (bot.mode == "dedicated") {
            bool sent = session_pool.send_reaction_for_bot(bot.id, to_jid_str, message_id, reaction);
            if (sent) {
                registry.update_bot_last_active(bot.id);
                registry.log_action(bot.id, "send_reaction", "to=%s via=dedicated".printf(to_jid_str));
            }
            return sent;
        }

        XmppStream? stream = session_pool.get_stream(bot);
        if (stream == null) return false;

        try {
            Jid to_jid = new Jid(to_jid_str);
            var reactions = new Gee.ArrayList<string>();
            reactions.add(reaction);

            stream.get_module<Xmpp.Xep.Reactions.Module>(Xmpp.Xep.Reactions.Module.IDENTITY)
                .send_reaction.begin(stream, to_jid, Xmpp.MessageStanza.TYPE_CHAT, message_id, reactions);

            registry.log_action(bot.id, "send_reaction", "to=%s".printf(to_jid_str));
            return true;
        } catch (Error e) {
            warning("BotRouter: Failed to send reaction: %s", e.message);
            return false;
        }
    }

    public async bool join_room(BotInfo bot, string room_jid_str, string? nick = null) {
        if (bot.mode == "dedicated") {
            bool joined = yield session_pool.join_muc_for_bot(bot.id, room_jid_str, nick);
            if (joined) {
                BotUtils.remember_muc_room(registry, bot.id, room_jid_str, nick ?? bot.name ?? "");
                registry.log_action(bot.id, "join_room", "%s via=dedicated persisted=true".printf(room_jid_str));
            }
            return joined;
        }

        Account? account = session_pool.get_account_for_bot(bot);
        if (account == null) return false;

        try {
            Jid room_jid = new Jid(room_jid_str);
            string nickname = nick ?? (bot.name ?? "bot");

            app.stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                .join.begin(account, room_jid, nickname, null);

            registry.log_action(bot.id, "join_room", room_jid_str);
            return true;
        } catch (Error e) {
            warning("BotRouter: Failed to join room: %s", e.message);
            return false;
        }
    }

    public bool leave_room(BotInfo bot, string room_jid_str) {
        if (bot.mode == "dedicated") {
            bool left = session_pool.leave_muc_for_bot(bot.id, room_jid_str);
            if (left) {
                BotUtils.forget_muc_room(registry, bot.id, room_jid_str);
                registry.log_action(bot.id, "leave_room", "%s via=dedicated persisted=false".printf(room_jid_str));
            }
            return left;
        }

        Account? account = session_pool.get_account_for_bot(bot);
        if (account == null) return false;

        try {
            Jid room_jid = new Jid(room_jid_str);
            app.stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                .part(account, room_jid);

            registry.log_action(bot.id, "leave_room", room_jid_str);
            return true;
        } catch (Error e) {
            warning("BotRouter: Failed to leave room: %s", e.message);
            return false;
        }
    }

    // --- Inbound: XMPP -> Bot Update Queue / Webhook ---

    public void set_ejabberd_api(EjabberdApi api) {
        this.ejabberd_api = api;
    }

    public void on_message_received(Entities.Message message, Conversation conversation) {
        if (stopped) return;
        // Skip messages with empty body (OMEMO-encrypted, PubSub notifications, etc.)
        if (message.body == null || message.body.strip() == "") return;

        // Skip messages from pubsub/system services
        string from_str = message.from.to_string();
        if (from_str.has_prefix("pubsub.") || from_str.has_prefix("upload.")) return;

        // For bot update queue: skip own outgoing messages
        if (message.direction == Entities.Message.DIRECTION_SENT) return;

        // Route to all active bots owned by this account
        Account account = conversation.account;
        var bots = registry.get_all_active_bots();

        foreach (BotInfo bot in bots) {
            // Check if this bot is bound to this account
            Account? bot_account = session_pool.get_account_for_bot(bot);
            if (bot_account == null || !bot_account.equals(account)) continue;
            if (!BotUtils.can_receive_updates_for_enabled_account(bot, registry)) continue;

            // Create update payload
            string payload = message_to_json(message, conversation);

            // Enqueue for long-poll (getUpdates)
            registry.enqueue_update(bot.id, "message", payload);

            // Dispatch webhook if configured
            if (bot.webhook_enabled && bot.webhook_url != null && bot.webhook_secret != null) {
                string full_payload = "{\"update_type\":\"message\",\"data\":%s}".printf(payload);
                webhook_dispatcher.dispatch(bot.webhook_url, bot.webhook_secret, full_payload);
            }
        }
    }

    // Handle incoming messages on dedicated bot streams
    private void on_dedicated_bot_message(int bot_id, Xmpp.MessageStanza stanza) {
        if (stopped) return;
        if (stanza.body == null || stanza.body.strip() == "") return;

        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null || bot.status != "active") return;

        string body = stanza.body.strip();
        string from_str = stanza.from != null ? stanza.from.bare_jid.to_string() : "";
        bool is_groupchat = stanza.type_ == Xmpp.MessageStanza.TYPE_GROUPCHAT;

        if (!BotUtils.can_process_dedicated_inbound_command(bot, registry)) {
            if (!is_groupchat) {
                send_receive_updates_disabled_notice(bot, from_str);
            }
            return;
        }

        // Handle /help and other slash commands directly via the dedicated bot stream
        if (!is_groupchat && body.has_prefix("/")) {
            // Check for async commands first
            if (handle_dedicated_command_async(bot, body, from_str)) {
                // Async command is being handled
            } else {
                string? response = handle_dedicated_command(bot, body);
                if (response != null && from_str != "") {
                    session_pool.send_message_for_bot(bot_id, from_str, response);
                }
            }
            // Don't forward slash commands to AI/Telegram
            return;
        }

        if (!BotUtils.can_receive_updates(bot)) {
            if (!is_groupchat) {
                send_receive_updates_disabled_notice(bot, from_str);
            }
            return;
        }

        bool group_mentions_bot = is_groupchat && BotUtils.dedicated_group_message_mentions_bot(bot, body);
        bool group_mentions_owner = is_groupchat &&
            BotUtils.should_notify_owner_about_group_mention(bot, body, group_mentions_bot);
        string muc_ai_mode = registry.get_setting("bot_%d_muc_ai_mode".printf(bot.id)) ?? "mention_only";
        bool group_should_reply = is_groupchat &&
            BotUtils.should_dedicated_group_ai_reply(bot, body, group_mentions_bot, muc_ai_mode);
        string sender_nick = stanza.from != null && stanza.from.is_full() ? stanza.from.resourcepart : "";
        bool file_transfer_body = BotUtils.is_legacy_aesgcm_file_url(body);
        if (group_mentions_owner) {
            notify_owner_about_muc_mention(bot, from_str, sender_nick, body);
        }

        // Legacy aesgcm:// file-transfer bodies are transport data, not user prompts.
        if (!file_transfer_body && ai.is_enabled(bot_id) && from_str != "") {
            if (is_groupchat) {
                if (group_should_reply) {
                    handle_ai_groupchat_message.begin(bot_id, from_str, body, sender_nick);
                }
            } else {
                handle_ai_message.begin(bot_id, from_str, body);
            }
        }

        // Forward to Telegram if enabled
        if (telegram.is_enabled(bot_id) && from_str != "") {
            telegram.forward_to_telegram.begin(bot_id, from_str, body);
        }

        // Build JSON payload from the stanza
        string to_str = stanza.to != null ? stanza.to.to_string() : "";
        string msg_type = stanza.type_ == Xmpp.MessageStanza.TYPE_GROUPCHAT ? "groupchat" : "chat";
        long now = (long) new DateTime.now_utc().to_unix();

        string payload = "{\"from\":\"%s\",\"to\":\"%s\",\"body\":\"%s\",\"type\":\"%s\",\"stanza_id\":\"%s\",\"timestamp\":%ld}".printf(
            escape_json(from_str), escape_json(to_str),
            escape_json(stanza.body ?? ""), escape_json(msg_type),
            escape_json(stanza.id ?? ""), now);

        // Enqueue for getUpdates
        registry.enqueue_update(bot.id, "message", payload);

        // Dispatch webhook if configured
        if (bot.webhook_enabled && bot.webhook_url != null && bot.webhook_secret != null) {
            string full_payload = "{\"update_type\":\"message\",\"data\":%s}".printf(payload);
            webhook_dispatcher.dispatch(bot.webhook_url, bot.webhook_secret, full_payload);
        }

        message("BotRouter: Dedicated bot %d received message from %s", bot_id, from_str);
    }

    private void notify_owner_about_muc_mention(BotInfo bot, string room_jid, string sender_nick, string body) {
        string? owner = bot.owner_jid;
        if (owner == null || owner.strip() == "" || room_jid == "") return;

        string mode = registry.get_setting("bot_%d_muc_owner_notify".printf(bot.id)) ?? "off";
        if (mode != "mentions" && mode != "mentions_when_owner_absent") return;

        if (mode == "mentions_when_owner_absent" &&
                session_pool.is_real_jid_present_in_muc(bot.id, room_jid, owner.strip())) {
            return;
        }

        string who = sender_nick != "" ? sender_nick : _("Someone");
        string snippet = BotUtils.truncate_utf8(body.strip(), 500);
        string msg = _("Mention in %s by %s:").printf(room_jid, who) + "\n" + snippet;
        session_pool.send_message_for_bot(bot.id, owner.strip(), msg);
    }

    // Handle async slash commands (AI, Telegram) - returns true if handled
    private bool handle_dedicated_command_async(BotInfo bot, string body, string from_str) {
        string[] parts = body.strip().split(" ", 3);
        string cmd = parts[0].ascii_down();
        string? arg1 = parts.length > 1 ? parts[1].strip() : null;
        string? arg2 = parts.length > 2 ? parts[2].strip() : null;

        if (BotUtils.dedicated_command_requires_admin(cmd, arg1, arg2)) {
            if (!BotUtils.is_owner_jid(bot, from_str)) {
                send_owner_only_denied(bot, from_str);
                return true;
            }
            if (!BotUtils.has_permission(bot, "admin")) {
                send_permission_denied(bot, from_str, "admin");
                return true;
            }
        }

        switch (cmd) {
            case "/ki":
                handle_ki_command.begin(bot, from_str, arg1, arg2);
                return true;
            case "/telegram":
                handle_telegram_command.begin(bot, from_str, arg1, arg2);
                return true;
            case "/api":
                handle_api_command(bot, from_str, arg1, arg2);
                return true;
            case "/clear":
                handle_clear_command.begin(bot, from_str, arg1);
                return true;
            default:
                return false;
        }
    }

    private void send_permission_denied(BotInfo bot, string from_str, string scope) {
        if (from_str == "") return;
        string response = _("Permission denied.") + "\n" + _("Missing permission: %s").printf(scope);
        session_pool.send_message_for_bot(bot.id, from_str, response);
    }

    private void send_owner_only_denied(BotInfo bot, string from_str) {
        if (from_str == "") return;
        string response = _("Permission denied.") + "\n" + _("Only the bot owner may change bot settings.");
        session_pool.send_message_for_bot(bot.id, from_str, response);
    }

    private void send_receive_updates_disabled_notice(BotInfo bot, string from_str) {
        if (from_str == "") return;

        string response;
        if (!BotUtils.has_permission(bot, "receive_updates")) {
            response = _("Bot cannot process incoming messages because the Receive updates permission is disabled.") +
                "\n" + _("Enable Receive updates in the bot permissions to use AI, Telegram, getUpdates or webhooks.");
        } else {
            response = _("Botmother is disabled for this account.") +
                "\n" + _("Enable Botmother for this account to process incoming bot messages.");
        }
        session_pool.send_message_for_bot(bot.id, from_str, response);
    }

    // Handle /ki commands
    private async void handle_ki_command(BotInfo bot, string from_str, string? action, string? args) {
        string response;

        if (action == null) {
            // KI main menu
            response = build_ki_menu(bot.id, bot.jid ?? "");
        } else {
            switch (action.ascii_down()) {
                case "on":
                    if (!ai.is_enabled(bot.id)) {
                        string? endpoint = registry.get_setting("bot_%d_ai_endpoint".printf(bot.id));
                        if (endpoint == null) {
                            response = _("AI not configured.") + "\n\n" + build_ki_setup_menu(bot.jid ?? "");
                        } else {
                            registry.set_setting("bot_%d_ai_enabled".printf(bot.id), "true");
                            response = _("AI activated!") + "\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                        }
                    } else {
                        response = _("AI is already active.") + "\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                    }
                    break;
                case "off":
                    ai.disable(bot.id);
                    response = _("AI deactivated.") + "\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                    break;
                case "status":
                    response = ai.get_status(bot.id) + "\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                    break;
                case "clear":
                    ai.clear_history(bot.id, from_str);
                    response = _("Chat history cleared.") + "\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                    break;
                case "anbieter":
                case "providers":
                    response = build_ki_providers_menu(bot.jid ?? "");
                    break;
                case "system":
                    if (args != null && args.length > 0) {
                        registry.set_setting("bot_%d_ai_system".printf(bot.id), args);
                        response = _("System prompt updated:") + "\n%s\n\n".printf(args) + build_ki_menu(bot.id, bot.jid ?? "");
                    } else {
                        string? current = registry.get_setting("bot_%d_ai_system".printf(bot.id));
                        response = _("Current system prompt:") + "\n%s\n\n".printf(current ?? _("(default)")) +
                            _("Change with:") + "\n/ki system <new prompt>\n\n" +
                            _("Example:") + "\n/ki system You are a friendly assistant.\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                    }
                    break;
                case "setup":
                    if (args == null) {
                        response = build_ki_setup_menu(bot.jid ?? "");
                    } else {
                        // Parse: <provider> <key> <model>
                        string[] setup_parts = args.split(" ", 3);
                        if (setup_parts.length < 3) {
                            response = build_ki_setup_help(setup_parts[0], bot.jid ?? "");
                        } else {
                            string provider = setup_parts[0].strip();
                            string api_key = setup_parts[1].strip();
                            string model = setup_parts[2].strip();
                            if (provider == "" || model == "") {
                                response = build_ki_setup_menu(bot.jid ?? "");
                            } else if (!ai.has_provider_preset(provider)) {
                                response = _("Unknown AI provider.") + "\n\n" + build_ki_setup_menu(bot.jid ?? "");
                            } else if (ai.provider_requires_api_key(provider) && (api_key == "" || api_key == "-")) {
                                response = _("API key is required for this provider.") + "\n\n" +
                                    build_ki_setup_help(provider, bot.jid ?? "");
                            } else {
                                response = ai.configure_preset(bot.id, provider, api_key, model, true) +
                                    "\n\n" + _("Next steps:") + "\n/ki on  - " + _("Activate AI") + "\n/ki system <prompt>  - " + _("Set system prompt");
                            }
                        }
                    }
                    break;
                case "modell":
                case "model":
                    if (args != null && args.length > 0) {
                        registry.set_setting("bot_%d_ai_model".printf(bot.id), args);
                        response = _("Model changed: %s").printf(args) + "\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                    } else {
                        string? current_model = registry.get_setting("bot_%d_ai_model".printf(bot.id));
                        string? current_type = registry.get_setting("bot_%d_ai_type".printf(bot.id));
                        response = _("Current model: %s").printf(current_model ?? _("(not set)")) + "\n\n" +
                            build_ki_models_help(current_type ?? "openai", bot.jid ?? "");
                    }
                    break;
                default:
                    response = _("Unknown: /ki %s").printf(action) + "\n\n" + build_ki_menu(bot.id, bot.jid ?? "");
                    break;
            }
        }

        if (!BotUtils.has_permission(bot, "admin")) {
            response += "\n\n" + admin_permission_hint();
        }

        if (from_str != "") {
            session_pool.send_message_for_bot(bot.id, from_str, response);
        }
    }

    // Build the KI main menu
    private string build_ki_menu(int bot_id, string jid = "") {
        bool enabled = ai.is_enabled(bot_id);
        string? ai_type = registry.get_setting("bot_%d_ai_type".printf(bot_id));
        string? model = registry.get_setting("bot_%d_ai_model".printf(bot_id));
        bool configured = registry.get_setting("bot_%d_ai_endpoint".printf(bot_id)) != null;

        var sb = new StringBuilder();
        sb.append(_("AI Assistant") + "\n");
        sb.append("════════════════════\n\n");

        // Status
        sb.append(_("Status: %s").printf(enabled ? _("active") : _("off")) + "\n");
        if (configured) {
            sb.append(_("Provider: %s").printf(ai_type ?? "?") + "\n");
            sb.append(_("Model: %s").printf(model ?? "?") + "\n");
        } else {
            sb.append(_("(Not yet configured)") + "\n");
        }

        sb.append("\n────────────────────\n");
        sb.append(_("Commands:") + "\n\n");

        if (!configured) {
            if (jid != "") {
                sb.append(cmd_uri(jid, "/ki%20setup") + " \u2014 " + _("Set up AI") + "\n");
                sb.append(cmd_uri(jid, "/ki%20providers") + " \u2014 " + _("Show all providers") + "\n");
            } else {
                sb.append("/ki setup       - " + _("Set up AI") + "\n");
                sb.append("/ki providers   - " + _("Show all providers") + "\n");
            }
        } else {
            if (jid != "") {
                if (enabled) {
                    sb.append(cmd_uri(jid, "/ki%20off") + " \u2014 " + _("Turn off AI") + "\n");
                } else {
                    sb.append(cmd_uri(jid, "/ki%20on") + " \u2014 " + _("Turn on AI") + "\n");
                }
                sb.append(cmd_uri(jid, "/ki%20status") + " \u2014 " + _("Current configuration") + "\n");
                sb.append(cmd_uri(jid, "/ki%20model") + " \u2014 " + _("Show/change model") + "\n");
                sb.append(cmd_uri(jid, "/ki%20clear") + " \u2014 " + _("Clear chat history") + "\n");
                sb.append(cmd_uri(jid, "/ki%20providers") + " \u2014 " + _("Switch provider") + "\n");
                sb.append(cmd_uri(jid, "/ki%20setup") + " \u2014 " + _("Set up again") + "\n");
            } else {
                if (enabled) {
                    sb.append("/ki off         - " + _("Turn off AI") + "\n");
                } else {
                    sb.append("/ki on          - " + _("Turn on AI") + "\n");
                }
                sb.append("/ki status      - " + _("Current configuration") + "\n");
                sb.append("/ki model       - " + _("Show/change model") + "\n");
                sb.append("/ki system      - " + _("Show/change system prompt") + "\n");
                sb.append("/ki clear       - " + _("Clear chat history") + "\n");
                sb.append("/ki providers   - " + _("Switch provider") + "\n");
                sb.append("/ki setup       - " + _("Set up again") + "\n");
            }
        }

        sb.append("\n────────────────────\n");
        if (jid != "") {
            sb.append(_("Back:") + " " + cmd_uri(jid, "/help"));
        } else {
            sb.append(_("Back: /help"));
        }
        return sb.str;
    }

    // Build the KI setup menu (choose provider)
    private string build_ki_setup_menu(string jid = "") {
        var sb = new StringBuilder();
        sb.append(_("AI Setup") + "\n");
        sb.append("════════════════════\n\n");
        sb.append(_("Choose a provider:") + "\n\n");
        sb.append("  /ki setup openai <KEY> <MODEL>\n");
        sb.append("  /ki setup claude <KEY> <MODEL>\n");
        sb.append("  /ki setup gemini <KEY> <MODEL>\n");
        sb.append("  /ki setup groq <KEY> <MODEL>\n");
        sb.append("  /ki setup mistral <KEY> <MODEL>\n");
        sb.append("  /ki setup deepseek <KEY> <MODEL>\n");
        sb.append("  /ki setup perplexity <KEY> <MODEL>\n");
        sb.append("  /ki setup xai <KEY> <MODEL>\n");
        sb.append("  /ki setup ollama - <MODEL>\n");
        sb.append("  /ki setup openclaw <TOKEN> agent\n");
        sb.append("\n────────────────────\n");
        sb.append(_("Details for a provider:") + "\n");
        sb.append("  /ki setup openai  " + _("(without key shows help)") + "\n\n");
        if (jid != "") {
            sb.append(_("All providers with models:") + " " + cmd_uri(jid, "/ki%20providers") + "\n");
            sb.append(_("Back:") + " " + cmd_uri(jid, "/ki"));
        } else {
            sb.append(_("All providers with models: /ki providers") + "\n");
            sb.append(_("Back: /ki"));
        }
        return sb.str;
    }

    // Build help for a specific provider setup
    private string build_ki_setup_help(string provider, string jid = "") {
        string p = provider.ascii_down();
        var sb = new StringBuilder();
        sb.append(_("AI Setup: %s").printf(p) + "\n");
        sb.append("════════════════════\n\n");

        switch (p) {
            case "openai":
                sb.append("API-Key: https://platform.openai.com/api-keys\n\n");
                sb.append(_("Models:") + " gpt-4o, gpt-4o-mini, gpt-4-turbo, o1\n\n");
                sb.append(_("Example:") + "\n/ki setup openai sk-abc123 gpt-4o\n");
                break;
            case "claude":
                sb.append("API-Key: https://console.anthropic.com/\n\n");
                sb.append(_("Models:") + " claude-sonnet-4-20250514, claude-3-haiku, claude-3-opus\n\n");
                sb.append(_("Example:") + "\n/ki setup claude sk-ant-abc123 claude-sonnet-4-20250514\n");
                break;
            case "gemini":
                sb.append("API-Key: https://aistudio.google.com/apikey\n\n");
                sb.append(_("Models:") + " gemini-2.5-flash-lite, gemini-2.5-flash, gemini-2.5-pro\n\n");
                sb.append(_("Example:") + "\n/ki setup gemini AIza-abc123 gemini-2.5-flash-lite\n");
                break;
            case "groq":
                sb.append("API-Key: https://console.groq.com/keys\n\n");
                sb.append(_("Models:") + " llama-3.3-70b-versatile, mixtral-8x7b, gemma-7b\n\n");
                sb.append(_("Example:") + "\n/ki setup groq gsk_abc123 llama-3.3-70b-versatile\n");
                break;
            case "mistral":
                sb.append("API-Key: https://console.mistral.ai/\n\n");
                sb.append(_("Models:") + " mistral-large-latest, mistral-medium, mistral-small\n\n");
                sb.append(_("Example:") + "\n/ki setup mistral abc123 mistral-large-latest\n");
                break;
            case "deepseek":
                sb.append("API-Key: https://platform.deepseek.com/\n\n");
                sb.append(_("Models:") + " deepseek-chat, deepseek-coder\n\n");
                sb.append(_("Example:") + "\n/ki setup deepseek abc123 deepseek-chat\n");
                break;
            case "perplexity":
                sb.append("API-Key: https://www.perplexity.ai/settings/api\n\n");
                sb.append(_("Models:") + " sonar-medium, sonar-small\n\n");
                sb.append(_("Example:") + "\n/ki setup perplexity pplx-abc123 sonar-medium\n");
                break;
            case "xai":
                sb.append("API-Key: https://console.x.ai/\n\n");
                sb.append(_("Models:") + " grok-4.20-reasoning, grok-4, grok-3\n\n");
                sb.append(_("Example:") + "\n/ki setup xai xai_abc123 grok-4.20-reasoning\n");
                break;
            case "ollama":
                sb.append(_("No API key needed (local, use - as placeholder)") + "\n\n");
                sb.append(_("Models:") + " llama3, phi3, gemma, mistral, codellama, ...\n");
                sb.append(_("(Depends on your Ollama installation)") + "\n\n");
                sb.append(_("Example:") + "\n/ki setup ollama - llama3\n");
                break;
            case "openclaw":
                sb.append("Endpoint: http://localhost:18789/hooks/agent\n\n");
                sb.append(_("OpenClaw is an autonomous AI agent/orchestrator.") + "\n");
                sb.append(_("It manages multiple AI models independently.") + "\n\n");
                sb.append(_("Token: from your OpenClaw Gateway config") + "\n\n");
                sb.append(_("Example:") + "\n/ki setup openclaw oc_abc123 agent\n");
                break;
            default:
                sb.append(_("Unknown provider: %s").printf(p) + "\n\n");
                sb.append(_("Available: openai, claude, gemini, groq, mistral, deepseek, perplexity, xai, ollama, openclaw") + "\n");
                break;
        }

        sb.append("\n────────────────────\n");
        if (jid != "") {
            sb.append(_("All providers:") + " " + cmd_uri(jid, "/ki%20setup") + "\n");
            sb.append(_("Back:") + " " + cmd_uri(jid, "/ki"));
        } else {
            sb.append(_("All providers: /ki setup") + "\n");
            sb.append(_("Back: /ki"));
        }
        return sb.str;
    }

    // Build the providers overview menu
    private string build_ki_providers_menu(string jid = "") {
        var sb = new StringBuilder();
        sb.append(_("AI Providers") + "\n");
        sb.append("════════════════════\n\n");
        sb.append("1. OpenAI     - gpt-4o, gpt-4o-mini, o1\n");
        sb.append("2. Claude     - claude-sonnet-4-20250514, claude-3-haiku\n");
        sb.append("3. Gemini     - gemini-2.5-flash-lite, gemini-2.5-flash\n");
        sb.append("4. Groq       - llama-3.3-70b-versatile, mixtral-8x7b\n");
        sb.append("5. Mistral    - mistral-large-latest, mistral-medium\n");
        sb.append("6. DeepSeek   - deepseek-chat, deepseek-coder\n");
        sb.append("7. Perplexity - sonar-medium, sonar-small\n");
        sb.append("8. xAI/Grok   - grok-4.20-reasoning, grok-4\n");
        sb.append("9. Ollama     - llama3, phi3, gemma (" + _("local") + ")\n");
        sb.append("10. OpenClaw  - " + _("Autonomous AI agent") + "\n");
        sb.append("\n────────────────────\n");
        sb.append(_("Details & Setup:") + "\n");
        sb.append("  /ki setup openai\n");
        sb.append("  /ki setup groq\n");
        sb.append("  /ki setup ollama\n");
        sb.append("  ... " + _("etc.") + "\n\n");
        if (jid != "") {
            sb.append(_("Back:") + " " + cmd_uri(jid, "/ki"));
        } else {
            sb.append(_("Back: /ki"));
        }
        return sb.str;
    }

    // Build help for available models for current provider
    private string build_ki_models_help(string ai_type, string jid = "") {
        var sb = new StringBuilder();
        sb.append(_("Change model:") + "\n/ki model <name>\n\n");
        sb.append(_("Available models for %s:").printf(ai_type) + "\n");
        switch (ai_type.ascii_down()) {
            case "openai":
                sb.append("  gpt-4o, gpt-4o-mini, gpt-4-turbo, o1\n");
                break;
            case "claude":
                sb.append("  claude-sonnet-4-20250514, claude-3-haiku, claude-3-opus\n");
                break;
            case "gemini":
                sb.append("  gemini-2.0-flash, gemini-1.5-pro, gemini-pro\n");
                break;
            case "groq":
                sb.append("  llama-3.3-70b-versatile, mixtral-8x7b, gemma-7b\n");
                break;
            case "mistral":
                sb.append("  mistral-large-latest, mistral-medium, mistral-small\n");
                break;
            case "deepseek":
                sb.append("  deepseek-chat, deepseek-coder\n");
                break;
            case "perplexity":
                sb.append("  sonar-medium, sonar-small\n");
                break;
            case "ollama":
                sb.append("  llama3, phi3, gemma, mistral, codellama, ...\n");
                break;
            case "openclaw":
                sb.append("  agent " + _("(OpenClaw manages models internally)") + "\n");
                break;
            default:
                sb.append("  " + _("(unknown provider)") + "\n");
                break;
        }
        if (jid != "") {
            sb.append("\n" + _("Back:") + " " + cmd_uri(jid, "/ki"));
        } else {
            sb.append("\n" + _("Back: /ki"));
        }
        return sb.str;
    }

    // Handle /telegram commands
    private async void handle_telegram_command(BotInfo bot, string from_str, string? action, string? args) {
        if (stopped) return;
        string response;

        if (action == null) {
            // Telegram main menu
            response = build_telegram_menu(bot.id, bot.jid ?? "");
        } else {
            switch (action.ascii_down()) {
                case "on":
                    if (!telegram.is_enabled(bot.id)) {
                        string? token = registry.get_secret_setting("bot_%d_tg_token".printf(bot.id));
                        if (token == null) {
                            response = _("Telegram not configured.") + "\n\n" + build_telegram_setup_menu(bot.jid ?? "");
                        } else {
                            registry.set_setting("bot_%d_tg_enabled".printf(bot.id), "true");
                            bool polling = start_telegram_polling_for_bot(bot, from_str);
                            response = _("Telegram bridge activated!");
                            if (!polling) response += "\n" + _("Incoming updates are disabled for this bot.");
                            response += "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                        }
                    } else {
                        response = _("Telegram bridge is already active.") + "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                    }
                    break;
                case "off":
                    telegram.disable(bot.id);
                    response = _("Telegram bridge deactivated.") + "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                    break;
                case "status":
                    response = telegram.get_status(bot.id) + "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                    break;
                case "test":
                    response = yield telegram.test_connection(bot.id);
                    if (stopped) return;
                    response += "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                    break;
                case "setup":
                    if (args == null) {
                        response = build_telegram_setup_menu(bot.jid ?? "");
                    } else {
                        string[] setup_parts = args.split(" ", 3);
                        if (setup_parts.length < 2) {
                            response = _("Not enough parameters.") + "\n\n" + build_telegram_setup_menu(bot.jid ?? "");
                        } else {
                            string tg_token = setup_parts[0].strip();
                            string chat_id = setup_parts[1].strip();
                            string mode = setup_parts.length > 2 ? setup_parts[2].strip().ascii_down() : "bridge";
                            if (tg_token == "" || chat_id == "") {
                                response = _("Not enough parameters.") + "\n\n" + build_telegram_setup_menu(bot.jid ?? "");
                            } else if (!BotUtils.is_valid_telegram_mode(mode)) {
                                response = _("Invalid mode: %s").printf(mode) + "\n\n" +
                                    _("Available: bridge, forward") + "\n\n" + build_telegram_setup_menu(bot.jid ?? "");
                            } else {
                                telegram.configure(bot.id, tg_token, chat_id, mode, true);
                                bool polling = start_telegram_polling_for_bot(bot, from_str);
                                response = (polling ? _("Telegram bridge configured and started!") : _("Telegram bridge configured.")) +
                                    "\n" + _("Chat ID: %s").printf(chat_id) +
                                    "\n" + _("Mode: %s").printf(mode);
                                if (!polling) response += "\n" + _("Incoming updates are disabled for this bot.");
                                response += "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                            }
                        }
                    }
                    break;
                case "modus":
                case "mode":
                    if (args != null && args.length > 0) {
                        string new_mode = args.ascii_down();
                        if (BotUtils.is_valid_telegram_mode(new_mode)) {
                            registry.set_setting("bot_%d_tg_mode".printf(bot.id), new_mode);
                            response = _("Mode changed: %s").printf(new_mode) + "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                        } else {
                            response = _("Invalid mode: %s").printf(new_mode) + "\n\n" +
                                _("Available: bridge, forward") + "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                        }
                    } else {
                        string? current_mode = registry.get_setting("bot_%d_tg_mode".printf(bot.id));
                        response = _("Current mode: %s").printf(current_mode ?? "bridge") + "\n\n" +
                            _("Change mode:") + "\n" +
                            "  /telegram mode bridge   - " + _("Messages in both directions") + "\n" +
                            "  /telegram mode forward  - " + _("Only XMPP -> Telegram") + "\n\n" +
                            build_telegram_menu(bot.id, bot.jid ?? "");
                    }
                    break;
                default:
                    response = _("Unknown: /telegram %s").printf(action) + "\n\n" + build_telegram_menu(bot.id, bot.jid ?? "");
                    break;
            }
        }

        if (!BotUtils.has_permission(bot, "admin")) {
            response += "\n\n" + admin_permission_hint();
        }

        if (from_str != "") {
            session_pool.send_message_for_bot(bot.id, from_str, response);
        }
    }

    private bool start_telegram_polling_for_bot(BotInfo bot, string fallback_jid) {
        if (!BotUtils.can_receive_updates_for_enabled_account(bot, registry)) {
            telegram.stop_polling(bot.id);
            return false;
        }

        string target_jid = bot.owner_jid != null && bot.owner_jid.strip() != ""
            ? bot.owner_jid.strip()
            : fallback_jid;
        telegram.start_polling(bot.id, target_jid);
        return true;
    }

    private string admin_permission_hint() {
        return _("Configuration actions require the admin permission.");
    }

    // Build the Telegram main menu
    private string build_telegram_menu(int bot_id, string jid = "") {
        bool enabled = telegram.is_enabled(bot_id);
        bool configured = registry.get_secret_setting("bot_%d_tg_token".printf(bot_id)) != null;
        string? mode = registry.get_setting("bot_%d_tg_mode".printf(bot_id));

        var sb = new StringBuilder();
        sb.append(_("Telegram Bridge") + "\n");
        sb.append("════════════════════\n\n");

        sb.append(_("Status: %s").printf(enabled ? _("active") : _("off")) + "\n");
        if (configured) {
            sb.append(_("Mode: %s").printf(mode ?? "bridge") + "\n");
        } else {
            sb.append(_("(Not yet configured)") + "\n");
        }

        sb.append("\n────────────────────\n");
        sb.append(_("Commands:") + "\n\n");

        if (!configured) {
            if (jid != "") {
                sb.append(cmd_uri(jid, "/telegram%20setup") + " \u2014 " + _("Set up Telegram") + "\n");
            } else {
                sb.append("/telegram setup    - " + _("Set up Telegram") + "\n");
            }
        } else {
            if (jid != "") {
                if (enabled) {
                    sb.append(cmd_uri(jid, "/telegram%20off") + " \u2014 " + _("Turn off bridge") + "\n");
                } else {
                    sb.append(cmd_uri(jid, "/telegram%20on") + " \u2014 " + _("Turn on bridge") + "\n");
                }
                sb.append(cmd_uri(jid, "/telegram%20status") + " \u2014 " + _("Current configuration") + "\n");
                sb.append(cmd_uri(jid, "/telegram%20mode") + " \u2014 " + _("Show/change mode") + "\n");
                sb.append(cmd_uri(jid, "/telegram%20test") + " \u2014 " + _("Test connection") + "\n");
                sb.append(cmd_uri(jid, "/telegram%20setup") + " \u2014 " + _("Set up again") + "\n");
            } else {
                if (enabled) {
                    sb.append("/telegram off      - " + _("Turn off bridge") + "\n");
                } else {
                    sb.append("/telegram on       - " + _("Turn on bridge") + "\n");
                }
                sb.append("/telegram status   - " + _("Current configuration") + "\n");
                sb.append("/telegram mode     - " + _("Show/change mode") + "\n");
                sb.append("/telegram test     - " + _("Test connection") + "\n");
                sb.append("/telegram setup    - " + _("Set up again") + "\n");
            }
        }

        sb.append("\n────────────────────\n");
        if (jid != "") {
            sb.append(_("Back:") + " " + cmd_uri(jid, "/help"));
        } else {
            sb.append(_("Back: /help"));
        }
        return sb.str;
    }

    // Build the Telegram setup guide
    private string build_telegram_setup_menu(string jid = "") {
        var sb = new StringBuilder();
        sb.append(_("Telegram Setup") + "\n");
        sb.append("════════════════════\n\n");
        sb.append(_("Step 1: Get a bot token") + "\n");
        sb.append("  " + _("Open Telegram and message @BotFather") + "\n");
        sb.append("  " + _("Send: /newbot") + "\n");
        sb.append("  " + _("You will receive a token (e.g. 123456:ABC-DEF1234)") + "\n\n");
        sb.append(_("Step 2: Find your chat ID") + "\n");
        sb.append("  " + _("Message @userinfobot on Telegram") + "\n");
        sb.append("  " + _("It will reply with your chat ID (e.g. 987654321)") + "\n\n");
        sb.append(_("Step 3: Configure here") + "\n");
        sb.append("  /telegram setup <TOKEN> <CHAT_ID>\n\n");
        sb.append(_("Example:") + "\n");
        sb.append("  /telegram setup 123456:ABC-DEF1234 987654321\n\n");
        sb.append(_("Optional with mode:") + "\n");
        sb.append("  /telegram setup <TOKEN> <CHAT_ID> bridge\n");
        sb.append("  /telegram setup <TOKEN> <CHAT_ID> forward\n\n");
        sb.append("  bridge  = " + _("Messages in both directions (default)") + "\n");
        sb.append("  forward = " + _("Only XMPP -> Telegram") + "\n");
        sb.append("\n────────────────────\n");
        if (jid != "") {
            sb.append(_("Back:") + " " + cmd_uri(jid, "/telegram"));
        } else {
            sb.append(_("Back: /telegram"));
        }
        return sb.str;
    }

    // Forward message to AI and send response back
    private async void handle_ai_message(int bot_id, string from_str, string text) {
        if (stopped || from_str == "") return;

        string? response = yield ai.ask(bot_id, from_str, text);
        if (stopped) return;
        if (response != null && response.strip() != "") {
            session_pool.send_message_for_bot(bot_id, from_str, response);
        } else {
            session_pool.send_message_for_bot(bot_id, from_str, _("AI returned an empty response."));
        }
    }

    private async void handle_ai_groupchat_message(int bot_id, string room_jid, string text, string sender_nick) {
        if (stopped || room_jid == "") return;

        string prompt = sender_nick != "" ? "Room: %s\nSender: %s\nMessage: %s".printf(room_jid, sender_nick, text) :
            "Room: %s\nMessage: %s".printf(room_jid, text);
        string runtime_context =
            "You are currently replying inside an XMPP group chat. " +
            "Answer only the current message, not the whole room history. " +
            "Use the same language as the sender. " +
            "Sound like a helpful chat participant, not like a generic AI assistant. " +
            "Keep replies short unless the sender explicitly asks for details. " +
            "Do not claim to be human. Do not invent private knowledge about room members. " +
            "If the message is ambiguous, ask one concise clarifying question.";
        string? response = yield ai.ask_with_context(bot_id, room_jid, prompt, runtime_context);
        if (stopped) return;
        if (response != null && response.strip() != "") {
            session_pool.send_groupchat_for_bot(bot_id, room_jid, response);
        } else {
            session_pool.send_groupchat_for_bot(bot_id, room_jid, _("AI returned an empty response."));
        }
    }

    // Handle /clear command - clear bot chat history
    private async void handle_clear_command(BotInfo bot, string from_str, string? scope) {
        if (stopped) return;
        var sb = new StringBuilder();

        // 1. Clear AI conversation history (RAM)
        ai.clear_history(bot.id, "all");
        sb.append(_("AI conversation history cleared.") + "\n");

        // 2. Clear local message database for the bot conversation
        if (bot.jid != null) {
            try {
                var jid = new Jid(bot.jid);
                Jid? owner_jid = null;
                if (bot.owner_jid != null) {
                    owner_jid = new Jid(bot.owner_jid);
                }
                // Find the conversation in DinoX's local DB
                var conversation_manager = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
                bool found = false;
                foreach (var account in app.stream_interactor.get_accounts()) {
                    if (owner_jid == null || !account.bare_jid.equals(owner_jid)) continue;
                    var conv = conversation_manager.get_conversation(jid.bare_jid, account, Conversation.Type.CHAT);
                    if (conv != null) {
                        conversation_manager.clear_conversation_history(conv, false);
                        sb.append(_("Local chat history cleared.") + "\n");
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    sb.append(_("No local conversation found for %s.").printf(bot.jid) + "\n");
                }
            } catch (Error e) {
                sb.append(_("Error clearing local history: %s").printf(e.message) + "\n");
            }
        }

        // 3. Clear MAM archive via ejabberd REST API if configured
        // BUG-09 fix: Explicit warning that ejabberd only supports global MAM delete
        // Note: ejabberd has no per-user MAM delete, only global (all users).
        // We only delete if the admin explicitly requests it, as it affects ALL users.
        if (scope != null && scope.ascii_down() == "mam") {
            if (ejabberd_api != null && ejabberd_api.is_configured()) {
                sb.append("⚠️ " + _("WARNING: ejabberd does NOT support per-user MAM deletion.") + "\n");
                sb.append(_("This will delete the ENTIRE server message archive for ALL users on this domain!") + "\n");
                sb.append(_("Deleting server message archive (ALL users)...") + "\n");
                session_pool.send_message_for_bot(bot.id, from_str, sb.str);
                sb.truncate(0);

                var result = yield ejabberd_api.delete_mam_messages();
                if (stopped) return;
                if (result.success) {
                    sb.append(_("Server message archive (MAM) cleared.") + "\n");
                } else {
                    sb.append(_("MAM delete failed: %s").printf(result.error_message ?? "unknown") + "\n");
                }
            } else {
                sb.append(_("ejabberd API not configured.") + "\n");
            }
        }

        sb.append("\n" + _("Done! Chat history has been cleaned up."));
        session_pool.send_message_for_bot(bot.id, from_str, sb.str);
    }

    // Handle slash commands for dedicated bots
    private string? handle_dedicated_command(BotInfo bot, string body) {
        string cmd = body.split(" ")[0].ascii_down();
        switch (cmd) {
            case "/help":
                return build_help_menu(bot);
            case "/start":
                return _("Welcome! I am %s.").printf(bot.name ?? "Bot") + "\n\n" + build_help_menu(bot);
            case "/info":
                string ki_status = ai.is_enabled(bot.id) ? _("active") : _("off");
                string tg_status = telegram.is_enabled(bot.id) ? _("active") : _("off");
                return _("Bot: %s").printf(bot.name ?? "?") + "\n" +
                    "JID: %s\n".printf(bot.jid ?? "?") +
                    _("Mode: %s").printf(bot.mode ?? "?") + "\n" +
                    _("AI: %s").printf(ki_status) + "\n" +
                    "Telegram: %s\n\n".printf(tg_status) +
                    "────────────────────\n" + _("Back: /help");
            default:
                return null; // Unknown command - let it be handled by webhook/getUpdates
        }
    }

    // Build an xmpp: URI that auto-sends a command when clicked
    private string cmd_uri(string jid, string command) {
        string encoded = command.replace(" ", "%20");
        return "xmpp:" + jid + "?message;body=" + encoded;
    }

    // Build the main help menu
    private string build_help_menu(BotInfo bot) {
        string jid = bot.jid ?? "";
        var sb = new StringBuilder();
        sb.append("%s\n".printf(bot.name ?? "Bot"));
        sb.append("════════════════════\n\n");

        // Status overview
        bool ki_on = ai.is_enabled(bot.id);
        bool tg_on = telegram.is_enabled(bot.id);
        bool ki_configured = registry.get_setting("bot_%d_ai_endpoint".printf(bot.id)) != null;
        bool tg_configured = registry.get_secret_setting("bot_%d_tg_token".printf(bot.id)) != null;

        sb.append(_("Status:") + "\n");
        if (ki_configured) {
            string? ai_type = registry.get_setting("bot_%d_ai_type".printf(bot.id));
            string? model = registry.get_setting("bot_%d_ai_model".printf(bot.id));
            sb.append("  " + _("AI: %s (%s / %s)").printf(ki_on ? _("active") : _("off"), ai_type ?? "?", model ?? "?") + "\n");
        } else {
            sb.append("  " + _("AI: not configured") + "\n");
        }
        if (tg_configured) {
            sb.append("  " + _("Telegram: %s").printf(tg_on ? _("active") : _("off")) + "\n");
        } else {
            sb.append("  " + _("Telegram: not configured") + "\n");
        }

        sb.append("\n────────────────────\n");
        sb.append(_("Menus:") + "\n\n");
        if (jid != "") {
            sb.append(cmd_uri(jid, "/ki") + " \u2014 " + _("AI assistant setup & control") + "\n");
            sb.append(cmd_uri(jid, "/telegram") + " \u2014 " + _("Telegram bridge setup & control") + "\n");
            sb.append(cmd_uri(jid, "/api") + " \u2014 " + _("HTTP API & webhook documentation") + "\n");
        } else {
            sb.append("/ki         - " + _("AI assistant setup & control") + "\n");
            sb.append("/telegram   - " + _("Telegram bridge setup & control") + "\n");
            sb.append("/api        - " + _("HTTP API & webhook documentation") + "\n");
        }

        sb.append("\n────────────────────\n");
        sb.append(_("Basic commands:") + "\n\n");
        if (jid != "") {
            sb.append(cmd_uri(jid, "/info") + " \u2014 " + _("Bot details") + "\n");
            sb.append(cmd_uri(jid, "/clear") + " \u2014 " + _("Clear chat history") + "\n");
        } else {
            sb.append("/info       - " + _("Bot details") + "\n");
            sb.append("/clear      - " + _("Clear chat history") + "\n");
        }

        // Custom commands from DB
        var commands = registry.get_bot_commands(bot.id);
        if (commands.size > 0) {
            sb.append("\n────────────────────\n");
            sb.append(_("Custom commands:") + "\n\n");
            foreach (var c in commands) {
                if (jid != "") {
                    sb.append(cmd_uri(jid, "/" + c.command) + " \u2014 " + c.description + "\n");
                } else {
                    sb.append("/%s - %s\n".printf(c.command, c.description));
                }
            }
        }

        // Quick actions based on status
        sb.append("\n────────────────────\n");
        sb.append(_("Quick start:") + "\n\n");
        if (!ki_configured) {
            if (jid != "") {
                sb.append(cmd_uri(jid, "/ki%20setup") + " \u2014 " + _("Set up AI now") + "\n");
            } else {
                sb.append("/ki setup   - " + _("Set up AI now") + "\n");
            }
        } else if (!ki_on) {
            if (jid != "") {
                sb.append(cmd_uri(jid, "/ki%20on") + " \u2014 " + _("Turn on AI") + "\n");
            } else {
                sb.append("/ki on      - " + _("Turn on AI") + "\n");
            }
        } else {
            sb.append(_("Just send a message for the AI!") + "\n");
        }
        if (!tg_configured) {
            if (jid != "") {
                sb.append(cmd_uri(jid, "/telegram%20setup") + " \u2014 " + _("Set up Telegram now") + "\n");
            } else {
                sb.append("/telegram setup  - " + _("Set up Telegram now") + "\n");
            }
        } else if (!tg_on) {
            if (jid != "") {
                sb.append(cmd_uri(jid, "/telegram%20on") + " \u2014 " + _("Turn on Telegram") + "\n");
            } else {
                sb.append("/telegram on     - " + _("Turn on Telegram") + "\n");
            }
        }

        return sb.str;
    }

    // ════════════════════════════════════════════════════════════
    // /api command handler — HTTP API documentation & examples
    // ════════════════════════════════════════════════════════════

    private void handle_api_command(BotInfo bot, string from_str, string? action, string? args) {
        string response;

        if (action == null) {
            response = build_api_menu(bot);
        } else {
            switch (action.ascii_down()) {
                case "nachrichten":
                case "messages":
                    response = build_api_messages_menu(bot);
                    break;
                case "webhook":
                case "webhooks":
                    response = build_api_webhook_menu(bot);
                    break;
                case "verwaltung":
                case "management":
                    response = build_api_management_menu(bot);
                    break;
                case "erweitert":
                case "advanced":
                    response = build_api_advanced_menu(bot);
                    break;
                case "auth":
                case "token":
                    response = build_api_auth_menu(bot);
                    break;
                case "beispiele":
                case "examples":
                    response = build_api_quick_examples(bot);
                    break;
                case "server":
                    response = handle_api_server_command(bot, args);
                    break;
                default:
                    response = _("Unknown: /api %s").printf(action) + "\n\n" + build_api_menu(bot);
                    break;
            }
        }

        if (from_str != "") {
            session_pool.send_message_for_bot(bot.id, from_str, response);
        }
    }

    // API main menu
    private string build_api_menu(BotInfo bot) {
        var sb = new StringBuilder();
        sb.append("HTTP API\n");
        sb.append("════════════════════\n\n");
        sb.append(_("Base URL: %s://localhost:%d").printf(
            app.settings.api_mode == "network" ? "https" : "http",
            app.settings.api_port) + "\n");
        sb.append("Bot-ID: %d\n".printf(bot.id));
        sb.append("JID: %s\n".printf(bot.jid ?? "?"));

        string jid = bot.jid ?? "";

        sb.append("\n────────────────────\n");
        sb.append(_("Topics:") + "\n\n");
        if (jid != "") {
            sb.append(cmd_uri(jid, "/api%20auth") + " \u2014 " + _("Authentication & token") + "\n");
            sb.append(cmd_uri(jid, "/api%20messages") + " \u2014 " + _("Send & receive messages") + "\n");
            sb.append(cmd_uri(jid, "/api%20webhook") + " \u2014 " + _("Set up webhook") + "\n");
            sb.append(cmd_uri(jid, "/api%20management") + " \u2014 " + _("Create, delete, manage bots") + "\n");
            sb.append(cmd_uri(jid, "/api%20advanced") + " \u2014 " + _("Files, reactions, rooms") + "\n");
            sb.append(cmd_uri(jid, "/api%20examples") + " \u2014 " + _("Quick start with curl") + "\n");
            sb.append(cmd_uri(jid, "/api%20server") + " \u2014 " + _("API server settings") + "\n");
        } else {
            sb.append("/api auth         - " + _("Authentication & token") + "\n");
            sb.append("/api messages     - " + _("Send & receive messages") + "\n");
            sb.append("/api webhook      - " + _("Set up webhook") + "\n");
            sb.append("/api management   - " + _("Create, delete, manage bots") + "\n");
            sb.append("/api advanced     - " + _("Files, reactions, rooms") + "\n");
            sb.append("/api examples     - " + _("Quick start with curl") + "\n");
            sb.append("/api server       - " + _("API server settings") + "\n");
        }

        sb.append("\n────────────────────\n");
        if (jid != "") {
            sb.append(_("Back:") + " " + cmd_uri(jid, "/help"));
        } else {
            sb.append(_("Back: /help"));
        }
        return sb.str;
    }

    // API: Authentication
    private string build_api_auth_menu(BotInfo bot) {
        var sb = new StringBuilder();
        sb.append(_("API: Authentication") + "\n");
        sb.append("════════════════════\n\n");

        sb.append(_("All bot endpoints require a Bearer token.") + "\n\n");
        sb.append("Header:\n");
        sb.append("  Authorization: Bearer <TOKEN>\n\n");

        sb.append(_("Tokens are shown only once at creation.") + "\n");
        sb.append(_("Regenerate tokens in Bot Manager or with POST /bot/token.") + "\n\n");

        sb.append("────────────────────\n");
        sb.append(_("Example:") + "\n\n");
        sb.append("curl -H \"Authorization: Bearer <TOKEN>\" \\\n");
        sb.append("  %s/getMe\n\n".printf(api_base_url()));

        sb.append("────────────────────\n");
        sb.append(_("Management endpoints (no token needed):") + "\n");
        sb.append("  /bot/create, /bot/list, /bot/delete\n");
        sb.append("  " + _("(only accessible from localhost)") + "\n\n");

        sb.append(_("Token management:") + "\n\n");
        sb.append("  " + _("Regenerate token:") + "\n");
        sb.append("  curl -X POST %s/token \\\n".printf(api_base_url()));
        sb.append("    -d '{\"id\":%d}'\n\n".printf(bot.id));
        sb.append("  " + _("Revoke token:") + "\n");
        sb.append("  curl -X POST %s/revoke \\\n".printf(api_base_url()));
        sb.append("    -d '{\"id\":%d}'\n".printf(bot.id));

        sb.append("\n────────────────────\n");
        { string _jid = bot.jid ?? ""; if (_jid != "") { sb.append(_("Back:") + " " + cmd_uri(_jid, "/api")); } else { sb.append(_("Back: /api")); } }
        return sb.str;
    }

    // API: Messages (send/receive)
    private string build_api_messages_menu(BotInfo bot) {
        string tok = "<TOKEN>";

        var sb = new StringBuilder();
        sb.append(_("API: Messages") + "\n");
        sb.append("════════════════════\n\n");
        sb.append(_("Required scopes:") + "\n");
        sb.append("  sendMessage: send_message / muc_send\n");
        sb.append("  getUpdates: receive_updates\n");
        sb.append("  getMe/getInfo: " + _("authenticated token") + "\n");
        sb.append(_("Target restrictions also apply to outbound requests.") + "\n\n");

        // sendMessage
        sb.append(_("1. Send message") + "\n");
        sb.append("   POST /bot/sendMessage\n\n");
        sb.append("curl -X POST %s/sendMessage \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\" \\\n".printf(tok));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\n");
        sb.append("    \"to\": \"recipient@server.tld\",\n");
        sb.append("    \"text\": \"Hello World!\"\n");
        sb.append("  }'\n\n");

        sb.append("   " + _("Parameters:") + "\n");
        sb.append("   to    - " + _("Recipient JID (required)") + "\n");
        sb.append("   text  - " + _("Message text (required)") + "\n");
        sb.append("   type  - \"chat\" " + _("(default)") + " " + _("or") + " \"groupchat\"\n\n");

        sb.append("────────────────────\n\n");

        // getUpdates
        sb.append(_("2. Receive messages (polling)") + "\n");
        sb.append("   GET /bot/getUpdates\n\n");
        sb.append("curl %s/getUpdates \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\"\n\n".printf(tok));

        sb.append("   " + _("With offset (acknowledge previous):") + "\n");
        sb.append("curl %s/getUpdates?offset=42 \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\"\n\n".printf(tok));

        sb.append("   " + _("With long polling:") + "\n");
        sb.append("curl %s/getUpdates?timeout=30 \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\"\n\n".printf(tok));

        sb.append("   " + _("Parameters:") + "\n");
        sb.append("   offset - " + _("Updates from this ID (optional)") + "\n");
        sb.append("   limit  - " + _("Max count, 1-100 (default: 100)") + "\n");
        sb.append("   timeout - " + _("Long polling seconds, 0-30 (optional)") + "\n\n");

        sb.append("   " + _("Response format:") + "\n");
        sb.append("   {\"ok\":true,\"result\":[{\n");
        sb.append("     \"update_id\": 1,\n");
        sb.append("     \"type\": \"message\",\n");
        sb.append("     \"data\": {\n");
        sb.append("       \"from\": \"sender@server.tld\",\n");
        sb.append("       \"body\": \"Hello!\",\n");
        sb.append("       \"timestamp\": 1707900000\n");
        sb.append("     }\n");
        sb.append("   }]}\n");

        sb.append("\n────────────────────\n");
        { string _jid = bot.jid ?? ""; if (_jid != "") { sb.append(_("Next:") + " " + cmd_uri(_jid, "/api%20webhook") + "\n"); } else { sb.append(_("Next: /api webhook") + "\n"); } }
        { string _jid = bot.jid ?? ""; if (_jid != "") { sb.append(_("Back:") + " " + cmd_uri(_jid, "/api")); } else { sb.append(_("Back: /api")); } }
        return sb.str;
    }

    // API: Webhooks
    private string build_api_webhook_menu(BotInfo bot) {
        string tok = "<TOKEN>";
        bool wh_enabled = bot.webhook_enabled;
        string? wh_url = bot.webhook_url;

        var sb = new StringBuilder();
        sb.append("API: Webhooks\n");
        sb.append("════════════════════\n\n");
        sb.append(_("Required scope: webhook") + "\n\n");

        sb.append(_("Status: %s").printf(wh_enabled ? _("active") : _("off")) + "\n");
        if (wh_url != null) {
            sb.append("URL: %s\n".printf(WebhookDispatcher.sanitize_url_for_log(wh_url)));
        }

        sb.append("\n────────────────────\n\n");

        // setWebhook
        sb.append(_("1. Set up webhook") + "\n");
        sb.append("   POST /bot/setWebhook\n\n");
        sb.append("curl -X POST %s/setWebhook \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\" \\\n".printf(tok));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\"url\": \"https://my-server.com/webhook\"}'\n\n");
        sb.append("   " + _("Response contains a secret for signature verification.") + "\n\n");

        sb.append("────────────────────\n\n");

        // deleteWebhook
        sb.append(_("2. Remove webhook") + "\n");
        sb.append("   POST /bot/deleteWebhook\n\n");
        sb.append("curl -X POST %s/deleteWebhook \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\"\n\n".printf(tok));

        sb.append("────────────────────\n\n");

        // Webhook format
        sb.append(_("3. Webhook format") + "\n\n");
        sb.append("   " + _("DinoX sends POST to your URL with:") + "\n\n");
        sb.append("   Header:\n");
        sb.append("   X-Bot-Signature: sha256=<HMAC-SHA256>\n");
        sb.append("   X-Bot-Delivery: <UUID>\n");
        sb.append("   Content-Type: application/json\n\n");
        sb.append("   Body:\n");
        sb.append("   {\"update_type\":\"message\",\"data\":{\n");
        sb.append("     \"from\":\"sender@...\",\n");
        sb.append("     \"body\":\"Message\",\n");
        sb.append("     \"timestamp\":1707900000\n");
        sb.append("   }}\n\n");
        sb.append("   " + _("Verify signature (Python):") + "\n");
        sb.append("   import hmac, hashlib\n");
        sb.append("   sig = hmac.new(secret.encode(),\n");
        sb.append("     body, hashlib.sha256).hexdigest()\n");
        sb.append("   assert header == 'sha256=' + sig\n");

        sb.append("\n────────────────────\n");
        { string _jid = bot.jid ?? ""; if (_jid != "") { sb.append(_("Back:") + " " + cmd_uri(_jid, "/api")); } else { sb.append(_("Back: /api")); } }
        return sb.str;
    }

    // API: Management (create, delete, list bots)
    private string build_api_management_menu(BotInfo bot) {
        var sb = new StringBuilder();
        sb.append(_("API: Bot Management") + "\n");
        sb.append("════════════════════\n\n");
        sb.append(_("(No token needed - localhost only)") + "\n\n");

        // Create
        sb.append(_("1. Create bot") + "\n");
        sb.append("   POST /bot/create\n\n");
        sb.append("curl -X POST %s/create \\\n".printf(api_base_url()));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\n");
        sb.append("    \"name\": \"My Bot\",\n");
        sb.append("    \"account\": \"user@server.tld\",\n");
        sb.append("    \"mode\": \"dedicated\"\n");
        sb.append("  }'\n\n");
        sb.append("   " + _("Local modes: personal, dedicated. Create CloudBots at cloud.dinox.im and manage them in the Bot Manager with a management token.") + "\n\n");

        sb.append("────────────────────\n\n");

        // List
        sb.append(_("2. List bots") + "\n");
        sb.append("   GET /bot/list\n\n");
        sb.append("curl %s/list\n\n".printf(api_base_url()));
        sb.append("   " + _("Filter by account:") + "\n");
        sb.append("curl %s/list?account=user@server.tld\n\n".printf(api_base_url()));

        sb.append("────────────────────\n\n");

        // Delete
        sb.append(_("3. Delete bot") + "\n");
        sb.append("   POST /bot/delete\n\n");
        sb.append("curl -X POST %s/delete \\\n".printf(api_base_url()));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\"id\": %d}'\n\n".printf(bot.id));

        sb.append("────────────────────\n\n");

        // Activate/Deactivate
        sb.append(_("4. Activate/deactivate bot") + "\n");
        sb.append("   POST /bot/activate\n\n");
        sb.append("curl -X POST %s/activate \\\n".printf(api_base_url()));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\"id\": %d, \"active\": true}'\n\n".printf(bot.id));

        sb.append("────────────────────\n\n");

        // Health
        sb.append("5. Health-Check\n");
        sb.append("   GET /health\n\n");
        sb.append("curl %s/health\n".printf(api_root_url()));

        sb.append("\n────────────────────\n");
        { string _jid = bot.jid ?? ""; if (_jid != "") { sb.append(_("Back:") + " " + cmd_uri(_jid, "/api")); } else { sb.append(_("Back: /api")); } }
        return sb.str;
    }

    // API: Advanced features (files, reactions, rooms, commands)
    private string build_api_advanced_menu(BotInfo bot) {
        string tok = "<TOKEN>";

        var sb = new StringBuilder();
        sb.append(_("API: Advanced Features") + "\n");
        sb.append("════════════════════\n\n");
        sb.append(_("Required scopes:") + "\n");
        sb.append("  sendFile: file_send\n");
        sb.append("  sendReaction: send_message\n");
        sb.append("  joinRoom/leaveRoom: muc_join\n");
        sb.append("  setCommands: admin\n");
        sb.append("  getCommands: receive_updates\n");
        sb.append(_("Target restrictions also apply to outbound requests.") + "\n\n");

        // sendFile
        sb.append(_("1. Send file") + "\n");
        sb.append("   POST /bot/sendFile\n\n");
        sb.append("curl -X POST %s/sendFile \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\" \\\n".printf(tok));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\n");
        sb.append("    \"to\": \"recipient@server.tld\",\n");
        sb.append("    \"url\": \"https://example.com/image.jpg\",\n");
        sb.append("    \"caption\": \"Check this out!\"\n");
        sb.append("  }'\n\n");

        sb.append("────────────────────\n\n");

        // sendReaction
        sb.append(_("2. Send reaction") + "\n");
        sb.append("   POST /bot/sendReaction\n\n");
        sb.append("curl -X POST %s/sendReaction \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\" \\\n".printf(tok));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\n");
        sb.append("    \"to\": \"recipient@server.tld\",\n");
        sb.append("    \"message_id\": \"msg-uuid-123\",\n");
        sb.append("    \"reaction\": \"👍\"\n");
        sb.append("  }'\n\n");

        sb.append("────────────────────\n\n");

        // joinRoom / leaveRoom
        sb.append(_("3. Join group room") + "\n");
        sb.append("   POST /bot/joinRoom\n\n");
        sb.append("curl -X POST %s/joinRoom \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\" \\\n".printf(tok));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\"room\": \"room@conference.server.tld\"}'\n\n");

        sb.append("   " + _("Leave: POST /bot/leaveRoom") + "\n\n");

        sb.append("────────────────────\n\n");

        // setCommands / getCommands
        sb.append(_("4. Register bot commands") + "\n");
        sb.append("   POST /bot/setCommands\n\n");
        sb.append("curl -X POST %s/setCommands \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer %s\" \\\n".printf(tok));
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\"commands\": [\n");
        sb.append("    {\"command\": \"weather\", \"description\": \"Get weather\"},\n");
        sb.append("    {\"command\": \"news\", \"description\": \"Show news\"}\n");
        sb.append("  ]}'\n\n");

        sb.append("   " + _("Get commands: GET /bot/getCommands") + "\n\n");

        sb.append("────────────────────\n\n");

        // getInfo / getMe
        sb.append(_("5. Bot information") + "\n");
        sb.append("   GET /bot/getMe\n");
        sb.append("   GET /bot/getInfo  " + _("(incl. commands & sessions)") + "\n\n");
        sb.append("curl -H \"Authorization: Bearer %s\" \\\n".printf(tok));
        sb.append("  %s/getInfo\n".printf(api_base_url()));

        sb.append("\n────────────────────\n");
        { string _jid = bot.jid ?? ""; if (_jid != "") { sb.append(_("Back:") + " " + cmd_uri(_jid, "/api")); } else { sb.append(_("Back: /api")); } }
        return sb.str;
    }

    // Quick-start examples
    // API: Server Settings
    private string handle_api_server_command(BotInfo bot, string? args) {
        var settings = app.settings;

        if (args == null || args.strip() == "") {
            return build_api_server_menu(bot);
        }

        string cmd = args.strip().ascii_down();

        if (cmd == "local" || cmd == "lokal") {
            settings.api_mode = "local";
            return _("API server mode set to 'local'.") + "\n" +
                   _("The server listens only on localhost (127.0.0.1).") + "\n\n" +
                   _("Changes applied automatically.") + "\n\n" +
                   _("Back: /api server");
        }

        if (cmd == "network" || cmd == "netzwerk") {
            settings.api_mode = "network";
            string cert_info;
            if (settings.api_tls_cert == "" || settings.api_tls_key == "") {
                cert_info = _("A self-signed certificate will be generated automatically.");
            } else {
                cert_info = _("Custom certificate configured.");
            }
            return _("API server mode set to 'network'.") + "\n" +
                   _("The server listens on all interfaces (0.0.0.0) with TLS.") + "\n" +
                   "%s\n\n".printf(cert_info) +
                   _("Changes applied automatically.") + "\n\n" +
                   _("Back: /api server");
        }

        if (cmd.has_prefix("port ")) {
            string port_str = cmd.substring(5).strip();
            int port;
            if (parse_api_port(port_str, out port)) {
                settings.api_port = port;
                return _("API port set to %d.").printf(port) + "\n\n" +
                    _("Changes applied automatically.") + "\n\n" + _("Back: /api server");
            } else {
                return _("Invalid port: %s").printf(port_str) + "\n" +
                    _("Allowed: 1024-65535") + "\n\n" + _("Back: /api server");
            }
        }

        if (cmd.has_prefix("cert ")) {
            string cert_path = args.strip().substring(5).strip();
            if (cert_path.ascii_down() == "auto" || cert_path == "") {
                settings.api_tls_cert = "";
                settings.api_tls_key = "";
                return _("TLS certificate set to automatic (self-signed).") + "\n\n" +
                    _("Changes applied automatically.") + "\n\n" + _("Back: /api server");
            }
            settings.api_tls_cert = cert_path;
            return _("TLS certificate path set: %s").printf(cert_path) + "\n\n" +
                _("Don't forget to also set the key:") + "\n/api server key /path/to/key.pem\n\n" +
                _("Back: /api server");
        }

        if (cmd.has_prefix("key ")) {
            string key_path = args.strip().substring(4).strip();
            if (key_path == "") {
                return _("Invalid key path.") + "\n" +
                    _("Use /api server cert auto to reset TLS settings.") + "\n\n" +
                    _("Back: /api server");
            }
            settings.api_tls_key = key_path;
            return _("TLS key path set: %s").printf(key_path) + "\n\n" +
                _("Changes applied automatically.") + "\n\n" + _("Back: /api server");
        }

        if (cmd == "status") {
            return build_api_server_status();
        }

        if (cmd == "renew" || cmd == "renew-cert" || cmd == "zertifikat-erneuern") {
            string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
            string cert_path = Path.build_filename(cert_dir, "server.crt");
            string key_path = Path.build_filename(cert_dir, "server.key");

            // Delete old cert
            CertGen.delete_cert(cert_path, key_path);

            // Generate new one
            int ret = CertGen.generate_self_signed_cert(cert_path, key_path, "DinoX API Server");
            if (ret < 0) {
                return _("Error creating certificate (code: %d).").printf(ret) + "\n\n" + _("Back: /api server");
            }
            trigger_api_server_restart();
            return _("New self-signed certificate created!") + "\n" +
                   _("Path: %s").printf(cert_path) + "\n\n" +
                   _("Server will restart automatically with the new certificate.") + "\n\n" +
                   _("Back: /api server");
        }

        if (cmd == "delete-cert" || cmd == "zertifikat-loeschen") {
            string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
            string cert_path = Path.build_filename(cert_dir, "server.crt");
            string key_path = Path.build_filename(cert_dir, "server.key");
            CertGen.delete_cert(cert_path, key_path);
            trigger_api_server_restart();
            return _("Self-signed certificate deleted.") + "\n\n" +
                   _("A new one will be generated on next start in network mode.") + "\n\n" +
                   _("Back: /api server");
        }

        return _("Unknown: /api server %s").printf(args) + "\n\n" + build_api_server_menu(bot);
    }

    private bool parse_api_port(string raw, out int port) {
        port = 0;
        string text = raw.strip();
        if (text == "") return false;
        if (text.length > 5) return false;
        for (int i = 0; i < text.length; i++) {
            char c = text[i];
            if (c < '0' || c > '9') return false;
        }
        int64 parsed = int64.parse(text);
        if (parsed < 1024 || parsed > 65535) return false;
        port = (int) parsed;
        return true;
    }

    private void trigger_api_server_restart() {
        var settings = app.settings;
        if (settings.api_tls_cert == "") {
            settings.api_tls_cert = " ";
            settings.api_tls_cert = "";
        } else {
            string cert = settings.api_tls_cert;
            settings.api_tls_cert = "";
            settings.api_tls_cert = cert;
        }
    }

    private string build_api_server_menu(BotInfo bot) {
        var settings = app.settings;
        string mode = settings.api_mode;
        int port = settings.api_port;
        string cert = settings.api_tls_cert;
        string key = settings.api_tls_key;

        var sb = new StringBuilder();
        sb.append(_("API: Server Settings") + "\n");
        sb.append("════════════════════\n\n");
        if (!BotUtils.has_permission(bot, "admin")) {
            sb.append(admin_permission_hint() + "\n\n");
        }

        // Current status
        sb.append(_("Current:") + "\n");
        sb.append("  " + _("Mode: %s").printf(mode == "network" ? _("Network (0.0.0.0 + TLS)") : _("Local (127.0.0.1)")) + "\n");
        sb.append("  " + _("Port: %d").printf(port) + "\n");
        if (mode == "network") {
            if (cert == "" || key == "") {
                sb.append("  TLS: " + _("Automatic (self-signed)") + "\n");
                // Check if auto-cert exists
                string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
                string auto_cert = Path.build_filename(cert_dir, "server.crt");
                bool valid = CertGen.check_cert_valid(auto_cert) == 1;
                sb.append("  " + _("Certificate: %s").printf(valid ? _("present and valid") : _("will be generated on start")) + "\n");
            } else {
                sb.append("  TLS: " + _("Custom certificate configured.") + "\n");
            }
        }
        sb.append("  URL: %s://localhost:%d\n".printf(mode == "network" ? "https" : "http", port));

        sb.append("\n────────────────────\n");
        sb.append(_("Change mode:") + "\n\n");
        sb.append("/api server local      - " + _("Localhost only (no TLS)") + "\n");
        sb.append("/api server network    - " + _("All interfaces (with TLS)") + "\n");

        sb.append("\n────────────────────\n");
        sb.append(_("Configuration:") + "\n\n");
        sb.append("/api server port <nr>  - " + _("Change port (1024-65535)") + "\n");
        sb.append("/api server status     - " + _("Detailed status") + "\n");

        if (mode == "network") {
            sb.append("\n────────────────────\n");
            sb.append(_("TLS Certificate:") + "\n\n");
            sb.append("/api server cert <path>     - " + _("Custom certificate (PEM)") + "\n");
            sb.append("/api server key <path>      - " + _("Custom key (PEM)") + "\n");
            sb.append("/api server cert auto       - " + _("Back to self-signed") + "\n");
            sb.append("/api server renew-cert      - " + _("Generate new cert") + "\n");
            sb.append("/api server delete-cert     - " + _("Delete cert") + "\n");
        }

        sb.append("\n────────────────────\n");
        sb.append(_("Note: Changes are applied automatically.") + "\n\n");
        sb.append(_("Back: /api"));
        return sb.str;
    }

    private string build_api_server_status() {
        var settings = app.settings;
        string mode = settings.api_mode;
        int port = settings.api_port;

        var sb = new StringBuilder();
        sb.append(_("API: Server Status") + "\n");
        sb.append("════════════════════\n\n");

        sb.append(_("Mode: %s").printf(mode == "network" ? _("Network (HTTPS)") : _("Local (HTTP)")) + "\n");
        sb.append(_("Port: %d").printf(port) + "\n");
        sb.append("Bind: %s\n".printf(mode == "network" ? "0.0.0.0" : "127.0.0.1"));
        sb.append(_("Protocol: %s").printf(mode == "network" ? "HTTPS (TLS)" : "HTTP") + "\n");

        if (mode == "network") {
            string cert = settings.api_tls_cert;
            string key = settings.api_tls_key;

            sb.append("\n" + _("TLS Configuration:") + "\n");
            if (cert == "" || key == "") {
                sb.append("  " + _("Mode: Automatic (self-signed)") + "\n");
                string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
                string auto_cert = Path.build_filename(cert_dir, "server.crt");
                bool valid = CertGen.check_cert_valid(auto_cert) == 1;
                sb.append("  " + _("Status: %s").printf(valid ? _("Valid") : _("Not found / expired")) + "\n");
            } else {
                sb.append("  " + _("Mode: Custom certificate") + "\n");
                bool valid = CertGen.check_cert_valid(cert) == 1;
                sb.append("  " + _("Status: %s").printf(valid ? _("Valid") : _("Invalid / expired")) + "\n");
            }

            sb.append("\n" + _("Note for curl:") + "\n");
            sb.append("  " + _("Self-signed:") + " curl -k https://host:%d/health\n".printf(port));
            sb.append("  " + _("Custom cert:") + " curl https://host:%d/health\n".printf(port));
        } else {
            sb.append("\n" + _("No TLS (localhost-only is secure).") + "\n");
            sb.append(_("For external access: nginx reverse proxy") + "\n");
            sb.append(_("or activate network mode.") + "\n");
        }

        sb.append("\n────────────────────\n");
        sb.append(_("Back: /api server"));
        return sb.str;
    }

    private string build_api_quick_examples(BotInfo bot) {
        string tok = "<TOKEN>";

        var sb = new StringBuilder();
        sb.append(_("API: Quick Start") + "\n");
        sb.append("════════════════════\n\n");

        sb.append("TOKEN=\"%s\"\n\n".printf(tok));
        sb.append(_("Required scopes:") + " send_message, receive_updates, webhook\n");
        sb.append(_("Target restrictions also apply to outbound requests.") + "\n\n");

        sb.append("# 1. " + _("Test bot") + "\n");
        sb.append("curl -H \"Authorization: Bearer $TOKEN\" \\\n");
        sb.append("  %s/getMe\n\n".printf(api_base_url()));

        sb.append("# 2. " + _("Send message") + "\n");
        sb.append("curl -X POST %s/sendMessage \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer $TOKEN\" \\\n");
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\"to\":\"user@server.tld\",\"text\":\"Hello!\"}'\n\n");

        sb.append("# 3. " + _("Get messages") + "\n");
        sb.append("curl -H \"Authorization: Bearer $TOKEN\" \\\n");
        sb.append("  %s/getUpdates\n\n".printf(api_base_url()));

        sb.append("# 4. " + _("Set up webhook") + "\n");
        sb.append("curl -X POST %s/setWebhook \\\n".printf(api_base_url()));
        sb.append("  -H \"Authorization: Bearer $TOKEN\" \\\n");
        sb.append("  -H \"Content-Type: application/json\" \\\n");
        sb.append("  -d '{\"url\":\"https://my-server.com/hook\"}'\n\n");

        sb.append("# 5. Health-Check\n");
        sb.append("curl %s/health\n\n".printf(api_root_url()));

        sb.append("────────────────────\n\n");

        sb.append(_("Python example:") + "\n\n");
        sb.append("import requests\n\n");
        sb.append("TOKEN = \"%s\"\n".printf(tok));
        sb.append("API = \"%s\"\n".printf(api_base_url()));
        sb.append("H = {\"Authorization\": f\"Bearer {TOKEN}\"}\n\n");
        sb.append("# " + _("Send message") + "\n");
        sb.append("requests.post(f\"{API}/sendMessage\",\n");
        sb.append("  headers=H,\n");
        sb.append("  json={\"to\": \"user@server.tld\",\n");
        sb.append("        \"text\": \"Hello from Python!\"})\n\n");
        sb.append("# " + _("Get messages") + "\n");
        sb.append("r = requests.get(f\"{API}/getUpdates\",\n");
        sb.append("  headers=H)\n");
        sb.append("for update in r.json()[\"result\"]:\n");
        sb.append("  print(update[\"data\"][\"body\"])\n\n");

        sb.append("────────────────────\n\n");

        sb.append(_("All endpoints:") + "\n\n");
        sb.append("  Bot:  getMe, getInfo\n");
        sb.append("  Msg:  sendMessage, getUpdates\n");
        sb.append("  File: sendFile\n");
        sb.append("  Hook: setWebhook, deleteWebhook\n");
        sb.append("  Cmd:  setCommands, getCommands\n");
        sb.append("  MUC:  joinRoom, leaveRoom\n");
        sb.append("  React: sendReaction\n");
        sb.append("  Mgmt: create, list, delete,\n");
        sb.append("         activate, token, revoke\n");
        sb.append("  Sys:  health, ejabberd/settings,\n");
        sb.append("         ejabberd/test\n");

        sb.append("\n────────────────────\n");
        { string _jid = bot.jid ?? ""; if (_jid != "") { sb.append(_("Back:") + " " + cmd_uri(_jid, "/api")); } else { sb.append(_("Back: /api")); } }
        return sb.str;
    }

    private string message_to_json(Entities.Message message, Conversation conversation) {
        var sb = new StringBuilder();
        sb.append("{");
        sb.append("\"from\":\"%s\"".printf(escape_json(message.from.to_string())));
        sb.append(",\"to\":\"%s\"".printf(escape_json(message.to.to_string())));
        sb.append(",\"body\":\"%s\"".printf(escape_json(message.body ?? "")));
        sb.append(",\"type\":\"%s\"".printf(conversation.type_ == Conversation.Type.GROUPCHAT ? "groupchat" : "chat"));
        sb.append(",\"stanza_id\":\"%s\"".printf(escape_json(message.stanza_id ?? "")));
        sb.append(",\"timestamp\":%ld".printf((long) (message.time ?? new DateTime.now_utc()).to_unix()));
        sb.append("}");
        return sb.str;
    }

    private string api_root_url() {
        string scheme = app.settings.api_mode == "network" ? "https" : "http";
        int port = app.settings.api_port;
        if (port < 1 || port > 65535) port = 7842;
        return "%s://localhost:%d".printf(scheme, port);
    }

    private string api_base_url() {
        return api_root_url() + "/bot";
    }

    // Delegate to shared BotUtils (BUG-05 fix)
    private static string escape_json(string s) {
        return BotUtils.escape_json(s);
    }

    // Listener for the message pipeline
    private class ReceivedMessageListener : MessageListener {
        public string[] after_actions_const = {};
        public override string action_group { get { return "BOT_FEATURES"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private WeakRef router;

        public ReceivedMessageListener(MessageRouter router) {
            this.router = WeakRef(router);
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            MessageRouter? current_router = router.get() as MessageRouter;
            if (current_router != null) current_router.on_message_received(message, conversation);
            return false; // Don't consume the message
        }
    }
}

}
