using GLib;

namespace Dino {

public class ProgressOutputStream : OutputStream {
    private OutputStream inner;

    private int64 _written_bytes = 0;
    private int64 last_update_time = 0;
    private bool notify_queued = false;

    public int64 written_bytes {
        get { return _written_bytes; }
        private set { _written_bytes = value; }
    }

    public ProgressOutputStream(OutputStream inner) {
        this.inner = inner;
    }

    private void update_written(ssize_t bytes) {
        _written_bytes += bytes;

        int64 now = GLib.get_monotonic_time();
        if (now - last_update_time > 100 * 1000 && !notify_queued) {
            last_update_time = now;
            notify_queued = true;
            Idle.add(() => {
                notify_queued = false;
                notify_property("written-bytes");
                return Source.REMOVE;
            });
        }
    }

    public override ssize_t write(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        ssize_t written = inner.write(buffer, cancellable);
        if (written > 0) update_written(written);
        return written;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return inner.close(cancellable);
    }

    public override async bool close_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }
}

}
