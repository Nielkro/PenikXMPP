/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gdk;
using Soup;

using Dino.Entities;
using Dino.Security;
using Xmpp;
using Xmpp.Xep;

namespace Dino {

public errordomain StickerError {
    INVALID_URI,
    NOT_CONNECTED,
    NOT_FOUND,
    RESTRICTED,
    DOWNLOAD_FAILED,
    PUBLISH_FAILED,
}

public delegate void StickerImportProgress(int completed, int total);

public class Stickers : StreamInteractionModule, Object {
    public static ModuleIdentity<Stickers> IDENTITY = new ModuleIdentity<Stickers>("stickers");
    public string id { get { return IDENTITY.id; } }
    public signal void publishing_changed(Account account, string pack_id, bool publishing);
    public signal void importing_changed(Account account, string pack_id, bool importing);

    private StreamInteractor stream_interactor;
    private Database db;
    private FileEncryption file_encryption;
    private AccountHttpSessionPool http_sessions;
    private GLib.MainContext http_context;
    private HashSet<string> publishing_packs = new HashSet<string>();
    private HashSet<string> importing_packs = new HashSet<string>();

    private const string STICKERS_NODE = Xmpp.Xep.Stickers.NS_URI;
    private const int THUMB_SIZE = 48;

    // SVG detection delegated to FileDetectionUtils to avoid duplication.

    public static void start(StreamInteractor stream_interactor, Database db, FileEncryption file_encryption) {
        var m = new Stickers(stream_interactor, db, file_encryption);
        stream_interactor.add_module(m);
    }

    private Stickers(StreamInteractor stream_interactor, Database db, FileEncryption file_encryption) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.file_encryption = file_encryption;

        // libsoup binds to the thread-default main context at creation time.
        // Make sure we always use it from that same context.
        this.http_context = GLib.MainContext.ref_thread_default();
        this.http_sessions = new AccountHttpSessionPool("stickers");

        DirUtils.create_with_parents(get_stickers_dir(), 0700);
    }

    public void shutdown() {
        http_sessions.shutdown();
    }

    private async void ensure_http_context() {
        // `get_thread_default()` may be null even while running on the default main
        // context. `MainContext.invoke()` may execute callbacks immediately in some
        // situations; if that happens before we reach `yield`, it can cause re-entrant
        // recursion in Vala async state machines. Use an explicit Source attached to
        // the desired context to guarantee asynchronous resumption.
        if (http_context.is_owner()) return;
        var idle = new GLib.IdleSource();
        idle.set_callback(() => {
            ensure_http_context.callback();
            return GLib.Source.REMOVE;
        });
        idle.attach(http_context);
        yield;
    }

    public static string get_stickers_dir() {
        return Path.build_filename(Dino.get_storage_dir(), "stickers");
    }

    internal static OutgoingFileSource get_outgoing_source_for_path(
            string path, string stickers_dir) {
        return File.new_for_path(path).has_prefix(File.new_for_path(stickers_dir))
                ? OutgoingFileSource.DINOX_MANAGED_STORAGE
                : OutgoingFileSource.EXTERNAL_PLAINTEXT;
    }

    private static string get_pack_dir(string pack_id) {
        return Path.build_filename(get_stickers_dir(), pack_id);
    }

    private static string get_pack_thumbs_dir(string pack_id) {
        return Path.build_filename(get_pack_dir(pack_id), "thumbs");
    }

    private class ThumbJob : Object {
        public string source_path;
        public string thumb_path;

        public ThumbJob(string source_path, string thumb_path) {
            this.source_path = source_path;
            this.thumb_path = thumb_path;
        }
    }

    private AsyncQueue<ThumbJob>? thumb_queue;
    private bool thumb_worker_started = false;

    private void ensure_thumb_worker() {
        if (thumb_worker_started) return;
        thumb_worker_started = true;
        thumb_queue = new AsyncQueue<ThumbJob>();

        new Thread<void*>("stickers-thumbgen", () => {
            while (true) {
                ThumbJob job = thumb_queue.pop();

                // Best-effort: if something else created it already, skip.
                if (FileUtils.test(job.thumb_path, FileTest.EXISTS)) continue;

                DirUtils.create_with_parents(Path.get_dirname(job.thumb_path), 0700);

                try {
                    // Decrypt source
                    uint8[] source_data;
                    if (!FileUtils.get_data(job.source_path, out source_data)) continue;
                    uint8[] plaintext = file_encryption.decrypt_data(source_data);

                    // Create stream from plaintext
                    var stream = new MemoryInputStream.from_data(plaintext, null);

                    var pixbuf = new Pixbuf.from_stream_at_scale(stream, THUMB_SIZE, THUMB_SIZE, true);
                    pixbuf = pixbuf.apply_embedded_orientation();
                    
                    uint8[] thumb_data = pixbuf_to_png_bytes(pixbuf);
                    
                    // Encrypt thumb
                    uint8[] thumb_enc = file_encryption.encrypt_data(thumb_data);
                    
                    FileUtils.set_data(job.thumb_path, thumb_enc);
                } catch (Error e) {
                    // best-effort
                }
            }
            // unreachable
            // return null;
        });
    }

    public static string? get_thumbnail_path_for_item(StickerItem item) {
        if (item.pack_id == null || item.pack_id == "") return null;
        if (item.local_path == null || item.local_path == "") return null;

        string base_name;
        if (item.hash_value != null && item.hash_value != "") {
            base_name = filename_safe_base64(item.hash_value);
        } else {
            // Fallback for older/incomplete items.
            base_name = Checksum.compute_for_string(ChecksumType.SHA1, item.local_path);
        }

        return Path.build_filename(get_pack_thumbs_dir(item.pack_id), base_name + ".png");
    }

    public Bytes? get_thumbnail_bytes_for_item(StickerItem item) {
        string? path = get_thumbnail_path_for_item(item);
        if (path == null) return null;

        try {
            uint8[] data;
            if (!FileUtils.get_data(path, out data)) return null;
            uint8[] plaintext = file_encryption.decrypt_data(data);
            return new Bytes(plaintext);
        } catch (Error e) {
            return null;
        }
    }

    public Bytes? get_sticker_bytes(StickerItem item) {
        if (item.local_path == null) return null;
        try {
            uint8[] data;
            if (!FileUtils.get_data(item.local_path, out data)) return null;
            uint8[] plaintext = file_encryption.decrypt_data(data);
            return new Bytes(plaintext);
        } catch (Error e) {
            return null;
        }
    }

    private void maybe_generate_thumbnail(string pack_id, StickerItem item) {
        if (item.local_path == null || item.local_path == "") return;

        // Thumbnail generation is best-effort. Some loaders (notably SVG via librsvg)
        // have caused crashes in the Flatpak runtime when importing sticker packs.
        // Skip thumbnailing for non-raster/unknown types; the UI can still generate
        // thumbnails lazily when needed.
        if (item.media_type != null && item.media_type != "") {
            switch (item.media_type) {
                case "image/png":
                case "image/jpeg":
                case "image/jpg":
                case "image/webp":
                case "image/gif":
                    break;
                default:
                    return;
            }
        } else {
            return;
        }

        // Do not trust the declared mime-type fully: some packs contain SVG data mislabeled as
        // image/png or similar. Loading SVG via gdk-pixbuf/librsvg has been observed to crash in
        // Flatpak runtimes.
        if (FileDetectionUtils.looks_like_svg_file(File.new_for_path(item.local_path))) {
            return;
        }

        string? thumb_path = get_thumbnail_path_for_item(item);
        if (thumb_path == null || thumb_path == "") return;
        if (FileUtils.test(thumb_path, FileTest.EXISTS)) return;

        // Generating thumbnails can be expensive (decode/scale). Do it off the
        // main thread to avoid UI stalls; the UI can still lazy-generate on demand.
        ensure_thumb_worker();
        if (thumb_queue != null) {
            thumb_queue.push(new ThumbJob(item.local_path, thumb_path));
        }
    }

    private static string filename_safe_base64(string b64) {
        // URL-safe-ish, and also file-system-safe-ish.
        return b64.replace("/", "_").replace("+", "-").replace("=", "");
    }

    public class StickerPack : Object {
        public string pack_id { get; set; }
        public string? name { get; set; }
        public string? summary { get; set; }
        public bool restricted { get; set; }
        public string? source_jid { get; set; }
        public string? source_node { get; set; }
    }

    public class StickerItem : Object {
        public string pack_id { get; set; }
        public int position { get; set; }
        public string? desc { get; set; }
        public string? media_type { get; set; }
        public string? hash_algo { get; set; }
        public string? hash_value { get; set; }
        public string? source_url { get; set; }
        public string? local_path { get; set; }
    }

    public Gee.List<StickerPack> get_packs(Account account) {
        var packs = new ArrayList<StickerPack>();
        foreach (var row in db.sticker_pack.select().with(db.sticker_pack.account_id, "=", account.id)) {
            var p = new StickerPack();
            p.pack_id = row[db.sticker_pack.pack_id];
            p.name = row[db.sticker_pack.name];
            p.summary = row[db.sticker_pack.summary];
            p.restricted = row[db.sticker_pack.restricted];
            p.source_jid = row[db.sticker_pack.source_jid];
            p.source_node = row[db.sticker_pack.source_node];
            packs.add(p);
        }
        return packs;
    }

    public Gee.List<StickerItem> get_items(Account account, string pack_id) {
        var items = new ArrayList<StickerItem>();
        var q = db.sticker_item.select()
            .with(db.sticker_item.account_id, "=", account.id)
            .with(db.sticker_item.pack_id, "=", pack_id)
            .order_by(db.sticker_item.position, "ASC");
        foreach (var row in q) {
            var it = new StickerItem();
            it.pack_id = row[db.sticker_item.pack_id];
            it.position = row[db.sticker_item.position];
            it.desc = row[db.sticker_item.desc];
            it.media_type = row[db.sticker_item.media_type];
            it.hash_algo = row[db.sticker_item.hash_algo];
            it.hash_value = row[db.sticker_item.hash_value];
            it.source_url = row[db.sticker_item.source_url];
            it.local_path = row[db.sticker_item.local_path];
            items.add(it);
        }
        return items;
    }

    public async StickerPack import_pack(Account account, Jid source_jid, string node, string pack_id) throws Error {
        return yield import_pack_with_progress(account, source_jid, node, pack_id);
    }

    public async StickerPack import_pack_with_progress(Account account, Jid source_jid, string node,
            string pack_id, StickerImportProgress? progress = null) throws Error {
        if (is_pack_publishing(account, pack_id)) {
            throw new StickerError.PUBLISH_FAILED("Sticker pack is being published");
        }
        string key = account.id.to_string() + ":" + pack_id;
        if (!importing_packs.add(key)) {
            throw new StickerError.DOWNLOAD_FAILED("Sticker pack is already being imported");
        }
        try {
            return yield import_pack_internal(account, source_jid, node, pack_id, progress);
        } finally {
            importing_packs.remove(key);
            importing_changed(account, pack_id, false);
        }
    }

    private async StickerPack import_pack_internal(Account account, Jid source_jid, string node,
            string pack_id, StickerImportProgress? progress) throws Error {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new StickerError.NOT_CONNECTED("Not connected");

        StanzaNode? pack_node = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).request_item(stream, source_jid, node, pack_id);
        if (pack_node == null) throw new StickerError.NOT_FOUND("Sticker pack not found");
        if (pack_node.name != "pack" || pack_node.ns_uri != Xmpp.Xep.Stickers.NS_URI) {
            throw new StickerError.INVALID_URI("PubSub item is not a sticker pack");
        }

        var parsed_pack = parse_pack(pack_node);
        parsed_pack.pack_id = pack_id;
        parsed_pack.source_jid = source_jid.to_string();
        parsed_pack.source_node = node;

        if (parsed_pack.restricted) throw new StickerError.RESTRICTED("Sticker pack is restricted");
        ensure_account_not_removed(account);

        // Store pack metadata
        db.sticker_pack.upsert()
            .value(db.sticker_pack.account_id, account.id, true)
            .value(db.sticker_pack.pack_id, pack_id, true)
            .value(db.sticker_pack.source_jid, parsed_pack.source_jid)
            .value(db.sticker_pack.source_node, parsed_pack.source_node)
            .value(db.sticker_pack.name, parsed_pack.name)
            .value(db.sticker_pack.summary, parsed_pack.summary)
            .value(db.sticker_pack.restricted, parsed_pack.restricted)
            .perform();
        importing_changed(account, pack_id, true);
        ensure_pack_not_removed(account, pack_id);

        // Replace items
        db.exec(@"DELETE FROM sticker_item WHERE account_id=$(account.id) AND pack_id='$(pack_id.replace("'", "''"))'");

        var items = parse_items(pack_node, pack_id);
        int pos = 0;
        foreach (var item in items) {
            ensure_pack_not_removed(account, pack_id);
            item.position = pos++;

            if (item.source_url != null && item.hash_value != null) {
                string ext = guess_extension(item.media_type);
                string file_name = filename_safe_base64(item.hash_value) + ext;
                string pack_dir = Path.build_filename(get_stickers_dir(), pack_id);
                DirUtils.create_with_parents(pack_dir, 0700);
                string local_path = Path.build_filename(pack_dir, file_name);

                try {
                    yield download_to_file(item.source_url, local_path, account, pack_id);
                    item.local_path = local_path;
                } catch (StickerError.NOT_FOUND e) {
                    // Account/library removal is cancellation, not a broken
                    // image download. Stop before any late inserts or PEP writes.
                    throw e;
                } catch (Error e) {
                    warning("Failed to download sticker %s: %s", item.source_url, e.message);
                    // Keep pack usable; item just won't be sendable offline.
                }
            }

            // remove_pack may run while the HTTP request yields. It must not
            // be undone by late item inserts or thumbnail jobs for this account.
            ensure_pack_not_removed(account, pack_id);
            maybe_generate_thumbnail(pack_id, item);

            db.sticker_item.insert()
                .value(db.sticker_item.account_id, account.id)
                .value(db.sticker_item.pack_id, pack_id)
                .value(db.sticker_item.position, item.position)
                .value(db.sticker_item.desc, item.desc)
                .value(db.sticker_item.media_type, item.media_type)
                .value(db.sticker_item.hash_algo, item.hash_algo)
                .value(db.sticker_item.hash_value, item.hash_value)
                .value(db.sticker_item.source_url, item.source_url)
                .value(db.sticker_item.local_path, item.local_path)
                .perform();
            if (progress != null) progress(pos, items.size);
        }

        // Duplicate to our own PEP node
        ensure_pack_not_removed(account, pack_id);
        var my_jid = stream.get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid.bare_jid;
        bool published = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).publish(stream, my_jid, STICKERS_NODE, pack_id, pack_node,
            new Pubsub.PublishOptions().set_persist_items(true).set_max_items("max").set_send_last_published_item("never").set_access_model(Pubsub.ACCESS_MODEL_OPEN)
        );
        if (!published) {
            warning("Failed to publish imported sticker pack %s to PEP", pack_id);
        }
        ensure_pack_not_removed(account, pack_id);

        return parsed_pack;
    }

    private void ensure_pack_not_removed(Account account, string pack_id) throws Error {
        if (db.query_column_checked(
                "SELECT 1 FROM sticker_pack WHERE account_id = ? AND pack_id = ? LIMIT 1",
                { account.id.to_string(), pack_id }).length == 0) {
            throw new StickerError.NOT_FOUND("Sticker pack was removed");
        }
    }

    private void ensure_account_not_removed(Account account) throws Error {
        if (db.query_column_checked("SELECT 1 FROM account WHERE id = ? LIMIT 1",
                { account.id.to_string() }).length == 0) {
            throw new StickerError.NOT_FOUND("Account was removed");
        }
    }

    public async StickerPack preview_pack(Account account, Jid source_jid, string node, string pack_id) throws Error {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new StickerError.NOT_CONNECTED("Not connected");

        StanzaNode? pack_node = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).request_item(stream, source_jid, node, pack_id);
        if (pack_node == null) throw new StickerError.NOT_FOUND("Sticker pack not found");
        if (pack_node.name != "pack" || pack_node.ns_uri != Xmpp.Xep.Stickers.NS_URI) {
            throw new StickerError.INVALID_URI("PubSub item is not a sticker pack");
        }

        var parsed_pack = parse_pack(pack_node);
        parsed_pack.pack_id = pack_id;
        parsed_pack.source_jid = source_jid.to_string();
        parsed_pack.source_node = node;

        if (parsed_pack.restricted) throw new StickerError.RESTRICTED("Sticker pack is restricted");

        return parsed_pack;
    }

    public void remove_pack(Account account, string pack_id) throws Error {
        if (is_pack_publishing(account, pack_id)) {
            throw new StickerError.PUBLISH_FAILED("Sticker pack is being published");
        }
        // Remove DB entries
        string pack_id_escaped = pack_id.replace("'", "''");
        db.exec(@"DELETE FROM sticker_item WHERE account_id=$(account.id) AND pack_id='$(pack_id_escaped)'");
        db.exec(@"DELETE FROM sticker_pack WHERE account_id=$(account.id) AND pack_id='$(pack_id_escaped)'");

        // Files and thumbnails are shared by all accounts importing a pack.
        // Check items too, so an incomplete older database never loses a
        // still-referenced file just because its pack metadata is missing.
        if (db.query_column_checked(
                "SELECT 1 FROM sticker_pack WHERE pack_id = ? UNION ALL " +
                "SELECT 1 FROM sticker_item WHERE pack_id = ? LIMIT 1",
                { pack_id, pack_id }).length > 0) return;

        File pack_dir = File.new_for_path(get_pack_dir(pack_id));
        File stickers_dir = File.new_for_path(get_stickers_dir());
        // Imported PubSub IDs are not filesystem names. Keep legacy nested
        // paths usable, but never recursively remove the cache root or escape it.
        if (!pack_dir.has_prefix(stickers_dir)) return;
        File? parent = pack_dir.get_parent();
        while (parent != null && !parent.equal(stickers_dir)) {
            // NOFOLLOW on the final file does not cover an intermediate link
            // in a legacy nested pack ID. Never traverse those either.
            if (parent.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) != FileType.DIRECTORY) return;
            parent = parent.get_parent();
        }

        // Legacy IDs may contain '/': removing their parent must also preserve
        // a different pack's nested cache, or any legacy item path inside it.
        foreach (string remaining_id in db.query_column_checked(
                "SELECT pack_id FROM sticker_pack UNION SELECT pack_id FROM sticker_item")) {
            File remaining_dir = File.new_for_path(get_pack_dir(remaining_id));
            if (remaining_dir.equal(pack_dir) || remaining_dir.has_prefix(pack_dir)) return;
        }
        foreach (string path in db.query_column_checked(
                "SELECT local_path FROM sticker_item WHERE local_path IS NOT NULL AND local_path != ''")) {
            File remaining_file = File.new_for_path(path);
            if (remaining_file.equal(pack_dir) || remaining_file.has_prefix(pack_dir)) return;
        }

        // Remove unreferenced downloaded files (best-effort).
        try {
            delete_dir_recursive(pack_dir);
        } catch (Error e) {
            // best effort; DB removal is the important part
            warning("Failed to remove sticker pack dir %s: %s", pack_dir.get_path(), e.message);
        }
    }

    public async void send_sticker(Conversation conversation, string pack_id, StickerItem item) throws Error {
        if (item.local_path == null) throw new StickerError.DOWNLOAD_FAILED("Sticker file not available locally");

        var file_manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);

        var cfg = new OutgoingStickerConfig(pack_id, (item.desc != null && item.desc != "") ? item.desc : null);
        File sticker_file = File.new_for_path(item.local_path);
        OutgoingFileSource source = get_outgoing_source_for_path(
                item.local_path, get_stickers_dir());

        FileTransfer? sent_transfer = null;
        yield file_manager.send_file_with_source(
                sticker_file, conversation, source, (file_transfer) => {
            sent_transfer = file_transfer;
            file_transfer.is_sticker = true;
            file_transfer.sticker_pack_id = cfg.pack_id;
            file_transfer.sticker_pack_node = STICKERS_NODE;
            file_transfer.sticker_pack_jid = null;

            // Ensure fallback body is emoji-like desc if we have it
            if (cfg.desc != null) {
                file_transfer.desc = cfg.desc;
            }
        });
        // FileManager reports preparation/transport failures through the
        // transfer state rather than throwing. Surface that result to the UI.
        if (sent_transfer == null) {
            throw new StickerError.DOWNLOAD_FAILED("Sticker file could not be prepared for sending");
        }
        if (((!) sent_transfer).phase == FileTransfer.Phase.FAILED) {
            throw new StickerError.DOWNLOAD_FAILED(
                    ((!) sent_transfer).phase_error ?? "Sticker could not be sent");
        }
    }

    private class OutgoingStickerConfig : Object {
        public string pack_id { get; construct; }
        public string? desc { get; construct; }

        public OutgoingStickerConfig(string pack_id, string? desc) {
            Object(
                pack_id: pack_id.dup(),
                desc: desc != null ? ((!)desc).dup() : null
            );
        }
    }

    private async void download_to_file(string url, string dest_path, Account account, string pack_id) throws Error {
        yield ensure_http_context();
        ensure_pack_not_removed(account, pack_id);
        Soup.Session http = (Soup.Session) http_sessions.get_session(account);
        /* Validate URL before passing to libsoup — Soup.Message()
         * returns null for unparseable URIs, causing a crash. */
        try {
            Uri.parse(url, UriFlags.NONE);
        } catch (Error e) {
            throw new StickerError.DOWNLOAD_FAILED("Invalid URL: %s".printf(e.message));
        }
        Soup.Message? nullable_msg = new Soup.Message("GET", url);
        if (nullable_msg == null) {
            throw new StickerError.DOWNLOAD_FAILED("Invalid URL: HTTP request could not be created");
        }
        Soup.Message msg = (!) nullable_msg;
        var bytes = yield http.send_and_read_async(msg, GLib.Priority.LOW, null);
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new StickerError.DOWNLOAD_FAILED(@"HTTP $(msg.status_code)" );
        }

        ensure_pack_not_removed(account, pack_id);
        string pending_path = new_pending_sticker_path();
        try {
            // PBKDF2 and disk writes must not run on the GTK/libsoup context.
            // Keep the immutable response bytes alive until the worker finishes.
            yield FileTransferWorker.run("store-downloaded-sticker", () => {
                encrypt_sticker_to_pending(bytes, pending_path);
            });
            ensure_pack_not_removed(account, pack_id);
            commit_pending_sticker(pending_path, dest_path, true);
        } finally {
            discard_pending_sticker(pending_path);
        }
    }

    private static string new_pending_sticker_path() {
        return Path.build_filename(get_stickers_dir(), ".import-" + Uuid.string_random() + ".part");
    }

    private void encrypt_sticker_to_pending(Bytes bytes, string pending_path) throws Error {
        var pending = File.new_for_path(pending_path);
        var input = new MemoryInputStream.from_bytes(bytes);
        OutputStream? output = null;
        try {
            output = pending.create(FileCreateFlags.PRIVATE);
            file_encryption.encrypt_stream_sync(input, (!) output);
            ((!) output).close();
            output = null;
        } finally {
            if (output != null) {
                try { ((!) output).close(); } catch (Error ignored) { }
            }
            try { input.close(); } catch (Error ignored) { }
        }
    }

    private static void commit_pending_sticker(string pending_path, string dest_path, bool overwrite) throws Error {
        // Both paths are in the sticker cache, so this is a short same-filesystem
        // rename. Commit it without yielding after the main-context DB guard.
        if (!overwrite && FileUtils.test(dest_path, FileTest.EXISTS)) return;
        DirUtils.create_with_parents(Path.get_dirname(dest_path), 0700);
        File.new_for_path(pending_path).move(File.new_for_path(dest_path),
                overwrite ? FileCopyFlags.OVERWRITE : FileCopyFlags.NONE);
    }

    private static void discard_pending_sticker(string pending_path) {
        try { File.new_for_path(pending_path).delete(); } catch (Error ignored) { }
    }

    public async string create_pack_from_folder(Account account, string folder_path, bool publish) throws Error {
        string pack_id = yield create_local_pack_from_folder(account, folder_path);
        if (!publish) return "";
        return yield publish_pack(account, pack_id);
    }

    public async string create_local_pack_from_folder(Account account, string folder_path) throws Error {
        return yield create_local_pack_from_folder_with_progress(account, folder_path);
    }

    public async string create_local_pack_from_folder_with_progress(Account account, string folder_path,
            StickerImportProgress? progress = null) throws Error {
        string pack_id = Xmpp.random_uuid();
        string key = account.id.to_string() + ":" + pack_id;
        importing_packs.add(key);
        try {
            return yield create_local_pack_from_folder_internal(account, folder_path, pack_id, progress);
        } finally {
            importing_packs.remove(key);
            importing_changed(account, pack_id, false);
        }
    }

    private async string create_local_pack_from_folder_internal(Account account, string folder_path,
            string pack_id, StickerImportProgress? progress) throws Error {
        File folder = File.new_for_path(folder_path);
        var folder_info = yield folder.query_info_async("standard::type", FileQueryInfoFlags.NONE, Priority.LOW);
        if (folder_info.get_file_type() != FileType.DIRECTORY) throw new StickerError.INVALID_URI("Not a folder");
        ensure_account_not_removed(account);

        string name = folder.get_basename() ?? pack_id;

        string pack_dir = Path.build_filename(get_stickers_dir(), pack_id);

        // Store pack metadata
        db.sticker_pack.upsert()
            .value(db.sticker_pack.account_id, account.id, true)
            .value(db.sticker_pack.pack_id, pack_id, true)
            .value(db.sticker_pack.source_jid, "")
            .value(db.sticker_pack.source_node, "")
            .value(db.sticker_pack.name, name)
            .value(db.sticker_pack.summary, "")
            .value(db.sticker_pack.restricted, false)
            .perform();
        importing_changed(account, pack_id, true);
        ensure_pack_not_removed(account, pack_id);

        // Ensure we don't collide
        db.exec(@"DELETE FROM sticker_item WHERE account_id=$(account.id) AND pack_id='$(pack_id.replace("'", "''"))'");

        FileEnumerator? enumerator = null;
        int completed = 0;
        try {
            enumerator = yield folder.enumerate_children_async(
                    "standard::name,standard::type,standard::content-type", FileQueryInfoFlags.NONE, Priority.LOW);
            ensure_pack_not_removed(account, pack_id);
            while (true) {
                // Bound the metadata retained and let GIO perform directory I/O
                // away from the main context, including for large non-image folders.
                var infos = yield enumerator.next_files_async(32, Priority.LOW);
                ensure_pack_not_removed(account, pack_id);
                if (infos.length() == 0) break;
                foreach (var info in infos) {
                    if (info.get_file_type() != FileType.REGULAR) continue;
                    string? content_type = normalize_mime_type(info.get_content_type(), info.get_name());
                    if (content_type == null || !content_type.has_prefix("image/")) continue;
                    string? path = folder.get_child(info.get_name()).get_path();
                    if (path == null || path == "") continue;

                    string pending_path = new_pending_sticker_path();
                    string? hash_value = null;
                    string local_path = "";
                    try {
                        // One image at a time: no whole-pack byte buffering, no
                        // database or stream state may be touched by this worker.
                        yield FileTransferWorker.run("import-local-sticker", () => {
                            Bytes bytes = File.new_for_path(path).load_bytes(null, null);
                            var hash = new Xmpp.Xep.CryptographicHashes.Hash.compute(ChecksumType.SHA256, bytes.get_data());
                            hash_value = hash.val;
                            encrypt_sticker_to_pending(bytes, pending_path);
                        });
                        ensure_pack_not_removed(account, pack_id);
                        local_path = Path.build_filename(pack_dir,
                                filename_safe_base64((!) hash_value) + guess_extension(content_type));
                        commit_pending_sticker(pending_path, local_path, false);
                    } finally {
                        discard_pending_sticker(pending_path);
                    }

                    var it = new StickerItem();
                    it.pack_id = pack_id;
                    it.position = completed;
                    it.media_type = content_type;
                    it.hash_algo = "sha-256";
                    it.hash_value = hash_value;
                    it.local_path = local_path;
                    maybe_generate_thumbnail(pack_id, it);

                    db.sticker_item.insert()
                        .value(db.sticker_item.account_id, account.id)
                        .value(db.sticker_item.pack_id, pack_id)
                        .value(db.sticker_item.position, it.position)
                        .value(db.sticker_item.desc, it.desc)
                        .value(db.sticker_item.media_type, it.media_type)
                        .value(db.sticker_item.hash_algo, it.hash_algo)
                        .value(db.sticker_item.hash_value, it.hash_value)
                        .value(db.sticker_item.source_url, it.source_url)
                        .value(db.sticker_item.local_path, it.local_path)
                        .perform();
                    completed++;
                    if (progress != null) progress(completed, 0);
                }
            }
            if (completed == 0) throw new StickerError.NOT_FOUND("No images found in folder");
        } catch (Error e) {
            // A failed import must not leave an incomplete library entry. This
            // is separate from a later publication failure, which keeps the pack.
            try { remove_pack(account, pack_id); } catch (Error ignored) { }
            throw e;
        } finally {
            if (enumerator != null) {
                try { enumerator.close(); } catch (Error ignored) { }
            }
        }

        return pack_id;
    }

    public async string publish_pack(Account account, string pack_id) throws Error {
        if (is_pack_importing(account, pack_id)) {
            throw new StickerError.PUBLISH_FAILED("Sticker pack is being imported");
        }
        string key = account.id.to_string() + ":" + pack_id;
        if (!publishing_packs.add(key)) {
            throw new StickerError.PUBLISH_FAILED("Sticker pack is already being published");
        }
        publishing_changed(account, pack_id, true);
        try {
            return yield publish_pack_internal(account, pack_id);
        } finally {
            publishing_packs.remove(key);
            publishing_changed(account, pack_id, false);
        }
    }

    public bool is_pack_publishing(Account account, string pack_id) {
        return publishing_packs.contains(account.id.to_string() + ":" + pack_id);
    }

    public bool is_pack_importing(Account account, string pack_id) {
        return importing_packs.contains(account.id.to_string() + ":" + pack_id);
    }

    private async string publish_pack_internal(Account account, string pack_id) throws Error {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new StickerError.NOT_CONNECTED("Not connected");

        // Load pack metadata
        StickerPack? pack = null;
        foreach (var p in get_packs(account)) {
            if (p.pack_id == pack_id) {
                pack = p;
                break;
            }
        }
        if (pack == null) throw new StickerError.NOT_FOUND("Sticker pack not found");
        if (pack.restricted) throw new StickerError.RESTRICTED("Sticker pack is restricted");

        // Ensure we have items
        var items = get_items(account, pack_id);
        if (items.size == 0) throw new StickerError.NOT_FOUND("Sticker pack is empty");

        var upload = stream.get_module<Xmpp.Xep.HttpFileUpload.Module>(Xmpp.Xep.HttpFileUpload.Module.IDENTITY);
        if (upload == null) throw new StickerError.PUBLISH_FAILED("HTTP File Upload (XEP-0363) is not available");

        var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
        if (pubsub == null) throw new StickerError.PUBLISH_FAILED("PubSub module unavailable");

        // Upload any item that doesn't have a source URL yet.
        // Sticker files on disk are encrypted at rest (AES-256-GCM). We must
        // decrypt to a temp file before uploading so recipients get usable data
        // and the reported size matches the plaintext content.
        foreach (var it in items) {
            if (it.source_url != null && it.source_url != "") continue;
            if (it.local_path == null || it.local_path == "") {
                warning("Sticker item has no local path; skipping upload");
                continue;
            }

            ensure_pack_not_removed(account, pack_id);
            // Decrypt the at-rest file to a temp location for upload. Streaming
            // decryption and PBKDF2 run on the existing file worker.
            string temp_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-sticker-upload-" + Uuid.string_random());
            File temp_file = File.new_for_path(temp_path);
            string source_path = it.local_path;
            bool temp_owned = false;
            try {
                int64 size = -1;
                yield FileTransferWorker.run("prepare-sticker-upload", () => {
                    var output = temp_file.create(FileCreateFlags.PRIVATE);
                    temp_owned = true;
                    file_encryption.decrypt_file_to_stream_sync(File.new_for_path(source_path), output);
                    size = temp_file.query_info("standard::size", FileQueryInfoFlags.NONE).get_size();
                });
                ensure_pack_not_removed(account, pack_id);

                string filename = File.new_for_path(source_path).get_basename() ?? (it.hash_value ?? Xmpp.random_uuid());
                string? ct = (it.media_type != null && it.media_type != "") ? it.media_type : "application/octet-stream";
                var slot = yield upload.request_slot(stream, filename, size, ct);
                ensure_pack_not_removed(account, pack_id);
                yield upload_file_to_slot(slot.url_put, slot.headers, temp_file, ct, size, account.domainpart, account);
                ensure_pack_not_removed(account, pack_id);

                it.source_url = slot.url_get;

                // Older DBs don't have a UNIQUE constraint needed for UPSERT.
                db.sticker_item.update()
                    .with(db.sticker_item.account_id, "=", account.id)
                    .with(db.sticker_item.pack_id, "=", pack_id)
                    .with(db.sticker_item.position, "=", it.position)
                    .set(db.sticker_item.desc, it.desc)
                    .set(db.sticker_item.media_type, it.media_type)
                    .set(db.sticker_item.hash_algo, it.hash_algo)
                    .set(db.sticker_item.hash_value, it.hash_value)
                    .set(db.sticker_item.source_url, it.source_url)
                    .set(db.sticker_item.local_path, it.local_path)
                    .perform();
            } finally {
                if (temp_owned) {
                    try { temp_file.delete(); } catch (Error ignored) { }
                }
            }
        }

        // Build and publish sticker pack to our PEP node
        StanzaNode pack_node = build_pack_node(pack.name, pack.summary, items);
        var bind = stream.get_flag(Xmpp.Bind.Flag.IDENTITY);
        if (bind == null || bind.my_jid == null) throw new StickerError.NOT_CONNECTED("Not connected");
        var my_jid = bind.my_jid.bare_jid;
        bool published = yield pubsub.publish(
            stream,
            my_jid,
            STICKERS_NODE,
            pack_id,
            pack_node,
            new Pubsub.PublishOptions().set_persist_items(true).set_max_items("max").set_send_last_published_item("never").set_access_model(Pubsub.ACCESS_MODEL_OPEN)
        );
        if (!published) throw new StickerError.PUBLISH_FAILED("Failed to publish sticker pack");
        // Account deletion can remove the metadata while the PEP IQ yields.
        // A late result must not recreate that account's library entry.
        ensure_pack_not_removed(account, pack_id);

        // Store source info for sharing
        db.sticker_pack.upsert()
            .value<int>(db.sticker_pack.account_id, account.id, true)
            .value<string>(db.sticker_pack.pack_id, pack_id, true)
            .value<string>(db.sticker_pack.source_jid, my_jid.to_string())
            .value<string>(db.sticker_pack.source_node, STICKERS_NODE)
            .value<string>(db.sticker_pack.name, pack.name ?? pack_id)
            .value<string>(db.sticker_pack.summary, pack.summary ?? "")
            .value<bool>(db.sticker_pack.restricted, false)
            .perform();

        string node_enc = Uri.escape_string(STICKERS_NODE, null, false);
        string item_enc = Uri.escape_string(pack_id, null, false);
        return @"xmpp:$(my_jid.to_string())?pubsub;action=retrieve;node=$(node_enc);item=$(item_enc)";
    }

    private async void upload_file_to_slot(string url_put, Gee.Map<string, string>? headers, File file, string? content_type, int64 size, string cert_domain, Account? account = null) throws Error {
        yield ensure_http_context();
        Soup.Session http = (Soup.Session) (account != null
            ? http_sessions.get_session((!) account)
            : http_sessions.get_default_session());
        /* Validate URL before passing to libsoup */
        try {
            Uri.parse(url_put, UriFlags.NONE);
        } catch (Error e) {
            throw new IOError.INVALID_ARGUMENT("Invalid upload URL: %s".printf(e.message));
        }
        Soup.Message? nullable_put_message = new Soup.Message("PUT", url_put);
        if (nullable_put_message == null) {
            throw new IOError.INVALID_ARGUMENT("Invalid upload URL: HTTP request could not be created");
        }
        Soup.Message put_message = (!) nullable_put_message;
        InputStream? input_stream = null;
        try {
#if SOUP_3_0
            put_message.accept_certificate.connect((peer_cert, errors) => { return ConnectionManager.on_invalid_certificate(cert_domain, peer_cert, errors, db); });
            input_stream = file.read(null);
            string ct = (content_type != null && content_type != "") ? content_type : "application/octet-stream";
            put_message.set_request_body(ct, (!) input_stream, (ssize_t) size);
#else
            // Older libsoup not supported here
#endif

            if (headers != null) {
                foreach (var entry in headers.entries) {
                    put_message.request_headers.append(entry.key, entry.value);
                }
            }

            yield http.send_async(put_message, GLib.Priority.LOW, null);
            if (put_message.status_code < 200 || put_message.status_code >= 300) {
                throw new StickerError.DOWNLOAD_FAILED(@"HTTP $(put_message.status_code)" );
            }
        } finally {
            // In particular on Windows, close the body file before the caller
            // tries to remove its plaintext staging file after success/failure.
            if (input_stream != null) {
                try { ((!) input_stream).close(); } catch (Error ignored) { }
            }
        }
    }

    private static StanzaNode build_pack_node(string? name, string? summary, Gee.List<StickerItem> items) {
        StanzaNode pack_node = new StanzaNode.build("pack", Xmpp.Xep.Stickers.NS_URI).add_self_xmlns();
        if (name != null && name != "") {
            pack_node.put_node(new StanzaNode.build("name", Xmpp.Xep.Stickers.NS_URI).put_node(new StanzaNode.text(name)));
        }
        if (summary != null && summary != "") {
            pack_node.put_node(new StanzaNode.build("summary", Xmpp.Xep.Stickers.NS_URI).put_node(new StanzaNode.text(summary)));
        }

        foreach (var it in items) {
            StanzaNode item_node = new StanzaNode.build("item", Xmpp.Xep.Stickers.NS_URI);

            var meta = new Xmpp.Xep.FileMetadataElement.FileMetadata();
            if (it.local_path != null) {
                meta.name = Path.get_basename(it.local_path);
            }
            meta.mime_type = it.media_type;
            meta.size = -1;
            if (it.local_path != null) {
                try {
                    var finfo = File.new_for_path(it.local_path).query_info("standard::size", FileQueryInfoFlags.NONE, null);
                    meta.size = finfo.get_size();
                } catch (Error e) {
                    meta.size = -1;
                }
            }
            if (it.hash_value != null && it.hash_algo != null) {
                ChecksumType? t = Xmpp.Xep.CryptographicHashes.hash_string_to_type(it.hash_algo);
                if (t != null) {
                    meta.hashes.add(new Xmpp.Xep.CryptographicHashes.Hash.with_checksum(t, it.hash_value));
                }
            }
            item_node.put_node(meta.to_stanza_node());

            if (it.source_url != null) {
                StanzaNode sources_node = new StanzaNode.build("sources", Xmpp.Xep.StatelessFileSharing.NS_URI).add_self_xmlns();
                sources_node.put_node(Xmpp.Xep.HttpSchemeForUrlData.to_stanza_node(it.source_url));
                item_node.put_node(sources_node);
            }

            pack_node.put_node(item_node);
        }

        return pack_node;
    }

    private static void delete_dir_recursive(File file) throws Error {
        FileType t;
        try {
            var info = file.query_info("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            t = info.get_file_type();
        } catch (Error e) {
            // Doesn't exist or not accessible
            return;
        }

        if (t == FileType.DIRECTORY) {
            var enumerator = file.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            FileInfo child_info;
            while ((child_info = enumerator.next_file(null)) != null) {
                var child = file.get_child(child_info.get_name());
                delete_dir_recursive(child);
            }
            enumerator.close(null);
            try {
                file.delete(null);
            } catch (Error e) {
                // might be non-empty due to races; ignore
            }
        } else {
            try {
                file.delete(null);
            } catch (Error e) {
                // ignore
            }
        }
    }

    private static string guess_extension(string? media_type) {
        if (media_type == null) return "";
        switch (media_type) {
            case "image/png": return ".png";
            case "image/gif": return ".gif";
            case "image/webp": return ".webp";
            case "image/jpeg": return ".jpg";
            case "image/svg+xml": return ".svg";
            default: return "";
        }
    }

    private static StickerPack parse_pack(StanzaNode pack_node) {
        var pack = new StickerPack();
        // name/summary: pick first without lang preference
        var name_node = pack_node.get_subnode("name", Xmpp.Xep.Stickers.NS_URI);
        if (name_node != null) pack.name = name_node.get_string_content();
        var summary_node = pack_node.get_subnode("summary", Xmpp.Xep.Stickers.NS_URI);
        if (summary_node != null) pack.summary = summary_node.get_string_content();
        pack.restricted = pack_node.get_subnode("restricted", Xmpp.Xep.Stickers.NS_URI) != null;
        return pack;
    }

    private static Gee.List<StickerItem> parse_items(StanzaNode pack_node, string pack_id) {
        var items = new ArrayList<StickerItem>();
        foreach (var item_node in pack_node.get_subnodes("item", Xmpp.Xep.Stickers.NS_URI)) {
            var it = new StickerItem();
            it.pack_id = pack_id;

            var metadata = Xep.FileMetadataElement.get_file_metadata(item_node);
            if (metadata != null) {
                it.desc = metadata.desc;
                it.media_type = metadata.mime_type;
                if (metadata.hashes.size > 0) {
                    // pick first
                    it.hash_algo = metadata.hashes[0].algo;
                    it.hash_value = metadata.hashes[0].val;
                }
            }

            var sources_node = item_node.get_subnode("sources", Xep.StatelessFileSharing.NS_URI);
            if (sources_node != null) {
                it.source_url = Xep.HttpSchemeForUrlData.get_url(sources_node);
            }

            items.add(it);
        }
        return items;
    }
}

}
