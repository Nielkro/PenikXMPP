/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

/**
 * Fail-closed per-account readiness shared by connection and archive users.
 *
 * A gate must emit readiness_changed whenever its answer for an account may
 * have changed. ConnectionManager will not establish or resume an account
 * while any registered gate is unavailable.
 */
public abstract class AccountReadinessGate : Object {
    public signal void readiness_changed(Account account);

    public abstract bool is_ready(Account account);
}

public class ConnectionManager : Object {

    public signal void stream_opened(Account account, XmppStream stream);
    public signal void stream_attached_modules(Account account, XmppStream stream);
    public signal void connection_state_changed(Account account, ConnectionState state);
    public signal void connection_error(Account account, ConnectionError error);
    public signal void certificate_validation_required(
        Account account,
        TlsCertificate peer_cert,
        TlsCertificateFlags errors
    );

    public enum ConnectionState {
        CONNECTED,
        CONNECTING,
        DISCONNECTED
    }

    private HashMap<Account, Connection> connections = new HashMap<Account, Connection>(Account.hash_func, Account.equals_func);
    private HashMap<Account, ConnectionError> connection_errors = new HashMap<Account, ConnectionError>(Account.hash_func, Account.equals_func);

    private HashMap<Account, bool> connection_ongoing = new HashMap<Account, bool>(Account.hash_func, Account.equals_func);
    private HashMap<Account, bool> connection_directly_retry = new HashMap<Account, bool>(Account.hash_func, Account.equals_func);
    private ArrayList<AccountReadinessGate> readiness_gates =
        new ArrayList<AccountReadinessGate>();
    // Login1 can deliver wake while the asynchronous suspend disconnect is
    // still waiting on its first stream.  Keep those events strictly ordered,
    // and grant wake ownership only to the exact account/connection/stream
    // snapshot terminalized by one suspend cycle.
    private ArrayList<bool> prepare_for_sleep_requests = new ArrayList<bool>();
    private bool prepare_for_sleep_active = false;
    private bool device_suspended = false;
    private bool shutdown_requested = false;
    private uint suspend_cycle_generation = 0;
    private HashMap<Account, SuspendAccountSnapshot> suspend_reconnect_accounts =
        new HashMap<Account, SuspendAccountSnapshot>(Account.hash_func,
            Account.equals_func);

    // Test-only connect interception keeps suspend/wake audits local and
    // deterministic instead of opening real DNS/TCP connections.
    private bool connect_stream_intercepted_for_tests = false;
    private ArrayList<Account> intercepted_connect_accounts_for_tests =
        new ArrayList<Account>(Account.equals_func);

    private NetworkMonitor? network_monitor;
    private Login1Manager? login1;
    private ModuleManager module_manager;
    public string? log_options;
    private Database? db;

    public class ConnectionError {

        public enum Source {
            CONNECTION,
            SASL,
            TLS,
            STREAM_ERROR,
            DNS_SECURITY
        }

        public enum Reconnect {
            NOW,
            LATER,
            NEVER
        }

        public Source source;
        public string? identifier;
        public Reconnect reconnect_recomendation { get; set; default=Reconnect.NOW; }
        
        // TLS certificate information for certificate pinning
        public TlsCertificate? tls_certificate { get; set; }
        public TlsCertificateFlags tls_flags { get; set; }
        public string? tls_domain { get; set; }
        public Error? dns_security_error { get; set; }

        public ConnectionError(Source source, string? identifier) {
            this.source = source;
            this.identifier = identifier;
        }
    }

    private class Connection {
        public string uuid { get; set; }
        public XmppStream? stream { get; set; }
        public ConnectionState connection_state { get; set; default = ConnectionState.DISCONNECTED; }
        public DateTime? established { get; set; }
        public DateTime? last_activity { get; set; }
        public uint reconnect_generation { get; private set; default = 0; }
        public DnsSecurity.Attempt? dns_attempt;
        public bool provisional_stream_retained { get; set; default = false; }
        public bool stream_replacement_pending { get; set; default = false; }
        public bool terminal_disconnect_requested { get; set;
            default = false; }
        public bool readiness_blocked { get; set; default = false; }
        public bool readiness_resume_pending { get; set; default = false; }
        public bool readiness_disconnect_in_progress { get; set;
            default = false; }
        public bool readiness_reconnect_permitted { get; set;
            default = false; }
        public bool readiness_terminal_transition { get; set;
            default = false; }
        public uint suspend_terminal_generation { get; set; default = 0; }
        private HashSet<XmppStream> disconnecting_streams =
            new HashSet<XmppStream>();

        public Connection() {
            reset();
        }

        public void invalidate_reconnect_checks() {
            reconnect_generation++;
        }

        public void reset(bool disconnect_stream = true) {
            cancel_dns_attempt();
            invalidate_reconnect_checks();
            if (stream != null) {
                stream.detach_modules();

                if (disconnect_stream) {
                    disconnect_stream_once.begin((!) stream);
                }
            }
            stream = null;
            provisional_stream_retained = false;
            established = last_activity = null;
            uuid = Xmpp.random_uuid();
        }

        public void make_offline() {
            cancel_dns_attempt();
            Xmpp.Presence.Stanza presence = new Xmpp.Presence.Stanza();
            presence.type_ = Xmpp.Presence.Stanza.TYPE_UNAVAILABLE;
            if (stream != null) {
                stream.get_module<Presence.Module>(Presence.Module.IDENTITY).send_presence(stream, presence);
            }
        }

        public async void disconnect_account() {
            cancel_dns_attempt();
            XmppStream? current_stream = stream;
            if (current_stream != null) {
                yield disconnect_stream_once((!) current_stream);
            }
        }

        public bool is_disconnecting(XmppStream candidate) {
            return disconnecting_streams.contains(candidate);
        }

        public void cancel_dns_attempt() {
            if (dns_attempt != null) dns_attempt.cancel();
            dns_attempt = null;
        }

        public async void disconnect_stream_once(XmppStream target) {
            if (!disconnecting_streams.add(target)) return;
            try {
                yield target.disconnect();
            } catch (Error e) {
                debug("Error disconnecting stream %p: %s", target,
                    e.message);
            } finally {
                disconnecting_streams.remove(target);
            }
        }
    }

    private class SuspendAccountSnapshot {
        public Account account { get; private set; }
        public Connection connection { get; private set; }
        public XmppStream? stream { get; private set; }
        public uint cycle_generation { get; private set; }

        public SuspendAccountSnapshot(Account account, Connection connection,
                XmppStream? stream, uint cycle_generation) {
            this.account = account;
            this.connection = connection;
            this.stream = stream;
            this.cycle_generation = cycle_generation;
        }
    }

    public ConnectionManager(ModuleManager module_manager, Database? db = null) {
        this.module_manager = module_manager;
        this.db = db;
        network_monitor = GLib.NetworkMonitor.get_default();
        if (network_monitor != null) {
            network_monitor.network_changed.connect(on_network_changed);
            network_monitor.notify["connectivity"].connect(on_network_changed);
        }

        get_login1.begin((_, res) => {
            login1 = get_login1.end(res);
            if (login1 != null) {
                login1.PrepareForSleep.connect(on_prepare_for_sleep);
            }
        });

        Timeout.add_seconds(60, () => {
            foreach (Account account in connections.keys) {
                if (connections[account].last_activity == null ||
                        connections[account].last_activity.compare(new DateTime.now_utc().add_minutes(-1)) < 0) {
                    check_reconnect(account);
                }
            }
            return true;
        });
    }

    internal ConnectionManager.for_tests(ModuleManager module_manager, Database? db = null) {
        this.module_manager = module_manager;
        this.db = db;
    }

    public void add_readiness_gate(AccountReadinessGate gate) {
        if (readiness_gates.contains(gate)) return;
        readiness_gates.add(gate);
        gate.readiness_changed.connect(on_readiness_changed);

        // A gate can be registered after accounts were already handed to the
        // manager. Reconcile a snapshot so stopping a stream cannot mutate the
        // collection currently being traversed.
        var accounts = new ArrayList<Account>(Account.equals_func);
        accounts.add_all(connections.keys);
        foreach (Account account in accounts) {
            on_readiness_changed(account);
        }
    }

    private bool is_account_ready(Account account) {
        foreach (AccountReadinessGate gate in readiness_gates) {
            if (!gate.is_ready(account)) return false;
        }
        return true;
    }

    private void on_readiness_changed(Account account) {
        if (!connections.has_key(account)) return;
        if (!is_account_ready(account)) {
            block_account_for_readiness(account);
        } else {
            resume_account_after_readiness(account);
        }
    }

    private void block_account_for_readiness(Account account) {
        if (!connections.has_key(account)) return;
        Connection connection = connections[account];
        if (connection.readiness_blocked) return;

        bool readiness_may_resume = connection.readiness_reconnect_permitted ||
            !connection.terminal_disconnect_requested ||
            connection.suspend_terminal_generation != 0;
        connection.readiness_blocked = true;
        connection.readiness_reconnect_permitted = readiness_may_resume;
        connection.readiness_resume_pending = false;
        connection_directly_retry[account] = false;

        XmppStream? blocked_stream = connection.stream;
        connection.readiness_disconnect_in_progress = blocked_stream != null;

        // Readiness owns this terminal transition. It supersedes a pending
        // suspend resume and invalidates every delayed connect/ping result.
        suspend_reconnect_accounts.unset(account);
        connection.readiness_terminal_transition = true;
        change_connection_state(account, ConnectionState.DISCONNECTED);
        connection.readiness_terminal_transition = false;
        // Rotate the generation and detach immediately, but do not let a
        // readiness recovery race a replacement connect beside the old
        // stream's asynchronous close.
        connection.reset(false);

        if (blocked_stream != null) {
            connection.disconnect_stream_once.begin((!) blocked_stream,
                    (_, res) => {
                connection.disconnect_stream_once.end(res);
                if (!connections.has_key(account) ||
                        connections[account] != connection) return;
                connection.readiness_disconnect_in_progress = false;
                if (is_account_ready(account)) {
                    resume_account_after_readiness(account);
                }
            });
        } else if (is_account_ready(account)) {
            // A readiness signal can synchronously repair its dependency from
            // a connection-state observer. Reconcile only after the terminal
            // transition and generation rotation are complete.
            resume_account_after_readiness(account);
        }
    }

    private void resume_account_after_readiness(Account account) {
        if (!connections.has_key(account)) return;
        Connection connection = connections[account];
        if (!connection.readiness_blocked || !is_account_ready(account)) return;
        if (connection.readiness_terminal_transition ||
                connection.readiness_disconnect_in_progress) return;

        connection.readiness_blocked = false;
        connection.readiness_resume_pending = false;
        if (shutdown_requested ||
                !connection.readiness_reconnect_permitted) {
            connection.readiness_reconnect_permitted = false;
            return;
        }

        connection.readiness_reconnect_permitted = false;
        connection.terminal_disconnect_requested = false;
        connection.suspend_terminal_generation = 0;
        connection.provisional_stream_retained = false;
        connection.stream_replacement_pending = false;

        if (device_suspended) {
            connection.readiness_resume_pending = true;
            return;
        }

        if (connection_ongoing.has_key(account) &&
                connection_ongoing[account]) {
            // Do not overlap the superseded establish attempt. Its stale-result
            // fence starts this single successor after the old callback exits.
            connection_directly_retry[account] = true;
            return;
        }
        start_connect_stream(account);
    }

    // Test-only seam: exposes a fake connected stream to StreamInteractor
    // without simulating the full connect, module-attach and negotiation flow.
    internal void set_connected_stream_for_tests(Account account, XmppStream stream) {
        if (!connections.has_key(account)) {
            connections[account] = new Connection();
            connection_ongoing[account] = false;
            connection_directly_retry[account] = false;
        }

        connections[account].stream = stream;
        connections[account].connection_state = ConnectionState.CONNECTED;
        connections[account].provisional_stream_retained = false;
        connections[account].terminal_disconnect_requested = false;
        connections[account].suspend_terminal_generation = 0;
        connections[account].established = new DateTime.now_utc();
        connections[account].last_activity = new DateTime.now_utc();
        connection_errors.unset(account);
        stream_opened(account, stream);
        connection_state_changed(account, ConnectionState.CONNECTED);
    }

    internal void set_connection_state_for_tests(Account account,
            ConnectionState state) {
        change_connection_state(account, state);
    }

    internal void set_provisional_disconnected_for_tests(Account account) {
        change_connection_state(account, ConnectionState.DISCONNECTED, true);
    }

    internal void set_stream_replacement_pending_for_tests(Account account) {
        change_connection_state(account, ConnectionState.DISCONNECTED, false,
            true);
    }

    internal void prepare_for_sleep_for_tests(bool suspend) {
        queue_prepare_for_sleep(suspend);
    }

    internal bool is_prepare_for_sleep_idle_for_tests() {
        return !prepare_for_sleep_active && prepare_for_sleep_requests.is_empty;
    }

    internal bool is_suspend_reconnect_owned_for_tests(Account account) {
        if (!suspend_reconnect_accounts.has_key(account) ||
                !connections.has_key(account)) return false;
        SuspendAccountSnapshot snapshot = suspend_reconnect_accounts[account];
        return connections[account] == snapshot.connection &&
            connections[account].suspend_terminal_generation ==
                snapshot.cycle_generation;
    }

    internal uint get_suspend_cycle_generation_for_tests() {
        return suspend_cycle_generation;
    }

    internal void intercept_connect_stream_for_tests() {
        connect_stream_intercepted_for_tests = true;
        intercepted_connect_accounts_for_tests.clear();
    }

    internal int get_intercepted_connect_count_for_tests(Account account) {
        int count = 0;
        foreach (Account candidate in intercepted_connect_accounts_for_tests) {
            if (candidate.equals(account)) count++;
        }
        return count;
    }

    internal XmppStream? get_assigned_stream_for_tests(Account account) {
        return connections.has_key(account) ? connections[account].stream :
            null;
    }

    internal bool is_connection_ongoing_for_tests(Account account) {
        return connection_ongoing.has_key(account) &&
            connection_ongoing[account];
    }

    internal bool is_readiness_blocked_for_tests(Account account) {
        return connections.has_key(account) &&
            connections[account].readiness_blocked;
    }

    internal void remove_managed_account_for_tests(Account account) {
        connections.unset(account);
        connection_ongoing.unset(account);
        connection_directly_retry.unset(account);
    }

    public XmppStream? get_stream(Account account) {
        if (get_state(account) == ConnectionState.CONNECTED &&
                is_account_ready(account) &&
                !connections[account].readiness_blocked) {
            return connections[account].stream;
        }
        return null;
    }

    internal XmppStream? get_provisionally_retained_stream(Account account) {
        if (!connections.has_key(account) ||
                connections[account].readiness_blocked ||
                !is_account_ready(account) ||
                !connections[account].provisional_stream_retained) return null;
        return connections[account].stream;
    }

    internal bool is_stream_replacement_pending(Account account) {
        return connections.has_key(account) &&
            connections[account].stream_replacement_pending;
    }

    internal bool is_terminal_disconnect_requested(Account account) {
        return connections.has_key(account) &&
            connections[account].terminal_disconnect_requested;
    }

    internal bool mark_stream_session_resolved(Account account,
            XmppStream stream) {
        if (!connections.has_key(account) ||
                connections[account].stream != stream ||
                connections[account].terminal_disconnect_requested ||
                connections[account].readiness_blocked ||
                !is_account_ready(account)) {
            return false;
        }
        connections[account].provisional_stream_retained = false;
        connections[account].stream_replacement_pending = false;
        connections[account].terminal_disconnect_requested = false;
        connections[account].suspend_terminal_generation = 0;
        return true;
    }

    internal bool is_current_or_provisionally_retained_stream(Account account,
            XmppStream stream) {
        if (!connections.has_key(account) ||
                connections[account].stream != stream ||
                connections[account].readiness_blocked ||
                !is_account_ready(account)) return false;
        return connections[account].connection_state == ConnectionState.CONNECTED ||
            connections[account].provisional_stream_retained;
    }

    public ConnectionState get_state(Account account) {
        if (connections.has_key(account)){
            return connections[account].connection_state;
        }
        return ConnectionState.DISCONNECTED;
    }

    public ConnectionError? get_error(Account account) {
        if (connection_errors.has_key(account)) {
            return connection_errors[account];
        }
        return null;
    }

    public DnsSecurity.Mode get_dns_security_mode(Account account) throws Error {
        return DnsSecurity.Mode.from_setting(db != null ? db.account_settings.get_value(account.id, "dns-security-mode") : null);
    }

    public string get_dns_security_resolver(Account account) {
        return db != null ? (db.account_settings.get_value(account.id, "dns-security-doh-uri") ?? "") : "";
    }

    public void apply_dns_security(Account account, DnsSecurity.Mode mode, string resolver_uri) throws Error {
        if (mode != DnsSecurity.Mode.OFF && mode != DnsSecurity.Mode.WHEN_AVAILABLE && mode != DnsSecurity.Mode.REQUIRED) {
            throw new DnsSecurity.ConfigurationError.INVALID_MODE("Select a DNSSEC/DANE mode");
        }
        if (db == null || account.id <= 0 ||
                !db.account.select().with(db.account.id, "=", account.id).single().row().is_present()) {
            throw new IOError.NOT_FOUND("The account no longer exists");
        }
        string uri_text = resolver_uri.strip();
        if (mode != DnsSecurity.Mode.OFF) {
            if (!DnsSecurity.Configuration.supported()) throw new DnsSecurity.SecurityError.UNAVAILABLE("This build has no DNSSEC/DANE support");
            if (uri_text != "") {
                var uri = Uri.parse(uri_text, UriFlags.NONE);
                if (uri.get_scheme() != "https" || uri.get_host() == null ||
                        uri.get_userinfo() != null || uri.get_fragment() != null) {
                    throw new DnsSecurity.SecurityError.INVALID_CONFIGURATION("Use an HTTPS resolver URL without credentials or a fragment");
                }
            }
            if (account.proxy_type != "none" && uri_text == "") {
                throw new DnsSecurity.SecurityError.INVALID_CONFIGURATION("A proxy connection needs an explicitly selected HTTPS DNS resolver");
            }
        }
        // One atomic, account-scoped update. Never reconnect on each field edit.
        db.exec("SAVEPOINT dns_security_settings");
        try {
            db.exec_prepared("INSERT OR REPLACE INTO account_settings (account_id, key, value) VALUES (?, ?, ?)",
                { account.id.to_string(), "dns-security-mode", mode.to_setting() });
            db.exec_prepared("INSERT OR REPLACE INTO account_settings (account_id, key, value) VALUES (?, ?, ?)",
                { account.id.to_string(), "dns-security-doh-uri", uri_text });
            db.exec("RELEASE dns_security_settings");
        } catch (Error error) {
            try {
                db.exec("ROLLBACK TO dns_security_settings");
                db.exec("RELEASE dns_security_settings");
            } catch (Error ignored) { }
            throw error;
        }
        if (connections.has_key(account)) {
            connections[account].reset();
            connections[account].terminal_disconnect_requested = false;
            if (account.enabled) start_connect_stream(account);
        }
    }

    /**
     * Get the TLS peer certificate for a connected account.
     * Returns the live certificate from the active TLS connection.
     */
    public TlsCertificate? get_peer_certificate(Account account) {
        if (!connections.has_key(account)) return null;
        var stream = connections[account].stream;
        if (stream == null) return null;
        if (stream is Xmpp.TlsXmppStream) {
            return ((Xmpp.TlsXmppStream) stream).get_tls_peer_certificate();
        }
        return null;
    }

    public Collection<Account> get_managed_accounts() {
        return connections.keys;
    }

    public void connect_account(Account account) {
        if (shutdown_requested) return;
        if (!connections.has_key(account)) {
            connections[account] = new Connection();
            connection_ongoing[account] = false;
            connection_directly_retry[account] = false;

            start_connect_stream(account);
        } else {
            if (!is_account_ready(account)) {
                // This public call is an explicit reconnect intent (including
                // the existing Tor/settings paths), unlike timer/network
                // callbacks. Preserve it until every dependency is ready.
                connections[account].readiness_reconnect_permitted = true;
                block_account_for_readiness(account);
                return;
            }
            if (connections[account].readiness_blocked) {
                connections[account].readiness_reconnect_permitted = true;
                resume_account_after_readiness(account);
                return;
            }
            if (connections[account].terminal_disconnect_requested) {
                connections[account].terminal_disconnect_requested = false;
                connections[account].suspend_terminal_generation = 0;
                connections[account].stream_replacement_pending = false;
                connections[account].reset();
                start_connect_stream(account);
            } else {
                check_reconnect(account, true);
            }
        }
    }

    public void make_offline_all() {
        shutdown_requested = true;
        foreach (Account account in connections.keys) {
            connections[account].readiness_reconnect_permitted = false;
            connections[account].readiness_resume_pending = false;
            make_offline(account);
        }
    }

    private void make_offline(Account account,
            uint suspend_terminal_generation = 0) {
        if (!connections.has_key(account)) return;
        connections[account].make_offline();
        change_connection_state(account, ConnectionState.DISCONNECTED, false,
            false, suspend_terminal_generation);
    }

    public async void disconnect_account(Account account) {
        if (connections.has_key(account)) {
            connections[account].readiness_reconnect_permitted = false;
            connections[account].readiness_resume_pending = false;
            make_offline(account);
            yield connections[account].disconnect_account();
            connections.unset(account);
            connection_ongoing.unset(account);
            connection_directly_retry.unset(account);
        }
    }

    /**
     * Close all XMPP connections without removing account state.
     * Used during application shutdown to cleanly close sockets without
     * triggering account_removed (which would wipe OMEMO identity data).
     * Waits synchronously (up to 3 s) for all streams to send
     * </stream:stream> and close their sockets.
     */
    public void disconnect_all() {
        shutdown_requested = true;
        var accounts_list = new ArrayList<Account>();
        accounts_list.add_all(connections.keys);

        foreach (Account account in accounts_list) {
            if (connections.has_key(account)) {
                connections[account].readiness_reconnect_permitted = false;
                connections[account].readiness_resume_pending = false;
            }
            make_offline(account);
        }

        if (accounts_list.size == 0) {
            connections.clear();
            return;
        }

        int pending = accounts_list.size;
        var loop = new MainLoop(MainContext.@default(), false);

        foreach (Account account in accounts_list) {
            if (!connections.has_key(account)) {
                pending--;
                continue;
            }
            connections[account].disconnect_account.begin((obj, res) => {
                pending--;
                if (pending <= 0 && loop.is_running()) loop.quit();
            });
        }

        if (pending > 0) {
            Timeout.add(3000, () => {
                debug("disconnect_all: timeout reached, proceeding with shutdown");
                if (loop.is_running()) loop.quit();
                return Source.REMOVE;
            });
            loop.run();
        }

        connections.clear();
    }

    private void start_connect_stream(Account account) {
        if (shutdown_requested) return;
        if (!connections.has_key(account)) return;
        if (!is_account_ready(account)) {
            block_account_for_readiness(account);
            return;
        }
        if (connections[account].readiness_blocked) {
            resume_account_after_readiness(account);
            return;
        }
        if (connections[account].terminal_disconnect_requested) return;
        if (device_suspended) {
            connections[account].readiness_resume_pending = true;
            return;
        }
        if (connect_stream_intercepted_for_tests) {
            intercepted_connect_accounts_for_tests.add(account);
            return;
        }
        connect_stream.begin(account, (_, res) => {
            connect_stream.end(res);
        });
    }

    private async void connect_stream(Account account) {
        if (!connections.has_key(account)) return;
        if (!is_account_ready(account)) {
            block_account_for_readiness(account);
            return;
        }

        debug("[%s] (Maybe) Establishing a new connection", account.bare_jid.to_string());

        connection_errors.unset(account);

        XmppStreamResult stream_result;

        if (connection_ongoing[account]) {
            debug("[%s] Connection attempt already in progress. Directly retry if it fails.", account.bare_jid.to_string());
            connection_directly_retry[account] = true;
            return;
        } else if (connections[account].stream != null) {
            debug("[%s] Cancelling connecting because there is already a stream", account.bare_jid.to_string());
            return;
        } else {
            connection_ongoing[account] = true;
            connection_directly_retry[account] = false;

            change_connection_state(account, ConnectionState.CONNECTING);
            
            // Save reference to detect if connection was replaced while we yield
            var my_conn = connections[account];
            string attempt_uuid = my_conn.uuid;

            stream_result = yield establish_account_stream(account);

            // Check if our connection was replaced (e.g. Tor disabled → reconnect)
            // reset() rotates uuid.  Account, Connection object and attempt
            // generation must all still match after the asynchronous establish;
            // otherwise suspend/wake or an explicit reset already superseded it.
            if (discard_stale_connect_result(account, my_conn, attempt_uuid,
                    stream_result.stream)) return;

            connections[account].stream = stream_result.stream;

            bool retry_after_failure = stream_result.stream == null &&
                stream_result.tls_errors == null &&
                stream_result.dns_security_error == null &&
                connection_directly_retry[account] &&
                !my_conn.terminal_disconnect_requested &&
                !my_conn.readiness_blocked &&
                is_account_ready(account);
            connection_ongoing[account] = false;
            connection_directly_retry[account] = false;
            if (retry_after_failure) {
                start_connect_stream(account);
                return;
            }
        }

        if (stream_result.stream == null) {
            if (stream_result.dns_security_error != null) {
                // Distinct from TLS pinning: a user certificate exception
                // cannot override DNSSEC or a published TLSA association.
                change_connection_state(account, ConnectionState.DISCONNECTED);
                set_connection_error(account, new ConnectionError(
                    ConnectionError.Source.DNS_SECURITY, stream_result.dns_security_error.message) {
                    reconnect_recomendation = ConnectionError.Reconnect.NEVER,
                    dns_security_error = stream_result.dns_security_error
                });
                return;
            }
            if (stream_result.tls_errors != null) {
                // A TLS validation failure is terminal for this attempt.  Do
                // not leave a previous resumable MUC session suspended behind
                // a replacement stream that can never be negotiated.
                change_connection_state(account,
                    ConnectionState.DISCONNECTED);
                var error = new ConnectionError(ConnectionError.Source.TLS, null) { 
                    reconnect_recomendation = ConnectionError.Reconnect.NEVER,
                    tls_flags = stream_result.tls_errors,
                    tls_certificate = stream_result.tls_certificate,
                    tls_domain = account.domainpart
                };
                set_connection_error(account, error);
                return;
            }

            debug("[%s] Could not connect", account.bare_jid.to_string());

            change_connection_state(account, ConnectionState.DISCONNECTED,
                false, true);

            check_reconnect(account, true);

            return;
        }

        XmppStream stream = stream_result.stream;

        debug("[%s] New connection: %p", account.full_jid.to_string(), stream);

        connections[account].established = new DateTime.now_utc();
        stream.attached_modules.connect((stream) => {
            if (!connections.has_key(account) ||
                    connections[account].stream != stream ||
                    connections[account].terminal_disconnect_requested ||
                    connections[account].readiness_blocked ||
                    !is_account_ready(account)) {
                if (connections.has_key(account) &&
                        connections[account].stream == stream &&
                        !is_account_ready(account)) {
                    block_account_for_readiness(account);
                }
                return;
            }
            stream_attached_modules(account, stream);
            change_connection_state(account, ConnectionState.CONNECTED);

//            stream.get_module<Xep.Muji.Module>(Xep.Muji.Module.IDENTITY).join_call(stream, new Jid("test@muc.poez.io"), true);
        });
        stream.get_module<Sasl.Module>(Sasl.Module.IDENTITY).received_auth_failure.connect((stream, node) => {
            if (!connections.has_key(account) ||
                    connections[account].stream != stream) return;
            // Close the small window in which a SASL failure was already
            // known but suspend could still claim the connection as its own.
            change_connection_state(account, ConnectionState.DISCONNECTED);
            set_connection_error(account, new ConnectionError(ConnectionError.Source.SASL,
                stream.get_flag(Sasl.Flag.IDENTITY)?.failure_reason));
        });
        stream.get_module<Sasl.Module>(Sasl.Module.IDENTITY).channel_binding_failed.connect((stream) => {
            if (!connections.has_key(account) ||
                    connections[account].stream != stream) return;
            change_connection_state(account, ConnectionState.DISCONNECTED);
            set_connection_error(account, new ConnectionError(ConnectionError.Source.SASL, "channel-binding-required"));
        });

        string connection_uuid = connections[account].uuid;
        stream.received_node.connect(() => {
            if (connections.has_key(account) &&
                    connections[account].stream == stream &&
                    connections[account].uuid == connection_uuid &&
                    !connections[account].readiness_blocked &&
                    is_account_ready(account)) {
                connections[account].last_activity = new DateTime.now_utc();
            } else {
                warning("Got node for outdated connection");
            }
        });
        if (!is_account_ready(account)) {
            block_account_for_readiness(account);
            return;
        }
        stream_opened(account, stream);

        try {
            yield stream.loop();
        } catch (Error e) {
            debug("[%s %p] Connection error: %s", account.bare_jid.to_string(), stream, e.message);

            if (!connections.has_key(account) ||
                    connections[account].stream != stream) return;

            // Explicit logout, shutdown and suspend already moved this
            // connection to a terminal DISCONNECTED state.  The resulting
            // cancelled stream loop must not turn that terminal decision back
            // into an automatic replacement/resume attempt.
            if (finish_terminal_stream_loop(account, stream)) return;

            ConnectionError? pending_error = connection_errors[account];
            bool replacement_expected = pending_error == null ||
                ((!) pending_error).source != ConnectionError.Source.SASL;
            change_connection_state(account, ConnectionState.DISCONNECTED,
                false, replacement_expected);
            if (!connections.has_key(account)) return;
            connections[account].reset();

            StreamError.Flag? flag = stream.get_flag(StreamError.Flag.IDENTITY);
            if (flag != null) {
                warning(@"[%s %p] Stream Error: %s", account.bare_jid.to_string(), stream, flag.error_type);
                set_connection_error(account, new ConnectionError(ConnectionError.Source.STREAM_ERROR, flag.error_type));

                if (flag.resource_rejected) {
                    account.set_random_resource();
                    start_connect_stream(account);
                    return;
                }
            }

            ConnectionError? error = connection_errors[account];
            if (error != null && error.source == ConnectionError.Source.SASL) {
                return;
            }

            check_reconnect(account, true);
        }
    }

    private bool finish_terminal_stream_loop(Account account,
            XmppStream stream) {
        if (!connections.has_key(account) ||
                connections[account].stream != stream) return true;
        Connection connection = connections[account];
        if (!connection.terminal_disconnect_requested) return false;

        // Explicit logout, shutdown and suspend already own the asynchronous
        // disconnect that cancelled stream.loop().  Rotate the generation and
        // detach state without launching a second disconnect on that stream.
        connection.reset(!connection.is_disconnecting(stream));
        return true;
    }

    internal bool finish_terminal_stream_loop_for_tests(Account account,
            XmppStream stream) {
        return finish_terminal_stream_loop(account, stream);
    }

    internal virtual async XmppStreamResult establish_account_stream(
            Account account) {
        Connection? owner = connections[account];
        if (owner == null) return new XmppStreamResult() { io_error = new IOError.CANCELLED("Account removed") };
        DnsSecurity.Mode mode;
        try {
            mode = DnsSecurity.Mode.from_setting(db != null ? db.account_settings.get_value(account.id, "dns-security-mode") : null);
        } catch (Error error) {
            return new XmppStreamResult() { dns_security_error = error };
        }
        owner.cancel_dns_attempt();
        var attempt = new DnsSecurity.Attempt(mode);
        owner.dns_attempt = attempt;
        var configuration = new DnsSecurity.Configuration(attempt,
            db != null ? db.account_settings.get_value(account.id, "dns-security-doh-uri") : null);
        // All target/proxy values below are copied before the first yield. A
        // route edit cancels this attempt immediately, even if its UI reconnect
        // waits for several fields to be saved together.
        ulong route_handler = account.notify.connect((property) => {
            if (property.name.has_prefix("proxy-") || property.name == "custom-host" ||
                    property.name == "custom-port" || property.name == "enabled" || property.name == "password") {
                attempt.cancel();
            }
        });
        // Pass custom host/port if configured.
        uint16 custom_port = (account.custom_port > 0 &&
            account.custom_port <= 65535) ? (uint16) account.custom_port : 0;
        uint16 proxy_port = (account.proxy_port > 0 &&
            account.proxy_port <= 65535) ? (uint16) account.proxy_port : 0;
        try {
            return yield Xmpp.establish_stream(account.bare_jid,
                module_manager.get_modules(account), log_options,
                (peer_cert, errors) => {
                    return on_invalid_certificate_for_account(account, peer_cert,
                        errors);
                },
                account.custom_host, custom_port,
                account.proxy_type, account.proxy_host, proxy_port,
                account.proxy_user, account.proxy_pass, configuration);
        } finally {
            SignalHandler.disconnect(account, route_handler);
        }
    }

    private bool discard_stale_connect_result(Account account,
            Connection attempt_connection, string attempt_uuid,
            XmppStream? result_stream) {
        bool same_connection = connections.has_key(account) &&
            connections[account] == attempt_connection;
        if (same_connection && !is_account_ready(account)) {
            block_account_for_readiness(account);
        }
        bool current_attempt = same_connection &&
            attempt_connection.uuid == attempt_uuid &&
            !attempt_connection.terminal_disconnect_requested &&
            !attempt_connection.readiness_blocked &&
            is_account_ready(account);
        if (current_attempt) return false;

        debug("[%s] Connection attempt was superseded while connecting, discarding late result",
            account.bare_jid.to_string());
        if (result_stream != null) ((!) result_stream).disconnect.begin();

        // The account-wide flags may already belong to a replacement
        // Connection.  Only the original owner may complete them.  A wake
        // request made while establish_stream() was in flight is coalesced in
        // connection_directly_retry and starts exactly one successor now.
        if (same_connection) {
            bool retry = connection_directly_retry[account] &&
                !attempt_connection.terminal_disconnect_requested &&
                !attempt_connection.readiness_blocked &&
                is_account_ready(account) &&
                !device_suspended &&
                attempt_connection.stream == null;
            connection_ongoing[account] = false;
            connection_directly_retry[account] = false;
            if (retry) start_connect_stream(account);
        }
        return true;
    }

    private void check_reconnects(bool directly_reconnect = false) {
        foreach (Account account in connections.keys) {
            check_reconnect(account, directly_reconnect);
        }
    }

    private void check_reconnect(Account account, bool directly_reconnect = false) {
        if (!connections.has_key(account)) return;
        if (!is_account_ready(account)) {
            block_account_for_readiness(account);
            return;
        }
        if (connections[account].readiness_blocked) return;
        if (connections[account].terminal_disconnect_requested) return;

        bool acked = false;
        DateTime? last_activity_was = connections[account].last_activity;

        if (connections[account].stream == null) {
            if (!directly_reconnect) return;
            uint reconnect_generation = connections[account].reconnect_generation;
            Timeout.add_seconds(10, () => {
                if (!connections.has_key(account)) return false;
                if (!is_account_ready(account)) {
                    block_account_for_readiness(account);
                    return false;
                }
                if (connections[account].readiness_blocked) return false;
                if (connections[account].terminal_disconnect_requested) {
                    return false;
                }
                if (connections[account].stream != null) return false;
                if (connections[account].last_activity != last_activity_was) return false;
                if (connections[account].reconnect_generation != reconnect_generation) return false;
                if (!is_stalled_stream_reconnect_allowed(connections[account].connection_state, true)) return false;

                start_connect_stream(account);
                return false;
            });
            return;
        }

        XmppStream stream = connections[account].stream;
        // A replacement transport that has not negotiated yet owns its own
        // progress/failure path.  Sending a recovery ping here can neither
        // prove the old session nor safely restart the new one.
        if (!stream.negotiation_complete) return;
        bool allow_disconnected_stream_reconnect = directly_reconnect;
        uint reconnect_generation = connections[account].reconnect_generation;
        ConnectionState state_at_check = connections[account].connection_state;
        if (!is_stalled_stream_reconnect_allowed(state_at_check, allow_disconnected_stream_reconnect)) return;

        Xep.Ping.Module ping_module = stream.get_module<Xep.Ping.Module>(Xep.Ping.Module.IDENTITY);
        ping_module.send_ping.begin(stream, account.bare_jid.domain_jid, (_, res) => {
            Iq.Stanza? ping_result = ping_module.send_ping.end(res);
            if (ping_result == null) {
                if (!connections.has_key(account)) return;
                if (!is_account_ready(account)) {
                    block_account_for_readiness(account);
                    return;
                }
                if (connections[account].readiness_blocked) return;
                if (connections[account].stream != stream) return;
                if (connections[account].reconnect_generation != reconnect_generation) return;
                if (connections[account].last_activity != last_activity_was) return;
                reconnect_stalled_stream(account, stream, "Server ping failed", reconnect_generation, allow_disconnected_stream_reconnect);
                return;
            }
            if (!connections.has_key(account)) return;
            if (!is_account_ready(account)) {
                block_account_for_readiness(account);
                return;
            }
            if (connections[account].readiness_blocked) return;
            if (connections[account].stream != stream) return;
            if (connections[account].reconnect_generation != reconnect_generation) return;
            if (!is_stalled_stream_reconnect_allowed(connections[account].connection_state, allow_disconnected_stream_reconnect)) return;
            acked = true;
            change_connection_state(account, ConnectionState.CONNECTED);
        });

        Timeout.add_seconds(10, () => {
            if (!connections.has_key(account)) return false;
            if (!is_account_ready(account)) {
                block_account_for_readiness(account);
                return false;
            }
            if (connections[account].readiness_blocked) return false;
            if (connections[account].stream != stream) return false;
            if (connections[account].reconnect_generation != reconnect_generation) return false;
            if (acked) return false;
            if (connections[account].last_activity != last_activity_was) return false;

            // Reconnect. Nothing gets through the stream.
            reconnect_stalled_stream(account, stream, "Server ping timed out", reconnect_generation, allow_disconnected_stream_reconnect);
            return false;
        });
    }

    private void reconnect_stalled_stream(Account account, XmppStream stream, string reason, uint reconnect_generation, bool allow_disconnected_state = false) {
        if (!connections.has_key(account)) return;
        if (!is_account_ready(account)) {
            block_account_for_readiness(account);
            return;
        }
        if (connections[account].readiness_blocked) return;
        if (connections[account].terminal_disconnect_requested) return;
        if (connections[account].stream != stream) return;
        if (connections[account].reconnect_generation != reconnect_generation) return;
        ConnectionState current_state = connections[account].connection_state;
        if (!is_stalled_stream_reconnect_allowed(current_state, allow_disconnected_state)) return;

        debug("[%s %p] %s. Reconnecting", account.bare_jid.to_string(), stream, reason);
        change_connection_state(account, ConnectionState.DISCONNECTED, false,
            true);

        connections[account].reset();
        start_connect_stream(account);
    }

    private bool is_stalled_stream_reconnect_allowed(ConnectionState state, bool allow_disconnected_state) {
        if (state == ConnectionState.CONNECTED || state == ConnectionState.CONNECTING) return true;
        if (allow_disconnected_state && state == ConnectionState.DISCONNECTED) return true;
        return false;
    }

    private bool network_is_online() {
        /* FIXME: We should also check for connectivity eventually. For more
         * details on why we don't do it for now, see:
         *
         * - https://github.com/dino/dino/pull/236#pullrequestreview-86851793
         * - https://bugzilla.gnome.org/show_bug.cgi?id=792240
         */
        return network_monitor != null && network_monitor.network_available;
    }

    private void on_network_changed() {
        if (network_is_online()) {
            debug("NetworkMonitor: Network reported online");
            check_reconnects(true);
        } else {
            debug("NetworkMonitor: Network reported offline");
            foreach (Account account in connections.keys) {
                change_connection_state(account,
                    ConnectionState.DISCONNECTED, true);
            }
        }
    }

    private void on_prepare_for_sleep(bool suspend) {
        queue_prepare_for_sleep(suspend);
    }

    private void queue_prepare_for_sleep(bool suspend) {
        prepare_for_sleep_requests.add(suspend);
        start_prepare_for_sleep_processing();
    }

    private void start_prepare_for_sleep_processing() {
        if (prepare_for_sleep_active) return;

        prepare_for_sleep_active = true;
        process_prepare_for_sleep_requests.begin((_, res) => {
            process_prepare_for_sleep_requests.end(res);
            prepare_for_sleep_active = false;
            // A request can arrive after the coroutine consumed its last item
            // but before its completion callback ran.
            if (!prepare_for_sleep_requests.is_empty) {
                start_prepare_for_sleep_processing();
            }
        });
    }

    private async void process_prepare_for_sleep_requests() {
        while (!prepare_for_sleep_requests.is_empty) {
            bool suspend = prepare_for_sleep_requests.remove_at(0);
            yield handle_prepare_for_sleep(suspend);
        }
    }

    private uint next_suspend_cycle_generation() {
        suspend_cycle_generation++;
        if (suspend_cycle_generation == 0) suspend_cycle_generation = 1;
        return suspend_cycle_generation;
    }

    private async void handle_prepare_for_sleep(bool suspend) {
        if (suspend) {
            if (device_suspended) return;
            debug("Login1: Device suspended");

            uint cycle_generation = next_suspend_cycle_generation();
            suspend_reconnect_accounts.clear();
            var accounts = new ArrayList<Account>();
            accounts.add_all(connections.keys);
            var snapshots = new ArrayList<SuspendAccountSnapshot>();

            // This complete account/connection/stream snapshot and all owned
            // terminal transitions happen before the first disconnect yields.
            // Wake therefore sees either the whole cycle or none of it.
            foreach (Account account in accounts) {
                if (!connections.has_key(account)) continue;
                Connection connection = connections[account];
                if (!is_account_ready(account)) {
                    block_account_for_readiness(account);
                    continue;
                }
                if (connection.readiness_blocked) continue;
                if (connection.terminal_disconnect_requested) continue;

                var snapshot = new SuspendAccountSnapshot(account, connection,
                    connection.stream, cycle_generation);
                snapshots.add(snapshot);
                make_offline(account, cycle_generation);
                if (connections.has_key(account) &&
                        connections[account] == connection &&
                        connection.terminal_disconnect_requested &&
                        connection.suspend_terminal_generation ==
                            cycle_generation) {
                    suspend_reconnect_accounts[account] = snapshot;
                }
            }
            device_suspended = true;

            foreach (SuspendAccountSnapshot snapshot in snapshots) {
                XmppStream? stream = snapshot.stream;
                if (stream == null) continue;
                yield snapshot.connection.disconnect_stream_once((!) stream);
            }
        } else {
            if (!device_suspended) return;
            debug("Login1: Device un-suspend");
            uint cycle_generation = suspend_cycle_generation;
            var snapshots = new ArrayList<SuspendAccountSnapshot>();
            snapshots.add_all(suspend_reconnect_accounts.values);
            suspend_reconnect_accounts.clear();
            device_suspended = false;

            foreach (SuspendAccountSnapshot snapshot in snapshots) {
                Account account = snapshot.account;
                if (!connections.has_key(account)) continue;
                Connection connection = connections[account];
                if (snapshot.cycle_generation != cycle_generation ||
                        connection != snapshot.connection ||
                        !connection.terminal_disconnect_requested ||
                        connection.suspend_terminal_generation !=
                            cycle_generation ||
                        (connection.stream != null &&
                         connection.stream != snapshot.stream)) continue;

                // Only this exact suspend-owned terminal may become retryable.
                // TLS/SASL/user terminals, removed accounts and replacement
                // connection/stream objects cannot pass the ownership fence.
                connection.terminal_disconnect_requested = false;
                connection.suspend_terminal_generation = 0;
                connection.stream_replacement_pending = false;
                // The exact captured stream was already awaited by the
                // serialized suspend phase.  Detach/reset it without starting
                // a second asynchronous disconnect beside the wake reconnect.
                connection.reset(false);
                start_connect_stream(account);
            }

            // Accounts first connected while suspended, or whose dependency
            // recovered after readiness had superseded the suspend snapshot,
            // are not represented by suspend_reconnect_accounts. Resume each
            // of those explicit intents once after the normal ownership pass.
            var pending_accounts = new ArrayList<Account>();
            pending_accounts.add_all(connections.keys);
            foreach (Account account in pending_accounts) {
                if (!connections.has_key(account)) continue;
                Connection connection = connections[account];
                if (!connection.readiness_resume_pending) continue;
                connection.readiness_resume_pending = false;
                if (connection.readiness_blocked ||
                        connection.terminal_disconnect_requested ||
                        !is_account_ready(account)) continue;
                if (connection_ongoing.has_key(account) &&
                        connection_ongoing[account]) {
                    connection_directly_retry[account] = true;
                } else if (connection.stream == null) {
                    start_connect_stream(account);
                }
            }
        }
    }

    private void change_connection_state(Account account, ConnectionState state,
            bool retain_stream_provisionally = false,
            bool await_stream_replacement = false,
            uint suspend_terminal_generation = 0) {
        if (connections.has_key(account)) {
            if (state == ConnectionState.CONNECTED &&
                    (connections[account].readiness_blocked ||
                     !is_account_ready(account))) {
                if (!is_account_ready(account)) {
                    block_account_for_readiness(account);
                }
                return;
            }
            if (state == ConnectionState.DISCONNECTED) {
                connections[account].invalidate_reconnect_checks();
                if (!retain_stream_provisionally &&
                        !await_stream_replacement &&
                        suspend_terminal_generation == 0 &&
                        !connections[account]
                            .readiness_terminal_transition) {
                    connections[account].readiness_reconnect_permitted = false;
                    connections[account].readiness_resume_pending = false;
                }
            }
            if (state == ConnectionState.DISCONNECTED) {
                // Only a negotiated, previously connected transport can be
                // retained as the same session.  In particular, an offline
                // notification must not reclassify an unnegotiated replacement
                // stream while XEP-0198 fresh-vs-resumed is still pending.
                bool was_terminal = connections[account]
                    .terminal_disconnect_requested;
                bool retain_same_stream = !was_terminal &&
                    retain_stream_provisionally &&
                    connections[account].stream != null &&
                    !connections[account].stream_replacement_pending &&
                    (connections[account].connection_state ==
                        ConnectionState.CONNECTED ||
                     connections[account].provisional_stream_retained);
                connections[account].provisional_stream_retained =
                    retain_same_stream;
                if (was_terminal) {
                    connections[account].stream_replacement_pending = false;
                    // A later explicit terminal decision supersedes suspend
                    // ownership.  Network/offline bookkeeping must not.
                    if (!retain_stream_provisionally &&
                            !await_stream_replacement &&
                            suspend_terminal_generation == 0) {
                        connections[account].suspend_terminal_generation = 0;
                    }
                } else if (retain_same_stream) {
                    connections[account].stream_replacement_pending = false;
                    connections[account].suspend_terminal_generation = 0;
                } else if (await_stream_replacement ||
                        retain_stream_provisionally) {
                    // An offline event during CONNECTING is not a user-requested
                    // terminal shutdown.  Keep it retryable, while never
                    // treating its unnegotiated stream as the retained one.
                    connections[account].stream_replacement_pending = true;
                    connections[account].suspend_terminal_generation = 0;
                } else {
                    connections[account].stream_replacement_pending = false;
                    connections[account].terminal_disconnect_requested = true;
                    connections[account].cancel_dns_attempt();
                    connections[account].suspend_terminal_generation =
                        suspend_terminal_generation;
                    discard_stream_management_session(account);
                }
            } else if (state == ConnectionState.CONNECTED) {
                connections[account].provisional_stream_retained = false;
                connections[account].suspend_terminal_generation = 0;
                if (!connections[account].stream_replacement_pending) {
                    connections[account].terminal_disconnect_requested =
                        false;
                }
            }
            connections[account].connection_state = state;
            connection_state_changed(account, state);
        }
    }

    private void discard_stream_management_session(Account account) {
        Xep.StreamManagement.Module? stream_management = module_manager
            .get_module<Xep.StreamManagement.Module>(account,
                Xep.StreamManagement.Module.IDENTITY);
        if (stream_management != null) {
            ((!) stream_management).discard_session(
                "Terminal account disconnect",
                connections.has_key(account) ? connections[account].stream :
                    null);
        }
    }

    private void set_connection_error(Account account, ConnectionError error) {
        connection_errors[account] = error;
        connection_error(account, error);

        // Auto-trigger certificate dialog for TLS errors with certificate info
        if (error.source == ConnectionError.Source.TLS && error.tls_certificate != null) {
            certificate_validation_required(account, error.tls_certificate, error.tls_flags);
        }
    }

    /**
     * Validates a TLS certificate. Returns true if the certificate should be accepted.
     * This method checks for pinned certificates and special cases like .onion domains.
     */
    public bool on_invalid_certificate_for_account(Account account, TlsCertificate peer_cert, TlsCertificateFlags errors) {
        string domain = account.domainpart;
        
        // .onion domains get special treatment - accept unknown CA
        if (domain.has_suffix(".onion") && errors == TlsCertificateFlags.UNKNOWN_CA) {
            warning("Accepting TLS certificate from unknown CA from .onion address %s", domain);
            return true;
        }

        // Check if certificate is already pinned
        if (db != null) {
            string cert_fp = CertificateManager.get_certificate_fingerprint(peer_cert);
            string? pinned_fp = db.pinned_certificate.get_pinned_fingerprint(domain);

            if (pinned_fp != null && pinned_fp == cert_fp) {
                // Certificate matches pinned fingerprint - accept it
                debug("Certificate for %s matches pinned fingerprint, accepting", domain);
                return true;
            }
        }

        // Certificate not trusted - will trigger connection error with cert info
        // The UI can then show a dialog to pin the certificate
        warning("TLS certificate for %s not trusted (flags: %s)", domain, errors.to_string());
        return false;
    }

    public static bool on_invalid_certificate(string domain, TlsCertificate peer_cert, TlsCertificateFlags errors, Database? db = null) {
        if (domain.has_suffix(".onion") && errors == TlsCertificateFlags.UNKNOWN_CA) {
            // It's barely possible for .onion servers to provide a non-self-signed cert.
            // But that's fine because encryption is provided independently though TOR.
            warning("Accepting TLS certificate from unknown CA from .onion address %s", domain);
            return true;
        }

        // Check if certificate is pinned (e.g. self-signed certs accepted by user for XMPP connection)
        // This ensures HTTP file uploads/downloads work with the same pinned certs
        if (db != null) {
            string cert_fp = CertificateManager.get_certificate_fingerprint(peer_cert);
            string? pinned_fp = db.pinned_certificate.get_pinned_fingerprint(domain);

            if (pinned_fp != null && pinned_fp == cert_fp) {
                debug("HTTP certificate for %s matches pinned fingerprint, accepting", domain);
                return true;
            }
        }

        return false;
    }

    /**
     * Pin a certificate for the given domain. Call this when user accepts an untrusted certificate.
     */
    public void pin_certificate(string domain, TlsCertificate cert, TlsCertificateFlags flags) {
        if (db == null) return;
        CertificateManager.pin_to_db(db, domain, cert, flags);
    }

    /**
     * Remove a pinned certificate for the given domain.
     */
    public void unpin_certificate(string domain) {
        if (db == null) return;
        
        db.pinned_certificate.delete()
            .with(db.pinned_certificate.domain, "=", domain)
            .perform();
        debug("Certificate unpinned for domain %s", domain);
    }

    /**
     * Check if a certificate is pinned for the given domain.
     */
    public bool is_certificate_pinned(string domain) {
        if (db == null) return false;
        return db.pinned_certificate.get_pinned_fingerprint(domain) != null;
    }

    /**
     * Get information about a pinned certificate.
     */
    public CertificateInfo? get_pinned_certificate_info(string domain) {
        if (db == null) return null;
        return CertificateManager.get_pinned_info_from_db(db, domain);
    }
}

}
