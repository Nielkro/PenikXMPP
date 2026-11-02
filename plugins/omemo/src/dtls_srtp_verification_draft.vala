using Omemo;
using Gee;
using Xmpp;

namespace Dino.Plugins.Omemo.DtlsSrtpVerificationDraft {
    public const string NS_URI = "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification";

    private class MujiDevice : Object {
        internal Jid room;
        internal Jid occupant;
        internal Jid peer;
        internal int device;
        internal MujiDevice(Jid room, Jid occupant, Jid peer, int device) {
            this.room = room; this.occupant = occupant;
            this.peer = peer; this.device = device;
        }
    }

    private class CallBinding : Object {
        internal Jid peer;
        internal int device;
        internal bool pinned = false;
        internal string? identity;
        internal MujiDevice? member;
        internal Cancellable cancellable = new Cancellable();
        internal CallBinding(Jid peer, int device, MujiDevice? member = null) {
            this.peer = peer; this.device = device; this.member = member;
        }
    }

    private class FingerprintRewrite : Object {
        internal StanzaNode transport;
        internal StanzaNode original;
        internal StanzaNode replacement;
        internal FingerprintRewrite(StanzaNode transport, StanzaNode original, StanzaNode replacement) {
            this.transport = transport; this.original = original; this.replacement = replacement;
        }
        internal void apply() {
            transport.sub_nodes.remove(original);
            transport.put_node(replacement);
        }
    }

    /** The advertised draft is optional. Once selected, never silently downgrade it. */
    public class StreamModule : XmppStreamModule, Iq.OutgoingRequestFilter, Iq.IncomingRequestFilter {
        public static Xmpp.ModuleIdentity<StreamModule> IDENTITY = new Xmpp.ModuleIdentity<StreamModule>(NS_URI, "dtls_srtp_omemo_verification_draft");
        private VerificationSendListener send_listener = new VerificationSendListener();
        private HashMap<string, CallBinding> calls = new HashMap<string, CallBinding>();
        private HashMap<string, MujiDevice> members = new HashMap<string, MujiDevice>();
        private HashSet<string> ended_calls = new HashSet<string>();
        private ArrayList<string> ended_order = new ArrayList<string>();
        private XmppStream? attached_stream;
        private uint generation = 0;
        private Dino.Entities.Account? account;
        private Database? db;

        public StreamModule(Dino.Entities.Account? account = null, Database? db = null) {
            this.account = account; this.db = db;
        }

        private static string call_key(Jid peer, string sid) { return peer.to_string() + "\n" + sid; }
        private static string member_key(Jid room, Jid peer) { return room.bare_jid.to_string() + "\n" + peer.to_string(); }

        private bool local_recipient(XmppStream stream, Jid? recipient) {
            Bind.Flag? flag = stream.get_flag<Bind.Flag>(Bind.Flag.IDENTITY);
            if (flag == null || ((!) flag).my_jid == null) return false;
            Jid local = ((!) flag).my_jid;
            return recipient == null || (recipient.equals_bare(local) &&
                (recipient.resourcepart == null || recipient.equals(local)));
        }

        private void end_call(Jid peer, string sid) {
            end_call_key(call_key(peer, sid));
        }

        private void end_call_key(string key) {
            CallBinding? binding = calls[key];
            if (binding != null) ((!) binding).cancellable.cancel();
            calls.unset(key);
            if (ended_calls.add(key)) ended_order.add(key);
            if (ended_order.size > 1024) ended_calls.remove(ended_order.remove_at(0));
        }

        private void remove_member(MujiDevice member) {
            string key = member_key(member.room, member.peer);
            if (members[key] == member) members.unset(key);
            var stale = new ArrayList<string>();
            foreach (var entry in calls.entries) {
                if (entry.value.member == member) {
                    stale.add(entry.key);
                }
            }
            foreach (string id in stale) end_call_key(id);
        }

        private CallBinding? resolve_binding(Jid peer, string sid, StanzaNode jingle) throws Error {
            if (peer.resourcepart == null) return null;
            string key = call_key(peer, sid);
            if (ended_calls.contains(key)) throw new IOError.CANCELLED("Call already ended");
            CallBinding? binding = calls[key];
            // Adoption into MUJI preserves the established direct leg and SID.
            if (binding != null) return binding;
            StanzaNode? muji = jingle.get_subnode("muji", Xep.Muji.NS_URI);
            string? room_string = muji != null ? ((!) muji).get_attribute("room") : null;
            if (room_string == null) return null;
            Jid room = new Jid((!) room_string);
            MujiDevice? member = members[member_key(room, peer)];
            if (member == null) return null;
            if (((!) member).device <= 0)
                throw new IOError.PERMISSION_DENIED("Ambiguous or invalid MUJI OMEMO device");
            binding = new CallBinding(peer, ((!) member).device, member);
            calls[key] = binding;
            return binding;
        }

        private bool binding_is_current(XmppStream stream, uint epoch, string sid, CallBinding binding) {
            if (attached_stream != stream || generation != epoch || binding.cancellable.is_cancelled() ||
                    calls[call_key(binding.peer, sid)] != binding) return false;
            if (binding.member != null) {
                MujiDevice member = (!) binding.member;
                if (members[member_key(member.room, member.peer)] != member) return false;
            }
            return true;
        }

        private string? identity_for_call(Omemo.StreamModule module, Jid peer, int device,
                bool require_accepted = false, bool allow_prekey_learning = false) throws Error {
            if (module.store.registration_pending || !module.store.is_persistence_ready || device <= 0)
                throw new IOError.PERMISSION_DENIED("OMEMO call store is not ready");
            if (account == null || db == null)
                throw new IOError.PERMISSION_DENIED("OMEMO call account context is unavailable");
            string? metadata_key = null;
            if (account != null && db != null) {
                Database database = (!) db;
                int identity_id = database.identity.get_id_checked(((!) account).id);
                if (identity_id <= 0) throw new IOError.PERMISSION_DENIED("OMEMO account identity is unavailable");
                Qlite.Row? row = database.identity_meta.get_device_checked(identity_id, peer.bare_jid.to_string(), device);
                if (row != null && (((!) row)[database.identity_meta.trust_level] == TrustLevel.UNTRUSTED ||
                        ((!) row)[database.identity_meta.identity_key_changed]))
                    throw new IOError.PERMISSION_DENIED("OMEMO call device was rejected or changed");
                bool accepted = row != null &&
                    (((!) row)[database.identity_meta.trust_level] == TrustLevel.TRUSTED ||
                     ((!) row)[database.identity_meta.trust_level] == TrustLevel.VERIFIED);
                bool unknown_key = row == null || ((!) row)[database.identity_meta.identity_key_public_base64] == null;
                bool may_learn = allow_prekey_learning && unknown_key &&
                    database.trust.get_blind_trust_checked(identity_id, peer.bare_jid.to_string(), true);
                if (require_accepted && !accepted && !may_learn)
                    throw new IOError.PERMISSION_DENIED("OMEMO call device has not been accepted");
                if (row != null) metadata_key = ((!) row)[database.identity_meta.identity_key_public_base64];
            }
            var address = new Address(peer.bare_jid.to_string(), device);
            try {
                uint8[]? identity = module.store.identity_key_store.load_identity(address);
                string? native_key = identity != null ? Base64.encode((!) identity) : null;
                if (metadata_key != null && native_key != null && metadata_key != native_key)
                    throw new IOError.PERMISSION_DENIED("OMEMO call identity stores disagree");
                return native_key ?? metadata_key;
            } finally { address.device_id = 0; }
        }

        private static void require_same_identity(string? expected, string? actual) throws Error {
            if (expected != null && expected != actual)
                throw new IOError.PERMISSION_DENIED("OMEMO call device identity changed");
        }

        private static ArrayList<StanzaNode> fingerprint_transports(StanzaNode jingle) {
            var transports = new ArrayList<StanzaNode>();
            foreach (StanzaNode content in jingle.get_subnodes("content", Xep.Jingle.NS_URI)) {
                StanzaNode? transport = content.get_subnode("transport", Xep.JingleIceUdp.NS_URI);
                if (transport != null && (((!) transport).get_subnode("fingerprint", Xep.JingleIceUdp.DTLS_NS_URI) != null ||
                        ((!) transport).get_subnode("fingerprint", NS_URI) != null)) transports.add((!) transport);
            }
            return transports;
        }

        private static StanzaNode replacement_fingerprint(StanzaNode original, string ns) {
            StanzaNode result = new StanzaNode.build("fingerprint", ns).add_self_xmlns();
            string? hash = original.get_attribute("hash");
            string? setup = original.get_attribute("setup");
            if (hash != null) result.put_attribute("hash", hash);
            if (setup != null) result.put_attribute("setup", setup);
            return result;
        }

        public async void prepare_send(XmppStream stream, Iq.Stanza iq, Cancellable cancellable) throws Error {
            if (iq.type_ != Iq.Stanza.TYPE_SET) return;
            StanzaNode? node = iq.stanza.get_subnode("jingle", Xep.Jingle.NS_URI);
            if (node == null || iq.to == null) return;
            if (attached_stream != stream) throw new IOError.CANCELLED("OMEMO call stream was replaced");
            StanzaNode jingle = (!) node;
            string? sid = jingle.get_attribute("sid");
            if (sid == null || sid.length == 0) return;
            if (jingle.get_attribute("action") == "session-terminate") { end_call(iq.to, sid); return; }
            ArrayList<StanzaNode> transports = fingerprint_transports(jingle);
            if (transports.is_empty) return;
            CallBinding? maybe_binding = resolve_binding(iq.to, sid, jingle);
            if (maybe_binding == null) return; // A peer that did not advertise the optional draft uses ordinary DTLS.
            CallBinding binding = (!) maybe_binding;
            Omemo.StreamModule? module = stream.get_module<Omemo.StreamModule>(Omemo.StreamModule.IDENTITY);
            if (module == null) throw new IOError.PERMISSION_DENIED("OMEMO call module is unavailable");
            uint epoch = generation;
            // Account removal discards identity bytes as well as readiness.
            // Check that state before dereferencing the local public key.
            string? previous_identity = identity_for_call((!) module, binding.peer, binding.device);
            uint32 own_device = ((!) module).store.local_registration_id;
            string own_identity = Base64.encode(((!) module).store.identity_key_store.identity_key_public.get_data());
            require_same_identity(binding.identity, previous_identity);
            ulong cancel_handler = binding.cancellable.cancelled.connect(() => { cancellable.cancel(); });
            try {
                if (!binding_is_current(stream, epoch, sid, binding) || cancellable.is_cancelled())
                    throw new IOError.CANCELLED("OMEMO call preparation was cancelled");
                if (!yield ((!) module).ensure_legacy_session_for_send(stream, binding.peer.bare_jid, binding.device, cancellable))
                    throw new IOError.PERMISSION_DENIED("Could not prepare the OMEMO call session");
                if (!binding_is_current(stream, epoch, sid, binding) || cancellable.is_cancelled() ||
                        ((!) module).store.local_registration_id != own_device ||
                        Base64.encode(((!) module).store.identity_key_store.identity_key_public.get_data()) != own_identity)
                    throw new IOError.CANCELLED("OMEMO call identity changed during preparation");
                string? current_identity = identity_for_call((!) module, binding.peer, binding.device, true);
                require_same_identity(previous_identity, current_identity);
                require_same_identity(binding.identity, current_identity);
                var rewrites = new ArrayList<FingerprintRewrite>();
                Xep.Omemo.OmemoEncryptor encryptor = stream.get_module<Xep.Omemo.OmemoEncryptor>(Xep.Omemo.OmemoEncryptor.IDENTITY);
                foreach (StanzaNode transport in transports) {
                    Gee.List<StanzaNode> originals = transport.get_subnodes("fingerprint", Xep.JingleIceUdp.DTLS_NS_URI);
                    if (originals.is_empty || transport.get_subnode("fingerprint", NS_URI) != null)
                        throw new IOError.PERMISSION_DENIED("Unexpected prepared OMEMO fingerprint");
                    foreach (StanzaNode original in originals) {
                        var data = encryptor.encrypt_plaintext(original.get_deep_string_content());
                        encryptor.encrypt_key(data, binding.peer.bare_jid, binding.device);
                        StanzaNode replacement = replacement_fingerprint(original, NS_URI);
                        replacement.put_node(data.get_encrypted_node());
                        rewrites.add(new FingerprintRewrite(transport, original, replacement));
                    }
                }
                // Ratchets may advance during preparation, but no partial or cleartext IQ may escape.
                foreach (FingerprintRewrite rewrite in rewrites) rewrite.apply();
                binding.identity = current_identity;
                binding.pinned = true;
            } finally { SignalHandler.disconnect(binding.cancellable, cancel_handler); }
        }

        public void prepare_receive(XmppStream stream, Iq.Stanza iq) throws Error {
            if (iq.type_ != Iq.Stanza.TYPE_SET || iq.from == null || !local_recipient(stream, iq.to)) return;
            StanzaNode? node = iq.stanza.get_subnode("jingle", Xep.Jingle.NS_URI);
            if (node == null) return;
            if (attached_stream != stream) throw new IOError.CANCELLED("OMEMO call stream was replaced");
            StanzaNode jingle = (!) node;
            string? sid = jingle.get_attribute("sid");
            if (sid == null || sid.length == 0) return;
            if (jingle.get_attribute("action") == "session-terminate") { end_call(iq.from, sid); return; }
            ArrayList<StanzaNode> transports = fingerprint_transports(jingle);
            if (transports.is_empty) return;
            CallBinding? binding = resolve_binding(iq.from, sid, jingle);
            if (binding != null && !binding_is_current(stream, generation, sid, (!) binding))
                throw new IOError.PERMISSION_DENIED("OMEMO call binding is no longer current");
            bool has_encrypted = false, has_plain = false;
            foreach (StanzaNode transport in transports) {
                has_encrypted |= transport.get_subnode("fingerprint", NS_URI) != null;
                has_plain |= transport.get_subnode("fingerprint", Xep.JingleIceUdp.DTLS_NS_URI) != null;
            }
            if (!has_encrypted) {
                if (binding != null && ((!) binding).pinned)
                    throw new IOError.PERMISSION_DENIED("OMEMO call fingerprint downgrade");
                return; // Offering the draft does not require a remote caller to select it.
            }
            if (has_plain || iq.from.resourcepart == null)
                throw new IOError.PERMISSION_DENIED("Mixed or unbound OMEMO call fingerprints");
            Omemo.StreamModule module = stream.get_module<Omemo.StreamModule>(Omemo.StreamModule.IDENTITY);
            Xep.Omemo.OmemoDecryptor decryptor = stream.get_module<Xep.Omemo.OmemoDecryptor>(Xep.Omemo.OmemoDecryptor.IDENTITY);
            var rewrites = new ArrayList<FingerprintRewrite>();
            int device = binding != null ? ((!) binding).device : -1;
            string? previous_identity = null;
            foreach (StanzaNode transport in transports) {
                foreach (StanzaNode original in transport.get_subnodes("fingerprint", NS_URI)) {
                StanzaNode? encrypted = original.get_subnode("encrypted", Omemo.NS_URI);
                Xep.Omemo.ParsedData? parsed = encrypted != null ? decryptor.parse_node((!) encrypted) : null;
                if (parsed == null || ((!) parsed).ciphertext == null || ((!) parsed).sid <= 0 ||
                        (device > 0 && device != ((!) parsed).sid))
                    throw new IOError.PERMISSION_DENIED("Unexpected OMEMO call sender device");
                device = ((!) parsed).sid;
                // First authenticated prekeys may learn a key only under the
                // same checked blind-trust policy as ordinary OMEMO messages.
                string? before = identity_for_call(module, iq.from, device, true, true);
                if (binding != null) require_same_identity(((!) binding).identity, before);
                require_same_identity(previous_identity, before);
                string? cleartext = null;
                foreach (Bytes key in ((!) parsed).our_potential_encrypted_keys.keys) {
                    ((!) parsed).is_prekey = ((!) parsed).our_potential_encrypted_keys[key];
                    ((!) parsed).encrypted_key = key.get_data();
                    try {
                        uint8[] secret = decryptor.decrypt_key((!) parsed, iq.from.bare_jid);
                        cleartext = decryptor.decrypt(((!) parsed).ciphertext, secret, ((!) parsed).iv);
                        break;
                    } catch (Error e) { /* Another wrapper for our numeric device ID may be present. */ }
                }
                if (cleartext == null) throw new IOError.PERMISSION_DENIED("Could not decrypt OMEMO call fingerprint");
                string? after = identity_for_call(module, iq.from, device, true);
                require_same_identity(before, after);
                previous_identity = after;
                StanzaNode replacement = replacement_fingerprint(original, Xep.JingleIceUdp.DTLS_NS_URI);
                replacement.put_node(new StanzaNode.text((!) cleartext));
                rewrites.add(new FingerprintRewrite(transport, original, replacement));
                }
            }
            if (binding == null) {
                binding = new CallBinding(iq.from, device);
                calls[call_key(iq.from, sid)] = binding;
            }
            ((!) binding).identity = previous_identity;
            ((!) binding).pinned = true;
            foreach (FingerprintRewrite rewrite in rewrites) rewrite.apply();
        }

        private void on_message_received(XmppStream stream, MessageStanza message) {
            if (attached_stream != stream) return;
            StanzaNode? proceed = message.stanza.get_subnode("proceed", Xep.JingleMessageInitiation.NS_URI);
            if (proceed == null || message.from == null || message.from.resourcepart == null ||
                    !local_recipient(stream, message.to)) return;
            string? sid = ((!) proceed).get_attribute("id");
            StanzaNode? device_node = ((!) proceed).get_subnode("device", NS_URI);
            int device = device_node != null ? ((!) device_node).get_attribute_int("id", -1) : -1;
            if (sid == null || sid.length == 0 || device <= 0 || ended_calls.contains(call_key(message.from, sid))) return;
            CallBinding? existing = calls[call_key(message.from, sid)];
            if (existing != null) {
                if (((!) existing).device != device) ((!) existing).cancellable.cancel();
                return;
            }
            calls[call_key(message.from, sid)] = new CallBinding(message.from, device);
        }

        private void on_pre_send_presence_stanza(XmppStream stream, Presence.Stanza presence) {
            StanzaNode? muji = presence.stanza.get_subnode("muji", Xep.Muji.NS_URI);
            Omemo.StreamModule? module = stream.get_module<Omemo.StreamModule>(Omemo.StreamModule.IDENTITY);
            if (muji == null || module == null || ((!) module).store.local_registration_id == 0) return;
            // Monocles uses muji@device; older Dino peers use the draft child.
            // Publish the same device in both forms, including preparing state.
            ((!) muji).set_attribute("device", ((!) module).store.local_registration_id.to_string());
            foreach (StanzaNode old in ((!) muji).get_subnodes("device", NS_URI))
                ((!) muji).sub_nodes.remove(old);
            ((!) muji).put_node(new StanzaNode.build("device", NS_URI).add_self_xmlns()
                .put_attribute("id", ((!) module).store.local_registration_id.to_string()));
        }

        private static int parse_muji_device_id(string? value) {
            if (value == null || value.length == 0) return 0;
            int result = 0;
            for (int i = 0; i < value.length; i++) {
                int digit = value[i] - '0';
                if (digit < 0 || digit > 9 || result > (int.MAX - digit) / 10) return 0;
                result = result * 10 + digit;
            }
            return result;
        }

        private static int muji_device(StanzaNode muji, out bool advertised) {
            string? attribute = muji.get_attribute("device");
            Gee.List<StanzaNode> children = muji.get_subnodes("device", NS_URI);
            advertised = attribute != null || !children.is_empty;
            if (children.size > 1) return 0;
            int from_attribute = parse_muji_device_id(attribute);
            int from_child = children.size == 1 ? parse_muji_device_id(children[0].get_attribute("id")) : 0;
            // A malformed or conflicting form must not fall back to the other
            // form, nor make a supported peer appear to offer ordinary DTLS.
            if (attribute != null && from_attribute <= 0 || children.size == 1 && from_child <= 0 ||
                    attribute != null && children.size == 1 && from_attribute != from_child) return 0;
            return attribute != null ? from_attribute : from_child;
        }

        private void on_received_available(XmppStream stream, Presence.Stanza presence) {
            if (attached_stream != stream) return;
            var stale = new ArrayList<MujiDevice>();
            foreach (MujiDevice member in members.values) if (member.occupant.equals(presence.from)) stale.add(member);
            Gee.List<StanzaNode> muji_nodes = presence.stanza.get_subnodes("muji", Xep.Muji.NS_URI);
            bool advertised = muji_nodes.size > 1;
            int device = 0;
            if (muji_nodes.size == 1) device = muji_device(muji_nodes[0], out advertised);
            StanzaNode? item = presence.stanza.get_deep_subnode("http://jabber.org/protocol/muc#user:x", "http://jabber.org/protocol/muc#user:item");
            string? real = item != null ? ((!) item).get_attribute("jid") : null;
            Jid? peer = null;
            try { if (real != null) peer = new Jid((!) real); } catch (InvalidJidError e) { }
            bool valid = presence.type_ != Presence.Stanza.TYPE_UNAVAILABLE && advertised && peer != null && peer.resourcepart != null;
            foreach (MujiDevice old in stale) {
                if (valid && old.peer.equals((!) peer) && old.device == device) return;
                remove_member(old);
            }
            // Keep an invalid advertisement scoped to the authenticated room /
            // real full JID so a new SID cannot bypass it as an ordinary peer.
            if (valid) members[member_key(presence.from.bare_jid, (!) peer)] = new MujiDevice(presence.from.bare_jid, presence.from, (!) peer, device);
        }

        private void on_received_unavailable(XmppStream stream, Presence.Stanza presence) { on_received_available(stream, presence); }

        public override void attach(XmppStream stream) {
            if (attached_stream == stream) return;
            if (attached_stream != null) detach((!) attached_stream);
            attached_stream = stream; generation++;
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(on_message_received);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.connect(send_listener);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).add_outgoing_request_filter(this);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).add_incoming_request_filter(this);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).pre_send_presence_stanza.connect(on_pre_send_presence_stanza);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_available.connect(on_received_available);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_unavailable.connect(on_received_unavailable);
        }

        public override void detach(XmppStream stream) {
            // Account modules are shared across stream generations. A late old
            // detach must not unregister the replacement stream's security filters.
            if (attached_stream != stream) return;
            if (attached_stream == stream) {
                generation++; attached_stream = null;
                foreach (CallBinding binding in calls.values) binding.cancellable.cancel();
                calls.clear(); members.clear(); ended_calls.clear(); ended_order.clear();
            }
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(on_message_received);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.disconnect(send_listener);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).remove_outgoing_request_filter(this);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).remove_incoming_request_filter(this);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).pre_send_presence_stanza.disconnect(on_pre_send_presence_stanza);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_available.disconnect(on_received_available);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_unavailable.disconnect(on_received_unavailable);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }

    public class VerificationSendListener : StanzaListener<MessageStanza> {

        private string[] after_actions_const = {};

        public override string action_group { get { return "REWRITE_NODES"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        public override async bool run(XmppStream stream, MessageStanza message) {
            StanzaNode? proceed_node = message.stanza.get_subnode("proceed", Xep.JingleMessageInitiation.NS_URI);
            if (proceed_node == null) return false;

            StanzaNode device_node = new StanzaNode.build("device", NS_URI).add_self_xmlns()
                    .put_attribute("id", stream.get_module<Omemo.StreamModule>(Omemo.StreamModule.IDENTITY).store.local_registration_id.to_string());
            proceed_node.put_node(device_node);
            return false;
        }
    }

    public class OmemoContentEncryption : Xep.Jingle.ContentEncryption {
        public Jid jid { get; set; }
        public int sid { get; set; }

        public OmemoContentEncryption(string encryption_ns, string encryption_name, Jid jid, int sid) {
            base(encryption_ns, encryption_name);
            this.jid = jid;
            this.sid = sid;
        }
    }
}

