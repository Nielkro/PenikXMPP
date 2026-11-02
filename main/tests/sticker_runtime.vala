using Dino.Entities;
using Dino.Security;
using Gee;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

// The widgets below are production sources, not test copies. Only transport
// and the application profile are isolated; PubSub and sticker storage remain real.
class StickerRuntimeTest : Gee.TestCase {
    private delegate bool Ready();

    public StickerRuntimeTest() {
        base("StickerRuntime");
        add_test("duplicate_thumbnails_survive_close_reopen_and_pack_switch", test_thumbnails);
        add_test("pack_selection_is_account_scoped_and_removed_packs_reset", test_selection);
        add_test("missing_tiles_are_disabled_and_send_failure_names_original_chat", test_unavailable_and_send);
        add_test("preferred_account_retry_and_stale_preview_are_safe", test_preview);
        add_test("unavailable_preferred_account_never_falls_back", test_unavailable_account);
        add_test("folder_sharing_retry_preserves_local_pack_and_close_cancels_start", test_folder);
        add_test("manager_actions_are_labeled_account_scoped_and_close_safe", test_manager);
        add_test("folder_import_keeps_spinner_and_rendered_frames_active", test_folder_progress);
        add_test("animation_preference_explains_chat_playback", test_animation_preference_label);
        add_test("LOCALE_raster_mime_and_extensions_use_ascii_rules", test_raster_locale);
    }

    private void test_raster_locale() {
        fail_if_not(ChatInput.StickerChooser.is_supported_raster_sticker_source("Sticker.GIF", "IMAGE/GIF"));
        fail_if_not(ChatInput.StickerChooser.is_supported_raster_sticker_source("日本語.PNG", "IMAGE/PNG"));
        fail_if(ChatInput.StickerChooser.is_supported_raster_sticker_source("not-an-image.txt", "text/plain"));
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public TestApplication(Database db, StreamInteractor interactor, FileEncryption encryption) {
            Object(application_id: "im.dinox.sticker-runtime-test", flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "isolated sticker runtime test";
            this.file_encryption = encryption;
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    private class Fixture : Object {
        public string root;
        public string cache_prefix;
        public Database db;
        public StreamInteractor interactor;
        public FileEncryption encryption;
        public Dino.Stickers stickers;
        public Account first;
        public Account second;
        public StickerRuntimeStream first_stream;
        public StickerRuntimeStream second_stream;
        public Adw.Window window = new Adw.Window();
        public Gtk.MenuButton menu = new Gtk.MenuButton();
        public Dino.Ui.ChatInput.StickerChooser chooser;
        public Gee.ArrayList<Gtk.Window> extra_windows = new Gee.ArrayList<Gtk.Window>();
        private TestApplication app;
        private GLib.Application? previous_app;

        public Fixture() throws Error {
            previous_app = GLib.Application.get_default();
            root = Path.build_filename(Environment.get_user_cache_dir(), "sticker-runtime-" + Uuid.string_random());
            DirUtils.create_with_parents(root, 0700);
            cache_prefix = "ui-runtime-" + Uuid.string_random();
            db = new Database(Path.build_filename(root, "dino.db"), "isolated sticker runtime test");
            interactor = new StreamInteractor.for_tests(db);
            encryption = new FileEncryption("isolated sticker runtime test");
            Dino.Stickers.start(interactor, db, encryption);
            stickers = interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            app = new TestApplication(db, interactor, encryption);
            GLib.Application.set_default(app);
            first = new Account(new Jid("first@example.test"), "fixture") { enabled = true };
            second = new Account(new Jid("second@example.test"), "fixture") { enabled = true };
            first.persist(db);
            second.persist(db);
            first_stream = connect_stream(first);
            second_stream = connect_stream(second);
            chooser = new Dino.Ui.ChatInput.StickerChooser(interactor);
            Util.set_menu_button_popover(menu, chooser);
            menu.label = "Stickers";
            var box = new Gtk.Box(Orientation.VERTICAL, 0) { halign = Align.CENTER, valign = Align.END };
            box.append(menu);
            window.content = box;
            window.set_default_size(620, 540);
        }

        private StickerRuntimeStream connect_stream(Account account) throws Error {
            var stream = new StickerRuntimeStream(new Jid("example.test"));
            var bind = new Xmpp.Bind.Flag();
            bind.my_jid = account.full_jid;
            stream.add_flag(bind);
            var iq = new Xmpp.Iq.Module();
            stream.add_module(iq);
            iq.attach(stream);
            stream.add_module(new Xmpp.Xep.Pubsub.Module());
            stream.add_module(new Xmpp.Xep.HttpFileUpload.Module());
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            return stream;
        }

        public Conversation conversation(Account account, string contact = "contact@example.test") throws Error {
            return new Conversation(new Jid(contact), account, Conversation.Type.CHAT);
        }

        public string pack(string name, Account account, bool shared = false) {
            string id = cache_prefix + "/" + name;
            DirUtils.create_with_parents(Path.build_filename(Dino.Stickers.get_stickers_dir(), id), 0700);
            db.sticker_pack.insert()
                .value(db.sticker_pack.account_id, account.id)
                .value(db.sticker_pack.pack_id, id)
                .value(db.sticker_pack.name, name)
                .value(db.sticker_pack.source_jid, shared ? "source@example.test" : null)
                .value(db.sticker_pack.source_node, shared ? "urn:xmpp:stickers:0" : null)
                .perform();
            return id;
        }

        public string path(string name) {
            string dir = Path.build_filename(Dino.Stickers.get_stickers_dir(), cache_prefix);
            DirUtils.create_with_parents(dir, 0700);
            return Path.build_filename(dir, name);
        }

        public string image(string name, uint32 rgba) throws Error {
            var pixbuf = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, 64, 64);
            pixbuf.fill(rgba);
            string result = path(name);
            FileUtils.set_data(result, encryption.encrypt_data(Util.pixbuf_to_png_bytes(pixbuf)));
            return result;
        }

        public void item(Account account, string id, int position, string? path, string desc = "Fixture sticker") {
            db.sticker_item.insert()
                .value(db.sticker_item.account_id, account.id)
                .value(db.sticker_item.pack_id, id)
                .value(db.sticker_item.position, position)
                .value(db.sticker_item.local_path, path)
                .value(db.sticker_item.media_type, "image/png")
                .value(db.sticker_item.desc, desc)
                .value(db.sticker_item.source_url, "https://example.test/sticker.png")
                .perform();
        }

        public void open(Conversation conversation) throws Error {
            chooser.set_conversation(conversation);
            window.present();
            wait_for(() => window.get_mapped(), "fixture window must map");
            menu.active = true;
            wait_for(() => chooser.visible && chooser.get_root() != null, "chooser must open on its real MenuButton");
        }

        public void close() {
            foreach (var extra in extra_windows) extra.destroy();
            chooser.popdown();
            Util.set_menu_button_popover(menu, null);
            chooser.dispose();
            window.destroy();
            // Finish intercepted IQs while the DB is still open, including
            // cleanup after a failing test's pending publication/preview.
            for (int i = 0; i < 3; i++) {
                while (first_stream.pending.size > 0) first_stream.respond();
                while (second_stream.pending.size > 0) second_stream.respond();
                iterate_for(15);
            }
            foreach (var account in new Account[] { first, second }) {
                foreach (var pack in stickers.get_packs(account)) {
                    try { stickers.remove_pack(account, pack.pack_id); } catch (Error ignored) { }
                }
            }
            stickers.shutdown();
            GLib.Application.set_default(previous_app);
            db.close();
            remove_tree(File.new_for_path(Path.build_filename(Dino.Stickers.get_stickers_dir(), cache_prefix)));
            remove_tree(File.new_for_path(root));
        }
    }

    private static void wait_for(Ready ready, string reason, uint timeout_ms = 4000) throws Error {
        int64 deadline = get_monotonic_time() + timeout_ms * 1000;
        MainContext context = MainContext.default();
        while (!ready()) {
            if (get_monotonic_time() >= deadline) throw new IOError.TIMED_OUT(reason);
            if (context.pending()) context.iteration(false);
            else Thread.usleep(1000);
        }
    }

    private static void iterate_for(uint milliseconds) {
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        MainContext context = MainContext.default();
        while (get_monotonic_time() < deadline) {
            if (context.pending()) context.iteration(false);
            else Thread.usleep(1000);
        }
    }

    private static T? find_widget<T>(Widget root) {
        if (root.get_type().is_a(typeof(T))) return (T) root;
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
            T? found = find_widget<T>(child);
            if (found != null) return found;
        }
        return null;
    }

    private static T require_widget<T>(Widget root) throws Error {
        T? found = find_widget<T>(root);
        if (found == null) throw new IOError.NOT_FOUND("Missing production widget %s".printf(typeof(T).name()));
        return (!) found;
    }

    private static Label? find_text(Widget root, string text) {
        if (root is Label && ((Label) root).label == text) return (Label) root;
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
            Label? found = find_text(child, text);
            if (found != null) return found;
        }
        return null;
    }

    private static Button? find_button(Widget root, string label) {
        if (root is Button && ((Button) root).label == label) return (Button) root;
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
            Button? found = find_button(child, label);
            if (found != null) return found;
        }
        return null;
    }

    private static Button require_button(Widget root, string label) throws Error {
        Button? result = find_button(root, label);
        if (result == null) throw new IOError.NOT_FOUND("Missing labeled action: " + label);
        return (!) result;
    }

    private static void collect_pictures(Widget root, Gee.ArrayList<Gtk.Picture> result) {
        if (root is Gtk.Picture) result.add((Gtk.Picture) root);
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) collect_pictures(child, result);
    }

    private static Gee.ArrayList<Gtk.Picture> pictures(Widget root) {
        var result = new Gee.ArrayList<Gtk.Picture>();
        GridView? grid = find_widget<GridView>(root);
        if (grid != null) collect_pictures(grid, result);
        return result;
    }

    private static bool painted(Widget root, int count) {
        var cells = pictures(root);
        if (cells.size != count) return false;
        foreach (var picture in cells) if (picture.paintable == null) return false;
        return true;
    }

    private static Button picture_button(Gtk.Picture picture) throws Error {
        for (Widget? parent = picture.get_parent(); parent != null; parent = parent.get_parent()) {
            if (parent is Button) return (Button) parent;
        }
        throw new IOError.NOT_FOUND("A sticker picture must belong to its production button");
    }

    private static MenuButton pack_menu(Fixture f) throws Error {
        var root = f.chooser.child as Gtk.Box;
        if (root == null || root.get_first_child() == null) throw new IOError.NOT_FOUND("Missing chooser header");
        return require_widget<MenuButton>((!) root.get_first_child());
    }

    private static string selected_pack(Fixture f) throws Error {
        return require_widget<Label>(pack_menu(f)).label;
    }

    private static void choose(Fixture f, string name) throws Error {
        Gtk.Popover? popover = pack_menu(f).popover;
        if (popover == null) throw new IOError.NOT_FOUND("Missing production pack popover");
        var list = require_widget<ListBox>(popover);
        for (int i = 0; ; i++) {
            ListBoxRow? row = list.get_row_at_index(i);
            if (row == null) break;
            Label? label = find_widget<Label>(row);
            if (label != null && label.label == name) {
                list.row_activated(row);
                return;
            }
        }
        throw new IOError.NOT_FOUND("Pack is absent from the actual chooser: " + name);
    }

    private static void remove_tree(File file) {
        try {
            if (file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
                var children = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? child;
                while ((child = children.next_file()) != null) remove_tree(file.get_child(child.get_name()));
                children.close();
            }
            file.delete();
        } catch (Error ignored) { }
    }

    private void test_thumbnails() {
        Fixture? f = null;
        try {
            f = new Fixture();
            string red = f.pack("Red", f.first);
            string red_path = f.image("red.png", 0xff0000ffu);
            f.item(f.first, red, 0, red_path, "First red");
            f.item(f.first, red, 1, red_path, "Second red");
            string blue = f.pack("Blue", f.first);
            f.item(f.first, blue, 0, f.image("blue.png", 0x0000ffff), "Blue");
            f.open(f.conversation(f.first));
            choose(f, "Red");
            wait_for(() => pictures(f.chooser).size == 2, "both duplicate production cells must bind");
            // Give the worker time to take the first job without dispatching its
            // completion; reopen queues another generation for the same path.
            Thread.usleep(2000);
            f.menu.active = false;
            f.chooser.popdown();
            f.menu.active = true;
            wait_for(() => painted(f.chooser, 2), "both duplicate cells must paint after stale completion/reopen");
            var cells = pictures(f.chooser);
            fail_if(cells[0].paintable != cells[1].paintable, "duplicates must share the decoded texture");
            fail_if_not_eq_str("First red", picture_button(cells[0]).tooltip_text ?? "");
            Gdk.Paintable red_texture = (!) cells[0].paintable;
            choose(f, "Blue");
            wait_for(() => painted(f.chooser, 1), "switching packs must paint the new source");
            fail_if(pictures(f.chooser)[0].paintable == red_texture, "a recycled cell must never retain the prior source");
            choose(f, "Red");
            wait_for(() => painted(f.chooser, 2), "switching back must restore both duplicate thumbnails");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_selection() {
        Fixture? f = null;
        try {
            f = new Fixture();
            string first_id = f.pack("First Pack", f.first);
            string favorite_id = f.pack("Last Pack", f.first);
            string second_id = f.pack("Second Pack", f.second);
            string first_path = f.image("first.png", 0x00ff00ff);
            f.item(f.first, first_id, 0, first_path);
            f.item(f.first, favorite_id, 0, first_path);
            f.item(f.second, second_id, 0, f.image("second.png", 0x0000ffff));
            f.open(f.conversation(f.first));
            fail_if_not_eq_str("First Pack", selected_pack(f), "first use must immediately select an installed pack");
            choose(f, "Last Pack");
            f.chooser.set_conversation(f.conversation(f.first, "other@example.test"));
            fail_if_not_eq_str("Last Pack", selected_pack(f), "non-first selection must survive same-account conversation reload");
            f.chooser.set_conversation(f.conversation(f.second));
            fail_if_not_eq_str("Second Pack", selected_pack(f), "another account must open its own first pack");
            choose(f, "Second Pack");
            f.chooser.set_conversation(f.conversation(f.first));
            fail_if_not_eq_str("Last Pack", selected_pack(f));
            f.stickers.remove_pack(f.first, favorite_id);
            f.chooser.set_conversation(f.conversation(f.first));
            fail_if_not_eq_str("First Pack", selected_pack(f), "removed selection must fall back to an installed pack");
            choose(f, "Select Sticker Pack");
            f.chooser.set_conversation(f.conversation(f.first));
            fail_if_not_eq_str("Select Sticker Pack", selected_pack(f), "an explicit empty selection must survive reload");
            f.chooser.set_conversation(f.conversation(f.second));
            fail_if_not_eq_str("Second Pack", selected_pack(f));
            f.stickers.remove_pack(f.second, second_id);
            f.chooser.set_conversation(f.conversation(f.second));
            fail_if_not_eq_str("Select Sticker Pack", selected_pack(f), "deleted selection must reset");
            fail_if(find_text(f.chooser, "No sticker packs yet.") == null, "empty-pack message must not be overwritten by no-selection");
            fail_if(find_button(f.chooser, "Add Sticker Pack") == null, "empty chooser needs a labeled add action");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_unavailable_and_send() {
        Fixture? f = null;
        try {
            f = new Fixture();
            string id = f.pack("Unavailable", f.first);
            f.item(f.first, id, 0, null, "Missing download");
            f.item(f.first, id, 1, "", "Empty source");
            f.item(f.first, id, 2, f.path("absent.png"), "Removed file");
            f.open(f.conversation(f.first));
            choose(f, "Unavailable");
            wait_for(() => pictures(f.chooser).size == 3, "unavailable items must remain visibly represented");
            foreach (var picture in pictures(f.chooser)) {
                Button button = picture_button(picture);
                fail_if(button.sensitive, "missing/empty/nonexistent sources must disable sending");
                fail_if(find_text(button, "Sticker unavailable") == null, "unavailable tiles need a visible placeholder");
            }

            string broken = f.pack("Broken", f.first);
            string broken_path = f.path("broken.png");
            FileUtils.set_contents(broken_path, "invalid encrypted sticker");
            f.item(f.first, broken, 0, broken_path, "Broken sticker");
            // Reload the real chooser after changing fixture storage.
            f.chooser.set_conversation(f.conversation(f.first, "original@example.test"));
            choose(f, "Broken");
            wait_for(() => find_text(f.chooser, "Preview unavailable") != null, "a decode failure must be visible");
            Dino.FileTransferStorage.start(f.interactor, f.db);
            Dino.FileManager.start(f.interactor, f.db, f.encryption);
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Failed to decrypt file for sending:*");
            picture_button(pictures(f.chooser)[0]).clicked();
            f.chooser.set_conversation(f.conversation(f.second, "new@example.test"));
            wait_for(() => f.window.visible_dialog is Adw.AlertDialog, "real send preparation failure must present an alert");
            GLib.Test.assert_expected_messages();
            var alert = (Adw.AlertDialog) f.window.visible_dialog;
            fail_if_not_eq_str("Could not send sticker", alert.heading);
            fail_if(!alert.body.contains("first@example.test") || !alert.body.contains("original@example.test"),
                "async send errors must name their captured account and chat");
            fail_if(alert.body.contains("new@example.test"), "a failure must not be attributed to the newly selected chat");
            alert.force_close();
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_preview() {
        Fixture? f = null;
        try {
            f = new Fixture();
            var dialog = new StickerPackImportDialog(f.interactor, new Jid("source@example.test"), "pack-node", "pack-id", f.second);
            f.extra_windows.add(dialog);
            dialog.present();
            wait_for(() => f.second_stream.pending.size == 1, "preferred second account must request preview");
            var combo = require_widget<AccountComboBox>(dialog);
            Button import_action = require_button(dialog, "Import");
            fail_if(combo.active_account == null || combo.active_account.id != f.second.id, "preferred account B must win over account A");
            fail_if_not_eq_int(0, f.first_stream.pending.size);
            f.second_stream.respond();
            wait_for(() => find_text(dialog, "Could not load sticker pack") != null, "empty PubSub result must show preview failure");
            Button retry = require_button(dialog, "Try Again");
            fail_if(!retry.visible, "preview failure must offer a retry");
            retry.clicked();
            wait_for(() => f.second_stream.pending.size == 1, "retry must issue a new real PubSub request");
            f.second_stream.respond("Second preview");
            wait_for(() => import_action.sensitive, "successful retry must enable import");
            fail_if(find_text(dialog, "Second preview") == null, "successful preview must replace failure text");
            combo.select_account(f.first);
            wait_for(() => f.first_stream.pending.size == 1, "account switch must request a new preview");
            combo.select_account(f.second);
            wait_for(() => f.second_stream.pending.size == 1, "switching back must start another generation");
            f.first_stream.respond("Stale first preview");
            iterate_for(10);
            fail_if(find_text(dialog, "Stale first preview") != null, "late account-A preview must never overwrite account B");
            fail_if(require_button(dialog, "Import").sensitive, "stale completion must not enable import for a pending account");
            f.second_stream.respond("Current second preview");
            wait_for(() => find_text(dialog, "Current second preview") != null, "current account result must populate preview");
            combo.select_account(f.first);
            wait_for(() => f.first_stream.pending.size == 1, "close-safety case must have a pending preview");
            Label? loading = find_text(dialog, "Loading…");
            if (loading == null) throw new IOError.NOT_FOUND("Missing busy preview label");
            dialog.close();
            f.first_stream.respond("Preview after close");
            iterate_for(15);
            fail_if_not_eq_str("Loading…", loading.label, "closed preview must not mutate detached widgets");

            // Exercise actual import too: even a programmatic account change
            // while the selector is disabled cannot redirect the captured job.
            string imported_id = f.cache_prefix + "/imported";
            DirUtils.create_with_parents(Path.build_filename(Dino.Stickers.get_stickers_dir(), imported_id), 0700);
            var importing = new StickerPackImportDialog(f.interactor, new Jid("source@example.test"), "pack-node", imported_id, f.second);
            f.extra_windows.add(importing);
            importing.present();
            wait_for(() => f.second_stream.pending.size == 1, "import fixture must request account B preview");
            var import_spinner = require_widget<Gtk.Spinner>(importing);
            fail_if(!import_spinner.visible || !import_spinner.spinning, "XMPP preview must visibly indicate ongoing work");
            f.second_stream.respond("Import B");
            Button import_now = require_button(importing, "Import");
            wait_for(() => import_now.sensitive, "current preview must allow importing");
            import_now.clicked();
            fail_if(!import_spinner.visible || !import_spinner.spinning, "XMPP import must start a visible spinner immediately");
            var import_combo = require_widget<AccountComboBox>(importing);
            fail_if(import_combo.sensitive, "account selector must be disabled during import");
            import_combo.select_account(f.first);
            wait_for(() => f.second_stream.pending.size == 1, "import retrieval must use captured account B");
            f.second_stream.respond("Imported B");
            wait_for(() => f.stickers.get_packs(f.second).size == 1 && f.second_stream.pending.size == 1,
                "import must persist and publish through account B");
            fail_if(!import_spinner.spinning, "spinner must remain active through final XMPP publication");
            fail_if_not_eq_int(0, f.stickers.get_packs(f.first).size, "changing the disabled selector must not redirect import");
            f.second_stream.respond();
            wait_for(() => !importing.visible, "successful import must close its real dialog");
            fail_if(import_spinner.spinning, "finished XMPP import must stop the spinner");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_unavailable_account() {
        Fixture? f = null;
        try {
            f = new Fixture();
            var unavailable = new Account(new Jid("removed@example.test"), "fixture") { id = 999, enabled = true };
            var dialog = new StickerPackImportDialog(f.interactor, new Jid("source@example.test"), "pack-node", "pack-id", unavailable);
            f.extra_windows.add(dialog);
            dialog.present();
            wait_for(() => find_text(dialog, "No account available") != null, "missing preferred account must fail closed");
            var combo = require_widget<AccountComboBox>(dialog);
            fail_if(combo.active_account != null, "unavailable context must not silently choose the first account");
            fail_if(require_button(dialog, "Import").sensitive || require_button(dialog, "Copy Link").sensitive,
                "unavailable account must disable import and sharing actions");
            fail_if_not_eq_int(0, f.first_stream.pending.size + f.second_stream.pending.size, "no preview may use a fallback account");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_folder() {
        Fixture? f = null;
        try {
            f = new Fixture();
            string folder = Path.build_filename(f.root, "Local Stickers");
            DirUtils.create_with_parents(folder, 0700);
            // SVG is intentionally not thumbnailed: this test exercises dialog
            // state and real import storage without spawning another decoder.
            FileUtils.set_contents(Path.build_filename(folder, "smile.svg"),
                "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2'/></svg>");
            f.interactor.connection_manager.remove_managed_account_for_tests(f.second);
            var dialog = new StickerPackFolderImportDialog(f.interactor, f.second, folder);
            f.extra_windows.add(dialog);
            Button retry_action = require_button(dialog, "Try Sharing Again");
            Button close_action = require_button(dialog, "Close");
            int created = 0;
            dialog.pack_created.connect(() => created++);
            dialog.present();
            wait_for(() => dialog.get_mapped(), "folder dialog must map");
            fail_if(find_text(dialog, "Account: second@example.test") == null, "folder creation must visibly identify its captured account");
            require_button(dialog, "Share and Copy Link").clicked();
            wait_for(() => retry_action.visible &&
                f.stickers.get_packs(f.second).size == 1, "failed publication must keep the created local pack and offer retry");
            fail_if_not_eq_int(1, created);
            string created_id = f.stickers.get_packs(f.second)[0].pack_id;
            fail_if_not_eq_int(0, f.stickers.get_packs(f.first).size, "folder import must not switch to another account");
            require_button(dialog, "Try Sharing Again").clicked();
            wait_for(() => retry_action.visible && close_action.sensitive, "sharing retry must settle after the offline failure");
            fail_if_not_eq_int(1, created, "publication retry must not emit another local creation");
            fail_if_not_eq_int(1, f.stickers.get_packs(f.second).size, "publication retry must not duplicate the local pack");
            fail_if_not_eq_str(created_id, f.stickers.get_packs(f.second)[0].pack_id);
            dialog.close();

            var cancelled = new StickerPackFolderImportDialog(f.interactor, f.first, folder);
            f.extra_windows.add(cancelled);
            cancelled.present();
            wait_for(() => cancelled.get_mapped(), "cancellation dialog must map");
            require_button(cancelled, "Local only").clicked();
            cancelled.destroy();
            iterate_for(20);
            fail_if_not_eq_int(0, f.stickers.get_packs(f.first).size, "closing before the queued creation starts must cancel it");
            f.stickers.remove_pack(f.second, created_id);
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_folder_progress() {
        Fixture? f = null;
        StickerPackFolderImportDialog? dialog = null;
        uint tick_id = 0;
        try {
            f = new Fixture();
            string folder = Path.build_filename(f.root, "Spinner Images");
            DirUtils.create_with_parents(folder, 0700);
            for (int i = 0; i < 6; i++) {
                var image = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, 128, 128);
                image.fill(((uint32) i * 0x10203000u) | 0xffu);
                FileUtils.set_data(Path.build_filename(folder, "image-%d.png".printf(i)), Util.pixbuf_to_png_bytes(image));
            }
            dialog = new StickerPackFolderImportDialog(f.interactor, f.first, folder);
            f.extra_windows.add(dialog);
            dialog.present();
            wait_for(() => dialog.get_mapped(), "import progress window must map");
            var spinner = require_widget<Gtk.Spinner>(dialog);
            int busy_frames = 0;
            tick_id = dialog.add_tick_callback((widget, clock) => {
                if (spinner.visible && spinner.spinning) busy_frames++;
                return Source.CONTINUE;
            });
            require_button(dialog, "Local only").clicked();
            fail_if(!spinner.visible || !spinner.spinning, "folder import must immediately show its spinner");
            wait_for(() => !spinner.spinning && f.stickers.get_packs(f.first).size == 1,
                "real encrypted image import must complete", 10000);
            fail_if(busy_frames < 2, "spinner must render multiple frames during actual file hashing/encryption/storage");
            fail_if_not_eq_int(6, f.stickers.get_items(f.first, f.stickers.get_packs(f.first)[0].pack_id).size,
                "responsive import must preserve every image");
            fail_if(find_text(dialog, "Sticker pack imported") == null, "folder completion must be described as an import");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (dialog != null && tick_id != 0) dialog.remove_tick_callback(tick_id);
            if (f != null) f.close();
        }
    }

    private void test_animation_preference_label() {
        var builder = new Gtk.Builder.from_resource("/im/dinox/dinox/preferences_window/general_preferences_page.ui");
        var row = builder.get_object("sticker_animations_row") as Adw.SwitchRow;
        if (fail_if(row == null, "the animation preference row must exist")) return;
        fail_if_not_eq_str("Play Sticker Animations", row.title);
        fail_if_not_eq_str("Play animated stickers in the chat. When disabled, show a still image.", row.subtitle);
    }

    private static Adw.ActionRow? find_pack_row(Widget root, string name) {
        if (root is Adw.ActionRow && ((Adw.ActionRow) root).title == name) return (Adw.ActionRow) root;
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
            Adw.ActionRow? found = find_pack_row(child, name);
            if (found != null) return found;
        }
        return null;
    }

    private static Button pack_action(StickerManagerDialog manager, string name, string action) throws Error {
        Adw.ActionRow? row = find_pack_row(manager, name);
        if (row == null) throw new IOError.NOT_FOUND("Missing manager pack row " + name);
        return require_button(row, action);
    }

    private static Adw.AlertDialog await_alert(Fixture f, string heading) throws Error {
        wait_for(() => f.window.visible_dialog is Adw.AlertDialog, "manager must present an actual confirmation dialog");
        var result = (Adw.AlertDialog) f.window.visible_dialog;
        fail_if_not_eq_str(heading, result.heading);
        wait_for(() => result.get_mapped(), "confirmation buttons must be mapped before activation");
        // libadwaita 1.5 opens the dialog sheet on its second frame after map.
        // Clicking earlier closes an unopened sheet, which its pending map
        // callback then reopens. A real user acts on the rendered dialog.
        int frames = 0;
        uint tick = result.add_tick_callback((widget, clock) => {
            frames++;
            return frames < 2;
        });
        try {
            wait_for(() => frames == 2, "confirmation must render before button activation");
        } finally {
            if (frames < 2) result.remove_tick_callback(tick);
        }
        return result;
    }

    private void test_manager() {
        Fixture? f = null;
        try {
            f = new Fixture();
            string local = f.pack("Local", f.first);
            f.item(f.first, local, 0, f.path("local.png"));
            string shared = f.pack("Shared", f.first, true);
            f.pack("Shared", f.second, true);
            var manager = new StickerManagerDialog(f.interactor, f.conversation(f.first));
            f.window.present();
            manager.present(f.window);
            wait_for(() => f.window.visible_dialog == manager, "production manager must be presented");
            fail_if(pack_action(manager, "Local", "Share Pack").label != "Share Pack", "local packs need a labeled share action");
            fail_if(pack_action(manager, "Shared", "Copy Link").label != "Copy Link", "published packs need a labeled copy action");
            fail_if(pack_action(manager, "Shared", "Remove").label != "Remove", "removal must be labeled");
            pack_action(manager, "Shared", "Remove").clicked();
            var removal = await_alert(f, "Remove Sticker Pack?");
            require_button(removal, "Cancel").clicked();
            wait_for(() => f.window.visible_dialog == manager, "cancelled removal must return to manager");
            fail_if_not_eq_int(2, f.stickers.get_packs(f.first).size, "cancel must preserve installed packs");
            pack_action(manager, "Local", "Share Pack").clicked();
            var sharing = await_alert(f, "Share Sticker Pack?");
            fail_if(!sharing.body.contains("Anyone with the link"), "sharing must explain public link retrieval");
            require_button(sharing, "Share Pack").clicked();
            wait_for(() => f.first_stream.pending.size == 1, "sharing must reach real PubSub publication");
            wait_for(() => f.window.visible_dialog == manager, "share confirmation must close through its button action");
            fail_if(pack_action(manager, "Local", "Remove").sensitive, "publication must disable conflicting removal");
            manager.force_close();
            f.first_stream.respond();
            wait_for(() => !f.stickers.is_pack_publishing(f.first, local), "late publication must settle after manager close");
            fail_if(f.window.visible_dialog is Adw.AlertDialog, "closed manager must not present a late completion/error dialog");

            var second_manager = new StickerManagerDialog(f.interactor, f.conversation(f.first));
            second_manager.present(f.window);
            wait_for(() => f.window.visible_dialog == second_manager, "manager must reopen with current storage");
            pack_action(second_manager, "Shared", "Remove").clicked();
            removal = await_alert(f, "Remove Sticker Pack?");
            require_button(removal, "Remove").clicked();
            fail_if_not_eq_int(1, f.stickers.get_packs(f.first).size, "confirmed removal must affect the manager account");
            fail_if_not_eq_int(1, f.stickers.get_packs(f.second).size, "confirmed removal must preserve the other account's same pack");
            fail_if_not_eq_str(shared, f.stickers.get_packs(f.second)[0].pack_id);
            second_manager.force_close();
        } catch (Error err) { fail_if_reached(err.message); }
        finally { if (f != null) f.close(); }
    }
}

private class StickerRuntimeStream : Xmpp.XmppStream {
    public Gee.ArrayList<Xmpp.StanzaNode> pending = new Gee.ArrayList<Xmpp.StanzaNode>();

    public StickerRuntimeStream(Jid remote) { base(remote); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async Xmpp.StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("isolated sticker runtime stream has no reader");
    }
    public override async void write_async(Xmpp.StanzaNode node,
            int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        pending.add(node);
    }

    // Empty results model an absent pack without logging an unexpected IQ error.
    // Named results use the actual XEP-0060 / XEP-0449 payload parsed by libdino.
    public void respond(string? name = null) {
        if (pending.size == 0) return;
        Xmpp.StanzaNode request = pending.remove_at(0);
        var response = new Xmpp.StanzaNode.build("iq")
            .put_attribute("type", "result")
            .put_attribute("id", request.get_attribute("id"));
        if (name != null) {
            var pack = new Xmpp.StanzaNode.build("pack", Xmpp.Xep.Stickers.NS_URI)
                .put_node(new Xmpp.StanzaNode.build("name", Xmpp.Xep.Stickers.NS_URI)
                    .put_node(new Xmpp.StanzaNode.text(name)));
            response.put_node(new Xmpp.StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI)
                .put_node(new Xmpp.StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                    .put_node(new Xmpp.StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI)
                        .put_attribute("id", "pack-id").put_node(pack))));
        }
        received_iq_stanza(this, response);
    }
}

}
