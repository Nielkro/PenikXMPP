using Gtk;

namespace Dino.Ui.Test {

class ChatPreviewLayoutRuntimeTest : Gee.TestCase {
    // Match libsoup's const char* parameter, also on MinGW. The explicit
    // length preserves binary PNG data, including embedded NUL bytes.
    [CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
    private extern static void set_preview_response(Soup.ServerMessage message,
        string content_type, Soup.MemoryUse memory_use, string body, size_t length);

    public ChatPreviewLayoutRuntimeTest() {
        base("ChatPreviewLayoutRuntime");
        add_test("late_url_preview_keeps_scroll_position_and_reuses_cached_results", test_async_preview);
        add_test("late_previews_above_and_below_keep_the_reading_position", test_reading_position);
        add_test("header_menus_preserve_history_despite_stale_focus_state", test_header_focus);
        add_test("keyboard_focus_still_reveals_chat_controls", test_chat_keyboard_focus);
        add_test("chat_focus_follows_window_reparenting", test_chat_focus_reparenting);
        add_test("real_url_card_bounds_thumbnail_and_wraps_in_narrow_rows", test_preview);
        add_test("image_target_size_can_shrink_without_losing_aspect_ratio", test_image);
        add_test("bounded_card_reserves_wrapped_height_in_wider_hosts", test_bounded_height);
        add_test("web_thumbnail_keeps_all_image_edges_and_original_aspect", test_thumbnail_edges);
        add_test("html_tokens_and_unicode_offsets_are_locale_independent", test_html_locale);
    }

    private class FocusFixture : Object {
        public Gtk.Window window = new Gtk.Window();
        public Box rows = new Box(Orientation.VERTICAL, 0);
        public Box chat;
        public Gtk.Viewport viewport = new Gtk.Viewport(null, null);
        private ConversationSummary.ChatFocusScroll focus_scroll;
        public ScrolledWindow scrolled = new ScrolledWindow();
        public Entry composer = new Entry() { text = "Unsent draft" };
        public MenuButton[] menus = {};
        public Label[] messages = {};

        public FocusFixture() {
            var root = new Box(Orientation.VERTICAL, 0);
            var header = new Box(Orientation.HORIZONTAL, 0);
            var actions = new SimpleActionGroup();
            actions.add_action(new SimpleAction("noop", null));
            window.insert_action_group("probe", actions);
            var model = new GLib.Menu();
            model.append("Test action", "probe.noop");
            for (int i = 0; i < 3; i++) {
                var menu = new MenuButton() { menu_model = model, label = "Menu %d".printf(i) };
                menus += menu;
                header.append(menu);
            }
            for (int i = 0; i < 40; i++) {
                var message = new Label("Message %d".printf(i)) {
                    selectable = true, height_request = 50, xalign = 0
                };
                messages += message;
                rows.append(message);
            }
            var body = new Box(Orientation.VERTICAL, 0) {
                valign = Align.END, layout_manager = new BinLayout()
            };
            body.append(new Overlay() { child = rows });
            viewport.child = body;
            scrolled.child = viewport;
            focus_scroll = new ConversationSummary.ChatFocusScroll(viewport);
            scrolled.vexpand = true;
            var manager = new ConversationSummary.ChatScrollLayout(scrolled, rows) {
                preserve_visible_row = true
            };
            chat = new Box(Orientation.VERTICAL, 0) { layout_manager = manager, vexpand = true };
            chat.append(new Overlay() { child = scrolled });
            root.append(header);
            root.append(chat);
            root.append(composer);
            window.child = root;
            window.set_default_size(700, 450);
            window.present();
        }
    }

    private void test_header_focus() {
        var fixture = new FocusFixture();
        ulong paint_handler = 0;
        Gdk.FrameClock? clock = null;
        try {
            settle();
            fixture.composer.grab_focus();
            fixture.scrolled.vadjustment.value = 700;
            settle();
            Graphene.Rect original;
            fail_if_not(fixture.messages[14].compute_bounds(fixture.scrolled, out original));
            // Simulate the stale GTK state explicitly. A header control never
            // becomes a descendant of the history, regardless of this flag.
            fixture.viewport.set_state_flags(StateFlags.FOCUS_WITHIN, false);
            clock = fixture.window.get_frame_clock();
            paint_handler = clock.after_paint.connect(() => {
                Graphene.Rect bounds;
                fail_if_not(fixture.messages[14].compute_bounds(fixture.scrolled, out bounds));
                fail_if((bounds.origin.y - original.origin.y).abs() > 0.5,
                    "header focus must not shift the rendered history, even for one frame");
            });
            foreach (MenuButton menu in fixture.menus) {
                for (int repeat = 0; repeat < 3; repeat++) {
                    menu.popup();
                    settle(350);
                    fail_if_not(menu.popover.get_mapped(), "the regression must exercise an open native menu");
                    fail_if((fixture.scrolled.vadjustment.value - 700).abs() > 0.5,
                        "opening a header menu must not scroll towards that menu");
                    menu.popdown();
                    settle(350);
                    fail_if((fixture.scrolled.vadjustment.value - 700).abs() > 0.5,
                        "returning focus to a header button must not progressively scroll older history");
                }
            }
            fail_if_not_eq_str("Unsent draft", fixture.composer.text);
        } finally {
            if (paint_handler != 0) clock.disconnect(paint_handler);
            fixture.window.destroy();
            settle();
        }
    }

    private void test_chat_keyboard_focus() {
        var fixture = new FocusFixture();
        try {
            settle();
            foreach (int index in new int[] { 39, 0, 20 }) {
                fail_if_not(fixture.messages[index].grab_focus());
                settle(50);
                // A layout pass with unchanged row bounds must not cancel
                // GTK's ongoing scroll towards the newly focused control.
                fixture.chat.queue_allocate();
                settle(350);
                Graphene.Rect bounds;
                fail_if_not(fixture.messages[index].compute_bounds(fixture.scrolled, out bounds));
                fail_if(bounds.origin.y < -0.5 ||
                        bounds.origin.y + bounds.size.height > fixture.scrolled.get_height() + 0.5,
                    "keyboard focus must remain visible (message %d: y=%.2f, height=%.2f, viewport=%d)"
                        .printf(index, bounds.origin.y, bounds.size.height, fixture.scrolled.get_height()));
            }
            fail_if_not_eq_str("Unsent draft", fixture.composer.text);
        } finally {
            fixture.window.destroy();
            settle();
        }
    }

    private void test_chat_focus_reparenting() {
        var fixture = new FocusFixture();
        var second_window = new Gtk.Window() { default_width = 700, default_height = 450 };
        try {
            settle();
            Widget content = fixture.window.child;
            fixture.window.child = null;
            second_window.child = content;
            second_window.present();
            settle(350);
            fail_if_not(fixture.messages[39].grab_focus());
            settle(350);
            Graphene.Rect bounds;
            fail_if_not(fixture.messages[39].compute_bounds(fixture.scrolled, out bounds));
            fail_if(bounds.origin.y < -0.5 ||
                    bounds.origin.y + bounds.size.height > fixture.scrolled.get_height() + 0.5,
                "focus scrolling must reconnect to the new window");
            double position = fixture.scrolled.vadjustment.value;
            var old_window_entry = new Entry();
            fixture.window.child = old_window_entry;
            fixture.window.present();
            fail_if_not(old_window_entry.grab_focus());
            settle(350);
            fail_if((fixture.scrolled.vadjustment.value - position).abs() > 0.5,
                "focus in the old window must not move the reparented chat");
        } finally {
            second_window.destroy();
            fixture.window.destroy();
            settle();
        }
    }

    private void test_html_locale() {
        string? previous = Intl.setlocale(LocaleCategory.CTYPE, null);
        Intl.setlocale(LocaleCategory.CTYPE, "");
        var server = new Soup.Server("server-header", "DinoX-locale-preview-test", null);
        var cache = UrlPreviewCache.get_instance();
        ulong handler = 0;
        try {
            server.add_handler(null, (server, message, path, query) => {
                string html = "<html><head><!-- İ 日本語 العربية -->" +
                    (path == "/fallback" ?
                    "<TITLE>İstanbul 日本語 &amp; العربية</TITLE><META NAME='DESCRIPTION' CONTENT='Doğru açıklama'>" :
                    "<META PROPERTY='OG:TITLE' CONTENT='İstanbul 日本語 &amp; العربية'>" +
                    "<META PROPERTY='OG:SITE_NAME' CONTENT='DinoX'><META PROPERTY='OG:DESCRIPTION' CONTENT='Doğru açıklama'>") +
                    "</head></html>";
                message.set_status(200, null);
                set_preview_response(message, "text/html; charset=UTF-8", Soup.MemoryUse.COPY, html, html.length);
            });
            server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            foreach (string path in new string[] { "opengraph", "fallback" }) {
                string url = server.get_uris().data.to_string() + path;
                bool finished = false;
                handler = cache.preview_ready.connect((loaded, data) => { if (loaded == url) finished = true; });
                var card = new UrlPreviewWidget(url);
                int64 deadline = get_monotonic_time() + 5 * TimeSpan.SECOND;
                while (!finished && get_monotonic_time() < deadline) settle();
                fail_if_not(finished, "the local HTML fixture must finish");
                var data = cache.lookup(url);
                if (!fail_if(data == null, "parsed preview must be cached")) {
                    fail_if(data.failed);
                    fail_if_not_eq_str("İstanbul 日本語 & العربية", data.title);
                    fail_if_not_eq_str("Doğru açıklama", data.description);
                    if (path == "opengraph") fail_if_not_eq_str("DinoX", data.site_name);
                }
                cache.disconnect(handler); handler = 0;
                card.dispose();
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (handler != 0) cache.disconnect(handler);
            server.disconnect(); Intl.setlocale(LocaleCategory.CTYPE, previous);
        }
    }

    private void test_reading_position() {
        var messages = new Box(Orientation.VERTICAL, 0) { margin_bottom = 15 };
        var earlier = new Box(Orientation.VERTICAL, 0);
        earlier.append(new Label("Earlier messages") { height_request = 500 });
        var reading = new Label("Currently reading this message") { height_request = 45 };
        var later = new Box(Orientation.VERTICAL, 0);
        later.append(new Label("Later messages") { height_request = 600 });
        messages.append(earlier);
        messages.append(reading);
        messages.append(later);
        // Match the production overlays and bottom-aligned body, not just a
        // bare scrolled window. Layout repairs must cross those wrappers too.
        var body = new Box(Orientation.VERTICAL, 0) { valign = Align.END, layout_manager = new BinLayout() };
        body.append(new Overlay() { child = messages });
        var scrolled = new ScrolledWindow() { child = body };
        var manager = new ConversationSummary.ChatScrollLayout(scrolled, messages);
        var root = new Box(Orientation.VERTICAL, 0) { layout_manager = manager };
        root.append(new Overlay() { child = scrolled });
        var window = new Gtk.Window() { child = root, default_width = 500, default_height = 250 };
        ulong painted_handler = 0;
        Gdk.FrameClock? clock = null;
        try {
            window.present();
            settle();
            scrolled.vadjustment.value = 510;
            settle();
            manager.preserve_visible_row = true;
            Graphene.Rect original;
            fail_if_not(reading.compute_bounds(scrolled, out original));
            clock = window.get_frame_clock();
            int paints = 0;
            painted_handler = clock.after_paint.connect(() => {
                Graphene.Rect current;
                fail_if_not(reading.compute_bounds(scrolled, out current));
                fail_if((current.origin.y - original.origin.y).abs() > 0.5,
                    "each painted frame must keep the message being read at its previous position");
                paints++;
            });
            var data = new UrlPreviewData() {
                url = "https://example.invalid/late-card",
                title = "A late preview that adds height to a message",
                description = "The reading position must not follow changes below the visible message."
            };
            later.append(new UrlPreviewWidget.from_data(data));
            settle();
            fail_if((scrolled.vadjustment.value - 510).abs() > 0.5,
                "a preview below the viewport must not change the scroll position");
            earlier.append(new UrlPreviewWidget.from_data(data));
            settle();
            fail_if(scrolled.vadjustment.value <= 510,
                "a preview above the viewport must be compensated before painting");
            messages.prepend(new Label("Loaded older history") { height_request = 100 });
            settle();
            messages.remove(messages.get_first_child());
            settle();
            fail_if(paints < 4, "the test must observe each late layout change");
        } finally {
            if (painted_handler != 0) clock.disconnect(painted_handler);
            window.destroy();
            settle();
        }
    }

    private void test_async_preview() {
        var server = new Soup.Server("server-header", "DinoX-preview-test", null);
        var cache = UrlPreviewCache.get_instance();
        var messages = new Box(Orientation.VERTICAL, 0);
        var scrolled = new ScrolledWindow() { child = messages };
        var layout = new Box(Orientation.VERTICAL, 0) {
            layout_manager = new ConversationSummary.ChatScrollLayout(scrolled)
        };
        layout.append(scrolled);
        var window = new Gtk.Window() { child = layout, default_width = 500, default_height = 250 };
        var motion = new ConversationSummary.ChatScrollMotion(scrolled);
        ulong changed = scrolled.vadjustment.changed.connect(motion.snap_to_bottom);
        ulong ready = 0;
        int requests = 0;
        try {
            uint8[] image = Util.pixbuf_to_png_bytes(edge_marked_image(1200, 800));
            server.add_handler(null, (server, message, path, query) => {
                requests++;
                message.set_status(200, null);
                if (path == "/preview.png") {
                    set_preview_response(message, "image/png", Soup.MemoryUse.COPY, (string) image, image.length);
                } else {
                    string html = "<html><head><title>Delayed preview</title><meta property='og:image' content='/preview.png'></head></html>";
                    set_preview_response(message, "text/html", Soup.MemoryUse.COPY, html, html.length);
                }
            });
            server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            string url = server.get_uris().data.to_string() + "page";
            bool finished = false;
            ready = cache.preview_ready.connect((loaded_url, data) => {
                if (loaded_url == url) finished = true;
            });
            UrlPreviewWidget? removed = new UrlPreviewWidget(url);
            var removed_ref = WeakRef(removed);
            removed = null;
            fail_if(removed_ref.get() != null,
                "an in-flight preview must not retain rows from a closed chat");
            var earlier = new Label("Earlier message") { height_request = 500 };
            var card = new UrlPreviewWidget(url);
            var latest = new Label("Latest message") { height_request = 45 };
            messages.append(earlier);
            messages.append(card);
            messages.append(latest);
            window.present();
            int64 deadline = get_monotonic_time() + 5000000;
            while (!finished && get_monotonic_time() < deadline) settle();
            fail_if_not(finished, "the local preview request must finish");
            settle();
            fail_if_not_eq_int(2, requests, "simultaneous rows must share one HTML and one image request");
            var data = cache.lookup(url);
            fail_if(data == null || data.failed || data.image_texture == null);
            if (data != null && data.image_texture != null) {
                fail_if(data.image_texture.get_width() > 300 || data.image_texture.get_height() > 200);
                fail_if_not_eq_str("Delayed preview", data.title);
            }
            fail_if(messages.get_first_child() != earlier || messages.get_last_child() != latest,
                "loading a preview must leave neighboring message widgets intact");
            Graphene.Rect bounds;
            fail_if_not(latest.compute_bounds(scrolled, out bounds));
            fail_if((bounds.origin.y + bounds.size.height - scrolled.get_height()).abs() > 0.5,
                "the later URL card must not displace the visible last message");
            var cached_card = new UrlPreviewWidget(url);
            fail_if(cached_card.get_first_child() == null, "a repeated visit must build from cached metadata immediately");
            settle();
            fail_if_not_eq_int(2, requests, "a repeated chat visit must not refetch the URL");
            cached_card.dispose();
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (ready != 0) cache.disconnect(ready);
            scrolled.vadjustment.disconnect(changed);
            window.destroy();
            server.disconnect();
            settle();
        }
    }

    private static void settle(uint milliseconds = 100) {
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private static Picture? picture(Widget root) {
        if (root is Picture) return (Picture) root;
        for (Widget? child = root.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            var result = picture(child);
            if (result != null) return result;
        }
        return null;
    }

    private static void check_bounds(Widget root, Widget ancestor) {
        if (!root.get_visible() || !root.get_mapped()) return;
        Graphene.Rect bounds;
        if (root is Label || root is Picture) {
            fail_if_not(root.compute_bounds(ancestor, out bounds));
            fail_if(bounds.origin.x < -0.5 || bounds.origin.x + bounds.size.width > ancestor.get_width() + 0.5,
                "actual preview text and thumbnail must remain inside the allocated card");
            fail_if(bounds.origin.y < -0.5 || bounds.origin.y + bounds.size.height > ancestor.get_height() + 0.5,
                "bounding preview width must still reserve enough height for its wrapped content");
        }
        for (Widget? child = root.get_first_child(); child != null;
                child = child.get_next_sibling()) check_bounds(child, ancestor);
    }

    private void test_preview() {
        var pixbuf = edge_marked_image(1200, 800);
        var data = new UrlPreviewData() {
            url = "https://example.invalid/local-render-only",
            site_name = "A long site name which must stay in the available preview space",
            title = "A very long title including an_unbroken_component_that_cannot_force_the_chat_to_grow_wider_than_its_window",
            description = "A detailed description that wraps within the card, while keeping the thumbnail compact and all text visible in narrow conversation views.",
            image_texture = Util.texture_from_pixbuf(pixbuf)
        };
        var manager = Adw.StyleManager.get_default();
        var original = manager.color_scheme;
        var original_direction = Widget.get_default_direction();
        try {
            foreach (int width in new int[] { 320, 500, 1000 }) {
                foreach (TextDirection direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                    foreach (Adw.ColorScheme scheme in new Adw.ColorScheme[] {
                            Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                        var window = new Adw.Window();
                        try {
                            manager.color_scheme = scheme;
                            window.add_css_class("dino-main");
                            // A real RTL locale gives every newly constructed
                            // descendant this direction, not just the card root.
                            Widget.set_default_direction(direction);
                            var card = new UrlPreviewWidget.from_data(data);
                            card.set_direction(direction);
                            var row = new Box(Orientation.VERTICAL, 0) {
                                margin_start = 57, margin_end = 15
                            };
                            row.append(card);
                            // Native Windows toplevels have a 360px minimum.
                            // Constrain the chat viewport, not the OS frame.
                            var viewport = new SizingBin() { max_width = width };
                            row.set_parent(viewport);
                            window.content = viewport;
                            window.set_direction(direction);
                            window.set_default_size(width, 360);
                            window.present();
                            settle();
                            int minimum, natural, min_baseline, nat_baseline;
                            row.measure(Orientation.HORIZONTAL, -1, out minimum, out natural,
                                out min_baseline, out nat_baseline);
                            GLib.Test.message("URL card host=%d min=%d natural=%d allocated=%d",
                                width, minimum, natural, card.get_width());
                            fail_if(minimum > 320 || row.get_width() + row.margin_start + row.margin_end > width,
                                "a real URL preview cannot force the conversation wider than the window");
                            fail_if(card.get_width() > 540,
                                "wide chats must retain a compact link card instead of stretching it across the row");
                            var thumbnail = picture(card);
                            if (fail_if(thumbnail == null, "fixture must exercise a real downloaded-size texture")) continue;
                            fail_if(thumbnail.get_width() > 160 || thumbnail.get_height() > 100,
                                "thumbnail must remain bounded without forcing a square");
                            fail_if(Math.fabs(thumbnail.get_width() - thumbnail.get_height() * 1.5) > 1,
                                "the 1200x800 preview must keep its original 3:2 aspect ratio");
                            check_rendered_edges(window, thumbnail);
                            check_bounds(card, card);
                        } finally { window.destroy(); settle(); }
                    }
                }
            }
        } finally {
            manager.color_scheme = original;
            Widget.set_default_direction(original_direction);
        }
    }

    private void test_image() {
        var image = new FixedRatioPicture() {
            min_width = 64, min_height = 1, max_width = 600, max_height = 300,
            target_width = 600, target_height = 300
        };
        int minimum, natural, min_baseline, nat_baseline;
        image.measure(Orientation.HORIZONTAL, -1, out minimum, out natural,
            out min_baseline, out nat_baseline);
        fail_if_not_eq_int(64, minimum, "preferred image width is not a minimum");
        fail_if_not_eq_int(600, natural);
        image.measure(Orientation.VERTICAL, 240, out minimum, out natural,
            out min_baseline, out nat_baseline);
        fail_if_not_eq_int(120, natural, "narrow image must retain its aspect ratio");
        image.measure(Orientation.VERTICAL, 900, out minimum, out natural,
            out min_baseline, out nat_baseline);
        fail_if_not_eq_int(300, natural, "image must not upscale above its preview target");
        var window = new Adw.Window();
        try {
            var viewport = new SizingBin() { max_width = 240 };
            image.set_parent(viewport);
            window.content = viewport;
            window.set_default_size(400, 220);
            window.present(); settle();
            fail_if_not_eq_int(240, image.get_width(),
                "preview must fit the actual content area, excluding window decorations");
        } finally { window.destroy(); settle(); }
    }

    private void test_bounded_height() {
        var bounded = new SizingBin() { max_width = 540 };
        var text = new Label(string.nfill(300, 'x')) {
            wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR
        };
        text.set_parent(bounded);
        int min_at_bound, natural_at_bound, min_in_wide_host, natural_in_wide_host;
        bounded.measure(Orientation.VERTICAL, 540, out min_at_bound,
            out natural_at_bound, null, null);
        bounded.measure(Orientation.VERTICAL, 900, out min_in_wide_host,
            out natural_in_wide_host, null, null);
        fail_if_not_eq_int(natural_at_bound, natural_in_wide_host,
            "a wide host cannot reduce the height reserved for a capped card");
        fail_if_not_eq_int(min_at_bound, min_in_wide_host);
        int min_unconstrained, natural_unconstrained;
        bounded.measure(Orientation.VERTICAL, -1, out min_unconstrained,
            out natural_unconstrained, null, null);
        fail_if_not_eq_int(min_at_bound, min_unconstrained,
            "unconstrained minimum height must account for the width ceiling too");
        bounded.dispose();
    }

    private static Gdk.Pixbuf edge_marked_image(int width, int height) {
        var image = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, width, height);
        image.fill(0x777777ff);
        int horizontal_band = int.max(1, width / 10);
        int vertical_band = int.max(1, height / 10);
        new Gdk.Pixbuf.subpixbuf(image, 0, 0, width, vertical_band).fill(0xffff00ffu);
        new Gdk.Pixbuf.subpixbuf(image, 0, height - vertical_band, width, vertical_band).fill(0x00ff00ffu);
        new Gdk.Pixbuf.subpixbuf(image, 0, 0, horizontal_band, height).fill(0xff0000ffu);
        new Gdk.Pixbuf.subpixbuf(image, width - horizontal_band, 0, horizontal_band, height).fill(0x0000ffffu);
        return image;
    }

    private static void check_rendered_edges(Adw.Window window, Picture picture) {
        var paintable = new WidgetPaintable(picture);
        Gsk.RenderNode? node = null;
        int64 deadline = get_monotonic_time() + 5 * TimeSpan.SECOND;
        // Native windows can be allocated before their first painted frame.
        // Wait for an actual snapshot instead of assuming 100 ms is enough.
        do {
            var snapshot = new Snapshot();
            if (picture.get_mapped() && picture.get_width() > 0 && picture.get_height() > 0) {
                paintable.snapshot(snapshot, picture.get_width(), picture.get_height());
                node = snapshot.to_node();
            }
            if (node != null) break;
            settle();
        } while (get_monotonic_time() < deadline);
        var renderer = window.get_renderer();
        if (fail_if(node == null || renderer == null, "the real GTK thumbnail must render")) return;
        var rendered = ((!) renderer).render_texture((!) node, null);
        size_t stride = rendered.get_width() * 4;
        uint8[] pixels = new uint8[stride * rendered.get_height()];
#if GTK_4_12
        var downloader = new Gdk.TextureDownloader(rendered);
        downloader.set_format(Gdk.MemoryFormat.R8G8B8A8);
        downloader.download_into(pixels, stride);
#else
        rendered.download(pixels, stride);
#endif
        bool red_or_blue = false, other_red_or_blue = false;
        bool green = false, yellow = false;
        for (int offset = 0; offset + 3 < pixels.length; offset += 4) {
            int a = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2];
            // The fallback GDK download may use native BGRA byte order. Both
            // red/blue endpoints and the green/yellow border remain detectable.
            if (a > 200 && g < 70 && b < 70) red_or_blue = true;
            if (b > 200 && g < 70 && a < 70) other_red_or_blue = true;
            if (g > 200 && a < 70 && b < 70) green = true;
            if (g > 200 && ((a > 200 && b < 70) || (b > 200 && a < 70))) yellow = true;
        }
        fail_if_not(red_or_blue && other_red_or_blue && green && yellow,
            "all four coloured image edges must survive the actual GTK render without cropping");
    }

    private void test_thumbnail_edges() {
        int[] widths = {1200, 400, 600, 24};
        int[] heights = {400, 1200, 600, 12};
        for (int index = 0; index < widths.length; index++) {
            int[] dimensions = {widths[index], heights[index]};
            var window = new Adw.Window();
            try {
                var image = edge_marked_image(dimensions[0], dimensions[1]);
                var data = new UrlPreviewData() {
                    url = "https://example.invalid/no-network-aspect-fixture",
                    title = "Preview with visible image edges",
                    image_texture = Util.texture_from_pixbuf(image)
                };
                var card = new UrlPreviewWidget.from_data(data);
                var grid = (Grid) new Builder.from_resource(
                    "/im/dinox/dinox/conversation_item_widget.ui").get_object("main_grid");
                grid.attach(new Label("A message above the webpage preview") { wrap = true, hexpand = true }, 2, 1, 1, 1);
                grid.attach(card, 2, 2, 1, 1);
                window.add_css_class("dino-main");
                // Conversation rows live in a scroll viewport. In particular,
                // a row's minimum height must not become the native window's
                // minimum height during Win32's initial size negotiation.
                window.content = new ScrolledWindow() { child = grid };
                window.set_default_size(500, 300);
                window.present(); settle();
                var thumbnail = picture(card);
                if (fail_if(thumbnail == null)) continue;
                fail_if(thumbnail.get_width() > int.min(160, dimensions[0]) ||
                        thumbnail.get_height() > int.min(100, dimensions[1]),
                    "landscape, portrait and tiny thumbnails must not upscale or exceed their bounds");
                double ratio = (double) dimensions[0] / dimensions[1];
                fail_if(Math.fabs(thumbnail.get_width() - thumbnail.get_height() * ratio) > ratio + 1,
                    "thumbnail allocation must preserve the original image ratio");
                check_rendered_edges(window, thumbnail);
                check_bounds(card, card);
            } finally { window.destroy(); settle(); }
        }
    }
}

}
