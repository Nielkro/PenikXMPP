namespace Dino.Ui.Test {

class FileTransferInputTest : Gee.TestCase {
    [CCode (cname = "gdk_content_formats_new", cheader_filename = "gdk/gdk.h")]
    private static extern Gdk.ContentFormats content_formats_new_const(
        [CCode (array_length_type = "guint", type = "const char**")] string[] mime_types);

    public FileTransferInputTest() {
        base("FileTransferInputTest");
        add_test("plain_text_is_not_intercepted", test_plain_text_is_not_intercepted);
        add_test("file_list_has_priority_over_image", test_file_list_has_priority_over_image);
        add_test("uri_list_is_treated_as_file_list", test_uri_list_is_treated_as_file_list);
        add_test("supported_image_is_recognized", test_supported_image_is_recognized);
        add_test("texture_gtype_is_recognized", test_texture_gtype_is_recognized);
        add_test("first_file_preserves_file_list_order", test_first_file_preserves_file_list_order);
        add_test("legacy_single_file_value_is_supported", test_legacy_single_file_value_is_supported);
        add_test("non_file_value_is_rejected", test_non_file_value_is_rejected);
        add_test("copy_drag_action_is_accepted", test_copy_drag_action_is_accepted);
        add_test("move_only_drag_action_is_rejected", test_move_only_drag_action_is_rejected);
        add_test("file_drop_target_intercepts_child_text_view", test_file_drop_target_intercepts_child_text_view);
        add_test("uri_list_drop_matches_file_target", test_uri_list_drop_matches_file_target);
        add_test("portal_drop_is_preferred_over_uri_list", test_portal_drop_is_preferred_over_uri_list);
        add_test("legacy_portal_drop_is_supported", test_legacy_portal_drop_is_supported);
        add_test("uri_list_selects_first_native_file", test_uri_list_selects_first_native_file);
        add_test("uri_list_rejects_remote_only_content", test_uri_list_rejects_remote_only_content);
        add_test("windows_filename_w_preserves_unicode_path", test_windows_filename_w_preserves_unicode_path);
        add_test("windows_filename_w_rejects_malformed_content", test_windows_filename_w_rejects_malformed_content);
        add_test("stale_conversation_generation_is_rejected", test_stale_conversation_generation_is_rejected);
        add_test("different_conversation_target_is_rejected", test_different_conversation_target_is_rejected);
        add_test("unavailable_upload_is_rejected", test_unavailable_upload_is_rejected);
        add_test("unreadable_native_drop_requests_reselection", test_unreadable_native_drop_requests_reselection);
        add_test("remote_or_malformed_drop_does_not_request_reselection", test_remote_or_malformed_drop_does_not_request_reselection);
        add_test("file_access_reselection_requires_flatpak_and_decoder", test_file_access_reselection_requires_flatpak_and_decoder);
        add_test("native_runtime_uses_synchronous_drop_target", test_native_runtime_uses_synchronous_drop_target);
        add_test("legacy_x11_rootwindow_async_workaround_is_version_scoped", test_legacy_x11_rootwindow_async_workaround_is_version_scoped);
        add_test("legacy_rootwindow_matcher_requires_move_bubble", test_legacy_rootwindow_matcher_requires_move_bubble);
        add_test("send_overlay_preview_fits_fixed_content_width", test_send_overlay_preview_fits_fixed_content_width);
        add_test("transfer_method_choice_is_visible_for_both_senders", test_transfer_method_choice_is_visible_for_both_senders);
        add_test("transfer_method_choice_is_visible_for_jingle_only", test_transfer_method_choice_is_visible_for_jingle_only);
        add_test("transfer_method_choice_is_visible_for_http_only", test_transfer_method_choice_is_visible_for_http_only);
        add_test("transfer_method_choice_is_hidden_without_sender", test_transfer_method_choice_is_hidden_without_sender);
        add_test("progressive_sender_update_preserves_selection", test_progressive_sender_update_preserves_selection);
    }

    private void test_plain_text_is_not_intercepted() {
        var formats = content_formats_new_const({ "text/plain" });
        assert_true(FileTransferInput.classify_clipboard_formats(formats) == ClipboardTransferKind.NONE,
                "plain text paste must remain handled by Gtk.TextView");
    }

    private void test_file_list_has_priority_over_image() {
        var builder = new Gdk.ContentFormatsBuilder();
        builder.add_gtype(typeof(Gdk.FileList));
        builder.add_mime_type("image/png");
        Gdk.ContentFormats formats = builder.to_formats();

        assert_true(FileTransferInput.classify_clipboard_formats(formats) == ClipboardTransferKind.FILE_LIST,
                "a copied file must retain its original file and name instead of becoming a bitmap copy");
    }

    private void test_uri_list_is_treated_as_file_list() {
        var formats = content_formats_new_const({ "text/uri-list", "text/plain" });
        assert_true(FileTransferInput.classify_clipboard_formats(formats) == ClipboardTransferKind.FILE_LIST,
                "URI-list clipboard providers must enter the file transfer path");
    }

    private void test_supported_image_is_recognized() {
        var formats = content_formats_new_const({ "image/png" });
        assert_true(FileTransferInput.classify_clipboard_formats(formats) == ClipboardTransferKind.IMAGE,
                "clipboard screenshots must enter the image transfer path");
    }

    private void test_texture_gtype_is_recognized() {
        var formats = new Gdk.ContentFormats.for_gtype(typeof(Gdk.Texture));
        assert_true(FileTransferInput.classify_clipboard_formats(formats) == ClipboardTransferKind.IMAGE,
                "an in-process texture provider must enter the image transfer path");
    }

    private void test_first_file_preserves_file_list_order() {
        File first = File.new_for_path("/tmp/first-file.txt");
        File second = File.new_for_path("/tmp/second-file.txt");
        File[] files = { first, second };
        var file_list = new Gdk.FileList.from_array(files);
        Value value = Value(typeof(Gdk.FileList));
        value.set_boxed(file_list);

        File? extracted = FileTransferInput.first_file_from_value(value);
        assert_true(extracted != null && ((!) extracted).equal(first),
                "the existing single-file send dialog must use the first copied file deterministically");
    }

    private void test_non_file_value_is_rejected() {
        Value value = Value(typeof(string));
        value.set_string("file:///tmp/not-a-file-list");
        assert_true(FileTransferInput.first_file_from_value(value) == null,
                "plain clipboard text must not be reinterpreted as a file list");
    }

    private void test_legacy_single_file_value_is_supported() {
        File file = File.new_for_path("/tmp/legacy-single-file.txt");
        Value value = Value(typeof(File));
        value.set_object(file);

        File? extracted = FileTransferInput.first_file_from_value(value);
        assert_true(extracted != null && ((!) extracted).equal(file),
                "single-file drop providers must remain supported");
    }

    private void test_copy_drag_action_is_accepted() {
        assert_true(FileTransferInput.has_compatible_drag_action(
                Gdk.DragAction.COPY | Gdk.DragAction.MOVE, Gdk.DragAction.COPY),
                "a provider offering COPY must be accepted by the file drop target");
    }

    private void test_move_only_drag_action_is_rejected() {
        assert_false(FileTransferInput.has_compatible_drag_action(
                Gdk.DragAction.MOVE, Gdk.DragAction.COPY),
                "a MOVE-only provider must not be accepted by a COPY-only target");
    }

    private void test_file_drop_target_intercepts_child_text_view() {
        Gtk.DropTargetAsync async_target = FileTransferInput.create_async_drop_target();
        Gtk.DropTarget native_target = FileTransferInput.create_native_drop_target();
        assert_true(async_target.propagation_phase == Gtk.PropagationPhase.CAPTURE,
                "the sandbox file target must run before Gtk.TextView can insert a file URI as text");
        assert_true(native_target.propagation_phase == Gtk.PropagationPhase.CAPTURE,
                "the native file target must run before Gtk.TextView can insert a file URI as text");
        assert_true(async_target.actions == Gdk.DragAction.COPY &&
                native_target.actions == Gdk.DragAction.COPY,
                "dropping an attachment must never request that the source file be moved");

        unowned Type[] native_gtypes = native_target.get_gtypes();
        assert_true(native_gtypes.length == 2 &&
                native_gtypes[0] == typeof(Gdk.FileList) &&
                native_gtypes[1] == typeof(File),
                "native Linux and Windows must retain FileList and legacy File drop support");

        Gdk.ContentFormats formats = FileTransferInput.create_drop_formats();
        assert_true(formats.contain_gtype(typeof(Gdk.FileList)),
                "the target must accept standard GTK file lists");
        assert_true(formats.contain_gtype(typeof(File)),
                "the target must accept legacy single-file providers");
        assert_true(formats.contain_mime_type(
                FileTransferInput.PORTAL_FILE_TRANSFER_MIME),
                "the target must advertise the standard FileTransfer portal format");
        assert_false(formats.contain_gtype(typeof(string)),
                "plain text drops must continue to the Gtk.TextView");
    }

    private void test_uri_list_drop_matches_file_target() {
        Gdk.ContentFormats target_formats = FileTransferInput.create_drop_formats();
        var uri_list_formats = content_formats_new_const({ "text/uri-list" });

        assert_true(FileTransferInput.has_compatible_file_format(
                target_formats, uri_list_formats),
                "a MIME-only URI-list from Explorer or a portal must reach the file drop handler");
        assert_false(FileTransferInput.has_compatible_file_format(
                target_formats, content_formats_new_const({ "text/plain" })),
                "plain text must continue to the Gtk.TextView instead of becoming a file drop");
    }

    private void test_portal_drop_is_preferred_over_uri_list() {
        var source_formats = content_formats_new_const({
            "text/uri-list",
            FileTransferInput.PORTAL_FILE_TRANSFER_MIME,
            FileTransferInput.LEGACY_PORTAL_FILE_TRANSFER_MIME
        });

        bool standard_decoder_available =
            FileTransferInput.can_deserialize_as_file_list(
                FileTransferInput.PORTAL_FILE_TRANSFER_MIME);
        bool legacy_decoder_available =
            FileTransferInput.can_deserialize_as_file_list(
                FileTransferInput.LEGACY_PORTAL_FILE_TRANSFER_MIME);
        assert_true(FileTransferInput.preferred_portal_file_transfer_mime(
                source_formats) == FileTransferInput.select_portal_file_transfer_mime(
                source_formats, standard_decoder_available,
                legacy_decoder_available),
            "the runtime portal selector must use the decoders registered by GTK");
        assert_true(FileTransferInput.target_can_request_file_access() ==
                FileTransferInput.can_request_file_access(
                    FileTransferInput.is_flatpak_runtime(),
                    standard_decoder_available, legacy_decoder_available),
            "the target access policy must use the actual runtime boundary and decoders");

        assert_true(FileTransferInput.select_portal_file_transfer_mime(
                source_formats, true, true) ==
                FileTransferInput.PORTAL_FILE_TRANSFER_MIME,
                "sandboxed drops must retrieve the standard portal grant instead of a host path");
        assert_true(FileTransferInput.select_portal_file_transfer_mime(
                source_formats, false, false) == null,
                "native GTK must not select portal data without a registered portal decoder");
    }

    private void test_legacy_portal_drop_is_supported() {
        var source_formats = content_formats_new_const({
            "text/uri-list",
            FileTransferInput.LEGACY_PORTAL_FILE_TRANSFER_MIME
        });

        assert_true(FileTransferInput.select_portal_file_transfer_mime(
                source_formats, false, true) ==
                FileTransferInput.LEGACY_PORTAL_FILE_TRANSFER_MIME,
                "GTK 4.6 portal drops must remain readable during the compatibility window");
        assert_true(FileTransferInput.select_portal_file_transfer_mime(
                source_formats, false, false) == null,
                "legacy portal data must not be selected without a registered decoder");
    }

    private void test_uri_list_selects_first_native_file() {
        File expected = File.new_for_path(Path.build_filename(
                Environment.get_tmp_dir(), "first copied file.txt"));
        string uri_list = "# copied files\r\nhttps://example.test/not-local\r\n%s\r\n".printf(
                expected.get_uri());

        File? selected = FileTransferInput.first_native_file_from_uri_list(uri_list);
        assert_true(selected != null && ((!) selected).equal(expected),
                "URI-list fallback must skip remote entries and select the first local file");
    }

    private void test_uri_list_rejects_remote_only_content() {
        File? selected = FileTransferInput.first_native_file_from_uri_list(
                "https://example.test/not-local\r\n");
        assert_true(selected == null,
                "remote URLs must not be reinterpreted as local clipboard attachments");
    }

    private void test_windows_filename_w_preserves_unicode_path() {
        string expected_path = "C:\\Users\\info\\Desktop\\DinoX Explorer Игорь 50%.png";
        uint8[] encoded = encode_windows_filename_w(expected_path);

        File? selected = FileTransferInput.file_from_windows_filename_w(encoded);
        assert_true(selected != null && ((!) selected).equal(File.new_for_path(expected_path)),
                "FileNameW fallback must preserve Unicode, spaces and percent characters");
    }

    private void test_windows_filename_w_rejects_malformed_content() {
        assert_true(FileTransferInput.file_from_windows_filename_w({
                'C', 0, ':', 0, 'x', 0
            }) == null, "FileNameW must be NUL-terminated");
        assert_true(FileTransferInput.file_from_windows_filename_w({
                'x', 0, 0, 0
            }) == null, "FileNameW must contain an absolute Windows path");
        assert_true(FileTransferInput.file_from_windows_filename_w({
                'C', 0, ':', 0, '\\', 0, 'x', 0, 0, 0, 'y', 0
            }) == null, "FileNameW must not contain data after its terminator");
        assert_true(FileTransferInput.file_from_windows_filename_w(
                encode_windows_filename_w("\\\\.\\PhysicalDrive0")) == null,
                "FileNameW must reject Win32 device namespaces");
        assert_true(FileTransferInput.file_from_windows_filename_w(
                encode_windows_filename_w("\\\\?\\C:\\secret.txt")) == null,
                "FileNameW must reject extended Win32 device namespaces");
        assert_true(FileTransferInput.file_from_windows_filename_w(
                encode_windows_filename_w("\\\\server")) == null,
                "FileNameW UNC paths must include a share component");
    }

    private static uint8[] encode_windows_filename_w(string path) {
        size_t bytes_read;
        size_t bytes_written;
        try {
            string converted = GLib.convert(path, -1, "UTF-16LE", "UTF-8",
                    out bytes_read, out bytes_written);
            uint8[] encoded = new uint8[bytes_written + 2];
            Memory.copy(encoded, converted.data, bytes_written);
            return encoded;
        } catch (ConvertError e) {
            assert_not_reached();
        }
    }

    private void test_stale_conversation_generation_is_rejected() {
        assert_false(FileTransferInput.is_current_request(3, 4, true),
                "a deferred paste/drop from the previous chat must not be dispatched");
        assert_true(FileTransferInput.is_current_request(4, 4, true),
                "the current chat generation may dispatch an available file transfer");
    }

    private void test_different_conversation_target_is_rejected() {
        var expected_target = new Object();
        var other_target = new Object();

        assert_false(FileTransferInput.is_current_target_request(
                expected_target, other_target, 4, 4, true),
            "a completed attachment check must not open a picker in a different chat");
        assert_true(FileTransferInput.is_current_target_request(
                expected_target, expected_target, 4, 4, true),
            "the original attachment target may continue while its generation is current");
    }

    private void test_unavailable_upload_is_rejected() {
        assert_false(FileTransferInput.is_current_request(4, 4, false),
                "file transfer must remain gated when no upload path is available");
    }

    private void test_unreadable_native_drop_requests_reselection() {
        File native_file = File.new_for_path("/home/test/Desktop/dropped.png");
        assert_true(FileTransferInput.should_reselect_unreadable_drop(
                native_file, new IOError.NOT_FOUND("sandbox-hidden host path"), true),
                "an unavailable local drop must be recoverable through the file portal");
        assert_true(FileTransferInput.should_reselect_unreadable_drop(
                native_file, new IOError.PERMISSION_DENIED("sandbox-denied host path"), true),
                "a denied local drop must be recoverable through the file portal");
        assert_false(FileTransferInput.should_reselect_unreadable_drop(
                native_file, new IOError.NOT_FOUND("missing native file"), false),
                "native and Win32 targets must not open a second chooser for a failed drop");
    }

    private void test_remote_or_malformed_drop_does_not_request_reselection() {
        assert_false(FileTransferInput.should_reselect_unreadable_drop(
                File.new_for_uri("https://example.test/file.png"),
                new IOError.NOT_FOUND("remote file unavailable"), true),
                "remote drops must not be reinterpreted as local portal selections");
        assert_false(FileTransferInput.should_reselect_unreadable_drop(
                File.new_for_path("/home/test/Desktop/dropped.png"),
                new IOError.INVALID_DATA("malformed drop"), true),
                "malformed drop data must fail closed instead of opening a file chooser");
    }

    private void test_file_access_reselection_requires_flatpak_and_decoder() {
        assert_true(FileTransferInput.can_request_file_access(true, true, false),
                "a Flatpak target with the standard portal decoder may request file access");
        assert_true(FileTransferInput.can_request_file_access(true, false, true),
                "a Flatpak target with the legacy portal decoder may request file access");
        assert_false(FileTransferInput.can_request_file_access(false, true, true),
                "native Linux and Windows must not inherit the sandbox recovery path");
        assert_false(FileTransferInput.can_request_file_access(true, false, false),
                "a sandbox without a registered decoder must fail closed");
    }

    private void test_native_runtime_uses_synchronous_drop_target() {
        assert_false(FileTransferInput.should_use_async_drop_target(false),
                "native Linux and Windows must stay on GtkDropTarget");
        assert_true(FileTransferInput.should_use_async_drop_target(true),
                "Flatpak must keep the async MIME target even if portal decoder discovery changes");
    }

    private void test_legacy_x11_rootwindow_async_workaround_is_version_scoped() {
        assert_true(FileTransferInput.should_remove_legacy_rootwindow_drop_target(
                false, true, 4, 14, 5),
                "native GTK 4.14 on X11 needs the GtkDropTargetAsync missing-leave cleanup workaround");
        assert_true(FileTransferInput.should_remove_legacy_rootwindow_drop_target(
                false, true, 4, 20, 0),
                "GTK 4.20.0 predates the GtkDropTargetAsync controller cleanup");
        assert_false(FileTransferInput.should_remove_legacy_rootwindow_drop_target(
                false, true, 4, 20, 1),
                "GTK 4.20.1 cleans up GtkDropTargetAsync controller state; GTK X11 issue #3755 remains separate");
        assert_false(FileTransferInput.should_remove_legacy_rootwindow_drop_target(
                true, true, 4, 14, 5),
                "Flatpak portal drops must retain their async target");
        assert_false(FileTransferInput.should_remove_legacy_rootwindow_drop_target(
                false, false, 4, 14, 5),
                "Wayland must not inherit an X11-only workaround");
        assert_false(FileTransferInput.should_remove_legacy_rootwindow_drop_target(
                false, true, 5, 0, 0),
                "future GTK major versions must not inherit a legacy workaround");
    }

    private void test_legacy_rootwindow_matcher_requires_move_bubble() {
        var bubble_move_target = new Gtk.DropTargetAsync(
                content_formats_new_const({ "application/x-rootwindow-drop" }),
                Gdk.DragAction.MOVE) {
            propagation_phase = Gtk.PropagationPhase.BUBBLE
        };
        var capture_move_target = new Gtk.DropTargetAsync(
                content_formats_new_const({ "application/x-rootwindow-drop" }),
                Gdk.DragAction.MOVE) {
            propagation_phase = Gtk.PropagationPhase.CAPTURE
        };
        var wrong_mime_move_target = new Gtk.DropTargetAsync(
                content_formats_new_const({ "application/x-dinox-unrelated" }),
                Gdk.DragAction.MOVE) {
            propagation_phase = Gtk.PropagationPhase.BUBBLE
        };
        var copy_target = new Gtk.DropTargetAsync(
                FileTransferInput.create_drop_formats(), Gdk.DragAction.COPY) {
            propagation_phase = Gtk.PropagationPhase.BUBBLE
        };
        assert_true(FileTransferInput.is_legacy_rootwindow_drop_target(
                bubble_move_target),
                "only a GtkWindow-like async MOVE+BUBBLE target may match the controller workaround");
        assert_false(FileTransferInput.is_legacy_rootwindow_drop_target(
                capture_move_target),
                "application capture-phase MOVE targets must remain; this workaround does not address GTK X11 issue #3755");
        assert_false(FileTransferInput.is_legacy_rootwindow_drop_target(
                wrong_mime_move_target),
                "an unrelated MOVE+BUBBLE target must never be mistaken for GtkWindow's rootwindow controller");
        assert_false(FileTransferInput.is_legacy_rootwindow_drop_target(
                copy_target),
                "DinoX COPY drop targets must remain attached");
    }

    private void test_send_overlay_preview_fits_fixed_content_width() {
        int preview_width = FileTransferInput.preview_max_width_for_content(400);
        assert_true(preview_width == 370,
                "the image preview plus body margins and border must fit the fixed 400px dialog width");
        assert_true(FileTransferInput.FILE_SEND_PREVIEW_MAX_HEIGHT == 240,
                "the image preview must leave vertical room for the header and transfer controls");
    }

    private void test_transfer_method_choice_is_visible_for_both_senders() {
        assert_true(FileTransferInput.should_show_transfer_method_choice(true, true),
                "automatic, direct transfer and server upload must be visible when both senders are available");
    }

    private void test_transfer_method_choice_is_visible_for_jingle_only() {
        assert_true(FileTransferInput.should_show_transfer_method_choice(true, false),
                "automatic and direct transfer must remain visible when Jingle is the only available sender");
    }

    private void test_transfer_method_choice_is_visible_for_http_only() {
        assert_true(FileTransferInput.should_show_transfer_method_choice(false, true),
                "automatic and server upload must remain visible when HTTP is the only available sender");
    }

    private void test_transfer_method_choice_is_hidden_without_sender() {
        assert_false(FileTransferInput.should_show_transfer_method_choice(false, false),
                "the transfer method choice must stay hidden when the file cannot be sent");
    }

    private void test_progressive_sender_update_preserves_selection() {
        int[] http_only = {
            FileManager.NO_REQUIRED_FILE_SENDER_ID,
            FileManager.HTTP_PROVIDER_ID
        };
        int[] both = {
            FileManager.NO_REQUIRED_FILE_SENDER_ID,
            FileManager.JINGLE_PROVIDER_ID,
            FileManager.HTTP_PROVIDER_ID
        };

        assert_true(FileTransferInput.selection_for_preferred_sender(
                both, FileManager.HTTP_PROVIDER_ID) == 2,
                "a late direct-transfer result must not reset an explicit server-upload selection");
        assert_true(FileTransferInput.selection_for_preferred_sender(
                http_only, FileManager.JINGLE_PROVIDER_ID) == 0,
                "a no-longer available explicit sender must fall back to Automatic");
    }
}

}
