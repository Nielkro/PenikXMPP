using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino.Plugins.BotFeatures {

// Manages XMPP streams for bot accounts.
// In "personal" mode, bots share the user's existing stream.
// In "dedicated" mode, bots have their own XMPP sessions.
public class SessionPool : Object {
    private const size_t MAX_VCARD_AVATAR_BYTES = 128 * 1024;

    private class PendingMessage : Object {
        public string to_jid;
        public string body;
        public string? message_id;

        public PendingMessage(string to_jid, string body, string? message_id) {
            this.to_jid = to_jid;
            this.body = body;
            this.message_id = message_id;
        }
    }

    private class CredentialVerifyState : Object {
        public bool done = false;
        public bool success = false;
        public string error = "";
    }

    private Dino.Application app;
    private BotRegistry? registry;
    public BotOmemoManager? bot_omemo;
    private bool stopped = false;

    private bool runtime_available() {
        return !stopped && app.settings.bot_features_enabled;
    }

    private bool is_current_dedicated_stream(int bot_id, XmppStream stream) {
        return runtime_available() && dedicated_streams.has_key(bot_id) &&
            dedicated_streams[bot_id] == stream;
    }

    protected virtual async XmppStreamResult establish_dedicated_stream(
            Jid jid, Gee.List<XmppStreamModule> modules) {
        return yield Xmpp.establish_stream(jid, modules, null,
            (peer_cert, errors) => { return true; });
    }

    // Personal mode: bot_id -> Account
    private HashMap<int, Account> personal_bindings = new HashMap<int, Account>();

    // Dedicated mode: bot_id -> own XmppStream
    private HashMap<int, TlsXmppStream> dedicated_streams = new HashMap<int, TlsXmppStream>();
    private HashMap<int, bool> connecting = new HashMap<int, bool>();
    private HashMap<int, BotInfo> bot_infos = new HashMap<int, BotInfo>();
    private HashSet<int> dedicated_ready = new HashSet<int>();
    private HashMap<int, ArrayList<PendingMessage>> pending_messages = new HashMap<int, ArrayList<PendingMessage>>();

    // Signal fired when a dedicated bot stream is fully ready
    public signal void dedicated_bot_ready(int bot_id, BotInfo bot);

    // Signal fired when a dedicated bot receives a message
    public signal void dedicated_message_received(int bot_id, Xmpp.MessageStanza message);

    public SessionPool(Dino.Application app) {
        this.app = app;
    }

    public void set_registry(BotRegistry registry) {
        this.registry = registry;
    }

    public void set_bot_omemo(BotOmemoManager omemo) {
        this.bot_omemo = omemo;
    }

    public async string verify_dedicated_credentials(string jid_str, string password) {
        string trimmed_jid = jid_str.strip();
        string trimmed_password = password.strip();
        if (trimmed_jid == "" || trimmed_password == "") {
            return "Missing JID or password";
        }

        try {
            Jid bare_jid = new Jid(trimmed_jid);
            var state = new CredentialVerifyState();

            var sasl_module = new Sasl.Module(bare_jid.to_string(), trimmed_password);
            sasl_module.received_auth_failure.connect((stream, node) => {
                state.error = describe_sasl_failure(node);
                state.done = true;
                stream.disconnect.begin();
            });

            var modules = new ArrayList<XmppStreamModule>();
            modules.add(new Iq.Module());
            modules.add(sasl_module);
            modules.add(new Bind.Module("bot-verify"));
            modules.add(new Session.Module());
            modules.add(new StreamError.Module());

            XmppStreamResult result = yield Xmpp.establish_stream(
                bare_jid, modules, null,
                (peer_cert, errors) => { return true; }
            );
            if (result.stream == null) {
                return result.io_error != null ? result.io_error.message : "Could not create XMPP stream";
            }

            result.stream.stream_negotiated.connect((stream) => {
                state.success = true;
                state.done = true;
                stream.disconnect.begin();
            });

            run_credential_verify_loop.begin(result.stream, state);
            for (int i = 0; i < 100 && !state.done; i++) {
                Timeout.add(100, verify_dedicated_credentials.callback);
                yield;
            }

            if (!state.done) {
                result.stream.disconnect.begin();
                return "Timed out while verifying XMPP login";
            }
            return state.success ? "" : (state.error != "" ? state.error : "XMPP login verification failed");
        } catch (Error e) {
            return e.message;
        }
    }

    public void unbind(int bot_id) {
        personal_bindings.unset(bot_id);
        disconnect_dedicated(bot_id);
    }

    // Get the XMPP stream for a bot.
    public XmppStream? get_stream(BotInfo bot) {
        if (!runtime_available()) return null;
        if (bot.mode == "personal") {
            Account? account = personal_bindings[bot.id];
            if (account == null || !is_active_owner_account(bot, account)) {
                account = get_active_owner_account(bot);
                if (account != null) {
                    personal_bindings[bot.id] = account;
                } else {
                    personal_bindings.unset(bot.id);
                }
            }
            if (account != null) {
                return app.stream_interactor.get_stream(account);
            }
        }

        if (bot.mode == "dedicated") {
            // Return existing stream if connected
            if (dedicated_streams.has_key(bot.id)) {
                return dedicated_streams[bot.id];
            }
            // Auto-connect if not yet connected
            if (!connecting.has_key(bot.id) || !connecting[bot.id]) {
                connect_dedicated.begin(bot);
            }
            return null;
        }

        return null;
    }

    public Account? get_account_for_bot(BotInfo bot) {
        if (!runtime_available()) return null;
        if (bot.mode == "personal") {
            Account? account = personal_bindings[bot.id];
            if (account == null || !is_active_owner_account(bot, account)) {
                account = get_active_owner_account(bot);
                if (account != null) {
                    personal_bindings[bot.id] = account;
                } else {
                    personal_bindings.unset(bot.id);
                }
            }
            return account;
        }
        return null;
    }

    // Connect a dedicated bot to XMPP with its own stream
    public async bool connect_dedicated(BotInfo bot) {
        if (!runtime_available()) return false;
        string? raw_jid = bot.jid;
        string? raw_password = bot.bot_password;
        if (raw_jid == null || raw_jid.strip() == "" ||
                raw_password == null || raw_password.strip() == "") {
            warning("SessionPool: Bot %d has no JID or password for dedicated mode", bot.id);
            return false;
        }
        string bot_jid = raw_jid.strip();
        string bot_password = raw_password.strip();
        bot_infos[bot.id] = bot;

        if (bot.owner_jid != null && bot.owner_jid.strip() != "" &&
                !is_account_enabled(bot.owner_jid.strip())) {
            message("SessionPool: Not connecting dedicated bot %d because Botmother is disabled for %s",
                bot.id, bot.owner_jid.strip());
            return false;
        }

        if (dedicated_streams.has_key(bot.id)) {
            return true; // already connected or negotiating
        }

        if (connecting.has_key(bot.id) && connecting[bot.id]) {
            return true; // already connecting
        }
        connecting[bot.id] = true;

        // Pre-suppress subscription notification BEFORE connecting, so the
        // subscription request from ejabberd never reaches the systray.
        try {
            Jid suppress_jid = new Jid(bot_jid);
            var presence_mgr = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            if (bot.owner_jid != null) {
                Jid owner_jid = new Jid(bot.owner_jid);
                presence_mgr.suppress_subscription_notification_for_account_jid(owner_jid, suppress_jid);
                message("SessionPool: Pre-suppressed subscription for %s", bot_jid);
            }
        } catch (Error e) {
            // non-fatal
        }

        try {
            Jid bare_jid = new Jid(bot_jid);

            // Build minimal module set for bot operation
            var modules = new ArrayList<XmppStreamModule>();
            var sasl_module = new Sasl.Module(bare_jid.to_string(), bot_password);
            sasl_module.received_auth_failure.connect((stream, node) => {
                if (!is_current_dedicated_stream(bot.id, stream)) return;
                string failure = describe_sasl_failure(node);
                warning("SessionPool: Bot %d SASL auth failed for %s: %s",
                    bot.id, bot_jid, failure);
                mark_bot_auth_failed(bot.id, stream, failure);
            });
            modules.add(new Iq.Module());
            modules.add(sasl_module);
            modules.add(new Xep.StreamManagement.Module());
            modules.add(new Bind.Module("bot"));
            modules.add(new Session.Module());
            // ServiceDiscovery MUST come before modules that call add_feature()
            modules.add(new Xep.ServiceDiscovery.Module.with_identity("client", "bot", "DinoX Bot"));
            modules.add(new Presence.Module());
            modules.add(new Xmpp.MessageModule());
            modules.add(new Xep.Muc.Module());
            modules.add(new Xep.Ping.Module());
            modules.add(new StreamError.Module());
            modules.add(new Xep.DelayedDelivery.Module());
            modules.add(new Roster.Module());
            modules.add(new Xep.VCard.Module());

            // OMEMO: add PubSub + StreamModule for E2E encryption
            modules.add(new Xep.Pubsub.Module());
            if (bot_omemo != null) {
                bot_omemo.init_bot(bot.id);
                var omemo_module = bot_omemo.create_stream_module(bot.id);
                if (omemo_module != null) {
                    modules.add(omemo_module);
                    message("SessionPool: Added OMEMO module for bot %d (device_id=%u)",
                        bot.id, bot_omemo.get_device_id(bot.id));
                }
            }

            message("SessionPool: Connecting dedicated bot %d as %s ...", bot.id, bot_jid);

            XmppStreamResult result = yield establish_dedicated_stream(bare_jid, modules);
            // An already-started connect may finish after global shutdown. Its
            // old pool must never install that stream or start negotiation.
            if (!runtime_available() || (bot.owner_jid != null &&
                    !is_account_enabled(bot.owner_jid))) {
                if (result.stream != null) result.stream.disconnect.begin();
                connecting[bot.id] = false;
                return false;
            }

            if (result.stream != null) {
                int bot_id = bot.id;
                bot_infos[bot_id] = bot;

                // Set up callbacks BEFORE loop() starts processing
                // stream_negotiated fires when SASL+Bind are done
                result.stream.stream_negotiated.connect((stream) => {
                    on_bot_stream_ready(bot_id, stream);
                });

                // Listen for incoming messages
                result.stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY)
                    .received_message.connect((stream, msg_stanza) => {
                        on_dedicated_message(bot_id, msg_stanza);
                    });

                // Only accept subscriptions from the bot's owner
                string? owner_jid_str = bot.owner_jid;
                result.stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                    .received_subscription_request.connect((stream, jid) => {
                        if (!is_current_dedicated_stream(bot_id, stream)) return;
                        if (owner_jid_str != null && jid.bare_jid.to_string() == owner_jid_str) {
                            message("SessionPool: Bot %d approving subscription from owner %s", bot_id, jid.to_string());
                            stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                                .approve_subscription(stream, jid.bare_jid);
                            stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                                .request_subscription(stream, jid.bare_jid);
                        } else {
                            warning("SessionPool: Bot %d REJECTED subscription from non-owner %s (owner=%s)",
                                bot_id, jid.to_string(), owner_jid_str ?? "(null)");
                        }
                    });

                // Store stream now so it's available when negotiation completes
                dedicated_streams[bot_id] = result.stream;
                dedicated_ready.remove(bot_id);

                // Wire OMEMO signal handlers (bundle auto-session, device list cache)
                if (bot_omemo != null) {
                    bot_omemo.wire_signals(bot_id, result.stream);
                }

                message("SessionPool: Bot %d stream created, starting negotiation...", bot.id);

                // Run the stream event loop (handles SASL, Bind, then keeps alive)
                run_stream_loop.begin(bot.id, result.stream);

                connecting[bot.id] = false;
                return true;
            } else {
                string err = "unknown";
                if (result.io_error != null) err = result.io_error.message;
                warning("SessionPool: Failed to connect bot %d: %s", bot.id, err);
                connecting[bot.id] = false;
                return false;
            }
        } catch (Error e) {
            warning("SessionPool: Error connecting bot %d: %s", bot.id, e.message);
            connecting[bot.id] = false;
            return false;
        }
    }

    // Called when SASL + Bind negotiation is complete
    private void on_bot_stream_ready(int bot_id, XmppStream stream) {
        if (!is_current_dedicated_stream(bot_id, stream)) return;
        message("SessionPool: Bot %d fully negotiated and ready!", bot_id);
        on_bot_stream_ready_async.begin(bot_id, stream);
    }

    private async void on_bot_stream_ready_async(int bot_id, XmppStream stream) {
        if (!is_current_dedicated_stream(bot_id, stream)) return;
        // Send initial presence (online)
        stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
            .send_presence(stream, new Presence.Stanza());

        BotInfo? bot = bot_infos.has_key(bot_id) ? bot_infos[bot_id] : null;

        if (bot != null) {
            dedicated_ready.add(bot_id);
            dedicated_bot_ready(bot_id, bot);
            if (!is_current_dedicated_stream(bot_id, stream)) return;
            flush_pending_messages(bot_id);

            // Metadata/OMEMO publishes must not block the Botmother test console
            // or API send path. They can be slow or server-limited.
            publish_bot_metadata.begin(bot_id, stream, bot);
        }
    }

    private async void publish_bot_metadata(int bot_id, XmppStream stream, BotInfo bot) {
        if (!is_current_dedicated_stream(bot_id, stream)) return;
        if (bot_omemo != null && bot_omemo.is_initialized(bot_id)) {
            yield publish_bot_omemo(bot_id, stream);
            if (!is_current_dedicated_stream(bot_id, stream)) return;
        }

        if (bot.name != null) {
            yield publish_bot_vcard4(bot_id, stream, bot.name);
            if (!is_current_dedicated_stream(bot_id, stream)) return;
            yield publish_bot_vcard(bot_id, stream, bot.name);
        }
    }

    public void refresh_bot_metadata(BotInfo bot) {
        if (bot.mode != "dedicated" || !dedicated_streams.has_key(bot.id)) return;
        publish_bot_metadata.begin(bot.id, dedicated_streams[bot.id], bot);
    }

    /**
     * Publish the bot's OMEMO device list and bundle via PubSub.
     * Sequential to respect ejabberd c2s shaper rate limits.
     * Make-public runs fire-and-forget since it's not on the critical path.
     */
    private async void publish_bot_omemo(int bot_id, XmppStream stream) {
        uint32 device_id = bot_omemo.get_device_id(bot_id);
        if (device_id == 0) return;

        Jid? my_jid = stream.get_flag(Bind.Flag.IDENTITY) != null
            ? stream.get_flag(Bind.Flag.IDENTITY).my_jid : null;
        if (my_jid == null) {
            warning("SessionPool: Bot %d has no bound JID yet", bot_id);
            return;
        }

        message("SessionPool: Publishing OMEMO for bot %d (device_id=%u, jid=%s)",
            bot_id, device_id, my_jid.to_string());

        // 1. Device list first (small payload)
        yield publish_device_list(bot_id, stream, device_id);
        if (!is_current_dedicated_stream(bot_id, stream)) return;

        // 2. Then bundle (bigger payload with 100 pre-keys)
        yield bot_omemo.publish_bundle(bot_id, stream);

        message("SessionPool: Bot %d OMEMO publish complete", bot_id);
    }

    /** Publish device list and make node public (background-safe). */
    private async void publish_device_list(int bot_id, XmppStream stream, uint32 device_id) {
        var list_node = new StanzaNode.build("list", "eu.siacs.conversations.axolotl")
            .add_self_xmlns();
        var device_node = new StanzaNode.build("device", "eu.siacs.conversations.axolotl")
            .put_attribute("id", device_id.to_string());
        list_node.put_node(device_node);

        yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
            .publish(stream, null, "eu.siacs.conversations.axolotl.devicelist",
                     "current", list_node);
        if (!is_current_dedicated_stream(bot_id, stream)) return;
        message("SessionPool: Bot %d device list published", bot_id);

        // Make device list node publicly accessible (fire-and-forget)
        try_make_pubsub_node_public.begin(bot_id, stream, "eu.siacs.conversations.axolotl.devicelist");
    }

    /** Make a PubSub node publicly accessible so other clients can read it. */
    private async void try_make_pubsub_node_public(int bot_id, XmppStream stream, string node_id) {
        if (!is_current_dedicated_stream(bot_id, stream)) return;
        Xep.DataForms.DataForm? form = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
            .request_node_config(stream, null, node_id);
        if (!is_current_dedicated_stream(bot_id, stream) || form == null) return;
        foreach (Xep.DataForms.DataForm.Field field in form.fields) {
            if (field.var == "pubsub#access_model" && field.get_value_string() != Xep.Pubsub.ACCESS_MODEL_OPEN) {
                field.set_value_string(Xep.Pubsub.ACCESS_MODEL_OPEN);
                yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
                    .submit_node_config(stream, null, form, node_id);
                message("SessionPool: Made node %s public", node_id);
                break;
            }
        }
    }

    // Publish XEP-0292 vCard4 profile data through PEP for modern clients.
    private async void publish_bot_vcard4(int bot_id, XmppStream stream, string bot_name) {
        if (!is_current_dedicated_stream(bot_id, stream)) return;
        var pubsub = stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY);
        if (pubsub == null) return;

        var vcard4 = new Xep.VCard4.VCard4.create();
        vcard4.full_name = bot_name;
        vcard4.nickname = bot_name;

        bool standard_ok = yield pubsub.publish(stream, null, Xep.VCard4.NS_URI, "current", vcard4.node);
        if (!is_current_dedicated_stream(bot_id, stream)) return;
        bool legacy_ok = yield pubsub.publish(stream, null, Xep.VCard4.NODE_URI_LEGACY, "current", vcard4.node);

        if (standard_ok || legacy_ok) {
            message("SessionPool: Published vCard4 for bot %d", bot_id);
        } else {
            warning("SessionPool: Failed to publish vCard4 for bot %d", bot_id);
        }
    }

    // Publish a vCard with the bot's display name and avatar
    private async void publish_bot_vcard(int bot_id, XmppStream stream, string bot_name) {
        try {
            var vcard = new Xep.VCard.VCardInfo();
            vcard.full_name = bot_name;
            vcard.nickname = bot_name;

            // Load avatar from settings if available
            if (registry != null) {
                string? avatar_b64 = registry.get_setting("bot_avatar:%d".printf(bot_id));
                string? avatar_type = registry.get_setting("bot_avatar_type:%d".printf(bot_id));
                if (avatar_b64 != null && avatar_b64.length > 0) {
                    uint8[] avatar = GLib.Base64.decode(avatar_b64);
                    if (avatar.length <= MAX_VCARD_AVATAR_BYTES) {
                        vcard.photo = new GLib.Bytes(avatar);
                        vcard.photo_type = avatar_type ?? "image/png";
                        message("SessionPool: Publishing vCard with avatar for bot %d", bot_id);
                    } else {
                        warning("SessionPool: Skipping vCard avatar for bot %d because it is too large (%zu bytes)", bot_id, avatar.length);
                    }
                }
            }

            yield Xep.VCard.publish_vcard(stream, vcard);
            message("SessionPool: Published vCard for bot %d: %s", bot_id, bot_name);
        } catch (Error e) {
            warning("SessionPool: Failed to publish vCard for bot %d: %s", bot_id, e.message);
        }
    }

    private string describe_sasl_failure(StanzaNode node) {
        var parts = new ArrayList<string>();
        foreach (StanzaNode child in node.get_all_subnodes()) {
            string name = child.name ?? "";
            if (name == "text") {
                string? text = child.get_string_content();
                if (text != null && text.strip() != "") {
                    parts.add("text=%s".printf(text.strip()));
                }
            } else if (name != "") {
                parts.add(name);
            }
        }
        if (parts.size == 0) return node.to_string();
        return BotUtils.join_strings(", ", parts);
    }

    private void mark_bot_auth_failed(int bot_id, XmppStream stream, string failure) {
        if (!is_current_dedicated_stream(bot_id, stream) || registry == null) return;
        BotInfo? bot = registry.get_bot_by_id(bot_id);
        if (bot == null || bot.status != "active") return;
        registry.update_bot_status(bot_id, "disabled");
        registry.log_action(bot_id, "auth_failed_disabled", failure);
        registry.bot_status_changed(bot_id, "disabled");
    }

    private async void run_credential_verify_loop(TlsXmppStream stream, CredentialVerifyState state) {
        try {
            yield stream.loop();
            if (!state.done) {
                state.error = "Stream ended before negotiation";
                state.done = true;
            }
        } catch (IOError.CANCELLED e) {
            if (!state.done) {
                state.error = e.message;
                state.done = true;
            }
        } catch (Error e) {
            if (!state.done) {
                state.error = e.message;
                state.done = true;
            }
        }
    }

    // Run the stream loop to keep the connection alive and process stanzas
    private async void run_stream_loop(int bot_id, TlsXmppStream stream) {
        if (!is_current_dedicated_stream(bot_id, stream)) {
            stream.disconnect.begin();
            return;
        }
        try {
            yield stream.loop();
        } catch (IOError.CANCELLED e) {
            // Normal: stream was intentionally disconnected (bot toggled off)
            message("SessionPool: Bot %d stream cancelled (normal disconnect)", bot_id);
        } catch (Error e) {
            BotInfo? bot = bot_infos.has_key(bot_id) ? bot_infos[bot_id] : null;
            string jid_state = bot != null && bot.jid != null && bot.jid.strip() != "" ? bot.jid : "missing";
            string password_state = bot != null && bot.bot_password != null && bot.bot_password.strip() != "" ? "present" : "missing";
            warning("SessionPool: Bot %d stream error for %s (password=%s): %s",
                bot_id, jid_state, password_state, e.message);
        }
        // Stream disconnected. Only the current stream may clear the current
        // state; older overlapping loops can finish after a newer reconnect.
        if (dedicated_streams.has_key(bot_id) && dedicated_streams[bot_id] == stream) {
            dedicated_streams.unset(bot_id);
            dedicated_ready.remove(bot_id);
            connecting[bot_id] = false;
            message("SessionPool: Bot %d disconnected, will reconnect on next use", bot_id);
        } else {
            message("SessionPool: Ignored disconnect from stale stream for bot %d", bot_id);
        }
    }

    // Handle incoming messages on a dedicated bot stream
    private void on_dedicated_message(int bot_id, Xmpp.MessageStanza msg) {
        if (!runtime_available()) return;
        if (is_delayed_before_resume(bot_id, msg)) {
            message("SessionPool: Ignored delayed message for resumed bot %d", bot_id);
            return;
        }

        bool is_groupchat = msg.type_ == Xmpp.MessageStanza.TYPE_GROUPCHAT;
        if (is_groupchat && is_delayed_message(msg)) {
            message("SessionPool: Ignored delayed MUC message for bot %d", bot_id);
            return;
        }

        if (is_groupchat && is_own_muc_echo(bot_id, msg)) {
            return;
        }

        if (is_bot_control_message(msg)) {
            message("SessionPool: Ignored control message for bot %d", bot_id);
            return;
        }

        // Direct messages are only accepted from the bot's owner. Groupchat
        // messages are room traffic and are filtered later by MessageRouter.
        if (!is_groupchat && msg.from != null) {
            BotInfo? bot = bot_infos.has_key(bot_id) ? bot_infos[bot_id] : null;
            if (bot != null && bot.owner_jid != null) {
                string sender = msg.from.bare_jid.to_string();
                if (sender != bot.owner_jid) {
                    message("SessionPool: Bot %d ignored direct message from non-owner %s (owner=%s)",
                        bot_id, sender, bot.owner_jid);
                    return;
                }
            }
        }

        // Try OMEMO decryption first
        if (bot_omemo != null && bot_omemo.is_omemo_encrypted(msg)) {
            string? plaintext = bot_omemo.decrypt_message(bot_id, msg);
            if (plaintext != null) {
                msg.body = plaintext;
                message("SessionPool: Decrypted OMEMO message for bot %d", bot_id);
            } else {
                warning("SessionPool: OMEMO decryption failed for bot %d", bot_id);
                return; // drop undecryptable OMEMO messages
            }
        }

        if (msg.body == null || msg.body.strip() == "") return;
        // Emit signal so MessageRouter can handle it
        dedicated_message_received(bot_id, msg);
    }

    private bool is_bot_control_message(Xmpp.MessageStanza msg) {
        if (Xep.MessageRetraction.get_retract_id(msg) != null) return true;

        foreach (Xep.FallbackIndication.Fallback fallback in Xep.FallbackIndication.get_fallbacks(msg)) {
            if (fallback.ns_uri == Xep.MessageRetraction.NS_URI || fallback.ns_uri == Xep.MessageRetraction.NS_URI_0) {
                return true;
            }
        }

        return false;
    }

    private bool is_own_muc_echo(int bot_id, Xmpp.MessageStanza msg) {
        if (msg.from == null || !msg.from.is_full()) return false;
        XmppStream? stream = dedicated_streams.has_key(bot_id) ? dedicated_streams[bot_id] : null;
        if (stream == null) return false;

        Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (flag == null) return false;

        string? own_nick = flag.get_muc_nick(msg.from.bare_jid);
        return own_nick != null && msg.from.resourcepart == own_nick;
    }

    private bool is_delayed_before_resume(int bot_id, Xmpp.MessageStanza msg) {
        if (registry == null) return false;

        string? raw_cutoff = registry.get_setting("bot_ignore_delayed_before:%d".printf(bot_id));
        if (raw_cutoff == null || raw_cutoff.strip() == "") return false;

        int64 cutoff = 0;
        if (!int64.try_parse(raw_cutoff.strip(), out cutoff) || cutoff <= 0) return false;

        DateTime? delayed = Xep.DelayedDelivery.get_time_for_message(msg);
        return delayed != null && delayed.to_unix() < cutoff;
    }

    private bool is_delayed_message(Xmpp.MessageStanza msg) {
        return Xep.DelayedDelivery.get_time_for_message(msg) != null;
    }

    // Send a message from a dedicated bot to a JID (tries OMEMO first)
    public bool send_message_for_bot(int bot_id, string to_jid, string body, string? message_id = null) {
        if (!runtime_available()) return false;
        if (!dedicated_streams.has_key(bot_id) || !dedicated_ready.contains(bot_id)) {
            BotInfo? bot = bot_infos.has_key(bot_id) ? bot_infos[bot_id] : (registry != null ? registry.get_bot_by_id(bot_id) : null);
            if (bot == null || bot.status != "active") return false;

            queue_pending_message(bot_id, to_jid, body, message_id);
            if (!connecting.has_key(bot_id) || !connecting[bot_id]) {
                connect_dedicated.begin(bot);
            }
            message("SessionPool: Queued message for dedicated bot %d while stream connects", bot_id);
            return true;
        }
        var stream = dedicated_streams[bot_id];

        // Try OMEMO-encrypted send
        if (bot_omemo != null && bot_omemo.is_initialized(bot_id)) {
            try {
                Jid jid = new Jid(to_jid);
                bot_omemo.encrypt_and_send.begin(bot_id, stream, jid, body, message_id, (obj, res) => {
                    bool ok = bot_omemo.encrypt_and_send.end(res);
                    if (!is_current_dedicated_stream(bot_id, stream)) return;
                    if (!ok) {
                        // Fallback: send plaintext
                        warning("SessionPool: OMEMO send failed for bot %d, falling back to plaintext", bot_id);
                        send_plaintext(bot_id, stream, to_jid, body, message_id);
                    }
                });
                return true;
            } catch (Error e) {
                warning("SessionPool: OMEMO send error for bot %d: %s", bot_id, e.message);
            }
        }

        // Fallback: plaintext
        return send_plaintext(bot_id, stream, to_jid, body, message_id);
    }

    public async bool join_muc_for_bot(int bot_id, string room_jid, string? nick = null) {
        XmppStream? stream = yield wait_for_ready_dedicated_stream(bot_id);
        BotInfo? bot = bot_infos.has_key(bot_id) ? bot_infos[bot_id] : (registry != null ? registry.get_bot_by_id(bot_id) : null);
        if (stream == null || bot == null || bot.status != "active") return false;

        try {
            Jid room = new Jid(room_jid);
            string muc_nick = nick != null && nick.strip() != "" ? nick.strip() : (bot.name ?? "bot");
            var muc = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            Xep.Muc.JoinResult? result = yield muc.enter(stream, room.bare_jid, muc_nick, null, null, false, null);
            if (result == null) {
                warning("SessionPool: Bot %d failed to join MUC %s: no result", bot_id, room_jid);
                return false;
            }
            if (result.muc_error != null || result.stanza_error != null) {
                warning("SessionPool: Bot %d failed to join MUC %s: muc_error=%s stanza_error=%s",
                    bot_id, room_jid,
                    result.muc_error != null ? result.muc_error.to_string() : "none",
                    result.stanza_error ?? "none");
                return false;
            }
            message("SessionPool: Bot %d joined MUC %s as %s", bot_id, room.bare_jid.to_string(), muc_nick);
            return true;
        } catch (Error e) {
            warning("SessionPool: Bot %d failed to join MUC %s: %s", bot_id, room_jid, e.message);
            return false;
        }
    }

    public async void rejoin_saved_mucs_for_bot(BotInfo bot) {
        if (registry == null || bot.mode != "dedicated" || bot.status != "active") return;

        var rooms = BotUtils.get_muc_rooms(registry, bot.id);
        foreach (BotUtils.BotMucRoom entry in rooms) {
            if (entry.room_jid == "") continue;
            string? nick = entry.nick != "" ? entry.nick : bot.name;
            bool joined = yield join_muc_for_bot(bot.id, entry.room_jid, nick);
            if (joined) {
                message("SessionPool: Bot %d rejoined saved MUC %s", bot.id, entry.room_jid);
            } else {
                warning("SessionPool: Bot %d failed to rejoin saved MUC %s", bot.id, entry.room_jid);
            }
        }
    }

    public bool leave_muc_for_bot(int bot_id, string room_jid) {
        XmppStream? stream = get_ready_dedicated_stream(bot_id);
        if (stream == null) return false;

        try {
            Jid room = new Jid(room_jid);
            var muc = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            if (!is_muc_joined_for_bot(bot_id, room.bare_jid.to_string())) return false;
            muc.exit(stream, room.bare_jid);
            message("SessionPool: Bot %d left MUC %s", bot_id, room.bare_jid.to_string());
            return true;
        } catch (Error e) {
            warning("SessionPool: Bot %d failed to leave MUC %s: %s", bot_id, room_jid, e.message);
            return false;
        }
    }

    public bool send_groupchat_for_bot(int bot_id, string room_jid, string body, string? message_id = null) {
        XmppStream? stream = get_ready_dedicated_stream(bot_id);
        if (stream == null) return false;

        try {
            Jid room = new Jid(room_jid);
            if (!is_muc_joined_for_bot(bot_id, room.bare_jid.to_string())) {
                warning("SessionPool: Bot %d cannot send to MUC %s because it is not joined", bot_id, room.bare_jid.to_string());
                return false;
            }

            var msg_stanza = message_id != null
                ? new Xmpp.MessageStanza(message_id)
                : new Xmpp.MessageStanza();
            msg_stanza.to = room.bare_jid;
            msg_stanza.type_ = Xmpp.MessageStanza.TYPE_GROUPCHAT;
            msg_stanza.body = body;
            stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY)
                .send_message.begin(stream, msg_stanza);
            return true;
        } catch (Error e) {
            warning("SessionPool: Bot %d failed to send MUC message to %s: %s", bot_id, room_jid, e.message);
            return false;
        }
    }

    public bool send_reaction_for_bot(int bot_id, string to_jid, string message_id, string reaction) {
        XmppStream? stream = get_ready_dedicated_stream(bot_id);
        if (stream == null) return false;

        try {
            Jid jid = new Jid(to_jid);
            var reactions = new Gee.ArrayList<string>();
            reactions.add(reaction);

            stream.get_module<Xmpp.Xep.Reactions.Module>(Xmpp.Xep.Reactions.Module.IDENTITY)
                .send_reaction.begin(stream, jid, Xmpp.MessageStanza.TYPE_CHAT, message_id, reactions);
            return true;
        } catch (Error e) {
            warning("SessionPool: Bot %d failed to send reaction to %s: %s", bot_id, to_jid, e.message);
            return false;
        }
    }

    public bool is_real_jid_present_in_muc(int bot_id, string room_jid, string real_jid) {
        XmppStream? stream = get_ready_dedicated_stream(bot_id);
        if (stream == null || real_jid.strip() == "") return false;

        try {
            Jid room = new Jid(room_jid);
            Jid real = new Jid(real_jid);
            Xep.Muc.Flag? muc_flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            Presence.Flag? presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
            if (muc_flag == null || presence_flag == null) return false;

            Gee.List<Jid>? occupants = presence_flag.get_resources(room.bare_jid);
            if (occupants == null) return false;

            foreach (Jid occupant in occupants) {
                Jid? occupant_real = muc_flag.get_real_jid(occupant);
                if (occupant_real != null && occupant_real.equals_bare(real)) {
                    return true;
                }
            }
        } catch (Error e) {
            return false;
        }
        return false;
    }

    private XmppStream? get_ready_dedicated_stream(int bot_id) {
        if (!runtime_available()) return null;
        if (!dedicated_streams.has_key(bot_id) || !dedicated_ready.contains(bot_id)) {
            BotInfo? bot = bot_infos.has_key(bot_id) ? bot_infos[bot_id] : (registry != null ? registry.get_bot_by_id(bot_id) : null);
            if (bot != null && bot.status == "active" && (!connecting.has_key(bot_id) || !connecting[bot_id])) {
                connect_dedicated.begin(bot);
            }
            return null;
        }
        return dedicated_streams[bot_id];
    }

    private async XmppStream? wait_for_ready_dedicated_stream(int bot_id) {
        XmppStream? stream = get_ready_dedicated_stream(bot_id);
        if (stream != null) return stream;

        for (int i = 0; i < 100 && runtime_available(); i++) {
            Timeout.add(100, wait_for_ready_dedicated_stream.callback);
            yield;

            if (!runtime_available()) return null;
            if (dedicated_streams.has_key(bot_id) && dedicated_ready.contains(bot_id)) {
                return dedicated_streams[bot_id];
            }
        }
        return null;
    }

    private bool is_muc_joined_for_bot(int bot_id, string room_jid) {
        XmppStream? stream = get_ready_dedicated_stream(bot_id);
        if (stream == null) return false;
        try {
            Jid room = new Jid(room_jid);
            Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            return flag != null && flag.get_muc_nick(room.bare_jid) != null;
        } catch (Error e) {
            return false;
        }
    }

    private void queue_pending_message(int bot_id, string to_jid, string body, string? message_id) {
        ArrayList<PendingMessage>? queue = pending_messages.has_key(bot_id) ? pending_messages[bot_id] : null;
        if (queue == null) {
            queue = new ArrayList<PendingMessage>();
            pending_messages[bot_id] = queue;
        }
        if (queue.size >= 10) {
            queue.remove_at(0);
            warning("SessionPool: Dropped oldest pending message for dedicated bot %d", bot_id);
        }
        queue.add(new PendingMessage(to_jid, body, message_id));
    }

    private void flush_pending_messages(int bot_id) {
        if (!pending_messages.has_key(bot_id)) return;
        ArrayList<PendingMessage> queue = pending_messages[bot_id];
        pending_messages.unset(bot_id);
        foreach (PendingMessage pending in queue) {
            send_message_for_bot(bot_id, pending.to_jid, pending.body, pending.message_id);
        }
    }

    private bool send_plaintext(int bot_id, XmppStream stream, string to_jid, string body, string? message_id = null) {
        if (!is_current_dedicated_stream(bot_id, stream)) return false;
        try {
            var msg_stanza = message_id != null
                ? new Xmpp.MessageStanza(message_id)
                : new Xmpp.MessageStanza();
            msg_stanza.to = new Jid(to_jid);
            msg_stanza.type_ = Xmpp.MessageStanza.TYPE_CHAT;
            msg_stanza.body = body;
            stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY)
                .send_message.begin(stream, msg_stanza);
            return true;
        } catch (Error e) {
            warning("SessionPool: Failed to send message for bot %d: %s", bot_id, e.message);
            return false;
        }
    }

    /**
     * Clean up PubSub nodes for a bot before disconnecting.
     * Must be called while the stream is still alive.
     */
    public void cleanup_pubsub_and_disconnect(int bot_id, uint32 device_id) {
        if (!dedicated_streams.has_key(bot_id)) return;
        var stream = dedicated_streams[bot_id];

        // Delete OMEMO PubSub nodes (device list + bundle)
        var pubsub = stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY);
        pubsub.delete_node(stream, null, "eu.siacs.conversations.axolotl.devicelist");
        message("SessionPool: Deleted device list node for bot %d", bot_id);

        if (device_id > 0) {
            string bundle_node = "eu.siacs.conversations.axolotl.bundles:%u".printf(device_id);
            pubsub.delete_node(stream, null, bundle_node);
            message("SessionPool: Deleted bundle node %s for bot %d", bundle_node, bot_id);
        }

        // Delete avatar node
        pubsub.delete_node(stream, null, "urn:xmpp:avatar:data");
        pubsub.delete_node(stream, null, "urn:xmpp:avatar:metadata");

        // Delete vCard node
        pubsub.delete_node(stream, null, "urn:ietf:params:xml:ns:vcard-4.0");
        pubsub.delete_node(stream, null, "urn:xmpp:vcard4");

        // Give the delete IQs a moment to send, then disconnect
        GLib.Timeout.add(500, () => {
            disconnect_dedicated(bot_id);
            return false;
        });
    }

    public void prepare_for_account_unregister(int bot_id) {
        uint32 device_id = 0;
        if (bot_omemo != null) {
            device_id = bot_omemo.get_device_id(bot_id);
            bot_omemo.cleanup_bot(bot_id);
        }
        cleanup_pubsub_and_disconnect(bot_id, device_id);
    }

    // Disconnect a specific dedicated bot
    public void disconnect_dedicated(int bot_id) {
        if (dedicated_streams.has_key(bot_id)) {
            dedicated_streams[bot_id].disconnect.begin();
            dedicated_streams.unset(bot_id);
            dedicated_ready.remove(bot_id);
            connecting[bot_id] = false;
            pending_messages.unset(bot_id);
            message("SessionPool: Disconnected dedicated bot %d", bot_id);
        }
    }

    // Connect all active dedicated bots
    public void connect_all_dedicated() {
        if (!runtime_available() || registry == null) return;
        var bots = registry.get_all_active_bots();
        foreach (BotInfo bot in bots) {
            if (bot.mode == "dedicated" &&
                    bot.jid != null && bot.jid.strip() != "" &&
                    bot.bot_password != null && bot.bot_password.strip() != "") {
                connect_dedicated.begin(bot);
            }
        }
    }

    private Account? get_active_owner_account(BotInfo bot) {
        if (bot.owner_jid == null || bot.owner_jid.strip() == "") {
            warning("SessionPool: Personal bot %d has no owner JID", bot.id);
            return null;
        }

        if (!is_account_enabled(bot.owner_jid)) {
            return null;
        }

        try {
            Jid owner_jid = new Jid(bot.owner_jid);
            foreach (Account account in app.stream_interactor.get_accounts()) {
                if (account.bare_jid.equals_bare(owner_jid) &&
                        app.stream_interactor.get_stream(account) != null) {
                    return account;
                }
            }
        } catch (Error e) {
            warning("SessionPool: Personal bot %d has invalid owner JID %s: %s",
                bot.id, bot.owner_jid, e.message);
        }
        return null;
    }

    private bool is_active_owner_account(BotInfo bot, Account account) {
        if (bot.owner_jid == null || bot.owner_jid.strip() == "") return false;
        if (!is_account_enabled(bot.owner_jid)) return false;

        try {
            Jid owner_jid = new Jid(bot.owner_jid);
            return account.bare_jid.equals_bare(owner_jid) &&
                app.stream_interactor.get_stream(account) != null;
        } catch (Error e) {
            return false;
        }
    }

    private bool is_account_enabled(string jid_str) {
        if (!runtime_available()) return false;
        if (registry == null) return true;
        string key = "botmother_account_enabled:" + jid_str;
        string? val = registry.get_setting(key);
        return val == null || val == "true";
    }

    public void shutdown() {
        if (stopped) return;
        stopped = true;
        disconnect_all();
        bot_infos.clear();
    }

    public void disconnect_all() {
        personal_bindings.clear();
        // Disconnect all dedicated streams
        foreach (var entry in dedicated_streams.entries) {
            entry.value.disconnect.begin();
        }
        dedicated_streams.clear();
        dedicated_ready.clear();
        connecting.clear();
        pending_messages.clear();
    }
}

}
