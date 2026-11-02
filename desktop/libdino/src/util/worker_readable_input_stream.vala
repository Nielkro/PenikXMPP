using GLib;

namespace Dino {

internal class WorkerReadableInputStream : InputStream {
    private const int64 DISPATCH_TIMEOUT_USEC = 5 * 1000 * 1000;

    private InputStream inner;
    private MainContext async_context;
    private int64 owner_thread_id;

    public WorkerReadableInputStream(InputStream inner) {
        this.inner = inner;
        this.async_context = MainContext.ref_thread_default();
        this.owner_thread_id = (int64) Thread.self<void*>();
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        if (buffer.length == 0) return 0;
        reject_owner_thread_sync_io();

        var state = new WorkerReadableInputStreamState();

        dispatch_to_async_context(() => {
            if (!state.mark_started()) return Source.REMOVE;
            inner.read_async.begin(buffer, Priority.LOW, cancellable, (_, res) => {
                try {
                    state.complete_read(inner.read_async.end(res), null);
                } catch (IOError e) {
                    state.complete_read(0, e);
                }
            });
            return Source.REMOVE;
        });

        wait_for_dispatch_start(state, "read");
        state.wait_until_done();

        if (state.failure != null) throw (!) state.failure;
        return state.read_result;
    }

    public override async ssize_t read_async(uint8[]? buffer, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.read_async(buffer, io_priority, cancellable);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        reject_owner_thread_sync_io();

        var state = new WorkerReadableInputStreamState();

        dispatch_to_async_context(() => {
            if (!state.mark_started()) return Source.REMOVE;
            inner.close_async.begin(Priority.LOW, cancellable, (_, res) => {
                try {
                    state.complete_close(inner.close_async.end(res), null);
                } catch (IOError e) {
                    state.complete_close(false, e);
                }
            });
            return Source.REMOVE;
        });

        wait_for_dispatch_start(state, "close");
        state.wait_until_done();

        if (state.failure != null) throw (!) state.failure;
        return state.close_result;
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }

    private void reject_owner_thread_sync_io() throws IOError {
        if ((int64) Thread.self<void*>() == owner_thread_id) {
            throw new IOError.WOULD_BLOCK("worker-readable stream cannot run synchronous I/O on its async owner thread");
        }
    }

    private void wait_for_dispatch_start(WorkerReadableInputStreamState state, string operation) {
        int64 end_time = get_monotonic_time() + DISPATCH_TIMEOUT_USEC;
        state.mutex.lock();
        while (!state.started && !state.done) {
            if (!state.cond.wait_until(state.mutex, end_time)) {
                state.complete_locked(new IOError.WOULD_BLOCK(
                        "worker-readable stream async %s did not start on its owner context".printf(operation)));
                break;
            }
        }
        state.mutex.unlock();
    }

    private void dispatch_to_async_context(owned SourceFunc func) {
        var source = new IdleSource();
        source.set_callback((owned) func);
        source.attach(async_context);
    }
}

private class WorkerReadableInputStreamState : Object {
    public Mutex mutex = Mutex();
    public Cond cond = Cond();
    public bool started = false;
    public bool done = false;
    public ssize_t read_result = 0;
    public bool close_result = false;
    public IOError? failure = null;

    public bool mark_started() {
        mutex.lock();
        try {
            if (done) return false;
            started = true;
            cond.signal();
            return true;
        } finally {
            mutex.unlock();
        }
    }

    public void complete_read(ssize_t result, IOError? error) {
        mutex.lock();
        try {
            if (done) return;
            read_result = result;
            complete_locked(error);
        } finally {
            mutex.unlock();
        }
    }

    public void complete_close(bool result, IOError? error) {
        mutex.lock();
        try {
            if (done) return;
            close_result = result;
            complete_locked(error);
        } finally {
            mutex.unlock();
        }
    }

    public void complete_locked(IOError? error) {
        done = true;
        failure = error;
        cond.signal();
    }

    public void wait_until_done() {
        mutex.lock();
        while (!done) {
            cond.wait(mutex);
        }
        mutex.unlock();
    }
}

}
