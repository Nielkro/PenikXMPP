using GLib;

namespace Dino {

public class PrefixSniffingInputStream : InputStream {
    private InputStream inner;
    private int max_prefix_bytes;
    private uint8[] prefix = new uint8[0];
    private int64 passed_bytes = 0;

    public PrefixSniffingInputStream(InputStream inner, int max_prefix_bytes = 8192) {
        this.inner = inner;
        this.max_prefix_bytes = int.max(0, max_prefix_bytes);
    }

    public uint8[] get_prefix() {
        uint8[] copy = new uint8[prefix.length];
        if (prefix.length > 0) {
            Memory.copy(copy, prefix, prefix.length);
        }
        return copy;
    }

    public int64 get_passed_bytes() {
        return passed_bytes;
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        ssize_t read_bytes = inner.read(buffer, cancellable);
        capture_prefix(buffer, read_bytes);
        return read_bytes;
    }

    public override async ssize_t read_async(uint8[]? buffer, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        ssize_t read_bytes = yield inner.read_async(buffer, io_priority, cancellable);
        if (buffer != null) capture_prefix((!) buffer, read_bytes);
        return read_bytes;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return inner.close(cancellable);
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }

    private void capture_prefix(uint8[] buffer, ssize_t read_bytes) {
        if (read_bytes <= 0) return;

        passed_bytes += read_bytes;
        if (prefix.length >= max_prefix_bytes) return;

        int remaining = max_prefix_bytes - prefix.length;
        int to_copy = int.min(remaining, (int) read_bytes);
        if (to_copy <= 0) return;

        uint8[] next = new uint8[prefix.length + to_copy];
        if (prefix.length > 0) {
            Memory.copy(next, prefix, prefix.length);
        }
        Memory.copy((void*) ((uint8*) next + prefix.length), buffer, (size_t) to_copy);
        prefix = next;
    }
}

}
