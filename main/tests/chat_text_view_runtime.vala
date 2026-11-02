using Dino.Entities;
using Gee;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

class ChatTextViewRuntimeTest : Gee.TestCase {
    [CCode (cname = "g_subprocess_newv", cheader_filename = "gio/gio.h")]
    private static extern Subprocess subprocess_newv_const(
        [CCode (array_length = false, array_null_terminated = true, type = "const gchar* const*")] string[] argv,
        SubprocessFlags flags) throws Error;

    public ChatTextViewRuntimeTest() {
        base("ChatTextViewRuntime");
        add_test("send_mode_preference_updates_existing_and_new_composers", test_send_mode_binding);
        add_test("native_enter_keys_respect_send_mode_selection_and_composition", test_native_enter_keys);
        add_test("rich_draft_restores_unicode_styles_and_caret_selection", test_rich_draft);
        add_test("draft_restore_clamps_invalid_ranges_without_losing_text", test_draft_ranges);
        add_test("completion_edits_the_caret_token_in_multiline_text", test_multiline_completion);
        add_test("completion_preserves_formats_and_cycles_only_its_word", test_completion_formats);
        add_test("completion_room_and_account_switches_forget_previous_candidates", test_completion_scope);
        add_test("completion_cancels_on_cursor_selection_and_external_edit", test_completion_drift);
        add_test("slash_prefix_removal_preserves_payload_markup_offsets", test_markup_prefix);
        add_test("initialized_composer_releases_widgets_and_signal_owners", test_initialized_composer_lifetime);
        add_test("initialized_composer_drafts_keep_account_and_private_peer_scope", test_initialized_composer_draft_scope);
        add_test("initialized_composer_attachments_follow_availability_and_send_policy", test_initialized_composer_attachments);
        add_test("native_context_menu_keeps_selection_and_clipboard_actions", test_native_context_clipboard);
        add_test("native_context_reset_preserves_draft_and_keyboard_menu", test_native_context_reset);
        add_test("encryption_button_projects_cached_trust_without_activation", test_encryption_button_trust);
        add_test("encryption_menu_radio_selection_changes_only_once", test_encryption_menu_selection);
        add_test("encryption_button_discards_other_accounts_and_stale_chat_events", test_encryption_button_scope);
        add_test("encryption_button_unset_and_dispose_release_menu_and_pending_refresh", test_encryption_button_cleanup);
    }

    private void settle_context(int milliseconds = 80) {
        var loop = new MainLoop();
        Timeout.add(milliseconds, () => { loop.quit(); return Source.REMOVE; });
        loop.run();
        while (MainContext.default().pending()) MainContext.default().iteration(false);
    }

    private Adw.SwitchRow? find_send_mode_switch(Widget widget) {
        if (widget is Adw.SwitchRow && ((Adw.SwitchRow) widget).title ==
                _("Send Messages with Ctrl+Enter")) return (Adw.SwitchRow) widget;
        for (Widget? child = widget.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            var row = find_send_mode_switch(child);
            if (row != null) return row;
        }
        return null;
    }

    private void test_send_mode_binding() {
        ComposerFixture? fixture = null;
        Binding? binding = null;
        try {
            fixture = new ComposerFixture();
            var view = new ChatInput.View().init(fixture.interactor);
            var model = new ViewModel.GeneralPreferencesPage();
            binding = fixture.app.settings.bind_property("send-on-ctrl-enter", model,
                "send-on-ctrl-enter", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            var page = new GeneralPreferencesPage() { model = model };
            page.ensure_content();
            var row = find_send_mode_switch(page);
            fail_if(row == null, "the send mode must be selectable in General preferences");
            if (row == null) return;
            fail_if(row.active || view.chat_text_view.send_on_ctrl_enter,
                "existing profiles must keep Enter to send by default");
            row.active = true;
            fail_if_not(fixture.app.settings.send_on_ctrl_enter);
            fail_if_not(view.chat_text_view.send_on_ctrl_enter,
                "changing the native switch must update an already open composer");
            fail_if_not(new Dino.Entities.Settings.from_db(fixture.db).send_on_ctrl_enter);
            var second_view = new ChatInput.View().init(fixture.interactor);
            fail_if_not(second_view.chat_text_view.send_on_ctrl_enter,
                "a newly opened composer must inherit the saved preference");
            fixture.app.settings.send_on_ctrl_enter = false;
            fail_if(row.active || model.send_on_ctrl_enter ||
                view.chat_text_view.send_on_ctrl_enter || second_view.chat_text_view.send_on_ctrl_enter,
                "switching back must update preferences and every composer immediately");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (binding != null) binding.unbind();
            if (fixture != null) { fixture.settle(); fixture.close(); }
        }
    }

    private void x11_input(string[] arguments) throws Error {
        string[] argv = { "xdotool" };
        foreach (string argument in arguments) argv += argument;
        var process = subprocess_newv_const(argv, SubprocessFlags.STDOUT_SILENCE);
        if (!process.wait_check()) throw new IOError.FAILED("Native key injection failed");
        settle_context();
    }

    private void test_native_enter_keys() {
        // Only enable this in the dedicated Xvfb test. Never focus the user's desktop.
        if (Environment.get_variable("DINOX_TEST_NATIVE_KEYS") != "1") {
            GLib.Test.skip("Native key injection requires the dedicated Xvfb test");
            return;
        }
        var window = new Gtk.Window() { title = "DinoX Enter runtime", default_width = 480 };
        var view = new ChatTextView();
        ComposerFixture? fixture = null;
        window.child = view;
        int sends = 0;
        string sent_text = "";
        view.send_text.connect(() => { sends++; sent_text = view.get_text(); view.text_view.buffer.text = ""; });
        try {
            fixture = new ComposerFixture();
            window.present();
            view.text_view.grab_focus();
            settle_context();
            x11_input({"search", "--name", "^DinoX Enter runtime$", "windowfocus", "--sync"});

            foreach (string key in new string[] {"Return", "KP_Enter", "ctrl+Return"}) {
                view.text_view.buffer.text = "send";
                int before = sends;
                x11_input({"key", "--clearmodifiers", key});
                fail_if_not_eq_int(before + 1, sends, "default mode: " + key);
                fail_if_not_eq_str("send", sent_text);
            }
            view.text_view.buffer.text = "line";
            x11_input({"key", "--clearmodifiers", "shift+Return"});
            fail_if_not_eq_str("line\n", view.get_text());

            view.send_on_ctrl_enter = true;
            int before = sends;
            foreach (string key in new string[] {"Return", "KP_Enter", "shift+Return"}) {
                view.text_view.buffer.text = "line";
                x11_input({"key", "--clearmodifiers", key});
                fail_if_not_eq_int(before, sends, "Ctrl+Enter mode must not send: " + key);
                fail_if_not_eq_str("line\n", view.get_text());
            }
            foreach (string key in new string[] {"ctrl+Return", "ctrl+KP_Enter"}) {
                view.text_view.buffer.text = "first\nsecond";
                int previous = sends;
                x11_input({"key", "--clearmodifiers", key});
                fail_if_not_eq_int(previous + 1, sends, "Ctrl+Enter mode: " + key);
                fail_if_not_eq_str("first\nsecond", sent_text);
            }

            // GTK must replace a selection with a newline.
            view.text_view.buffer.text = "first second";
            TextIter start, end;
            view.text_view.buffer.get_iter_at_offset(out start, 5);
            view.text_view.buffer.get_end_iter(out end);
            view.text_view.buffer.select_range(start, end);
            x11_input({"key", "--clearmodifiers", "Return"});
            fail_if_not_eq_str("first\n", view.get_text());

            foreach (bool mode in new bool[] {false, true}) {
                view.send_on_ctrl_enter = mode;
                before = sends;
                view.text_view.buffer.text = " \n\t";
                x11_input({"key", "--clearmodifiers", mode ? "ctrl+Return" : "Return"});
                fail_if_not_eq_int(before, sends, "whitespace must never be sent");
                view.text_view.buffer.text = "";
                // The simple GTK input method confirms U+4E2D with Enter.
                x11_input({"key", "--clearmodifiers", "ctrl+shift+u", "4", "e", "2", "d", "Return"});
                fail_if_not_eq_int(before, sends, "confirming a composed character must not send");
                fail_if_not_eq_str("中", view.get_text());
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            Util.clear_focus_before_detach(view);
            window.child = null;
            window.destroy();
            settle_context();
            if (fixture != null) fixture.close();
        }
    }

    private PopoverMenu? context_menu(ChatTextView view) {
        for (Widget? child = view.text_view.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            if (child is PopoverMenu) return (PopoverMenu) child;
        }
        return null;
    }

    private bool menu_has_action(GLib.MenuModel model, string action_name) {
        for (int index = 0; index < model.get_n_items(); index++) {
            Variant? action = model.get_item_attribute_value(index,
                GLib.Menu.ATTRIBUTE_ACTION, VariantType.STRING);
            if (action != null && ((!) action).get_string() == action_name) return true;
            foreach (string link in new string[] { GLib.Menu.LINK_SECTION, GLib.Menu.LINK_SUBMENU }) {
                GLib.MenuModel? child = model.get_item_link(index, link);
                if (child != null && menu_has_action((!) child, action_name)) return true;
            }
        }
        return false;
    }

    private string? clipboard_text(ChatTextView view) {
        string? result = null;
        bool finished = false;
        var loop = new MainLoop();
        view.text_view.get_clipboard().read_text_async.begin(null, (object, response) => {
            try { result = view.text_view.get_clipboard().read_text_async.end(response); }
            catch (Error error) { fail_if_reached(error.message); }
            finished = true;
            loop.quit();
        });
        uint deadline = Timeout.add_seconds(2, () => { loop.quit(); return Source.REMOVE; });
        if (!finished) loop.run();
        if (finished) Source.remove(deadline);
        fail_if_not(finished, "the native clipboard must return the selected text");
        return result;
    }

    private void test_native_context_clipboard() {
        var window = new Gtk.Window();
        var view = new ChatTextView();
        window.set_child(view);
        window.present();
        view.restore_draft("first🙂\nsecond", new ArrayList<Xep.MessageMarkup.Span>(), 5, 0);
        settle_context();
        fail_if_not(view.text_view.activate_action("menu.popup", null));
        settle_context();
        PopoverMenu? menu = context_menu(view);
        fail_if(menu == null || !((!) menu).get_mapped(), "keyboard context activation must keep GTK's native menu");
        if (menu != null) {
            GLib.MenuModel? model = ((!) menu).get_menu_model();
            fail_if(model == null);
            if (model != null) {
                foreach (string action in new string[] { "clipboard.cut", "clipboard.copy", "clipboard.paste" }) {
                    fail_if_not(menu_has_action((!) model, action), "the GTK context menu must retain " + action);
                }
            }
        }
        fail_if_not_eq_int(5, view.text_view.buffer.cursor_position);
        TextIter start, end;
        view.text_view.buffer.get_selection_bounds(out start, out end);
        fail_if_not_eq_int(0, start.get_offset());
        fail_if_not_eq_int(5, end.get_offset());
        fail_if_not(view.text_view.activate_action("clipboard.copy", null));
        fail_if_not_eq_str("first", clipboard_text(view));
        fail_if_not(view.text_view.activate_action("clipboard.cut", null));
        fail_if_not_eq_str("🙂\nsecond", view.get_text());
        view.reset_context_menu();
        settle_context();
        fail_if_not(view.text_view.activate_action("menu.popup", null));
        settle_context();
        fail_if_not(view.text_view.activate_action("clipboard.paste", null));
        settle_context();
        fail_if_not_eq_str("first🙂\nsecond", view.get_text());
        view.reset_context_menu();
        settle_context();
        Util.clear_focus_before_detach(view);
        window.set_child(null);
        window.destroy();
    }

    private void test_native_context_reset() {
        var window = new Gtk.Window();
        var view = new ChatTextView();
        window.set_child(view);
        window.present();
        view.restore_draft("é🙂 unchanged", new ArrayList<Xep.MessageMarkup.Span>(), 2, 0);
        settle_context();
        fail_if_not(view.text_view.activate_action("menu.popup", null));
        settle_context();
        view.reset_context_menu();
        settle_context();
        PopoverMenu? menu = context_menu(view);
        fail_if(menu != null && ((!) menu).visible, "a changed conversation must dismiss its previous native menu");
        fail_if_not_eq_str("é🙂 unchanged", view.get_text());
        fail_if_not_eq_int(2, view.text_view.buffer.cursor_position);
        fail_if_not(view.text_view.activate_action("menu.popup", null), "keyboard menu activation remains independent of pointer capture");
        settle_context();
        menu = context_menu(view);
        fail_if(menu == null || !((!) menu).get_mapped());
        view.reset_context_menu();
        settle_context();
        Util.clear_focus_before_detach(view);
        window.set_child(null);
        window.destroy();
    }

    private Gee.List<Xep.MessageMarkup.Span> spans() {
        var result = new ArrayList<Xep.MessageMarkup.Span>();
        result.add(span(0, 5, Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
        result.add(span(6, 10, Xep.MessageMarkup.SpanType.EMPHASIS));
        result.add(span(11, 14, Xep.MessageMarkup.SpanType.DELETED));
        return result;
    }

    private void test_markup_prefix() {
        var input_spans = new ArrayList<Xep.MessageMarkup.Span>();
        input_spans.add(span(0, 4, Xep.MessageMarkup.SpanType.DELETED));
        input_spans.add(span(5, 10, Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
        var stripped = ChatTextView.trim_markup_prefix(input_spans, 5, 5);
        fail_if_not_eq_int(1, stripped.size);
        fail_if_not_eq_int(0, stripped[0].start_char);
        fail_if_not_eq_int(5, stripped[0].end_char);
        fail_if_not(stripped[0].types.contains(Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
        var escaped = ChatTextView.trim_markup_prefix(input_spans, 1, 9);
        fail_if_not_eq_int(4, escaped[1].start_char);
        fail_if_not_eq_int(9, escaped[1].end_char);
        fail_if_not_eq_int(5, input_spans[1].start_char, "draft markup input is unchanged");
    }

    private Xep.MessageMarkup.Span span(int start, int end,
            Xep.MessageMarkup.SpanType type) {
        var types = new ArrayList<Xep.MessageMarkup.SpanType>();
        types.add(type);
        return new Xep.MessageMarkup.Span() {
            types = types, start_char = start, end_char = end
        };
    }

    private bool has_span(ChatTextView view, int start, int end,
            Xep.MessageMarkup.SpanType type) {
        foreach (var markup in view.get_markups()) {
            if (markup.start_char == start && markup.end_char == end &&
                    markup.types.contains(type)) return true;
        }
        return false;
    }

    private void test_rich_draft() {
        var view = new ChatTextView();
        string body = "Grüße\n🙂日中文\nEnd";
        view.restore_draft(body, spans(), 10, 6);
        fail_if_not_eq_str(body, view.get_text());
        fail_if_not(has_span(view, 0, 5, Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
        fail_if_not(has_span(view, 6, 10, Xep.MessageMarkup.SpanType.EMPHASIS));
        fail_if_not(has_span(view, 11, 14, Xep.MessageMarkup.SpanType.DELETED));
        TextIter cursor, bound;
        view.text_view.buffer.get_iter_at_mark(out cursor, view.text_view.buffer.get_insert());
        view.text_view.buffer.get_iter_at_mark(out bound, view.text_view.buffer.get_selection_bound());
        fail_if_not_eq_int(10, cursor.get_offset(), "cursor uses characters rather than UTF-8 bytes");
        fail_if_not_eq_int(6, bound.get_offset());
        fail_if_not_eq_str("🙂日中文", view.text_view.buffer.get_text(bound, cursor, true));
        var saved = view.get_markups();
        view.restore_draft("Other conversation", new ArrayList<Xep.MessageMarkup.Span>());
        fail_if_not_eq_int(0, view.get_markups().size);
        view.restore_draft(body, saved, 10, 6);
        fail_if_not_eq_int(3, view.get_markups().size, "saved spans must not alias cleared buffer tags");
        view.dispose();
    }

    private void test_draft_ranges() {
        var view = new ChatTextView();
        var markups = new ArrayList<Xep.MessageMarkup.Span>();
        markups.add(span(-9, 99, Xep.MessageMarkup.SpanType.EMPHASIS));
        markups.add(span(50, 60, Xep.MessageMarkup.SpanType.DELETED));
        markups.add(span(2, 1, Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
        view.restore_draft("é🙂x", markups, 999, 999);
        fail_if_not_eq_str("é🙂x", view.get_text());
        fail_if_not_eq_int(1, view.get_markups().size);
        fail_if_not(has_span(view, 0, 3, Xep.MessageMarkup.SpanType.EMPHASIS));
        fail_if_not_eq_int(3, view.text_view.buffer.cursor_position);
        fail_if(view.text_view.buffer.has_selection);
        view.restore_draft("", spans());
        fail_if_not_eq_int(0, view.get_markups().size);
        view.dispose();
    }

    // Completion sources are actual account-scoped persisted messages. No
    // stream is attached, and no fake production completion API is introduced.
    private class Fixture : Object {
        public Database db;
        public StreamInteractor interactor;
        public ChatTextView view = new ChatTextView();
        public OccupantsTabCompletor completor;
        public Account first;
        public Account second;
        public Conversation room;
        public Conversation other_room;
        public Conversation second_account_room;
        private int serial = 0;

        public Fixture() throws Error {
            string path = Path.build_filename(Environment.get_user_data_dir(),
                "chat-completion-" + Uuid.string_random() + ".db");
            DirUtils.create_with_parents(Environment.get_user_data_dir(), 0700);
            db = new Database(path, "isolated chat completion runtime test");
            interactor = new StreamInteractor.for_tests(db);
            MessageProcessor.start(interactor, db);
            MessageStorage.start(interactor, db);
            PresenceManager.start(interactor, db);
            BlockingManager.start(interactor);
            Calls.start(interactor, db);
            ConversationManager.start(interactor, db);
            MucManager.start(interactor, db);
            interactor.add_module(new ContentItemStore.for_tests(interactor, db));
            first = new Account(new Jid("first@example.test"), "unused");
            second = new Account(new Jid("second@example.test"), "unused");
            first.persist(db);
            second.persist(db);
            room = conversation(first, "room@example.test");
            other_room = conversation(first, "other@example.test");
            second_account_room = conversation(second, "room@example.test");
            add_sender(room, "Alice");
            add_sender(room, "Alfred");
            add_sender(other_room, "Bob");
            add_sender(second_account_room, "Arthur");
            completor = new OccupantsTabCompletor(interactor, view.text_view);
            completor.initialize_for_conversation(room);
        }

        private Conversation conversation(Account account, string jid) throws Error {
            var result = new Conversation(new Jid(jid), account, Conversation.Type.GROUPCHAT);
            result.persist(db);
            return result;
        }

        private void add_sender(Conversation conversation, string nickname) throws Error {
            DateTime time = new DateTime.now_utc().add_seconds(++serial);
            var message = new Dino.Entities.Message("Completion fixture") {
                account = conversation.account,
                counterpart = conversation.counterpart.with_resource(nickname),
                ourpart = conversation.account.bare_jid,
                direction = Dino.Entities.Message.DIRECTION_RECEIVED,
                type_ = Dino.Entities.Message.Type.GROUPCHAT,
                time = time, local_time = time,
                encryption = Encryption.NONE
            };
            interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).add_message(message, conversation);
            interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).insert_message(message, conversation);
        }

        public void text(string body, int cursor = -1) {
            view.restore_draft(body, new ArrayList<Xep.MessageMarkup.Span>(), cursor);
        }

        public void cursor(int offset) {
            TextIter position;
            view.text_view.buffer.get_iter_at_offset(out position, offset);
            view.text_view.buffer.place_cursor(position);
        }

        public bool tab(bool backwards = false, Gdk.ModifierType modifier = 0) {
            return completor.on_text_input_key_press(backwards ? Gdk.Key.ISO_Left_Tab : Gdk.Key.Tab,
                0, backwards ? Gdk.ModifierType.SHIFT_MASK : modifier);
        }

        public void close() {
            completor.unset_conversation();
            view.dispose();
        }
    }

    private void test_multiline_completion() {
        try {
            var fixture = new Fixture();
            fixture.text("Al\nends Al", 2);
            fail_if_not(fixture.tab());
            fail_if_not_eq_str("Alfred,\nends Al", fixture.view.get_text());
            fail_if_not(fixture.tab());
            fail_if_not_eq_str("Alice,\nends Al", fixture.view.get_text());
            fail_if_not(fixture.tab(true));
            fail_if_not_eq_str("Alfred,\nends Al", fixture.view.get_text());
            fixture.close();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_completion_formats() {
        try {
            var fixture = new Fixture();
            var markups = new ArrayList<Xep.MessageMarkup.Span>();
            markups.add(span(3, 7, Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
            fixture.view.restore_draft("Al body", markups, 2);
            fail_if_not(fixture.tab());
            fail_if_not_eq_str("Alfred, body", fixture.view.get_text());
            fail_if_not(has_span(fixture.view, 8, 12, Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
            fail_if_not(fixture.tab());
            fail_if_not_eq_str("Alice, body", fixture.view.get_text());
            fail_if_not(has_span(fixture.view, 7, 11, Xep.MessageMarkup.SpanType.STRONG_EMPHASIS));
            fixture.close();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_completion_scope() {
        try {
            var fixture = new Fixture();
            fixture.text("Al");
            fail_if_not(fixture.tab());
            fixture.completor.initialize_for_conversation(fixture.other_room);
            fixture.text("B");
            fail_if_not(fixture.tab());
            fail_if_not_eq_str("Bob, ", fixture.view.get_text());
            fixture.completor.initialize_for_conversation(fixture.second_account_room);
            fixture.text("Ar");
            fail_if_not(fixture.tab());
            fail_if_not_eq_str("Arthur, ", fixture.view.get_text());
            var direct = new Conversation(new Jid("peer@example.test"), fixture.first, Conversation.Type.CHAT);
            fixture.completor.initialize_for_conversation(direct);
            fixture.text("Ar");
            fail_if(fixture.tab());
            fail_if_not_eq_str("Ar", fixture.view.get_text());
            fixture.completor.unset_conversation();
            fail_if(fixture.tab());
            fixture.close();
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_completion_drift() {
        try {
            var fixture = new Fixture();
            fixture.text("Al");
            fixture.tab();
            fixture.cursor(0);
            fixture.cursor(8);
            fail_if_not(fixture.tab());
            fail_if_not_eq_str("Alfred, Alfred ", fixture.view.get_text(),
                "after cursor drift an empty caret token starts a fresh recent-sender completion");
            fixture.text("Al");
            fixture.tab();
            fixture.text("B");
            fail_if(fixture.tab(), "an edited buffer must not cycle old Al candidates");
            fixture.text("Al");
            TextIter first, last;
            fixture.view.text_view.buffer.get_start_iter(out first);
            fixture.view.text_view.buffer.get_end_iter(out last);
            fixture.view.text_view.buffer.select_range(first, last);
            fail_if(fixture.tab(), "Tab must not replace selected text");
            fail_if_not_eq_str("Al", fixture.view.get_text());
            fixture.cursor(2);
            fail_if(fixture.tab(false, Gdk.ModifierType.CONTROL_MASK));
            fail_if(fixture.tab(false, Gdk.ModifierType.ALT_MASK));
            fixture.close();
        } catch (Error error) { fail_if_reached(error.message); }
    }
    // A fully initialized input must survive account/conversation transitions
    // without borrowing another target's draft or retaining destroyed widgets.
    private class ComposerEncryptionEntry : Object, Plugins.EncryptionListEntry {
        private Encryption mode;
        private string mode_name;
        public Encryption encryption { get { return mode; } }
        public string name { get { return mode_name; } }
        public Plugins.ConversationEncryptionTrust trust = Plugins.ConversationEncryptionTrust.UNKNOWN;
        public int trust_queries = 0;
        public int activation_calls = 0;
        public int last_account_id = 0;
        public string? last_counterpart = null;

        public ComposerEncryptionEntry(Encryption mode, string mode_name) {
            this.mode = mode;
            this.mode_name = mode_name;
        }

        public Plugins.ConversationEncryptionTrust get_conversation_trust(Conversation conversation) {
            trust_queries++;
            last_account_id = conversation.account.id;
            last_counterpart = conversation.counterpart.bare_jid.to_string();
            return trust;
        }

        public void encryption_activated(Conversation conversation, owned Plugins.SetInputFieldStatus callback) {
            activation_calls++;
        }

        public Object? get_encryption_icon(Conversation conversation, ContentItem item) { return null; }
        public string? get_encryption_icon_name(Conversation conversation, ContentItem item) { return null; }
    }

    private Image? composer_encryption_icon(Widget widget) {
        if (widget is Image) {
            string? icon = ((Image) widget).icon_name;
            if (icon == "changes-allow-symbolic" || icon == "changes-prevent-symbolic" ||
                    icon == "dino-shield-check-symbolic") return (Image) widget;
        }
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            Image? result = composer_encryption_icon(child);
            if (result != null) return result;
        }
        return null;
    }

    private CheckButton? composer_encryption_choice(Widget widget, Encryption encryption) {
        if (widget is CheckButton) {
            var choice = (CheckButton) widget;
            Variant? target = choice.action_target;
            if (choice.action_name == "enc.encryption" && target != null &&
                    target.is_of_type(VariantType.INT32) && target.get_int32() == (int) encryption) return choice;
        }
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            CheckButton? result = composer_encryption_choice(child, encryption);
            if (result != null) return result;
        }
        return null;
    }

    private bool composer_has_label(Widget widget, string text) {
        if (widget is Label && ((Label) widget).label == text) return true;
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            if (composer_has_label(child, text)) return true;
        }
        return false;
    }

    private void assert_composer_encryption_state(MenuButton menu, string css_class,
            string icon_name, string tooltip_part) {
        // Inspect only the composer child, not an icon inside the popover.
        Image? icon = menu.get_child() != null ? composer_encryption_icon(menu.get_child()) : null;
        fail_if(icon == null, "the composer needs its own visible encryption-status image");
        if (icon == null) return;
        fail_if_not_eq_str(icon_name, icon.icon_name ?? "");
        foreach (string candidate in new string[] { "dim-label", "accent", "success", "warning" }) {
            fail_if(icon.has_css_class(candidate) != (candidate == css_class),
                "the composer must retain exactly the current trust colour: " + css_class);
        }
        fail_if_not((menu.tooltip_text ?? "").contains(tooltip_part),
            "the trust state must also be readable as text, independently of its colour");
    }

    private void test_encryption_button_trust() {
        ComposerFixture? fixture = null;
        Gtk.Window? window = null;
        EncryptionButton? controller = null;
        try {
            fixture = new ComposerFixture();
            var omemo = new ComposerEncryptionEntry(Encryption.OMEMO, "OMEMO");
            var pgp = new ComposerEncryptionEntry(Encryption.PGP, "OpenPGP");
            fixture.app.plugin_registry.register_encryption_list_entry(omemo);
            fixture.app.plugin_registry.register_encryption_list_entry(pgp);
            var account = new Account(new Jid("first@example.test"), "fixture") { id = 1 };
            var conversation = new Conversation(new Jid("contact@example.test"), account, Conversation.Type.CHAT) {
                encryption = Encryption.OMEMO
            };
            var menu = new MenuButton();
            controller = new EncryptionButton(fixture.interactor, menu);
            int changes = 0;
            controller.encryption_changed.connect(() => { changes++; });
            window = new Gtk.Window();
            window.set_child(menu);
            window.present();
            controller.set_conversation(conversation);
            fixture.settle();
            int initial_changes = changes;
            Plugins.ConversationEncryptionTrust[] states = {
                Plugins.ConversationEncryptionTrust.UNKNOWN, Plugins.ConversationEncryptionTrust.TRUSTED,
                Plugins.ConversationEncryptionTrust.VERIFIED, Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION
            };
            string[] names = { _("Unknown"), _("Trusted"), _("Verified"), _("Check keys") };
            string[] colours = { "dim-label", "accent", "success", "warning" };
            for (int i = 0; i < states.length; i++) {
                omemo.trust = states[i];
                fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, account, conversation.counterpart);
                fixture.settle();
                assert_composer_encryption_state(menu, colours[i],
                    states[i] == Plugins.ConversationEncryptionTrust.VERIFIED
                        ? "dino-shield-check-symbolic" : "changes-prevent-symbolic", names[i]);
                fail_if_not((menu.tooltip_text ?? "").contains("OMEMO"));
                menu.active = true;
                fixture.settle();
                fail_if_not(menu.popover is PopoverMenu && menu.popover.get_mapped(),
                    "encryption choices must open in the real GTK menu");
#if GTK_4_8
                CheckButton? choice = composer_encryption_choice(menu.popover, Encryption.OMEMO);
                fail_if(choice == null, "the current protocol needs a native actionable radio choice");
                if (choice != null) {
                    fail_if_not(choice.active, "the current conversation mode must stay selected");
                    fail_if_not(composer_has_label(choice, "OMEMO") && composer_has_label(choice, names[i]),
                        "protocol and current trust must be readable on separate labels");
                    Image? choice_icon = composer_encryption_icon(choice);
                    fail_if(choice_icon == null, "the protocol choice needs its own visible status icon");
                    if (choice_icon != null) {
                        foreach (string candidate in colours) {
                            fail_if(choice_icon.has_css_class(candidate) != (candidate == colours[i]),
                                "the popup icon must use exactly the same trust colour as the composer");
                        }
                    }
                }
#endif
                menu.active = false;
                fixture.settle();
            }
            fail_if_not_eq_int(initial_changes, changes,
                "opening the menu and refreshing trust must not restart encryption readiness");
            conversation.encryption = Encryption.PGP;
            int pgp_changes = changes;
            for (int i = 2; i >= 1; i--) {
                pgp.trust = states[i];
                fixture.app.plugin_registry.encryption_trust_changed(Encryption.PGP, account, conversation.counterpart);
                fixture.settle();
                assert_composer_encryption_state(menu, colours[i],
                    states[i] == Plugins.ConversationEncryptionTrust.VERIFIED
                        ? "dino-shield-check-symbolic" : "changes-prevent-symbolic", names[i]);
                fail_if_not((menu.tooltip_text ?? "").contains("OpenPGP"));
                menu.active = true;
                fixture.settle();
#if GTK_4_8
                CheckButton? pgp_choice = composer_encryption_choice(menu.popover, Encryption.PGP);
                fail_if(pgp_choice == null, "OpenPGP must retain its own actionable radio choice");
                if (pgp_choice != null) {
                    fail_if_not(pgp_choice.active && composer_has_label(pgp_choice, "OpenPGP") &&
                        composer_has_label(pgp_choice, names[i]), "OpenPGP must show its own selected trust state");
                    Image? pgp_icon = composer_encryption_icon(pgp_choice);
                    fail_if(pgp_icon == null);
                    if (pgp_icon != null) {
                        foreach (string candidate in colours) {
                            fail_if(pgp_icon.has_css_class(candidate) != (candidate == colours[i]),
                                "OpenPGP's popup colour must follow its own trust state");
                        }
                    }
                }
#endif
                menu.active = false;
            }
            fail_if_not_eq_int(pgp_changes, changes, "OpenPGP trust display updates must not activate encryption");
            omemo.trust = Plugins.ConversationEncryptionTrust.VERIFIED;
            conversation.encryption = Encryption.OMEMO;
            menu.active = true;
            fixture.settle();
            int open_menu_changes = changes;
            pgp.trust = Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION;
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.PGP, account, conversation.counterpart);
            fixture.settle();
            fail_if_not_eq_int((int) Encryption.OMEMO, (int) conversation.encryption,
                "a trust update for another visible protocol must not select it");
            fail_if_not_eq_int(open_menu_changes, changes,
                "updating an inactive protocol's popup row must not restart readiness");
            assert_composer_encryption_state(menu, "success", "dino-shield-check-symbolic", _("Verified"));
#if GTK_4_8
            CheckButton? inactive_pgp = composer_encryption_choice(menu.popover, Encryption.PGP);
            CheckButton? active_omemo = composer_encryption_choice(menu.popover, Encryption.OMEMO);
            fail_if(inactive_pgp == null || active_omemo == null);
            if (inactive_pgp != null && active_omemo != null) {
                fail_if(inactive_pgp.active || !active_omemo.active,
                    "an inactive protocol's trust update must preserve the existing radio selection");
                fail_if_not(composer_has_label(inactive_pgp, _("Check keys")) &&
                    composer_has_label(active_omemo, _("Verified")),
                    "the changed OpenPGP status must not overwrite the OMEMO status");
                Image? pgp_icon = composer_encryption_icon(inactive_pgp);
                fail_if(pgp_icon == null);
                if (pgp_icon != null) {
                    foreach (string candidate in colours) {
                        fail_if(pgp_icon.has_css_class(candidate) != (candidate == "warning"),
                            "the inactive OpenPGP choice must receive only its new warning colour");
                    }
                }
            }
#endif
            menu.active = false;
            fail_if_not_eq_int(0, omemo.activation_calls + pgp.activation_calls,
                "rendering trust must never activate either encryption plugin");
            conversation.encryption = Encryption.NONE;
            fixture.settle();
            assert_composer_encryption_state(menu, "dim-label", "changes-allow-symbolic", _("Unencrypted"));
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controller != null) controller.unset_conversation();
            if (window != null) { Util.clear_focus_before_detach(window); window.set_child(null); window.destroy(); window = null; }
            controller = null;
            if (fixture != null) { fixture.settle(); fixture.close(); }
        }
    }

    private void test_encryption_menu_selection() {
        ComposerFixture? fixture = null;
        Gtk.Window? window = null;
        EncryptionButton? controller = null;
        try {
            fixture = new ComposerFixture();
            fixture.app.plugin_registry.register_encryption_list_entry(new ComposerEncryptionEntry(Encryption.OMEMO, "OMEMO"));
            fixture.app.plugin_registry.register_encryption_list_entry(new ComposerEncryptionEntry(Encryption.PGP, "OpenPGP"));
            var account = new Account(new Jid("first@example.test"), "fixture") { id = 1 };
            var conversation = new Conversation(new Jid("contact@example.test"), account, Conversation.Type.CHAT);
            var menu = new MenuButton();
            controller = new EncryptionButton(fixture.interactor, menu);
            window = new Gtk.Window();
            window.set_child(menu);
            window.present();
            controller.set_conversation(conversation);
            fixture.settle();
            int changes = 0;
            controller.encryption_changed.connect(() => { changes++; });
            Encryption[] selections = { Encryption.OMEMO, Encryption.PGP, Encryption.NONE };
            for (int i = 0; i < selections.length; i++) {
                menu.active = true;
                fixture.settle();
                fail_if_not_eq_int(i, changes, "opening a choice menu must not change the saved encryption mode");
#if GTK_4_8
                CheckButton? choice = composer_encryption_choice(menu.popover, selections[i]);
                fail_if(choice == null, "every mode must retain its enc.encryption integer target");
                if (choice == null) return;
                fail_if_not(((Widget) choice).activate(), "native keyboard activation must select the protocol");
#else
                fail_if_not(menu.activate_action("enc.encryption", "i", (int) selections[i]));
#endif
                fixture.settle();
                fail_if_not_eq_int((int) selections[i], (int) conversation.encryption,
                    "the actual choice must update the original conversation");
                fail_if_not_eq_int(i + 1, changes,
                    "a native radio activation must trigger exactly one encryption change");
                fail_if(menu.active, "an explicit selection should dismiss the choice menu");
                menu.active = true;
                fixture.settle();
#if GTK_4_8
                foreach (Encryption option in new Encryption[] { Encryption.NONE, Encryption.OMEMO, Encryption.PGP }) {
                    CheckButton? selected = composer_encryption_choice(menu.popover, option);
                    fail_if(selected == null || selected.active != (option == selections[i]),
                        "reopening must show exactly the currently selected protocol");
                }
#endif
                menu.active = false;
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controller != null) controller.unset_conversation();
            if (window != null) { Util.clear_focus_before_detach(window); window.set_child(null); window.destroy(); window = null; }
            controller = null;
            if (fixture != null) { fixture.settle(); fixture.close(); }
        }
    }

    private void test_encryption_button_scope() {
        ComposerFixture? fixture = null;
        Gtk.Window? window = null;
        EncryptionButton? controller = null;
        try {
            fixture = new ComposerFixture();
            var entry = new ComposerEncryptionEntry(Encryption.OMEMO, "OMEMO");
            fixture.app.plugin_registry.register_encryption_list_entry(entry);
            var first = new Account(new Jid("same@example.test"), "fixture") { id = 1 };
            var second = new Account(new Jid("same@example.test"), "fixture") { id = 2 };
            var peer = new Jid("contact@example.test");
            var old_chat = new Conversation(peer, first, Conversation.Type.CHAT) { encryption = Encryption.OMEMO };
            var current = new Conversation(peer, second, Conversation.Type.CHAT) { encryption = Encryption.OMEMO };
            var menu = new MenuButton();
            controller = new EncryptionButton(fixture.interactor, menu);
            window = new Gtk.Window();
            window.set_child(menu);
            window.present();
            controller.set_conversation(old_chat);
            fixture.settle();
            menu.active = true;
            fixture.settle();
            // Leave an old-target refresh pending while moving to an account
            // with the same bare address, as in restored/duplicated profiles.
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, first, peer);
            entry.trust = Plugins.ConversationEncryptionTrust.VERIFIED;
            controller.set_conversation(current);
            fixture.settle();
            fail_if(menu.active, "switching accounts must dismiss the old target's menu");
            fail_if_not_eq_int(second.id, entry.last_account_id);
            assert_composer_encryption_state(menu, "success", "dino-shield-check-symbolic", _("Verified"));
            int queries = entry.trust_queries;
            entry.trust = Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION;
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, first, peer);
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, second, new Jid("elsewhere@example.test"));
            fixture.settle();
            fail_if_not_eq_int(queries, entry.trust_queries,
                "a different account id or contact must not repaint the current composer");
            assert_composer_encryption_state(menu, "success", "dino-shield-check-symbolic", _("Verified"));
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, second, peer.with_resource("phone"));
            fixture.settle();
            assert_composer_encryption_state(menu, "warning", "changes-prevent-symbolic", _("Check keys"));
            // Own-device trust contributes to an outgoing OMEMO recipient set.
            entry.trust = Plugins.ConversationEncryptionTrust.TRUSTED;
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, second, second.bare_jid);
            fixture.settle();
            assert_composer_encryption_state(menu, "accent", "changes-prevent-symbolic", _("Trusted"));
            var next = new Conversation(new Jid("next@example.test"), second, Conversation.Type.CHAT) {
                encryption = Encryption.OMEMO
            };
            entry.trust = Plugins.ConversationEncryptionTrust.VERIFIED;
            controller.set_conversation(next);
            fixture.settle();
            queries = entry.trust_queries;
            entry.trust = Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION;
            old_chat.notify_property("encryption");
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, second, peer);
            fixture.settle();
            fail_if_not_eq_int(queries, entry.trust_queries,
                "the old conversation's notify and contact events must stay disconnected");
            fail_if_not_eq_str(next.counterpart.to_string(), entry.last_counterpart ?? "");
            assert_composer_encryption_state(menu, "success", "dino-shield-check-symbolic", _("Verified"));
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controller != null) controller.unset_conversation();
            if (window != null) { Util.clear_focus_before_detach(window); window.set_child(null); window.destroy(); window = null; }
            controller = null;
            if (fixture != null) { fixture.settle(); fixture.close(); }
        }
    }

    private void test_encryption_button_cleanup() {
        ComposerFixture? fixture = null;
        Gtk.Window? window = null;
        EncryptionButton? controller = null;
        MenuButton? menu = null;
        try {
            fixture = new ComposerFixture();
            var entry = new ComposerEncryptionEntry(Encryption.OMEMO, "OMEMO");
            fixture.app.plugin_registry.register_encryption_list_entry(entry);
            var account = new Account(new Jid("first@example.test"), "fixture") { id = 1 };
            var conversation = new Conversation(new Jid("contact@example.test"), account, Conversation.Type.CHAT) {
                encryption = Encryption.OMEMO
            };
            menu = new MenuButton();
            controller = new EncryptionButton(fixture.interactor, menu);
            window = new Gtk.Window();
            window.set_child(menu);
            window.present();
            controller.set_conversation(conversation);
            fixture.settle();
            menu.active = true;
            fixture.settle();
            var weak_controller = WeakRef(controller);
            var weak_menu = WeakRef(menu);
            var weak_popover = WeakRef(menu.popover);
            var weak_icon = WeakRef(composer_encryption_icon(menu.get_child()));
            var weak_choice = WeakRef(composer_encryption_choice(menu.popover, Encryption.OMEMO));
            controller.unset_conversation();
            fixture.settle();
            int queries = entry.trust_queries;
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, account, conversation.counterpart);
            fixture.settle();
            fail_if_not_eq_int(queries, entry.trust_queries, "unset must stop following the previous target");
            fail_if(menu.visible || menu.active, "an unset encryption selector must be hidden and closed");
            controller.set_conversation(conversation);
            // Dispose before a coalesced display refresh has run.
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, account, conversation.counterpart);
            Util.clear_focus_before_detach(menu);
            window.set_child(null);
            window.destroy();
            window = null;
            controller = null;
            menu = null;
            fixture.settle();
            fail_if_not(weak_controller.get() == null, "registry or idle retained the encryption controller");
            fail_if_not(weak_menu.get() == null, "destroyed composer retained its encryption menu button");
            var retained_popover = weak_popover.get() as Popover;
            if (retained_popover != null) {
                GLib.Test.message("Retained popover refs=%u parent=%s root=%s visible=%s mapped=%s realized=%s",
                    retained_popover.ref_count,
                    retained_popover.get_parent() != null ? retained_popover.get_parent().get_type().name() : "none",
                    retained_popover.get_root() != null ? retained_popover.get_root().get_type().name() : "none",
                    retained_popover.visible.to_string(), retained_popover.get_mapped().to_string(), retained_popover.get_realized().to_string());
            }
            retained_popover = null;
            fail_if_not(weak_popover.get() == null, "disposed selector retained the GTK popover");
            fail_if_not(weak_icon.get() == null, "disposed selector retained its coloured status icon");
            fail_if_not(weak_choice.get() == null, "disposed selector retained an actionable menu row");
            // Emitting after disposal must not access widgets or a dead target.
            queries = entry.trust_queries;
            fixture.app.plugin_registry.encryption_trust_changed(Encryption.OMEMO, account, conversation.counterpart);
            fixture.settle();
            fail_if_not_eq_int(queries, entry.trust_queries);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controller != null) controller.unset_conversation();
            if (window != null) { Util.clear_focus_before_detach(window); window.set_child(null); window.destroy(); window = null; }
            controller = null;
            menu = null;
            if (fixture != null) { fixture.settle(); fixture.close(); }
        }
    }

    private class ComposerApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public Dino.Security.FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
        public Dino.SearchPathGenerator? search_path_generator { get; set; }

        public ComposerApplication(Database db, Dino.Security.FileEncryption encryption) {
            Object(application_id: "im.dinox.composer-runtime-test", flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.file_encryption = encryption;
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.settings.stickers_enabled = false;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    private class ComposerFixture : Object {
        public Database db;
        public StreamInteractor interactor;
        public ComposerApplication app;
        private GLib.Application? previous_app;
        private string root;

        public ComposerFixture(bool avatars = false) throws Error {
            previous_app = GLib.Application.get_default();
            root = DirUtils.make_tmp("dinox-composer-runtime-XXXXXX");
            db = new Database(Path.build_filename(root, "core.db"), "isolated composer fixture");
            var encryption = new Dino.Security.FileEncryption("isolated composer fixture");
            app = new ComposerApplication(db, encryption);
            GLib.Application.set_default(app);
            interactor = new StreamInteractor.for_tests(db);
            app.stream_interactor = interactor;
            MessageProcessor.start(interactor, db);
            PresenceManager.start(interactor, db);
            Calls.start(interactor, db);
            ConversationManager.start(interactor, db);
            MucManager.start(interactor, db);
            Dino.Stickers.start(interactor, db, encryption);
            if (avatars) {
                RosterManager.start(interactor, db);
                EntityInfo.start(interactor, db);
                AvatarManager.start(interactor, db, encryption);
            }
        }

        public void settle() {
            var loop = new MainLoop();
            Timeout.add(120, () => { loop.quit(); return Source.REMOVE; });
            loop.run();
            while (MainContext.default().pending()) MainContext.default().iteration(false);
        }

        public void close() {
            interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY).shutdown();
            GLib.Application.set_default(previous_app);
            db.close();
            foreach (string suffix in new string[]{"", "-wal", "-shm"}) {
                FileUtils.unlink(Path.build_filename(root, "core.db" + suffix));
            }
            DirUtils.remove(root);
        }
    }

    private void test_initialized_composer_lifetime() {
        ComposerFixture? fixture = null;
        try {
            fixture = new ComposerFixture();
            for (int i = 0; i < 4; i++) {
                Gtk.Window? window = new Gtk.Window();
                ChatInput.View? view = new ChatInput.View().init(fixture.interactor);
                window.set_child(view);
                window.present();
                fixture.settle();
                var weak_view = WeakRef(view);
                var weak_editor = WeakRef(view.chat_text_view);
                var weak_lock = WeakRef(view.encryption_button);
                var weak_emoji = WeakRef(view.emoji_button);
                Util.clear_focus_before_detach(view);
                window.set_child(null);
                window.destroy();
                window = null;
                view = null;
                fixture.settle();
                fail_if_not(weak_view.get() == null, "initialized input retained by global settings/signals");
                fail_if_not(weak_editor.get() == null, "destroyed input retains its editor");
                fail_if_not(weak_lock.get() == null, "destroyed input retains encryption action/menu");
                fail_if_not(weak_emoji.get() == null, "destroyed input retains emoji action/menu");
            }
            fixture.app.settings.location_sharing_enabled = !fixture.app.settings.location_sharing_enabled;
            fixture.settle();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_initialized_composer_draft_scope() {
        ComposerFixture? fixture = null;
        Gtk.Window? window = null;
        ChatInput.View? view = null;
        try {
            fixture = new ComposerFixture(true);
            var first = new Account(new Jid("same@example.test"), "fixture") { id = 1 };
            var second = new Account(new Jid("same@example.test"), "fixture") { id = 2 };
            var a = new Conversation(new Jid("alice@example.test"), first, Conversation.Type.CHAT) { id = 11 };
            var b = new Conversation(new Jid("bob@example.test"), first, Conversation.Type.CHAT) { id = 12 };
            var other = new Conversation(new Jid("alice@example.test"), second, Conversation.Type.CHAT) { id = 11 };
            window = new Gtk.Window();
            view = new ChatInput.View().init(fixture.interactor);
            window.set_child(view);
            window.present();
            view.initialize_for_conversation(a);
            view.chat_text_view.restore_draft("Grüße\n🙂日中文\nEnd", spans(), 10, 6);
            view.initialize_for_conversation(b);
            fail_if_not_eq_str("", view.text, "a different conversation must start with its own draft");
            view.text = "Draft B";
            view.initialize_for_conversation(a);
            fail_if_not_eq_str("Grüße\n🙂日中文\nEnd", view.text);
            fail_if_not_eq_int(3, view.chat_text_view.get_markups().size);
            fail_if_not_eq_int(10, view.chat_text_view.text_view.buffer.cursor_position);
            TextIter start, end;
            view.chat_text_view.text_view.buffer.get_selection_bounds(out start, out end);
            fail_if_not_eq_int(6, start.get_offset());
            fail_if_not_eq_int(10, end.get_offset());
            view.initialize_for_conversation(other);
            fail_if_not_eq_str("", view.text, "same bare JID must not merge distinct account rows");
            view.initialize_for_conversation(a);
            fail_if_not_eq_str("Grüße\n🙂日中文\nEnd", view.text);
            var pm = new Conversation(new Jid("room@example.test/Nick"), first,
                Conversation.Type.GROUPCHAT_PM) { id = 13, muc_pm_peer_identity = "occupant:original" };
            view.initialize_for_conversation(pm);
            view.text = "Draft for the original occupant";
            view.initialize_for_conversation(b);
            pm.muc_pm_peer_identity = "real-jid:promoted@example.test";
            view.initialize_for_conversation(pm);
            fail_if_not_eq_str("Draft for the original occupant", view.text,
                "stronger identity evidence for the continuous occupant must keep the draft");
            pm.history_cleared_at = new DateTime.from_unix_utc(50);
            fixture.interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_cleared(pm);
            fail_if_not_eq_str("Draft for the original occupant", view.text,
                "ordinary history clear after identity promotion must keep the same person's draft");
            view.initialize_for_conversation(b);
            pm.history_cleared_at = new DateTime.from_unix_utc(100);
            pm.muc_pm_peer_identity = "occupant:replacement";
            view.initialize_for_conversation(pm);
            fail_if_not_eq_str("", view.text, "replacement occupant must not receive the old private draft");
            view.text = "Replacement draft";
            pm.history_cleared_at = new DateTime.from_unix_utc(200);
            pm.muc_pm_peer_identity = "occupant:third";
            fixture.interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_cleared(pm);
            fail_if_not_eq_str("", view.text, "active peer replacement must clear the current private draft");
            view.initialize_for_conversation(a);
            // The real disconnect lifecycle initializes protocol modules before
            // emitting account_removed. Do not create a network connection.
            fixture.interactor.module_manager.initialize(first);
            fixture.interactor.account_removed(first);
            fail_if_not_eq_str("", view.text);
            fail_if(view.record_button.sensitive);
            fail_if(view.send_button.sensitive);
            view.initialize_for_conversation(b);
            view.initialize_for_conversation(a);
            fail_if_not_eq_str("", view.text, "removed account drafts must not resurrect");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (view != null) Util.clear_focus_before_detach(view);
            if (window != null) { window.set_child(null); window.destroy(); window = null; }
            view = null;
            if (fixture != null) { fixture.settle(); fixture.close(); }
        }
    }

    private void test_initialized_composer_attachments() {
        ComposerFixture? fixture = null;
        ChatInput.View? view = null;
        try {
            fixture = new ComposerFixture();
            fixture.app.settings.location_sharing_enabled = true;
            view = new ChatInput.View().init(fixture.interactor);
            view.set_file_upload_active(false);
            view.text = "Draft";
            view.set_send_allowed(true);
            fail_if_not(view.file_button.visible, "location-only servers still need the attachment menu");
            fail_if(view.send_file_button.visible, "HTTP file action must be absent when unavailable");
            fail_if_not(view.send_location_button.visible && view.send_location_button.sensitive);
            view.set_location_request_active(true);
            fail_if(view.send_location_button.sensitive, "an active location lookup must suppress duplicate requests");
            view.set_location_request_active(false);
            fail_if_not(view.send_location_button.sensitive);
            view.set_send_allowed(false);
            fail_if(view.file_button.sensitive || view.send_location_button.sensitive ||
                view.record_button.sensitive || view.video_record_button.sensitive ||
                view.send_button.sensitive || view.sticker_button.sensitive,
                "blocked composer policy must apply to every send affordance");
            fixture.app.settings.location_sharing_enabled = false;
            fail_if(view.file_button.visible, "empty attachment menus must not remain visible");
            view.set_file_upload_active(true);
            view.set_send_allowed(true);
            fail_if_not(view.file_button.visible && view.send_file_button.visible && view.send_file_button.sensitive);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            view = null;
            if (fixture != null) { fixture.settle(); fixture.close(); }
        }
    }
}

}
