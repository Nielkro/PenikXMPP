// Private read-only evidence, not product code or a security filter decision.
using Dino;
using Dino.Entities;
using Gee;
using Xmpp;

namespace LocalInterop {

class ObserverScope : Object {
    internal const string DRAFT = "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification";
    internal const string LEGACY = "eu.siacs.conversations.axolotl";
    private const int MAX_RECORDS = 1024;
    private const int MAX_BYTES = 4 * 1024 * 1024;
    private const int MAX_RECORD_BYTES = 16384;
    private const int64 MAX_DURATION_US = 2700 * 1000000L;
    internal weak Driver driver;
    internal InteropApplication app;
    internal Dino.Plugins.Omemo.Plugin plugin;
    internal Account owner;
    internal int owner_id;
    internal XmppStream? stream;
    internal uint generation = 0;
    internal string local_full = "";
    private FileOutputStream? output;
    private MujiPresenceObserver presence;
    private FingerprintRewriteObserver auth;
    private int records = 0;
    private int bytes_written = 0;
    private int64 started_us;
    private bool finished = false;
    private string? unavailable;
    private uint timer;
    private ulong negotiated_handler;
    private ulong resumed_handler;
    private ulong state_handler;
    private ulong removed_handler;
    internal string evidence_path;

    public ObserverScope(Driver driver, InteropApplication app,
            Dino.Plugins.Omemo.Plugin plugin, Account owner, string root) throws Error {
        if (!test_bare(owner.bare_jid.to_string()) || owner.id <= 0)
            throw new IOError.PERMISSION_DENIED("Observer requires exact existing test account");
        this.driver = driver; this.app = app; this.plugin = plugin;
        this.owner = owner; this.owner_id = owner.id;
        this.started_us = get_monotonic_time();
        evidence_path = Path.build_filename(root, "private-wire-observers-" + Uuid.string_random() + ".jsonl");
        output = File.new_for_path(evidence_path).create(FileCreateFlags.PRIVATE);
        presence = new MujiPresenceObserver(this);
        auth = new FingerprintRewriteObserver(this);
        negotiated_handler = app.stream_interactor.stream_negotiated.connect(on_stream_ready);
        resumed_handler = app.stream_interactor.stream_resumed.connect(on_stream_ready);
        state_handler = app.stream_interactor.connection_manager.connection_state_changed.connect((account, state) => {
            if (account == owner && state != ConnectionManager.ConnectionState.CONNECTED) detach();
        });
        removed_handler = app.stream_interactor.account_removed.connect((account) => {
            if (account == owner) finish();
        });
        timer = Timeout.add_seconds(1, () => {
            if (finished) return false;
            if (get_monotonic_time() - started_us >= MAX_DURATION_US) { finish(); return false; }
            if (stream != null && !current((!) stream)) detach();
            return !finished;
        });
        // Restoration may have negotiated before the private driver selected its account.
        XmppStream? existing = app.stream_interactor.get_connected_stream_for_action(owner);
        if (existing != null) on_stream_ready(owner, (!) existing);
    }

    internal static bool test_bare(string bare) {
        return bare == "nora.schneider.interop.de.71115b@dinox.im" ||
            bare == "leon.fischer.interop.de.71115b@dinox.im" ||
            bare == "felix.wagner.interop.de.71115b@dinox.im";
    }

    internal static int device_number(string? raw) {
        if (raw == null || raw.length == 0 || raw.length > 10) return 0;
        int value = 0;
        for (int i = 0; i < raw.length; i++) {
            int d = raw[i] - '0';
            if (d < 0 || d > 9 || value > (int.MAX - d) / 10) return 0;
            value = value * 10 + d;
        }
        return value;
    }

    internal static string? public_hex(uint8[]? bytes) {
        if (bytes == null || bytes.length != 33 || bytes[0] != 5) return null;
        var hex = new StringBuilder();
        foreach (uint8 b in bytes) hex.append_printf("%02x", (uint) b);
        return hex.str;
    }

    internal static string? public_base64_hex(string? value) {
        return value == null ? null : public_hex(Base64.decode((!) value));
    }

    internal bool current(XmppStream candidate) {
        if (finished || stream != candidate || owner.id != owner_id || !owner.enabled ||
                get_monotonic_time() - started_us >= MAX_DURATION_US ||
                app.stream_interactor.get_connected_stream_for_action(owner) != candidate) return false;
        Bind.Flag? bind = candidate.get_flag<Bind.Flag>(Bind.Flag.IDENTITY);
        return bind != null && ((!) bind).my_jid != null &&
            ((!) bind).my_jid.to_string() == local_full &&
            ((!) bind).my_jid.equals_bare(owner.bare_jid) &&
            ((!) bind).my_jid.resourcepart != null;
    }

    internal bool peer_allowed(Jid peer, bool allow_self = false) {
        return peer.resourcepart != null && test_bare(peer.bare_jid.to_string()) &&
            ((allow_self && peer.to_string() == local_full) ||
             (!peer.equals_bare(owner.bare_jid) && driver.observer_peer_allowed(peer)));
    }

    internal bool local_recipient(Jid? recipient) {
        if (recipient == null) return true;
        try {
            Jid local = new Jid(local_full);
            return recipient.equals_bare(local) &&
                (recipient.resourcepart == null || recipient.equals(local));
        } catch (InvalidJidError e) { return false; }
    }

    private void on_stream_ready(Account account, XmppStream candidate) {
        if (finished || account != owner || account.id != owner_id ||
                app.stream_interactor.get_connected_stream_for_action(owner) != candidate) return;
        // Both negotiated and resumed paths re-append only after real modules attached.
        detach();
        Bind.Flag? bind = candidate.get_flag<Bind.Flag>(Bind.Flag.IDENTITY);
        var draft = candidate.get_module<Dino.Plugins.Omemo.DtlsSrtpVerificationDraft.StreamModule>(
            Dino.Plugins.Omemo.DtlsSrtpVerificationDraft.StreamModule.IDENTITY);
        if (bind == null || ((!) bind).my_jid == null ||
                !((!) bind).my_jid.equals_bare(owner.bare_jid) ||
                ((!) bind).my_jid.resourcepart == null || draft == null) {
            unavailable = "current binding or real draft module unavailable";
            return;
        }
        stream = candidate; local_full = ((!) bind).my_jid.to_string(); generation++;
        presence.attach(candidate);
        auth.attach(candidate); // add_incoming_request_filter appends after the draft.
        var row = new Json.Object(); row.set_string_member("event", "observer_stream_attached");
        row.set_boolean_member("real_draft_module_present", true); emit(row);
    }

    internal void detach() {
        if (stream == null) return;
        XmppStream old = (!) stream;
        generation++; stream = null; local_full = "";
        presence.detach(old); auth.detach(old);
    }

    internal Json.Object? own_public_binding(XmppStream candidate) throws Error {
        if (!current(candidate) || plugin.db == null) return null;
        var module = candidate.get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY);
        if (module == null) return null;
        var database = (!) plugin.db;
        uint32 own_device = ((!) module).store.local_registration_id;
        if (own_device == 0 || own_device > int.MAX) return null;
        Bytes? own_public = ((!) module).store.identity_key_store.identity_key_public;
        if (own_public == null) return null;
        string? own_hex = public_hex(((!) own_public).get_data());
        if (own_hex == null) return null;
        bool own_found = false;
        foreach (Qlite.Row own_row in database.identity.select().with(database.identity.account_id, "=", owner_id)) {
            if (own_row[database.identity.device_id] == own_device &&
                    public_base64_hex(own_row[database.identity.identity_key_public_base64]) == own_hex) own_found = true;
        }
        if (!own_found || !current(candidate)) return null;
        var row = new Json.Object();
        row.set_int_member("own_device_id", own_device); row.set_string_member("own_public_identity_hex", (!) own_hex);
        return row;
    }

    // Reads only selected-account public identity metadata and native public identity.
    internal Json.Object? public_binding(XmppStream candidate, Jid peer, int device) throws Error {
        if (!current(candidate) || !peer_allowed(peer) || device <= 0 || plugin.db == null) return null;
        Json.Object? row = own_public_binding(candidate);
        if (row == null) return null;
        var module = candidate.get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY);
        if (module == null) return null;
        var database = (!) plugin.db;
        int identity = database.identity.get_id_checked(owner_id);
        if (identity <= 0) return null;
        Qlite.Row? metadata = database.identity_meta.get_device_checked(identity, peer.bare_jid.to_string(), device);
        if (metadata == null) return null;
        string? metadata_hex = public_base64_hex(((!) metadata)[database.identity_meta.identity_key_public_base64]);
        var address = new global::Omemo.Address(peer.bare_jid.to_string(), device);
        string? native_hex = null;
        try { native_hex = public_hex(((!) module).store.identity_key_store.load_identity(address)); }
        finally { address.device_id = 0; }
        if (metadata_hex == null || native_hex == null || metadata_hex != native_hex || !current(candidate)) return null;
        row.set_int_member("peer_device_id", device); row.set_string_member("peer_public_identity_hex", (!) native_hex);
        row.set_int_member("peer_trust", ((!) metadata)[database.identity_meta.trust_level]);
        row.set_boolean_member("peer_identity_changed", ((!) metadata)[database.identity_meta.identity_key_changed]);
        row.set_boolean_member("peer_active", ((!) metadata)[database.identity_meta.now_active]);
        row.set_boolean_member("public_native_store_equals_metadata", true);
        return row;
    }

    internal void note_unavailable(string reason) { unavailable = reason; }

    internal void emit(Json.Object row) {
        if (finished || output == null) return;
        if (records >= MAX_RECORDS) { unavailable = "observer record limit reached"; finish(); return; }
        row.set_int_member("schema_version", 1);
        row.set_string_member("run_id", "20261015-71115b");
        row.set_string_member("account", owner.bare_jid.to_string()); row.set_int_member("account_id", owner_id);
        row.set_string_member("local_full_jid", local_full); row.set_int_member("stream_generation", generation);
        row.set_int_member("observed_real_us", get_real_time()); row.set_int_member("observed_monotonic_us", get_monotonic_time());
        var node = new Json.Node(Json.NodeType.OBJECT); node.set_object(row);
        var generator = new Json.Generator(); generator.set_root(node);
        string line = generator.to_data(null) + "\n";
        if (line.length > MAX_RECORD_BYTES) { unavailable = "observer record exceeds fixed size limit"; return; }
        if (bytes_written + line.length > MAX_BYTES) { unavailable = "observer byte limit reached"; finish(); return; }
        try {
            size_t written;
            ((!) output).write_all(line.data, out written);
            ((!) output).flush(); bytes_written += (int) written; records++;
        } catch (Error e) { unavailable = "private observer output unavailable"; finish(); }
    }

    internal Json.Object status() {
        var row = new Json.Object(); row.set_string_member("path", evidence_path);
        row.set_int_member("records", records); row.set_int_member("bytes", bytes_written);
        row.set_boolean_member("finished", finished);
        if (unavailable != null) row.set_string_member("unavailable", (!) unavailable);
        row.set_boolean_member("observation_only_no_blanket_call_auth_claim", true);
        return row;
    }

    public void finish() {
        if (finished) return;
        detach(); finished = true;
        if (timer != 0) { Source.remove(timer); timer = 0; }
        SignalHandler.disconnect(app.stream_interactor, negotiated_handler);
        SignalHandler.disconnect(app.stream_interactor, resumed_handler);
        SignalHandler.disconnect(app.stream_interactor.connection_manager, state_handler);
        SignalHandler.disconnect(app.stream_interactor, removed_handler);
        try { if (output != null) ((!) output).close(); } catch (Error e) { }
        output = null;
    }
}

}
