using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

protected class RosterList : Object {

    public signal void conversation_selected(Conversation? conversation);
    public signal void rows_changed();
    private StreamInteractor stream_interactor;
    private Gee.List<Account> accounts;
    private ulong[] handler_ids = new ulong[0];
    private RosterManager? roster_manager = null;

    private ListBox list_box = new ListBox();
    private HashMap<Account, HashMap<Jid, ListBoxRow>> rows = new HashMap<Account, HashMap<Jid, ListBoxRow>>(Account.hash_func, Account.equals_func);

    private Gee.List<Roster.Item> pending_items = new Gee.ArrayList<Roster.Item>();
    private Account? pending_account;
    private int pending_account_index = 0;
    private uint initial_load_timeout_id = 0;
    private bool load_scheduled = false;
    private bool load_started = false;
    private uint batch_timeout_id = 0;
    private uint hydration_timeout_id = 0;
    private bool disposed = false;
    private int loaded_rows = 0;
    private int64 load_start_us = 0;
    private bool timing_enabled = false;
    private const int WORK_BUDGET_US = 2500;
    private const uint INITIAL_LOAD_DELAY_MS = 30;
    private const uint BATCH_PROCESS_DELAY_MS = 4;
    private const int HYDRATION_BATCH_SIZE = 24;
    private const int PENDING_ROSTER_CHANGE_BATCH_SIZE = 40;
    private int pending_batch_offset = 0;
    private int pending_hydration_offset = 0;
    private bool suppress_initial_updates = false;
    private Gee.List<ListRow> pending_hydrations = new Gee.ArrayList<ListRow>();
    private HashMap<string, PendingRosterChange> pending_roster_changes = new HashMap<string, PendingRosterChange>();
    private Gee.List<string> pending_roster_change_order = new Gee.ArrayList<string>();
    private uint pending_roster_change_flush_id = 0;
    private uint ui_refresh_timeout_id = 0;
    private bool ui_refresh_needs_rows_changed = false;
    private bool draining_pending_roster_changes = false;

    private class PendingRosterChange : Object {
        public Account account;
        public Jid jid;
        public bool is_remove;
        public string? display_name;

        public PendingRosterChange(Account account, Jid jid, bool is_remove, string? display_name = null) {
            this.account = account;
            this.jid = jid;
            this.is_remove = is_remove;
            this.display_name = display_name;
        }
    }

    public RosterList(StreamInteractor stream_interactor, Gee.List<Account> accounts, bool auto_start = true) {
        timing_enabled = UiTiming.enabled();
        int64 t0_us = timing_enabled ? UiTiming.now_us() : 0;
        this.stream_interactor = stream_interactor;
        this.accounts = accounts;
        this.load_started = false;
        this.load_scheduled = false;

        roster_manager = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        if (roster_manager != null) {
            handler_ids += roster_manager.removed_roster_item.connect((account, jid, _roster_item) => {
                if (!disposed && accounts.contains(account)) {
                    if (suppress_initial_updates || draining_pending_roster_changes) {
                        upsert_pending_roster_change(get_roster_change_key(account, jid), new PendingRosterChange(account, jid, true));
                        schedule_pending_roster_change_apply();
                    } else {
                        remove_row(account, jid);
                    }
                }
            });
            handler_ids += roster_manager.updated_roster_item.connect((account, jid, roster_item) => {
                if (!disposed && accounts.contains(account)) {
                    if (suppress_initial_updates || draining_pending_roster_changes) {
                        upsert_pending_roster_change(get_roster_change_key(account, jid), new PendingRosterChange(account, jid, false, roster_item.name));
                        schedule_pending_roster_change_apply();
                    } else {
                        update_row(account, jid, roster_item.name);
                    }
                }
            });
        } else {
            warning("RosterList: RosterManager unavailable for account list updates");
        }
        list_box.destroy.connect(() => {
            deactivate();
        });

        // Initialize row maps for all accounts
        foreach (Account a in accounts) {
            rows[a] = new HashMap<Jid, ListBoxRow>(Jid.hash_func, Jid.equals_func);
        }

        if (auto_start) {
            start_loading();
        }
        if (timing_enabled) {
            UiTiming.log_ms("RosterList.constructor: accounts=%d".printf(accounts.size), t0_us);
        }
    }

    private void cancel_pending_loads() {
        if (initial_load_timeout_id != 0) {
            Source.remove(initial_load_timeout_id);
            initial_load_timeout_id = 0;
        }
        load_scheduled = false;
        if (batch_timeout_id != 0) {
            Source.remove(batch_timeout_id);
            batch_timeout_id = 0;
        }
        if (hydration_timeout_id != 0) {
            Source.remove(hydration_timeout_id);
            hydration_timeout_id = 0;
        }
        pending_hydrations.clear();
        pending_hydration_offset = 0;
        if (pending_roster_change_flush_id != 0) {
            Source.remove(pending_roster_change_flush_id);
            pending_roster_change_flush_id = 0;
        }
        draining_pending_roster_changes = false;
        pending_roster_changes.clear();
        pending_roster_change_order.clear();
        if (ui_refresh_timeout_id != 0) {
            Source.remove(ui_refresh_timeout_id);
            ui_refresh_timeout_id = 0;
        }
        ui_refresh_needs_rows_changed = false;
    }

    public void start_loading() {
        if (disposed || load_started || load_scheduled) {
            return;
        }
        if (loaded_rows > 0) {
            clear_all_rows();
        }
        load_scheduled = true;
        initial_load_timeout_id = Timeout.add_full(GLib.Priority.DEFAULT, INITIAL_LOAD_DELAY_MS, () => {
            initial_load_timeout_id = 0;
            load_scheduled = false;
            if (disposed) {
                return false;
            }
            load_started = true;
            start_deferred_load();
            return false;
        });
    }

    public void deactivate() {
        if (disposed) return;
        disposed = true;
        cancel_pending_loads();
        foreach (ulong handler_id in handler_ids) {
            if (roster_manager != null) {
                roster_manager.disconnect(handler_id);
            }
        }
        handler_ids = new ulong[0];
    }

    private void start_deferred_load() {
        if (disposed) return;
        suppress_initial_updates = true;
        if (timing_enabled) {
            load_start_us = UiTiming.now_us();
        }
        loaded_rows = 0;
        clear_all_rows();
        pending_account_index = 0;
        pending_batch_offset = 0;
        if (hydration_timeout_id != 0) {
            Source.remove(hydration_timeout_id);
            hydration_timeout_id = 0;
        }
        pending_hydrations.clear();
        pending_hydration_offset = 0;
        pending_roster_changes.clear();
        pending_roster_change_order.clear();
        draining_pending_roster_changes = false;
        load_next_account();
    }

    private void load_next_account() {
        if (disposed) return;
        if (pending_account_index >= accounts.size) {
            complete_initial_load();
            return;
        }

        int64 t0_us = timing_enabled ? UiTiming.now_us() : 0;
        pending_account = accounts[pending_account_index];
        if (roster_manager == null) {
            warning("RosterList: RosterManager unavailable while loading roster");
            complete_initial_load();
            return;
        }
        var roster = roster_manager.get_roster(pending_account);
        pending_items.clear();
        pending_items.add_all(roster);
        if (timing_enabled) {
            UiTiming.log_ms("RosterList.load_next_account: account_index=%d items=%d".printf(pending_account_index, pending_items.size), t0_us);
        }

        if (pending_items.size == 0) {
            pending_account_index++;
            load_next_account();
            return;
        }

        pending_batch_offset = 0;
        schedule_batch();
    }

    private void schedule_batch() {
        if (disposed) return;
        if (batch_timeout_id != 0) return;
        batch_timeout_id = Timeout.add_full(deferred_work_priority(), BATCH_PROCESS_DELAY_MS, () => {
            batch_timeout_id = 0;
            return process_batch();
        });
    }

    private bool process_batch() {
        if (disposed || pending_account == null) return false;
        int64 t0_us = timing_enabled ? UiTiming.now_us() : 0;
        int64 deadline_us = GLib.get_monotonic_time() + WORK_BUDGET_US;
        int start_offset = pending_batch_offset;
        bool show_account = accounts.size > 1;

        while (pending_batch_offset < pending_items.size && GLib.get_monotonic_time() < deadline_us) {
            int i = pending_batch_offset;
            Roster.Item item = pending_items[i];
            ListRow row = new ListRow.from_jid(stream_interactor, item.jid, pending_account, show_account, item.name, false);
            ListBoxRow list_box_row = new ListBoxRow() { child=row };
            rows[pending_account][item.jid] = list_box_row;
            list_box.append(list_box_row);
            queue_row_for_hydration(row);
            pending_batch_offset++;
        }

        int rows_added = pending_batch_offset - start_offset;
        if (rows_added > 0) {
            loaded_rows += rows_added;
            schedule_ui_refresh();
        }
        if (timing_enabled) {
            UiTiming.log_ms("RosterList.load_batch: account_index=%d offset=%d rows=%d loaded=%d pending=%d".printf(pending_account_index, start_offset, rows_added, loaded_rows, pending_items.size), t0_us);
        }

        if (pending_batch_offset < pending_items.size) {
            schedule_batch();
            return false;
        }

        if (pending_account_index + 1 < accounts.size) {
            schedule_ui_refresh();
            pending_account_index++;
            schedule_next_account();
            return false;
        }

        complete_initial_load();
        return false;
    }

    private void schedule_next_account() {
        if (disposed) return;
        if (batch_timeout_id != 0) return;
        batch_timeout_id = Timeout.add_full(deferred_work_priority(), BATCH_PROCESS_DELAY_MS, () => {
            batch_timeout_id = 0;
            load_next_account();
            return false;
        });
    }

    private void remove_row(Account account, Jid jid, bool signal_change = true) {
        if (disposed) return;
        if (rows.has_key(account) && rows[account].has_key(jid)) {
            var list_box_row = rows[account][jid];
            remove_list_box_row(list_box_row);
            rows[account].unset(jid);
            if (signal_change) schedule_ui_refresh_with_rows_changed();
        }
    }

    private void remove_list_box_row(ListBoxRow list_box_row) {
        ListRow? list_row = list_box_row.child as ListRow;
        if (list_row != null) {
            list_row.deactivate();
        }
        list_box.remove(list_box_row);
    }

    private void update_row(Account account, Jid jid, string? display_name = null, bool do_rows_changed = true) {
        if (disposed) return;
        remove_row(account, jid, false);
        ListRow row = new ListRow.from_jid(stream_interactor, jid, account, accounts.size > 1, display_name, false);
        ListBoxRow list_box_row = new ListBoxRow() { child=row };
        rows[account][jid] = list_box_row;
        list_box.append(list_box_row);
        queue_row_for_hydration(row);
        if (do_rows_changed) schedule_ui_refresh_with_rows_changed();
    }

    private void schedule_hydrate_rows() {
        if (disposed || hydration_timeout_id != 0) return;
        hydration_timeout_id = Idle.add_full(deferred_work_priority(), () => {
            hydration_timeout_id = 0;
            return process_hydrate_rows();
        });
    }

    private int deferred_work_priority() {
#if WINDOWS
        // The visible contact dialog uses bounded 2.5 ms batches. LOW sources
        // can otherwise be starved for seconds by startup MUC presence work.
        return GLib.Priority.DEFAULT;
#else
        return GLib.Priority.LOW;
#endif
    }

    private void queue_row_for_hydration(ListRow row) {
        pending_hydrations.add(row);
        schedule_hydrate_rows();
    }

    private bool process_hydrate_rows() {
        int64 t0_us = timing_enabled ? UiTiming.now_us() : 0;
        if (disposed) return false;
        int processed = 0;
        int64 deadline_us = GLib.get_monotonic_time() + WORK_BUDGET_US;
        while (pending_hydration_offset < pending_hydrations.size && processed < HYDRATION_BATCH_SIZE && GLib.get_monotonic_time() < deadline_us) {
            ListRow row = pending_hydrations[pending_hydration_offset];
            if (!row.is_disposed) {
                row.hydrate_immediately();
            }
            pending_hydration_offset++;
            processed++;
        }
        if (processed > 0) {
            schedule_ui_refresh();
        }
        if (pending_hydration_offset < pending_hydrations.size) {
            schedule_hydrate_rows();
            return false;
        }
        pending_hydrations.clear();
        pending_hydration_offset = 0;
        if (timing_enabled) {
            UiTiming.log_ms("RosterList.hydrate_batch_done", t0_us);
        }
        return false;
    }

    private string get_roster_change_key(Account account, Jid jid) {
        return account.bare_jid.to_string() + "\t" + jid.to_string();
    }

    private void apply_pending_roster_changes() {
        if (disposed || pending_roster_changes.size == 0) return;
        int64 t0_us = timing_enabled ? UiTiming.now_us() : 0;
        int total = pending_roster_changes.size;
        int applied = 0;

        while (pending_roster_change_order.size > 0 && applied < PENDING_ROSTER_CHANGE_BATCH_SIZE) {
            string key = pending_roster_change_order.remove_at(0);
            PendingRosterChange? change = pending_roster_changes[key];
            pending_roster_changes.unset(key);
            if (change == null) {
                continue;
            }
            apply_pending_roster_change(change);
            applied++;
        }

        if (pending_roster_change_order.size == 0) {
            pending_roster_changes.clear();
            draining_pending_roster_changes = false;
        } else {
            schedule_pending_roster_change_apply(1);
        }

        if (applied > 0) {
            schedule_ui_refresh_with_rows_changed();
        }
        if (timing_enabled) {
            UiTiming.log_ms("RosterList.apply_pending_roster_changes: applied=%d total_before=%d remaining=%d".printf(applied, total, pending_roster_changes.size), t0_us);
        }
    }

    private void apply_pending_roster_change(PendingRosterChange change) {
        if (change.is_remove) {
            remove_row(change.account, change.jid, false);
        } else {
            update_row(change.account, change.jid, change.display_name, false);
        }
    }

    private void upsert_pending_roster_change(string key, PendingRosterChange change) {
        bool already_present = pending_roster_changes.has_key(key);
        pending_roster_changes[key] = change;
        if (!already_present) {
            pending_roster_change_order.add(key);
        }
    }

    private void schedule_pending_roster_change_apply(uint delay_ms = 25) {
        if (disposed || pending_roster_changes.size == 0 || pending_roster_change_flush_id != 0) {
            return;
        }
        if (suppress_initial_updates) {
            return;
        }
        pending_roster_change_flush_id = Timeout.add(delay_ms, () => {
            pending_roster_change_flush_id = 0;
            if (disposed) return false;
            apply_pending_roster_changes();
            return false;
        });
    }

    private void complete_initial_load() {
        if (pending_roster_change_flush_id != 0) {
            Source.remove(pending_roster_change_flush_id);
            pending_roster_change_flush_id = 0;
        }
        suppress_initial_updates = false;
        draining_pending_roster_changes = pending_roster_changes.size > 0;
        load_started = false;
        if (ui_refresh_timeout_id != 0) {
            Source.remove(ui_refresh_timeout_id);
            ui_refresh_timeout_id = 0;
        }
        ui_refresh_needs_rows_changed = false;
        schedule_ui_refresh_with_rows_changed();
        schedule_pending_roster_change_apply(1);
        if (timing_enabled) {
            UiTiming.log_ms("RosterList.deferred_load: rows=%d".printf(loaded_rows), load_start_us);
        }
    }

    private void schedule_ui_refresh_with_rows_changed() {
        if (disposed) return;
        ui_refresh_needs_rows_changed = true;
        schedule_ui_refresh();
    }

    private void schedule_ui_refresh() {
        if (disposed) return;
        if (ui_refresh_timeout_id != 0) return;
        ui_refresh_timeout_id = Timeout.add(0, () => {
            if (disposed) {
                ui_refresh_timeout_id = 0;
                ui_refresh_needs_rows_changed = false;
                return false;
            }
            ui_refresh_timeout_id = 0;
            list_box.invalidate_sort();
            list_box.invalidate_filter();
            bool should_signal_rows_changed = ui_refresh_needs_rows_changed;
            ui_refresh_needs_rows_changed = false;
            if (should_signal_rows_changed) {
                rows_changed();
            }
            return false;
        });
    }

    private void clear_all_rows() {
        foreach (Account account in accounts) {
            if (!rows.has_key(account)) {
                continue;
            }
            var account_rows = rows[account];
            var removal_rows = new Gee.ArrayList<ListBoxRow>();
            foreach (ListBoxRow row in account_rows.values) {
                removal_rows.add(row);
            }
            foreach (ListBoxRow row in removal_rows) {
                remove_list_box_row(row);
            }
            account_rows.clear();
        }
        schedule_ui_refresh();
    }

    public ListBox get_list_box() {
        return list_box;
    }
}

}
