using Gee;

namespace Dino.Plugins.BotFeatures {

public class BotRegistry : Qlite.Database {
    private const int VERSION = 3;
    private const int GCM_IV_SIZE = 12;
    private const int GCM_TAG_SIZE = 16;
    private const string ENC_PREFIX = "ENC:";
    private const string BOT_PASSWORD_KEY_PREFIX = "bot_secret_password:";
    private const string WEBHOOK_SECRET_KEY_PREFIX = "bot_webhook_secret:";

    private uint8[]? _enc_key = null;

    // Fired after a bot is deleted, with the owner JID, bot ID, and bot details
    public signal void bot_deleted(string owner_jid, int bot_id, string? bot_jid, string? bot_mode);

    // Fired when per-account Botmother is toggled on/off
    public signal void account_toggled(string account_jid, bool enabled);

    // Fired when a bot's status changes (active/disabled)
    public signal void bot_status_changed(int bot_id, string new_status);

    // --- Bot Table ---
    public class BotTable : Qlite.Table {
        public Qlite.Column<int> id = new Qlite.Column.Integer("id") { primary_key = true, auto_increment = true };
        public Qlite.Column<string> name_ = new Qlite.Column.Text("name") { not_null = true };
        public Qlite.Column<string> jid = new Qlite.Column.Text("jid");
        public Qlite.Column<string> token_hash = new Qlite.Column.Text("token_hash") { unique = true };
        public Qlite.Column<string> token_raw = new Qlite.Column.Text("token_raw") { min_version = 2 };
        public Qlite.Column<string> owner_jid = new Qlite.Column.Text("owner_jid") { not_null = true };
        public Qlite.Column<string> description = new Qlite.Column.Text("description");
        public Qlite.Column<string> permissions = new Qlite.Column.Text("permissions") { @default = "'all'" };
        public Qlite.Column<string> status = new Qlite.Column.Text("status") { @default = "'active'" };
        public Qlite.Column<string> mode = new Qlite.Column.Text("mode") { @default = "'personal'" };
        public Qlite.Column<long> created_at = new Qlite.Column.Long("created_at");
        public Qlite.Column<long> last_active = new Qlite.Column.Long("last_active");
        public Qlite.Column<string> webhook_url = new Qlite.Column.Text("webhook_url");
        public Qlite.Column<string> webhook_secret = new Qlite.Column.Text("webhook_secret");
        public Qlite.Column<bool> webhook_enabled = new Qlite.Column.BoolInt("webhook_enabled");
        public Qlite.Column<string> bot_password = new Qlite.Column.Text("bot_password") { min_version = 3 };

        internal BotTable(Qlite.Database db) {
            base(db, "bot");
            init({id, name_, jid, token_hash, token_raw, owner_jid, description, permissions, status, mode,
                  created_at, last_active, webhook_url, webhook_secret, webhook_enabled, bot_password});
        }
    }

    // --- Bot Commands Table ---
    public class BotCommandTable : Qlite.Table {
        public Qlite.Column<int> id = new Qlite.Column.Integer("id") { primary_key = true, auto_increment = true };
        public Qlite.Column<int> bot_id = new Qlite.Column.Integer("bot_id") { not_null = true };
        public Qlite.Column<string> command = new Qlite.Column.Text("command") { not_null = true };
        public Qlite.Column<string> description = new Qlite.Column.Text("description");

        internal BotCommandTable(Qlite.Database db) {
            base(db, "bot_command");
            init({id, bot_id, command, description});
        }
    }

    // --- Update Queue Table (for getUpdates long-poll) ---
    public class UpdateTable : Qlite.Table {
        public Qlite.Column<int> id = new Qlite.Column.Integer("id") { primary_key = true, auto_increment = true };
        public Qlite.Column<int> bot_id = new Qlite.Column.Integer("bot_id") { not_null = true };
        public Qlite.Column<string> update_type = new Qlite.Column.Text("update_type") { not_null = true };
        public Qlite.Column<string> payload = new Qlite.Column.Text("payload") { not_null = true };
        public Qlite.Column<long> created_at = new Qlite.Column.Long("created_at");

        internal UpdateTable(Qlite.Database db) {
            base(db, "update_queue");
            init({id, bot_id, update_type, payload, created_at});
        }
    }

    // --- Settings Table ---
    public class SettingsTable : Qlite.Table {
        public Qlite.Column<string> key_ = new Qlite.Column.Text("key") { primary_key = true };
        public Qlite.Column<string> value_ = new Qlite.Column.Text("value");

        internal SettingsTable(Qlite.Database db) {
            base(db, "settings");
            init({key_, value_});
        }
    }

    // --- Audit Log Table ---
    public class AuditLogTable : Qlite.Table {
        public Qlite.Column<int> id = new Qlite.Column.Integer("id") { primary_key = true, auto_increment = true };
        public Qlite.Column<int> bot_id = new Qlite.Column.Integer("bot_id");
        public Qlite.Column<string> action = new Qlite.Column.Text("action") { not_null = true };
        public Qlite.Column<string> details = new Qlite.Column.Text("details");
        public Qlite.Column<string> ip_address = new Qlite.Column.Text("ip_address");
        public Qlite.Column<long> timestamp = new Qlite.Column.Long("timestamp");

        internal AuditLogTable(Qlite.Database db) {
            base(db, "audit_log");
            init({id, bot_id, action, details, ip_address, timestamp});
        }
    }

    public BotTable bot;
    public BotCommandTable bot_command;
    public UpdateTable update_queue;
    public SettingsTable settings;
    public AuditLogTable audit_log;

    public BotRegistry(string db_path, string? key = null) throws Error {
        base(db_path, VERSION);
        bot = new BotTable(this);
        bot_command = new BotCommandTable(this);
        update_queue = new UpdateTable(this);
        settings = new SettingsTable(this);
        audit_log = new AuditLogTable(this);
        init({bot, bot_command, update_queue, settings, audit_log}, key);

        try {
            exec("PRAGMA journal_mode = WAL");
            exec("PRAGMA synchronous = NORMAL");
            exec("PRAGMA secure_delete = ON");
        } catch (Error e) {
            warning("BotRegistry: PRAGMA error: %s", e.message);
        }
    }

    // --- Bot CRUD ---

    public int create_bot(string name, string owner_jid, string token_hash, string mode = "personal",
                          string? jid = null, string? description = null) {
        long now = (long) new DateTime.now_utc().to_unix();
        // BUG-04 fix: perform() returns last_insert_rowid() — no separate SELECT needed
        int64 new_bot_id = bot.insert()
            .value(bot.name_, name)
            .value(bot.owner_jid, owner_jid)
            .value(bot.token_hash, token_hash)
            .value(bot.mode, mode)
            .value(bot.created_at, now)
            .value(bot.last_active, now)
            .value(bot.status, "active")
            .value(bot.jid, jid)
            .value(bot.description, description)
            .value(bot.webhook_enabled, false)
            .perform();
        return (int) new_bot_id;
    }

    public BotInfo? get_bot_by_id(int bot_id) {
        Qlite.RowOption row = bot.row_with(bot.id, bot_id);
        if (row.is_present()) {
            return bot_info_from_row(row.inner);
        }
        return null;
    }

    public BotInfo? get_bot_by_token_hash(string hash) {
        Qlite.RowOption row = bot.select()
            .with(bot.token_hash, "=", hash)
            .single()
            .row();
        if (row.is_present()) {
            return bot_info_from_row(row.inner);
        }
        return null;
    }

    public Gee.List<BotInfo> get_bots_by_owner(string owner_jid) {
        var result = new ArrayList<BotInfo>();
        foreach (Qlite.Row row in bot.select().with(bot.owner_jid, "=", owner_jid)) {
            result.add(bot_info_from_row(row));
        }
        return result;
    }

    public Gee.List<BotInfo> get_all_active_bots() {
        var result = new ArrayList<BotInfo>();
        foreach (Qlite.Row row in bot.select().with(bot.status, "=", "active")) {
            result.add(bot_info_from_row(row));
        }
        return result;
    }

    public Gee.List<BotInfo> get_all_bots() {
        var result = new ArrayList<BotInfo>();
        foreach (Qlite.Row row in bot.select()) {
            result.add(bot_info_from_row(row));
        }
        return result;
    }

    public void update_bot_token_hash(int bot_id, string new_hash) {
        bot.update().with(bot.id, "=", bot_id).set(bot.token_hash, new_hash).perform();
    }

    // BUG-02: update_bot_token_raw() removed — raw tokens are never stored

    public void update_bot_status(int bot_id, string status) {
        bot.update().with(bot.id, "=", bot_id).set(bot.status, status).perform();
    }

    public void update_bot_permissions(int bot_id, string permissions) {
        bot.update().with(bot.id, "=", bot_id).set(bot.permissions, permissions).perform();
    }

    public void update_bot_password(int bot_id, string password) {
        set_secret_setting(bot_password_key(bot_id), password);
        bot.update().with(bot.id, "=", bot_id).set(bot.bot_password, "").perform();
    }

    public void update_bot_last_active(int bot_id) {
        long now = (long) new DateTime.now_utc().to_unix();
        bot.update().with(bot.id, "=", bot_id).set(bot.last_active, now).perform();
    }

    public void set_webhook(int bot_id, string? url, string? secret, bool enabled) {
        if (secret != null && secret != "") {
            set_secret_setting(webhook_secret_key(bot_id), secret);
        } else {
            delete_setting(webhook_secret_key(bot_id));
        }
        bot.update().with(bot.id, "=", bot_id)
            .set(bot.webhook_url, url)
            .set(bot.webhook_secret, "")
            .set(bot.webhook_enabled, enabled)
            .perform();
    }

    public void delete_bot(int bot_id) {
        // Look up owner and bot details before deleting
        string? owner = null;
        string? jid = null;
        string? mode = null;
        BotInfo? info = get_bot_by_id(bot_id);
        if (info != null) {
            owner = info.owner_jid;
            jid = info.jid;
            mode = info.mode;
        }

        bot_command.delete().with(bot_command.bot_id, "=", bot_id).perform();
        update_queue.delete().with(update_queue.bot_id, "=", bot_id).perform();
        delete_bot_settings(bot_id);
        bot.delete().with(bot.id, "=", bot_id).perform();

        if (owner != null) {
            bot_deleted(owner, bot_id, jid, mode);
        }
    }

    public int delete_account_owner_data(string owner_jid) {
        string owner = owner_jid.strip();
        if (owner == "") return 0;

        var bots = get_bots_by_owner(owner);
        foreach (BotInfo info in bots) {
            delete_bot(info.id);
        }
        delete_owner_settings(owner);
        return bots.size;
    }

    public void delete_owner_settings(string owner_jid) {
        string owner = owner_jid.strip();
        if (owner == "") return;

        delete_setting("botmother_account_enabled:" + owner);
        delete_setting(cloudbot_tokens_key(owner));
    }

    private void delete_bot_settings(int bot_id) {
        delete_setting(bot_password_key(bot_id));
        delete_setting(webhook_secret_key(bot_id));
        delete_setting("bot_avatar:%d".printf(bot_id));
        delete_setting("bot_avatar_type:%d".printf(bot_id));
        delete_setting("bot_allowed_targets:%d".printf(bot_id));
        delete_setting("bot_target_mode:%d".printf(bot_id));
        delete_setting("bot_dedicated_provisioning:%d".printf(bot_id));
        delete_setting("bot_%d_purpose".printf(bot_id));
        delete_setting("bot_%d_muc_rooms".printf(bot_id));
        delete_setting("bot_%d_muc_ai_mode".printf(bot_id));
        delete_setting("bot_%d_muc_owner_notify".printf(bot_id));
        delete_setting("bot_ignore_delayed_before:%d".printf(bot_id));

        string ai_prefix = "bot_%d_ai".printf(bot_id);
        delete_setting(ai_prefix + "_enabled");
        delete_setting(ai_prefix + "_provider");
        delete_setting(ai_prefix + "_type");
        delete_setting(ai_prefix + "_endpoint");
        delete_setting(ai_prefix + "_key");
        delete_setting(ai_prefix + "_model");
        delete_setting(ai_prefix + "_system");

        string tg_prefix = "bot_%d_tg".printf(bot_id);
        delete_setting(tg_prefix + "_enabled");
        delete_setting(tg_prefix + "_token");
        delete_setting(tg_prefix + "_chat_id");
        delete_setting(tg_prefix + "_mode");
    }

    // --- Bot Commands CRUD ---

    public void set_bot_commands(int bot_id, Gee.List<CommandInfo> commands) {
        bot_command.delete().with(bot_command.bot_id, "=", bot_id).perform();
        foreach (CommandInfo cmd in commands) {
            bot_command.insert()
                .value(bot_command.bot_id, bot_id)
                .value(bot_command.command, cmd.command)
                .value(bot_command.description, cmd.description)
                .perform();
        }
    }

    public Gee.List<CommandInfo> get_bot_commands(int bot_id) {
        var result = new ArrayList<CommandInfo>();
        foreach (Qlite.Row row in bot_command.select().with(bot_command.bot_id, "=", bot_id)) {
            result.add(new CommandInfo(
                bot_command.command.get(row),
                bot_command.description.get(row)
            ));
        }
        return result;
    }

    // --- Update Queue ---

    public int enqueue_update(int bot_id, string update_type, string payload) {
        long now = (long) new DateTime.now_utc().to_unix();
        // perform() returns last_insert_rowid() — no separate SELECT needed
        int64 new_update_id = update_queue.insert()
            .value(update_queue.bot_id, bot_id)
            .value(update_queue.update_type, update_type)
            .value(update_queue.payload, payload)
            .value(update_queue.created_at, now)
            .perform();
        return (int) new_update_id;
    }

    public Gee.List<UpdateInfo> get_updates(int bot_id, int offset = 0, int limit = 100) {
        var result = new ArrayList<UpdateInfo>();
        foreach (Qlite.Row row in update_queue.select()
                    .with(update_queue.bot_id, "=", bot_id)
                    .with(update_queue.id, ">=", offset)
                    .order_by(update_queue.id, "ASC")
                    .limit(limit)) {
            result.add(new UpdateInfo(
                update_queue.id.get(row),
                update_queue.bot_id.get(row),
                update_queue.update_type.get(row),
                update_queue.payload.get(row),
                update_queue.created_at.get(row)
            ));
        }
        return result;
    }

    public void delete_updates_up_to(int bot_id, int update_id) {
        update_queue.delete()
            .with(update_queue.bot_id, "=", bot_id)
            .with(update_queue.id, "<=", update_id)
            .perform();
    }

    // Cleanup old updates (older than 24h)
    public void cleanup_old_updates() {
        long cutoff = (long) new DateTime.now_utc().to_unix() - 86400;
        update_queue.delete().with(update_queue.created_at, "<", cutoff).perform();
    }

    // --- Settings ---

    public string? get_setting(string key) {
        Qlite.RowOption row = settings.row_with(settings.key_, key);
        if (row.is_present()) {
            return settings.value_.get(row.inner);
        }
        return null;
    }

    public void set_setting(string key, string value) {
        settings.upsert()
            .value(settings.key_, key, true)
            .value(settings.value_, value)
            .perform();
    }

    public void delete_setting(string key) {
        settings.delete().with(settings.key_, "=", key).perform();
    }

    public void delete_settings_like(string pattern) {
        settings.delete().with(settings.key_, "LIKE", pattern).perform();
    }

    public Gee.HashMap<string, string> get_settings_like(string pattern) {
        var result = new Gee.HashMap<string, string>();
        foreach (Qlite.Row row in settings.select().with(settings.key_, "LIKE", pattern)) {
            result[settings.key_.get(row)] = settings.value_.get(row);
        }
        return result;
    }

    private string cloudbot_tokens_key(string account_jid) {
        return "cloudbot_management_tokens:%s".printf(account_jid.strip());
    }

    public Gee.List<string> get_cloudbot_management_tokens(string account_jid) {
        var result = new ArrayList<string>();
        string? stored = get_secret_setting(cloudbot_tokens_key(account_jid));
        if (stored == null || stored == "") return result;

        foreach (string token in stored.split("\n")) {
            string trimmed = token.strip();
            if (trimmed != "" && !result.contains(trimmed)) {
                result.add(trimmed);
            }
        }
        return result;
    }

    public void add_cloudbot_management_token(string account_jid, string token) {
        string trimmed = token.strip();
        if (trimmed == "") return;

        var tokens = get_cloudbot_management_tokens(account_jid);
        if (!tokens.contains(trimmed)) {
            tokens.add(trimmed);
        }
        store_cloudbot_management_tokens(account_jid, tokens);
    }

    public void remove_cloudbot_management_token(string account_jid, string token) {
        string trimmed = token.strip();
        var tokens = get_cloudbot_management_tokens(account_jid);
        tokens.remove(trimmed);
        store_cloudbot_management_tokens(account_jid, tokens);
    }

    private void store_cloudbot_management_tokens(string account_jid, Gee.List<string> tokens) {
        var cleaned = new ArrayList<string>();
        foreach (string token in tokens) {
            string trimmed = token.strip();
            if (trimmed != "" && !cleaned.contains(trimmed)) {
                cleaned.add(trimmed);
            }
        }
        if (cleaned.size == 0) {
            delete_setting(cloudbot_tokens_key(account_jid));
            return;
        }

        var value = new StringBuilder();
        bool first = true;
        foreach (string token in cleaned) {
            if (!first) value.append("\n");
            value.append(token);
            first = false;
        }
        set_secret_setting(cloudbot_tokens_key(account_jid), value.str);
    }

    public void migrate_legacy_bot_secrets() {
        var legacy_passwords = new HashMap<int, string>();
        var legacy_webhook_secrets = new HashMap<int, string>();

        foreach (Qlite.Row row in bot.select()) {
            int bot_id = bot.id.get(row);
            string? password = bot.bot_password.get(row);
            string? webhook = bot.webhook_secret.get(row);
            if (password != null && password != "") {
                legacy_passwords[bot_id] = password;
            }
            if (webhook != null && webhook != "") {
                legacy_webhook_secrets[bot_id] = webhook;
            }
        }

        foreach (int bot_id in legacy_passwords.keys) {
            set_secret_setting(bot_password_key(bot_id), legacy_passwords[bot_id]);
            bot.update().with(bot.id, "=", bot_id).set(bot.bot_password, "").perform();
        }
        foreach (int bot_id in legacy_webhook_secrets.keys) {
            set_secret_setting(webhook_secret_key(bot_id), legacy_webhook_secrets[bot_id]);
            bot.update().with(bot.id, "=", bot_id).set(bot.webhook_secret, "").perform();
        }
    }

    // --- Encrypted Settings ---

    // Lazily derive a 32-byte AES-256 key from server_hmac_key via HMAC-SHA256.
    // Returns null only if server_hmac_key is not yet stored (TokenManager hasn't initialized).
    private uint8[]? get_enc_key() {
        if (_enc_key != null) return _enc_key;
        string? hmac_key = get_setting("server_hmac_key");
        if (hmac_key == null || hmac_key == "") return null;
        var hmac = new GLib.Hmac(ChecksumType.SHA256, (uchar[]) hmac_key.data);
        hmac.update((uchar[]) "dinox-settings-encryption".data);
        size_t len = 32;
        _enc_key = new uint8[len];
        hmac.get_digest(_enc_key, ref len);
        return _enc_key;
    }

    // Store a setting with AES-256-GCM encryption.
    // Falls back to plaintext only if the encryption key is not yet available.
    public void set_secret_setting(string key, string value) {
        uint8[]? enc_key = get_enc_key();
        if (enc_key == null) {
            set_setting(key, value);
            return;
        }
        try {
            uint8[] plaintext = value.data;
            // Generate random IV from two UUID4s (128-bit secure random), take first 12 bytes
            string uuid_hex = GLib.Uuid.string_random().replace("-", "");
            uint8[] iv = new uint8[GCM_IV_SIZE];
            for (int i = 0; i < GCM_IV_SIZE; i++) {
                iv[i] = (uint8) uint64.parse("0x" + uuid_hex.substring(i * 2, 2));
            }

            var cipher = new Crypto.SymmetricCipher("AES-GCM");
            cipher.set_key(enc_key);
            cipher.set_iv(iv);
            uint8[] ciphertext = new uint8[plaintext.length];
            cipher.encrypt(ciphertext, plaintext);
            uint8[] tag = cipher.get_tag(GCM_TAG_SIZE);

            // Pack: IV || ciphertext || tag
            uint8[] packed = new uint8[GCM_IV_SIZE + ciphertext.length + GCM_TAG_SIZE];
            GLib.Memory.copy(packed, iv, GCM_IV_SIZE);
            GLib.Memory.copy((uint8*) packed + GCM_IV_SIZE, ciphertext, ciphertext.length);
            GLib.Memory.copy((uint8*) packed + GCM_IV_SIZE + ciphertext.length, tag, GCM_TAG_SIZE);

            set_setting(key, ENC_PREFIX + GLib.Base64.encode(packed));
        } catch (GLib.Error e) {
            warning("BotRegistry: encrypt error for '%s': %s — storing plaintext", key, e.message);
            set_setting(key, value);
        }
    }

    // Read a setting and decrypt if encrypted. Auto-migrates plaintext values on first read.
    public string? get_secret_setting(string key) {
        string? raw = get_setting(key);
        if (raw == null) return null;

        if (raw.has_prefix(ENC_PREFIX)) {
            uint8[]? enc_key = get_enc_key();
            if (enc_key == null) {
                warning("BotRegistry: cannot decrypt '%s' — no encryption key", key);
                return null;
            }
            try {
                uint8[] packed = GLib.Base64.decode(raw.substring(ENC_PREFIX.length));
                if (packed.length < GCM_IV_SIZE + GCM_TAG_SIZE) {
                    warning("BotRegistry: encrypted data too short for '%s'", key);
                    return null;
                }
                uint8[] iv = packed[0:GCM_IV_SIZE];
                uint8[] ciphertext = packed[GCM_IV_SIZE:packed.length - GCM_TAG_SIZE];
                uint8[] tag = packed[packed.length - GCM_TAG_SIZE:packed.length];

                var cipher = new Crypto.SymmetricCipher("AES-GCM");
                cipher.set_key(enc_key);
                cipher.set_iv(iv);
                uint8[] plaintext = new uint8[ciphertext.length];
                cipher.decrypt(plaintext, ciphertext);
                cipher.check_tag(tag);

                uint8[] nul_terminated = new uint8[plaintext.length + 1];
                GLib.Memory.copy(nul_terminated, plaintext, plaintext.length);
                nul_terminated[plaintext.length] = 0;
                return ((string) nul_terminated).dup();
            } catch (GLib.Error e) {
                warning("BotRegistry: decrypt error for '%s': %s", key, e.message);
                return null;
            }
        }

        // Plaintext value found — auto-migrate to encrypted storage
        uint8[]? enc_key = get_enc_key();
        if (enc_key != null) {
            set_secret_setting(key, raw);
        }
        return raw;
    }

    // --- Audit Log ---

    public void log_action(int bot_id, string action, string? details = null, string? ip = null) {
        long now = (long) new DateTime.now_utc().to_unix();
        audit_log.insert()
            .value(audit_log.bot_id, bot_id)
            .value(audit_log.action, action)
            .value(audit_log.details, details)
            .value(audit_log.ip_address, ip)
            .value(audit_log.timestamp, now)
            .perform();
    }

    // --- Helper ---

    private BotInfo bot_info_from_row(Qlite.Row row) {
        var info = new BotInfo();
        info.id = bot.id.get(row);
        info.name = bot.name_.get(row);
        info.jid = bot.jid.get(row);
        info.token_hash = bot.token_hash.get(row);
        // BUG-02 fix: token_raw deliberately not read — never store raw tokens
        info.owner_jid = bot.owner_jid.get(row);
        info.description = bot.description.get(row);
        info.permissions = bot.permissions.get(row);
        info.status = bot.status.get(row);
        info.mode = bot.mode.get(row);
        info.created_at = bot.created_at.get(row);
        info.last_active = bot.last_active.get(row);
        info.webhook_url = bot.webhook_url.get(row);
        info.webhook_secret = get_bot_secret_with_legacy_fallback(webhook_secret_key(info.id), bot.webhook_secret.get(row));
        info.webhook_enabled = bot.webhook_enabled.get(row);
        info.bot_password = get_bot_secret_with_legacy_fallback(bot_password_key(info.id), bot.bot_password.get(row));
        return info;
    }

    private string bot_password_key(int bot_id) {
        return BOT_PASSWORD_KEY_PREFIX + bot_id.to_string();
    }

    private string webhook_secret_key(int bot_id) {
        return WEBHOOK_SECRET_KEY_PREFIX + bot_id.to_string();
    }

    private string? get_bot_secret_with_legacy_fallback(string key, string? legacy_value) {
        string? secret = get_secret_setting(key);
        if (secret != null && secret != "") return secret;
        if (legacy_value == null || legacy_value == "") return null;
        return legacy_value;
    }
}

// --- Data Classes ---

public class BotInfo : Object {
    public int id { get; set; }
    public string? name { get; set; }
    public string? jid { get; set; }
    public string? token_hash { get; set; }
    // BUG-02 fix: token_raw removed — raw tokens are shown once at creation, never stored
    public string? owner_jid { get; set; }
    public string? description { get; set; }
    public string? permissions { get; set; }
    public string? status { get; set; }
    public string? mode { get; set; }
    public long created_at { get; set; }
    public long last_active { get; set; }
    public string? webhook_url { get; set; }
    public string? webhook_secret { get; set; }
    public bool webhook_enabled { get; set; }
    public string? bot_password { get; set; }
}

public class CommandInfo : Object {
    public string command { get; set; }
    public string? description { get; set; }

    public CommandInfo(string command, string? description) {
        this.command = command;
        this.description = description;
    }
}

public class UpdateInfo : Object {
    public int id { get; set; }
    public int bot_id { get; set; }
    public string update_type { get; set; }
    public string payload { get; set; }
    public long created_at { get; set; }

    public UpdateInfo(int id, int bot_id, string update_type, string payload, long created_at) {
        this.id = id;
        this.bot_id = bot_id;
        this.update_type = update_type;
        this.payload = payload;
        this.created_at = created_at;
    }
}

}
