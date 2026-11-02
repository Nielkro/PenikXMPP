using Dino.Entities;
using Dino.Security;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

// These tests drive the production controller, native row factory and actual
// offline MucManager against a private, persisted multi-account profile.
class MucHistoryPreferencesRuntimeTest : Gee.TestCase {
    private const string PROFILE_KEY = "isolated MUC history UI runtime test";

    public MucHistoryPreferencesRuntimeTest() {
        base("MucHistoryPreferencesRuntime");
        add_test("Auto_custom_boundaries_persist_for_only_the_selected_account_and_room", test_period_scope);
        add_test("LoadNow_commits_pending_native_text_and_reports_next_join_honestly", test_load_now);
        add_test("reused_context_and_changed_durable_identity_cannot_retarget_controls", test_context_scope);
        add_test("closing_disconnects_controls_and_weak_callbacks_release_owner", test_lifetime);
        add_test("Section_preserves_legacy_Text_rows_before_and_after_heading", test_sections);
        add_test("native_rebuild_commits_pending_number_and_clears_detached_focus", test_rebuild);
        add_test("localized_section_fits_460px_with_native_keyboard_controls", test_layout);
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public TestApplication(Database db, StreamInteractor interactor) {
            Object(application_id: "im.dinox.muc-history-ui-runtime-test", flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            db_key = PROFILE_KEY;
            file_encryption = new FileEncryption(PROFILE_KEY);
            settings = new Dino.Entities.Settings.from_db(db);
            stream_interactor = interactor;
        }
        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    // The real dialog model uses this same observable conversation property;
    // source reuse is checked by the production weak provider before any save.
    private class Context : Object {
        public Conversation conversation { get; set; }
        public Context(Conversation conversation) { this.conversation = conversation; }
    }

    private class Fixture : Object {
        public string root;
        public string path;
        public Database db;
        public StreamInteractor interactor;
        public MucManager manager;
        public Account first;
        public Account second;
        public Conversation room;
        public Conversation other_account_room;
        public Conversation sibling_room;
        private TestApplication app;
        private GLib.Application? previous_app;
        private bool closed = false;

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-muc-history-ui-XXXXXX");
            path = Path.build_filename(root, "dino.db");
            db = new Database(path, PROFILE_KEY);
            interactor = new StreamInteractor.for_tests(db);
            previous_app = GLib.Application.get_default();
            app = new TestApplication(db, interactor);
            GLib.Application.set_default(app);
            MessageProcessor.start(interactor, db);
            MessageStorage.start(interactor, db);
            PresenceManager.start(interactor, db);
            Calls.start(interactor, db);
            ConversationManager.start(interactor, db);
            MucManager.start(interactor, db);
            manager = interactor.get_module<MucManager>(MucManager.IDENTITY);
            first = new Account(new Jid("first@example.test"), "fixture") { enabled = true };
            second = new Account(new Jid("second@example.test"), "fixture") { enabled = true };
            first.persist(db);
            second.persist(db);
            room = persisted_room(first, "same@conference.example.test");
            other_account_room = persisted_room(second, "same@conference.example.test");
            sibling_room = persisted_room(first, "other@conference.example.test");
        }

        private Conversation persisted_room(Account account, string jid) throws Error {
            var conversation = new Conversation(new Jid(jid), account, Conversation.Type.GROUPCHAT);
            conversation.persist(db);
            return conversation;
        }

        public int saved_days(Conversation conversation) {
            var row = db.conversation.select().with(db.conversation.id, "=", conversation.id).single().row().inner;
            return row[db.conversation.muc_history_days];
        }

        public void close() {
            if (closed) return;
            closed = true;
            manager.shutdown();
            drain();
            GLib.Application.set_default(previous_app);
            db.close();
            FileUtils.remove(path);
            FileUtils.remove(path + "-wal");
            FileUtils.remove(path + "-shm");
            DirUtils.remove(root);
        }
    }

    private static ConversationDetails.HistoryLoadPreferences preferences(Context context, MucManager manager) {
        WeakRef context_weak = WeakRef(context);
        return new ConversationDetails.HistoryLoadPreferences(context.conversation, manager, context, () => {
            var current = context_weak.get() as Context;
            return current != null ? current.conversation : null;
        });
    }

    private void test_period_scope() {
        Fixture? fixture = null;
        ConversationDetails.HistoryLoadPreferences? controls = null;
        try {
            fixture = new Fixture();
            var context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            fail_if(controls.custom_period.state, "default must be Auto");
            fail_if(controls.days.enabled, "Auto must disable the custom period editor");
            fail_if_not_eq_int(30, controls.days.value);
            controls.custom_period.state = true;
            fail_if_not_eq_int(30, fixture.saved_days(fixture.room));
            controls.days.value = 1;
            fail_if_not_eq_int(1, fixture.saved_days(fixture.room));
            controls.days.value = 365;
            fail_if_not_eq_int(365, fixture.saved_days(fixture.room));
            fail_if_not_eq_int(0, fixture.saved_days(fixture.other_account_room));
            fail_if_not_eq_int(0, fixture.saved_days(fixture.sibling_room));
            fail_if_not_eq_str(_("The saved setting also applies when you next join this group."), controls.load_now.description);
            fail_if(fixture.interactor.get_stream(fixture.first) != null,
                "editing preferences must not connect an offline account");
            var reopened = new Database(fixture.path, PROFILE_KEY);
            var row = reopened.conversation.select().with(reopened.conversation.id, "=", fixture.room.id).single().row().inner;
            var cold_room = new Conversation.from_row(reopened, row);
            fail_if_not_eq_int(365, cold_room.muc_history_days, "saved preference must survive a fresh database reader");
            reopened.close();
            controls.custom_period.state = false;
            fail_if_not_eq_int(0, fixture.saved_days(fixture.room));
            fail_if(controls.days.enabled);
            controls.days.value = 80;
            fail_if_not_eq_int(0, fixture.saved_days(fixture.room), "disabled custom input cannot replace Auto");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (controls != null) controls.close(); if (fixture != null) fixture.close(); }
    }

    private void test_load_now() {
        Fixture? fixture = null;
        ConversationDetails.HistoryLoadPreferences? controls = null;
        var window = new Adw.Window();
        try {
            fixture = new Fixture();
            var context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            controls.custom_period.state = true;
            var rows = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
            controls.append_to(rows);
            var groups = Util.rows_to_preference_groups_with_sections(rows, _("Settings"));
            var box = new Box(Orientation.VERTICAL, 12);
            foreach (var group in groups) box.append(group);
            window.content = box;
            window.set_default_size(460, 420);
            window.present();
            drain();
            var native_days = find_spin(box);
            fail_if(native_days == null, "factory must render an actual native SpinRow");
            if (native_days == null) return;
            fail_if_not(native_days.grab_focus(), "native period must support keyboard editing");
            ((Editable) native_days).text = "90";
            // GtkEditable text has not yet been committed to the adjustment.
            fail_if_not_eq_int(30, controls.days.value);
            var button = find_button(box, _("Load now"));
            fail_if(button == null);
            if (button == null) return;
            button.clicked();
            fail_if_not_eq_int(90, controls.days.value);
            fail_if_not_eq_int(90, fixture.saved_days(fixture.room));
            fail_if_not_eq_str(_("Saved. History will be loaded when you next join this group."), controls.load_now.description);
            ((Editable) native_days).text = "999";
            controls.days.commit();
            fail_if_not_eq_int(365, controls.days.value, "native range must cap custom periods at365 days");
            ((Editable) native_days).text = "0";
            controls.days.commit();
            fail_if_not_eq_int(1, controls.days.value, "custom periods must stay at least1 day");
            controls.days.value = 91;
            fail_if_not_eq_str(_("The saved setting also applies when you next join this group."), controls.load_now.description,
                "a later period edit must restore helper text instead of a stale requested/completed status");
            fail_if_not_eq_int(0, fixture.saved_days(fixture.other_account_room));
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controls != null) controls.close();
            Util.clear_focus_before_detach(window);
            window.destroy(); drain();
            if (fixture != null) fixture.close();
        }
    }

    private void test_context_scope() {
        Fixture? fixture = null;
        ConversationDetails.HistoryLoadPreferences? controls = null;
        try {
            fixture = new Fixture();
            var context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            controls.custom_period.state = true;
            context.conversation = fixture.other_account_room;
            fail_if(controls.custom_period.enabled || controls.days.enabled || controls.load_now.enabled,
                "reused dialog context must invalidate all original controls synchronously");
            context.conversation = fixture.room;
            controls.days.value = 99;
            controls.load_now.clicked();
            fail_if_not_eq_int(30, fixture.saved_days(fixture.room));
            fail_if_not_eq_int(0, fixture.saved_days(fixture.other_account_room));
            controls.close();
            context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            int original_id = fixture.room.id;
            fixture.room.id = fixture.sibling_room.id;
            controls.days.value = 120;
            controls.load_now.clicked();
            fail_if(controls.load_now.enabled, "same object with changed durable identity must be disabled");
            fixture.room.id = original_id;
            fail_if_not_eq_int(30, fixture.saved_days(fixture.room));
            fail_if_not_eq_int(0, fixture.saved_days(fixture.sibling_room));
            controls.close();
            context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            fixture.db.conversation.delete().with(fixture.db.conversation.id, "=", fixture.room.id).perform();
            controls.load_now.clicked();
            fail_if(controls.load_now.enabled, "backend rejection of a deleted row must close the save path");
            fail_if_not_eq_str(_("This group is no longer available for this account."), controls.load_now.description);
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (controls != null) controls.close(); if (fixture != null) fixture.close(); }
    }

    private void test_lifetime() {
        Fixture? fixture = null;
        ConversationDetails.HistoryLoadPreferences? controls = null;
        var window = new Adw.Window();
        Adw.Dialog? dialog = new Adw.Dialog();
        try {
            fixture = new Fixture();
            var context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            controls.custom_period.state = true;
            var rows = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
            controls.append_to(rows);
            var settings_box = new Box(Orientation.VERTICAL, 12) {
                margin_start = 12, margin_end = 12, margin_top = 18, margin_bottom = 40
            };
            foreach (var group in Util.rows_to_preference_groups_with_sections(rows, _("Settings"))) {
                settings_box.append(group);
            }
            // Match the real conversation-details template: its fixed target
            // size and scrolling settings page are part of the dialog layout.
            // A lone SpinRow directly in AdwDialog is not that production path.
            var clamp = new Adw.Clamp() { child = settings_box };
            var scroller = new ScrolledWindow() { vexpand = true, child = clamp };
            var toolbar = new Adw.ToolbarView() { content = scroller };
            toolbar.add_top_bar(new Adw.HeaderBar());
            dialog.content_width = 600;
            dialog.content_height = 600;
            dialog.follows_content_size = false;
            dialog.child = toolbar;
            controls.attach_to_dialog(dialog);
            window.set_default_size(460, 640);
            window.present(); dialog.present(window); drain();
            var native_days = find_spin(settings_box);
            fail_if(native_days == null, "the real settings factory must provide the retained editor");
            if (native_days == null) return;
            native_days.grab_focus();
            ((Editable) native_days).text = "145";
            var retained_days = controls.days;
            var retained_button = controls.load_now;
            WeakRef weak_controls = WeakRef(controls);
            // closed is the production completion signal, preceding teardown.
            dialog.closed();
            fail_if(native_days.sensitive, "closed dialog must disable the native editor");
            retained_days.value = 200;
            retained_button.clicked();
            fail_if_not_eq_int(30, fixture.saved_days(fixture.room), "focus flush and retained controls cannot save after close");
            controls = null;
            dialog.child = null;
            dialog.force_close();
            iterate_for(250);
            dialog.dispose();
            dialog = null;
            drain();
            fail_if(weak_controls.get() != null, "retained models must not keep their controller alive");
            Adw.SpinRow? detached = (Adw.SpinRow) Util.row_to_preference_row(retained_days);
            WeakRef weak_native = WeakRef(detached);
            detached = null;
            drain();
            retained_days.commit();
            retained_days.enabled = true;
            fail_if(weak_native.get() != null, "weak commit/enabled callbacks must not retain removed native rows");
            context.conversation = fixture.other_account_room;
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controls != null) controls.close();
            if (dialog != null) dialog.dispose();
            Util.clear_focus_before_detach(window); window.destroy(); drain();
            if (fixture != null) fixture.close();
        }
    }

    private void test_sections() {
        var rows = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
        rows.append(new ViewModel.PreferencesRow.Text() { title = "Legacy before", text = "property before" });
        rows.append(new ViewModel.PreferencesRow.Section() { title = "History <section>" });
        rows.append(new ViewModel.PreferencesRow.Text() { title = "Legacy after", text = "property after" });
        var groups = Util.rows_to_preference_groups_with_sections(rows, _("Settings"));
        fail_if_not_eq_int(2, groups.size, "only an explicit Section may split settings");
        fail_if_not_eq_str(_("Settings"), groups[0].title);
        // AdwPreferencesGroup's getter returns the rendered GtkLabel text,
        // while its title setter passes markup to a use-markup label.
        fail_if_not_eq_str("History <section>", groups[1].title);
        var heading = find_label(groups[1], "History <section>");
        fail_if(heading == null, "the heading must visibly preserve literal angle brackets");
        if (heading != null) {
            fail_if_not(heading.use_markup);
            fail_if_not_eq_str("History &lt;section&gt;", heading.label,
                "literal heading must be escaped for the native markup label");
            fail_if_not_eq_str("History <section>", heading.get_text(),
                "entities must not appear in the rendered title");
        }
        var before = find_action_row(groups[0], "Legacy before");
        var after = find_action_row(groups[1], "Legacy after");
        fail_if(before == null || after == null, "legacy plugin Text rows must remain native property rows");
        if (before != null) fail_if_not_eq_str("property before", before.subtitle);
        if (after != null) fail_if_not_eq_str("property after", after.subtitle);
        fail_if(find_action_row(groups[0], "Legacy after") != null || find_action_row(groups[1], "Legacy before") != null);
    }

    private void test_rebuild() {
        Fixture? fixture = null;
        ConversationDetails.HistoryLoadPreferences? controls = null;
        var window = new Adw.Window();
        try {
            fixture = new Fixture();
            var context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            controls.custom_period.state = true;
            var rows = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
            controls.append_to(rows);
            var box = new Box(Orientation.VERTICAL, 12);
            foreach (var group in Util.rows_to_preference_groups_with_sections(rows, _("Settings"))) box.append(group);
            window.content = box; window.set_default_size(460, 440); window.present(); drain();
            var native_days = find_spin(box);
            fail_if(native_days == null);
            if (native_days == null) return;
            native_days.grab_focus();
            ((Editable) native_days).text = "144";
            rows.append(new ViewModel.PreferencesRow.Text() { title = "Late plugin", text = "Property" });
            Util.commit_preference_rows(rows);
            Widget? child = box.get_first_child();
            while (child != null) {
                Util.clear_focus_before_detach(child);
                box.remove(child); child = box.get_first_child();
            }
            fail_if(window.get_focus() != null, "rebuild must clear focus before detaching an active GtkText delegate");
            foreach (var group in Util.rows_to_preference_groups_with_sections(rows, _("Settings"))) box.append(group);
            drain();
            fail_if_not_eq_int(144, fixture.saved_days(fixture.room));
            var replacement = find_spin(box);
            fail_if(replacement == null);
            if (replacement != null) fail_if_not_eq_int(144, (int) replacement.value);
            fail_if(find_action_row(box, "Late plugin") == null);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controls != null) controls.close();
            Util.clear_focus_before_detach(window); window.destroy(); drain();
            if (fixture != null) fixture.close();
        }
    }

    private void test_layout() {
        Fixture? fixture = null;
        ConversationDetails.HistoryLoadPreferences? controls = null;
        var window = new Adw.Window() { title = "DinoX isolated MUC history preferences fixture" };
        try {
            fixture = new Fixture();
            var context = new Context(fixture.room);
            controls = preferences(context, fixture.manager);
            var rows = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
            rows.append(new ViewModel.PreferencesRow.Toggle() { title = _("Show status messages"), state = false });
            controls.append_to(rows);
            var box = new Box(Orientation.VERTICAL, 18) {
                margin_start = 12, margin_end = 12, margin_top = 18, margin_bottom = 20
            };
            var groups = Util.rows_to_preference_groups_with_sections(rows, _("Settings"));
            foreach (var group in groups) box.append(group);
            var scroller = new ScrolledWindow() { hscrollbar_policy = PolicyType.NEVER, child = box };
            var toolbar = new Adw.ToolbarView() { content = scroller };
            toolbar.add_top_bar(new Adw.HeaderBar() { title_widget = new Adw.WindowTitle(_("Group Details"), "same@conference.example.test") });
            window.content = toolbar; window.set_default_size(460, 600); window.present();
            iterate_for(80);
            fail_if_not_eq_str(_("Load message history"), groups[1].title);
            var spin = find_spin(box);
            var button = find_button(box, _("Load now"));
            fail_if(spin == null || button == null);
            if (spin == null || button == null) return;
            fail_if(spin.sensitive, "Auto shows custom days disabled");
            fail_if_not_eq_str(_("Days to load"), spin.title);
            fail_if_not(button.grab_focus(), "native load action must be keyboard focusable");
            controls.custom_period.state = true;
            fail_if_not(spin.sensitive);
            fail_if_not(spin.grab_focus(), "native numeric edit must be keyboard focusable");
            foreach (var group in groups) {
                int minimum, natural;
                group.measure(Orientation.HORIZONTAL, -1, out minimum, out natural, null, null);
                fail_if(minimum > 436, "wrapped translated controls must fit a 460px window");
            }
            string? locale = Environment.get_variable("LANGUAGE");
            if (Environment.get_variable("DINOX_UI_TEST_LOCALE_DIR") != null && locale != null && locale.has_prefix("de")) {
                fail_if_not_eq_str("Nachrichtenverlauf nachladen", groups[1].title);
                fail_if_not_eq_str("Zeitraum in Tagen", spin.title);
                fail_if_not_eq_str("Jetzt nachladen", button.label);
            }
            // Run this one test under an isolated Xvfb, then capture its window
            // using xdotool/ImageMagick under the same DISPLAY. Never desktop.
            if (Environment.get_variable("DINOX_MUC_HISTORY_SCREENSHOT_HOLD") == "1") {
                GLib.Test.message("Screenshot fixture ready: DinoX isolated MUC history preferences fixture (460px)");
                iterate_for(15000);
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (controls != null) controls.close();
            Util.clear_focus_before_detach(window); window.destroy(); drain();
            if (fixture != null) fixture.close();
        }
    }

    private static Label? find_label(Widget parent, string text) {
        var label = parent as Label;
        if (label != null && label.get_text() == text) return label;
        Widget? child = parent.get_first_child();
        while (child != null) {
            var result = find_label(child, text); if (result != null) return result;
            child = child.get_next_sibling();
        }
        return null;
    }

    private static Adw.SpinRow? find_spin(Widget parent) {
        if (parent is Adw.SpinRow) return (Adw.SpinRow) parent;
        Widget? child = parent.get_first_child();
        while (child != null) {
            var row = find_spin(child); if (row != null) return row;
            child = child.get_next_sibling();
        }
        return null;
    }

    private static Button? find_button(Widget parent, string label) {
        var button = parent as Button;
        if (button != null && button.label == label) return button;
        Widget? child = parent.get_first_child();
        while (child != null) {
            var result = find_button(child, label); if (result != null) return result;
            child = child.get_next_sibling();
        }
        return null;
    }

    private static Adw.ActionRow? find_action_row(Widget parent, string title) {
        var row = parent as Adw.ActionRow;
        if (row != null && row.title == title) return row;
        Widget? child = parent.get_first_child();
        while (child != null) {
            var result = find_action_row(child, title); if (result != null) return result;
            child = child.get_next_sibling();
        }
        return null;
    }

    private static void drain() { iterate_for(30); }
    private static void iterate_for(uint milliseconds) {
        var context = MainContext.default();
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < deadline) {
            while (context.pending()) context.iteration(false);
            Thread.usleep(1000);
        }
        while (context.pending()) context.iteration(false);
    }
}

}
