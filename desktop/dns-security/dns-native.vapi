[CCode (cheader_filename = "dns-resolver.h")]
namespace DinoDns.Native {
    [Compact]
    [CCode (cname = "SSL_CTX", cprefix = "dino_dane_tls_context_", free_function = "SSL_CTX_free", cheader_filename = "openssl-context.h")]
    public class TlsContext {
        public TlsContext(string hostname, GLib.GenericArray<GLib.Bytes> records,
            bool require_tlsa, int64 expires_at, GLib.Cancellable cancellable,
            string? ca_file, string? ca_directory) throws GLib.Error;
        public int result();
    }
    [CCode (cname = "DinoDnsValidation", cprefix = "DINO_DNS_", has_type_id = false)]
    public enum Validation { SECURE, INSECURE, BOGUS }

    [Compact]
    [CCode (cname = "DinoDnsAnswer", free_function = "dino_dns_answer_free")]
    public class Answer {
        public Validation validation;
        public bool nxdomain;
        public int64 expires_at;
        public string? canonical_name;
        public GLib.GenericArray<GLib.Bytes> records;
    }

    [CCode (cname = "DinoDnsResolver", cprefix = "dino_dns_resolver_", type_id = "dino_dns_resolver_get_type ()")]
    public class Resolver : GLib.Object {
        public Resolver([CCode (type = "const gchar* const*", array_length = false, array_null_terminated = true)] string[] forwarders,
                        string trust_anchors, bool tcp_only) throws GLib.Error;
        public async Answer resolve_async(string name, uint16 rrtype, uint timeout_ms,
                                          GLib.Cancellable? cancellable = null) throws GLib.Error;
        public void close();
    }

    [CCode (cname = "dino_dns_system_forwarders", array_length = false, array_null_terminated = true)]
    public string[] system_forwarders() throws GLib.Error;
    [CCode (cname = "dino_dns_root_trust_anchors")]
    public unowned string root_trust_anchors();

    [CCode (cname = "dino_dane_records_usable", cheader_filename = "dane-verifier.h")]
    public bool dane_records_usable(GLib.GenericArray<GLib.Bytes> records);
    [CCode (cname = "dino_dane_verify", cheader_filename = "dane-verifier.h")]
    public bool dane_verify(GLib.GenericArray<GLib.Bytes> records, GLib.GenericArray<GLib.Bytes> chain,
        [CCode (type = "const gchar* const*", array_length = false, array_null_terminated = true)] string[] reference_names,
        bool pkix_valid, int64 expires_at) throws GLib.Error;
}
