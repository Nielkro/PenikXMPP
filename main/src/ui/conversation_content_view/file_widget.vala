using Gee;
using Gdk;
using Gtk;
using Pango;

using Dino.Entities;
using Dino.Security;

namespace Dino.Ui {

public class FileWidget : SizeRequestBin {

    enum State {
        IMAGE,
        VIDEO,
        AUDIO,
        DEFAULT
    }

    private FileTransfer? file_transfer;
    private StreamInteractor? stream_interactor;
    public FileTransfer.State file_transfer_state { get; set; }
    public string file_transfer_mime_type { get; set; }
    private State? state = null;

    private FileDefaultWidgetController default_widget_controller;
    private FileContextMenu? context_menu;
    private Widget? content = null;
    private Binding? state_binding = null;
    private Binding? mime_binding = null;
    private ulong notify_ft_state_handler_id = 0;
    private ulong notify_ft_mime_handler_id = 0;
    private Cancellable thumbnail_cancellable = new Cancellable();
    private bool thumbnail_started = false;
    private Gdk.Pixbuf? thumbnail_preview;

    public signal void open_file();
    public signal void save_file_as();
    public signal void start_download();
    public signal void cancel_download();

    class construct {
        install_action("file.open", null, (widget, action_name) => { ((FileWidget) widget).open_file(); });
        install_action("file.save_as", null, (widget, action_name) => { ((FileWidget) widget).save_file_as(); });
        install_action("file.download", null, (widget, action_name) => { ((FileWidget) widget).start_download(); });
        install_action("file.cancel", null, (widget, action_name) => { ((FileWidget) widget).cancel_download(); });
    }

    construct {
        margin_top = 4;
        size_request_mode = SizeRequestMode.HEIGHT_FOR_WIDTH;
    }

    public FileWidget(FileTransfer? file_transfer = null, StreamInteractor? stream_interactor = null) {
        this.file_transfer = file_transfer;
        this.stream_interactor = stream_interactor;

        if (file_transfer == null) return;

        start_update_widget();
//        size_allocate.connect((allocation) => {
//            if (allocation.height > parent.get_allocated_height()) {
//                Idle.add(() => { parent.queue_resize(); return false; });
//            }
//        });

        state_binding = file_transfer.bind_property("state", this, "file-transfer-state");
        mime_binding = file_transfer.bind_property("mime-type", this, "file-transfer-mime-type");

        notify_ft_state_handler_id = this.notify["file-transfer-state"].connect(start_update_widget);
        notify_ft_mime_handler_id = this.notify["file-transfer-mime-type"].connect(start_update_widget);
    }

    private void start_update_widget() {
        update_widget.begin((obj, res) => {
            update_widget.end(res);
        });
    }

    private async void update_widget() {
        if (file_transfer == null) return;
        string? normalized_mime_type = Dino.normalize_display_mime_type(file_transfer.mime_type, file_transfer.file_name);
        if (normalized_mime_type != null &&
            normalized_mime_type != "application/octet-stream" &&
            normalized_mime_type != file_transfer.mime_type) {
            file_transfer.mime_type = normalized_mime_type;
        }

        bool show_video = normalized_mime_type != null &&
            normalized_mime_type.ascii_down().has_prefix("video/") &&
            file_transfer.state == FileTransfer.State.COMPLETE;
        bool show_audio = normalized_mime_type != null &&
            normalized_mime_type.ascii_down().has_prefix("audio/") &&
            file_transfer.state == FileTransfer.State.COMPLETE;
        // Dedicated players own their menu, including when used without this wrapper.
        if (show_video || show_audio) {
            if (context_menu != null) { context_menu.dispose(); context_menu = null; }
        } else if (context_menu == null) {
            context_menu = new FileContextMenu(this, file_transfer, stream_interactor);
        }
        if (show_video && state != State.VIDEO) {
            clear_content();
            content = new ConversationSummary.VideoPlayerWidget(file_transfer, stream_interactor);
            state = State.VIDEO;
            content.insert_after(this, null);
            return;
        }

        if (show_audio && state != State.AUDIO) {
            clear_content();
            content = new ConversationSummary.AudioPlayerWidget(file_transfer, stream_interactor);
            state = State.AUDIO;
            content.insert_after(this, null);
            return;
        }

        if (show_video || show_audio) return;
        bool show_image = FileImageWidget.can_display(file_transfer, thumbnail_preview);

        if (show_image && !show_video && state != State.IMAGE) {
            var content_bak = content;

            FileImageWidget file_image_widget = null;
            file_image_widget = new FileImageWidget();
            yield file_image_widget.set_file_transfer(file_transfer, thumbnail_preview);

            // If the widget changed in the meanwhile, stop
            if (content != content_bak) {
                file_image_widget.dispose();
                return;
            }

            clear_content();
            content = file_image_widget;
            state = State.IMAGE;
            content.insert_after(this, null);
            return;
        }

        if (!show_image && state != State.DEFAULT) {
            clear_content();
            FileDefaultWidget default_file_widget = new FileDefaultWidget();
            default_widget_controller = new FileDefaultWidgetController(default_file_widget, stream_interactor);
            default_widget_controller.set_file_transfer(file_transfer);
            content = default_file_widget;
            this.state = State.DEFAULT;
            content.insert_after(this, null);
        }
        if (!thumbnail_started && file_transfer.state != FileTransfer.State.COMPLETE &&
                file_transfer.thumbnails.size > 0 && normalized_mime_type != null &&
                normalized_mime_type.has_prefix("image/")) {
            thumbnail_started = true;
            // Keep the ordinary file card, Download and Copy Link usable while
            // the optional embedded thumbnail is decoded off the GTK thread.
            prepare_thumbnail(this);
        }
    }

    private static void prepare_thumbnail(FileWidget owner) {
        var weak_widget = WeakRef(owner);
        Util.get_thumbnail_preview_async.begin(owner.file_transfer.thumbnails, owner.thumbnail_cancellable, (obj, res) => {
            var preview = Util.get_thumbnail_preview_async.end(res);
            var widget = weak_widget.get() as FileWidget;
            if (widget == null || widget.file_transfer == null || widget.thumbnail_cancellable.is_cancelled()) return;
            widget.thumbnail_preview = preview;
            if (preview != null) widget.start_update_widget();
        });
    }

    private void clear_content() {
        if (default_widget_controller != null) {
            default_widget_controller.dispose();
            default_widget_controller = null;
        }
        if (content != null) {
            content.unparent();
            content.dispose();
            content = null;
        }
    }

    public override void dispose() {
        thumbnail_cancellable.cancel();
        thumbnail_preview = null;
        if (context_menu != null) { context_menu.dispose(); context_menu = null; }
        // Break reference cycles: disconnect this.notify signals
        if (notify_ft_state_handler_id != 0) { this.disconnect(notify_ft_state_handler_id); notify_ft_state_handler_id = 0; }
        if (notify_ft_mime_handler_id != 0) { this.disconnect(notify_ft_mime_handler_id); notify_ft_mime_handler_id = 0; }
        if (state_binding != null) { state_binding.unbind(); state_binding = null; }
        if (mime_binding != null) { mime_binding.unbind(); mime_binding = null; }
        file_transfer = null;
        clear_content();
        base.dispose();
    }
}

}
