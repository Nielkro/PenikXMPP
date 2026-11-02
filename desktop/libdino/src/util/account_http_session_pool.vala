using Gee;

using Dino.Entities;

namespace Dino {

private class AccountHttpSessionEntry : Object {
    public Object session { get; private set; }
    public string? proxy_uri { get; private set; }

    public AccountHttpSessionEntry(Object session, string? proxy_uri) {
        this.session = session;
        this.proxy_uri = proxy_uri;
    }
}

/**
 * Owns fully configured libsoup sessions for account-scoped HTTP traffic.
 *
 * Callers must use the pool from their owning main context. Session-wide
 * network properties are never changed after the first request can start;
 * a live proxy change therefore retires the old session and creates a new
 * generation for subsequent requests.
 */
public class AccountHttpSessionPool : Object {
    private HashMap<Account, AccountHttpSessionEntry> sessions =
        new HashMap<Account, AccountHttpSessionEntry>(Account.hash_func, Account.equals_func);
    private ArrayList<Soup.Session> retired_sessions = new ArrayList<Soup.Session>();
    private Soup.Session? default_session = null;
    private string operation;

    public AccountHttpSessionPool(string operation) {
        this.operation = operation;
    }

    // Return Object so libdino's public VAPI does not force unrelated plugins
    // to import libsoup merely because they depend on libdino.
    public Object get_session(Account account) {
        string? proxy_uri = build_socks5_proxy_uri(account);
        AccountHttpSessionEntry? current = sessions[account];
        if (current != null && nullable_strings_equal(((!) current).proxy_uri, proxy_uri)) {
            return ((!) current).session;
        }

        if (current != null) {
            // Requests and download streams that already use the old immutable
            // session must be allowed to finish after a live proxy change.
            retired_sessions.add((Soup.Session) ((!) current).session);
        }

        Soup.Session session = create_configured_session(proxy_uri);
        sessions[account] = new AccountHttpSessionEntry(session, proxy_uri);
        GLib.log("dino-proxy", GLib.LogLevelFlags.LEVEL_DEBUG,
            proxy_uri != null ? "%s: proxy enabled for account %s" : "%s: direct connection for account %s",
            operation, account.bare_jid.to_string());
        return session;
    }

    public Object get_default_session() {
        if (default_session == null) {
            default_session = create_configured_session(null);
        }
        return (!) default_session;
    }

    public void shutdown() {
        foreach (AccountHttpSessionEntry entry in sessions.values) {
            ((Soup.Session) entry.session).abort();
        }
        sessions.clear();

        foreach (Soup.Session session in retired_sessions) {
            session.abort();
        }
        retired_sessions.clear();

        if (default_session != null) {
            ((!) default_session).abort();
            default_session = null;
        }
    }

    private static Soup.Session create_configured_session(string? proxy_uri) {
        var session = new Soup.Session();
        session.user_agent = @"Dino/$(get_short_version()) ";
        session.proxy_resolver = proxy_uri != null
            ? new SimpleProxyResolver((!) proxy_uri, null)
            : ProxyResolver.get_default();
        return session;
    }

    private static bool nullable_strings_equal(string? left, string? right) {
        if (left == null || right == null) return left == null && right == null;
        return (!) left == (!) right;
    }
}

}
