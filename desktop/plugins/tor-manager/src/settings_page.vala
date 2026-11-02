using Gtk;
using Adw;
using GLib;

namespace Dino.Plugins.TorManager {

    public class TorSettingsPage : Adw.PreferencesPage {
        private TorManager manager;
        private TextView bridge_input_view;
        private Button fetch_button;
        private Adw.ActionRow main_switch_row;
        private uint debounce_timeout_id = 0;
        private bool ignore_text_changes = false;
        
        private Switch firewall_switch;
        private Switch bridges_switch;
        private Label warning_label;
        private Label restart_status_label;
        private Gtk.DropDown transport_dropdown;
        private uint restart_status_clear_id = 0;
        private bool content_initialized = false;
        private uint deferred_content_source_id = 0;

        public TorSettingsPage(TorManager manager) {
            this.manager = manager;
            this.title = _("Tor");
            this.icon_name = "network-server-symbolic"; 
            this.name = "tor";
        }

        public void ensure_content() {
            if (content_initialized) return;
            content_initialized = true;

            var group = new Adw.PreferencesGroup();
            group.title = _("Tor Connection");
            this.add(group);

            main_switch_row = new Adw.ActionRow();
            main_switch_row.title = _("Enable Integrated Tor");
            main_switch_row.subtitle = _("Starts a private Tor process for DinoX");
            
            var toggle = new Switch();
            toggle.valign = Align.CENTER;
            toggle.active = manager.is_enabled;
            
            toggle.notify["active"].connect(() => {
                if (manager.is_enabled != toggle.active) {
                    manager.set_enabled.begin(toggle.active);
                }
            });
            
            main_switch_row.add_suffix(toggle);
            group.add(main_switch_row);
            
            // Bridge Config
             var bridge_group = new Adw.PreferencesGroup();
             bridge_group.title = _("Bridges (Censorship Circumvention)");
             bridge_group.description = _("Required if Tor is blocked. Supports obfs4 and WebTunnel bridges.");
             this.add(bridge_group);

             // Use Bridges Switch
            var use_bridges_row = new Adw.ActionRow();
            use_bridges_row.title = _("Use Bridges");
            use_bridges_row.subtitle = _("Hides the fact that you are using Tor.");
            
            bridges_switch = new Switch();
            bridges_switch.valign = Align.CENTER;
            bridges_switch.active = manager.use_bridges;

            use_bridges_row.add_suffix(bridges_switch);
            bridge_group.add(use_bridges_row);


            // Fascist Firewall Switch
            var firewall_row = new Adw.ActionRow();
            firewall_row.title = _("Firewall Mode (Port 80/443 Only)");
            firewall_row.subtitle = _("Only connect to bridges using standard web ports. Helps behind strict firewalls.");
             
            firewall_switch = new Switch();
            firewall_switch.valign = Align.CENTER;
            firewall_switch.active = manager.force_firewall_ports;
            
            // Warning Label for Firewall + Bridges
            warning_label = new Label(_("Warning: Only bridges on port 80/443 will work when Firewall Mode is enabled!"));
            warning_label.add_css_class("error"); // Red text
            warning_label.halign = Align.START;
            warning_label.wrap = true;
            warning_label.xalign = 0;
            warning_label.margin_start = 12;
            warning_label.margin_bottom = 12;
            warning_label.visible = false;
            
            firewall_switch.notify["active"].connect(() => {
                on_firewall_toggled.begin(firewall_switch.active, (obj, res) => on_firewall_toggled.end(res));
                update_warning();
            });

            firewall_row.add_suffix(firewall_switch);
            bridge_group.add(firewall_row);
            bridge_group.add(warning_label);

            restart_status_label = new Label("");
            restart_status_label.add_css_class("dim-label");
            restart_status_label.halign = Align.START;
            restart_status_label.wrap = true;
            restart_status_label.xalign = 0;
            restart_status_label.margin_start = 12;
            restart_status_label.margin_bottom = 12;
            restart_status_label.visible = false;
            bridge_group.add(restart_status_label);
            
            update_warning();


             var box = new Box(Orientation.VERTICAL, 0);
             box.add_css_class("card");
             box.sensitive = manager.use_bridges;
             
             // Label for manual input
             var manual_label = new Label(_("Bridge List (Auto or Manual Entry)"));
             manual_label.halign = Align.START;
             manual_label.margin_start = 12;
             manual_label.margin_top = 12;
             manual_label.add_css_class("heading");
             box.append(manual_label);

             var scrolled = new ScrolledWindow();
             scrolled.min_content_height = 100;
             scrolled.propagate_natural_height = true;
             // Add frame for input look
             scrolled.add_css_class("frame"); 
             
             bridge_input_view = new TextView();
             bridge_input_view.top_margin = 12;
             bridge_input_view.bottom_margin = 12;
             bridge_input_view.left_margin = 12;
             bridge_input_view.right_margin = 12;
             bridge_input_view.wrap_mode = WrapMode.WORD_CHAR;
             bridge_input_view.buffer.text = manager.controller.bridge_lines;
             
             bridge_input_view.buffer.changed.connect(() => {
                 on_bridges_text_changed_debounced();
             });

             scrolled.set_child(bridge_input_view);
             box.append(scrolled);
             bridge_group.add(box);

             // Action Row for Fetching with transport selector
             var fetch_row = new Adw.ActionRow();
             fetch_row.title = _("Request Fresh Bridges");
             fetch_row.subtitle = _("Fetches bridges from Tor Project. Choose transport type:");
             fetch_row.sensitive = manager.use_bridges;

             // Transport type dropdown: obfs4 or webtunnel
             string[] transport_labels = { "obfs4", "WebTunnel" };
             transport_dropdown = create_dropdown(transport_labels);
             transport_dropdown.selected = 1; // Default: WebTunnel (best for strict firewalls)
             transport_dropdown.valign = Align.CENTER;
             fetch_row.add_suffix(transport_dropdown);
             
             fetch_button = new Button.with_label(_("Request"));
             fetch_button.valign = Align.CENTER;
             fetch_button.clicked.connect(() => { on_fetch_clicked.begin((obj, res) => on_fetch_clicked.end(res)); });
             
             fetch_row.add_suffix(fetch_button);
             bridge_group.add(fetch_row);

            // Connect signal late to ensure all widgets exist
            bridges_switch.notify["active"].connect(() => {
                bool active = bridges_switch.active;
                on_use_bridges_toggled.begin(active, (obj, res) => on_use_bridges_toggled.end(res));
                box.sensitive = active;
                fetch_row.sensitive = active;
                firewall_row.sensitive = active;
                update_warning();
            });

            // Init sensitive state
            firewall_row.sensitive = manager.use_bridges;

            // Sync main switch if manager changes state (e.g. crash or external change)
            manager.notify["is-enabled"].connect(() => {
                if (toggle.active != manager.is_enabled) {
                     toggle.active = manager.is_enabled;
                }
            });


             var help_label = new Label(_("WebTunnel (port 443, looks like HTTPS) is best for strict firewalls. obfs4 is more widely available. Both fetch instantly without CAPTCHA."));
             help_label.add_css_class("dim-label");
             help_label.margin_top = 6;
             help_label.wrap = true;
             help_label.xalign = 0;
             help_label.halign = Align.START;
            bridge_group.add(help_label);
        }

        public void queue_content() {
            if (content_initialized || deferred_content_source_id != 0) return;
            deferred_content_source_id = Idle.add_full(GLib.Priority.LOW, () => {
                deferred_content_source_id = 0;
                ensure_content();
                return Source.REMOVE;
            });
        }

        ~TorSettingsPage() {
            if (deferred_content_source_id != 0) {
                Source.remove(deferred_content_source_id);
                deferred_content_source_id = 0;
            }
            if (debounce_timeout_id != 0) {
                Source.remove(debounce_timeout_id);
                debounce_timeout_id = 0;
            }
            if (restart_status_clear_id != 0) {
                Source.remove(restart_status_clear_id);
                restart_status_clear_id = 0;
            }
        }

        private async void on_use_bridges_toggled(bool state) {
            // Keep the main switch available to cancel a pending Tor restart.
            bool show_restart = manager.is_enabled;
            if (show_restart) {
                show_restart_status(_("Restarting Tor to apply bridge settings..."));
            }
            yield manager.update_use_bridges(state);
            if (show_restart) {
                show_restart_result(_("Tor bridge settings applied."));
            }
        }

        private void update_warning() {
            if (warning_label != null && bridges_switch != null && firewall_switch != null) {
                warning_label.visible = bridges_switch.active && firewall_switch.active;
            }
        }

        private async void on_firewall_toggled(bool state) {
            bool show_restart = manager.is_enabled;
            if (show_restart) {
                show_restart_status(_("Restarting Tor to apply firewall mode..."));
            }
            yield manager.update_firewall_ports(state);
            if (show_restart) {
                show_restart_result(_("Tor firewall mode applied."));
            }
        }

        private void on_bridges_text_changed_debounced() {
            if (ignore_text_changes) return;
            
            if (debounce_timeout_id != 0) {
                Source.remove(debounce_timeout_id);
                debounce_timeout_id = 0;
            }
            debounce_timeout_id = Timeout.add(1500, () => {
                commit_bridges_text.begin((obj, res) => commit_bridges_text.end(res));
                debounce_timeout_id = 0;
                return false;
            });
        }

        private async void commit_bridges_text() {
            bool show_restart = manager.is_enabled;
            if (show_restart) {
                show_restart_status(_("Restarting Tor to apply bridge list changes..."));
            }
            yield manager.set_bridges(bridge_input_view.buffer.text);
            if (show_restart) {
                show_restart_result(_("Tor bridge list applied."));
            }
        }

        private void show_restart_status(string message) {
            if (restart_status_clear_id != 0) {
                Source.remove(restart_status_clear_id);
                restart_status_clear_id = 0;
            }
            restart_status_label.label = message;
            restart_status_label.visible = true;
        }

        private void show_temporary_status(string message) {
            show_restart_status(message);
            restart_status_clear_id = Timeout.add_seconds(6, () => {
                restart_status_label.visible = false;
                restart_status_clear_id = 0;
                return Source.REMOVE;
            });
        }

        private void show_restart_result(string success_message) {
            if (manager.is_enabled && manager.controller.is_running) {
                show_temporary_status(success_message);
            } else {
                show_temporary_status(_("Tor restart failed. Check bridges and try again."));
            }
        }

        private async void on_fetch_clicked() {
            fetch_button.sensitive = false;
            fetch_button.label = _("Loading...");
            
            // Get selected transport from dropdown
            string transport = transport_dropdown.selected == 0 ? "obfs4" : "webtunnel";
            
            try {
                var client = new BridgeClient();
                string[] bridges = yield client.fetch_bridges(transport);

                // Health-check each bridge before applying
                fetch_button.label = _("Checking...");
                string[] health_results = yield check_bridges_health(bridges);

                yield apply_fetched_bridges(bridges, transport, health_results);
            } catch (Error e) {
                var dlg = new Adw.AlertDialog(
                    _("Error fetching bridges"),
                    e.message
                );
                dlg.add_response("ok", _("OK"));
                dlg.present(this.get_root() as Gtk.Window);
            } finally {
                fetch_button.sensitive = true;
                fetch_button.label = _("Request");
            }
        }

        /**
         * Check reachability of each bridge.
         * For webtunnel: HTTPS HEAD to the URL domain.
         * For obfs4: TCP connect to IP:port.
         * Returns an array of status strings (one per bridge).
         */
        private async string[] check_bridges_health(string[] bridges) {
            string[] results = new string[bridges.length];

            for (int i = 0; i < bridges.length; i++) {
                string bridge = bridges[i].strip();
                if (bridge.has_prefix("webtunnel ")) {
                    results[i] = yield check_webtunnel_bridge(bridge);
                } else if (bridge.has_prefix("obfs4 ")) {
                    results[i] = yield check_obfs4_bridge(bridge);
                } else {
                    results[i] = _("Unknown type");
                }
            }
            return results;
        }

        private async string check_webtunnel_bridge(string bridge) {
            // Extract URL from "webtunnel <ip>:<port> <fingerprint> url=https://... ver=..."
            string? url = null;
            int url_pos = bridge.index_of("url=");
            if (url_pos >= 0) {
                string after = bridge.substring(url_pos + 4);
                // URL ends at space or end of string
                int space = after.index_of(" ");
                url = (space >= 0) ? after.substring(0, space) : after;
            }

            if (url == null || url.length == 0) {
                return "✘ " + _("No URL found");
            }

            // Extract just the domain for display
            string domain = url;
            if (domain.has_prefix("https://")) domain = domain.substring(8);
            int slash = domain.index_of("/");
            if (slash >= 0) domain = domain.substring(0, slash);

            try {
                var session = new Soup.Session();
                session.timeout = 10;
                var msg = new Soup.Message("HEAD", url);
                // Avoid HTTP/2 teardown warnings for this short-lived bridge probe.
                msg.set_force_http1(true);
                yield session.send_and_read_async(msg, Priority.DEFAULT, null);

                uint code = msg.status_code;
                if (code == 0) {
                    return "✘ %s — %s".printf(domain, _("unreachable"));
                }
                // Any HTTP response means DNS, TLS and the web front are reachable.
                // Some working WebTunnel fronts intentionally return 5xx to normal HTTP.
                return "✔ %s — HTTP %u".printf(domain, code);
            } catch (Error e) {
                if (e.message.contains("resolve") || e.message.contains("DNS")) {
                    return "✘ %s — %s".printf(domain, _("DNS failed"));
                }
                return "✘ %s — %s".printf(domain, _("unreachable"));
            }
        }

        private async string check_obfs4_bridge(string bridge) {
            // Extract IP:port from "obfs4 <ip>:<port> <fingerprint> cert=... iat-mode=..."
            string[] parts = bridge.split(" ");
            if (parts.length < 2) return "✘ " + _("Invalid format");

            string addr = parts[1]; // e.g. "76.70.53.139:9856"
            int colon = addr.last_index_of(":");
            if (colon < 0) return "✘ " + _("Invalid address");

            string host = addr.substring(0, colon);
            uint16 port = (uint16) int.parse(addr.substring(colon + 1));

            try {
                var client = new SocketClient();
                client.timeout = 5;
                var address = new InetAddress.from_string(host);
                var sock_addr = new InetSocketAddress(address, port);
                
                var connection = yield client.connect_async(sock_addr, null);
                if (connection != null) {
                    try { connection.close(); } catch (Error e) { }
                    return "✔ %s:%u".printf(host, port);
                } else {
                    return "✘ %s:%u — %s".printf(host, port, _("unreachable"));
                }
            } catch (Error e) {
                return "✘ %s:%u — %s".printf(host, port, _("unreachable"));
            }
        }

        private async void apply_fetched_bridges(string[] bridges, string transport, string[] health_results) {
            if (bridges.length > 0) {
                // Sort bridges: prefer webtunnel, then obfs4 on port 443/80
                int good_ports = 0;
                Gee.ArrayList<string> sorted_bridges = new Gee.ArrayList<string>();
                Gee.ArrayList<string> sorted_health = new Gee.ArrayList<string>();
                foreach(string b in bridges) {
                    int idx = -1;
                    for (int i = 0; i < bridges.length; i++) {
                        if (bridges[i] == b) { idx = i; break; }
                    }
                    string health = (idx >= 0 && idx < health_results.length) ? health_results[idx] : "?";

                     if (b.has_prefix("webtunnel ")) {
                         sorted_bridges.insert(0, b);
                         sorted_health.insert(0, health);
                         good_ports++;
                     } else if (b.contains(":443 ") || b.contains(":80 ") || b.contains(":4433 ")) {
                         sorted_bridges.insert(good_ports, b);
                         sorted_health.insert(good_ports, health);
                         good_ports++;
                     } else {
                         sorted_bridges.add(b);
                         sorted_health.add(health);
                     }
                }

                StringBuilder sb = new StringBuilder();
                foreach (string b in sorted_bridges) {
                    sb.append(b);
                    sb.append("\n");
                }
                
                string new_bridges_text = sb.str;
                
                debug("TorSettingsPage: Applying new bridges (sorted) to UI:\n%s", new_bridges_text);
                
                ignore_text_changes = true;
                bridge_input_view.buffer.set_text(""); 
                while (MainContext.default().pending()) MainContext.default().iteration(false);
                bridge_input_view.buffer.set_text(new_bridges_text);
                ignore_text_changes = false;

                debug("TorSettingsPage: Explicitly saving new bridges...");
                yield manager.set_bridges(new_bridges_text);

                // Build health report
                int alive_count = 0;
                int dead_count = 0;
                StringBuilder health_report = new StringBuilder();
                for (int i = 0; i < sorted_health.size; i++) {
                    string h = sorted_health[i];
                    health_report.append(h);
                    health_report.append("\n");
                    if (h.has_prefix("✔")) alive_count++;
                    else dead_count++;
                }

                string msg = _("Received %d %s bridge(s).").printf(bridges.length, transport);
                msg += "\n" + _("Reachable: %d  \u2022  Dead: %d").printf(alive_count, dead_count);
                msg += "\n\n" + health_report.str;

                if (dead_count > 0 && alive_count == 0) {
                    msg += "\n" + _("All bridges are unreachable! Try a different transport type.");
                }

                string title = (dead_count > 0 && alive_count == 0)
                    ? _("Warning") : _("Success");
                var success_dlg = new Adw.AlertDialog(title, msg);
                success_dlg.add_response("ok", _("OK"));
                if (dead_count > 0) {
                     success_dlg.add_response("retry", _("Try Again"));
                }

                success_dlg.response.connect((resp) => {
                    if (resp == "retry") {
                        on_fetch_clicked.begin((obj, res) => on_fetch_clicked.end(res));
                    }
                });

                success_dlg.present(this.get_root() as Gtk.Window);
            } else {
                 var fail_dlg = new Adw.AlertDialog(_("Failed"), _("No bridges received. The server may be temporarily unavailable."));
                 fail_dlg.add_response("retry", _("Try Again"));
                 fail_dlg.add_response("cancel", _("Cancel"));
                 
                 fail_dlg.response.connect((resp) => {
                    if (resp == "retry") {
                        on_fetch_clicked.begin((obj, res) => on_fetch_clicked.end(res));
                    }
                 });
                 
                 fail_dlg.present(this.get_root() as Gtk.Window);
            }
        }
    }

    private static Gtk.DropDown create_dropdown(string[] labels) {
        var model = new Gtk.StringList(null);
        foreach (string label in labels) {
            model.append(label);
        }
        return new Gtk.DropDown(model, null);
    }
}
