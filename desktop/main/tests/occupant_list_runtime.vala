using Dino.Entities;
using Dino.Security;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

// Exercise the real cache-only member list with local protocol modules. The
// stream has no sockets and records every attempted write for the privacy gate.
class OccupantListRuntimeTest : Gee.TestCase {
    private const string KEY = "isolated member list runtime test";

    public OccupantListRuntimeTest() {
        base("OccupantListRuntime");
        add_test("first_presence_recovers_automatic_empty_fallback", test_empty_surface);
        add_test("last_leave_then_rejoin_recovers_without_reopening", test_last_leave);
        add_test("suspended_updates_keep_account_room_and_hat_scope", test_suspend_scope);
        add_test("hat_filter_follows_updates_and_preserves_value_copies", test_hat_filter);
        add_test("affiliation_and_role_changes_regroup_live_rows", test_affiliation_role);
        add_test("large_fallback_materializes_every_member_without_network", test_large_fallback);
        add_test("cleanup_disconnects_observers_and_releases_list", test_cleanup);
        add_test("new_popup_context_keeps_account_scope_and_releases_old_list", test_view_rebind);
        add_test("long_member_action_header_keeps_popover_width_bounded", test_menu_width);
        add_test("avatar_context_closes_when_host_window_unmaps", test_avatar_host_unmap);
        add_test("avatar_context_closes_when_message_anchor_unmaps", test_avatar_anchor_unmap);
        add_test("closed_avatar_context_releases_before_other_account_reopens", test_avatar_reopen);
        add_test("unicode_search_matches_canonical_names_and_full_casefold", test_unicode_search);
    }

    private class TestApplication : Dino.Ui.Application {
        public TestApplication(Database db, StreamInteractor interactor,
                FileEncryption encryption) {
            Object(application_id: "im.dinox.occupant-list-runtime-test",
                flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            db_key = KEY;
            file_encryption = encryption;
            settings = new Dino.Entities.Settings.from_db(db);
            stream_interactor = interactor;
        }
    }

    public class LocalStream : XmppStream {
        public int writes = 0;
        public LocalStream() throws Error { base(new Jid("example.test")); }
        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }
        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_SUPPORTED("This local fixture has no network");
        }
        public override async void write_async(StanzaNode node,
                int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError { writes++; }
    }

    public class Fixture : Object {
        public string path;
        public Database db;
        public StreamInteractor interactor;
        public Account first;
        public Account second;
        public Conversation room;
        public Conversation second_room;
        public LocalStream first_stream;
        public LocalStream second_stream;
        public Gtk.Window window = new Gtk.Window();
        public OccupantMenu.List? list;
        private TestApplication app;
        private GLib.Application? previous_app;
        private Gee.ArrayList<XmppStreamModule> attached = new Gee.ArrayList<XmppStreamModule>();
        private bool closed = false;

        public Fixture() throws Error {
            path = DirUtils.make_tmp("dinox-occupant-list-XXXXXX");
            db = new Database(Path.build_filename(path, "core.db"), KEY);
            interactor = new StreamInteractor.for_tests(db);
            var encryption = new FileEncryption(KEY);
            previous_app = GLib.Application.get_default();
            app = new TestApplication(db, interactor, encryption);
            GLib.Application.set_default(app);
            MessageProcessor.start(interactor, db);
            MessageStorage.start(interactor, db);
            PresenceManager.start(interactor, db);
            BlockingManager.start(interactor);
            Calls.start(interactor, db);
            ConversationManager.start(interactor, db);
            OccupantIdStore.start(interactor, db);
            MucManager.start(interactor, db);
            AvatarManager.start(interactor, db, encryption);
            RosterManager.start(interactor, db);
            EntityInfo.start(interactor, db);
            ContactModels.start(interactor);
            first = new Account(new Jid("first@example.test"), "unused");
            second = new Account(new Jid("second@example.test"), "unused");
            first.persist(db);
            second.persist(db);
            room = new Conversation(new Jid("same@conference.example.test"), first,
                Conversation.Type.GROUPCHAT) { nickname = "Self" };
            second_room = new Conversation(room.counterpart, second,
                Conversation.Type.GROUPCHAT) { nickname = "Other" };
            room.persist(db);
            second_room.persist(db);
            first_stream = prepare_stream(first);
            second_stream = prepare_stream(second);
            first_stream.get_flag(Xep.Muc.Flag.IDENTITY).set_muc_nick(
                room.counterpart.with_resource("Self"));
            second_stream.get_flag(Xep.Muc.Flag.IDENTITY).set_muc_nick(
                room.counterpart.with_resource("Other"));
            first_stream.get_flag(Xep.Muc.Flag.IDENTITY).set_muc_nick(
                new Jid("sibling@conference.example.test/Self"));
            window.set_default_size(360, 450);
            list = new OccupantMenu.List(interactor, room);
            window.set_child((!) list);
            window.present();
            settle(40);
        }

        private LocalStream prepare_stream(Account account) throws Error {
            interactor.module_manager.initialize(account);
            interactor.account_added(account);
            var stream = new LocalStream();
            stream.add_flag(new Bind.Flag() { my_jid = account.full_jid, finished = true });
            attach<Iq.Module>(account, stream, Iq.Module.IDENTITY);
            attach<MessageModule>(account, stream, MessageModule.IDENTITY);
            attach<Presence.Module>(account, stream, Presence.Module.IDENTITY);
            attach<Xep.ServiceDiscovery.Module>(account, stream, Xep.ServiceDiscovery.Module.IDENTITY);
            attach<Xep.Muc.Module>(account, stream, Xep.Muc.Module.IDENTITY);
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            return stream;
        }

        private void attach<T>(Account account, LocalStream stream,
                SimpleModuleIdentity identity) throws Error {
            T? value = interactor.module_manager.get_module<T>(account, identity);
            if (value == null) throw new IOError.FAILED("Missing fixture module " + identity.id);
            var module = (XmppStreamModule) ((!) value);
            stream.add_module(module);
            module.attach(stream);
            attached.add(module);
        }

        public void presence(string nick, bool available = true,
                string affiliation = "member", string role = "participant",
                string? hat = null, LocalStream? source = null,
                Jid? target_room = null) throws Error {
            LocalStream stream = source ?? first_stream;
            var node = new StanzaNode.build("presence", "jabber:client")
                .put_attribute("from", (target_room ?? room.counterpart).with_resource(nick).to_string())
                .put_attribute("to", stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string())
                .put_node(new StanzaNode.build("x", "http://jabber.org/protocol/muc#user")
                    .put_node(new StanzaNode.build("item", "http://jabber.org/protocol/muc#user")
                        .put_attribute("affiliation", affiliation)
                        .put_attribute("role", role)));
            if (!available) node.put_attribute("type", "unavailable");
            if (hat != null) {
                node.put_node(new StanzaNode.build("hats", "urn:xmpp:hats:0")
                    .put_node(new StanzaNode.build("hat", "urn:xmpp:hats:0")
                        .put_attribute("uri", "urn:example:hat:" + (!) hat)
                        .put_attribute("title", (!) hat)
                        .put_attribute("hue", "220")));
            }
            stream.received_presence_stanza(stream, node);
        }

        public ListView view() {
            return (ListView) find_widget((!) list, typeof(ListView));
        }
        public SearchEntry search() {
            return (SearchEntry) find_widget((!) list, typeof(SearchEntry));
        }
        public Gee.ArrayList<OccupantMenu.OccupantListItem> items() {
            var result = new Gee.ArrayList<OccupantMenu.OccupantListItem>();
            SelectionModel? model = view().model;
            if (model == null) return result;
            for (uint index = 0; index < ((!) model).get_n_items(); index++) {
                var item = ((!) model).get_item(index) as OccupantMenu.OccupantListItem;
                if (item != null && !((!) item).is_header) result.add((!) item);
            }
            return result;
        }
        public OccupantMenu.OccupantListItem? item(string nick) {
            foreach (var value in items()) {
                if (value.jid != null && ((!) value.jid).resourcepart == nick) return value;
            }
            return null;
        }
        public string first_header() {
            SelectionModel? model = view().model;
            if (model == null || ((!) model).get_n_items() == 0) return "";
            var item = ((!) model).get_item(0) as OccupantMenu.OccupantListItem;
            return item != null && ((!) item).is_header ? ((!) item).header_title : "";
        }
        public void close() {
            if (closed) return;
            closed = true;
            if (list != null) ((!) list).cleanup();
            Util.clear_focus_before_detach(window);
            window.set_child(null);
            window.destroy();
            list = null;
            interactor.get_module<MucManager>(MucManager.IDENTITY).shutdown();
            foreach (XmppStreamModule module in attached) {
                if (first_stream.modules.contains(module)) module.detach(first_stream);
                if (second_stream.modules.contains(module)) module.detach(second_stream);
            }
            settle(20);
            GLib.Application.set_default(previous_app);
            db.close();
            foreach (string name in new string[] { "core.db", "core.db-wal", "core.db-shm" }) {
                FileUtils.unlink(Path.build_filename(path, name));
            }
            DirUtils.remove(path);
        }
    }

    private static Widget? find_widget(Widget root, Type type) {
        if (root.get_type().is_a(type)) return root;
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
            Widget? match = find_widget(child, type);
            if (match != null) return match;
        }
        return null;
    }
    private static void settle(uint ms = 350) {
        var loop = new MainLoop();
        Timeout.add(ms, () => { loop.quit(); return Source.REMOVE; });
        loop.run();
        while (MainContext.default().pending()) MainContext.default().iteration(false);
    }

    private void test_empty_surface() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fail_if_not_eq_int(0, fixture.items().size);
            fixture.presence("First");
            settle();
            fail_if_not_eq_int(1, fixture.items().size,
                "first fallback presence must fill the empty automatic list without reopening");
            fail_if_not(fixture.item("First") != null);
            fail_if_not_eq_int(0, fixture.first_stream.writes,
                "opening and materializing member rows must never send avatar or affiliation IQs");
        } catch (Error error) { fail_if_reached(error.message); }
        if (fixture != null) fixture.close();
    }
    private void test_last_leave() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.presence("First"); settle();
            fixture.presence("First", false); settle();
            fail_if_not_eq_int(0, fixture.items().size);
            fixture.presence("Next"); settle();
            fail_if_not_eq_int(1, fixture.items().size);
            fail_if(fixture.item("First") != null);
            fail_if(fixture.item("Next") == null);
        } catch (Error error) { fail_if_reached(error.message); }
        if (fixture != null) fixture.close();
    }
    private void test_suspend_scope() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.presence("First", true, "member", "participant", "Support"); settle();
            fixture.list.suspend_for_popover_close();
            fixture.presence("First", false);
            fixture.presence("Next", true, "member", "participant", "Maintainer");
            fixture.presence("OtherAccount", true, "owner", "moderator", "Wrong", fixture.second_stream);
            fixture.presence("Sibling", true, "owner", "moderator", "Wrong", null,
                new Jid("sibling@conference.example.test"));
            settle();
            fixture.list.resume_auto_loading_if_needed(); settle();
            fail_if_not_eq_int(1, fixture.items().size);
            var next = fixture.item("Next");
            fail_if(next == null);
            if (next != null) {
                fail_if_not_eq_str("Maintainer", next.hats_text);
                fail_if_not_eq_int(1, next.hats.size);
            }
            fail_if_not_eq_int(0, fixture.first_stream.writes);
            fail_if_not_eq_int(0, fixture.second_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        if (fixture != null) fixture.close();
    }
    private void test_hat_filter() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.presence("First", true, "member", "participant", "Support");
            fixture.presence("Second", true, "member", "participant", "Maintainer"); settle();
            fixture.search().text = "Support"; settle(600);
            fail_if_not_eq_int(1, fixture.items().size);
            var first = fixture.item("First");
            fail_if(first == null);
            if (first != null) {
                var protocol_hats = fixture.first_stream.get_flag(Xep.Muc.Flag.IDENTITY)
                    .get_occupant_hats(fixture.room.counterpart.with_resource("First"));
                protocol_hats[0].title = "ProtocolMutation";
                fail_if_not_eq_str("Support", first.hats[0].title,
                    "row Hat metadata must not alias mutable protocol projections");
            }
            fixture.presence("First", true, "member", "participant", "Maintainer"); settle();
            fail_if_not_eq_int(0, fixture.items().size,
                "removing a matching Hat must remove its row from active search results");
            fixture.presence("Second", true, "member", "participant", "Support"); settle();
            fail_if_not_eq_int(1, fixture.items().size);
            fail_if(fixture.item("Second") == null);
            fixture.search().text = ""; settle(600);
            fail_if_not_eq_int(2, fixture.items().size);
        } catch (Error error) { fail_if_reached(error.message); }
        if (fixture != null) fixture.close();
    }
    private void test_affiliation_role() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.presence("First", true, "member", "participant"); settle();
            string member_header = fixture.first_header();
            fail_if(member_header == "");
            fixture.presence("First", true, "none", "moderator"); settle();
            fail_if(fixture.first_header() == member_header,
                "an unaffiliated moderator must move to the moderator section");
            var first = fixture.item("First");
            fail_if(first == null);
            if (first != null) {
                fail_if_not(first.affiliation_known);
                fail_if_not(first.role_known);
                fail_if_not(first.role == Xep.Muc.Role.MODERATOR);
            }
            fixture.presence("First", true, "member", "visitor"); settle();
            fail_if(fixture.first_header() == member_header,
                "a muted member must appear as visitor while retaining affiliation");
            fail_if_not_eq_int(1, fixture.items().size);
        } catch (Error error) { fail_if_reached(error.message); }
        if (fixture != null) fixture.close();
    }
    private void test_large_fallback() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            for (int index = 0; index < 120; index++) {
                fixture.presence("Member%03d".printf(index));
            }
            settle(800);
            fail_if_not_eq_int(120, fixture.items().size,
                "large fallback must not truncate member materialization at the lightweight threshold");
            fixture.list.suspend_for_popover_close();
            fixture.presence("Member119", false);
            fixture.presence("Member120");
            int64 reopen_started = get_monotonic_time();
            fixture.list.resume_auto_loading_if_needed();
            GLib.Test.message("120-member cached list reopen dispatch: %.3f ms",
                (get_monotonic_time() - reopen_started) / 1000.0);
            settle(600);
            fail_if_not_eq_int(120, fixture.items().size);
            fail_if(fixture.item("Member119") != null);
            fail_if(fixture.item("Member120") == null);
            fail_if_not_eq_int(0, fixture.first_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        if (fixture != null) fixture.close();
    }
    private void test_cleanup() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.presence("First"); settle();
            WeakRef list_ref = WeakRef(fixture.list);
            fixture.list.cleanup();
            fixture.window.set_child(null);
            fixture.list = null;
            settle();
            fail_if(list_ref.get() != null, "cleaned member list must release its handlers and sources");
            fixture.presence("AfterCleanup"); settle();
            fail_if(list_ref.get() != null);
            fail_if_not_eq_int(0, fixture.first_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        if (fixture != null) fixture.close();
    }
    private void test_view_rebind() {
        Fixture? fixture = null;
        OccupantMenu.View? popover = null;
        try {
            fixture = new Fixture();
            fixture.list.cleanup();
            fixture.window.set_child(null);
            fixture.list = null;
            var button = new MenuButton() { icon_name = "system-users-symbolic" };
            popover = new OccupantMenu.View(fixture.interactor, fixture.room);
            Util.set_menu_button_popover(button, popover);
            // Match the titlebar's small top anchor; a button filling the whole
            // window leaves no space for a native popover above or below it.
            var anchor_box = new Box(Orientation.VERTICAL, 0);
            button.halign = Align.END;
            anchor_box.append(button);
            fixture.window.set_child(anchor_box);
            button.popup(); settle(80);
            var old_list = (OccupantMenu.List) find_widget(popover, typeof(OccupantMenu.List));
            WeakRef old_list_ref = WeakRef(old_list);
            fixture.presence("FirstAccount"); settle();
            old_list = null;
            // Mirror OccupantsEntry's Windows-safe one-View-per-context
            // lifecycle instead of reopening an old native popup surface.
            popover.deactivate_for_deferred_cleanup();
            button.popdown();
            settle(650);
            popover.cleanup();
            Util.set_menu_button_popover(button, null);
            popover = new OccupantMenu.View(fixture.interactor, fixture.second_room);
            Util.set_menu_button_popover(button, popover);
            button.popup(); settle(80);
            fixture.presence("WrongAccount");
            fixture.presence("SecondAccount", true, "member", "participant", "Team", fixture.second_stream);
            settle();
            var current_view = (ListView) find_widget(popover, typeof(ListView));
            SelectionModel? model = current_view.model;
            int members = 0;
            if (model != null) {
                for (uint index = 0; index < ((!) model).get_n_items(); index++) {
                    var item = ((!) model).get_item(index) as OccupantMenu.OccupantListItem;
                    if (item == null || item.is_header) continue;
                    members++;
                    fail_if_not_eq_str("SecondAccount", item.display_name,
                        "the new popup must reject the previous account's later presence");
                    fail_if_not_eq_str("Team", item.hats_text);
                }
            }
            fail_if_not_eq_int(1, members);
            settle(1700);
            fail_if(old_list_ref.get() != null,
                "rebind must drain and release the former account's hidden list");
            popover.popdown_for_lifecycle(); settle(40);
            popover.cleanup();
            Util.set_menu_button_popover(button, null);
            fail_if_not_eq_int(0, fixture.first_stream.writes);
            fail_if_not_eq_int(0, fixture.second_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        if (popover != null) popover.cleanup();
        if (fixture != null) fixture.close();
    }
    private static Button prepare_avatar_anchor(Fixture fixture) {
        fixture.list.cleanup();
        Util.clear_focus_before_detach(fixture.window);
        fixture.window.set_child(null);
        fixture.list = null;
        var anchor = new Button() { label = "Avatar", halign = Align.START };
        var box = new Box(Orientation.VERTICAL, 0) { margin_top = 30 };
        box.append(anchor);
        fixture.window.set_child(box);
        settle(80);
        return anchor;
    }

    private static OccupantMenu.View open_avatar_context(Fixture fixture,
            Widget anchor, Conversation conversation, string nick = "Peer") throws Error {
        var popover = new OccupantMenu.View.for_avatar(fixture.interactor,
            conversation, anchor);
        // Match the message caller: the native is parented to the stable
        // window, while the visible message avatar owns its lifecycle.
        popover.set_parent(fixture.window);
        Graphene.Rect bounds;
        if (!anchor.compute_bounds(fixture.window, out bounds)) {
            throw new IOError.FAILED("Mapped avatar must have window-relative bounds");
        }
        popover.set_pointing_to({ (int) bounds.origin.x, (int) bounds.origin.y,
            (int) bounds.size.width, (int) bounds.size.height });
        popover.show_menu(conversation.counterpart.with_resource(nick), nick);
        WeakRef menu_weak = WeakRef(popover);
        // Install the close binding before popup, as the real caller does.
        popover.closed.connect(() => {
            var menu = menu_weak.get() as OccupantMenu.View;
            if (menu != null) menu.detach_safely_after_close();
        });
        popover.popup();
        settle(80);
        return popover;
    }

    private static void dispose_avatar_context(OccupantMenu.View? popover) {
        if (popover == null) return;
        popover.popdown_for_lifecycle();
        popover.cleanup();
        // Older GTK versions retain a hidden surface through the tooltip
        // grace period. Never unparent it early during test teardown either.
        settle(650);
        if (popover.get_parent() != null) popover.unparent();
    }

    private void test_avatar_host_unmap() {
        Fixture? fixture = null;
        OccupantMenu.View? popover = null;
        try {
            fixture = new Fixture();
            var anchor = prepare_avatar_anchor(fixture);
            popover = open_avatar_context(fixture, anchor, fixture.room);
            fail_if_not(popover.get_mapped(), "avatar context must map a native popup before hiding its host");
            fixture.window.visible = false;
            settle(80);
            fail_if(popover.visible || popover.get_mapped(),
                "hiding the chat window must close its avatar context instead of leaving a desktop popup");
            settle(650);
            fail_if(popover.get_parent() != null,
                "closed avatar context must detach after the native tooltip grace period");
            fail_if_not_eq_int(0, fixture.first_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        dispose_avatar_context(popover);
        if (fixture != null) fixture.close();
    }

    private void test_avatar_anchor_unmap() {
        Fixture? fixture = null;
        OccupantMenu.View? popover = null;
        try {
            fixture = new Fixture();
            var anchor = prepare_avatar_anchor(fixture);
            popover = open_avatar_context(fixture, anchor, fixture.room);
            fail_if_not(popover.get_mapped(), "avatar context must be mapped before its message disappears");
            anchor.visible = false;
            settle(80);
            fail_if_not(fixture.window.get_mapped(), "only the message anchor should unmap in this probe");
            fail_if(popover.visible || popover.get_mapped(),
                "an avatar context must close when its message is hidden even if the stable window stays mapped");
            settle(650);
            fail_if(popover.get_parent() != null);
            fail_if_not_eq_int(0, fixture.first_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        dispose_avatar_context(popover);
        if (fixture != null) fixture.close();
    }

    private void test_avatar_reopen() {
        Fixture? fixture = null;
        OccupantMenu.View? popover = null;
        try {
            fixture = new Fixture();
            var anchor = prepare_avatar_anchor(fixture);
            fixture.presence("FirstAccount");
            popover = open_avatar_context(fixture, anchor, fixture.room, "FirstAccount");
            fail_if_not(popover.get_mapped());
            WeakRef old_menu = WeakRef(popover);
            WeakRef old_list = WeakRef(find_widget(popover, typeof(OccupantMenu.List)));
            anchor.visible = false;
            // Normal avatar closure must retire the native and its context
            // without an explicit cleanup call from the message row.
            settle(650);
            fail_if(popover.visible || popover.get_mapped());
            fail_if(popover.get_parent() != null);
            popover = null;
            settle(80);
            fail_if(old_menu.get() != null,
                "closing an avatar context must release its anchor and root observer bindings");
            fail_if(old_list.get() != null,
                "a closed avatar context must release its former account's cached member list");

            anchor.visible = true;
            settle(80);
            fixture.presence("SecondAccount", true, "member", "participant", "Team", fixture.second_stream);
            popover = open_avatar_context(fixture, anchor, fixture.second_room, "SecondAccount");
            fail_if_not(popover.get_mapped(), "the same message anchor must support a fresh popup after closure");
            fixture.presence("LaterWrongAccount");
            settle();
            // A standalone avatar context exposes its action page, not the
            // titlebar's member list. Exercise that real surface; the normal
            // View rebind test above covers account-scoped member/Hat models.
            var stack = (Stack) popover.child;
            fail_if_not_eq_str("menu", stack.visible_child_name);
            var header = (Label) find_widget(stack.visible_child, typeof(Label));
            fail_if_not(popover.get_mapped() && header.get_mapped(),
                "the reopened avatar action page must remain mapped while unrelated account presence arrives");
            fail_if_not_eq_str("SecondAccount", header.get_text(),
                "the reopened action header must identify the selected current-account occupant");
            fail_if_not_eq_int(0, fixture.first_stream.writes);
            fail_if_not_eq_int(0, fixture.second_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        dispose_avatar_context(popover);
        if (fixture != null) fixture.close();
    }

    private void test_unicode_search() {
        try {
            var item = new OccupantMenu.OccupantListItem.occupant(
                new Jid("room@conference.example.test/Straße")) {
                display_name = "Straße José", hats_text = "Équipe"
            };
            fail_if_not(item.matches_filter(new string[] { "STRASSE" }),
                "full Unicode casefold must match sharp-s with SS");
            fail_if_not(item.matches_filter(new string[] { "Jose\u0301", "E\u0301QUIPE" }),
                "canonically equivalent composed and decomposed names must match");
            fail_if(item.matches_filter(new string[] { "Other" }));
        } catch (Error error) { fail_if_reached(error.message); }
    }
    private void test_menu_width() {
        Fixture? fixture = null;
        OccupantMenu.View? popover = null;
        try {
            fixture = new Fixture();
            string name = string.nfill(200, 'N');
            popover = new OccupantMenu.View(fixture.interactor, fixture.room);
            popover.show_menu(fixture.room.counterpart.with_resource(name), name);
            int minimum, natural;
            popover.child.measure(Orientation.HORIZONTAL, -1, out minimum,
                out natural, null, null);
            fail_if(minimum > 360,
                "valid long nicknames must not make the member action popover wider than a narrow chat");
            fail_if(natural > 360,
                "the bounded member header must not request a full untruncated nickname width");
            fail_if_not_eq_int(0, fixture.first_stream.writes);
        } catch (Error error) { fail_if_reached(error.message); }
        if (popover != null) popover.cleanup();
        if (fixture != null) fixture.close();
    }
}

}
