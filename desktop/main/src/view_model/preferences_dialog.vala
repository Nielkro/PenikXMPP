using Dino.Entities;
using Xmpp;
using Xmpp.Xep;
using Gee;

public class Dino.Ui.ViewModel.PreferencesDialog : Object {
    public signal void update();

    public HashMap<Account, AccountDetails> account_details = new HashMap<Account, AccountDetails>(Account.hash_func, Account.equals_func);
    public AccountDetails selected_account { get; set; }
    public Gtk.SingleSelection active_accounts_selection { get; default=new Gtk.SingleSelection(new GLib.ListStore(typeof(ViewModel.AccountDetails))); }

    public StreamInteractor stream_interactor;
    public Database db;

    public GeneralPreferencesPage general_page { get; set; default=new GeneralPreferencesPage(); }

    public void populate(Database db, StreamInteractor stream_interactor) {
        this.db = db;
        this.stream_interactor = stream_interactor;

        stream_interactor.connection_manager.connection_error.connect((account, error) => {
            var account_detail = account_details[account];
            if (account_detail != null) {
                account_detail.connection_error = error;
            }
        });
        stream_interactor.connection_manager.connection_state_changed.connect((account, state) => {
            var account_detail = account_details[account];
            if (account_detail != null) {
                account_detail.connection_state = state;
                account_detail.connection_error = stream_interactor.connection_manager.get_error(account);
            }
        });
        stream_interactor.account_added.connect((account) => {
            update_data(account);
        });
        stream_interactor.account_removed.connect(() => {
            update_data();
        });

        bind_general_page();
        update_data();
    }

    public ArrayList<Account> get_active_accounts() {
        var active_accounts = new ArrayList<Account>();
        if (stream_interactor == null) return active_accounts;

        foreach (var account in stream_interactor.get_accounts()) {
            if (account.enabled) active_accounts.add(account);
        }
        return active_accounts;
    }

    private void update_data(Account? newly_added_account = null) {
        // account_details should hold the correct set of accounts (add or remove some if needed), but do not override remaining ones (would destroy bindings)
        var current_accounts = db.get_accounts();
        var remove_accounts = new ArrayList<Account>();
        foreach (var account in account_details.keys) {
            if (!current_accounts.contains(account)) {
                debug("Account %s removed from account_details", account.bare_jid.to_string());
                remove_accounts.add(account);
            }
        }
        if (selected_account != null && remove_accounts.contains(selected_account.account)) {
            selected_account = null;
        }
        foreach (var account in remove_accounts) {
            account_details.unset(account);
        }
        foreach (var account in current_accounts) {
            if (!account_details.has_key(account)) {
                debug("AccountDetails recreated for %s", account.bare_jid.to_string());
                account_details[account] = new AccountDetails(account, stream_interactor);
            }
            if (selected_account == null && account.enabled) selected_account = account_details[account];
        }

        // Update account picker model with currently active accounts (reuse existing AccountDetails)
        var active_accounts = get_active_accounts();
        // StreamInteractor emits account_added before ConnectionManager adds the
        // account to get_accounts(). Include that account for this synchronous
        // refresh so cached preferences pages see it without an application
        // restart. Later refreshes use the managed account list as usual.
        if (newly_added_account != null && newly_added_account.enabled &&
                account_details.has_key(newly_added_account) &&
                !active_accounts.contains(newly_added_account)) {
            active_accounts.add(newly_added_account);
        }

        var list_model = (GLib.ListStore) active_accounts_selection.model;
        list_model.remove_all();
        foreach (var account in active_accounts) {
            if (account_details.has_key(account)) {
                list_model.append(account_details[account]);
            }
        }

        update();
    }

    public void set_avatar_file(Account account, File file) {
        var avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
        avatar_manager.publish.begin(account, file, (_, res) => {
            if (!avatar_manager.publish.end(res)) {
                warning("The avatar could not be published by the server.");
            }
        });
    }

    public void remove_avatar(Account account) {
        stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY).unset_avatar(account);
    }

    public Plugins.AccountRemovalImpact get_account_removal_impact(Account account) {
        var result = new Plugins.AccountRemovalImpact();
        var app = Dino.Application.get_default();
        foreach (Plugins.AccountRemovalProvider provider in app.plugin_registry.account_removal_providers) {
            result.add(provider.get_account_removal_impact(account));
        }
        return result;
    }

    public async string? remove_account(Account account, bool also_from_server = false, bool delete_managed_bots = false) {
        var app = Dino.Application.get_default();
        if (app != null && !app.begin_account_change()) return "profile-operation-in-progress";
        try {
            var mode = also_from_server ? Plugins.AccountRemovalMode.SERVER : Plugins.AccountRemovalMode.LOCAL_ONLY;
            var operation = new PreferencesAccountRemovalOperation(this, account, mode, delete_managed_bots);
            return yield Plugins.AccountRemovalCoordinator.run(operation, also_from_server);
        } finally {
            if (app != null) app.end_account_change();
        }
    }

    private async string? remove_server_account(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return "account-not-connected";

        var module = ((!) stream).get_module<Xmpp.Xep.InBandRegistration.Module>(Xmpp.Xep.InBandRegistration.Module.IDENTITY);
        if (module == null) return "xep-0077-unavailable";

        string? server_error = yield ((!) module).cancel_registration((!) stream);
        if (server_error != null) {
            warning("Failed to remove account %s from server: %s", account.bare_jid.to_string(), (!) server_error);
        }
        return server_error;
    }

    private async void remove_local_account(Account account) {
        yield stream_interactor.disconnect_account(account);
        account.remove();
        update_data();
    }

    private async void cleanup_account_removal_providers(Account account, Plugins.AccountRemovalMode mode, bool delete_managed_bots) {
        var app = Dino.Application.get_default();
        foreach (Plugins.AccountRemovalProvider provider in app.plugin_registry.account_removal_providers) {
            yield provider.cleanup_removed_account(account, mode, delete_managed_bots);
        }
    }

    private class PreferencesAccountRemovalOperation : Object, Plugins.AccountRemovalOperation {
        private PreferencesDialog owner;
        private Account account;
        private Plugins.AccountRemovalMode mode;
        private bool delete_managed_bots;

        public PreferencesAccountRemovalOperation(PreferencesDialog owner, Account account, Plugins.AccountRemovalMode mode, bool delete_managed_bots) {
            this.owner = owner;
            this.account = account;
            this.mode = mode;
            this.delete_managed_bots = delete_managed_bots;
        }

        public async string? remove_server_account() {
            return yield owner.remove_server_account(account);
        }

        public async void cleanup_related_data() {
            yield owner.cleanup_account_removal_providers(account, mode, delete_managed_bots);
        }

        public async void remove_local_account() {
            yield owner.remove_local_account(account);
        }
    }

    public void reconnect_account(Account account) {
        // Use connection_manager directly to avoid firing account_removed,
        // which would cause the OMEMO plugin to delete all identity keys.
        stream_interactor.connection_manager.disconnect_account.begin(account, () => {
            stream_interactor.connection_manager.connect_account(account);
        });
    }

    public void enable_disable_account(Account account) {
        if (account.enabled) {
            account.enabled = false;
            // Use connection_manager directly — do NOT fire account_removed
            // (that would delete OMEMO identity keys just for disabling an account)
            stream_interactor.connection_manager.disconnect_account.begin(account, (_, res) => {
                stream_interactor.connection_manager.disconnect_account.end(res);
            });

            // Close all conversations for this account (including pinned ones)
            // so they disappear from the sidebar immediately
            var conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            var to_close = new Gee.ArrayList<Conversation>();
            foreach (Conversation conv in conversation_manager.get_active_conversations(account)) {
                to_close.add(conv);
            }
            foreach (Conversation conv in to_close) {
                conversation_manager.close_conversation(conv);
            }
        } else {
            account.enabled = true;
            stream_interactor.connect_account(account);
        }
        update_data();
    }

    public ChangePasswordDialog get_change_password_dialog_model() {
        return new ChangePasswordDialog() {
            account = selected_account.account,
            stream_interactor = stream_interactor
        };
    }

    private void bind_general_page() {
        var settings = Dino.Application.get_default().settings;
        settings.bind_property("send-typing", general_page, "send-typing", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("send-marker", general_page, "send-marker", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("sync-displayed-state", general_page,
            "sync-displayed-state",
            BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("notifications", general_page, "notifications", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("notification-sounds", general_page, "notification-sounds", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("keep-background", general_page, "keep-background", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("convert-utf8-smileys", general_page, "convert-emojis", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("send-on-ctrl-enter", general_page, "send-on-ctrl-enter", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("window-controls", general_page, "window-controls", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("interface-style", general_page, "interface-style", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("color-scheme", general_page, "color-scheme", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("accent-color", general_page, "accent-color", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("chat-font-family", general_page, "chat-font-family", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("chat-font-scale", general_page, "chat-font-scale", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);

        settings.bind_property("stickers-enabled", general_page, "stickers-enabled", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("sticker-animations-enabled", general_page, "sticker-animations-enabled", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("location-sharing-enabled", general_page, "location-sharing-enabled", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("bot-features-enabled", general_page, "bot-features-enabled", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("api-mode", general_page, "api-mode", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("api-port", general_page, "api-port", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("api-tls-cert", general_page, "api-tls-cert", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("api-tls-key", general_page, "api-tls-key", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        settings.bind_property("language", general_page, "language", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
    }
}

public class Dino.Ui.ViewModel.ChangePasswordDialog : Object {
    public Entities.Account account { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    private bool password_change_in_progress = false;

    public async string? change_password(string new_password) {
        if (password_change_in_progress) return _("A password change is already in progress.");
        if (account == null || stream_interactor == null) return _("This account is no longer available.");
        Entities.Account target_account = account;
        StreamInteractor target_interactor = stream_interactor;
        string target_password = new_password;
        var registration = target_interactor.get_module<Register>(Register.IDENTITY);
        if (registration == null) return _("Password changes are not available.");

        password_change_in_progress = true;
        try {
            string? result = yield registration.change_password(target_account, target_password);
            if (result == null) {
                // Persist only the account that sent this request, even if the
                // dialog now refers to another account. This does not recreate
                // a deleted account: Account.remove() detaches its DB updates.
                target_account.password = target_password;
                return null;
            }
            if (result == Register.ERROR_CONNECTION_FAILED) {
                return _("Connect the account before changing its password.");
            }
            if (result == Register.ERROR_NO_RESPONSE) {
                return _("The server did not confirm the password change. The saved password has not been changed.");
            }
            return _("The server rejected the password change (%s).").printf(result);
        } finally {
            password_change_in_progress = false;
        }
    }
}
