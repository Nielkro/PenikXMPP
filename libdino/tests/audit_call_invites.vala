using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino.Test {

// Public CIM event ingress, real conversation/call persistence and deliberately
// nonallocating engine facets. No user acceptance or physical capture occurs.
class CallInviteIngressAudit : Gee.TestCase {
    public CallInviteIngressAudit() {
        base("CallInviteIngressAudit");
        add_test("first_roster_from_muji_invite_creates_ringing_chat", () => test_authorized(Roster.Item.SUBSCRIPTION_FROM, false));
        add_test("first_roster_both_muji_invite_uses_actual_bound_resource", () => test_authorized(Roster.Item.SUBSCRIPTION_BOTH, true));
        add_test("repeated_muji_invite_does_not_duplicate_call", test_duplicate);
        add_test("unknown_muji_invite_creates_no_call_or_chat", () => test_rejected("unknown", false));
        add_test("to_only_muji_invite_creates_no_call_or_chat", () => test_rejected("to", false));
        add_test("none_subscription_muji_invite_creates_no_call_or_chat", () => test_rejected("none", false));
        add_test("blocked_roster_muji_invite_creates_no_call_or_chat", () => test_rejected("blocked", false));
        add_test("existing_chat_does_not_authorize_muji_invite", () => test_rejected("chat", false));
        add_test("other_account_roster_does_not_authorize_muji_invite", () => test_rejected("other-roster", false));
        add_test("foreign_account_recipient_creates_no_call_or_chat", () => test_rejected("foreign-to", false));
        add_test("wrong_bound_resource_creates_no_call_or_chat", () => test_rejected("wrong-resource", false));
        add_test("bare_sender_muji_invite_creates_no_call_or_chat", () => test_rejected("bare-sender", false));
        add_test("stale_stream_cannot_publish_bare_recipient_muji_invite", test_stale_stream);
        add_test("unknown_direct_jingle_invite_rejected_before_available_legacy_backend", () => test_rejected("unknown", true));
        add_test("blocked_direct_jingle_invite_rejected_before_available_legacy_backend", () => test_rejected("blocked", true));
    }

    private delegate void Scenario(Fixture fixture) throws Error;

    private void run(owned Scenario scenario) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            scenario((!) fixture);
        } catch (Error error) {
            fail_if_reached("Call invite ingress audit failed: " + error.message);
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void test_authorized(string subscription, bool full_recipient) {
        run((f) => {
            f.authorize(f.account, subscription);
            fail_if(f.chat() != null, "the first invite must not depend on an existing CHAT");
            fail_if(f.account.full_jid.equals(f.bound), "fixture must distinguish configured and actual bound resources");
            f.invite("first-invite", false, null, full_recipient ? f.bound : f.account.bare_jid, null, full_recipient);
            fail_if(f.incoming != 1, "one authorized proposal must emit exactly one incoming call");
            fail_if(f.call_rows() != 1, "the ringing call must be durably persisted");
            Conversation? conversation = f.chat();
            fail_if(conversation == null, "authorized first MUJI invite must create its account-specific CHAT");
            if (conversation != null) {
                fail_if(!((!) conversation).account.equals(f.account) || ((!) conversation).type_ != Conversation.Type.CHAT,
                    "the new CHAT must belong to the receiving account");
                fail_if(f.observed_conversation != conversation, "the UI event must identify that same persisted CHAT");
            }
            Call? call = f.observed_call;
            fail_if(call == null || ((!) call).state != Call.State.RINGING || ((!) call).direction != Call.DIRECTION_INCOMING,
                "the published call must remain incoming and ringing");
            if (call != null && conversation != null) {
                fail_if(!((!) call).account.equals(f.account) || !((!) call).ourpart.equals(f.bound),
                    "the call must use the receiving account's actual bound full JID");
                fail_if(((CallStore) f.interactor.get_module<CallStore>(CallStore.IDENTITY))
                    .get_call_by_id(((!) call).id, (!) conversation) == null,
                    "the ordinary CallStore must be able to restore the ringing call");
            }
            fail_if(f.observed_state == null || ((!) f.observed_state).media_backend != CallMediaBackend.GOOGLE_WEBRTC ||
                    ((!) f.observed_state).invited_to_group_call == null ||
                    !((!) ((!) f.observed_state).invited_to_group_call).equals(f.room),
                "the pending state must retain its offered MUJI room and selected media backend");
            if (f.observed_state != null) fail_if(((!) f.observed_state).we_should_send_video != full_recipient,
                "audio-only and video invitations must preserve their requested media without enabling capture");
            f.assert_no_acceptance();
        });
    }

    private void test_duplicate() {
        run((f) => {
            f.authorize(f.account, Roster.Item.SUBSCRIPTION_BOTH);
            f.invite("duplicate-proposal");
            f.invite("duplicate-proposal");
            fail_if(f.incoming != 1, "repeated delivery must not ring twice");
            fail_if(f.call_rows() != 1, "repeated delivery must not persist a second call");
            fail_if(f.conversation_rows() != 1, "repeated delivery must reuse the first CHAT");
            f.assert_no_acceptance();
        });
    }

    private void test_stale_stream() {
        run((f) => {
            f.authorize(f.account, Roster.Item.SUBSCRIPTION_BOTH);
            var obsolete_stream = new InviteStream(new Jid("old.example.test"));
            f.invite("obsolete-source", false, null, f.account.bare_jid, obsolete_stream);
            fail_if(f.incoming != 0, "a stale source stream must not ring even when bare recipient and roster match");
            fail_if(f.call_rows() != 0, "a stale source stream must leave no persisted call");
            fail_if(f.conversation_rows() != 0, "a stale source stream must not create a CHAT");
            f.assert_no_acceptance();
        });
    }

    private void test_rejected(string reason, bool jingle) {
        run((f) => {
            if (reason == "blocked" || reason == "foreign-to" || reason == "wrong-resource" || reason == "bare-sender")
                f.authorize(f.account, Roster.Item.SUBSCRIPTION_BOTH);
            else if (reason == "to") f.authorize(f.account, Roster.Item.SUBSCRIPTION_TO);
            else if (reason == "none") f.authorize(f.account, Roster.Item.SUBSCRIPTION_NONE);
            else if (reason == "other-roster") f.authorize(f.other, Roster.Item.SUBSCRIPTION_BOTH);
            if (reason == "blocked") f.stream.get_flag<Xep.BlockingCommand.Flag>(Xep.BlockingCommand.Flag.IDENTITY)
                .blocklist.add(f.peer.bare_jid.to_string());
            if (reason == "chat") f.manager.create_conversation(f.peer.bare_jid, f.account, Conversation.Type.CHAT);
            int initial_conversations = f.conversation_rows();
            Jid recipient = reason == "foreign-to" ? f.other.bare_jid
                : reason == "wrong-resource" ? f.account.bare_jid.with_resource("unrelated-installation") : f.bound;
            f.invite("reject-" + reason, jingle,
                reason == "bare-sender" ? f.peer.bare_jid : f.peer, recipient);
            fail_if(f.incoming != 0, "unauthorized endpoints must never publish a ringing UI event");
            fail_if(f.call_rows() != 0, "unauthorized endpoints must not leave persisted call rows");
            fail_if(f.conversation_rows() != initial_conversations,
                "untrusted invite ingress must not create a CHAT, including when another account trusts that peer");
            f.assert_no_acceptance();
        });
    }

    private class Fixture : Object {
        internal string directory;
        internal Database db;
        internal StreamInteractor interactor;
        internal Account account;
        internal Account other;
        internal Jid peer;
        internal Jid bound;
        internal Jid room;
        internal ConversationManager manager;
        internal Calls calls;
        internal InviteStream stream;
        internal InviteEngine engine;
        internal InviteApplication app;
        internal GLib.Application? previous;
        internal int incoming = 0;
        internal Call? observed_call;
        internal CallState? observed_state;
        internal Conversation? observed_conversation;

        internal Fixture() throws Error {
            directory = DirUtils.make_tmp("dinox-call-invite-audit-XXXXXX");
            db = new Database(Path.build_filename(directory, "app.db"), "call-invite-test-only");
            interactor = new StreamInteractor.for_tests(db);
            previous = GLib.Application.get_default();
            app = new InviteApplication(db, interactor);
            engine = new InviteEngine();
            app.plugin_registry.jmi_call_engine_plugin = engine;
            app.plugin_registry.muji_call_engine_plugin = engine;
            // Negative Jingle cases must not pass merely because legacy media
            // is unavailable. This fake advertises support but opens nothing.
            app.plugin_registry.video_call_plugin = new InviteLegacyEngine();
            GLib.Application.set_default(app);
            MessageStorage.start(interactor, db);
            FileTransferStorage.start(interactor, db);
            MessageProcessor.start(interactor, db);
            EntityInfo.start(interactor, db);
            RosterManager.start(interactor, db);
            Calls.start(interactor, db);
            ConversationManager.start(interactor, db);
            PresenceManager.start(interactor, db);
            OccupantIdStore.start(interactor, db);
            MucManager.start(interactor, db);
            BlockingManager.start(interactor);
            CallStore.start(interactor, db);
            interactor.add_module(new ContentItemStore.for_tests(interactor, db));
            account = new Account(new Jid("alice@example.test"), "test-only");
            account.enabled = true;
            account.persist(db);
            other = new Account(new Jid("other@example.test"), "test-only");
            other.enabled = true;
            other.persist(db);
            interactor.module_manager.initialize(account);
            interactor.account_added(account);
            peer = new Jid("bob@example.test/phone");
            bound = account.bare_jid.with_resource("actual-server-bound-resource");
            room = new Jid("call-room@conference.example.test");
            stream = new InviteStream(new Jid("example.test"));
            var bind = new Bind.Flag();
            bind.my_jid = bound;
            bind.finished = true;
            stream.add_flag(bind);
            stream.add_flag(new Xep.BlockingCommand.Flag());
            attach<Iq.Module>(Iq.Module.IDENTITY);
            attach<MessageModule>(MessageModule.IDENTITY);
            attach<Presence.Module>(Presence.Module.IDENTITY);
            attach<Xep.ServiceDiscovery.Module>(Xep.ServiceDiscovery.Module.IDENTITY);
            attach<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            // The public event belongs to the exact account module to which
            // Calls subscribed through its ordinary account_added lifecycle.
            Xep.CallInvites.Module invites = interactor.module_manager.get_module<Xep.CallInvites.Module>(account, Xep.CallInvites.Module.IDENTITY);
            stream.add_module(invites);
            stream.add_module(interactor.module_manager.get_module<Xep.BlockingCommand.Module>(account, Xep.BlockingCommand.Module.IDENTITY));
            stream.negotiation_complete = true;
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            manager = interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            calls = interactor.get_module<Calls>(Calls.IDENTITY);
            calls.call_incoming.connect((call, state, conversation, video, multiparty) => {
                incoming++;
                observed_call = call;
                observed_state = state;
                observed_conversation = conversation;
            });
            drain();
        }

        private void attach<T>(SimpleModuleIdentity identity) {
            XmppStreamModule module = (XmppStreamModule) interactor.module_manager.get_module<T>(account, identity);
            stream.add_module(module);
            module.attach(stream);
        }

        internal void authorize(Account owner, string subscription) throws Error {
            var item = new Roster.Item();
            item.jid = peer.bare_jid;
            item.subscription = subscription;
            var items = new ArrayList<Roster.Item>();
            items.add(item);
            interactor.get_module<RosterManager>(RosterManager.IDENTITY)
                .get_or_create_roster_store(owner).set_roster(items);
        }

        internal Conversation? chat() {
            return manager.get_conversation(peer.bare_jid, account, Conversation.Type.CHAT);
        }

        internal int call_rows() throws Error { return int.parse(db.query_column_checked("SELECT count(*) FROM call")[0]); }
        internal int conversation_rows() throws Error { return int.parse(db.query_column_checked("SELECT count(*) FROM conversation")[0]); }

        internal void invite(string id, bool jingle = false, Jid? from = null, Jid? to = null, XmppStream? source = null, bool video = true) {
            var methods = new ArrayList<StanzaNode>();
            methods.add(jingle
                ? new StanzaNode.build("jingle", Xep.CallInvites.NS_URI).put_attribute("sid", "jingle-" + id)
                : new StanzaNode.build("muji", Xep.Muji.NS_URI).put_attribute("room", room.to_string()));
            var message = Xep.CallInvites.Module.build_propose_message(id, to ?? bound, video, !jingle,
                MessageStanza.TYPE_CHAT, methods[0]);
            message.from = from ?? peer;
            stream.get_module<Xep.CallInvites.Module>(Xep.CallInvites.Module.IDENTITY)
                .call_proposed(source ?? stream, message.from, message.to, id, video, methods, message);
            drain();
        }

        internal void assert_no_acceptance() {
            fail_if(engine.allocations != 0, "ringing must not allocate a media session before user acceptance");
            fail_if(stream.joins != 0, "ringing must not enter the offered MUJI room before acceptance");
            fail_if(stream.accepts != 0, "ringing must not emit CIM accept or JMI proceed before acceptance");
        }

        internal void close() {
            if (observed_state != null) ((!) observed_state).reject();
            interactor.connection_manager.set_connection_state_for_tests(account,
                ConnectionManager.ConnectionState.DISCONNECTED);
            interactor.account_removed(account);
            interactor.get_module<MucManager>(MucManager.IDENTITY).shutdown();
            foreach (XmppStreamModule module in stream.modules) module.detach(stream);
            drain();
            GLib.Application.set_default(previous);
            db.close();
            remove_directory(directory);
        }
    }

    private static void drain() {
        int iterations = 0;
        while (MainContext.default().pending() && iterations++ < 1000) MainContext.default().iteration(false);
    }

    private static void remove_directory(string path) {
        try {
            Dir directory = Dir.open(path);
            string? name;
            while ((name = directory.read_name()) != null) {
                string child = Path.build_filename(path, (!) name);
                if (FileUtils.test(child, FileTest.IS_DIR)) remove_directory(child);
                else FileUtils.remove(child);
            }
            DirUtils.remove(path);
        } catch (FileError error) { }
    }
}

private class InviteApplication : GLib.Application, Dino.Application {
    public Database db { get; set; }
    public string? db_key { get; set; }
    public Security.FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
    public SearchPathGenerator? search_path_generator { get; set; }
    internal InviteApplication(Database db, StreamInteractor interactor) {
        Object(application_id: "im.dinox.call-invite-ingress-audit", flags: GLib.ApplicationFlags.NON_UNIQUE);
        this.db = db;
        this.db_key = "call-invite-test-only";
        this.file_encryption = new Security.FileEncryption((!) db_key);
        this.settings = new Dino.Entities.Settings.from_db(db);
        this.stream_interactor = interactor;
    }
    public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
}

private class InviteStream : XmppStream {
    internal int joins = 0;
    internal int accepts = 0;
    internal InviteStream(Jid remote) { base(remote); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError { throw new IOError.NOT_CONNECTED("audit stream has no network reader"); }
    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (node.name == "presence" && node.get_subnode("x", "http://jabber.org/protocol/muc") != null &&
                node.get_attribute("type") != Presence.Stanza.TYPE_UNAVAILABLE) joins++;
        if (node.name == "message" && (node.get_subnode("accept", Xep.CallInvites.NS_URI) != null ||
                node.get_subnode("proceed", Xep.JingleMessageInitiation.NS_URI) != null)) accepts++;
    }
}

private class InviteEngine : Object, Plugins.JmiCallEnginePlugin, Plugins.MujiCallEnginePlugin {
    internal int allocations = 0;
    public string engine_id { get { return "call-invite-audit"; } }
    public string group_engine_id { get { return "call-invite-audit"; } }
    public bool runtime_enabled() { return true; }
    bool Plugins.MujiCallEnginePlugin.runtime_enabled() { return true; }
    public bool can_start_audio_only(Account account) { return true; }
    public bool can_start_video(Account account) { return true; }
    public bool can_start_group_audio(Account account) { return true; }
    public bool can_start_group_video(Account account) { return true; }
    public Gee.List<Plugins.MediaDevice> get_audio_devices(bool incoming) { return new ArrayList<Plugins.MediaDevice>(); }
    public Plugins.MediaDevice? get_preferred_audio_device(bool incoming) { return null; }
    public void set_audio_device(Plugins.MediaDevice device) throws Error { }
    public Plugins.JmiCallEngineSession start_outgoing_audio_session(XmppStream stream, Jid local, Jid peer, string sid, uint64 id) throws Error {
        allocations++;
        throw new IOError.NOT_SUPPORTED("No media before acceptance");
    }
    public Plugins.JmiCallEngineSession create_incoming_session(XmppStream stream, Jid local, Jid peer, string sid, uint64 id, Gee.List<StanzaNode> descriptions) throws Error {
        allocations++;
        throw new IOError.NOT_SUPPORTED("No media before acceptance");
    }
    public bool handle_proceed(Jid from, Jid to, string sid) throws Error { allocations++; return false; }
    public Plugins.MujiCallEngineGroupSession create_group_session(XmppStream stream, Jid local, Jid room, uint64 id, bool video) throws Error {
        allocations++;
        throw new IOError.NOT_SUPPORTED("No media before acceptance");
    }
}

private class InviteLegacyEngine : Object, Plugins.VideoCallPlugin {
    public bool supported() { return true; }
    public Plugins.VideoCallWidget? create_widget(Plugins.WidgetType type) { return null; }
    public Gee.List<Plugins.MediaDevice> get_devices(string media, bool incoming) { return new ArrayList<Plugins.MediaDevice>(); }
    public Plugins.MediaDevice? get_preferred_device(string media, bool incoming) { return null; }
    public Plugins.MediaDevice? get_device(Xep.JingleRtp.Stream? stream, bool incoming) { return null; }
    public void set_pause(Xep.JingleRtp.Stream? stream, bool pause) { }
    public void set_device(Xep.JingleRtp.Stream? stream, Plugins.MediaDevice? device) { }
    public double get_device_volume(Plugins.MediaDevice? device) { return 1; }
    public void set_device_volume(Plugins.MediaDevice? device, double volume) { }
    public void set_digital_gain_db(int gain_db, bool manual_mode) { }
    public double get_stream_volume(Xep.JingleRtp.Stream? stream) { return 1; }
    public void set_stream_volume(Xep.JingleRtp.Stream? stream, double volume) { }
    public void send_dtmf(Xep.JingleRtp.Stream? stream, char digit, uint duration_ms = 250) { }
    public void dispose_pipeline() { }
    public void dump_dot() { }
}

}
