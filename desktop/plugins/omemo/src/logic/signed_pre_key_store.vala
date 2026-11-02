using Qlite;
using Omemo;

namespace Dino.Plugins.Omemo {

internal class BackedSignedPreKeyStore : SimpleSignedPreKeyStore {
    private Database db;
    private int identity_id;
    private string? initialization_error;

    internal bool is_ready { get { return initialization_error == null; } }

    public BackedSignedPreKeyStore(Database db, int identity_id) {
        this.db = db;
        this.identity_id = identity_id;
        init();
    }

    private void init() {
        try {
            RowIterator rows = db.signed_pre_key.select()
                    .with(db.signed_pre_key.identity_id, "=", identity_id)
                    .iterator();
            while (rows.next_checked()) {
                Row row = rows.get();
                base.store_signed_pre_key(row[db.signed_pre_key.signed_pre_key_id],
                        Base64.decode(row[db.signed_pre_key.record_base64]));
            }
        } catch (Error e) {
            initialization_error = e.message;
            warning("Failed to initialize persistent OMEMO signed-pre-key store: %s", e.message);
        }
    }

    private void ensure_ready() throws Error {
        if (initialization_error != null) {
            throw new GLib.Error(
                Quark.from_string("omemo-signed-pre-key-store"),
                ErrorCode.UNKNOWN,
                "Persistent OMEMO signed-pre-key store is unavailable: %s".printf((!) initialization_error));
        }
    }

    internal void mark_unavailable(string reason) {
        if (initialization_error == null) initialization_error = reason;
    }

    public override uint8[]? load_signed_pre_key(uint32 pre_key_id) throws Error {
        ensure_ready();
        return base.load_signed_pre_key(pre_key_id);
    }

    public override bool contains_signed_pre_key(uint32 pre_key_id) throws Error {
        ensure_ready();
        return base.contains_signed_pre_key(pre_key_id);
    }

    public override void store_signed_pre_key(uint32 pre_key_id, uint8[] record) throws Error {
        ensure_ready();
        db.signed_pre_key.upsert()
                .value(db.signed_pre_key.identity_id, identity_id, true)
                .value(db.signed_pre_key.signed_pre_key_id, (int) pre_key_id, true)
                .value(db.signed_pre_key.record_base64, Base64.encode(record))
                .perform_checked();
        base.store_signed_pre_key(pre_key_id, record);
    }

    public override void delete_signed_pre_key(uint32 pre_key_id) throws Error {
        ensure_ready();
        db.signed_pre_key.delete()
                .with(db.signed_pre_key.identity_id, "=", identity_id)
                .with(db.signed_pre_key.signed_pre_key_id, "=", (int) pre_key_id)
                .perform_checked();
        base.delete_signed_pre_key(pre_key_id);
    }
}

}
