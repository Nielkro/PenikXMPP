using Gtk;

using Dino.Entities;

namespace Dino.Plugins.OpenPgp {

public class ContactDetailsProvider : Plugins.ContactDetailsProvider, Object {
    private const uint XEP0373_KEY_CHECK_TIMEOUT_SECONDS = 45;

    public string id { get { return "pgp_info"; } }
    public string tab { get { return "encryption"; } }

    private class KeyserverFetchResult : Object {
        public bool found { get; set; default = false; }
        public string? fingerprint { get; set; default = null; }
        public string error_msg { get; set; default = ""; }
        public GPGHelper.Key? key { get; set; default = null; }
    }

    private class RowUpdateToken : Object {
        public uint generation = 0;
        public bool cancelled = false;
        public Adw.AlertDialog? email_dialog = null;
        public Xep0373KeyManager.RequestGuard? xep0373_request_guard = null;

        public void cancel() {
            cancelled = true;
            generation++;
            cancel_xep0373_request();
            if (email_dialog != null) {
                ((!) email_dialog).force_close();
                email_dialog = null;
            }
        }

        public void set_xep0373_request_guard(Xep0373KeyManager.RequestGuard guard) {
            cancel_xep0373_request();
            xep0373_request_guard = guard;
        }

        public void clear_xep0373_request_guard(Xep0373KeyManager.RequestGuard guard) {
            if (xep0373_request_guard == guard) {
                xep0373_request_guard = null;
            }
        }

        private void cancel_xep0373_request() {
            if (xep0373_request_guard != null) {
                ((!) xep0373_request_guard).cancel();
                xep0373_request_guard = null;
            }
        }
    }

    private class StatusSignalCleanup : Object {
        private Conversation conversation;
        private Manager? manager;
        public ulong encryption_notify_id = 0;
        public ulong key_state_changed_id = 0;

        public StatusSignalCleanup(Conversation conversation, Manager? manager) {
            this.conversation = conversation;
            this.manager = manager;
        }

        public void disconnect_all() {
            if (encryption_notify_id != 0 && SignalHandler.is_connected(conversation, encryption_notify_id)) {
                conversation.disconnect(encryption_notify_id);
            }
            encryption_notify_id = 0;

            if (manager != null && key_state_changed_id != 0) {
                Manager manager_ref = (!) manager;
                if (SignalHandler.is_connected(manager_ref, key_state_changed_id)) {
                    manager_ref.disconnect(key_state_changed_id);
                }
            }
            key_state_changed_id = 0;
        }
    }

    private class ContactKeySnapshot : Object {
        public string? legacy_key;
        public bool legacy_announced;
        public string? xmpp_key;
        public bool supports_xmpp_openpgp;
        public string xmpp_trust_state;

        public ContactKeySnapshot(string? legacy_key, bool legacy_announced, string? xmpp_key, bool supports_xmpp_openpgp, string xmpp_trust_state) {
            update(legacy_key, legacy_announced, xmpp_key, supports_xmpp_openpgp, xmpp_trust_state);
        }

        public void update(string? legacy_key, bool legacy_announced, string? xmpp_key, bool supports_xmpp_openpgp, string xmpp_trust_state) {
            this.legacy_key = legacy_key;
            this.legacy_announced = legacy_announced;
            this.xmpp_key = xmpp_key;
            this.supports_xmpp_openpgp = supports_xmpp_openpgp;
            this.xmpp_trust_state = xmpp_trust_state;
        }

        public bool differs_from(string? legacy_key, bool legacy_announced, string? xmpp_key, bool supports_xmpp_openpgp, string xmpp_trust_state) {
            return !nullable_strings_equal(this.legacy_key, legacy_key) ||
                this.legacy_announced != legacy_announced ||
                !nullable_strings_equal(this.xmpp_key, xmpp_key) ||
                this.supports_xmpp_openpgp != supports_xmpp_openpgp ||
                this.xmpp_trust_state != xmpp_trust_state;
        }

        private static bool nullable_strings_equal(string? a, string? b) {
            if (a == null || b == null) return a == b;
            return (!) a == (!) b;
        }
    }

    private StreamInteractor stream_interactor;
    private Database db;

    public ContactDetailsProvider(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
    }

    public void populate(Conversation conversation, Plugins.ContactDetails contact_details, WidgetType type) { }

    public Object? get_widget(Conversation conversation) {
        if (conversation == null) return null;
        
        var preferences_group = new Adw.PreferencesGroup() { title="OpenPGP" };

        if (conversation.type_ != Conversation.Type.CHAT) return null;

        string? legacy_key = db.get_contact_legacy_key(conversation.account, conversation.counterpart.bare_jid);
        bool legacy_key_announced = db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid);
        string? xmpp_key = db.get_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
        bool supports_xmpp_openpgp = db.contact_supports_xep0374(conversation.account, conversation.counterpart.bare_jid);
        string xmpp_trust_state = db.get_contact_xmpp_trust_state(conversation.account, conversation.counterpart.bare_jid);

        Gtk.Image legacy_status_icon;
        Gtk.Image xmpp_status_icon;
        Adw.ActionRow legacy_status_row;
        Adw.ActionRow xmpp_status_row;
        add_openpgp_status_rows(preferences_group, legacy_key, legacy_key_announced, xmpp_key, supports_xmpp_openpgp, xmpp_trust_state, conversation,
                out legacy_status_row, out legacy_status_icon, out xmpp_status_row, out xmpp_status_icon);

        return preferences_group;
    }

    private bool widgets_can_update(Gtk.Widget row, Gtk.Widget icon) {
        return row.get_root() != null && icon.get_root() != null;
    }

    private void cancel_openpgp_status_rows(RowUpdateToken legacy_update_token, RowUpdateToken xmpp_update_token,
            StatusSignalCleanup status_signal_cleanup) {
        legacy_update_token.cancel();
        xmpp_update_token.cancel();
        status_signal_cleanup.disconnect_all();
    }

    private void add_openpgp_status_rows(Adw.PreferencesGroup preferences_group, string? legacy_key, bool legacy_key_announced, string? xmpp_key,
            bool supports_xmpp_openpgp, string xmpp_trust_state, Conversation conversation,
            out Adw.ActionRow legacy_row, out Gtk.Image legacy_icon, out Adw.ActionRow xmpp_row, out Gtk.Image xmpp_icon) {
        legacy_row = new Adw.ActionRow() {
            title = _("OpenPGP Legacy (XEP-0027/keyserver)"),
            subtitle = get_legacy_status_description(legacy_key, legacy_key_announced)
        };
        legacy_icon = new Gtk.Image.from_icon_name(legacy_key != null && legacy_key_announced ? "check-plain-symbolic" : "dialog-information-symbolic");
        legacy_row.add_suffix(legacy_icon);
        Adw.ActionRow legacy_row_ref = legacy_row;
        Gtk.Image legacy_fetch_icon_ref = legacy_icon;
        var legacy_update_token = new RowUpdateToken();
        var xmpp_update_token = new RowUpdateToken();
        var key_snapshot = new ContactKeySnapshot(legacy_key, legacy_key_announced, xmpp_key, supports_xmpp_openpgp, xmpp_trust_state);
        var legacy_fetch_btn = new Gtk.Button.from_icon_name("sync-synchronizing-symbolic");
        legacy_fetch_btn.valign = Gtk.Align.CENTER;
        legacy_fetch_btn.add_css_class("flat");
        legacy_fetch_btn.tooltip_text = _("Search keyserver");
        legacy_fetch_btn.clicked.connect(() => {
            fetch_key_combined.begin(conversation, legacy_row_ref, legacy_fetch_icon_ref, legacy_update_token);
        });
        legacy_row.add_suffix(legacy_fetch_btn);
        preferences_group.add(legacy_row);

        xmpp_row = new Adw.ActionRow() {
            title = _("OpenPGP XMPP (XEP-0373/0374)"),
            subtitle = get_xmpp_status_description(xmpp_key, supports_xmpp_openpgp, xmpp_trust_state)
        };
        xmpp_icon = new Gtk.Image.from_icon_name(get_xmpp_status_icon(xmpp_key, xmpp_trust_state));
        apply_xmpp_status_icon(xmpp_icon, xmpp_key, xmpp_trust_state);
        xmpp_row.add_suffix(xmpp_icon);
        Adw.ActionRow xmpp_row_ref = xmpp_row;
        Gtk.Image legacy_icon_ref = legacy_icon;
        Gtk.Image xmpp_icon_ref = xmpp_icon;
        var xmpp_copy_btn = new Gtk.Button.from_icon_name("edit-copy-symbolic");
        xmpp_copy_btn.valign = Gtk.Align.CENTER;
        xmpp_copy_btn.add_css_class("flat");
        xmpp_copy_btn.tooltip_text = _("Copy XMPP-published OpenPGP fingerprint");
        xmpp_copy_btn.visible = xmpp_key != null;
        xmpp_copy_btn.clicked.connect(() => {
            copy_xmpp_fingerprint(conversation, xmpp_copy_btn);
        });
        xmpp_row.add_suffix(xmpp_copy_btn);
        var xmpp_verify_btn = new Gtk.Button.from_icon_name("check-plain-symbolic");
        xmpp_verify_btn.valign = Gtk.Align.CENTER;
        xmpp_verify_btn.add_css_class("flat");
        xmpp_verify_btn.tooltip_text = _("Mark XMPP-published key as verified");
        xmpp_verify_btn.visible = xmpp_key != null;
        xmpp_verify_btn.sensitive = xmpp_key != null && xmpp_trust_state != Database.XMPP_TRUST_VERIFIED;
        var xmpp_unverify_btn = new Gtk.Button.from_icon_name("edit-clear-symbolic");
        xmpp_unverify_btn.valign = Gtk.Align.CENTER;
        xmpp_unverify_btn.add_css_class("flat");
        xmpp_unverify_btn.tooltip_text = _("Reset XMPP-published key verification");
        xmpp_unverify_btn.visible = xmpp_key != null && xmpp_trust_state == Database.XMPP_TRUST_VERIFIED;
        xmpp_verify_btn.clicked.connect(() => {
            mark_xmpp_key_verified.begin(conversation, legacy_row_ref, legacy_icon_ref, xmpp_row_ref, xmpp_icon_ref,
                    legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn);
        });
        xmpp_unverify_btn.clicked.connect(() => {
            reset_xmpp_key_verification(conversation, legacy_row_ref, legacy_icon_ref, xmpp_row_ref, xmpp_icon_ref,
                    legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn);
        });
        xmpp_row.add_suffix(xmpp_verify_btn);
        xmpp_row.add_suffix(xmpp_unverify_btn);
        var xmpp_refresh_btn = new Gtk.Button.from_icon_name("sync-synchronizing-symbolic");
        xmpp_refresh_btn.valign = Gtk.Align.CENTER;
        xmpp_refresh_btn.add_css_class("flat");
        xmpp_refresh_btn.tooltip_text = _("Refresh XMPP-published key");
        xmpp_refresh_btn.clicked.connect(() => {
            refresh_xmpp_key_status.begin(conversation, legacy_row_ref, legacy_icon_ref, xmpp_row_ref, xmpp_icon_ref,
                    legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn);
        });
        xmpp_row.add_suffix(xmpp_refresh_btn);
        preferences_group.add(xmpp_row);

        update_key_row_details.begin(legacy_row, legacy_icon, legacy_key, get_legacy_status_description(legacy_key, legacy_key_announced),
                true, null, legacy_key_announced, legacy_update_token);
        update_key_row_details.begin(xmpp_row, xmpp_icon, xmpp_key, get_xmpp_status_description(xmpp_key, supports_xmpp_openpgp, xmpp_trust_state), false,
                conversation.counterpart.bare_jid.to_string(), true, xmpp_update_token, xmpp_trust_state);

        Adw.ActionRow legacy_row_status_ref = legacy_row;
        Gtk.Image legacy_icon_status_ref = legacy_icon;
        Adw.ActionRow xmpp_row_status_ref = xmpp_row;
        Gtk.Image xmpp_icon_status_ref = xmpp_icon;
        Manager? manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
        var status_signal_cleanup = new StatusSignalCleanup(conversation, manager);
        status_signal_cleanup.encryption_notify_id = conversation.notify["encryption"].connect(() => {
            if (!widgets_can_update(legacy_row_status_ref, legacy_icon_status_ref) ||
                    !widgets_can_update(xmpp_row_status_ref, xmpp_icon_status_ref)) {
                status_signal_cleanup.disconnect_all();
                return;
            }
            refresh_status_rows_from_db(conversation, legacy_row_status_ref, legacy_icon_status_ref,
                    xmpp_row_status_ref, xmpp_icon_status_ref, legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn);
        });
        if (manager != null) {
            status_signal_cleanup.key_state_changed_id = ((!) manager).key_state_changed.connect((account, jid) => {
                if (!widgets_can_update(legacy_row_status_ref, legacy_icon_status_ref) ||
                        !widgets_can_update(xmpp_row_status_ref, xmpp_icon_status_ref)) {
                    status_signal_cleanup.disconnect_all();
                    return;
                }
                if (!account.equals(conversation.account)) return;
                if (jid != null && !((!) jid).bare_jid.equals(conversation.counterpart.bare_jid)) return;
                refresh_status_rows_from_db(conversation, legacy_row_status_ref, legacy_icon_status_ref,
                        xmpp_row_status_ref, xmpp_icon_status_ref, legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn);
            });
        }
        legacy_row.notify["root"].connect((obj, pspec) => {
            var row = obj as Gtk.Widget;
            if (row != null && row.get_root() == null) {
                cancel_openpgp_status_rows(legacy_update_token, xmpp_update_token, status_signal_cleanup);
            }
        });
        xmpp_row.notify["root"].connect((obj, pspec) => {
            var row = obj as Gtk.Widget;
            if (row != null && row.get_root() == null) {
                cancel_openpgp_status_rows(legacy_update_token, xmpp_update_token, status_signal_cleanup);
            }
        });
        legacy_row.destroy.connect(() => {
            cancel_openpgp_status_rows(legacy_update_token, xmpp_update_token, status_signal_cleanup);
        });
        xmpp_row.destroy.connect(() => {
            cancel_openpgp_status_rows(legacy_update_token, xmpp_update_token, status_signal_cleanup);
        });
    }

    private void refresh_status_rows_from_db(Conversation conversation, Adw.ActionRow legacy_row, Gtk.Image legacy_icon,
            Adw.ActionRow xmpp_row, Gtk.Image xmpp_icon, RowUpdateToken legacy_update_token, RowUpdateToken xmpp_update_token,
            ContactKeySnapshot key_snapshot, Gtk.Button? xmpp_verify_btn = null, Gtk.Button? xmpp_copy_btn = null,
            Gtk.Button? xmpp_unverify_btn = null, bool force = false) {
        if (legacy_update_token.cancelled || xmpp_update_token.cancelled) return;
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;

        string? legacy_key = db.get_contact_legacy_key(conversation.account, conversation.counterpart.bare_jid);
        bool legacy_key_announced = db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid);
        string? xmpp_key = db.get_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
        bool supports_xmpp_openpgp = db.contact_supports_xep0374(conversation.account, conversation.counterpart.bare_jid);
        string xmpp_trust_state = db.get_contact_xmpp_trust_state(conversation.account, conversation.counterpart.bare_jid);
        if (!force && !key_snapshot.differs_from(legacy_key, legacy_key_announced, xmpp_key, supports_xmpp_openpgp, xmpp_trust_state)) return;
        key_snapshot.update(legacy_key, legacy_key_announced, xmpp_key, supports_xmpp_openpgp, xmpp_trust_state);

        update_key_row_details.begin(legacy_row, legacy_icon, legacy_key, get_legacy_status_description(legacy_key, legacy_key_announced),
                true, null, legacy_key_announced, legacy_update_token);
        update_key_row_details.begin(xmpp_row, xmpp_icon, xmpp_key, get_xmpp_status_description(xmpp_key, supports_xmpp_openpgp, xmpp_trust_state), false,
                conversation.counterpart.bare_jid.to_string(), true, xmpp_update_token, xmpp_trust_state);
        if (xmpp_verify_btn != null) {
            ((!) xmpp_verify_btn).visible = xmpp_key != null && xmpp_trust_state != Database.XMPP_TRUST_VERIFIED;
            ((!) xmpp_verify_btn).sensitive = xmpp_key != null && xmpp_trust_state != Database.XMPP_TRUST_VERIFIED;
        }
        if (xmpp_copy_btn != null) {
            ((!) xmpp_copy_btn).visible = xmpp_key != null;
        }
        if (xmpp_unverify_btn != null) {
            ((!) xmpp_unverify_btn).visible = xmpp_key != null && xmpp_trust_state == Database.XMPP_TRUST_VERIFIED;
        }
    }

    private uint begin_row_update(RowUpdateToken update_token) {
        if (update_token.cancelled) return 0;
        update_token.generation++;
        return update_token.generation;
    }

    private bool row_update_is_current(RowUpdateToken update_token, uint generation) {
        return !update_token.cancelled && generation != 0 && update_token.generation == generation;
    }

    private async void refresh_xmpp_key_status(Conversation conversation, Adw.ActionRow legacy_row, Gtk.Image legacy_icon, Adw.ActionRow xmpp_row, Gtk.Image xmpp_icon,
            RowUpdateToken legacy_update_token, RowUpdateToken xmpp_update_token, ContactKeySnapshot key_snapshot,
            Gtk.Button xmpp_verify_btn, Gtk.Button xmpp_copy_btn, Gtk.Button xmpp_unverify_btn) {
        var manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
        if (manager == null || manager.xep0373_manager == null) return;
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;

        uint refresh_generation = begin_row_update(xmpp_update_token);
        if (!row_update_is_current(xmpp_update_token, refresh_generation)) return;
        xmpp_row.subtitle = _("Checking XMPP-published OpenPGP key...");
        xmpp_icon.icon_name = "sync-synchronizing-symbolic";
        bool key_check_finished = false;
        bool key_check_timed_out = false;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(XEP0373_KEY_CHECK_TIMEOUT_SECONDS, () => {
            if (key_check_finished || !row_update_is_current(xmpp_update_token, refresh_generation)) {
                timeout_id = 0;
                return Source.REMOVE;
            }
            key_check_timed_out = true;
            timeout_id = 0;
            if (row_update_is_current(xmpp_update_token, refresh_generation) && widgets_can_update(xmpp_row, xmpp_icon)) {
                xmpp_row.subtitle = _("Checking the XMPP-published OpenPGP key timed out.");
                xmpp_icon.icon_name = "dialog-warning-symbolic";
            }
            return Source.REMOVE;
        });
        var request_guard = new Xep0373KeyManager.RequestGuard();
        xmpp_update_token.set_xep0373_request_guard(request_guard);
        yield manager.xep0373_manager.request_keys_with_guard(conversation.account, conversation.counterpart.bare_jid, request_guard);
        xmpp_update_token.clear_xep0373_request_guard(request_guard);
        key_check_finished = true;
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        if (key_check_timed_out) return;
        if (!row_update_is_current(xmpp_update_token, refresh_generation)) return;
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;
        yield manager.refresh_xep0374_support(conversation.account, conversation.counterpart.bare_jid);
        if (!row_update_is_current(xmpp_update_token, refresh_generation)) return;
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;
        refresh_status_rows_from_db(conversation, legacy_row, legacy_icon, xmpp_row, xmpp_icon, legacy_update_token,
                xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn, true);
    }

    private async void update_key_row_details(Adw.ActionRow row, Gtk.Image icon, string? key_id, string status,
            bool legacy_keyserver, string? expected_xmpp_jid = null, bool active_status = true, RowUpdateToken? update_token = null,
            string? xmpp_trust_state = null) {
        uint update_generation = 0;
        if (update_token != null) {
            update_generation = begin_row_update((!) update_token);
            if (!row_update_is_current((!) update_token, update_generation)) return;
        }
        if (key_id == null || ((!) key_id).length == 0) {
            if (update_token != null && !row_update_is_current((!) update_token, update_generation)) return;
            if (!widgets_can_update(row, icon)) return;
            row.subtitle = status;
            icon.icon_name = "dialog-information-symbolic";
            return;
        }

        row.subtitle = status + "\n" + _("Checking keyring...");

        string key_id_copy = (!) key_id;
        if (!active_status) {
            if (update_token != null && !row_update_is_current((!) update_token, update_generation)) return;
            if (!widgets_can_update(row, icon)) return;
            row.subtitle = status + "\n" + markup_id(key_id_copy, key_id_copy.length >= 32);
            icon.icon_name = "dialog-information-symbolic";
            return;
        }

        string? expected_xmpp_jid_copy = expected_xmpp_jid;
        SourceFunc callback = update_key_row_details.callback;
        Gee.List<GPGHelper.Key>? keys = null;
        bool identity_ok = false;
        new Thread<void*>("openpgp-contact-key-details", () => {
            try {
                keys = GPGHelper.get_keylist(key_id_copy);
                if (legacy_keyserver) {
                    identity_ok = GPGHelper.key_has_email_uid(key_id_copy);
                } else if (expected_xmpp_jid_copy != null && ((!) expected_xmpp_jid_copy).length > 0) {
                    identity_ok = GPGHelper.key_has_xmpp_uid(key_id_copy, (!) expected_xmpp_jid_copy);
                }
            } catch (Error e) {
                debug("ContactDetailsProvider: Failed to get keylist for %s: %s", key_id_copy, e.message);
            }
            Idle.add((owned) callback);
            return null;
        });
        yield;
        if (update_token != null && !row_update_is_current((!) update_token, update_generation)) return;
        if (!widgets_can_update(row, icon)) return;

        bool key_in_keychain = keys != null && keys.size > 0;
        string? fpr = key_in_keychain ? keys[0].fpr : null;
        if (key_in_keychain && fpr != null) {
            if (!identity_ok) {
                row.subtitle = status + "\n" + (legacy_keyserver
                    ? _("Invalid for legacy XEP-0027/keyserver: key has no email user ID.")
                    : _("Invalid for OpenPGP for XMPP: key has no matching xmpp: user ID.")) + "\n" + markup_id(fpr, false);
                icon.icon_name = "dialog-warning-symbolic";
                return;
            }
            row.subtitle = status + "\n" + markup_id(fpr, true);
            if (legacy_keyserver) {
                icon.icon_name = active_status ? "check-plain-symbolic" : "dialog-information-symbolic";
            } else {
                apply_xmpp_status_icon(icon, key_id, xmpp_trust_state ?? Database.XMPP_TRUST_UNVERIFIED);
            }
        } else {
            row.subtitle = status + "\n" + _("Key not in keyring") + "\n" + markup_id(key_id_copy, false);
            icon.icon_name = legacy_keyserver ? "dialog-warning-symbolic" : "dialog-information-symbolic";
        }
    }

    private string get_legacy_status_description(string? legacy_key, bool legacy_key_announced) {
        if (legacy_key != null && legacy_key_announced) {
            return _("Active: legacy XEP-0027/keyserver key is currently usable for this contact.");
        }
        if (legacy_key != null) {
            return _("Stored: legacy XEP-0027/keyserver key is known, but is not currently active for this contact.");
        }
        return _("Inactive: no legacy XEP-0027/keyserver key is stored.");
    }

    private string get_xmpp_status_description(string? xmpp_key, bool supports_xmpp_openpgp, string xmpp_trust_state) {
        if (xmpp_key != null) {
            if (xmpp_trust_state == Database.XMPP_TRUST_VERIFIED) {
                return _("Verified: XMPP-published OpenPGP key is stored and manually verified.");
            }
            if (xmpp_trust_state == Database.XMPP_TRUST_CHANGED) {
                return _("Changed: XMPP-published OpenPGP key differs from the previously verified key. Verify the fingerprint before trusting this identity.");
            }
            return _("Unverified: XMPP-published OpenPGP key is stored. Compare the fingerprint before trusting this identity.");
        }
        if (supports_xmpp_openpgp) {
            return _("Supported: contact advertises OpenPGP for XMPP, but no retrievable XMPP-published key is stored.");
        }
        return _("Inactive: no OpenPGP-for-XMPP support or XMPP-published key is known.");
    }

    private string get_xmpp_status_icon(string? xmpp_key, string xmpp_trust_state) {
        if (xmpp_key == null || ((!) xmpp_key).length == 0) return "dialog-information-symbolic";
        if (xmpp_trust_state == Database.XMPP_TRUST_VERIFIED) return "check-plain-symbolic";
        if (xmpp_trust_state == Database.XMPP_TRUST_CHANGED) return "dialog-warning-symbolic";
        return "dialog-information-symbolic";
    }

    private void apply_xmpp_status_icon(Gtk.Image icon, string? xmpp_key, string xmpp_trust_state) {
        icon.icon_name = get_xmpp_status_icon(xmpp_key, xmpp_trust_state);
        icon.remove_css_class("success");
        icon.remove_css_class("warning");
        if (xmpp_key == null || ((!) xmpp_key).length == 0) return;
        if (xmpp_trust_state == Database.XMPP_TRUST_VERIFIED) {
            icon.add_css_class("success");
        } else if (xmpp_trust_state == Database.XMPP_TRUST_CHANGED) {
            icon.add_css_class("warning");
        }
    }

    private void copy_xmpp_fingerprint(Conversation conversation, Gtk.Button copy_btn) {
        string? xmpp_key = db.get_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
        if (xmpp_key == null || ((!) xmpp_key).length == 0) return;

        Gdk.Display? display = Gdk.Display.get_default();
        if (display == null) return;

        ((!) display).get_clipboard().set_text((!) xmpp_key);
        copy_btn.tooltip_text = _("Fingerprint copied");
    }

    private async void mark_xmpp_key_verified(Conversation conversation, Adw.ActionRow legacy_row, Gtk.Image legacy_icon,
            Adw.ActionRow xmpp_row, Gtk.Image xmpp_icon, RowUpdateToken legacy_update_token, RowUpdateToken xmpp_update_token,
            ContactKeySnapshot key_snapshot, Gtk.Button xmpp_verify_btn, Gtk.Button xmpp_copy_btn, Gtk.Button xmpp_unverify_btn) {
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;
        uint verification_generation = begin_row_update(xmpp_update_token);
        if (!row_update_is_current(xmpp_update_token, verification_generation)) return;

        string? displayed_key = key_snapshot.xmpp_key;
        string? current_key = db.get_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
        if (displayed_key == null || current_key == null ||
                !fingerprint_or_keyid_matches((!) displayed_key, (!) current_key)) {
            if (!row_update_is_current(xmpp_update_token, verification_generation)) return;
            refresh_status_rows_from_db(conversation, legacy_row, legacy_icon, xmpp_row, xmpp_icon,
                    legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn, true);
            return;
        }

        string key_id_copy = (!) displayed_key;
        string jid_copy = conversation.counterpart.bare_jid.to_string();
        xmpp_verify_btn.sensitive = false;
        xmpp_row.subtitle = _("Verifying OpenPGP-for-XMPP key...");
        xmpp_icon.icon_name = "sync-synchronizing-symbolic";

        bool verification_ok = false;
        string? verified_fingerprint = null;
        SourceFunc callback = mark_xmpp_key_verified.callback;
        new Thread<void*>("openpgp-contact-key-verify", () => {
            try {
                Gee.List<GPGHelper.Key> keys = GPGHelper.get_keylist(key_id_copy);
                if (keys.size > 0) {
                    verified_fingerprint = keys[0].fpr;
                    verification_ok = fingerprint_or_keyid_matches(key_id_copy, (!) verified_fingerprint) &&
                        GPGHelper.key_has_xmpp_uid((!) verified_fingerprint, jid_copy);
                }
            } catch (Error e) {
                debug("ContactDetailsProvider: Failed to verify XMPP key %s before marking trust: %s", key_id_copy, e.message);
            }
            Idle.add((owned) callback);
            return null;
        });
        yield;

        if (!row_update_is_current(xmpp_update_token, verification_generation)) return;
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;

        current_key = db.get_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
        if (current_key == null || !fingerprint_or_keyid_matches(key_id_copy, (!) current_key)) {
            if (!row_update_is_current(xmpp_update_token, verification_generation)) return;
            refresh_status_rows_from_db(conversation, legacy_row, legacy_icon, xmpp_row, xmpp_icon,
                    legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn, true);
            return;
        }

        if (!verification_ok) {
            xmpp_row.subtitle = _("Cannot verify: key is not in the keyring or has no matching xmpp: user ID.") + "\n" + markup_id(key_id_copy, false);
            xmpp_icon.icon_name = "dialog-warning-symbolic";
            xmpp_verify_btn.sensitive = true;
            return;
        }

        if (!row_update_is_current(xmpp_update_token, verification_generation)) return;
        db.mark_contact_xmpp_key_verified(conversation.account, conversation.counterpart.bare_jid);
        var manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
        if (manager != null) {
            manager.notify_key_state_changed(conversation.account, conversation.counterpart.bare_jid);
        }
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;
        refresh_status_rows_from_db(conversation, legacy_row, legacy_icon, xmpp_row, xmpp_icon,
                legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn, true);
    }

    private void reset_xmpp_key_verification(Conversation conversation, Adw.ActionRow legacy_row, Gtk.Image legacy_icon,
            Adw.ActionRow xmpp_row, Gtk.Image xmpp_icon, RowUpdateToken legacy_update_token, RowUpdateToken xmpp_update_token,
            ContactKeySnapshot key_snapshot, Gtk.Button xmpp_verify_btn, Gtk.Button xmpp_copy_btn, Gtk.Button xmpp_unverify_btn) {
        if (legacy_update_token.cancelled || xmpp_update_token.cancelled) return;
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;

        db.reset_contact_xmpp_key_verification(conversation.account, conversation.counterpart.bare_jid);
        var manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
        if (manager != null) {
            manager.notify_key_state_changed(conversation.account, conversation.counterpart.bare_jid);
        }
        if (!widgets_can_update(legacy_row, legacy_icon) || !widgets_can_update(xmpp_row, xmpp_icon)) return;
        refresh_status_rows_from_db(conversation, legacy_row, legacy_icon, xmpp_row, xmpp_icon,
                legacy_update_token, xmpp_update_token, key_snapshot, xmpp_verify_btn, xmpp_copy_btn, xmpp_unverify_btn, true);
    }

    private static bool fingerprint_or_keyid_matches(string expected_key, string actual_key) {
        string expected = normalize_key_match_value(expected_key);
        string actual = normalize_key_match_value(actual_key);
        if (expected.length == 0 || actual.length == 0) return false;
        return expected == actual || expected.has_suffix(actual) || actual.has_suffix(expected);
    }

    private static string normalize_key_match_value(string value) {
        return value.up().replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "");
    }
    
    // Combined fetch: try fingerprint first, then JID, then ask for email
    private async void fetch_key_combined(Conversation conversation, Adw.ActionRow row, Gtk.Image icon, RowUpdateToken update_token) {
        uint fetch_generation = begin_row_update(update_token);
        if (!row_update_is_current(update_token, fetch_generation)) return;
        string jid = conversation.counterpart.bare_jid.to_string();
        string error_msg = "";
        
        // Step 1: Use only the legacy/XEP-0027 key id for keyserver lookup.
        // Do not reuse the mode-dependent key id here; an XEP-0373 key must not
        // be treated as a keyserver/legacy identity.
        string? known_key_id = db.get_contact_legacy_key(conversation.account, conversation.counterpart.bare_jid);
        
        if (known_key_id != null) {
            row.subtitle = _("Searching keyserver with fingerprint: ") + known_key_id.substring(0, int.min(16, known_key_id.length)) + "...";
            debug("ContactDetails: Trying fingerprint %s", known_key_id);
            
            KeyserverFetchResult result = yield fetch_key_from_keyserver((!) known_key_id, update_token, fetch_generation);
            if (!row_update_is_current(update_token, fetch_generation)) return;
            if (!widgets_can_update(row, icon)) return;
            
            if (store_legacy_contact_key(conversation, result, (!) known_key_id, update_token, fetch_generation)) {
                update_key_row_details.begin(row, icon, result.fingerprint, get_legacy_status_description(result.fingerprint, db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid)), true, null,
                        db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid), update_token);
                return;
            } else {
                // Show more helpful error message
                error_msg = result.error_msg;
                if (error_msg.length == 0) {
                    error_msg = _("Key not found or has no verified email on keyserver.\nAsk the contact to verify their email on keys.openpgp.org\nor send you their public key file directly.");
                }
                row.subtitle = _("Failed: ") + error_msg;
                // Continue to try other methods
            }
        }
        
        // Step 2: Try keyserver with JID
        if (!row_update_is_current(update_token, fetch_generation)) return;
        if (!widgets_can_update(row, icon)) return;
        row.subtitle = _("Searching keyserver with JID...");
        
        KeyserverFetchResult jid_result = yield fetch_key_from_keyserver(jid, update_token, fetch_generation);
        if (!row_update_is_current(update_token, fetch_generation)) return;
        if (!widgets_can_update(row, icon)) return;
        
        if (store_legacy_contact_key(conversation, jid_result, jid, update_token, fetch_generation)) {
            update_key_row_details.begin(row, icon, jid_result.fingerprint, get_legacy_status_description(jid_result.fingerprint, db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid)), true, null,
                    db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid), update_token);
            return;
        }
        
        // Step 2: JID not found - show email input dialog directly
        if (!row_update_is_current(update_token, fetch_generation)) return;
        if (!widgets_can_update(row, icon)) return;
        yield show_email_input_dialog(conversation, row, icon, update_token);
    }
    
    private async void show_email_input_dialog(Conversation conversation, Adw.ActionRow row, Gtk.Image icon, RowUpdateToken update_token) {
        if (!widgets_can_update(row, icon)) return;
        if (!row_update_is_current(update_token, update_token.generation)) return;
        row.subtitle = _("Not found with JID. Enter email address:");
        // Find parent window
        Gtk.Window? parent_window = null;
        var widget = row as Gtk.Widget;
        while (widget != null && !(widget is Gtk.Window)) {
            widget = widget.get_parent();
        }
        if (widget is Gtk.Window) parent_window = (Gtk.Window)widget;
        if (parent_window == null) return;
        
        var dialog = new Adw.AlertDialog(
            _("Enter Email Address"),
            _("The key was not found using the JID.\n\nEnter the email address that is in the contact's OpenPGP key:")
        );
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("search", _("Search"));
        dialog.default_response = "search";
        dialog.close_response = "cancel";
        uint dialog_generation = update_token.generation;
        update_token.email_dialog = dialog;
        
        var entry = new Gtk.Entry();
        entry.placeholder_text = "user@example.com";
        entry.margin_start = 12;
        entry.margin_end = 12;
        dialog.extra_child = entry;
        
        dialog.response.connect((response) => {
            if (update_token.email_dialog != dialog) return;
            if (response == "search") {
                if (!row_update_is_current(update_token, dialog_generation)) return;
                if (!widgets_can_update(row, icon)) return;
                string email = entry.text.strip();
                if (email.length > 0) {
                    update_token.email_dialog = null;
                    fetch_key_by_email.begin(conversation, email, row, icon, update_token);
                }
            }
        });
        dialog.closed.connect(() => {
            if (update_token.email_dialog == dialog) {
                update_token.email_dialog = null;
            }
        });
        
        dialog.present(parent_window);
    }
    
    private async void fetch_key_by_email(Conversation conversation, string email, Adw.ActionRow row, Gtk.Image icon, RowUpdateToken update_token) {
        if (!widgets_can_update(row, icon)) return;
        uint fetch_generation = begin_row_update(update_token);
        if (!row_update_is_current(update_token, fetch_generation)) return;
        row.subtitle = _("Searching keyserver for: ") + email + "...";
        
        KeyserverFetchResult result = yield fetch_key_from_keyserver(email, update_token, fetch_generation);
        if (!row_update_is_current(update_token, fetch_generation)) return;
        if (!widgets_can_update(row, icon)) return;
        
        if (store_legacy_contact_key(conversation, result, email, update_token, fetch_generation)) {
            update_key_row_details.begin(row, icon, result.fingerprint, get_legacy_status_description(result.fingerprint, db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid)), true, null,
                    db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid), update_token);
        } else {
            row.subtitle = _("Not found: ") + email + ". " + result.error_msg;
        }
    }

    private async KeyserverFetchResult fetch_key_from_keyserver(string query, RowUpdateToken? update_token = null, uint generation = 0) {
        var result = new KeyserverFetchResult();
        string query_copy = query;
        SourceFunc callback = fetch_key_from_keyserver.callback;

        new Thread<void*>("openpgp-keyserver-fetch", () => {
            try {
                if (looks_like_key_id(query_copy)) {
                    if (!keyserver_fetch_is_cancelled(update_token, generation)) {
                        result.found = GPGHelper.download_key_from_keyserver(query_copy);
                    }
                    if (result.found && !keyserver_fetch_is_cancelled(update_token, generation)) {
                        GPGHelper.invalidate_secret_keys_cache();
                        result.key = GPGHelper.get_public_key(query_copy);
                    }
                } else {
                    Gee.List<string> candidates = GPGHelper.search_keyserver(query_copy);
                    foreach (string candidate in candidates) {
                        if (keyserver_fetch_is_cancelled(update_token, generation)) {
                            break;
                        }
                        if (GPGHelper.download_key_from_keyserver(candidate)) {
                            if (!keyserver_fetch_is_cancelled(update_token, generation)) {
                                GPGHelper.invalidate_secret_keys_cache();
                                result.key = GPGHelper.get_public_key(candidate);
                                result.found = true;
                            }
                            break;
                        }
                    }
                }
                if (result.key != null) {
                    result.fingerprint = ((!) result.key).fpr;
                }
            } catch (Error e) {
                result.error_msg = e.message;
            }
            Idle.add((owned) callback);
            return null;
        });
        yield;
        return result;
    }

    private bool keyserver_fetch_is_cancelled(RowUpdateToken? update_token, uint generation) {
        return update_token != null && !row_update_is_current((!) update_token, generation);
    }

    private static bool looks_like_key_id(string query) {
        string normalized = query.up().replace("0X", "").replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "");
        if (normalized.length < 8) return false;

        for (int i = 0; i < normalized.length; i++) {
            char c = normalized[i];
            if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) {
                return false;
            }
        }
        return true;
    }

    private bool store_legacy_contact_key(Conversation conversation, KeyserverFetchResult result, string query,
            RowUpdateToken update_token, uint generation) {
        if (!row_update_is_current(update_token, generation)) return false;
        if (!result.found || result.fingerprint == null || ((!) result.fingerprint).length == 0) return false;
        if (result.key != null && (((!) result.key).revoked || ((!) result.key).expired || !((!) result.key).can_encrypt)) {
            debug("ContactDetailsProvider: Refusing unusable legacy OpenPGP key %s from keyserver", (!) result.fingerprint);
            return false;
        }

        try {
            if (!GPGHelper.key_has_email_uid((!) result.fingerprint)) {
                debug("ContactDetailsProvider: Refusing legacy keyserver key %s without email user ID", (!) result.fingerprint);
                return false;
            }
        } catch (Error e) {
            debug("ContactDetailsProvider: Failed to validate legacy keyserver key %s: %s", (!) result.fingerprint, e.message);
            return false;
        }

        if (!row_update_is_current(update_token, generation)) return false;
        db.set_contact_key(conversation.account, conversation.counterpart.bare_jid, (!) result.fingerprint, Database.KEY_SOURCE_KEYSERVER, false);

        var manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
        if (manager != null && result.key != null) {
            manager.cache_key(query, (!) result.key);
            manager.cache_key((!) result.fingerprint, (!) result.key);
        }
        if (manager != null) {
            manager.notify_key_state_changed(conversation.account, conversation.counterpart.bare_jid);
        }
        return true;
    }
}

}
