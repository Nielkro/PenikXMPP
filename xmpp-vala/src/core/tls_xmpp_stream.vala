public abstract class Xmpp.TlsXmppStream : IoXmppStream {

    public TlsCertificateFlags? errors;
    public TlsCertificate? peer_certificate;
    public DnsSecurity.HandshakeGuard? dns_security { get; set; }
    public Error? dns_security_error { get; private set; }

    internal bool cancel_on_deadline() {
        cancel();
        return Source.CONTINUE; // The connection owner removes its timer in finally.
    }

    protected async void authenticate_tls(TlsConnection connection,
            OnInvalidCertWrapper on_invalid_cert) throws Error {
        if (dns_security == null) {
            connection.accept_certificate.connect(on_invalid_certificate);
            connection.accept_certificate.connect((cert, flags) => on_invalid_cert.func(cert, flags));
            // Complete the handshake before exposing the stream to XMPP.
            yield connection.handshake_async(Priority.DEFAULT, cancellable);
            return;
        }

        // Allow the handshake to obtain the actual chain, but do not send any
        // application bytes until the independent gate below succeeds. Never
        // invoke the user's pin exception for a TLSA-authenticated endpoint.
        ulong provisional = connection.accept_certificate.connect(() => true);
        try {
            dns_security.check_current();
            yield connection.handshake_async(Priority.DEFAULT, cancellable);
            bool accepted = yield dns_security.verify_peer(connection);
            cancellable.set_error_if_cancelled();
            dns_security.check_current();
            if (!accepted) {
                on_invalid_certificate(connection.peer_certificate, connection.peer_certificate_errors);
                if (!on_invalid_cert.func(connection.peer_certificate, connection.peer_certificate_errors)) {
                    throw new TlsError.BAD_CERTIFICATE("The server certificate was rejected");
                }
            }
        } catch (Error error) {
            if (dns_security.requires_tlsa || error is DnsSecurity.SecurityError) {
                dns_security_error = error;
                // A failed DANE gate must not offer the ordinary pin dialog.
                errors = null;
                peer_certificate = null;
            }
            throw error;
        } finally {
            connection.disconnect(provisional);
        }
    }

    protected void check_dns_attempt() throws IOError {
        if (dns_security == null) return;
        try {
            cancellable.set_error_if_cancelled();
            dns_security.check_current();
        } catch (Error error) {
            dns_security_error = error;
            throw new IOError.PERMISSION_DENIED("%s", error.message);
        }
    }

    public delegate bool OnInvalidCert(GLib.TlsCertificate peer_cert, GLib.TlsCertificateFlags errors);
    public class OnInvalidCertWrapper {
        public OnInvalidCert func;
        public OnInvalidCertWrapper(owned OnInvalidCert func) {
            this.func = (owned) func;
        }
    }

    protected TlsXmppStream(Jid remote_name) {
        base(remote_name);
    }

    /**
     * Get the TLS peer certificate from the active connection.
     * Works for both successful (CA-signed) and pinned connections.
     */
    public TlsCertificate? get_tls_peer_certificate() {
        // First check if we stored a cert from on_invalid_certificate
        if (peer_certificate != null) return peer_certificate;
        // Otherwise get it from the live TLS connection
        IOStream? io_stream = get_stream();
        if (io_stream != null && io_stream is TlsConnection) {
            return ((TlsConnection) io_stream).peer_certificate;
        }
        return null;
    }

    // The negotiated protocol, never the configured minimum or a server claim.
    // GIO exposes this on Linux and Windows with the same API.
    public string? get_tls_version_hex() {
#if GLIB_2_70
        var connection = get_stream() as TlsConnection;
        if (connection == null) return null;
        switch (connection.protocol_version) {
            case TlsProtocolVersion.TLS_1_0: return "0301";
            case TlsProtocolVersion.TLS_1_1: return "0302";
            case TlsProtocolVersion.TLS_1_2: return "0303";
            case TlsProtocolVersion.TLS_1_3: return "0304";
            default: return null;
        }
#else
        return null;
#endif
    }

    public bool has_tls_transport() {
        return get_stream() is TlsConnection;
    }

#if GLIB_2_66
    /**
     * Get TLS channel binding data for SCRAM-*-PLUS authentication.
     * Returns null if channel binding is not available.
     *
     * Preference: tls-exporter (RFC 9266, GLib 2.74+) > tls-server-end-point (RFC 5929)
     * tls-unique is NOT supported because it is broken with TLS 1.3.
     */
    public uint8[]? get_channel_binding_data(out string? cb_type) {
        cb_type = null;
#if GLIB_2_74
        uint8[]? exporter = get_channel_binding_data_for_type("tls-exporter", out cb_type);
        if (exporter != null) return exporter;
#endif
        return get_channel_binding_data_for_type("tls-server-end-point", out cb_type);
    }

    public uint8[]? get_channel_binding_data_for_type(string requested_type, out string? cb_type) {
        cb_type = null;
        IOStream? io_stream = get_stream();
        if (io_stream == null || !(io_stream is TlsConnection)) return null;
        TlsConnection tls_conn = (TlsConnection) io_stream;

#if GLIB_2_74
        if (requested_type == "tls-exporter") {
            // RFC 9266: works with TLS 1.2 and TLS 1.3.
            try {
                var data = new ByteArray();
                if (GLibFixes.tls_get_channel_binding(tls_conn, TlsChannelBindingType.EXPORTER, data)) {
                    cb_type = "tls-exporter";
                    uint8[] result = new uint8[data.len];
                    for (uint i = 0; i < data.len; i++) result[i] = data.data[i];
                    return result;
                }
            } catch (Error e) {
                warning("Channel binding (tls-exporter) failed: %s", e.message);
            }
            return null;
        }
#endif

        if (requested_type == "tls-server-end-point") {
            // RFC 5929: hash of the server certificate.
            try {
                var data = new ByteArray();
                if (GLibFixes.tls_get_channel_binding(tls_conn, TlsChannelBindingType.SERVER_END_POINT, data)) {
                    cb_type = "tls-server-end-point";
                    uint8[] result = new uint8[data.len];
                    for (uint i = 0; i < data.len; i++) result[i] = data.data[i];
                    return result;
                }
            } catch (Error e) {
                warning("Channel binding (tls-server-end-point) failed: %s", e.message);
            }
        }

        return null;
    }
#endif

    protected bool on_invalid_certificate(TlsCertificate peer_cert, TlsCertificateFlags errors) {
        this.errors = errors;
        this.peer_certificate = peer_cert;

        string error_str = "";
        foreach (var f in new TlsCertificateFlags[]{TlsCertificateFlags.UNKNOWN_CA, TlsCertificateFlags.BAD_IDENTITY,
            TlsCertificateFlags.NOT_ACTIVATED, TlsCertificateFlags.EXPIRED, TlsCertificateFlags.REVOKED,
            TlsCertificateFlags.INSECURE, TlsCertificateFlags.GENERIC_ERROR, TlsCertificateFlags.VALIDATE_ALL}) {
            if (f in errors) {
                error_str += @"$(f), ";
            }
        }
        warning(@"[%p, %s] Tls Certificate Errors: %s", this, this.remote_name.to_string(), error_str);
        return false;
    }
}
