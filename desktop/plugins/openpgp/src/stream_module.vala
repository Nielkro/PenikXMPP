using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino.Plugins.OpenPgp {
    private const string NS_URI = "jabber:x";
    private const string NS_URI_ENCRYPTED = NS_URI + ":encrypted";
    private const string NS_URI_SIGNED = NS_URI +  ":signed";

    public class Module : XmppStreamModule {
        public static Xmpp.ModuleIdentity<Module> IDENTITY = new Xmpp.ModuleIdentity<Module>(NS_URI, "0027_current_pgp_usage");

        public signal void received_jid_key_id(XmppStream stream, Jid jid, string key_id);
        public signal void received_jid_without_legacy_key(XmppStream stream, Jid jid);
        public signal void legacy_presence_state_reset(XmppStream stream);
        
        // Signal emitted when key setup is complete - allows triggering presence resend
        public signal void key_setup_complete();

        private string? signed_status = null;
        private string? signed_status_text = null;
        private string? pending_signed_status_text = null;
        private GPGHelper.Key? own_key = null;
        private Database? db = null;
        private Account? account = null;
        private Manager? manager = null;
        private PresenceManager? presence_manager = null;
        private ReceivedPipelineDecryptListener received_pipeline_decrypt_listener;
        
        // Flag to prevent use-after-free in thread callbacks
        private bool module_disposed = false;
        
        // Reference to attached stream for presence resend
        private weak XmppStream? attached_stream = null;
        
        // Store key_id for deferred initialization (safer on Windows)
        private string? pending_key_id = null;
        private bool key_setup_done = false;
        private uint key_setup_generation = 0;
        private uint attach_generation = 0;
        private HashMap<string, uint> presence_generations = new HashMap<string, uint>();

        public Module(Database? db = null, Account? account = null, string? own_key_id = null, Manager? manager = null, PresenceManager? presence_manager = null) {
            // DON'T do key setup in constructor - just store the ID
            // The actual setup happens in attach() when the stream is ready
            // This avoids thread race conditions on Windows
            this.db = db;
            this.account = account;
            this.manager = manager;
            this.presence_manager = presence_manager;
            this.pending_key_id = own_key_id;
            this.received_pipeline_decrypt_listener = new ReceivedPipelineDecryptListener(db, account, manager);
            debug("OpenPGP XEP-0027: Module created with key_id: %s (setup deferred)", own_key_id ?? "none");
        }

        internal string? get_pending_private_key_id() {
            return pending_key_id;
        }

        public void set_private_key_id(string? own_key_id) {
            // Just update the pending key ID - actual setup is done in do_key_setup()
            key_setup_generation++;
            this.pending_key_id = own_key_id;
            this.key_setup_done = false;
            
            if (own_key_id == null || own_key_id.length == 0) {
                own_key = null;
                signed_status = null;
                signed_status_text = null;
                pending_signed_status_text = null;
                debug("OpenPGP XEP-0027: Key cleared");
            } else if (attached_stream != null) {
                // If already attached, do setup now
                do_key_setup();
            }
        }
        
        // Perform key setup in background thread - non-blocking
        private void do_key_setup() {
            if (key_setup_done || pending_key_id == null || pending_key_id.length == 0) {
                return;
            }
            
            // Mark as done immediately to prevent duplicate calls
            key_setup_done = true;
            
            debug("OpenPGP XEP-0027: Starting async key setup for: %s", pending_key_id);
            
            // Copy values for thread safety
            string key_id_copy = pending_key_id;
            uint setup_generation = key_setup_generation;
            string status_text_copy = get_current_broadcast_status_text();
            
            // Run GPG operations in background thread to avoid blocking UI
            new Thread<void*>("openpgp-key-setup", () => {
                GPGHelper.Key? key = null;
                string? sig = null;
                
                try {
                    key = GPGHelper.get_private_key(key_id_copy);
                    if (key == null) {
                        debug("OpenPGP XEP-0027: Can't get PGP private key %s - key returned null", key_id_copy);
                        return null;
                    }
                    
                    debug("OpenPGP XEP-0027: Got private key, now trying to sign...");
                    sig = gpg_sign(status_text_copy, key);
                } catch (Error e) {
                    debug("OpenPGP XEP-0027: Failed to get private key %s: %s", key_id_copy, e.message);
                    return null;
                }
                
                // Callback to main thread with results
                Idle.add(() => {
                    if (module_disposed) return false;
                    if (setup_generation != key_setup_generation || pending_key_id != key_id_copy) return false;
                    
                    if (sig != null && key != null) {
                        this.own_key = key;
                        this.signed_status = sig;
                        this.signed_status_text = status_text_copy;
                        this.pending_signed_status_text = null;
                        debug("OpenPGP XEP-0027: Presence signing ENABLED with key %s", key_id_copy);
                        
                        // Send presence with signature
                        if (attached_stream != null) {
                            debug("OpenPGP XEP-0027: Sending signed presence...");
                            var presence_module = attached_stream.get_module<Presence.Module>(Presence.Module.IDENTITY);
                            if (presence_module != null) {
                                var presence = new Presence.Stanza();
                                presence.type_ = Presence.Stanza.TYPE_AVAILABLE;
                                presence_module.send_presence(attached_stream, presence);
                                debug("OpenPGP XEP-0027: Signed presence sent!");
                            }
                        }
                        
                        key_setup_complete();
                    } else {
                        debug("OpenPGP XEP-0027: Failed to create signed_status - signing disabled!");
                    }
                    return false;
                });

                return null;
            });
        }
        
        // XEP-0027 encryption (legacy format)
        public bool encrypt(MessageStanza message, GPGHelper.Key[] keys) {
            string? enc_body = gpg_encrypt(message.body, keys);
            if (enc_body != null) {
                message.stanza.put_node(new StanzaNode.build("x", NS_URI_ENCRYPTED).add_self_xmlns().put_node(new StanzaNode.text(enc_body)));
                message.body = "[This message is OpenPGP encrypted (see XEP-0027)]";
                Xep.ExplicitEncryption.add_encryption_tag_to_message(message, NS_URI_ENCRYPTED);
                return true;
            }
            return false;
        }
        
        // XEP-0374 encryption (modern format with signcrypt)
        public bool encrypt_0374(MessageStanza message, Jid recipient, GPGHelper.Key[] keys) {
            if (message.body == null) {
                warning("OpenPGP XEP-0374: refusing to encrypt message with empty body for %s", recipient.to_string());
                return false;
            }
            if (keys.length == 0) {
                warning("OpenPGP XEP-0374: refusing to encrypt message for %s without recipient keys", recipient.to_string());
                return false;
            }
            if (message.to == null) message.to = recipient;
            
            // Sign and encrypt the signcrypt element
            uint8[] encrypted;
            try {
                // Create signcrypt content element
                var signcrypt = new Xmpp.Xep.OpenPgpContent.SigncryptElement.with_body(recipient, message.body);
                string signcrypt_xml = signcrypt.to_stanza_node().to_xml();
                
                // Let GPGHelper resolve the current signing key from the
                // configured recipient list. The list always includes the
                // account key first; avoiding the cached own_key object prevents
                // stale key state from blocking sends after key changes/imports.
                encrypted = GPGHelper.sign_and_encrypt_data(signcrypt_xml, keys, null);
            } catch (Error e) {
                warning("OpenPGP XEP-0374: Sign+Encrypt failed for %s with %d keys: %s",
                        recipient.to_string(), keys.length, e.message);
                return false;
            }

            if (encrypted.length == 0) {
                warning("OpenPGP XEP-0374: Sign+Encrypt returned empty output for %s", recipient.to_string());
                return false;
            }

            string base64_data = Base64.encode(encrypted);
            
            // Create <openpgp> element
            var openpgp_node = new StanzaNode.build("openpgp", "urn:xmpp:openpgp:0")
                .add_self_xmlns()
                .put_node(new StanzaNode.text(base64_data));
            
            message.stanza.put_node(openpgp_node);
            
            // Add EME (Explicit Message Encryption) hint
            message.stanza.put_node(new StanzaNode.build("encryption", "urn:xmpp:eme:0")
                .add_self_xmlns()
                .put_attribute("namespace", "urn:xmpp:openpgp:0")
                .put_attribute("name", "OpenPGP for XMPP"));
            
            // Add fallback body
            message.body = "[This message is encrypted with OpenPGP for XMPP (XEP-0373/0374)]";
            
            // Add store hint
            message.stanza.put_node(new StanzaNode.build("store", "urn:xmpp:hints").add_self_xmlns());
            
            debug("OpenPGP XEP-0374: Message encrypted with signcrypt format");
            return true;
        }
        
        // Extract PGP data from ASCII armor (remove headers/footers, base64 encode if needed)
        internal static string extract_pgp_data(string armored) {
            int start = armored.index_of("\n\n");
            if (start < 0) start = armored.index_of("\r\n\r\n");
            if (start < 0) return Base64.encode(armored.data);
            
            start += 2;
            int end = armored.index_of("-----END PGP MESSAGE-----");
            if (end < 0) end = armored.length;
            
            // The data between headers is already base64, just return it
            return armored.substring(start, end - start).strip();
        }

        public override void attach(XmppStream stream) {
            module_disposed = false;
            attach_generation++;
            presence_generations.clear();
            // Store reference to stream for presence resend after key setup
            attached_stream = stream;
            
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_presence.connect(on_received_presence);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).pre_send_presence_stanza.connect(on_pre_send_presence_stanza);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_pipeline.connect(received_pipeline_decrypt_listener);
            stream.add_flag(new Flag());
            
            // Perform deferred key setup now that stream is attached
            // Use Idle.add to not block the attach() call
            Idle.add(() => {
                if (!module_disposed) {
                    do_key_setup();
                }
                return false;
            });
        }

        public override void detach(XmppStream stream) {
            // Mark as disposed FIRST to prevent any pending callbacks from running
            module_disposed = true;
            attach_generation++;
            presence_generations.clear();
            legacy_presence_state_reset(stream);
            attached_stream = null;
            
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_presence.disconnect(on_received_presence);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).pre_send_presence_stanza.disconnect(on_pre_send_presence_stanza);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_pipeline.disconnect(received_pipeline_decrypt_listener);
        }

        public static void require(XmppStream stream) {
            if (stream.get_module<Module>(IDENTITY) == null) stream.add_module(new Module());
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }

        private void on_received_presence(XmppStream stream, Presence.Stanza presence) {
            Jid from_jid = presence.from;
            uint current_attach_generation = attach_generation;
            uint presence_generation = next_presence_generation(from_jid);

            if (presence.type_ == Presence.Stanza.TYPE_UNAVAILABLE) {
                received_jid_without_legacy_key(stream, from_jid);
                return;
            }

            if (presence.type_ != Presence.Stanza.TYPE_AVAILABLE) {
                return;
            }

            StanzaNode x_node = presence.stanza.get_subnode("x", NS_URI_SIGNED);
            if (x_node == null) {
                received_jid_without_legacy_key(stream, from_jid);
                return;
            }
            string? sig = x_node.get_string_content();
            if (sig == null) {
                received_jid_without_legacy_key(stream, from_jid);
                return;
            }
            debug("OpenPGP XEP-0027: Got signed presence from %s, signature length: %d", from_jid.to_string(), sig.length);
            received_jid_without_legacy_key(stream, from_jid);
            
            // Store copies for thread safety
            string sig_copy = sig;
            string signed_data = presence.status == null ? "" : presence.status;
            
            // Run GPG verification in background thread to avoid blocking UI
            new Thread<void*>("openpgp-verify-presence", () => {
                GPGHelper.SignatureVerifyResult verify_result = verify_signature(sig_copy, signed_data);
                if (!verify_result.verified && verify_result.key_missing && verify_result.key_id != null) {
                    try {
                        debug("OpenPGP XEP-0027: Auto-fetching missing presence verification key %s for %s",
                                verify_result.key_id, from_jid.to_string());
                        if (GPGHelper.download_key_from_keyserver((!) verify_result.key_id)) {
                            verify_result = verify_signature(sig_copy, signed_data);
                        }
                    } catch (Error e) {
                        debug("OpenPGP XEP-0027: Keyserver fetch for presence key %s failed: %s",
                                verify_result.key_id ?? "-", e.message);
                    }
                }
                
                string? final_key_id = verify_result.key_id;
                bool final_verified = verify_result.verified;

                // Callback to main thread to update UI/flags.
                Idle.add(() => {
                    if (!presence_event_is_current(stream, from_jid, presence_generation, current_attach_generation)) return false;

                    if (final_key_id != null && final_verified) {
                        stream.get_flag(Flag.IDENTITY).set_key_id(from_jid, final_key_id);
                        received_jid_key_id(stream, from_jid, final_key_id);
                        debug("OpenPGP XEP-0027: VERIFIED key %s from %s", final_key_id, from_jid.to_string());
                    } else {
                        received_jid_without_legacy_key(stream, from_jid);
                        debug("OpenPGP XEP-0027: Ignoring unverified or unusable signed presence from %s", from_jid.to_string());
                    }
                    return false;
                });

                return null;
            });
        }

        private uint next_presence_generation(Jid jid) {
            string token = jid.to_string();
            uint generation = presence_generations.has_key(token) ? presence_generations[token] + 1 : 1;
            presence_generations[token] = generation;
            return generation;
        }

        private bool presence_event_is_current(XmppStream stream, Jid jid, uint generation, uint stream_generation) {
            string token = jid.to_string();
            return !module_disposed &&
                attached_stream == stream &&
                attach_generation == stream_generation &&
                presence_generations.has_key(token) &&
                presence_generations[token] == generation;
        }
        
        // Wrapper for GPGHelper.verify_signature
        private static GPGHelper.SignatureVerifyResult verify_signature(string sig, string signed_text) {
            // Validate signature before passing to GPG - avoid radix64 errors
            // Check for base64url characters that will cause GPG to fail
            if (sig.contains("-") || sig.contains("_")) {
                debug("OpenPGP XEP-0027: Signature contains base64url characters, skipping");
                return new GPGHelper.SignatureVerifyResult();
            }
            
            // XEP-0027 uses detached PGP SIGNATURE format, not PGP MESSAGE
            string armor = "-----BEGIN PGP SIGNATURE-----\n\n" + sig + "\n-----END PGP SIGNATURE-----";
            debug("OpenPGP XEP-0027: Verifying detached signature, armored length=%d", armor.length);
            try {
                return GPGHelper.verify_signature(armor, signed_text);
            } catch (Error e) {
                debug("OpenPGP: Failed to verify signature: %s", e.message);
                return new GPGHelper.SignatureVerifyResult();
            }
        }

        private void on_pre_send_presence_stanza(XmppStream stream, Presence.Stanza presence) {
            if (presence.type_ == Presence.Stanza.TYPE_AVAILABLE && own_key != null) {
                normalize_broadcast_presence_before_signing(presence);
                string status_text = presence.status ?? "";
                string? signature = get_cached_signature_for_presence_status(status_text);
                if (signature != null) {
                    presence.stanza.put_node(new StanzaNode.build("x", NS_URI_SIGNED).add_self_xmlns().put_node(new StanzaNode.text(signature)));
                    debug("OpenPGP XEP-0027: Sending signed presence with key signature (length: %d)", signature.length);
                } else {
                    prepare_signature_for_presence_status(status_text, true);
                    debug("OpenPGP XEP-0027: NOT sending signed presence - signature for current status is not ready yet");
                }
            } else if (presence.type_ == Presence.Stanza.TYPE_AVAILABLE) {
                debug("OpenPGP XEP-0027: NOT sending signed presence - signed_status is NULL!");
            }
        }

        private void normalize_broadcast_presence_before_signing(Presence.Stanza presence) {
            if (presence_manager == null || presence.to != null) return;

            string current_show = ((!) presence_manager).get_current_show();
            string? current_status = ((!) presence_manager).get_current_status_msg();
            if (current_show != "online" && presence.show == Presence.Stanza.SHOW_ONLINE) {
                presence.show = current_show;
            }
            if (current_status != null && ((!) current_status).strip() != "" && presence.status == null) {
                presence.status = current_status;
            }
        }

        private string get_current_broadcast_status_text() {
            if (presence_manager == null) return "";
            string? current_status = ((!) presence_manager).get_current_status_msg();
            return current_status != null ? ((!) current_status) : "";
        }

        private string? get_cached_signature_for_presence_status(string status_text) {
            if (signed_status != null && signed_status_text == status_text) return signed_status;
            if (own_key == null) return null;
            return null;
        }

        private void prepare_signature_for_presence_status(string status_text, bool resend_after) {
            if (own_key == null || pending_signed_status_text == status_text) return;

            GPGHelper.Key key = (!) own_key;
            string status_text_copy = status_text;
            uint setup_generation = key_setup_generation;
            uint stream_generation = attach_generation;
            pending_signed_status_text = status_text;

            new Thread<void*>("openpgp-presence-sign", () => {
                string? signature = gpg_sign(status_text_copy, key);
                Idle.add(() => {
                    if (module_disposed ||
                            setup_generation != key_setup_generation ||
                            stream_generation != attach_generation ||
                            pending_signed_status_text != status_text_copy) {
                        return false;
                    }
                    if (signature != null) {
                        signed_status = signature;
                        signed_status_text = status_text_copy;
                    }
                    pending_signed_status_text = null;
                    if (signature != null && resend_after && presence_manager != null && account != null) {
                        ((!) presence_manager).resend_presence((!) account);
                    }
                    return false;
                });
                return null;
            });
        }

        private static string? gpg_encrypt(string plain, GPGHelper.Key[] keys) {
            string encr;
            try {
                encr = GPGHelper.encrypt_armor(plain, keys, 0);
            } catch (Error e) {
                debug("OpenPGP: Encryption failed: %s", e.message);
                return null;
            }
            
            string? result = extract_encrypted_from_armor(encr);
            if (result != null) {
                debug("OpenPGP gpg_encrypt: Extracted (length %d)", result.length);
            }
            return result;
        }

        /**
         * Extract base64 content from PGP MESSAGE armor.
         *
         * Format:
         *   -----BEGIN PGP MESSAGE-----
         *   (optional headers)
         *
         *   [base64 data]
         *   -----END PGP MESSAGE-----
         *
         * Returns null if no valid armor found.
         */
        internal static string? extract_encrypted_from_armor(string raw) {
            // Note: Windows GPG may use \r\n, so normalize first
            string normalized = raw.replace("\r\n", "\n");
            
            int begin_marker = normalized.index_of("-----BEGIN PGP MESSAGE-----");
            if (begin_marker == -1) {
                debug("OpenPGP: No PGP MESSAGE header found");
                return null;
            }
            
            // Find the empty line after headers
            int content_start = normalized.index_of("\n\n", begin_marker);
            if (content_start == -1) {
                debug("OpenPGP: No empty line after header");
                return null;
            }
            content_start += 2; // Skip \n\n
            
            int end_marker = normalized.index_of("-----END PGP MESSAGE-----");
            if (end_marker == -1) {
                debug("OpenPGP: No END PGP MESSAGE footer found");
                return null;
            }
            
            // Extract only the base64 part
            string base64_content = normalized.substring(content_start, end_marker - content_start);
            return base64_content.strip();
        }

        private static string? gpg_sign(string str, GPGHelper.Key key) {
            string signed;
            try {
                signed = GPGHelper.sign(str, 1, key);  // 1 = DETACH mode
            } catch (Error e) {
                debug("OpenPGP: Signing failed: %s", e.message);
                return null;
            }
            
            debug("OpenPGP gpg_sign: GPG returned detached signature, armored length=%d", signed.length);
            
            string? result = extract_signature_from_armor(signed);
            if (result != null) {
                debug("OpenPGP gpg_sign: Extracted signature length=%d", result.length);
            }
            return result;
        }

        /**
         * Extract base64 content from PGP SIGNATURE armor.
         *
         * GPG output format:
         *   -----BEGIN PGP SIGNATURE-----
         *   Hash: SHA256              (optional header lines)
         *
         *   iQIzBAABCAAdFiEE...       (base64 data, 64-char wrapped)
         *   =XXXX                      (CRC24 checksum)
         *   -----END PGP SIGNATURE-----
         *
         * Returns null if armor is malformed.
         *
         * FRAGILITY NOTE: The fallback path (when \n\n is missing) uses an
         * offset of +30 to skip the BEGIN header. This is a magic number and
         * the +2 adjustment after it assumes \n\n was found, causing an
         * off-by-one in the fallback path.
         */
        internal static string? extract_signature_from_armor(string raw) {
            int begin_marker = raw.index_of("-----BEGIN PGP SIGNATURE-----");
            if (begin_marker == -1) {
                debug("OpenPGP: No PGP SIGNATURE header found in signed output");
                return null;
            }
            
            // Find the empty line after any headers (Hash: SHA256, etc.)
            int content_start = raw.index_of("\n\n", begin_marker);
            if (content_start != -1) {
                content_start += 2; // Skip the \n\n
            } else {
                // Fallback: no blank line separator. Find first \n after header.
                int header_end = raw.index_of("\n", begin_marker);
                if (header_end == -1) {
                    return null;
                }
                content_start = header_end + 1; // Skip the single \n
            }
            
            int end_marker = raw.index_of("-----END PGP SIGNATURE-----");
            if (end_marker == -1) {
                debug("OpenPGP: No END PGP SIGNATURE footer found");
                return null;
            }
            
            // Extract the base64 content (includes checksum line like =XXXX)
            string base64_content = raw.substring(content_start, end_marker - content_start);
            
            // Remove newlines to get pure base64
            base64_content = base64_content.replace("\r\n", "\n").replace("\r", "");
            
            // Strip trailing newline
            return base64_content.strip();
        }
    }

    public class MessageFlag : Xmpp.MessageFlag {
        public const string id = "pgp";

        public bool decrypted = false;
        public string? protocol = null;

        public static MessageFlag? get_flag(MessageStanza message) {
            return (MessageFlag) message.get_flag(NS_URI, id);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return id; }
    }

public class ReceivedPipelineDecryptListener : StanzaListener<MessageStanza> {

    private string[] after_actions_const = {"MODIFY_BODY"};
    private Database? db;
    private Account? account;
    private Manager? manager;

    public ReceivedPipelineDecryptListener(Database? db = null, Account? account = null, Manager? manager = null) {
        this.db = db;
        this.account = account;
        this.manager = manager;
    }

    public override string action_group { get { return "ENCRYPT_BODY"; } }
    public override string[] after_actions { get { return after_actions_const; } }

    public override async bool run(XmppStream stream, MessageStanza message) {
        debug("OpenPGP ReceivedPipeline: Processing message from %s, body=%s", 
              message.from != null ? message.from.to_string() : "null",
              message.body != null ? "(has body)" : "(no body)");

        Jid? own_jid = stream.has_flag(Bind.Flag.IDENTITY) ? stream.get_flag(Bind.Flag.IDENTITY).my_jid : null;
        
        // Try XEP-0374 format first (<openpgp> element)
        string? openpgp_data = get_openpgp_content(message);
        if (openpgp_data != null) {
            if (has_outer_message_retraction(message)) {
                debug("OpenPGP receive: skipping XEP-0374 body decrypt for outer XEP-0424 retraction stanza=%s",
                        message.id ?? "-");
                return false;
            }
            debug("OpenPGP ReceivedPipeline: Found XEP-0374 encrypted content, length=%d", openpgp_data.length);
            MessageFlag flag = new MessageFlag();
            flag.protocol = Manager.FILE_PROTOCOL_XEP0374;
            message.add_flag(flag);
            if (account != null && manager != null &&
                    !((!) manager).incoming_xep0374_message_matches_openpgp_conversation((!) account, message)) {
                return false;
            }
            if (!yield GPGHelper.has_secret_keys_async()) {
                debug("OpenPGP receive: no secret keys available for XEP-0374 stanza=%s",
                        message.id ?? "-");
                return false;
            }
            Jid? sender_key_jid = get_expected_xep0374_sender_key_jid(stream, message.from);
            if (account != null && manager != null && sender_key_jid != null &&
                    !(own_jid != null && ((!) sender_key_jid).equals_bare(own_jid)) &&
                    !((!) manager).contact_xmpp_key_was_refreshed_this_session((!) account, ((!) sender_key_jid).bare_jid)) {
                if (is_archive_message(message)) {
                    if (!((!) manager).incoming_xep0374_message_is_account_archive_chat((!) account, message)) {
                        debug("OpenPGP receive: archived XEP-0374 message has no refreshed sender key; skipping automatic XEP-0373 fetch sender=%s stanza=%s",
                                ((!) sender_key_jid).to_string(), message.id ?? "-");
                        return false;
                    }
                    // Archive replay must not initiate key discovery. Use
                    // only this account's stored XMPP key, then apply the
                    // same UID, signature and recipient checks as live data.
                    debug("OpenPGP receive: archived XEP-0374 message uses the stored sender key without an automatic XEP-0373 fetch sender=%s stanza=%s",
                            ((!) sender_key_jid).to_string(), message.id ?? "-");
                } else {
                    warning("OpenPGP receive: refreshing XEP-0373 key before accepting XEP-0374 message sender=%s stanza=%s",
                            ((!) sender_key_jid).to_string(), message.id ?? "-");
                    bool refreshed = yield ((!) manager).ensure_fresh_xep0373_contact_key((!) account, ((!) sender_key_jid).bare_jid);
                    if (!refreshed) {
                        warning("OpenPGP receive: XEP-0374 message rejected because sender key could not be refreshed sender=%s stanza=%s",
                                ((!) sender_key_jid).to_string(), message.id ?? "-");
                        return false;
                    }
                }
            }
            string? expected_sender_key = get_expected_xmpp_sender_key(sender_key_jid, own_jid);
            Gee.List<Jid>? expected_recipients = get_expected_signcrypt_recipients(stream, message.from, message.to, own_jid, message.type_);
            if (expected_sender_key == null) {
                warning("OpenPGP receive: XEP-0374 message has no trusted XMPP key for sender=%s stanza=%s",
                        sender_key_jid != null ? ((!) sender_key_jid).to_string() : "-", message.id ?? "-");
                return false;
            }
            if (sender_key_jid != null &&
                    !yield key_has_xmpp_uid_async((!) expected_sender_key, ((!) sender_key_jid).bare_jid.to_string())) {
                warning("OpenPGP receive: XEP-0374 sender key has no matching xmpp: user ID sender=%s stanza=%s",
                        ((!) sender_key_jid).to_string(), message.id ?? "-");
                return false;
            }
            string? decrypted = yield gpg_decrypt_0374(openpgp_data, expected_sender_key, expected_recipients);
            if (decrypted != null) {
                flag.decrypted = true;
                message.body = decrypted;
                debug("OpenPGP ReceivedPipeline: Decrypted XEP-0374 message, length=%d", decrypted.length);
            } else {
                warning("OpenPGP receive: XEP-0374 decryption returned null for stanza=%s from=%s",
                        message.id ?? "-", message.from != null ? message.from.to_string() : "-");
            }
            return false;
        }
        
        // Fall back to XEP-0027 format (<x xmlns='jabber:x:encrypted'>)
        string? encrypted = get_cyphertext(message);
        if (encrypted != null) {
            debug("OpenPGP ReceivedPipeline: Found XEP-0027 encrypted content, length=%d", encrypted.length);
            MessageFlag flag = new MessageFlag();
            flag.protocol = Manager.FILE_PROTOCOL_XEP0027;
            message.add_flag(flag);
            if (!yield GPGHelper.has_secret_keys_async()) {
                debug("OpenPGP receive: no secret keys available for XEP-0027 stanza=%s",
                        message.id ?? "-");
                return false;
            }
            string? decrypted = yield gpg_decrypt(encrypted);
            if (decrypted != null) {
                flag.decrypted = true;
                message.body = decrypted;
                if (account != null && manager != null && message.from != null &&
                        !(own_jid != null && message.from.equals_bare(own_jid))) {
                    ((!) manager).mark_legacy_contact_activity((!) account, message.from);
                }
                debug("OpenPGP ReceivedPipeline: Decrypted XEP-0027 message, length=%d", decrypted.length);
            } else {
                debug("OpenPGP ReceivedPipeline: XEP-0027 decryption returned null!");
            }
        } else {
            debug("OpenPGP ReceivedPipeline: No encrypted content found in message");
        }
        return false;
    }

    private static bool is_archive_message(MessageStanza message) {
        return Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message) != null;
    }

    internal static bool has_outer_message_retraction(MessageStanza message) {
        return Xmpp.Xep.MessageRetraction.get_retract_id(message) != null;
    }

    private string? get_expected_xmpp_sender_key(Jid? sender, Jid? own_jid) {
        if (sender == null || db == null) return null;

        if (own_jid != null && sender.equals_bare(own_jid)) {
            return account != null ? db.get_account_xmpp_key((!) account) : null;
        }

        return account != null ? db.get_contact_xmpp_key((!) account, sender.bare_jid) : null;
    }

    private Jid? get_expected_xep0374_sender_key_jid(XmppStream stream, Jid? sender) {
        if (sender == null) return null;

        if (is_private_muc_sender_without_real_jid(stream, (!) sender)) return null;

        Jid? muc_real_jid = get_muc_real_jid(stream, (!) sender);
        if (muc_real_jid != null) {
            return ((!) muc_real_jid).bare_jid;
        }

        return ((!) sender).bare_jid;
    }

    internal Gee.List<Jid>? get_expected_signcrypt_recipients_for_tests(XmppStream stream, Jid? sender,
            Jid? stanza_to, Jid? own_jid, string message_type) {
        return get_expected_signcrypt_recipients(stream, sender, stanza_to, own_jid, message_type);
    }

    private Gee.List<Jid>? get_expected_signcrypt_recipients(XmppStream stream, Jid? sender,
            Jid? stanza_to, Jid? own_jid, string message_type) {
        var recipients = new Gee.ArrayList<Jid>();
        Jid? muc_real_jid = sender != null ? get_muc_real_jid(stream, (!) sender) : null;

        if (sender != null && muc_real_jid != null) {
            if (message_type == MessageStanza.TYPE_GROUPCHAT) {
                add_expected_recipient(recipients, ((!) sender).bare_jid);
            } else if (own_jid != null && ((!) muc_real_jid).equals_bare(own_jid)) {
                add_outgoing_signcrypt_recipients(stream, recipients, stanza_to);
            } else {
                if (own_jid != null) {
                    add_expected_recipient(recipients, ((!) own_jid).bare_jid);
                }
                Jid? own_muc_jid = get_own_muc_jid(stream, ((!) sender).bare_jid);
                if (own_muc_jid != null) {
                    add_expected_recipient(recipients, (!) own_muc_jid);
                }
            }
            return recipients.size > 0 ? recipients : null;
        }
        if (own_jid != null && sender != null && sender.equals_bare(own_jid)) {
            add_outgoing_signcrypt_recipients(stream, recipients, stanza_to);
            return recipients.size > 0 ? recipients : null;
        }
        if (own_jid != null) {
            add_expected_recipient(recipients, ((!) own_jid).bare_jid);
        }
        return recipients.size > 0 ? recipients : null;
    }

    private void add_outgoing_signcrypt_recipients(XmppStream stream, Gee.List<Jid> recipients, Jid? stanza_to) {
        if (stanza_to == null) return;

        Jid? target_muc_real_jid = get_muc_real_jid(stream, (!) stanza_to);
        if (target_muc_real_jid != null) {
            add_expected_recipient(recipients, (!) stanza_to);
            add_expected_recipient(recipients, ((!) target_muc_real_jid).bare_jid);
            return;
        }

        add_expected_recipient(recipients, ((!) stanza_to).bare_jid);
    }

    private static void add_expected_recipient(Gee.List<Jid> recipients, Jid candidate) {
        foreach (Jid existing in recipients) {
            if (existing.equals(candidate)) return;
        }
        recipients.add(candidate);
    }

    private Jid? get_own_muc_jid(XmppStream stream, Jid room) {
        Xep.Muc.Flag? muc_flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (muc_flag == null) return null;

        string? own_nick = ((!) muc_flag).get_muc_nick(room.bare_jid);
        if (own_nick == null || ((!) own_nick) == "") return null;

        try {
            return room.bare_jid.with_resource((!) own_nick);
        } catch (Error e) {
            debug("OpenPGP receive: failed to build own MUC JID for room %s: %s", room.to_string(), e.message);
            return null;
        }
    }

    private bool is_private_muc_sender_without_real_jid(XmppStream stream, Jid sender) {
        if (sender.resourcepart == null || sender.resourcepart == "") return false;

        Xep.Muc.Flag? muc_flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (muc_flag == null) return false;
        if (!((!) muc_flag).has_room_feature(sender.bare_jid, Xep.Muc.Feature.MEMBERS_ONLY) ||
                !((!) muc_flag).has_room_feature(sender.bare_jid, Xep.Muc.Feature.NON_ANONYMOUS)) {
            return false;
        }

        return get_muc_real_jid(stream, sender) == null;
    }

    private Jid? get_muc_real_jid(XmppStream stream, Jid sender) {
        if (sender.resourcepart == null || sender.resourcepart == "") return null;

        Xep.Muc.Flag? muc_flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (muc_flag == null) return null;

        Jid? real_jid = ((!) muc_flag).get_real_jid(sender);
        if (real_jid == null || ((!) real_jid).equals(sender)) return null;
        return (!) real_jid;
    }

    private static async bool key_has_xmpp_uid_async(string key_id, string bare_jid) {
        SourceFunc callback = key_has_xmpp_uid_async.callback;
        bool ok = false;
        new Thread<void*>("openpgp-xmpp-uid-check", () => {
            try {
                ok = GPGHelper.key_has_xmpp_uid(key_id, bare_jid);
            } catch (Error e) {
                debug("OpenPGP receive: failed to check XMPP user ID for key %s: %s", key_id, e.message);
            }
            Idle.add((owned) callback);
            return null;
        });
        yield;
        return ok;
    }

    // Decrypt XEP-0374 format
    private static async string? gpg_decrypt_0374(string base64_data, string expected_sender_key,
            Gee.List<Jid>? expected_recipients) {
        SourceFunc callback = gpg_decrypt_0374.callback;
        Xep0374DecryptResult res = new Xep0374DecryptResult();
        new Thread<void*> (null, () => {
            string clean_data = base64_data.strip();
            
            debug("OpenPGP gpg_decrypt_0374: Input length=%d", clean_data.length);
            
            string? decrypted_xml = null;
            
            if (clean_data.has_prefix("-----BEGIN PGP")) {
                debug("OpenPGP gpg_decrypt_0374: Data is already armored");
                try {
                    decrypted_xml = GPGHelper.decrypt(clean_data);
                } catch (Error e) {
                    debug("OpenPGP gpg_decrypt_0374: Armored decryption failed: %s", e.message);
                }
            } else {
                // Remove whitespace from base64
                clean_data = clean_data.replace("\n", "").replace("\r", "").replace(" ", "").replace("\t", "");
                
                // Validate: reject base64url characters (- _) that would
                // silently produce garbled binary and NODATA errors from GPG
                if (clean_data.contains("-") || clean_data.contains("_")) {
                    debug("OpenPGP gpg_decrypt_0374: Data contains base64url characters, skipping");
                    Idle.add((owned) callback);
                    return null;
                }
                
                // Add padding if needed
                int padding_needed = (4 - (clean_data.length % 4)) % 4;
                for (int i = 0; i < padding_needed; i++) {
                    clean_data += "=";
                }
                
                debug("OpenPGP gpg_decrypt_0374: Base64 after cleanup, length=%d", clean_data.length);
                
                // Decode base64 to binary
                uint8[] binary_data = Base64.decode(clean_data);
                debug("OpenPGP gpg_decrypt_0374: Decoded to %d binary bytes", binary_data.length);
                
                // Decrypt binary data
                try {
                    var decrypted = GPGHelper.decrypt_data(binary_data);
                    // Convert uint8[] to string safely
                    decrypted_xml = (string) decrypted.data;
                    if (decrypted.data.length > 0 && decrypted.data[decrypted.data.length - 1] != 0) {
                        var sb = new StringBuilder();
                        foreach (uint8 b in decrypted.data) {
                            if (b != 0) sb.append_c((char) b);
                        }
                        decrypted_xml = sb.str;
                    }
                    res.signer_fingerprint = decrypted.signer_fingerprint;
                    res.signature_valid = decrypted.signature_valid;
                    debug("OpenPGP gpg_decrypt_0374: Binary decryption successful");
                } catch (Error e) {
                    warning("OpenPGP receive: XEP-0374 binary decryption failed: %s", e.message);
                    
                    // Fallback: try ASCII armor
                    var wrapped = new StringBuilder();
                    for (int i = 0; i < clean_data.length; i += 64) {
                        int end = int.min(i + 64, clean_data.length);
                        wrapped.append(clean_data.substring(i, end - i));
                        wrapped.append("\n");
                    }
                    
                    string armor = "-----BEGIN PGP MESSAGE-----\n\n" + wrapped.str + "-----END PGP MESSAGE-----";
                    try {
                        decrypted_xml = GPGHelper.decrypt(armor);
                        debug("OpenPGP gpg_decrypt_0374: ASCII armor fallback successful");
                    } catch (Error e2) {
                        warning("OpenPGP receive: XEP-0374 ASCII armor fallback also failed: %s", e2.message);
                    }
                }
            }
            
            if (decrypted_xml != null) {
                debug("OpenPGP gpg_decrypt_0374: Decrypted XML length=%d", decrypted_xml.length);
                res.decrypted_xml = decrypted_xml;
            }
            Idle.add((owned) callback);
            return null;
        });
        yield;
        if (res.decrypted_xml == null) return null;
        return yield extract_verified_body_from_signcrypt(res.decrypted_xml, res.signer_fingerprint,
                res.signature_valid, expected_sender_key, expected_recipients);
    }

    private class Xep0374DecryptResult {
        public string? decrypted_xml;
        public string? signer_fingerprint;
        public bool signature_valid = false;
    }

    private static async string? extract_verified_body_from_signcrypt(string xml, string? signer_fingerprint,
            bool signature_valid, string expected_sender_key, Gee.List<Jid>? expected_recipients) {
        if (!signature_valid || signer_fingerprint == null ||
                !fingerprint_or_keyid_matches(expected_sender_key, signer_fingerprint)) {
            warning("OpenPGP receive: XEP-0374 signer does not match stored XMPP key");
            return null;
        }

        try {
            var reader = new StanzaReader.for_string(xml);
            StanzaNode node = yield reader.read_node();
            var signcrypt = Xmpp.Xep.OpenPgpContent.SigncryptElement.from_stanza_node(node);
            if (signcrypt == null) {
                warning("OpenPGP receive: XEP-0374 decrypted XML is not a signcrypt element");
                return null;
            }

            if (expected_recipients != null && ((!) expected_recipients).size > 0) {
                if (signcrypt.to == null || !signcrypt_recipient_matches((!) signcrypt.to, (!) expected_recipients)) {
                    warning("OpenPGP receive: XEP-0374 recipient does not match local account");
                    return null;
                }
            } else if (signcrypt.to == null) {
                warning("OpenPGP receive: XEP-0374 signcrypt element has no recipient");
                return null;
            }

            string? body = signcrypt.get_body_text();
            if (body == null) {
                warning("OpenPGP receive: XEP-0374 decrypted XML did not contain a body element");
                return null;
            }
            debug("OpenPGP gpg_decrypt_0374: Extracted verified body length=%d", body.length);
            return body;
        } catch (Error e) {
            warning("OpenPGP receive: XEP-0374 decrypted XML parse failed: %s", e.message);
            return null;
        }
    }

    private static bool signcrypt_recipient_matches(Jid actual, Gee.List<Jid> expected_recipients) {
        foreach (Jid expected in expected_recipients) {
            if (expected.is_full()) {
                if (actual.equals(expected)) return true;
            } else if (actual.equals_bare(expected)) {
                return true;
            }
        }
        return false;
    }

    internal static bool fingerprint_or_keyid_matches(string expected_key, string signer_key) {
        return openpgp_key_ids_match(expected_key, signer_key);
    }
    
    // Extract body text from signcrypt XML
    internal static string? extract_body_from_signcrypt(string xml) {
        // Bug #17 FIX: Use "<body>" or "<body " to avoid matching <bodyguard> etc.
        // Look for <body> (self-closing or with attributes) followed by </body>
        int body_start = -1;
        int search_from = 0;
        while (true) {
            int pos = xml.index_of("<body", search_from);
            if (pos < 0) return null;
            // Check that the char after "<body" is '>', ' ', '/' or end-of-string
            int after = pos + 5; // length of "<body"
            if (after >= xml.length) return null;
            char c = xml[after];
            if (c == '>' || c == ' ' || c == '/' || c == '\t' || c == '\n' || c == '\r') {
                body_start = pos;
                break;
            }
            // Not a real <body> element — skip past and keep searching
            search_from = after;
        }
        
        int content_start = xml.index_of(">", body_start);
        if (content_start < 0) return null;
        content_start++;
        
        int body_end = xml.index_of("</body>", content_start);
        if (body_end < 0) return null;
        
        return xml.substring(content_start, body_end - content_start);
    }

    private static async string? gpg_decrypt(string enc) {
        SourceFunc callback = gpg_decrypt.callback;
        string? res = null;
        new Thread<void*> (null, () => {
            string clean_data = enc.strip();
            
            debug("OpenPGP gpg_decrypt: Input length=%d", clean_data.length);
            
            // Check if it's already armored
            if (clean_data.has_prefix("-----BEGIN PGP")) {
                debug("OpenPGP gpg_decrypt: Data is already armored, decrypting directly");
                try {
                    res = GPGHelper.decrypt(clean_data);
                    debug("OpenPGP gpg_decrypt: Armored decryption successful");
                } catch (Error e) {
                    debug("OpenPGP gpg_decrypt: Armored decryption failed: %s", e.message);
                }
            } else {
                // XEP-0027 sends base64-encoded PGP message
                // Decode base64 and pass binary data to GPG
                
                // Remove any whitespace/newlines from the base64
                clean_data = clean_data.replace("\n", "").replace("\r", "").replace(" ", "").replace("\t", "");
                
                // Validate: reject base64url characters (- _) that would
                // silently produce garbled binary and NODATA errors from GPG
                if (clean_data.contains("-") || clean_data.contains("_")) {
                    debug("OpenPGP gpg_decrypt: Data contains base64url characters, skipping");
                    res = null;
                    Idle.add((owned) callback);
                    return null;
                }
                
                debug("OpenPGP gpg_decrypt: Base64 after cleanup, length=%d", clean_data.length);
                
                // Add padding if needed
                int padding_needed = (4 - (clean_data.length % 4)) % 4;
                for (int i = 0; i < padding_needed; i++) {
                    clean_data += "=";
                }
                
                // Decode base64 to binary
                uint8[] binary_data = Base64.decode(clean_data);
                debug("OpenPGP gpg_decrypt: Decoded to %d binary bytes", binary_data.length);
                
                // Write binary data to temp file and decrypt
                try {
                    var decrypted = GPGHelper.decrypt_data(binary_data);
                    // Convert uint8[] to string safely
                    res = (string) decrypted.data;
                    // Ensure null termination for string
                    if (decrypted.data.length > 0 && decrypted.data[decrypted.data.length - 1] != 0) {
                        // Data is not null-terminated, create proper string
                        var sb = new StringBuilder();
                        foreach (uint8 b in decrypted.data) {
                            if (b != 0) sb.append_c((char) b);
                        }
                        res = sb.str;
                    }
                    debug("OpenPGP gpg_decrypt: Binary decryption successful, result length=%d",
                          res != null ? res.length : 0);
                } catch (Error e) {
                    debug("OpenPGP gpg_decrypt: Binary decryption failed: %s", e.message);
                    
                    // Fallback: try as ASCII armor
                    debug("OpenPGP gpg_decrypt: Trying ASCII armor fallback...");
                    var wrapped = new StringBuilder();
                    for (int i = 0; i < clean_data.length; i += 64) {
                        int end = int.min(i + 64, clean_data.length);
                        wrapped.append(clean_data.substring(i, end - i));
                        wrapped.append("\n");
                    }
                    
                    string armor = "-----BEGIN PGP MESSAGE-----\n\n" + wrapped.str + "-----END PGP MESSAGE-----";
                    try {
                        res = GPGHelper.decrypt(armor);
                        debug("OpenPGP gpg_decrypt: ASCII armor fallback successful");
                    } catch (Error e2) {
                        debug("OpenPGP gpg_decrypt: ASCII armor fallback also failed: %s", e2.message);
                        res = null;
                    }
                }
            }
            Idle.add((owned) callback);
            return null;
        });
        yield;
        return res;
    }

    private string? get_cyphertext(MessageStanza message) {
        // Debug: dump stanza to see what we're looking for
        debug("OpenPGP get_cyphertext: Looking for <x xmlns='jabber:x:encrypted'>");
        StanzaNode? x_node = message.stanza.get_subnode("x", NS_URI_ENCRYPTED);
        if (x_node != null) {
            string? content = x_node.get_string_content();
            debug("OpenPGP get_cyphertext: Found encrypted content, length=%d", content != null ? content.length : 0);
            return content;
        }
        debug("OpenPGP get_cyphertext: No <x> node found with namespace %s", NS_URI_ENCRYPTED);
        return null;
    }
    
    private string? get_openpgp_content(MessageStanza message) {
        debug("OpenPGP get_openpgp_content: Looking for <openpgp xmlns='urn:xmpp:openpgp:0'>");
        StanzaNode? openpgp_node = message.stanza.get_subnode("openpgp", "urn:xmpp:openpgp:0");
        if (openpgp_node != null) {
            string? content = openpgp_node.get_string_content();
            debug("OpenPGP get_openpgp_content: Found openpgp content, length=%d", content != null ? content.length : 0);
            return content;
        }
        debug("OpenPGP get_openpgp_content: No <openpgp> node found");
        return null;
    }
}

}
