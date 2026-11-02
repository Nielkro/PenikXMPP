namespace Dino.Plugins.OpenPgp {

class TransferTempDirectory : Object {
    public string path { get; private set; }

    public TransferTempDirectory(string prefix) throws FileError {
        this.path = DirUtils.make_tmp(prefix + "-XXXXXX");
    }

    public string child(string name) {
        return Path.build_filename(path, name);
    }

    public void remove_if_empty() {
        DirUtils.remove(path);
    }
}

// Used for OpenPGP send-side encrypted temporary output. Receive-side
// plaintext streams are owned by Dino.FileManager.
internal class TempFileInputStream : DinoNative.InputStream {
    private File file;
    private FileInputStream inner;
    private string? temp_directory;
    private bool closed = false;

    public TempFileInputStream(File file, string? temp_directory = null) throws Error {
        this.file = file;
        this.temp_directory = temp_directory;
        this.inner = file.read();
    }

    public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        return inner.read(buffer, cancellable);
    }

    public override async ssize_t read_async([CCode (type = "void*")] uint8[]? buffer, int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.read_async(buffer, io_priority, cancellable);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        if (closed) return true;
        closed = true;

        IOError? close_error = null;
        try {
            inner.close(cancellable);
        } catch (IOError e) {
            close_error = e;
        }

        delete_temp_file();

        if (close_error != null) throw (!) close_error;
        return true;
    }

    public override async bool close_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (closed) return true;
        closed = true;

        IOError? close_error = null;
        try {
            yield inner.close_async(io_priority, cancellable);
        } catch (IOError e) {
            close_error = e;
        }

        delete_temp_file();

        if (close_error != null) throw (!) close_error;
        return true;
    }

    private void delete_temp_file() {
        string? path = file.get_path();
        if (path != null && path != "") {
            GPGHelper.secure_delete_file(path);
        }
        if (temp_directory != null) {
            DirUtils.remove((!) temp_directory);
            temp_directory = null;
        }
    }
}

}
