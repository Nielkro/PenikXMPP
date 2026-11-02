namespace Xmpp.DnsSecurity {

public errordomain SecurityError {
    INVALID_CONFIGURATION,
    UNAVAILABLE,
    LOOKUP_FAILED,
    BOGUS,
    REQUIRED,
    EXPIRED,
    TLSA_MISMATCH
}

/** Immutable input owned by one account connection attempt. No global cache. */
public class Configuration : Object {
    public Attempt attempt { get; private set; }
    public string? doh_uri { get; private set; }

    public Configuration(Attempt attempt, string? doh_uri = null) {
        this.attempt = attempt;
        this.doh_uri = doh_uri;
    }

    public static bool supported() {
#if HAVE_DNSSEC
        return true;
#else
        return false;
#endif
    }
}

/** A live-handshake gate; it never authorizes another socket or a later attempt. */
public class HandshakeGuard : Object {
    public Attempt attempt { get; private set; }
    public bool requires_tlsa { get; private set; }
    public bool verified { get; private set; default = false; }
    private int64 expires_at;
    private string[] reference_names;
    private GenericArray<Bytes> records;

    // The caller must provide authenticated discovery/TLSA evidence. This is
    // not a certificate-probe result; verification uses the live connection.
    public HandshakeGuard(Attempt attempt, int64 expires_at,
            string[] reference_names, GenericArray<Bytes> records, bool requires_tlsa) {
        this.attempt = attempt;
        this.expires_at = expires_at;
        this.reference_names = reference_names;
        this.records = records;
        this.requires_tlsa = requires_tlsa;
    }

    public void check_current() throws Error {
        attempt.cancellable.set_error_if_cancelled();
        if (get_monotonic_time() >= expires_at) {
            throw new SecurityError.EXPIRED("DNS evidence expired before server authentication; retry the connection");
        }
    }

    /** Copy immutable evidence for a native TLS backend on the same attempt.
     * This does not mark the GIO handshake verified. The other backend must
     * enforce the evidence on its live connection and report its own result. */
    public GenericArray<Bytes> copy_records() {
        var result = new GenericArray<Bytes>();
        for (uint i = 0; i < records.length; i++) result.add(records[i]);
        return result;
    }

    public int64 evidence_expiry { get { return expires_at; } }

    // Called after the TLS handshake, before writing any TLS application data.
    // Certificate overrides during the handshake are only provisional. A valid
    // public-CA certificate also has to pass TLSA; accept-certificate alone is
    // insufficient because GIO does not emit it for a valid PKIX certificate.
    public async bool verify_peer(TlsConnection connection) throws Error {
        check_current();
        TlsCertificate? certificate = connection.peer_certificate;
        if (certificate == null) throw new SecurityError.TLSA_MISMATCH("The TLS peer supplied no certificate");
        bool pkix_valid = connection.peer_certificate_errors == 0;
        bool needs_pkix = !requires_tlsa;
        for (uint i = 0; i < records.length; i++) {
            unowned uint8[] record = records[i].get_data();
            if (record.length >= 3 && record[0] == 1) needs_pkix = true;
        }
        if (needs_pkix && !pkix_valid && connection.database != null) {
            foreach (string name in reference_names) {
                var flags = yield connection.database.verify_chain_async(certificate,
                    TlsDatabase.PURPOSE_AUTHENTICATE_SERVER, new NetworkAddress(name, 0),
                    connection.interaction, TlsDatabaseVerifyFlags.NONE, attempt.cancellable);
                if (flags == 0) { pkix_valid = true; break; }
            }
        }
        check_current();
        if (!requires_tlsa) return pkix_valid;
#if HAVE_DNSSEC
        var chain = new GenericArray<Bytes>();
        var seen = new Gee.HashSet<TlsCertificate>();
        TlsCertificate? current = certificate;
        while (current != null) {
            if (chain.length >= 16 || !seen.add(current)) {
                throw new SecurityError.TLSA_MISMATCH("Invalid or excessive TLS certificate chain");
            }
            ByteArray der = current.certificate;
            if (der == null || der.len == 0) {
                throw new SecurityError.TLSA_MISMATCH("TLS backend did not expose the peer certificate");
            }
            chain.add(new Bytes(der.data));
            current = current.issuer;
        }
        if (!DinoDns.Native.dane_verify(records, chain, reference_names, pkix_valid, expires_at)) {
            throw new SecurityError.TLSA_MISMATCH("The server certificate does not match the DNSSEC-authenticated TLSA records");
        }
        check_current();
        verified = true;
        return true;
#else
        throw new SecurityError.UNAVAILABLE("This build has no DNSSEC/DANE support");
#endif
    }
}

/** DNS evidence for a manually selected TLS broker, without XMPP SRV rules. */
public class BrokerEndpoint : Object {
    public string address { get; private set; }
    public string hostname { get; private set; }
    public HandshakeGuard guard { get; private set; }

    public static bool is_special(string host) { return Discovery.is_special(host); }

    public static async Gee.List<BrokerEndpoint> lookup(Configuration configuration,
            string host, uint16 port, string proxy_uri) throws Error {
        Discovery? discovery = null;
        try {
            string name = Discovery.normalize_host(host);
            if (Discovery.is_special(name)) throw new SecurityError.REQUIRED("DANE does not apply to this broker address");
            discovery = new Discovery(configuration, proxy_uri);
            // A configured broker is an explicit delegation; use its actual port.
            var targets = yield discovery.targets(name, name, port);
            var addresses = yield discovery.addresses(name, targets[0]);
            var result = new Gee.ArrayList<BrokerEndpoint>();
            foreach (var endpoint in addresses) {
                result.add(new BrokerEndpoint() { address = endpoint.host, hostname = name, guard = endpoint.guard });
            }
            configuration.attempt.cancellable.set_error_if_cancelled();
            return result;
        } finally {
            if (discovery != null) discovery.close();
        }
    }
}

internal class Endpoint : Object {
    public string host;
    public uint16 port;
    public bool direct_tls;
#if HAVE_DNSSEC
    public uint16 priority;
    public uint16 weight;
    public bool authorized;
    public int64 expires_at = int64.MAX;
#endif
    public HandshakeGuard? guard;
}

/** One resolver and transport for one immutable connection attempt. */
internal class Discovery : Object {
    private Configuration configuration;
#if HAVE_DNSSEC
    private DinoDns.Native.Resolver? resolver;
    private DinoDns.DohForwarder? forwarder;
#endif

#if DNSSEC_TEST
    internal Discovery.for_resolver(Configuration configuration, DinoDns.Native.Resolver resolver) {
        this.configuration = configuration;
        this.resolver = resolver;
    }
#endif

    public Discovery(Configuration configuration, string proxy_uri) throws Error {
        this.configuration = configuration;
        configuration.attempt.cancellable.set_error_if_cancelled();
#if HAVE_DNSSEC
        try {
            string[] forwarders;
            if (configuration.doh_uri != null && configuration.doh_uri != "") {
                forwarder = new DinoDns.DohForwarder(configuration.doh_uri, proxy_uri);
                forwarders = { forwarder.forwarder_address };
            } else {
                if (proxy_uri != "direct://") {
                    throw new SecurityError.INVALID_CONFIGURATION("DNSSEC over a proxy requires an explicitly configured HTTPS DNS resolver");
                }
                forwarders = DinoDns.Native.system_forwarders();
            }
            resolver = new DinoDns.Native.Resolver(forwarders,
                DinoDns.Native.root_trust_anchors(), forwarder != null);
        } catch (Error error) {
            close();
            throw error;
        }
#else
        throw new SecurityError.UNAVAILABLE("This build has no DNSSEC/DANE support");
#endif
    }

    public void close() {
#if HAVE_DNSSEC
        if (resolver != null) resolver.close();
        if (forwarder != null) forwarder.close();
#endif
    }

    // Special-use names must not be exported to a public DNS resolver.
    public static bool is_special(string host) {
        string name = (Hostname.to_ascii(host) ?? host).ascii_down();
        if (name.has_suffix(".")) name = name.substring(0, name.length - 1);
        return new InetAddress.from_string(name) != null || !name.contains(".") ||
            name == "localhost" || name.has_suffix(".localhost") ||
            name.has_suffix(".local") || name.has_suffix(".localdomain") ||
            name.has_suffix(".lan") || name.has_suffix(".home") ||
            name.has_suffix(".internal") || name.has_suffix(".onion") ||
            name == "home.arpa" || name.has_suffix(".home.arpa");
    }

    public static string normalize_host(string host) throws SecurityError {
        string? ascii = Hostname.to_ascii(host);
        if (ascii == null || ascii.length == 0) throw new SecurityError.INVALID_CONFIGURATION("Invalid DNS hostname");
        ascii = ascii.ascii_down();
        if (ascii.has_suffix(".")) ascii = ascii.substring(0, ascii.length - 1);
        if (ascii.length > 253) throw new SecurityError.INVALID_CONFIGURATION("DNS hostname is too long");
        foreach (string label in ascii.split(".")) {
            if (label.length == 0 || label.length > 63 || label[0] == '-' || label[label.length - 1] == '-') {
                throw new SecurityError.INVALID_CONFIGURATION("Invalid DNS hostname label");
            }
            for (int i = 0; i < label.length; i++) {
                char ch = label[i];
                if (!(ch >= 'a' && ch <= 'z') && !(ch >= '0' && ch <= '9') && ch != '-') {
                    throw new SecurityError.INVALID_CONFIGURATION("Invalid character in DNS hostname");
                }
            }
        }
        return ascii;
    }

#if HAVE_DNSSEC
    private async DinoDns.Native.Answer lookup(string name, uint16 type) throws Error {
        configuration.attempt.cancellable.set_error_if_cancelled();
        var answer = yield resolver.resolve_async(name, type, 10000, configuration.attempt.cancellable);
        configuration.attempt.cancellable.set_error_if_cancelled();
        if (answer.validation == DinoDns.Native.Validation.BOGUS) {
            throw new SecurityError.BOGUS("DNSSEC validation failed for %s", name);
        }
        if (answer.expires_at <= get_monotonic_time()) {
            throw new SecurityError.EXPIRED("DNS answer expired for %s", name);
        }
        return (owned) answer;
    }

    // libunbound exposes decompressed wire-format RDATA. Reject pointers or
    // trailing data rather than interpreting them relative to another packet.
    private static string read_srv_host(uint8[] data) throws Error {
        int offset = 6;
        var host = new StringBuilder();
        while (offset < data.length) {
            uint length = data[offset++];
            if (length == 0) {
                if (offset != data.length) break;
                if (host.len == 0) return ".";
                return normalize_host(host.str);
            }
            if (length > 63 || offset + length >= data.length) break;
            if (host.len > 0) host.append_c('.');
            for (uint i = 0; i < length; i++) {
                uint8 ch = data[offset++];
                if (ch == 0 || ch >= 128) throw new SecurityError.LOOKUP_FAILED("Malformed SRV target");
                host.append_c((char) ch);
            }
        }
        throw new SecurityError.LOOKUP_FAILED("Malformed SRV response");
    }
#endif

    public async Gee.List<Endpoint> targets(string domain, string? custom_host, uint16 port) throws Error {
#if HAVE_DNSSEC
        var targets = new Gee.ArrayList<Endpoint>();
        if (custom_host != null && custom_host != "" && port > 0) {
            targets.add(new Endpoint() { host = normalize_host(custom_host), port = port, authorized = true });
            return targets;
        }
        int64 absence_expiry = int64.MAX;
        bool secure_absence = true;
        bool service_disabled = false;
        foreach (string service in new string[] { "xmpp-client", "xmpps-client" }) {
            var answer = yield lookup("_%s._tcp.%s".printf(service, domain), 33);
            bool secure = answer.validation == DinoDns.Native.Validation.SECURE;
            secure_absence = secure_absence && secure;
            absence_expiry = int64.min(absence_expiry, answer.expires_at);
            if (answer.records.length > 32) throw new SecurityError.LOOKUP_FAILED("Excessive SRV targets");
            for (uint i = 0; i < answer.records.length; i++) {
                unowned uint8[] data = answer.records[i].get_data();
                if (data.length < 7) throw new SecurityError.LOOKUP_FAILED("Truncated SRV response");
                string host = read_srv_host(data);
                if (host == ".") { service_disabled = true; continue; }
                uint16 srv_port = (uint16) ((data[4] << 8) | data[5]);
                if (srv_port == 0 || is_special(host)) throw new SecurityError.LOOKUP_FAILED("Invalid public SRV target");
                targets.add(new Endpoint() {
                    host = host, port = srv_port, direct_tls = service == "xmpps-client",
                    priority = (uint16) ((data[0] << 8) | data[1]),
                    weight = (uint16) ((data[2] << 8) | data[3]),
                    authorized = secure, expires_at = answer.expires_at
                });
            }
        }
        // Fallback only after successful no-data discovery, never after an
        // outage, bogus answer, explicit service denial, or failed SRV target.
        if (targets.size == 0 && !service_disabled) {
            targets.add(new Endpoint() { host = domain, port = 5222,
                authorized = secure_absence, expires_at = absence_expiry });
        }
        // RFC 2782 weighted selection within each priority, without preferring
        // TLSA-capable servers over another authenticated SRV endpoint.
        targets.sort((a, b) => a.priority - b.priority);
        var ordered = new Gee.ArrayList<Endpoint>();
        while (targets.size > 0) {
            uint priority = targets[0].priority;
            var group = new Gee.ArrayList<Endpoint>();
            while (targets.size > 0 && targets[0].priority == priority) {
                group.add(targets.remove_at(0));
            }
            while (group.size > 0) {
                group.sort((a, b) => (a.weight == 0 ? 0 : 1) - (b.weight == 0 ? 0 : 1));
                int total = 0;
                foreach (var endpoint in group) total += endpoint.weight;
                int draw = Random.int_range(0, total + 1);
                int selected = total == 0 ? Random.int_range(0, group.size) : 0;
                if (total != 0) {
                    int sum = 0;
                    for (int i = 0; i < group.size; i++) {
                        sum += group[i].weight;
                        if (sum >= draw) { selected = i; break; }
                    }
                }
                ordered.add(group.remove_at(selected));
            }
        }
        return ordered;
#else
        throw new SecurityError.UNAVAILABLE("This build has no DNSSEC/DANE support");
#endif
    }

    public async Gee.List<Endpoint> addresses(string domain, Endpoint target) throws Error {
#if HAVE_DNSSEC
        var endpoints = new Gee.ArrayList<Endpoint>();
        var a = yield lookup(target.host, 1);
        var aaaa = yield lookup(target.host, 28);
        // RFC 7673 section 3.2: any secure address RRset permits TLSA lookup.
        // lookup() has already rejected bogus/failed results for either family.
        bool secure = a.validation == DinoDns.Native.Validation.SECURE ||
            aaaa.validation == DinoDns.Native.Validation.SECURE;
        debug("DNSSEC endpoint: delegated=%s, A=%d, AAAA=%d", target.authorized.to_string(),
            (int) a.validation, (int) aaaa.validation);
        int64 expiry = int64.min(target.expires_at, int64.min(a.expires_at, aaaa.expires_at));
        var records = new GenericArray<Bytes>();
        bool enforce = false;
        if (target.authorized && secure) {
            var tlsa = yield lookup("_%u._tcp.%s".printf(target.port, target.host), 52);
            expiry = int64.min(expiry, tlsa.expires_at);
            if (tlsa.validation == DinoDns.Native.Validation.SECURE) {
                records = tlsa.records;
                enforce = DinoDns.Native.dane_records_usable(records);
            }
        }
        if (!enforce && configuration.attempt.mode == Mode.REQUIRED) {
            throw new SecurityError.REQUIRED("DNSSEC-authenticated, usable TLSA records are required for %s:%u", target.host, target.port);
        }
        string[] names = target.authorized ? new string[] { domain, target.host } : new string[] { domain };
        var guard = new HandshakeGuard(configuration.attempt, expiry, names, records, enforce);
        for (uint family = 0; family < 2; family++) {
            unowned GenericArray<Bytes> addresses = family == 0 ? a.records : aaaa.records;
            for (uint i = 0; i < addresses.length; i++) {
                unowned uint8[] data = addresses[i].get_data();
                if (data.length != (family == 0 ? 4 : 16)) throw new SecurityError.LOOKUP_FAILED("Malformed DNS address");
                var ip = new InetAddress.from_bytes(data, family == 0 ? SocketFamily.IPV4 : SocketFamily.IPV6);
                endpoints.add(new Endpoint() { host = ip.to_string(), port = target.port,
                    direct_tls = target.direct_tls, guard = guard });
            }
        }
        if (endpoints.size == 0) throw new SecurityError.LOOKUP_FAILED("No addresses for %s", target.host);
        return endpoints;
#else
        throw new SecurityError.UNAVAILABLE("This build has no DNSSEC/DANE support");
#endif
    }
}

}
