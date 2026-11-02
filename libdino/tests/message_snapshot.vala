namespace Dino.Test {

class MessageSnapshotTest : Gee.TestCase {
    public MessageSnapshotTest() {
        base("MessageSnapshot");
        add_test("drain_waits_for_all_pipelines_and_holds_new_admission", () => run_case(0));
        add_test("already_cancelled_does_not_close_admission", () => run_case(1));
        add_test("cancellation_releases_waiting_messages", () => run_case(2));
        add_test("timeout_releases_waiting_messages", () => run_case(3));
        add_test("nested_pause_does_not_release_first_barrier", () => run_case(4));
    }

    private void run_case(int scenario) {
        var loop = new MainLoop();
        string? failure = null;
        bool done = false;
        exercise.begin(scenario, (_, result) => {
            try { exercise.end(result); }
            catch (Error e) { failure = e.message; }
            done = true;
            loop.quit();
        });
        uint timeout = 0;
        timeout = Timeout.add_seconds(5, () => {
            timeout = 0;
            failure = "Message snapshot gate test timed out";
            loop.quit();
            return Source.REMOVE;
        });
        if (!done) loop.run();
        if (timeout != 0) Source.remove(timeout);
        fail_if(failure != null, failure ?? "");
    }

    private async void turn() {
        Idle.add(turn.callback);
        yield;
    }

    private void require(bool condition, string reason) throws Error {
        if (!condition) throw new IOError.FAILED(reason);
    }

    private async void exercise(int scenario) throws Error {
        var gate = new MessageSnapshotGate();
        var cancellable = new Cancellable();
        if (scenario == 1) {
            cancellable.cancel();
            bool rejected = false;
            try { yield gate.pause(cancellable); } catch (IOError.CANCELLED expected) { rejected = true; }
            require(rejected && !gate.held, "Already-cancelled pause closed admission");
            yield gate.enter();
            gate.leave();
            return;
        }
        if (scenario == 4) {
            yield gate.pause(cancellable);
            bool rejected = false;
            try { yield gate.pause(); } catch (IOError.BUSY expected) { rejected = true; }
            require(rejected && gate.held, "Nested pause released the first barrier");
            gate.resume();
            return;
        }

        yield gate.enter();
        if (scenario == 0) yield gate.enter();
        bool paused = false;
        bool cancelled = false;
        bool timed_out = false;
        string? failure = null;
        SourceFunc? pause_finished = null;
        gate.pause.begin(cancellable, scenario == 3 ? 20 : 1000, (_, result) => {
            try { gate.pause.end(result); paused = true; }
            catch (IOError.CANCELLED expected) { cancelled = true; }
            catch (IOError.TIMED_OUT expected) { timed_out = true; }
            catch (Error e) { failure = e.message; }
            if (pause_finished != null) Idle.add((owned) pause_finished);
        });
        require(gate.held && !paused, "Pause did not wait for an active receive pipeline");
        bool admitted = false;
        gate.enter.begin((_, result) => { gate.enter.end(result); admitted = true; });
        if (scenario != 3) yield turn();
        require(!admitted, "New message entered while the snapshot barrier was held");

        if (scenario == 0) {
            gate.leave();
            yield turn();
            require(!paused && !admitted, "Snapshot began before every pipeline completed");
            pause_finished = exercise.callback;
            gate.leave();
            yield;
            require(paused && !admitted && gate.active_count == 0, "Drain failed to establish a stable snapshot boundary");
            gate.resume();
            yield turn();
            yield turn();
            require(admitted && gate.active_count == 1, "Resume lost a held incoming message");
            gate.leave();
        } else {
            pause_finished = exercise.callback;
            if (scenario == 2) cancellable.cancel();
            yield;
            yield turn();
            require(failure == null && !paused && !gate.held && admitted,
                "Failed pause did not release new message admission");
            require(scenario == 2 ? cancelled : timed_out, "Incorrect pause failure result");
            gate.leave();
            gate.leave();
        }
        require(gate.active_count == 0 && !gate.held, "Message pipeline accounting leaked");
    }
}

}
