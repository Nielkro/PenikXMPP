namespace Xmpp.Sasl {
    private const string NS_URI = "urn:ietf:params:xml:ns:xmpp-sasl";
    private const string SASL_CB_NS_URI = "urn:xmpp:sasl-cb:0";

    public class Flag : XmppStreamFlag {
        public static FlagIdentity<Flag> IDENTITY = new FlagIdentity<Flag>(NS_URI, "sasl");
        public string mechanism;
        public string name;
        public string password;
        public string client_nonce;
        public uint8[] server_signature;
        public string gs2_header = "n,,";
        public uint8[]? channel_binding_data;
        public bool finished = false;
        public bool failed = false;
        public bool challenge_received = false;
        public string? failure_reason;
        public string? advertised_hash;
        public string? tls_version;
        public bool require_advertised_hash = false;
        // Snapshot before the post-authentication stream replaces its features.
        // Advertisement is separate from successful use of SCRAM-PLUS.
        public bool? server_offers_channel_binding = null;

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }

    namespace Mechanism {
        public const string PLAIN = "PLAIN";
        public const string SCRAM_SHA_1 = "SCRAM-SHA-1";
        public const string SCRAM_SHA_1_PLUS = "SCRAM-SHA-1-PLUS";
        public const string SCRAM_SHA_256 = "SCRAM-SHA-256";
        public const string SCRAM_SHA_256_PLUS = "SCRAM-SHA-256-PLUS";
        public const string SCRAM_SHA_512 = "SCRAM-SHA-512";
        public const string SCRAM_SHA_512_PLUS = "SCRAM-SHA-512-PLUS";
    }

    public delegate bool PersistScramFunc();

    public class Module : XmppStreamNegotiationModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "sasl");

        public string name { get; set; }
        public string password { get; set; }
        public bool require_channel_binding { get; set; default = false; }
        public bool allow_plain { get; set; default = false; }
        public bool scram_seen { get; set; default = false; }
        public bool use_full_name = false;
        public PersistScramFunc? persist_scram;

        public signal void received_auth_failure(XmppStream stream, StanzaNode node);
        public signal void channel_binding_failed(XmppStream stream);
        // Emitted only after verifying the server's SCRAM proof.
        public signal void scram_authenticated(XmppStream stream);

        public Module(string name, string password) {
            this.name = name;
            this.password = password;
        }

        public override void attach(XmppStream stream) {
            stream.received_features_node.connect(this.received_features_node);
            stream.received_nonza.connect(this.received_nonza);
        }

        public override void detach(XmppStream stream) {
            stream.received_features_node.disconnect(this.received_features_node);
            stream.received_nonza.disconnect(this.received_nonza);
        }

        private static size_t SHA1_SIZE = 20;

        private static uint8[] sha1(uint8[] data) {
            Checksum checksum = new Checksum(ChecksumType.SHA1);
            checksum.update(data, data.length);
            uint8[] res = new uint8[SHA1_SIZE];
            checksum.get_digest(res, ref SHA1_SIZE);
            return res;
        }

        private static uint8[] hmac_sha1(uint8[] key, uint8[] data) {
            Hmac hmac = new Hmac(ChecksumType.SHA1, key);
            hmac.update(data);
            uint8[] res = new uint8[SHA1_SIZE];
            hmac.get_digest(res, ref SHA1_SIZE);
            return res;
        }

        private static uint8[] pbkdf2_sha1(string password, uint8[] salt, uint iterations) {
            uint8[] res = new uint8[SHA1_SIZE];
            uint8[] last = new uint8[salt.length + 4];
            for(int i = 0; i < salt.length; i++) {
                last[i] = salt[i];
            }
            last[salt.length + 3] = 1;
            for(int i = 0; i < iterations; i++) {
                last = hmac_sha1((uint8[]) password.to_utf8(), last);
                xor_inplace(res, last);
            }
            return res;
        }

        private static size_t SHA256_SIZE = 32;

        private static uint8[] sha256(uint8[] data) {
            Checksum checksum = new Checksum(ChecksumType.SHA256);
            checksum.update(data, data.length);
            uint8[] res = new uint8[SHA256_SIZE];
            checksum.get_digest(res, ref SHA256_SIZE);
            return res;
        }

        private static uint8[] hmac_sha256(uint8[] key, uint8[] data) {
            Hmac hmac = new Hmac(ChecksumType.SHA256, key);
            hmac.update(data);
            uint8[] res = new uint8[SHA256_SIZE];
            hmac.get_digest(res, ref SHA256_SIZE);
            return res;
        }

        private static uint8[] pbkdf2_sha256(string password, uint8[] salt, uint iterations) {
            uint8[] res = new uint8[SHA256_SIZE];
            uint8[] last = new uint8[salt.length + 4];
            for(int i = 0; i < salt.length; i++) {
                last[i] = salt[i];
            }
            last[salt.length + 3] = 1;
            for(int i = 0; i < iterations; i++) {
                last = hmac_sha256((uint8[]) password.to_utf8(), last);
                xor_inplace(res, last);
            }
            return res;
        }

        private static size_t SHA512_SIZE = 64;

        private static uint8[] sha512(uint8[] data) {
            Checksum checksum = new Checksum(ChecksumType.SHA512);
            checksum.update(data, data.length);
            uint8[] res = new uint8[SHA512_SIZE];
            checksum.get_digest(res, ref SHA512_SIZE);
            return res;
        }

        private static uint8[] hmac_sha512(uint8[] key, uint8[] data) {
            Hmac hmac = new Hmac(ChecksumType.SHA512, key);
            hmac.update(data);
            uint8[] res = new uint8[SHA512_SIZE];
            hmac.get_digest(res, ref SHA512_SIZE);
            return res;
        }

        private static uint8[] pbkdf2_sha512(string password, uint8[] salt, uint iterations) {
            uint8[] res = new uint8[SHA512_SIZE];
            uint8[] last = new uint8[salt.length + 4];
            for(int i = 0; i < salt.length; i++) {
                last[i] = salt[i];
            }
            last[salt.length + 3] = 1;
            for(int i = 0; i < iterations; i++) {
                last = hmac_sha512((uint8[]) password.to_utf8(), last);
                xor_inplace(res, last);
            }
            return res;
        }

        // Dispatch helpers for multi-algorithm SCRAM
        private static uint8[] scram_hash(string mechanism, uint8[] data) {
            if (mechanism == Mechanism.SCRAM_SHA_512 || mechanism == Mechanism.SCRAM_SHA_512_PLUS) return sha512(data);
            if (mechanism == Mechanism.SCRAM_SHA_256 || mechanism == Mechanism.SCRAM_SHA_256_PLUS) return sha256(data);
            return sha1(data);
        }

        private static uint8[] scram_hmac(string mechanism, uint8[] key, uint8[] data) {
            if (mechanism == Mechanism.SCRAM_SHA_512 || mechanism == Mechanism.SCRAM_SHA_512_PLUS) return hmac_sha512(key, data);
            if (mechanism == Mechanism.SCRAM_SHA_256 || mechanism == Mechanism.SCRAM_SHA_256_PLUS) return hmac_sha256(key, data);
            return hmac_sha1(key, data);
        }

        private static uint8[] scram_pbkdf2(string mechanism, string password, uint8[] salt, uint iterations) {
            if (mechanism == Mechanism.SCRAM_SHA_512 || mechanism == Mechanism.SCRAM_SHA_512_PLUS) return pbkdf2_sha512(password, salt, iterations);
            if (mechanism == Mechanism.SCRAM_SHA_256 || mechanism == Mechanism.SCRAM_SHA_256_PLUS) return pbkdf2_sha256(password, salt, iterations);
            return pbkdf2_sha1(password, salt, iterations);
        }

        private static bool is_scram(string mechanism) {
            return mechanism == Mechanism.SCRAM_SHA_1 || mechanism == Mechanism.SCRAM_SHA_1_PLUS ||
                   mechanism == Mechanism.SCRAM_SHA_256 || mechanism == Mechanism.SCRAM_SHA_256_PLUS ||
                   mechanism == Mechanism.SCRAM_SHA_512 || mechanism == Mechanism.SCRAM_SHA_512_PLUS;
        }

        private static bool is_scram_plus(string mechanism) {
            return mechanism == Mechanism.SCRAM_SHA_1_PLUS ||
                   mechanism == Mechanism.SCRAM_SHA_256_PLUS ||
                   mechanism == Mechanism.SCRAM_SHA_512_PLUS;
        }

        public static bool has_channel_binding_feature(StanzaNode features) {
            return features.get_subnode("sasl-channel-binding", SASL_CB_NS_URI) != null;
        }

        public static Gee.List<string> get_advertised_channel_binding_types(StanzaNode features) {
            Gee.List<string> ret = new Gee.ArrayList<string>();
            StanzaNode? feature = features.get_subnode("sasl-channel-binding", SASL_CB_NS_URI);
            if (feature == null) return ret;

            foreach (StanzaNode node in ((!)feature).get_subnodes("channel-binding", SASL_CB_NS_URI)) {
                string? type = node.get_attribute("type", SASL_CB_NS_URI);
                if (type != null && type.strip() != "" && !ret.contains(type.strip())) {
                    ret.add(type.strip());
                }
            }
            return ret;
        }

        public static string? choose_channel_binding_type(Gee.List<string> advertised_types, bool feature_advertised, Gee.List<string> available_types) {
            if (!feature_advertised) {
                return null;
            }
            if (available_types.contains("tls-exporter") && advertised_types.contains("tls-exporter")) {
                return "tls-exporter";
            }
            if (available_types.contains("tls-server-end-point") && advertised_types.contains("tls-server-end-point")) {
                return "tls-server-end-point";
            }
            return null;
        }

        public static string choose_gs2_header(string mechanism, string? cb_type, bool channel_binding_possible, bool server_offers_scram_plus) {
            if (is_scram_plus(mechanism)) {
                return cb_type != null ? @"p=$cb_type,," : "n,,";
            }
            return channel_binding_possible && !server_offers_scram_plus ? "y,," : "n,,";
        }

        public static string escape_scram_username(string name) {
            return name.replace("=", "=3D").replace(",", "=2C");
        }

        private static bool has_scram_plus(string[] supported_mechanisms) {
            return Mechanism.SCRAM_SHA_512_PLUS in supported_mechanisms ||
                   Mechanism.SCRAM_SHA_256_PLUS in supported_mechanisms ||
                   Mechanism.SCRAM_SHA_1_PLUS in supported_mechanisms;
        }

        private static string? choose_scram_plus_mechanism(string[] supported_mechanisms) {
            if (Mechanism.SCRAM_SHA_512_PLUS in supported_mechanisms) return Mechanism.SCRAM_SHA_512_PLUS;
            if (Mechanism.SCRAM_SHA_256_PLUS in supported_mechanisms) return Mechanism.SCRAM_SHA_256_PLUS;
            if (Mechanism.SCRAM_SHA_1_PLUS in supported_mechanisms) return Mechanism.SCRAM_SHA_1_PLUS;
            return null;
        }

        private static string? choose_scram_mechanism(string[] supported_mechanisms) {
            if (Mechanism.SCRAM_SHA_512 in supported_mechanisms) return Mechanism.SCRAM_SHA_512;
            if (Mechanism.SCRAM_SHA_256 in supported_mechanisms) return Mechanism.SCRAM_SHA_256;
            if (Mechanism.SCRAM_SHA_1 in supported_mechanisms) return Mechanism.SCRAM_SHA_1;
            return null;
        }

        private static void xor_inplace(uint8[] mix, uint8[] a2) {
            for(int i = 0; i < mix.length; i++) {
                mix[i] = mix[i] ^ a2[i];
            }
        }

        private static uint8[] xor(uint8[] a1, uint8[] a2) {
            uint8[] mix = new uint8[a1.length];
            for(int i = 0; i < a1.length; i++) {
                mix[i] = a1[i] ^ a2[i];
            }
            return mix;
        }

        private static string generate_csprng_nonce() {
            uint8[] nonce_bytes = new uint8[24];
            GCrypt.Random.randomize(nonce_bytes, GCrypt.Random.Level.VERY_STRONG);
            return Base64.encode(nonce_bytes);
        }

        // XEP-0474: include every advertised mechanism, including unknown ones.
        // strcmp is bytewise (i;octet), unlike locale-sensitive collation.
        public static string downgrade_hash(string mechanism, string[] mechanisms,
                bool cb_advertised, string[] cb_types) {
            var sorted = new Gee.ArrayList<string>();
            foreach (string item in mechanisms) sorted.add(item);
            sorted.sort((a, b) => strcmp(a, b));
            string input = string.joinv("\x1e", sorted.to_array());
            if (cb_advertised) {
                sorted.clear();
                foreach (string item in cb_types) sorted.add(item);
                sorted.sort((a, b) => strcmp(a, b));
                input += "\x1f" + string.joinv("\x1e", sorted.to_array());
            }
            return Base64.encode(scram_hash(mechanism, input.data));
        }

        private Flag create_flag(XmppStream stream) {
            var flag = new Flag();
            var mechanisms = stream.features.get_subnode("mechanisms", NS_URI);
            if (mechanisms != null) {
                string[] offered = {};
                foreach (var mechanism in mechanisms.get_subnodes("mechanism", NS_URI)) {
                    offered += mechanism.get_string_content();
                }
                flag.server_offers_channel_binding = has_scram_plus(offered);
            }
            return flag;
        }

        private void reject(XmppStream stream, string reason) {
            Flag? flag = stream.get_flag(Flag.IDENTITY);
            if (flag == null) {
                flag = create_flag(stream);
                stream.add_flag(flag);
            }
            if (flag.failed || flag.finished) return;
            flag.failed = true;
            flag.failure_reason = reason;
            flag.password = null;
            flag.server_signature = null;
            // Stop the transport before callbacks can retry or write a closing tag.
            if (stream is IoXmppStream) ((IoXmppStream) stream).abort_connection();
            received_auth_failure(stream, new StanzaNode.build("failure", NS_URI));
        }

        private static uint8[]? decode_base64(string? encoded) {
            if (encoded == null || encoded == "" || encoded.length > 32768) return null;
            uint8[] decoded = Base64.decode(encoded);
            if (Base64.encode(decoded) != encoded) return null;
            return decoded;
        }

        private static Gee.Map<string, string>? read_attributes(string? encoded, out string text) {
            text = "";
            uint8[]? bytes = decode_base64(encoded);
            if (bytes == null || bytes.length > 16384) return null;
            // SCRAM server messages are ASCII; reject embedded NUL and controls.
            foreach (uint8 c in bytes) if (c < 0x21 || c > 0x7e) return null;
            text = (string) bytes;
            var attributes = new Gee.HashMap<string, string>();
            foreach (string part in text.split(",")) {
                if (part.length < 3 || part[1] != '=' ||
                    !((part[0] >= 'a' && part[0] <= 'z') || (part[0] >= 'A' && part[0] <= 'Z'))) return null;
                string key = part.substring(0, 1);
                if (key == "m" || attributes.has_key(key)) return null;
                attributes[key] = part.substring(2);
            }
            return attributes;
        }

        public void received_nonza(XmppStream stream, StanzaNode node) {
            if (node.ns_uri != NS_URI) return;
            Flag? flag = stream.get_flag(Flag.IDENTITY);
            if (flag == null || flag.failed || flag.finished) return;
            if (node.name == "failure") {
                flag.failed = true;
                flag.password = null;
                received_auth_failure(stream, node);
                return;
            }
            if (node.name == "success") {
                if (is_scram(flag.mechanism)) {
                    string text;
                    var attrs = read_attributes(node.get_string_content(), out text);
                    uint8[]? signature = attrs != null ? decode_base64(attrs["v"]) : null;
                    if (!flag.challenge_received || signature == null || attrs.has_key("e") ||
                        flag.server_signature == null || signature.length != flag.server_signature.length) {
                        reject(stream, "invalid-scram-proof");
                        return;
                    }
                    uint8 difference = 0;
                    for (int i = 0; i < signature.length; i++) difference |= signature[i] ^ flag.server_signature[i];
                    if (difference != 0) {
                        reject(stream, "invalid-scram-proof");
                        return;
                    }
                    if (persist_scram != null && !persist_scram()) {
                        reject(stream, "scram-pin-storage-failed");
                        return;
                    }
                    scram_seen = true;
                    scram_authenticated(stream);
                }
                stream.require_setup();
                flag.password = null;
                flag.finished = true;
                debug("SASL: Authenticated via %s at %s", flag.mechanism, stream.remote_name.to_string());
                return;
            }
            if (node.name != "challenge") return;
            if (!is_scram(flag.mechanism) || flag.challenge_received) {
                reject(stream, "invalid-scram-challenge");
                return;
            }
            string challenge;
            var attributes = read_attributes(node.get_string_content(), out challenge);
            if (attributes == null) {
                reject(stream, "invalid-scram-challenge");
                return;
            }
            string? server_nonce = attributes["r"];
            string? iteration_text = attributes["i"];
            uint8[]? salt = decode_base64(attributes["s"]);
            uint64 iterations = 0;
            if (server_nonce == null || !server_nonce.has_prefix(flag.client_nonce) ||
                server_nonce.length <= flag.client_nonce.length || salt == null ||
                iteration_text == null || !uint64.try_parse(iteration_text, out iterations) ||
                iterations.to_string() != iteration_text || iterations < 4096 || iterations > 1000000) {
                reject(stream, "invalid-scram-challenge");
                return;
            }
            string? hash = attributes["h"];
            if ((hash != null && hash != flag.advertised_hash) ||
                (hash == null && flag.require_advertised_hash)) {
                reject(stream, "sasl-downgrade-detected");
                return;
            }
            string? tls_version = attributes["t"];
            if (tls_version != null && (flag.tls_version == null || tls_version != flag.tls_version)) {
                reject(stream, "tls-version-mismatch");
                return;
            }
            // Do not rewrite the challenge: h/t and unknown optional attributes
            // must remain part of the password-authenticated SCRAM transcript.
            flag.challenge_received = true;
            uint8[] gs2_bytes = flag.gs2_header.data;
            uint8[] cb_input = new uint8[gs2_bytes.length + (flag.channel_binding_data != null ? flag.channel_binding_data.length : 0)];
            for (int i = 0; i < gs2_bytes.length; i++) cb_input[i] = gs2_bytes[i];
            if (flag.channel_binding_data != null) {
                for (int i = 0; i < flag.channel_binding_data.length; i++) cb_input[gs2_bytes.length + i] = flag.channel_binding_data[i];
            }
            string c_value = Base64.encode(cb_input);
            string client_final_message_bare = @"c=$c_value,r=$server_nonce";
            uint8[] salted_password = scram_pbkdf2(flag.mechanism, flag.password, salt, (uint) iterations);
            uint8[] client_key = scram_hmac(flag.mechanism, salted_password, "Client Key".data);
            uint8[] stored_key = scram_hash(flag.mechanism, client_key);
            string auth_message = @"n=$(flag.name),r=$(flag.client_nonce),$challenge,$client_final_message_bare";
            uint8[] client_signature = scram_hmac(flag.mechanism, stored_key, auth_message.data);
            uint8[] client_proof = xor(client_key, client_signature);
            uint8[] server_key = scram_hmac(flag.mechanism, salted_password, "Server Key".data);
            flag.server_signature = scram_hmac(flag.mechanism, server_key, auth_message.data);
            string client_final_message = @"$client_final_message_bare,p=$(Base64.encode(client_proof))";
            stream.write_node(new StanzaNode.build("response", NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.text(Base64.encode(client_final_message.data))));
        }

        public void received_features_node(XmppStream stream) {
            if (stream.has_flag(Flag.IDENTITY)) return;
            if (stream.is_setup_needed()) return;

            var mechanisms = stream.features.get_subnode("mechanisms", NS_URI);
            if (mechanisms == null) return;
            string[] supported_mechanisms = {};
            foreach (var mechanism in mechanisms.sub_nodes) {
                if (mechanism.name != "mechanism" || mechanism.ns_uri != NS_URI) continue;
                supported_mechanisms += mechanism.get_string_content();
            }
            if (!name.contains("@")) {
                name = "%s@%s".printf(name, stream.remote_name.to_string());
            }
            if (!use_full_name && name.contains("@")) {
                var split = name.split("@");
                if (split[1] == stream.remote_name.to_string()) {
                    name = split[0];
                } else {
                    use_full_name = true;
                }
            }
            string name = this.name;
            if (!use_full_name && name.contains("@")) {
                var split = name.split("@");
                if (split[1] == stream.remote_name.to_string()) {
                    name = split[0];
                }
            }
            bool cb_feature_advertised = has_channel_binding_feature(stream.features);
            Gee.List<string> advertised_cb_types = get_advertised_channel_binding_types(stream.features);
            Gee.List<string> available_cb_types = new Gee.ArrayList<string>();
            uint8[]? cb_data = null;
            string? cb_type = null;
#if GLIB_2_66
            if (stream is TlsXmppStream) {
                string? probe_type = null;
#if GLIB_2_74
                if (((TlsXmppStream) stream).get_channel_binding_data_for_type("tls-exporter", out probe_type) != null) {
                    available_cb_types.add("tls-exporter");
                }
#endif
                if (((TlsXmppStream) stream).get_channel_binding_data_for_type("tls-server-end-point", out probe_type) != null) {
                    available_cb_types.add("tls-server-end-point");
                }
                cb_type = choose_channel_binding_type(advertised_cb_types, cb_feature_advertised, available_cb_types);
                if (cb_type != null) {
                    string? actual_cb_type = null;
                    cb_data = ((TlsXmppStream) stream).get_channel_binding_data_for_type(cb_type, out actual_cb_type);
                    if (actual_cb_type != cb_type) {
                        cb_data = null;
                    }
                }
            }
#endif
            bool channel_binding_possible = available_cb_types.size > 0;
            bool server_offers_scram_plus = has_scram_plus(supported_mechanisms);

            debug("SASL: Server offers: %s | Channel binding: %s (%s) | XEP-0440: %s | Downgrade protection: %s",
                string.joinv(", ", supported_mechanisms),
                cb_data != null ? "available" : "unavailable",
                cb_type ?? "none",
                cb_feature_advertised ? string.joinv(", ", advertised_cb_types.to_array()) : "not advertised",
                require_channel_binding ? "ON" : "off");

            bool require_hash = false;
            string? scram_mechanism = null;
            if (cb_data != null) {
                scram_mechanism = choose_scram_plus_mechanism(supported_mechanisms);
                if (scram_mechanism == null && !require_channel_binding) {
                    scram_mechanism = choose_scram_mechanism(supported_mechanisms);
                }
            } else if (!require_channel_binding) {
                if (cb_feature_advertised && server_offers_scram_plus) {
                    // XEP-0474 rule 6: bare SCRAM is safe only if the server
                    // proves the advertised lists in its first challenge.
                    require_hash = true;
                }
                scram_mechanism = choose_scram_mechanism(supported_mechanisms);
            }
            if (scram_mechanism != null) {
                debug("SASL: Selected %s for %s", scram_mechanism, stream.remote_name.to_string());
                string normalized_password = password.normalize(-1, NormalizeMode.NFKC);
                string client_nonce = generate_csprng_nonce();
                string scram_name = escape_scram_username(name);
                // GS2 header: "p=<cb_type>,," for -PLUS, "y,," when we
                // support channel binding but did not receive a usable -PLUS
                // mechanism, and "n,," only when channel binding is unavailable.
                string gs2_header = choose_gs2_header(scram_mechanism, cb_type, channel_binding_possible, server_offers_scram_plus);
                string initial_message = @"n=$scram_name,r=$client_nonce";
                stream.write_node(new StanzaNode.build("auth", NS_URI).add_self_xmlns()
                        .put_attribute("mechanism", scram_mechanism)
                        .put_node(new StanzaNode.text(Base64.encode((uchar[]) (gs2_header+initial_message).to_utf8()))));
                var flag = create_flag(stream);
                flag.mechanism = scram_mechanism;
                flag.name = scram_name;
                flag.password = normalized_password;
                flag.client_nonce = client_nonce;
                flag.gs2_header = gs2_header;
                string[] hash_cb_types = {};
                var cb_feature = stream.features.get_subnode("sasl-channel-binding", SASL_CB_NS_URI);
                if (cb_feature != null) {
                    foreach (var child in cb_feature.get_subnodes("channel-binding", SASL_CB_NS_URI)) {
                        string? type = child.get_attribute("type");
                        if (type != null) hash_cb_types += type;
                    }
                }
                flag.advertised_hash = downgrade_hash(scram_mechanism, supported_mechanisms, cb_feature_advertised, hash_cb_types);
                flag.require_advertised_hash = require_hash;
                flag.tls_version = (stream is TlsXmppStream) ? ((TlsXmppStream) stream).get_tls_version_hex() : null;
                if (is_scram_plus(scram_mechanism)) {
                    flag.channel_binding_data = cb_data;
                }
                stream.add_flag(flag);
            } else if (require_channel_binding || require_hash) {
                reject(stream, "channel-binding-required");
                return;
            } else if (Mechanism.PLAIN in supported_mechanisms) {
                if (scram_seen) {
                    reject(stream, "plain-downgrade-blocked");
                    return;
                }
                if (!allow_plain) {
                    reject(stream, "plain-disabled");
                    return;
                }
                if (!(stream is TlsXmppStream) || !((TlsXmppStream) stream).has_tls_transport()) {
                    reject(stream, "plain-requires-tls");
                    return;
                }
                stream.write_node(new StanzaNode.build("auth", NS_URI).add_self_xmlns()
                                    .put_attribute("mechanism", Mechanism.PLAIN)
                                    .put_node(new StanzaNode.text(Base64.encode(get_plain_bytes(name, password)))));
                var flag = create_flag(stream);
                flag.mechanism = Mechanism.PLAIN;
                flag.name = name;
                stream.add_flag(flag);
            } else {
                reject(stream, "no-supported-mechanism");
                return;
            }
        }

        private static uchar[] get_plain_bytes(string name_s, string password_s) {
            var name = name_s.to_utf8();
            var password = password_s.to_utf8();
            uchar[] res = new uchar[name.length + password.length + 2];
            res[0] = 0;
            res[name.length + 1] = 0;
            for(int i = 0; i < name.length; i++) { res[i + 1] = (uchar) name[i]; }
            for(int i = 0; i < password.length; i++) { res[i + name.length + 2] = (uchar) password[i]; }
            return res;
        }

        public override bool mandatory_outstanding(XmppStream stream) {
            return !stream.has_flag(Flag.IDENTITY) || !stream.get_flag(Flag.IDENTITY).finished;
        }

        public override bool negotiation_active(XmppStream stream) {
            return stream.has_flag(Flag.IDENTITY) && !stream.get_flag(Flag.IDENTITY).finished;
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }
}
