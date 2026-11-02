using Dino.Entities;
using Dino.Security;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

// Exercise the production chat image widget, its background decoder and real
// encrypted FileTransfer -> FileManager plaintext lease path. The fixture GIF
// contains red and blue 8x8 frames, each displayed for 160 ms, looping forever.
class StickerAnimationRuntimeTest : Gee.TestCase {
    private const string ANIMATED_GIF = "R0lGODlhCAAIAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQAEAAAACwAAAAACAAIAAAIDwABCBxIsKDBgwgTKkwYEAAh+QQBEAABACwAAAAACAAIAIEAAP8AAAAAAAAAAAAIDwABCBxIsKDBgwgTKkwYEAA7";
    private delegate bool Ready();

    public StickerAnimationRuntimeTest() {
        base("StickerAnimationRuntime");
        add_test("sticker_off_shows_first_frame_and_on_resumes_existing_chat_widget", test_setting);
        add_test("ordinary_gif_is_independent_of_sticker_setting", test_ordinary_gif);
        add_test("viewport_and_unmap_pause_until_visible_again", test_visibility);
        add_test("preview_decoder_honors_pixel_limit_and_cancellation", test_decoder_limits);
        add_test("large_gif_frames_are_decoded_at_preview_size", test_large_gif);
        add_test("large_chat_image_shrinks_before_and_after_decode", test_large_image);
        add_test("failed_download_keeps_menu_usable_while_embedded_preview_loads", test_failed_thumbnail);
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
            Object(application_id: "im.dinox.sticker-animation-runtime-test", flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "isolated chat sticker animation test";
            this.file_encryption = encryption;
            this.stream_interactor = interactor;
            this.settings = new Dino.Entities.Settings.from_db(db);
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    private class Fixture : Object {
        public string root;
        public string source_path;
        public Database db;
        public TestApplication app;
        public Adw.Window window = new Adw.Window();
        public Gtk.ScrolledWindow scrolled = new Gtk.ScrolledWindow();
        public FileImageWidget image;
        public FileTransfer transfer;
        private GLib.Application? previous_app;

        public Fixture(bool is_sticker, bool enabled, int offset = 0, bool large_image = false, bool large_gif = false) throws Error {
            previous_app = GLib.Application.get_default();
            root = DirUtils.make_tmp("dinox-sticker-animation-XXXXXX");
            db = new Database(Path.build_filename(root, "dino.db"), "isolated chat sticker animation test");
            var interactor = new StreamInteractor.for_tests(db);
            var encryption = new FileEncryption("isolated chat sticker animation test");
            FileManager.start(interactor, db, encryption);
            app = new TestApplication(db, interactor, encryption);
            GLib.Application.set_default(app);
            app.settings.sticker_animations_enabled = enabled;

            string source_name = "animation-runtime-" + Uuid.string_random() + ".enc";
            source_path = Path.build_filename(FileManager.get_storage_dir(), source_name);
            uint8[] data = Base64.decode(ANIMATED_GIF);
            if (large_gif) {
                // The GIF logical canvas, independent of the small frame rects.
                // A compressed file can decode to much larger frames.
                data[6] = 0x40; data[7] = 0x06; // 1600
                data[8] = 0xb0; data[9] = 0x04; // 1200
            }
            if (large_image) {
                var source = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 1200, 600);
                source.fill(0x4385bfff);
                data = Util.pixbuf_to_png_bytes(source);
            }
            FileUtils.set_data(source_path, encryption.encrypt_data(data));
            transfer = new FileTransfer() {
                file_name = large_image ? "wide.png" : "two-frames.gif",
                mime_type = large_image ? "image/png" : "image/gif", path = source_name,
                direction = FileTransfer.DIRECTION_RECEIVED, provider = FileManager.SFS_PROVIDER_ID,
                is_sticker = is_sticker, size = data.length,
                width = large_image ? 1200 : large_gif ? 1600 : 8, height = large_image ? 600 : large_gif ? 1200 : 8
            };
            transfer.set_transfer_phase(FileTransfer.Phase.COMPLETE);
            image = large_image ? new FileImageWidget() : new FileImageWidget(100, 100);
            var column = new Gtk.Box(Orientation.VERTICAL, 0);
            if (offset > 0) column.append(new Gtk.Box(Orientation.VERTICAL, 0) { height_request = offset });
            column.append(image);
            column.append(new Gtk.Box(Orientation.VERTICAL, 0) { height_request = 900 });
            scrolled.set_child(column);
            // Exercise a genuinely narrow chat even if the native window
            // manager enforces a wider minimum for the toplevel.
            var viewport = new SizingBin() { max_width = 260 };
            scrolled.set_parent(viewport);
            window.content = viewport;
            window.set_default_size(260, 220);
            window.present();
            wait_for(() => image.get_mapped(), "chat image widget must map");
            if (offset > 0) {
                wait_for(() => scrolled.vadjustment.upper > offset + 220,
                    "scroll content must be allocated before moving to the sticker");
                scrolled.vadjustment.value = offset;
            }
            image.set_file_transfer.begin(transfer);
            if (large_image) {
                var reserved = picture(image);
                fail_if_not(reserved != null && reserved.paintable == null,
                    "initial image sizing must be measured before the async decode completes");
                int minimum, natural, min_baseline, nat_baseline;
                image.measure(Orientation.HORIZONTAL, -1, out minimum, out natural,
                    out min_baseline, out nat_baseline);
                fail_if(minimum > 260, "the undecoded image target must also remain shrinkable");
            }
            wait_for(() => picture(image) != null && picture(image).paintable is Gdk.Texture,
                "real encrypted GIF must decode in the production chat widget");
        }

        public void close() {
            var parent = image.get_parent() as Gtk.Box;
            if (parent != null) parent.remove(image);
            window.destroy();
            image.dispose();
            // Also drain generation-invalidated decode/cleanup callbacks before
            // closing the isolated database or restoring the default app.
            iterate_for(30);
            FileImageWidget.clear_frame_cache();
            GLib.Application.set_default(previous_app);
            db.close();
            try { File.new_for_path(source_path).delete(); } catch (Error ignored) { }
            remove_tree(File.new_for_path(root));
        }
    }

    private static FixedRatioPicture? picture(Gtk.Widget widget) {
        if (widget is FixedRatioPicture) return (FixedRatioPicture) widget;
        for (Gtk.Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            FixedRatioPicture? found = picture(child);
            if (found != null) return found;
        }
        return null;
    }

    private static string frame(FileImageWidget image) {
        var texture = picture(image).paintable as Gdk.Texture;
        size_t stride = texture.get_width() * 4;
        uint8[] pixels = new uint8[stride * texture.get_height()];
        texture.download(pixels, stride);
        return Checksum.compute_for_data(ChecksumType.SHA256, pixels);
    }

    private static bool is_in_visible_area(Fixture f) {
        Graphene.Rect bounds;
        if (!f.image.compute_bounds(f.scrolled, out bounds)) return false;
        return bounds.origin.y < f.scrolled.vadjustment.page_size &&
            bounds.origin.y + bounds.size.height > 0;
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

    private static void iterate_for(uint duration_ms) {
        int64 deadline = get_monotonic_time() + duration_ms * 1000;
        MainContext context = MainContext.default();
        while (get_monotonic_time() < deadline) {
            if (context.pending()) context.iteration(false);
            else Thread.usleep(1000);
        }
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

    private void test_setting() {
        Fixture? f = null;
        try {
            f = new Fixture(true, false);
            string first = frame(f.image);
            int changes = 0;
            ulong notify_id = picture(f.image).notify["paintable"].connect(() => { changes++; });
            iterate_for(450);
            fail_if_not_eq_str(first, frame(f.image), "off at decode must show a still frame");
            fail_if_not_eq_int(0, changes, "off must not submit animation frames");

            f.app.settings.sticker_animations_enabled = true;
            wait_for(() => frame(f.image) != first, "enabling must animate the already loaded chat sticker");
            f.app.settings.sticker_animations_enabled = false;
            fail_if_not_eq_str(first, frame(f.image), "disabling must restore the first frame");
            int stopped_changes = changes;
            iterate_for(450);
            fail_if_not_eq_int(stopped_changes, changes, "disabled animation must remain stopped");

            f.app.settings.sticker_animations_enabled = true;
            wait_for(() => frame(f.image) != first, "re-enabling must resume without reimport or widget replacement");
            picture(f.image).disconnect(notify_id);
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (f != null) f.close();
        }
    }

    private void test_ordinary_gif() {
        Fixture? f = null;
        try {
            f = new Fixture(false, false);
            string initial = frame(f.image);
            wait_for(() => frame(f.image) != initial, "ordinary GIF must animate while sticker animations are disabled");
            f.app.settings.sticker_animations_enabled = true;
            f.app.settings.sticker_animations_enabled = false;
            string after_toggle = frame(f.image);
            wait_for(() => frame(f.image) != after_toggle, "sticker preference changes must not stop ordinary GIF playback");
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (f != null) f.close();
        }
    }

    private void test_visibility() {
        Fixture? f = null;
        try {
            // A nonzero document position catches double-counted scroll offsets
            // that would incorrectly pause a visible sticker in a long chat.
            f = new Fixture(true, true, 600);
            string initial = frame(f.image);
            wait_for(() => frame(f.image) != initial, "visible sticker must actually advance its pixels");
            f.scrolled.vadjustment.value = f.scrolled.vadjustment.upper - f.scrolled.vadjustment.page_size;
            wait_for(() => !is_in_visible_area(f), "scrolling must actually move the sticker outside the viewport");
            iterate_for(30);
            string offscreen = frame(f.image);
            iterate_for(450);
            fail_if_not_eq_str(offscreen, frame(f.image), "sticker outside the viewport must pause");
            f.scrolled.vadjustment.value = 600;
            wait_for(() => is_in_visible_area(f), "returning must actually put the sticker inside the viewport");
            wait_for(() => frame(f.image) != offscreen, "returning to the viewport must resume playback");

            f.image.visible = false;
            wait_for(() => !f.image.get_mapped(), "hidden chat sticker must unmap");
            string unmapped = frame(f.image);
            iterate_for(450);
            fail_if_not_eq_str(unmapped, frame(f.image), "unmapped sticker must pause");
            f.image.visible = true;
            wait_for(() => frame(f.image) != unmapped, "remapping must resume playback");
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (f != null) f.close();
        }
    }

    private static void check_image_width(FileImageWidget image, Gtk.Widget viewport) {
        int minimum, natural, min_baseline, nat_baseline;
        image.measure(Orientation.HORIZONTAL, -1, out minimum, out natural,
            out min_baseline, out nat_baseline);
        fail_if(minimum > 260, "a 600px inline image target must not become its minimum width");
        fail_if(viewport.get_width() > 260 || image.get_width() > viewport.get_width(),
            "metadata and decoded image must fit the narrow chat viewport");
    }

    private void test_decoder_limits() {
        uint8[] bytes = Base64.decode(ANIMATED_GIF);
        bytes[6] = bytes[8] = 0x10;
        bytes[7] = bytes[9] = 0x27; // 10000 x 10000 pixels
        try {
            int width, height;
            var stream = new MemoryInputStream.from_bytes(new Bytes(bytes));
            StickerAnimationCompat.new_from_stream(stream, 600, 300, out width, out height);
            fail_if_reached("oversized canvases must not allocate full animated frames");
        } catch (IOError.NO_SPACE expected) { }
        catch (Error error) { fail_if_reached(error.message); }
        try {
            // Valid 10000 x 10000 PNG header with an empty IDAT. Its size is
            // reported during close(), which also reports a decode failure.
            // Keep NO_SPACE so FileImageWidget cannot retry the full decoder.
            uint8[] broken_png = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAIAAAA1LPVwAAAAAElEQVQ1rwYeAAAAAElFTkSuQmCC");
            int width, height;
            var stream = new MemoryInputStream.from_bytes(new Bytes(broken_png));
            StickerAnimationCompat.new_from_stream(stream, 600, 300, out width, out height);
            fail_if_reached("malformed oversized PNGs must not bypass the preview pixel limit");
        } catch (IOError.NO_SPACE expected) { }
        catch (Error error) { fail_if_reached(error.message); }
        try {
            int width, height;
            var cancelled = new Cancellable();
            cancelled.cancel();
            var stream = new MemoryInputStream.from_bytes(new Bytes(Base64.decode(ANIMATED_GIF)));
            StickerAnimationCompat.new_from_stream(stream, 600, 300, out width, out height, cancelled);
            fail_if_reached("cancelled previews must stop decoding");
        } catch (IOError.CANCELLED expected) { }
        catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_failed_thumbnail() {
        Fixture? f = null;
        FileWidget? widget = null;
        try {
            f = new Fixture(false, false);
            var transfer = new FileTransfer() {
                account = f.transfer.account, file_name = "not-downloaded.png", mime_type = "image/png",
                direction = FileTransfer.DIRECTION_RECEIVED, provider = FileManager.HTTP_PROVIDER_ID,
                info = "url:https://example.invalid/not-downloaded.png", size = 100000
            };
            transfer.set_transfer_phase(FileTransfer.Phase.FAILED, "test failed transfer");
            var large = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 1200, 600);
            large.fill(0x4385bfff);
            transfer.thumbnails.add(new Xep.JingleContentThumbnails.Thumbnail() {
                data = new Bytes(Util.pixbuf_to_png_bytes(large)), media_type = "image/png"
            });
            widget = new FileWidget(transfer);
            fail_if(!(widget.get_first_child() is FileDefaultWidget),
                "a failed file must immediately have a usable ordinary card before thumbnail decoding");
            f.scrolled.child = widget;
            wait_for(() => widget.get_mapped(), "file card must map");
            fail_if_not(widget.activate_action("file-details.popup", null));
            iterate_for(50);
            fail_if_not(widget.activate_action("file-details.copy-link", null),
                "Copy Link must work without downloading the failed file");
            wait_for(() => picture(widget) != null, "bounded embedded thumbnail must eventually replace the file card");
            var texture = picture(widget).paintable as Gdk.Texture;
            fail_if(texture == null || texture.get_width() > 320 || texture.get_height() > 320,
                "embedded metadata must not upload the original image dimensions to the renderer");
            fail_if(transfer.path != null || transfer.state != FileTransfer.State.FAILED,
                "showing the embedded preview must not start or change a file download");
            f.scrolled.child = null;
            widget.dispose();
            widget = null;

            // A queued decoder must not retain a chat row that was just closed.
            widget = new FileWidget(transfer);
            var weak_widget = WeakRef(widget);
            widget.dispose();
            widget = null;
            fail_if(weak_widget.get() != null, "closing the chat must release the pending file widget immediately");
            iterate_for(50);
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (widget != null) widget.dispose();
            if (f != null) f.close();
        }
    }

    private void test_large_gif() {
        Fixture? f = null;
        try {
            f = new Fixture(false, true, 0, false, true);
            var loaded = picture(f.image);
            iterate_for(500);
            var texture = loaded.paintable as Gdk.Texture;
            fail_if(texture.get_width() > 600 || texture.get_height() > 300,
                "animated preview frames must not upload the original full-size canvas on the GTK thread");
            fail_if_not_eq_int(1600, f.transfer.width);
            fail_if_not_eq_int(1200, f.transfer.height);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_large_image() {
        Fixture? f = null;
        try {
            f = new Fixture(false, false, 0, true);
            var loaded = picture(f.image);
            if (fail_if(loaded == null, "real encrypted PNG must decode into the production picture")) return;
            fail_if_not_eq_int(600, loaded.target_width,
                "large image must retain its ordinary preview target after decode");
            fail_if_not_eq_int(300, loaded.target_height);
            check_image_width(f.image, f.scrolled);
            fail_if(loaded.get_width() > 260, "decoded image cannot force a horizontal overflow");
            fail_if(Math.fabs(loaded.get_height() - loaded.get_width() / 2.0) > 1,
                "the real inline preview must retain its 2:1 ratio after shrinking");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }
}

}
