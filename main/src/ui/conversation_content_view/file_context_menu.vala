using Gtk;
using Dino.Entities;

namespace Dino.Ui {

// File information and source access also work before downloading the file.
internal class FileContextMenu : Object {
    private weak Widget widget;
    private FileTransfer transfer;
    private StreamInteractor? stream_interactor;
    private PopoverMenu? popover;
    private SimpleActionGroup actions = new SimpleActionGroup();
    private SimpleAction copy_link = new SimpleAction("copy-link", null);
    private GestureClick click;
    private ShortcutController shortcuts;
    private ulong metadata_handler;
    private ulong unmap_handler;
    private uint popup_source;
    private bool pending;
    private int pointer_x;
    private int pointer_y;
    private bool disposed;

    public FileContextMenu(Widget widget, FileTransfer transfer, StreamInteractor? stream_interactor = null) {
        this.widget = widget;
        this.transfer = transfer;
        this.stream_interactor = stream_interactor;
        copy_link.activate.connect(on_copy_link);
        actions.add_action(copy_link);
        var popup = new SimpleAction("popup", null);
        popup.activate.connect(on_keyboard_popup);
        actions.add_action(popup);
        widget.insert_action_group("file-details", actions);
        click = new GestureClick() { button = Gdk.BUTTON_SECONDARY, propagation_phase = PropagationPhase.CAPTURE };
        click.pressed.connect(on_pressed);
        click.released.connect(on_released);
        click.cancel.connect(cancel_pending);
        widget.add_controller(click);
        shortcuts = new ShortcutController();
        shortcuts.add_shortcut(new Shortcut(new KeyvalTrigger(Gdk.Key.Menu, 0), new NamedAction("file-details.popup")));
        shortcuts.add_shortcut(new Shortcut(new KeyvalTrigger(Gdk.Key.F10, Gdk.ModifierType.SHIFT_MASK), new NamedAction("file-details.popup")));
        widget.add_controller(shortcuts);
        widget.focusable = true;
        unmap_handler = widget.unmap.connect(on_unmap);
        metadata_handler = transfer.notify.connect((property) => {
            if (property.name == "file-name" || property.name == "mime-type" || property.name == "size") update_tooltip();
        });
        update_tooltip();
    }

    private void update_tooltip() {
        if (disposed || widget == null) return;
        string detail = Util.sanitize_utf8(transfer.file_name ?? "");
        if (transfer.mime_type != null && transfer.mime_type != "") detail += "\n" + Util.sanitize_utf8(transfer.mime_type);
        if (transfer.size >= 0) detail += "\n" + FileDefaultWidget.get_size_string(transfer.size);
        widget.tooltip_text = detail;
        if (popover != null && popover.visible) widget.has_tooltip = false;
    }

    internal string? get_link() {
        // Use stored provider data only: no HEAD/GET, decrypt or file open.
        FileManager? manager = stream_interactor != null ? stream_interactor.get_module<FileManager>(FileManager.IDENTITY) : null;
        FileProvider? provider = manager != null ? manager.select_file_provider(transfer) : null;
        if (provider != null) {
            var data = provider.get_file_receive_data(transfer) as HttpFileReceiveData;
            if (data != null) return checked_link(data.url);
        }
        if (transfer.provider == FileManager.SFS_PROVIDER_ID) {
            foreach (var source in transfer.sfs_sources) {
                var http = source as Xmpp.Xep.StatelessFileSharing.HttpSource;
                if (http != null) return checked_link(http.url);
                var encrypted = source as Xmpp.Xep.StatelessFileSharing.EsfsHttpSource;
                if (encrypted != null) return checked_link(encrypted.url);
            }
        } else if (transfer.provider == FileManager.HTTP_PROVIDER_ID && transfer.info != null && transfer.info.has_prefix("url:")) {
            return checked_link(transfer.info.substring(4));
        }
        return null;
    }

    private static string? checked_link(string? value) {
        if (value == null || value.strip() == "") return null;
        string link = value.strip();
        try {
            var uri = Uri.parse(link, UriFlags.NONE);
            string? scheme = uri.get_scheme();
            if (uri.get_host() == null || !(scheme == "https" || scheme == "http" || scheme == "aesgcm")) return null;
            return link;
        } catch (Error error) { return null; }
    }

    private void on_copy_link() {
        if (disposed || widget == null) return;
        string? link = get_link();
        if (link != null) widget.get_clipboard().set_text(link);
    }

    private void on_keyboard_popup() {
        if (widget != null) show_menu(widget.get_width() / 2, widget.get_height() / 2);
    }

    private void on_pressed(int presses, double x, double y) {
        cancel_pending();
        pending = true;
        pointer_x = (int) x;
        pointer_y = (int) y;
        click.set_state(EventSequenceState.CLAIMED);
    }

    private void on_released() {
        if (!pending || popup_source != 0) return;
        popup_source = queue_popup(this);
    }

    private static uint queue_popup(FileContextMenu owner) {
        var owner_ref = WeakRef(owner);
        return Idle.add(() => {
            var menu = owner_ref.get() as FileContextMenu;
            if (menu != null) {
                menu.popup_source = 0;
                bool show = menu.pending;
                menu.pending = false;
                if (show) menu.show_menu(menu.pointer_x, menu.pointer_y);
            }
            return Source.REMOVE;
        });
    }

    private void show_menu(int x, int y) {
        if (disposed || widget == null || !widget.get_mapped()) return;
        copy_link.set_enabled(get_link() != null);
        if (popover == null) {
            var model = new GLib.Menu();
            model.append(_("Copy Link"), "file-details.copy-link");
            popover = new PopoverMenu.from_model(model);
            popover.set_parent(widget);
            popover.closed.connect(on_menu_closed);
        }
        widget.has_tooltip = false;
        widget.trigger_tooltip_query();
        popover.set_pointing_to({ x, y, 1, 1 });
        popover.popup();
    }

    private void on_menu_closed() {
        if (!disposed && widget != null) widget.has_tooltip = true;
    }

    private void cancel_pending() {
        pending = false;
        if (popup_source != 0) Source.remove(popup_source);
        popup_source = 0;
    }

    private void on_unmap() {
        cancel_pending();
        if (popover != null) popover.popdown();
    }

    public override void dispose() {
        if (disposed) { base.dispose(); return; }
        disposed = true;
        cancel_pending();
        if (metadata_handler != 0) transfer.disconnect(metadata_handler);
        metadata_handler = 0;
        if (popover != null) {
            Util.clear_focus_before_detach(popover);
            popover.popdown();
            popover.unparent();
            popover = null;
        }
        if (widget != null) {
            if (unmap_handler != 0) widget.disconnect(unmap_handler);
            widget.tooltip_text = null;
            widget.insert_action_group("file-details", null);
            widget.remove_controller(click);
            widget.remove_controller(shortcuts);
        }
        unmap_handler = 0;
        base.dispose();
    }
}

}
