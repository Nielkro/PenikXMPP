namespace Dino.Test {

class MucOccupantWorkerAudit : Gee.TestCase {
    private const string ACCOUNT = "alice@example.test";
    private const string ROOM = "room@conference.example.test";

    public MucOccupantWorkerAudit() {
        base("MucOccupantWorkerAudit");
        add_test("worker_reduces_fifo_off_main_and_delivers_on_main",
            test_worker_thread_fifo_and_delivery);
        add_test("per_room_backpressure_is_bounded_and_degraded",
            test_per_room_backpressure);
        add_test("control_presence_evicts_available_but_is_preserved",
            test_control_presence_preserved);
        add_test("eviction_marks_finish_snapshot_degraded_before_publish",
            test_eviction_precedes_finish_snapshot);
        add_test("leave_rejoin_generation_rejects_stale_work",
            test_leave_rejoin_generation);
        add_test("main_context_drain_uses_bounded_batches",
            test_bounded_main_drain);
        add_test("shadow_mode_emits_only_full_snapshot",
            test_shadow_snapshot_only);
        add_test("live_changes_coalesce_until_flush",
            test_live_changes_coalesce_until_flush);
        add_test("live_flush_rejects_stale_room_generation",
            test_live_flush_rejects_stale_generation);
        add_test("live_batch_keeps_canonical_full_jid_nick",
            test_live_batch_keeps_canonical_full_jid_nick);
    }

    private void test_worker_thread_fifo_and_delivery() {
        int64 caller_thread_id = (int64) Thread.self<void*>();
        var worker = new MucOccupantWorker(null, 32, 16, 32, 8, false);
        var changed_ids = new Gee.ArrayList<string>();
        int64 callback_thread_id = 0;
        worker.delta_ready.connect((delta) => {
            callback_thread_id = (int64) Thread.self<void*>();
            if (!delta.initial_sync_finished && delta.changed_count > 0) {
                changed_ids.add(delta.changed_at(0).occupant_full_jid);
            }
        });

        MucRoomKey room = room_key(1);
        fail_if(!worker.start_room(room), "Room start must enter the bounded control queue");
        fail_if(!worker.enqueue(available(room, 1, "anna")), "First presence must be accepted");
        fail_if(!worker.enqueue(available(room, 2, "bert")), "Second presence must be accepted");
        fail_if(!worker.enqueue(available(room, 3, "carla")), "Third presence must be accepted");
        fail_if(!worker.finish_room(room), "Initial-sync completion must be preserved");

        worker.start();
        wait_until_flushed(worker);

        MucOccupantWorkerStats stats = worker.get_stats();
        fail_if(stats.worker_thread_id == 0 || stats.worker_thread_id == caller_thread_id,
            "Reducer work must run on the dedicated worker thread");
        fail_if(callback_thread_id != caller_thread_id,
            "Worker deltas must be emitted on the caller main context");
        fail_if(changed_ids.size != 3,
            "Every accepted display-changing presence must emit one ordered delta");
        if (changed_ids.size == 3) {
            fail_if_not_eq_str(changed_ids[0], ROOM + "/anna", "First FIFO occupant");
            fail_if_not_eq_str(changed_ids[1], ROOM + "/bert", "Second FIFO occupant");
            fail_if_not_eq_str(changed_ids[2], ROOM + "/carla", "Third FIFO occupant");
        }
        fail_if(stats.processed_commands < 6,
            "Start, three presences, finish, and barrier must all be processed");

        worker.shutdown();
        fail_if(worker.get_stats().worker_running,
            "Shutdown must synchronously join the MUC occupant worker");
    }

    private void test_per_room_backpressure() {
        var worker = new MucOccupantWorker(null, 8, 2, 16, 4, false);
        bool saw_degraded = false;
        worker.delta_ready.connect((delta) => {
            if (delta.degraded_partial) saw_degraded = true;
        });

        MucRoomKey room = room_key(1);
        fail_if(!worker.start_room(room), "Room start must be accepted");
        fail_if(!worker.enqueue(available(room, 1, "anna")), "First room presence must fit");
        fail_if(!worker.enqueue(available(room, 2, "bert")), "Second room presence must fit");
        fail_if(worker.enqueue(available(room, 3, "carla")),
            "Third ordinary presence must be dropped at the per-room limit");
        fail_if(worker.enqueue(available(room, 4, "dora")),
            "Further ordinary presence must stay bounded at the per-room limit");

        worker.start();
        wait_until_flushed(worker);
        MucOccupantWorkerStats stats = worker.get_stats();
        fail_if(stats.dropped_available != 2,
            "Every per-room overflow must be counted");
        fail_if(stats.peak_ingress_depth > 8,
            "Ingress queue must never exceed its configured capacity");
        fail_if(!saw_degraded || stats.degraded_rooms != 1,
            "Repeated drops in one generation must coalesce to one degraded transition");
        fail_if(stats.processed_commands != 5,
            "Repeated drops must not enqueue one degraded marker per presence");
        worker.shutdown();

        var global_worker = new MucOccupantWorker(null, 4, 4, 16, 4, false);
        MucRoomKey global_room = room_key(2);
        fail_if(!global_worker.start_room(global_room), "Global room start must fit");
        fail_if(!global_worker.enqueue(available(global_room, 1, "one")), "Global presence one");
        fail_if(!global_worker.enqueue(available(global_room, 2, "two")), "Global presence two");
        fail_if(!global_worker.enqueue(available(global_room, 3, "three")), "Global presence three");
        fail_if(global_worker.enqueue(available(global_room, 4, "four")),
            "Ordinary presence must not grow a full global queue");
        global_worker.start();
        wait_until_flushed(global_worker);
        MucOccupantWorkerStats global_stats = global_worker.get_stats();
        fail_if(global_stats.dropped_available != 1 || global_stats.peak_ingress_depth > 4,
            "Global overflow must remain bounded and observable");
        global_worker.shutdown();
    }

    private void test_control_presence_preserved() {
        var worker = new MucOccupantWorker(null, 4, 4, 16, 4, false);
        var deltas = new Gee.ArrayList<MucRoomDelta>();
        worker.delta_ready.connect((delta) => deltas.add(delta));
        MucRoomKey room = room_key(1);

        fail_if(!worker.start_room(room), "Room start must fit");
        fail_if(!worker.enqueue(available(room, 1, "anna")), "Available anna must fit");
        fail_if(!worker.enqueue(available(room, 2, "bert")), "Available bert must fit");
        fail_if(!worker.enqueue(available(room, 3, "carla")), "Available carla must fit");
        fail_if(!worker.enqueue(unavailable(room, 4, "carla")),
            "Unavailable control presence must evict ordinary load instead of being dropped");

        worker.start();
        wait_for_ingress_drain(worker);
        fail_if(!worker.snapshot_room(room), "Snapshot command must be preserved after overload");
        wait_until_flushed(worker);

        MucOccupantWorkerStats stats = worker.get_stats();
        fail_if(stats.evicted_available != 1,
            "Exactly one ordinary AVAILABLE must be evicted for the control presence");
        fail_if(stats.peak_ingress_depth > 4,
            "Control preservation must not exceed the configured queue bound");
        fail_if(stats.degraded_rooms != 1,
            "The room affected by eviction must be marked degraded");

        MucRoomDelta? snapshot = null;
        foreach (MucRoomDelta delta in deltas) {
            if (delta.changed_count == delta.occupant_count &&
                    delta.occupant_count == 1 && delta.changed_count == 1 &&
                    delta.changed_at(0).occupant_full_jid == ROOM + "/bert") {
                snapshot = delta;
            }
        }
        fail_if(snapshot == null,
            "Unavailable must remove carla while the non-evicted bert remains in the snapshot");
        worker.shutdown();
    }

    private void test_eviction_precedes_finish_snapshot() {
        var worker = new MucOccupantWorker(null, 4, 4, 16, 4, false);
        MucRoomDelta? finished_snapshot = null;
        worker.delta_ready.connect((delta) => {
            if (delta.initial_sync_finished && delta.full_snapshot) {
                finished_snapshot = delta;
            }
        });
        MucRoomKey room = room_key(1);

        fail_if(!worker.start_room(room), "Room start must fit");
        fail_if(!worker.enqueue(available(room, 1, "anna")), "Available anna must fit");
        fail_if(!worker.enqueue(available(room, 2, "bert")), "Available bert must fit");
        fail_if(!worker.enqueue(available(room, 3, "carla")), "Available carla must fit");
        fail_if(!worker.finish_room(room),
            "Finish control must evict ordinary load instead of being dropped");

        worker.start();
        wait_for_ingress_drain(worker);
        wait_until_flushed(worker);
        MucOccupantWorkerStats stats = worker.get_stats();
        fail_if(stats.evicted_available != 1,
            "Finish control must evict exactly one ordinary presence in this fixture");
        fail_if(stats.peak_ingress_depth > 4,
            "Degraded-before-finish ordering must preserve the hard queue bound");
        fail_if(finished_snapshot == null,
            "Finish control must publish one full shadow snapshot");
        if (finished_snapshot != null) {
            fail_if(!((!) finished_snapshot).degraded_partial,
                "An eviction must mark the full snapshot degraded before it is published");
        }
        worker.shutdown();
    }

    private void test_leave_rejoin_generation() {
        var worker = new MucOccupantWorker(null, 32, 16, 32, 8, false);
        var deltas = new Gee.ArrayList<MucRoomDelta>();
        worker.delta_ready.connect((delta) => deltas.add(delta));

        MucRoomKey old_room = room_key(1);
        MucRoomKey new_room = room_key(2);
        fail_if(!worker.start_room(old_room), "Old generation must start");
        fail_if(!worker.enqueue(available(old_room, 1, "old")), "Old generation presence");
        fail_if(!worker.cancel_room(old_room), "Old generation cancel must be FIFO-preserved");
        fail_if(!worker.start_room(new_room), "New room generation must start");
        fail_if(!worker.enqueue(available(old_room, 2, "stale")),
            "Stale presence can enter the queue but must be rejected by the worker generation gate");
        fail_if(!worker.enqueue(available(new_room, 1, "fresh")), "New generation presence");
        fail_if(!worker.snapshot_room(new_room), "New generation snapshot command");

        worker.start();
        wait_until_flushed(worker);
        MucOccupantWorkerStats stats = worker.get_stats();
        fail_if(stats.stale_commands < 1,
            "A queued old-generation presence must be counted as stale");
        fail_if(stats.cancelled_rooms != 1 || stats.started_rooms != 2,
            "Leave/rejoin lifecycle commands must be applied exactly once");

        MucRoomDelta? final_snapshot = null;
        foreach (MucRoomDelta delta in deltas) {
            if (delta.room.room_generation == 2 && delta.changed_count == 1 &&
                    delta.changed_at(0).occupant_full_jid == ROOM + "/fresh") {
                final_snapshot = delta;
            }
            for (uint i = 0; i < delta.changed_count; i++) {
                fail_if(delta.changed_at(i).occupant_full_jid == ROOM + "/stale",
                    "Stale generation output must never reach the main context");
            }
        }
        fail_if(final_snapshot == null,
            "The current room generation must retain its fresh occupant snapshot");
        worker.shutdown();
    }

    private void test_bounded_main_drain() {
        int64 caller_thread_id = (int64) Thread.self<void*>();
        int64 callback_thread_id = 0;
        var worker = new MucOccupantWorker(null, 32, 16, 32, 2, false);
        worker.delta_ready.connect((delta) => {
            callback_thread_id = (int64) Thread.self<void*>();
        });
        MucRoomKey room = room_key(1);
        fail_if(!worker.start_room(room), "Drain test room must start");
        for (uint64 sequence = 1; sequence <= 7; sequence++) {
            fail_if(!worker.enqueue(available(room, sequence, @"user$sequence")),
                "Drain test presence must fit");
        }

        worker.start();
        wait_until_flushed(worker);
        MucOccupantWorkerStats stats = worker.get_stats();
        fail_if(stats.main_drain_passes < 4,
            "Seven deltas plus the barrier must require at least four bounded drain passes");
        fail_if(stats.max_delivered_in_pass > 2,
            "No main-context drain may exceed its configured batch size");
        fail_if(stats.peak_egress_depth > 32,
            "Worker output must remain inside the configured egress bound");
        fail_if(callback_thread_id != caller_thread_id,
            "Batched delta delivery must stay on the caller main context");
        worker.shutdown();
    }

    private void test_shadow_snapshot_only() {
        var worker = new MucOccupantWorker(null, 32, 16, 32, 8, false, false);
        var deltas = new Gee.ArrayList<MucRoomDelta>();
        worker.delta_ready.connect((delta) => deltas.add(delta));
        MucRoomKey room = room_key(1);

        fail_if(!worker.start_room(room), "Shadow room must start");
        fail_if(!worker.enqueue(available(room, 1, "anna")), "Shadow presence anna");
        fail_if(!worker.enqueue(available(room, 2, "bert")), "Shadow presence bert");
        fail_if(!worker.finish_room(room), "Shadow room must finish");
        worker.start();
        wait_until_flushed(worker);

        fail_if(deltas.size != 1,
            "Shadow mode must not round-trip one main-context delta per presence");
        if (deltas.size == 1) {
            fail_if(!deltas[0].full_snapshot || !deltas[0].initial_sync_finished ||
                    deltas[0].occupant_count != 2 || deltas[0].changed_count != 2,
                "Shadow mode must still emit the complete finished snapshot");
        }
        worker.shutdown();
    }

    private void test_live_changes_coalesce_until_flush() {
        var worker = new MucOccupantWorker(null, 32, 16, 32, 8, false,
            false, true);
        var deltas = new Gee.ArrayList<MucRoomDelta>();
        int flushed = 0;
        worker.delta_ready.connect((delta) => deltas.add(delta));
        worker.room_flushed.connect((room) => flushed++);
        MucRoomKey room = room_key(1);

        fail_if(!worker.start_room(room), "Live-batch room must start");
        fail_if(!worker.enqueue(available(room, 1, "anna")),
            "Initial anna presence must fit");
        fail_if(!worker.enqueue(available(room, 2, "bert")),
            "Initial bert presence must fit");
        fail_if(!worker.finish_room(room), "Initial snapshot must finish");
        fail_if(!worker.enqueue(available_with_role(room, 3, "anna",
                MucWorkerRoleState.MODERATOR)),
            "Anna role update must enter the live batch");
        fail_if(!worker.enqueue(available(room, 4, "carla")),
            "Carla join must enter the live batch");
        fail_if(!worker.enqueue(unavailable(room, 5, "bert")),
            "Bert removal must enter the live batch");
        fail_if(!worker.enqueue(available_with_role(room, 6, "carla",
                MucWorkerRoleState.VISITOR)),
            "Carla's later state must replace her earlier batch state");
        fail_if(!worker.flush_room(room), "Live batch flush must be preserved");

        worker.start();
        wait_until_flushed(worker);

        fail_if(deltas.size != 2,
            "Initial snapshot plus one coalesced live delta must be emitted");
        MucRoomDelta? live = null;
        foreach (MucRoomDelta delta in deltas) {
            if (delta.initial_sync_finished && !delta.full_snapshot) live = delta;
        }
        fail_if(live == null, "The explicit flush must emit one live delta");
        if (live != null) {
            MucRoomDelta batch = (!) live;
            fail_if(batch.occupant_count != 2 || batch.changed_count != 2 ||
                    batch.removed_count != 1,
                "Live batch must contain final anna/carla state and one bert removal");
            fail_if_not_eq_str(batch.removed_at(0), ROOM + "/bert",
                "Coalesced removed occupant");
            fail_if_not_eq_str(batch.changed_at(0).occupant_full_jid,
                ROOM + "/anna", "First deterministic changed occupant");
            fail_if_not_eq_str(batch.changed_at(1).occupant_full_jid,
                ROOM + "/carla", "Second deterministic changed occupant");
            fail_if((batch.changed_flags_at(0) & MucOccupantChange.ROLE) == 0,
                "Anna's batch entry must report the real role change");
            fail_if((batch.changed_flags_at(0) & MucOccupantChange.MEMBERSHIP) != 0,
                "Anna's existing membership must not be reported as new");
            fail_if((batch.changed_flags_at(1) & MucOccupantChange.MEMBERSHIP) == 0 ||
                    (batch.changed_flags_at(1) & MucOccupantChange.ROLE) == 0,
                "Carla's coalesced entry must retain join and later role flags");
            fail_if(batch.changed_at(1).role != MucWorkerRoleState.VISITOR,
                "Carla's latest role must win inside the batch");
        }
        fail_if(flushed != 1,
            "Every accepted live flush command must publish one completion marker");
        worker.shutdown();
    }

    private void test_live_flush_rejects_stale_generation() {
        var worker = new MucOccupantWorker(null, 32, 16, 32, 8, false,
            false, true);
        var deltas = new Gee.ArrayList<MucRoomDelta>();
        worker.delta_ready.connect((delta) => deltas.add(delta));

        MucRoomKey old_room = room_key(1);
        MucRoomKey new_room = room_key(2);
        fail_if(!worker.start_room(old_room), "Old live room must start");
        fail_if(!worker.enqueue(available(old_room, 1, "old")),
            "Old initial presence must fit");
        fail_if(!worker.finish_room(old_room), "Old initial snapshot must finish");
        fail_if(!worker.enqueue(available(old_room, 2, "stale-live")),
            "Old live update may enter before cancellation");
        fail_if(!worker.cancel_room(old_room), "Old generation must cancel");
        fail_if(!worker.start_room(new_room), "New live room must start");
        fail_if(!worker.enqueue(available(new_room, 1, "fresh")),
            "New initial presence must fit");
        fail_if(!worker.finish_room(new_room), "New initial snapshot must finish");
        fail_if(!worker.enqueue(available(new_room, 2, "current-live")),
            "Current live update must fit");
        fail_if(!worker.flush_room(old_room),
            "Stale flush may enter the queue but must fail the generation gate");
        fail_if(!worker.flush_room(new_room), "Current generation must flush");

        worker.start();
        wait_until_flushed(worker);

        bool saw_current_live = false;
        foreach (MucRoomDelta delta in deltas) {
            if (!delta.full_snapshot && delta.room.room_generation == 2 &&
                    delta.changed_count == 1 &&
                    delta.changed_at(0).occupant_full_jid ==
                        ROOM + "/current-live") {
                saw_current_live = true;
            }
            if (!delta.full_snapshot) {
                for (uint i = 0; i < delta.changed_count; i++) {
                    fail_if(delta.changed_at(i).occupant_full_jid ==
                            ROOM + "/stale-live",
                        "Cancelled-generation live state must never reach the main context");
                }
            }
        }
        fail_if(!saw_current_live,
            "The current generation's live batch must survive stale-flush rejection");
        fail_if(worker.get_stats().stale_commands < 1,
            "The old-generation flush must be counted as stale");
        worker.shutdown();
    }

    private void test_live_batch_keeps_canonical_full_jid_nick() {
        var worker = new MucOccupantWorker(null, 32, 16, 32, 8, false,
            false, true);
        var deltas = new Gee.ArrayList<MucRoomDelta>();
        worker.delta_ready.connect((delta) => deltas.add(delta));
        MucRoomKey room = room_key(1);

        fail_if(!worker.start_room(room), "Canonical-nick room must start");
        fail_if(!worker.enqueue(available_with_hint_and_role(room, 1, "anna",
                "room", MucWorkerRoleState.PARTICIPANT)),
            "Initial mismatching nick hint must enter the reducer");
        fail_if(!worker.finish_room(room), "Canonical-nick snapshot must finish");
        fail_if(!worker.enqueue(available_with_hint_and_role(room, 2, "anna",
                "different-wrong-hint", MucWorkerRoleState.MODERATOR)),
            "Live role update with a bad nick hint must enter the batch");
        fail_if(!worker.flush_room(room), "Canonical-nick live batch must flush");

        worker.start();
        wait_until_flushed(worker);

        MucRoomDelta? initial = null;
        MucRoomDelta? live = null;
        foreach (MucRoomDelta delta in deltas) {
            if (delta.full_snapshot) initial = delta;
            else if (delta.initial_sync_finished) live = delta;
        }
        fail_if(initial == null || ((!) initial).changed_count != 1,
            "The initial canonical snapshot must be emitted");
        fail_if(live == null || ((!) live).changed_count != 1,
            "The live canonical role delta must be emitted");
        if (initial != null) {
            fail_if_not_eq_str(((!) initial).changed_at(0).nick, "anna",
                "Initial worker snapshot must ignore a mismatching nick hint");
        }
        if (live != null) {
            fail_if_not_eq_str(((!) live).changed_at(0).nick, "anna",
                "Live worker batch must retain the full-JID resource nick");
        }
        worker.shutdown();
    }

    private void wait_until_flushed(MucOccupantWorker worker) {
        var loop = new MainLoop();
        bool reached = false;
        bool timed_out = false;
        uint64 expected_barrier = 0;
        ulong handler_id = worker.barrier_reached.connect((barrier_id) => {
            if (barrier_id == expected_barrier) {
                reached = true;
                loop.quit();
            }
        });
        expected_barrier = worker.enqueue_barrier();
        fail_if(expected_barrier == 0, "Barrier must enter the bounded control queue");

        var timeout = new TimeoutSource(5000);
        timeout.set_callback(() => {
            timed_out = true;
            loop.quit();
            return Source.REMOVE;
        });
        timeout.attach(MainContext.@default());
        loop.run();
        timeout.destroy();
        SignalHandler.disconnect(worker, handler_id);

        fail_if(timed_out, "MUC occupant worker barrier timed out");
        fail_if(!reached, "MUC occupant worker barrier must be delivered on the main context");
    }

    private void wait_for_ingress_drain(MucOccupantWorker worker) {
        int64 deadline = GLib.get_monotonic_time() + 5 * TimeSpan.SECOND;
        while (worker.get_stats().current_ingress_depth > 0 &&
                GLib.get_monotonic_time() < deadline) {
            Thread.usleep(1000);
        }
        fail_if(worker.get_stats().current_ingress_depth > 0,
            "Worker must drain queued ingress before the follow-up snapshot");
    }

    private MucRoomKey room_key(uint64 room_generation) {
        return new MucRoomKey(7, ACCOUNT, ROOM, 1, room_generation);
    }

    private MucPresenceEnvelope available(MucRoomKey room, uint64 sequence, string nick) {
        return new MucPresenceEnvelope(room, sequence, MucWorkerPresenceKind.AVAILABLE,
            ROOM + "/" + nick, nick, null,
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true,
            null, null, null, null, false, (int64) sequence * 1000);
    }

    private MucPresenceEnvelope unavailable(MucRoomKey room, uint64 sequence, string nick) {
        return new MucPresenceEnvelope(room, sequence, MucWorkerPresenceKind.UNAVAILABLE,
            ROOM + "/" + nick, nick, null,
            MucWorkerAffiliationState.UNKNOWN, false,
            MucWorkerRoleState.UNKNOWN, false,
            null, null, null, null, false, (int64) sequence * 1000);
    }

    private MucPresenceEnvelope available_with_role(MucRoomKey room,
            uint64 sequence, string nick, MucWorkerRoleState role) {
        return new MucPresenceEnvelope(room, sequence,
            MucWorkerPresenceKind.AVAILABLE, ROOM + "/" + nick, nick, null,
            MucWorkerAffiliationState.MEMBER, true, role, true,
            null, null, null, null, false, (int64) sequence * 1000);
    }

    private MucPresenceEnvelope available_with_hint_and_role(MucRoomKey room,
            uint64 sequence, string resource, string event_nick,
            MucWorkerRoleState role) {
        return new MucPresenceEnvelope(room, sequence,
            MucWorkerPresenceKind.AVAILABLE, ROOM + "/" + resource,
            event_nick, null, MucWorkerAffiliationState.MEMBER, true,
            role, true, null, null, null, null, false,
            (int64) sequence * 1000);
    }
}

}
