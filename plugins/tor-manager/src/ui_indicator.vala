using Gtk;
using Adw;
using GLib;
using Gee;
using Dino.Entities;

namespace Dino.Plugins.TorManager {

    public class TorIndicator : Object {
        private TorManager manager;
        private Dino.Application dino_app;
        private GLib.NetworkMonitor? network_monitor;
        private ToggleButton button;
        private Popover popover;
        private Image icon;
        private Label summary_label;
        private Label system_status_label;
        private Label xmpp_status_label;
        private Label tor_status_label;
        private Box accounts_box;
        private Box providers_box;
        private Switch? toggle_switch;
        private HashSet<string> connected_provider_ids = new HashSet<string>();
        private bool is_bootstrapped = false;
        private uint account_refresh_source = 0;

        public TorIndicator(TorManager manager, Dino.Application app) {
            this.manager = manager;
            this.dino_app = app;
            this.network_monitor = GLib.NetworkMonitor.get_default();

            app.plugin_registry.network_status_provider_registered.connect((provider) => {
                connect_provider(provider);
                rebuild_provider_widgets();
                update_status();
            });

            var si = manager.get_stream_interactor();
            si.account_added.connect(on_accounts_changed);
            si.account_removed.connect(on_accounts_changed);
            si.connection_manager.connection_state_changed.connect(on_connection_state_changed);
            si.connection_manager.connection_error.connect((account, error) => update_status());

            if (network_monitor != null) {
                network_monitor.network_changed.connect((available) => update_status());
                network_monitor.notify["connectivity"].connect(() => update_status());
            }

            var gtk_app = GLib.Application.get_default() as Gtk.Application;
            if (gtk_app != null) {
                gtk_app.activate.connect(() => {
                    start_search_loop(gtk_app);
                });

                if (gtk_app.active_window != null) {
                     start_search_loop(gtk_app);
                }
            }
        }

        ~TorIndicator() {
            if (account_refresh_source != 0) Source.remove(account_refresh_source);
        }

        private void on_accounts_changed(Account account) {
            if (account_refresh_source != 0) return;
            // Account and connection notifications can precede changes to the
            // managed list. Refresh after that change, coalescing notifications.
            account_refresh_source = attach_account_refresh(this);
        }

        private void on_connection_state_changed(Account account, ConnectionManager.ConnectionState state) {
            // Disabling an account uses ConnectionManager directly, without an
            // account_removed signal. Its provider rows must be refreshed too.
            on_accounts_changed(account);
        }

        private static uint attach_account_refresh(TorIndicator owner) {
            var weak_owner = WeakRef(owner);
            return Idle.add(() => {
                var indicator = weak_owner.get() as TorIndicator;
                if (indicator != null) {
                    indicator.account_refresh_source = 0;
                    indicator.rebuild_provider_widgets();
                    indicator.update_status();
                }
                return Source.REMOVE;
            });
        }

        private void start_search_loop(Gtk.Application app, int attempt = 0) {
            Timeout.add(500, () => {
                if (button != null) return Source.REMOVE;

                var window = app.active_window;
                if (window != null) {
                    init_ui(app);
                    if (button != null) return Source.REMOVE;
                }

                if (attempt < 10) {
                     start_search_loop(app, attempt + 1);
                } else {
                     warning("TorManager: Could not find sidebar header bar to attach network indicator after 5 seconds.");
                }
                return Source.REMOVE;
            });
        }

        private void init_ui(Gtk.Application app) {
            if (button != null) return;

            var window = app.active_window;
            if (window == null) return;

            var header = find_sidebar_header(window);
            if (header != null) {
                create_button();
                header.pack_end(button);
            }
        }

        private Adw.HeaderBar? find_sidebar_header(Widget root) {
            if (root is Adw.HeaderBar) {
                if (root.has_css_class("dino-left")) return (Adw.HeaderBar)root;
            }

            for (var child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
                var found = find_sidebar_header(child);
                if (found != null) return found;
            }
            return null;
        }

        private void create_button() {
            button = new ToggleButton();
            button.has_frame = false;
            button.tooltip_text = _("Network Status");

            icon = new Image.from_icon_name("network-wired-symbolic");
            button.child = icon;

            popover = new Popover();
            popover.set_parent(button);
            popover.autohide = true;
            popover.has_arrow = true;

            popover.closed.connect(() => {
                button.active = false;
            });
            button.toggled.connect(() => {
                if (button.active) {
                    rebuild_provider_widgets();
                    update_status();
                    popover.popup();
                } else {
                    popover.popdown();
                }
            });

            var box = new Box(Orientation.VERTICAL, 10);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            box.set_size_request(300, -1);

            var title = new Label(_("Network Status"));
            title.add_css_class("title-4");
            title.halign = Align.START;
            box.append(title);

            summary_label = new Label(_("Checking status..."));
            summary_label.add_css_class("dim-label");
            summary_label.halign = Align.START;
            summary_label.wrap = true;
            summary_label.xalign = 0;
            box.append(summary_label);

            var overview_box = new Box(Orientation.VERTICAL, 4);
            overview_box.append(make_section_label(_("Overview")));
            system_status_label = make_status_value_label();
            overview_box.append(make_row(_("System"), system_status_label));
            xmpp_status_label = make_status_value_label();
            overview_box.append(make_row(_("XMPP"), xmpp_status_label));
            box.append(overview_box);

            var accounts_section = new Box(Orientation.VERTICAL, 4);
            accounts_section.append(make_section_label(_("Accounts")));
            accounts_box = new Box(Orientation.VERTICAL, 4);
            accounts_section.append(accounts_box);
            box.append(accounts_section);

            var tor_section = new Box(Orientation.VERTICAL, 6);
            tor_section.append(make_section_label(_("Tor")));
            tor_status_label = make_status_value_label();
            tor_section.append(make_row(_("Status"), tor_status_label));

            var row_box = new Box(Orientation.HORIZONTAL, 12);
            var row_label = new Label(_("Enable Tor"));
            row_label.halign = Align.START;
            row_label.hexpand = true;
            row_box.append(row_label);

            toggle_switch = new Switch();
            toggle_switch.valign = Align.CENTER;
            toggle_switch.active = manager.is_enabled;
            toggle_switch.notify["active"].connect(() => {
                 if (manager.is_enabled != toggle_switch.active) {
                     manager.set_enabled.begin(toggle_switch.active);
                 }
            });
            manager.notify["is-enabled"].connect(() => {
                if (toggle_switch.active != manager.is_enabled) {
                    toggle_switch.active = manager.is_enabled;
                }
                update_status();
            });

            row_box.append(toggle_switch);
            tor_section.append(row_box);

            var settings_btn = new Button.with_label(_("Tor Settings"));
            settings_btn.add_css_class("pill");
            settings_btn.clicked.connect(() => {
                popover.popdown();
                var app = GLib.Application.get_default();
                if (app != null) {
                     app.activate_action("preferences-page", new Variant.string("tor"));
                }
            });
            tor_section.append(settings_btn);
            box.append(tor_section);

            providers_box = new Box(Orientation.VERTICAL, 6);
            box.append(providers_box);

            // Keep the complete overview, including Tor controls, reachable
            // when account and provider lists exceed the available height.
            var scrolled = new ScrolledWindow() {
                hscrollbar_policy = PolicyType.NEVER,
                vscrollbar_policy = PolicyType.AUTOMATIC,
                propagate_natural_height = true,
                max_content_height = 420,
                propagate_natural_width = true,
                max_content_width = 420,
                child = box
            };
            popover.set_child(scrolled);

            manager.controller.notify["is-running"].connect(() => {
                if (!manager.controller.is_running) is_bootstrapped = false;
                update_status();
            });
            manager.controller.notify["is-starting"].connect(() => {
                update_status();
            });
            manager.controller.bootstrap_status.connect((percent, summary) => {
                 if (percent == 0) {
                     is_bootstrapped = false;
                     tor_status_label.label = summary;
                 } else if (percent >= 100) {
                     is_bootstrapped = true;
                 } else {
                     tor_status_label.label = _("Bootstrapping: %d%%").printf(percent);
                 }
                 update_status();
            });

            foreach (NetworkStatusProvider provider in dino_app.plugin_registry.network_status_providers) {
                connect_provider(provider);
            }
            rebuild_provider_widgets();
            update_status();
        }

        private Label make_section_label(string text) {
            var label = new Label(text);
            label.add_css_class("heading");
            label.halign = Align.START;
            label.xalign = 0;
            return label;
        }

        private Label make_status_value_label() {
            var label = new Label("");
            label.halign = Align.END;
            label.xalign = 1;
            label.wrap = true;
            label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            label.max_width_chars = 24;
            return label;
        }

        private Box make_row(string title, Label value_label) {
            var row = new Box(Orientation.HORIZONTAL, 12);
            var label = new Label(title);
            label.halign = Align.FILL;
            label.xalign = 0;
            label.hexpand = true;
            label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            label.max_width_chars = 24;
            label.tooltip_text = title;
            row.append(label);
            row.append(value_label);
            return row;
        }

        private void connect_provider(NetworkStatusProvider provider) {
            if (connected_provider_ids.contains(provider.id)) return;
            connected_provider_ids.add(provider.id);
            provider.status_changed.connect(() => {
                rebuild_provider_widgets();
                update_status();
            });
        }

        private void rebuild_provider_widgets() {
            if (providers_box == null) return;
            Widget? child;
            while ((child = providers_box.get_first_child()) != null) {
                providers_box.remove(child);
            }

            foreach (NetworkStatusProvider provider in dino_app.plugin_registry.network_status_providers) {
                var widget = provider.get_widget(WidgetType.GTK4) as Widget;
                if (widget != null) providers_box.append(widget);
            }
        }

        private bool system_network_available() {
            return network_monitor == null || network_monitor.network_available;
        }

        private void update_status() {
            if (icon == null) return;

            update_system_status();
            update_xmpp_status();
            update_account_rows();
            update_tor_status();

            NetworkStatusLevel level = get_aggregate_status();
            apply_level_to_icon(level);

            string text = get_aggregate_label(level);
            summary_label.label = text;
            button.tooltip_text = text;
        }

        private void update_system_status() {
            bool online = system_network_available();
            system_status_label.label = online ? _("Online") : _("Offline");
            apply_level_to_label(system_status_label, online ? NetworkStatusLevel.OK : NetworkStatusLevel.ERROR);
        }

        private void update_xmpp_status() {
            int total = 0;
            int connected = 0;
            int connecting = 0;
            foreach (Account account in manager.get_stream_interactor().get_accounts()) {
                if (!account.enabled) continue;
                total++;
                var state = manager.get_stream_interactor().connection_manager.get_state(account);
                if (state == ConnectionManager.ConnectionState.CONNECTED) connected++;
                else if (state == ConnectionManager.ConnectionState.CONNECTING) connecting++;
            }

            if (total == 0) {
                xmpp_status_label.label = _("No active accounts");
                apply_level_to_label(xmpp_status_label, NetworkStatusLevel.DISABLED);
            } else if (connected == total) {
                xmpp_status_label.label = _("%d/%d connected").printf(connected, total);
                apply_level_to_label(xmpp_status_label, NetworkStatusLevel.OK);
            } else if (connected > 0 || connecting > 0) {
                xmpp_status_label.label = _("%d/%d connected").printf(connected, total);
                apply_level_to_label(xmpp_status_label, NetworkStatusLevel.WARNING);
            } else {
                xmpp_status_label.label = _("Disconnected");
                apply_level_to_label(xmpp_status_label, NetworkStatusLevel.ERROR);
            }
        }

        private void update_account_rows() {
            Widget? child;
            while ((child = accounts_box.get_first_child()) != null) {
                accounts_box.remove(child);
            }

            foreach (Account account in manager.get_stream_interactor().get_accounts()) {
                if (!account.enabled) continue;

                var state = manager.get_stream_interactor().connection_manager.get_state(account);
                NetworkStatusLevel level = NetworkStatusLevel.ERROR;
                string state_label = _("Disconnected");
                if (state == ConnectionManager.ConnectionState.CONNECTED) {
                    level = NetworkStatusLevel.OK;
                    state_label = _("Connected");
                } else if (state == ConnectionManager.ConnectionState.CONNECTING) {
                    level = NetworkStatusLevel.WARNING;
                    state_label = _("Connecting...");
                }

                string route = get_account_route(account);
                var value = make_status_value_label();
                value.label = "%s - %s".printf(state_label, route);
                var connection_manager = manager.get_stream_interactor().connection_manager;
                try {
                    if (connection_manager.get_dns_security_mode(account) != Xmpp.DnsSecurity.Mode.OFF) {
                        var stream = connection_manager.get_stream(account) as Xmpp.TlsXmppStream;
                        var error = connection_manager.get_error(account);
                        string verification = stream != null && stream.dns_security != null && stream.dns_security.verified ?
                            _("DANE verified") : error != null && error.source == ConnectionManager.ConnectionError.Source.DNS_SECURITY ?
                            _("DNSSEC/DANE failed") : state == ConnectionManager.ConnectionState.CONNECTED ?
                            _("DANE not active") : _("DANE pending");
                        value.label += "\n" + verification;
                    }
                } catch (Error error) { value.label += "\n" + _("Invalid DNSSEC settings"); }
                value.tooltip_text = value.label;
                apply_level_to_label(value, level);
                var row = make_row(account.bare_jid.to_string(), value);
                var settings = new Button.from_icon_name("go-next-symbolic");
                settings.add_css_class("flat");
                settings.tooltip_text = _("Open account settings");
                settings.clicked.connect(() => {
                    popover.popdown();
                    GLib.Application.get_default().activate_action("preferences-account", new Variant.int32(account.id));
                });
                row.append(settings);
                accounts_box.append(row);
            }

            if (accounts_box.get_first_child() == null) {
                var value = make_status_value_label();
                value.label = _("No active accounts");
                apply_level_to_label(value, NetworkStatusLevel.DISABLED);
                accounts_box.append(make_row(_("Accounts"), value));
            }
        }

        private string get_account_route(Account account) {
            if (account.proxy_type == "tor") return _("Tor");
            if (account.proxy_type == "socks5") {
                string host = account.proxy_host ?? "";
                if (host != "" && account.proxy_port > 0) {
                    return _("SOCKS5 %s:%d").printf(host, account.proxy_port);
                }
                return _("SOCKS5");
            }
            return _("Direct");
        }

        private void update_tor_status() {
            if (manager.controller.is_running) {
                if (is_bootstrapped) {
                    string mode = manager.use_bridges ? _("Bridges") : _("Direct");
                    if (manager.force_firewall_ports) {
                        mode += " + " + _("Firewall");
                    }
                    tor_status_label.label = _("Connected (%s)").printf(mode);
                    apply_level_to_label(tor_status_label, NetworkStatusLevel.OK);
                } else {
                    if (tor_status_label.label == "") tor_status_label.label = _("Starting...");
                    apply_level_to_label(tor_status_label, NetworkStatusLevel.WARNING);
                }
            } else if (manager.is_enabled || manager.controller.is_starting) {
                string summary = manager.controller.bootstrap_summary;
                if (!manager.controller.is_starting && summary != "" && summary != _("Stopped")) {
                    tor_status_label.label = summary;
                } else {
                    tor_status_label.label = _("Starting...");
                }
                apply_level_to_label(tor_status_label, NetworkStatusLevel.WARNING);
            } else {
                tor_status_label.label = _("Disabled");
                apply_level_to_label(tor_status_label, NetworkStatusLevel.DISABLED);
            }
        }

        private NetworkStatusLevel get_aggregate_status() {
            if (!system_network_available()) return NetworkStatusLevel.ERROR;

            int total = 0;
            int connected = 0;
            int connecting = 0;
            foreach (Account account in manager.get_stream_interactor().get_accounts()) {
                if (!account.enabled) continue;
                total++;
                var state = manager.get_stream_interactor().connection_manager.get_state(account);
                if (state == ConnectionManager.ConnectionState.CONNECTED) connected++;
                else if (state == ConnectionManager.ConnectionState.CONNECTING) connecting++;
            }

            // Providers may be active without any XMPP account (for example
            // standalone MQTT), or remain connected while XMPP is offline.
            foreach (NetworkStatusProvider provider in dino_app.plugin_registry.network_status_providers) {
                switch (provider.get_status_level()) {
                    case NetworkStatusLevel.OK:
                        total++;
                        connected++;
                        break;
                    case NetworkStatusLevel.WARNING:
                        total++;
                        connecting++;
                        break;
                    case NetworkStatusLevel.ERROR:
                        total++;
                        break;
                    case NetworkStatusLevel.DISABLED:
                        break;
                }
            }

            if (total == 0) return NetworkStatusLevel.DISABLED;
            if (connected == 0 && connecting == 0) return NetworkStatusLevel.ERROR;
            if (connected < total || connecting > 0) return NetworkStatusLevel.WARNING;
            if (manager.is_enabled && (!manager.controller.is_running || !is_bootstrapped)) return NetworkStatusLevel.WARNING;

            return NetworkStatusLevel.OK;
        }

        private string get_aggregate_label(NetworkStatusLevel level) {
            switch (level) {
                case NetworkStatusLevel.OK:
                    return _("Connected");
                case NetworkStatusLevel.WARNING:
                    return _("Partially connected");
                case NetworkStatusLevel.ERROR:
                    return _("Offline");
                case NetworkStatusLevel.DISABLED:
                    return _("No active accounts");
            }
            return _("Unknown Status");
        }

        private void apply_level_to_icon(NetworkStatusLevel level) {
            icon.remove_css_class("success");
            icon.remove_css_class("warning");
            icon.remove_css_class("error");
            icon.remove_css_class("dim-label");

            switch (level) {
                case NetworkStatusLevel.OK:
                    icon.add_css_class("success");
                    break;
                case NetworkStatusLevel.WARNING:
                    icon.add_css_class("warning");
                    break;
                case NetworkStatusLevel.ERROR:
                    icon.add_css_class("error");
                    break;
                case NetworkStatusLevel.DISABLED:
                    icon.add_css_class("dim-label");
                    break;
            }
        }

        private void apply_level_to_label(Label label, NetworkStatusLevel level) {
            label.remove_css_class("success");
            label.remove_css_class("warning");
            label.remove_css_class("error");
            label.remove_css_class("dim-label");

            switch (level) {
                case NetworkStatusLevel.OK:
                    label.add_css_class("success");
                    break;
                case NetworkStatusLevel.WARNING:
                    label.add_css_class("warning");
                    break;
                case NetworkStatusLevel.ERROR:
                    label.add_css_class("error");
                    break;
                case NetworkStatusLevel.DISABLED:
                    label.add_css_class("dim-label");
                    break;
            }
        }
    }
}
