using Omemo;
using Qlite;

namespace Dino.Plugins.Omemo {

internal class BackedSessionStore : SimpleSessionStore {
    private Database db;
    private int identity_id;
    private string? initialization_error;
    private bool memory_only_mutation;

    internal bool is_ready { get { return initialization_error == null; } }

    internal bool belongs_to(Database database, int identity_id) {
        return this.db == database && this.identity_id == identity_id;
    }

    public BackedSessionStore(Database db, int identity_id) {
        this.db = db;
        this.identity_id = identity_id;
        init();
    }

    private void init() {
        try {
            RowIterator rows = db.session.select()
                    .with(db.session.identity_id, "=", identity_id)
                    .iterator();
            while (rows.next_checked()) {
                Row row = rows.get();
                Address addr = new Address(row[db.session.address_name], row[db.session.device_id]);
                memory_only_mutation = true;
                base.store_session(addr, Base64.decode(row[db.session.record_base64]));
                memory_only_mutation = false;
                addr.device_id = 0;
            }
        } catch (Error e) {
            memory_only_mutation = false;
            initialization_error = e.message;
            warning("Failed to initialize persistent OMEMO session store: %s", e.message);
        }
    }

    private void ensure_ready() throws Error {
        if (initialization_error != null) {
            throw new GLib.Error(
                Quark.from_string("omemo-session-store"),
                ErrorCode.UNKNOWN,
                "Persistent OMEMO session store is unavailable: %s".printf((!) initialization_error));
        }
    }

    internal void mark_unavailable(string reason) {
        if (initialization_error == null) initialization_error = reason;
    }

    private void persist_session(Address address, uint8[] record) throws Error {
        db.session.upsert()
                .value(db.session.identity_id, identity_id, true)
                .value(db.session.address_name, address.name, true)
                .value(db.session.device_id, address.device_id, true)
                .value(db.session.record_base64, Base64.encode(record))
                .perform_checked();
    }

    private void delete_persisted_session(Address address) throws Error {
        db.session.delete()
                .with(db.session.identity_id, "=", identity_id)
                .with(db.session.address_name, "=", address.name)
                .with(db.session.device_id, "=", address.device_id)
                .perform_checked();
    }

    public override uint8[]? load_session(Address address) throws Error {
        ensure_ready();
        return base.load_session(address);
    }

    public override IntList get_sub_device_sessions(string name) throws Error {
        ensure_ready();
        return base.get_sub_device_sessions(name);
    }

    public override bool contains_session(Address address) throws Error {
        ensure_ready();
        return base.contains_session(address);
    }

    public override void store_session(Address address, uint8[] record) throws Error {
        ensure_ready();

        // Persist the next ratchet state before exposing it in memory. The
        // UPSERT replaces the old record atomically; it must never be preceded
        // by the SimpleSessionStore's DELETE operation in the database.
        persist_session(address, record);

        memory_only_mutation = true;
        try {
            base.store_session(address, record);
        } finally {
            memory_only_mutation = false;
        }
    }

    public override void delete_session(Address address) throws Error {
        ensure_ready();
        if (!memory_only_mutation) {
            delete_persisted_session(address);
        }
        base.delete_session(address);
    }

    public override void delete_all_sessions(string name) throws Error {
        ensure_ready();
        if (!memory_only_mutation) {
            db.session.delete()
                    .with(db.session.identity_id, "=", identity_id)
                    .with(db.session.address_name, "=", name)
                    .perform_checked();
        }

        memory_only_mutation = true;
        try {
            base.delete_all_sessions(name);
        } finally {
            memory_only_mutation = false;
        }
    }

    /**
     * Restore a previously snapshotted session in memory only.
     *
     * PREKEY transaction rollback already restores SQLCipher. Calling the
     * regular backed methods afterwards would start a second database write
     * while the transaction state may be unknown.
     */
    internal void restore_memory_only(Address address, uint8[]? record)
            throws Error {
        memory_only_mutation = true;
        try {
            if (record == null) {
                if (base.contains_session(address)) {
                    base.delete_session(address);
                }
            } else {
                base.store_session(address, (!) record);
            }
        } finally {
            memory_only_mutation = false;
        }
    }
}

}
