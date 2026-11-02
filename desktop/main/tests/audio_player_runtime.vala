using Dino.Entities;
using Dino.Security;
using Dino.Ui.ConversationSummary;
using Gtk;

namespace Dino.Ui.Test {

// Exercise the production GTK player. The fake output counts provider use;
// encrypted input and its asynchronous plaintext lease use the real core.
class AudioPlayerRuntimeTest : Gee.TestCase {
    private delegate bool Ready();
    private static bool chat_icon_path_added = false;

    public AudioPlayerRuntimeTest() {
        base("AudioPlayerRuntime");
        add_test("native_seek_actions_update_elapsed_total_and_keep_progress", test_seek_actions);
        add_test("unavailable_transfer_disables_play_and_seek", test_transfer_gate);
        add_test("drawing_callback_does_not_retain_unparented_player", test_widget_lifetime);
        add_test("unmap_during_plaintext_lease_never_opens_output", test_unmap_during_setup);
        add_test("decoded_audio_speed_pause_resume_and_unmap_use_fake_output", test_decoded_playback);
        add_test("rate_change_and_pause_during_preroll_never_deliver_pcm", test_pause_during_preroll);
        add_test("replay_and_seek_during_eos_drain_replace_finished_output", test_eos_drain);
        add_test("chat_grid_keeps_compact_controls_clear_of_message_actions", test_chat_layout);
        add_test("responsive_navigation_preserves_native_seek_accessibility", test_responsive_navigation);
    }

    private class OutputSession : Dino.Plugins.MediaMessagePlaybackSession {
        private Mutex mutex = Mutex();
        private bool running = false;
        private int pushes = 0;
        public int sample_rate = 0;
        public int stop_count = 0;
        public int finish_count = 0;
        public int flush_count = 0;
        public uint finish_delay_ms = 0;
        public int push_count {
            get { mutex.lock(); int value = pushes; mutex.unlock(); return value; }
        }
        public override bool active {
            get { mutex.lock(); bool value = running; mutex.unlock(); return value; }
        }
        public override void start(int sample_rate, int channels, int bytes_per_sample) throws Error {
            mutex.lock();
            this.sample_rate = sample_rate;
            running = true;
            mutex.unlock();
        }
        public override uint push_pcm(Bytes pcm_data) throws Error {
            mutex.lock();
            pushes++;
            mutex.unlock();
            return 0;
        }
        public override void set_paused(bool paused) throws Error { }
        public override void flush() throws Error { flush_count++; }
        public override uint finish() throws Error { finish_count++; return finish_delay_ms; }
        public override void stop() {
            mutex.lock();
            if (running) stop_count++;
            running = false;
            mutex.unlock();
        }
    }

    private class OutputProvider : Object, Dino.Plugins.MediaMessagePlaybackProvider {
        public string id { get { return "isolated-audio-player-output"; } }
        public bool available { get { return true; } }
        public string? unavailable_reason { owned get { return null; } }
        public int creations = 0;
        public uint finish_delay_ms = 0;
        public Gee.ArrayList<OutputSession> sessions = new Gee.ArrayList<OutputSession>();
        public Dino.Plugins.MediaMessagePlaybackSession create_audio_playback_session() throws Error {
            creations++;
            var session = new OutputSession();
            session.finish_delay_ms = finish_delay_ms;
            sessions.add(session);
            return session;
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
        public TestApplication(Database db, StreamInteractor interactor, FileEncryption encryption) {
            Object(application_id: "im.dinox.audio-player-runtime-test", flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "isolated audio player test";
            this.file_encryption = encryption;
            this.stream_interactor = interactor;
            this.settings = new Dino.Entities.Settings.from_db(db);
        }
        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    private static FileTransfer transfer(FileTransfer.Phase phase = FileTransfer.Phase.COMPLETE) {
        var file = new FileTransfer() {
            file_name = "voice.wav", mime_type = "audio/wav", size = 32044,
            direction = FileTransfer.DIRECTION_RECEIVED, provider = FileManager.SFS_PROVIDER_ID
        };
        file.set_transfer_phase(phase, phase == FileTransfer.Phase.FAILED ? "synthetic unavailable audio" : null);
        return file;
    }

    private static Scale seek_scale(Widget parent) {
        if (parent is Scale) return (Scale) parent;
        for (Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_scale((!) child);
            if (found != null) return found;
        }
        assert_not_reached();
    }

    private static Scale? find_scale(Widget parent) {
        if (parent is Scale) return (Scale) parent;
        for (Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_scale((!) child);
            if (found != null) return found;
        }
        return null;
    }

    private static Label? find_label(Widget parent, string text) {
        if (parent is Label && ((Label) parent).label == text) return (Label) parent;
        for (Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_label((!) child, text);
            if (found != null) return found;
        }
        return null;
    }

    private static Button play_button(AudioPlayerWidget player) {
        return (Button) player.get_first_child().get_first_child();
    }

    private static CheckButton speed_option(AudioPlayerWidget player, int index) {
        var menu = (MenuButton) player.get_first_child().get_last_child();
        Widget? option = menu.popover.get_child().get_first_child().get_next_sibling();
        for (int i = 0; i < index; i++) option = option.get_next_sibling();
        return (CheckButton) option;
    }

    private static string ui_resource_text(string path) throws Error {
        var data = resources_lookup_data(path, ResourceLookupFlags.NONE);
        var text = new StringBuilder();
        text.append_len((string) data.get_data(), (ssize_t) data.get_size());
        return text.str;
    }

    private static Widget chat_embedding(AudioPlayerWidget player, out Box actions,
                                         bool show_header = true, string sender = "Ich") throws Error {
        if (!chat_icon_path_added) {
            IconTheme.get_for_display(Gdk.Display.get_default()).add_resource_path("/im/dinox/dinox/icons");
            chat_icon_path_added = true;
        }
        // Load the production grid, replacing only the account-aware avatar
        // widget. The player occupies the skeleton's actual four-column span.
        string grid_xml = ui_resource_text("/im/dinox/dinox/conversation_item_widget.ui");
        var grid_builder = new Builder.from_string(grid_xml.replace("DinoUiAvatarPicture", "GtkImage"), -1);
        var grid = (Grid) grid_builder.get_object("main_grid");
        grid.add_css_class("message-box");
        grid.hexpand = true;
        var avatar = (Image) grid_builder.get_object("avatar_picture");
        avatar.icon_name = "avatar-default-symbolic";
        avatar.pixel_size = 35;
        ((Label) grid_builder.get_object("name_label")).label = sender;
        ((Label) grid_builder.get_object("time_label")).label = "17:59";
        ((Image) grid_builder.get_object("encrypted_image")).icon_name = "changes-prevent-symbolic";
        ((Image) grid_builder.get_object("marked_image")).icon_name = "emblem-ok-symbolic";
        string[] header_ids = { "avatar_picture", "name_label", "time_label", "encrypted_image", "marked_image" };
        foreach (string id in header_ids) ((Widget) grid_builder.get_object(id)).visible = show_header;
        if (show_header) grid.add_css_class("has-skeleton");
        player.valign = Align.END;
        grid.attach(player, 2, 1, 4, 1);

        // The production view owns this empty overlay toolbar and fills it
        // with the sender and message action widgets at runtime.
        string view_xml = ui_resource_text("/im/dinox/dinox/conversation_content_view/view.ui");
        int begin = view_xml.index_of("<object class=\"GtkBox\" id=\"message_menu_box\">");
        int end = view_xml.index_of("</object>", begin);
        if (begin < 0 || end < begin) throw new IOError.INVALID_DATA("Production message toolbar was not found");
        string toolbar_xml = "<interface>" + view_xml.substring(begin, end - begin + 9) + "</interface>";
        var toolbar_builder = new Builder.from_string(toolbar_xml, -1);
        actions = (Box) toolbar_builder.get_object("message_menu_box");
        actions.visible = true;
        var target = new Label(sender + ":") {
            ellipsize = Pango.EllipsizeMode.END, max_width_chars = 12,
            margin_start = 6, margin_end = 2, valign = Align.CENTER
        };
        target.add_css_class("caption");
        target.add_css_class("message-action-target-label");
        actions.append(target);
        var reaction = new MenuButton() { icon_name = "dino-emoticon-add-symbolic", name = "reaction" };
        Dino.Ui.Util.set_menu_button_popover(reaction, new Popover() { child = new Label("Reactions") });
        reaction.add_css_class("message-action-button");
        actions.append(reaction);
        var reply = new Button.from_icon_name("mail-reply-sender-symbolic") { name = "reply" };
        reply.add_css_class("message-action-button");
        actions.append(reply);
        var delete_button = new Button.from_icon_name("user-trash-symbolic") { name = "delete" };
        delete_button.add_css_class("message-action-button");
        actions.append(delete_button);
        var overlay = new Overlay() { hexpand = true, valign = Align.START };
        overlay.set_child(grid);
        overlay.add_overlay(actions);
        var chat = new Box(Orientation.VERTICAL, 0);
        chat.add_css_class("dino-conversation");
        chat.append(overlay);
        return chat;
    }

    private static void position_chat_actions(Widget chat, Box actions) {
        var overlay = (Overlay) chat.get_first_child();
        Graphene.Rect row_bounds;
        assert(overlay.get_child().compute_bounds(overlay, out row_bounds));
        // ConversationView anchors the actions to the allocated row, including
        // the header row's CSS margin, rather than to the viewport origin.
        actions.margin_top = (int) row_bounds.origin.y;
    }

    private static Graphene.Rect widget_bounds(Widget widget, Widget ancestor) {
        Graphene.Rect bounds;
        assert(widget.compute_bounds(ancestor, out bounds));
        return bounds;
    }

    private static bool overlaps(Graphene.Rect a, Graphene.Rect b) {
        return a.origin.x + a.size.width > b.origin.x + 0.5 &&
            b.origin.x + b.size.width > a.origin.x + 0.5 &&
            a.origin.y + a.size.height > b.origin.y + 0.5 &&
            b.origin.y + b.size.height > a.origin.y + 0.5;
    }

    private static bool fits_inside(Graphene.Rect child, Graphene.Rect parent) {
        return child.origin.x >= parent.origin.x - 0.5 && child.origin.y >= parent.origin.y - 0.5 &&
            child.origin.x + child.size.width <= parent.origin.x + parent.size.width + 0.5 &&
            child.origin.y + child.size.height <= parent.origin.y + parent.size.height + 0.5;
    }

    private void test_chat_layout() {
        TextDirection original_direction = Widget.get_default_direction();
        int[] widths = { 1080, 720, 500, 360 };
        try {
            foreach (int width in widths) {
                foreach (bool rtl in new bool[] { false, true }) {
                    Widget.set_default_direction(rtl ? TextDirection.RTL : TextDirection.LTR);
                    foreach (bool header in new bool[] { true, false }) {
                        var window = new Window() {
                            title = "DinoX chat audio layout fixture", default_width = width,
                            default_height = 180, decorated = false
                        };
                        window.add_css_class("dino-main");
                        AudioPlayerWidget? player = new AudioPlayerWidget(transfer());
                        player.update_timeline(17 * Gst.SECOND, 3 * Gst.SECOND);
                        Box actions;
                        string sender = width == 500 ? "A very long sender name that must ellipsize" : "Ich";
                        Widget chat = chat_embedding((!) player, out actions, header, sender);
                        window.set_child(chat);
                        window.present();
                        wait_for(() => ((!) player).get_mapped() && ((!) player).get_width() > 0,
                            "embedded chat player must be allocated");
                        position_chat_actions(chat, actions);
                        iterate_for(40);
                        Graphene.Rect player_rect = widget_bounds((!) player, window);
                        Graphene.Rect actions_rect = widget_bounds(actions, window);
                        string context = "%dpx %s %s".printf(width, rtl ? "RTL" : "LTR", header ? "header" : "grouped");
                        GLib.Test.message("%s: window=%d player=(%.1f,%.1f %.1fx%.1f) actions=(%.1f,%.1f %.1fx%.1f)",
                            context, window.get_width(), player_rect.origin.x, player_rect.origin.y,
                            player_rect.size.width, player_rect.size.height, actions_rect.origin.x,
                            actions_rect.origin.y, actions_rect.size.width, actions_rect.size.height);
                        fail_if(window.get_width() > width + 1, context + ": chat minimum width must fit the requested window");
                        fail_if(player_rect.size.width > 380, context + ": audio player must remain compact in a wide chat");
                        var controls = (Box) player.get_first_child();
                        var time = (Label) controls.get_last_child().get_prev_sibling();
                        Widget[] checked = { play_button((!) player), seek_scale((!) player), time, controls.get_last_child() };
                        foreach (Widget control in checked) {
                            var rect = widget_bounds(control, window);
                            fail_if_not(fits_inside(rect, player_rect), context + ": control must stay inside the audio message");
                            fail_if(overlaps(rect, actions_rect), context + ": message actions collide with audio control " + control.get_type().name());
                        }
                        fail_if(play_button((!) player).get_width() > 34 || play_button((!) player).get_height() > 34,
                            context + ": play circle must remain at the 32px CSS size plus its border");
                        // Gtk.Scale.get_width() excludes its horizontal CSS
                        // padding; the allocated seek control includes it.
                        var seek_rect = widget_bounds(seek_scale((!) player), window);
                        GLib.Test.message("%s: seek content=%d allocated=%.1f", context,
                            seek_scale((!) player).get_width(), seek_rect.size.width);
                        fail_if(seek_rect.size.width < 96, context + ": seek area must retain its readable minimum");
                        int text_width, text_height;
                        time.get_layout().get_pixel_size(out text_width, out text_height);
                        fail_if(time.get_width() < text_width || time.get_height() < text_height,
                            context + ": elapsed/total text must not clip");
                        foreach (Widget left in checked) {
                            foreach (Widget right in checked) {
                                if (left != right) fail_if(overlaps(widget_bounds(left, window), widget_bounds(right, window)),
                                    context + ": player controls must not overlap");
                            }
                        }
                        string? screenshot_width = Environment.get_variable("DINOX_AUDIO_PLAYER_CHAT_SCREENSHOT_WIDTH");
                        bool screenshot_rtl = Environment.get_variable("DINOX_AUDIO_PLAYER_CHAT_SCREENSHOT_RTL") == "1";
                        bool screenshot_grouped = Environment.get_variable("DINOX_AUDIO_PLAYER_CHAT_SCREENSHOT_GROUPED") == "1";
                        if (Environment.get_variable("DINOX_AUDIO_PLAYER_CHAT_SCREENSHOT_HOLD") == "1" &&
                            width.to_string() == (screenshot_width ?? "720") && rtl == screenshot_rtl && header != screenshot_grouped) {
                            GLib.Test.message("Chat screenshot fixture ready: %s", context);
                            iterate_for(15000);
                        }
                        window.set_child(null);
                        window.destroy();
                        window.dispose();
                        player = null;
                        iterate_for(20);
                    }
                }
            }
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            Widget.set_default_direction(original_direction);
        }
    }

    private void test_responsive_navigation() {
        var window = new Adw.Window() {
            default_width = 1080, default_height = 220,
            width_request = 500, height_request = 160
        };
        // Resize the chat viewport itself. GTK's Windows backend can retain a
        // mapped toplevel's size after set_default_size(), even for an empty
        // window, so it cannot drive this navigation lifecycle fixture.
        var viewport = new SizingBin() { max_width = 1080 };
        var breakpoint_bin = new Adw.BreakpointBin() { width_request = 500, height_request = 160 };
        try {
            var player = new AudioPlayerWidget(transfer());
            player.update_timeline(17 * Gst.SECOND, 3 * Gst.SECOND);
            var content = new Adw.ToolbarView() { content = player };
            content.add_top_bar(new Adw.HeaderBar());
            var split = new Adw.NavigationSplitView() {
                sidebar = new Adw.NavigationPage(new Label("Contacts"), "Contacts"),
                content = new Adw.NavigationPage(content, "Chat"),
                show_content = true
            };
            breakpoint_bin.child = split;
            breakpoint_bin.set_parent(viewport);
            window.content = viewport;
            var breakpoint = new Adw.Breakpoint(Adw.BreakpointCondition.parse("max-width: 860sp"));
            breakpoint.add_setter(split, "collapsed", true);
            breakpoint_bin.add_breakpoint(breakpoint);
            window.present();
            wait_for(() => player.get_mapped() && !split.collapsed, "wide audio chat must map");
            iterate_for(80);
            var scale = seek_scale(player);
#if GTK_4_12
            if (Environment.get_variable("GTK_A11Y") == "test") {
                fail_if(((Accessible) scale).get_at_context() == null,
                    "accessibility regression run must have an active AT context");
            }
#endif
            for (int i = 0; i < 3; i++) {
                viewport.max_width = 500;
                viewport.queue_resize();
                try {
                    wait_for(() => split.collapsed && player.get_mapped(), "narrow audio chat must remain visible");
                } catch (Error error) {
                    GLib.Test.message("Navigation resize: viewport=%d collapsed=%s show-content=%s player-mapped=%s",
                        breakpoint_bin.get_width(), split.collapsed.to_string(), split.show_content.to_string(), player.get_mapped().to_string());
                    throw error;
                }
                iterate_for(80);
                fail_if_not(split.show_content, "collapse must preserve the open chat");
                // With GTK_A11Y=none GTK has no AT context and reports GENERIC.
                // The enabled accessibility runs must retain the native role.
                if (Environment.get_variable("GTK_A11Y") != "none") {
                    fail_if_not(scale.get_accessible_role() == AccessibleRole.SLIDER,
                        "reparented seek control must retain GTK's native slider role");
                }
                fail_if(scale.get_value() != 3, "resize must preserve the seek position");

                // Native Back changes navigation without discarding the chat.
                split.show_content = false;
                wait_for(() => !player.get_mapped(), "Back must display the sidebar");
                iterate_for(80);
                viewport.max_width = 1080;
                viewport.queue_resize();
                wait_for(() => !split.collapsed && player.get_mapped(), "expanded chat must map again");
                iterate_for(80);
                fail_if(split.show_content, "expanding must not overwrite the Back selection");
                viewport.max_width = 500;
                viewport.queue_resize();
                wait_for(() => split.collapsed && !player.get_mapped(), "collapse after Back must retain the sidebar");
                iterate_for(80);
                split.show_content = true;
                wait_for(() => player.get_mapped(), "opening the current chat must remap its existing player");
                iterate_for(80);
                viewport.max_width = 1080;
                viewport.queue_resize();
                wait_for(() => !split.collapsed, "window must expand for the next resize cycle");
                iterate_for(80);
            }
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            window.content = null;
            window.destroy();
            window.dispose();
            iterate_for(20);
        }
    }

    private void test_seek_actions() {
        // Unmapped GTK controls exercise native range actions without starting
        // a decoder/output. update_timeline is also used by production queries.
        var player = new AudioPlayerWidget(transfer());
        player.update_timeline(17 * Gst.SECOND, 3 * Gst.SECOND);
        var scale = seek_scale(player);
        if (Environment.get_variable("GTK_A11Y") != "none") {
            fail_if_not(scale.get_accessible_role() == AccessibleRole.SLIDER,
                "seek control must expose the native slider role");
        }
        fail_if_not(scale.sensitive, "completed audio with known duration must enable seeking");
        fail_if_not(find_label(player, "0:03/0:17") != null, "elapsed and total must be shown together");
        fail_if(scale.get_value() != 3, "native range must represent elapsed seconds");

        scale.move_slider(ScrollType.STEP_FORWARD);
        fail_if(scale.get_value() != 4, "native forward action must advance one second");
        fail_if_not(find_label(player, "0:04/0:17") != null, "keyboard action must update elapsed text");
        scale.move_slider(ScrollType.END);
        fail_if(scale.get_value() != 17, "End must seek to the duration");
        scale.move_slider(ScrollType.START);
        fail_if(scale.get_value() != 0, "Home must seek to zero");

        TextDirection previous_direction = Widget.get_default_direction();
        try {
            // GTK widgets with direction NONE use the locale's global
            // direction; a local container direction is not inherited.
            Widget.set_default_direction(TextDirection.RTL);
            fail_if_not(scale.get_flippable(), "native slider must follow RTL layout");
            fail_if_not(scale.get_direction() == TextDirection.RTL, "seek scale must follow the RTL locale direction");
        } finally {
            Widget.set_default_direction(previous_direction);
        }
        player.update_timeline(17 * Gst.SECOND, 3 * Gst.SECOND);
        player.queue_draw();
        drain_main_context();
        fail_if(scale.get_value() != 3, "repaint must preserve the playback position");
        player.update_timeline(17 * Gst.SECOND, 22 * Gst.SECOND);
        fail_if_not(find_label(player, "0:17/0:17") != null, "position must clamp to the duration");
    }

    private void test_transfer_gate() {
        var file = transfer();
        var player = new AudioPlayerWidget(file);
        player.update_timeline(17 * Gst.SECOND, 3 * Gst.SECOND);
        file.set_transfer_phase(FileTransfer.Phase.FAILED, "synthetic unavailable audio");
        fail_if(play_button(player).sensitive, "failed audio must disable playback");
        fail_if(seek_scale(player).sensitive, "failed audio must disable seek and plaintext release");
        fail_if_not(find_label(player, "0:00/0:17") != null, "failed transfer must reset active progress");
    }

    private void test_widget_lifetime() {
        // No dispose() call: the draw callback must not form child -> player
        // -> child ownership, including after an actual GTK drawing pass.
        AudioPlayerWidget? player = new AudioPlayerWidget(transfer(FileTransfer.Phase.FAILED));
        var weak_player = WeakRef(player);
        var window = new Window();
        window.set_child(player);
        window.present();
        iterate_for(40);
        window.set_child(null);
        window.destroy();
        window.dispose();
        player = null;
        iterate_for(40);
        fail_if(weak_player.get() != null, "unparented audio player must be released without manual dispose");
    }

    private void test_unmap_during_setup() {
        Database? db = null;
        TestApplication? app = null;
        string? source_path = null;
        AudioPlayerWidget? player = null;
        var window = new Window();
        GLib.Application? previous_app = GLib.Application.get_default();
        try {
            db = new Database(":memory:", "isolated audio player test");
            var interactor = new StreamInteractor.for_tests((!) db);
            var encryption = new FileEncryption("isolated audio player test");
            FileManager.start(interactor, (!) db, encryption);
            app = new TestApplication((!) db, interactor, encryption);
            var provider = new OutputProvider();
            app.plugin_registry.media_message_playback_provider = provider;
            GLib.Application.set_default(app);
            string source_name = "audio-player-" + Uuid.string_random() + ".enc";
            source_path = Path.build_filename(FileManager.get_storage_dir(), source_name);
            DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);
            FileUtils.set_data((!) source_path, encryption.encrypt_data(wav_fixture()));
            var file = transfer();
            file.path = source_name;
            player = new AudioPlayerWidget(file);
            var weak_player = WeakRef(player);
            window.set_child(player);
            window.present();
            wait_for(() => ((!) player).get_mapped(), "audio player must map before the start action");

            play_button((!) player).clicked();
            // Real decrypt_file_to_stream yields to its worker; remove the
            // view before allowing the main-loop continuation to run.
            window.set_child(null);
            window.destroy();
            window.dispose();
            player = null;
            wait_for(() => weak_player.get() == null,
                "cancelled async setup must finish and release the player");
            fail_if_not_eq_int(0, provider.creations,
                "a decrypted continuation after unmap must never create native speaker output");
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            if (player != null) {
                window.set_child(null);
                window.destroy();
                window.dispose();
                player = null;
                iterate_for(40);
            }
            GLib.Application.set_default(previous_app);
            if (db != null) db.close();
            if (source_path != null) FileUtils.remove((!) source_path);
        }
    }

    private void test_decoded_playback() {
        Database? db = null;
        string? source_path = null;
        AudioPlayerWidget? player = null;
        var window = new Window() { title = "DinoX audio player fixture", default_width = 520, default_height = 160 };
        GLib.Application? previous_app = GLib.Application.get_default();
        try {
            db = new Database(":memory:", "isolated audio playback integration test");
            var interactor = new StreamInteractor.for_tests((!) db);
            var encryption = new FileEncryption("isolated audio playback integration test");
            FileManager.start(interactor, (!) db, encryption);
            var app = new TestApplication((!) db, interactor, encryption);
            var provider = new OutputProvider();
            app.plugin_registry.media_message_playback_provider = provider;
            GLib.Application.set_default(app);
            string source_name = "audio-playback-" + Uuid.string_random() + ".enc";
            source_path = Path.build_filename(FileManager.get_storage_dir(), source_name);
            DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);
            uint8[] wav = wav_fixture(17);
            FileUtils.set_data((!) source_path, encryption.encrypt_data(wav));
            var file = transfer();
            file.path = source_name;
            file.size = wav.length;
            player = new AudioPlayerWidget(file);
            var weak_player = WeakRef(player);
            window.set_child(player);
            window.present();
            wait_for(() => ((!) player).get_mapped(), "audio integration fixture must map");

            speed_option((!) player, 2).active = true;
            fail_if_not_eq_int(0, provider.creations, "speed selection before playback must not open output");
            play_button((!) player).clicked();
            wait_for(() => provider.sessions.size == 1 && provider.sessions[0].push_count > 0 && seek_scale((!) player).sensitive,
                "real WAV decoding must deliver PCM to the fake output and discover duration");
            fail_if_not_eq_int(96000, provider.sessions[0].sample_rate,
                "2x menu selection must accelerate the WebRTC source clock");
            fail_if(Math.fabs(seek_scale((!) player).adjustment.upper - 17) > 0.01,
                "real decoder duration must drive the seek range");
            seek_scale((!) player).set_value(3);
            int64 sought_position = -1;
            wait_for(() => ((!) player).query_playback_position(out sought_position),
                "native seek must finish before sampling the real position");
            fail_if(sought_position < 3 * Gst.SECOND,
                "accepted native seek must move the decoder to three seconds");
            play_button((!) player).clicked();
            fail_if(provider.sessions[0].active, "pause must stop the native output session");
            fail_if_not_eq_int(1, provider.sessions[0].stop_count, "pause must stop each output session exactly once");
            double paused_position = seek_scale((!) player).get_value();
            fail_if(paused_position < 2.5, "pause must retain the real seek position");

            speed_option((!) player, 1).active = true;
            iterate_for(30);
            fail_if_not_eq_int(1, provider.creations, "changing speed while paused must not restart playback");
            fail_if(seek_scale((!) player).get_value() != paused_position, "paused speed change must preserve position");
            play_button((!) player).clicked();
            int64 resumed_position = -1;
            wait_for(() => provider.sessions.size == 2 && provider.sessions[1].push_count > 0 &&
                ((!) player).query_playback_position(out resumed_position),
                "resume must decode again into a fresh fake output session");
            fail_if_not_eq_int(72000, provider.sessions[1].sample_rate,
                "1.5x menu selection must apply on resume");
            fail_if(resumed_position < (int64) (paused_position * Gst.SECOND) - 10 * Gst.MSECOND,
                "the real decoder position on resume must preserve the saved position");

            // Local screenshot support belongs only to this isolated test.
            // Run a named test with the hold variable, then capture its window
            // using xdotool/ImageMagick under the same DISPLAY.
            if (Environment.get_variable("DINOX_AUDIO_PLAYER_TEST_SCREENSHOT_HOLD") == "1") {
                play_button((!) player).clicked();
                GLib.Test.message("Screenshot fixture ready: DinoX audio player fixture");
                iterate_for(15000);
            }

            window.set_child(null);
            fail_if(provider.sessions[1].active, "unmap must stop the current output session");
            fail_if_not_eq_int(1, provider.sessions[1].stop_count, "unmap must stop the resumed session exactly once");
            window.destroy();
            window.dispose();
            player = null;
            wait_for(() => weak_player.get() == null, "decoded player must release all sources and child callbacks");
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            if (player != null) {
                window.set_child(null);
                window.destroy();
                window.dispose();
                player = null;
                iterate_for(40);
            }
            GLib.Application.set_default(previous_app);
            if (db != null) db.close();
            if (source_path != null) FileUtils.remove((!) source_path);
        }
    }

    private void test_pause_during_preroll() {
        Database? db = null;
        string? source_path = null;
        AudioPlayerWidget? player = null;
        var window = new Window();
        GLib.Application? previous_app = GLib.Application.get_default();
        try {
            db = new Database(":memory:", "isolated audio preroll cancellation test");
            var interactor = new StreamInteractor.for_tests((!) db);
            var encryption = new FileEncryption("isolated audio preroll cancellation test");
            FileManager.start(interactor, (!) db, encryption);
            var app = new TestApplication((!) db, interactor, encryption);
            var provider = new OutputProvider();
            app.plugin_registry.media_message_playback_provider = provider;
            GLib.Application.set_default(app);
            string source_name = "audio-preroll-" + Uuid.string_random() + ".enc";
            source_path = Path.build_filename(FileManager.get_storage_dir(), source_name);
            DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);
            uint8[] wav = wav_fixture(17);
            FileUtils.set_data((!) source_path, encryption.encrypt_data(wav));
            var file = transfer();
            file.path = source_name;
            file.size = wav.length;
            player = new AudioPlayerWidget(file);
            var weak_player = WeakRef(player);
            player.update_timeline(17 * Gst.SECOND, 0);
            // Queue a real slider request before mapping; playback starts only
            // after the user action in the mapped view.
            seek_scale((!) player).set_value(3);
            window.set_child(player);
            window.present();
            wait_for(() => ((!) player).get_mapped(), "preroll cancellation fixture must map");
            play_button((!) player).clicked();

            // Dispatch one main-context turn at a time. The decrypt callback
            // creates the real PAUSED pipeline and installs its bus watch;
            // ASYNC_DONE cannot dispatch until the following context turn.
            var context = MainContext.default();
            int64 deadline = get_monotonic_time() + 4000000;
            while (provider.creations == 0) {
                if (get_monotonic_time() >= deadline) throw new IOError.TIMED_OUT("real preroll must start");
                if (context.pending()) context.iteration(false);
                else Thread.usleep(1000);
            }
            fail_if_not_eq_int(0, provider.sessions[0].push_count,
                "PAUSED preroll must not deliver playback PCM");
            int64 position;
            fail_if(player.query_playback_position(out position),
                "real playback time must not be accepted before preroll/seek completion");

            speed_option((!) player, 2).active = true;
            fail_if_not_eq_int(2, provider.creations,
                "rate change during preroll must replace the already-created bridge");
            fail_if_not_eq_int(1, provider.sessions[0].stop_count,
                "replacing preroll output must stop the old source clock");
            fail_if_not_eq_int(96000, provider.sessions[1].sample_rate,
                "replacement preroll bridge must use the latest playback rate");
            play_button((!) player).clicked();
            fail_if_not(find_label((!) player, "0:03/0:17") != null,
                "early pause must retain the requested resume position");
            iterate_for(100);
            fail_if_not_eq_int(0, provider.sessions[0].push_count,
                "invalidated old preroll must never later deliver PCM");
            fail_if_not_eq_int(0, provider.sessions[1].push_count,
                "cancelled new preroll must never later deliver PCM");
            fail_if_not_eq_int(1, provider.sessions[1].stop_count,
                "early pause must stop the pending output exactly once");
            fail_if_not_eq_int(2, provider.creations,
                "a cancelled ASYNC_DONE must not restart an output session");
            window.set_child(null);
            window.destroy();
            window.dispose();
            player = null;
            wait_for(() => weak_player.get() == null,
                "cancelled preroll must release the actual widget and sources");
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            if (player != null) {
                window.set_child(null);
                window.destroy();
                window.dispose();
                player = null;
                iterate_for(40);
            }
            GLib.Application.set_default(previous_app);
            if (db != null) db.close();
            if (source_path != null) FileUtils.remove((!) source_path);
        }
    }

    private void test_eos_drain() {
        Database? db = null;
        string? source_path = null;
        AudioPlayerWidget? player = null;
        var window = new Window();
        GLib.Application? previous_app = GLib.Application.get_default();
        try {
            db = new Database(":memory:", "isolated audio eos drain test");
            var interactor = new StreamInteractor.for_tests((!) db);
            var encryption = new FileEncryption("isolated audio eos drain test");
            FileManager.start(interactor, (!) db, encryption);
            var app = new TestApplication((!) db, interactor, encryption);
            var provider = new OutputProvider() { finish_delay_ms = 400 };
            app.plugin_registry.media_message_playback_provider = provider;
            GLib.Application.set_default(app);
            string source_name = "audio-eos-" + Uuid.string_random() + ".enc";
            source_path = Path.build_filename(FileManager.get_storage_dir(), source_name);
            DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);
            uint8[] wav = wav_fixture();
            FileUtils.set_data((!) source_path, encryption.encrypt_data(wav));
            var file = transfer();
            file.path = source_name;
            file.size = wav.length;
            player = new AudioPlayerWidget(file);
            var weak_player = WeakRef(player);
            window.set_child(player);
            window.present();
            wait_for(() => ((!) player).get_mapped(), "EOS fixture must map");
            play_button((!) player).clicked();
            wait_for(() => provider.sessions.size == 1 && provider.sessions[0].finish_count == 1,
                "actual decoder EOS must start the simulated output drain");
            fail_if_not(provider.sessions[0].active, "fixture must still own output during the drain");

            play_button((!) player).clicked();
            int64 position = -1;
            wait_for(() => provider.sessions.size == 2 && provider.sessions[1].push_count > 0 &&
                ((!) player).query_playback_position(out position),
                "replay during drain must start a fresh real decoder");
            fail_if_not_eq_int(1, provider.sessions[0].stop_count,
                "replay must release the finished session exactly once");
            fail_if(position >= Gst.SECOND, "replay must restart the actual decoder at the beginning");

            wait_for(() => provider.sessions[1].finish_count == 1,
                "replayed decoder must reach its next EOS drain");
            seek_scale((!) player).set_value(0.5);
            wait_for(() => provider.sessions.size == 3 && provider.sessions[2].push_count > 0 &&
                ((!) player).query_playback_position(out position),
                "seek during drain must use a fresh decoder/output session");
            fail_if(position < 500 * Gst.MSECOND || position >= 1200 * Gst.MSECOND,
                "new decoder must start at the requested half-second seek");
            fail_if_not_eq_int(1, provider.sessions[1].stop_count,
                "seek must release the finished session exactly once");
            fail_if_not_eq_int(0, provider.sessions[1].flush_count,
                "seeking during drain must never flush a finished bridge");
            window.set_child(null);
            window.destroy();
            window.dispose();
            player = null;
            wait_for(() => weak_player.get() == null, "EOS replay/seek fixture must release the player");
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            if (player != null) {
                window.set_child(null);
                window.destroy();
                window.dispose();
                player = null;
                iterate_for(40);
            }
            GLib.Application.set_default(previous_app);
            if (db != null) db.close();
            if (source_path != null) FileUtils.remove((!) source_path);
        }
    }

    private static uint8[] wav_fixture(int seconds = 2) {
        // 16-bit mono PCM, 8 kHz, with a changing envelope for a real waveform.
        uint32 pcm_size = (uint32) (seconds * 8000 * 2);
        uint8[] data = new uint8[pcm_size + 44];
        string header = "RIFF";
        for (int i = 0; i < 4; i++) data[i] = header[i];
        uint32 riff_size = pcm_size + 36;
        for (int i = 0; i < 4; i++) data[4 + i] = (uint8) (riff_size >> (8 * i));
        string format = "WAVEfmt ";
        for (int i = 0; i < 8; i++) data[8 + i] = format[i];
        data[16] = 16; data[20] = 1; data[22] = 1;
        data[24] = 0x40; data[25] = 0x1f;
        data[28] = 0x80; data[29] = 0x3e;
        data[32] = 2; data[34] = 16;
        string chunk = "data";
        for (int i = 0; i < 4; i++) data[36 + i] = chunk[i];
        for (int i = 0; i < 4; i++) data[40 + i] = (uint8) (pcm_size >> (8 * i));
        for (int i = 0; i < seconds * 8000; i++) {
            double t = (double) i / 8000;
            double envelope = 0.05 + 0.65 * Math.pow(Math.fabs(Math.sin(t * 0.55)), 2);
            if (Math.fmod(t, 4.0) > 3.25) envelope = 0;
            int16 sample = (int16) (18000 * envelope * Math.sin(2 * Math.PI * 440 * t));
            data[44 + 2 * i] = (uint8) sample;
            data[45 + 2 * i] = (uint8) (sample >> 8);
        }
        return data;
    }

    private static void drain_main_context() {
        var context = MainContext.default();
        while (context.pending()) context.iteration(false);
    }

    private static void wait_for(Ready ready, string reason, uint timeout_ms = 4000) throws Error {
        int64 deadline = get_monotonic_time() + timeout_ms * 1000;
        while (!ready()) {
            if (get_monotonic_time() >= deadline) throw new IOError.TIMED_OUT(reason);
            drain_main_context();
            Thread.usleep(1000);
        }
    }

    private static void iterate_for(uint duration_ms) {
        int64 deadline = get_monotonic_time() + duration_ms * 1000;
        while (get_monotonic_time() < deadline) {
            drain_main_context();
            Thread.usleep(1000);
        }
    }
}

}
