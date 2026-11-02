namespace Dino {

/** Main-context admission barrier: drain complete receive pipelines before a
 * synchronous set of core/plugin snapshots. No database or protocol mutations. */
internal class MessageSnapshotGate : Object {
    private enum Result { READY, CANCELLED, TIMED_OUT }

    private class Waiter : Object {
        public Result result = Result.READY;
        private bool completed = false;
        private SourceFunc? callback;

        public Waiter(owned SourceFunc callback) { this.callback = (owned) callback; }

        public void complete(Result result) {
            if (completed) return;
            completed = true;
            this.result = result;
            Idle.add(() => {
                SourceFunc? resume = (owned) callback;
                if (resume != null) ((!) resume)();
                return Source.REMOVE;
            });
        }
    }

    internal uint active_count { get; private set; default = 0; }
    internal bool held { get; private set; default = false; }
    private Gee.ArrayList<Waiter> incoming = new Gee.ArrayList<Waiter>();
    private Waiter? drain_waiter;

    public async void enter() {
        while (held) {
            var waiter = new Waiter(enter.callback);
            incoming.add(waiter);
            yield;
            incoming.remove(waiter);
        }
        active_count++;
    }

    public void leave() {
        assert(active_count > 0);
        active_count--;
        if (active_count == 0 && drain_waiter != null) drain_waiter.complete(Result.READY);
    }

    public async void pause(Cancellable? cancellable = null, uint timeout_ms = 15000) throws Error {
        if (held) throw new IOError.BUSY("A message snapshot barrier is already active");
        if (cancellable != null) cancellable.set_error_if_cancelled();
        held = true;
        if (active_count == 0) return;

        var waiter = new Waiter(pause.callback);
        drain_waiter = waiter;
        uint timeout = 0;
        timeout = Timeout.add(timeout_ms, () => {
            timeout = 0;
            waiter.complete(Result.TIMED_OUT);
            return Source.REMOVE;
        });
        ulong cancel_handler = 0;
        if (cancellable != null) {
            cancel_handler = cancellable.cancelled.connect(() => {
                // Cancellation can originate on a worker thread. The waiter
                // and gate are exclusively owned by the application context.
                Idle.add(() => { waiter.complete(Result.CANCELLED); return Source.REMOVE; });
            });
            // Covers cancellation between the initial check and connecting.
            if (cancellable.is_cancelled()) waiter.complete(Result.CANCELLED);
        }
        yield;
        drain_waiter = null;
        if (timeout != 0) Source.remove(timeout);
        if (cancellable != null && cancel_handler != 0) SignalHandler.disconnect(cancellable, cancel_handler);
        if (!held || waiter.result != Result.READY || (cancellable != null && cancellable.is_cancelled())) {
            resume();
            if (waiter.result == Result.TIMED_OUT) throw new IOError.TIMED_OUT("Messages did not finish before the snapshot deadline");
            throw new IOError.CANCELLED("Message snapshot barrier was cancelled");
        }
    }

    public void resume() {
        if (!held) return;
        held = false;
        if (drain_waiter != null) drain_waiter.complete(Result.CANCELLED);
        foreach (var waiter in incoming) waiter.complete(Result.READY);
        incoming.clear();
    }
}

}
