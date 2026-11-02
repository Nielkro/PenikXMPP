namespace Dino.Plugins.Mqtt {

/** Shared broker controls. The caller owns Save & Apply and the connection. */
internal class DnsSecurityGroup : Adw.PreferencesGroup {
    private Adw.ComboRow mode;
    private Adw.EntryRow resolver;
    private Adw.ActionRow explanation;
    private Adw.ActionRow status;
    private Adw.ActionRow resolver_help;
    public signal void changed();

    public DnsSecurityGroup(bool standalone = false) {
        title = _("Connection security");
        description = _("These settings apply only to this MQTT broker, independently of XMPP accounts.");
        mode = new Adw.ComboRow() { title = _("DNSSEC and DANE"), use_subtitle = true };
        var choices = new Gtk.StringList(null);
        choices.append(_("Off"));
        choices.append(_("Check supporting domains"));
        choices.append(_("Require DNSSEC and DANE"));
        mode.model = choices;
        add(mode);
        explanation = new Adw.ActionRow() { title = _("How this mode works") };
        add(explanation);
        resolver = new Adw.EntryRow() { title = _("HTTPS DNS resolver") };
        resolver.show_apply_button = false;
        add(resolver);
        resolver_help = new Adw.ActionRow() {
            title = _("DNS queries"),
            subtitle = standalone ?
                _("Standalone MQTT connects directly. Leave the resolver empty to use system DNS. Account proxy settings do not apply here.") :
                _("Leave the resolver empty to use system DNS directly. Tor and SOCKS5 require an HTTPS resolver through the account's proxy.")
        };
        add(resolver_help);
        status = new Adw.ActionRow() { title = _("Verification status") };
        add(status);
        mode.notify["selected"].connect(() => { update_explanation(); changed(); });
        resolver.changed.connect(() => changed());
        update_explanation();
    }

    private void update_explanation() {
        resolver.sensitive = mode.selected != 0;
        resolver_help.visible = mode.selected != 0;
        if (mode.selected == 0) explanation.subtitle = _("Uses the existing TLS certificate verification.");
        else if (mode.selected == 1) explanation.subtitle = _("Checks DNSSEC and uses DANE when the broker supports it. DNS errors stop the connection. Local addresses use ordinary TLS.");
        else explanation.subtitle = _("Connects only with valid DNSSEC and DANE. Requires TLS and a public broker domain.");
    }

    public void load(MqttConnectionConfig config) {
        mode.selected = config.dns_mode == "off" ? 0 : config.dns_mode == "when-available" ? 1 :
            config.dns_mode == "required" ? 2 : Gtk.INVALID_LIST_POSITION;
        resolver.text = config.dns_resolver;
        visible = Xmpp.DnsSecurity.Configuration.supported() || config.dns_mode != "off";
        update_explanation();
        update_status(false, false, null);
    }

    public void store(MqttConnectionConfig config, bool tls) throws Error {
        if (mode.selected > 2) throw new IOError.INVALID_ARGUMENT(_("Choose a DNSSEC and DANE mode."));
        string uri = resolver.text.strip();
        if (mode.selected != 0) {
            if (!Xmpp.DnsSecurity.Configuration.supported())
                throw new IOError.NOT_SUPPORTED(_("This build does not include DNSSEC and DANE support."));
            if (!tls) throw new IOError.INVALID_ARGUMENT(_("Enable TLS before enabling DNSSEC and DANE for this broker."));
            if (uri != "") {
                var parsed = Uri.parse(uri, UriFlags.NONE);
                if (parsed.get_scheme() != "https" || parsed.get_host() == null || parsed.get_userinfo() != null || parsed.get_fragment() != null)
                    throw new IOError.INVALID_ARGUMENT(_("Enter an HTTPS resolver URL without credentials or a fragment."));
            }
        }
        config.dns_mode = mode.selected == 0 ? "off" : mode.selected == 1 ? "when-available" : "required";
        config.dns_resolver = uri;
    }

    public void update_status(bool connected, bool verified, string? error, bool tls = false) {
        status.remove_css_class("success");
        status.remove_css_class("error");
        if (error != null) {
            status.subtitle = _("Connection stopped by the selected security policy. Check the broker, DNS resolver and TLS settings, then save and apply to retry.");
            status.add_css_class("error");
        } else if (connected && verified) {
            status.subtitle = _("Verified through DNSSEC and DANE");
            status.add_css_class("success");
        } else if (connected && !tls) status.subtitle = _("Connected without TLS.");
        else if (connected) status.subtitle = _("Connected with ordinary TLS; DANE is not active.");
        else status.subtitle = _("No active verified connection.");
    }
}

}
