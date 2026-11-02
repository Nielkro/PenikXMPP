/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;

namespace Dino {

internal class MucOccupantWorkerStats : Object {
    internal uint64 accepted_envelopes { get; private set; }
    internal uint64 accepted_control_commands { get; private set; }
    internal uint64 dropped_available { get; private set; }
    internal uint64 evicted_available { get; private set; }
    internal uint64 processed_commands { get; private set; }
    internal uint64 stale_commands { get; private set; }
    internal uint64 emitted_deltas { get; private set; }
    internal uint64 degraded_rooms { get; private set; }
    internal uint64 started_rooms { get; private set; }
    internal uint64 cancelled_rooms { get; private set; }
    internal uint current_ingress_depth { get; private set; }
    internal uint peak_ingress_depth { get; private set; }
    internal uint current_egress_depth { get; private set; }
    internal uint peak_egress_depth { get; private set; }
    internal uint64 main_drain_passes { get; private set; }
    internal uint max_delivered_in_pass { get; private set; }
    internal int64 worker_thread_id { get; private set; }
    internal bool worker_running { get; private set; }

    internal MucOccupantWorkerStats(uint64 accepted_envelopes,
            uint64 accepted_control_commands, uint64 dropped_available,
            uint64 evicted_available, uint64 processed_commands,
            uint64 stale_commands, uint64 emitted_deltas,
            uint64 degraded_rooms, uint64 started_rooms,
            uint64 cancelled_rooms, uint current_ingress_depth,
            uint peak_ingress_depth, uint current_egress_depth,
            uint peak_egress_depth, uint64 main_drain_passes,
            uint max_delivered_in_pass, int64 worker_thread_id,
            bool worker_running) {
        this.accepted_envelopes = accepted_envelopes;
        this.accepted_control_commands = accepted_control_commands;
        this.dropped_available = dropped_available;
        this.evicted_available = evicted_available;
        this.processed_commands = processed_commands;
        this.stale_commands = stale_commands;
        this.emitted_deltas = emitted_deltas;
        this.degraded_rooms = degraded_rooms;
        this.started_rooms = started_rooms;
        this.cancelled_rooms = cancelled_rooms;
        this.current_ingress_depth = current_ingress_depth;
        this.peak_ingress_depth = peak_ingress_depth;
        this.current_egress_depth = current_egress_depth;
        this.peak_egress_depth = peak_egress_depth;
        this.main_drain_passes = main_drain_passes;
        this.max_delivered_in_pass = max_delivered_in_pass;
        this.worker_thread_id = worker_thread_id;
        this.worker_running = worker_running;
    }
}

/**
 * Bounded single-threaded reducer lane for MUC occupant presence.
 *
 * The caller only submits immutable value objects. No Account, Jid,
 * XmppStream, stanza, GTK object, or main-context-owned mutable collection
 * crosses the worker boundary. The existing XMPP MUC state remains
 * authoritative; this worker produces immutable display snapshots and can
 * optionally suppress incremental outputs during initial roster collection.
 */
internal class MucOccupantWorker : Object {
    internal const uint DEFAULT_INGRESS_CAPACITY = 8192;
    internal const uint DEFAULT_PER_ROOM_AVAILABLE_CAPACITY = 4096;
    internal const uint DEFAULT_EGRESS_CAPACITY = 2048;
    internal const uint DEFAULT_MAIN_DRAIN_BATCH = 32;

    internal signal void delta_ready(MucRoomDelta delta);
    internal signal void room_flushed(MucRoomKey room);
    internal signal void barrier_reached(uint64 barrier_id);

    private MainContext delivery_context;
    private uint ingress_capacity;
    private uint per_room_available_capacity;
    private uint egress_capacity;
    private uint main_drain_batch;
    private bool emit_incremental_deltas;
    private bool batch_live_deltas;

    private GLib.Queue<MucOccupantWorkerCommand> ingress = new GLib.Queue<MucOccupantWorkerCommand>();
    private HashMap<string, int> queued_available_by_room = new HashMap<string, int>();
    private HashMap<string, MucRoomKey> pending_degraded = new HashMap<string, MucRoomKey>();
    private HashSet<string> degraded_marker_scheduled = new HashSet<string>();
    private Mutex ingress_mutex;
    private Cond ingress_cond;
    private bool accepting = true;

    private GLib.Queue<MucOccupantWorkerOutput> egress = new GLib.Queue<MucOccupantWorkerOutput>();
    private Mutex egress_mutex;
    private Cond egress_cond;
    private bool egress_stopping = false;
    private Source? egress_source;

    private Mutex lifecycle_mutex;
    private Thread<void*>? worker_thread;
    private bool start_allowed = true;

    private Mutex stats_mutex;
    private uint64 stats_accepted_envelopes = 0;
    private uint64 stats_accepted_control_commands = 0;
    private uint64 stats_dropped_available = 0;
    private uint64 stats_evicted_available = 0;
    private uint64 stats_processed_commands = 0;
    private uint64 stats_stale_commands = 0;
    private uint64 stats_emitted_deltas = 0;
    private uint64 stats_degraded_rooms = 0;
    private uint64 stats_started_rooms = 0;
    private uint64 stats_cancelled_rooms = 0;
    private uint stats_current_ingress_depth = 0;
    private uint stats_peak_ingress_depth = 0;
    private uint stats_current_egress_depth = 0;
    private uint stats_peak_egress_depth = 0;
    private uint64 stats_main_drain_passes = 0;
    private uint stats_max_delivered_in_pass = 0;
    private int64 stats_worker_thread_id = 0;
    private bool stats_worker_running = false;
    private uint64 next_barrier_id = 1;

    internal MucOccupantWorker(MainContext? delivery_context = null,
            uint ingress_capacity = DEFAULT_INGRESS_CAPACITY,
            uint per_room_available_capacity = DEFAULT_PER_ROOM_AVAILABLE_CAPACITY,
            uint egress_capacity = DEFAULT_EGRESS_CAPACITY,
            uint main_drain_batch = DEFAULT_MAIN_DRAIN_BATCH,
            bool autostart = true, bool emit_incremental_deltas = true,
            bool batch_live_deltas = false) {
        this.delivery_context = delivery_context != null
            ? (!) delivery_context
            : MainContext.ref_thread_default();
        this.ingress_capacity = uint.max(2, ingress_capacity);
        this.per_room_available_capacity = uint.max(1,
            uint.min(per_room_available_capacity, this.ingress_capacity));
        this.egress_capacity = uint.max(1, egress_capacity);
        this.main_drain_batch = uint.max(1, main_drain_batch);
        this.emit_incremental_deltas = emit_incremental_deltas;
        this.batch_live_deltas = batch_live_deltas;
        if (autostart) start();
    }

    internal void start() {
        lifecycle_mutex.lock();
        if (worker_thread == null && start_allowed) {
            worker_thread = new Thread<void*>("muc-occupant-worker", worker_main);
        }
        lifecycle_mutex.unlock();
    }

    internal bool start_room(MucRoomKey room) {
        return enqueue_control(new MucOccupantWorkerCommand.start_room(room));
    }

    internal bool enqueue(MucPresenceEnvelope envelope) {
        bool ordinary_available = envelope.kind == MucWorkerPresenceKind.AVAILABLE &&
            !envelope.is_self_presence && envelope.status_code_count == 0;
        if (ordinary_available) {
            return enqueue_available(new MucOccupantWorkerCommand.for_envelope(envelope));
        }
        return enqueue_control(new MucOccupantWorkerCommand.for_envelope(envelope));
    }

    internal bool finish_room(MucRoomKey room, bool degraded_partial = false) {
        return enqueue_control(new MucOccupantWorkerCommand.finish_room(room, degraded_partial));
    }

    internal bool snapshot_room(MucRoomKey room) {
        return enqueue_control(new MucOccupantWorkerCommand.snapshot_room(room));
    }

    internal bool flush_room(MucRoomKey room) {
        return enqueue_control(new MucOccupantWorkerCommand.flush_room(room));
    }

    internal bool cancel_room(MucRoomKey room) {
        return enqueue_control(new MucOccupantWorkerCommand.cancel_room(room));
    }

    internal bool cancel_account(int account_id, string account_bare_jid) {
        return enqueue_control(new MucOccupantWorkerCommand.cancel_account(
            account_id, account_bare_jid));
    }

    internal uint64 enqueue_barrier() {
        stats_mutex.lock();
        uint64 barrier_id = next_barrier_id++;
        stats_mutex.unlock();
        if (!enqueue_control(new MucOccupantWorkerCommand.barrier(barrier_id))) return 0;
        return barrier_id;
    }

    internal MucOccupantWorkerStats get_stats() {
        stats_mutex.lock();
        var result = new MucOccupantWorkerStats(
            stats_accepted_envelopes, stats_accepted_control_commands,
            stats_dropped_available, stats_evicted_available,
            stats_processed_commands, stats_stale_commands,
            stats_emitted_deltas, stats_degraded_rooms,
            stats_started_rooms, stats_cancelled_rooms,
            stats_current_ingress_depth, stats_peak_ingress_depth,
            stats_current_egress_depth, stats_peak_egress_depth,
            stats_main_drain_passes, stats_max_delivered_in_pass,
            stats_worker_thread_id, stats_worker_running);
        stats_mutex.unlock();
        return result;
    }

    internal void shutdown() {
        lifecycle_mutex.lock();
        if (!start_allowed && worker_thread == null) {
            lifecycle_mutex.unlock();
            return;
        }
        start_allowed = false;
        Thread<void*>? thread_to_join = worker_thread;
        lifecycle_mutex.unlock();

        egress_mutex.lock();
        egress_stopping = true;
        Source? source_to_destroy = egress_source;
        egress_source = null;
        while (!egress.is_empty()) egress.pop_head();
        update_egress_depth_locked();
        egress_cond.broadcast();
        egress_mutex.unlock();
        if (source_to_destroy != null) ((!) source_to_destroy).destroy();

        ingress_mutex.lock();
        accepting = false;
        while (!ingress.is_empty()) ingress.pop_head();
        queued_available_by_room.clear();
        pending_degraded.clear();
        degraded_marker_scheduled.clear();
        update_ingress_depth_locked();
        ingress_cond.broadcast();
        ingress_mutex.unlock();

        if (thread_to_join != null && ((!) thread_to_join) != Thread.self<void*>()) {
            ((!) thread_to_join).join();
        }

        lifecycle_mutex.lock();
        worker_thread = null;
        lifecycle_mutex.unlock();
    }

    private bool enqueue_available(MucOccupantWorkerCommand command) {
        MucRoomKey room = (!) command.room;
        string exact_key = exact_room_key(room);

        ingress_mutex.lock();
        if (!accepting) {
            ingress_mutex.unlock();
            return false;
        }

        int room_depth = queued_available_by_room.has_key(exact_key)
            ? queued_available_by_room[exact_key]
            : 0;
        if (ingress.length >= ingress_capacity ||
                room_depth >= (int) per_room_available_capacity) {
            mark_degraded_locked(room);
            increment_dropped_available();
            move_one_degraded_marker_locked();
            update_ingress_depth_locked();
            ingress_cond.signal();
            ingress_mutex.unlock();
            return false;
        }

        ingress.push_tail(command);
        queued_available_by_room[exact_key] = room_depth + 1;
        record_accepted_envelope(false);
        update_ingress_depth_locked();
        ingress_cond.signal();
        ingress_mutex.unlock();
        return true;
    }

    private bool enqueue_control(MucOccupantWorkerCommand command) {
        ingress_mutex.lock();
        while (accepting && ingress.length >= ingress_capacity) {
            int evict_index = find_oldest_available_locked();
            if (evict_index >= 0) {
                MucOccupantWorkerCommand evicted = ingress.pop_nth((uint) evict_index);
                decrement_available_depth_locked((!) evicted.room);
                mark_degraded_locked((!) evicted.room);
                increment_evicted_available();
                break;
            }

            lifecycle_mutex.lock();
            bool can_drain = worker_thread != null;
            lifecycle_mutex.unlock();
            if (!can_drain) {
                ingress_mutex.unlock();
                return false;
            }
            ingress_cond.wait(ingress_mutex);
        }

        if (!accepting) {
            ingress_mutex.unlock();
            return false;
        }

        attach_pending_degraded_locked(command);
        ingress.push_tail(command);
        if (command.operation == MucOccupantWorkerOperation.ENVELOPE) {
            record_accepted_envelope(true);
        } else {
            increment_control_commands();
        }
        update_ingress_depth_locked();
        ingress_cond.signal();
        ingress_mutex.unlock();
        return true;
    }

    private int find_oldest_available_locked() {
        for (uint i = 0; i < ingress.length; i++) {
            unowned MucOccupantWorkerCommand current = ingress.peek_nth(i);
            if (current.evictable_available) return (int) i;
        }
        return -1;
    }

    private void mark_degraded_locked(MucRoomKey room) {
        string key = exact_room_key(room);
        if (degraded_marker_scheduled.contains(key)) return;
        degraded_marker_scheduled.add(key);
        pending_degraded[key] = room;
    }

    private void attach_pending_degraded_locked(MucOccupantWorkerCommand command) {
        if (pending_degraded.is_empty) return;

        var rooms = new ArrayList<MucRoomKey>();
        foreach (MucRoomKey room in pending_degraded.values) rooms.add(room);
        pending_degraded.clear();
        command.set_degraded_before(rooms.to_array());
        increment_control_commands_by((uint64) rooms.size);
    }

    private void move_one_degraded_marker_locked() {
        if (pending_degraded.is_empty || ingress.length >= ingress_capacity) return;
        string? selected_key = null;
        MucRoomKey? selected_room = null;
        foreach (var entry in pending_degraded.entries) {
            selected_key = entry.key;
            selected_room = entry.value;
            break;
        }
        if (selected_key == null || selected_room == null) return;
        pending_degraded.unset((!) selected_key);
        ingress.push_tail(new MucOccupantWorkerCommand.mark_degraded((!) selected_room));
        increment_control_commands();
        update_ingress_depth_locked();
    }

    private void decrement_available_depth_locked(MucRoomKey room) {
        string key = exact_room_key(room);
        if (!queued_available_by_room.has_key(key)) return;
        int next = queued_available_by_room[key] - 1;
        if (next <= 0) queued_available_by_room.unset(key);
        else queued_available_by_room[key] = next;
    }

    private MucOccupantWorkerCommand? take_command() {
        ingress_mutex.lock();
        while (ingress.is_empty() && accepting) {
            move_one_degraded_marker_locked();
            if (!ingress.is_empty()) break;
            ingress_cond.wait(ingress_mutex);
        }
        if (ingress.is_empty()) {
            ingress_mutex.unlock();
            return null;
        }

        MucOccupantWorkerCommand command = ingress.pop_head();
        if (command.evictable_available) decrement_available_depth_locked((!) command.room);
        move_one_degraded_marker_locked();
        update_ingress_depth_locked();
        ingress_cond.broadcast();
        ingress_mutex.unlock();
        return command;
    }

    private void* worker_main() {
        set_worker_running(true);
        var reducers = new HashMap<string, MucOccupantReducer>();
        var live_batches = new HashMap<string, MucOccupantLiveBatch>();

        while (true) {
            MucOccupantWorkerCommand? command = take_command();
            if (command == null) break;
            process_command((!) command, reducers, live_batches);
        }

        live_batches.clear();
        reducers.clear();
        set_worker_running(false);
        return null;
    }

    private void process_command(MucOccupantWorkerCommand command,
            HashMap<string, MucOccupantReducer> reducers,
            HashMap<string, MucOccupantLiveBatch> live_batches) {
        increment_processed_commands();
        for (uint i = 0; i < command.degraded_before_count; i++) {
            apply_degraded_marker(command.degraded_before_at(i), reducers,
                live_batches);
        }
        switch (command.operation) {
            case MucOccupantWorkerOperation.START_ROOM:
                MucRoomKey start_key = (!) command.room;
                clear_old_degraded_tracking(start_key);
                live_batches.unset(logical_room_key(start_key));
                reducers[logical_room_key(start_key)] = new MucOccupantReducer(start_key);
                increment_started_rooms();
                break;
            case MucOccupantWorkerOperation.ENVELOPE:
                MucPresenceEnvelope envelope = (!) command.envelope;
                MucOccupantReducer? reducer = reducers[logical_room_key(envelope.room)];
                if (reducer == null || !((!) reducer).room.matches(envelope.room)) {
                    increment_stale_commands();
                    break;
                }
                MucRoomDelta? envelope_delta = ((!) reducer).apply(envelope);
                handle_reducer_delta(envelope_delta, live_batches);
                break;
            case MucOccupantWorkerOperation.FINISH_ROOM:
                MucOccupantReducer? finish_reducer = exact_reducer(reducers, (!) command.room);
                if (finish_reducer == null) {
                    increment_stale_commands();
                    break;
                }
                MucRoomDelta? finished = ((!) finish_reducer).finish_initial_sync(command.degraded_partial);
                if (finished != null) publish_delta(((!) finish_reducer).snapshot());
                break;
            case MucOccupantWorkerOperation.MARK_DEGRADED:
                apply_degraded_marker((!) command.room, reducers, live_batches);
                break;
            case MucOccupantWorkerOperation.SNAPSHOT_ROOM:
                MucOccupantReducer? snapshot_reducer = exact_reducer(reducers, (!) command.room);
                if (snapshot_reducer == null) {
                    increment_stale_commands();
                    break;
                }
                publish_delta(((!) snapshot_reducer).snapshot());
                break;
            case MucOccupantWorkerOperation.FLUSH_ROOM:
                MucRoomKey flush_key = (!) command.room;
                MucOccupantReducer? flush_reducer = exact_reducer(reducers,
                    flush_key);
                if (flush_reducer == null) {
                    increment_stale_commands();
                    break;
                }
                string flush_logical_key = logical_room_key(flush_key);
                MucOccupantLiveBatch? live_batch = live_batches[flush_logical_key];
                if (live_batch != null && ((!) live_batch).room.matches(flush_key)) {
                    publish_delta(((!) live_batch).to_delta());
                    live_batches.unset(flush_logical_key);
                }
                push_output(new MucOccupantWorkerOutput.room_flushed(flush_key));
                break;
            case MucOccupantWorkerOperation.CANCEL_ROOM:
                MucRoomKey cancel_key = (!) command.room;
                MucOccupantReducer? cancel_reducer = reducers[logical_room_key(cancel_key)];
                if (cancel_reducer != null && ((!) cancel_reducer).room.matches(cancel_key)) {
                    reducers.unset(logical_room_key(cancel_key));
                    increment_cancelled_rooms();
                } else {
                    increment_stale_commands();
                }
                MucOccupantLiveBatch? cancelled_batch = live_batches[
                    logical_room_key(cancel_key)];
                if (cancelled_batch != null &&
                        ((!) cancelled_batch).room.matches(cancel_key)) {
                    live_batches.unset(logical_room_key(cancel_key));
                }
                clear_exact_degraded_tracking(cancel_key);
                break;
            case MucOccupantWorkerOperation.CANCEL_ACCOUNT:
                var remove_keys = new ArrayList<string>();
                foreach (var entry in reducers.entries) {
                    MucRoomKey room = entry.value.room;
                    if (room.account_id == command.account_id &&
                            room.account_bare_jid == command.account_bare_jid) {
                        remove_keys.add(entry.key);
                    }
                }
                foreach (string remove_key in remove_keys) reducers.unset(remove_key);
                var remove_batch_keys = new ArrayList<string>();
                foreach (var entry in live_batches.entries) {
                    MucRoomKey room = entry.value.room;
                    if (room.account_id == command.account_id &&
                            room.account_bare_jid == command.account_bare_jid) {
                        remove_batch_keys.add(entry.key);
                    }
                }
                foreach (string remove_key in remove_batch_keys) {
                    live_batches.unset(remove_key);
                }
                increment_cancelled_rooms_by((uint64) remove_keys.size);
                clear_account_degraded_tracking(command.account_id,
                    (!) command.account_bare_jid);
                break;
            case MucOccupantWorkerOperation.BARRIER:
                push_output(new MucOccupantWorkerOutput.barrier(command.barrier_id));
                break;
        }
    }

    private void apply_degraded_marker(MucRoomKey room,
            HashMap<string, MucOccupantReducer> reducers,
            HashMap<string, MucOccupantLiveBatch> live_batches) {
        MucOccupantReducer? reducer = exact_reducer(reducers, room);
        if (reducer == null) {
            increment_stale_commands();
            return;
        }
        MucRoomDelta? delta = ((!) reducer).mark_degraded_partial();
        if (delta != null) increment_degraded_rooms();
        handle_reducer_delta(delta, live_batches);
    }

    private void handle_reducer_delta(MucRoomDelta? delta,
            HashMap<string, MucOccupantLiveBatch> live_batches) {
        if (delta == null) return;
        MucRoomDelta current = (!) delta;
        if (emit_incremental_deltas) {
            publish_delta(current);
            return;
        }
        if (!batch_live_deltas || !current.initial_sync_finished ||
                current.full_snapshot) return;

        string key = logical_room_key(current.room);
        MucOccupantLiveBatch? batch = live_batches[key];
        if (batch == null || !((!) batch).room.matches(current.room)) {
            batch = new MucOccupantLiveBatch(current.room);
            live_batches[key] = (!) batch;
        }
        ((!) batch).merge(current);
    }

    private void clear_exact_degraded_tracking(MucRoomKey room) {
        string exact_key = exact_room_key(room);
        ingress_mutex.lock();
        pending_degraded.unset(exact_key);
        degraded_marker_scheduled.remove(exact_key);
        ingress_mutex.unlock();
    }

    private void clear_old_degraded_tracking(MucRoomKey current_room) {
        string logical_prefix = logical_room_key(current_room) + "\x1f";
        string current_exact_key = exact_room_key(current_room);
        ingress_mutex.lock();
        var remove_keys = new ArrayList<string>();
        foreach (string key in degraded_marker_scheduled) {
            if (key != current_exact_key && key.has_prefix(logical_prefix)) {
                remove_keys.add(key);
            }
        }
        foreach (string key in remove_keys) {
            degraded_marker_scheduled.remove(key);
            pending_degraded.unset(key);
        }
        ingress_mutex.unlock();
    }

    private void clear_account_degraded_tracking(int account_id,
            string account_bare_jid) {
        string account_prefix = @"$(account_id)\x1f$(account_bare_jid)\x1f";
        ingress_mutex.lock();
        var remove_keys = new ArrayList<string>();
        foreach (string key in degraded_marker_scheduled) {
            if (key.has_prefix(account_prefix)) remove_keys.add(key);
        }
        foreach (string key in remove_keys) {
            degraded_marker_scheduled.remove(key);
            pending_degraded.unset(key);
        }
        ingress_mutex.unlock();
    }

    private MucOccupantReducer? exact_reducer(
            HashMap<string, MucOccupantReducer> reducers, MucRoomKey room) {
        MucOccupantReducer? reducer = reducers[logical_room_key(room)];
        if (reducer == null || !((!) reducer).room.matches(room)) return null;
        return reducer;
    }

    private void publish_delta(MucRoomDelta? delta) {
        if (delta == null) return;
        push_output(new MucOccupantWorkerOutput.for_delta((!) delta));
    }

    private bool push_output(MucOccupantWorkerOutput output) {
        egress_mutex.lock();
        while (!egress_stopping && egress.length >= egress_capacity) {
            egress_cond.wait(egress_mutex);
        }
        if (egress_stopping) {
            egress_mutex.unlock();
            return false;
        }

        egress.push_tail(output);
        update_egress_depth_locked();
        ensure_egress_source_locked();
        egress_mutex.unlock();
        return true;
    }

    private void ensure_egress_source_locked() {
        if (egress_source != null || egress_stopping) return;
        var source = new IdleSource();
        // Delivery is strictly bounded by main_drain_batch. Normal priority
        // prevents Windows' initial presence burst from starving the completed
        // roster snapshot behind unrelated low-priority startup sources.
        source.set_priority(Priority.DEFAULT);
        source.set_callback(drain_outputs);
        source.attach(delivery_context);
        egress_source = source;
    }

    private bool drain_outputs() {
        uint delivered = 0;
        while (delivered < main_drain_batch) {
            egress_mutex.lock();
            if (egress.is_empty() || egress_stopping) {
                egress_mutex.unlock();
                break;
            }
            MucOccupantWorkerOutput output = egress.pop_head();
            update_egress_depth_locked();
            egress_cond.broadcast();
            egress_mutex.unlock();

            if (output.delta != null) {
                increment_emitted_deltas();
                delta_ready((!) output.delta);
            } else if (output.room != null) {
                room_flushed((!) output.room);
            } else {
                barrier_reached(output.barrier_id);
            }
            delivered++;
        }
        record_main_drain(delivered);

        egress_mutex.lock();
        bool keep = !egress_stopping && !egress.is_empty();
        if (!keep) egress_source = null;
        egress_mutex.unlock();
        return keep ? Source.CONTINUE : Source.REMOVE;
    }

    private string logical_room_key(MucRoomKey room) {
        return @"$(room.account_id)\x1f$(room.account_bare_jid)\x1f$(room.room_bare_jid)";
    }

    private string exact_room_key(MucRoomKey room) {
        return @"$(logical_room_key(room))\x1f$(room.stream_generation)\x1f$(room.room_generation)";
    }

    private void update_ingress_depth_locked() {
        stats_mutex.lock();
        stats_current_ingress_depth = ingress.length;
        stats_peak_ingress_depth = uint.max(stats_peak_ingress_depth,
            stats_current_ingress_depth);
        stats_mutex.unlock();
    }

    private void update_egress_depth_locked() {
        stats_mutex.lock();
        stats_current_egress_depth = egress.length;
        stats_peak_egress_depth = uint.max(stats_peak_egress_depth,
            stats_current_egress_depth);
        stats_mutex.unlock();
    }

    private void record_accepted_envelope(bool control) {
        stats_mutex.lock();
        stats_accepted_envelopes++;
        if (control) stats_accepted_control_commands++;
        stats_mutex.unlock();
    }

    private void increment_control_commands() {
        increment_control_commands_by(1);
    }

    private void increment_control_commands_by(uint64 count) {
        stats_mutex.lock();
        stats_accepted_control_commands += count;
        stats_mutex.unlock();
    }

    private void increment_dropped_available() {
        stats_mutex.lock();
        stats_dropped_available++;
        stats_mutex.unlock();
    }

    private void increment_evicted_available() {
        stats_mutex.lock();
        stats_evicted_available++;
        stats_mutex.unlock();
    }

    private void increment_processed_commands() {
        stats_mutex.lock();
        stats_processed_commands++;
        stats_mutex.unlock();
    }

    private void increment_stale_commands() {
        stats_mutex.lock();
        stats_stale_commands++;
        stats_mutex.unlock();
    }

    private void increment_emitted_deltas() {
        stats_mutex.lock();
        stats_emitted_deltas++;
        stats_mutex.unlock();
    }

    private void increment_degraded_rooms() {
        stats_mutex.lock();
        stats_degraded_rooms++;
        stats_mutex.unlock();
    }

    private void increment_started_rooms() {
        stats_mutex.lock();
        stats_started_rooms++;
        stats_mutex.unlock();
    }

    private void increment_cancelled_rooms() {
        increment_cancelled_rooms_by(1);
    }

    private void increment_cancelled_rooms_by(uint64 count) {
        stats_mutex.lock();
        stats_cancelled_rooms += count;
        stats_mutex.unlock();
    }

    private void record_main_drain(uint delivered) {
        stats_mutex.lock();
        stats_main_drain_passes++;
        stats_max_delivered_in_pass = uint.max(stats_max_delivered_in_pass, delivered);
        stats_mutex.unlock();
    }

    private void set_worker_running(bool running) {
        stats_mutex.lock();
        stats_worker_running = running;
        if (running) stats_worker_thread_id = (int64) Thread.self<void*>();
        stats_mutex.unlock();
    }
}

private class MucOccupantLiveBatch : Object {
    internal MucRoomKey room { get; private set; }

    private HashMap<string, MucOccupantSnapshot> changed =
        new HashMap<string, MucOccupantSnapshot>();
    private HashMap<string, int> changed_flags = new HashMap<string, int>();
    private HashSet<string> removed = new HashSet<string>();
    private uint64 revision = 0;
    private bool initial_sync_started = true;
    private bool initial_snapshot_ready = true;
    private bool initial_sync_finished = true;
    private bool degraded_partial = false;
    private uint occupant_count = 0;

    internal MucOccupantLiveBatch(MucRoomKey room) {
        this.room = room;
    }

    internal void merge(MucRoomDelta delta) {
        if (!room.matches(delta.room)) return;

        revision = delta.revision;
        initial_sync_started = delta.initial_sync_started;
        initial_snapshot_ready = delta.initial_snapshot_ready;
        initial_sync_finished = delta.initial_sync_finished;
        degraded_partial = delta.degraded_partial;
        occupant_count = delta.occupant_count;

        for (uint i = 0; i < delta.removed_count; i++) {
            string occupant_id = delta.removed_at(i);
            changed.unset(occupant_id);
            changed_flags.unset(occupant_id);
            removed.add(occupant_id);
        }
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantSnapshot snapshot = delta.changed_at(i);
            string occupant_id = snapshot.occupant_full_jid;
            removed.remove(occupant_id);
            changed[occupant_id] = snapshot;
            int previous_flags = changed_flags.has_key(occupant_id)
                ? changed_flags[occupant_id]
                : (int) MucOccupantChange.NONE;
            changed_flags[occupant_id] = previous_flags |
                (int) delta.changed_flags_at(i);
        }
    }

    internal MucRoomDelta to_delta() {
        var changed_ids = new ArrayList<string>();
        changed_ids.add_all(changed.keys);
        changed_ids.sort((left, right) => strcmp(left, right));

        var changed_values = new ArrayList<MucOccupantSnapshot>();
        var flags = new ArrayList<int>();
        foreach (string occupant_id in changed_ids) {
            changed_values.add(changed[occupant_id]);
            flags.add(changed_flags[occupant_id]);
        }

        var removed_values = new ArrayList<string>();
        removed_values.add_all(removed);
        removed_values.sort((left, right) => strcmp(left, right));

        return new MucRoomDelta(room, revision, initial_sync_started,
            initial_snapshot_ready, initial_sync_finished, degraded_partial,
            false, occupant_count, changed_values.to_array(),
            removed_values.to_array(), flags.to_array());
    }
}

private enum MucOccupantWorkerOperation {
    START_ROOM,
    ENVELOPE,
    FINISH_ROOM,
    MARK_DEGRADED,
    SNAPSHOT_ROOM,
    FLUSH_ROOM,
    CANCEL_ROOM,
    CANCEL_ACCOUNT,
    BARRIER
}

private class MucOccupantWorkerCommand : Object {
    internal MucOccupantWorkerOperation operation { get; private set; }
    internal MucRoomKey? room { get; private set; }
    internal MucPresenceEnvelope? envelope { get; private set; }
    internal bool degraded_partial { get; private set; }
    internal int account_id { get; private set; }
    internal string? account_bare_jid { get; private set; }
    internal uint64 barrier_id { get; private set; }
    internal bool evictable_available { get; private set; }

    private MucRoomKey[] degraded_before_value = new MucRoomKey[0];

    internal uint degraded_before_count {
        get { return (uint) degraded_before_value.length; }
    }

    internal MucRoomKey degraded_before_at(uint index) {
        return degraded_before_value[index];
    }

    internal void set_degraded_before(MucRoomKey[] rooms) {
        degraded_before_value = new MucRoomKey[rooms.length];
        for (int i = 0; i < rooms.length; i++) degraded_before_value[i] = rooms[i];
    }

    internal MucOccupantWorkerCommand.start_room(MucRoomKey room) {
        operation = MucOccupantWorkerOperation.START_ROOM;
        this.room = room;
    }

    internal MucOccupantWorkerCommand.for_envelope(MucPresenceEnvelope envelope) {
        operation = MucOccupantWorkerOperation.ENVELOPE;
        this.envelope = envelope;
        this.room = envelope.room;
        evictable_available = envelope.kind == MucWorkerPresenceKind.AVAILABLE &&
            !envelope.is_self_presence && envelope.status_code_count == 0;
    }

    internal MucOccupantWorkerCommand.finish_room(MucRoomKey room, bool degraded_partial) {
        operation = MucOccupantWorkerOperation.FINISH_ROOM;
        this.room = room;
        this.degraded_partial = degraded_partial;
    }

    internal MucOccupantWorkerCommand.mark_degraded(MucRoomKey room) {
        operation = MucOccupantWorkerOperation.MARK_DEGRADED;
        this.room = room;
    }

    internal MucOccupantWorkerCommand.snapshot_room(MucRoomKey room) {
        operation = MucOccupantWorkerOperation.SNAPSHOT_ROOM;
        this.room = room;
    }

    internal MucOccupantWorkerCommand.flush_room(MucRoomKey room) {
        operation = MucOccupantWorkerOperation.FLUSH_ROOM;
        this.room = room;
    }

    internal MucOccupantWorkerCommand.cancel_room(MucRoomKey room) {
        operation = MucOccupantWorkerOperation.CANCEL_ROOM;
        this.room = room;
    }

    internal MucOccupantWorkerCommand.cancel_account(int account_id, string account_bare_jid) {
        operation = MucOccupantWorkerOperation.CANCEL_ACCOUNT;
        this.account_id = account_id;
        this.account_bare_jid = account_bare_jid;
    }

    internal MucOccupantWorkerCommand.barrier(uint64 barrier_id) {
        operation = MucOccupantWorkerOperation.BARRIER;
        this.barrier_id = barrier_id;
    }
}

private class MucOccupantWorkerOutput : Object {
    internal MucRoomDelta? delta { get; private set; }
    internal MucRoomKey? room { get; private set; }
    internal uint64 barrier_id { get; private set; }

    internal MucOccupantWorkerOutput.for_delta(MucRoomDelta delta) {
        this.delta = delta;
    }

    internal MucOccupantWorkerOutput.barrier(uint64 barrier_id) {
        this.barrier_id = barrier_id;
    }

    internal MucOccupantWorkerOutput.room_flushed(MucRoomKey room) {
        this.room = room;
    }
}

}
