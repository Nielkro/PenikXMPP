using Dino.Entities;
using Dino.Security;
using Gee;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

[CCode (cname = "gtk_test_accessible_check_property", cheader_filename = "gtk/gtk.h")]
private static extern string? check_conversation_row_accessible_property(Accessible accessible,
    AccessibleProperty property, ...);

// Exercise the production selector, row template and avatar model. The only
// isolation is an application profile/database without an XMPP connection.
class ConversationSelectorRowRuntimeTest : Gee.TestCase {
    private delegate bool Ready();

    public ConversationSelectorRowRuntimeTest() {
        base("ConversationSelectorRowRuntime");
        add_test("compact_preserves_rows_selection_scroll_and_new_row_inheritance", test_selector);
        add_test("unread_badges_use_real_account_scoped_counts_and_read_updates", test_unread);
        add_test("muted_mentions_and_live_display_names_remain_visible", test_mentions_and_names);
        add_test("earlier_unread_mentions_follow_corrections_and_room_nick_changes", test_mention_updates);
        add_test("room_markers_follow_account_scoped_privacy_without_contact_presence", test_room_markers);
        add_test("remapping_preserves_compact_tooltip_and_accessible_name", test_remap);
        add_test("long_names_fit_the_rail_in_each_theme_and_direction", test_bounds);
        add_test("cleanup_releases_row_and_disconnects_display_name_binding", test_cleanup);
        add_test("trust_visibility_refreshes_real_preview_without_unread_side_effects", test_trust_visibility);
        add_test("local_decryption_diagnostic_is_localized_without_changing_user_text", test_diagnostic_preview);
        add_test("encryption_context_entry_uses_local_trust_and_account_scoped_room_visibility", test_encryption_menu_state_and_scope);
        add_test("encryption_context_activation_keeps_target_and_releases_custom_button", test_encryption_menu_target_and_cleanup);
        add_test("header_menus_reuse_widgets_and_keep_current_account_actions", test_header_menu_reuse);
        add_test("call_control_clears_stale_visibility_before_next_main_loop", test_call_control_selection);
    }

    private class TestEncryptionEntry : Object, Plugins.EncryptionListEntry {
        public Encryption encryption { get { return Encryption.OMEMO; } }
        public string name { get { return "OMEMO"; } }
        public Plugins.ConversationEncryptionTrust trust = Plugins.ConversationEncryptionTrust.UNKNOWN;
        public int activation_calls = 0;
        public int trust_queries = 0;

        public Plugins.ConversationEncryptionTrust get_conversation_trust(Conversation conversation) {
            trust_queries++;
            return trust;
        }
        public void encryption_activated(Conversation conversation, owned Plugins.SetInputFieldStatus callback) {
            activation_calls++;
        }
        public Object? get_encryption_icon(Conversation conversation, ContentItem item) { return null; }
        public string? get_encryption_icon_name(Conversation conversation, ContentItem item) { return null; }
    }

    private class TestEncryptionDetails : Object, Plugins.ContactDetailsProvider {
        public string id { get { return "omemo_info"; } }
        public string tab { get { return "encryption"; } }
        public int widget_requests = 0;
        public void populate(Conversation conversation, Plugins.ContactDetails details, Plugins.WidgetType type) { }
        public Object? get_widget(Conversation conversation) {
            widget_requests++;
            return new Adw.PreferencesGroup() { title = "OMEMO" };
        }
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }
        public Variant? details_target = null;
        public int details_requests = 0;

        public TestApplication(Database db, StreamInteractor interactor, FileEncryption encryption) {
            // NON_UNIQUE still exports one object path per ID on the shared
            // D-Bus connection. Independent fixtures need distinct paths.
            Object(application_id: "im.dinox.conversation-row-runtime-test.fixture" +
                Uuid.string_random().replace("-", ""), flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "isolated conversation row runtime test";
            this.file_encryption = encryption;
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.settings.notifications = true;
            this.stream_interactor = interactor;
        }

        public void capture_details_actions() throws Error {
            register(null);
            var action = new SimpleAction("open-conversation-details", new VariantType("(is)"));
            WeakRef app_weak = WeakRef(this);
            action.activate.connect((parameter) => {
                var app = app_weak.get() as TestApplication;
                if (app == null) return;
                app.details_target = parameter;
                app.details_requests++;
            });
            add_action(action);
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    private class Fixture : Object {
        public string root;
        public Database db;
        public StreamInteractor interactor;
        public Account first;
        public Account second;
        public ConversationSelector selector;
        public ListBox list_box;
        public Adw.Window window = new Adw.Window();
        public ScrolledWindow scroller = new ScrolledWindow() {
            hscrollbar_policy = PolicyType.NEVER, vexpand = true
        };
        public TestApplication app;
        private GLib.Application? previous_app;
        private int serial = 0;

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-conversation-row-XXXXXX");
            db = new Database(Path.build_filename(root, "dino.db"), "isolated conversation row runtime test");
            interactor = new StreamInteractor.for_tests(db);
            var encryption = new FileEncryption("isolated conversation row runtime test");
            previous_app = GLib.Application.get_default();
            app = new TestApplication(db, interactor, encryption);
            GLib.Application.set_default(app);

            // Match the production dependency order, but never add an account
            // to StreamInteractor or negotiate a stream: these are offline rows.
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
            FileManager.start(interactor, db, encryption);
            CallStore.start(interactor, db);
            ContentItemStore.start(interactor, db);
            ChatInteraction.start(interactor);
            MessageCorrection.start(interactor, db);
            MessageDeletion.start(interactor, db);
            FileTransferStorage.start(interactor, db);
            ContactModels.start(interactor);
            EntityInfo.start(interactor, db);

            first = new Account(new Jid("first@example.test"), "fixture") { enabled = true };
            second = new Account(new Jid("second@example.test"), "fixture") { enabled = true };
            first.persist(db);
            second.persist(db);
            interactor.module_manager.initialize(first);
            interactor.module_manager.initialize(second);
            interactor.account_added(first);
            interactor.account_added(second);
            var icon_theme = IconTheme.get_for_display(Gdk.Display.get_default());
            if (!icon_theme.has_icon("dino-bell-large-none-symbolic")) {
                icon_theme.add_resource_path("/im/dinox/dinox/icons");
            }
            fail_if_not(icon_theme.has_icon("dino-bell-large-none-symbolic"),
                "the fixture must use the production mute icon rather than a missing-image placeholder");
            fail_if_not(icon_theme.has_icon("system-users-symbolic") &&
                icon_theme.has_icon("changes-prevent-symbolic"),
                "both compact room markers must resolve to actual theme icons");
            typeof(AvatarPicture).ensure();
            selector = new ConversationSelector().init(interactor);
            list_box = (ListBox) selector.get_first_child();
            scroller.child = selector;
            window.add_css_class("dino-main");
            window.content = scroller;
            window.set_default_size(300, 320);
        }

        public Conversation conversation(Account account, string peer = "peer@example.test",
                Conversation.Type type = Conversation.Type.CHAT) throws Error {
            var conversation = interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .create_conversation(new Jid(peer), account, type);
            interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).start_conversation(conversation);
            return conversation;
        }

        public ConversationSelectorRow row(Conversation conversation) throws Error {
            Widget? child = list_box.get_first_child();
            while (child != null) {
                var row = child as ConversationSelectorRow;
                if (row != null && row.conversation.equals(conversation)) return row;
                child = child.get_next_sibling();
            }
            throw new IOError.FAILED("The real selector must contain the conversation row");
        }

        public void set_room_private(Conversation room, bool is_private) {
            // Populate real account-scoped discovery storage; no UI state is
            // injected. The same room may have different cached information
            // for the other account.
            string hash = "fixture-room-features-%d-%d".printf(room.account.id, ++serial);
            db.entity.upsert()
                .value(db.entity.account_id, room.account.id, true)
                .value(db.entity.jid_id, db.get_jid_id(room.counterpart.bare_jid), true)
                .value(db.entity.resource, "", true)
                .value(db.entity.last_seen, (long) (new DateTime.now_utc()).to_unix())
                .value(db.entity.caps_hash, hash)
                .perform();
            if (is_private) {
                foreach (string feature in new string[] { "muc_membersonly", "muc_nonanonymous" }) {
                    db.entity_feature.insert()
                        .value(db.entity_feature.entity, hash)
                        .value(db.entity_feature.feature, feature)
                        .perform();
                }
            }
            interactor.get_module<MucManager>(MucManager.IDENTITY)
                .room_info_updated(room.account, room.counterpart.bare_jid);
        }

        public MessageItem add_message(Conversation conversation, bool mention = false,
                string body = "Fixture message", Encryption encryption = Encryption.NONE,
                bool decryption_failed = false) throws Error {
            DateTime time = new DateTime.now_utc().add_seconds(++serial);
            var message = new Dino.Entities.Message(body) {
                account = conversation.account,
                counterpart = conversation.type_ == Conversation.Type.GROUPCHAT
                    ? conversation.counterpart.with_resource("sender") : conversation.counterpart,
                ourpart = conversation.account.bare_jid,
                direction = Dino.Entities.Message.DIRECTION_RECEIVED,
                type_ = conversation.type_ == Conversation.Type.GROUPCHAT
                    ? Dino.Entities.Message.Type.GROUPCHAT : Dino.Entities.Message.Type.CHAT,
                time = time, local_time = time, has_mention = mention,
                encryption = encryption, decryption_failed = decryption_failed
            };
            interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).add_message(message, conversation);
            var store = interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            store.insert_message(message, conversation);
            var item = store.get_item_by_foreign(conversation, 1, message.id) as MessageItem;
            if (item == null) throw new IOError.FAILED("The persisted fixture message must have a real content item");
            return item;
        }

        public void present() throws Error {
            window.present();
            wait_for(() => selector.get_mapped(), "the real selector must map");
        }

        public void close() {
            // Finish the production row's initial/read idle before closing DB.
            drain();
            scroller.child = null;
            selector.dispose();
            Widget? child = list_box.get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                list_box.remove(child);
                child = next;
            }
            window.destroy();
            interactor.get_module<MucManager>(MucManager.IDENTITY).shutdown();
            drain();
            GLib.Application.set_default(previous_app);
            db.close();
            FileUtils.remove(Path.build_filename(root, "dino.db"));
            FileUtils.remove(Path.build_filename(root, "dino.db-shm"));
            FileUtils.remove(Path.build_filename(root, "dino.db-wal"));
            DirUtils.remove(root);
        }
    }

    private void test_selector() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var selected = fixture.conversation(fixture.first);
            for (int i = 0; i < 9; i++) fixture.conversation(fixture.first, "contact%d@example.test".printf(i));
            var row = fixture.row(selected);
            var avatar = row_widget(row, "picture") as AvatarPicture;
            var avatar_model = avatar.model;
            fixture.selector.on_conversation_selected(selected);
            fixture.present();
            wait_for(() => fixture.scroller.vadjustment.upper > fixture.scroller.vadjustment.page_size,
                "the real selector must be scrollable");
            fixture.scroller.vadjustment.value = 120;
            double scroll = fixture.scroller.vadjustment.value;
            int selections = 0;
            fixture.selector.conversation_selected.connect(() => selections++);
            for (int i = 0; i < 4; i++) {
                fixture.selector.compact = i % 2 == 0;
                drain();
                fail_if(fixture.row(selected) != row || fixture.list_box.get_selected_row() != row,
                    "manual compaction must preserve the selected row instance");
                fail_if((row_widget(row, "picture") as AvatarPicture) != avatar || avatar.model != avatar_model,
                    "manual compaction must preserve the existing avatar and model");
                fail_if(Math.fabs(fixture.scroller.vadjustment.value - scroll) > 1,
                    "compaction must preserve the vertical scroll position");
            }
            fail_if_not_eq_int(0, selections, "compaction must not select or reload a conversation");
            fixture.selector.compact = true;
            var added = fixture.conversation(fixture.second, "new@example.test");
            var added_row = fixture.row(added);
            fail_if(!added_row.compact || row_widget(added_row, "text_container").visible,
                "a new conversation must inherit compact layout");
            fail_if(fixture.list_box.get_selected_row() != row,
                "adding a compact row must preserve the current selection");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_unread() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.selector.compact = true;
            var first = fixture.conversation(fixture.first);
            var second = fixture.conversation(fixture.second);
            MessageItem? newest = null;
            for (int i = 0; i < 123; i++) newest = fixture.add_message(first);
            var other = fixture.add_message(second);
            var first_row = fixture.row(first);
            var second_row = fixture.row(second);
            first_row.content_item_received(newest);
            second_row.content_item_received(other);
            wait_for(() => row_label(first_row, "compact_unread_count_label").label == "\u206699+\u2069" &&
                row_label(second_row, "compact_unread_count_label").label == "1",
                "compact badges must use the real account-scoped unread counts");
            fail_if_not_eq_str("123", row_label(first_row, "unread_count_label").label,
                "the existing expanded count must remain intact");
            string expected = GLib.dgettext("dino", "Unread messages: %d").printf(123);
            fail_if(first_row.tooltip_text == null || !first_row.tooltip_text.contains(expected) ||
                !first_row.tooltip_text.contains(fixture.first.bare_jid.to_string()) ||
                first_row.tooltip_text.contains(fixture.second.bare_jid.to_string()),
                "the compact tooltip must retain the full count and correct account");
            fail_if(!row_label(first_row, "compact_unread_count_label").has_css_class("unread-count-notify"),
                "normal notification counts must retain their notification style");
            first.read_up_to_item = ((!) newest).id;
            wait_for(() => !row_widget(first_row, "compact_unread_count_label").visible,
                "marking the real last content item read must hide the compact badge");
            fail_if(!row_widget(second_row, "compact_unread_count_label").visible,
                "reading one account must not clear the other account's badge");
            first.pinned = 1;
            wait_for(() => row_widget(first_row, "compact_pinned_image").visible,
                "pinning must immediately update the compact avatar");
            fail_if(row_widget(second_row, "compact_pinned_image").visible,
                "pinning one account must not pin the same peer on another account");
            fail_if(first_row.tooltip_text == null ||
                !first_row.tooltip_text.contains(GLib.dgettext("dino", "Pinned")),
                "the compact summary must describe the current pin state");
            fixture.selector.compact = false;
            fail_if(row_widget(first_row, "compact_pinned_image").visible ||
                !row_widget(first_row, "pinned_image").visible,
                "expanding must preserve the original pin icon and hide its compact copy");
            fixture.selector.compact = true;
            first.pinned = 0;
            wait_for(() => !row_widget(first_row, "compact_pinned_image").visible,
                "unpinning must immediately clear the compact avatar badge");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_mentions_and_names() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.selector.compact = true;
            var room = fixture.conversation(fixture.first, "room@conference.example.test", Conversation.Type.GROUPCHAT);
            var row = fixture.row(room);
            room.notify_setting = Conversation.NotifySetting.OFF;
            row.content_item_received(fixture.add_message(room, true));
            wait_for(() => row_widget(row, "compact_mention_indicator_label").visible,
                "a real unread mention must remain visible in a muted compact room");
            fail_if(!row_widget(row, "compact_muted_image").visible ||
                !row_widget(row, "compact_unread_count_label").visible ||
                !row_widget(row, "compact_unread_count_label").has_css_class("unread-count"),
                "muting must retain the count and use the existing muted notification style");
            var model = fixture.interactor.get_module<ContactModels>(ContactModels.IDENTITY).get_display_name_model(room);
            model.display_name = "Renamed room";
            string expected = "Renamed room\n" + fixture.first.bare_jid.to_string() + "\n" +
                GLib.dgettext("dino", "Group chat") + "\n" +
                GLib.dgettext("dino", "Unread messages: %d").printf(1) + "\n" +
                GLib.dgettext("dino", "Mentioned") + "\n" + GLib.dgettext("dino", "Muted");
            fail_if(row.tooltip_text != expected || row_label(row, "name_label").label != "Renamed room",
                "the real display-name binding must update compact and expanded metadata together");
            assert_accessible_label(row, expected);
            fixture.selector.compact = false;
            fail_if(!row_widget(row, "text_container").visible ||
                !row_widget(row, "mention_indicator_label").visible ||
                row_widget(row, "compact_mention_indicator_label").visible,
                "expanding must restore the existing mention indicator and hide its compact overlay");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_mention_updates() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.selector.compact = true;
            var room = fixture.conversation(fixture.first, "room@conference.example.test", Conversation.Type.GROUPCHAT);
            var other_room = fixture.conversation(fixture.second, "room@conference.example.test", Conversation.Type.GROUPCHAT);
            var row = fixture.row(room);
            var other_row = fixture.row(other_room);
            var earlier = fixture.add_message(room, true);
            fixture.add_message(room);
            fixture.add_message(other_room, true);
            wait_for(() => row_widget(row, "compact_mention_indicator_label").visible &&
                row_widget(other_row, "compact_mention_indicator_label").visible,
                "both accounts must initially show their independent unread mention");
            earlier.message.has_mention = false;
            fixture.interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY)
                .received_correction(earlier);
            wait_for(() => !row_widget(row, "compact_mention_indicator_label").visible,
                "editing an earlier unread message must clear its mention even when the count stays unchanged");
            fail_if_not(row_widget(other_row, "compact_mention_indicator_label").visible,
                "the correction must not clear another account's mention");
            earlier.message.has_mention = true;
            fixture.interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY)
                .received_correction(earlier);
            wait_for(() => row_widget(row, "compact_mention_indicator_label").visible,
                "adding a mention to an earlier unread message must refresh the same-count row");
            earlier.message.mention_state = Message.MentionState.UNKNOWN;
            earlier.message.body = "Alice: offline nickname fixture";
            room.nickname = "Bob";
            wait_for(() => !row_widget(row, "compact_mention_indicator_label").visible,
                "the legacy body must not match the wrong saved nickname");
            room.nickname = "Alice";
            wait_for(() => row_widget(row, "compact_mention_indicator_label").visible,
                "a saved nickname arriving after the row must refresh the offline mention");
            fail_if_not(row_widget(other_row, "compact_mention_indicator_label").visible);
            earlier.message.body = "";
            earlier.message.has_mention = false;
            fixture.interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY)
                .item_deleted(earlier);
            wait_for(() => !row_widget(row, "compact_mention_indicator_label").visible,
                "deleting an earlier unread mention must clear the marker");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_room_markers() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.selector.compact = true;
            var room = fixture.conversation(fixture.first, "room@conference.example.test", Conversation.Type.GROUPCHAT);
            var other_room = fixture.conversation(fixture.second, "room@conference.example.test", Conversation.Type.GROUPCHAT);
            var contact = fixture.conversation(fixture.first);
            var private_message = fixture.conversation(fixture.first,
                "room@conference.example.test/member", Conversation.Type.GROUPCHAT_PM);
            var row = fixture.row(room);
            var other_row = fixture.row(other_room);
            var marker = (Image) row_widget(row, "compact_muc_indicator");
            var other_marker = (Image) row_widget(other_row, "compact_muc_indicator");
            fail_if(!marker.visible || marker.icon_name != "system-users-symbolic" ||
                row_widget(row, "status_label").visible,
                "a room with no presence must still have its own group marker");
            fail_if(row_widget(fixture.row(contact), "compact_muc_indicator").visible ||
                row_widget(fixture.row(private_message), "compact_muc_indicator").visible,
                "direct contacts and private messages inside a MUC must not acquire room markers");

            fixture.set_room_private(room, true);
            fail_if(!marker.visible || marker.icon_name != "changes-prevent-symbolic" ||
                !row_widget(row, "private_room_image").visible ||
                !row.tooltip_text.contains(GLib.dgettext("dino", "Private room (supports group calls)")),
                "late private-room discovery must update the marker and translated summary");
            assert_accessible_label(row, (!) row.tooltip_text);
            fail_if(!other_marker.visible || other_marker.icon_name != "system-users-symbolic" ||
                row_widget(other_row, "private_room_image").visible,
                "private-room discovery must not leak across accounts sharing the room JID");
            fixture.set_room_private(room, false);
            fail_if(marker.icon_name != "system-users-symbolic" ||
                !row.tooltip_text.contains(GLib.dgettext("dino", "Group chat")),
                "removing private-room features must restore the ordinary group marker");

            fixture.selector.compact = false;
            fixture.set_room_private(room, true);
            fail_if(marker.visible || !row_widget(row, "muc_indicator").visible ||
                !row_widget(row, "private_room_image").visible,
                "expanded rows must keep their original icons and hide the compact marker");
            fixture.selector.compact = true;
            fail_if(!marker.visible || marker.icon_name != "changes-prevent-symbolic" ||
                row_widget(row, "status_label").visible,
                "compacting again must preserve the discovered room type without a presence status");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_remap() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.selector.compact = true;
            var conversation = fixture.conversation(fixture.first);
            var row = fixture.row(conversation);
            drain();
            string expected = (!) row.tooltip_text;
            fixture.present();
            fixture.scroller.child = null;
            wait_for(() => !row.get_realized(), "detaching must unrealize the same production row");
            fixture.scroller.child = fixture.selector;
            wait_for(() => row.get_mapped(), "reattaching must remap the same production row");
            fail_if(Util.use_tooltips() && !row.has_tooltip,
                "remapping must restore the compact tooltip without a new message or mode toggle");
            fail_if(row.tooltip_text != expected,
                "remapping must retain the same conversation and account tooltip");
            assert_accessible_label(row, expected);
            fixture.selector.compact = false;
            if (Environment.get_variable("GTK_A11Y") == "test") {
                fail_if(Gtk.test_accessible_has_property(row, AccessibleProperty.LABEL),
                    "expanded rows must return to GTK's existing implicit accessible name");
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_bounds() {
        Fixture? fixture = null;
        var style = Adw.StyleManager.get_default();
        Adw.ColorScheme previous_scheme = style.color_scheme;
        TextDirection previous_direction = Widget.get_default_direction();
        try {
            fixture = new Fixture();
            fixture.selector.compact = true;
            var conversation = fixture.conversation(fixture.first,
                "a-very-long-room-name-that-must-not-widen-the-avatar-rail@conference.example.test",
                Conversation.Type.GROUPCHAT);
            conversation.notify_setting = Conversation.NotifySetting.OFF;
            conversation.pinned = 1;
            var row = fixture.row(conversation);
            for (int i = 0; i < 101; i++) row.content_item_received(fixture.add_message(conversation, i == 0));
            wait_for(() => row_label(row, "compact_unread_count_label").label == "\u206699+\u2069" &&
                row_widget(row, "compact_muted_image").visible &&
                row_widget(row, "compact_pinned_image").visible &&
                row_widget(row, "compact_mention_indicator_label").visible,
                "the bounded count must be ready before measuring the rail");
            fixture.window.set_default_size(72, 320);
            fixture.present();
            foreach (Adw.ColorScheme scheme in new Adw.ColorScheme[] { Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                style.color_scheme = scheme;
                foreach (TextDirection direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    iterate_for(35);
                    int minimum, natural, min_baseline, natural_baseline;
                    fixture.selector.measure(Orientation.HORIZONTAL, -1,
                        out minimum, out natural, out min_baseline, out natural_baseline);
                    fail_if(minimum > 72 || natural > 72,
                        "the long contact and count must fit the 72px compact rail (minimum=%d, natural=%d)".printf(minimum, natural));
                    Graphene.Rect avatar;
                    fail_if_not(row_widget(row, "picture").compute_bounds(row, out avatar),
                        "the production avatar must have row bounds");
                    fail_if(avatar.get_width() != 32 || avatar.get_height() != 32,
                        "the compact avatar must keep its 32px size in both directions");
                    string[] markers = { "compact_unread_count_label", "compact_muted_image",
                        "compact_mention_indicator_label", "compact_muc_indicator", "compact_pinned_image" };
                    Graphene.Rect[] marker_bounds = new Graphene.Rect[markers.length];
                    for (int i = 0; i < markers.length; i++) {
                        var widget = row_widget(row, markers[i]);
                        Graphene.Rect bounds;
                        fail_if_not(widget.visible, "each real marker must be visible");
                        fail_if_not(widget.compute_bounds(row, out bounds),
                            "each real marker must have row bounds");
                        marker_bounds[i] = bounds;
                        fail_if(bounds.get_width() <= 0 || bounds.get_height() <= 0 ||
                            bounds.get_x() < 0 || bounds.get_y() < 0 ||
                            bounds.get_x() + bounds.get_width() > row.get_width() ||
                            bounds.get_y() + bounds.get_height() > row.get_height(),
                            "all markers must fit inside the compact rail");
                        for (int j = 0; j < i; j++) {
                            var other = marker_bounds[j];
                            bool overlap = bounds.get_x() < other.get_x() + other.get_width() &&
                                other.get_x() < bounds.get_x() + bounds.get_width() &&
                                bounds.get_y() < other.get_y() + other.get_height() &&
                                other.get_y() < bounds.get_y() + bounds.get_height();
                            fail_if(overlap, "%s must not obscure %s".printf(markers[i], markers[j]));
                        }
                    }
                }
            }
            fixture.selector.compact = false;
            wait_for(() => row_widget(row, "picture").get_width() == 35 &&
                row_widget(row, "picture").get_height() == 35,
                "expanding must restore the normal 35px avatar");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (fixture != null) fixture.close();
            Widget.set_default_direction(previous_direction);
            style.color_scheme = previous_scheme;
        }
    }

    private void test_cleanup() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.selector.compact = true;
            var conversation = fixture.conversation(fixture.first);
            ConversationSelectorRow? row = fixture.row(conversation);
            var model = fixture.interactor.get_module<ContactModels>(ContactModels.IDENTITY).get_display_name_model(conversation);
            WeakRef row_weak = WeakRef(row);
            drain();
            row = null;
            fixture.interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).hide_conversation(conversation);
            wait_for(() => row_weak.get() == null,
                "normal conversation removal must release the row despite live modules and display-name models");
            model.display_name = "Late rename after removal";
            conversation.notify_setting = Conversation.NotifySetting.OFF;
            drain();
            fail_if(row_weak.get() != null, "late notifications must not recreate or retain the removed row");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_trust_visibility() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(); fixture.selector.compact = true;
            var conversation = fixture.conversation(fixture.first);
            var other = fixture.conversation(fixture.second);
            var old = fixture.add_message(conversation, false, "older visible message");
            var hidden = fixture.add_message(conversation, false, "sensitive trusted preview", Encryption.OMEMO);
            var other_message = fixture.add_message(other, false, "other account preview");
            var row = fixture.row(conversation); var other_row = fixture.row(other);
            // The isolated insert helper only persists. Production announces
            // after the receive pipeline, so initialize its receipt hook here.
            row.content_item_received(hidden);
            other_row.content_item_received(other_message);
            fixture.present();
            wait_for(() => row_label(row, "message_label").label == "sensitive trusted preview" &&
                row_label(row, "unread_count_label").label == "2", "the actual row must show the latest persisted message");
            string unread = row_label(row, "unread_count_label").label;
            string compact_unread = row_label(row, "compact_unread_count_label").label;
            string tooltip = row.tooltip_text ?? "";
            int new_messages = 0;
            var store = fixture.interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            store.new_item.connect((item, conv) => { new_messages++; });
            store.set_item_hide_checked(hidden, true);
            drain();
            fail_if_not_eq_str(row_label(row, "message_label").label, "older visible message");
            fail_if_not_eq_str(row_label(other_row, "message_label").label, "other account preview");
            fail_if_not_eq_str(row.tooltip_text ?? "", tooltip, "trust projection preserves account/unread tooltip metadata");
            fail_if((row.tooltip_text ?? "").contains("sensitive trusted preview"));
            store.set_item_hide_checked(old, true);
            drain();
            fail_if(row_widget(row, "message_label").visible || row_widget(row, "time_label").visible);
            fail_if_not_eq_str(row_label(row, "message_label").label, "");
            store.set_item_hide_checked(hidden, false);
            drain();
            fail_if_not_eq_str(row_label(row, "message_label").label, "sensitive trusted preview");
            fail_if_not_eq_str(row_label(row, "unread_count_label").label, unread);
            fail_if_not_eq_str(row_label(row, "compact_unread_count_label").label, compact_unread);
            fail_if_not_eq_int(new_messages, 0, "hide/reveal must never announce a new message");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_diagnostic_preview() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var conversation = fixture.conversation(fixture.first);
            string marker = "[This OMEMO message could not be decrypted]";
            var failure = fixture.add_message(conversation, false, marker, Encryption.OMEMO, true);
            var row = fixture.row(conversation);
            row.content_item_received(failure);
            string localized = GLib.dgettext("dino", "This OMEMO message could not be decrypted on this device.");
            wait_for(() => row_label(row, "message_label").label == localized,
                "the real sidebar must use the localized local failure diagnostic");
            var authenticated = fixture.add_message(conversation, false, marker, Encryption.OMEMO, false);
            row.content_item_received(authenticated);
            wait_for(() => row_label(row, "message_label").label == marker,
                "authenticated user text matching a failure marker must stay unchanged");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_encryption_menu_state_and_scope() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var entry = new TestEncryptionEntry();
            var details = new TestEncryptionDetails();
            fixture.app.plugin_registry.register_encryption_list_entry(entry);
            fixture.app.plugin_registry.register_contact_details_entry(details);
            var conversation = fixture.conversation(fixture.first);
            conversation.encryption = Encryption.NONE;
            fixture.present();
            var row = fixture.row(conversation);
            var menu = row_context_menu(row);
            Button? button = encryption_context_button(menu);
            fail_if(button == null, "a normal contact with an encryption details provider needs the shortcut");
            if (button == null) return;
            var details_section = menu.menu_model.get_item_link(0, Menu.LINK_SECTION);
            var notifications_section = menu.menu_model.get_item_link(1, Menu.LINK_SECTION);
            fail_if(details_section == null || notifications_section == null,
                "details and notification controls must be separate native menu sections");
            if (details_section == null || notifications_section == null) return;
            fail_if_not_eq_str("row.details", details_section.get_item_attribute_value(0, "action", VariantType.STRING).get_string(),
                "the existing Info entry must retain its original action");
            fail_if_not_eq_str("row.edit", details_section.get_item_attribute_value(1, "action", VariantType.STRING).get_string());
            fail_if_not_eq_str("encryption-entry", details_section.get_item_attribute_value(2, "custom", VariantType.STRING).get_string());
            fail_if_not_eq_str("row.mute", notifications_section.get_item_attribute_value(0, "action", VariantType.STRING).get_string());
            fail_if_not_eq_str(_("Encryption"), encryption_context_label(button).label);
            fail_if_not_eq_str(_("Unencrypted"), encryption_context_status(button).label);
            fail_if_not(encryption_context_icon(button).has_css_class("dim-label"));
            fail_if_not_eq_int(0, entry.trust_queries, "unencrypted mode must not claim a protocol's trust state");
            row.dismiss_popover(); iterate_for(40);

            conversation.encryption = Encryption.OMEMO;
            Plugins.ConversationEncryptionTrust[] states = {
                Plugins.ConversationEncryptionTrust.UNKNOWN, Plugins.ConversationEncryptionTrust.TRUSTED,
                Plugins.ConversationEncryptionTrust.VERIFIED, Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION
            };
            string[] statuses = { _("Unknown"), _("Trusted"), _("Verified"), _("Check keys") };
            string[] classes = { "dim-label", "accent", "success", "warning" };
            for (int i = 0; i < states.length; i++) {
                entry.trust = states[i];
                menu = row_context_menu(row);
                button = encryption_context_button(menu);
                fail_if(button == null);
                if (button == null) return;
                string expected = "%s · OMEMO · %s".printf(_("Encryption"), statuses[i]);
                fail_if_not_eq_str(_("Encryption"), encryption_context_label(button).label);
                fail_if_not_eq_str("OMEMO · %s".printf(statuses[i]), encryption_context_status(button).label);
                iterate_for(30);
                fail_if(encryption_context_status(button).get_layout().is_ellipsized(),
                    "the separate status line must keep the trust result readable");
                fail_if_not(encryption_context_icon(button).has_css_class(classes[i]));
                fail_if_not_eq_str(states[i] == Plugins.ConversationEncryptionTrust.VERIFIED
                    ? "dino-shield-check-symbolic" : "dino-security-high-symbolic",
                    encryption_context_icon(button).icon_name);
                foreach (string other in classes) {
                    if (other != classes[i]) fail_if(encryption_context_icon(button).has_css_class(other));
                }
                fail_if_not((button.tooltip_text ?? "").contains(expected), "ellipsized text must remain complete in the tooltip");
                fail_if_not(encryption_context_label(button).ellipsize == Pango.EllipsizeMode.END);
                fail_if_not(button.get_accessible_role() == AccessibleRole.MENU_ITEM);
                if (Environment.get_variable("GTK_A11Y") == "test") {
                    fail_if(check_conversation_row_accessible_property(button, AccessibleProperty.LABEL, expected) != null);
                }
                if (states[i] == Plugins.ConversationEncryptionTrust.VERIFIED) {
                    fail_if_not((button.tooltip_text ?? "").contains(_("Locally known active keys are verified. Open encryption details to review them.")));
                }
                row.dismiss_popover(); iterate_for(40);
            }
            fail_if_not_eq_int(0, entry.activation_calls, "opening this menu must never run encryption activation or readiness work");
            fail_if_not_eq_int(0, details.widget_requests, "a provider lookup must not construct key-management UI");

            var room = fixture.conversation(fixture.first, "same@conference.example.test", Conversation.Type.GROUPCHAT);
            var public_room = fixture.conversation(fixture.second, "same@conference.example.test", Conversation.Type.GROUPCHAT);
            fixture.set_room_private(room, true);
            fixture.set_room_private(public_room, false);
            menu = row_context_menu(fixture.row(room));
            fail_if(encryption_context_button(menu) == null, "a private room uses its own account-scoped details provider");
            fixture.row(room).dismiss_popover(); iterate_for(40);
            Conversation[] excluded = {
                public_room,
                fixture.conversation(fixture.first, "same@conference.example.test/nick", Conversation.Type.GROUPCHAT_PM),
                fixture.conversation(fixture.first, "device@mqtt.local"),
                fixture.conversation(fixture.first, fixture.first.bare_jid.to_string())
            };
            excluded[3].nickname = "Botmother";
            foreach (Conversation target in excluded) {
                var excluded_row = fixture.row(target);
                fail_if(encryption_context_button(row_context_menu(excluded_row)) != null,
                    "public rooms, MUC PMs and synthetic system chats must not expose this shortcut");
                excluded_row.dismiss_popover(); iterate_for(40);
            }
            fixture.app.plugin_registry.contact_details_entries.clear();
            fail_if(encryption_context_button(row_context_menu(row)) != null,
                "an encryption list entry alone must not advertise a nonexistent details tab");
            row.dismiss_popover();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_encryption_menu_target_and_cleanup() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.app.plugin_registry.register_encryption_list_entry(new TestEncryptionEntry());
            var details = new TestEncryptionDetails();
            fixture.app.plugin_registry.register_contact_details_entry(details);
            fixture.app.capture_details_actions();
            var target = fixture.conversation(fixture.first, "peer@example.test");
            var selected = fixture.conversation(fixture.second, "peer@example.test");
            fixture.selector.on_conversation_selected(selected);
            fixture.present();
            ConversationSelectorRow? row = fixture.row(target);
            PopoverMenu? menu = row_context_menu(row);
            Button? button = encryption_context_button(menu);
            fail_if(button == null);
            if (button == null) return;
            fail_if_not(button.grab_focus(), "the custom native menu item must accept keyboard focus");
            button.activate();
            wait_for(() => fixture.app.details_requests == 1, "the custom entry must open details once");
            fail_if(fixture.app.details_target == null);
            if (fixture.app.details_target == null) return;
            fail_if_not_eq_int(target.id, fixture.app.details_target.get_child_value(0).get_int32(),
                "the entry belongs to the right-clicked account and conversation, not the selected chat");
            fail_if_not_eq_str("encryption", fixture.app.details_target.get_child_value(1).get_string(),
                "the new shortcut must directly request the encryption tab, never about");
            fail_if_not(((ConversationSelectorRow) fixture.list_box.get_selected_row()).conversation == selected);
            wait_for(() => !menu.get_mapped(), "custom menu activation must dismiss its popover");
            button = null; menu = null;

            menu = row_context_menu(row);
            button = encryption_context_button(menu);
            fixture.app.plugin_registry.contact_details_entries.clear();
            button.activate(); iterate_for(300);
            fail_if_not_eq_int(1, fixture.app.details_requests, "a stale menu must recheck that its encryption tab still exists");
            row.dismiss_popover(); iterate_for(40);
            fixture.app.plugin_registry.register_contact_details_entry(details);
            button = null; menu = null;

            menu = row_context_menu(row);
            button = encryption_context_button(menu);
            WeakRef row_weak = WeakRef(row);
            WeakRef menu_weak = WeakRef(menu);
            WeakRef button_weak = WeakRef(button);
            row = null; menu = null; button = null;
            fixture.interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).hide_conversation(target);
            wait_for(() => row_weak.get() == null && menu_weak.get() == null && button_weak.get() == null,
                "removing a row with its custom menu open must release the row, popover and button");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private static PopoverMenu row_context_menu(ConversationSelectorRow row) throws Error {
        var controllers = row.observe_controllers();
        bool released = false;
        for (uint i = 0; i < controllers.get_n_items(); i++) {
            var gesture = controllers.get_item(i) as GestureClick;
            if (gesture != null && gesture.get_button() == 3) {
                gesture.released(1, 8, 8);
                released = true;
                break;
            }
        }
        if (!released) throw new IOError.FAILED("The real row must retain its right-click gesture");
        for (Widget? child = row.get_first_child(); child != null; child = child.get_next_sibling()) {
            var menu = child as PopoverMenu;
            if (menu != null) {
                wait_for(() => menu.get_mapped(), "the production context menu must map");
                return menu;
            }
        }
        throw new IOError.FAILED("The row's production gesture must create a native popover menu");
    }

    private static Button? encryption_context_button(Widget parent) {
        var button = parent as Button;
        if (button != null && button.action_name == "row.encryption") return button;
        for (Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            Button? found = encryption_context_button(child);
            if (found != null) return found;
        }
        return null;
    }

    private static Image encryption_context_icon(Button button) {
        return (Image) button.child.get_first_child();
    }

    private static Label encryption_context_label(Button button) {
        return (Label) button.child.get_first_child().get_next_sibling().get_first_child();
    }

    private static Label encryption_context_status(Button button) {
        return (Label) encryption_context_label(button).get_next_sibling();
    }

    private static Widget row_widget(ConversationSelectorRow row, string id) {
        return (Widget) row.get_template_child(typeof(ConversationSelectorRow), id);
    }

    private static Label row_label(ConversationSelectorRow row, string id) {
        return (Label) row_widget(row, id);
    }

    private static void assert_accessible_label(ConversationSelectorRow row, string expected) {
        if (Environment.get_variable("GTK_A11Y") != "test") return;
        fail_if(check_conversation_row_accessible_property(row, AccessibleProperty.LABEL, expected) != null,
            "the real accessible label must preserve the full account-scoped compact summary");
        fail_if_not(((Accessible) row).get_accessible_role() == AccessibleRole.LIST_ITEM,
            "compaction must preserve the native list-item accessible role");
    }

    private void test_header_menu_reuse() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.app.capture_details_actions();
            var first = fixture.conversation(fixture.first);
            var second = fixture.conversation(fixture.second);
            first.notify_setting = Conversation.NotifySetting.ON;
            second.notify_setting = Conversation.NotifySetting.OFF;
            var private_room = fixture.conversation(fixture.first, "same@conference.example.test", Conversation.Type.GROUPCHAT);
            var public_room = fixture.conversation(fixture.second, "same@conference.example.test", Conversation.Type.GROUPCHAT);
            fixture.set_room_private(private_room, true);
            fixture.set_room_private(public_room, false);
            var mqtt = fixture.conversation(fixture.first, "device@mqtt.local");
            var private_message = fixture.conversation(fixture.first,
                "same@conference.example.test/member", Conversation.Type.GROUPCHAT_PM);

            var menu = new MenuEntry(fixture.interactor);
            var notifications = new NotificationEntry(fixture.interactor);
            var menu_button = (MenuButton) menu.get_widget(Plugins.WidgetType.GTK4);
            var notification_button = (MenuButton) notifications.get_widget(Plugins.WidgetType.GTK4);
            var header = new Box(Orientation.HORIZONTAL, 6);
            header.append(notification_button);
            header.append(menu_button);
            var content = new Box(Orientation.VERTICAL, 6);
            fixture.window.content = null;
            content.append(header);
            content.append(fixture.scroller);
            fixture.window.content = content;
            menu.set_conversation(first);
            notifications.set_conversation(first);
            fixture.present();
            var menu_popover = (PopoverMenu) menu_button.popover;
            var notification_popover = (PopoverMenu) notification_button.popover;
            var direct_menu_model = menu_popover.menu_model;
            var direct_notification_model = notification_popover.menu_model;

            menu_button.popup(); iterate_for(200);
            fail_if_not(menu_popover.get_mapped(), "the real native menu must open before changing its target");
            menu.set_conversation(second);
            notifications.set_conversation(second);
            iterate_for(200);
            fail_if(menu_popover.get_mapped(), "switching chats must close the previous chat's open menu");
            fail_if(menu_button.popover != menu_popover || notification_button.popover != notification_popover,
                "switching accounts must keep both native popover widgets");
            fail_if(menu_popover.menu_model != direct_menu_model ||
                notification_popover.menu_model != direct_notification_model,
                "equivalent direct chats must keep the existing menu models");
            fail_if_not(menu_button.activate_action_variant("conversation.details", null));
            Variant? target = fixture.app.details_target;
            fail_if(target == null, "the retained details action must still dispatch");
            if (target != null) fail_if_not_eq_int(second.id, target.get_child_value(0).get_int32(),
                "the retained action must select the new account's conversation, even for the same JID");
            fail_if_not_eq_str("dino-bell-large-none-symbolic", notification_button.icon_name ?? "");
            fail_if_not(notification_button.activate_action_variant("notification.setting",
                new Variant.int32(Conversation.NotifySetting.DEFAULT)));
            fail_if_not(second.notify_setting == Conversation.NotifySetting.DEFAULT);
            fail_if_not(first.notify_setting == Conversation.NotifySetting.ON,
                "the retained notification action must not modify the previous account");
            second.notify_setting = Conversation.NotifySetting.OFF;
            first.notify_setting = Conversation.NotifySetting.OFF;
            first.notify_setting = Conversation.NotifySetting.ON;
            fail_if_not_eq_str("dino-bell-large-none-symbolic", notification_button.icon_name ?? "");

            menu.set_conversation(private_room);
            notifications.set_conversation(private_room);
            var group_menu_model = menu_popover.menu_model;
            var group_notification_model = notification_popover.menu_model;
            fail_if(menu_button.popover != menu_popover || notification_button.popover != notification_popover,
                "changing chat type must update the models without replacing their popovers");
            fail_if_not_eq_int(1, header_menu_action_count(group_menu_model, "app.leave-current-conversation"));
            fail_if_not_eq_int(4, group_notification_model.get_n_items());
            fail_if_not_eq_str(_("Notifications enabled"), notification_button.tooltip_text ?? "");
            menu.set_conversation(public_room);
            notifications.set_conversation(public_room);
            fail_if(menu_popover.menu_model != group_menu_model ||
                notification_popover.menu_model != group_notification_model,
                "private and public rooms share menu entries, but keep independent live settings");
            fail_if_not_eq_str(_("Notifications for mentions"), notification_button.tooltip_text ?? "");
            fixture.set_room_private(public_room, true);
            fail_if_not_eq_str(_("Notifications enabled"), notification_button.tooltip_text ?? "");
            fail_if(notification_popover.menu_model != group_notification_model,
                "late room discovery must update notification state without rebuilding the menu");

            foreach (var target_chat in new Conversation[] { first, mqtt, private_message, public_room }) {
                menu.set_conversation(target_chat);
                notifications.set_conversation(target_chat);
                fail_if(menu_button.popover != menu_popover || notification_button.popover != notification_popover);
                int expected_history = target_chat == first || target_chat == public_room ? 1 : 0;
                fail_if_not_eq_int(expected_history, header_menu_action_count(menu_popover.menu_model,
                    "app.load-current-conversation-history"));
                fail_if_not_eq_int(target_chat == public_room ? 1 : 0,
                    header_menu_action_count(menu_popover.menu_model, "app.leave-current-conversation"));
                fail_if_not_eq_int(target_chat == public_room ? 4 : 3,
                    notification_popover.menu_model.get_n_items());
            }
            notification_button.popup(); iterate_for(200);
            fail_if_not(notification_popover.get_mapped());
            menu.unset_conversation(); notifications.unset_conversation();
            iterate_for(200);
            fail_if(menu_button.visible || notification_button.visible || notification_popover.get_mapped(),
                "clearing the selection must close and hide retained menu widgets");
            menu.set_conversation(public_room); notifications.set_conversation(public_room);
            fail_if(menu_button.popover != menu_popover || notification_button.popover != notification_popover,
                "reopening a conversation must retain the native popovers too");
            menu.unset_conversation(); notifications.unset_conversation();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_call_control_selection() {
        Fixture? fixture = null;
        CallTitlebarEntry? entry = null;
        try {
            fixture = new Fixture();
            var direct = fixture.conversation(fixture.first);
            var public_room = fixture.conversation(fixture.first,
                "public@conference.example.test", Conversation.Type.GROUPCHAT);
            fixture.set_room_private(public_room, false);
            var other_account = fixture.conversation(fixture.second);
            entry = new CallTitlebarEntry(fixture.interactor);
            var button = (MenuButton) entry.get_widget(Plugins.WidgetType.GTK4);
            var content = new Box(Orientation.VERTICAL, 6);
            fixture.window.content = null;
            content.append(button);
            content.append(fixture.scroller);
            fixture.window.content = content;
            fixture.present();
            var popover = button.popover;
            var calls = fixture.interactor.get_module<Calls>(Calls.IDENTITY);

            foreach (var target in new Conversation[] { public_room, other_account }) {
                entry.set_conversation(direct);
                drain();
                // Seed the visible previous-chat presentation. These accounts
                // deliberately stay offline; positive call capabilities have
                // their own service tests. This checks the selection/frame
                // boundary without an XMPP connection or an actual call.
                button.visible = true;
                button.sensitive = true;
                iterate_for(200);
                fail_if_not(button.get_mapped());
                button.popup(); iterate_for(200);
                fail_if_not(popover.get_mapped());
                // A pending update for the old target must not defer the new
                // target's state until after GTK has had a chance to paint.
                calls.conversation_call_capabilities_changed(direct.account, direct.counterpart);
                entry.set_conversation(target);
                fail_if(button.visible || button.sensitive,
                    "the unavailable target must hide and disable the old call control before returning");
                fail_if(button.popover != popover,
                    "updating visibility must retain the native call menu");
                iterate_for(200);
                fail_if(button.get_mapped() || popover.get_mapped(),
                    "queued updates must not restore the old chat's button or popup");
            }
            calls.conversation_call_capabilities_changed(other_account.account, other_account.counterpart);
            entry.unset_conversation();
            fail_if(button.visible || button.sensitive);
            drain();
            fail_if(button.visible || button.sensitive);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (entry != null) { entry.unset_conversation(); entry.dispose(); }
            if (fixture != null) fixture.close();
        }
    }

    private static int header_menu_action_count(MenuModel model, string expected) {
        int count = 0;
        for (int i = 0; i < model.get_n_items(); i++) {
            Variant? action = model.get_item_attribute_value(i, Menu.ATTRIBUTE_ACTION, VariantType.STRING);
            if (action != null && action.get_string() == expected) count++;
            foreach (string link in new string[] { Menu.LINK_SECTION, Menu.LINK_SUBMENU }) {
                MenuModel? child = model.get_item_link(i, link);
                if (child != null) count += header_menu_action_count(child, expected);
            }
        }
        return count;
    }

    private static void drain() {
        while (MainContext.default().pending()) MainContext.default().iteration(false);
    }

    private static void iterate_for(int milliseconds) {
        int64 deadline = GLib.get_monotonic_time() + milliseconds * TimeSpan.MILLISECOND;
        do {
            drain();
            Thread.usleep(1000);
        } while (GLib.get_monotonic_time() < deadline);
    }

    private static void wait_for(Ready ready, string reason) throws Error {
        int64 deadline = GLib.get_monotonic_time() + 2 * TimeSpan.SECOND;
        while (!ready() && GLib.get_monotonic_time() < deadline) {
            drain();
            Thread.usleep(1000);
        }
        if (!ready()) throw new IOError.TIMED_OUT(reason);
    }
}

}
