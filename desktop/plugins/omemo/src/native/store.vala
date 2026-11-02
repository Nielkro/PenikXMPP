namespace Omemo {

public abstract class IdentityKeyStore : Object {
    public abstract Bytes identity_key_private { get; set; }
    public abstract Bytes identity_key_public { get; set; }
    public abstract uint32 local_registration_id { get; set; }

    public signal void trusted_identity_added (TrustedIdentity id);
    public signal void trusted_identity_updated (TrustedIdentity id);

    public abstract void save_identity (Address address, uint8[] key) throws Error ;

    public abstract bool is_trusted_identity (Address address, uint8[] key) throws Error ;

    public abstract uint8[]? load_identity (Address address) throws Error ;

    public abstract void delete_identity (Address address) throws Error ;

    public class TrustedIdentity {
        public uint8[] key { get; set; }
        public string name { get; private set; }
        public int device_id { get; private set; }

        public TrustedIdentity (string name, int device_id, uint8[] key) {
            this.key = key;
            this.name = name;
            this.device_id = device_id;
        }

        public TrustedIdentity.by_address (Address address, uint8[] key) {
            this (address.name, address.device_id, key);
        }
    }
}

public abstract class SessionStore : Object {

    public signal void session_stored (Session session);
    public signal void session_removed (Session session);
    public abstract uint8[]? load_session (Address address) throws Error ;

    public abstract IntList get_sub_device_sessions (string name) throws Error ;

    public abstract void store_session (Address address, uint8[] record) throws Error ;

    public abstract bool contains_session (Address address) throws Error ;

    public abstract void delete_session (Address address) throws Error ;

    public abstract void delete_all_sessions (string name) throws Error ;

    public class Session {
        public string name;
        public int device_id;
        public uint8[] record;
    }
}

public abstract class PreKeyStore : Object {

    public signal void pre_key_stored (Key key);
    public signal void pre_key_deleted (Key key);

    public abstract uint8[]? load_pre_key (uint32 pre_key_id) throws Error ;

    public abstract void store_pre_key (uint32 pre_key_id, uint8[] record) throws Error ;

    public abstract bool contains_pre_key (uint32 pre_key_id) throws Error ;

    public abstract void delete_pre_key (uint32 pre_key_id) throws Error ;

    public virtual uint32 get_max_key_id () { return 0; }

    public class Key {
        public uint32 key_id { get; private set; }
        public uint8[] record { get; private set; }

        public Key (uint32 key_id, uint8[] record) {
            this.key_id = key_id;
            this.record = record;
        }
    }
}

public abstract class SignedPreKeyStore : Object {

    public signal void signed_pre_key_stored (Key key);
    public signal void signed_pre_key_deleted (Key key);

    public abstract uint8[]? load_signed_pre_key (uint32 pre_key_id) throws Error ;

    public abstract void store_signed_pre_key (uint32 pre_key_id, uint8[] record) throws Error ;

    public abstract bool contains_signed_pre_key (uint32 pre_key_id) throws Error ;

    public abstract void delete_signed_pre_key (uint32 pre_key_id) throws Error ;

    public virtual uint32 get_max_key_id () { return 0; }

    public class Key {
        public uint32 key_id { get; private set; }
        public uint8[] record { get; private set; }

        public Key (uint32 key_id, uint8[] record) {
            this.key_id = key_id;
            this.record = record;
        }
    }
}

public class Store : Object {
    public Context context { get; private set; }
    public IdentityKeyStore identity_key_store { get; set; default = new SimpleIdentityKeyStore (); }
    public SessionStore session_store { get; set; default = new SimpleSessionStore (); }
    public PreKeyStore pre_key_store { get; set; default = new SimplePreKeyStore (); }
    public SignedPreKeyStore signed_pre_key_store { get; set; default = new SimpleSignedPreKeyStore (); }
    public uint32 local_registration_id { get { return persistence_ready ? identity_key_store.local_registration_id : 0; } }
    internal bool is_persistence_ready { get { return persistence_ready; } }
    // Publishing the first bundle needs durable keys; using ratchets must
    // additionally wait until the new device ID has been checked/registered.
    internal bool registration_pending { get; set; default = false; }
    internal NativeStoreContext native_context {get { return native_store_context_; }}
    private NativeStoreContext native_store_context_;
    private bool persistence_ready;
    internal signal void persistence_readiness_changed(bool ready);

    internal void mark_persistence_unavailable() {
        bool changed = persistence_ready;
        persistence_ready = false;
        var backed_session = session_store as
                Dino.Plugins.Omemo.BackedSessionStore;
        if (backed_session != null) {
            ((!) backed_session).mark_unavailable(
                    "parent OMEMO store is unavailable");
        }
        var backed_pre_key = pre_key_store as
                Dino.Plugins.Omemo.BackedPreKeyStore;
        if (backed_pre_key != null) {
            ((!) backed_pre_key).mark_unavailable(
                    "parent OMEMO store is unavailable");
        }
        var backed_signed_pre_key = signed_pre_key_store as
                Dino.Plugins.Omemo.BackedSignedPreKeyStore;
        if (backed_signed_pre_key != null) {
            ((!) backed_signed_pre_key).mark_unavailable(
                    "parent OMEMO store is unavailable");
        }
        if (changed) persistence_readiness_changed(false);
    }

    internal void mark_persistence_ready() {
        if (persistence_ready) return;
        persistence_ready = true;
        persistence_readiness_changed(true);
    }

    /**
     * Drop all account-scoped cryptographic material after explicit account
     * removal. Native callbacks are disabled first; replacing the backing
     * stores then releases own identity bytes, remote identities, sessions
     * and pre-keys even if another short-lived object still references Store.
     */
    internal void discard_sensitive_state() {
        bool changed = persistence_ready;
        persistence_ready = false;
        identity_key_store = new SimpleIdentityKeyStore();
        session_store = new SimpleSessionStore();
        pre_key_store = new SimplePreKeyStore();
        signed_pre_key_store = new SimpleSignedPreKeyStore();
        if (changed) persistence_readiness_changed(false);
    }

    private void ensure_persistence_ready() throws Error {
        if (!persistence_ready) {
            throw new GLib.Error(
                Quark.from_string("omemo-persistent-store"),
                ErrorCode.UNKNOWN,
                "Persistent OMEMO store is not ready");
        }
    }

    internal void require_persistence_ready() throws Error {
        ensure_persistence_ready();
    }

    static int iks_get_identity_key_pair (out Buffer? public_data, out Buffer? private_data, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) {
            public_data = null;
            private_data = null;
            return ErrorCode.UNKNOWN;
        }
        public_data = new Buffer.from (store.identity_key_store.identity_key_public.get_data ());
        private_data = new Buffer.from (store.identity_key_store.identity_key_private.get_data ());
        return 0;
    }

    static int iks_get_local_registration_id (void* user_data, out uint32 registration_id) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) {
            registration_id = 0;
            return ErrorCode.UNKNOWN;
        }
        registration_id = store.identity_key_store.local_registration_id;
        return 0;
    }

    static int iks_save_identity ([CCode (type = "const signal_protocol_address*")] Address address, uint8[] key, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            store.identity_key_store.save_identity (address, key);
            return 0;
        });
    }

    static int iks_is_trusted_identity ([CCode (type = "const signal_protocol_address*")] Address address, uint8[] key, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            return store.identity_key_store.is_trusted_identity (address, key) ? 1 : 0;
        });
    }

    static void iks_destroy_func (void* user_data) {
    }

    static int ss_load_session_func (out Buffer? record, out Buffer? user_record, [CCode (type = "const signal_protocol_address*")] Address address, void* user_data) {
        Store store = (Store) user_data;
        user_record = null; // No support for user_record
        if (!store.persistence_ready) {
            record = null;
            return ErrorCode.UNKNOWN;
        }
        uint8[]? res = null;
        try {
            res = store.session_store.load_session (address);
        } catch (Error e) {
            record = null;
            return error_to_code (e);
        }
        if (res == null) {
            record = null;
            return 0;
        }
        record = new Buffer.from ((!)res);
        if (record == null) return ErrorCode.NOMEM;
        return 1;
    }

    static int ss_get_sub_device_sessions_func (out IntList? sessions, [CCode (array_length_type = "size_t", type = "const char*")] char[] name, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) {
            sessions = null;
            return ErrorCode.UNKNOWN;
        }
        try {
            sessions = store.session_store.get_sub_device_sessions (carr_to_string (name));
        } catch (Error e) {
            sessions = null;
            return error_to_code (e);
        }
        return (int) ((!) sessions).size;
    }

    static int ss_store_session_func ([CCode (type = "const signal_protocol_address*")] Address address, uint8[] record, uint8[] user_record, void* user_data) {
        // Ignoring user_record
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            store.session_store.store_session (address, record);
            return 0;
        });
    }

    static int ss_contains_session_func ([CCode (type = "const signal_protocol_address*")] Address address, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            return store.session_store.contains_session (address) ? 1 : 0;
        });
    }

    static int ss_delete_session_func ([CCode (type = "const signal_protocol_address*")] Address address, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            if (!store.session_store.contains_session (address)) return 0;
            store.session_store.delete_session (address);
            return 1;
        });
    }

    static int ss_delete_all_sessions_func ([CCode (array_length_type = "size_t", type = "const char*")] char[] name, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            string address_name = carr_to_string (name);
            IntList sessions = store.session_store.get_sub_device_sessions (address_name);
            int deleted = (int) sessions.size;
            store.session_store.delete_all_sessions (address_name);
            return deleted;
        });
    }

    static void ss_destroy_func (void* user_data) {
    }

    static int pks_load_pre_key (out Buffer? record, uint32 pre_key_id, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) {
            record = null;
            return ErrorCode.UNKNOWN;
        }
        uint8[]? res = null;
        try {
            res = store.pre_key_store.load_pre_key (pre_key_id);
        } catch (Error e) {
            record = null;
            return error_to_code (e);
        }
        if (res == null) {
            record = null;
            store.context.observe_missing_pre_key(store, pre_key_id, false);
            return ErrorCode.INVALID_KEY_ID;
        }
        record = new Buffer.from ((!)res);
        if (record == null) return ErrorCode.NOMEM;
        return 0;
    }

    static int pks_store_pre_key (uint32 pre_key_id, uint8[] record, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            store.pre_key_store.store_pre_key (pre_key_id, record);
            return 0;
        });
    }

    static int pks_contains_pre_key (uint32 pre_key_id, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            return store.pre_key_store.contains_pre_key (pre_key_id) ? 1 : 0;
        });
    }

    static int pks_remove_pre_key (uint32 pre_key_id, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            store.pre_key_store.delete_pre_key (pre_key_id);
            return 0;
        });
    }

    static void pks_destroy_func (void* user_data) {
    }

    static int spks_load_signed_pre_key (out Buffer? record, uint32 pre_key_id, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) {
            record = null;
            return ErrorCode.UNKNOWN;
        }
        uint8[]? res = null;
        try {
            res = store.signed_pre_key_store.load_signed_pre_key (pre_key_id);
        } catch (Error e) {
            record = null;
            return error_to_code (e);
        }
        if (res == null) {
            record = null;
            store.context.observe_missing_pre_key(store, pre_key_id, true);
            return ErrorCode.INVALID_KEY_ID;
        }
        record = new Buffer.from ((!)res);
        if (record == null) return ErrorCode.NOMEM;
        return 0;
    }

    static int spks_store_signed_pre_key (uint32 pre_key_id, uint8[] record, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            store.signed_pre_key_store.store_signed_pre_key (pre_key_id, record);
            return 0;
        });
    }

    static int spks_contains_signed_pre_key (uint32 pre_key_id, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            return store.signed_pre_key_store.contains_signed_pre_key (pre_key_id) ? 1 : 0;
        });
    }

    static int spks_remove_signed_pre_key (uint32 pre_key_id, void* user_data) {
        Store store = (Store) user_data;
        if (!store.persistence_ready) return ErrorCode.UNKNOWN;
        return catch_to_code (() => {
            store.signed_pre_key_store.delete_signed_pre_key (pre_key_id);
            return 0;
        });
    }

    static void spks_destroy_func (void* user_data) {
    }

    internal Store (Context context, bool persistence_ready = true) {
        this.context = context;
        this.persistence_ready = persistence_ready;
        NativeStoreContext.create (out native_store_context_, context.native_context);

        NativeIdentityKeyStore iks = NativeIdentityKeyStore () {
            get_identity_key_pair = iks_get_identity_key_pair,
            get_local_registration_id = iks_get_local_registration_id,
            save_identity = iks_save_identity,
            is_trusted_identity = iks_is_trusted_identity,
            destroy_func = iks_destroy_func,
            user_data = this
        };
        native_context.set_identity_key_store (iks);

        NativeSessionStore ss = NativeSessionStore () {
            load_session_func = ss_load_session_func,
            get_sub_device_sessions_func = ss_get_sub_device_sessions_func,
            store_session_func = ss_store_session_func,
            contains_session_func = ss_contains_session_func,
            delete_session_func = ss_delete_session_func,
            delete_all_sessions_func = ss_delete_all_sessions_func,
            destroy_func = ss_destroy_func,
            user_data = this
        };
        native_context.set_session_store (ss);

        NativePreKeyStore pks = NativePreKeyStore () {
            load_pre_key = pks_load_pre_key,
            store_pre_key = pks_store_pre_key,
            contains_pre_key = pks_contains_pre_key,
            remove_pre_key = pks_remove_pre_key,
            destroy_func = pks_destroy_func,
            user_data = this
        };
        native_context.set_pre_key_store (pks);

        NativeSignedPreKeyStore spks = NativeSignedPreKeyStore () {
            load_signed_pre_key = spks_load_signed_pre_key,
            store_signed_pre_key = spks_store_signed_pre_key,
            contains_signed_pre_key = spks_contains_signed_pre_key,
            remove_signed_pre_key = spks_remove_signed_pre_key,
            destroy_func = spks_destroy_func,
            user_data = this
        };
        native_context.set_signed_pre_key_store (spks);
    }

    private void require_registration_ready () throws Error {
        if (registration_pending) {
            throw new GLib.Error (Quark.from_string("omemo-registration"),
                    ErrorCode.NO_SESSION, "OMEMO device registration is not complete");
        }
    }

    public SessionBuilder create_session_builder (Address other) throws Error {
        ensure_persistence_ready();
        require_registration_ready ();
        SessionBuilder builder;
        throw_by_code (session_builder_create (out builder, native_context, other, context.native_context), "Error creating session builder");
        return builder;
    }

    public SessionCipher create_session_cipher (Address other) throws Error {
        ensure_persistence_ready();
        require_registration_ready ();
        SessionCipher cipher;
        throw_by_code (session_cipher_create (out cipher, native_context, other, context.native_context));
        return cipher;
    }

    public IdentityKeyPair identity_key_pair {
        owned get {
            IdentityKeyPair pair;
            Protocol.Identity.get_key_pair (native_context, out pair);
            return pair;
        }
    }

    public bool is_trusted_identity (Address address, ECPublicKey key) throws Error {
        ensure_persistence_ready();
        return throw_by_code (Protocol.Identity.is_trusted_identity (native_context, address, key)) == 1;
    }

    public void save_identity (Address address, ECPublicKey key) throws Error {
        ensure_persistence_ready();
        throw_by_code (Protocol.Identity.save_identity (native_context, address, key));
    }

    public bool contains_session (Address other) throws Error {
        ensure_persistence_ready();
        return throw_by_code (Protocol.Session.contains_session (native_context, other)) == 1;
    }

    public void delete_session (Address address) throws Error {
        ensure_persistence_ready();
        throw_by_code (Protocol.Session.delete_session (native_context, address));
    }

    public void delete_all_sessions(string name) throws Error {
        ensure_persistence_ready();
        session_store.delete_all_sessions(name);
    }

    public SessionRecord load_session (Address other) throws Error {
        ensure_persistence_ready();
        SessionRecord record;
        throw_by_code (Protocol.Session.load_session (native_context, out record, other));
        return record;
    }

    public bool contains_pre_key (uint32 pre_key_id) throws Error {
        ensure_persistence_ready();
        return throw_by_code (Protocol.PreKey.contains_key (native_context, pre_key_id)) == 1;
    }

    public void store_pre_key (PreKeyRecord record) throws Error {
        ensure_persistence_ready();
        throw_by_code (Protocol.PreKey.store_key (native_context, record));
    }

    public PreKeyRecord load_pre_key (uint32 pre_key_id) throws Error {
        ensure_persistence_ready();
        PreKeyRecord res;
        throw_by_code (Protocol.PreKey.load_key (native_context, out res, pre_key_id));
        return res;
    }

    public bool contains_signed_pre_key (uint32 pre_key_id) throws Error {
        ensure_persistence_ready();
        return throw_by_code (Protocol.SignedPreKey.contains_key (native_context, pre_key_id)) == 1;
    }

    public void store_signed_pre_key (SignedPreKeyRecord record) throws Error {
        ensure_persistence_ready();
        throw_by_code (Protocol.SignedPreKey.store_key (native_context, record));
    }

    public SignedPreKeyRecord load_signed_pre_key (uint32 pre_key_id) throws Error {
        ensure_persistence_ready();
        SignedPreKeyRecord res;
        throw_by_code (Protocol.SignedPreKey.load_key (native_context, out res, pre_key_id));
        return res;
    }
}

}
