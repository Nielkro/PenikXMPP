using Dino.Entities;
using Gee;
using Xmpp;
using Omemo;
using Qlite;

namespace Dino.Plugins.Omemo {

internal errordomain DeviceKeyActionError {
    STALE_KEY,
    UNAVAILABLE
}

/** Immutable authorization for the exact key shown by a device action. */
public class DeviceKeyTarget : Object {
    public int account_id { get; private set; }
    public string account_jid { get; private set; }
    public int identity_id { get; private set; }
    public string address_name { get; private set; }
    public int device_id { get; private set; }
    public string key_base64 { get; private set; }

    public DeviceKeyTarget(Account account, Row device, Database db,
            string? displayed_key = null) {
        account_id = account.id;
        account_jid = account.bare_jid.to_string();
        identity_id = device[db.identity_meta.identity_id];
        address_name = device[db.identity_meta.address_name];
        device_id = device[db.identity_meta.device_id];
        key_base64 = displayed_key ?? device[db.identity_meta.identity_key_public_base64] ?? "";
    }
}

/** Immutable scope for an explicit reset of a contact's sessions. */
public class AccountKeyScope : Object {
    public int account_id { get; private set; }
    public string account_jid { get; private set; }
    public int identity_id { get; private set; }
    public int device_id { get; private set; }
    public string key_base64 { get; private set; }

    public AccountKeyScope(Account account, Database db) throws Error {
        Row? row = db.identity.select().with(db.identity.account_id, "=", account.id)
            .single().iterator().get_next_checked();
        if (row == null || account.id <= 0) throw new DeviceKeyActionError.STALE_KEY("Account identity is unavailable");
        account_id = account.id;
        account_jid = account.bare_jid.to_string();
        identity_id = ((!) row)[db.identity.id];
        device_id = ((!) row)[db.identity.device_id];
        key_base64 = ((!) row)[db.identity.identity_key_public_base64];
    }
}

private class MessageDeviceTagEpoch : Object { }

private class MessageDeviceTag : Object {
    internal int account_id;
    internal int device_id;
    internal MessageDeviceTagEpoch epoch;
    internal string? key_base64;
    internal string? peer_address;
    internal MessageDeviceTag(int account_id, int device_id, MessageDeviceTagEpoch epoch, string? key_base64, string? peer_address) {
        this.account_id = account_id;
        this.device_id = device_id;
        this.epoch = epoch;
        this.key_base64 = key_base64;
        this.peer_address = peer_address;
    }
}

public class TrustManager {

    private const bool OMEMO2_RUNTIME_ENABLED = false;
    private static bool omemo2_runtime_test_override = false;

    public signal void bad_message_state_updated(Account account, Jid jid, int device_id);
    /** Manual device actions have committed; separate from per-message warnings. */
    public signal void device_trust_state_changed(Account account, Jid jid);
    /** Emitted after an own device is removed from the local DB, so the
     *  device list on PubSub can be republished without that device. */
    public signal void own_device_removed(Account account, int device_id);
    public signal void session_reset(Account account, Jid jid, int device_id);
    public signal void contact_sessions_reset(Account account, Jid jid);

    public bool omemo2_enabled {
        get { return OMEMO2_RUNTIME_ENABLED || omemo2_runtime_test_override; }
        set {
            if (value && !OMEMO2_RUNTIME_ENABLED && !omemo2_runtime_test_override) {
                debug("OMEMO 2 runtime is disabled; ignoring enable request");
            }
        }
    }

    private StreamInteractor stream_interactor;
    private Database db;
    private TagMessageListener tag_message_listener;

    // A received stanza may have identical content/IDs on multiple accounts.
    // Keep its device tag on the actual pipeline object, including body edits.
    private const string MESSAGE_DEVICE_TAG = "dinox-omemo-received-device";
    // Object data belongs to Message, never to a global Message-keyed map.
    // Epochs retain no Account or Message and are dropped on account removal.
    private HashMap<int, MessageDeviceTagEpoch> message_tag_epochs =
        new HashMap<int, MessageDeviceTagEpoch>();
    private Dino.Database? application_database;
    private uint64 device_action_sequence = 0;

    public TrustManager(StreamInteractor stream_interactor, Database db, Dino.Database? application_database = null) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.application_database = application_database;
        this.omemo2_enabled = omemo2_enabled_by_default();

        tag_message_listener = new TagMessageListener(stream_interactor, this, db);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(tag_message_listener);
    }

    public static bool omemo2_enabled_by_default() {
        return OMEMO2_RUNTIME_ENABLED;
    }

    internal static void set_omemo2_runtime_test_override(bool enabled) {
        omemo2_runtime_test_override = enabled;
    }

    public void remember_message_device(Message message, int device_id, string? authenticated_key_base64 = null, Jid? authenticated_peer = null) {
        if (message.account == null || message.account.id <= 0 || device_id <= 0) return;
        int account_id = message.account.id;
        MessageDeviceTagEpoch? epoch = message_tag_epochs[account_id];
        if (epoch == null) {
            epoch = new MessageDeviceTagEpoch();
            message_tag_epochs[account_id] = (!) epoch;
        }
        message.set_data<MessageDeviceTag>(MESSAGE_DEVICE_TAG,
            new MessageDeviceTag(account_id, device_id, (!) epoch, authenticated_key_base64, authenticated_peer != null ? ((!) authenticated_peer).bare_jid.to_string() : null));
    }

    public int get_message_device(Message message) {
        unowned MessageDeviceTag? tag = message.get_data<MessageDeviceTag>(MESSAGE_DEVICE_TAG);
        if (tag == null || message.account == null ||
                message.account.id != ((!) tag).account_id ||
                message_tag_epochs[((!) tag).account_id] != ((!) tag).epoch) return 0;
        return ((!) tag).device_id;
    }

    public bool clear_message_device(Message message) {
        bool present = message.get_data<MessageDeviceTag>(MESSAGE_DEVICE_TAG) != null;
        message.set_data<MessageDeviceTag?>(MESSAGE_DEVICE_TAG, null);
        return present;
    }

    private MessageDeviceTag? take_message_tag(Message message) {
        MessageDeviceTag? tag = message.get_data<MessageDeviceTag>(MESSAGE_DEVICE_TAG);
        bool valid = tag != null && get_message_device(message) > 0;
        clear_message_device(message);
        return valid ? tag : null;
    }

    public int take_message_device(Message message) {
        int device_id = get_message_device(message);
        clear_message_device(message);
        return device_id;
    }

    internal void forget_account(Account account) {
        // A replacement account with the same ID receives a distinct epoch.
        message_tag_epochs.unset(account.id);
    }

    public void set_blind_trust(Account account, Jid jid, bool blind_trust) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;
        db.trust.update()
            .with(db.trust.identity_id, "=", identity_id)
            .with(db.trust.address_name, "=", jid.bare_jid.to_string())
            .set(db.trust.blind_trust, blind_trust).perform();
    }

    /**
     * Reset the Signal session for a single device without removing the
     * device or its trust level. Refreshes device metadata; the next outgoing
     * message fetches a fresh bundle and starts its PreKey session.
     */
    public void reset_session(Account account, Jid jid, int device_id) {
        apply_current_device_action(account, jid, device_id, -2);
    }

    /**
     * Reset all local Signal sessions for a contact.
     *
     * This intentionally does not fetch bundles immediately. Fresh sessions are
     * established lazily when the next message is encrypted for this contact.
     */
    public void reset_all_sessions(Account account, Jid jid) {
        try { reset_all_sessions_checked(account, jid, new AccountKeyScope(account, db)); }
        catch (Error e) { warning("Could not reset OMEMO sessions for account %d: %s", account.id, e.message); }
    }

    public void reset_all_sessions_checked(Account account, Jid jid, AccountKeyScope scope) throws Error {
        if (scope.account_id != account.id || scope.account_jid != account.bare_jid.to_string() ||
                scope.identity_id <= 0 || scope.device_id <= 0 || scope.key_base64.length == 0) {
            throw new DeviceKeyActionError.STALE_KEY("The displayed account identity is no longer current");
        }
        StreamModule? module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        Store? store = module != null ? ((!) module).store : null;
        BackedSessionStore? backed = store != null ? ((!) store).session_store as BackedSessionStore : null;
        if (store != null) {
            ((!) store).require_persistence_ready();
            if (backed == null || !((!) backed).belongs_to(db, scope.identity_id) ||
                    Base64.encode(((!) store).identity_key_store.identity_key_public.get_data()) != scope.key_base64) {
                throw new DeviceKeyActionError.UNAVAILABLE("Account session store does not match the displayed identity");
            }
        }
        string savepoint_name = "omemo_contact_reset_" + (++device_action_sequence).to_string();
        string address_name = jid.bare_jid.to_string();
        var previous = new HashMap<int, Bytes>();
        bool savepoint = false;
        bool native_mutated = false;
        try {
            db.exec("SAVEPOINT " + savepoint_name);
            savepoint = true;
            db.exec_prepared("UPDATE identity SET device_id = device_id WHERE id = ? AND account_id = ? " +
                "AND device_id = ? AND identity_key_public_base64 = ?",
                {scope.identity_id.to_string(), scope.account_id.to_string(), scope.device_id.to_string(), scope.key_base64});
            if (db.changes() != 1) throw new DeviceKeyActionError.STALE_KEY("Account identity changed before session reset");
            RowIterator sessions = db.session.select().with(db.session.identity_id, "=", scope.identity_id)
                .with(db.session.address_name, "=", address_name).iterator();
            while (sessions.next_checked()) {
                Row row = sessions.get();
                int device_id = row[db.session.device_id];
                var persisted = new Bytes(Base64.decode(row[db.session.record_base64]));
                previous[device_id] = persisted;
                if (backed != null) {
                    Address address = new Address(address_name, device_id);
                    try {
                        uint8[]? memory = ((!) backed).load_session(address);
                        if (memory == null || new Bytes((!) memory).compare(persisted) != 0) {
                            throw new DeviceKeyActionError.UNAVAILABLE("Native session differs from persistent state");
                        }
                    } finally { address.device_id = 0; }
                }
            }
            if (backed != null) {
                IntList devices = ((!) backed).get_sub_device_sessions(address_name);
                if (devices.size != previous.size) throw new DeviceKeyActionError.UNAVAILABLE("Native session count differs from persistent state");
                for (uint i = 0; i < devices.size; i++) {
                    if (!previous.has_key(devices.get(i))) throw new DeviceKeyActionError.UNAVAILABLE("Native session is not persisted");
                }
                native_mutated = true;
                ((!) backed).delete_all_sessions(address_name);
            } else {
                db.session.delete().with(db.session.identity_id, "=", scope.identity_id)
                    .with(db.session.address_name, "=", address_name).perform_checked();
            }
            db.exec("RELEASE SAVEPOINT " + savepoint_name);
            savepoint = false;
        } catch (Error e) {
            if (savepoint) {
                try {
                    db.exec("ROLLBACK TO SAVEPOINT " + savepoint_name);
                    db.exec("RELEASE SAVEPOINT " + savepoint_name);
                } catch (Error rollback_error) {
                    if (store != null) ((!) store).mark_persistence_unavailable();
                    warning("OMEMO contact reset rollback failed after '%s': %s", e.message, rollback_error.message);
                }
            }
            if (native_mutated && backed != null) {
                try {
                    // Native callbacks are synchronous. Restore memory only;
                    // SQLCipher has already restored the exact previous rows.
                    foreach (Map.Entry<int, Bytes> entry in previous.entries) {
                        Address address = new Address(address_name, entry.key);
                        try { ((!) backed).restore_memory_only(address, entry.value.get_data()); }
                        finally { address.device_id = 0; }
                    }
                } catch (Error restore_error) {
                    if (store != null) ((!) store).mark_persistence_unavailable();
                    warning("OMEMO contact reset memory rollback failed after '%s': %s", e.message, restore_error.message);
                }
            }
            throw e;
        }
        contact_sessions_reset(account, jid.bare_jid);
    }

    /**
     * Remove a device entirely: delete session + identity_meta entry.
     * If this is one of the user's own devices, also emit own_device_removed()
     * so the PubSub device list gets republished without it.
     */
    public void delete_device(Account account, Jid jid, int device_id) {
        apply_current_device_action(account, jid, device_id, -1);
    }

    public void set_device_trust(Account account, Jid jid, int device_id, TrustLevel trust_level) {
        apply_current_device_action(account, jid, device_id, (int) trust_level);
    }

    private void apply_current_device_action(Account account, Jid jid, int device_id, int action) {
        try {
            int identity_id = db.identity.get_id_checked(account.id);
            Row? device = db.identity_meta.get_device_checked(identity_id,
                jid.bare_jid.to_string(), device_id);
            if (device == null) return;
            perform_key_action(account, jid, new DeviceKeyTarget(account, (!) device, db), action);
        } catch (Error e) {
            warning("OMEMO device action failed for account %d: %s", account.id, e.message);
        }
    }

    /** No yield occurs between exact-key CAS, native mutation and commit. */
    public void perform_key_action(Account account, Jid jid, DeviceKeyTarget target, int action) throws Error {
        if (account.id <= 0 || target.account_id != account.id ||
                target.account_jid != account.bare_jid.to_string() ||
                target.device_id <= 0 || target.key_base64.length == 0 ||
                target.address_name != jid.bare_jid.to_string() ||
                db.identity.get_id_checked(account.id) != target.identity_id) {
            throw new DeviceKeyActionError.STALE_KEY("The displayed account or device key is no longer current");
        }
        if (action != -1 && action != -2 &&
                action != TrustLevel.TRUSTED && action != TrustLevel.VERIFIED &&
                action != TrustLevel.UNTRUSTED) {
            throw new IOError.INVALID_ARGUMENT("Unsupported OMEMO device action");
        }
        StreamModule? module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        Store? store = module != null ? ((!) module).store : null;
        if ((action == -1 || action == -2) && store != null) {
            ((!) store).require_persistence_ready();
            BackedSessionStore? backed = ((!) store).session_store as BackedSessionStore;
            if (backed == null || !((!) backed).belongs_to(db, target.identity_id)) {
                throw new DeviceKeyActionError.UNAVAILABLE("Persistent session store is unavailable for device action");
            }
        }
        string savepoint_name = "omemo_device_action_" + (++device_action_sequence).to_string();
        Address address = new Address(target.address_name, target.device_id);
        uint8[]? previous_session = null;
        bool savepoint = false;
        bool session_mutated = false;
        try {
            if (store != null && (action == -1 || action == -2)) {
                previous_session = ((!) store).session_store.load_session(address);
            }
            db.exec("SAVEPOINT " + savepoint_name);
            savepoint = true;
            // This first write locks the database and guards all subsequent
            // mutations, including reset/remove. Trust is not changed here.
            db.exec_prepared("UPDATE identity_meta SET trust_level = trust_level " +
                "WHERE identity_id = ? AND address_name = ? AND device_id = ? " +
                "AND identity_key_public_base64 = ? " +
                "AND EXISTS (SELECT 1 FROM identity WHERE id = ? AND account_id = ?)",
                {target.identity_id.to_string(), target.address_name,
                 target.device_id.to_string(), target.key_base64,
                 target.identity_id.to_string(), target.account_id.to_string()});
            if (db.changes() != 1) {
                throw new DeviceKeyActionError.STALE_KEY("The displayed device key changed; review the current fingerprint");
            }
            if (action == -1 || action == -2) {
                if (store != null && previous_session != null) {
                    session_mutated = true;
                    ((!) store).delete_session(address);
                } else {
                    // A reset also succeeds when there is no native session.
                    // Calling SimpleSessionStore.delete_session in that case
                    // would manufacture an error for confirmed absence.
                    db.session.delete().with(db.session.identity_id, "=", target.identity_id)
                        .with(db.session.address_name, "=", target.address_name)
                        .with(db.session.device_id, "=", target.device_id).perform_checked();
                }
                if (action == -1) {
                    db.identity_meta.delete().with(db.identity_meta.identity_id, "=", target.identity_id)
                        .with(db.identity_meta.address_name, "=", target.address_name)
                        .with(db.identity_meta.device_id, "=", target.device_id)
                        .with(db.identity_meta.identity_key_public_base64, "=", target.key_base64).perform_checked();
                    if (db.changes() != 1) throw new DeviceKeyActionError.STALE_KEY("Device key changed during removal");
                }
            } else {
                db.identity_meta.update().with(db.identity_meta.identity_id, "=", target.identity_id)
                    .with(db.identity_meta.address_name, "=", target.address_name)
                    .with(db.identity_meta.device_id, "=", target.device_id)
                    .with(db.identity_meta.identity_key_public_base64, "=", target.key_base64)
                    .set(db.identity_meta.trust_level, action)
                    .set(db.identity_meta.identity_key_changed, false).perform_checked();
                if (db.changes() != 1) throw new DeviceKeyActionError.STALE_KEY("Device key changed during trust update");
                if (action == TrustLevel.TRUSTED || action == TrustLevel.VERIFIED) {
                    db.identity_meta.update().with(db.identity_meta.identity_id, "=", target.identity_id)
                        .with(db.identity_meta.address_name, "=", target.address_name)
                        .with(db.identity_meta.device_id, "=", target.device_id)
                        .set_null(db.identity_meta.last_message_untrusted).perform_checked();
                }
            }
            db.exec("RELEASE SAVEPOINT " + savepoint_name);
            savepoint = false;
        } catch (Error e) {
            if (savepoint) {
                try {
                    db.exec("ROLLBACK TO SAVEPOINT " + savepoint_name);
                    db.exec("RELEASE SAVEPOINT " + savepoint_name);
                } catch (Error rollback_error) {
                    if (store != null) ((!) store).mark_persistence_unavailable();
                    warning("OMEMO device action rollback failed: %s", rollback_error.message);
                }
            }
            if (session_mutated && store != null) {
                try {
                    var backed = ((!) store).session_store as BackedSessionStore;
                    if (backed == null) throw new IOError.FAILED("Persistent session store changed during device action");
                    ((!) backed).restore_memory_only(address, previous_session);
                } catch (Error restore_error) {
                    ((!) store).mark_persistence_unavailable();
                    warning("OMEMO device action memory rollback failed after '%s': %s", e.message, restore_error.message);
                }
            }
            address.device_id = 0;
            throw e;
        }
        address.device_id = 0;
        if (action == -1 && jid.equals_bare(account.bare_jid)) own_device_removed(account, target.device_id);
        if (action == -2) session_reset(account, jid.bare_jid, target.device_id);
        if (action == -2 && module != null) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                ((!) module).reset_bundle_request(jid, target.device_id);
                ((!) module).fetch_bundle_info((!) stream, jid.bare_jid, target.device_id, false);
            }
        }
        if (action >= 0) update_message_visibility(account, jid, target.identity_id, target.device_id, target.key_base64, (TrustLevel) action);
        device_trust_state_changed(account, jid.bare_jid);
        bad_message_state_updated(account, jid, target.device_id);
    }

    private void update_message_visibility(Account account, Jid jid, int identity_id, int device_id, string key_base64, TrustLevel trust_level) {
        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        Dino.Database? app_db = application_database ?? (app != null ? ((!) app).db : null);
        if (app_db == null) return;
        try {
            foreach (Row row in db.content_item_meta.with_device(identity_id, jid.bare_jid.to_string(), device_id)
                    .with(db.content_item_meta.key_public, "=", key_base64)) {
                int content_id = row[db.content_item_meta.content_item_id];
                Row? item_row = ((!) app_db).content_item.select()
                    .with(((!) app_db).content_item.id, "=", content_id)
                    .single().iterator().get_next_checked();
                if (item_row == null) continue;
                int conversation_id = ((!) item_row)[((!) app_db).content_item.conversation_id];
                Row? conversation_row = ((!) app_db).conversation.select()
                    .with(((!) app_db).conversation.id, "=", conversation_id)
                    .with(((!) app_db).conversation.account_id, "=", account.id)
                    .single().iterator().get_next_checked();
                if (conversation_row == null) continue;
                bool hidden = trust_level == TrustLevel.UNTRUSTED || trust_level == TrustLevel.UNKNOWN;
                long cleared_at = ((!) conversation_row)[((!) app_db).conversation.history_cleared_at];
                if (!hidden && cleared_at > 0 && ((!) item_row)[((!) app_db).content_item.time] < cleared_at) continue;
                ContentItemStore? items = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
                if (items != null) {
                    ((!) items).apply_trust_visibility(account, content_id, hidden);
                } else {
                    // Headless instances have no active chat collection.
                    ((!) app_db).content_item.update().with(((!) app_db).content_item.id, "=", content_id)
                        .with(((!) app_db).content_item.conversation_id, "=", conversation_id)
                        .set(((!) app_db).content_item.hide, hidden).perform_checked();
                }
            }
        } catch (Error e) {
            warning("OMEMO: Could not update message visibility after device trust changed: %s", e.message);
        }
    }

    public bool has_unassigned_hidden_messages(Account account, Jid jid, int device_id) throws Error {
        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        Dino.Database? app_db = application_database ?? (app != null ? ((!) app).db : null);
        if (app_db == null) return false;
        int identity_id = db.identity.get_id_checked(account.id);
        if (identity_id <= 0) return false;
        var ids = new ArrayList<string>();
        RowIterator rows = db.content_item_meta.with_device(identity_id, jid.bare_jid.to_string(), device_id)
            .with_null(db.content_item_meta.key_public).iterator();
        while (rows.next_checked()) {
            ids.add(rows.get()[db.content_item_meta.content_item_id].to_string());
            if (ids.size == 128) {
                if (has_hidden_content_ids((!) app_db, account.id, ids)) return true;
                ids.clear();
            }
        }
        return ids.size > 0 && has_hidden_content_ids((!) app_db, account.id, ids);
    }

    private static bool has_hidden_content_ids(Dino.Database app_db, int account_id, Gee.List<string> ids) throws Error {
        // IDs are integers read from our own database. Batch them to avoid one
        // application-database query per archived message and parameter limits.
        string[] content_ids = new string[ids.size];
        for (int i = 0; i < ids.size; i++) content_ids[i] = ids[i];
        Row? row = app_db.query_sql("SELECT ci.id FROM content_item ci JOIN conversation c " +
            "ON c.id = ci.conversation_id WHERE c.account_id = ? AND ci.hide = 1 " +
            "AND ci.id IN (" + string.joinv(",", content_ids) + ") LIMIT 1",
            {account_id.to_string()}).get_next_checked();
        return row != null;
    }

    internal async void tag_message_for_tests(Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
        yield tag_message_listener.run(message, stanza, conversation);
    }

    public bool is_known_address(Account account, Jid jid) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return false;
        QueryBuilder query = db.identity_meta.with_address(identity_id, jid.bare_jid.to_string())
                .with(db.identity_meta.now_active, "=", true);
        if (!omemo2_enabled) {
            query.with(db.identity_meta.supports_omemo1, "=", true);
        }
        return query.count() > 0;
    }

    public Gee.List<int32> get_trusted_devices(Account account, Jid jid) {
        return get_trusted_devices_filtered(account, jid, 0);
    }

    public Gee.List<int32> get_trusted_devices_omemo1(Account account, Jid jid) {
        return get_trusted_devices_filtered(account, jid, 1);
    }

    internal bool has_legacy_device_identity(Account account, Jid jid, int32 device_id) {
        try {
            int identity_id = db.identity.get_id_checked(account.id);
            if (identity_id <= 0) return false;
            Row? device = db.identity_meta.get_device_checked(identity_id, jid.bare_jid.to_string(), device_id);
            return device != null && ((!) device)[db.identity_meta.now_active] &&
                    ((!) device)[db.identity_meta.supports_omemo1] &&
                    ((!) device)[db.identity_meta.identity_key_public_base64] != null;
        } catch (Error e) {
            return false;
        }
    }

    public Gee.List<int32> get_trusted_devices_omemo2(Account account, Jid jid) {
        if (!omemo2_enabled) return new ArrayList<int32>();
        return get_trusted_devices_filtered(account, jid, 2);
    }

    public bool has_omemo1_devices(Account account, Jid jid) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return false;
        return db.identity_meta.has_omemo1_devices(identity_id, jid.bare_jid.to_string());
    }

    public bool has_omemo2_devices(Account account, Jid jid) {
        if (!omemo2_enabled) return false;
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return false;
        return db.identity_meta.has_omemo2_devices(identity_id, jid.bare_jid.to_string());
    }

    public bool should_use_omemo2(Account account, Gee.List<Jid> recipients) {
        if (!omemo2_enabled) return false;
        if (recipients.size == 0) return false;
        foreach (Jid recipient in recipients) {
            if (!has_omemo2_devices(account, recipient) || has_omemo1_devices(account, recipient)) {
                return false;
            }
        }
        return true;
    }

    private Gee.List<int32> get_trusted_devices_filtered(Account account, Jid jid, int protocol) {
        Gee.List<int32> devices = new ArrayList<int32>();
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return devices;

        foreach (Row device in db.identity_meta.get_trusted_devices(identity_id, jid.bare_jid.to_string())) {
            bool supports_omemo1 = device[db.identity_meta.supports_omemo1];
            bool supports_omemo2 = device[db.identity_meta.supports_omemo2];

            if (protocol == 1 && !supports_omemo1 && supports_omemo2) continue;
            if (protocol == 2 && !supports_omemo2) continue;

            if(device[db.identity_meta.trust_level] != TrustLevel.UNKNOWN || device[db.identity_meta.identity_key_public_base64] == null)
                devices.add(device[db.identity_meta.device_id]);
        }
        return devices;
    }

    private class TagMessageListener : MessageListener {
        public string[] after_actions_const = new string[]{ "STORE" };
        public override string action_group { get { return "DECRYPT_TAG"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StreamInteractor stream_interactor;
        private TrustManager trust_manager;
        private Database db;

        public TagMessageListener(StreamInteractor stream_interactor, TrustManager trust_manager, Database db) {
            this.stream_interactor = stream_interactor;
            this.trust_manager = trust_manager;
            this.db = db;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            MessageDeviceTag? tag = trust_manager.take_message_tag(message);
            int device_id = tag != null ? ((!) tag).device_id : 0;

            // TODO: Handling of files

            ContentItem? content_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_item_by_foreign(conversation, 1, message.id);

            if (content_item != null && device_id != 0) {
                Jid? jid = content_item.jid;
                bool may_persist_peer = true;
                if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                    // Native authentication may identify a historic peer even
                    // when current room privacy forbids retaining that link.
                    // Use the ephemeral authenticated peer for trust checks,
                    // without recreating the forbidden link in plugin metadata.
                    jid = null;
                    if (tag != null && ((!) tag).peer_address != null) {
                        try { jid = new Jid(((!) tag).peer_address); }
                        catch (InvalidJidError e) { }
                    }
                    MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
                    may_persist_peer = muc_manager != null && message.real_jid != null && jid != null &&
                        ((!) message.real_jid).bare_jid.equals(((!) jid).bare_jid) &&
                        ((!) muc_manager).may_retain_authenticated_message_real_jid(
                            conversation.account, conversation.counterpart.bare_jid);
                }

                int identity_id = db.identity.get_id(conversation.account.id);
                if (identity_id <= 0 || jid == null || tag == null || ((!) tag).key_base64 == null ||
                        ((!) tag).key_base64.length == 0 ||
                        ((!) tag).peer_address != ((!) jid).bare_jid.to_string()) {
                    stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).set_item_hide(content_item, true);
                    return false;
                }
                Row? device = identity_id > 0
                    ? db.identity_meta.get_device(identity_id, ((!) jid).bare_jid.to_string(), device_id) : null;
                bool key_matches_device = device != null &&
                    ((!) device)[db.identity_meta.identity_key_public_base64] == ((!) tag).key_base64;
                TrustLevel trust_level = key_matches_device
                    ? (TrustLevel) ((!) device)[db.identity_meta.trust_level] : TrustLevel.UNKNOWN;
                if (trust_level == TrustLevel.UNTRUSTED || trust_level == TrustLevel.UNKNOWN) {
                    stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).set_item_hide(content_item, true);
                    
                    // Don't mark messages as untrusted if they are older than conversation history clear
                    bool should_mark_untrusted = true;
                    if (conversation.history_cleared_at != null && message.time != null) {
                        if (message.time.compare(conversation.history_cleared_at) < 0) {
                            should_mark_untrusted = false;
                        }
                    }
                    
                    if (should_mark_untrusted && key_matches_device) {
                        db.identity_meta.update_last_message_untrusted(identity_id, jid.bare_jid.to_string(), device_id, message.time);
                        trust_manager.bad_message_state_updated(conversation.account, jid, device_id);
                    }
                }

                if (!may_persist_peer) return false;
                db.content_item_meta.insert()
                    .value(db.content_item_meta.content_item_id, content_item.id)
                    .value(db.content_item_meta.identity_id, identity_id)
                    .value(db.content_item_meta.address_name, jid.bare_jid.to_string())
                    .value(db.content_item_meta.device_id, device_id)
                    .value(db.content_item_meta.key_public, ((!) tag).key_base64)
                    .value(db.content_item_meta.trusted_when_received, trust_level == TrustLevel.TRUSTED || trust_level == TrustLevel.VERIFIED)
                    .perform();
            }
            return false;
        }
    }
}

}
