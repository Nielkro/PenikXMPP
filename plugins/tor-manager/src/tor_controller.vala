using GLib;
using Gee;

namespace Dino.Plugins.TorManager {

    public class TorController : Object {
        private OwnedProcess? tor_process;
        private uint operation_generation = 0;
        private ArrayList<OwnedProcess> stopping_processes = new ArrayList<OwnedProcess>();
        private signal void owned_processes_stopped();
        private string? transport_working_directory = null;
        private LinkedList<string> last_log_lines = new LinkedList<string>();
        // private DataInputStream? control_stream;

        public bool is_running { get; protected set; default = false; }
        public bool socks_ready { get; protected set; default = false; }
        public bool is_starting { get; protected set; default = false; }
        public int socks_port { get; protected set; default = 9155; }
        public int bootstrap_percent { get; protected set; default = 0; }
        public string bootstrap_summary { get; protected set; default = ""; }
        public string bridge_lines { get; set; default = ""; }
        public bool use_bridges { get; set; default = true; }
        public bool force_firewall_ports { get; set; default = false; }
        
        public signal void process_exited(int status);
        public signal void bootstrap_status(int percent, string summary);
        public signal void started();


        public TorController() {
            // Check if Tor is available
            check_installation();
        }

        protected TorController.for_tests() {
            // Fake controllers must never locate, spawn or connect real Tor.
        }

        ~TorController() {
            stop();
        }

#if WINDOWS
        // Get the directory where the executable is located
        private string? get_executable_dir() {
            // Use DINOX_EXE_DIR set by main.vala (reliable, based on args[0])
            string? exe_dir = Environment.get_variable("DINOX_EXE_DIR");
            if (exe_dir != null) {
                return exe_dir;
            }
            // Fallback: current working directory
            return Environment.get_current_dir();
        }
#endif

        private bool executable_exists(string? path) {
            return path != null && path != "" && FileUtils.test(path, FileTest.EXISTS);
        }

        private string? find_executable(string env_name, string[] names, string[] bundled_candidates, string[] developer_candidates = {}) {
            string? env_path = Environment.get_variable(env_name);
            if (executable_exists(env_path)) {
                debug("[TOR] Using %s=%s", env_name, env_path);
                return env_path;
            }
            if (env_path != null && env_path != "") {
                warning("[TOR] %s is set to '%s', but that executable does not exist.", env_name, env_path);
            }

            foreach (string candidate in bundled_candidates) {
                if (executable_exists(candidate)) {
                    debug("[TOR] Found bundled executable candidate: %s", candidate);
                    return candidate;
                }
            }

            foreach (string candidate in developer_candidates) {
                if (executable_exists(candidate)) {
                    debug("[TOR] Found developer executable candidate: %s", candidate);
                    return candidate;
                }
            }

            if (Environment.get_variable("DINOX_TOR_ALLOW_SYSTEM_FALLBACK") != "1") {
                return null;
            }

            foreach (string name in names) {
                string? path = Environment.find_program_in_path(name);
                if (path != null) {
                    debug("[TOR] Found %s in PATH via explicit system fallback: %s", name, path);
                    return path;
                }
            }

            return null;
        }

#if !WINDOWS
        private void add_local_build_candidates(Gee.ArrayList<string> candidates, string relative_path) {
            try {
                string self_path = FileUtils.read_link("/proc/self/exe");
                string? persistent_prefix = LocalTorRuntime.find_prefix(self_path);
                if (persistent_prefix != null) {
                    candidates.add(Path.build_filename(persistent_prefix, relative_path));
                }
                string? self_dir = Path.get_dirname(self_path);
                if (self_dir != null) {
                    candidates.add(Path.build_filename(self_dir, "..", "release-deps", relative_path));
                }
            } catch (Error e) { /* ignore */ }
            candidates.add(Path.build_filename(Environment.get_current_dir(), "build", "release-deps", relative_path));
        }
#endif

        private string[] string_list_to_array(Gee.List<string> list) {
            string[] array = new string[list.size];
            for (int i = 0; i < list.size; i++) {
                array[i] = list[i];
            }
            return array;
        }

        // Tor configuration values use C-style quoted strings. Always quote
        // filesystem paths so spaces and non-ASCII profile/install names stay
        // part of the same value on every supported platform.
        private static string quote_torrc_path(string path) {
            return "\"" + path.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
        }

        private string? find_tor_executable() {
            var bundled_candidates = new Gee.ArrayList<string>();
            var developer_candidates = new Gee.ArrayList<string>();
#if WINDOWS
            string? exe_dir = get_executable_dir();
            if (exe_dir != null) {
                bundled_candidates.add(Path.build_filename(exe_dir, "bin", "tor.exe"));
                bundled_candidates.add(Path.build_filename(exe_dir, "tor.exe"));
            }
            developer_candidates.add("C:\\msys64\\mingw64\\bin\\tor.exe");
            string[] names = {"tor.exe"};
#else
            string? appdir = Environment.get_variable("APPDIR");
            if (appdir != null) {
                bundled_candidates.add(Path.build_filename(appdir, "usr", "bin", "tor"));
                bundled_candidates.add(Path.build_filename(appdir, "bin", "tor"));
            }
            bundled_candidates.add("/app/bin/tor");
            string[] names = {"tor"};
            add_local_build_candidates(developer_candidates, Path.build_filename("bin", "tor"));
#endif
            return find_executable("DINOX_TOR_PATH", names, string_list_to_array(bundled_candidates), string_list_to_array(developer_candidates));
        }

        private string? find_lyrebird_executable() {
            var bundled_candidates = new Gee.ArrayList<string>();
            var developer_candidates = new Gee.ArrayList<string>();
#if WINDOWS
            string[] names = {"lyrebird.exe"};
            string? exe_dir = get_executable_dir();
            if (exe_dir != null) {
                bundled_candidates.add(Path.build_filename(exe_dir, "bin", "lyrebird.exe"));
                bundled_candidates.add(Path.build_filename(exe_dir, "lyrebird.exe"));
            }
            developer_candidates.add(Path.build_filename(Environment.get_home_dir(), "go", "bin", "lyrebird.exe"));
            developer_candidates.add("C:\\msys64\\mingw64\\bin\\lyrebird.exe");
#else
            string[] names = {"lyrebird"};
            string? appdir = Environment.get_variable("APPDIR");
            if (appdir != null) {
                bundled_candidates.add(Path.build_filename(appdir, "usr", "bin", "lyrebird"));
                bundled_candidates.add(Path.build_filename(appdir, "bin", "lyrebird"));
            }
            bundled_candidates.add("/app/bin/lyrebird");
            add_local_build_candidates(developer_candidates, Path.build_filename("bin", "lyrebird"));

            try {
                string self_path = FileUtils.read_link("/proc/self/exe");
                string? self_dir = Path.get_dirname(self_path);
                if (self_dir != null) {
                    bundled_candidates.add(Path.build_filename(self_dir, "lyrebird"));
                }
            } catch (Error e) { /* ignore */ }
#endif

            return find_executable("DINOX_LYREBIRD_PATH", names, string_list_to_array(bundled_candidates), string_list_to_array(developer_candidates));
        }

        private string? find_obfs4proxy_executable() {
            var bundled_candidates = new Gee.ArrayList<string>();
            var developer_candidates = new Gee.ArrayList<string>();
#if WINDOWS
            string[] names = {"obfs4proxy.exe"};
            string? exe_dir = get_executable_dir();
            if (exe_dir != null) {
                bundled_candidates.add(Path.build_filename(exe_dir, "bin", "obfs4proxy.exe"));
                bundled_candidates.add(Path.build_filename(exe_dir, "obfs4proxy.exe"));
            }
            developer_candidates.add(Path.build_filename(Environment.get_home_dir(), "go", "bin", "obfs4proxy.exe"));
            developer_candidates.add("C:\\msys64\\mingw64\\bin\\obfs4proxy.exe");
#else
            string[] names = {"obfs4proxy"};
            string? appdir = Environment.get_variable("APPDIR");
            if (appdir != null) {
                bundled_candidates.add(Path.build_filename(appdir, "usr", "bin", "obfs4proxy"));
                bundled_candidates.add(Path.build_filename(appdir, "bin", "obfs4proxy"));
            }
            bundled_candidates.add("/app/bin/obfs4proxy");
            add_local_build_candidates(developer_candidates, Path.build_filename("bin", "obfs4proxy"));

            try {
                string self_path = FileUtils.read_link("/proc/self/exe");
                string? self_dir = Path.get_dirname(self_path);
                if (self_dir != null) {
                    bundled_candidates.add(Path.build_filename(self_dir, "obfs4proxy"));
                }
            } catch (Error e) { /* ignore */ }
#endif

            return find_executable("DINOX_OBFS4PROXY_PATH", names, string_list_to_array(bundled_candidates), string_list_to_array(developer_candidates));
        }

        private bool append_client_transport_plugins(StringBuilder torrc, string bridges) {
            transport_working_directory = null;
            bool needs_obfs4 = false;
            bool needs_webtunnel = false;

            foreach (string line in bridges.split("\n")) {
                string clean_line = line.strip();
                if (clean_line == "" || clean_line.has_prefix("#")) continue;

                if (clean_line.has_prefix("obfs4 ")) {
                    needs_obfs4 = true;
                } else if (clean_line.has_prefix("webtunnel ")) {
                    needs_webtunnel = true;
                }
            }

            if (!needs_obfs4 && !needs_webtunnel) return true;

            string? lyrebird_path = find_lyrebird_executable();
            string? obfs4proxy_path = find_obfs4proxy_executable();

            if (needs_webtunnel) {
                if (lyrebird_path == null) {
                    bootstrap_percent = 0;
                    bootstrap_summary = _("WebTunnel bridges require Lyrebird");
                    warning("WebTunnel bridges require lyrebird, but no lyrebird executable was found.");
                    bootstrap_status(0, bootstrap_summary);
                    return false;
                }

                if (needs_obfs4) {
                    if (!append_transport_command(torrc, "obfs4,webtunnel", lyrebird_path)) return false;
                    debug("[TOR] Using lyrebird for obfs4 and webtunnel: %s", lyrebird_path);
                } else {
                    if (!append_transport_command(torrc, "webtunnel", lyrebird_path)) return false;
                    debug("[TOR] Using lyrebird for webtunnel: %s", lyrebird_path);
                }
                return true;
            }

            if (needs_obfs4) {
                if (lyrebird_path != null) {
                    if (!append_transport_command(torrc, "obfs4", lyrebird_path)) return false;
                    debug("[TOR] Using lyrebird for obfs4: %s", lyrebird_path);
                } else if (obfs4proxy_path != null) {
                    if (!append_transport_command(torrc, "obfs4", obfs4proxy_path)) return false;
                    debug("[TOR] Using obfs4proxy for obfs4: %s", obfs4proxy_path);
                } else {
                    bootstrap_percent = 0;
                    bootstrap_summary = _("obfs4 bridges require Lyrebird or obfs4proxy");
                    warning("obfs4 bridges require lyrebird or obfs4proxy, but no pluggable transport executable was found.");
                    bootstrap_status(0, bootstrap_summary);
                    return false;
                }
            }

            return true;
        }

        private bool append_transport_command(StringBuilder torrc, string transports, string path) {
            try {
                var command = new TransportCommand(path);
                torrc.append(command.config_line(transports));
                transport_working_directory = command.working_directory;
                return true;
            } catch (Error e) {
                bootstrap_percent = 0;
                bootstrap_summary = e.message;
                warning("Cannot configure bridge transport: %s", e.message);
                bootstrap_status(0, bootstrap_summary);
                return false;
            }
        }

        private void check_installation() {
            check_installation_async.begin((obj, res) => check_installation_async.end(res));
        }

        private ArrayList<OwnedProcess> checking_processes = new ArrayList<OwnedProcess>();

        private async void check_installation_async() {
            try {
                string? tor_path = find_tor_executable();
                if (tor_path == null) {
                    debug("Tor executable not found yet.");
                    return;
                }
                string[] argv = {tor_path, "--version"};
                OwnedProcess proc = OwnedProcess.spawn(argv, null);
                checking_processes.add(proc);
                yield proc.wait_async();
                checking_processes.remove(proc);
                retire_process(proc);
                if (proc.get_exit_status() == 0) {
                    debug("Tor executable found.");
                } else {
                    debug("Tor executable NOT found or errored.");
                }
            } catch (Error e) {
                debug("Tor check skipped: %s", e.message);
            }
        }

        private int find_free_port(int start_port) {
            int port = start_port;
            // Try up to 100 ports
            for (int i = 0; i < 100; i++) {
                try {
                    // Try to bind a socket to this port
                    Socket socket = new Socket(SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
                    InetAddress address = new InetAddress.from_string("127.0.0.1");
                    InetSocketAddress socket_address = new InetSocketAddress(address, (uint16)port);
                    
                    socket.bind(socket_address, false);
                    socket.close();
                    
                    // If we get here, port is free
                    return port;
                } catch (Error e) {
                    // Port likely in use, try next
                    port++;
                }
            }
            // Fallback to start_port if all fail (unlikely)
            return start_port;
        }

        public virtual void clean_state() {
            string data_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "tor");
            warning("TorController: Cleaning Tor state in %s", data_dir);
            
            // Remove files that might contain corrupted state
            string[] files_to_delete = {"cached-certs", "cached-microdescs", "cached-microdesc-consensus", "cached-descriptors", "cached-descriptors.new", "state", "tor.pid", "lock", "cached-extrainfo", "cached-extrainfo.new"};
            
            foreach (string fname in files_to_delete) {
                string p = Path.build_filename(data_dir, fname);
                if (FileUtils.test(p, FileTest.EXISTS)) {
                    if (FileUtils.unlink(p) != 0) {
                        // Just log warning, not critical
                        warning("TorController: Failed to delete %s", p);
                    }
                }
            }
        }

        public virtual async void start() {
            if (is_running || is_starting) return;
            uint generation = ++operation_generation;
            is_starting = true;
            socks_ready = false;
            transport_working_directory = null;
            bootstrap_percent = 0;
            bootstrap_summary = "";
            last_log_lines.clear();

            // Only await process trees owned by this controller. Never kill
            // unrelated system Tor instances or other profiles by command line.
            yield await_stopping_processes();
            if (generation != operation_generation) return;
            string data_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "tor");

            // Find a free port only after the preceding owned process tree drained.
            socks_port = find_free_port(9155);
            debug("TorController: Selected available port: %d", socks_port);

            DirUtils.create_with_parents(data_dir, 0700);

            // Cleanup stale PID file if it exists, just to be clean
            string pid_file = Path.build_filename(data_dir, "tor.pid");
            if (FileUtils.test(pid_file, FileTest.EXISTS)) {
                FileUtils.unlink(pid_file);
            }
            
            string torrc_path = Path.build_filename(data_dir, "torrc");

            StringBuilder torrc = new StringBuilder();
            torrc.append_printf("DataDirectory %s\n", quote_torrc_path(data_dir));
            torrc.append_printf("PidFile %s\n", quote_torrc_path(pid_file));
            torrc.append_printf("SocksPort %d\n", socks_port);
            
            // Try to find GeoIP files
            string? packaged_tor_data_dir = Environment.get_variable("DINOX_TOR_DATA_DIR");
            if (packaged_tor_data_dir != null && packaged_tor_data_dir.strip() != "") {
                packaged_tor_data_dir = File.new_for_path(packaged_tor_data_dir).get_path();
            }
            string[] geoip_opts = {};
            if (packaged_tor_data_dir != null && packaged_tor_data_dir.strip() != "") {
                geoip_opts += Path.build_filename(packaged_tor_data_dir, "geoip");
            }
#if WINDOWS
            string? edir = get_executable_dir();
            if (edir != null) {
                geoip_opts += Path.build_filename(edir, "share", "tor", "geoip");
            }
            geoip_opts += "C:\\msys64\\mingw64\\share\\tor\\geoip";
            geoip_opts += "C:\\msys64\\share\\tor\\geoip";
#else
            geoip_opts += "/app/share/tor/geoip";
            var local_geoip = new Gee.ArrayList<string>();
            add_local_build_candidates(local_geoip, Path.build_filename("share", "tor", "geoip"));
            foreach (string path in local_geoip) geoip_opts += path;
            geoip_opts += "/usr/share/tor/geoip";
            geoip_opts += "/usr/local/share/tor/geoip";
#endif
            foreach (string p in geoip_opts) {
                if (FileUtils.test(p, FileTest.EXISTS)) {
                    torrc.append_printf("GeoIPFile %s\n", quote_torrc_path(p));
                    break;
                }
            }
            string[] geoip6_opts = {};
            if (packaged_tor_data_dir != null && packaged_tor_data_dir.strip() != "") {
                geoip6_opts += Path.build_filename(packaged_tor_data_dir, "geoip6");
            }
#if WINDOWS
            if (edir != null) {
                geoip6_opts += Path.build_filename(edir, "share", "tor", "geoip6");
            }
            geoip6_opts += "C:\\msys64\\mingw64\\share\\tor\\geoip6";
            geoip6_opts += "C:\\msys64\\share\\tor\\geoip6";
#else
            geoip6_opts += "/app/share/tor/geoip6";
            var local_geoip6 = new Gee.ArrayList<string>();
            add_local_build_candidates(local_geoip6, Path.build_filename("share", "tor", "geoip6"));
            foreach (string path in local_geoip6) geoip6_opts += path;
            geoip6_opts += "/usr/share/tor/geoip6";
            geoip6_opts += "/usr/local/share/tor/geoip6";
#endif
            foreach (string p in geoip6_opts) {
                 if (FileUtils.test(p, FileTest.EXISTS)) {
                    torrc.append_printf("GeoIPv6File %s\n", quote_torrc_path(p));
                    break;
                }
            }

            if (use_bridges && bridge_lines.strip() != "") {
                if (!append_client_transport_plugins(torrc, bridge_lines)) {
                    is_starting = false;
                    return;
                }

                torrc.append("UseBridges 1\n");
                
                // Firewall Bypass Logic
                if (force_firewall_ports) {
                    torrc.append("FascistFirewall 1\n");
                    torrc.append("ReachableAddresses *:80,*:443\n");
                }

                foreach (string line in bridge_lines.split("\n")) {
                    string clean_line = line.strip();
                    if (clean_line != "" && !clean_line.has_prefix("#")) {
                        torrc.append_printf("Bridge %s\n", clean_line);
                    }
                }
            }

            try {
                FileUtils.set_contents(torrc_path, torrc.str);
                // DEBUG PRINT TORRC
                debug("[TOR-DEBUG] Writing torrc to: %s", torrc_path);
                debug("[TOR-DEBUG] Content:\n%s", torrc.str);
            } catch (Error e) {
                warning("Failed to write torrc: %s", e.message);
                is_starting = false;
                return;
            }

            string? tor_path = find_tor_executable();
            if (tor_path == null) {
                bootstrap_percent = 0;
                bootstrap_summary = _("Tor executable was not found");
                warning("Failed to start Tor: no Tor executable found.");
                bootstrap_status(0, bootstrap_summary);
                is_starting = false;
                return;
            }

            // Resolve before changing cwd; an explicit helper override may
            // itself be relative to DinoX's original working directory.
            string[] argv = {File.new_for_path(tor_path).get_path(), "-f", torrc_path};

            try {
                OwnedProcess proc = OwnedProcess.spawn(argv, transport_working_directory);
                tor_process = proc;
                is_running = true;
                is_starting = false;
                debug("Tor process started with PID: %s", proc.get_identifier());
                monitor_process.begin(proc, generation, (obj, res) => monitor_process.end(res));

                bool port_open = yield wait_until_port_open(socks_port, proc, generation);
                if (generation != operation_generation || tor_process != proc) return;
                if (!port_open) {
                    warning("Tor request port %d did not open. Stopping Tor process.", socks_port);
                    stop();
                    return;
                }
                socks_ready = true;
                started();
                
            } catch (Error e) {
                warning("Failed to start Tor: %s", e.message);
                // CRITICAL FIX: Ensure we don't leave a zombie process if start fails (e.g. timeout)
                if (generation == operation_generation) stop();
            }
        }
        
        private async bool wait_until_port_open(int port, OwnedProcess proc, uint generation) {
            debug("Waiting for Tor request port %d to open...", port);
            // Wait up to 20 seconds (200 * 100ms) - Bridges can be slow to initialize
            for (int i = 0; i < 200; i++) {
                // Abort early if user disabled Tor while we were waiting
                if (!is_running || generation != operation_generation || tor_process != proc) {
                    debug("Tor stopped while waiting for port %d. Aborting.", port);
                    return false;
                }
                try {
                    Socket socket = new Socket(SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
                    InetAddress address = new InetAddress.from_string("127.0.0.1");
                    InetSocketAddress socket_address = new InetSocketAddress(address, (uint16)port);
                    
                    bool connected = socket.connect(socket_address);
                    socket.close();
                    if (connected) {
                        debug("Tor request port %d is open!", port);
                        return true;
                    }
                } catch (Error e) {
                    // Ignore connection refused, keep waiting
                }
                
                // Yield to main loop properly so IO can happen
                Timeout.add(100, () => {
                    wait_until_port_open.callback();
                    return false;
                });
                yield;
            }
            warning("Timed out waiting for Tor port %d to open.", port);
            return false;
        }

        public void report_error(string summary) {
            socks_ready = false;
            bootstrap_percent = 0;
            bootstrap_summary = summary;
            bootstrap_status(0, summary);
        }

        public virtual void stop() {
            operation_generation++;
            OwnedProcess? proc = tor_process;
            tor_process = null;
            if (proc != null) retire_process((!) proc);
            var checks = new ArrayList<OwnedProcess>();
            checks.add_all(checking_processes);
            checking_processes.clear();
            foreach (OwnedProcess check in checks) retire_process(check);
            socks_ready = false;
            is_running = false;
            is_starting = false;
            bootstrap_percent = 0;
            bootstrap_summary = _("Stopped");
            bootstrap_status(0, bootstrap_summary);
        }

        private void retire_process(OwnedProcess proc) {
            if (stopping_processes.contains(proc)) return;
            stopping_processes.add(proc);
            proc.request_stop();
            drain_owned_process.begin(proc, (obj, res) => drain_owned_process.end(res));
        }

        private async void drain_owned_process(OwnedProcess proc) {
            bool warned = false;
            do {
                try {
                    yield proc.stop_and_wait();
                } catch (Error error) {
                    if (!warned) {
                        warning("Could not finish stopping owned Tor process: %s", error.message);
                        warned = true;
                    }
                }
                if (!proc.is_tree_drained()) {
                    // Retain the owner after an exceptional native deadline.
                    // Its supervisor still tracks a late exit; shutdown must
                    // not report success while a process remains alive.
                    Timeout.add(200, () => {
                        drain_owned_process.callback();
                        return Source.REMOVE;
                    });
                    yield;
                }
            } while (!proc.is_tree_drained());
            stopping_processes.remove(proc);
            if (stopping_processes.is_empty) owned_processes_stopped();
        }

        private async void await_stopping_processes() {
            if (stopping_processes.is_empty) return;
            ulong handler = owned_processes_stopped.connect(() => {
                await_stopping_processes.callback();
            });
            yield;
            disconnect(handler);
        }

        public virtual async void stop_and_wait() {
            stop();
            yield await_stopping_processes();
        }

        private async void monitor_process(OwnedProcess proc, uint generation) {
            try {
                // Read stderr AND stdout while waiting
                var stderr_pipe = new DataInputStream(proc.get_stderr_pipe()) {
                    newline_type = DataStreamNewlineType.ANY
                };
                var stdout_pipe = new DataInputStream(proc.get_stdout_pipe()) {
                    newline_type = DataStreamNewlineType.ANY
                };
                
                // We create a background task to read logs
                read_logs.begin(stderr_pipe, "STDERR", proc, generation, (obj, res) => read_logs.end(res));
                read_logs.begin(stdout_pipe, "STDOUT", proc, generation, (obj, res) => read_logs.end(res));

                yield proc.wait_async();
                
                if (this.tor_process == proc && generation == operation_generation) { // if still the active process
                    int status = proc.get_exit_status();
                    warning("Tor process exited unexpectedly with status: %d", status);
                    if (status != 0) {
                        warning("--- Last Tor Logs ---");
                        foreach (string l in last_log_lines) {
                            warning("%s", l);
                        }
                        warning("---------------------");
                    }
                    tor_process = null;
                    socks_ready = false;
                    is_running = false;
                    is_starting = false;
                    bootstrap_percent = 0;
                    retire_process(proc);
                    process_exited(status);
                }
            } catch (Error e) {
                if (tor_process == proc && generation == operation_generation) {
                    tor_process = null;
                    socks_ready = false;
                    is_running = false;
                    is_starting = false;
                    bootstrap_percent = 0;
                    retire_process(proc);
                    process_exited(1);
                }
                warning("Error waiting for Tor process: %s", e.message);
            }
        }

        private async void read_logs(DataInputStream pipe, string type, OwnedProcess proc, uint generation) {
            try {
                // Set the input stream to non-blocking to ensure we don't hang if there's no output initially?
                // Actually, read_line_async is fine. But we need to make sure we catch everything.
                string? line;
                Regex? bootstrap_regex = null;
                try {
                     bootstrap_regex = new Regex("Bootstrapped (\\d+)% \\((.+?)\\): (.+)");
                } catch (Error e) { warning("Regex error: %s", e.message); }

                while ((line = yield pipe.read_line_async()) != null) {
                    if (generation != operation_generation || tor_process != proc) return;
                    if (bootstrap_regex != null && line.contains("Bootstrapped")) {
                        MatchInfo info;
                        if (bootstrap_regex.match(line, 0, out info)) {
                            int percent = int.parse(info.fetch(1));
                            string summary = info.fetch(3);
                            bootstrap_percent = percent;
                            bootstrap_summary = summary;
                            bootstrap_status(percent, summary);
                        }
                    }

                    string log_entry = "[Tor %s] %s".printf(type, line);
                    debug("%s", log_entry);
                    last_log_lines.add(log_entry);
                    if (last_log_lines.size > 20) last_log_lines.remove_at(0);
                }
            } catch (Error e) {
                 debug("[TOR-READ-ERROR-%s] %s", type, e.message);
            }
        }

    }
}
