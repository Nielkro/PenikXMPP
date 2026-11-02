/*
 * MqttClient — libmosquitto wrapper with GLib Main Loop integration.
 *
 * Instead of mosquitto_loop_start() (which spawns a thread), we integrate
 * the mosquitto socket into GLib's main loop via IOChannel + Timeout.
 * This keeps everything on the GTK main thread — no locking needed.
 *
 * Flow:
 *   1. mosquitto_connect() runs in a GLib.Thread (blocks for TCP handshake)
 *   2. On success: IOChannel watch on the socket fd for IN/ERR/HUP
 *   3. loop_read()  — processes incoming MQTT packets, fires callbacks
 *   4. loop_write() — flushes outgoing data (triggered when want_write())
 *   5. loop_misc()  — keepalive + housekeeping, every 1 second via Timeout
 *   6. On disconnect: teardown sources, schedule reconnect after 5 seconds
 *
 * Platform notes:
 *   Linux:   IOChannel.unix_new() for socket, /etc/ssl/certs/ for CA certs
 *   Windows: IOChannel.win32_new_socket() for Winsock, bundled ssl/certs/ca-bundle.crt
 *
 * Requires: libmosquitto-dev (apt install libmosquitto-dev)
 *           MSYS2: pacman -S mingw-w64-x86_64-mosquitto
 */

using GLib;

namespace Dino.Plugins.Mqtt {

public class MqttClient : Object {

    public bool is_connected { get; private set; default = false; }

    /** Emitted on incoming message (topic + raw payload bytes + QoS + retained). */
    public signal void on_message(string topic, uint8[] payload, int qos, bool retained);

    /** Emitted on incoming message with MQTT 5.0 User Properties.
     *  The properties HashMap maps name→value string pairs.
     *  Only emitted if the message actually carries user properties. */
    public signal void on_message_properties(string topic,
                                              Gee.HashMap<string, string> properties);

    /** Emitted when MQTT connection state changes. */
    public signal void on_connection_changed(bool connected);

    /* ── Private state ───────────────────────────────────────────── */

    private Mosquitto.Client? mosq = null;
    private Xmpp.DnsSecurity.Attempt? dns_attempt;
    private bool dns_lookup_pending;
    private string broker_dns_mode = "off";
    private string? broker_dns_resolver;
    public string? security_error { get; private set; }
    public bool dane_verified { get; private set; default = false; }
    public bool uses_tls { get { return broker_use_tls; } }
#if HAVE_DNSSEC
    private DinoDns.Native.TlsContext? tls_context;
#endif
    private GLib.IOChannel? io_channel = null;
    private uint io_watch_id = 0;
    private uint write_watch_id = 0;
    private uint misc_timer_id = 0;
    private uint reconnect_timer_id = 0;
    private uint reconnect_connack_timeout_id = 0;
    private uint operation_generation = 0;
    private bool tcp_operation_in_progress = false;
    private bool initial_connack_pending = false;

    /* Exponential reconnect backoff (Robustness R2) */
    private uint reconnect_delay_secs = 5;
    private const uint RECONNECT_DELAY_MIN = 5;
    private const uint RECONNECT_DELAY_MAX = 300;  /* 5 minutes */

    /* Stored for reconnection */
    private string broker_host = "";
    private int broker_port = 1883;
    private bool broker_use_tls = false;
    private string? broker_username = null;
    private string? broker_password = null;
    private bool initial_connect_done = false;

    /* Proxy settings for SOCKS5/Tor */
    private string? broker_proxy_type = null;
    private string? broker_proxy_host = null;
    private int broker_proxy_port = 0;
    private string? broker_proxy_user = null;
    private string? broker_proxy_pass = null;

    /* Topics to re-subscribe after reconnect */
    private Gee.HashMap<string, int> subscribed_topics =
        new Gee.HashMap<string, int>();

    /* LWT (Last Will and Testament) — set before connect */
    private string? lwt_topic = null;
    private string lwt_payload = "offline";

    /* Instance registry for C callback dispatch.
     * mosquitto_new() stores a userdata pointer that is passed to every
     * callback.  We pass the instance_id, then look up the MqttClient. */
    private static uint _next_instance_id = 1;
    /* BUG-19 note: uint overflow wraps safely to 0 at 4 billion; benign */
    private static Gee.HashMap<uint, unowned MqttClient>? _instances = null;
    private uint _instance_id = 0;

    private static bool _lib_initialized = false;

    /* ── Construction / Destruction ──────────────────────────────── */

    public MqttClient() {
        if (!_lib_initialized) {
            Mosquitto.lib_init();
            _lib_initialized = true;
        }
        if (_instances == null) {
            _instances = new Gee.HashMap<uint, unowned MqttClient>();
        }
        _instance_id = _next_instance_id++;
        _instances[_instance_id] = this;
    }

    ~MqttClient() {
        disconnect_sync();
        if (_instances != null) {
            _instances.unset(_instance_id);
        }
    }

    /* ── Connect ─────────────────────────────────────────────────── */

    /**
     * Set the Last Will and Testament (LWT) for this connection.
     * Must be called BEFORE connect_async().
     * The broker will publish this message if the client disconnects
     * unexpectedly (without a clean DISCONNECT packet).
     */
    public void set_will(string topic, string payload) {
        lwt_topic = topic;
        lwt_payload = payload;
    }

    /**
     * Connect to an MQTT broker.
     *
     * The TCP handshake runs in a background thread so the GTK main loop
     * is not blocked. After TCP succeeds, GLib sources are installed and
     * the CONNACK callback sets is_connected = true.
     *
     * Returns true if TCP connect + CONNACK succeeded within the timeout.
     */
    public async bool connect_async(string host, int port = 1883, bool use_tls = false,
            string? username = null, string? password = null, string? proxy_type = null,
            string? proxy_host = null, int proxy_port = 0, string? proxy_user = null,
            string? proxy_pass = null, string dns_mode = "off", string? dns_resolver = null) {
        if (is_connected) return true;
        if (tcp_operation_in_progress || dns_lookup_pending) return false;
        disconnect_sync();
        security_error = null;
        dane_verified = false;
        broker_dns_mode = dns_mode;
        broker_dns_resolver = dns_resolver;
        Xmpp.DnsSecurity.Attempt? attempt = null;
        try {
            var mode = Xmpp.DnsSecurity.Mode.from_setting(dns_mode);
            attempt = new Xmpp.DnsSecurity.Attempt(mode);
            dns_attempt = attempt;
            if (mode == Xmpp.DnsSecurity.Mode.OFF) {
                return yield connect_one(host, port, use_tls, username, password,
                    proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass);
            }
            if (!Xmpp.DnsSecurity.Configuration.supported())
                throw new Xmpp.DnsSecurity.SecurityError.UNAVAILABLE("DNSSEC/DANE is not included in this build");
            if (!use_tls)
                throw new Xmpp.DnsSecurity.SecurityError.REQUIRED("DNSSEC/DANE requires MQTT TLS");
            if (Xmpp.DnsSecurity.BrokerEndpoint.is_special(host)) {
                if (mode == Xmpp.DnsSecurity.Mode.REQUIRED)
                    throw new Xmpp.DnsSecurity.SecurityError.REQUIRED("DANE does not apply to local, IP or onion broker addresses");
                string special = host.ascii_down().strip();
                if (special.has_suffix(".")) special = special.substring(0, special.length - 1);
                if (special.has_suffix(".onion") && proxy_type != "tor" && proxy_type != "socks5")
                    throw new Xmpp.DnsSecurity.SecurityError.INVALID_CONFIGURATION("An onion broker requires a proxy");
                return yield connect_one(host, port, true, username, password,
                    proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass);
            }
            string route = "direct://";
            if (proxy_type != null && proxy_type != "none" && proxy_type != "") {
                string ph = proxy_host ?? (proxy_type == "tor" ? "127.0.0.1" : "");
                int pp = proxy_port > 0 ? proxy_port : (proxy_type == "tor" ? 9050 : 0);
                if ((proxy_type != "tor" && proxy_type != "socks5") ||
                        new InetAddress.from_string(ph) == null || pp < 1 || pp > 65535)
                    throw new Xmpp.DnsSecurity.SecurityError.INVALID_CONFIGURATION("A numeric SOCKS5 proxy endpoint is required");
                string auth = proxy_user != null && proxy_user != "" ?
                    "%s:%s@".printf(Uri.escape_string(proxy_user, null, false), Uri.escape_string(proxy_pass ?? "", null, false)) : "";
                route = "socks5://%s%s:%d".printf(auth, ph.contains(":") ? "[" + ph + "]" : ph, pp);
            }
            if (port < 1 || port > 65535)
                throw new Xmpp.DnsSecurity.SecurityError.INVALID_CONFIGURATION("Invalid MQTT port");
            dns_lookup_pending = true;
            var configuration = new Xmpp.DnsSecurity.Configuration(attempt, dns_resolver);
            var endpoints = yield Xmpp.DnsSecurity.BrokerEndpoint.lookup(configuration, host, (uint16) port, route);
            dns_lookup_pending = false;
            foreach (var endpoint in endpoints) {
                if (!attempt.is_current(dns_attempt)) return false;
                endpoint.guard.check_current();
                if (yield connect_one(endpoint.hostname, port, true, username, password,
                        proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass,
                        endpoint.address, endpoint.guard)) return true;
                if (security_error != null) break;
            }
            return false;
        } catch (Error error) {
            if (attempt != null && !attempt.is_current(dns_attempt)) return false;
            security_error = error.message;
            on_connection_changed(false);
            return false;
        } finally {
            dns_lookup_pending = false;
        }
    }

    private async bool connect_one(string host, int port = 1883,
                                    bool use_tls = false,
                                    string? username = null,
                                    string? password = null,
                                    string? proxy_type = null,
                                    string? proxy_host = null,
                                    int proxy_port = 0,
                                    string? proxy_user = null,
                                    string? proxy_pass = null,
                                    string? connect_address = null,
                                    Xmpp.DnsSecurity.HandshakeGuard? guard = null) {
        if (is_connected) {
            debug("MQTT: Already connected to %s:%d", broker_host, broker_port);
            return true;
        }
        if (tcp_operation_in_progress) {
            warning("MQTT: connect_async ignored while TCP operation is still running");
            return false;
        }
        if (mosq != null) {
            mosq.disconnect();
            mosq = null;
        }

        /* Store for reconnect */
        broker_host = host;
        broker_port = port;
        broker_use_tls = use_tls;
        broker_username = username;
        broker_password = password;
        broker_proxy_type = proxy_type;
        broker_proxy_host = proxy_host;
        broker_proxy_port = proxy_port;
        broker_proxy_user = proxy_user;
        broker_proxy_pass = proxy_pass;

        /* Create mosquitto client — pass instance_id as userdata for
         * C callback dispatch (supports multiple MqttClient instances) */
        string client_id = "dinox-%u-%lld".printf(_instance_id,
                                                   GLib.get_real_time() / 1000);
        mosq = new Mosquitto.Client(client_id, true,
                                     (void*)(int64)_instance_id);

        if (mosq == null) {
            warning("MQTT: mosquitto_new() failed");
            return false;
        }

        /* Credentials */
        if (username != null && username != "") {
            mosq.username_pw_set(username, password);
        }

        /* TLS — try common CA certificate locations */
        if (use_tls) {
            string? cafile = null;
            string? capath = null;

#if WINDOWS
            /* Windows: prefer SSL_CERT_FILE env var (set by main.vala from exe_dir),
             * then probe common locations as fallback */
            string? env_cert = Environment.get_variable("SSL_CERT_FILE");
            if (env_cert != null && FileUtils.test(env_cert, FileTest.EXISTS)) {
                cafile = env_cert;
            } else {
                string cwd = Environment.get_current_dir();
                string[] win_ca_paths = {
                    Path.build_filename(cwd, "ssl", "certs", "ca-bundle.crt"),
                    Path.build_filename(cwd, "ca-bundle.crt"),
                    "C:\\msys64\\mingw64\\ssl\\certs\\ca-bundle.crt",
                    "/mingw64/ssl/certs/ca-bundle.crt",
                };
                foreach (string p in win_ca_paths) {
                    if (FileUtils.test(p, FileTest.EXISTS)) {
                        cafile = p;
                        break;
                    }
                }
                if (cafile == null) {
                    warning("MQTT: No CA certificate bundle found — TLS may fail. " +
                            "Tried: SSL_CERT_FILE env, %s", string.joinv(", ", win_ca_paths));
                }
            }
#else
            /* Linux / macOS: standard CA certificate locations */
            if (FileUtils.test("/etc/ssl/certs/ca-certificates.crt", FileTest.EXISTS)) {
                cafile = "/etc/ssl/certs/ca-certificates.crt";
            } else if (FileUtils.test("/etc/pki/tls/certs/ca-bundle.crt", FileTest.EXISTS)) {
                cafile = "/etc/pki/tls/certs/ca-bundle.crt";
            } else if (FileUtils.test("/etc/ssl/ca-bundle.pem", FileTest.EXISTS)) {
                cafile = "/etc/ssl/ca-bundle.pem";
            } else if (FileUtils.test("/var/lib/ca-certificates/ca-bundle.pem", FileTest.EXISTS)) {
                cafile = "/var/lib/ca-certificates/ca-bundle.pem";
            } else if (FileUtils.test("/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", FileTest.EXISTS)) {
                cafile = "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem";
            } else if (FileUtils.test("/etc/ssl/cert.pem", FileTest.EXISTS)) {
                cafile = "/etc/ssl/cert.pem";
            } else if (FileUtils.test("/etc/ssl/certs/ca-bundle.crt", FileTest.EXISTS)) {
                cafile = "/etc/ssl/certs/ca-bundle.crt";
            } else if (FileUtils.test("/etc/ssl/certs", FileTest.IS_DIR)) {
                capath = "/etc/ssl/certs";
            }
#endif

#if HAVE_DNSSEC
            if (guard != null) {
                try {
                    guard.check_current();
                    tls_context = new DinoDns.Native.TlsContext(host, guard.copy_records(),
                        guard.requires_tlsa, guard.evidence_expiry, guard.attempt.cancellable, cafile, capath);
                    if (mosq.int_option(Mosquitto.Option.SSL_CTX_WITH_DEFAULTS, 0) != Mosquitto.Error.SUCCESS ||
                            mosq.void_option(Mosquitto.Option.SSL_CTX, tls_context) != Mosquitto.Error.SUCCESS)
                        throw new IOError.NOT_SUPPORTED("The MQTT library cannot enforce this TLS policy");
                } catch (Error error) {
                    security_error = error.message;
                    mosq = null;
                    on_connection_changed(false);
                    return false;
                }
            } else
#endif
            {
                int tls_rc = mosq.tls_set(cafile, capath, null, null);
                if (tls_rc != Mosquitto.Error.SUCCESS) {
                    warning("MQTT: tls_set failed (rc=%d)", tls_rc);
                    mosq = null;
                    on_connection_changed(false);
                    return false;
                }
            }
        }

        /* Install C callbacks (dispatch via static _active pointer) */
        mosq.connect_callback_set(on_connect_cb);
        mosq.disconnect_callback_set(on_disconnect_cb);

        /* LWT (Last Will and Testament) — set before connect */
        if (lwt_topic != null && lwt_topic != "") {
            uint8[] lwt_data = lwt_payload.data;
            int will_rc = mosq.will_set(lwt_topic, lwt_data.length, lwt_data, 1, true);
            if (will_rc != Mosquitto.Error.SUCCESS) {
                warning("MQTT: will_set failed (rc=%d)", will_rc);
            } else {
                debug("MQTT: LWT set — topic=%s payload=%s", lwt_topic, lwt_payload);
            }
        }

        /* Use MQTT 5.0 protocol for User Properties support.
         * The v5 message callback works for all protocol versions —
         * props will be NULL for v3.1.1 connections. */
        mosq.int_option(Mosquitto.Option.PROTOCOL_VERSION,
                         Mosquitto.PROTOCOL_V5);
        mosq.message_v5_callback_set(on_message_v5_cb);

        /* SOCKS5 proxy — must be set before connect */
        if (proxy_type == "socks5" || proxy_type == "tor") {
            string ph = (proxy_host != null && proxy_host != "") ? proxy_host : "127.0.0.1";
            int pp = (proxy_port > 0) ? proxy_port : (proxy_type == "tor" ? 9050 : 1080);
            int socks_rc = mosq.socks5_set(ph, pp,
                                            (proxy_user != null && proxy_user != "") ? proxy_user : null,
                                            (proxy_pass != null && proxy_pass != "") ? proxy_pass : null);
            if (socks_rc != Mosquitto.Error.SUCCESS) {
                warning("MQTT: socks5_set(%s:%d) failed rc=%d", ph, pp, socks_rc);
                mosq = null;
                on_connection_changed(false);
                return false;
            } else {
                GLib.log("dino-proxy", GLib.LogLevelFlags.LEVEL_DEBUG,
                         "MQTT: proxy socks5://%s:%d (auth=%s)", ph, pp,
                         (proxy_user != null && proxy_user != "") ? "yes" : "no");
            }
        }

        /* ---------- TCP connect in background thread ---------- */
        int tcp_rc = Mosquitto.Error.UNKNOWN;
        /* capture async resume callback */
        SourceFunc resume = connect_one.callback;
        unowned Mosquitto.Client? connect_mosq = mosq;
        uint connect_generation = ++operation_generation;
        tcp_operation_in_progress = true;

        new Thread<void*>("mqtt-connect", () => {
            if (connect_mosq != null) {
                tcp_rc = connect_mosq.connect(connect_address ?? host, port, 60);
            }
            Idle.add((owned) resume);
            return null;
        });
        yield;   /* resume when thread finishes */
        if (operation_generation == connect_generation || mosq == connect_mosq) {
            tcp_operation_in_progress = false;
        }

        /* BUG-3 fix: If disconnect_sync() was called while the TCP thread
         * was running, mosq is now null.  Bail out safely. */
        if (mosq == null || mosq != connect_mosq || operation_generation != connect_generation) {
            if (mosq == connect_mosq && mosq != null) {
                if (tcp_rc == Mosquitto.Error.SUCCESS) {
                    mosq.disconnect();
                }
                mosq = null;
            }
            warning("MQTT: connect_async aborted — client was disconnected during TCP handshake");
            return false;
        }

        update_security_result();
        if (tcp_rc != Mosquitto.Error.SUCCESS) {
            warning("MQTT: TCP connect to %s:%d failed (rc=%d: %s)",
                    host, port, tcp_rc, rc_to_string(tcp_rc));
            mosq = null;
            /* Notify listeners so UI doesn’t stay stuck on “Connecting…” (R3) */
            on_connection_changed(false);
            return false;
        }

        initial_connect_done = true;

        /* TCP connected — install GLib main loop sources */
        setup_glib_sources();

        debug("MQTT: TCP connected to %s:%d, waiting for CONNACK…", host, port);

        /* Wait for CONNACK (on_connect_cb stores result and resumes us) */
        int connack_rc = -1;
        bool connack_timed_out = false;
        initial_connack_pending = true;
        connack_resume = connect_one.callback;

        /* Timeout: give broker 10 s to respond */
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(10, () => {
            connack_rc = -1;    /* timeout */
            connack_timed_out = true;
            timeout_id = 0;
            if (connack_resume != null) {
                Idle.add((owned) connack_resume);
                connack_resume = null;
            }
            return false;
        });

        yield;   /* resume on CONNACK or timeout */
        if (mosq == null || mosq != connect_mosq || operation_generation != connect_generation) {
            initial_connack_pending = false;
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            connack_resume = null;
            return false;
        }

        /* If CONNACK arrived, connack_rc was written by handle_connect.
         * If we timed out, ignore any late-arriving CONNACK. */
        if (!connack_timed_out) {
            connack_rc = connack_result;
        }
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }
        connack_resume = null;
        initial_connack_pending = false;

        update_security_result();
        if (connack_rc != 0) {
            warning("MQTT: CONNACK refused (rc=%d: %s)",
                    connack_rc, connack_rc_to_string(connack_rc));
            teardown_glib_sources();
            mosq.disconnect();
            mosq = null;
            initial_connect_done = false;
            /* Notify listeners so UI doesn’t stay stuck on “Connecting…” (R3) */
            on_connection_changed(false);
            return false;
        }

        if (guard != null) {
            try { guard.check_current(); }
            catch (Error error) { security_error = error.message; disconnect_sync(); return false; }
        }
        message("MQTT: Connected to %s:%d ✔", host, port);
        return true;
    }

    /* Used to resume connect_async from the CONNACK callback */
    private SourceFunc? connack_resume = null;
    private int connack_result = -1;

    /* ── GLib Main Loop Integration ──────────────────────────────── */

    private void setup_glib_sources() {
        int fd = mosq.socket();
        if (fd < 0) {
            warning("MQTT: mosquitto_socket() returned %d", fd);
            return;
        }

#if WINDOWS
        io_channel = new IOChannel.win32_socket(fd);
#else
        io_channel = new IOChannel.unix_new(fd);
#endif
        try {
            io_channel.set_encoding(null);
        } catch (IOChannelError e) {
            warning("MQTT: set_encoding failed: %s", e.message);
        }
        io_channel.set_buffered(false);

        /* Persistent read watch */
        io_watch_id = io_channel.add_watch(
            IOCondition.IN | IOCondition.ERR | IOCondition.HUP,
            on_io_readable);

        /* Periodic housekeeping (keepalive, ping, retry) */
        misc_timer_id = Timeout.add_seconds(1, on_misc_timer);
    }

    private void teardown_glib_sources() {
        if (io_watch_id  != 0) { Source.remove(io_watch_id);  io_watch_id  = 0; }
        if (write_watch_id != 0) { Source.remove(write_watch_id); write_watch_id = 0; }
        if (misc_timer_id != 0) { Source.remove(misc_timer_id); misc_timer_id = 0; }
        if (reconnect_timer_id != 0) { Source.remove(reconnect_timer_id); reconnect_timer_id = 0; }
        if (reconnect_connack_timeout_id != 0) {
            Source.remove(reconnect_connack_timeout_id);
            reconnect_connack_timeout_id = 0;
        }
        io_channel = null;
    }

    /* ── IO callbacks ────────────────────────────────────────────── */

    private bool on_io_readable(IOChannel source, IOCondition cond) {
        if (mosq == null) return false;

        if ((cond & IOCondition.ERR) != 0 || (cond & IOCondition.HUP) != 0) {
            warning("MQTT: Socket error/hangup");
            io_watch_id = 0;
            handle_disconnect_event(Mosquitto.Error.CONN_LOST);
            return false;    /* remove this watch */
        }

        int rc = mosq.loop_read(1);
        if (rc != Mosquitto.Error.SUCCESS) {
            warning("MQTT: loop_read failed (rc=%d: %s)", rc, rc_to_string(rc));
            io_watch_id = 0;
            handle_disconnect_event(rc);
            return false;
        }

        /* Flush outgoing data if the library buffered a response */
        schedule_write_if_needed();

        return true;    /* keep watching */
    }

    private bool on_io_writable(IOChannel source, IOCondition cond) {
        if (mosq == null) {
            write_watch_id = 0;
            return false;
        }

        int rc = mosq.loop_write(1);
        if (rc != Mosquitto.Error.SUCCESS) {
            warning("MQTT: loop_write failed (rc=%d)", rc);
        }

        write_watch_id = 0;
        return false;    /* one-shot: remove write watch */
    }

    private bool on_misc_timer() {
        if (mosq == null) return false;

        int rc = mosq.loop_misc();
        if (rc != Mosquitto.Error.SUCCESS) {
            if (rc == Mosquitto.Error.NO_CONN || rc == Mosquitto.Error.CONN_LOST) {
                misc_timer_id = 0;
                handle_disconnect_event(rc);
                return false;
            }
        }

        schedule_write_if_needed();
        return true;    /* keep timer */
    }

    private void schedule_write_if_needed() {
        if (mosq != null && mosq.want_write() &&
            write_watch_id == 0 && io_channel != null) {
            write_watch_id = io_channel.add_watch(
                IOCondition.OUT, on_io_writable);
        }
    }

    /* ── Mosquitto C callbacks (static → dispatch via instance registry) ── */

    private static unowned MqttClient? lookup(void* userdata) {
        uint id = (uint)(int64)userdata;
        if (_instances != null && _instances.has_key(id)) {
            return _instances[id];
        }
        return null;
    }

    private static void on_connect_cb(Mosquitto.Client mosq,
                                      void* userdata, int rc) {
        unowned MqttClient? self = lookup(userdata);
        if (self != null) self.handle_connect(rc);
    }

    private static void on_disconnect_cb(Mosquitto.Client mosq,
                                         void* userdata, int rc) {
        unowned MqttClient? self = lookup(userdata);
        if (self != null) self.handle_disconnect_event(rc);
    }

    private static void on_message_v5_cb(Mosquitto.Client mosq,
                                       void* userdata, Mosquitto.Message* msg,
                                       Mosquitto.Property? props) {
        unowned MqttClient? self = lookup(userdata);
        if (self != null) self.handle_message(msg, props);
    }

    /* ── Instance event handlers ─────────────────────────────────── */

    private void handle_connect(int rc) {
        update_security_result();
        connack_result = rc;
        bool connect_async_waiting = initial_connack_pending;

        if (rc == 0) {
            if (reconnect_connack_timeout_id != 0) {
                Source.remove(reconnect_connack_timeout_id);
                reconnect_connack_timeout_id = 0;
            }
            is_connected = true;
            /* Reset reconnect backoff on success (R2) */
            reconnect_delay_secs = RECONNECT_DELAY_MIN;
            /* Re-subscribe topics BEFORE signal — prevents double-subscribe
             * because on_connection_changed handlers won't re-subscribe */
            foreach (var entry in subscribed_topics.entries) {
                mosq.subscribe(null, entry.key, entry.value);
                debug("MQTT: Re-subscribed to '%s' (qos=%d)", entry.key, entry.value);
            }

            on_connection_changed(true);
            debug("MQTT: CONNACK success");
        } else {
            warning("MQTT: CONNACK refused (rc=%d: %s)",
                    rc, connack_rc_to_string(rc));
            is_connected = false;
            on_connection_changed(false);
            if (!connect_async_waiting && initial_connect_done) {
                teardown_glib_sources();
                schedule_reconnect();
            }
        }

        /* Resume connect_async if it's waiting */
        if (connack_resume != null) {
            Idle.add((owned) connack_resume);
            connack_resume = null;
        }
    }

    private void update_security_result() {
#if HAVE_DNSSEC
        if (tls_context == null) return;
        int result = tls_context.result();
        dane_verified = result == 2;
        if (result < 0) security_error = result == -2 ? "DNS evidence expired before MQTT authentication" :
            result == -3 ? "MQTT connection attempt was cancelled" : "The MQTT server failed TLS/DANE verification";
#endif
    }

    private void handle_disconnect_event(int rc) {
        update_security_result();
        bool was_connected = is_connected;
        bool waiting_for_initial_connack = initial_connack_pending;
        bool should_reconnect = was_connected || initial_connect_done;
        is_connected = false;

        teardown_glib_sources();

        if (waiting_for_initial_connack) {
            initial_connect_done = false;
            initial_connack_pending = false;
            connack_result = -1;
            on_connection_changed(false);
            if (connack_resume != null) {
                Idle.add((owned) connack_resume);
                connack_resume = null;
            }
            warning("MQTT: Connection dropped before CONNACK (rc=%d: %s)",
                    rc, rc_to_string(rc));
            return;
        }

        if (should_reconnect && security_error == null) {
            on_connection_changed(false);
            warning("MQTT: Connection lost (rc=%d: %s), reconnecting in %u s…",
                    rc, rc_to_string(rc), reconnect_delay_secs);
            schedule_reconnect();
        }
    }

    private void handle_message(Mosquitto.Message* msg,
                                Mosquitto.Property? props = null) {
        /* Copy topic and payload — they're only valid during this callback */
        string topic = msg->topic;
        int qos = msg->qos;
        bool retained = msg->retain;

        uint8[] payload = new uint8[msg->payloadlen];
        if (msg->payloadlen > 0 && msg->payload != null) {
            GLib.Memory.move(payload, msg->payload, msg->payloadlen);
        }

        on_message(topic, payload, qos, retained);

        /* Extract MQTT 5.0 User Properties if present */
        if (props != null) {
            var user_props = new Gee.HashMap<string, string>();
            string? name = null;
            string? value = null;

            unowned Mosquitto.Property? current = props;
            bool skip = false;
            int prop_count = 0;
            const int MAX_USER_PROPERTIES = 256;

            while (true) {
                current = Mosquitto.Property.read_string_pair(
                    current, Mosquitto.PropertyId.USER_PROPERTY,
                    out name, out value, skip);
                if (current == null) break;
                if (++prop_count > MAX_USER_PROPERTIES) {
                    warning("MQTT: User Property limit (%d) reached, truncating",
                            MAX_USER_PROPERTIES);
                    break;
                }
                if (name != null && value != null) {
                    user_props[name] = value;
                }
                skip = true;  /* skip the one we just read */
            }

            if (user_props.size > 0) {
                on_message_properties(topic, user_props);
            }
        }
    }

    /* ── Reconnection ────────────────────────────────────────────── */

    private void schedule_reconnect() {
        if (reconnect_timer_id != 0) return;
        if (!initial_connect_done) return;    /* first connect never succeeded */

        debug("MQTT: Scheduling reconnect in %u s…", reconnect_delay_secs);
        reconnect_timer_id = Timeout.add_seconds(reconnect_delay_secs, () => {
            reconnect_timer_id = 0;
            attempt_reconnect.begin((obj, result) => {
                attempt_reconnect.end(result);
            });
            return false;
        });

        /* Exponential backoff: double delay for next failure, capped (R2) */
        reconnect_delay_secs = uint.min(
            reconnect_delay_secs * 2, RECONNECT_DELAY_MAX);
    }

    private async void attempt_reconnect() {
        if ((mosq == null && broker_dns_mode == "off") || is_connected) return;
        if (broker_dns_mode != "off") {
            // Never reuse TLSA evidence, SSL_CTX, or a DNS route on reconnect.
            string host = broker_host;
            int port = broker_port;
            bool tls = broker_use_tls;
            string? user = broker_username, pass = broker_password;
            string? pt = broker_proxy_type, ph = broker_proxy_host;
            int pp = broker_proxy_port;
            string? pu = broker_proxy_user, pw = broker_proxy_pass;
            string mode = broker_dns_mode;
            string? resolver = broker_dns_resolver;
            bool ok = yield connect_async(host, port, tls, user, pass, pt, ph, pp, pu, pw, mode, resolver);
            if (!ok && security_error == null && dns_attempt != null && !dns_attempt.cancellable.is_cancelled()) {
                initial_connect_done = true;
                schedule_reconnect();
            }
            return;
        }

        debug("MQTT: Reconnecting to %s:%d…", broker_host, broker_port);

        int rc = Mosquitto.Error.UNKNOWN;
        SourceFunc resume = attempt_reconnect.callback;
        unowned Mosquitto.Client? reconnect_mosq = mosq;
        uint reconnect_generation = ++operation_generation;
        tcp_operation_in_progress = true;

        new Thread<void*>("mqtt-reconnect", () => {
            if (reconnect_mosq != null) {
                rc = reconnect_mosq.reconnect();
            }
            Idle.add((owned) resume);
            return null;
        });
        yield;
        if (operation_generation == reconnect_generation || mosq == reconnect_mosq) {
            tcp_operation_in_progress = false;
        }

        /* Guard: mosq may have been nulled by disconnect_sync() while
         * the reconnect thread was running — avoid crash. */
        if (mosq == null || mosq != reconnect_mosq || operation_generation != reconnect_generation) {
            if (mosq == reconnect_mosq && mosq != null) {
                if (rc == Mosquitto.Error.SUCCESS) {
                    mosq.disconnect();
                }
                mosq = null;
            }
            return;
        }

        if (rc == Mosquitto.Error.SUCCESS) {
            setup_glib_sources();
            debug("MQTT: Reconnect TCP OK, waiting for CONNACK…");
            if (reconnect_connack_timeout_id != 0) {
                Source.remove(reconnect_connack_timeout_id);
                reconnect_connack_timeout_id = 0;
            }
            reconnect_connack_timeout_id = Timeout.add_seconds(10, () => {
                reconnect_connack_timeout_id = 0;
                if (mosq != null && !is_connected && initial_connect_done) {
                    warning("MQTT: Reconnect CONNACK timed out, retrying…");
                    teardown_glib_sources();
                    schedule_reconnect();
                }
                return false;
            });
            /* handle_connect will fire from on_connect_cb via loop_read */
        } else {
            warning("MQTT: Reconnect failed (rc=%d), retrying…", rc);
            schedule_reconnect();
        }
    }

    /* ── Public API ──────────────────────────────────────────────── */

    /**
     * Subscribe to an MQTT topic filter.
     * Supports wildcards: + (single level), # (multi level).
     */
    public void subscribe(string topic, int qos = 0) {
        subscribed_topics[topic] = qos;  /* remember for reconnect */

        if (mosq == null || !is_connected) return;

        int rc = mosq.subscribe(null, topic, qos);
        if (rc != Mosquitto.Error.SUCCESS) {
            warning("MQTT: subscribe('%s') failed (rc=%d)", topic, rc);
        } else {
            debug("MQTT: Subscribed to '%s' (qos=%d)", topic, qos);
        }

        schedule_write_if_needed();
    }

    /**
     * Unsubscribe from an MQTT topic filter.
     */
    public void unsubscribe(string topic) {
        subscribed_topics.unset(topic);

        if (mosq == null || !is_connected) return;
        mosq.unsubscribe(null, topic);
        schedule_write_if_needed();
    }

    /**
     * Get the set of currently subscribed topics.
     */
    public Gee.Set<string> get_subscribed_topics() {
        /* Return a COPY to avoid concurrent-modification crashes
         * when callers unsubscribe while iterating */
        var copy = new Gee.HashSet<string>();
        copy.add_all(subscribed_topics.keys);
        return copy;
    }

    /**
     * Publish raw bytes to an MQTT topic.
     */
    public void publish(string topic, uint8[] payload,
                        int qos = 0, bool retain = false) {
        if (mosq == null || !is_connected) return;

        int rc = mosq.publish(null, topic, payload.length, payload, qos, retain);
        if (rc != Mosquitto.Error.SUCCESS) {
            warning("MQTT: publish('%s') failed (rc=%d)", topic, rc);
        }

        schedule_write_if_needed();
    }

    /**
     * Publish a UTF-8 string to an MQTT topic (convenience wrapper).
     */
    public void publish_string(string topic, string payload,
                               int qos = 0, bool retain = false) {
        publish(topic, payload.data, qos, retain);
    }

    /**
     * Disconnect gracefully (async-safe).
     */
    public async void disconnect_async() {
        disconnect_sync();
    }

    /**
     * Disconnect immediately (safe to call from any context).
     */
    public void disconnect_sync() {
        if (dns_attempt != null) dns_attempt.cancel();
        operation_generation++;
        teardown_glib_sources();
        initial_connack_pending = false;
        if (connack_resume != null) {
            Idle.add((owned) connack_resume);
            connack_resume = null;
        }

        bool was_connected = is_connected;
        is_connected = false;
        initial_connect_done = false;

        if (tcp_operation_in_progress) {
            if (was_connected) {
                on_connection_changed(false);
            }
            return;
        }
        if (mosq != null) mosq.disconnect();
        mosq = null;
#if HAVE_DNSSEC
        tls_context = null;
#endif
        dane_verified = false;

        if (was_connected) {
            on_connection_changed(false);
        }

        message("MQTT: Disconnected");
    }

    /* ── Helpers ──────────────────────────────────────────────────── */

    /** Human-readable MOSQ_ERR_* code. */
    private static string rc_to_string(int rc) {
        switch (rc) {
            case Mosquitto.Error.SUCCESS:       return "SUCCESS";
            case Mosquitto.Error.NOMEM:         return "NOMEM";
            case Mosquitto.Error.PROTOCOL:      return "PROTOCOL";
            case Mosquitto.Error.INVAL:         return "INVAL";
            case Mosquitto.Error.NO_CONN:       return "NO_CONN";
            case Mosquitto.Error.CONN_REFUSED:  return "CONN_REFUSED";
            case Mosquitto.Error.NOT_FOUND:     return "NOT_FOUND";
            case Mosquitto.Error.CONN_LOST:     return "CONN_LOST";
            case Mosquitto.Error.TLS:           return "TLS";
            case Mosquitto.Error.AUTH:          return "AUTH";
            case Mosquitto.Error.ERRNO:         return "ERRNO";
            case Mosquitto.Error.EAI:           return "EAI (DNS)";
            default:                            return "UNKNOWN(%d)".printf(rc);
        }
    }

    /** Human-readable CONNACK return code. */
    private static string connack_rc_to_string(int rc) {
        switch (rc) {
            case 0: return "Accepted";
            case 1: return "Refused: wrong protocol version";
            case 2: return "Refused: identifier rejected";
            case 3: return "Refused: server unavailable";
            case 4: return "Refused: bad username/password";
            case 5: return "Refused: not authorized";
            default: return "Unknown CONNACK rc=%d".printf(rc);
        }
    }
}

}
