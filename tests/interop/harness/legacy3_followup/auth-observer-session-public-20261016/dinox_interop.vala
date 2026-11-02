// Local-only real-server interop driver. No signaling or crypto test doubles.
using Dino;
using Dino.Entities;
using Dino.Plugins;
using Dino.Plugins.GoogleWebrtc;
using Gee;
using Xmpp;

namespace LocalInterop {

class InteropApplication : GLib.Application, Dino.Application {
    public Dino.Database db { get; set; }
    public string? db_key { get; set; }
    public Dino.Security.FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
    public Dino.SearchPathGenerator? search_path_generator { get; set; }

    public InteropApplication(string key) {
        Object(application_id: "im.dinox.local.interop", flags: ApplicationFlags.NON_UNIQUE);
        db_key = key;
    }

    public void handle_uri(string jid, string query, Gee.Map<string, string> options) {}
}

// This wrapper only observes real factory results and disables physical capture
// before any wire session starts. The production plugin still owns all routing,
// XmppEngine*Transports, native workers, signaling and lifetime management.
class SyntheticProvider : Object, JmiCallEnginePlugin, MujiCallEnginePlugin {
    public Dino.Plugins.GoogleWebrtc.Plugin actual;
    public ArrayList<EngineJmiSession> sessions = new ArrayList<EngineJmiSession>();
    public ArrayList<EngineMujiGroupSession> groups = new ArrayList<EngineMujiGroupSession>();
    public uint64 decoded_frame_events = 0;
    public uint64 synthetic_pushes = 0;
    public string? push_error;
    public string engine_id { get { return actual.engine_id; } }
    public string group_engine_id { get { return ((MujiCallEnginePlugin) actual).group_engine_id; } }

    public SyntheticProvider(Dino.Plugins.GoogleWebrtc.Plugin actual) { this.actual = actual; }
    public bool runtime_enabled() { return actual.runtime_enabled(); }
    bool MujiCallEnginePlugin.runtime_enabled() { return actual.runtime_enabled(); }
    public bool can_start_audio_only(Account a) { return actual.can_start_audio_only(a); }
    public bool can_start_video(Account a) { return actual.can_start_video(a); }
    public bool can_start_group_audio(Account a) { return actual.can_start_group_audio(a); }
    public bool can_start_group_video(Account a) { return actual.can_start_group_video(a); }
    public Gee.List<MediaDevice> get_audio_devices(bool incoming) { return actual.get_audio_devices(incoming); }
    public MediaDevice? get_preferred_audio_device(bool incoming) { return actual.get_preferred_audio_device(incoming); }
    public void set_audio_device(MediaDevice device) throws Error { actual.set_audio_device(device); }
    public double get_audio_device_volume(MediaDevice? d) { return actual.get_audio_device_volume(d); }
    public void set_audio_device_volume(MediaDevice? d, double v) throws Error { actual.set_audio_device_volume(d, v); }
    // Never expose physical cameras to UI or device preference selection.
    public Gee.List<MediaDevice> get_video_devices() { return new ArrayList<MediaDevice>(); }
    public MediaDevice? get_preferred_video_device() { return null; }

    private EngineJmiSession observe(JmiCallEngineSession session) {
        EngineJmiSession observed = (EngineJmiSession) session;
        observed.suppress_local_capture_start_for_test();
        if (!sessions.contains(observed)) {
            sessions.add(observed);
            observed.remote_video_frame.connect((frame) => { decoded_frame_events++; });
        }
        return observed;
    }

    public JmiCallEngineSession start_outgoing_audio_session(XmppStream s, Jid local, Jid peer, string sid, uint64 id) throws Error {
        return start_outgoing_session(s, local, peer, sid, id, false);
    }
    public JmiCallEngineSession start_outgoing_session(XmppStream s, Jid local, Jid peer, string sid, uint64 id, bool video) throws Error {
        return observe(actual.start_outgoing_session(s, local, peer, sid, id, video));
    }
    public JmiCallEngineSession create_incoming_session(XmppStream s, Jid local, Jid peer, string sid, uint64 id, Gee.List<StanzaNode> descriptions) throws Error {
        return observe(actual.create_incoming_session(s, local, peer, sid, id, descriptions));
    }
    public bool handle_proceed(Jid from, Jid to, string sid) throws Error { return actual.handle_proceed(from, to, sid); }
    public MujiCallEngineGroupSession create_group_session(XmppStream s, Jid local, Jid room, uint64 id, bool video) throws Error {
        var group = (EngineMujiGroupSession) actual.create_group_session(s, local, room, id, video);
        group.suppress_capture_start_for_test();
        group.peer_session_created.connect((session) => { observe(session); });
        groups.add(group);
        return group;
    }

    public void tick() {
        foreach (EngineJmiSession s in sessions) {
            if (s.jmi_state == JmiState.ENDED || s.jmi_state == JmiState.REJECTED || s.jmi_state == JmiState.RETRACTED || s.wire_session == null || !s.video_requested || s.muji_room_jid != null) continue;
            try {
                s.wire_session.session.engine.push_synthetic_video_frame(320, 240);
                synthetic_pushes++;
            } catch (Error e) { push_error = e.message; }
        }
        foreach (EngineMujiGroupSession group in groups) {
            try {
                group.push_preview_synthetic_frame_for_test(320, 240);
                synthetic_pushes++;
            } catch (Error e) { push_error = e.message; }
        }
    }
}

class Driver : Object {
    public MainLoop loop = new MainLoop();
    private InteropApplication app;
    private Dino.Security.ProfileLock profile_lock;
    private Dino.Plugins.Omemo.Plugin omemo;
    private SyntheticProvider provider;
    private Account? account;
    private Calls calls;
    private CallState? active_call;
    private Json.Object config;
    private string root;
    private string run_id;
    private HashSet<string> allowed = new HashSet<string>();
    private HashMap<string, Jid> parsed_jids = new HashMap<string, Jid>();
    private HashSet<string> rooms = new HashSet<string>();
    private HashSet<string> processed = new HashSet<string>();
    private ArrayList<Dino.Entities.Message> messages = new ArrayList<Dino.Entities.Message>();
    private bool command_pending = false;
    private bool stopping = false;
    private ObserverScope? wire_observers;
    private string? asynchronous_error;
    private Json.Object? last_call_terminal;

    public Driver(string root, Json.Object config) throws Error {
        this.root = root;
        this.config = config;
        this.run_id = config.get_string_member("run_id");
        foreach (Json.Node node in config.get_array_member("allowed_jids").get_elements()) {
            Jid target = new Jid(node.get_string()).bare_jid;
            allowed.add(target.to_string());
            parsed_jids[target.to_string()] = target;
        }
        if (config.has_member("allowed_rooms")) {
            foreach (Json.Node node in config.get_array_member("allowed_rooms").get_elements()) {
                rooms.add(new Jid(node.get_string()).bare_jid.to_string());
            }
        }
        // Use the real production process-owned lock before touching either DB.
        profile_lock = Dino.Security.ProfileLock.acquire(Dino.Application.get_storage_dir());
        app = new InteropApplication(config.get_string_member("db_key"));
        GLib.Application.set_default(app);
        ((Dino.Application) app).init();
        omemo = new Dino.Plugins.Omemo.Plugin();
        omemo.registered(app); // Includes production readiness + DTLS fingerprint module.
        if (omemo.db == null || omemo.trust_manager == null) throw new IOError.FAILED("OMEMO plugin did not initialize");
        var actual = new Dino.Plugins.GoogleWebrtc.Plugin();
        actual.registered(app);
        provider = new SyntheticProvider(actual);
        app.plugin_registry.jmi_call_engine_plugin = provider;
        app.plugin_registry.muji_call_engine_plugin = provider;
        if (!provider.runtime_enabled()) throw new IOError.FAILED("Native libwebrtc runtime unavailable");
        calls = app.stream_interactor.get_module<Calls>(Calls.IDENTITY);
        calls.call_incoming.connect((call, state, conversation, video, multiparty) => {
            if (account == null || call.account != account ||
                    (!allowed.contains(call.counterpart.bare_jid.to_string()) &&
                     !rooms.contains(call.counterpart.bare_jid.to_string()) &&
                     (state.cim_counterpart == null || !allowed.contains(state.cim_counterpart.bare_jid.to_string())))) {
                state.reject();
                return;
            }
            active_call = state;
        });
        calls.call_outgoing.connect((call, state, conversation) => {
            if (account != null && call.account == account) active_call = state;
        });
        calls.call_terminated.connect((call, reason, text) => {
            if (account == null || call.account != account) return;
            var terminal = new Json.Object();
            terminal.set_int_member("call_id", call.id);
            terminal.set_string_member("peer", call.counterpart.to_string());
            terminal.set_string_member("state", call.state.to_string());
            if (reason != null) terminal.set_string_member("reason", reason);
            if (text != null) terminal.set_string_member("text", text);
            last_call_terminal = terminal;
        });
        var processor = app.stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        processor.message_received.connect((message, conversation) => {
            if (account != null && message.account == account &&
                    (allowed.contains(message.counterpart.bare_jid.to_string()) || rooms.contains(message.counterpart.bare_jid.to_string()))) {
                messages.add(message);
            }
        });
        processor.message_sent.connect((message, conversation) => {
            if (account != null && message.account == account && !messages.contains(message)) messages.add(message);
        });
    }

    public async void start() throws Error {
        // Let production Application.restore run first. Only this isolated profile
        // may own the configured account; never reuse a desktop account object.
        yield delay(300);
        Jid own = new Jid(config.get_string_member("jid"));
        foreach (Account existing in app.stream_interactor.get_accounts()) {
            if (!existing.bare_jid.equals_bare(own)) throw new IOError.PERMISSION_DENIED("Unexpected account in isolated profile");
            account = existing;
        }
        if (account == null) {
            Account fresh = new Account(own.bare_jid, config.get_string_member("password"));
            fresh.alias = config.get_string_member("name");
            fresh.enabled = true;
            fresh.persist(app.db);
            account = fresh;
            start_observers();
            app.stream_interactor.connect_account(fresh);
        } else start_observers();
        Timeout.add(100, () => { if (stopping) return false; provider.tick(); return true; });
        Timeout.add(300, () => {
            if (stopping) return false;
            try { write_json(Path.build_filename(root, "state.json"), snapshot()); }
            catch (Error e) { asynchronous_error = "State output failed"; }
            if (!command_pending) scan_commands.begin();
            return true;
        });
    }

    private void start_observers() throws Error {
        wire_observers = new ObserverScope(this, app, omemo, (!) account, root);
    }

    public void finish_observers() {
        if (wire_observers != null) wire_observers.finish();
    }

    internal bool observer_peer_allowed(Jid peer) {
        return allowed.contains(peer.bare_jid.to_string()) && ObserverScope.test_bare(peer.bare_jid.to_string());
    }

    private bool observer_call_live() {
        if (account == null || active_call == null || active_call.call.account != account) return false;
        return active_call.call.state == Call.State.RINGING || active_call.call.state == Call.State.ESTABLISHING ||
            active_call.call.state == Call.State.IN_PROGRESS;
    }

    internal bool observer_room_allowed(Jid room) {
        if (room.resourcepart != null || room.domainpart != "conference.dinox.im") return false;
        if (rooms.contains(room.to_string())) return true;
        return observer_call_live() && active_call.group_call != null &&
            active_call.group_call.muc_jid.equals_bare(room);
    }

    internal bool observer_call_allowed(Jid peer, string sid, Jid? room) {
        if (account == null || !observer_peer_allowed(peer)) return false;
        foreach (EngineJmiSession session in provider.sessions) {
            if (session.sid != sid || !session.peer_jid.equals(peer) ||
                    !session.local_full_jid.equals(account.full_jid) || session.jmi_state == JmiState.ENDED ||
                    session.jmi_state == JmiState.REJECTED || session.jmi_state == JmiState.RETRACTED) continue;
            if (room == null) return true;
            if (session.muji_room_jid != null && session.muji_room_jid.equals_bare(room)) return true;
        }
        // A first incoming mesh IQ precedes the engine's per-peer session creation.
        return room != null && observer_room_allowed(room) && observer_call_live() &&
            active_call.group_call != null && active_call.group_call.muc_jid.equals_bare(room);
    }

    private static async void delay(uint milliseconds) {
        Timeout.add(milliseconds, () => { delay.callback(); return false; });
        yield;
    }

    private Jid peer(Json.Object command) throws Error {
        Jid p = new Jid(command.get_string_member("peer"));
        if (!allowed.contains(p.bare_jid.to_string())) throw new IOError.PERMISSION_DENIED("Peer is outside this run's exact allowlist");
        return p;
    }
    private Jid room(Json.Object command) throws Error {
        Jid p = new Jid(command.get_string_member("room"));
        if (!rooms.contains(p.bare_jid.to_string())) throw new IOError.PERMISSION_DENIED("Room is outside this run's exact allowlist");
        return p;
    }
    private Conversation conversation(Jid jid, bool muc = false) {
        return app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
            .create_conversation(jid, (!) account, muc ? Conversation.Type.GROUPCHAT : Conversation.Type.CHAT);
    }
    private CallState current_call() throws Error {
        if (active_call == null || active_call.call.account != account) throw new IOError.NOT_FOUND("No owned call");
        return (!) active_call;
    }

    private Encryption requested_encryption(Json.Object command) throws Error {
        string mode = command.has_member("encryption") ? command.get_string_member("encryption") : "legacy";
        if (mode == "legacy") return Encryption.OMEMO;
        if (mode == "none") return Encryption.NONE;
        throw new IOError.NOT_SUPPORTED("DinoX stable interop requires legacy OMEMO; OMEMO 2 is disabled");
    }

    private async Json.Object call_capabilities(Conversation c, bool video) throws Error {
        Account owner = c.account;
        XmppStream? expected = app.stream_interactor.get_connected_stream_for_action(owner);
        if (expected == null) throw new IOError.NOT_CONNECTED("Call preflight requires the current stream");
        var result = new Json.Object();
        var observed = new Json.Array();
        bool current_jmi = false;
        if (c.type_ == Conversation.Type.CHAT) {
            var presence = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            var info = app.stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
            Gee.List<Jid>? resources = presence.get_full_jids(c.counterpart, owner);
            var candidates = new ArrayList<Jid>();
            var eligible = new ArrayList<Jid>();
            var eligible_frames = new ArrayList<Xmpp.Presence.Stanza>();
            if (resources != null) candidates.add_all(resources);
            foreach (Jid peer_resource in candidates) {
                Xmpp.Presence.Flag? flag = expected.get_flag<Xmpp.Presence.Flag>(Xmpp.Presence.Flag.IDENTITY);
                Xmpp.Presence.Stanza? frame = flag != null ? flag.get_presence(peer_resource) : null;
                if (frame == null) continue;
                bool? jmi = yield info.get_feature_support(owner, peer_resource, Xep.JingleMessageInitiation.NS_URI);
                bool? rtp = yield info.get_feature_support(owner, peer_resource, Xep.JingleRtp.NS_URI);
                if (account != owner || app.stream_interactor.get_connected_stream_for_action(owner) != expected)
                    throw new IOError.CANCELLED("Call preflight stream changed");
                if (flag.get_presence(peer_resource) != frame)
                    throw new IOError.CANCELLED("Call preflight presence changed");
                bool still_present = false;
                Gee.List<Jid>? current = presence.get_full_jids(c.counterpart, owner);
                if (current != null) foreach (Jid active in current) if (active.equals(peer_resource)) still_present = true;
                if (!still_present) throw new IOError.CANCELLED("Call preflight peer resource changed");
                var row = new Json.Object();
                row.set_string_member("full_jid", peer_resource.to_string());
                row.set_boolean_member("jmi_known", jmi != null);
                row.set_boolean_member("rtp_known", rtp != null);
                row.set_boolean_member("jmi", jmi != null && (!) jmi);
                row.set_boolean_member("rtp", rtp != null && (!) rtp);
                observed.add_object_element(row);
                if (jmi != null && (!) jmi && rtp != null && (!) rtp) {
                    eligible.add(peer_resource);
                    eligible_frames.add(frame);
                }
            }
            Gee.List<Jid>? current = presence.get_full_jids(c.counterpart, owner);
            Xmpp.Presence.Flag? final_flag = expected.get_flag<Xmpp.Presence.Flag>(Xmpp.Presence.Flag.IDENTITY);
            for (int i = 0; i < eligible.size; i++) {
                bool still_present = false;
                if (current != null) foreach (Jid active in current) if (active.equals(eligible[i])) still_present = true;
                if (still_present && final_flag != null && final_flag.get_presence(eligible[i]) == eligible_frames[i])
                    current_jmi = true;
            }
        }
        if (account != owner || app.stream_interactor.get_connected_stream_for_action(owner) != expected)
            throw new IOError.CANCELLED("Call preflight stream changed before capability selection");
        ConversationCallCapabilities capabilities = calls.get_conversation_call_capabilities(c);
        CallCapabilityStatus status = video ? capabilities.video : capabilities.audio;
        result.set_string_member("status", status.to_string());
        result.set_string_member("reason", capabilities.reason.to_string());
        result.set_array_member("resources", observed);
        result.set_boolean_member("current_jmi_peer", current_jmi);
        result.set_boolean_member("available", status == CallCapabilityStatus.AVAILABLE &&
            (c.type_ == Conversation.Type.GROUPCHAT || current_jmi));
        result.set_string_member("media_engine", provider.engine_id);
        return result;
    }

    private async Json.Object execute(Json.Object command) throws Error {
        string op = command.get_string_member("op");
        if (op == "status" || op == "stats") return snapshot();
        if (op == "authorize_room") {
            rooms.add(new Jid(command.get_string_member("room")).bare_jid.to_string());
            return snapshot();
        }
        if ((op == "accept_call" || op == "reject_call" || op == "hangup" || op == "add_participant") && !command.has_member("call_id")) throw new IOError.PERMISSION_DENIED("Exact logical call_id is required");
        if (command.has_member("call_id") && (active_call == null || command.get_int_member("call_id") != active_call.call.id)) throw new IOError.PERMISSION_DENIED("Stale logical call owner");
        if (op == "stop") {
            stopping = true;
            if (active_call != null) active_call.end();
            yield app.stream_interactor.connection_manager.disconnect_account((!) account);
            finish_observers();
            return snapshot();
        }
        if (app.stream_interactor.get_connected_stream_for_action((!) account) == null) throw new IOError.NOT_CONNECTED("Account is not online");
        switch (op) {
        case "contact": {
            Jid target = peer(command);
            var roster = app.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
            if (roster.get_roster_item((!) account, target) == null && !(yield roster.add_jid_async((!) account, target, null))) throw new IOError.FAILED("Roster addition failed");
            yield app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).request_mutual_subscription((!) account, target, true);
            break;
        }
        case "chat": {
            Conversation c = conversation(peer(command));
            c.encryption = requested_encryption(command);
            break;
        }
        case "prepare_crypto": {
            Conversation c = command.has_member("room") ? conversation(room(command), true) : conversation(peer(command));
            c.encryption = requested_encryption(command);
            var manager = app.stream_interactor.get_module<Dino.Plugins.Omemo.Manager>(Dino.Plugins.Omemo.Manager.IDENTITY);
            bool prepared = yield manager.ensure_get_keys_for_conversation(c);
            var result = snapshot();
            result.set_boolean_member("keys_prepared", prepared);
            return result;
        }
        case "send_text": {
            Conversation c = command.has_member("room") ? conversation(room(command), true) : conversation(peer(command));
            c.encryption = requested_encryption(command);
            string text = command.get_string_member("text");
            if (!text.has_prefix(run_id + ":")) throw new IOError.PERMISSION_DENIED("Test messages must begin with this run_id followed by colon");
            Dino.send_message(c, text, 0, null, new ArrayList<Xep.MessageMarkup.Span>());
            break;
        }
        case "call_capabilities": {
            Conversation c = command.has_member("room") ? conversation(room(command), true) : conversation(peer(command));
            var result = snapshot();
            result.set_object_member("call_capabilities", yield call_capabilities(c,
                command.has_member("video") && command.get_boolean_member("video")));
            return result;
        }
        case "start_call": {
            Conversation c = command.has_member("room") ? conversation(room(command), true) : conversation(peer(command));
            bool video = command.has_member("video") && command.get_boolean_member("video");
            Json.Object capabilities = yield call_capabilities(c, video);
            if (!capabilities.get_boolean_member("available")) throw new IOError.NOT_SUPPORTED("Production call preflight is not available");
            active_call = yield calls.initiate_call(c, video);
            if (active_call == null) throw new IOError.FAILED("Production call initiation returned no owner");
            break;
        }
        case "accept_call":
            if (current_call().invited_to_group_call != null && !rooms.contains(current_call().invited_to_group_call.bare_jid.to_string())) throw new IOError.PERMISSION_DENIED("Authorize this exact invited room before acceptance");
            current_call().accept();
            break;
        case "reject_call":
            current_call().reject();
            break;
        case "hangup":
            current_call().end();
            break;
        case "add_participant": {
            var outcome = yield current_call().invite_to_call(peer(command));
            Json.Object result = snapshot();
            result.set_string_member("invitation_result", outcome.to_string());
            return result;
        }
        case "join_room": {
            Jid target = room(command);
            conversation(target, true);
            yield app.stream_interactor.get_module<MucManager>(MucManager.IDENTITY).join((!) account, target,
                config.get_string_member("name"), null);
            break;
        }
        case "set_trust": {
            Jid target = peer(command);
            int device_id = (int) command.get_int_member("device_id");
            Dino.Plugins.Omemo.TrustLevel trust = command.get_string_member("trust") == "reject"
                ? Dino.Plugins.Omemo.TrustLevel.UNTRUSTED : Dino.Plugins.Omemo.TrustLevel.TRUSTED;
            omemo.trust_manager.set_device_trust((!) account, target, device_id, trust);
            break;
        }
        default: throw new IOError.NOT_SUPPORTED("Unknown operation");
        }
        return snapshot();
    }

    private async void scan_commands() {
        command_pending = true;
        try {
            Dir dir = Dir.open(Path.build_filename(root, "inbox"));
            string? filename;
            var names = new ArrayList<string>();
            while ((filename = dir.read_name()) != null) {
                if (filename.has_suffix(".json") && !processed.contains(filename) && !FileUtils.test(Path.build_filename(root, "results", filename), FileTest.EXISTS)) names.add(filename);
            }
            names.sort((a,b) => strcmp(a,b));
            foreach (string name in names) {
                processed.add(name);
                Json.Object result = new Json.Object();
                try {
                    var parser = new Json.Parser();
                    parser.load_from_file(Path.build_filename(root, "inbox", name));
                    Json.Object command = parser.get_root().get_object();
                    if (!command.has_member("run_id") || command.get_string_member("run_id") != run_id) throw new IOError.PERMISSION_DENIED("Foreign run_id");
                    if (command.get_string_member("id") + ".json" != name) throw new IOError.INVALID_DATA("Command filename/id mismatch");
                    result = yield execute(command);
                    result.set_boolean_member("ok", true);
                } catch (Error e) {
                    result.set_boolean_member("ok", false);
                    result.set_string_member("error", e.message);
                }
                result.set_string_member("id", name.substring(0, name.length - 5));
                result.set_string_member("run_id", run_id);
                result.set_string_member("account", config.get_string_member("jid"));
                write_json(Path.build_filename(root, "results", name), result);
                if (stopping) { loop.quit(); break; }
            }
        } catch (Error e) { asynchronous_error = "Command processing failed"; }
        command_pending = false;
    }

    private static string? public_identity_hex(string? encoded) {
        if (encoded == null) return null;
        uint8[] bytes = Base64.decode((!) encoded);
        if (bytes.length != 33 || bytes[0] != 5) return null;
        var hex = new StringBuilder();
        foreach (uint8 octet in bytes) hex.append_printf("%02x", (uint) octet);
        return hex.str;
    }

    private Json.Object snapshot() {
        var result = new Json.Object();
        result.set_string_member("run_id", run_id);
        result.set_string_member("account", config.get_string_member("jid"));
        result.set_string_member("source", "production-core-omemo-xmpp-libwebrtc");
        if (wire_observers != null) result.set_object_member("private_wire_observers", wire_observers.status());
        result.set_boolean_member("physical_capture_suppressed", true);
        result.set_boolean_member("profile_lock_held", profile_lock != null);
        result.set_boolean_member("online", account != null && app.stream_interactor.get_connected_stream_for_action((!) account) != null);
        if (account != null) result.set_string_member("full_jid", account.full_jid.to_string());
        if (asynchronous_error != null) result.set_string_member("error", (!) asynchronous_error);
        if (last_call_terminal != null) result.set_object_member("last_call_terminal", (!) last_call_terminal);
        result.set_int_member("synthetic_pushes", (int64) provider.synthetic_pushes);
        result.set_int_member("decoded_frame_events", (int64) provider.decoded_frame_events);
        if (provider.push_error != null) result.set_string_member("last_push_error", (!) provider.push_error);
        if (active_call != null) {
            var call = new Json.Object();
            call.set_int_member("id", active_call.call.id);
            call.set_string_member("state", active_call.call.state.to_string());
            call.set_string_member("counterpart", active_call.call.counterpart.to_string());
            call.set_string_member("encryption", active_call.call.encryption.to_string());
            call.set_int_member("peers", active_call.peers.size);
            if (active_call.invited_to_group_call != null) call.set_string_member("invited_room", active_call.invited_to_group_call.to_string());
            if (active_call.cim_counterpart != null) call.set_string_member("inviter", active_call.cim_counterpart.to_string());
            if (active_call.group_call != null) call.set_string_member("room", active_call.group_call.muc_jid.to_string());
            result.set_object_member("call", call);
        }
        var session_rows = new Json.Array();
        foreach (EngineJmiSession s in provider.sessions) {
            var row = new Json.Object();
            row.set_string_member("sid", s.sid);
            row.set_string_member("local", s.local_full_jid.to_string());
            row.set_string_member("peer", s.peer_jid.to_string());
            row.set_string_member("jmi_state", s.jmi_state.to_string());
            if (s.muji_room_jid != null) row.set_string_member("room", s.muji_room_jid.to_string());
            if (s.wire_session != null) {
                row.set_string_member("wire_state", s.wire_session.state.to_string());
                try {
                    var ns = s.wire_session.session.engine.get_state();
                    row.set_string_member("peer_connection_state", ns.peer_connection_state.to_string());
                    row.set_string_member("ice_connection_state", ns.ice_connection_state.to_string());
                    row.set_int_member("capture_running", ns.local_video_capture_running);
                    row.set_int_member("capture_frames", (int64) ns.local_video_capture_frame_count);
                    row.set_int_member("local_source_frames", (int64) ns.local_video_source_frame_count);
                    row.set_int_member("audio_in_packets", (int64) ns.inbound_audio_packets_received);
                    row.set_int_member("audio_out_packets", (int64) ns.outbound_audio_packets_sent);
                    row.set_int_member("audio_sink_samples", (int64) ns.remote_audio_sink_sample_count);
                    row.set_double_member("audio_sink_peak", ns.remote_audio_sink_peak_level);
                    row.set_int_member("video_in_packets", (int64) ns.inbound_video_packets_received);
                    row.set_int_member("video_out_packets", (int64) ns.outbound_video_packets_sent);
                    row.set_int_member("video_decoded", (int64) ns.inbound_video_frames_decoded);
                    row.set_int_member("video_encoded", (int64) ns.outbound_video_frames_encoded);
                    row.set_int_member("video_sink_frames", (int64) ns.remote_video_sink_frame_count);
                    row.set_int_member("stats_reports", (int64) ns.stats_report_count);
                } catch (Error e) { row.set_string_member("stats_unavailable", "session closed or worker unavailable"); }
            }
            session_rows.add_object_element(row);
        }
        result.set_array_member("sessions", session_rows);
        var message_rows = new Json.Array();
        foreach (Dino.Entities.Message m in messages) {
            var row = new Json.Object();
            row.set_string_member("stanza_id", m.stanza_id ?? "");
            row.set_string_member("peer", m.counterpart.to_string());
            row.set_string_member("body", m.body ?? "");
            row.set_string_member("encryption", m.encryption.to_string());
            row.set_string_member("marked", m.marked.to_string());
            row.set_string_member("direction", m.direction == Dino.Entities.Message.DIRECTION_SENT ? "sent" : "received");
            if (m.delivery_error_text != null) row.set_string_member("error", m.delivery_error_text);
            message_rows.add_object_element(row);
        }
        result.set_array_member("messages", message_rows);
        var contact_rows = new Json.Array();
        if (account != null) {
            int identity_id = omemo.db.identity.get_id(account.id);
            // Only the selected account's public identity is an observation.
            // Never serialize a key pair or any private-key column.
            foreach (Qlite.Row own in omemo.db.identity.select()
                    .with(omemo.db.identity.account_id, "=", account.id)) {
                result.set_int_member("own_omemo_device_id", own[omemo.db.identity.device_id]);
                string? own_public = public_identity_hex(own[omemo.db.identity.identity_key_public_base64]);
                if (own_public != null) result.set_string_member("own_public_identity_hex", (!) own_public);
            }
            foreach (string address in allowed) {
                var contact = new Json.Object();
                contact.set_string_member("jid", address);
                var resources = new Json.Array();
                var presences = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).get_full_jids(parsed_jids[address], (!) account);
                if (presences != null) foreach (Jid resource in presences) resources.add_string_element(resource.to_string());
                contact.set_array_member("resources", resources);
                var devices = new Json.Array();
                foreach (Qlite.Row known in omemo.db.identity_meta.with_address(identity_id, address)) {
                    var device = new Json.Object();
                    device.set_int_member("device_id", known[omemo.db.identity_meta.device_id]);
                    device.set_int_member("trust", known[omemo.db.identity_meta.trust_level]);
                    device.set_boolean_member("active", known[omemo.db.identity_meta.now_active]);
                    device.set_boolean_member("legacy", known[omemo.db.identity_meta.supports_omemo1]);
                    string? peer_public = public_identity_hex(known[omemo.db.identity_meta.identity_key_public_base64]);
                    if (peer_public != null) device.set_string_member("public_identity_hex", (!) peer_public);
                    devices.add_object_element(device);
                }
                contact.set_array_member("devices", devices);
                contact_rows.add_object_element(contact);
            }
        }
        result.set_array_member("contacts", contact_rows);
        return result;
    }

    private static void write_json(string path, Json.Object object) throws Error {
        var node = new Json.Node(Json.NodeType.OBJECT);
        node.set_object(object);
        var generator = new Json.Generator();
        generator.set_root(node);
        string data = generator.to_data(null);
        File.new_for_path(path).replace_contents(data.data, null, false, FileCreateFlags.PRIVATE, null);
    }
}

int main(string[] args) {
    if (args.length != 2) { stderr.printf("Expected one isolated command-directory path\n"); return 2; }
    try {
        string root = File.new_for_path(args[1]).get_path();
        var parser = new Json.Parser();
        parser.load_from_file(Path.build_filename(root, "config.json"));
        Json.Object config = parser.get_root().get_object();
        string data_home = Environment.get_variable("XDG_DATA_HOME") ?? "";
        string scope = Path.get_dirname(Path.get_dirname(root));
        string expected_data = config.has_member("xdg_data_home") ? config.get_string_member("xdg_data_home") : Path.build_filename(root, "xdg-data");
        if (Path.get_basename(scope) != "monocles-dinox-interop-20261015" || data_home != expected_data ||
                !data_home.has_prefix(scope + Path.DIR_SEPARATOR_S)) throw new IOError.PERMISSION_DENIED("Owned isolated XDG_DATA_HOME is required");
        if (FileUtils.test("/dev/video0", FileTest.EXISTS) || FileUtils.test("/dev/video1", FileTest.EXISTS)) throw new IOError.PERMISSION_DENIED("Physical video devices remain visible; private /dev is required");
        if (Environment.get_variable("DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE") != "synthetic") throw new IOError.PERMISSION_DENIED("Synthetic audio is required");
        Gtk.init();
        Adw.init();
        var driver = new Driver(root, config);
        driver.start.begin((obj,res) => {
            try { driver.start.end(res); }
            catch (Error e) { stderr.printf("Interop initialization failed: %s\n", e.message); driver.loop.quit(); }
        });
        driver.loop.run();
        driver.finish_observers();
        return 0;
    } catch (Error e) { stderr.printf("Interop initialization failed: %s\n", e.message); return 1; }
}

}
