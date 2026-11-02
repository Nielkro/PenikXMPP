using Gee;
using Gdk;
using Gtk;

using Dino.Entities;

namespace Dino.Ui {

[GtkTemplate (ui = "/im/dinox/dinox/file_send_overlay.ui")]
public class FileSendOverlay : Adw.Dialog {

    public signal void send_file(File file, int preferred_file_sender_id);

    [GtkChild] protected unowned Button send_button;
    [GtkChild] protected unowned SizingBin file_widget_insert;
    [GtkChild] protected unowned Label info_label;
    [GtkChild] protected unowned Box transfer_method_box;
    [GtkChild] protected unowned DropDown transfer_method_dropdown;

    private File file;
    private bool can_send = true;
    private int[] transfer_method_sender_ids = {};
    private int preferred_file_sender_id = FileManager.NO_REQUIRED_FILE_SENDER_ID;

    public FileSendOverlay(File file, FileInfo file_info) {
        this.file = file;
        send_button.sensitive = false;
        set_transfer_method_options(false, false);
        transfer_method_dropdown.notify["selected"].connect(update_preferred_file_sender_id);
        load_file_widget.begin(file, file_info);
    }

    [GtkCallback]
    private void on_send_button_clicked() {
        update_preferred_file_sender_id();
        send_file(file, preferred_file_sender_id);
        close();
    }

    private async void load_file_widget(File file, FileInfo file_info) {
        string file_name = Util.sanitize_utf8(file_info.get_display_name());
        string mime_type = Dino.normalize_mime_type(file_info.get_content_type(), file_name);

        bool is_image = Dino.Util.can_preview_image(mime_type, file_name);

        Widget? widget = null;
        if (is_image) {
            FileImageWidget image_widget = new FileImageWidget(
                    FileTransferInput.preview_max_width_for_content(content_width),
                    FileTransferInput.FILE_SEND_PREVIEW_MAX_HEIGHT);
            try {
                yield image_widget.load_from_file(file, file_name);
                widget = image_widget;
            } catch (Error e) {
                warning("FileSendOverlay: Failed to load image preview for %s: %s", file_name, e.message);
            }
        }

        if (widget == null) {
            FileDefaultWidget default_widget = new FileDefaultWidget();
            default_widget.name_label.label = file_name;
            default_widget.set_static_file_info(mime_type);
            widget = default_widget;
        }

        widget.set_parent(file_widget_insert);
    }

    public void set_file_sender_limits(HashMap<int, long> limits, int64 file_size) {
        bool jingle_available = sender_limit_allows(limits, FileManager.JINGLE_PROVIDER_ID, file_size);
        bool http_available = sender_limit_allows(limits, FileManager.HTTP_PROVIDER_ID, file_size);
        set_transfer_method_options(jingle_available, http_available);
        if (can_send) {
            send_button.sensitive = jingle_available || http_available;
        }
    }

    private void set_transfer_method_options(bool jingle_available, bool http_available) {
        int previous_preferred_sender_id = preferred_file_sender_id;
        var model = new StringList(null);
        int[] sender_ids = {};

        model.append(_("Automatic"));
        sender_ids += FileManager.NO_REQUIRED_FILE_SENDER_ID;

        if (jingle_available) {
            model.append(_("Direct transfer"));
            sender_ids += FileManager.JINGLE_PROVIDER_ID;
        }
        if (http_available) {
            model.append(_("Server upload"));
            sender_ids += FileManager.HTTP_PROVIDER_ID;
        }

        transfer_method_sender_ids = (owned) sender_ids;
        transfer_method_dropdown.model = model;
        transfer_method_dropdown.selected = FileTransferInput.selection_for_preferred_sender(
                transfer_method_sender_ids, previous_preferred_sender_id);
        transfer_method_box.visible = FileTransferInput.should_show_transfer_method_choice(
                jingle_available, http_available);
        update_preferred_file_sender_id();
    }

    private static bool sender_limit_allows(HashMap<int, long> limits, int sender_id, int64 file_size) {
        if (!limits.has_key(sender_id)) return false;
        long limit = limits[sender_id];
        return limit >= file_size;
    }

    private void update_preferred_file_sender_id() {
        uint selected = transfer_method_dropdown.selected;
        if (selected < transfer_method_sender_ids.length) {
            preferred_file_sender_id = transfer_method_sender_ids[(int) selected];
        } else {
            preferred_file_sender_id = FileManager.NO_REQUIRED_FILE_SENDER_ID;
        }
    }

    public void set_file_too_large() {
        info_label.label= _("The file exceeds the server's maximum upload size.");
        Util.force_error_color(info_label);
        send_button.sensitive = false;
        can_send = false;
    }

    public void set_no_transfer_method_available() {
        info_label.label= _("The file cannot be sent with the currently available transfer methods.");
        Util.force_error_color(info_label);
        send_button.sensitive = false;
        can_send = false;
    }
}

}
