using Xmpp;

namespace Dino.Entities {

public class FileTransfer : Object {

    public signal void sources_changed();

    public const bool DIRECTION_SENT = true;
    public const bool DIRECTION_RECEIVED = false;

    public enum State {
        COMPLETE,
        IN_PROGRESS,
        NOT_STARTED,
        FAILED
    }

    public enum Phase {
        NONE,
        PREPARING,
        ENCRYPTING,
        REQUESTING_SLOT,
        UPLOADING,
        ANNOUNCING,
        DOWNLOADING,
        DECRYPTING,
        VERIFYING,
        STORING,
        PREVIEWING,
        COMPLETE,
        FAILED
    }

    public int id { get; set; default=-1; }
    public string? file_sharing_id { get; set; }
    public Account account { get; set; }
    public Jid counterpart { get; set; }
    public Jid ourpart { get; set; }
    public Jid? from {
        get { return direction == DIRECTION_SENT ? ourpart : counterpart; }
    }
    public Jid? to {
        get { return direction == DIRECTION_SENT ? counterpart : ourpart; }
    }
    public bool direction { get; set; }
    public DateTime time { get; set; }
    public DateTime? local_time { get; set; }
    public Encryption encryption { get; set; default=Encryption.NONE; }
    public string? encryption_protocol { get; set; }

    private InputStream? input_stream_ = null;
    public InputStream input_stream {
        get {
            if (input_stream_ == null) {
                File file = File.new_for_path(Path.build_filename(storage_dir, path ?? file_name));
                try {
                    input_stream_ = file.read();
                } catch (Error e) {
                    warning("FileTransfer: Failed to read file %s: %s", file.get_path(), e.message);
                }
            }
            return input_stream_;
        }
        set {
            input_stream_ = value;
        }
    }

    private string file_name_;
    public string file_name {
        get { return file_name_; }
        set {
            file_name_ = sanitize_file_name(value);
        }
    }

    public static string sanitize_file_name(string? value) {
        string normalized = (value ?? "").make_valid().replace("\\", "/").strip();
        string name = Path.get_basename(normalized);
        if (name == Path.DIR_SEPARATOR_S || name == "." || name == ".." || name == "") {
            name = "unknown filename";
        } else {
            StringBuilder clean = new StringBuilder();
            for (int i = 0; i < name.length; i++) {
                char c = name[i];
                if (c < 32 || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|' || c == '/') {
                    clean.append_c('_');
                } else {
                    clean.append_c(c);
                }
            }
            name = clean.str.strip();
            while (name.has_suffix(".") || name.has_suffix(" ")) {
                name = name.substring(0, name.length - 1);
            }
            if (name == "" || name == "." || name == "..") {
                return "unknown filename";
            }
            if (name.has_prefix(".")) {
                name = "_" + name;
            }
        }
        return name;
    }

    public static Encryption resolve_received_encryption(Encryption provider_encryption, Encryption decryptor_encryption) {
        if (provider_encryption != Encryption.NONE) return provider_encryption;
        return decryptor_encryption;
    }

    public static Phase receive_store_phase_for(bool has_decryptor, bool decrypts_before_return) {
        if (!has_decryptor) return Phase.DOWNLOADING;
        return decrypts_before_return ? Phase.STORING : Phase.DECRYPTING;
    }

    private string? server_file_name_ = null;
    public string server_file_name {
        get { return server_file_name_ ?? file_name; }
        set { server_file_name_ = value; }
    }
    public string path { get; set; }
    public string? mime_type { get; set; }
    public int64 size { get; set; }
    public State state { get; set; default=State.NOT_STARTED; }
    public Phase phase { get; set; default=Phase.NONE; }
    public string? phase_error { get; set; }
    public int provider { get; set; }
    public string info { get; set; }
    public int message_db_id { get; set; default=-1; }
    public Cancellable cancellable { get; private set; default=new Cancellable(); }
    public string? cancel_token { get; set; }
    public int retry_count { get; set; default=0; }
    public long next_retry_time { get; set; default=0; }
    public long last_attempt_time { get; set; default=0; }

    // These values are not persisted.
    public int preferred_file_sender_id { get; set; default=-1; }
    public int64 transferred_bytes { get; set; }
    public int64 phase_total_bytes { get; set; default=-1; }
    private bool transient_download_source_available = false;

    public Xep.FileMetadataElement.FileMetadata file_metadata {
        owned get {
            return new Xep.FileMetadataElement.FileMetadata() {
                name = this.file_name,
                mime_type = this.mime_type,
                size = this.size,
                desc = this.desc,
                date = this.modification_date,
                width = this.width,
                height = this.height,
                length = this.length,
                hashes = this.hashes,
                thumbnails = this.thumbnails
            };
        }
        set {
            this.file_name = value.name;
            this.mime_type = value.mime_type;
            this.size = value.size;
            this.desc = value.desc;
            this.modification_date = value.date;
            this.width = value.width;
            this.height = value.height;
            this.length = value.length;
            this.hashes = value.hashes;
            this.thumbnails = value.thumbnails;
        }
    }

    /**
     * Return the local message relation. Numeric `info` values are retained as
     * a read fallback for transfers written before database version 51.
     */
    public int resolve_message_db_id() {
        if (message_db_id > 0) return message_db_id;
        // Only HTTP (0) and Stateless File Sharing (2) historically stored a
        // local message id in `info`. Jingle (1) owns this field as transport
        // state and a numeric session id must never become a chat relation.
        if (provider != 0 && provider != 2) return -1;
        if (info == null || info == "" || info.has_prefix("url:")) return -1;

        int legacy_message_db_id;
        if (int.try_parse(info, out legacy_message_db_id) &&
                legacy_message_db_id > 0) {
            return legacy_message_db_id;
        }
        return -1;
    }
    public string? desc { get; set; }
    public DateTime? modification_date { get; set; }
    public int width { get; set; default=-1; }
    public int height { get; set; default=-1; }
    public int64 length { get; set; default=-1; }
    public Gee.List<Xep.CryptographicHashes.Hash> hashes = new Gee.ArrayList<Xep.CryptographicHashes.Hash>();
    public Gee.List<Xep.StatelessFileSharing.Source> sfs_sources = new Gee.ArrayList<Xep.StatelessFileSharing.Source>(Xep.StatelessFileSharing.Source.equals_func);
    public Gee.List<Xep.JingleContentThumbnails.Thumbnail> thumbnails = new Gee.ArrayList<Xep.JingleContentThumbnails.Thumbnail>();
        public bool is_sticker { get; set; default=false; }
        public string? sticker_pack_id { get; set; }
        public string? sticker_pack_jid { get; set; }
        public string? sticker_pack_node { get; set; }

    private const int ESFS_AES_256_KEY_BYTES = 32;
    private const int ESFS_GCM_IV_BYTES = 12;
    private const int ESFS_COMPAT_GCM_IV_BYTES = 16;
    private const string ESFS_AES_256_GCM_NOPADDING_URI = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0";

    private Database? db;
    private string storage_dir;

    public FileTransfer.from_row(Database db, Qlite.Row row, string storage_dir) throws InvalidJidError {
        this.db = db;
        this.storage_dir = storage_dir;

        id = row[db.file_transfer.id];
        file_sharing_id = row[db.file_transfer.file_sharing_id];
        account = db.get_account_by_id(row[db.file_transfer.account_id]); // TODO don't have to generate acc new

            // Sticker fields (optional)
            is_sticker = row[db.file_transfer.is_sticker];
            sticker_pack_id = row[db.file_transfer.sticker_pack_id];
            sticker_pack_jid = row[db.file_transfer.sticker_pack_jid];
            sticker_pack_node = row[db.file_transfer.sticker_pack_node];

        counterpart = db.get_jid_by_id(row[db.file_transfer.counterpart_id]);
        string counterpart_resource = row[db.file_transfer.counterpart_resource];
        if (counterpart_resource != null) counterpart = counterpart.with_resource(counterpart_resource);

        string our_resource = row[db.file_transfer.our_resource];
        if (our_resource != null) {
            ourpart = account.bare_jid.with_resource(our_resource);
        } else {
            ourpart = account.bare_jid;
        }
        direction = row[db.file_transfer.direction];
        time = new DateTime.from_unix_utc(row[db.file_transfer.time]);
        local_time = new DateTime.from_unix_utc(row[db.file_transfer.local_time]);
        encryption = (Encryption) row[db.file_transfer.encryption];
        encryption_protocol = row[db.file_transfer.encryption_protocol];
        file_name = row[db.file_transfer.file_name];
        path = row[db.file_transfer.path];
        mime_type = row[db.file_transfer.mime_type];
        size = (int64) row[db.file_transfer.size];
        state = (State) row[db.file_transfer.state];
        phase = phase_for_state(state, direction);
        provider = row[db.file_transfer.provider];
        info = row[db.file_transfer.info];
        message_db_id = row[db.file_transfer.message_id];
        retry_count = row[db.file_transfer.retry_count];
        next_retry_time = row[db.file_transfer.next_retry_time];
        last_attempt_time = row[db.file_transfer.last_attempt_time];
        modification_date = new DateTime.from_unix_utc(row[db.file_transfer.modification_date]);
        width = row[db.file_transfer.width];
        height = row[db.file_transfer.height];
        length = (int64) row[db.file_transfer.length];

        // TODO put those into the initial query
        foreach(var hash_row in db.file_hashes.select().with(db.file_hashes.id, "=", id)) {
            Xep.CryptographicHashes.Hash hash = new Xep.CryptographicHashes.Hash();
            hash.algo = hash_row[db.file_hashes.algo];
            hash.val = hash_row[db.file_hashes.value];
            hashes.add(hash);
        }

        foreach(var thumbnail_row in db.file_thumbnails.select().with(db.file_thumbnails.id, "=", id)) {
            Bytes? data = Xmpp.get_data_for_uri(thumbnail_row[db.file_thumbnails.uri]);
            if (data == null) continue;
            Xep.JingleContentThumbnails.Thumbnail thumbnail = new Xep.JingleContentThumbnails.Thumbnail();
            thumbnail.data = data;
            thumbnail.media_type = thumbnail_row[db.file_thumbnails.mime_type];
            thumbnail.width = thumbnail_row[db.file_thumbnails.width];
            thumbnail.height = thumbnail_row[db.file_thumbnails.height];
            thumbnails.add(thumbnail);
        }

        foreach(Qlite.Row source_row in db.sfs_sources.select().with(db.sfs_sources.file_transfer_id, "=", id)) {
            if (source_row[db.sfs_sources.type] == "http") {
                sfs_sources.add(new Xep.StatelessFileSharing.HttpSource() { url=source_row[db.sfs_sources.data] });
            } else if (source_row[db.sfs_sources.type] == "esfs") {
                Xep.StatelessFileSharing.EsfsHttpSource? esfs_source = parse_persisted_esfs_source(source_row[db.sfs_sources.data]);
                if (esfs_source != null) {
                    sfs_sources.add(esfs_source);
                }
            }
        }

        notify.connect(on_update);
    }

    public void persist(Database db) {
        if (id != -1) return;

        this.db = db;
        Qlite.InsertBuilder builder = db.file_transfer.insert()
            .value(db.file_transfer.account_id, account.id)
            .value(db.file_transfer.counterpart_id, db.get_jid_id(counterpart))
            .value(db.file_transfer.counterpart_resource, counterpart.resourcepart)
            .value(db.file_transfer.our_resource, ourpart.resourcepart)
            .value(db.file_transfer.direction, direction)
            .value(db.file_transfer.time, (long) time.to_unix())
            .value(db.file_transfer.local_time, (long) local_time.to_unix())
            .value(db.file_transfer.encryption, encryption)
            .value(db.file_transfer.file_name, file_name)
            .value(db.file_transfer.size, (long) size)
            .value(db.file_transfer.state, persistent_state_for(state))
            .value(db.file_transfer.provider, provider)
            .value(db.file_transfer.info, info)
            .value(db.file_transfer.message_id, message_db_id);

            builder.value(db.file_transfer.is_sticker, is_sticker);
            if (sticker_pack_id != null) builder.value(db.file_transfer.sticker_pack_id, sticker_pack_id);
            if (sticker_pack_jid != null) builder.value(db.file_transfer.sticker_pack_jid, sticker_pack_jid);
            if (sticker_pack_node != null) builder.value(db.file_transfer.sticker_pack_node, sticker_pack_node);

        if (file_sharing_id != null) builder.value(db.file_transfer.file_sharing_id, file_sharing_id);
        if (encryption_protocol != null) builder.value(db.file_transfer.encryption_protocol, encryption_protocol);
        if (path != null) builder.value(db.file_transfer.path, path);
        if (mime_type != null) builder.value(db.file_transfer.mime_type, mime_type);
        builder.value(db.file_transfer.retry_count, retry_count);
        builder.value(db.file_transfer.next_retry_time, next_retry_time);
        builder.value(db.file_transfer.last_attempt_time, last_attempt_time);
        if (modification_date != null) builder.value(db.file_transfer.modification_date, (long) modification_date.to_unix());
        if (width != -1) builder.value(db.file_transfer.width, width);
        if (height != -1) builder.value(db.file_transfer.height, height);
        if (length != -1) builder.value(db.file_transfer.length, (long) length);

        id = (int) builder.perform();

        foreach (Xep.CryptographicHashes.Hash hash in hashes) {
            db.file_hashes.insert()
                    .value(db.file_hashes.id, id)
                    .value(db.file_hashes.algo, hash.algo)
                    .value(db.file_hashes.value, hash.val)
                    .perform();
        }
        foreach (Xep.JingleContentThumbnails.Thumbnail thumbnail in thumbnails) {
            if (thumbnail.data == null) continue;
            string data_uri = thumbnail.to_data_uri();

            db.file_thumbnails.insert()
                    .value(db.file_thumbnails.id, id)
                    .value(db.file_thumbnails.uri, data_uri)
                    .value(db.file_thumbnails.mime_type, thumbnail.media_type)
                    .value(db.file_thumbnails.width, thumbnail.width)
                    .value(db.file_thumbnails.height, thumbnail.height)
                    .perform();
        }

        foreach (Xep.StatelessFileSharing.Source source in sfs_sources) {
            persist_source(source);
        }

        notify.connect(on_update);
    }

    public void set_transfer_phase(Phase phase, string? error = null) {
        freeze_notify();
        phase_error = error;

        switch (phase) {
            case Phase.NONE:
                state = State.NOT_STARTED;
                phase_total_bytes = -1;
                transferred_bytes = 0;
                break;
            case Phase.COMPLETE:
                state = State.COMPLETE;
                phase_error = null;
                if (size >= 0) {
                    phase_total_bytes = size;
                    transferred_bytes = size;
                } else {
                    phase_total_bytes = -1;
                    transferred_bytes = 0;
                }
                break;
            case Phase.FAILED:
                state = State.FAILED;
                break;
            case Phase.PREPARING:
            case Phase.ENCRYPTING:
            case Phase.REQUESTING_SLOT:
            case Phase.UPLOADING:
            case Phase.ANNOUNCING:
            case Phase.DOWNLOADING:
            case Phase.DECRYPTING:
            case Phase.VERIFYING:
            case Phase.STORING:
            case Phase.PREVIEWING:
                phase_total_bytes = -1;
                transferred_bytes = 0;
                state = State.IN_PROGRESS;
                break;
        }
        this.phase = phase;
        thaw_notify();
    }

    public static State persistent_state_for(State state) {
        return state == State.IN_PROGRESS ? State.FAILED : state;
    }

    public void prepare_transfer_attempt() {
        if (cancellable.is_cancelled()) {
            cancellable = new Cancellable();
        }
        last_attempt_time = (long) new DateTime.now_utc().to_unix();
        next_retry_time = 0;
    }

    public void clear_retry_schedule() {
        retry_count = 0;
        next_retry_time = 0;
    }

    public void schedule_retry(uint delay_seconds) {
        retry_count++;
        next_retry_time = (long) new DateTime.now_utc().to_unix() + (long) delay_seconds;
    }

    public bool is_plaintext_release_allowed() {
        return state == State.COMPLETE;
    }

    public bool has_local_file_copy() {
        return path != null && path != "";
    }

    public bool can_start_receive_attempt(int sfs_provider_id = -1, int durable_url_provider_id = -1) {
        bool can_receive = direction == DIRECTION_RECEIVED ||
            (sfs_provider_id >= 0 && is_sent_remote_download_offer(sfs_provider_id, durable_url_provider_id));
        return can_receive && (state == State.NOT_STARTED || state == State.FAILED);
    }

    public bool can_retry_send_attempt() {
        return direction == DIRECTION_SENT && state == State.FAILED && has_local_file_copy();
    }

    public bool is_sent_remote_download_offer(int sfs_provider_id, int durable_url_provider_id = -1) {
        if (direction != DIRECTION_SENT || has_local_file_copy()) return false;
        if (provider == sfs_provider_id) return has_usable_sfs_source();
        if (durable_url_provider_id >= 0 && provider == durable_url_provider_id) {
            return info != null && ((!) info).has_prefix("url:");
        }
        return false;
    }

    public bool is_auto_download_candidate(int sfs_provider_id, int64 max_size, int transient_provider_id = -1) {
        bool can_receive = direction == DIRECTION_RECEIVED || is_sent_remote_download_offer(sfs_provider_id);
        return can_receive &&
            state == State.NOT_STARTED &&
            size >= 0 &&
            size < max_size &&
            has_usable_download_source(sfs_provider_id, transient_provider_id);
    }

    public bool has_usable_download_source(int sfs_provider_id, int transient_provider_id = -1) {
        if (direction == DIRECTION_SENT) {
            if (provider == sfs_provider_id && !has_local_file_copy()) return has_usable_sfs_source();
            return true;
        }
        if (provider == transient_provider_id) return transient_download_source_available;
        if (provider != sfs_provider_id) return true;
        return has_usable_sfs_source();
    }

    public void set_transient_download_source_available(bool available) {
        if (transient_download_source_available == available) return;
        transient_download_source_available = available;
        sources_changed();
    }

    public bool has_usable_sfs_source() {
        if (sfs_sources.is_empty) return false;

        foreach (Xep.StatelessFileSharing.Source source in sfs_sources) {
            if (is_structurally_usable_sfs_source(source, encryption)) return true;
        }
        return false;
    }

    public static bool is_structurally_usable_sfs_source(Xep.StatelessFileSharing.Source source, Encryption file_encryption) {
        var esfs_source = source as Xep.StatelessFileSharing.EsfsHttpSource;
        if (esfs_source != null) {
            return is_structurally_usable_esfs_source(esfs_source);
        }

        var http_source = source as Xep.StatelessFileSharing.HttpSource;
        if (http_source != null) {
            return file_encryption == Encryption.NONE && is_http_url(http_source.url);
        }

        return false;
    }

    private static bool is_http_url(string? url) {
        if (url == null) return false;
        string normalized = ((!) url).strip().ascii_down();
        return normalized.has_prefix("https://") || normalized.has_prefix("http://");
    }

    private static bool is_structurally_usable_esfs_source(Xep.StatelessFileSharing.EsfsHttpSource source) {
        if (!is_http_url(source.url)) return false;
        if (source.key == null || source.key.length != ESFS_AES_256_KEY_BYTES) return false;
        if (source.iv == null) return false;

        if (is_supported_esfs_gcm_cipher(source.cipher_uri)) {
            return source.iv.length == ESFS_GCM_IV_BYTES || source.iv.length == ESFS_COMPAT_GCM_IV_BYTES;
        }
        return false;
    }

    private static bool is_supported_esfs_gcm_cipher(string? cipher_uri) {
        return (cipher_uri ?? "").strip().ascii_down() == ESFS_AES_256_GCM_NOPADDING_URI;
    }

    private static Phase phase_for_state(State state, bool direction) {
        switch (state) {
            case State.COMPLETE:
                return Phase.COMPLETE;
            case State.FAILED:
                return Phase.FAILED;
            case State.IN_PROGRESS:
                return direction == DIRECTION_SENT ? Phase.UPLOADING : Phase.DOWNLOADING;
            case State.NOT_STARTED:
            default:
                return Phase.NONE;
        }
    }

    public void add_sfs_source(Xep.StatelessFileSharing.Source source) {
        if (sfs_sources.contains(source)) return; // Don't add the same source twice. Might happen due to MAM and lacking deduplication.

        sfs_sources.add(source);
        if (id != -1) {
            persist_source(source);
        }
        sources_changed();
    }

    private void persist_source(Xep.StatelessFileSharing.Source source) {
        Xep.StatelessFileSharing.HttpSource? http_source = source as Xep.StatelessFileSharing.HttpSource;
        if (http_source != null) {
            db.sfs_sources.insert()
                    .value(db.sfs_sources.file_transfer_id, id)
                    .value(db.sfs_sources.type, "http")
                    .value(db.sfs_sources.data, http_source.url)
                    .perform();
            return;
        }

        Xep.StatelessFileSharing.EsfsHttpSource? esfs_source = source as Xep.StatelessFileSharing.EsfsHttpSource;
        if (esfs_source != null) {
            db.sfs_sources.insert()
                    .value(db.sfs_sources.file_transfer_id, id)
                    .value(db.sfs_sources.type, "esfs")
                    .value(db.sfs_sources.data, serialize_esfs_source(esfs_source))
                    .perform();
        }
    }

    private static string serialize_esfs_source(Xep.StatelessFileSharing.EsfsHttpSource source) {
        return "%s\n%s\n%s\n%s".printf(
            source.url,
            source.cipher_uri ?? "",
            Base64.encode(source.key),
            Base64.encode(source.iv));
    }

    private static Xep.StatelessFileSharing.EsfsHttpSource? parse_persisted_esfs_source(string data) {
        string[] parts = data.split("\n");
        if (parts.length < 4 || parts[0] == "" || parts[1] == "" || parts[2] == "" || parts[3] == "") return null;

        var source = new Xep.StatelessFileSharing.EsfsHttpSource();
        source.url = parts[0];
        source.cipher_uri = parts[1];
        source.key = Base64.decode(parts[2]);
        source.iv = Base64.decode(parts[3]);
        return is_structurally_usable_esfs_source(source) ? source : null;
    }

    public File? get_file() {
        if (path == null) return null;
        return File.new_for_path(Path.build_filename(Dino.get_storage_dir(), "files", path));
    }

    private void on_update(Object o, ParamSpec sp) {
        Qlite.UpdateBuilder update_builder = db.file_transfer.update().with(db.file_transfer.id, "=", id);
        switch (sp.name) {
            case "file-sharing-id":
                update_builder.set(db.file_transfer.file_sharing_id, file_sharing_id); break;
            case "counterpart":
                update_builder.set(db.file_transfer.counterpart_id, db.get_jid_id(counterpart));
                update_builder.set(db.file_transfer.counterpart_resource, counterpart.resourcepart); break;
            case "ourpart":
                update_builder.set(db.file_transfer.our_resource, ourpart.resourcepart); break;
            case "direction":
                update_builder.set(db.file_transfer.direction, direction); break;
            case "time":
                update_builder.set(db.file_transfer.time, (long) time.to_unix()); break;
            case "local-time":
                update_builder.set(db.file_transfer.local_time, (long) local_time.to_unix()); break;
            case "encryption":
                update_builder.set(db.file_transfer.encryption, encryption); break;
            case "encryption-protocol":
                update_builder.set(db.file_transfer.encryption_protocol, encryption_protocol); break;
            case "file-name":
                update_builder.set(db.file_transfer.file_name, file_name); break;
            case "path":
                update_builder.set(db.file_transfer.path, path); break;
            case "mime-type":
                update_builder.set(db.file_transfer.mime_type, mime_type); break;
            case "size":
                update_builder.set(db.file_transfer.size, (long) size); break;
            case "state":
                // Runtime phases are not persisted. Store active attempts as
                // failed recovery state so restart/reconnect never restores a
                // stale in-progress transfer without an active job owner.
                update_builder.set(db.file_transfer.state, persistent_state_for(state)); break;
            case "phase":
            case "phase-error":
            case "transferred-bytes":
            case "phase-total-bytes":
                return;
            case "provider":
                update_builder.set(db.file_transfer.provider, provider); break;
            case "info":
                update_builder.set(db.file_transfer.info, info); break;
            case "message-db-id":
                update_builder.set(db.file_transfer.message_id, message_db_id); break;
            case "retry-count":
                update_builder.set(db.file_transfer.retry_count, retry_count); break;
            case "next-retry-time":
                update_builder.set(db.file_transfer.next_retry_time, next_retry_time); break;
            case "last-attempt-time":
                update_builder.set(db.file_transfer.last_attempt_time, last_attempt_time); break;
            case "modification-date":
                update_builder.set(db.file_transfer.modification_date, (long) modification_date.to_unix()); break;
            case "width":
                update_builder.set(db.file_transfer.width, width); break;
            case "height":
                update_builder.set(db.file_transfer.height, height); break;
            case "length":
                update_builder.set(db.file_transfer.length, (long) length); break;

                case "is-sticker":
                    update_builder.set(db.file_transfer.is_sticker, is_sticker); break;
                case "sticker-pack-id":
                    update_builder.set(db.file_transfer.sticker_pack_id, sticker_pack_id); break;
                case "sticker-pack-jid":
                    update_builder.set(db.file_transfer.sticker_pack_jid, sticker_pack_jid); break;
                case "sticker-pack-node":
                    update_builder.set(db.file_transfer.sticker_pack_node, sticker_pack_node); break;
        }
        update_builder.perform();
    }
}

}
