using Dino.Entities;
using Gee;
using Omemo;
using Qlite;
using Xmpp;

namespace Dino.Plugins.Omemo {

internal class LegacyInvalidPreKey : Object {
    internal Jid jid;
    internal int device_id;
    internal string identity_key;
    internal string packet_hash;

    internal LegacyInvalidPreKey(Jid jid, int device_id,
            string identity_key, uint8[] packet) {
        this.jid = jid.bare_jid;
        this.device_id = device_id;
        this.identity_key = identity_key;
        packet_hash = Checksum.compute_for_data(ChecksumType.SHA256, packet);
    }

    internal string target_key() {
        return jid.to_string() + ":" + device_id.to_string();
    }
}

internal class LegacyRecoveryAttempt : Object {
    internal LegacyInvalidPreKey failure;
    internal int64 started;
    internal LegacyRecoveryTransport? transport;

    internal LegacyRecoveryAttempt(LegacyInvalidPreKey failure, int64 now) {
        this.failure = failure;
        started = now;
    }
}

/** Confirmation protection outlives the disposable encrypted wire snapshot. */
internal class LegacyRecoveryScope : Object {
    internal string session_base_key { get; private set; }
    internal int identity_id { get; private set; }
    internal uint32 registration_id { get; private set; }
    internal string local_identity { get; private set; }
    internal string peer_jid { get; private set; }
    internal int peer_device_id { get; private set; }
    internal string peer_identity { get; private set; }

    internal LegacyRecoveryScope(LegacyInvalidPreKey failure,
            string session_base_key, int identity_id = 0,
            uint32 registration_id = 0, string local_identity = "") {
        peer_jid = failure.jid.to_string();
        peer_device_id = failure.device_id;
        peer_identity = failure.identity_key;
        this.session_base_key = session_base_key;
        this.identity_id = identity_id;
        this.registration_id = registration_id;
        this.local_identity = local_identity;
    }

    internal bool matches_failure(LegacyInvalidPreKey failure) {
        return peer_jid == failure.jid.to_string() &&
            peer_device_id == failure.device_id && peer_identity == failure.identity_key;
    }

    internal bool matches_own_identity(int identity_id, uint32 registration_id,
            string local_identity) {
        return this.identity_id == identity_id &&
            this.registration_id == registration_id && this.local_identity == local_identity;
    }
}

/** Immutable wire material; delivery retries never create another ratchet. */
internal class LegacyRecoveryTransport : Object {
    internal LegacyRecoveryScope scope { get; private set; }
    internal string session_base_key { get { return scope.session_base_key; } }
    private string stanza_id;
    private string encrypted_key;
    private string iv;
    private bool write_attempted = false;
    private int64 last_write_attempt = 0;

    internal LegacyRecoveryTransport(LegacyInvalidPreKey failure,
            MessageStanza response, string session_base_key, int identity_id,
            uint32 registration_id, string local_identity) throws Error {
        StanzaNode? encrypted = response.stanza.get_subnode("encrypted", NS_URI);
        StanzaNode? header = encrypted != null ? encrypted.get_subnode("header", NS_URI) : null;
        StanzaNode? iv_node = header != null ? header.get_subnode("iv", NS_URI) : null;
        Gee.List<StanzaNode>? keys = header != null ? header.get_subnodes("key", NS_URI) : null;
        if (response.id == null || response.to == null || response.to.is_full() ||
                !response.to.equals_bare(failure.jid) ||
                response.type_ != MessageStanza.TYPE_CHAT ||
                encrypted == null || encrypted.get_subnode("payload", NS_URI) != null ||
                header == null || header.get_attribute_int("sid") != registration_id ||
                iv_node == null || keys == null || keys.size != 1 ||
                keys[0].get_attribute_int("rid") != failure.device_id ||
                !keys[0].get_attribute_bool("prekey", false)) {
            throw new IOError.INVALID_DATA("Invalid committed OMEMO recovery transport");
        }
        iv = iv_node.get_string_content();
        encrypted_key = keys[0].get_string_content();
        if (Base64.decode(iv).length != 12 || encrypted_key.length == 0 ||
                encrypted_key.length > 4096) {
            throw new IOError.INVALID_DATA("Invalid committed OMEMO recovery wire material");
        }
        stanza_id = response.id;
        scope = new LegacyRecoveryScope(failure, session_base_key,
                identity_id, registration_id, local_identity);
    }

    internal bool matches_failure(LegacyInvalidPreKey failure) {
        return scope.matches_failure(failure);
    }

    internal bool may_retry(int64 now) {
        return !write_attempted || now - last_write_attempt >= LegacyRecoveryLimiter.COOLDOWN;
    }

    internal void write_started(int64 now) {
        write_attempted = true;
        last_write_attempt = now;
    }

    internal MessageStanza create_stanza() throws Error {
        var data = new Xep.Omemo.EncryptionData(scope.registration_id);
        data.iv = Base64.decode(iv);
        data.add_device_key(scope.peer_device_id, Base64.decode(encrypted_key), true);
        var response = new MessageStanza(stanza_id);
        response.to = new Jid(scope.peer_jid);
        response.type_ = MessageStanza.TYPE_CHAT;
        response.stanza.put_node(data.get_encrypted_node());
        response.stanza.put_node(new StanzaNode.build("store", "urn:xmpp:hints").add_self_xmlns());
        return response;
    }

    internal bool matches_stanza(MessageStanza response) {
        StanzaNode? encrypted = response.stanza.get_subnode("encrypted", NS_URI);
        StanzaNode? header = encrypted != null ? encrypted.get_subnode("header", NS_URI) : null;
        StanzaNode? iv_node = header != null ? header.get_subnode("iv", NS_URI) : null;
        Gee.List<StanzaNode>? keys = header != null ? header.get_subnodes("key", NS_URI) : null;
        return response.id == stanza_id && response.to != null &&
            response.to.to_string() == scope.peer_jid && response.type_ == MessageStanza.TYPE_CHAT &&
            response.body == null && encrypted != null &&
            encrypted.get_subnode("payload", NS_URI) == null &&
            header != null && header.get_attribute_int("sid") == scope.registration_id &&
            iv_node != null && iv_node.get_string_content() == iv &&
            keys != null && keys.size == 1 &&
            keys[0].get_attribute_int("rid") == scope.peer_device_id &&
            keys[0].get_attribute_bool("prekey", false) &&
            keys[0].get_string_content() == encrypted_key;
    }
}

/** Per-account bounds survive reconnects while this account decryptor exists. */
internal class LegacyRecoveryLimiter : Object {
    internal const int MAX_RECENT = 128;
    internal const int MAX_PENDING = 4;
    internal const int64 COOLDOWN = 5 * TimeSpan.MINUTE;
    internal const int64 REPLAY_WINDOW = TimeSpan.HOUR;
    private ArrayList<LegacyRecoveryAttempt> recent = new ArrayList<LegacyRecoveryAttempt>();
    private HashMap<string, LegacyRecoveryAttempt> pending = new HashMap<string, LegacyRecoveryAttempt>();
    private HashMap<string, LegacyRecoveryScope> awaiting_confirmation = new HashMap<string, LegacyRecoveryScope>();
    private HashMap<string, LegacyRecoveryTransport> undelivered = new HashMap<string, LegacyRecoveryTransport>();

    internal LegacyRecoveryAttempt? reserve(LegacyInvalidPreKey failure,
            int64 now) {
        string target = failure.target_key();
        for (int i = recent.size - 1; i >= 0; i--) {
            if (now - recent[i].started >= REPLAY_WINDOW) recent.remove_at(i);
        }
        if (pending.has_key(target) || pending.size >= MAX_PENDING) return null;
        if (awaiting_confirmation.has_key(target)) {
            LegacyRecoveryTransport? transport = undelivered[target];
            if (transport == null || !transport.matches_failure(failure) ||
                    !transport.may_retry(now)) return null;
            foreach (LegacyRecoveryAttempt previous in recent) {
                if (previous.failure.target_key() == target &&
                        previous.failure.packet_hash == failure.packet_hash) return null;
            }
            if (recent.size >= MAX_RECENT) return null;
            var retry = new LegacyRecoveryAttempt(failure, now);
            retry.transport = transport;
            recent.add(retry);
            pending[target] = retry;
            return retry;
        }
        if (awaiting_confirmation.size >= MAX_RECENT) return null;
        for (int i = recent.size - 1; i >= 0; i--) {
            LegacyRecoveryAttempt previous = recent[i];
            if (previous.failure.target_key() == target &&
                    (previous.failure.packet_hash == failure.packet_hash ||
                     now - previous.started < COOLDOWN)) return null;
        }
        // Do not evict replay protection to make room for a stream of failures.
        if (recent.size >= MAX_RECENT) return null;
        var attempt = new LegacyRecoveryAttempt(failure, now);
        recent.add(attempt);
        pending[target] = attempt;
        return attempt;
    }

    internal bool is_pending(LegacyRecoveryAttempt attempt) {
        return pending[attempt.failure.target_key()] == attempt;
    }

    internal void complete(LegacyRecoveryAttempt attempt) {
        if (is_pending(attempt)) pending.unset(attempt.failure.target_key());
    }

    internal void committed(LegacyRecoveryAttempt attempt, string session_base_key,
            LegacyRecoveryTransport? transport = null) {
        string target = attempt.failure.target_key();
        awaiting_confirmation[target] = transport != null ? ((!) transport).scope :
            new LegacyRecoveryScope(attempt.failure, session_base_key);
        if (transport != null) {
            attempt.transport = transport;
            undelivered[target] = transport;
        }
    }

    internal void write_started(LegacyRecoveryAttempt attempt, int64 now) {
        if (is_pending(attempt) && attempt.transport != null &&
                undelivered[attempt.failure.target_key()] == attempt.transport) {
            ((!) attempt.transport).write_started(now);
        }
    }

    internal void delivered(LegacyRecoveryAttempt attempt) {
        if (is_pending(attempt) &&
                undelivered[attempt.failure.target_key()] == attempt.transport) {
            undelivered.unset(attempt.failure.target_key());
        }
    }

    internal void retire_target(Jid jid, int device_id) {
        string target = jid.bare_jid.to_string() + ":" + device_id.to_string();
        retire_target_key(target);
    }

    private void retire_target_key(string target) {
        awaiting_confirmation.unset(target);
        undelivered.unset(target);
        pending.unset(target);
        for (int i = recent.size - 1; i >= 0; i--) {
            if (recent[i].failure.target_key() == target) recent.remove_at(i);
        }
    }

    internal void retire_contact(Jid jid) {
        string name = jid.bare_jid.to_string();
        var targets = new HashSet<string>();
        foreach (LegacyRecoveryScope scope in awaiting_confirmation.values) {
            if (scope.peer_jid == name) targets.add(name + ":" + scope.peer_device_id.to_string());
        }
        foreach (LegacyRecoveryAttempt attempt in recent) {
            if (attempt.failure.jid.to_string() == name) targets.add(attempt.failure.target_key());
        }
        foreach (LegacyRecoveryAttempt attempt in pending.values) {
            if (attempt.failure.jid.to_string() == name) targets.add(attempt.failure.target_key());
        }
        foreach (string target in targets) retire_target_key(target);
    }

    /** Caller must first verify the persisted own identity and approved peer. */
    internal void retire_obsolete_scope(LegacyInvalidPreKey failure,
            int identity_id, uint32 registration_id, string local_identity) {
        var obsolete = new ArrayList<LegacyRecoveryScope>();
        foreach (LegacyRecoveryScope scope in awaiting_confirmation.values) {
            if ((scope.identity_id > 0 &&
                    !scope.matches_own_identity(identity_id, registration_id, local_identity)) ||
                    (scope.peer_jid == failure.jid.to_string() &&
                     scope.peer_device_id == failure.device_id &&
                     scope.peer_identity != failure.identity_key)) obsolete.add(scope);
        }
        foreach (LegacyRecoveryScope scope in obsolete) {
            retire_target_key(scope.peer_jid + ":" + scope.peer_device_id.to_string());
        }
    }

    internal void authenticated_from(Jid jid, int device_id,
            string? session_base_key = null) {
        string target = jid.bare_jid.to_string() + ":" + device_id.to_string();
        if (!awaiting_confirmation.has_key(target)) pending.unset(target);
        // A delayed message can promote an archived receive state. It must not
        // enable another forced rekey and eventually evict the native 40-state
        // archive. Only an authenticated reply on our new session confirms it.
        if (session_base_key != null &&
                awaiting_confirmation.has_key(target) &&
                awaiting_confirmation[target].session_base_key == session_base_key) {
            awaiting_confirmation.unset(target);
            undelivered.unset(target);
            pending.unset(target);
        }
    }
}

/**
 * XEP-0384 v0.3 section 5 recovery for live direct/private-MUC payload messages. Automatic
 * responses are intentionally suppressed for archives/delayed copies, unknown
 * identities, and payloadless transports: unauthenticated failures must not
 * replace trusted identities or cause reciprocal key-transport repair loops.
 */
internal class LegacyPreKeyRecovery : Object {
    [CCode (cname = "session_record_has_session_state", cheader_filename = "omemo/session_record.h")]
    private static extern int native_has_session_state(SessionRecord record,
            uint32 version, ECPublicKey base_key);
    /** Only current server-disclosed room identities authorize a direct reply. */
    private class MucContext : Object {
        internal MucManager manager;
        internal MucManager.MucOwnerMutationContext context;
        internal uint64 visibility_generation;
        internal Jid occupant;
        internal Entities.Message message_identity;

        internal MucContext(MucManager manager,
                MucManager.MucOwnerMutationContext context, Jid occupant,
                uint64 visibility_generation, Entities.Message message) {
            this.manager = manager;
            this.context = context;
            this.occupant = occupant;
            this.visibility_generation = visibility_generation;
            // Capture identity evidence before yielding; later mutation of the
            // input message must not authorize a reused room nickname.
            message_identity = new Entities.Message(null) {
                real_jid = message.real_jid,
                occupant_db_id = message.occupant_db_id
            };
        }
    }

    private class ResetRelay : Object {
        private weak LegacyPreKeyRecovery owner;

        internal ResetRelay(LegacyPreKeyRecovery owner) {
            this.owner = owner;
        }

        internal void on_session_reset(Account account, Jid jid, int device_id) {
            if (owner != null && account == owner.account) owner.limiter.retire_target(jid, device_id);
        }

        internal void on_contact_reset(Account account, Jid jid) {
            if (owner != null && account == owner.account) owner.limiter.retire_contact(jid);
        }
    }

    private Account account;
    private StreamInteractor stream_interactor;
    private TrustManager trust_manager;
    private Database db;
    private Store store;
    private LegacyRecoveryLimiter limiter = new LegacyRecoveryLimiter();
    private ResetRelay reset_relay;

    internal LegacyPreKeyRecovery(Account account,
            StreamInteractor stream_interactor, TrustManager trust_manager,
            Database db, Store store) {
        this.account = account;
        this.stream_interactor = stream_interactor;
        this.trust_manager = trust_manager;
        this.db = db;
        this.store = store;
        reset_relay = new ResetRelay(this);
        trust_manager.session_reset.connect(reset_relay.on_session_reset);
        trust_manager.contact_sessions_reset.connect(reset_relay.on_contact_reset);
    }

    ~LegacyPreKeyRecovery() {
        trust_manager.session_reset.disconnect(reset_relay.on_session_reset);
        trust_manager.contact_sessions_reset.disconnect(reset_relay.on_contact_reset);
    }

    internal static bool allows_message(Entities.Message message,
            MessageStanza stanza, Conversation conversation,
            LegacyInvalidPreKey failure) {
        if (message.account != conversation.account ||
                message.direction != Entities.Message.DIRECTION_RECEIVED ||
                stanza.from == null ||
                failure.jid.equals_bare(message.account.bare_jid) ||
                MessageArchiveManagement.MessageFlag.get_flag(stanza) != null ||
                stanza.stanza.get_subnode("delay", Xep.DelayedDelivery.NS_URI) != null ||
                Xep.DelayedDelivery.MessageFlag.get_flag(stanza) != null ||
                stanza.stanza.get_subnode("encrypted", NS_URI) == null ||
                stanza.stanza.get_subnode("encrypted", NS_URI).get_subnode("payload", NS_URI) == null) return false;
        if (conversation.type_ == Conversation.Type.CHAT) {
            return message.type_ == Entities.Message.Type.CHAT &&
                stanza.type_ == MessageStanza.TYPE_CHAT &&
                stanza.from.equals_bare(failure.jid);
        }
        // This only checks the envelope. consider() additionally binds the
        // live occupant to server-disclosed private-room identity evidence.
        return conversation.type_ == Conversation.Type.GROUPCHAT &&
            message.type_ == Entities.Message.Type.GROUPCHAT &&
            stanza.type_ == MessageStanza.TYPE_GROUPCHAT &&
            stanza.from.is_full() &&
            stanza.from.equals_bare(conversation.counterpart) &&
            message.from != null && message.from.equals(stanza.from);
    }

    private MucContext? capture_muc_context(Entities.Message message,
            MessageStanza stanza, Conversation conversation,
            LegacyInvalidPreKey failure) {
        MucManager? manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (manager == null) return null;
        Jid? participant = manager.get_verified_private_muc_participant(
                account, conversation.counterpart, (!) stanza.from);
        if (participant == null || !participant.equals_bare(failure.jid) ||
                !manager.current_occupant_matches_message_identity(account,
                    conversation.counterpart, (!) stanza.from, message)) return null;
        MucManager.MucOwnerMutationContext? context =
                manager.capture_current_muc_context(account, conversation.counterpart);
        if (context == null) return null;
        return new MucContext(manager, (!) context, (!) stanza.from,
                manager.get_room_real_jid_visibility_generation(account,
                    conversation.counterpart), message);
    }

    private bool is_current_muc_context(MucContext? muc,
            LegacyInvalidPreKey failure) {
        if (muc == null) return true; // Existing direct-chat authorization.
        MucManager manager = ((!) muc).manager;
        Jid room = ((!) muc).context.room;
        if (!manager.is_current_muc_context(account, ((!) muc).context) ||
                manager.get_room_real_jid_visibility_generation(account, room) !=
                    ((!) muc).visibility_generation ||
                !manager.current_occupant_matches_message_identity(account,
                    room, ((!) muc).occupant, ((!) muc).message_identity)) return false;
        Jid? participant = manager.get_verified_private_muc_participant(
                account, room, ((!) muc).occupant);
        return participant != null && participant.equals_bare(failure.jid);
    }

    internal void authenticated_from(Jid jid, int device_id) {
        string? base_key = null;
        var address = new Address(jid.bare_jid.to_string(), device_id);
        try {
            if (store.is_persistence_ready && !store.registration_pending) {
                base_key = Base64.encode(store.load_session(address).state.alice_base_key.serialize());
            }
        } catch (Error e) {
            debug("OMEMO v1 recovery confirmation unavailable: %s", e.message);
        }
        address.device_id = 0;
        limiter.authenticated_from(jid, device_id, base_key);
    }

    private bool allows_device(LegacyInvalidPreKey failure, int identity_id)
            throws Error {
        if (failure.device_id <= 0 || identity_id <= 0) return false;
        Row? device = db.identity_meta.get_device_checked(identity_id,
                failure.jid.to_string(), failure.device_id);
        if (device == null) return false;
        TrustLevel trust = (TrustLevel) device[db.identity_meta.trust_level];
        return (trust == TrustLevel.TRUSTED || trust == TrustLevel.VERIFIED) &&
            device[db.identity_meta.now_active] &&
            device[db.identity_meta.supports_omemo1] &&
            !device[db.identity_meta.identity_key_changed] &&
            device[db.identity_meta.identity_key_public_base64] == failure.identity_key &&
            trust_manager.get_trusted_devices_omemo1(account, failure.jid)
                .contains(failure.device_id);
    }

    private bool matches_persisted_own_identity(int identity_id,
            uint32 registration_id, string local_identity) throws Error {
        BackedSessionStore? sessions = store.session_store as BackedSessionStore;
        if (sessions == null || !((!) sessions).belongs_to(db, identity_id)) return false;
        Row? own = db.identity.select().with(db.identity.account_id, "=", account.id)
            .single().iterator().get_next_checked();
        return own != null && ((!) own)[db.identity.id] == identity_id &&
            ((!) own)[db.identity.device_id] == registration_id &&
            !((!) own)[db.identity.registration_pending] &&
            ((!) own)[db.identity.identity_key_public_base64] == local_identity &&
            ((!) own)[db.identity.identity_key_private_base64] ==
                Base64.encode(store.identity_key_store.identity_key_private.get_data());
    }

    internal void consider(Entities.Message message, MessageStanza stanza,
            Conversation conversation, LegacyInvalidPreKey failure) {
        if (message.account != account || conversation.account != account ||
                store.registration_pending ||
                !allows_message(message, stanza, conversation, failure)) return;
        MucContext? muc = null;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            muc = capture_muc_context(message, stanza, conversation, failure);
            if (muc == null) return;
        }
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;
        StreamModule? module = stream.get_module<StreamModule>(StreamModule.IDENTITY);
        if (module == null || module.store != store ||
                !module.is_attached_stream(stream)) return;
        try {
            store.require_persistence_ready();
            int identity_id = db.identity.get_id_checked(account.id);
            if (!allows_device(failure, identity_id)) return;
            uint32 registration_id = store.local_registration_id;
            string local_identity = Base64.encode(store.identity_key_store.identity_key_public.get_data());
            if (!matches_persisted_own_identity(identity_id, registration_id, local_identity)) return;
            // Only an authoritative cryptographic scope change retires the
            // old confirmation guard. Context changes and archive promotion
            // alone must never enable repeated session-builder transitions.
            limiter.retire_obsolete_scope(failure, identity_id, registration_id, local_identity);
            LegacyRecoveryAttempt? attempt = limiter.reserve(failure,
                    get_monotonic_time());
            if (attempt == null) return;
            recover.begin((!) attempt, stream, module,
                    module.attachment_generation, identity_id,
                    registration_id, local_identity, muc);
        } catch (Error e) {
            debug("OMEMO v1 recovery unavailable: %s", e.message);
        }
    }

    private bool is_current(LegacyRecoveryAttempt attempt, XmppStream stream,
            StreamModule module, uint generation, int identity_id,
            uint32 registration_id, string local_identity,
            MucContext? muc) throws Error {
        return limiter.is_pending(attempt) && store.is_persistence_ready &&
            !store.registration_pending &&
            stream_interactor.get_stream(account) == stream &&
            module.store == store && module.is_attached_stream(stream) &&
            module.attachment_generation == generation &&
            store.local_registration_id == registration_id &&
            Base64.encode(store.identity_key_store.identity_key_public.get_data()) == local_identity &&
            matches_persisted_own_identity(identity_id, registration_id, local_identity) &&
            is_current_muc_context(muc, attempt.failure) &&
            allows_device(attempt.failure, identity_id) &&
            (attempt.transport == null || matches_transport_scope(
                (!) attempt.transport, attempt.failure, identity_id,
                registration_id, local_identity));
    }

    private bool matches_transport_scope(LegacyRecoveryTransport transport,
            LegacyInvalidPreKey failure, int identity_id,
            uint32 registration_id, string local_identity) throws Error {
        if (!transport.matches_failure(failure) ||
                !transport.scope.matches_own_identity(identity_id,
                    registration_id, local_identity)) return false;
        var address = new Address(failure.jid.to_string(), failure.device_id);
        try {
            if (!store.contains_session(address) ||
                    store.create_session_cipher(address).get_session_version() != 3) return false;
            SessionRecord record = store.load_session(address);
            ECPublicKey base_key = store.context.decode_public_key(
                    Base64.decode(transport.session_base_key));
            // An authenticated delayed receive can promote an old state.
            // Retrying the same wire packet is safe only while its original
            // native state still exists; never rebuild a missing/v4 session.
            return native_has_session_state(record, 3, base_key) == 1;
        } finally {
            address.device_id = 0;
        }
    }

    private async void recover(LegacyRecoveryAttempt attempt,
            XmppStream stream, StreamModule module, uint generation,
            int identity_id, uint32 registration_id, string local_identity,
            MucContext? muc) {
        try {
            if (!is_current(attempt, stream, module, generation,
                    identity_id, registration_id, local_identity, muc)) return;
            MessageModule? message_module = stream.get_module<MessageModule>(MessageModule.IDENTITY);
            if (message_module == null) return;
            if (attempt.transport == null) {
                Bundle? bundle = yield module.request_recovery_bundle(stream,
                        attempt.failure.jid, attempt.failure.device_id);
                if (bundle == null || !is_current(attempt, stream, module,
                        generation, identity_id, registration_id, local_identity, muc)) return;
                LegacyRecoveryTransport transport = build_transport(attempt.failure, (!) bundle);
                limiter.committed(attempt, transport.session_base_key, transport);
            }
            MessageStanza response = ((!) attempt.transport).create_stanza();
            // Keep the ordinary stanza pipeline, then recheck the attachment
            // before writing: a listener can yield while the account disconnects.
            yield message_module.send_pipeline.run(stream, response);
            if (!is_current(attempt, stream, module, generation,
                    identity_id, registration_id, local_identity, muc)) return;
            if (!((!) attempt.transport).matches_stanza(response) ||
                    (response.from != null && !response.from.equals_bare(account.bare_jid))) {
                throw new IOError.INVALID_DATA("Outgoing pipeline changed the committed OMEMO recovery transport");
            }
            // A failed transport does not roll back a committed ratchet.
            // It may have partially written: retry only this same packet,
            // under fresh authorization and the existing cooldown.
            limiter.write_started(attempt, get_monotonic_time());
            yield stream.write_async(response.stanza);
            limiter.delivered(attempt);
        } catch (Error e) {
            debug("OMEMO v1 pre-key recovery stopped: %s", e.message);
        } finally {
            limiter.complete(attempt);
        }
    }

    internal MessageStanza build_response(LegacyInvalidPreKey failure,
            Bundle bundle, out string session_base_key) throws Error {
        LegacyRecoveryTransport transport = build_transport(failure, bundle);
        session_base_key = transport.session_base_key;
        return transport.create_stanza();
    }

    private LegacyRecoveryTransport build_transport(LegacyInvalidPreKey failure,
            Bundle bundle) throws Error {
        store.require_persistence_ready();
        if (store.registration_pending) throw new IOError.PENDING("Own device registration is pending");
        int identity_id = db.identity.get_id_checked(account.id);
        if (!allows_device(failure, identity_id) ||
                !matches_persisted_own_identity(identity_id, store.local_registration_id,
                    Base64.encode(store.identity_key_store.identity_key_public.get_data())) ||
                !StreamModule.is_valid_legacy_bundle(bundle) ||
                Base64.encode(bundle.identity_key.serialize()) != failure.identity_key) {
            throw new IOError.PERMISSION_DENIED("Recovery bundle or device identity is not trusted");
        }
        BackedSessionStore? sessions = store.session_store as BackedSessionStore;
        if (sessions == null || !((!) sessions).belongs_to(db, identity_id)) {
            throw new IOError.FAILED("Recovery requires the account's persistent session store");
        }

        var address = new Address(failure.jid.to_string(), failure.device_id);
        if (store.contains_session(address) &&
                store.create_session_cipher(address).get_session_version() != 3) {
            throw new IOError.NOT_SUPPORTED("Recovery cannot replace another OMEMO protocol session");
        }
        uint8[]? previous_session = store.session_store.load_session(address);
        uint8[]? previous_identity = store.identity_key_store.load_identity(address);
        string savepoint = "omemo_v1_recovery_" + Uuid.string_random().replace("-", "");
        bool active = false;
        uint8[] keytag = new uint8[32];
        try {
            db.exec("SAVEPOINT " + savepoint);
            active = true;
            Bundle.PreKey prekey = bundle.pre_keys[Random.int_range(0, bundle.pre_keys.size)];
            SessionBuilder builder = store.create_session_builder(address);
            // libomemo-c archives the existing v3 receive state here; deleting
            // the session first would discard delayed-message decryption keys.
            builder.process_pre_key_bundle(create_pre_key_bundle(
                    failure.device_id, failure.device_id, prekey.key_id,
                    prekey.key, bundle.signed_pre_key_id, bundle.signed_pre_key,
                    bundle.signed_pre_key_signature, bundle.identity_key));

            uint8[] key = new uint8[16];
            uint8[] iv = new uint8[12];
            store.context.randomize(key);
            store.context.randomize(iv);
            uint8[] tag;
            try {
                tag = aes_encrypt(Cipher.AES_GCM_NOPADDING, key, iv, new uint8[0]);
                if (tag.length != 16) throw new IOError.FAILED("Unexpected empty-payload authentication tag");
                Memory.copy(keytag, key, 16);
                Memory.copy((uint8*) keytag + 16, tag, 16);
            } finally {
                Memory.set(key, 0, key.length);
            }
            SessionCipher cipher = store.create_session_cipher(address);
            CiphertextMessage encrypted_key = cipher.encrypt(keytag);
            if (encrypted_key.type != CiphertextType.PREKEY) {
                throw new IOError.FAILED("Recovery must start with a fresh PREKEY message");
            }
            var data = new Xep.Omemo.EncryptionData(store.local_registration_id);
            data.iv = iv;
            data.add_device_key(failure.device_id, encrypted_key.serialized, true);
            var response = new MessageStanza();
            response.to = failure.jid;
            response.type_ = MessageStanza.TYPE_CHAT;
            response.stanza.put_node(data.get_encrypted_node());
            response.stanza.put_node(new StanzaNode.build("store", "urn:xmpp:hints").add_self_xmlns());
            string session_base_key = Base64.encode(store.load_session(address).state.alice_base_key.serialize());
            // Capture and validate the immutable packet inside the same
            // savepoint as its native state. Snapshot failure must not commit
            // a ratchet whose recovery packet cannot be retained.
            var transport = new LegacyRecoveryTransport(failure, response,
                    session_base_key, identity_id, store.local_registration_id,
                    Base64.encode(store.identity_key_store.identity_key_public.get_data()));
            db.exec("RELEASE SAVEPOINT " + savepoint);
            active = false;
            return transport;
        } catch (Error e) {
            if (active) {
                bool restored = true;
                try {
                    db.exec("ROLLBACK TO SAVEPOINT " + savepoint);
                    db.exec("RELEASE SAVEPOINT " + savepoint);
                } catch (Error rollback_error) {
                    restored = false;
                }
                try {
                    sessions.restore_memory_only(address, previous_session);
                    if (previous_identity == null) store.identity_key_store.delete_identity(address);
                    else store.identity_key_store.save_identity(address, (!) previous_identity);
                } catch (Error restore_error) {
                    restored = false;
                }
                if (!restored) store.mark_persistence_unavailable();
            }
            throw e;
        } finally {
            Memory.set(keytag, 0, keytag.length);
            // Native builders/ciphers borrow Address rather than retaining it.
            address.device_id = 0;
        }
    }
}

}
