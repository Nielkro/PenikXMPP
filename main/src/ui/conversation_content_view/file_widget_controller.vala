using Gee;
using Gtk;

using Dino.Entities;

namespace Dino.Ui {

public interface FileOpenLauncher : Object {
    public abstract void launch(File file) throws Error;
}

public interface FileSaveTargetPicker : Object {
    public abstract async File? pick_save_target(Gtk.Window? parent, string title, string initial_name) throws Error;
}

private class DefaultFileOpenLauncher : Object, FileOpenLauncher {
    public void launch(File file) throws Error {
#if WINDOWS
        string? path = file.get_path();
        if (path == null || path == "") {
            throw new IOError.FAILED("Cannot open file without local path");
        }
        if (!SystrayWin32.open_file(path)) {
            throw new IOError.FAILED("Windows could not open the file with the default application");
        }
#else
        AppInfo.launch_default_for_uri(file.get_uri(), null);
#endif
    }
}

private class DefaultFileSaveTargetPicker : Object, FileSaveTargetPicker {
    public async File? pick_save_target(Gtk.Window? parent, string title, string initial_name) throws Error {
        var save_dialog = new Gtk.FileDialog();
        save_dialog.title = title;
        save_dialog.initial_name = initial_name;
        return yield save_dialog.save(parent, null);
    }
}

public class FileWidgetController : Object {

    private weak Widget widget;
    private FileTransfer file_transfer;
    private StreamInteractor? stream_interactor;
    private FileOpenLauncher file_open_launcher;
    private FileSaveTargetPicker file_save_target_picker;
    private Gee.ArrayList<Dino.PlaintextFileLease> plaintext_leases = new Gee.ArrayList<Dino.PlaintextFileLease>();
    private bool disposed = false;

    public FileWidgetController(FileWidget widget, FileTransfer file_transfer, StreamInteractor? stream_interactor = null, FileOpenLauncher? file_open_launcher = null, FileSaveTargetPicker? file_save_target_picker = null) {
        this.widget = widget;
        this.ref();
        this.widget.weak_ref(() => {
            disposed = true;
            cleanup_temp_open_files();
            this.widget = null;
            this.unref();
        });
        this.file_transfer = file_transfer;
        this.stream_interactor = stream_interactor;
        this.file_open_launcher = file_open_launcher ?? new DefaultFileOpenLauncher();
        this.file_save_target_picker = file_save_target_picker ?? new DefaultFileSaveTargetPicker();

        widget.open_file.connect(start_open_file);
        widget.save_file_as.connect(start_save_file);
        widget.start_download.connect(start_download);
        widget.cancel_download.connect(cancel_download);

        FileManager? file_manager = get_file_manager();
        if (file_manager != null) {
            ((!) file_manager).arm_scheduled_transfer_retry(file_transfer);
        }
    }

    public override void dispose() {
        disposed = true;
        cleanup_temp_open_files();
        base.dispose();
    }

    private void start_open_file() {
        if (disposed) return;
        open_file.begin((obj, res) => {
            open_file.end(res);
        });
    }

    private async void open_file() {
        if (disposed) return;
        if (!file_transfer.is_plaintext_release_allowed()) return;

        try{
            FileManager? file_manager = get_file_manager();
            if (file_manager == null) return;

            Dino.PlaintextFileLease lease = yield ((!) file_manager).create_plaintext_file_lease(file_transfer, "open");
            if (disposed || widget == null || !file_transfer.is_plaintext_release_allowed()) {
                lease.release();
                return;
            }
            plaintext_leases.add(lease);
            file_open_launcher.launch(lease.file);
        } catch (Error err) {
            File? err_file = (file_transfer != null) ? file_transfer.get_file() : null;
            warning("Failed to open %s - %s", err_file != null ? err_file.get_uri() : "(null)", err.message);
        }
    }

    private void start_save_file() {
        if (disposed) return;
        if (!file_transfer.is_plaintext_release_allowed()) return;

        save_file.begin((obj, res) => {
            save_file.end(res);
        });
    }

    private async void save_file() {
        if (disposed) return;
        if (!file_transfer.is_plaintext_release_allowed()) return;

        try {
            File? target_file = yield file_save_target_picker.pick_save_target(
                widget != null ? ((!) widget).get_root() as Gtk.Window : null,
                _("Save as…"),
                file_transfer.file_name);
            if (disposed || target_file == null || !file_transfer.is_plaintext_release_allowed()) return;

            FileManager? file_manager = get_file_manager();
            if (!disposed && file_manager != null) {
                yield ((!) file_manager).export_plaintext_file(file_transfer, (!) target_file);
            }
        } catch (Error e) {
            warning("Failed to save file: %s", e.message);
        }
    }

    private void start_download() {
        if (disposed) return;
        FileManager? file_manager = get_file_manager();
        if (file_manager != null) {
            if (file_transfer.direction == FileTransfer.DIRECTION_SENT &&
                    !file_transfer.is_sent_remote_download_offer(FileManager.SFS_PROVIDER_ID, FileManager.HTTP_PROVIDER_ID)) {
                if (!file_transfer.can_retry_send_attempt()) return;
                ((!) file_manager).retry_send_file.begin(file_transfer);
            } else {
                if (!((!) file_manager).has_usable_download_source(file_transfer)) return;
                ((!) file_manager).download_file.begin(file_transfer);
            }
        }
    }

    private void cancel_download() {
        if (disposed) return;
        FileManager? file_manager = get_file_manager();
        if (file_manager != null) {
            ((!) file_manager).cancel_download(file_transfer);
        } else {
            file_transfer.cancellable.cancel();
        }
    }

    private FileManager? get_file_manager() {
        if (disposed) return null;
        if (stream_interactor != null) {
            return ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
        }

        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        if (app == null || app.stream_interactor == null) return null;
        return app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
    }

    private void cleanup_temp_open_files() {
        foreach (Dino.PlaintextFileLease lease in plaintext_leases) {
            lease.release();
        }
        plaintext_leases.clear();
    }
}

}
