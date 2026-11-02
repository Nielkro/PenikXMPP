using Dino.Entities;
using Qlite;
using Gee;
using Omemo;
using Xmpp;
using Xmpp.Xep.Omemo;
using Xmpp.Xep.Sce;

namespace Dino.Plugins.Omemo {

    /**
     * OMEMO 2 decryptor (XEP-0384 v0.8+).
     *
     * Decryption flow:
     * 1. Find our <key> in <keys jid='our_jid'> group
     * 2. DR_decrypt(encrypted_key) -> mk(32) || auth_tag(16) = 48 bytes
     * 3. HKDF-SHA-256(mk, salt=32_zero_bytes, info="OMEMO Payload") -> 80 bytes:
     *    enc_key[32] | auth_key[32] | iv[16]
     * 4. Verify: HMAC-SHA-256(auth_key, ciphertext)[0:16] == auth_tag
     * 5. plaintext = AES-256-CBC-PKCS7-decrypt(enc_key, iv, ciphertext)
     * 6. Parse SCE envelope -> extract body text
     */
    public class Omemo2Decrypt : Xep.Omemo.Omemo2Decryptor {

        public signal void device_trust_state_changed(Account account, Jid jid);

        private const string PREKEY_SAVEPOINT_PREFIX =
                "omemo_v2_prekey_decrypt_";

        private Account account;
        private Store store;
        private Database db;
        private StreamInteractor stream_interactor;
        private TrustManager trust_manager;
        /* HKDF constants */
        private const int MK_SIZE = 32;
        private const string HKDF_INFO = "OMEMO Payload";
        private const int HKDF_OUTPUT_SIZE = 80;
        private const int HKDF_SALT_SIZE = 32;

        public override uint32 own_device_id { get { return store.local_registration_id; }}

        public Omemo2Decrypt(Account account, StreamInteractor stream_interactor, TrustManager trust_manager, Database db, Store store) {
            this.account = account;
            this.stream_interactor = stream_interactor;
            this.trust_manager = trust_manager;
            this.db = db;
            this.store = store;
        }

        /**
         * Try to decrypt an OMEMO 2 encrypted message.
         */
        public async bool decrypt_message(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            StanzaNode? encrypted_node = stanza.stanza.get_subnode("encrypted", NS_URI_V2);
            if (encrypted_node == null || MessageFlag.get_flag(stanza) != null || stanza.from == null) return false;
            if (message.account != account || conversation.account != account ||
                    message.account.id != account.id || conversation.account.id != account.id ||
                    !store.is_persistence_ready) return false;
            XmppStream? source_stream = stream_interactor.get_stream(account);

            if (!Plugin.ensure_context()) return false;
            AccountKeyScope source_identity;
            try {
                source_identity = new AccountKeyScope(account, db);
                if (source_identity.device_id != (int) own_device_id ||
                        source_identity.key_base64 != Base64.encode(store.identity_key_pair.public.serialize()) ||
                        !OmemoDecryptor.backing_session_matches(store, db, source_identity.identity_id)) return false;
            } catch (Error error) { return false; }
            int identity_id = source_identity.identity_id;
            uint32 source_device_id = own_device_id;
            string source_identity_key = source_identity.key_base64;
            bool is_mam_replay =
                    Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza) != null;

            MessageFlag flag = new MessageFlag();
            stanza.add_flag(flag);

            Jid our_jid = account.bare_jid;
            Omemo2ParsedData? data = parse_node(encrypted_node, our_jid);
            if (data == null) return false;

            foreach (Bytes encr_key in data.our_potential_encrypted_keys.keys) {
                bool is_kex = data.our_potential_encrypted_keys[encr_key];
                uint8[] encrypted_key = encr_key.get_data();

                Gee.List<Jid> possible_jids = get_potential_message_jids(message, encrypted_key, is_kex, data, identity_id);
                if (possible_jids.size == 0) {
                    debug("OMEMO 2: Received message from unknown entity with device id %d", data.sid);
                }

                foreach (Jid possible_jid in possible_jids) {
                    if (is_kex) {
                        Address archive_address =
                                new Address(possible_jid.bare_jid.to_string(), data.sid);
                        bool has_incompatible_session = true;
                        bool identity_matches = false;
                        try {
                            has_incompatible_session = false;
                            if (store.contains_session(archive_address)) {
                                SessionCipher existing_cipher =
                                        store.create_session_cipher(archive_address);
                                has_incompatible_session =
                                        existing_cipher.get_session_version() != 4;
                            }
                            identity_matches =
                                    prekey_sender_identity_matches_known_device(
                                        encrypted_key, true, data.sid,
                                        possible_jid);
                        } catch (Error e) {
                            debug("OMEMO 2: Archived pre-key message from %s/%d could not be inspected safely: %s",
                                    possible_jid.to_string(), data.sid, e.message);
                        }
                        if (!OmemoDecryptor.should_process_omemo2_prekey_message(
                                is_mam_replay, true, has_incompatible_session,
                                identity_matches)) {
                            debug("OMEMO 2: Ignoring pre-key message from %s/%d (mam=%s) to preserve the current device identity and session",
                                    possible_jid.to_string(), data.sid,
                                    is_mam_replay.to_string());
                            continue;
                        }
                    }

                    try {
                        /* Decrypt per-device key -> mk || auth_tag */
                        uint8[] mk_and_tag = decrypt_key_raw(encrypted_key, is_kex, data.sid, possible_jid);
                        string authenticated_key = OmemoDecryptor.authenticated_session_key(
                            store, possible_jid, data.sid, 4);

                        if (data.ciphertext != null) {
                            Xep.Sce.Envelope envelope = yield decrypt_envelope(data.ciphertext, mk_and_tag);
                            if (!store.is_persistence_ready ||
                                    stream_interactor.get_stream(account) != source_stream ||
                                    db.identity.get_id_checked(account.id) != identity_id ||
                                    own_device_id != source_device_id ||
                                    Base64.encode(store.identity_key_pair.public.serialize()) != source_identity_key) return false;
                            var current_identity = new AccountKeyScope(account, db);
                            if (current_identity.identity_id != identity_id ||
                                    current_identity.device_id != (int) source_device_id ||
                                    current_identity.key_base64 != source_identity_key ||
                                    !OmemoDecryptor.backing_session_matches(store, db, identity_id)) return false;
                            validate_envelope_context(envelope, possible_jid,
                                message, conversation);

                            /* Extract body if present */
                            string? body = envelope.get_body();
                            message.body = body;

                            /* Inject all SCE content nodes into stanza for downstream handlers
                             * (e.g. FileProvider for file-sharing, OOB, SFS elements) */
                            foreach (StanzaNode content_node in envelope.content_nodes) {
                                debug("OMEMO 2: SCE content node: <%s xmlns='%s'> subnodes=%d",
                                      content_node.name,
                                      content_node.ns_uri ?? "(null)",
                                      content_node.sub_nodes.size);
                                if (content_node.name != "body") {
                                    stanza.stanza.put_node(content_node);
                                }
                                /* Store BOB (Bits of Binary) data from SCE envelope so that
                                 * thumbnail cid: URIs can be resolved later.  The normal
                                 * BOB pipeline listener ran before OMEMO decryption and
                                 * couldn't see these nodes. */
                                if (content_node.name == "data" && content_node.ns_uri == Xmpp.Xep.BitsOfBinary.NS_URI) {
                                    string? cid = content_node.get_attribute("cid");
                                    string? base64 = content_node.get_string_content();
                                    if (cid != null && base64 != null) {
                                        if (Xmpp.Xep.BitsOfBinary.known_bobs == null) {
                                            Xmpp.Xep.BitsOfBinary.known_bobs = new Gee.HashMap<string, GLib.Bytes>();
                                        }
                                        Xmpp.Xep.BitsOfBinary.known_bobs[cid] = new GLib.Bytes.take(GLib.Base64.decode(base64));
                                        debug("OMEMO 2: Stored BOB data for cid=%s (%d bytes)", cid, (int)Xmpp.Xep.BitsOfBinary.known_bobs[cid].length);
                                    }
                                }
                            }
                        } else {
                            // No authenticated chat content: an outer fallback
                            // body must not be displayed as encrypted text.
                            message.body = null;
                        }

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

                        return true;
                    } catch (Error e) {
                        // Preserve all ratchet state after a decryption failure.
                        // Session replacement is available only through the explicit
                        // manual reset UI; an automatic reset could destroy a valid
                        // session because of one delayed or malformed message.
                        debug("OMEMO 2: Decrypting message from %s/%d failed; preserving session for manual recovery: %s",
                                possible_jid.to_string(), data.sid, e.message);
                    }
                }
            }

            if (data.ciphertext != null &&
                data.our_potential_encrypted_keys.size == 0 &&
                store.local_registration_id != data.sid
            ) {
                bool should_mark_undecryptable = true;
                if (conversation.history_cleared_at != null && message.time != null) {
                    if (message.time.compare(conversation.history_cleared_at) < 0) {
                        should_mark_undecryptable = false;
                    }
                }

                if (should_mark_undecryptable) {
                    Jid report_jid = message.real_jid != null ? (!) message.real_jid : message.from;
                    db.identity_meta.update_last_message_undecryptable(identity_id, report_jid.bare_jid.to_string(), data.sid, message.time);
                    trust_manager.bad_message_state_updated(conversation.account, report_jid, data.sid);
                }
            }

            debug("OMEMO 2: Received encrypted message that could not be decrypted.");
            return false;
        }

        internal void inspect_archive_copy(
                StanzaNode encrypted_node, out bool sender_device_is_ours,
                out bool has_key_for_our_device) {
            sender_device_is_ours = false;
            has_key_for_our_device = false;
            Omemo2ParsedData? data = parse_node(encrypted_node, account.bare_jid);
            if (data == null) return;
            sender_device_is_ours =
                    ((!) data).sid == store.local_registration_id;
            has_key_for_our_device =
                    ((!) data).our_potential_encrypted_keys.size > 0;
        }

        /**
         * Decrypt per-device key using Double Ratchet.
         */
        private uint8[] decrypt_key_raw(uint8[] encrypted_key, bool is_kex, int sid, Jid from_jid) throws GLib.Error {
            store.require_persistence_ready();
            Address address = new Address(from_jid.bare_jid.to_string(), sid);
            uint8[] decrypted;

            if (is_kex) {
                int identity_id = db.identity.get_id_checked(account.id);
                if (identity_id <= 0) {
                    throw new GLib.Error(
                        Quark.from_string("omemo2-identity-store"),
                        ErrorCode.UNKNOWN,
                        "Persistent OMEMO account identity is unavailable");
                }
                /* Use OMEMO 2 deserialization: registration_id from header sid */
                PreKeyOmemoMessage msg = Plugin.get_context().deserialize_omemo_pre_key_message(encrypted_key, (uint32)sid);
                if (!msg.has_pre_key_id()) {
                    throw new IOError.INVALID_DATA("OMEMO 2 key exchange requires a one-time pre-key ID");
                }
                string identity_key = Base64.encode(msg.identity_key.serialize());
                ensure_prekey_state_is_compatible(encrypted_key, identity_id,
                        from_jid, sid, address);

                uint8[]? previous_session = store.session_store.load_session(address);
                uint8[]? previous_pre_key = store.pre_key_store.load_pre_key(msg.pre_key_id);
                uint8[]? previous_identity = store.identity_key_store.load_identity(address);
                string savepoint_name = PREKEY_SAVEPOINT_PREFIX +
                        Uuid.string_random().replace("-", "");
                bool savepoint_active = false;
                bool consumed_pre_key = false;
                bool device_metadata_changed = false;
                try {
                    // The native callbacks update the ratchet and consume the
                    // one-time pre-key separately. The SAVEPOINT makes those
                    // writes atomic with the authenticated application-level
                    // device metadata.
                    db.exec("SAVEPOINT " + savepoint_name);
                    savepoint_active = true;
                    debug("OMEMO 2: Starting new session for decryption with %s/%d", from_jid.to_string(), sid);
                    SessionCipher cipher = store.create_session_cipher(address);
                    cipher.version = 4; // OMEMO 2 requires protocol version 4
                    decrypted = cipher.decrypt_pre_key_message(msg);
                    device_metadata_changed = persist_authenticated_prekey_device(identity_id,
                            identity_key, from_jid, sid);
                    consumed_pre_key = msg.has_pre_key_id() && previous_pre_key != null &&
                        !store.pre_key_store.contains_pre_key(msg.pre_key_id);
                    db.exec("RELEASE SAVEPOINT " + savepoint_name);
                    savepoint_active = false;
                } catch (Error e) {
                    if (savepoint_active) {
                        if (!rollback_prekey_savepoint(savepoint_name, e)) {
                            store.mark_persistence_unavailable();
                        }
                        restore_prekey_memory(address, msg.pre_key_id,
                                previous_session, previous_pre_key,
                                previous_identity, e);
                    }
                    throw e;
                }
                if (device_metadata_changed) {
                    device_trust_state_changed(account, from_jid.bare_jid);
                }
                if (consumed_pre_key) {
                    XmppStream? stream = stream_interactor.get_stream(account);
                    StreamModule2? module = stream != null
                        ? ((!) stream).get_module<StreamModule2>(StreamModule2.IDENTITY) : null;
                    if (module != null && ((!) module).store == store) {
                        ((!) module).on_omemo2_pre_key_consumed((!) stream);
                    }
                }
            } else {
                debug("OMEMO 2: Continuing session for decryption with %s/%d", from_jid.to_string(), sid);
                OmemoMessage msg = Plugin.get_context().deserialize_omemo_message(encrypted_key);
                SessionCipher cipher = store.create_session_cipher(address);
                cipher.version = 4; // OMEMO 2 requires protocol version 4
                decrypted = cipher.decrypt_message(msg);
            }

            address.device_id = 0;
            return decrypted;
        }

        /**
         * Decrypt the OMEMO 2 payload using the message key.
         */
        public override async string decrypt(uint8[] ciphertext, uint8[] message_key) throws GLib.Error {
            Xep.Sce.Envelope envelope = yield decrypt_envelope(ciphertext, message_key);
            string? body = envelope.get_body();
            return body ?? "";
        }

        /**
         * Decrypt payload: verify HMAC, AES-256-CBC decrypt, parse SCE.
         * Returns the full SCE envelope for processing all content nodes.
         */
        private async Xep.Sce.Envelope decrypt_envelope(uint8[] ciphertext, uint8[] mk_and_tag) throws GLib.Error {
            uint8[] plaintext = omemo2_decrypt_payload(ciphertext, mk_and_tag);

            /* Parse SCE envelope */
            Xep.Sce.Envelope? envelope = yield Xep.Sce.Envelope.from_xml(plaintext);
            if (envelope == null) {
                throw new GLib.Error(Quark.from_string("omemo2"), 15, "Failed to parse SCE envelope");
            }

            debug("OMEMO 2: SCE envelope decoded, %d content nodes, body=%s",
                  envelope.content_nodes.size, envelope.get_body() != null ? "yes" : "no");

            return envelope;
        }

        // XEP-0384's SCE profile binds authenticated plaintext to a real
        // sender, a logical destination (room or direct peer), and send time.
        // Room services rewrite outer from/to, so compare its logical room
        // destination and the already authenticated device's real identity.
        internal static void validate_envelope_context(Xep.Sce.Envelope envelope,
                Jid authenticated_sender, Entities.Message message,
                Conversation conversation) throws Error {
            // XEP-0384 §5.5.1: rpad MUST, from SHOULD, time MAY. Validate
            // every supplied affix; absence of optional ones is not an error.
            if (!envelope.has_padding) {
                throw new IOError.INVALID_DATA("OMEMO 2 SCE random padding is required");
            }
            if (envelope.from_jid != null) {
                Jid sender = new Jid((!) envelope.from_jid);
                if (!sender.is_bare() || !sender.equals(authenticated_sender.bare_jid)) {
                    throw new IOError.INVALID_DATA("OMEMO 2 SCE sender does not match the authenticated device");
                }
            }
            bool groupchat = conversation.type_ == Conversation.Type.GROUPCHAT;
            if (groupchat && envelope.to_jid == null) {
                throw new IOError.INVALID_DATA("OMEMO 2 groupchat SCE destination is required");
            }
            if (envelope.to_jid != null) {
                Jid target = new Jid((!) envelope.to_jid);
                Jid expected = groupchat ? conversation.counterpart.bare_jid :
                    (message.direction == Entities.Message.DIRECTION_RECEIVED
                        ? message.account.bare_jid : conversation.counterpart.bare_jid);
                if (!target.is_bare() || !target.equals(expected)) {
                    throw new IOError.INVALID_DATA("OMEMO 2 SCE destination does not match this conversation");
                }
            }
            message.encryption_time_mismatch = false;
            if (envelope.timestamp != null) {
                // Delivery/MAM time can differ because of clock skew or delayed
                // delivery. XEP-0420 requires alerting the user about a material
                // difference, not silently discarding authenticated content.
                if (message.time != null) {
                    TimeSpan delta = ((!) envelope.timestamp).difference((!) message.time);
                    message.encryption_time_mismatch = delta < -5 * TimeSpan.MINUTE || delta > 5 * TimeSpan.MINUTE;
                }
            }
        }

        /**
         * Pure crypto pipeline for decryption: HKDF → HMAC verify → AES-256-CBC decrypt.
         *
         * Inverse of Omemo2Encrypt.omemo2_encrypt_payload().
         * Deterministic given (ciphertext, mk_and_tag). No I/O, no async.
         *
         * @param ciphertext    AES-256-CBC ciphertext
         * @param mk_and_tag   mk || truncated_hmac (48 bytes)
         * @return              decrypted plaintext bytes
         */
        internal static uint8[] omemo2_decrypt_payload(uint8[] ciphertext, uint8[] mk_and_tag) throws GLib.Error {
            if (mk_and_tag.length < MK_SIZE + 16) {
                throw new GLib.Error(Quark.from_string("omemo2"), 10, "Decrypted key too short (got %d, need %d)", mk_and_tag.length, MK_SIZE + 16);
            }

            uint8[] mk = mk_and_tag[0:MK_SIZE];
            uint8[] received_tag = mk_and_tag[MK_SIZE:MK_SIZE + 16];

            /* HKDF to derive enc_key, auth_key, iv */
            uint8[] salt = new uint8[HKDF_SALT_SIZE];
            Memory.set(salt, 0, HKDF_SALT_SIZE);
            uint8[] hkdf_output = new uint8[HKDF_OUTPUT_SIZE];

            int rc = omemo2_hkdf_sha256(hkdf_output, HKDF_OUTPUT_SIZE,
                mk, salt, HKDF_INFO.data);
            if (rc != 0) throw new GLib.Error(Quark.from_string("omemo2"), 11, "HKDF failed");

            uint8[] enc_key = hkdf_output[0:32];
            uint8[] auth_key = hkdf_output[32:64];
            uint8[] iv = hkdf_output[64:80];

            /* Verify HMAC */
            uint8[] computed_tag = new uint8[16];
            rc = omemo2_hmac_sha256(computed_tag, 16, auth_key, ciphertext);
            if (rc != 0) throw new GLib.Error(Quark.from_string("omemo2"), 12, "HMAC computation failed");

            if (!constant_time_compare(computed_tag, received_tag)) {
                throw new GLib.Error(Quark.from_string("omemo2"), 13, "HMAC verification failed");
            }

            /* AES-256-CBC decrypt */
            uint8[] plaintext;
            size_t plaintext_len;
            rc = omemo2_aes_256_cbc_pkcs7_decrypt(out plaintext, out plaintext_len,
                enc_key, iv, ciphertext);
            if (rc != 0) throw new GLib.Error(Quark.from_string("omemo2"), 14, "AES-256-CBC decrypt failed");
            plaintext.length = (int)plaintext_len;

            return plaintext;
        }

        /**
         * Constant-time comparison to prevent timing attacks.
         */
        internal static bool constant_time_compare(uint8[] a, uint8[] b) {
            if (a.length != b.length) return false;
            uint8 result = 0;
            for (int i = 0; i < a.length; i++) {
                result |= a[i] ^ b[i];
            }
            return result == 0;
        }

        public override uint8[] decrypt_key(Omemo2ParsedData data, Jid from_jid) throws GLib.Error {
            /* Find the first working key */
            foreach (Bytes encr_key in data.our_potential_encrypted_keys.keys) {
                bool is_kex = data.our_potential_encrypted_keys[encr_key];
                try {
                    return decrypt_key_raw(encr_key.get_data(), is_kex, data.sid, from_jid);
                } catch (Error e) {
                    debug("OMEMO 2: Key decryption attempt failed: %s", e.message);
                }
            }
            throw new GLib.Error(-1, 0, "No valid key found for decryption");
        }

        public uint8[] decrypt_key_for_encrypted_key(uint8[] encrypted_key, bool is_kex, int sid, Jid from_jid) throws GLib.Error {
            return decrypt_key_raw(encrypted_key, is_kex, sid, from_jid);
        }

        public bool prekey_sender_identity_matches_known_device(uint8[] encrypted_key, bool is_kex, int sid, Jid from_jid) throws GLib.Error {
            if (!is_kex) return true;

            int identity_id = db.identity.get_id_checked(account.id);
            if (identity_id <= 0) {
                throw new GLib.Error(
                    Quark.from_string("omemo2-identity-store"),
                    ErrorCode.UNKNOWN,
                    "Persistent OMEMO account identity is unavailable");
            }

            PreKeyOmemoMessage msg = Plugin.get_context().deserialize_omemo_pre_key_message(encrypted_key, (uint32) sid);
            string identity_key = Base64.encode(msg.identity_key.serialize());
            Row? device = get_prekey_device(identity_id, from_jid, sid);
            if (device == null || ((!) device)[db.identity_meta.identity_key_public_base64] == null) return true;

            return ((!) device)[db.identity_meta.identity_key_public_base64] == identity_key;
        }

        private Gee.List<Jid> get_potential_message_jids(Entities.Message message, uint8[] encrypted_key, bool is_kex, Omemo2ParsedData data, int identity_id) {
            Gee.List<Jid> possible_jids = new ArrayList<Jid>();
            if (message.type_ == Message.Type.CHAT) {
                possible_jids.add(message.from.bare_jid);
            } else {
                if (message.real_jid != null) {
                    possible_jids.add(message.real_jid.bare_jid);
                } else if (is_kex) {
                    try {
                        PreKeyOmemoMessage msg = Plugin.get_context().deserialize_omemo_pre_key_message(encrypted_key, (uint32)data.sid);
                        string identity_key = Base64.encode(msg.identity_key.serialize());
                        foreach (Row row in db.identity_meta.get_with_device_id(identity_id, data.sid).with(db.identity_meta.identity_key_public_base64, "=", identity_key)) {
                            try {
                                possible_jids.add(new Jid(row[db.identity_meta.address_name]));
                            } catch (InvalidJidError e) {
                                warning("Ignoring invalid jid from database: %s", e.message);
                            }
                        }
                    } catch (Error e) {
                        warning("OMEMO 2: Failed to deserialize pre-key message: %s", e.message);
                    }
                } else {
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

        private void ensure_prekey_state_is_compatible(uint8[] encrypted_key,
                int identity_id, Jid from_jid, int sid,
                Address address) throws Error {
            if (store.contains_session(address)) {
                SessionCipher existing_cipher = store.create_session_cipher(address);
                if (existing_cipher.get_session_version() != 4) {
                    throw new GLib.Error(
                        Quark.from_string("omemo2-prekey-session"),
                        ErrorCode.LEGACY_MESSAGE,
                        "OMEMO 2 PREKEY must not replace an incompatible session before authentication");
                }
            }
            if (!prekey_sender_identity_matches_known_device(
                    encrypted_key, true, sid, from_jid)) {
                throw new GLib.Error(
                    Quark.from_string("omemo2-prekey-identity"),
                    ErrorCode.UNTRUSTED_IDENTITY,
                    "OMEMO 2 PREKEY identity differs from the persisted device identity");
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
                debug("OMEMO 2: Learn new device from incoming message from %s/%d", address_name, sid);
                bool blind_trust = db.trust.get_blind_trust_checked(
                        identity_id, address_name, true);
                db.identity_meta.insert_device_session_checked(identity_id,
                        address_name, sid, identity_key,
                        blind_trust ? TrustLevel.TRUSTED : TrustLevel.UNKNOWN);
            }

            if (trust_manager.omemo2_enabled) {
                XmppStream? stream = stream_interactor.get_stream(account);
                if (stream != null) {
                    var module = stream.get_module<StreamModule2>(StreamModule2.IDENTITY);
                    if (module != null) {
                        module.request_user_devicelist.begin(stream, from_jid);
                    }
                }
            }

            return metadata_changed;
        }

        private void restore_prekey_memory(Address address, uint32 pre_key_id,
                uint8[]? previous_session, uint8[]? previous_pre_key,
                uint8[]? previous_identity, Error original_error) {
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
            if (pre_key_store == null) {
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
                critical("OMEMO 2 PREKEY memory rollback failed after '%s': %s; disabling the account store",
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
                critical("OMEMO 2 PREKEY database rollback failed after '%s': %s; disabling the account store",
                        original_error.message, rollback_error.message);
                return false;
            }
        }
    }

    /**
     * Classification of what action to take when processing a pre-key message
     * with respect to identity key storage.
     *
     * Security note: KEY_CHANGED must not keep the old trust decision. It
     * resets trust to UNKNOWN and is surfaced in the key-management UI.
     */
    internal enum PreKeyUpdateAction {
        /** Device is new — insert with blind-trust or UNKNOWN. */
        INSERT_NEW,
        /** Identity key matches — no database write needed. */
        NO_CHANGE,
        /** Identity key CHANGED — old session invalid, trust reset to UNKNOWN. */
        KEY_CHANGED,
    }

    /**
     * Pure decision function: classify what action update_db_for_prekey should take.
     *
     * Extracted from Omemo2Decrypt.update_db_for_prekey() and
     * OmemoDecryptor.update_db_for_prekey() for testability.
     *
     * @param existing_identity_key  The identity key currently stored in DB (null if none)
     * @param incoming_identity_key  The identity key from the incoming pre-key message
     * @param device_exists          Whether a device record exists in the DB
     * @return The action to take
     */
    internal static PreKeyUpdateAction classify_prekey_update(
        string? existing_identity_key,
        string incoming_identity_key,
        bool device_exists
    ) {
        if (!device_exists || existing_identity_key == null) {
            return PreKeyUpdateAction.INSERT_NEW;
        }
        if (existing_identity_key != incoming_identity_key) {
            return PreKeyUpdateAction.KEY_CHANGED;
        }
        return PreKeyUpdateAction.NO_CHANGE;
    }

    /**
     * Stage at which a decryption failure occurred, relative to ratchet state.
     *
     * PRE_RATCHET errors are safe to retry — the Double Ratchet has not advanced.
     * POST_RATCHET errors mean the ratchet key was consumed and the message
     * can never be retried (CWE-755: inconsistent state on partial failure).
     */
    internal enum DecryptFailureStage {
        /** Failure before ratchet advance: deserialization, no session, lookup. */
        PRE_RATCHET,
        /** Failure after ratchet advance: HMAC, AES, SCE parse. */
        POST_RATCHET,
        /** Unknown error — assume post-ratchet for safety. */
        UNKNOWN_ASSUME_POST,
    }

    /**
     * Classify a decryption error to determine if the Double Ratchet has advanced.
     *
     * In the OMEMO 2 decrypt path (decrypt_key_raw → decrypt_envelope), failures
     * can occur at different stages:
     *
     * PRE-RATCHET (safe to retry):
     * - Deserialization failure (bad protobuf)
     * - SG_ERR_NO_SESSION (no session in store)
     * - SG_ERR_INVALID_MESSAGE (message format rejected before decrypt)
     * - SG_ERR_LEGACY_MESSAGE (v3/v4 version mismatch)
     * - DB update failure (update_db_for_prekey returns false)
     *
     * POST-RATCHET (ratchet consumed, cannot retry):
     * - HMAC verification failed (ratchet decrypted key, but payload HMAC bad)
     * - AES-256-CBC decrypt failed (key derived, CBC failed)
     * - SCE envelope parse failed (plaintext obtained, XML parse failed)
     * - Decrypted key too short (ratchet decrypted, but result wrong size)
     *
     * @param error_message  The GLib.Error.message string
     * @return The failure stage classification
     */
    internal static DecryptFailureStage classify_decrypt_failure_stage(string error_message) {
        /* Pre-ratchet: Signal Protocol errors occur before chain key consumption */
        if (error_message.contains("SG_ERR_NO_SESSION")) return DecryptFailureStage.PRE_RATCHET;
        if (error_message.contains("SG_ERR_INVALID_MESSAGE")) return DecryptFailureStage.PRE_RATCHET;
        if (error_message.contains("SG_ERR_LEGACY_MESSAGE")) return DecryptFailureStage.PRE_RATCHET;
        if (error_message.contains("deserialize")) return DecryptFailureStage.PRE_RATCHET;
        if (error_message.contains("Failed updating db for prekey")) return DecryptFailureStage.PRE_RATCHET;

        /* Post-ratchet: these occur after cipher.decrypt returned successfully */
        if (error_message.contains("HMAC verification failed")) return DecryptFailureStage.POST_RATCHET;
        if (error_message.contains("AES-256-CBC decrypt failed")) return DecryptFailureStage.POST_RATCHET;
        if (error_message.contains("Failed to parse SCE envelope")) return DecryptFailureStage.POST_RATCHET;
        if (error_message.contains("Decrypted key too short")) return DecryptFailureStage.POST_RATCHET;
        if (error_message.contains("HKDF failed")) return DecryptFailureStage.POST_RATCHET;
        if (error_message.contains("HMAC computation failed")) return DecryptFailureStage.POST_RATCHET;

        /* Unknown — conservative: assume ratchet may have advanced */
        return DecryptFailureStage.UNKNOWN_ASSUME_POST;
    }

    /**
     * Message listener for OMEMO 2 decryption.
     */
    public class Omemo2DecryptMessageListener : MessageListener {
        private const string UNDECRYPTABLE_BODY = "[This OMEMO message could not be decrypted]";

        public string[] after_actions_const = new string[]{ };
        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private HashMap<Account, Omemo2Decrypt> decryptors;

        public Omemo2DecryptMessageListener(HashMap<Account, Omemo2Decrypt> decryptors) {
            this.decryptors = decryptors;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            StanzaNode? encrypted_node = stanza.stanza.get_subnode("encrypted", "urn:xmpp:omemo:2");
            bool had_payload = encrypted_node != null && ((!) encrypted_node).get_deep_string_content("payload") != null;
            bool is_mam_replay =
                    Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza) != null;
            bool decrypted = false;
            if (decryptors.has_key(message.account)) {
                decrypted = yield decryptors[message.account].decrypt_message(message, stanza, conversation);
            }

            // Replace the fallback body so failed OMEMO payload messages stay
            // visible, while ratchet-only messages without payload remain hidden.
            if (encrypted_node != null && !decrypted && message.encryption != Encryption.OMEMO) {
                message.encryption = Encryption.OMEMO;
                bool sender_device_is_ours = false;
                bool has_key_for_our_device = false;
                if (decryptors.has_key(message.account)) {
                    decryptors[message.account].inspect_archive_copy(
                            (!) encrypted_node, out sender_device_is_ours,
                            out has_key_for_our_device);
                }
                if (OmemoDecryptor.should_hide_failed_own_mam_copy(
                        message.direction, is_mam_replay,
                        sender_device_is_ours, has_key_for_our_device)) {
                    debug("OMEMO 2: Ignoring undecryptable own archive copy (stanza_id=%s)",
                            message.stanza_id ?? "-");
                    message.body = null;
                    message.decryption_failed = had_payload;
                } else if (had_payload) {
                    warning("OMEMO 2 payload message could not be decrypted (from=%s, stanza_id=%s)",
                            message.from != null ? message.from.to_string() : "-",
                            message.stanza_id ?? "-");
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
