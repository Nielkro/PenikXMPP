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
    private uint attach_idle;
    private XmppStream? pending_attach_stream;
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
                owner.id != owner_id || !owner.enabled ||
                app.stream_interactor.get_stream(owner) != candidate) return;
        if ((stream == candidate && current(candidate)) || pending_attach_stream == candidate) return;
        detach();
        // XmppStream emits negotiated before setting negotiation_complete.
        // Re-enter once after that synchronous emission, retaining this candidate.
        pending_attach_stream = candidate;
        attach_idle = Idle.add(() => {
            attach_idle = 0; pending_attach_stream = null;
            attach_ready(account, candidate);
            return Source.REMOVE;
        });
    }

    private void attach_ready(Account account, XmppStream candidate) {
        if (finished || account != owner || account.id != owner_id ||
                owner.id != owner_id || !owner.enabled ||
                app.stream_interactor.get_connected_stream_for_action(owner) != candidate) return;
        // Both negotiated and resumed paths append only after real modules attached.
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
        if (attach_idle != 0) { Source.remove(attach_idle); attach_idle = 0; }
        pending_attach_stream = null;
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

    // Pre-filter pin only: metadata is not proof of the session's public identity.
    internal Json.Object? public_metadata_binding(XmppStream candidate, Jid peer, int device) throws Error {
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
        if (metadata_hex == null || !current(candidate)) return null;
        row.set_int_member("peer_device_id", device); row.set_string_member("peer_public_identity_hex", (!) metadata_hex);
        row.set_int_member("peer_trust", ((!) metadata)[database.identity_meta.trust_level]);
        row.set_boolean_member("peer_identity_changed", ((!) metadata)[database.identity_meta.identity_key_changed]);
        row.set_boolean_member("peer_active", ((!) metadata)[database.identity_meta.now_active]);
        return row;
    }

    private Json.Object? binding_unavailable(Json.Object diagnostic, string reason) {
        diagnostic.set_string_member("reason", reason);
        return null;
    }

    // Called synchronously by the appended incoming filter after the real Draft
    // decrypt/rewrite. Never serialize the SessionRecord or any private material.
    internal Json.Object? public_binding(XmppStream candidate, Jid peer, int device,
            string stage, out Json.Object diagnostic) throws Error {
        diagnostic = new Json.Object();
        diagnostic.set_string_member("stage", stage);
        diagnostic.set_string_member("step", "metadata");
        diagnostic.set_string_member("reason", "not_evaluated");
        diagnostic.set_string_member("public_session_origin", "not_observed");
        diagnostic.set_string_member("backing_owner_check", "backing_belongs_to_not_public");
        diagnostic.set_boolean_member("backing_owner_independently_verified", false);
        diagnostic.set_boolean_member("native_memory_checked", false);
        diagnostic.set_boolean_member("native_memory_present", false);
        diagnostic.set_boolean_member("public_session_equals_metadata", false);
        try {
            if (stage != "before_filters" && stage != "after_real_draft_rewrite")
                return binding_unavailable(diagnostic, "unknown_observation_stage");
            diagnostic.set_string_member("step", "own_public_identity");
            if (own_public_binding(candidate) == null)
                return binding_unavailable(diagnostic, "own_public_identity_unavailable");
            diagnostic.set_string_member("step", "peer_public_metadata");
            Json.Object? row = public_metadata_binding(candidate, peer, device);
            if (row == null) return binding_unavailable(diagnostic, "peer_public_metadata_unavailable");
            var module = candidate.get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY);
            if (module == null) return binding_unavailable(diagnostic, "current_omemo_module_unavailable");
            var store = ((!) module).store;
            var session_store = store.session_store;
            var database = (!) plugin.db;
            int identity = database.identity.get_id_checked(owner_id);
            diagnostic.set_string_member("step", "registration");
            Qlite.Row? own_row = database.identity.select()
                .with(database.identity.account_id, "=", owner_id).single().iterator().get_next_checked();
            if (identity <= 0 || own_row == null || ((!) own_row)[database.identity.id] != identity ||
                    ((!) own_row)[database.identity.registration_pending] || store.local_registration_id == 0 ||
                    ((!) own_row)[database.identity.device_id] != store.local_registration_id)
                return binding_unavailable(diagnostic, "selected_account_registration_not_ready");
            if (row.get_boolean_member("peer_identity_changed") ||
                    (row.get_int_member("peer_trust") != (int) Dino.Plugins.Omemo.TrustLevel.TRUSTED &&
                     row.get_int_member("peer_trust") != (int) Dino.Plugins.Omemo.TrustLevel.VERIFIED))
                return binding_unavailable(diagnostic, "peer_public_identity_not_accepted");
            var address = new global::Omemo.Address(peer.bare_jid.to_string(), device);
            try {
                diagnostic.set_string_member("step", "session_presence");
                if (!store.contains_session(address)) return binding_unavailable(diagnostic, "session_unavailable");
                diagnostic.set_string_member("step", "session_public_identity");
                // Public wrapper: ensure_persistence_ready(), then exactly
                // Protocol.Session.load_session(native_context, out record, address, 3).
                global::Omemo.SessionRecord record = store.load_session(address);
                if (record.state.session_version != 3)
                    return binding_unavailable(diagnostic, "session_version_not_legacy_3");
                global::Omemo.ECPublicKey? remote_public = record.state.remote_identity_key;
                if (remote_public == null) return binding_unavailable(diagnostic, "session_remote_public_identity_unavailable");
                string? session_hex = public_hex(((!) remote_public).serialize());
                if (session_hex == null) return binding_unavailable(diagnostic, "session_remote_public_identity_invalid");
                diagnostic.set_string_member("public_session_origin", stage == "after_real_draft_rewrite" ?
                    "post_decrypt_promoted_record_state_remote_identity_key_v3" :
                    "pre_filter_record_state_remote_identity_key_v3_no_new_decryption_claim");
                if (session_hex != row.get_string_member("peer_public_identity_hex"))
                    return binding_unavailable(diagnostic, "session_public_identity_differs_from_metadata");
                diagnostic.set_boolean_member("public_session_equals_metadata", true);
                diagnostic.set_string_member("step", "native_memory_public_identity");
                uint8[]? memory_public = store.identity_key_store.load_identity(address);
                diagnostic.set_boolean_member("native_memory_checked", true);
                diagnostic.set_boolean_member("native_memory_present", memory_public != null);
                if (memory_public != null && public_hex(memory_public) != session_hex)
                    return binding_unavailable(diagnostic, "native_memory_public_identity_differs_from_session");
                diagnostic.set_string_member("step", "current_identity_recheck");
                Json.Object? current_public = public_metadata_binding(candidate, peer, device);
                Qlite.Row? ready_after = database.identity.select()
                    .with(database.identity.account_id, "=", owner_id).single().iterator().get_next_checked();
                if (current_public == null || !current(candidate) || ((!) module).store != store ||
                        store.session_store != session_store ||
                        ready_after == null || ((!) ready_after)[database.identity.id] != identity ||
                        ((!) ready_after)[database.identity.registration_pending] ||
                        ((!) ready_after)[database.identity.device_id] != store.local_registration_id ||
                        current_public.get_int_member("own_device_id") != row.get_int_member("own_device_id") ||
                        current_public.get_string_member("own_public_identity_hex") != row.get_string_member("own_public_identity_hex") ||
                        current_public.get_string_member("peer_public_identity_hex") != session_hex ||
                        current_public.get_boolean_member("peer_identity_changed") ||
                        current_public.get_int_member("peer_trust") != row.get_int_member("peer_trust"))
                    return binding_unavailable(diagnostic, "current_account_store_or_public_identity_changed");
                row.set_boolean_member("public_session_equals_metadata", true);
                row.set_string_member("public_session_origin", diagnostic.get_string_member("public_session_origin"));
                row.set_boolean_member("native_memory_present", memory_public != null);
                row.set_boolean_member("public_native_store_equals_metadata", memory_public != null);
                diagnostic.set_string_member("step", "complete");
                diagnostic.set_string_member("reason", memory_public != null ?
                    "session_and_native_memory_public_identity_match" :
                    "session_public_identity_matches_native_memory_absent");
                return row;
            } finally { address.device_id = 0; }
        } catch (Error e) {
            return binding_unavailable(diagnostic, "public_binding_read_failed");
        }
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
        bool attached = stream != null && current((!) stream);
        row.set_boolean_member("actual_attached", attached);
        row.set_boolean_member("late_attach_pending", attach_idle != 0);
        row.set_int_member("stream_generation", generation);
        row.set_string_member("local_full_jid", attached ? local_full : "");
        row.set_boolean_member("real_draft_module_present", attached &&
            ((!) stream).get_module<Dino.Plugins.Omemo.DtlsSrtpVerificationDraft.StreamModule>(
                Dino.Plugins.Omemo.DtlsSrtpVerificationDraft.StreamModule.IDENTITY) != null);
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
