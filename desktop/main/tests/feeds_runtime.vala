using Gtk;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui.Test {

class FeedsRuntimeTest : Gee.TestCase {
    public FeedsRuntimeTest() {
        base("FeedsRuntime");
        add_test("embedded_dialog_resizes_children_and_cleanup", layout);
        add_test("native_text_menus_preserve_unicode_selection_and_clipboard", text_menus);
    }
    private void text_menus() {
        const string ORIGINAL = "Привет🙂 Straße é";
        var host = new Adw.Window() { default_width = 500, default_height = 500 };
        var box = new Box(Orientation.VERTICAL, 12);
        var row = new Adw.EntryRow() { title = "Feed URL", text = ORIGINAL };
        var group = new Adw.PreferencesGroup(); group.add(row); box.append(group);
        var entry = new Entry() { text = ORIGINAL }; box.append(entry);
        var view = new TextView() { height_request = 160 }; view.buffer.text = ORIGINAL; box.append(view);
        host.content = box;
        foreach (Widget widget in new Widget[] { row, entry, view }) Util.TextContextMenu.attach(widget);
        host.present(); pump();
        foreach (Widget outer in new Widget[] { row, entry, view }) {
            Widget widget = outer;
            while (widget is Editable) {
                var next = ((Editable) widget).get_delegate() as Widget;
                if (next == null || next == widget) break;
                widget = next;
            }
            widget.grab_focus();
            if (widget is Editable) ((Editable) widget).select_region(0, 7);
            else {
                TextIter start, end;
                view.buffer.get_iter_at_offset(out start, 0);
                view.buffer.get_iter_at_offset(out end, 7);
                view.buffer.select_range(start, end);
            }
            // Keyboard/menu actions must still use GTK's original menu.
            fail_if_not(widget.activate_action("menu.popup", null)); pump();
            PopoverMenu? menu = null;
            for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child is PopoverMenu) { menu = (PopoverMenu) child; break; }
            }
            fail_if(menu == null || !menu.get_mapped(), "Native text menu missing");
            fail_if_not(widget.activate_action("clipboard.cut", null)); pump();
            fail_if_not_eq_str(" Straße é", (widget is Editable) ? ((Editable) widget).text : view.buffer.text);
            fail_if_not(widget.activate_action("clipboard.paste", null)); pump();
            fail_if_not_eq_str(ORIGINAL, (widget is Editable) ? ((Editable) widget).text : view.buffer.text);
            if (menu != null) menu.popdown();
            pump();
        }
        host.destroy(); pump();
    }
    private void layout() {
        if (Environment.get_variable("DINOX_UI_TEST_LOCALE_DIR") != null &&
                Environment.get_variable("LANGUAGE") == "de")
            fail_if_not_eq_str("Konto", _("Account"));
        string? directory = null;
        Database? db = null;
        var server = new Soup.Server("server-header", "DinoX-feed-ui-test", null);
        var host = new Adw.Window() { title = "DinoX", default_width = 960, default_height = 760 };
        var background = new Adw.ToolbarView() { content = new Label("DinoX") };
        background.add_top_bar(new Adw.HeaderBar());
        host.content = background;
        FeedsDialog? dialog = null;
        Feeds.Service? service = null;
        var style = Adw.StyleManager.get_default();
        var previous_scheme = style.color_scheme;
        style.color_scheme = Adw.ColorScheme.FORCE_DARK;
        try {
            directory = DirUtils.make_tmp("dinox-feed-ui-XXXXXX");
            db = new Database(Path.build_filename((!) directory, "dino.db"), "feed-ui-test");
            var interactor = new StreamInteractor.for_tests((!) db);
            var account = new Account(new Jid("игорь@example.test"), "secret") { enabled = true };
            account.persist((!) db);
            var stream = new FeedUiStream();
            var bind = new Bind.Flag();
            bind.my_jid = account.bare_jid.with_resource("feed-ui-test"); bind.finished = true;
            stream.add_flag(bind); stream.negotiation_complete = true;
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            Feeds.Service.start(interactor, (!) db);
            service = interactor.get_module<Feeds.Service>(Feeds.Service.IDENTITY);
            service.store.add(account.id, "alice@example.test", "urn:feed:" + string.nfill(240, 'x') + ":Привет",
                0, 0, 30, new Gee.ArrayList<Feeds.Entry>());
            host.present(); pump();
            uint toplevels = Gtk.Window.get_toplevels().get_n_items();
            dialog = new FeedsDialog(interactor);
            trace_sizes(dialog.child);
            dialog.present(host); pump();
            // Trigger the real load callback while the URL still owns focus,
            // as can also happen during an asynchronous feed refresh.
            int requests = 0;
            server.add_handler(null, (server, message, path, query) => {
                requests++;
                message.set_status(200, null);
                string body = "<rss><channel><item><guid>focus-test</guid><title>Привет 🙂</title></item></channel></rss>";
                set_feed_ui_response(message, "application/rss+xml", Soup.MemoryUse.COPY, body, body.length);
            });
            server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
            var url = find_entry((!) dialog);
            var fetch = find_button((!) dialog, _("Load articles"));
            fail_if(url == null || fetch == null, "The web feed controls must exist");
            if (url != null && fetch != null) {
                url.text = server.get_uris().data.to_string() + "feed";
                fail_if_not(url.grab_focus(), "The visible URL input must accept focus");
                url.set_position(-1); pump();
                var focused_text = host.get_focus();
                fail_if(!(focused_text is Text), "The URL must own native text focus before loading");
                fetch.clicked();
                fail_if(url.is_sensitive(), "The real load operation must disable the input while pending");
                if (focused_text != null) assert_text_focus_released(focused_text);
                pump(1600); // Cover cursor blinking and the local HTTP response.
                fail_if_not_eq_int(1, requests, "One load activation must issue one HTTP request");
                fail_if(!url.is_sensitive(), "The input must become usable again after loading");
                fail_if(find_button((!) dialog, _("Preview and share…")) == null,
                    "The real feed response must be displayed");
                GLib.Test.message("Loading completed with text focus released");

                // Refreshing another page must not steal the URL's focus.
                url.grab_focus(); url.set_position(-1); pump();
                var focus_before = host.get_focus();
                service.changed();
                fail_if(host.get_focus() != focus_before, "Refreshing subscriptions stole focus from another page");
                GLib.Test.message("Unrelated refresh preserved input focus");
            }
            // End the focused-load scenario before the independent layout checks.
            host.set_focus(null); pump();
            var interval = find_interval((!) dialog);
            fail_if(interval == null || interval.value != 30,
                "The interval must be visible on the initial Web feeds page before loading a feed");
            if (interval != null) {
                fail_if(!interval.get_mapped() || interval.adjustment.lower != 5 || interval.adjustment.upper != 1440,
                    "The visible interval must offer 5 to 1440 minutes");
                interval.value = 90;
                pump(); // Let the changed value render before taking a snapshot.
            }
            fail_if(dialog.get_root() != host || host.get_visible_dialog() != dialog,
                "Feeds must be embedded in the application's dialog host");
            fail_if(Gtk.Window.get_toplevels().get_n_items() != toplevels,
                "Opening feeds must not create an independent operating-system window");
            capture(host, "wide");
            host.set_default_size(430, 640); pump();
            fail_if(host.get_width() > 430, "The dialog prevented the application from narrowing");
            Stack? stack = find_stack((!) dialog);
            fail_if(stack == null, "Feed pages missing");
            if (stack != null) {
                stack.visible_child_name = "subscriptions"; pump();
                var list = (Box) stack.get_child_by_name("subscriptions");
                // Hold a reference so the test also detects stale blink work
                // when refresh removes a still-focused subscription editor.
                var editor = new Entry() { text = "90" };
                list.prepend(editor);
                editor.grab_focus(); editor.set_position(-1); pump();
                var focused_text = host.get_focus();
                service.changed();
                fail_if(editor.get_parent() != null, "Subscription refresh must replace the old rows");
                if (focused_text != null) assert_text_focus_released(focused_text);
                pump(1600);
                GLib.Test.message("Focused subscription editor removed cleanly");
            }
            if (stack != null) foreach (string page in new string[] {"web", "subscriptions", "xmpp", "own"}) {
                stack.visible_child_name = page; pump();
                fail_if(dialog.child.get_width() > host.get_width() || dialog.child.get_height() > host.get_height(),
                    "Feed content exceeded its parent window");
                fail_if(stack.get_visible_child() == null || !stack.get_visible_child().get_mapped());
            }
            capture(host, "narrow");
            var compose = find_button((!) dialog, _("Write a post in my feed…"));
            fail_if(compose == null, "Post composer action missing");
            if (compose != null) {
                compose.clicked(); pump();
                var child = host.get_visible_dialog();
                fail_if(child == null || child == dialog || child.get_root() != host,
                    "The composer must use the same application dialog host");
                fail_if(Gtk.Window.get_toplevels().get_n_items() != toplevels,
                    "A feed action created a separate window");
                capture(host, "composer");
                if (child != null && child != dialog) child.close();
                pump();
                fail_if(host.get_visible_dialog() != dialog, "Closing a child must return to Feeds");
                // Closing the owning dialog must also release any open child.
                compose.clicked(); pump();
            }
            dialog.force_close(); pump();
            fail_if(host.get_visible_dialog() != null, "Closing Feeds left a child dialog open");
            dialog = null;
            service.changed();
            service.social.updated(account, account.bare_jid.to_string(), Feeds.Social.MICROBLOG);
            pump();
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (dialog != null) dialog.force_close();
            host.destroy(); pump();
            style.color_scheme = previous_scheme;
            if (service != null) service.shutdown();
            server.disconnect();
            if (db != null) db.close();
            if (directory != null) {
                string path = Path.build_filename((!) directory, "dino.db");
                FileUtils.remove(path); FileUtils.remove(path + "-shm"); FileUtils.remove(path + "-wal"); DirUtils.remove((!) directory);
            }
        }
    }
    [CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
    private extern static void set_feed_ui_response(Soup.ServerMessage message, string? content_type,
        Soup.MemoryUse memory_use, string body, size_t length);

    private void assert_text_focus_released(Widget text) {
        fail_if(text.has_focus, "The old field must no longer have keyboard focus");
        var controllers = text.observe_controllers();
        bool found = false;
        for (uint i = 0; i < controllers.get_n_items(); i++) {
            var focus = controllers.get_item(i) as EventControllerFocus;
            if (focus == null) continue;
            found = true;
            fail_if(focus.is_focus, "GTK's native focus controller missed focus-out");
        }
        fail_if(!found, "The test must inspect a native focus controller");
    }

    private Adw.EntryRow? find_entry(Widget widget) {
        if (widget is Adw.EntryRow && widget.get_mapped()) return (Adw.EntryRow) widget;
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            var entry = find_entry(child); if (entry != null) return entry;
        }
        return null;
    }
    private void trace_sizes(Widget widget) {
        int minimum, natural;
        widget.measure(Orientation.HORIZONTAL, -1, out minimum, out natural, null, null);
        if (minimum > 600) GLib.Test.message("Wide minimum: %s %d/%d", widget.get_type().name(), minimum, natural);
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) trace_sizes(child);
    }
    private Button? find_button(Widget widget, string text) {
        if (widget is Button && ((Button) widget).label == text) return (Button) widget;
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            var button = find_button(child, text); if (button != null) return button;
        }
        return null;
    }
    private Adw.SpinRow? find_interval(Widget widget) {
        if (widget is Adw.SpinRow) return (Adw.SpinRow) widget;
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            var row = find_interval(child); if (row != null) return row;
        }
        return null;
    }
    private void capture(Adw.Window host, string name) {
        string? directory = Environment.get_variable("DINOX_FEEDS_CAPTURE_DIR");
        if (directory == null) return;
        DirUtils.create_with_parents(directory, 0700);
        var snapshot = new Snapshot();
        new WidgetPaintable(host).snapshot(snapshot, host.get_width(), host.get_height());
        var node = snapshot.to_node();
        var renderer = host.get_renderer();
        if (fail_if(node == null || renderer == null, "Screenshot requested before a rendered frame: " + name)) return;
        fail_if_not(renderer.render_texture(node, null).save_to_png(Path.build_filename(directory, name + ".png")));
    }
    private Stack? find_stack(Widget widget) {
        if (widget is Stack && ((Stack) widget).get_child_by_name("web") != null) return (Stack) widget;
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            Stack? stack = find_stack(child); if (stack != null) return stack;
        }
        return null;
    }
    private void pump(int milliseconds = 400) {
        int64 end = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < end) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
    }
}

private class FeedUiStream : XmppStream {
    public FeedUiStream() throws Error { base(new Jid("example.test")); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError { throw new IOError.NOT_CONNECTED("UI fixture"); }
    public override async void write_async(StanzaNode node, int priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError { throw new IOError.NOT_CONNECTED("No network in UI fixture"); }
}
}
