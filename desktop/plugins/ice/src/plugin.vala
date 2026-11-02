using Gee;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

private extern const size_t NICE_ADDRESS_STRING_LEN;

public class Dino.Plugins.Ice.Plugin : RootInterface, Object {
    private HashMap<Account, uint> timeouts = new HashMap<Account, uint>(Account.hash_func, Account.equals_func);
    private HashMap<Account, int64?> extdisco_warning_timestamps = new HashMap<Account, int64?>(Account.hash_func, Account.equals_func);

    public Dino.Application app;

    public void registered(Dino.Application app) {
        Nice.debug_enable(true);
        this.app = app;
        app.stream_interactor.module_manager.initialize_account_modules.connect((account, list) => {
            list.add(new Module());
        });
        app.stream_interactor.stream_attached_modules.connect((account, stream) => {
            if (stream.get_module<Socks5Bytestreams.Module>(Socks5Bytestreams.Module.IDENTITY) != null) {
                stream.get_module<Socks5Bytestreams.Module>(Socks5Bytestreams.Module.IDENTITY).set_local_ip_address_handler(get_local_ip_addresses);
            }
            if (stream.get_module<JingleSocks5Bytestreams.Module>(JingleSocks5Bytestreams.Module.IDENTITY) != null) {
                string? proxy_uri = apply_jingle_s5b_account_proxy_policy(account, stream);
                GLib.log("dino-proxy", GLib.LogLevelFlags.LEVEL_DEBUG,
                         "jingle-s5b: %s local direct candidates for account %s",
                         proxy_uri == null ? "allowing" : "blocking",
                         account.bare_jid.to_string());
            }
            if (stream.get_module<JingleRawUdp.Module>(JingleRawUdp.Module.IDENTITY) != null) {
                stream.get_module<JingleRawUdp.Module>(JingleRawUdp.Module.IDENTITY).set_local_ip_address_handler(get_local_ip_addresses);
            }
        });
        app.stream_interactor.stream_negotiated.connect(external_discovery_refresh_services);
        app.stream_interactor.account_removed.connect((account) => {
            clear_refresh_timeout(account);
            extdisco_warning_timestamps.unset(account);
        });
    }

    private async void external_discovery_refresh_services(Account account, XmppStream stream) {
        clear_refresh_timeout(account);
        if (app.stream_interactor.get_stream(account) != stream) return;

        Module? ice_udp_module = stream.get_module<JingleIceUdp.Module>(JingleIceUdp.Module.IDENTITY) as Module;
        if (ice_udp_module == null) return;

        ExternalServiceDiscoverySupport extdisco_support = yield query_external_service_discovery_support(account, stream);
        if (app.stream_interactor.get_stream(account) != stream) return;

        if (extdisco_support != ExternalServiceDiscoverySupport.UNSUPPORTED) {
            Gee.List<Xep.ExternalServiceDiscovery.Service> services;
            bool found_usable_turn_service = false;
            bool request_completed = false;
            try {
                services = yield ExternalServiceDiscovery.request_services_checked(stream);
                request_completed = true;
            } catch (IOError e) {
                log_external_service_discovery_failure(account, "Could not request XEP-0215 services", e);
                services = new ArrayList<Xep.ExternalServiceDiscovery.Service>();
            }
            if (app.stream_interactor.get_stream(account) != stream) return;

            foreach (Xep.ExternalServiceDiscovery.Service service in services) {
                if ((service.transport == "udp" || service.transport == "tcp") && (service.ty == "stun" || service.ty == "turn")) {
                    InetAddress? ip = yield lookup_ipv4_addess(service.host);
                    if (app.stream_interactor.get_stream(account) != stream) return;
                    if (ip == null) continue;

                    if (ip.is_any || ip.is_link_local || ip.is_loopback || ip.is_multicast || ip.is_site_local) {
                        warning("Ignoring STUN/TURN server at %s", service.host);
                        continue;
                    }

                    if (service.ty == "stun") {
                        debug("Server offers STUN server: %s:%u, resolved to %s", service.host, service.port, ip.to_string());
                        ice_udp_module.stun_ip = ip.to_string();
                        ice_udp_module.stun_port = service.port;
                    } else if (service.ty == "turn") {
                        debug("Server offers TURN server: %s:%u, resolved to %s", service.host, service.port, ip.to_string());
                        ice_udp_module.turn_ip = ip.to_string();
                        ice_udp_module.turn_service = service;
                        found_usable_turn_service = true;
                    }
                }
            }

            if (request_completed && !found_usable_turn_service) {
                clear_turn_service(ice_udp_module, "Clearing TURN credentials because XEP-0215 returned no usable TURN service");
            }
        } else if (extdisco_support == ExternalServiceDiscoverySupport.UNSUPPORTED) {
            debug("Server does not advertise XEP-0215 external service discovery");
            clear_turn_service(ice_udp_module, "Clearing TURN credentials because the server does not advertise XEP-0215");
        }

        clear_expired_turn_service(ice_udp_module, new DateTime.now_utc());

        if (ice_udp_module.stun_ip == null) {
            InetAddress ip = yield lookup_ipv4_addess("stun.l.google.com");
            if (app.stream_interactor.get_stream(account) != stream) return;
            if (ip == null) return;

            debug("Using fallback STUN server: stun.l.google.com:19302, resolved to %s", ip.to_string());

            ice_udp_module.stun_ip = ip.to_string();
            ice_udp_module.stun_port = 19302;
        }

        // Refresh TURN credentials before they expire
        if (ice_udp_module.turn_service != null) {
            DateTime? expires = ice_udp_module.turn_service.expires;
            DateTime now = new DateTime.now_utc();
            uint? refresh_delay = calculate_turn_refresh_delay(expires, now);

            if (refresh_delay != null) {
                uint delay = (!) refresh_delay;
                debug("Re-fetching TURN credentials in %u sec", delay);

                timeouts[account] = Timeout.add_seconds(delay, () => {
                    timeouts.unset(account);
                    if (app.stream_interactor.get_stream(account) == stream) {
                        external_discovery_refresh_services.begin(account, stream);
                    }
                    return Source.REMOVE;
                });
            } else if (expires != null) {
                uint? cleanup_delay = calculate_turn_expiry_cleanup_delay(expires, now);
                if (cleanup_delay != null) {
                    uint delay = (!) cleanup_delay;
                    debug("Clearing TURN credentials in %u sec", delay);

                    timeouts[account] = Timeout.add_seconds(delay, () => {
                        timeouts.unset(account);
                        if (app.stream_interactor.get_stream(account) == stream) {
                            clear_expired_turn_service(ice_udp_module, new DateTime.now_utc());
                        }
                        return Source.REMOVE;
                    });
                } else {
                    debug("TURN credentials are close to expiry or expired, not scheduling a refresh");
                }
            }
        }
    }

    public void shutdown() {
        clear_all_refresh_timeouts();
    }

    public void rekey_database(string new_key) throws Error {
        // No own database
    }

    public void checkpoint_database() {
        // No own database
    }

    private async InetAddress? lookup_ipv4_addess(string host) {
        try {
            Resolver resolver = Resolver.get_default();
            GLib.List<GLib.InetAddress>? ips = yield resolver.lookup_by_name_async(host);
            foreach (GLib.InetAddress ina in ips) {
                if (ina.get_family() != SocketFamily.IPV4) continue;
                return ina;
            }
        } catch (Error e) {
            warning("Failed looking up IP address of %s", host);
        }
        return null;
    }

    private async ExternalServiceDiscoverySupport query_external_service_discovery_support(Account account, XmppStream stream) {
        Iq.Stanza iq = new Iq.Stanza.get(new StanzaNode.build("query", ServiceDiscovery.NS_URI_INFO).add_self_xmlns()) { to=stream.remote_name };
        Iq.Stanza response_iq;

        try {
            response_iq = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        } catch (IOError e) {
            log_external_service_discovery_failure(account, "Could not verify XEP-0215 support", e);
            return ExternalServiceDiscoverySupport.UNKNOWN;
        }

        if (response_iq.is_error()) {
            debug("Could not verify XEP-0215 support: server disco#info returned an IQ error");
            return ExternalServiceDiscoverySupport.UNKNOWN;
        }

        StanzaNode? query_node = response_iq.stanza.get_subnode("query", ServiceDiscovery.NS_URI_INFO);
        if (query_node == null) {
            warning("Could not verify XEP-0215 support: malformed server disco#info response");
            return ExternalServiceDiscoverySupport.UNKNOWN;
        }

        foreach (StanzaNode feature_node in query_node.get_subnodes("feature", ServiceDiscovery.NS_URI_INFO)) {
            if (feature_node.get_attribute("var", ServiceDiscovery.NS_URI_INFO) == ExternalServiceDiscovery.NS_URI) {
                return ExternalServiceDiscoverySupport.SUPPORTED;
            }
        }
        return ExternalServiceDiscoverySupport.UNSUPPORTED;
    }

    private void log_external_service_discovery_failure(Account account, string message, IOError error) {
        if (error is IOError.CANCELLED) {
            debug("%s: %s", message, error.message);
            return;
        }

        if (error is IOError.TIMED_OUT) {
            int64 now_unix = new DateTime.now_utc().to_unix();
            int64? stored_last_warning_unix = extdisco_warning_timestamps[account];
            int64 last_warning_unix = stored_last_warning_unix ?? 0;
            if (last_warning_unix == 0 || now_unix - last_warning_unix >= 3600) {
                warning("%s: %s", message, error.message);
                extdisco_warning_timestamps[account] = now_unix;
            } else {
                debug("%s: %s", message, error.message);
            }
            return;
        }

        warning("%s: %s", message, error.message);
    }

    private void clear_refresh_timeout(Account account) {
        if (!timeouts.has_key(account)) return;

        uint timeout_id = timeouts[account];
        timeouts.unset(account);
        if (timeout_id != 0) Source.remove(timeout_id);
    }

    private void clear_all_refresh_timeouts() {
        foreach (uint timeout_id in timeouts.values) {
            if (timeout_id != 0) Source.remove(timeout_id);
        }
        timeouts.clear();
    }

    private void clear_expired_turn_service(Module ice_udp_module, DateTime now) {
        if (ice_udp_module.turn_service == null) return;

        DateTime? expires = ice_udp_module.turn_service.expires;
        if (expires == null || ((!) expires).to_unix() > now.to_unix()) return;

        clear_turn_service(ice_udp_module, "Clearing expired TURN credentials");
    }

    private void clear_turn_service(Module ice_udp_module, string reason) {
        if (ice_udp_module.turn_service == null && ice_udp_module.turn_ip == null) return;

        debug("%s", reason);
        ice_udp_module.turn_service = null;
        ice_udp_module.turn_ip = null;
    }
}

namespace Dino.Plugins.Ice {

internal const uint MIN_TURN_REFRESH_DELAY_SECONDS = 300;

internal enum ExternalServiceDiscoverySupport {
    SUPPORTED,
    UNSUPPORTED,
    UNKNOWN
}

internal static uint? calculate_turn_refresh_delay(DateTime? expires, DateTime now) {
    if (expires == null) return null;

    int64 remaining = ((!) expires).to_unix() - now.to_unix();
    if (remaining <= 0) return null;

    int64 refresh_delay = remaining / 2;
    if (refresh_delay < MIN_TURN_REFRESH_DELAY_SECONDS || refresh_delay > uint.MAX) return null;

    return (uint) refresh_delay;
}

internal static uint? calculate_turn_expiry_cleanup_delay(DateTime? expires, DateTime now) {
    if (expires == null) return null;

    int64 remaining = ((!) expires).to_unix() - now.to_unix();
    if (remaining <= 0 || remaining > uint.MAX) return null;

    return (uint) remaining;
}

}
