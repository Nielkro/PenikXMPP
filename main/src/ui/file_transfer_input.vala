/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Ui {

internal enum ClipboardTransferKind {
    NONE,
    FILE_LIST,
    IMAGE
}

internal class FileTransferInput : Object {
    public const string PORTAL_FILE_TRANSFER_MIME = "application/vnd.portal.filetransfer";
    public const string LEGACY_PORTAL_FILE_TRANSFER_MIME = "application/vnd.portal.files";
    private const string LEGACY_ROOTWINDOW_DROP_MIME = "application/x-rootwindow-drop";
    public const int FILE_SEND_PREVIEW_MAX_HEIGHT = 240;
    private const int FILE_SEND_BODY_HORIZONTAL_MARGIN = 14;
    private const int FILE_IMAGE_BORDER_WIDTH = 1;

    // GTK 4.14 returns the controller-owned formats pointer here. Its Vala
    // binding marks the return as owned, which would unref GTK's live value.
    [CCode (cname = "gtk_drop_target_async_get_formats", cheader_filename = "gtk/gtk.h")]
    private static extern unowned Gdk.ContentFormats?
        peek_async_drop_target_formats(Gtk.DropTargetAsync target);
    public static Gdk.ContentFormats create_drop_formats() {
        var builder = new Gdk.ContentFormatsBuilder();
        // Prefer the FileTransfer portal over text/uri-list. The latter only
        // contains host paths and is not readable inside a Flatpak sandbox.
        builder.add_mime_type(PORTAL_FILE_TRANSFER_MIME);
        builder.add_mime_type(LEGACY_PORTAL_FILE_TRANSFER_MIME);
        builder.add_gtype(typeof(Gdk.FileList));
        builder.add_gtype(typeof(File));
        builder.add_mime_type("text/uri-list");

        return builder.to_formats();
    }

    public static Gtk.DropTargetAsync create_async_drop_target() {
        var target = new Gtk.DropTargetAsync(create_drop_formats(), Gdk.DragAction.COPY) {
            // The conversation view contains a Gtk.TextView whose built-in
            // text target can deserialize file drops as URI/path text. Handle
            // file formats on the parent first, while non-file formats keep
            // propagating to the text widget.
            propagation_phase = Gtk.PropagationPhase.CAPTURE
        };
        return target;
    }

    public static Gtk.DropTarget create_native_drop_target() {
        var target = new Gtk.DropTarget(typeof(Gdk.FileList), Gdk.DragAction.COPY) {
            // Run before Gtk.TextView can deserialize the same file as path
            // text. Native targets only need GTypes; the async MIME target is
            // reserved for sandboxed FileTransfer-portal drops.
            propagation_phase = Gtk.PropagationPhase.CAPTURE
        };
        target.set_gtypes({ typeof(Gdk.FileList), typeof(File) });
        return target;
    }

    public static ClipboardTransferKind classify_clipboard_formats(Gdk.ContentFormats formats) {
        // Clipboard backends commonly expose text/uri-list rather than the
        // boxed FileList type directly. Include every registered GDK
        // deserializer before deciding which application path owns the paste.
        var builder = new Gdk.ContentFormatsBuilder();
        builder.add_formats(formats);
        Gdk.ContentFormats expanded_formats = builder.to_formats();
        expanded_formats = expanded_formats.union_deserialize_gtypes();

        if (expanded_formats.contain_gtype(typeof(Gdk.FileList)) ||
                formats.contain_mime_type("text/uri-list") ||
                formats.contain_mime_type("application/x.windows.FileNameW")) {
            return ClipboardTransferKind.FILE_LIST;
        }

        if (expanded_formats.contain_gtype(typeof(Gdk.Texture)) ||
                formats.contain_mime_type("image/png") ||
                formats.contain_mime_type("image/jpeg") ||
                formats.contain_mime_type("image/bmp") ||
                formats.contain_mime_type("image/gif") ||
                formats.contain_mime_type("image/tiff") ||
                formats.contain_mime_type("image/webp") ||
                formats.contain_mime_type("image/svg+xml")) {
            return ClipboardTransferKind.IMAGE;
        }

        return ClipboardTransferKind.NONE;
    }

    public static File? first_file_from_value(GLib.Value value) {
        if (value.holds(typeof(File))) {
            return value.get_object() as File;
        }

        if (!value.holds(typeof(Gdk.FileList))) return null;

        unowned Gdk.FileList? file_list = (Gdk.FileList?) value.get_boxed();
        if (file_list == null) return null;

        foreach (unowned File file in ((!) file_list).get_files()) {
            File selected_file = file;
            return selected_file;
        }
        return null;
    }

    public static bool is_current_request(uint expected_generation,
            uint current_generation, bool upload_available) {
        return expected_generation == current_generation && upload_available;
    }

    public static bool is_current_target_request(Object expected_target,
            Object? current_target, uint expected_generation,
            uint current_generation, bool upload_available) {
        return expected_target == current_target && is_current_request(
                expected_generation, current_generation, upload_available);
    }

    public static bool should_reselect_unreadable_drop(File file, Error error,
            bool access_confirmation_available) {
        // A sandbox sees an unexported host path as missing (or denied). Only
        // these local-path failures may trigger an explicit FileDialog grant;
        // remote URIs and malformed input must fail closed instead.
        return access_confirmation_available && file.is_native() &&
                file.get_path() != null &&
                (error is IOError.NOT_FOUND || error is IOError.PERMISSION_DENIED);
    }

    public static bool has_compatible_drag_action(Gdk.DragAction offered,
            Gdk.DragAction accepted) {
        return (offered & accepted) != 0;
    }

    public static bool has_compatible_file_format(Gdk.ContentFormats target_formats,
            Gdk.ContentFormats source_formats) {
        // Some backends (notably Explorer/portals) advertise only
        // text/uri-list even though GDK can deserialize it as FileList.
        if (source_formats.contain_mime_type("text/uri-list") &&
                (target_formats.contain_gtype(typeof(Gdk.FileList)) ||
                 target_formats.contain_gtype(typeof(File)))) {
            return true;
        }

        // Copy the immutable formats first: Vala treats
        // union_deserialize_gtypes() as consuming its receiver.
        var builder = new Gdk.ContentFormatsBuilder();
        builder.add_formats(source_formats);
        Gdk.ContentFormats expanded_source = builder.to_formats();
        expanded_source = expanded_source.union_deserialize_gtypes();
        return target_formats.match_gtype(expanded_source) != Type.INVALID;
    }

    public static string? preferred_portal_file_transfer_mime(Gdk.ContentFormats source_formats) {
        return select_portal_file_transfer_mime(
                source_formats,
                can_deserialize_as_file_list(PORTAL_FILE_TRANSFER_MIME),
                can_deserialize_as_file_list(LEGACY_PORTAL_FILE_TRANSFER_MIME));
    }

    public static string? select_portal_file_transfer_mime(
            Gdk.ContentFormats source_formats,
            bool standard_decoder_available, bool legacy_decoder_available) {
        if (source_formats.contain_mime_type(PORTAL_FILE_TRANSFER_MIME) &&
                standard_decoder_available) {
            return PORTAL_FILE_TRANSFER_MIME;
        }
        if (source_formats.contain_mime_type(LEGACY_PORTAL_FILE_TRANSFER_MIME) &&
                legacy_decoder_available) {
            return LEGACY_PORTAL_FILE_TRANSFER_MIME;
        }
        return null;
    }

    public static bool can_deserialize_as_file_list(string mime_type) {
        var builder = new Gdk.ContentFormatsBuilder();
        builder.add_mime_type(mime_type);
        Gdk.ContentFormats expanded = builder.to_formats();
        expanded = expanded.union_deserialize_gtypes();
        return expanded.contain_gtype(typeof(Gdk.FileList));
    }

    public static bool target_can_request_file_access() {
        // The target-side FileTransfer decoder is registered when GTK is
        // configured to use a file portal (for example inside Flatpak). A raw
        // URI-list drop without a portal grant may then require one explicit
        // FileDialog selection. /.flatpak-info is the non-forgeable runtime
        // boundary here; merely finding a portal service on native Linux is
        // not evidence that the target lacks filesystem access.
        return can_request_file_access(
                is_flatpak_runtime(),
                can_deserialize_as_file_list(PORTAL_FILE_TRANSFER_MIME),
                can_deserialize_as_file_list(LEGACY_PORTAL_FILE_TRANSFER_MIME));
    }

    public static bool is_flatpak_runtime() {
        return FileUtils.test("/.flatpak-info", FileTest.EXISTS);
    }

    public static bool should_use_async_drop_target(bool inside_flatpak) {
        // A sandbox may offer a portal format even when a particular decoder
        // is unavailable or registered later. Never silently fall back to the
        // native GType-only target inside Flatpak.
        return inside_flatpak;
    }

    public static bool should_remove_legacy_rootwindow_drop_target(
            bool inside_flatpak, bool is_x11,
            uint gtk_major, uint gtk_minor, uint gtk_micro) {
        if (inside_flatpak || !is_x11 || gtk_major != 4) return false;

        // GTK 4.20.1 added cleanup for GtkDropTargetAsync after DROP_START
        // and missing leave crossings. This workaround only permits removal
        // of GtkWindow's internal application/x-rootwindow-drop controller.
        // It does not fix the separate GTK X11 issue #3755 in GdkDrop.
        return gtk_minor < 20 || (gtk_minor == 20 && gtk_micro < 1);
    }

    public static bool is_legacy_rootwindow_drop_target(
            Gtk.EventController controller) {
        Gtk.DropTargetAsync? target = controller as Gtk.DropTargetAsync;
        // GtkWindow's private rootwindow target is a direct async MOVE target
        // for application/x-rootwindow-drop in the default BUBBLE phase.
        // DinoX file and portal targets use COPY, while application-owned
        // capture-phase or differently formatted MOVE targets must be retained.
        return target != null &&
                ((!) target).actions == Gdk.DragAction.MOVE &&
                controller.propagation_phase == Gtk.PropagationPhase.BUBBLE &&
                has_legacy_rootwindow_drop_format((!) target);
    }

    public static bool has_legacy_rootwindow_drop_format(
            Gtk.DropTargetAsync target) {
        unowned Gdk.ContentFormats? formats =
            peek_async_drop_target_formats(target);
        return formats != null && ((!) formats).contain_mime_type(
                LEGACY_ROOTWINDOW_DROP_MIME);
    }

    public static int preview_max_width_for_content(int dialog_content_width) {
        // The fixed-width send dialog body has 14px margins and the image
        // widget has a 1px border on both sides. Keep the preview's minimum
        // request within that budget so AdwBreakpointBin never reports
        // minimum width greater than its fixed natural width.
        return int.max(1, dialog_content_width -
                2 * FILE_SEND_BODY_HORIZONTAL_MARGIN -
                2 * FILE_IMAGE_BORDER_WIDTH);
    }

    public static bool can_request_file_access(bool inside_flatpak,
            bool standard_decoder_available, bool legacy_decoder_available) {
        return inside_flatpak &&
                (standard_decoder_available || legacy_decoder_available);
    }

    public static File? first_native_file_from_uri_list(string uri_list) {
        foreach (string uri in Uri.list_extract_uris(uri_list)) {
            File file = File.new_for_uri(uri);
            if (file.is_native()) return file;
        }
        return null;
    }

    public static File? file_from_windows_filename_w(uint8[] encoded_path) {
        if (encoded_path.length < 4 || encoded_path.length % 2 != 0) return null;

        int terminator = -1;
        for (int i = 0; i < encoded_path.length; i += 2) {
            if (encoded_path[i] == 0 && encoded_path[i + 1] == 0) {
                terminator = i;
                break;
            }
        }
        if (terminator <= 0) return null;
        for (int i = terminator; i < encoded_path.length; i++) {
            if (encoded_path[i] != 0) return null;
        }

        try {
            size_t bytes_read;
            string path = GLib.convert((string) encoded_path, terminator,
                    "UTF-8", "UTF-16LE", out bytes_read);
            if (bytes_read != terminator || !is_absolute_windows_path(path)) return null;
            return File.new_for_path(path);
        } catch (ConvertError e) {
            return null;
        }
    }

    private static bool is_absolute_windows_path(string path) {
        if (path.length >= 3 && path[1] == ':' &&
                ((path[0] >= 'A' && path[0] <= 'Z') ||
                 (path[0] >= 'a' && path[0] <= 'z')) &&
                (path[2] == '\\' || path[2] == '/')) {
            return true;
        }
        if (!path.has_prefix("\\\\") || path.has_prefix("\\\\.\\") ||
                path.has_prefix("\\\\?\\")) {
            return false;
        }

        int server_end = path.index_of_char('\\', 2);
        return server_end > 2 && server_end + 1 < path.length &&
                path[server_end + 1] != '\\' && path[server_end + 1] != '/';
    }

    public static bool should_show_transfer_method_choice(bool jingle_available,
            bool http_available) {
        // Even when only one explicit transport is currently usable, showing
        // it next to Automatic tells the user how the file can be sent.
        return jingle_available || http_available;
    }

    public static uint selection_for_preferred_sender(int[] sender_ids,
            int preferred_sender_id) {
        for (int i = 0; i < sender_ids.length; i++) {
            if (sender_ids[i] == preferred_sender_id) return (uint) i;
        }
        return 0;
    }
}

}
