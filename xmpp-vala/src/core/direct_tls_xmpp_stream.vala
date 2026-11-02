public class Xmpp.DirectTlsXmppStream : TlsXmppStream {

    private const string[] ADVERTISED_PROTOCOLS = {"xmpp-client", null};

    string host;
    uint16 port;
    TlsXmppStream.OnInvalidCertWrapper on_invalid_cert;
    string proxy_type;
    string? proxy_host;
    uint16 proxy_port;
    string? proxy_user;
    string? proxy_pass;

    public DirectTlsXmppStream(Jid remote_name, string host, uint16 port, TlsXmppStream.OnInvalidCertWrapper on_invalid_cert, string proxy_type = "none", string? proxy_host = null, uint16 proxy_port = 0, string? proxy_user = null, string? proxy_pass = null) {
        base(remote_name);
        this.host = host;
        this.port = port;
        this.on_invalid_cert = on_invalid_cert;
        this.proxy_type = proxy_type;
        this.proxy_host = proxy_host;
        this.proxy_port = proxy_port;
        this.proxy_user = proxy_user;
        this.proxy_pass = proxy_pass;
    }

    public override async void connect() throws IOError {
        SocketClient client = new SocketClient();
        if (proxy_type != "none") {
            string uri = "";
            if (proxy_type == "tor") {
                string h = (proxy_host != null && proxy_host != "") ? proxy_host : "127.0.0.1";
                if (":" in h) h = "[" + h + "]";
                uint16 p = (proxy_port > 0) ? proxy_port : 9050;
                uri = "socks5://%s:%u".printf(h, p);
            } else if (proxy_type == "socks5") {
                if (proxy_host != null && proxy_host != "" && proxy_port > 0) {
                    string h = proxy_host;
                    if (":" in h) h = "[" + h + "]";
                    if (proxy_user != null && proxy_user != "") {
                        string encoded_user = Uri.escape_string(proxy_user, null, false);
                        string encoded_pass = (proxy_pass != null && proxy_pass != "") ? Uri.escape_string(proxy_pass, null, false) : "";
                        uri = "socks5://%s:%s@%s:%u".printf(encoded_user, encoded_pass, h, proxy_port);
                    } else {
                        uri = "socks5://%s:%u".printf(h, proxy_port);
                    }
                }
            }
            
            if (uri != "") {
                GLib.log("dino-proxy", GLib.LogLevelFlags.LEVEL_DEBUG, "DirectTLS: proxy socks5://%s:%u (auth=%s)", proxy_host ?? "?", proxy_port, (proxy_user != null && proxy_user != "") ? "yes" : "no");
                client.set_proxy_resolver(new SimpleProxyResolver(uri, null));
            } else {
                throw new IOError.INVALID_ARGUMENT("SOCKS5 proxy is enabled but proxy host is not configured — refusing to connect without proxy (DirectTLS)");
            }
        } else {
            client.set_proxy_resolver(new SimpleProxyResolver("direct://", null));
            GLib.log("dino-proxy", GLib.LogLevelFlags.LEVEL_DEBUG, "DirectTLS: no proxy configured; forcing direct socket");
        }

        try {
            debug("Connecting to %s:%i (tls)", host, port);
            IOStream? io_stream = yield client.connect_to_host_async(host, port, cancellable);
            debug("Connection established (DirectTLS)");
            IOStream tls_stream = GLibFixes.tls_client_connection_new(io_stream, new NetworkAddress(remote_name.to_string(), port));
            TlsConnection? tls_connection = tls_stream as TlsConnection;
            if (tls_connection == null) {
                throw new IOError.FAILED("Failed creating DirectTLS connection");
            }
#if GLIB_2_60
            tls_connection.set_advertised_protocols(ADVERTISED_PROTOCOLS);
#endif
            reset_stream(tls_connection);

            yield authenticate_tls(tls_connection, on_invalid_cert);
            check_dns_attempt();

            yield setup();

            check_dns_attempt();
            attach_negotation_modules();
        } catch (IOError e) {
            throw e;
        } catch (Error e) {
            throw new IOError.CONNECTION_REFUSED("Failed connecting to %s:%i (tls): %s", host, port, e.message);
        }
    }
}
