using Gee;
using GLib;
using Gtk;
using Xmpp;
using Xmpp.Xep;

using Dino.Entities;

namespace Dino.Ui.Test {

class FileDefaultWidgetRuntimeTest : Gee.TestCase {

    private class ActionCounts : Object {
        public int open;
        public int download;
        public int cancel;
        public bool has_menu;
        public bool has_transfer_action;
        public string? transfer_action_name;
        public string? transfer_action_label;
        public string? mime_label;
    }

    public FileDefaultWidgetRuntimeTest() {
        base("FileDefaultWidgetRuntime");

        add_test("Gate4_incomplete_transfers_never_route_clicked_signal_to_open_action", test_incomplete_transfers_never_route_clicked_signal_to_open_action);
        add_test("Gate4_complete_transfer_routes_clicked_signal_to_open_action", test_complete_transfer_routes_clicked_signal_to_open_action);
        add_test("Gate4_download_action_requires_usable_received_source", test_download_action_requires_usable_received_source);
        add_test("Gate4_empty_media_failure_text_asks_for_resend", test_empty_media_failure_text_asks_for_resend);
        add_test("private_recipient_change_requires_explicit_file_selection", test_recipient_change);
        add_test("file_context_copies_source_before_download_and_shows_metadata", test_file_context);
        add_test("native_right_click_opens_file_menu_before_and_after_download", test_pointer_context);
        add_test("standalone_audio_and_video_players_expose_file_context", test_media_context);
        add_test("visible_cancel_button_routes_active_transfer_to_cancel", test_cancel_button);
        add_test("uppercase_mime_selects_media_player_in_system_locale", test_mime_locale);
    }

    private void test_mime_locale() {
        foreach (bool video in new bool[] { true, false }) {
            var transfer = create_transfer(FileTransfer.Phase.COMPLETE);
            transfer.file_name = "opaque-upload";
            transfer.mime_type = video ? "VIDEO/MP4" : "AUDIO/OGG";
            transfer.size = 0; // Classification only; never start a decoder.
            var widget = new FileWidget(transfer);
            try {
                fail_if_not(video ? widget.get_first_child() is ConversationSummary.VideoPlayerWidget :
                    widget.get_first_child() is ConversationSummary.AudioPlayerWidget,
                    "technical MIME case must select the same player in every system locale");
            } finally {
                widget.dispose();
            }
        }
    }

    private void test_media_context() {
        foreach (bool video in new bool[] { true, false }) {
            var transfer = create_transfer(FileTransfer.Phase.NONE);
            transfer.mime_type = video ? "video/mp4" : "audio/ogg";
            transfer.file_name = video ? "clip.mp4" : "voice.ogg";
            // No payload is needed for testing the source menu, and an empty
            // completed file must not start a decoder in this UI fixture.
            transfer.size = 0;
            add_usable_sfs_source(transfer);
            Widget player = video ? (Widget) new ConversationSummary.VideoPlayerWidget(transfer) :
                (Widget) new ConversationSummary.AudioPlayerWidget(transfer);
            var window = new Window() { title = "DinoX media file menu runtime", child = player,
                default_width = 460, default_height = 240 };
            try {
                window.present();
                settle_file_menu();
                foreach (var phase in new FileTransfer.Phase[] { FileTransfer.Phase.NONE, FileTransfer.Phase.COMPLETE }) {
                    transfer.set_transfer_phase(phase);
                    settle_file_menu();
#if !WINDOWS
                    if (Environment.get_variable("DINOX_TEST_NATIVE_KEYS") == "1") {
                        Graphene.Rect bounds;
                        fail_if_not(player.compute_bounds(window, out bounds));
                        string[] argv = { "xdotool", "search", "--name", "^DinoX media file menu runtime$",
                            "windowfocus", "--sync", "mousemove", "--window", "%1",
                            ((int) (bounds.origin.x + bounds.size.width / 2)).to_string(),
                            ((int) (bounds.origin.y + bounds.size.height / 2)).to_string(), "click", "3" };
                        var process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE);
                        fail_if_not(process.wait_check());
                    } else
#endif
                    {
                        fail_if_not(player.activate_action("file-details.popup", null));
                    }
                    settle_file_menu();
                    PopoverMenu? popup = null;
                    for (Widget? child = player.get_first_child(); child != null; child = child.get_next_sibling()) {
                        if (child is PopoverMenu) popup = (PopoverMenu) child;
                    }
                    fail_if(popup == null || !popup.get_mapped(), "the dedicated media player must expose the file menu");
                    fail_if(player.has_tooltip, "the filename must not flicker over an open menu");
                    fail_if_not(player.activate_action("file-details.copy-link", null));
                    if (popup != null) popup.popdown();
                    settle_file_menu();
                }
            }
#if !WINDOWS
            catch (Error error) { fail_if_reached(error.message); }
#endif
            finally {
                window.child = null;
                player.dispose();
                window.destroy();
                settle_file_menu();
            }
        }
    }

    private void test_pointer_context() {
#if WINDOWS
        GLib.Test.skip("X11 pointer injection is Linux-only; Windows tests activate the same native menu actions");
#else
        if (Environment.get_variable("DINOX_TEST_NATIVE_KEYS") != "1") {
            GLib.Test.skip("Pointer injection requires the dedicated Xvfb test");
            return;
        }
        var transfer = create_transfer(FileTransfer.Phase.NONE);
        add_usable_sfs_source(transfer);
        var host = new SizeRequestBin();
        var label = new Label("File attachment");
        label.set_parent(host);
        var menu = new FileContextMenu(host, transfer);
        var window = new Window() { title = "DinoX file menu runtime", child = host,
            default_width = 400, default_height = 200 };
        try {
            window.present();
            settle_file_menu();
            foreach (var phase in new FileTransfer.Phase[] { FileTransfer.Phase.NONE, FileTransfer.Phase.COMPLETE }) {
                transfer.set_transfer_phase(phase);
                Graphene.Rect bounds;
                fail_if_not(host.compute_bounds(window, out bounds));
                string x = ((int) (bounds.origin.x + bounds.size.width / 2)).to_string();
                string y = ((int) (bounds.origin.y + bounds.size.height / 2)).to_string();
                string[] argv = { "xdotool", "search", "--name", "^DinoX file menu runtime$",
                    "windowfocus", "--sync", "mousemove", "--window", "%1", x, y, "click", "3" };
                var process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE);
                fail_if_not(process.wait_check());
                settle_file_menu();
                PopoverMenu? popup = null;
                for (Widget? child = host.get_first_child(); child != null; child = child.get_next_sibling()) {
                    if (child is PopoverMenu) popup = (PopoverMenu) child;
                }
                fail_if(popup == null || !popup.get_mapped(), "a real right-click must open the attachment menu");
                fail_if(host.has_tooltip, "the filename tooltip must stay hidden while the menu is open");
                if (popup != null) popup.popdown();
                settle_file_menu();
                fail_if_not(host.has_tooltip);
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            menu.dispose();
            label.unparent();
            window.child = null;
            window.destroy();
            settle_file_menu();
        }
#endif
    }

    private void test_file_context() {
        var transfer = create_transfer(FileTransfer.Phase.NONE);
        transfer.file_name = "Bild — صورة.png";
        transfer.mime_type = "image/png";
        string url = "https://example.invalid/image%20name.png?download=1";
        transfer.add_sfs_source(new Xep.StatelessFileSharing.HttpSource() { url = url });
        var host = new SizeRequestBin();
        var label = new Label("File available to download");
        label.set_parent(host);
        var menu = new FileContextMenu(host, transfer);
        var window = new Window() { child = host, default_width = 400, default_height = 200 };
        try {
            window.present();
            settle_file_menu();
            fail_if_not(host.tooltip_text.contains(transfer.file_name));
            fail_if_not(host.tooltip_text.contains("image/png"));
            fail_if_not_eq_str(url, menu.get_link());
            fail_if_not(host.activate_action("file-details.popup", null));
            settle_file_menu();
            PopoverMenu? popup = null;
            for (Widget? child = host.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child is PopoverMenu) popup = (PopoverMenu) child;
            }
            fail_if(popup == null || !popup.get_mapped(), "the context menu must open on an incomplete file");
            fail_if_not(host.activate_action("file-details.copy-link", null));
            string? copied = null;
            bool clipboard_done = false;
            host.get_clipboard().read_text_async.begin(null, (obj, result) => {
                try { copied = host.get_clipboard().read_text_async.end(result); }
                catch (Error error) { fail_if_reached(error.message); }
                clipboard_done = true;
            });
            int64 deadline = get_monotonic_time() + 3000000;
            while (!clipboard_done && get_monotonic_time() < deadline) settle_file_menu();
            fail_if_not(clipboard_done);
            fail_if_not_eq_str(url, copied);
            fail_if(transfer.state != FileTransfer.State.NOT_STARTED || transfer.path != null,
                "copying the source must not download or open the file");
            if (popup != null) popup.popdown();

            transfer.provider = FileManager.HTTP_PROVIDER_ID;
            transfer.info = "url:aesgcm://example.invalid/encrypted.png#test-fragment";
            fail_if_not_eq_str(transfer.info.substring(4), menu.get_link());
            transfer.provider = FileManager.JINGLE_PROVIDER_ID;
            fail_if(menu.get_link() != null, "direct-transfer metadata is not a web link");
            transfer.provider = FileManager.HTTP_PROVIDER_ID;
            transfer.info = "url:file:///private/example.png";
            fail_if(menu.get_link() != null, "local paths must never become attachment web links");
            transfer.file_name = "Changed.png";
            fail_if_not(host.tooltip_text.contains("Changed.png"));
        } finally {
            menu.dispose();
            label.unparent();
            window.child = null;
            window.destroy();
            settle_file_menu();
        }
    }

    private void test_cancel_button() {
        var transfer = create_transfer(FileTransfer.Phase.DOWNLOADING);
        var widget = new FileDefaultWidget();
        var controller = new FileDefaultWidgetController(widget);
        var host = new Box(Orientation.VERTICAL, 0);
        // FileWidget installs its class actions before creating its children.
        // Match that order for this action-group stand-in as well.
        var counts = install_file_action_counters(host);
        host.append(widget);
        var window = new Window() { child = host };
        controller.set_file_transfer(transfer);
        try {
            window.present();
            settle_file_menu();
            foreach (FileTransfer.Phase phase in new FileTransfer.Phase[] {
                    FileTransfer.Phase.DOWNLOADING, FileTransfer.Phase.DECRYPTING,
                    FileTransfer.Phase.VERIFYING, FileTransfer.Phase.STORING }) {
                transfer.set_transfer_phase(phase);
                settle_file_menu();
                fail_if_not(widget.transfer_action_button.visible);
                fail_if_not(widget.transfer_action_button.get_mapped());
                fail_if_not(widget.transfer_action_button.is_sensitive());
                fail_if_not_eq_str("file.cancel", widget.transfer_action_button.action_name);
                int before = counts.cancel;
                widget.transfer_action_button.activate();
                for (int i = 0; i < 4; i++) settle_file_menu();
                fail_if_not_eq_int(before + 1, counts.cancel);
            }
            fail_if_not_eq_int(0, counts.open);
        } finally {
            controller.dispose();
            window.child = null;
            window.destroy();
            settle_file_menu();
        }
    }

    private static void settle_file_menu() {
        int64 deadline = get_monotonic_time() + 100000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private void test_recipient_change() {
        fail_if_not_eq_str(_("The original recipient can no longer be confirmed. Select the file again."),
            FileDefaultWidget.get_transfer_failure_text("Private-room attachment recipient changed; choose the file again"));
        fail_if_not_eq_str(_("File transfer cancelled."),
            FileDefaultWidget.get_transfer_failure_text("cancelled"));
    }

    private void test_incomplete_transfers_never_route_clicked_signal_to_open_action() {
        FileTransfer.Phase[] blocked_phases = {
            FileTransfer.Phase.NONE,
            FileTransfer.Phase.PREPARING,
            FileTransfer.Phase.ENCRYPTING,
            FileTransfer.Phase.REQUESTING_SLOT,
            FileTransfer.Phase.UPLOADING,
            FileTransfer.Phase.ANNOUNCING,
            FileTransfer.Phase.DOWNLOADING,
            FileTransfer.Phase.DECRYPTING,
            FileTransfer.Phase.VERIFYING,
            FileTransfer.Phase.STORING,
            FileTransfer.Phase.PREVIEWING,
            FileTransfer.Phase.FAILED
        };

        foreach (FileTransfer.Phase phase in blocked_phases) {
            FileTransfer file_transfer = create_transfer(phase);
            if (phase == FileTransfer.Phase.NONE || phase == FileTransfer.Phase.FAILED) {
                add_usable_sfs_source(file_transfer);
            }
            ActionCounts counts = click_default_widget(file_transfer);

            fail_if(file_transfer.is_plaintext_release_allowed(),
                @"test setup unexpectedly allows plaintext release for $(phase.to_string())");
            fail_if_not_eq_int(0, counts.open,
                @"Gate 4 UI runtime must not route the clicked signal for $(phase.to_string()) to file.open");
        }
    }

    private void test_complete_transfer_routes_clicked_signal_to_open_action() {
        FileTransfer file_transfer = create_transfer(FileTransfer.Phase.COMPLETE);
        ActionCounts counts = click_default_widget(file_transfer);

        fail_if_not(file_transfer.is_plaintext_release_allowed(),
            "complete transfer must be the only default-widget open state");
        fail_if_not_eq_int(1, counts.open,
            "complete transfer clicked signal must route to file.open exactly once");
        fail_if_not_eq_int(0, counts.download,
            "complete transfer clicked signal must not route to file.download");
        fail_if_not_eq_int(0, counts.cancel,
            "complete transfer clicked signal must not route to file.cancel");
    }

    private void test_download_action_requires_usable_received_source() {
        FileTransfer no_source = create_transfer(FileTransfer.Phase.NONE);
        GLib.Test.expect_message("dino", LogLevelFlags.LEVEL_WARNING, "*download requested but no source is available*");
        ActionCounts no_source_counts = click_default_widget(no_source);
        GLib.Test.assert_expected_messages();
        fail_if_not_eq_int(0, no_source_counts.download,
            "received not-started transfer without a usable source must not route to file.download");

        FileTransfer with_source = create_transfer(FileTransfer.Phase.NONE);
        add_usable_sfs_source(with_source);
        ActionCounts with_source_counts = click_default_widget(with_source);
        fail_if_not_eq_int(1, with_source_counts.download,
            "received not-started transfer with a usable source must route to file.download");
        fail_if_not_eq_int(0, with_source_counts.open,
            "received not-started transfer with a usable source must not route to file.open");

        FileTransfer sent_remote_offer = create_transfer(FileTransfer.Phase.NONE);
        sent_remote_offer.direction = FileTransfer.DIRECTION_SENT;
        sent_remote_offer.path = "";
        add_usable_sfs_source(sent_remote_offer);
        ActionCounts sent_remote_offer_counts = click_default_widget(sent_remote_offer);
        fail_if_not_eq_int(1, sent_remote_offer_counts.download,
            "own sent SFS transfer from another device with a usable source must route to file.download");
        fail_if(!sent_remote_offer_counts.has_transfer_action,
            "own sent SFS transfer from another device must show a visible Download action");
        fail_if_not_eq_str("file.download", sent_remote_offer_counts.transfer_action_name,
            "own sent SFS transfer visible action must route to file.download");
        fail_if_not_eq_str(_("Download"), sent_remote_offer_counts.transfer_action_label,
            "own sent SFS transfer visible action must be labelled as Download");

        FileTransfer sent_legacy_offer = create_transfer(FileTransfer.Phase.NONE);
        sent_legacy_offer.direction = FileTransfer.DIRECTION_SENT;
        sent_legacy_offer.provider = FileManager.HTTP_PROVIDER_ID;
        sent_legacy_offer.path = "";
        sent_legacy_offer.info = "url:aesgcm://upload.example.test/gate4-runtime.txt#00112233445566778899aabbccddeeff";
        ActionCounts sent_legacy_offer_counts = click_default_widget(sent_legacy_offer);
        fail_if_not_eq_int(1, sent_legacy_offer_counts.download,
            "own sent legacy HTTP/aesgcm transfer from another device must route to file.download");
        fail_if(!sent_legacy_offer_counts.has_transfer_action,
            "own sent legacy HTTP/aesgcm transfer from another device must show a visible Download action");

        FileTransfer stale_direct = create_transfer(FileTransfer.Phase.NONE);
        stale_direct.provider = FileManager.JINGLE_PROVIDER_ID;
        GLib.Test.expect_message("dino", LogLevelFlags.LEVEL_WARNING, "*download requested but no source is available*");
        ActionCounts stale_direct_counts = click_default_widget(stale_direct);
        GLib.Test.assert_expected_messages();
        fail_if_not_eq_int(0, stale_direct_counts.download,
            "received direct transfer without a live Jingle offer must not route to file.download");
        fail_if(stale_direct_counts.has_transfer_action,
            "received direct transfer without a live Jingle offer must not show a Download action");
        fail_if_not_eq_str(_("Direct transfer unavailable. Ask the sender to send it again."), stale_direct_counts.mime_label,
            "stale direct transfer must tell the user that the sender has to resend");

        FileTransfer failed_with_source = create_transfer(FileTransfer.Phase.FAILED);
        add_usable_sfs_source(failed_with_source);
        ActionCounts failed_counts = click_default_widget(failed_with_source);
        fail_if_not_eq_int(1, failed_counts.download,
            "failed received transfer with a usable source must route to file.download");

        FileTransfer sent_failed_with_source = create_transfer(FileTransfer.Phase.FAILED);
        sent_failed_with_source.direction = FileTransfer.DIRECTION_SENT;
        sent_failed_with_source.path = "";
        add_usable_sfs_source(sent_failed_with_source);
        ActionCounts sent_failed_counts = click_default_widget(sent_failed_with_source);
        fail_if_not_eq_int(1, sent_failed_counts.download,
            "failed own sent SFS transfer from another device with a usable source must route to file.download");
        fail_if(sent_failed_counts.has_menu,
            "failed own sent SFS transfer from another device must not show an open/save menu");
        fail_if(!sent_failed_counts.has_transfer_action,
            "failed own sent SFS transfer from another device must show a visible Download action");
        fail_if_not_eq_str(_("Download"), sent_failed_counts.transfer_action_label,
            "failed own sent SFS transfer from another device visible action must be labelled as Download");

        FileTransfer sent_failed_without_source = create_transfer(FileTransfer.Phase.FAILED);
        sent_failed_without_source.direction = FileTransfer.DIRECTION_SENT;
        sent_failed_without_source.path = "";
        ActionCounts sent_failed_without_source_counts = click_default_widget(sent_failed_without_source);
        fail_if_not_eq_int(0, sent_failed_without_source_counts.download,
            "failed sent transfer without local copy or usable source must not route to file.download");
        fail_if(sent_failed_without_source_counts.has_transfer_action,
            "failed sent transfer without local copy or usable source must not show a transfer action");

        FileTransfer retryable_sent_failed = create_transfer(FileTransfer.Phase.FAILED);
        retryable_sent_failed.direction = FileTransfer.DIRECTION_SENT;
        retryable_sent_failed.path = "persisted-local-copy.enc";
        ActionCounts retryable_sent_failed_counts = click_default_widget(retryable_sent_failed);
        fail_if_not_eq_int(1, retryable_sent_failed_counts.download,
            "retryable failed sent transfer must route to file.download for upload retry");
        fail_if(retryable_sent_failed_counts.has_menu,
            "retryable failed sent transfer must not hide retry upload in the file menu");
        fail_if(!retryable_sent_failed_counts.has_transfer_action,
            "retryable failed sent transfer must show visible retry upload action");
        fail_if_not_eq_str("file.download", retryable_sent_failed_counts.transfer_action_name,
            "retryable failed sent transfer visible action must route to upload retry");
        fail_if_not_eq_str(_("Retry upload"), retryable_sent_failed_counts.transfer_action_label,
            "retryable failed sent transfer visible action must be labelled as retry upload");
    }

    private void test_empty_media_failure_text_asks_for_resend() {
        fail_if_not_eq_str(
            _("Received media file is empty. Ask the sender to send it again."),
            FileDefaultWidget.get_transfer_failure_text("Received media file is empty"),
            "empty media receive errors must be classified as resend-needed");
        fail_if_not_eq_str(
            _("Received media file is empty. Ask the sender to send it again."),
            FileDefaultWidget.get_transfer_failure_text("Stream contains no data."),
            "GStreamer empty-stream diagnostics must use the same user-facing media error");
    }

    private ActionCounts click_default_widget(FileTransfer file_transfer) {
        var window = new Window();
        var action_host = new Box(Orientation.VERTICAL, 0);
        var widget = new FileDefaultWidget();
        var controller = new FileDefaultWidgetController(widget);
        var counts = install_file_action_counters(action_host);

        controller.set_file_transfer(file_transfer);
        action_host.append(widget);
        window.set_child(action_host);
        window.present();
        drain_main_context();
        counts.has_menu = widget.file_menu.popover != null;
        counts.has_transfer_action = widget.transfer_action_button.visible;
        counts.transfer_action_name = widget.transfer_action_button.action_name;
        counts.transfer_action_label = widget.transfer_action_button.label;
        counts.mime_label = widget.mime_label.label;

        widget.clicked();
        drain_main_context();

        controller.dispose();
        window.set_child(null);
        window.destroy();
        drain_main_context();

        return counts;
    }

    private ActionCounts install_file_action_counters(Widget widget) {
        var counts = new ActionCounts();
        var group = new SimpleActionGroup();

        var open_action = new SimpleAction("open", null);
        open_action.activate.connect(() => {
            counts.open++;
        });
        group.add_action(open_action);

        var download_action = new SimpleAction("download", null);
        download_action.activate.connect(() => {
            counts.download++;
        });
        group.add_action(download_action);

        var cancel_action = new SimpleAction("cancel", null);
        cancel_action.activate.connect(() => {
            counts.cancel++;
        });
        group.add_action(cancel_action);

        widget.insert_action_group("file", group);
        return counts;
    }

    private FileTransfer create_transfer(FileTransfer.Phase phase) {
        var file_transfer = new FileTransfer();
        file_transfer.file_name = "gate4-runtime.txt";
        file_transfer.mime_type = "text/plain";
        file_transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        file_transfer.size = 42;
        file_transfer.provider = FileManager.SFS_PROVIDER_ID;
        file_transfer.encryption = Encryption.NONE;
        file_transfer.set_transfer_phase(phase, phase == FileTransfer.Phase.FAILED ? "synthetic failure" : null);
        return file_transfer;
    }

    private void add_usable_sfs_source(FileTransfer file_transfer) {
        file_transfer.add_sfs_source(new Xep.StatelessFileSharing.HttpSource() {
            url = "https://example.invalid/gate4-runtime.txt"
        });
    }

    private void drain_main_context() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
    }
}

}
