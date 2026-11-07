using Gee;
using Dino.Entities;
using Omemo;

extern const string GETTEXT_PACKAGE;
extern const string LOCALE_INSTALL_DIR;

namespace Dino.Plugins.Omemo {

private class OmemoStoreReadinessGate : Dino.AccountReadinessGate {
    private HashMap<Account, Store> stores = new HashMap<Account, Store>(
        Account.hash_func, Account.equals_func);
    private HashMap<Account, ulong> store_handlers = new HashMap<Account, ulong>(
        Account.hash_func, Account.equals_func);

    public OmemoStoreReadinessGate() {
    }

    public override bool is_ready(Account account) {
        Store? store = stores[account];
        return store != null && ((!) store).is_persistence_ready;
    }

    public void watch_store(Account account, Store store) {
        Store? previous = stores[account];
        if (previous == store) return;
        if (previous != null) {
            SignalHandler.disconnect((!) previous, store_handlers[account]);
            // Re-enabling an account creates new protocol modules. Retained
            // Jingle callbacks/native ciphers must not keep a second writable
            // cache for the same persisted ratchet. This invalidates handles,
            // without deleting or resetting the saved identity or sessions.
            ((!) previous).mark_persistence_unavailable();
        }
        stores[account] = store;
        store_handlers[account] = store.persistence_readiness_changed.connect((ready) => {
            readiness_changed(account);
        });
    }

    public void forget_account(Account account) {
        Store? store = stores[account];
        if (store != null) {
            SignalHandler.disconnect((!) store, store_handlers[account]);
        }
        store_handlers.unset(account);
        stores.unset(account);
    }
}

public class Plugin : RootInterface, Object {
    public const bool DEBUG = false;
    private static Context? _context;
    public static Context get_context () {
        if (_context == null) ensure_context ();
        if (_context == null) error ("OMEMO Context not initialized");
        return (!)_context;
    }
    public static bool ensure_context () {
        try {
            lock (_context) {
                if (_context == null) {
                    _context = new Context (DEBUG);
                }
            }
            return true;
        } catch (Error e) {
            warning ("Error initializing libomemo-c Context %s", e.message);
            return false;
        }
    }

    public Dino.Application app;
    public Database db;
    public EncryptionListEntry list_entry;
    public ContactDetailsProvider contact_details_provider;
    public DeviceNotificationPopulator device_notification_populator;
    public HashMap<Account, OwnNotifications> own_notifications = new HashMap<Account, OwnNotifications> (Account.hash_func, Account.equals_func);
    public TrustManager trust_manager;
    public HashMap<Account, OmemoDecryptor> decryptors = new HashMap<Account, OmemoDecryptor> (Account.hash_func, Account.equals_func);
    public HashMap<Account, OmemoEncryptor> encryptors = new HashMap<Account, OmemoEncryptor> (Account.hash_func, Account.equals_func);
    public HashMap<Account, Omemo2Decrypt> decryptors_v2 = new HashMap<Account, Omemo2Decrypt> (Account.hash_func, Account.equals_func);
    public HashMap<Account, Omemo2Encrypt> encryptors_v2 = new HashMap<Account, Omemo2Encrypt> (Account.hash_func, Account.equals_func);
    private OmemoStoreReadinessGate store_readiness_gate;

    public void registered (Dino.Application app) {
        this.app = app;
        this.store_readiness_gate = new OmemoStoreReadinessGate();
        this.app.stream_interactor.get_module<MessageProcessor>(
            MessageProcessor.IDENTITY).history_sync.add_readiness_gate(
                store_readiness_gate);
        this.app.stream_interactor.connection_manager.add_readiness_gate(
            store_readiness_gate);
        if (!ensure_context ()) {
            warning ("OMEMO plugin disabled: libomemo-c context is unavailable");
            return;
        }
        try {
            this.db = new Database (Path.build_filename (Application.get_storage_dir (), "omemo.db"));
        } catch (Error e) {
            warning ("OMEMO plugin disabled: %s", e.message);
            return;
        }
        this.list_entry = new EncryptionListEntry (this);
        this.contact_details_provider = new ContactDetailsProvider (this);
        this.trust_manager = new TrustManager (this.app.stream_interactor, this.db);
        this.trust_manager.device_trust_state_changed.connect (on_device_trust_state_changed);
        this.device_notification_populator = new DeviceNotificationPopulator (this, this.app.stream_interactor);

        // In Penik, OMEMO UI elements are hidden from the user interface
        // this.app.plugin_registry.register_encryption_list_entry (list_entry);
        // this.app.plugin_registry.register_encryption_preferences_entry (new OmemoPreferencesEntry (this));
        // this.app.plugin_registry.register_contact_details_entry (contact_details_provider);
        // this.app.plugin_registry.register_notification_populator (device_notification_populator);
        // this.app.plugin_registry.register_conversation_addition_populator (new BadMessagesPopulator (this.app.stream_interactor, this));
        // this.app.plugin_registry.register_call_entryption_entry (DtlsSrtpVerificationDraft.NS_URI, new CallEncryptionEntry (db));

        this.app.stream_interactor.module_manager.initialize_account_modules.connect ((account, list) => {
            // Account stores must remain fail-closed until Manager has loaded
            // the persisted identity and every database-backed Signal store.
            Store store = Plugin.get_context ().create_store (false);
            store_readiness_gate.watch_store(account, store);
            list.add (new StreamModule (store));
            decryptors[account] = new OmemoDecryptor (account, app.stream_interactor, trust_manager, db, store);
            decryptors[account].device_trust_state_changed.connect (on_device_trust_state_changed);
            list.add (decryptors[account]);
            encryptors[account] = new OmemoEncryptor (account, trust_manager, store);
            list.add (encryptors[account]);
            if (trust_manager.omemo2_enabled) {
                var stream_module2 = new StreamModule2 (store);
                stream_module2.auto_publish_own_device_list = false;
                list.add (stream_module2);
                decryptors_v2[account] = new Omemo2Decrypt (account, app.stream_interactor, trust_manager, db, store);
                decryptors_v2[account].device_trust_state_changed.connect (on_device_trust_state_changed);
                list.add (decryptors_v2[account]);
                encryptors_v2[account] = new Omemo2Encrypt (account, trust_manager, store);
                list.add (encryptors_v2[account]);
            }
            list.add (new JetOmemo.Module ());
            list.add (new DtlsSrtpVerificationDraft.StreamModule (account, db));
            this.own_notifications[account] = new OwnNotifications (this, this.app.stream_interactor, account);
        });

        app.stream_interactor.get_module<MessageProcessor> (MessageProcessor.IDENTITY).received_pipeline.connect (new DecryptMessageListener (decryptors));
        if (trust_manager.omemo2_enabled) {
            app.stream_interactor.get_module<MessageProcessor> (MessageProcessor.IDENTITY).received_pipeline.connect (new Omemo2DecryptMessageListener (decryptors_v2));
        }
        app.stream_interactor.get_module<FileManager> (FileManager.IDENTITY).add_file_decryptor (new OmemoFileDecryptor ());
        app.stream_interactor.get_module<FileManager> (FileManager.IDENTITY).add_file_encryptor (new OmemoFileEncryptor ());
        JingleFileHelperRegistry.instance.add_encryption_helper (Encryption.OMEMO, new JetOmemo.EncryptionHelper (app.stream_interactor, trust_manager));

        Manager manager = Manager.start (this.app.stream_interactor, db,
            trust_manager, encryptors, encryptors_v2);
        manager.device_trust_state_changed.connect (on_device_trust_state_changed);
        manager.private_muc_readiness_changed.connect ((account, room) => {
            this.app.plugin_registry.encryption_readiness_changed (
                Encryption.OMEMO, account, room.bare_jid);
        });
        // Manager performs the transactional database wipe first. Afterwards
        // release every plugin-owned account object so no removed account or
        // discarded Store remains reachable until process shutdown.
        this.app.stream_interactor.account_removed.connect ((account) => {
            store_readiness_gate.forget_account(account);
            trust_manager.forget_account(account);
            own_notifications.unset (account);
            decryptors.unset (account);
            encryptors.unset (account);
            decryptors_v2.unset (account);
            encryptors_v2.unset (account);
        });

        string locales_dir;
        if (app.search_path_generator != null) {
            locales_dir = ((!)app.search_path_generator).get_locale_path (GETTEXT_PACKAGE, LOCALE_INSTALL_DIR);
        } else {
            locales_dir = LOCALE_INSTALL_DIR;
        }
        internationalize (GETTEXT_PACKAGE, locales_dir);
    }

    private void on_device_trust_state_changed(Account account, Xmpp.Jid jid) {
        app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, account, jid.bare_jid);
    }

    public void shutdown () {
        // Nothing to do
    }

    public void rekey_database (string new_key) throws Error {
        // OMEMO uses a separate auto-generated key from GNOME Keyring,
        // NOT the shared app.db_key. Rekey is a no-op here.
    }

    public void checkpoint_database () {
        if (db != null) {
            try {
                db.exec ("PRAGMA wal_checkpoint(TRUNCATE)");
            } catch (Error e) {
                warning ("OMEMO: WAL checkpoint failed: %s", e.message);
            }
        }
    }

    public void backup_database(string directory, Cancellable? cancellable = null) throws Error {
        if (db == null) return;
        string destination = Path.build_filename(directory, "omemo.db");
        if (cancellable == null) {
            db.backup_to(destination);
        } else {
            db.backup_to(destination, ((!) cancellable).is_cancelled);
        }
    }

    public bool has_new_devices (Account account, Xmpp.Jid jid) {
        int identity_id = db.identity.get_id (account.id);
        if (identity_id < 0) return false;

        return db.identity_meta.get_new_devices (identity_id, jid.bare_jid.to_string ()).count () > 0;
    }

    public bool has_changed_keys (Account account, Xmpp.Jid jid) {
        int identity_id = db.identity.get_id (account.id);
        if (identity_id < 0) return false;

        return db.identity_meta.get_changed_key_devices (identity_id, jid.bare_jid.to_string ()).count () > 0;
    }

    public void clear_bad_message_state (Account account, Xmpp.Jid jid) {
        int identity_id = db.identity.get_id (account.id);
        if (identity_id < 0) return;

        // Clear all bad message warnings for this contact
        string address_name = jid.bare_jid.to_string ();
        var devices = db.identity_meta.with_address( identity_id, address_name);
        foreach (Qlite.Row device in devices) {
            int device_id = device[db.identity_meta.device_id];
            db.identity_meta.update_last_message_untrusted (identity_id, address_name, device_id, null);
            db.identity_meta.update_last_message_undecryptable (identity_id, address_name, device_id, null);
        }

        trust_manager.bad_message_state_updated (account, jid, 0);
    }
}

}
