namespace DinoDns {

/** Private DNS/TCP -> DNS/HTTPS adapter for one account's validation attempt.
 * libunbound must be configured with ONLY forwarder_address, tcp_only=true.
 * All queries, including DNSKEY and DS, then follow the same HTTPS/proxy route.
 * No proxy autodetection, redirects, HTTP downgrade or alternate DNS service.
 */
public class DohForwarder : Object {
    public string forwarder_address { get; private set; }

    private SocketService listener;
    private Soup.Session session;
    private string endpoint;
    private bool socks_route;
    private Cancellable lifetime = new Cancellable();
    private ulong incoming_handler;
    private uint connections;
    private uint queries;
    private MainContext context;

    private static void advertise_socks_protocols(SocketClientEvent event, IOStream? stream) {
        // Early network events may have no stream (older Soup VAPIs omit
        // nullable). The TLS event runs before libsoup starts the handshake.
        var tls = stream as TlsConnection;
        if (event == SocketClientEvent.TLS_HANDSHAKING && tls != null) {
            // The property copies the same ALPN list without the older Vala
            // method binding's char** / const char* const* mismatch on MinGW.
            tls.advertised_protocols = { "h2", "http/1.1" };
        }
    }

    public DohForwarder(string endpoint, string proxy_uri) throws Error {
        var uri = Uri.parse(endpoint, UriFlags.NONE);
        if (uri.get_scheme() != "https" || uri.get_host() == null ||
                uri.get_userinfo() != null || uri.get_fragment() != null) {
            throw new IOError.INVALID_ARGUMENT("DNS-over-HTTPS requires an HTTPS resolver URL without credentials or a fragment");
        }
        if (proxy_uri != "direct://") {
            var proxy = Uri.parse(proxy_uri, UriFlags.NONE);
            if (proxy.get_scheme() != "socks5" || proxy.get_host() == null ||
                    new InetAddress.from_string(proxy.get_host()) == null ||
                    proxy.get_port() <= 0 || proxy.get_port() > 65535 ||
                    proxy.get_query() != null || proxy.get_fragment() != null ||
                    (proxy.get_path() != "" && proxy.get_path() != "/")) {
                // A numeric proxy endpoint avoids a local DNS bootstrap query.
                throw new IOError.INVALID_ARGUMENT("DNS validation requires a numeric SOCKS5 proxy address and port");
            }
        }
        this.endpoint = endpoint;
        socks_route = proxy_uri != "direct://";
        context = MainContext.ref_thread_default();
        session = (Soup.Session) Object.new(typeof(Soup.Session), "max-conns", 4, "max-conns-per-host", 4);
        session.proxy_resolver = new SimpleProxyResolver(proxy_uri, null);
        session.timeout = 15;
        session.idle_timeout = 5;
        listener = new SocketService();
        listener.stop();
        SocketAddress effective;
        listener.add_address(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0),
                             SocketType.STREAM, SocketProtocol.TCP, null, out effective);
        forwarder_address = "127.0.0.1@%u".printf(((InetSocketAddress) effective).port);
        incoming_handler = listener.incoming.connect((connection) => {
            if (lifetime.is_cancelled() || connections >= 8 || queries >= 512) {
                connection.close_async.begin(Priority.DEFAULT, null);
                return true;
            }
            connections++;
            serve.begin(connection, (obj, result) => serve.end(result));
            return true;
        });
        listener.start();
    }

    public void close() {
        if (lifetime.is_cancelled()) return;
        lifetime.cancel();
        listener.stop();
        listener.close();
        if (incoming_handler != 0) {
            listener.disconnect(incoming_handler);
            incoming_handler = 0;
        }
        session.abort();
    }

    private async void serve(SocketConnection connection) {
        var cancel = new Cancellable();
        ulong parent_handler = lifetime.connect(() => cancel.cancel());
        // Also bounds a local client that connects without sending a request.
        var timer = new TimeoutSource.seconds(15);
        timer.set_callback(() => { cancel.cancel(); return Source.REMOVE; });
        timer.attach(context);
        try {
            while (!cancel.is_cancelled() && queries < 512) {
                uint8[] prefix = new uint8[2];
                size_t count;
                yield connection.input_stream.read_all_async(prefix, Priority.DEFAULT, cancel, out count);
                if (count != 2) break;
                uint length = ((uint) prefix[0] << 8) | prefix[1];
                if (length < 12) throw new IOError.INVALID_DATA("Invalid DNS query length");
                uint8[] wire = new uint8[length];
                yield connection.input_stream.read_all_async(wire, Priority.DEFAULT, cancel, out count);
                if (count != length) throw new IOError.PARTIAL_INPUT("Incomplete DNS query");
                queries++;
                var message = new Soup.Message("POST", endpoint);
                // Negotiate HTTP/2 normally. Some DoH resolvers reject HTTP/1.1;
                // the bridge-fetch helper's HTTP/1-only workaround does not
                // apply to this account-owned resolver session.
                if (socks_route) {
                    // libsoup 3.4 suppresses h2 for every proxy, including
                    // SOCKS5. This is the resolver's end-to-end TLS stream,
                    // not TLS to an HTTP proxy. Keep its identity and trust.
                    message.network_event.connect(advertise_socks_protocols);
                }
                message.set_flags(Soup.MessageFlags.NO_REDIRECT);
                message.request_headers.replace("Accept", "application/dns-message");
                message.set_request_body_from_bytes("application/dns-message", new Bytes(wire));
                InputStream? body = null;
                try {
                    body = yield session.send_async(message, Priority.DEFAULT, cancel);
                    if (message.status_code != 200 ||
                            message.response_headers.get_content_type(null) != "application/dns-message") {
                        throw new IOError.INVALID_DATA("DNS-over-HTTPS server rejected the query");
                    }
                    var bytes = new ByteArray();
                    while (true) {
                        Bytes chunk = yield body.read_bytes_async(4096, Priority.DEFAULT, cancel);
                        if (chunk.get_size() == 0) break;
                        if (bytes.len + chunk.get_size() > 65535) {
                            throw new IOError.INVALID_DATA("Oversized DNS-over-HTTPS response");
                        }
                        bytes.append(chunk.get_data());
                    }
                    if (bytes.len < 12 || bytes.data[0] != wire[0] || bytes.data[1] != wire[1] ||
                            (bytes.data[2] & 0x80) == 0) {
                        throw new IOError.INVALID_DATA("Invalid DNS-over-HTTPS response");
                    }
                    prefix[0] = (uint8) (bytes.len >> 8);
                    prefix[1] = (uint8) bytes.len;
                    yield connection.output_stream.write_all_async(prefix, Priority.DEFAULT, cancel, out count);
                    yield connection.output_stream.write_all_async(bytes.data, Priority.DEFAULT, cancel, out count);
                } finally {
                    if (body != null) {
                        try { yield body.close_async(Priority.DEFAULT, null); } catch (Error e) { }
                    }
                }
            }
        } catch (Error e) {
            // Closing the TCP stream reports failure to the validator. Never
            // manufacture an unsigned/empty DNS answer for a transport error.
            // Do not log URLs or proxy credentials from exception messages.
        } finally {
            timer.destroy();
            lifetime.disconnect(parent_handler);
            try { yield connection.close_async(Priority.DEFAULT, null); } catch (Error e) { }
            connections--;
        }
    }
}

}
