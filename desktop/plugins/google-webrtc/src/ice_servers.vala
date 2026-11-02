using Gee;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

public class EngineIceServer : Object {
    public string url { get; private set; }
    public string? username { get; private set; }
    public string? credential { get; private set; }
    public DateTime? expires { get; private set; }

    public bool is_stun {
        get {
            string normalized = url.ascii_down();
            return normalized.has_prefix("stun:") || normalized.has_prefix("stuns:");
        }
    }

    public bool is_turn {
        get {
            string normalized = url.ascii_down();
            return normalized.has_prefix("turn:") || normalized.has_prefix("turns:");
        }
    }

    public EngineIceServer(string url, string? username = null, string? credential = null, DateTime? expires = null) {
        this.url = url;
        this.username = username;
        this.credential = credential;
        this.expires = expires;
    }

    public static Gee.List<EngineIceServer> from_external_services(
            Gee.List<ExternalServiceDiscovery.Service> services) {
        var ret = new ArrayList<EngineIceServer>();
        var seen = new HashSet<string>();

        foreach (ExternalServiceDiscovery.Service service in services) {
            EngineIceServer? mapped = from_external_service(service);
            if (mapped == null) continue;

            EngineIceServer ice_server = (!) mapped;
            string key = "%s\n%s\n%s".printf(
                ice_server.url,
                ice_server.username ?? "",
                ice_server.credential ?? "");
            if (seen.contains(key)) continue;

            seen.add(key);
            ret.add(ice_server);
        }

        return ret;
    }

    private static EngineIceServer? from_external_service(ExternalServiceDiscovery.Service service) {
        string type = (service.ty ?? "").strip().ascii_down();
        string host = (service.host ?? "").strip();
        string transport = (service.transport ?? "").strip().ascii_down();
        uint port = service.port;

        if (host == "" || port == 0 || port > 65535) return null;
        if (transport != "udp" && transport != "tcp") return null;
        if (type != "stun" && type != "stuns" && type != "turn" && type != "turns") return null;
        if ((type == "stuns" || type == "turns") && transport == "udp") return null;

        string escaped_host = wrap_ice_host(host);
        string url;
        if (type == "stun" || type == "stuns") {
            // STUN URLs must not carry a transport query in current libwebrtc.
            url = "%s:%s:%u".printf(type, escaped_host, port);
        } else {
            string? username = service.username;
            string? credential = service.password;
            if (username == null || credential == null || ((!) username).strip() == "" || ((!) credential).strip() == "") {
                return null;
            }
            url = "%s:%s:%u?transport=%s".printf(type, escaped_host, port, transport);
            return new EngineIceServer(url, username, credential, service.expires);
        }

        string? stun_username = service.username;
        string? stun_credential = service.password;
        if (stun_username != null && stun_credential != null && ((!) stun_username).strip() != "" && ((!) stun_credential).strip() != "") {
            return new EngineIceServer(url, stun_username, stun_credential, service.expires);
        }
        return new EngineIceServer(url, null, null, service.expires);
    }

    private static string wrap_ice_host(string host) {
        if (host.has_prefix("[") && host.has_suffix("]")) return host;
        if (host.index_of(":") >= 0) return "[%s]".printf(host);
        return host;
    }
}

public const uint MIN_TURN_REFRESH_DELAY_SECONDS = 300;

public static uint? calculate_ice_server_refresh_delay(Gee.List<EngineIceServer> ice_servers, DateTime now) {
    int64 earliest_expiry = int64.MAX;
    foreach (EngineIceServer ice_server in ice_servers) {
        if (!ice_server.is_turn || ice_server.expires == null) continue;
        int64 expiry = ((!) ice_server.expires).to_unix();
        if (expiry < earliest_expiry) earliest_expiry = expiry;
    }

    if (earliest_expiry == int64.MAX) return null;

    int64 remaining = earliest_expiry - now.to_unix();
    if (remaining <= 0) return null;

    int64 refresh_delay = remaining / 2;
    if (refresh_delay < MIN_TURN_REFRESH_DELAY_SECONDS || refresh_delay > uint.MAX) return null;

    return (uint) refresh_delay;
}

}
