/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Xmpp {

    private class SrvTargetInfo {
        public string host { get; set; }
        public uint16 port { get; set; }
        public string service { get; set; }
        public uint16 priority { get; set; }
    }

    public class XmppStreamResult {
        public TlsXmppStream? stream { get; set; }
        public TlsCertificateFlags? tls_errors { get; set; }
        public TlsCertificate? tls_certificate { get; set; }
        public IOError? io_error { get; set; }
        public Error? dns_security_error { get; set; }
    }

    public async XmppStreamResult establish_stream(Jid bare_jid, Gee.List<XmppStreamModule> modules, string? log_options, owned TlsXmppStream.OnInvalidCert on_invalid_cert, string? custom_host = null, uint16 custom_port = 0, string proxy_type = "none", string? proxy_host = null, uint16 proxy_port = 0, string? proxy_user = null, string? proxy_pass = null, DnsSecurity.Configuration? dns_security = null) {
        Jid remote = bare_jid.domain_jid;
        TlsXmppStream.OnInvalidCertWrapper on_invalid_cert_wrapper = new TlsXmppStream.OnInvalidCertWrapper((owned)on_invalid_cert);

        if (dns_security != null && dns_security.attempt.mode != DnsSecurity.Mode.OFF) {
            bool special = DnsSecurity.Discovery.is_special(remote.to_string()) ||
                (custom_port > 0 && custom_host != null && custom_host != "" && DnsSecurity.Discovery.is_special(custom_host));
            if (!special) {
                return yield establish_secured_stream(bare_jid, modules, log_options,
                    on_invalid_cert_wrapper, custom_host, custom_port, proxy_type, proxy_host,
                    proxy_port, proxy_user, proxy_pass, dns_security);
            }
            if (dns_security.attempt.mode == DnsSecurity.Mode.REQUIRED) {
                return new XmppStreamResult() { dns_security_error = new DnsSecurity.SecurityError.REQUIRED(
                    "DNSSEC/DANE is not applicable to this special-use address") };
            }
            string special_name = (custom_port > 0 && custom_host != null && custom_host != "") ? custom_host : remote.to_string();
            special_name = (Hostname.to_ascii(special_name) ?? special_name).ascii_down();
            if (special_name.has_suffix(".")) special_name = special_name.substring(0, special_name.length - 1);
            if (special_name.has_suffix(".onion") && proxy_type == "none") {
                return new XmppStreamResult() { dns_security_error = new DnsSecurity.SecurityError.INVALID_CONFIGURATION(
                    "An onion address requires a proxy route; refusing a local DNS lookup") };
            }
        }

        //Lookup xmpp-client and xmpps-client SRV records, or use custom host/port if provided
        GLib.List<SrvTargetInfo>? targets = new GLib.List<SrvTargetInfo>();
        
        if (custom_host != null && custom_host.length > 0 && custom_port > 0) {
            // Use custom host and port, skip SRV lookup.
            // Proxy settings (SOCKS5/Tor) still apply — custom_host only overrides the target, not the tunnel.
            GLib.log("dino-proxy", GLib.LogLevelFlags.LEVEL_DEBUG, "Custom connection: %s:%u (proxy_type=%s)", custom_host, custom_port, proxy_type);
            targets.append(new SrvTargetInfo() { host=custom_host, port=custom_port, service="xmpp-client", priority=0});
        } else if (proxy_type == "tor" || proxy_type == "socks5") {
            // SECURITY: When using Tor or a standalone SOCKS5 proxy, skip local
            // SRV DNS lookups entirely. Local DNS queries leak which XMPP server
            // the user connects to, defeating the proxy's purpose. Let GLib's
            // SOCKS5 proxy handle DNS resolution remotely (SOCKS5 CONNECT).
            GLib.log("dino-proxy", GLib.LogLevelFlags.LEVEL_DEBUG, "Proxy active (type=%s): skipping SRV, connecting to %s via proxy", proxy_type, remote.to_string());
            targets.append(new SrvTargetInfo() { host=remote.to_string(), port=5222, service="xmpp-client", priority=0});
            targets.append(new SrvTargetInfo() { host=remote.to_string(), port=443, service="xmpps-client", priority=10});
            targets.append(new SrvTargetInfo() { host=remote.to_string(), port=5223, service="xmpps-client", priority=20});
        } else if (dns_security != null && dns_security.attempt.mode != DnsSecurity.Mode.OFF &&
                DnsSecurity.Discovery.is_special(remote.to_string())) {
            // Local names and IP literals have no public SRV/TLSA service.
            // Leave ordinary local address resolution/TLS to SocketClient.
            targets.append(new SrvTargetInfo() { host=remote.to_string(), port=5222, service="xmpp-client", priority=0 });
        } else {
            // Standard SRV lookup
            GLibFixes.Resolver resolver = GLibFixes.Resolver.get_default();
            try {
                GLib.List<SrvTarget> xmpp_services = yield resolver.lookup_service_async("xmpp-client", "tcp", remote.to_string(), dns_security != null ? dns_security.attempt.cancellable : null);
                foreach (SrvTarget service in xmpp_services) {
                    targets.append(new SrvTargetInfo() { host=service.get_hostname(), port=service.get_port(), service="xmpp-client", priority=service.get_priority()});
                }
            } catch (Error e) {
                debug("Got no xmpp-client DNS records for %s: %s", remote.to_string(), e.message);
            }
            try {
                GLib.List<SrvTarget> xmpp_services = yield resolver.lookup_service_async("xmpps-client", "tcp", remote.to_string(), dns_security != null ? dns_security.attempt.cancellable : null);
                foreach (SrvTarget service in xmpp_services) {
                    targets.append(new SrvTargetInfo() { host=service.get_hostname(), port=service.get_port(), service="xmpps-client", priority=service.get_priority()});
                }
            } catch (Error e) {
                debug("Got no xmpps-client DNS records for %s: %s", remote.to_string(), e.message);
            }

            targets.sort((a, b) => {
                return a.priority - b.priority;
            });

            // Add fallback connection
            bool should_add_fallback = true;
            foreach (SrvTargetInfo target in targets) {
                if (target.service == "xmpp-client" && target.port == 5222 && target.host == remote.to_string()) {
                    should_add_fallback = false;
                }
            }
            if (should_add_fallback) {
                targets.append(new SrvTargetInfo() { host=remote.to_string(), port=5222, service="xmpp-client", priority=uint16.MAX});
            }
        }

        // Try all connection options from lowest to highest priority
        TlsXmppStream? stream = null;
        TlsCertificateFlags? tls_errors = null;
        TlsCertificate? tls_certificate = null;
        IOError? io_error = null;
        uint connection_timeout_id = 0;
        foreach (SrvTargetInfo target in targets) {
            ulong cancel_handler = 0;
            try {
                if (dns_security != null) dns_security.attempt.cancellable.set_error_if_cancelled();
                if (target.service == "xmpp-client") {
                    stream = new StartTlsXmppStream(remote, target.host, target.port, on_invalid_cert_wrapper, proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass);
                } else {
                    stream = new DirectTlsXmppStream(remote, target.host, target.port, on_invalid_cert_wrapper, proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass);
                }
                stream.log = new XmppLog(bare_jid.to_string(), log_options);
                if (dns_security != null) cancel_handler = dns_security.attempt.cancellable.cancelled.connect(stream.cancel);

                foreach (XmppStreamModule module in modules) {
                    stream.add_module(module);
                }

                connection_timeout_id = Timeout.add_seconds(60, () => {
                    warning("Connection attempt timed out");
                    stream.cancel();
                    connection_timeout_id = 0;
                    return Source.REMOVE;
                });

                yield stream.connect();

                if (connection_timeout_id != 0) {
                    Source.remove(connection_timeout_id);
                    connection_timeout_id = 0;
                }

                return new XmppStreamResult() { stream=stream };
            } catch (IOError e) {
                warning("Could not establish XMPP session with %s:%i: %s", target.host, target.port, e.message);
                io_error = e;

                if (stream != null) {
                    if (connection_timeout_id != 0) {
                        Source.remove(connection_timeout_id);
                        connection_timeout_id = 0;
                    }
                    if (stream.errors != null) {
                        tls_errors = stream.errors;
                        tls_certificate = stream.peer_certificate;
                    }
                    stream.detach_modules();
                    stream.abort_connection();
                }
                if (dns_security != null && dns_security.attempt.cancellable.is_cancelled()) break;
            } finally {
                if (cancel_handler != 0) SignalHandler.disconnect(dns_security.attempt.cancellable, cancel_handler);
            }
        }

        return new XmppStreamResult() { io_error=io_error, tls_errors=tls_errors, tls_certificate=tls_certificate };
    }

    private async XmppStreamResult establish_secured_stream(Jid jid, Gee.List<XmppStreamModule> modules,
            string? log_options, TlsXmppStream.OnInvalidCertWrapper on_invalid_cert,
            string? custom_host, uint16 custom_port, string proxy_type, string? proxy_host,
            uint16 proxy_port, string? proxy_user, string? proxy_pass, DnsSecurity.Configuration configuration) {
        DnsSecurity.Discovery? discovery = null;
        var result = new XmppStreamResult();
        uint deadline = Timeout.add_seconds(60, () => { configuration.attempt.cancel(); return Source.CONTINUE; });
        try {
            string proxy_uri = "direct://";
            if (proxy_type != "none") {
                string host = proxy_host ?? (proxy_type == "tor" ? "127.0.0.1" : "");
                uint16 port = proxy_port > 0 ? proxy_port : (proxy_type == "tor" ? (uint16) 9050 : (uint16) 0);
                if ((proxy_type != "socks5" && proxy_type != "tor") ||
                        new InetAddress.from_string(host) == null || port == 0) {
                    throw new DnsSecurity.SecurityError.INVALID_CONFIGURATION("DNSSEC requires a numeric, configured SOCKS5 proxy endpoint");
                }
                string auth = "";
                if (proxy_type == "socks5" && proxy_user != null && proxy_user != "") {
                    auth = "%s:%s@".printf(Uri.escape_string(proxy_user, null, false), Uri.escape_string(proxy_pass ?? "", null, false));
                }
                proxy_uri = "socks5://%s%s:%u".printf(auth, host.contains(":") ? "[" + host + "]" : host, port);
            }
            string domain = DnsSecurity.Discovery.normalize_host(jid.domainpart);
            discovery = new DnsSecurity.Discovery(configuration, proxy_uri);
            var targets = yield discovery.targets(domain, custom_host, custom_port);
            foreach (var target in targets) {
                Gee.List<DnsSecurity.Endpoint> endpoints;
                try {
                    endpoints = yield discovery.addresses(domain, target);
                } catch (Error error) {
                    configuration.attempt.cancellable.set_error_if_cancelled();
                    result.dns_security_error = error;
                    continue; // Only another target from the same checked SRV discovery.
                }
                foreach (var endpoint in endpoints) {
                    TlsXmppStream stream;
                    if (endpoint.direct_tls) {
                        stream = new DirectTlsXmppStream(jid.domain_jid, endpoint.host, endpoint.port,
                            on_invalid_cert, proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass);
                    } else {
                        stream = new StartTlsXmppStream(jid.domain_jid, endpoint.host, endpoint.port,
                            on_invalid_cert, proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass);
                    }
                    stream.dns_security = endpoint.guard;
                    stream.log = new XmppLog(jid.to_string(), log_options);
                    foreach (var module in modules) stream.add_module(module);
                    ulong cancel_handler = configuration.attempt.cancellable.cancelled.connect(stream.cancel);
                    uint timer = Timeout.add_seconds(30, stream.cancel_on_deadline);
                    bool connected = false;
                    try {
                        endpoint.guard.check_current();
                        yield stream.connect();
                        endpoint.guard.check_current();
                        connected = true;
                        return new XmppStreamResult() { stream = stream };
                    } catch (Error error) {
                        if (stream.dns_security_error != null) {
                            result.dns_security_error = stream.dns_security_error;
                        } else if (error is DnsSecurity.SecurityError) {
                            result.dns_security_error = error;
                        } else {
                            result.io_error = new IOError.FAILED("%s", error.message);
                            result.tls_errors = stream.errors;
                            result.tls_certificate = stream.peer_certificate;
                        }
                        configuration.attempt.cancellable.set_error_if_cancelled();
                    } finally {
                        Source.remove(timer);
                        SignalHandler.disconnect(configuration.attempt.cancellable, cancel_handler);
                        if (!connected) {
                            stream.detach_modules();
                            stream.abort_connection();
                        }
                    }
                }
            }
            if (targets.size == 0) result.dns_security_error = new DnsSecurity.SecurityError.LOOKUP_FAILED("The domain offers no XMPP service");
        } catch (Error error) {
            result.dns_security_error = error;
        } finally {
            Source.remove(deadline);
            if (discovery != null) discovery.close();
        }
        return result;
    }
}
