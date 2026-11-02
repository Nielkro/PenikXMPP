using Dino.Entities;
using Qlite;
using Gee;
using Omemo;
using Xmpp;

namespace Dino.Plugins.Omemo {

    public class OmemoDecryptor : Xep.Omemo.OmemoDecryptor {

        public signal void device_trust_state_changed(Account account, Jid jid);

        private const string PREKEY_SAVEPOINT_PREFIX =
                "omemo_v1_prekey_decrypt_";

        private Account account;
        private Store store;
        private Database db;
        private StreamInteractor stream_interactor;
        private TrustManager trust_manager;
        private LegacyPreKeyRecovery prekey_recovery;
        private LegacyInvalidPreKey? last_invalid_prekey;
        internal int last_failure_code { get; private set; default = 0; }
        internal string last_failure_kind { get; private set; default = "none"; }
        internal string last_failure_detail { get; private set; default = "none"; }
        public override uint32 own_device_id { get { return store.local_registration_id; }}
        internal bool store_ready { get { return store.is_persistence_ready && own_device_id != 0; } }

        public OmemoDecryptor(Account account, StreamInteractor stream_interactor, TrustManager trust_manager, Database db, Store store) {
            this.account = account;
            this.stream_interactor = stream_interactor;
            this.trust_manager = trust_manager;
            this.db = db;
            this.store = store;
            prekey_recovery = new LegacyPreKeyRecovery(account,
                    stream_interactor, trust_manager, db, store);
        }

        internal static bool should_hide_failed_own_mam_copy(
                bool message_direction, bool is_mam_replay,
                bool sender_device_is_ours, bool has_key_for_our_device) {
            return message_direction == Entities.Message.DIRECTION_SENT &&
                    is_mam_replay && sender_device_is_ours &&
                    !has_key_for_our_device;
        }

        internal static bool should_process_legacy_prekey_message(
                bool is_mam_replay, bool is_prekey, bool identity_matches) {
            if (!is_prekey) return true;
            // A changed sender identity must never replace a session merely
            // because a PREKEY arrived, regardless of whether it is live or
            // replayed from MAM. Bundle confirmation/manual reset owns that
            // transition.
            return identity_matches;
        }

        internal static bool should_process_omemo2_prekey_message(
                bool is_mam_replay, bool is_prekey,
                bool has_incompatible_session, bool identity_matches) {
            if (!is_prekey) return true;
            return !has_incompatible_session && identity_matches;
        }

        public bool decrypt_message(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            last_failure_code = 0;
            last_failure_kind = "none";
            last_failure_detail = "none";
            StanzaNode? encrypted_node = stanza.stanza.get_subnode("encrypted", NS_URI);
            if (encrypted_node == null || MessageFlag.get_flag(stanza) != null || stanza.from == null) return false;

            if (message.account.id != account.id || conversation.account.id != account.id ||
                    message.account != account || conversation.account != account) return false;
            if (!store_ready) {
                last_failure_kind = "store-unavailable";
                last_failure_detail = "stage=store-readiness";
                return false;
            }
            if (!Plugin.ensure_context()) {
                last_failure_kind = "context-unavailable";
                last_failure_detail = "stage=context-init";
                return false;
            }
            AccountKeyScope source_identity;
            try {
                source_identity = new AccountKeyScope(account, db);
                if (source_identity.device_id != (int) own_device_id ||
                        source_identity.key_base64 != Base64.encode(store.identity_key_pair.public.serialize()) ||
                        !backing_session_matches(store, db, source_identity.identity_id)) return false;
            } catch (Error error) { return false; }
            int identity_id = source_identity.identity_id;
            bool is_mam_replay =
                    Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza) != null;

            MessageFlag flag = new MessageFlag();
            stanza.add_flag(flag);

            Xep.Omemo.ParsedData? data = parse_node(encrypted_node);
            if (data == null) {
                last_failure_kind = "invalid-envelope";
                last_failure_detail = "stage=envelope-parse";
                return false;
            }
            if (data.our_potential_encrypted_keys.size == 0) {
                last_failure_kind = "recipient-key-missing";
                last_failure_detail = "stage=recipient-selection";
            }
            LegacyInvalidPreKey? recovery_candidate = null;

            foreach (Bytes encr_key in data.our_potential_encrypted_keys.keys) {
                data.is_prekey = data.our_potential_encrypted_keys[encr_key];
                data.encrypted_key = encr_key.get_data();
                Gee.List<Jid> possible_jids = get_potential_message_jids(message, data, identity_id);
                if (possible_jids.size == 0) {
                    debug("Received message from unknown entity with device id %d", data.sid);
                }

                foreach (Jid possible_jid in possible_jids) {
                    last_failure_detail = "none";
                    if (data.is_prekey) {
                        bool identity_matches = false;
                        try {
                            identity_matches =
                                    prekey_sender_identity_matches_known_device(
                                        data, possible_jid);
                        } catch (Error e) {
                            debug("Archived pre-key message from %s/%d could not be inspected safely: %s",
                                    possible_jid.to_string(), data.sid, e.message);
                        }
                        if (!should_process_legacy_prekey_message(
                                is_mam_replay, true, identity_matches)) {
                            last_failure_code = ErrorCode.UNTRUSTED_IDENTITY;
                            last_failure_kind = "prekey-identity-mismatch";
                            debug("OMEMO v1 PREKEY rejected (reason=identity-mismatch, mam=%s, sid=%d, stanza_id=%s); preserving the current device identity and session",
                                    is_mam_replay.to_string(), data.sid,
                                    message.stanza_id ?? "-");
                            continue;
                        }
                    }

                    try {
                        uint8[] key = decrypt_key(data, possible_jid);
                        string authenticated_key = authenticated_session_key(store, possible_jid, data.sid);
                        if (data.ciphertext != null) {
                            string cleartext = arr_to_str(aes_decrypt(Cipher.AES_GCM_NOPADDING, key, data.iv, data.ciphertext));
                            message.body = cleartext;
                        } else {
                            // XEP-0384 key transports have no chat payload.
                            // Their outer body is not authenticated content.
                            message.body = null;
                        }

                        // If we figured out which real jid a message comes from due to decryption working, save it
                        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                            bool retain_sender = stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                                .may_retain_authenticated_message_real_jid(account, conversation.counterpart);
                            if (!retain_sender) message.real_jid = null;
                            else if (message.real_jid == null) message.real_jid = possible_jid;
                        }

                        message.encryption = Encryption.OMEMO;
                        message.decryption_failed = false;

                        trust_manager.remember_message_device(message, data.sid, authenticated_key, possible_jid);

                        // Update last_active for this device (actual message, not just PubSub presence)
                        if (identity_id >= 0) {
                            db.identity_meta.update_last_active(identity_id, possible_jid.bare_jid.to_string(), data.sid);
                        }

                        prekey_recovery.authenticated_from(possible_jid, data.sid);

                        return true;
                    } catch (Error e) {
                        if (last_invalid_prekey != null) recovery_candidate = last_invalid_prekey;
                        // Preserve ratchet state after a decryption failure.
                        // The narrow invalid-PREKEY response below archives the
                        // old state; arbitrary failures must never delete it.
                        last_failure_code = e.code;
                        last_failure_kind = data.is_prekey ? "prekey" : "signal";
                        debug("Decrypting OMEMO v1 message from %s/%d failed (mam=%s, kind=%s, stanza_id=%s, error_code=%d); preserving session: %s",
                                possible_jid.to_string(), data.sid,
                                is_mam_replay.to_string(), last_failure_kind,
                                message.stanza_id ?? "-", e.code, e.message);
                    }
                }
            }

            // Only consider recovery after every recipient-key candidate has
            // failed; a later valid candidate must suppress the response.
            if (recovery_candidate != null) {
                prekey_recovery.consider(message, stanza, conversation,
                        (!) recovery_candidate);
            }

            if (
                data.ciphertext != null && // Ratchet forwarding doesn't contain payload and might not include us, which is ok
                data.our_potential_encrypted_keys.size == 0 && // The message was not encrypted to us
                stream_interactor.module_manager.get_module<StreamModule>(message.account, StreamModule.IDENTITY).store.local_registration_id != data.sid // Message from this device. Never encrypted to itself.
            ) {
                // Don't mark messages as undecryptable if they are older than conversation history clear
                bool should_mark_undecryptable = true;
                if (conversation.history_cleared_at != null && message.time != null) {
                    if (message.time.compare(conversation.history_cleared_at) < 0) {
                        // Message is older than clear timestamp - don't mark as undecryptable
                        should_mark_undecryptable = false;
                    }
                }
                
                if (should_mark_undecryptable) {
                    Jid report_jid = message.real_jid != null ? (!) message.real_jid : message.from;
                    db.identity_meta.update_last_message_undecryptable(identity_id, report_jid.bare_jid.to_string(), data.sid, message.time);
                    trust_manager.bad_message_state_updated(conversation.account, report_jid, data.sid);
                }
            }

            debug("Received OMEMO encryped message that could not be decrypted.");
            return false;
        }

        internal void inspect_archive_copy(
                StanzaNode encrypted_node, out bool sender_device_is_ours,
                out bool has_key_for_our_device,
                out bool has_prekey_for_our_device,
                out int sender_device_id) {
            sender_device_is_ours = false;
            has_key_for_our_device = false;
            has_prekey_for_our_device = false;
            sender_device_id = -1;
            Xep.Omemo.ParsedData? data = parse_node(encrypted_node);
            if (data == null) return;
            sender_device_id = ((!) data).sid;
            sender_device_is_ours =
                    ((!) data).sid == store.local_registration_id;
            has_key_for_our_device =
                    ((!) data).our_potential_encrypted_keys.size > 0;
            foreach (bool is_prekey in
                    ((!) data).our_potential_encrypted_keys.values) {
                if (is_prekey) {
                    has_prekey_for_our_device = true;
                    break;
                }
            }
        }

        public Gee.List<Jid> get_potential_message_jids(Entities.Message message, Xmpp.Xep.Omemo.ParsedData data, int identity_id) {
            Gee.List<Jid> possible_jids = new ArrayList<Jid>();
            if (message.type_ == Message.Type.CHAT) {
                possible_jids.add(message.from.bare_jid);
            } else {
                if (message.real_jid != null) {
                    possible_jids.add(message.real_jid.bare_jid);
                } else if (data.is_prekey) {
                    // pre key messages do store the identity key, so we can use that to find the real jid
                    try {
                        PreKeyOmemoMessage msg = Plugin.get_context().deserialize_signal_pre_key_message(data.encrypted_key);
                        string identity_key = Base64.encode(msg.identity_key.serialize());
                        foreach (Row row in db.identity_meta.get_with_device_id(identity_id, data.sid).with(db.identity_meta.identity_key_public_base64, "=", identity_key)) {
                            try {
                                possible_jids.add(new Jid(row[db.identity_meta.address_name]));
                            } catch (InvalidJidError e) {
                                warning("Ignoring invalid jid from database: %s", e.message);
                            }
                        }
                    } catch (Error e) {
                        warning("Failed to deserialize pre-key message: %s", e.message);
                    }
                } else {
                    // If we don't know the device name (MUC history w/o MAM), test decryption with all keys with fitting device id
                    foreach (Row row in db.identity_meta.get_with_device_id(identity_id, data.sid)) {
                        try {
                            possible_jids.add(new Jid(row[db.identity_meta.address_name]));
                        } catch (InvalidJidError e) {
                            warning("Ignoring invalid jid from database: %s", e.message);
                        }
                    }
                }
            }
            return possible_jids;
        }

        public override uint8[] decrypt_key(Xmpp.Xep.Omemo.ParsedData data, Jid from_jid) throws GLib.Error {
            last_invalid_prekey = null;
            last_failure_detail = "none";
            store.require_persistence_ready();
            int sid = data.sid;
            uint8[] ciphertext = data.ciphertext;
            uint8[] encrypted_key = data.encrypted_key;

            Address address = new Address(from_jid.to_string(), sid);
            uint8[] key;

            if (data.is_prekey) {
                int identity_id = db.identity.get_id_checked(account.id);
                if (identity_id <= 0) {
                    throw new GLib.Error(
                        Quark.from_string("omemo-identity-store"),
                        ErrorCode.UNKNOWN,
                        "Persistent OMEMO account identity is unavailable");
                }
                PreKeyOmemoMessage msg = Plugin.get_context().deserialize_signal_pre_key_message(encrypted_key);
                string identity_key = Base64.encode(msg.identity_key.serialize());
                ensure_prekey_identity_is_unchanged(identity_id, identity_key,
                        from_jid, sid);

                uint8[]? previous_session = store.session_store.load_session(address);
                bool has_pre_key_id = msg.has_pre_key_id();
                uint32 pre_key_id = has_pre_key_id ? msg.pre_key_id : 0;
                uint8[]? previous_pre_key = has_pre_key_id
                    ? store.pre_key_store.load_pre_key(pre_key_id) : null;
                uint8[]? previous_identity = store.identity_key_store.load_identity(address);

                string savepoint_name = PREKEY_SAVEPOINT_PREFIX +
                        Uuid.string_random().replace("-", "");
                bool savepoint_active = false;
                bool native_invalid_prekey = false;
                bool consumed_pre_key = false;
                bool device_metadata_changed = false;
                var trace = new PreKeyDecryptTrace();
                try {
                    // libomemo-c persists the new session and consumes the
                    // one-time pre-key through separate callbacks. Keep those
                    // writes and the authenticated device metadata in one
                    // durable unit so a process exit cannot expose a partial
                    // PREKEY transition.
                    db.exec("SAVEPOINT " + savepoint_name);
                    savepoint_active = true;
                    debug("Starting new session for decryption with device from %s/%d", from_jid.to_string(), sid);
                    try {
                        key = store.context.decrypt_pre_key_message(store,
                                address, msg, trace);
                    } catch (Error native_error) {
                        last_failure_detail = trace.describe();
                        native_invalid_prekey = native_error.code == ErrorCode.INVALID_KEY_ID;
                        throw native_error;
                    }
                    // Only an authenticated PREKEY may create/update device
                    // metadata. The native callbacks have already persisted
                    // the matching ratchet and consumed one-time pre-key.
                    device_metadata_changed = persist_authenticated_prekey_device(identity_id,
                            identity_key, from_jid, sid);
                    consumed_pre_key = has_pre_key_id &&
                            previous_pre_key != null &&
                            !store.pre_key_store.contains_pre_key(pre_key_id);
                    db.exec("RELEASE SAVEPOINT " + savepoint_name);
                    savepoint_active = false;
                } catch (Error e) {
                    if (savepoint_active) {
                        if (!rollback_prekey_savepoint(savepoint_name, e)) {
                            store.mark_persistence_unavailable();
                        }
                        restore_prekey_memory(address, pre_key_id,
                                previous_session, previous_pre_key,
                                previous_identity, e, has_pre_key_id);
                    }
                    if (native_invalid_prekey && store.is_persistence_ready) {
                        last_invalid_prekey = new LegacyInvalidPreKey(from_jid,
                                sid, identity_key, encrypted_key);
                    }
                    throw e;
                }
                if (device_metadata_changed) {
                    device_trust_state_changed(account, from_jid.bare_jid);
                }
                // A raw pre_key_deleted signal fires before SQL commit and
                // can be followed by rollback. Reconcile only durable native
                // consumption; matching sessions/optional-key packets do not.
                if (consumed_pre_key) {
                    XmppStream? stream = stream_interactor.get_stream(account);
                    StreamModule? module = stream != null
                        ? ((!) stream).get_module<StreamModule>(StreamModule.IDENTITY) : null;
                    if (module != null && ((!) module).store == store) {
                        ((!) module).on_legacy_pre_key_consumed((!) stream);
                    }
                }
            } else {
                debug("Continuing session for decryption with device from %s/%d", from_jid.to_string(), sid);
                var trace = new SignalDecryptTrace();
                try {
                    key = store.context.decrypt_signal_message(store, address, encrypted_key, trace);
                } catch (Error e) {
                    last_failure_detail = trace.describe();
                    throw e;
                }
            }

            if (key.length == 32) {
                // Standard OMEMO: 16-byte AES key + 16-byte GCM auth tag
                uint8[] new_key = new uint8[16];
                if (data.ciphertext != null) {
                    uint8[] new_ciphertext = new uint8[ciphertext.length + 16];
                    Memory.copy(new_ciphertext, ciphertext, ciphertext.length);
                    Memory.copy((uint8*)new_ciphertext + ciphertext.length, (uint8*)key + 16, 16);
                    data.ciphertext = new_ciphertext;
                }
                Memory.copy(new_key, key, 16);
                key = new_key;
            } else if (key.length != 16) {
                throw new GLib.Error(-1, 0, "Unexpected OMEMO key length: %d (expected 16 or 32)", key.length);
            }

            return key;
        }

        // Native decryption promotes the successfully decrypted state, including
        // archived states, to record.state. Capture that authenticated identity
        // before any asynchronous work or later device metadata replacement.
        internal static bool backing_session_matches(Store store, Database db, int identity_id) {
            // In-memory native stores are used by isolated library fixtures;
            // persistent stores must belong to this exact account database.
            BackedSessionStore? backing = store.session_store as BackedSessionStore;
            return backing == null || ((!) backing).belongs_to(db, identity_id);
        }

        internal static string authenticated_session_key(Store store, Jid peer,
                int device_id, int version = 3) throws Error {
            Address address = new Address(peer.bare_jid.to_string(), device_id);
            SessionRecord record;
            throw_by_code(Protocol.Session.load_session(store.native_context,
                out record, address, version));
            ECPublicKey? key = record.state.remote_identity_key;
            if (key == null) throw new IOError.INVALID_DATA("Authenticated OMEMO identity is unavailable");
            return Base64.encode(((!) key).serialize());
        }

        public bool prekey_sender_identity_matches_known_device(Xmpp.Xep.Omemo.ParsedData data, Jid from_jid) throws GLib.Error {
            if (!data.is_prekey) return true;

            int identity_id = db.identity.get_id_checked(account.id);
            if (identity_id <= 0) {
                throw new GLib.Error(
                    Quark.from_string("omemo-identity-store"),
                    ErrorCode.UNKNOWN,
                    "Persistent OMEMO account identity is unavailable");
            }

            PreKeyOmemoMessage msg = Plugin.get_context().deserialize_signal_pre_key_message(data.encrypted_key);
            string identity_key = Base64.encode(msg.identity_key.serialize());
            Row? device = get_prekey_device(identity_id, from_jid, data.sid);
            if (device == null || ((!) device)[db.identity_meta.identity_key_public_base64] == null) return true;

            return ((!) device)[db.identity_meta.identity_key_public_base64] == identity_key;
        }

        public override string decrypt(uint8[] ciphertext, uint8[] key, uint8[] iv) throws GLib.Error {
            return arr_to_str(aes_decrypt(Cipher.AES_GCM_NOPADDING, key, iv, ciphertext));
        }

        private Row? get_prekey_device(int identity_id, Jid from_jid, int sid)
                throws Error {
            string address_name = from_jid.bare_jid.to_string();
            string legacy_address_name = from_jid.to_string();
            Row? device = db.identity_meta.get_device_checked(
                    identity_id, address_name, sid);
            if (device == null && legacy_address_name != address_name) {
                device = db.identity_meta.get_device_checked(
                        identity_id, legacy_address_name, sid);
            }
            return device;
        }

        private void ensure_prekey_identity_is_unchanged(int identity_id,
                string identity_key, Jid from_jid, int sid) throws Error {
            Row? device = get_prekey_device(identity_id, from_jid, sid);
            if (device != null &&
                    ((!) device)[db.identity_meta.identity_key_public_base64] != null &&
                    ((!) device)[db.identity_meta.identity_key_public_base64] != identity_key) {
                throw new GLib.Error(
                    Quark.from_string("omemo-prekey-identity"),
                    ErrorCode.UNTRUSTED_IDENTITY,
                    "PREKEY identity differs from the persisted device identity");
            }
        }

        private bool persist_authenticated_prekey_device(int identity_id,
                string identity_key, Jid from_jid, int sid) throws Error {
            string address_name = from_jid.bare_jid.to_string();
            string legacy_address_name = from_jid.to_string();
            Row? device = get_prekey_device(identity_id, from_jid, sid);
            bool metadata_changed = device == null ||
                ((!) device)[db.identity_meta.identity_key_public_base64] == null ||
                ((!) device)[db.identity_meta.address_name] != address_name;
            if (device != null && device[db.identity_meta.identity_key_public_base64] != null) {
                if (legacy_address_name != address_name) {
                    db.identity_meta.insert_device_session_checked(identity_id,
                            address_name, sid, identity_key,
                            (TrustLevel) device[db.identity_meta.trust_level]);
                }
            } else {
                debug("Learn new device from incoming message from %s/%d", address_name, sid);
                bool blind_trust = db.trust.get_blind_trust_checked(
                        identity_id, address_name, true);
                db.identity_meta.insert_device_session_checked(identity_id,
                        address_name, sid, identity_key,
                        blind_trust ? TrustLevel.TRUSTED : TrustLevel.UNKNOWN);
            }
            
            // Always update device list when receiving prekey message, even for known devices
            // This fixes decryption issues in old chats where sessions have expired
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                stream.get_module<StreamModule>(StreamModule.IDENTITY).request_user_devicelist.begin(stream, from_jid);
            }
            return metadata_changed;
        }

        private void restore_prekey_memory(Address address, uint32 pre_key_id,
                uint8[]? previous_session, uint8[]? previous_pre_key,
                uint8[]? previous_identity, Error original_error,
                bool has_pre_key_id = true) {
            bool restore_failed = false;
            string failure_details = "";
            BackedSessionStore? session_store =
                    store.session_store as BackedSessionStore;
            BackedPreKeyStore? pre_key_store =
                    store.pre_key_store as BackedPreKeyStore;

            if (session_store == null) {
                restore_failed = true;
                failure_details += " session-store-not-backed";
            } else {
                try {
                    ((!) session_store).restore_memory_only(address,
                            previous_session);
                } catch (Error e) {
                    restore_failed = true;
                    failure_details += " session: " + e.message;
                }
            }
            if (!has_pre_key_id) {
                // This valid Signal envelope did not reference a one-time key.
            } else if (pre_key_store == null) {
                restore_failed = true;
                failure_details += " pre-key-store-not-backed";
            } else {
                try {
                    ((!) pre_key_store).restore_memory_only(pre_key_id,
                            previous_pre_key);
                } catch (Error e) {
                    restore_failed = true;
                    failure_details += " pre-key: " + e.message;
                }
            }
            try {
                if (previous_identity == null) {
                    store.identity_key_store.delete_identity(address);
                } else {
                    store.identity_key_store.save_identity(address,
                            (!) previous_identity);
                }
            } catch (Error e) {
                restore_failed = true;
                failure_details += " identity: " + e.message;
            }

            if (restore_failed) {
                store.mark_persistence_unavailable();
                critical("OMEMO PREKEY memory rollback failed after '%s': %s; disabling the account store",
                        original_error.message, failure_details.strip());
            }
        }

        private bool rollback_prekey_savepoint(string savepoint_name,
                Error original_error) {
            try {
                db.exec("ROLLBACK TO SAVEPOINT " + savepoint_name);
                db.exec("RELEASE SAVEPOINT " + savepoint_name);
                return true;
            } catch (Error rollback_error) {
                critical("OMEMO PREKEY database rollback failed after '%s': %s; disabling the account store",
                        original_error.message, rollback_error.message);
                return false;
            }
        }

        internal static string arr_to_str(uint8[] arr) {
            // null-terminate the array
            uint8[] rarr = new uint8[arr.length+1];
            Memory.copy(rarr, arr, arr.length);
            return (string)rarr;
        }
    }

    public class DecryptMessageListener : MessageListener {
        private const string UNDECRYPTABLE_BODY = "[This OMEMO message could not be decrypted]";

        public string[] after_actions_const = new string[]{ };
        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private HashMap<Account, OmemoDecryptor> decryptors;

        public DecryptMessageListener(HashMap<Account, OmemoDecryptor> decryptors) {
            this.decryptors = decryptors;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            StanzaNode? encrypted_node = stanza.stanza.get_subnode("encrypted", Omemo.NS_URI);
            bool had_payload = encrypted_node != null && ((!) encrypted_node).get_deep_string_content("payload") != null;
            bool is_mam_replay =
                    Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza) != null;
            OmemoDecryptor decryptor = decryptors[message.account];
            bool decrypted = decryptor.decrypt_message(message, stanza, conversation);

            // Replace the fallback body so failed OMEMO payload messages stay
            // visible, while ratchet-only messages without payload remain hidden.
            if (encrypted_node != null && !decrypted) {
                message.encryption = Encryption.OMEMO;
                bool sender_device_is_ours;
                bool has_key_for_our_device;
                bool has_prekey_for_our_device;
                int sender_device_id;
                decryptor.inspect_archive_copy((!) encrypted_node,
                        out sender_device_is_ours,
                        out has_key_for_our_device,
                        out has_prekey_for_our_device,
                        out sender_device_id);
                if (OmemoDecryptor.should_hide_failed_own_mam_copy(
                        message.direction, is_mam_replay,
                        sender_device_is_ours, has_key_for_our_device)) {
                    debug("Ignoring undecryptable own OMEMO archive copy (stanza_id=%s)",
                            message.stanza_id ?? "-");
                    message.body = null;
                    message.decryption_failed = had_payload;
                } else if (had_payload) {
                    warning("OMEMO v1 payload message could not be decrypted (from=%s, stanza_id=%s, mam=%s, sid=%d, kind=%s, error_code=%d, own_device_id=%u, store_ready=%s, key_for_own_device=%s, prekey_for_own_device=%s, detail=%s)",
                            message.from != null ? message.from.to_string() : "-",
                            message.stanza_id ?? "-", is_mam_replay.to_string(),
                            sender_device_id, decryptor.last_failure_kind,
                            decryptor.last_failure_code,
                            decryptor.own_device_id,
                            decryptor.store_ready.to_string(),
                            has_key_for_our_device.to_string(),
                            has_prekey_for_our_device.to_string(),
                            decryptor.last_failure_detail);
                    message.body = UNDECRYPTABLE_BODY;
                    message.decryption_failed = true;
                } else {
                    message.body = null;
                }
            }
            return false;
        }
    }
}
