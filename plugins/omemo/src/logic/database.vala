using Gee;
using Qlite;

using Dino.Entities;
using Dino.Security;

namespace Dino.Plugins.Omemo {

public class Database : Qlite.Database {
    private const int VERSION = 11;

    public class IdentityMetaTable : Table {
        //Default to provide backwards compatability
        public Column<int> identity_id = new Column.Integer("identity_id") { not_null = true, min_version = 2, default = "-1" };
        public Column<string> address_name = new Column.Text("address_name") { not_null = true };
        public Column<int> device_id = new Column.Integer("device_id") { not_null = true };
        public Column<string?> identity_key_public_base64 = new Column.Text("identity_key_public_base64");
        public Column<bool> trusted_identity = new Column.BoolInt("trusted_identity") { default = "0", max_version = 1 };
        public Column<int> trust_level = new Column.Integer("trust_level") { default = TrustLevel.UNKNOWN.to_string(), min_version = 2 };
        public Column<bool> now_active = new Column.BoolInt("now_active") { default = "1" };
        public Column<long> last_active = new Column.Long("last_active");
        public Column<long> last_message_untrusted = new Column.Long("last_message_untrusted") { min_version = 5 };
        public Column<long> last_message_undecryptable = new Column.Long("last_message_undecryptable") { min_version = 5 };
        public Column<string?> device_label = new Column.Text("device_label") { min_version = 6 };
        public Column<bool> supports_omemo1 = new Column.BoolInt("supports_omemo1") { min_version = 7, default = "1" };
        public Column<bool> supports_omemo2 = new Column.BoolInt("supports_omemo2") { min_version = 7, default = "0" };
        public Column<bool> identity_key_changed = new Column.BoolInt("identity_key_changed") { min_version = 8, default = "0" };

        internal IdentityMetaTable(Database db) {
            base(db, "identity_meta");
            init({identity_id, address_name, device_id, identity_key_public_base64, trusted_identity, trust_level, now_active, last_active, last_message_untrusted, last_message_undecryptable, device_label, supports_omemo1, supports_omemo2, identity_key_changed});
            index("identity_meta_idx", {identity_id, address_name, device_id}, true);
            index("identity_meta_list_idx", {identity_id, address_name});
        }

        public QueryBuilder with_address(int identity_id, string address_name) {
            return select().with(this.identity_id, "=", identity_id).with(this.address_name, "=", address_name);
        }

        public QueryBuilder get_with_device_id(int identity_id, int device_id) {
            return select().with(this.identity_id, "=", identity_id).with(this.device_id, "=", device_id);
        }

        public void insert_device_list(int32 identity_id, string address_name, ArrayList<int32> devices) {
            // Legacy OMEMO device lists replace the legacy view only. Keep
            // devices alive if they are still advertised by OMEMO 2.
            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.address_name, "=", address_name)
                .set(supports_omemo1, false)
                .set(now_active, false)
                .perform();
            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.address_name, "=", address_name)
                .with(this.supports_omemo2, "=", true)
                .set(now_active, true)
                .perform();
            foreach (int32 device_id in devices) {
                // Check if this device already exists — only set last_active for genuinely NEW devices
                bool is_new = !with_address(identity_id, address_name).with(this.device_id, "=", device_id).single().row().is_present();
                var builder = upsert()
                        .value(this.identity_id, identity_id, true)
                        .value(this.address_name, address_name, true)
                        .value(this.device_id, device_id, true)
                        .value(this.supports_omemo1, true)
                        .value(this.now_active, true);
                if (is_new) {
                    builder.value(this.last_active, (long) new DateTime.now_utc().to_unix());
                }
                builder.perform();
            }
        }

        /**
         * Replace the OMEMO 2 view without deactivating legacy-only devices.
         */
        public void insert_device_list_omemo2(int32 identity_id, string address_name, ArrayList<int32> devices) {
            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.address_name, "=", address_name)
                .set(supports_omemo2, false)
                .set(now_active, false)
                .perform();
            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.address_name, "=", address_name)
                .with(this.supports_omemo1, "=", true)
                .set(now_active, true)
                .perform();
            foreach (int32 device_id in devices) {
                bool is_new = !with_address(identity_id, address_name).with(this.device_id, "=", device_id).single().row().is_present();
                var builder = upsert()
                        .value(this.identity_id, identity_id, true)
                        .value(this.address_name, address_name, true)
                        .value(this.device_id, device_id, true)
                        .value(this.supports_omemo2, true)
                        .value(this.now_active, true);
                if (is_new) {
                    builder.value(this.supports_omemo1, false);
                    builder.value(this.last_active, (long) new DateTime.now_utc().to_unix());
                }
                builder.perform();
            }
        }

        public bool has_omemo1_devices(int identity_id, string address_name) {
            return with_address(identity_id, address_name)
                .with(this.now_active, "=", true)
                .with(this.supports_omemo1, "=", true)
                .count() > 0;
        }

        public bool has_omemo2_devices(int identity_id, string address_name) {
            return with_address(identity_id, address_name)
                .with(this.now_active, "=", true)
                .with(this.supports_omemo2, "=", true)
                .count() > 0;
        }

        public int64 insert_device_bundle(int32 identity_id, string address_name, int device_id, Bundle bundle, TrustLevel trust) {
            try {
                return insert_device_bundle_checked(identity_id, address_name, device_id, bundle, trust);
            } catch (Error e) {
                critical("Failed to persist OMEMO device bundle: %s", e.message);
                return -1;
            }
        }

        public int64 insert_device_bundle_checked(int32 identity_id, string address_name, int device_id, Bundle bundle, TrustLevel trust) throws Error {
            if (bundle == null || bundle.identity_key == null) return -1;
            // Check if identity_key changed -- can happen legitimately when key encoding
            // changes (e.g., OMEMO 2 Ed25519 vs Montgomery migration) or device reinstall.
            string identity_key = Base64.encode(bundle.identity_key.serialize());
            bool key_changed = false;
            Row? row = get_device_checked(identity_id, address_name, device_id);
            if (row != null && ((!) row)[identity_key_public_base64] != null && ((!) row)[identity_key_public_base64] != identity_key) {
                warning("Identity key changed for device %d of %s. Updating and resetting trust.", device_id, address_name);
                trust = TrustLevel.UNKNOWN;
                key_changed = true;
            }
            var builder = upsert()
                    .value(this.identity_id, identity_id, true)
                    .value(this.address_name, address_name, true)
                    .value(this.device_id, device_id, true)
                    .value(this.identity_key_public_base64, identity_key)
                    .value(this.trust_level, trust);
            if (key_changed) {
                builder.value(this.identity_key_changed, true);
            }
            return builder.perform_checked();
        }

        public int64 insert_device_session(int32 identity_id, string address_name, int device_id, string identity_key, TrustLevel trust) {
            try {
                return insert_device_session_checked(identity_id, address_name, device_id, identity_key, trust);
            } catch (Error e) {
                critical("Failed to persist OMEMO device identity: %s", e.message);
                return -1;
            }
        }

        public int64 insert_device_session_checked(int32 identity_id, string address_name, int device_id, string identity_key, TrustLevel trust) throws Error {
            bool key_changed = false;
            Row? row = get_device_checked(identity_id, address_name, device_id);
            if (row != null && ((!) row)[identity_key_public_base64] != null && ((!) row)[identity_key_public_base64] != identity_key) {
                warning("Identity key changed for device %d of %s. Updating (may be key format migration or reinstall).", device_id, address_name);
                // Reset trust to UNKNOWN when identity key changes
                trust = TrustLevel.UNKNOWN;
                key_changed = true;
            }
            var builder = upsert()
                    .value(this.identity_id, identity_id, true)
                    .value(this.address_name, address_name, true)
                    .value(this.device_id, device_id, true)
                    .value(this.identity_key_public_base64, identity_key)
                    .value(this.trust_level, trust);
            if (key_changed) {
                builder.value(this.identity_key_changed, true);
            }
            return builder.perform_checked();
        }

        public void update_last_message_untrusted(int identity_id, string address_name, int device_id, DateTime? time) {
            var stmt = update()
                    .with(this.identity_id, "=", identity_id)
                    .with(this.address_name, "=", address_name)
                    .with(this.device_id, "=", device_id);
            if (time != null) {
                stmt.set(last_message_untrusted, (long)time.to_unix());
            } else {
                stmt.set_null(last_message_untrusted);
            }
            stmt.perform();
        }

        public void update_last_message_undecryptable(int identity_id, string address_name, int device_id, DateTime? time) {
            var stmt = update()
                    .with(this.identity_id, "=", identity_id)
                    .with(this.address_name, "=", address_name)
                    .with(this.device_id, "=", device_id);
            if (time != null) {
                stmt.set(last_message_undecryptable, (long)time.to_unix());
            } else {
                stmt.set_null(last_message_undecryptable);
            }
            stmt.perform();
        }

        public QueryBuilder get_trusted_devices(int identity_id, string address_name) {
            return this.with_address(identity_id, address_name)
                .with(this.trust_level, "!=", TrustLevel.UNTRUSTED)
                .with(this.now_active, "=", true);
        }

        public QueryBuilder get_trusted_devices_omemo1(int identity_id, string address_name) {
            return get_trusted_devices(identity_id, address_name)
                .with(this.supports_omemo1, "=", true);
        }

        public QueryBuilder get_trusted_devices_omemo2(int identity_id, string address_name) {
            return get_trusted_devices(identity_id, address_name)
                .with(this.supports_omemo2, "=", true);
        }

        public QueryBuilder get_known_devices(int identity_id, string address_name) {
            return this.with_address(identity_id, address_name)
                .with(this.trust_level, "!=", TrustLevel.UNKNOWN)
                .with(this.now_active, "=", true)
                .without_null(this.identity_key_public_base64);
        }

        public QueryBuilder get_unknown_devices(int identity_id, string address_name) {
            return this.with_address(identity_id, address_name)
                .with(this.now_active, "=", true)
                .with_null(this.identity_key_public_base64);
        }

        public int64 count_active_omemo2_devices(int identity_id) {
            return this.select()
                .with(this.identity_id, "=", identity_id)
                .with(this.now_active, "=", true)
                .with(this.supports_omemo2, "=", true)
                .count();
        }

        public void disable_omemo2_runtime_state(int identity_id) {
            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.supports_omemo2, "=", true)
                .with(this.supports_omemo1, "=", false)
                .set(this.now_active, false)
                .set(this.supports_omemo2, false)
                .perform();

            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.supports_omemo2, "=", true)
                .with(this.supports_omemo1, "=", true)
                .set(this.supports_omemo2, false)
                .perform();
        }

        public QueryBuilder get_new_devices(int identity_id, string address_name) {
            return this.with_address(identity_id, address_name)
                .with(this.trust_level, "=", TrustLevel.UNKNOWN)
                .with(this.now_active, "=", true)
                .without_null(this.identity_key_public_base64);
        }

        public QueryBuilder get_changed_key_devices(int identity_id, string address_name) {
            return get_new_devices(identity_id, address_name)
                .with(this.identity_key_changed, "=", true);
        }

        public Row? get_device(int identity_id, string address_name, int device_id) {
            try {
                return get_device_checked(identity_id, address_name, device_id);
            } catch (Error e) {
                warning("Failed to read OMEMO device metadata: %s", e.message);
                return null;
            }
        }

        public Row? get_device_checked(int identity_id, string address_name,
                int device_id) throws Error {
            return this.with_address(identity_id, address_name)
                .with(this.device_id, "=", device_id)
                .single().iterator().get_next_checked();
        }

        /** Update last_active timestamp when a message is successfully decrypted from this device */
        public void update_last_active(int identity_id, string address_name, int device_id) {
            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.address_name, "=", address_name)
                .with(this.device_id, "=", device_id)
                .set(this.last_active, (long) new DateTime.now_utc().to_unix())
                .perform();
        }

        public void update_device_label(int identity_id, string address_name, int device_id, string label) {
            update()
                .with(this.identity_id, "=", identity_id)
                .with(this.address_name, "=", address_name)
                .with(this.device_id, "=", device_id)
                .set(this.device_label, label)
                .perform();
        }
    }


    public class TrustTable : Table {
        public Column<int> identity_id = new Column.Integer("identity_id") { not_null = true };
        public Column<string> address_name = new Column.Text("address_name");
        public Column<bool> blind_trust = new Column.BoolInt("blind_trust") { default = "1" } ;

        internal TrustTable(Database db) {
            base(db, "trust");
            init({identity_id, address_name, blind_trust});
            index("trust_idx", {identity_id, address_name}, true);
        }

        public bool get_blind_trust(int32 identity_id, string address_name, bool def = false) {
            try {
                return get_blind_trust_checked(identity_id, address_name, def);
            } catch (Error e) {
                warning("Failed to read OMEMO blind-trust policy: %s", e.message);
                return false;
            }
        }

        public bool get_blind_trust_checked(int32 identity_id,
                string address_name, bool def = false) throws Error {
            Row? row = this.select().with(this.identity_id, "=", identity_id)
                    .with(this.address_name, "=", address_name)
                    .single().iterator().get_next_checked();
            if (row != null) return ((!) row)[blind_trust];
            return def;
        }
    }

    public class IdentityTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { unique = true, not_null = true };
        public Column<int> device_id = new Column.Integer("device_id") { not_null = true };
        public Column<string> identity_key_private_base64 = new Column.NonNullText("identity_key_private_base64");
        public Column<string> identity_key_public_base64 = new Column.NonNullText("identity_key_public_base64");
        // Existing identities must never be regenerated merely by upgrading.
        // Only a newly inserted identity explicitly opts into first-publication
        // collision checks; the flag survives interrupted publication.
        public Column<bool> registration_pending = new Column.BoolInt("registration_pending") { not_null = true, min_version = 9, default = "0" };
        // One-time key deletion must not make its ID available for reuse after
        // reconnect/restart. Existing key records seed this additive column.
        public Column<int> pre_key_high_watermark = new Column.Integer("pre_key_high_watermark") { not_null = true, min_version = 10, default = "0" };

        internal IdentityTable(Database db) {
            base(db, "identity");
            init({id, account_id, device_id, identity_key_private_base64, identity_key_public_base64, registration_pending, pre_key_high_watermark});
        }

        public int get_id(int account_id) {
            try {
                return get_id_checked(account_id);
            } catch (Error e) {
                warning("Failed to read OMEMO account identity: %s", e.message);
                return -1;
            }
        }

        public int get_id_checked(int account_id) throws Error {
            Row? row = this.select().with(this.account_id, "=", account_id)
                    .single().iterator().get_next_checked();
            return row == null ? -1 : ((!) row)[this.id];
        }
    }

    public class SignedPreKeyTable : Table {
        public Column<int> identity_id = new Column.Integer("identity_id") { not_null = true };
        public Column<int> signed_pre_key_id = new Column.Integer("signed_pre_key_id") { not_null = true };
        public Column<string> record_base64 = new Column.NonNullText("record_base64");

        internal SignedPreKeyTable(Database db) {
            base(db, "signed_pre_key");
            init({identity_id, signed_pre_key_id, record_base64});
            unique({identity_id, signed_pre_key_id});
            index("signed_pre_key_idx", {identity_id, signed_pre_key_id}, true);
        }
    }

    public class PreKeyTable : Table {
        public Column<int> identity_id = new Column.Integer("identity_id") { not_null = true };
        public Column<int> pre_key_id = new Column.Integer("pre_key_id") { not_null = true };
        public Column<string> record_base64 = new Column.NonNullText("record_base64");

        internal PreKeyTable(Database db) {
            base(db, "pre_key");
            init({identity_id, pre_key_id, record_base64});
            unique({identity_id, pre_key_id});
            index("pre_key_idx", {identity_id, pre_key_id}, true);
        }
    }

    public class SessionTable : Table {
        public Column<int> identity_id = new Column.Integer("identity_id") { not_null = true };
        public Column<string> address_name = new Column.NonNullText("name");
        public Column<int> device_id = new Column.Integer("device_id") { not_null = true };
        public Column<string> record_base64 = new Column.NonNullText("record_base64");

        internal SessionTable(Database db) {
            base(db, "session");
            init({identity_id, address_name, device_id, record_base64});
            unique({identity_id, address_name, device_id});
            index("session_idx", {identity_id, address_name, device_id}, true);
        }
    }

    public class ContentItemMetaTable : Table {
        public Column<int> content_item_id = new Column.Integer("message_id") { primary_key = true };
        public Column<int> identity_id = new Column.Integer("identity_id") { not_null = true };
        public Column<string> address_name = new Column.Text("address_name") { not_null = true };
        public Column<int> device_id = new Column.Integer("device_id") { not_null = true };
        public Column<bool> trusted_when_received = new Column.BoolInt("trusted_when_received") { not_null = true, default = "1" };
        // Never infer an archived sender fingerprint from the current device
        // row: a device ID may have been reused with a different identity.
        public Column<string?> key_public = new Column.Text("key_public") { min_version = 11 };

        internal ContentItemMetaTable(Database db) {
            base(db, "content_item_meta");
            init({content_item_id, identity_id, address_name, device_id, trusted_when_received, key_public});
            index("content_item_meta_device_idx", {identity_id, device_id, address_name});
        }

        public RowOption with_content_item(ContentItem item) {
            return row_with(content_item_id, item.id);
        }

        public QueryBuilder with_device(int identity_id, string address_name, int device_id) {
            return select()
                .with(this.identity_id, "=", identity_id)
                .with(this.address_name, "=", address_name)
                .with(this.device_id, "=", device_id);
        }
    }

    public IdentityMetaTable identity_meta { get; private set; }
    public TrustTable trust { get; private set; }
    public IdentityTable identity { get; private set; }
    public SignedPreKeyTable signed_pre_key { get; private set; }
    public PreKeyTable pre_key { get; private set; }
    public SessionTable session { get; private set; }
    public ContentItemMetaTable content_item_meta { get; private set; }

    public Database(string fileName) throws Error {
        base(fileName, VERSION);
        identity_meta = new IdentityMetaTable(this);
        trust = new TrustTable(this);
        identity = new IdentityTable(this);
        signed_pre_key = new SignedPreKeyTable(this);
        pre_key = new PreKeyTable(this);
        session = new SessionTable(this);
        content_item_meta = new ContentItemMetaTable(this);
        
        string? key = null;
        try {
            key = KeyManager.get_or_create_db_key();
        } catch (Error e) {
            warning("OmemoDatabase: Failed to get encryption key: %s", e.message);
        }

        if (key == null) {
            // Without a key we cannot safely open or create the OMEMO database.
            throw new Error(-1, 0, "OMEMO database key unavailable; cannot open \"%s\"", fileName);
        }
        
        init({identity_meta, trust, identity, signed_pre_key, pre_key, session, content_item_meta}, key);

        try {
            exec("PRAGMA journal_mode = WAL");
            // Double-Ratchet state must survive a hard process/OS shutdown.
            // WAL+NORMAL may lose a recently acknowledged commit; reopening
            // such a database strands the peer on a newer ratchet state.
            exec("PRAGMA synchronous = FULL");
            exec("PRAGMA secure_delete = ON");
        } catch (Error e) {
            error("Failed to set OMEMO database properties: %s", e.message);
        }
    }

    public override void migrate(long oldVersion) {
        if(oldVersion == 1) {
            try {
                exec("DROP INDEX identity_meta_idx");
                exec("DROP INDEX identity_meta_list_idx");
                exec("CREATE UNIQUE INDEX identity_meta_idx ON identity_meta (identity_id, address_name, device_id)");
                exec("CREATE INDEX identity_meta_list_idx ON identity_meta (identity_id, address_name)");
            } catch (Error e) {
                critical("Failed to migrate OMEMO database: %s", e.message);
                Process.exit(-1);
            }
        }
    }
}

}
