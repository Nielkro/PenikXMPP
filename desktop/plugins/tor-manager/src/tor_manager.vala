using Dino;
using GLib;
using Dino.Entities;
using Gee;

namespace Dino.Plugins.TorManager {

    public class TorManager : AccountReadinessGate, StreamInteractionModule, AccountProxyProvider {
        public const string IDENTITY_STRING = "tor-manager";
        public static ModuleIdentity<TorManager> IDENTITY = new ModuleIdentity<TorManager>(IDENTITY_STRING);

        public string id { get { return IDENTITY_STRING; } }
        public string proxy_type { get { return "tor"; } }
        public string proxy_host { owned get { return "127.0.0.1"; } }
        public int proxy_port { get { return controller.socks_port; } }
        public bool proxy_enabled { get { return is_enabled; } }
        public bool proxy_ready {
            get {
                return accounts_proxy_ready && is_enabled &&
                       controller.socks_ready && controller.is_running &&
                       controller.bootstrap_percent >= 100 &&
                       controller.socks_port > 0;
            }
        }


        public TorController controller { get; private set; }
        public bool is_enabled { get; private set; default = false; }
        public bool use_bridges { get; private set; default = true; }
        public bool force_firewall_ports { get; private set; default = false; }
        private StreamInteractor stream_interactor;
        private Database db;
        private bool is_shutting_down = false;
        private bool is_starting_up = false;  // True during initial restore_state → enable sequence
        private bool is_transitioning = false; // Reentrancy guard for set_enabled / restart cycles
        private bool restart_requested_during_transition = false;
        private int retry_count = 0;
        private bool accounts_proxy_ready = false;
        private uint operation_generation = 0;
        private int bootstrap_timeout_seconds = BOOTSTRAP_TIMEOUT_SECONDS;
        private const int MAX_RETRIES = 2;
        private const int BOOTSTRAP_TIMEOUT_SECONDS = 180;

        // Seed bridges for first run. Users should refresh them from BridgeDB in settings.
        private const string BOOTSTRAP_BRIDGES = """# Default Bootstrap Bridges
# Refresh these from Tor settings if connection fails.
webtunnel [2001:db8:a62f:3205:a2b8:80f2:8491:9497]:443 CDCF334F257ACAD04A2C6CD9725B7FC686160912 url=https://meskio.net/eCDFZe3boSv+b2iqHiaY4ZgPxXBc ver=0.0.3
obfs4 103.17.153.52:443 487051F8352D0EB4D0277A4682694AF7A745D344 cert=isMTh9X1bKZy52LBBeuWgG9ZdapqCPbBeA9EhPRaLpgnYJpLQnl/tIV/t0TKVMAlUDomZg iat-mode=0
""";

        public TorManager(StreamInteractor stream_interactor, Database db) {
            initialize(stream_interactor, db, new TorController());
        }

        internal TorManager.for_tests(StreamInteractor stream_interactor, Database db,
                TorController controller, int bootstrap_timeout_seconds = 180) {
            this.bootstrap_timeout_seconds = bootstrap_timeout_seconds;
            initialize(stream_interactor, db, controller);
        }

        private void initialize(StreamInteractor stream_interactor, Database db,
                TorController controller) {
            this.stream_interactor = stream_interactor;
            this.db = db;
            this.controller = controller;
            connect_controller_weak(this, controller);
            this.stream_interactor.account_added.connect(on_account_added);
            // Register before restoring or starting Tor. Account restore may run
            // while the controller's first asynchronous start is still pending.
            stream_interactor.connection_manager.add_readiness_gate(this);
            restore_state();
        }

        private static void connect_controller_weak(TorManager manager,
                TorController controller) {
            WeakRef manager_ref = WeakRef(manager);
            WeakRef controller_ref = WeakRef(controller);
            controller.process_exited.connect((status) => {
                var current = (TorManager?) manager_ref.get();
                if (current != null) current.on_process_exited(status);
            });
            controller.notify["is-running"].connect(() => {
                var current = (TorManager?) manager_ref.get();
                var source = (TorController?) controller_ref.get();
                if (current != null && source != null && !source.is_running) {
                    current.fence_accounts();
                }
            });
            controller.bootstrap_status.connect((percent, summary) => {
                var current = (TorManager?) manager_ref.get();
                if (current == null) return;
                if (percent >= 100) current.retry_count = 0;
                else current.fence_accounts();
            });
        }

        public override bool is_ready(Account account) {
            if (is_shutting_down) return false;
            if (is_standalone_socks5(account)) return true;
            if (!is_enabled) return account.proxy_type != "tor";
            return proxy_ready && account.proxy_type == "tor" &&
                account.proxy_host == proxy_host && account.proxy_port == proxy_port;
        }

        private void refresh_account_readiness() {
            // Connection-state observers may remove accounts synchronously.
            var accounts = stream_interactor.get_accounts();
            foreach (Account account in accounts) readiness_changed(account);
        }

        private void fence_accounts() {
            accounts_proxy_ready = false;
            refresh_account_readiness();
        }

        private uint invalidate_operation() {
            operation_generation++;
            fence_accounts();
            return operation_generation;
        }

        private bool operation_is_current(uint generation) {
            return generation == operation_generation && !is_shutting_down;
        }

        public StreamInteractor get_stream_interactor() {
            return stream_interactor;
        }

        private bool is_standalone_socks5(Account account) {
            // SOCKS5 is an explicit per-account override, even when it points
            // to localhost or a Tor-like port. Global Tor must not overwrite it.
            return account.proxy_type == "socks5";
        }

        private void on_account_added(Account account) {
            if (is_enabled) {
                // Skip accounts with a real standalone SOCKS5 proxy
                if (is_standalone_socks5(account)) {
                    debug("TorManager: New account %s has standalone SOCKS5 proxy, not overriding with Tor",
                           account.bare_jid.to_string());
                    return;
                }

                // Set the current tuple before ConnectionManager evaluates our gate.
                // A pending start is blocked until the final port is confirmed.
                int port = controller.socks_port;
                debug("TorManager: New account added (%s). Setting proxy to 127.0.0.1:%d (Tor running: %s)",
                       account.bare_jid.to_string(), port, controller.is_running.to_string());
                account.proxy_type = "tor";
                account.proxy_host = "127.0.0.1";
                account.proxy_port = port;
            } else if (account.proxy_type == "tor") {
                // A caller may have loaded this object before restore_state
                // cleared its database row. Explicit Tor Off also clears that
                // stale in-memory managed tuple before the initial gate check.
                account.proxy_type = "none";
                account.proxy_host = "";
                account.proxy_port = 0;
            }
        }

        public void prepare_shutdown() {
            is_shutting_down = true;
            restart_requested_during_transition = false;
            invalidate_operation();
            controller.stop();
        }

        private void restore_state() {
            bool bridges_exist = false;

            foreach (var row in db.settings.select()) {
                string key = row[db.settings.key];
                string? val = row[db.settings.value];
                
                if (key == "tor_manager_enabled") {
                    debug("TorManager: restore_state() - DB value for 'tor_manager_enabled': %s", val ?? "null");
                    if (val == "true") {
                        is_enabled = true;
                    }
                } else if (key == "tor_manager_bridges") {
                    bridges_exist = true;
                    if (val != null) {
                        controller.bridge_lines = val;
                    }
                } else if (key == "tor_manager_use_bridges") {
                    if (val == "true") use_bridges = true;
                    else if (val == "false") use_bridges = false;
                } else if (key == "tor_manager_firewall_ports") {
                    if (val == "true") force_firewall_ports = true;
                    else if (val == "false") force_firewall_ports = false;
                }
            }
            
            // Sync controller
            controller.use_bridges = use_bridges;
            controller.force_firewall_ports = force_firewall_ports;

            // If bridges are not set in DB (first run), populate with bootstrap bridges
            if (!bridges_exist) {
                    controller.bridge_lines = BOOTSTRAP_BRIDGES;
                    db.settings.upsert()
                        .value(db.settings.key, "tor_manager_bridges", true)
                        .value(db.settings.value, BOOTSTRAP_BRIDGES)
                        .perform();
            }

            // Historical builds migrated socks5+localhost to "tor". SOCKS5 is
            // now always a standalone per-account override, so the migration is
            // intentionally skipped for fresh profiles.
            bool migration_done = db.settings.select().with(db.settings.key, "=", "tor_socks5_migration_done").count() > 0;
            if (!migration_done) {
                db.settings.upsert()
                    .value(db.settings.key, "tor_socks5_migration_done", true)
                    .value(db.settings.value, "true")
                    .perform();
                debug("TorManager: legacy socks5→tor migration skipped and flagged.");
            }

            if (is_enabled) {
                debug("TorManager: state is ENABLED. Starting Tor...");
                is_starting_up = true;
                // FORCE apply proxy settings on startup (true) because the port might have changed dynamically (e.g. 9155 -> 9156)
                set_enabled.begin(true, (obj, res) => {
                    set_enabled.end(res);
                    is_starting_up = false;
                });
            } else {
                // Explicit Tor Off clears only managed Tor routes, never standalone SOCKS5.
                debug("TorManager: state is DISABLED. Ensuring clear-net (DB Cleanup)...");
                cleanup_lingering_proxies();
            }
        }


        private void cleanup_lingering_proxies() {
            // 1. Collect targets: only clear proxy_type="tor" (set by TorManager).
            //    User-configured "socks5" proxies (including those on localhost) are NEVER touched.
            var targets = new Gee.ArrayList<int>();
            
            foreach (var row in db.account.select()) {
                string ptype = row[db.account.proxy_type];
                if (ptype == "tor") {
                    targets.add(row[db.account.id]);
                }
            }

            // 2. Remediate targets
            foreach (int id_val in targets) {
                    debug("TorManager: cleanup_lingering_proxies - Found lingering Tor proxy on account ID %d. Remediating...", id_val);

                // Fix RAM / Active Connections (property setters persist to DB via on_update)
                bool found_in_ram = false;
                if (stream_interactor != null) {
                    var accounts = stream_interactor.get_accounts();
                    foreach (var account in accounts) {
                        if (account.id == id_val) {
                            debug("TorManager: Forcing RAM disconnect for %s", account.bare_jid.to_string());
                            account.proxy_type = "none";
                            account.proxy_host = "";
                            account.proxy_port = 0;
                            found_in_ram = true;
                            readiness_changed(account);
                        }
                    }
                }
                // Account not loaded in RAM (e.g. disabled) — update DB directly
                if (!found_in_ram) {
                    db.account.update()
                        .set(db.account.proxy_type, "none")
                        .set(db.account.proxy_host, "")
                        .set(db.account.proxy_port, 0)
                        .with(db.account.id, "=", id_val)
                        .perform();
                }
            }
        }
        
        private void on_process_exited(int status) {
            if (is_shutting_down) {
                 debug("TorManager: Process exited during application shutdown (status %d). Ignoring.", status);
                 return;
            }

            // If user already disabled Tor, don't retry — just clean up
            if (!is_enabled) {
                debug("TorManager: Tor exited (status %d) but is_enabled=false. No retry.", status);
                return;
            }

            if (retry_count < MAX_RETRIES) {
                retry_count++;
                warning("TorManager: Tor exited unexpectedly with status %d so we are trying to fix it. Attempt %d/%d. Cleaning state...", status, retry_count, MAX_RETRIES);
                
                // Attempt to clean state which might be corrupted ("Acting on config options left us in a broken state")
                controller.clean_state();
                
                // Use the same serialized transition as a settings restart.
                restart_tor_for_current_settings.begin(false);
                return;
            }

            warning("TorManager: Tor exited with status %d. Retries exhausted; accounts remain blocked.", status);
            report_start_failure();
        }

        private void persist_enabled_state(bool enabled) {
            is_enabled = enabled;
            if (enabled) fence_accounts();
            else refresh_account_readiness();
            db.settings.upsert()
                .value(db.settings.key, "tor_manager_enabled", true)
                .value(db.settings.value, enabled ? "true" : "false")
                .perform();
        }

        private async void restart_tor_for_current_settings(bool reset_retry_budget = true) {
            if (reset_retry_budget) retry_count = 0;
            if (is_shutting_down) return;
            if (is_transitioning) {
                debug("TorManager: settings changed during active transition. Scheduling restart.");
                restart_requested_during_transition = true;
                invalidate_operation();
                controller.stop();
                return;
            }

            is_transitioning = true;
            // Exit the loop through its single cleanup path; these operations do not throw.
            do {
                restart_requested_during_transition = false;
                yield stop_tor(false);
                if (!is_enabled) {
                    yield stop_tor(true);
                    break;
                }

                yield start_tor(true);
                if (is_shutting_down) break;

                if (!is_enabled) {
                    yield stop_tor(true);
                    break;
                }

                if (!restart_requested_during_transition && !controller.is_running) {
                    warning("TorManager: Tor restart failed; keeping Tor enabled and accounts blocked.");
                    report_start_failure();
                    break;
                }
            } while (restart_requested_during_transition);
            is_transitioning = false;
        }
        
        public async void set_bridges(string bridges) {
            debug("TorManager: Updating bridges settings.");
            controller.bridge_lines = bridges;
            db.settings.upsert()
                    .value(db.settings.key, "tor_manager_bridges", true)
                    .value(db.settings.value, bridges)
                    .perform();
            
            if (is_enabled) {
                yield restart_tor_for_current_settings();
            }
        }

        public async void update_use_bridges(bool use) {
            if (use_bridges == use) return;
            use_bridges = use;
            controller.use_bridges = use;
            
            db.settings.upsert()
                    .value(db.settings.key, "tor_manager_use_bridges", true)
                    .value(db.settings.value, use ? "true" : "false")
                    .perform();
            
            if (is_enabled) {
                yield restart_tor_for_current_settings();
            }
        }

        public async void update_firewall_ports(bool use) {
            if (force_firewall_ports == use) return;
            force_firewall_ports = use;
            controller.force_firewall_ports = use;
            
            db.settings.upsert()
                    .value(db.settings.key, "tor_manager_firewall_ports", true)
                    .value(db.settings.value, use ? "true" : "false")
                    .perform();

            if (is_enabled) {
                yield restart_tor_for_current_settings();
            }
        }

        public async void set_enabled(bool enabled) {
            if (is_shutting_down) return;
            if (enabled && is_enabled && proxy_ready && !is_transitioning) return;
            // Explicit user enable/off starts a fresh retry budget. Automatic
            // process restarts must retain the accumulated failure count.
            retry_count = 0;
            // Always update desired state + DB immediately, even during transitions
            persist_enabled_state(enabled);

            if (is_transitioning) {
                debug("TorManager: set_enabled(%s) during active transition.", enabled.to_string());
                if (!enabled) {
                    // Kill Tor process immediately — the running start_tor
                    // will notice is_enabled==false and bail out. Proxy cleanup is
                    // idempotent and must not wait for a slow bootstrap timeout.
                    restart_requested_during_transition = false;
                    invalidate_operation();
                    controller.stop();
                    cleanup_lingering_proxies();
                } else {
                    // The user asked for Tor again while a failed/stopped bridge
                    // attempt is still unwinding. Keep the desired state and make
                    // the owning transition loop start a fresh controller once the
                    // current stop/start callback returns.
                    restart_requested_during_transition = true;
                }
                return;
            }
            debug("TorManager: set_enabled(%s) called. is_transitioning=false, proceeding.", enabled.to_string());
            is_transitioning = true;

            if (enabled) {
                debug("TorManager: Starting Tor...");
                do {
                    restart_requested_during_transition = false;
                    yield start_tor(true);
                    if (is_shutting_down) break;
                    if (restart_requested_during_transition && is_enabled) {
                        debug("TorManager: Restarting Tor after settings changed during startup.");
                        yield stop_tor(false);
                    }
                } while (restart_requested_during_transition && is_enabled);

                // If user toggled OFF while we were starting, clean up now
                if (!is_shutting_down && !is_enabled) {
                    debug("TorManager: User disabled Tor during startup. Cleaning up.");
                    yield stop_tor(true);
                } else if (!is_shutting_down && !controller.is_running) {
                    warning("TorManager: Tor start failed; keeping Tor enabled and accounts blocked.");
                    report_start_failure();
                }
            } else {
                debug("TorManager: Stopping Tor and cleaning up...");
                yield stop_tor(true);
                if (restart_requested_during_transition && is_enabled) {
                    debug("TorManager: User re-enabled Tor during shutdown. Starting a fresh Tor process.");
                    do {
                        restart_requested_during_transition = false;
                        yield start_tor(true);
                        if (is_shutting_down) break;
                        if (restart_requested_during_transition && is_enabled) {
                            debug("TorManager: Restarting Tor after settings changed during re-enable.");
                            yield stop_tor(false);
                        }
                    } while (restart_requested_during_transition && is_enabled);

                    if (!is_shutting_down && is_enabled && !controller.is_running) {
                        warning("TorManager: Tor re-enable failed; keeping Tor enabled and accounts blocked.");
                        report_start_failure();
                    }
                }
            }
            is_transitioning = false;
            debug("TorManager: set_enabled() transition complete. is_enabled=%s is_transitioning=false",
                  is_enabled.to_string());
        }

#if DINOX_TOR_TESTS
        internal bool transition_in_progress_for_tests() { return is_transitioning; }
#endif

        private void report_start_failure() {
            fence_accounts();
            // Retain the user's desired privacy state. Only explicit Off is
            // allowed to remove Tor routing or reconnect through the clear net.
            string summary = controller.bootstrap_summary;
            if (summary == "" || summary == _("Stopped")) {
                summary = _("Tor could not connect. Check settings and try again.");
            }
            controller.report_error(summary);
        }

        public async void start_tor(bool apply_proxy = false) {
            if (is_shutting_down || !is_enabled) return;
            uint generation = invalidate_operation();
            yield controller.start();
            if (!operation_is_current(generation)) return;

            // Bail out if Tor was disabled while we were starting (user toggled OFF mid-startup)
            if (!operation_is_current(generation) || !is_enabled || !controller.is_running) {
                debug("TorManager: Tor disabled or not running after start(). Skipping proxy application.");
                return;
            }

            // Persist SOCKS port so UI and other components can read it
            db.settings.upsert()
                .value(db.settings.key, "tor_socks_port", true)
                .value(db.settings.value, controller.socks_port.to_string())
                .perform();
            debug("TorManager: Stored tor_socks_port=%d in DB", controller.socks_port);

            if (apply_proxy) {
                // Keep the connection gate closed until listener confirmation,
                // bootstrap and current proxy tuples have all been established.
                bool bootstrapped = yield wait_for_bootstrap(bootstrap_timeout_seconds, generation);

                // Re-check: user may have disabled Tor while we waited for bootstrap
                if (!operation_is_current(generation) || !is_enabled || !controller.is_running) {
                    debug("TorManager: Tor disabled, superseded or died during bootstrap wait. Skipping proxy application.");
                    return;
                }

                if (bootstrapped) {
                    debug("TorManager: Tor bootstrapped, applying proxy settings now.");
                    apply_proxy_to_accounts(true);
                } else {
                    warning("TorManager: Tor bootstrap timed out after %ds. Stopping Tor.", bootstrap_timeout_seconds);
                    // Don't apply proxy — Tor isn't working.
                    // Stop Tor so the user can re-try or change bridges.
                    controller.stop();
                    // Emit a bootstrap_status signal so the UI shows the failure
                    controller.report_error(_("Bootstrap timed out — check bridges"));
                }
            }
        }

        /**
         * Wait until the TorController emits bootstrap_status with percent >= 100,
         * or until timeout_seconds expires. Returns true if bootstrap completed.
         */
        private async bool wait_for_bootstrap(int timeout_seconds, uint generation) {
            if (!operation_is_current(generation) || !controller.is_running) return false;
            if (controller.bootstrap_percent >= 100) return true;

            bool completed = false;
            bool resumed = false;
            ulong handler_id = 0;
            uint timeout_id = 0;
            uint cancel_id = 0;

            handler_id = controller.bootstrap_status.connect((percent, summary) => {
                if (!resumed && operation_is_current(generation) && percent >= 100) {
                    completed = true;
                    resumed = true;
                    wait_for_bootstrap.callback();
                }
            });

            timeout_id = Timeout.add_seconds((uint) timeout_seconds, () => {
                timeout_id = 0;
                if (!resumed) {
                    resumed = true;
                    wait_for_bootstrap.callback();
                }
                return Source.REMOVE;
            });

            cancel_id = Timeout.add(200, () => {
                if (!resumed && (!operation_is_current(generation) || !is_enabled || !controller.is_running)) {
                    cancel_id = 0;
                    resumed = true;
                    wait_for_bootstrap.callback();
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });

            yield;

            // Cleanup
            if (handler_id != 0) {
                SignalHandler.disconnect(controller, handler_id);
            }
            if (timeout_id != 0) {
                Source.remove(timeout_id);
            }
            if (cancel_id != 0) {
                Source.remove(cancel_id);
            }

            return completed;
        }

        public async void stop_tor(bool remove_proxy = false) {
            invalidate_operation();
            if (remove_proxy) cleanup_lingering_proxies();
            yield controller.stop_and_wait();
        }

        public void apply_proxy_to_accounts(bool enable_tor) {
            if (!enable_tor) {
                cleanup_lingering_proxies();
                return;
            }
            if (!is_enabled || is_shutting_down || !controller.is_running ||
                    !controller.socks_ready || controller.bootstrap_percent < 100) return;

            var accounts = stream_interactor.get_accounts();
            foreach (Account account in accounts) {
                if (is_standalone_socks5(account)) continue;
                account.proxy_type = "tor";
                account.proxy_host = "127.0.0.1";
                account.proxy_port = controller.socks_port;
            }
            // Never resume at the raw bootstrap signal: every account must
            // already contain this process's confirmed (possibly new) port.
            accounts_proxy_ready = true;
            refresh_account_readiness();
        }

    }
}
