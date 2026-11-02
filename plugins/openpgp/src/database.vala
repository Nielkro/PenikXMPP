using Qlite;
using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino.Plugins.OpenPgp {

public class Database : Qlite.Database {
    private const int VERSION = 12;

    public const string KEY_SOURCE_UNKNOWN = "unknown";
    public const string KEY_SOURCE_XEP0027 = "xep0027";
    public const string KEY_SOURCE_XEP0373 = "xep0373";
    public const string KEY_SOURCE_KEYSERVER = "keyserver";
    public const string KEY_SOURCE_MANUAL = "manual";

    public const string ACCOUNT_KEY_MODE_XMPP = "xmpp";
    public const string ACCOUNT_KEY_MODE_LEGACY = "legacy";

    public const string XMPP_TRUST_UNVERIFIED = "unverified";
    public const string XMPP_TRUST_VERIFIED = "verified";
    public const string XMPP_TRUST_CHANGED = "changed";

    public class AccountSetting : Table {
        public Column<int> account_id = new Column.Integer("account_id") { primary_key = true };
        public Column<string> key = new Column.Text("key") { not_null = true };
        public Column<string> key_mode = new Column.Text("key_mode") { min_version = 3, default = "'xmpp'" };
        public Column<string> legacy_key = new Column.Text("legacy_key") { min_version = 5 };
        public Column<string> xmpp_key = new Column.Text("xmpp_key") { min_version = 5 };

        internal AccountSetting(Database db) {
            base(db, "account_setting");
            init({account_id, key, key_mode, legacy_key, xmpp_key});
        }
    }

    public class ContactKey : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<string> jid = new Column.Text("jid") { not_null = true };
        public Column<string> key = new Column.Text("key") { not_null = true };
        public Column<string> source = new Column.Text("source") { min_version = 2, default = "'unknown'" };
        public Column<bool> supports_xep0374 = new Column.BoolInt("supports_xep0374") { min_version = 2, default = "0" };
        public Column<string> legacy_key = new Column.Text("legacy_key") { min_version = 4 };
        public Column<string> xmpp_key = new Column.Text("xmpp_key") { min_version = 4 };
        public Column<bool> legacy_announced = new Column.BoolInt("legacy_announced") { min_version = 8, default = "0" };
        public Column<string> xmpp_trust_state = new Column.Text("xmpp_trust_state") { min_version = 11, default = "'unverified'" };
        public Column<string> xmpp_verified_fingerprint = new Column.Text("xmpp_verified_fingerprint") { min_version = 11 };
        public Column<long> xmpp_trust_updated_at = new Column.Long("xmpp_trust_updated_at") { min_version = 11, default = "0" };

        internal ContactKey(Database db) {
            base(db, "contact_key");
            init({id, account_id, jid, key, source, supports_xep0374, legacy_key, xmpp_key, legacy_announced,
                    xmpp_trust_state, xmpp_verified_fingerprint, xmpp_trust_updated_at});
            unique({account_id, jid}, "REPLACE");
        }
    }

    // Tracks which keys have been published to a keyserver
    public class PublishedKey : Table {
        public Column<string> fingerprint = new Column.Text("fingerprint") { primary_key = true };
        public Column<string> keyserver = new Column.Text("keyserver") { not_null = true };
        public Column<int64?> published_at = new Column.Long("published_at") { not_null = true };

        internal PublishedKey(Database db) {
            base(db, "published_key");
            init({fingerprint, keyserver, published_at});
        }
    }

    // Tracks XMPP-published OpenPGP keys that must be retracted once the
    // account stream is available again.
    public class PendingXmppKeyRetraction : Table {
        public Column<string> token = new Column.NonNullText("token") { primary_key = true, min_version = 9 };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true, min_version = 9 };
        public Column<string> fingerprint = new Column.NonNullText("fingerprint") { min_version = 9 };
        public Column<long> created_at = new Column.Long("created_at") { not_null = true, min_version = 9 };

        internal PendingXmppKeyRetraction(Database db) {
            base(db, "pending_xmpp_key_retraction");
            init({token, account_id, fingerprint, created_at});
        }
    }

    // Explicitly imported keys may have an email UID different from the JID.
    // Visibility is an account assignment, not activation of either protocol.
    public class AccountPrivateKey : Table {
        public Column<string> token = new Column.NonNullText("token") { primary_key = true, min_version = 12 };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true, min_version = 12 };
        public Column<string> fingerprint = new Column.NonNullText("fingerprint") { min_version = 12 };

        internal AccountPrivateKey(Database db) {
            base(db, "account_private_key");
            init({token, account_id, fingerprint});
        }
    }

    // This is a local observation of a successfully published/inspected backup.
    // Never infer its contents from the currently active key or a short key ID.
    public class AccountSecretBackup : Table {
        public Column<int> account_id = new Column.Integer("account_id") { primary_key = true, min_version = 12 };
        public Column<string> digest = new Column.NonNullText("digest") { min_version = 12 };
        public Column<string> fingerprints = new Column.NonNullText("fingerprints") { min_version = 12 };

        internal AccountSecretBackup(Database db) {
            base(db, "account_secret_backup");
            init({account_id, digest, fingerprints});
        }
    }

    public class PendingSecretBackupCleanup : Table {
        public Column<int> account_id = new Column.Integer("account_id") { primary_key = true, min_version = 12 };
        public Column<string> fingerprint = new Column.NonNullText("fingerprint") { min_version = 12 };
        public Column<string> digest = new Column.NonNullText("digest") { min_version = 12 };

        internal PendingSecretBackupCleanup(Database db) {
            base(db, "pending_secret_backup_cleanup");
            init({account_id, fingerprint, digest});
        }
    }

    public AccountPrivateKey account_private_key_table { get; private set; }
    public AccountSecretBackup account_secret_backup_table { get; private set; }
    public PendingSecretBackupCleanup pending_secret_backup_cleanup_table { get; private set; }
    public AccountSetting account_setting_table { get; private set; }
    public ContactKey contact_key_table { get; private set; }
    public PublishedKey published_key_table { get; private set; }
    public PendingXmppKeyRetraction pending_xmpp_key_retraction_table { get; private set; }

    public Database(string filename, string? key) throws Error {
        base(filename, VERSION);
        this.account_setting_table = new AccountSetting(this);
        this.contact_key_table = new ContactKey(this);
        this.published_key_table = new PublishedKey(this);
        this.pending_xmpp_key_retraction_table = new PendingXmppKeyRetraction(this);
        this.account_private_key_table = new AccountPrivateKey(this);
        this.account_secret_backup_table = new AccountSecretBackup(this);
        this.pending_secret_backup_cleanup_table = new PendingSecretBackupCleanup(this);
        init({account_setting_table, contact_key_table, published_key_table, pending_xmpp_key_retraction_table,
                account_private_key_table, account_secret_backup_table, pending_secret_backup_cleanup_table}, key);

        try {
            exec("PRAGMA journal_mode = WAL");
            exec("PRAGMA synchronous = NORMAL");
            exec("PRAGMA secure_delete = ON");
        } catch (Error e) {
            error("Failed to set OpenPGP database properties: %s", e.message);
        }
    }

    public void set_contact_key(Account account, Jid jid, string key, string source = KEY_SOURCE_UNKNOWN, bool supports_xep0374 = false, bool legacy_announced = false) {
        string existing_source = get_contact_key_source(account, jid);
        bool existing_supports_xep0374 = contact_supports_xep0374(account, jid);
        string? legacy_key = get_contact_legacy_key(account, jid);
        string? xmpp_key = get_contact_xmpp_key(account, jid);
        bool existing_legacy_announced = contact_legacy_key_is_announced(account, jid);
        bool stored_legacy_announced = existing_legacy_announced;
        string stored_xmpp_trust_state = get_contact_xmpp_trust_state(account, jid);
        string? stored_xmpp_verified_fingerprint = get_contact_xmpp_verified_fingerprint(account, jid);
        long stored_xmpp_trust_updated_at = get_contact_xmpp_trust_updated_at(account, jid);

        string stored_source = source;
        if (stored_source == KEY_SOURCE_UNKNOWN && existing_source != KEY_SOURCE_UNKNOWN) {
            stored_source = existing_source;
        }
        if (source == KEY_SOURCE_XEP0373) {
            bool changed_xmpp_key = xmpp_key == null || !fingerprint_or_keyid_matches((!) xmpp_key, key);
            if (stored_xmpp_verified_fingerprint != null && ((!) stored_xmpp_verified_fingerprint).length > 0) {
                if (fingerprint_or_keyid_matches((!) stored_xmpp_verified_fingerprint, key)) {
                    if (stored_xmpp_trust_state != XMPP_TRUST_VERIFIED) {
                        stored_xmpp_trust_updated_at = now_unix();
                    }
                    stored_xmpp_trust_state = XMPP_TRUST_VERIFIED;
                } else {
                    if (stored_xmpp_trust_state != XMPP_TRUST_CHANGED || changed_xmpp_key) {
                        stored_xmpp_trust_updated_at = now_unix();
                    }
                    stored_xmpp_trust_state = XMPP_TRUST_CHANGED;
                }
            } else {
                if (changed_xmpp_key) stored_xmpp_trust_updated_at = now_unix();
                stored_xmpp_trust_state = XMPP_TRUST_UNVERIFIED;
                stored_xmpp_verified_fingerprint = null;
            }
            xmpp_key = key;
        } else if (is_legacy_source(source)) {
            bool same_legacy_key = legacy_key != null && fingerprint_or_keyid_matches((!) legacy_key, key);
            legacy_key = key;
            if (source == KEY_SOURCE_XEP0027 || legacy_announced) {
                stored_legacy_announced = true;
            } else if (!same_legacy_key) {
                stored_legacy_announced = false;
            }
        }

        contact_key_table.upsert()
                .value(contact_key_table.account_id, account.id, true)
                .value(contact_key_table.jid, jid.to_string(), true)
                .value(contact_key_table.key, key)
                .value(contact_key_table.source, stored_source)
                .value(contact_key_table.supports_xep0374, supports_xep0374 || existing_supports_xep0374)
                .value(contact_key_table.legacy_key, legacy_key)
                .value(contact_key_table.xmpp_key, xmpp_key)
                .value(contact_key_table.legacy_announced, stored_legacy_announced)
                .value(contact_key_table.xmpp_trust_state, stored_xmpp_trust_state)
                .value(contact_key_table.xmpp_verified_fingerprint, stored_xmpp_verified_fingerprint)
                .value(contact_key_table.xmpp_trust_updated_at, stored_xmpp_trust_updated_at)
                .perform();
    }

    public string? get_contact_key(Account account, Jid jid) {
        return contact_key_table.select({contact_key_table.key})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.key];
    }

    public string get_contact_key_source(Account account, Jid jid) {
        string? source = contact_key_table.select({contact_key_table.source})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.source];
        return source ?? KEY_SOURCE_UNKNOWN;
    }

    public string? get_contact_legacy_key(Account account, Jid jid) {
        string? key = contact_key_table.select({contact_key_table.legacy_key})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.legacy_key];
        if (key != null && key.length > 0) return key;
        return null;
    }

    public string? get_contact_xmpp_key(Account account, Jid jid) {
        string? key = contact_key_table.select({contact_key_table.xmpp_key})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.xmpp_key];
        if (key != null && key.length > 0) return key;
        return null;
    }

    public string? get_contact_key_for_mode(Account account, Jid jid, string account_key_mode) {
        if (account_key_mode == ACCOUNT_KEY_MODE_LEGACY) return get_contact_legacy_key(account, jid);
        return get_contact_xmpp_key(account, jid);
    }

    public bool has_contact_legacy_key(Account account, Jid jid) {
        string? key = get_contact_legacy_key(account, jid);
        return key != null && key.length > 0;
    }

    public bool contact_legacy_key_matches(Account account, Jid jid, string key_id) {
        string? key = get_contact_legacy_key(account, jid);
        return key != null && fingerprint_or_keyid_matches((!) key, key_id);
    }

    public bool contact_legacy_key_is_announced(Account account, Jid jid) {
        bool? announced = contact_key_table.select({contact_key_table.legacy_announced})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.legacy_announced];
        return announced ?? false;
    }

    public void set_contact_legacy_key_announced(Account account, Jid jid, bool announced) {
        contact_key_table.update()
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .set(contact_key_table.legacy_announced, announced)
            .perform();
    }

    public void clear_contact_legacy_key_announcements(Account? account = null) {
        var update = contact_key_table.update()
            .set(contact_key_table.legacy_announced, false);
        if (account != null) {
            update.with(contact_key_table.account_id, "=", ((!) account).id);
        }
        update.perform();
    }

    public bool has_contact_xmpp_key(Account account, Jid jid) {
        string? key = get_contact_xmpp_key(account, jid);
        return key != null && key.length > 0;
    }

    public string get_contact_xmpp_trust_state(Account account, Jid jid) {
        string? state = contact_key_table.select({contact_key_table.xmpp_trust_state})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.xmpp_trust_state];
        return normalize_xmpp_trust_state(state);
    }

    public string? get_contact_xmpp_verified_fingerprint(Account account, Jid jid) {
        string? fingerprint = contact_key_table.select({contact_key_table.xmpp_verified_fingerprint})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.xmpp_verified_fingerprint];
        if (fingerprint != null && fingerprint.length > 0) return fingerprint;
        return null;
    }

    public long get_contact_xmpp_trust_updated_at(Account account, Jid jid) {
        long? updated_at = contact_key_table.select({contact_key_table.xmpp_trust_updated_at})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.xmpp_trust_updated_at];
        return updated_at ?? 0;
    }

    public void mark_contact_xmpp_key_verified(Account account, Jid jid) {
        string? xmpp_key = get_contact_xmpp_key(account, jid);
        if (xmpp_key == null || ((!) xmpp_key).length == 0) return;

        contact_key_table.update()
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .set(contact_key_table.xmpp_trust_state, XMPP_TRUST_VERIFIED)
            .set(contact_key_table.xmpp_verified_fingerprint, (!) xmpp_key)
            .set(contact_key_table.xmpp_trust_updated_at, now_unix())
            .perform();
    }

    public bool contact_xmpp_key_is_verified(Account account, Jid jid) {
        string? xmpp_key = get_contact_xmpp_key(account, jid);
        string? verified_fingerprint = get_contact_xmpp_verified_fingerprint(account, jid);
        if (xmpp_key == null || verified_fingerprint == null) return false;
        if (get_contact_xmpp_trust_state(account, jid) != XMPP_TRUST_VERIFIED) return false;
        return fingerprint_or_keyid_matches((!) verified_fingerprint, (!) xmpp_key);
    }

    public void reset_contact_xmpp_key_verification(Account account, Jid jid) {
        contact_key_table.update()
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .set(contact_key_table.xmpp_trust_state, XMPP_TRUST_UNVERIFIED)
            .set_null(contact_key_table.xmpp_verified_fingerprint)
            .set(contact_key_table.xmpp_trust_updated_at, now_unix())
            .perform();
    }

    public void clear_contact_xmpp_key(Account account, Jid jid) {
        contact_key_table.update()
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .set(contact_key_table.source, KEY_SOURCE_UNKNOWN)
            .set_null(contact_key_table.xmpp_key)
            .set(contact_key_table.xmpp_trust_state, XMPP_TRUST_UNVERIFIED)
            .set(contact_key_table.xmpp_trust_updated_at, now_unix())
            .perform();
    }

    public bool clear_contact_xmpp_key_if_matches(Account account, Jid jid, string key_id) {
        string? current_key = get_contact_xmpp_key(account, jid);
        if (current_key == null || !fingerprint_or_keyid_matches((!) current_key, key_id)) {
            return false;
        }

        clear_contact_xmpp_key(account, jid);
        return true;
    }

    public void clear_contact_legacy_key(Account account, Jid jid) {
        contact_key_table.update()
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .set(contact_key_table.source, KEY_SOURCE_UNKNOWN)
            .set_null(contact_key_table.legacy_key)
            .set(contact_key_table.legacy_announced, false)
            .perform();
    }

    public bool contact_supports_xep0374(Account account, Jid jid) {
        bool? supports = contact_key_table.select({contact_key_table.supports_xep0374})
            .with(contact_key_table.account_id, "=", account.id)
            .with(contact_key_table.jid, "=", jid.to_string())
            .single()[contact_key_table.supports_xep0374];
        return supports ?? false;
    }

    public void set_contact_supports_xep0374(Account account, Jid jid, bool supports) {
        string? stored_key = get_contact_key(account, jid);
        string? legacy_key = get_contact_legacy_key(account, jid);
        string? xmpp_key = get_contact_xmpp_key(account, jid);
        if (stored_key == null || ((!) stored_key).length == 0) {
            stored_key = xmpp_key ?? legacy_key ?? "";
        }

        contact_key_table.upsert()
            .value(contact_key_table.account_id, account.id, true)
            .value(contact_key_table.jid, jid.to_string(), true)
            .value(contact_key_table.key, stored_key)
            .value(contact_key_table.source, get_contact_key_source(account, jid))
            .value(contact_key_table.supports_xep0374, supports)
            .value(contact_key_table.legacy_key, legacy_key)
            .value(contact_key_table.xmpp_key, xmpp_key)
            .value(contact_key_table.legacy_announced, contact_legacy_key_is_announced(account, jid))
            .value(contact_key_table.xmpp_trust_state, get_contact_xmpp_trust_state(account, jid))
            .value(contact_key_table.xmpp_verified_fingerprint, get_contact_xmpp_verified_fingerprint(account, jid))
            .value(contact_key_table.xmpp_trust_updated_at, get_contact_xmpp_trust_updated_at(account, jid))
            .perform();
    }

    public void bind_private_key_to_account(Account account, string fingerprint) {
        string normalized = normalize_key_match_value(fingerprint);
        account_private_key_table.upsert()
            .value(account_private_key_table.token, "%d:%s".printf(account.id, normalized), true)
            .value(account_private_key_table.account_id, account.id)
            .value(account_private_key_table.fingerprint, normalized)
            .perform();
    }

    public Gee.List<string> get_account_private_key_bindings(Account account) {
        var result = new ArrayList<string>();
        foreach (Qlite.Row row in account_private_key_table.select()
                .with(account_private_key_table.account_id, "=", account.id)) {
            result.add(row[account_private_key_table.fingerprint]);
        }
        return result;
    }

    public void unbind_private_key(string fingerprint) {
        account_private_key_table.delete()
            .with(account_private_key_table.fingerprint, "=", normalize_key_match_value(fingerprint)).perform();
    }

    public void unbind_private_key_from_account(Account account, string fingerprint) {
        account_private_key_table.delete()
            .with(account_private_key_table.account_id, "=", account.id)
            .with(account_private_key_table.fingerprint, "=", normalize_key_match_value(fingerprint)).perform();
    }

    public bool key_has_other_account_users(Account account, string fingerprint, Gee.Set<int>? existing_account_ids = null) {
        foreach (Qlite.Row row in account_setting_table.select()
                .with(account_setting_table.account_id, "!=", account.id)) {
            if (existing_account_ids != null && !existing_account_ids.contains(row[account_setting_table.account_id])) continue;
            string? xmpp_key = row[account_setting_table.xmpp_key];
            string? legacy_key = row[account_setting_table.legacy_key];
            string? selected = row[account_setting_table.key];
            if ((xmpp_key != null && fingerprint_or_keyid_matches((!) xmpp_key, fingerprint)) ||
                    (legacy_key != null && fingerprint_or_keyid_matches((!) legacy_key, fingerprint)) ||
                    (selected != null && fingerprint_or_keyid_matches((!) selected, fingerprint))) return true;
        }
        foreach (Qlite.Row row in account_private_key_table.select()
            .with(account_private_key_table.account_id, "!=", account.id)
            .with(account_private_key_table.fingerprint, "=", normalize_key_match_value(fingerprint))) {
            if (existing_account_ids == null || existing_account_ids.contains(row[account_private_key_table.account_id])) return true;
        }
        return false;
    }

    public void remember_secret_key_backup(Account account, string payload, Gee.Collection<string> fingerprints) {
        var normalized = new ArrayList<string>();
        foreach (string fingerprint in fingerprints) {
            string value = normalize_key_match_value(fingerprint);
            if (!normalized.contains(value)) normalized.add(value);
        }
        // Keep the native string vector typed; Gee's generic to_array() returns
        // gpointer* at the C boundary with the Windows Vala toolchain.
        string[] fingerprint_values = new string[normalized.size];
        int index = 0;
        foreach (string value in normalized) fingerprint_values[index++] = value;
        account_secret_backup_table.upsert()
            .value(account_secret_backup_table.account_id, account.id, true)
            .value(account_secret_backup_table.digest, Checksum.compute_for_string(ChecksumType.SHA256, payload))
            .value(account_secret_backup_table.fingerprints, string.joinv("\n", fingerprint_values))
            .perform();
        clear_pending_secret_key_backup_cleanup(account);
    }

    public Gee.List<string>? get_secret_key_backup_fingerprints(Account account, string payload) {
        string? digest = account_secret_backup_table.select()
            .with(account_secret_backup_table.account_id, "=", account.id)[account_secret_backup_table.digest];
        if (digest == null || digest != Checksum.compute_for_string(ChecksumType.SHA256, payload)) return null;
        string? fingerprints = account_secret_backup_table.select()
            .with(account_secret_backup_table.account_id, "=", account.id)[account_secret_backup_table.fingerprints];
        if (fingerprints == null || ((!) fingerprints).length == 0) return null;
        var result = new ArrayList<string>();
        foreach (string fingerprint in ((!) fingerprints).split("\n")) result.add(fingerprint);
        return result;
    }

    public string? get_secret_key_backup_observation_digest(Account account) {
        return account_secret_backup_table.select()
            .with(account_secret_backup_table.account_id, "=", account.id)[account_secret_backup_table.digest];
    }

    public void forget_secret_key_backup(Account account) {
        account_secret_backup_table.delete().with(account_secret_backup_table.account_id, "=", account.id).perform();
        clear_pending_secret_key_backup_cleanup(account);
    }

    public void mark_pending_secret_key_backup_cleanup(Account account, string fingerprint, string payload) {
        pending_secret_backup_cleanup_table.upsert()
            .value(pending_secret_backup_cleanup_table.account_id, account.id, true)
            .value(pending_secret_backup_cleanup_table.fingerprint, normalize_key_match_value(fingerprint))
            .value(pending_secret_backup_cleanup_table.digest, Checksum.compute_for_string(ChecksumType.SHA256, payload))
            .perform();
    }

    public string? get_pending_secret_key_backup_cleanup_fingerprint(Account account) {
        return pending_secret_backup_cleanup_table.select()
            .with(pending_secret_backup_cleanup_table.account_id, "=", account.id)
            [pending_secret_backup_cleanup_table.fingerprint];
    }

    public string? get_pending_secret_key_backup_cleanup_digest(Account account) {
        return pending_secret_backup_cleanup_table.select()
            .with(pending_secret_backup_cleanup_table.account_id, "=", account.id)
            [pending_secret_backup_cleanup_table.digest];
    }

    public void clear_pending_secret_key_backup_cleanup(Account account) {
        pending_secret_backup_cleanup_table.delete()
            .with(pending_secret_backup_cleanup_table.account_id, "=", account.id).perform();
    }

    public void set_account_key(Account account, string key, string key_mode = ACCOUNT_KEY_MODE_XMPP) {
        if (key_mode == ACCOUNT_KEY_MODE_LEGACY) {
            set_account_legacy_key(account, key);
        } else {
            set_account_xmpp_key(account, key);
        }
    }

    public void set_account_xmpp_key(Account account, string key) {
        string? legacy_key = get_account_legacy_key(account);
        upsert_account_key(account, key, ACCOUNT_KEY_MODE_XMPP, legacy_key, key);
    }

    public void set_account_legacy_key(Account account, string key) {
        string? xmpp_key = get_account_xmpp_key(account);
        upsert_account_key(account, key, ACCOUNT_KEY_MODE_LEGACY, key, xmpp_key);
    }

    private void upsert_account_key(Account account, string selected_key, string key_mode, string? legacy_key, string? xmpp_key) {
        account_setting_table.upsert()
                .value(account_setting_table.account_id, account.id, true)
                .value(account_setting_table.key, selected_key)
                .value(account_setting_table.key_mode, key_mode)
                .value(account_setting_table.legacy_key, legacy_key)
                .value(account_setting_table.xmpp_key, xmpp_key)
                .perform();
    }

    public string? get_account_key(Account account) {
        string mode = get_account_key_mode(account);
        return get_account_key_for_mode(account, mode);
    }

    public string? get_account_key_for_mode(Account account, string key_mode) {
        if (key_mode == ACCOUNT_KEY_MODE_LEGACY) return get_account_legacy_key(account);
        return get_account_xmpp_key(account);
    }

    public string? get_account_legacy_key(Account account) {
        string? key = account_setting_table.select({account_setting_table.legacy_key})
            .with(account_setting_table.account_id, "=", account.id)[account_setting_table.legacy_key];
        if (key != null && key.length > 0) return key;

        if (get_account_key_mode(account) != ACCOUNT_KEY_MODE_LEGACY) return null;

        string? legacy_fallback = account_setting_table.select({account_setting_table.key})
            .with(account_setting_table.account_id, "=", account.id)[account_setting_table.key];
        if (legacy_fallback != null && legacy_fallback.length > 0) return legacy_fallback;

        return null;
    }

    public string? get_account_legacy_key_for_presence(Account account) {
        if (get_account_key_mode(account) != ACCOUNT_KEY_MODE_LEGACY) return null;
        return get_account_legacy_key(account);
    }

    public string? get_account_xmpp_key(Account account) {
        string? key = account_setting_table.select({account_setting_table.xmpp_key})
            .with(account_setting_table.account_id, "=", account.id)[account_setting_table.xmpp_key];
        if (key != null && key.length > 0) return key;

        return null;
    }

    public void remove_account_key(Account account) {
        account_setting_table.delete()
            .with(account_setting_table.account_id, "=", account.id)
            .perform();
    }

    public void remove_account_key_for_mode(Account account, string key_mode) {
        if (key_mode == ACCOUNT_KEY_MODE_LEGACY) {
            remove_account_legacy_key(account);
        } else {
            remove_account_xmpp_key(account);
        }
    }

    public void remove_account_legacy_key(Account account) {
        string? xmpp_key = get_account_xmpp_key(account);
        if (xmpp_key != null && xmpp_key.length > 0) {
            upsert_account_key(account, (!) xmpp_key, ACCOUNT_KEY_MODE_XMPP, null, xmpp_key);
            return;
        }
        remove_account_key(account);
    }

    public void remove_account_xmpp_key(Account account) {
        string? legacy_key = get_account_legacy_key(account);
        if (legacy_key != null && legacy_key.length > 0) {
            upsert_account_key(account, (!) legacy_key, ACCOUNT_KEY_MODE_LEGACY, legacy_key, null);
            return;
        }
        remove_account_key(account);
    }

    public string get_account_key_mode(Account account) {
        string? mode = account_setting_table.select({account_setting_table.key_mode})
            .with(account_setting_table.account_id, "=", account.id)[account_setting_table.key_mode];
        if (mode == ACCOUNT_KEY_MODE_LEGACY) return ACCOUNT_KEY_MODE_LEGACY;
        return ACCOUNT_KEY_MODE_XMPP;
    }

    public static bool is_legacy_source(string source) {
        return source == KEY_SOURCE_XEP0027 ||
            source == KEY_SOURCE_KEYSERVER ||
            source == KEY_SOURCE_MANUAL;
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

    private static string normalize_xmpp_trust_state(string? state) {
        if (state == XMPP_TRUST_VERIFIED) return XMPP_TRUST_VERIFIED;
        if (state == XMPP_TRUST_CHANGED) return XMPP_TRUST_CHANGED;
        return XMPP_TRUST_UNVERIFIED;
    }

    private static long now_unix() {
        return (long) new DateTime.now_utc().to_unix();
    }

    // Mark a key as published to keyserver
    public void set_key_published(string fingerprint, string keyserver = "hkps://keys.openpgp.org") {
        published_key_table.upsert()
                .value(published_key_table.fingerprint, fingerprint, true)
                .value(published_key_table.keyserver, keyserver)
                .value(published_key_table.published_at, new DateTime.now_utc().to_unix())
                .perform();
    }

    // Check if a key has been published to keyserver
    public bool is_key_published(string fingerprint) {
        var row = published_key_table.select()
            .with(published_key_table.fingerprint, "=", fingerprint)
            .single()
            .row();
        return row != null;
    }

    // Get keyserver URL where key was published
    public string? get_key_keyserver(string fingerprint) {
        return published_key_table.select({published_key_table.keyserver})
            .with(published_key_table.fingerprint, "=", fingerprint)[published_key_table.keyserver];
    }

    public void mark_pending_xmpp_key_retraction(Account account, string fingerprint) {
        if (fingerprint.length == 0) return;
        string normalized_fingerprint = normalize_key_match_value(fingerprint);
        if (normalized_fingerprint.length == 0) return;
        pending_xmpp_key_retraction_table.upsert()
                .value(pending_xmpp_key_retraction_table.token, pending_xmpp_key_retraction_token(account, normalized_fingerprint), true)
                .value(pending_xmpp_key_retraction_table.account_id, account.id)
                .value(pending_xmpp_key_retraction_table.fingerprint, normalized_fingerprint)
                .value(pending_xmpp_key_retraction_table.created_at, (long) new DateTime.now_utc().to_unix())
                .perform();
    }

    public void clear_pending_xmpp_key_retraction(Account account, string fingerprint) {
        pending_xmpp_key_retraction_table.delete()
            .with(pending_xmpp_key_retraction_table.token, "=", pending_xmpp_key_retraction_token(account, fingerprint))
            .perform();
    }

    public Gee.List<string> get_pending_xmpp_key_retractions(Account account) {
        var fingerprints = new ArrayList<string>();
        foreach (Qlite.Row row in pending_xmpp_key_retraction_table.select({pending_xmpp_key_retraction_table.fingerprint})
                .with(pending_xmpp_key_retraction_table.account_id, "=", account.id)) {
            string fingerprint = row[pending_xmpp_key_retraction_table.fingerprint];
            if (fingerprint.length > 0) fingerprints.add(fingerprint);
        }
        return fingerprints;
    }

    private static string pending_xmpp_key_retraction_token(Account account, string fingerprint) {
        return "%d:%s".printf(account.id, normalize_key_match_value(fingerprint));
    }

    public override void migrate(long oldVersion) {
        if (oldVersion < 1) {
            // Version 1: Added published_key table (auto-created by init)
        }
        if (oldVersion < 4) {
            try {
                exec("UPDATE contact_key SET legacy_key = key WHERE source IN ('xep0027', 'keyserver', 'manual') AND (legacy_key IS NULL OR legacy_key = '')");
                exec("UPDATE contact_key SET xmpp_key = key WHERE source = 'xep0373' AND (xmpp_key IS NULL OR xmpp_key = '')");
            } catch (Error e) {
                warning("OpenPGP DB migration v4 failed: %s", e.message);
            }
        }
        if (oldVersion < 5) {
            try {
                exec("UPDATE account_setting SET legacy_key = key WHERE key_mode = 'legacy' AND (legacy_key IS NULL OR legacy_key = '')");
                exec("UPDATE account_setting SET xmpp_key = key WHERE (key_mode IS NULL OR key_mode != 'legacy') AND (xmpp_key IS NULL OR xmpp_key = '')");
            } catch (Error e) {
                warning("OpenPGP DB migration v5 failed: %s", e.message);
            }
        }
        if (oldVersion < 6) {
            try {
                // A key that was uploaded to a keyserver
                // but stored as the XMPP active key by older builds is legacy-active,
                // not an OpenPGP-for-XMPP publication.
                exec("UPDATE account_setting SET legacy_key = xmpp_key, key = xmpp_key, key_mode = 'legacy', xmpp_key = NULL " +
                    "WHERE (key_mode IS NULL OR key_mode != 'legacy') " +
                    "AND (legacy_key IS NULL OR legacy_key = '') " +
                    "AND xmpp_key IN (SELECT fingerprint FROM published_key)");
            } catch (Error e) {
                warning("OpenPGP DB migration v6 failed: %s", e.message);
            }
        }
        if (oldVersion < 7) {
            try {
                exec("UPDATE account_setting SET legacy_key = key WHERE key_mode = 'legacy' AND (legacy_key IS NULL OR legacy_key = '') AND key IS NOT NULL AND key != ''");
                exec("UPDATE account_setting SET key = legacy_key, key_mode = 'legacy' WHERE (key_mode IS NULL OR key_mode != 'legacy') AND (xmpp_key IS NULL OR xmpp_key = '') AND legacy_key IS NOT NULL AND legacy_key != ''");
                exec("UPDATE account_setting SET key = xmpp_key, key_mode = 'xmpp' WHERE key_mode = 'legacy' AND (legacy_key IS NULL OR legacy_key = '') AND xmpp_key IS NOT NULL AND xmpp_key != ''");
                exec("UPDATE account_setting SET legacy_key = key, key_mode = 'legacy' WHERE (key_mode IS NULL OR key_mode != 'legacy') AND (xmpp_key IS NULL OR xmpp_key = '') AND (legacy_key IS NULL OR legacy_key = '') AND key IN (SELECT fingerprint FROM published_key)");
            } catch (Error e) {
                warning("OpenPGP DB migration v7 failed: %s", e.message);
            }
        }
        if (oldVersion < 8) {
            try {
                // Existing legacy contact keys are preserved but not treated as
                // currently announced until a fresh signed XEP-0027 presence is seen.
                exec("UPDATE contact_key SET legacy_announced = 0 WHERE legacy_announced IS NULL");
            } catch (Error e) {
                warning("OpenPGP DB migration v8 failed: %s", e.message);
            }
        }
        if (oldVersion < 9) {
            // Version 9: Added pending_xmpp_key_retraction table.
        }
        if (oldVersion < 10) {
            try {
                exec("DROP TABLE IF EXISTS contact_key_v10");
                exec("""
                    CREATE TABLE contact_key_v10 (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        account_id INTEGER NOT NULL,
                        jid TEXT NOT NULL,
                        key TEXT NOT NULL,
                        source TEXT DEFAULT 'unknown',
                        supports_xep0374 INTEGER DEFAULT 0,
                        legacy_key TEXT,
                        xmpp_key TEXT,
                        legacy_announced INTEGER DEFAULT 0,
                        xmpp_trust_state TEXT DEFAULT 'unverified',
                        xmpp_verified_fingerprint TEXT,
                        xmpp_trust_updated_at INTEGER DEFAULT 0,
                        UNIQUE (account_id, jid) ON CONFLICT REPLACE
                    )
                """);
                // Old contact_key rows were global and cannot be attributed
                // safely once multiple OpenPGP accounts exist. Preserve them
                // only for the unambiguous single-account case.
                exec("""
                    INSERT INTO contact_key_v10 (account_id, jid, key, source, supports_xep0374, legacy_key, xmpp_key, legacy_announced, xmpp_trust_state, xmpp_verified_fingerprint, xmpp_trust_updated_at)
                    SELECT
                        account_setting.account_id,
                        contact_key.jid,
                        contact_key.key,
                        COALESCE(contact_key.source, 'unknown'),
                        COALESCE(contact_key.supports_xep0374, 0),
                        contact_key.legacy_key,
                        contact_key.xmpp_key,
                        COALESCE(contact_key.legacy_announced, 0),
                        'unverified',
                        NULL,
                        0
                    FROM contact_key
                    JOIN account_setting
                    WHERE (SELECT COUNT(*) FROM account_setting) = 1
                """);
                exec("DROP TABLE contact_key");
                exec("ALTER TABLE contact_key_v10 RENAME TO contact_key");
            } catch (Error e) {
                error("OpenPGP DB migration v10 failed: %s", e.message);
            }
        }
        if (oldVersion < 11) {
            try {
                exec("DROP TABLE IF EXISTS contact_key_v11");
                exec("""
                    CREATE TABLE contact_key_v11 (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        account_id INTEGER NOT NULL,
                        jid TEXT NOT NULL,
                        key TEXT NOT NULL,
                        source TEXT DEFAULT 'unknown',
                        supports_xep0374 INTEGER DEFAULT 0,
                        legacy_key TEXT,
                        xmpp_key TEXT,
                        legacy_announced INTEGER DEFAULT 0,
                        xmpp_trust_state TEXT DEFAULT 'unverified',
                        xmpp_verified_fingerprint TEXT,
                        xmpp_trust_updated_at INTEGER DEFAULT 0,
                        UNIQUE (account_id, jid) ON CONFLICT REPLACE
                    )
                """);
                exec("""
                    INSERT INTO contact_key_v11 (id, account_id, jid, key, source, supports_xep0374, legacy_key, xmpp_key, legacy_announced, xmpp_trust_state, xmpp_verified_fingerprint, xmpp_trust_updated_at)
                    SELECT
                        id,
                        account_id,
                        jid,
                        key,
                        COALESCE(source, 'unknown'),
                        COALESCE(supports_xep0374, 0),
                        legacy_key,
                        xmpp_key,
                        COALESCE(legacy_announced, 0),
                        'unverified',
                        NULL,
                        0
                    FROM contact_key
                """);
                exec("DROP TABLE contact_key");
                exec("ALTER TABLE contact_key_v11 RENAME TO contact_key");
            } catch (Error e) {
                error("OpenPGP DB migration v11 failed: %s", e.message);
            }
        }
    }
}

}
