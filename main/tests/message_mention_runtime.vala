using Dino.Entities;
using Dino.Security;
using Dino.Ui.ConversationSummary;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

[CCode (cname = "gtk_test_accessible_check_property", cheader_filename = "gtk/gtk.h")]
private static extern string? check_message_mention_accessible_property(
    Accessible accessible, AccessibleProperty property, ...);

[CCode (cname = "gtk_style_context_add_provider_for_display", cheader_filename = "gtk/gtk.h")]
private static extern void add_message_mention_style_provider(Gdk.Display display,
    StyleProvider provider, uint priority);

[CCode (cname = "gtk_style_context_remove_provider_for_display", cheader_filename = "gtk/gtk.h")]
private static extern void remove_message_mention_style_provider(Gdk.Display display,
    StyleProvider provider);

// Native presentation tests use the production template and controller against
// an isolated persisted profile, without connecting real accounts or servers.
class MessageMentionRuntimeTest : Gee.TestCase {
    private const string PROFILE_KEY = "isolated message mention runtime test";

    public MessageMentionRuntimeTest() {
        base("MessageMentionRuntime");
        add_test("cold_history_uses_saved_room_nickname_before_join", test_cold_history);
        add_test("explicit_mention_survives_database_read_and_body_alias", test_explicit_history);
        add_test("nickname_notifications_are_account_and_room_scoped", test_nickname_scope);
        add_test("outgoing_and_other_chat_types_do_not_inherit_room_text_highlight", test_direction_and_types);
        add_test("corrections_rebind_and_deletion_cannot_resurrect_highlight", test_revisions);
        add_test("attachment_mentions_use_validated_backing_message", test_attachment);
        add_test("weak_signal_bridges_release_owner_and_clear_is_idempotent", test_lifetime);
        add_test("header_badge_keeps_text_edge_and_native_metadata_bounds", test_geometry);
        add_test("metadata_group_stays_compact_when_body_and_window_change", test_compact_header);
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public TestApplication(Database db, StreamInteractor interactor,
                FileEncryption encryption) {
            Object(application_id: "im.dinox.message-mention-runtime-test",
                flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            db_key = PROFILE_KEY;
            file_encryption = encryption;
            settings = new Dino.Entities.Settings.from_db(db);
            stream_interactor = interactor;
        }
        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    private class Fixture : Object {
        public string root;
        public Database db;
        public StreamInteractor interactor;
        public Account first;
        public Account second;
        public Conversation room;
        public Conversation other_account_room;
        public Conversation sibling_room;
        private TestApplication app;
        private GLib.Application? previous_app;
        private int serial = 0;
        private bool closed = false;

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-message-mention-XXXXXX");
            db = new Database(Path.build_filename(root, "dino.db"), PROFILE_KEY);
            interactor = new StreamInteractor.for_tests(db);
            var encryption = new FileEncryption(PROFILE_KEY);
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
            room = conversation(first, "same@conference.example.test", Conversation.Type.GROUPCHAT, "Alice");
            other_account_room = conversation(second, "same@conference.example.test", Conversation.Type.GROUPCHAT, "Bob");
            sibling_room = conversation(first, "sibling@conference.example.test", Conversation.Type.GROUPCHAT, "Carol");
        }

        public Conversation conversation(Account account, string address,
                Conversation.Type type, string? nickname = null) throws Error {
            var conversation = interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY).create_conversation(new Jid(address), account, type);
            conversation.nickname = nickname;
            return conversation;
        }

        public MessageItem add_message(Conversation conversation, string body,
                bool sent = false) throws Error {
            DateTime time = new DateTime.now_utc().add_seconds(++serial);
            Jid peer = conversation.type_ == Conversation.Type.GROUPCHAT
                ? conversation.counterpart.with_resource("sender") : conversation.counterpart;
            Jid own = conversation.type_ == Conversation.Type.GROUPCHAT
                ? conversation.counterpart.with_resource(conversation.nickname ?? "Alice")
                : conversation.account.bare_jid;
            var message = new Dino.Entities.Message(body) {
                account = conversation.account, counterpart = peer, ourpart = own,
                direction = sent ? Dino.Entities.Message.DIRECTION_SENT : Dino.Entities.Message.DIRECTION_RECEIVED,
                type_ = Dino.Util.get_message_type_for_conversation(conversation),
                stanza_id = "mention-fixture-%d".printf(serial),
                time = time, local_time = time
            };
            interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).add_message(message, conversation);
            var store = interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            store.insert_message(message, conversation);
            MessageItem? item = store.get_item_by_foreign(conversation, 1, message.id) as MessageItem;
            if (item == null) throw new IOError.FAILED("Persisted fixture content item is missing");
            return (!) item;
        }

        public MessageItem read_cold(MessageItem item, Conversation? owner = null) throws Error {
            Conversation conversation = owner ?? item.conversation;
            var cold = interactor.get_module<MessageStorage>(MessageStorage.IDENTITY)
                .get_persisted_message_by_id(item.message.id, conversation);
            if (cold == null) throw new IOError.FAILED("Fresh database message read is missing");
            return new MessageItem((!) cold, conversation, item.id);
        }

        public void close() {
            if (closed) return;
            closed = true;
            interactor.get_module<MucManager>(MucManager.IDENTITY).shutdown();
            drain();
            GLib.Application.set_default(previous_app);
            db.close();
            FileUtils.remove(Path.build_filename(root, "dino.db"));
            FileUtils.remove(Path.build_filename(root, "dino.db-wal"));
            FileUtils.remove(Path.build_filename(root, "dino.db-shm"));
            DirUtils.remove(root);
        }
    }

    private class Row : Object {
        public Grid grid;
        public Label marker;
        public Label body;
        public MessageMentionPresentation? presentation;
        public Builder builder;

        public Row(Fixture fixture, Conversation conversation, ContentItem item) {
            builder = new Builder.from_resource("/im/dinox/dinox/conversation_item_widget.ui");
            grid = (Grid) builder.get_object("main_grid");
            grid.add_css_class("message-box");
            grid.add_css_class("has-skeleton");
            marker = (Label) builder.get_object("mention_indicator_label");
            ((Label) builder.get_object("name_label")).label = "Sender";
            ((Label) builder.get_object("time_label")).label = "12:34";
            ((Image) builder.get_object("encrypted_image")).icon_name = "changes-prevent-symbolic";
            ((Image) builder.get_object("marked_image")).icon_name = "object-select-symbolic";
            body = new Label("A multiline message body\nkeeps the same text edge") {
                xalign = 0, wrap = true, hexpand = true
            };
            grid.attach(body, 2, 1, 1, 1);
            presentation = new MessageMentionPresentation(fixture.interactor,
                conversation, item, grid, marker);
        }

        public void close() {
            if (presentation != null) ((!) presentation).clear();
            presentation = null;
        }
    }

    private void test_cold_history() {
        Fixture? fixture = null;
        Row? row = null;
        try {
            fixture = new Fixture();
            var original = fixture.add_message(fixture.room, "Alice, hello");
            var saved = fixture.db.conversation.select().with(fixture.db.conversation.id,
                "=", fixture.room.id).single().row().inner;
            var restored_room = new Conversation.from_row(fixture.db, saved);
            var cold = fixture.read_cold(original, restored_room);
            fail_if(fixture.interactor.get_stream(fixture.first) != null,
                "the regression must start before a stream or MUC join exists");
            fail_if_not_eq_int((int) Dino.Entities.Message.MentionState.UNKNOWN,
                (int) cold.message.mention_state,
                "old unclassified history must not depend on live transient flags");
            row = new Row(fixture, restored_room, cold);
            fail_if_not(((!) row.presentation).mentioned && row.marker.visible &&
                    row.grid.has_css_class("mentioned"),
                "cold history must highlight immediately without a chat switch");
            row.marker.visible = false;
            restored_room.notify_property("nickname");
            fail_if_not(row.marker.visible,
                "a later nickname notification must restore marker presentation consistently");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (row != null) row.close(); if (fixture != null) fixture.close(); }
    }

    private void test_explicit_history() {
        Fixture? fixture = null;
        Row? row = null;
        try {
            fixture = new Fixture();
            var item = fixture.add_message(fixture.room, "A protocol mention with an unrelated visible alias");
            item.message.has_mention = true;
            var cold = fixture.read_cold(item);
            fail_if_not(cold.message.has_mention,
                "explicit XEP-0372 mention classification must survive a fresh read");
            row = new Row(fixture, fixture.room, cold);
            fixture.room.nickname = "A different nickname";
            cold.message.body = "Still an unrelated alias";
            fail_if_not(((!) row.presentation).mentioned,
                "a saved explicit mention must survive nickname and visible alias changes");
            cold.message.has_mention = false;
            fail_if(row.marker.visible,
                "a definite nonmention must update the actual marker synchronously");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (row != null) row.close(); if (fixture != null) fixture.close(); }
    }

    private void test_nickname_scope() {
        Fixture? fixture = null;
        Row? row = null;
        Row? other = null;
        Row? sibling = null;
        try {
            fixture = new Fixture();
            row = new Row(fixture, fixture.room,
                fixture.add_message(fixture.room, "Changed, hello"));
            other = new Row(fixture, fixture.other_account_room,
                fixture.add_message(fixture.other_account_room, "Changed, hello"));
            sibling = new Row(fixture, fixture.sibling_room,
                fixture.add_message(fixture.sibling_room, "Changed, hello"));
            int changes = 0;
            ((!) row.presentation).changed.connect(() => changes++);
            fixture.room.nickname = "Changed";
            fail_if_not(row.marker.visible, "the visible room must react to its own nickname change");
            fail_if(other.marker.visible || sibling.marker.visible,
                "the same address on another account and other rooms must remain untouched");
            fixture.room.notify_property("nickname");
            fail_if_not_eq_int(1, changes,
                "unchanged mention state must not trigger redundant regrouping");
            fixture.room.nickname = "Alice";
            fail_if(row.marker.visible, "unknown legacy rows must also remove a stale nickname match");
            fail_if_not_eq_int(2, changes);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (row != null) row.close(); if (other != null) other.close();
            if (sibling != null) sibling.close(); if (fixture != null) fixture.close();
        }
    }

    private void test_direction_and_types() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var own = fixture.add_message(fixture.room, "Alice, a post sent by this account", true);
            own.message.has_mention = true;
            fail_if(MessageMentionPresentation.is_item_mentioned(fixture.interactor,
                fixture.room, own), "own messages must never claim the user was mentioned");
            var chat = fixture.conversation(fixture.first, "peer@example.test",
                Conversation.Type.CHAT, "Alice");
            var pm = fixture.conversation(fixture.first, "same@conference.example.test/sender",
                Conversation.Type.GROUPCHAT_PM, "Alice");
            foreach (Conversation conversation in new Conversation[] { chat, pm }) {
                var item = fixture.add_message(conversation, "Alice, ordinary direct text");
                fail_if(MessageMentionPresentation.is_item_mentioned(fixture.interactor,
                    conversation, item), "nickname text fallback belongs only to room messages");
                item.message.has_mention = true;
                fail_if_not(MessageMentionPresentation.is_item_mentioned(fixture.interactor,
                    conversation, item), "explicit incoming references retain direct-chat compatibility");
            }
            var incoming = fixture.add_message(fixture.room, "Alice, hello");
            var wrong_owner = new MessageItem(incoming.message, fixture.other_account_room, incoming.id);
            fail_if(MessageMentionPresentation.is_item_mentioned(fixture.interactor,
                fixture.other_account_room, wrong_owner), "a message from another account must fail closed");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_revisions() {
        Fixture? fixture = null;
        Row? row = null;
        try {
            fixture = new Fixture();
            var original = fixture.add_message(fixture.room, "Plain text");
            row = new Row(fixture, fixture.room, original);
            var correction_service = fixture.interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY);
            var foreign = fixture.add_message(fixture.other_account_room, "Bob, a mention elsewhere");
            correction_service.received_correction(new MessageItem(foreign.message,
                fixture.other_account_room, original.id));
            fail_if(row.marker.visible, "a reused content id from another account cannot update this row");
            var replacement = fixture.add_message(fixture.room, "Alice, added in an edit");
            var revision = new MessageItem(replacement.message, fixture.room, original.id);
            correction_service.received_correction(revision);
            fail_if_not(row.marker.visible, "a validated correction must add the mention immediately");
            replacement.message.body = "Plain edited text";
            fail_if(row.marker.visible, "changes to the rebound message must remove the mention");
            original.message.has_mention = true;
            fail_if(row.marker.visible, "observers of the old message must be disconnected");
            replacement.message.has_mention = true;
            fail_if_not(row.marker.visible, "the new explicit mention-state must be observed");
            fixture.interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).item_deleted(revision);
            fail_if(row.marker.visible || row.grid.has_css_class("mentioned"),
                "deleting the revision must immediately clear badge and stripe");
            replacement.message.body = "Alice, late notification";
            correction_service.received_correction(revision);
            fail_if(row.marker.visible, "late body/correction callbacks cannot resurrect a deleted mention");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (row != null) row.close(); if (fixture != null) fixture.close(); }
    }

    private void test_attachment() {
        Fixture? fixture = null;
        Row? row = null;
        try {
            fixture = new Fixture();
            var item = fixture.add_message(fixture.room, "Alice, caption for an attachment");
            var transfer = new FileTransfer() {
                account = fixture.first, counterpart = item.message.counterpart,
                ourpart = item.message.ourpart, direction = item.message.direction,
                time = item.time, local_time = item.time, message_db_id = item.message.id,
                provider = 0, file_name = "fixture.ogg", mime_type = "audio/ogg"
            };
            var file = new FileItem(transfer, fixture.room, -1, item.message);
            row = new Row(fixture, fixture.room, file);
            fail_if_not(row.marker.visible,
                "file/audio/video rows must resolve the same safe backing-message classifier");
            item.message.has_mention = true;
            item.message.body = "A protocol caption alias";
            fail_if_not(row.marker.visible, "attachment markers must observe their backing message");
            transfer.account = fixture.second;
            fail_if(MessageMentionPresentation.is_item_mentioned(fixture.interactor,
                fixture.room, file), "a foreign-account attachment relation must never create a highlight");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (row != null) row.close(); if (fixture != null) fixture.close(); }
    }

    private static void create_dropped_controller(Fixture fixture,
            MessageItem item, Grid grid, Label marker, ref WeakRef controller_weak) {
        var presentation = new MessageMentionPresentation(fixture.interactor,
            fixture.room, item, grid, marker);
        controller_weak.set(presentation);
    }

    private void test_lifetime() {
        Fixture? fixture = null;
        Row? row = null;
        try {
            fixture = new Fixture();
            var item = fixture.add_message(fixture.room, "Alice, hello");
            var grid = new Grid();
            var marker = new Label("@");
            WeakRef controller_weak = WeakRef(null);
            create_dropped_controller(fixture, item, grid, marker, ref controller_weak);
            drain();
            fail_if(controller_weak.get() != null,
                "nickname and service/message signal closures must not retain the controller");
            row = new Row(fixture, fixture.room, item);
            var retained = (!) row.presentation;
            retained.clear();
            retained.clear();
            fixture.room.nickname = "Alice";
            item.message.has_mention = true;
            fixture.interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY).received_correction(item);
            fixture.interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).item_deleted(item);
            fail_if(row.marker.visible || row.grid.has_css_class("mentioned") || retained.mentioned,
                "callbacks after clear cannot re-enable detached presentation");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (row != null) row.close(); if (fixture != null) fixture.close(); }
    }

    private void test_geometry() {
        Fixture? fixture = null;
        Row? row = null;
        var window = new Adw.Window();
        var box = new Box(Orientation.VERTICAL, 0);
        var style = Adw.StyleManager.get_default();
        Adw.ColorScheme original_scheme = style.color_scheme;
        TextDirection original_direction = Widget.get_default_direction();
        var background_probe = new Label("");
        background_probe.add_css_class("mention-background-probe");
        var color_probe_style = new CssProvider();
#if GTK_4_12
        color_probe_style.load_from_string(".mention-background-probe { color: @view_bg_color; }");
#else
        color_probe_style.load_from_data(".mention-background-probe { color: @view_bg_color; }");
#endif
        add_message_mention_style_provider(Gdk.Display.get_default(),
            color_probe_style, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        try {
            fixture = new Fixture();
            var item = fixture.add_message(fixture.room, "Plain message");
            item.message.has_mention = false;
            row = new Row(fixture, fixture.room, item);
            ((Label) row.builder.get_object("name_label")).label =
                "An unusually long participant display name that must stay ellipsized";
            box.add_css_class("dino-conversation");
            box.append(row.grid);
            box.append(background_probe);
            window.add_css_class("dino-main");
            window.content = box;
            window.set_default_size(560, 160);
            window.present();
            // Use the exact same body slot as production for both multiline
            // text and a naturally wide media/link-preview subtree.
            var preview = new Box(Orientation.VERTICAL, 0) {
                width_request = 300, height_request = 150, hexpand = true
            };
            preview.add_css_class("dino-link-preview");
            preview.append(new Picture() {
                width_request = 300, height_request = 130, can_shrink = true
            });
            Widget content = row.body;
            for (int content_kind = 0; content_kind < 2; content_kind++) {
                if (content_kind == 1) {
                    row.grid.remove(row.body);
                    row.grid.attach(preview, 2, 1, 1, 1);
                    content = preview;
                }
                foreach (Adw.ColorScheme scheme in new Adw.ColorScheme[] {
                    Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                    style.color_scheme = scheme;
                    foreach (TextDirection direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                        // Apply the locale-wide direction to the actual nested
                        // header widgets as well as the outer fixture grid.
                        Widget.set_default_direction(direction);
                        window.set_direction(direction);
                        row.grid.set_direction(direction);
                        content.set_direction(direction);
                        item.message.has_mention = false;
                        iterate_for(50);
                        Graphene.Rect before;
                        if (fail_if_not(content.compute_bounds(row.grid, out before),
                                "native body bounds must be allocated before enabling the mention")) continue;
                        item.message.has_mention = true;
                        iterate_for(50);
                        Graphene.Rect after;
                        Graphene.Rect marker_bounds;
                        fail_if_not(content.compute_bounds(row.grid, out after));
                        fail_if_not(row.marker.compute_bounds(row.grid, out marker_bounds));
                        fail_if(Math.fabs(before.origin.x - after.origin.x) > 0.5 ||
                                Math.fabs(before.size.width - after.size.width) > 0.5,
                            "enabling a header mention must not move or narrow text or media previews");
                        fail_if(marker_bounds.origin.y + marker_bounds.size.height > after.origin.y + 1,
                            "the plain @ belongs to metadata above the text, not in the avatar/body gutter");
                        foreach (string id in new string[] { "name_label", "time_label", "encrypted_image", "marked_image" }) {
                            Graphene.Rect bounds;
                            Widget metadata = (Widget) row.builder.get_object(id);
                            if (!metadata.compute_bounds(row.grid, out bounds)) continue;
                            Graphene.Rect intersection;
                            bool overlaps = marker_bounds.intersection(bounds, out intersection) &&
                                intersection.size.width > 0.5 && intersection.size.height > 0.5;
                            fail_if(overlaps, "the mention badge must not cover " + id);
                        }
                        fail_if_not_eq_str(_("You have been mentioned"), row.marker.tooltip_text ?? "",
                            "the native header marker must keep its translated tooltip");
                        double contrast = contrast_ratio(widget_color(row.marker),
                            widget_color(background_probe));
                        GLib.Test.message("mention contrast=%.2f theme=%s direction=%s content=%s",
                            contrast, style.dark ? "dark" : "light",
                            direction == TextDirection.RTL ? "RTL" : "LTR",
                            content_kind == 0 ? "text" : "preview");
                        fail_if(contrast < 4.5,
                            "the actual small header marker must provide at least 4.5:1 theme contrast");
                        if (Environment.get_variable("GTK_A11Y") == "test") {
                            string? error = check_message_mention_accessible_property(row.marker,
                                AccessibleProperty.LABEL, _("You have been mentioned"));
                            fail_if(error != null, error);
                        }
                    }
                }
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (row != null) row.close();
            window.destroy();
            iterate_for(20);
            style.color_scheme = original_scheme;
            Widget.set_default_direction(original_direction);
            remove_message_mention_style_provider(Gdk.Display.get_default(), color_probe_style);
            if (fixture != null) fixture.close();
        }
    }

    private void test_compact_header() {
        Fixture? fixture = null;
        TextDirection original_direction = Widget.get_default_direction();
        try {
            fixture = new Fixture();
            var item = fixture.add_message(fixture.room, "Alice, hello");
            item.message.has_mention = true;
            foreach (int width in new int[] { 360, 500, 1000 }) {
                foreach (TextDirection direction in new TextDirection[] {
                        TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    foreach (bool long_name in new bool[] { false, true }) {
                        Row? row = null;
                        var window = new Adw.Window();
                        try {
                            row = new Row(fixture, fixture.room, item);
                            var header = (Box) row.builder.get_object("header_box");
                            var name = (Label) row.builder.get_object("name_label");
                            name.label = long_name
                                ? "A participant with an exceptionally long display name which must fit every supported window size"
                                : "Sender";
                            ((Label) row.builder.get_object("time_label")).label = "Mi, 15:36";
                            var box = new Box(Orientation.VERTICAL, 0);
                            box.add_css_class("dino-conversation");
                            box.append(row.grid);
                            window.add_css_class("dino-main");
                            window.content = box;
                            window.set_direction(direction);
                            row.grid.set_direction(direction);
                            header.set_direction(direction);
                            window.set_default_size(width, 180);
                            row.body.label = "A short message";
                            window.present();
                            iterate_for(50);
                            Graphene.Rect short_header;
                            fail_if_not(header.compute_bounds(row.grid, out short_header));
                            var wide_body = new StringBuilder();
                            for (int repeat = 0; repeat < 12; repeat++) {
                                wide_body.append("A naturally wide body which wraps onto multiple lines. ");
                            }
                            row.body.label = wide_body.str;
                            iterate_for(50);
                            Graphene.Rect wide_header;
                            fail_if_not(header.compute_bounds(row.grid, out wide_header));
                            fail_if(Math.fabs(short_header.size.width - wide_header.size.width) > 0.5,
                                "message body width must not spread out its metadata group");
                            fail_if(window.get_width() > width,
                                "metadata must not force the window wider than its requested size");
                            fail_if(wide_header.origin.x < -0.5 ||
                                    wide_header.origin.x + wide_header.size.width > row.grid.get_width() + 0.5,
                                "the complete metadata group must fit the narrow allocated row");
                            fail_if_not(name.get_layout().is_ellipsized() == long_name,
                                "only overflowing participant names should be shortened");
                            Graphene.Rect previous = Graphene.Rect();
                            bool first = true;
                            foreach (string id in new string[] {
                                    "name_label", "time_label", "encrypted_image",
                                    "marked_image", "mention_indicator_label" }) {
                                Widget metadata = (Widget) row.builder.get_object(id);
                                Graphene.Rect bounds;
                                fail_if_not(metadata.compute_bounds(header, out bounds));
                                fail_if(bounds.origin.x < -0.5 ||
                                        bounds.origin.x + bounds.size.width > header.get_width() + 0.5,
                                    "all metadata must remain visible, including " + id);
                                if (!first) {
                                    double gap = direction == TextDirection.LTR
                                        ? bounds.origin.x - (previous.origin.x + previous.size.width)
                                        : previous.origin.x - (bounds.origin.x + bounds.size.width);
                                    fail_if(gap < -0.5 || gap > 7,
                                        "metadata widgets must stay adjacent in reading order: " + id);
                                }
                                previous = bounds;
                                first = false;
                            }
                        } finally {
                            if (row != null) row.close();
                            window.destroy();
                            iterate_for(10);
                        }
                    }
                }
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (fixture != null) fixture.close();
            Widget.set_default_direction(original_direction);
        }
    }

    private static Gdk.RGBA widget_color(Widget widget) {
#if GTK_4_12
        return widget.get_color();
#else
        return widget.get_style_context().get_color();
#endif
    }

    private static double linear_component(double component) {
        return component <= 0.04045 ? component / 12.92
            : Math.pow((component + 0.055) / 1.055, 2.4);
    }

    private static double luminance(Gdk.RGBA color) {
        return 0.2126 * linear_component(color.red) +
            0.7152 * linear_component(color.green) +
            0.0722 * linear_component(color.blue);
    }

    private static double contrast_ratio(Gdk.RGBA foreground, Gdk.RGBA background) {
        // GTK may expose a translucent theme foreground; compare the actual
        // composited glyph colour with the native view background.
        Gdk.RGBA composited = {
            (float) (foreground.red * foreground.alpha + background.red * (1 - foreground.alpha)),
            (float) (foreground.green * foreground.alpha + background.green * (1 - foreground.alpha)),
            (float) (foreground.blue * foreground.alpha + background.blue * (1 - foreground.alpha)),
            1
        };
        double fg = luminance(composited);
        double bg = luminance(background);
        return (double.max(fg, bg) + 0.05) / (double.min(fg, bg) + 0.05);
    }

    private static void drain() {
        MainContext context = MainContext.default();
        int iterations = 0;
        while (context.pending() && iterations++ < 1000) context.iteration(false);
    }

    private static void iterate_for(uint milliseconds) {
        int64 end = GLib.get_monotonic_time() + milliseconds * 1000;
        while (GLib.get_monotonic_time() < end) {
            drain();
            Thread.usleep(1000);
        }
        drain();
    }
}

}
