using Dino.Entities;
using Dino.Security;

namespace Dino.Test {

[CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
private extern void set_sticker_server_response(Soup.ServerMessage message, string? content_type,
    Soup.MemoryUse memory_use, string response_body, size_t response_length);

class StickersTest : Gee.TestCase {
    public StickersTest() {
        base("Stickers");
        add_test("removing_one_account_preserves_shared_files_until_last_reference", test_shared_pack);
        add_test("remaining_item_without_pack_metadata_preserves_cache", test_item_reference);
        add_test("nested_pubsub_id_preserves_other_pack_cache", test_nested_pack);
        add_test("legacy_item_path_preserves_other_pack_cache", test_legacy_item_path);
        add_test("traversal_and_cache_root_ids_never_delete_profile_files", test_unsafe_ids);
        add_test("folder_content_types_accept_windows_extensions", test_folder_content_types);
        add_test("folder_content_types_preserve_mime_and_generic_fallbacks", test_folder_content_type_fallbacks);
        add_test("technical_mime_and_extensions_ignore_system_case_rules", test_mime_locale);
#if !WINDOWS
        add_test("removal_never_follows_final_or_intermediate_links", test_symlinks);
#endif
        add_test("local_folder_creation_preserves_pack_after_publish_failure", test_local_folder_sync);
        add_test("empty_folder_creation_leaves_no_pack", test_empty_folder_sync);
        add_test("raster_folder_import_keeps_main_context_responsive", test_folder_heartbeat_sync);
        add_test("folder_removed_during_encryption_does_not_reappear", test_folder_removal_sync);
        add_test("xmpp_raster_download_storage_keeps_main_context_responsive", test_xmpp_heartbeat_sync);
        add_test("account_removed_during_xmpp_storage_preserves_other_account_cache", test_xmpp_removal_sync);
        add_test("upload_preparation_is_responsive_and_cleans_plaintext_on_failure", test_upload_cleanup_sync);
        add_test("import_guard_is_account_scoped_and_fetch_cannot_recreate_removed_account", test_import_guard_sync);
        add_test("send_preparation_failure_reaches_sticker_caller", test_send_failure_sync);
        add_test("publication_guard_is_account_scoped_and_removed_pack_is_not_recreated", test_publication_guard_sync);
    }

    private class Fixture : Object {
        public string root;
        public string cache_id;
        public string cache_dir;
        public Database db;
        public StreamInteractor interactor;
        public FileEncryption encryption;
        public Stickers stickers;
        public Account first;
        public Account second;
        public Gee.ArrayList<string> created_packs = new Gee.ArrayList<string>();

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-sticker-regression-XXXXXX");
            cache_id = "sticker-regression-" + Uuid.string_random();
            cache_dir = Path.build_filename(Stickers.get_stickers_dir(), cache_id);
            DirUtils.create_with_parents(cache_dir, 0700);
            db = new Database(Path.build_filename(root, "dino.db"), "sticker regression password");
            interactor = new StreamInteractor.for_tests(db);
            encryption = new FileEncryption("sticker regression password");
            Stickers.start(interactor, db, encryption);
            stickers = interactor.get_module<Stickers>(Stickers.IDENTITY);
            first = new Account(new Xmpp.Jid("first@example.test"), "one");
            second = new Account(new Xmpp.Jid("second@example.test"), "two");
            first.persist(db);
            second.persist(db);
        }

        public string pack_id(string name) {
            return cache_id + "/" + name;
        }

        public string path(string id, string name) {
            string directory = Path.build_filename(Stickers.get_stickers_dir(), id);
            DirUtils.create_with_parents(directory, 0700);
            return Path.build_filename(directory, name);
        }

        public void add_pack(Account account, string id, string? local_path = null) {
            db.sticker_pack.insert()
                .value(db.sticker_pack.account_id, account.id)
                .value(db.sticker_pack.pack_id, id)
                .value(db.sticker_pack.name, "Regression pack")
                .perform();
            if (local_path == null) return;
            add_item(account, id, local_path);
        }

        public void add_item(Account account, string id, string local_path) {
            db.sticker_item.insert()
                .value(db.sticker_item.account_id, account.id)
                .value(db.sticker_item.pack_id, id)
                .value(db.sticker_item.position, 0)
                .value(db.sticker_item.local_path, local_path)
                .perform();
        }

        public void close() {
            stickers.shutdown();
            foreach (string id in created_packs) {
                try { stickers.remove_pack(first, id); } catch (Error ignored) { }
            }
            db.close();
            cleanup(File.new_for_path(cache_dir));
            cleanup(File.new_for_path(root));
        }
    }

    private static void cleanup(File file) {
        try {
            if (file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
                var children = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? child;
                while ((child = children.next_file()) != null) cleanup(file.get_child(child.get_name()));
                children.close();
            }
            file.delete();
        } catch (Error ignored) { }
    }

    private class Heartbeat : Object {
        public int ticks = 0;
        public int64 longest_gap = 0;
        private int64 last_tick;
        private uint source_id = 0;

        public void start() {
            last_tick = get_monotonic_time();
            source_id = Timeout.add(5, () => {
                tick();
                ticks++;
                return Source.CONTINUE;
            });
        }

        private void tick() {
            int64 now = get_monotonic_time();
            longest_gap = int64.max(longest_gap, now - last_tick);
            last_tick = now;
        }

        public void stop() {
            if (source_id == 0) return;
            tick();
            Source.remove(source_id);
            source_id = 0;
        }
    }

    private static Bytes raster_bytes(uint32 color) throws Error {
        var pixbuf = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 512, 512);
        pixbuf.fill(color);
        uint8[] bytes;
        // BMP is a real raster format with sizeable source bytes; it avoids the
        // independent thumbnail worker's best-effort lifetime in this fixture.
        pixbuf.save_to_bufferv(out bytes, "bmp", null, null);
        return new Bytes(bytes);
    }

    private void test_folder_content_types() {
        foreach (string extension in new string[] { ".svg", ".bmp", ".PNG", ".jpeg" }) {
            string filename = "sticker" + extension;
            fail_if(!Dino.normalize_mime_type(extension, filename).has_prefix("image/"),
                "Windows extension content types must remain eligible for folder import");
            fail_if(!Dino.normalize_mime_type(extension).has_prefix("image/"),
                "known image extensions must normalize even without a separate filename");
        }
        fail_if_not_eq_str(Dino.normalize_mime_type(".txt", "notes.txt"), "text/plain");
        fail_if_not_eq_str(Dino.normalize_mime_type(".dinox-sticker-unknown"), "application/octet-stream");
        fail_if_not_eq_str(Dino.normalize_mime_type(".invalid/type", "sticker.bmp"), "image/bmp");
        fail_if_not_eq_str(Dino.normalize_mime_type(".invalid/type"), "application/octet-stream");
    }

    private void test_folder_content_type_fallbacks() {
        fail_if_not_eq_str(Dino.normalize_mime_type("image/bmp", "sticker.bmp"), "image/bmp");
        fail_if_not_eq_str(Dino.normalize_mime_type("application/pdf", "sticker.svg"), "application/pdf");
        fail_if_not_eq_str(Dino.normalize_mime_type(null, "sticker.svg"), "image/svg+xml");
        fail_if_not_eq_str(Dino.normalize_mime_type("application/octet-stream", "sticker.bmp"), "image/bmp");
        fail_if_not_eq_str(Dino.normalize_mime_type("application/x-ext-svg", "sticker.svg"), "image/svg+xml");
        fail_if_not_eq_str(Dino.normalize_mime_type("image", "sticker.bmp"), "image/bmp");
        fail_if_not_eq_str(Dino.normalize_mime_type("image"), "image/png");
        fail_if_not_eq_str(Dino.normalize_mime_type("text"), "text/plain");
    }

    private void test_mime_locale() {
        string? previous = Intl.setlocale(LocaleCategory.CTYPE, null);
        if (Intl.setlocale(LocaleCategory.CTYPE, "") == null) {
            GLib.Test.skip("Requested system character locale is unavailable");
            return;
        }
        try {
            GLib.Test.message("MIME character locale: %s", Intl.setlocale(LocaleCategory.CTYPE, null));
            fail_if_not_eq_str(Dino.mime_type_from_filename("日本語.GIF"), "image/gif");
            fail_if_not_eq_str(Dino.mime_type_from_filename("Türkçe.AVI"), "video/x-msvideo");
            fail_if_not_eq_str(Dino.mime_type_from_filename("العربية.HEIC"), "image/heic");
            fail_if_not_eq_str(Dino.normalize_mime_type("IMAGE"), "image/png");
            fail_if_not_eq_str(Dino.normalize_mime_type("VIDEO"), "video/mp4");
            fail_if_not_eq_str(Dino.normalize_mime_type("AUDIO"), "audio/mpeg");
            fail_if_not_eq_str(Dino.normalize_mime_type("APPLICATION/OCTET-STREAM", "clip.AVI"), "video/x-msvideo");
            fail_if_not(Dino.Util.is_pixbuf_supported_mime_type("IMAGE/PNG"));
            fail_if_not(Dino.Util.is_supported_image_filename("العربية.GIF"));
        } finally {
            Intl.setlocale(LocaleCategory.CTYPE, previous);
        }
    }

    private static Gee.HashSet<string> pending_paths() throws Error {
        var paths = new Gee.HashSet<string>();
        var directory = Dir.open(Stickers.get_stickers_dir());
        string? name;
        while ((name = directory.read_name()) != null) {
            if (name.has_prefix(".import-") && name.has_suffix(".part")) {
                paths.add(Path.build_filename(Stickers.get_stickers_dir(), name));
            }
        }
        return paths;
    }

    private static Gee.HashSet<string> upload_temp_paths() throws Error {
        var paths = new Gee.HashSet<string>();
        var directory = Dir.open(Environment.get_tmp_dir());
        string? name;
        while ((name = directory.read_name()) != null) {
            if (name.has_prefix("dinox-sticker-upload-")) {
                paths.add(Path.build_filename(Environment.get_tmp_dir(), name));
            }
        }
        return paths;
    }

    private static Xmpp.StanzaNode remote_pack(Bytes image, string url) {
        var pack = new Xmpp.StanzaNode.build("pack", Xmpp.Xep.Stickers.NS_URI).add_self_xmlns();
        var metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata();
        metadata.mime_type = "image/bmp";
        metadata.size = (int64) image.get_size();
        metadata.hashes.add(new Xmpp.Xep.CryptographicHashes.Hash.compute(ChecksumType.SHA256, image.get_data()));
        return pack.put_node(new Xmpp.StanzaNode.build("item", Xmpp.Xep.Stickers.NS_URI)
            .put_node(metadata.to_stanza_node())
            .put_node(new Xmpp.StanzaNode.build("sources", Xmpp.Xep.StatelessFileSharing.NS_URI)
                .put_node(Xmpp.Xep.HttpSchemeForUrlData.to_stanza_node(url))));
    }

    private static Xmpp.StanzaNode pubsub_pack_response(string id, Xmpp.StanzaNode pack) {
        return new Xmpp.StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI)
            .put_node(new Xmpp.StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                .put_node(new Xmpp.StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI).put_attribute("id", id).put_node(pack)));
    }

    private void test_shared_pack() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string id = fixture.pack_id("shared");
            string path = fixture.path(id, "sticker.enc");
            FileUtils.set_data(path, fixture.encryption.encrypt_data("shared sticker bytes".data));
            string thumbnail = fixture.path(id + "/thumbs", "thumbnail.enc");
            FileUtils.set_contents(thumbnail, "shared thumbnail");
            fixture.add_pack(fixture.first, id, path);
            fixture.add_pack(fixture.second, id, path);

            fixture.stickers.remove_pack(fixture.first, id);
            fail_if(fixture.stickers.get_packs(fixture.first).size != 0, "removed account must lose its pack row");
            fail_if(fixture.stickers.get_items(fixture.first, id).size != 0, "removed account must lose its item rows");
            fail_if(fixture.stickers.get_packs(fixture.second).size != 1, "second account must retain its library");
            var remaining = fixture.stickers.get_items(fixture.second, id);
            if (!fail_if(remaining.size != 1, "second account must retain its item")) {
                Bytes? bytes = fixture.stickers.get_sticker_bytes(remaining[0]);
                fail_if(bytes == null || bytes.compare(new Bytes("shared sticker bytes".data)) != 0,
                    "second account must still read the shared encrypted sticker");
            }
            fail_if(!FileUtils.test(thumbnail, FileTest.EXISTS), "shared thumbnail must survive");

            fixture.stickers.remove_pack(fixture.second, id);
            fail_if(FileUtils.test(Path.get_dirname(path), FileTest.EXISTS), "last reference must remove files and thumbnails");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_item_reference() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string id = fixture.pack_id("item-only");
            string path = fixture.path(id, "sticker.enc");
            FileUtils.set_contents(path, "still referenced");
            fixture.add_pack(fixture.first, id, path);
            fixture.add_item(fixture.second, id, path);
            fixture.stickers.remove_pack(fixture.first, id);
            fail_if(!FileUtils.test(path, FileTest.EXISTS), "item reference must protect cache even without metadata");
            fixture.stickers.remove_pack(fixture.second, id);
            fail_if(FileUtils.test(path, FileTest.EXISTS), "last item reference must permit cleanup");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_nested_pack() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string parent_id = fixture.pack_id("base64+parent");
            string child_id = parent_id + "/child=";
            string path = fixture.path(child_id, "sticker.enc");
            FileUtils.set_contents(path, "nested pack sticker");
            fixture.add_pack(fixture.first, parent_id);
            fixture.add_pack(fixture.second, child_id, path);
            fixture.stickers.remove_pack(fixture.first, parent_id);
            fail_if(!FileUtils.test(path, FileTest.EXISTS), "slash-bearing PubSub ID must keep another nested pack");
            fixture.stickers.remove_pack(fixture.second, child_id);
            fail_if(FileUtils.test(path, FileTest.EXISTS), "nested pack must clean up after its own last reference");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_legacy_item_path() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string id = fixture.pack_id("legacy-path-owner");
            string path = fixture.path(id, "sticker.enc");
            FileUtils.set_contents(path, "legacy cross-pack path");
            fixture.add_pack(fixture.first, id);
            fixture.add_pack(fixture.second, fixture.pack_id("different-id"), path);
            fixture.stickers.remove_pack(fixture.first, id);
            fail_if(!FileUtils.test(path, FileTest.EXISTS), "other pack's legacy item path must keep its file");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_unsafe_ids() {
        Fixture? fixture = null;
        string? outside_dir = null;
        try {
            fixture = new Fixture();
            string sibling_name = "sticker-outside-" + Uuid.string_random();
            outside_dir = Path.build_filename(Dino.get_storage_dir(), sibling_name);
            DirUtils.create_with_parents(outside_dir, 0700);
            string outside_file = Path.build_filename(outside_dir, "preserve.enc");
            FileUtils.set_contents(outside_file, "profile sibling");
            string unsafe_id = "../" + sibling_name;
            fixture.add_pack(fixture.first, unsafe_id);
            fixture.stickers.remove_pack(fixture.first, unsafe_id);
            fail_if(!FileUtils.test(outside_file, FileTest.EXISTS), "traversal must never delete a profile sibling");

            string cache_file = fixture.path(fixture.pack_id("keep"), "preserve.enc");
            FileUtils.set_contents(cache_file, "cache root child");
            fixture.add_pack(fixture.first, ".");
            fixture.stickers.remove_pack(fixture.first, ".");
            fail_if(!FileUtils.test(cache_file, FileTest.EXISTS), "cache root ID must never clear the complete library");
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            if (fixture != null) fixture.close();
            if (outside_dir != null) cleanup(File.new_for_path(outside_dir));
        }
    }

#if !WINDOWS
    private void test_symlinks() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string target = Path.build_filename(fixture.root, "link-target");
            string nested = Path.build_filename(target, "nested");
            DirUtils.create_with_parents(nested, 0700);
            string marker = Path.build_filename(nested, "preserve.enc");
            FileUtils.set_contents(marker, "never follow a link");
            string id = fixture.pack_id("link");
            File.new_for_path(Path.build_filename(Stickers.get_stickers_dir(), id)).make_symbolic_link(target);
            fixture.add_pack(fixture.first, id + "/nested");
            fixture.stickers.remove_pack(fixture.first, id + "/nested");
            fail_if(!FileUtils.test(marker, FileTest.EXISTS), "intermediate symlink must not expose its target to deletion");
            fixture.add_pack(fixture.first, id);
            fixture.stickers.remove_pack(fixture.first, id);
            fail_if(!FileUtils.test(marker, FileTest.EXISTS), "final symlink target must survive recursive removal");
            fail_if(FileUtils.test(Path.build_filename(Stickers.get_stickers_dir(), id), FileTest.IS_SYMLINK),
                "unreferenced final symlink itself should be removed");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }
#endif

    private void test_local_folder_sync() {
        bool completed = false;
        test_local_folder.begin((obj, res) => { test_local_folder.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_local_folder() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string folder = Path.build_filename(fixture.root, "images");
            DirUtils.create(folder, 0700);
            // SVG avoids background raster thumbnail jobs in this isolated test.
            FileUtils.set_contents(Path.build_filename(folder, "sticker.svg"),
                "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>");
            string id = yield fixture.stickers.create_local_pack_from_folder(fixture.first, folder);
            fixture.created_packs.add(id);
            fail_if(id.length == 0, "local creation must return the stable pack ID");
            bool failed = false;
            try { yield fixture.stickers.publish_pack(fixture.first, id); }
            catch (StickerError.NOT_CONNECTED expected) { failed = true; }
            fail_if(!failed, "publishing through a disconnected account must fail");
            var packs = fixture.stickers.get_packs(fixture.first);
            fail_if(packs.size != 1 || packs[0].pack_id != id, "publish failure must preserve the one created pack");
            var items = fixture.stickers.get_items(fixture.first, id);
            fail_if(items.size != 1 || fixture.stickers.get_sticker_bytes(items[0]) == null,
                "publish failure must preserve usable local sticker bytes");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_empty_folder_sync() {
        bool completed = false;
        test_empty_folder.begin((obj, res) => { test_empty_folder.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_empty_folder() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            bool failed = false;
            try { yield fixture.stickers.create_local_pack_from_folder(fixture.first, fixture.root); }
            catch (StickerError.NOT_FOUND expected) { failed = true; }
            fail_if(!failed, "folder without images must report failure");
            fail_if(fixture.stickers.get_packs(fixture.first).size != 0, "empty creation must not leave a ghost pack");
            fail_if_not_eq_str(fixture.db.query_column_checked("SELECT count(*) FROM sticker_item")[0], "0");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_folder_heartbeat_sync() {
        bool completed = false;
        test_folder_heartbeat.begin((obj, res) => { test_folder_heartbeat.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_folder_heartbeat() {
        Fixture? fixture = null;
        var heartbeat = new Heartbeat();
        try {
            fixture = new Fixture();
            string folder = Path.build_filename(fixture.root, "rasters");
            DirUtils.create(folder, 0700);
            for (int i = 0; i < 4; i++) {
                var bytes = raster_bytes(0x204060ff + ((uint32) i << 24));
                FileUtils.set_data(Path.build_filename(folder, "sticker-%d.bmp".printf(i)), bytes.get_data());
            }
            int progress_count = 0;
            heartbeat.start();
            string id = yield fixture.stickers.create_local_pack_from_folder_with_progress(fixture.first, folder,
                (count, total) => {
                    fail_if(!MainContext.default().is_owner(), "progress must run on the main context");
                    fail_if(count != ++progress_count || total != 0, "folder progress must count persisted images without a second scan");
                    fail_if(fixture.stickers.get_packs(fixture.first).size != 1,
                        "progress must only report a live library pack");
                });
            heartbeat.stop();
            fixture.created_packs.add(id);
            fail_if(progress_count != 4, "all raster images must be persisted and reported");
            fail_if(heartbeat.ticks < 4, "main-context heartbeat must run repeatedly during real hashing/encryption/storage");
            fail_if(heartbeat.longest_gap > 250000, "raster import must not monopolize the main context for 250 ms");
            var items = fixture.stickers.get_items(fixture.first, id);
            if (!fail_if(items.size != 4, "all real raster images must remain usable")) {
                foreach (var item in items) {
                    Bytes? actual = fixture.stickers.get_sticker_bytes(item);
                    fail_if(actual == null, "each imported raster must decrypt successfully");
                    if (actual != null) {
                        var hash = new Xmpp.Xep.CryptographicHashes.Hash.compute(ChecksumType.SHA256, actual.get_data());
                        fail_if(hash.val != item.hash_value, "stored hash must describe the plaintext raster");
                    }
                }
            }
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            heartbeat.stop();
            if (fixture != null) fixture.close();
        }
    }

    private void test_folder_removal_sync() {
        bool completed = false;
        test_folder_removal.begin((obj, res) => { test_folder_removal.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_folder_removal() {
        Fixture? fixture = null;
        uint remove_source = 0;
        try {
            fixture = new Fixture();
            string folder = Path.build_filename(fixture.root, "remove-during-storage");
            DirUtils.create(folder, 0700);
            FileUtils.set_data(Path.build_filename(folder, "sticker.bmp"), raster_bytes(0xa0b0c0ffu).get_data());
            var existing_pending = pending_paths();
            string? removed_id = null;
            string? owned_pending = null;
            Error? removal_error = null;
            remove_source = Timeout.add(2, () => {
                try {
                    foreach (string path in pending_paths()) {
                        if (existing_pending.contains(path)) continue;
                        var packs = fixture.stickers.get_packs(fixture.first);
                        if (packs.size == 0) continue;
                        removed_id = packs[0].pack_id;
                        owned_pending = path;
                        fixture.stickers.remove_pack(fixture.first, removed_id);
                        remove_source = 0;
                        return Source.REMOVE;
                    }
                } catch (Error err) { removal_error = err; }
                return Source.CONTINUE;
            });
            bool failed = false;
            try {
                string id = yield fixture.stickers.create_local_pack_from_folder(fixture.first, folder);
                fixture.created_packs.add(id);
            } catch (StickerError.NOT_FOUND expected) { failed = true; }
            fail_if(removal_error != null, removal_error != null ? removal_error.message : null);
            fail_if(removed_id == null || !failed, "removing while the real encryption worker runs must reject late completion");
            fail_if(fixture.stickers.get_packs(fixture.first).size != 0, "late worker result must not recreate the pack");
            if (removed_id != null) {
                fail_if(FileUtils.test(Path.build_filename(Stickers.get_stickers_dir(), removed_id), FileTest.EXISTS),
                    "late worker result must not recreate the removed cache directory");
            }
            if (owned_pending != null) fail_if(FileUtils.test(owned_pending, FileTest.EXISTS), "cancelled import must discard encrypted staging bytes");
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            if (remove_source != 0) Source.remove(remove_source);
            if (fixture != null) fixture.close();
        }
    }

    private void test_xmpp_heartbeat_sync() {
        bool completed = false;
        test_xmpp_heartbeat.begin((obj, res) => { test_xmpp_heartbeat.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_xmpp_heartbeat() {
        Fixture? fixture = null;
        Soup.Server? server = null;
        var heartbeat = new Heartbeat();
        try {
            fixture = new Fixture();
            Bytes image = raster_bytes(0x507090ff);
            server = new Soup.Server("server-header", "DinoX sticker tests", null);
            server.add_handler("/sticker.bmp", (server, message, path, query) => {
                message.set_status(200, null);
                // The explicit byte count includes embedded NUL bytes in BMP.
                set_sticker_server_response(message, "image/bmp", Soup.MemoryUse.COPY,
                    (string) image.get_data(), image.get_size());
                // Exclude the preceding IQ/HTTP wait from the responsiveness
                // measurement: it covers receiving and encrypting actual bytes.
                heartbeat.start();
            });
            server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            string url = server.get_uris().data.to_string() + "sticker.bmp";
            var stream = connected_publish_stream(fixture, fixture.first);
            string id = fixture.pack_id("http-import");
            var pack = remote_pack(image, url);

            bool done = false;
            Error? import_error = null;
            int progress_count = 0;
            fixture.stickers.import_pack_with_progress.begin(fixture.first, new Xmpp.Jid("source@example.test"),
                Xmpp.Xep.Stickers.NS_URI, id, (count, total) => {
                    heartbeat.stop();
                    fail_if(!MainContext.default().is_owner(), "download progress must return to the main context");
                    fail_if(count != 1 || total != 1, "XMPP progress must count processed metadata items");
                    progress_count++;
                }, (obj, res) => {
                    try { fixture.stickers.import_pack_with_progress.end(res); }
                    catch (Error err) { import_error = err; }
                    done = true;
                });
            while (stream.pending == null && !done) MainContext.default().iteration(true);
            stream.respond(pubsub_pack_response(id, pack));
            while (stream.pending == null && !done) MainContext.default().iteration(true);
            stream.respond();
            while (!done) MainContext.default().iteration(true);
            fixture.created_packs.add(id);
            fail_if(import_error != null, import_error != null ? import_error.message : null);
            fail_if(progress_count != 1, "one downloaded image must report successful persistence");
            fail_if(heartbeat.ticks < 3, "heartbeat must continue while the downloaded raster is encrypted/stored");
            fail_if(heartbeat.longest_gap > 250000, "HTTP response storage must not monopolize the main context for 250 ms");
            var items = fixture.stickers.get_items(fixture.first, id);
            if (!fail_if(items.size != 1, "downloaded pack must contain its image")) {
                var actual = fixture.stickers.get_sticker_bytes(items[0]);
                fail_if(actual == null || actual.compare(image) != 0, "XMPP download must preserve exact plaintext image bytes");
            }
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            heartbeat.stop();
            if (server != null) server.disconnect();
            if (fixture != null) fixture.close();
        }
    }

    private void test_xmpp_removal_sync() {
        bool completed = false;
        test_xmpp_removal.begin((obj, res) => { test_xmpp_removal.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_xmpp_removal() {
        Fixture? fixture = null;
        Soup.Server? server = null;
        uint remove_source = 0;
        try {
            fixture = new Fixture();
            Bytes image = raster_bytes(0x507090ff);
            server = new Soup.Server("server-header", "DinoX sticker tests", null);
            server.add_handler("/sticker.bmp", (server, message, path, query) => {
                message.set_status(200, null);
                set_sticker_server_response(message, "image/bmp", Soup.MemoryUse.COPY,
                    (string) image.get_data(), image.get_size());
            });
            server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            string url = server.get_uris().data.to_string() + "sticker.bmp";
            var stream = connected_publish_stream(fixture, fixture.first);
            string id = fixture.pack_id("http-removal");
            var hash = new Xmpp.Xep.CryptographicHashes.Hash.compute(ChecksumType.SHA256, image.get_data());
            string path = fixture.path(id, hash.val.replace("/", "_").replace("+", "-").replace("=", ""));
            Bytes other_account_image = raster_bytes(0x909080ffu);
            FileUtils.set_data(path, fixture.encryption.encrypt_data(other_account_image.get_data()));
            fixture.add_pack(fixture.second, id, path);
            var existing_pending = pending_paths();
            string? owned_pending = null;
            Error? removal_error = null;
            bool removed = false;
            remove_source = Timeout.add(2, () => {
                try {
                    foreach (string pending in pending_paths()) {
                        if (existing_pending.contains(pending)) continue;
                        owned_pending = pending;
                        // Real account cleanup can bypass remove_pack while an
                        // import is suspended. Its delayed write must not publish.
                        fixture.db.exec_prepared("DELETE FROM sticker_item WHERE account_id = ?", { fixture.first.id.to_string() });
                        fixture.db.exec_prepared("DELETE FROM sticker_pack WHERE account_id = ?", { fixture.first.id.to_string() });
                        fixture.db.exec_prepared("DELETE FROM account WHERE id = ?", { fixture.first.id.to_string() });
                        removed = true;
                        remove_source = 0;
                        return Source.REMOVE;
                    }
                } catch (Error err) { removal_error = err; }
                return Source.CONTINUE;
            });
            bool done = false;
            Error? import_error = null;
            fixture.stickers.import_pack.begin(fixture.first, new Xmpp.Jid("source@example.test"),
                Xmpp.Xep.Stickers.NS_URI, id, (obj, res) => {
                    try { fixture.stickers.import_pack.end(res); }
                    catch (Error err) { import_error = err; }
                    done = true;
                });
            while (stream.pending == null && !done) MainContext.default().iteration(true);
            stream.respond(pubsub_pack_response(id, remote_pack(image, url)));
            while (!done) {
                MainContext.default().iteration(true);
                // Complete an unexpected publication too, so a regression fails
                // its assertions instead of hanging the test indefinitely.
                if (stream.pending != null) stream.respond();
            }
            fail_if(removal_error != null, removal_error != null ? removal_error.message : null);
            fail_if(!removed || import_error == null || !(import_error is StickerError.NOT_FOUND),
                "account removal during real encrypted storage must reject late completion");
            fail_if(fixture.stickers.get_packs(fixture.first).size != 0, "removed account's library must remain absent");
            var other_items = fixture.stickers.get_items(fixture.second, id);
            if (!fail_if(other_items.size != 1, "the second account's shared cache must remain referenced")) {
                Bytes? actual = fixture.stickers.get_sticker_bytes(other_items[0]);
                fail_if(actual == null || actual.compare(other_account_image) != 0,
                    "late download must neither replace nor delete the other account's file");
            }
            if (owned_pending != null) fail_if(FileUtils.test(owned_pending, FileTest.EXISTS), "removed account must not leave encrypted staging bytes");
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            if (remove_source != 0) Source.remove(remove_source);
            if (server != null) server.disconnect();
            if (fixture != null) fixture.close();
        }
    }

    private void test_upload_cleanup_sync() {
        bool completed = false;
        test_upload_cleanup.begin((obj, res) => { test_upload_cleanup.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_upload_cleanup() {
        Fixture? fixture = null;
        var heartbeat = new Heartbeat();
        try {
            fixture = new Fixture();
            string id = fixture.pack_id("upload-preparation");
            string path = fixture.path(id, "sticker.bmp");
            FileUtils.set_data(path, fixture.encryption.encrypt_data(raster_bytes(0x203040ff).get_data()));
            fixture.add_pack(fixture.first, id, path);
            connected_publish_stream(fixture, fixture.first);
            var existing_temps = upload_temp_paths();
            bool failed = false;
            heartbeat.start();
            try { yield fixture.stickers.publish_pack(fixture.first, id); }
            catch (Xmpp.Xep.HttpFileUpload.HttpFileTransferError.SLOT_REQUEST expected) { failed = true; }
            heartbeat.stop();
            fail_if(!failed, "slot request failure must reach the caller after real decryption");
            fail_if(heartbeat.ticks < 3, "main-context heartbeat must continue during upload decryption/storage");
            fail_if(heartbeat.longest_gap > 250000, "upload preparation must not monopolize the main context for 250 ms");
            foreach (string temp in upload_temp_paths()) {
                fail_if(!existing_temps.contains(temp), "slot failure must delete the prepared plaintext file");
            }
            fail_if(fixture.stickers.is_pack_publishing(fixture.first, id), "slot failure must release the publication guard");
            fail_if(fixture.stickers.get_packs(fixture.first).size != 1, "publication failure must preserve the local pack");

            FileUtils.set_contents(path, "invalid ciphertext");
            bool corrupt_failed = false;
            try { yield fixture.stickers.publish_pack(fixture.first, id); }
            catch (IOError.FAILED expected) { corrupt_failed = true; }
            fail_if(!corrupt_failed, "decryption failure must reach the caller instead of publishing a broken item");
            foreach (string temp in upload_temp_paths()) {
                fail_if(!existing_temps.contains(temp), "decryption failure must delete even a partial plaintext file");
            }
            fail_if(fixture.stickers.is_pack_publishing(fixture.first, id), "decryption failure must release the publication guard");
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            heartbeat.stop();
            if (fixture != null) fixture.close();
        }
    }

    private void test_import_guard_sync() {
        bool completed = false;
        test_import_guard.begin((obj, res) => { test_import_guard.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_import_guard() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string id = fixture.pack_id("import-guard");
            var first_stream = connected_publish_stream(fixture, fixture.first);
            var second_stream = connected_publish_stream(fixture, fixture.second);
            int first_started = 0;
            int second_started = 0;
            fixture.stickers.importing_changed.connect((account, pack_id, importing) => {
                if (pack_id != id) return;
                fail_if(fixture.stickers.is_pack_importing(account, pack_id) != importing,
                    "import signals must expose the committed guard state");
                if (!importing) return;
                fail_if(fixture.stickers.get_packs(account).size != 1,
                    "the initial import signal must wait until metadata exists");
                if (account.id == fixture.first.id) first_started++;
                else if (account.id == fixture.second.id) second_started++;
            });
            bool first_done = false;
            bool second_done = false;
            Error? first_error = null;
            Error? second_error = null;
            var source = new Xmpp.Jid("source@example.test");
            fixture.stickers.import_pack.begin(fixture.first, source, Xmpp.Xep.Stickers.NS_URI, id, (obj, res) => {
                try { fixture.stickers.import_pack.end(res); } catch (Error err) { first_error = err; }
                first_done = true;
            });
            while (first_stream.pending == null && !first_done) MainContext.default().iteration(true);
            fail_if(first_done || !fixture.stickers.is_pack_importing(fixture.first, id),
                "the import guard must precede the initial network fetch");
            fail_if(first_started != 0, "a pending metadata fetch must not announce an uncreated library row");
            bool duplicate_blocked = false;
            try { yield fixture.stickers.import_pack(fixture.first, source, Xmpp.Xep.Stickers.NS_URI, id); }
            catch (StickerError.DOWNLOAD_FAILED expected) { duplicate_blocked = true; }
            fail_if(!duplicate_blocked, "a second importer must not replace the same account's metadata");
            bool publication_blocked = false;
            try { yield fixture.stickers.publish_pack(fixture.first, id); }
            catch (StickerError.PUBLISH_FAILED expected) { publication_blocked = true; }
            fail_if(!publication_blocked || fixture.stickers.is_pack_publishing(fixture.first, id),
                "an importing pack must be rejected before the publication guard is set");

            fixture.stickers.import_pack.begin(fixture.second, source, Xmpp.Xep.Stickers.NS_URI, id, (obj, res) => {
                try { fixture.stickers.import_pack.end(res); } catch (Error err) { second_error = err; }
                second_done = true;
            });
            while (second_stream.pending == null && !second_done) MainContext.default().iteration(true);
            fail_if(second_done || !fixture.stickers.is_pack_importing(fixture.second, id),
                "another account must be able to import the same remote pack concurrently");
            fixture.db.exec_prepared("DELETE FROM account WHERE id = ?", { fixture.first.id.to_string() });
            var pack = new Xmpp.StanzaNode.build("pack", Xmpp.Xep.Stickers.NS_URI).add_self_xmlns();
            first_stream.respond(pubsub_pack_response(id, pack));
            second_stream.respond(pubsub_pack_response(id, pack));
            while (!first_done || !second_done) {
                if (first_stream.pending != null) first_stream.respond();
                if (second_stream.pending != null) second_stream.respond();
                if (!first_done || !second_done) MainContext.default().iteration(true);
            }
            fail_if(first_error == null || !(first_error is StickerError.NOT_FOUND),
                "a metadata fetch finishing after account deletion must fail before creating a pack");
            fail_if(second_error != null, "the other account's independent import must succeed");
            fail_if(first_started != 0 || second_started != 1,
                "only the live account may announce new metadata");
            fail_if(fixture.stickers.is_pack_importing(fixture.first, id) || fixture.stickers.is_pack_importing(fixture.second, id),
                "both import guards must be released on success and failure");
            fail_if(fixture.stickers.get_packs(fixture.first).size != 0, "initial fetch must not recreate a deleted account library");
            fail_if(fixture.stickers.get_packs(fixture.second).size != 1, "the live account must retain its imported library");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_send_failure_sync() {
        bool completed = false;
        test_send_failure.begin((obj, res) => { test_send_failure.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_send_failure() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            FileTransferStorage.start(fixture.interactor, fixture.db);
            FileManager.start(fixture.interactor, fixture.db, fixture.encryption);
            string id = fixture.pack_id("broken-source");
            string path = fixture.path(id, "broken.enc");
            FileUtils.set_contents(path, "broken");
            var item = new Stickers.StickerItem() { pack_id = id, local_path = path };
            var conversation = new Conversation(new Xmpp.Jid("contact@example.test"), fixture.first, Conversation.Type.CHAT);
            bool failed = false;
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Failed to decrypt file for sending:*");
            try { yield fixture.stickers.send_sticker(conversation, id, item); }
            catch (StickerError.DOWNLOAD_FAILED expected) { failed = true; }
            GLib.Test.assert_expected_messages();
            fail_if(!failed, "FileManager's early preparation failure must reach the sticker caller");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_publication_guard_sync() {
        bool completed = false;
        test_publication_guard.begin((obj, res) => { test_publication_guard.end(res); completed = true; });
        while (!completed) MainContext.default().iteration(true);
    }

    private StickerPublishTestStream connected_publish_stream(Fixture fixture, Account account) throws Error {
        var stream = new StickerPublishTestStream(new Xmpp.Jid("example.test"));
        var bind = new Xmpp.Bind.Flag();
        bind.my_jid = account.full_jid;
        stream.add_flag(bind);
        var iq = new Xmpp.Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);
        stream.add_module(new Xmpp.Xep.Pubsub.Module());
        stream.add_module(new Xmpp.Xep.HttpFileUpload.Module());
        fixture.interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        return stream;
    }

    private async void test_publication_guard() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string id = fixture.pack_id("publishing");
            string path = fixture.path(id, "sticker.svg");
            FileUtils.set_contents(path, "already uploaded");
            fixture.add_pack(fixture.first, id, path);
            fixture.add_pack(fixture.second, id, path);
            fixture.db.exec("UPDATE sticker_item SET source_url='https://example.test/sticker.svg'");
            var first_stream = connected_publish_stream(fixture, fixture.first);
            var second_stream = connected_publish_stream(fixture, fixture.second);
            bool first_done = false;
            bool second_done = false;
            Error? first_error = null;
            Error? second_error = null;
            fixture.stickers.publish_pack.begin(fixture.first, id, (obj, res) => {
                try { fixture.stickers.publish_pack.end(res); } catch (Error err) { first_error = err; }
                first_done = true;
            });
            while (first_stream.pending == null && !first_done) MainContext.default().iteration(true);
            fail_if(first_done, "first publication must remain suspended awaiting its PEP result");
            fail_if(!fixture.stickers.is_pack_publishing(fixture.first, id), "active publication must be visible across dialogs");
            bool duplicate_blocked = false;
            try { yield fixture.stickers.publish_pack(fixture.first, id); }
            catch (StickerError.PUBLISH_FAILED expected) { duplicate_blocked = true; }
            fail_if(!duplicate_blocked, "duplicate publication for the same account and pack must be rejected");
            bool removal_blocked = false;
            try { fixture.stickers.remove_pack(fixture.first, id); }
            catch (StickerError.PUBLISH_FAILED expected) { removal_blocked = true; }
            fail_if(!removal_blocked, "service must prevent a stale dialog from removing a publishing pack");
            bool import_blocked = false;
            try {
                yield fixture.stickers.import_pack(fixture.first, new Xmpp.Jid("source@example.test"), Xmpp.Xep.Stickers.NS_URI, id);
            } catch (StickerError.PUBLISH_FAILED expected) { import_blocked = true; }
            fail_if(!import_blocked || fixture.stickers.is_pack_importing(fixture.first, id),
                "an importer must not replace a pack already being published");

            fixture.stickers.publish_pack.begin(fixture.second, id, (obj, res) => {
                try { fixture.stickers.publish_pack.end(res); } catch (Error err) { second_error = err; }
                second_done = true;
            });
            while (second_stream.pending == null && !second_done) MainContext.default().iteration(true);
            fail_if(second_done, "another account must be allowed to publish the same pack concurrently");

            // Account removal bypasses remove_pack: mimic its library cleanup
            // while the real PubSub module is waiting for an IQ response.
            fixture.db.exec_prepared("DELETE FROM sticker_item WHERE account_id = ?", { fixture.first.id.to_string() });
            fixture.db.exec_prepared("DELETE FROM sticker_pack WHERE account_id = ?", { fixture.first.id.to_string() });
            first_stream.respond();
            second_stream.respond();
            while (!first_done || !second_done) MainContext.default().iteration(true);
            fail_if(first_error == null || !(first_error is StickerError.NOT_FOUND),
                "late successful PEP response must not recreate removed account metadata");
            fail_if(second_error != null, "other account's independent publication must succeed");
            fail_if(fixture.stickers.is_pack_publishing(fixture.first, id) ||
                    fixture.stickers.is_pack_publishing(fixture.second, id), "publication guards must be released on both outcomes");
            fail_if(fixture.stickers.get_packs(fixture.first).size != 0, "removed account must remain absent");
            fail_if(fixture.stickers.get_packs(fixture.second).size != 1, "other account's published pack must remain intact");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (fixture != null) fixture.close(); }
    }
}

private class StickerPublishTestStream : Xmpp.XmppStream {
    public Xmpp.StanzaNode? pending;

    public StickerPublishTestStream(Xmpp.Jid remote) {
        base(remote);
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async Xmpp.StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("isolated sticker publication stream has no reader");
    }
    public override async void write_async(Xmpp.StanzaNode node,
            int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        pending = node;
    }

    public void respond(Xmpp.StanzaNode? payload = null) {
        if (pending == null) return;
        var response = new Xmpp.StanzaNode.build("iq")
            .put_attribute("type", "result")
            .put_attribute("id", pending.get_attribute("id"));
        if (payload != null) response.put_node(payload);
        pending = null;
        received_iq_stanza(this, response);
    }
}

}
