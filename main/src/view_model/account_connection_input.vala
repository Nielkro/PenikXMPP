/*
 * Copyright (C) 2026 DinoX Team
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Dino.Entities;
using Xmpp;

namespace Dino.Ui.ManageAccounts {

public enum AccountConnectionInputIssue {
    NONE,
    CUSTOM_SERVER,
    PROXY_ENDPOINT,
    PROXY_CREDENTIALS,
    RUNTIME_PROXY_UNAVAILABLE
}

/**
 * Validates the connection fields used before an account is persisted.
 * Applying is transactional: invalid input never changes the account.
 */
public class AccountConnectionInput : Object {
    private string custom_host_text;
    private string custom_port_text;
    private bool proxy_enabled;
    private string proxy_host_text;
    private string proxy_port_text;
    private string proxy_user_text;
    private string proxy_pass_text;

    public AccountConnectionInput(string custom_host_text,
                                  string custom_port_text,
                                  bool proxy_enabled,
                                  string proxy_host_text,
                                  string proxy_port_text,
                                  string proxy_user_text,
                                  string proxy_pass_text) {
        this.custom_host_text = custom_host_text;
        this.custom_port_text = custom_port_text;
        this.proxy_enabled = proxy_enabled;
        this.proxy_host_text = proxy_host_text;
        this.proxy_port_text = proxy_port_text;
        this.proxy_user_text = proxy_user_text;
        this.proxy_pass_text = proxy_pass_text;
    }

    public AccountConnectionInputIssue validate() {
        string custom_host = custom_host_text.strip();
        string custom_port = custom_port_text.strip();
        if ((custom_host == "") != (custom_port == "") ||
                (custom_host != "" && (!is_valid_host(custom_host) || parse_port(custom_port) == 0))) {
            return AccountConnectionInputIssue.CUSTOM_SERVER;
        }

        if (!proxy_enabled) return AccountConnectionInputIssue.NONE;

        string proxy_host = proxy_host_text.strip();
        if (!is_valid_host(proxy_host) || parse_port(proxy_port_text) == 0) {
            return AccountConnectionInputIssue.PROXY_ENDPOINT;
        }
        if (proxy_pass_text != "" && proxy_user_text.strip() == "") {
            return AccountConnectionInputIssue.PROXY_CREDENTIALS;
        }
        return AccountConnectionInputIssue.NONE;
    }

    /**
     * Applies an enabled application-wide proxy to a transient account before
     * its first connection. Invalid or not-yet-ready providers fail closed and
     * leave the account unchanged.
     */
    public static AccountConnectionInputIssue apply_runtime_proxy_to(Account account,
                                                                      bool enabled,
                                                                      bool ready,
                                                                      string proxy_type,
                                                                      string proxy_host,
                                                                      int proxy_port) {
        if (!enabled) return AccountConnectionInputIssue.NONE;

        string host = proxy_host.strip();
        if (!ready ||
                (proxy_type != "tor" && proxy_type != "socks5") ||
                !is_valid_host(host) ||
                proxy_port <= 0 || proxy_port > 65535) {
            return AccountConnectionInputIssue.RUNTIME_PROXY_UNAVAILABLE;
        }

        account.proxy_type = proxy_type;
        account.proxy_host = host;
        account.proxy_port = proxy_port;
        account.proxy_user = null;
        account.proxy_pass = null;
        return AccountConnectionInputIssue.NONE;
    }

    public AccountConnectionInputIssue apply_to(Account account) {
        AccountConnectionInputIssue issue = validate();
        if (issue != AccountConnectionInputIssue.NONE) return issue;

        string custom_host = custom_host_text.strip();
        account.custom_host = custom_host != "" ? custom_host : null;
        account.custom_port = custom_host != "" ? parse_port(custom_port_text) : 0;

        if (proxy_enabled) {
            string proxy_user = proxy_user_text.strip();
            account.proxy_type = "socks5";
            account.proxy_host = proxy_host_text.strip();
            account.proxy_port = parse_port(proxy_port_text);
            account.proxy_user = proxy_user != "" ? proxy_user : null;
            account.proxy_pass = proxy_pass_text != "" ? proxy_pass_text : null;
        } else {
            account.proxy_type = "none";
            account.proxy_host = null;
            account.proxy_port = 0;
            account.proxy_user = null;
            account.proxy_pass = null;
        }
        return AccountConnectionInputIssue.NONE;
    }

    /**
     * Preserves a manually configured SOCKS5 endpoint independently from its
     * active state. The account settings UI uses these values when users
     * disable the proxy temporarily and enable it again later.
     */
    public void persist_socks5_preferences(Database db, Account account) {
        if (!proxy_enabled || account.id <= 0 || account.proxy_type != "socks5") return;

        persist_account_setting(db, account.id, "socks5_host", account.proxy_host ?? "");
        persist_account_setting(db, account.id, "socks5_port", account.proxy_port.to_string());
        persist_account_setting(db, account.id, "socks5_user", account.proxy_user ?? "");
        persist_account_setting(db, account.id, "socks5_pass", account.proxy_pass ?? "");
    }

    private static void persist_account_setting(Database db, int account_id, string key, string value) {
        db.account_settings.upsert()
            .value(db.account_settings.account_id, account_id, true)
            .value(db.account_settings.key, key, true)
            .value(db.account_settings.value, value)
            .perform();
    }

    private static int parse_port(string text) {
        int port = 0;
        if (!int.try_parse(text.strip(), out port)) return 0;
        return port > 0 && port <= 65535 ? port : 0;
    }

    private static bool is_valid_host(string host) {
        if (host == "") return false;
        if (GLib.Hostname.is_ip_address(host)) return true;
        if (host.contains(":") ||
                host.contains("/") ||
                host.contains("\\") ||
                host.contains("@") ||
                host.contains("?") ||
                host.contains("#") ||
                host.contains("[") ||
                host.contains("]") ||
                host.contains(" ") ||
                host.contains("\t") ||
                host.contains("\n") ||
                host.contains("\r")) {
            return false;
        }

        try {
            Jid jid = new Jid(host);
            return jid.localpart == null && jid.resourcepart == null;
        } catch (InvalidJidError error) {
            return false;
        }
    }
}

}
