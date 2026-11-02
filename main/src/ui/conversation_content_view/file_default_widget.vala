using Gee;
using Gdk;
using Gtk;
using Graphene;

using Dino.Entities;

namespace Dino.Ui {

[GtkTemplate (ui = "/im/dinox/dinox/file_default_widget.ui")]
public class FileDefaultWidget : Gtk.Box {

    public signal void clicked();

    [GtkChild] public unowned Stack image_stack;
    [GtkChild] public unowned Label name_label;
    [GtkChild] public unowned Label mime_label;
    [GtkChild] public unowned Image content_type_image;
    [GtkChild] public unowned Spinner spinner;
    [GtkChild] public unowned Button transfer_action_button;
    [GtkChild] public unowned MenuButton file_menu;

    private FileTransfer.State state;

    construct {
        // Status and transfer failures must not impose their full text width
        // on the conversation, including translated messages and long MIME
        // descriptions. Keep all information visible by wrapping instead.
        mime_label.wrap = true;
        mime_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
        mime_label.max_width_chars = 44;
        mime_label.hexpand = true;
    }

    public void init_updating_file_info() {
        EventControllerMotion this_motion_events = new EventControllerMotion();
        this.add_controller(this_motion_events);
        this_motion_events.enter.connect(on_pointer_entered_event);
        this_motion_events.leave.connect(on_pointer_left_event);

        GestureClick gesture_click_controller = new GestureClick();
        gesture_click_controller.set_button(1); // listen for left clicks
        this.add_controller(gesture_click_controller);
        gesture_click_controller.pressed.connect((n_press, x, y) => {
            // Check whether the click was inside the file menu. Otherwise, open the file.
            Graphene.Point p = { (float)x, (float)y };
            if (this.compute_point(file_menu, p, out p)) {
                if (file_menu.contains(p.x, p.y)) return;
            }
            Graphene.Point action_p = { (float)x, (float)y };
            if (this.compute_point(transfer_action_button, action_p, out action_p)) {
                if (transfer_action_button.contains(action_p.x, action_p.y)) return;
            }

            this.clicked();
        });
    }

    public void set_static_file_info(string? mime_type) {
        spinner.stop(); // A hidden spinning spinner still uses CPU. Deactivate asap
        set_transfer_action(null, null);

        image_stack.set_visible_child_name("content_type_image");
        content_type_image.icon_name = get_file_icon_name(mime_type);
        mime_label.label = mime_type != null ? ContentType.get_description(mime_type) : null;
    }

    public void update_file_info(string? mime_type, FileTransfer.State state, FileTransfer.Phase phase, string? phase_error, bool direction, int64 size, int64 transferred_bytes, int64 phase_total_bytes, bool has_download_source = true, bool can_retry_send = false, bool direct_transfer_unavailable = false, bool can_download_remote_offer = false) {
        this.state = state;

        spinner.stop(); // A hidden spinning spinner still uses CPU. Deactivate asap

        content_type_image.icon_name = get_file_icon_name(mime_type);
        string? mime_description = mime_type != null ? ContentType.get_description(mime_type) : null;
        mime_label.use_markup = false;
        Util.set_menu_button_popover(file_menu, null);
        set_transfer_action(null, null);

        switch (state) {
            case FileTransfer.State.COMPLETE:
                mime_label.label = mime_description;
                image_stack.set_visible_child_name("content_type_image");

                // Create a menu
                Menu menu_model = new Menu();
                menu_model.append(_("Open"), "file.open");
                menu_model.append(_("Save as…"), "file.save_as");
                Gtk.PopoverMenu popover_menu = new Gtk.PopoverMenu.from_model(menu_model);
                Util.set_menu_button_popover(file_menu, popover_menu);
                popover_menu.closed.connect(on_pointer_left);
                break;
            case FileTransfer.State.IN_PROGRESS:
                mime_label.label = get_transfer_phase_label(phase, direction, size, transferred_bytes, phase_total_bytes);
                spinner.start();
                image_stack.set_visible_child_name("spinner");
                set_transfer_action(_("Cancel"), "file.cancel", true);
                break;
            case FileTransfer.State.NOT_STARTED:
                bool can_download_offer = direction == FileTransfer.DIRECTION_RECEIVED || can_download_remote_offer;
                if (direction == FileTransfer.DIRECTION_RECEIVED && !has_download_source) {
                    mime_label.label = get_missing_download_source_text(direct_transfer_unavailable);
                } else if (mime_description != null && size >= 0) {
                    mime_label.label =  _("%s offered: %s").printf(mime_description, get_size_string(size));
                } else if (mime_description != null) {
                    mime_label.label = _("%s offered").printf(mime_description);
                } else if (size >= 0) {
                    mime_label.label = _("File offered: %s").printf(get_size_string(size));
                } else {
                    mime_label.label = _("File offered");
                }
                image_stack.set_visible_child_name("content_type_image");
                if (can_download_offer && has_download_source) {
                    set_transfer_action(_("Download"), "file.download");
                }
                break;
            case FileTransfer.State.FAILED:
                mime_label.use_markup = true;
                string failure_text = get_transfer_failure_text(phase_error);
                mime_label.label = "<span foreground=\"#f44336\">" + Markup.escape_text(failure_text) + "</span>";
                image_stack.set_visible_child_name("content_type_image");
                if ((direction == FileTransfer.DIRECTION_RECEIVED || can_download_remote_offer) && has_download_source) {
                    set_transfer_action(_("Download"), "file.download");
                } else if (can_retry_send) {
                    set_transfer_action(_("Retry upload"), "file.download");
                }
                break;
        }
    }

    private void set_transfer_action(string? label, string? action_name, bool destructive = false) {
        transfer_action_button.remove_css_class("destructive-action");
        if (label == null || action_name == null) {
            transfer_action_button.visible = false;
            transfer_action_button.label = "";
            transfer_action_button.action_name = null;
            transfer_action_button.tooltip_text = null;
            return;
        }

        transfer_action_button.label = (!) label;
        transfer_action_button.action_name = (!) action_name;
        transfer_action_button.tooltip_text = (!) label;
        transfer_action_button.visible = true;
        if (destructive) transfer_action_button.add_css_class("destructive-action");
    }

    public static string get_transfer_phase_label(FileTransfer.Phase phase, bool direction, int64 size, int64 transferred_bytes, int64 phase_total_bytes) {
        switch (phase) {
            case FileTransfer.Phase.PREPARING:
                return _("Preparing file…");
            case FileTransfer.Phase.ENCRYPTING:
                return get_phase_progress_label(_("Encrypting file…"), phase_total_bytes, transferred_bytes);
            case FileTransfer.Phase.REQUESTING_SLOT:
                return _("Requesting upload slot…");
            case FileTransfer.Phase.UPLOADING:
                return get_transfer_progress_label(true, size, transferred_bytes, phase_total_bytes);
            case FileTransfer.Phase.ANNOUNCING:
                return _("Sending file message…");
            case FileTransfer.Phase.DOWNLOADING:
                return get_transfer_progress_label(false, size, transferred_bytes, phase_total_bytes);
            case FileTransfer.Phase.DECRYPTING:
                return get_phase_progress_label(_("Decrypting file…"), phase_total_bytes, transferred_bytes);
            case FileTransfer.Phase.VERIFYING:
                return get_phase_progress_label(_("Verifying file…"), phase_total_bytes, transferred_bytes);
            case FileTransfer.Phase.STORING:
                return get_phase_progress_label(
                    direction == FileTransfer.DIRECTION_SENT ? _("Saving local copy…") : _("Saving file…"),
                    phase_total_bytes,
                    transferred_bytes);
            case FileTransfer.Phase.PREVIEWING:
                return _("Preparing preview…");
            default:
                return direction == FileTransfer.DIRECTION_SENT ?
                    get_transfer_progress_label(true, size, transferred_bytes, phase_total_bytes) :
                    get_transfer_progress_label(false, size, transferred_bytes, phase_total_bytes);
        }
    }

    private static string get_phase_progress_label(string label, int64 size, int64 transferred_bytes) {
        if (size <= 0) return label;

        int64 progress = transferred_bytes * 100 / size;
        if (progress < 0) progress = 0;
        if (progress > 100) progress = 100;
        return "%s (%lld%%)".printf(label, progress);
    }

    private static string get_transfer_progress_label(bool upload, int64 size, int64 transferred_bytes, int64 phase_total_bytes) {
        if (phase_total_bytes > 0) {
            int64 progress = transferred_bytes * 100 / phase_total_bytes;
            if (progress < 0) progress = 0;
            if (progress > 100) progress = 100;
            return upload ?
                _("Uploading %s… (%u%%)").printf(get_size_string(size), progress) :
                _("Downloading %s… (%u%%)").printf(get_size_string(size), progress);
        }
        return upload ? _("Uploading…") : _("Downloading…");
    }

    public static string get_transfer_failure_text(string? phase_error) {
        if (phase_error == null || phase_error == "") {
            return _("File transfer failed");
        }

        string error = ((!) phase_error).down();
        if (error.has_prefix("private-room attachment recipient changed")) {
            return _("The original recipient can no longer be confirmed. Select the file again.");
        }
        if (contains_any(error, {
            "direct file transfer is no longer available",
            "transfer data not available anymore"
        })) {
            return _("Direct transfer unavailable. Ask the sender to send it again.");
        }

        if (contains_any(error, {
            "cancelled",
            "canceled"
        })) {
            return _("File transfer cancelled.");
        }

        if (contains_any(error, {
            "timed out",
            "timeout",
            "zeitüberschreitung"
        })) {
            return _("File transfer timed out. Check your connection and try again.");
        }

        if (contains_any(error, {
            "download source missing"
        })) {
            return _("Download source missing");
        }

        if (contains_any(error, {
            "received media file is empty",
            "media file is empty",
            "empty media",
            "empty stream",
            "stream contains no data",
            "can't typefind empty stream",
            "cant typefind empty stream"
        })) {
            return _("Received media file is empty. Ask the sender to send it again.");
        }

        if (contains_any(error, {
            "hash verification failed",
            "signature does not match",
            "signature missing",
            "signature invalid",
            "wrong signer"
        })) {
            return _("File verification failed. The file was not saved.");
        }

        if (contains_any(error, {
            "no trusted openpgp key",
            "selected openpgp mode"
        })) {
            return _("File verification failed. No trusted OpenPGP key is available for the sender.");
        }

        if (contains_any(error, {
            "decryption",
            "decrypt",
            "aesgcm",
            "esfs",
            "padding",
            "ciphertext",
            "missing omemo receive data"
        })) {
            return _("Encrypted file could not be decrypted.");
        }

        if (contains_any(error, {
            "http upload",
            "upload failed",
            "upload error",
            "upload slot",
            "no sender",
            "no stream",
            "incompatible with file encryption"
        })) {
            return _("File upload failed. Check your connection and try again.");
        }

        if (contains_any(error, {
            "head request",
            "http download",
            "download failed",
            "download url",
            "empty url",
            "malformed url",
            "no file provider",
            "no conversation",
            "no message"
        })) {
            return _("File download failed. Check your connection and try again.");
        }

        if (contains_any(error, {
            "saving file",
            "stored file",
            "not available"
        })) {
            return _("File could not be saved.");
        }

        return _("File transfer failed. See the logs for details.");
    }

    public static string get_missing_download_source_text(bool direct_transfer_unavailable = false) {
        return direct_transfer_unavailable ?
            _("Direct transfer unavailable. Ask the sender to send it again.") :
            _("Download source missing");
    }

    private static bool contains_any(string haystack, string[] needles) {
        foreach (string needle in needles) {
            if (haystack.contains(needle)) return true;
        }
        return false;
    }

    private void on_pointer_entered_event() {
        this.set_cursor_from_name("pointer");
        content_type_image.opacity = 0.7;
        if (state == FileTransfer.State.NOT_STARTED) {
            image_stack.set_visible_child_name("download_image");
        }
        if (state == FileTransfer.State.COMPLETE) {
            file_menu.opacity = 1;
        }
    }

    private void on_pointer_left_event() {
        if (file_menu.popover != null && file_menu.popover.visible) return;

        this.set_cursor(null);
        on_pointer_left();
    }

    private void on_pointer_left() {
        content_type_image.opacity = 0.5;
        if (state == FileTransfer.State.NOT_STARTED) {
            image_stack.set_visible_child_name("content_type_image");
        }
        file_menu.opacity = 0;
    }

    private static string get_file_icon_name(string? mime_type) {
        if (mime_type == null) return "dino-file-symbolic";

        string generic_icon_name = ContentType.get_generic_icon_name(mime_type) ?? "";
        switch (generic_icon_name) {
            case "audio-x-generic": return "dino-file-music-symbolic";
            case "image-x-generic": return "dino-file-image-symbolic";
            case "text-x-generic": return "dino-file-document-symbolic";
            case "text-x-generic-template": return "dino-file-document-symbolic";
            case "video-x-generic": return "dino-file-video-symbolic";
            case "x-office-document": return "dino-file-document-symbolic";
            case "x-office-spreadsheet": return "dino-file-table-symbolic";
            default: return "dino-file-symbolic";
        }
    }

    public static string get_size_string(int64 size) {
        if (size < 0) {
            return _("—");
        } else if (size < 1024) {
            return @"$(size) B";
        } else if (size < 1000 * 1000) {
            return @"$(size / 1000) kB";
        } else if (size < 1000 * 1000 * 1000) {
            return @"$(size / 1000  / 1000) MB";
        } else {
            return @"$(size  / 1000  / 1000  / 1000) GB";
        }
    }
}

public class FileDefaultWidgetController : Object {

    private FileDefaultWidget widget;
    private FileTransfer? file_transfer;
    private StreamInteractor? stream_interactor;
    public string file_transfer_state { get; set; }
    public FileTransfer.Phase file_transfer_phase { get; set; }
    public string? file_transfer_phase_error { get; set; }
    public string file_transfer_mime_type { get; set; }
    public int64 file_transfer_transferred_bytes { get; set; }
    public int64 file_transfer_phase_total_bytes { get; set; default=-1; }

    private FileTransfer.State state;
    private Binding? name_binding2 = null;
    private Binding? state_binding2 = null;
    private Binding? phase_binding2 = null;
    private Binding? phase_error_binding2 = null;
    private Binding? mime_binding2 = null;
    private Binding? bytes_binding2 = null;
    private Binding? phase_total_binding2 = null;
    private ulong notify_ctrl_state_handler_id = 0;
    private ulong notify_ctrl_phase_handler_id = 0;
    private ulong notify_ctrl_phase_error_handler_id = 0;
    private ulong notify_ctrl_mime_handler_id = 0;
    private ulong notify_ctrl_bytes_handler_id = 0;
    private ulong notify_ctrl_phase_total_handler_id = 0;
    private ulong sources_changed_handler_id = 0;

    public FileDefaultWidgetController(FileDefaultWidget widget, StreamInteractor? stream_interactor = null) {
        this.widget = widget;
        this.stream_interactor = stream_interactor;

        widget.clicked.connect(on_clicked);

        notify_ctrl_state_handler_id = this.notify["file-transfer-state"].connect(update_file_info);
        notify_ctrl_phase_handler_id = this.notify["file-transfer-phase"].connect(update_file_info);
        notify_ctrl_phase_error_handler_id = this.notify["file-transfer-phase-error"].connect(update_file_info);
        notify_ctrl_mime_handler_id = this.notify["file-transfer-mime-type"].connect(update_file_info);
        notify_ctrl_bytes_handler_id = this.notify["file-transfer-transferred-bytes"].connect(update_file_info);
        notify_ctrl_phase_total_handler_id = this.notify["file-transfer-phase-total-bytes"].connect(update_file_info);
    }

    public void set_file_transfer(FileTransfer? file_transfer) {
        this.file_transfer = file_transfer;
        if (file_transfer == null) return;

        widget.init_updating_file_info();

        name_binding2 = file_transfer.bind_property("file-name", widget.name_label, "label", BindingFlags.SYNC_CREATE);
        state_binding2 = file_transfer.bind_property("state", this, "file-transfer-state");
        phase_binding2 = file_transfer.bind_property("phase", this, "file-transfer-phase");
        phase_error_binding2 = file_transfer.bind_property("phase-error", this, "file-transfer-phase-error");
        mime_binding2 = file_transfer.bind_property("mime-type", this, "file-transfer-mime-type");
        bytes_binding2 = file_transfer.bind_property("transferred-bytes", this, "file-transfer-transferred-bytes");
        phase_total_binding2 = file_transfer.bind_property("phase-total-bytes", this, "file-transfer-phase-total-bytes");
        sources_changed_handler_id = file_transfer.sources_changed.connect(update_file_info);

        update_file_info();
    }

    private void update_file_info() {
        if (file_transfer == null) return;
        state = file_transfer.state;
        bool source_available = has_download_source();
        widget.update_file_info(file_transfer.mime_type, file_transfer.state, file_transfer.phase, file_transfer.phase_error, file_transfer.direction, file_transfer.size, file_transfer.transferred_bytes, file_transfer.phase_total_bytes, source_available, file_transfer.can_retry_send_attempt(), is_direct_transfer_unavailable(source_available), is_sent_remote_download_offer());
    }

    private bool has_download_source() {
        if (file_transfer == null) return false;
        FileManager? file_manager = get_file_manager();
        if (file_manager != null) return ((!) file_manager).has_usable_download_source(file_transfer);
        if (file_transfer.provider == FileManager.JINGLE_PROVIDER_ID) return false;
        return file_transfer.has_usable_download_source(FileManager.SFS_PROVIDER_ID);
    }

    private bool is_direct_transfer_unavailable(bool has_download_source) {
        return file_transfer != null &&
            file_transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
            file_transfer.provider == FileManager.JINGLE_PROVIDER_ID &&
            !has_download_source;
    }

    private bool is_sent_remote_download_offer() {
        return file_transfer != null &&
            ((!) file_transfer).is_sent_remote_download_offer(FileManager.SFS_PROVIDER_ID, FileManager.HTTP_PROVIDER_ID);
    }

    private FileManager? get_file_manager() {
        if (stream_interactor != null) {
            return ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
        }
        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        if (app == null || app.stream_interactor == null) return null;
        return app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
    }

    private void on_clicked() {
        switch (state) {
            case FileTransfer.State.COMPLETE:
                widget.activate_action("file.open", null);
                break;
            case FileTransfer.State.NOT_STARTED:
                if (!has_download_source()) {
                    warning("FileWidget: download requested but no source is available for %s", file_transfer != null ? file_transfer.file_name : "(none)");
                    return;
                }
                widget.activate_action("file.download", null);
                break;
            case FileTransfer.State.FAILED:
                if (file_transfer != null &&
                    (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED || is_sent_remote_download_offer()) &&
                    has_download_source()) {
                    widget.activate_action("file.download", null);
                } else if (file_transfer != null &&
                    file_transfer.can_retry_send_attempt()) {
                    widget.activate_action("file.download", null);
                }
                break;
            default:
                // Clicking doesn't do anything in IN_PROGRESS states
                break;
        }
    }

    public new void dispose() {
        // Break reference cycles: disconnect this.notify signals
        if (notify_ctrl_state_handler_id != 0) { this.disconnect(notify_ctrl_state_handler_id); notify_ctrl_state_handler_id = 0; }
        if (notify_ctrl_phase_handler_id != 0) { this.disconnect(notify_ctrl_phase_handler_id); notify_ctrl_phase_handler_id = 0; }
        if (notify_ctrl_phase_error_handler_id != 0) { this.disconnect(notify_ctrl_phase_error_handler_id); notify_ctrl_phase_error_handler_id = 0; }
        if (notify_ctrl_mime_handler_id != 0) { this.disconnect(notify_ctrl_mime_handler_id); notify_ctrl_mime_handler_id = 0; }
        if (notify_ctrl_bytes_handler_id != 0) { this.disconnect(notify_ctrl_bytes_handler_id); notify_ctrl_bytes_handler_id = 0; }
        if (notify_ctrl_phase_total_handler_id != 0) { this.disconnect(notify_ctrl_phase_total_handler_id); notify_ctrl_phase_total_handler_id = 0; }
        if (file_transfer != null && sources_changed_handler_id != 0) { file_transfer.disconnect(sources_changed_handler_id); sources_changed_handler_id = 0; }
        if (name_binding2 != null) { name_binding2.unbind(); name_binding2 = null; }
        if (state_binding2 != null) { state_binding2.unbind(); state_binding2 = null; }
        if (phase_binding2 != null) { phase_binding2.unbind(); phase_binding2 = null; }
        if (phase_error_binding2 != null) { phase_error_binding2.unbind(); phase_error_binding2 = null; }
        if (mime_binding2 != null) { mime_binding2.unbind(); mime_binding2 = null; }
        if (bytes_binding2 != null) { bytes_binding2.unbind(); bytes_binding2 = null; }
        if (phase_total_binding2 != null) { phase_total_binding2.unbind(); phase_total_binding2 = null; }
        file_transfer = null;
    }
}

}
