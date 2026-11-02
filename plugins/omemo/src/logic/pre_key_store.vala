using Omemo;
using Qlite;

namespace Dino.Plugins.Omemo {

internal class BackedPreKeyStore : SimplePreKeyStore {
    private Database db;
    private int identity_id;
    private string? initialization_error;

    internal bool is_ready { get { return initialization_error == null; } }

    public BackedPreKeyStore(Database db, int identity_id) {
        this.db = db;
        this.identity_id = identity_id;
        init();
    }

    private void init() {
        try {
            uint32 maximum_id = 0;
            RowIterator rows = db.pre_key.select()
                    .with(db.pre_key.identity_id, "=", identity_id)
                    .iterator();
            while (rows.next_checked()) {
                Row row = rows.get();
                maximum_id = uint32.max(maximum_id, (uint32) row[db.pre_key.pre_key_id]);
                base.store_pre_key(row[db.pre_key.pre_key_id],
                        Base64.decode(row[db.pre_key.record_base64]));
            }
            observe_high_watermark(maximum_id);
        } catch (Error e) {
            initialization_error = e.message;
            warning("Failed to initialize persistent OMEMO pre-key store: %s", e.message);
        }
    }

    private void ensure_ready() throws Error {
        if (initialization_error != null) {
            throw new GLib.Error(
                Quark.from_string("omemo-pre-key-store"),
                ErrorCode.UNKNOWN,
                "Persistent OMEMO pre-key store is unavailable: %s".printf((!) initialization_error));
        }
    }

    internal void mark_unavailable(string reason) {
        if (initialization_error == null) initialization_error = reason;
    }

    public override uint8[]? load_pre_key(uint32 pre_key_id) throws Error {
        ensure_ready();
        return base.load_pre_key(pre_key_id);
    }

    public override bool contains_pre_key(uint32 pre_key_id) throws Error {
        ensure_ready();
        return base.contains_pre_key(pre_key_id);
    }

    public override void store_pre_key(uint32 pre_key_id, uint8[] record) throws Error {
        ensure_ready();
        // Reserve the ID before exposing any key record. A failed insert may
        // leave a gap; it must never permit an already allocated ID to repeat.
        observe_high_watermark(pre_key_id);
        db.pre_key.upsert()
                .value(db.pre_key.identity_id, identity_id, true)
                .value(db.pre_key.pre_key_id, (int) pre_key_id, true)
                .value(db.pre_key.record_base64, Base64.encode(record))
                .perform_checked();
        base.store_pre_key(pre_key_id, record);
    }

    private int read_high_watermark() throws Error {
        Row? row = db.identity.select({db.identity.pre_key_high_watermark})
                .with(db.identity.id, "=", identity_id)
                .single().iterator().get_next_checked();
        if (row == null) throw new IOError.FAILED("Own OMEMO pre-key identity is unavailable");
        int high_watermark = ((!) row)[db.identity.pre_key_high_watermark];
        if (high_watermark < 0) {
            throw new IOError.INVALID_DATA("Own OMEMO pre-key high-water mark is invalid");
        }
        return high_watermark;
    }

    internal void observe_high_watermark(uint32 observed_id) throws Error {
        if (observed_id > int.MAX) {
            throw new IOError.INVALID_DATA("Own OMEMO pre-key ID range is exhausted");
        }
        int current = read_high_watermark();
        if (observed_id <= current) return;
        db.exec_prepared("UPDATE identity SET pre_key_high_watermark = MAX(pre_key_high_watermark, CAST(? AS INTEGER)) WHERE id = ?",
                {observed_id.to_string(), identity_id.to_string()});
        if (db.changes() != 1) throw new IOError.FAILED("Own OMEMO pre-key identity changed while reserving an ID");
    }

    // Called by the own legacy publisher outside PREKEY receive savepoints.
    // Persist the whole range before generating/storing keys or yielding to IQs.
    internal uint32 reserve_key_ids(uint count, uint32 observed_id) throws Error {
        ensure_ready();
        observe_high_watermark(uint32.max(observed_id, base.get_max_key_id()));
        int current = read_high_watermark();
        int64 first = (int64) current + 1;
        // libomemo-c treats 0xFFFFFF as a reusable last-resort key, not an
        // ordinary one-time key. Keep every generated range clear of it.
        if (first <= 0xFFFFFF && first + count - 1 >= 0xFFFFFF) first = 0x1000000;
        int64 last = first + count - 1;
        if (count == 0 || count > int.MAX || last > int.MAX) {
            throw new IOError.INVALID_DATA("Own OMEMO pre-key ID range is exhausted");
        }
        int reserved = (int) last;
        db.exec_prepared("UPDATE identity SET pre_key_high_watermark = ? WHERE id = ? AND pre_key_high_watermark = ?",
                {reserved.to_string(), identity_id.to_string(), current.to_string()});
        if (db.changes() != 1) throw new IOError.BUSY("Own OMEMO pre-key ID reservation changed concurrently");
        return (uint32) first;
    }

    public override void delete_pre_key(uint32 pre_key_id) throws Error {
        ensure_ready();
        db.pre_key.delete()
                .with(db.pre_key.identity_id, "=", identity_id)
                .with(db.pre_key.pre_key_id, "=", (int) pre_key_id)
                .perform_checked();
        base.delete_pre_key(pre_key_id);
    }

    /** Restore a PREKEY snapshot in memory without touching SQLCipher. */
    internal void restore_memory_only(uint32 pre_key_id, uint8[]? record)
            throws Error {
        if (record == null) {
            if (base.contains_pre_key(pre_key_id)) {
                base.delete_pre_key(pre_key_id);
            }
        } else {
            base.store_pre_key(pre_key_id, (!) record);
        }
    }
}

}
