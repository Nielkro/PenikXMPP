using Gdk;
using Gee;
using Gtk;

using Xmpp;
using Dino.Entities;

namespace Dino.Ui {

public class ConversationSelector : Widget {

    public signal void conversation_selected(Conversation conversation);
    public signal void conversation_activated(Conversation conversation);

    ListBox list_box = new ListBox() { hexpand=true };

    private StreamInteractor stream_interactor;
    private HashMap<Conversation, ConversationSelectorRow> rows = new HashMap<Conversation, ConversationSelectorRow>(Conversation.hash_func, Conversation.equals_func);
    // Guard: conversations currently being removed (collapse animation in progress).
    // Prevents add_conversation from re-creating a row during the async yield.
    private HashSet<Conversation> removing_conversations = new HashSet<Conversation>(Conversation.hash_func, Conversation.equals_func);
    private HashMap<Conversation, uint> pending_removal_source_ids = new HashMap<Conversation, uint>(Conversation.hash_func, Conversation.equals_func);
    private uint row_update_source_id = 0;
    private uint invalidate_sort_source_id = 0;
    private bool startup_row_timing_enabled = false;
    private uint startup_row_timing_flush_source_id = 0;
    private int startup_row_count = 0;
    private int64 startup_row_batch_started_us = 0;
    private int64 startup_row_batch_finished_us = 0;
    private int64 startup_row_total_us = 0;
    private int64 startup_latest_query_total_us = 0;
    private int64 startup_latest_query_max_us = 0;

    private bool ignore_selection_changes = false;
    private bool disposed = false;
    private bool compact_ = false;

    public bool compact {
        get { return compact_; }
        set {
            if (compact_ == value) return;
            compact_ = value;
            foreach (ConversationSelectorRow row in rows.values) row.compact = value;
        }
    }

    public ConversationSelector init(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        startup_row_timing_enabled = UiTiming.enabled();
        list_box.set_parent(this);
        list_box.add_css_class("navigation-sidebar");
        this.layout_manager = new BinLayout();

        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_activated.connect(add_conversation);
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_deactivated.connect(remove_conversation);
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_hidden.connect(remove_conversation);
        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).new_item.connect(on_content_item_received);
        row_update_source_id = Dino.WeakTimeout.add_seconds(
            60, this, update_row_times);

        foreach (Conversation conversation in stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations()) {
            add_conversation(conversation);
        }
        return this;
    }

    private static bool update_row_times(ConversationSelector selector) {
        if (selector.disposed) return Source.REMOVE;
        foreach (ConversationSelectorRow row in selector.rows.values) {
            row.update();
        }
        return Source.CONTINUE;
    }

    construct {
        list_box.set_sort_func(sort);

        // Selection loads the conversation once. Activation also works for the
        // current row after Back, and requests navigation without reloading it.
        list_box.row_selected.connect(on_row_selected);
        list_box.row_activated.connect((r) => {
            if (ignore_selection_changes) return;
            ConversationSelectorRow? row = r as ConversationSelectorRow;
            if (row != null) conversation_activated(row.conversation);
        });
    }

    private void on_row_selected(ListBoxRow? r) {
        if (ignore_selection_changes || r == null) return;

        int64 started_us = UiTiming.now_us();
        debug("ConversationSelector.on_row_selected: Called");
        ConversationSelectorRow? row = r as ConversationSelectorRow;
        if (row != null) {
            if (UiTiming.enabled()) {
                GLib.message("UI-TIMING ConversationSelector.on_row_selected: begin target=%d:%s",
                    row.conversation.id,
                    row.conversation.counterpart.bare_jid.to_string());
            }
            debug("ConversationSelector.on_row_selected: Emitting conversation_selected for %s", row.conversation.counterpart.to_string());
            conversation_selected(row.conversation);
            UiTiming.log_ms("ConversationSelector.on_row_selected: groupchat=%s target=%d:%s".printf(
                row.conversation.type_ == Conversation.Type.GROUPCHAT ? "true" : "false",
                row.conversation.id, row.conversation.counterpart.bare_jid.to_string()), started_us);
        } else {
            debug("ConversationSelector.on_row_selected: row is not ConversationSelectorRow!");
        }
    }

    public void on_conversation_selected(Conversation conversation) {
        if (!restore_pending_removal(conversation)) return;
        if (!rows.has_key(conversation)) {
            add_conversation(conversation);
        }
        
        bool prev_ignore = ignore_selection_changes;
        ignore_selection_changes = true;
        list_box.select_row(rows[conversation]);
        ignore_selection_changes = prev_ignore;
    }

    private void on_content_item_received(ContentItem item, Conversation conversation) {
        if (rows.has_key(conversation)) {
            schedule_invalidate_sort();
        }
    }

    private void on_account_added(Account account) {
        foreach (Conversation conversation in stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations()) {
            if (conversation.account == account) {
                add_conversation(conversation);
            }
        }
    }

    private void on_account_removed(Account account) {
        ArrayList<Conversation> to_remove = new ArrayList<Conversation>();
        foreach (Conversation conversation in rows.keys) {
             if (conversation.account == account) {
                 to_remove.add(conversation);
             }
        }
        foreach (Conversation conversation in to_remove) {
            remove_conversation(conversation);
        }
    }

    private void add_conversation(Conversation conversation) {
        if (!conversation.account.enabled) return;
        bool was_being_removed = removing_conversations.contains(conversation);
        if (!restore_pending_removal(conversation)) return;
        if (was_being_removed) {
            // Incoming content can reactivate a hidden conversation while its
            // two-phase row removal is pending. Keep the existing row instead
            // of losing the only conversation_activated signal.
            schedule_invalidate_sort();
            return;
        }
        ConversationSelectorRow row;
        if (!rows.has_key(conversation)) {
            int64 row_started_us = startup_row_timing_enabled ? UiTiming.now_us() : 0;
            conversation.notify["pinned"].connect(list_box.invalidate_sort);

            row = new ConversationSelectorRow(stream_interactor, conversation);
            row.compact = compact;
            rows[conversation] = row;
            list_box.append(row);
            row.main_revealer.set_reveal_child(true);

            EventControllerLegacy input_trace = new EventControllerLegacy();
            input_trace.propagation_phase = PropagationPhase.CAPTURE;
            input_trace.event.connect((event) => {
                if (!UiTiming.enabled()) return false;
                Gdk.EventType event_type = event.get_event_type();
                bool is_press = event_type == Gdk.EventType.BUTTON_PRESS ||
                    event_type == Gdk.EventType.TOUCH_BEGIN;
                bool is_release = event_type == Gdk.EventType.BUTTON_RELEASE ||
                    event_type == Gdk.EventType.TOUCH_END;
                if (is_press || is_release) {
                    GLib.message("UI-TIMING ConversationSelector.input_%s: delivered target=%d:%s",
                        is_press ? "press" : "release", conversation.id,
                        conversation.counterpart.bare_jid.to_string());
                }
                return false;
            });
            row.add_controller(input_trace);

            // Set up drag motion behaviour (select conversation after timeout)
            DropControllerMotion drop_motion_controller = new DropControllerMotion();
            uint drag_timeout = 0;
            drop_motion_controller.motion.connect((x, y) => {
                if (drag_timeout != 0) return;
                drag_timeout = Timeout.add(200, () => {
                    conversation_selected(conversation);
                    drag_timeout = 0;
                    return false;
                });
            });
            drop_motion_controller.leave.connect(() => {
                if (drag_timeout != 0) {
                    Source.remove(drag_timeout);
                    drag_timeout = 0;
                }
            });
            row.add_controller(drop_motion_controller);

            if (row_started_us != 0) {
                record_startup_row_timing(row, UiTiming.now_us() - row_started_us);
            }
        }
        schedule_invalidate_sort();
    }

    private bool restore_pending_removal(Conversation conversation) {
        if (!removing_conversations.contains(conversation)) return true;

        bool account_is_managed = false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account.equals(conversation.account)) {
                account_is_managed = true;
                break;
            }
        }
        if (!account_is_managed) return false;

        uint source_id = pending_removal_source_ids.has_key(conversation)
            ? pending_removal_source_ids[conversation]
            : 0;
        if (source_id != 0) Source.remove(source_id);
        pending_removal_source_ids.unset(conversation);
        removing_conversations.remove(conversation);
        if (rows.has_key(conversation)) {
            rows[conversation].set_selectable(true);
            rows[conversation].set_sensitive(true);
        }
        return true;
    }

    private void record_startup_row_timing(ConversationSelectorRow row, int64 row_total_us) {
        if (!startup_row_timing_enabled) return;

        int64 row_finished_us = UiTiming.now_us();
        if (startup_row_count == 0) {
            startup_row_batch_started_us = row_finished_us - row_total_us;
        }
        startup_row_batch_finished_us = row_finished_us;
        startup_row_count++;
        startup_row_total_us += row_total_us;
        startup_latest_query_total_us += row.initial_latest_query_us;
        startup_latest_query_max_us = int64.max(startup_latest_query_max_us, row.initial_latest_query_us);

        if (startup_row_timing_flush_source_id == 0) {
            startup_row_timing_flush_source_id = Idle.add(() => {
                startup_row_timing_flush_source_id = 0;
                startup_row_timing_enabled = false;
                GLib.message(
                    "UI-TIMING ConversationSelector.startup_rows: rows=%d creation_span=%.2f ms row_total=%.2f ms latest_query_total=%.2f ms latest_query_max=%.2f ms",
                    startup_row_count,
                    (startup_row_batch_finished_us - startup_row_batch_started_us) / 1000.0,
                    startup_row_total_us / 1000.0,
                    startup_latest_query_total_us / 1000.0,
                    startup_latest_query_max_us / 1000.0
                );
                return false;
            });
        }
    }

    private void schedule_invalidate_sort() {
        if (invalidate_sort_source_id != 0) return;
        invalidate_sort_source_id = Timeout.add_full(GLib.Priority.LOW, 50, () => {
            invalidate_sort_source_id = 0;
            list_box.invalidate_sort();
            return false;
        });
    }

    private bool is_active_conversation_row(ListBoxRow? row) {
        ConversationSelectorRow? conversation_row = row as ConversationSelectorRow;
        if (conversation_row == null) return false;

        Conversation conversation = ((!) conversation_row).conversation;
        return rows.has_key(conversation) && rows[conversation] == conversation_row &&
            !removing_conversations.contains(conversation);
    }

    private ListBoxRow? get_fallback_conversation_row(ConversationSelectorRow removed_row) {
        int removed_index = removed_row.get_index();
        if (removed_index < 0) removed_index = 0;

        for (int index = removed_index + 1; ; index++) {
            ListBoxRow? candidate = list_box.get_row_at_index(index);
            if (candidate == null) break;
            if (is_active_conversation_row(candidate)) return candidate;
        }
        for (int index = removed_index - 1; index >= 0; index--) {
            ListBoxRow? candidate = list_box.get_row_at_index(index);
            if (candidate != null && is_active_conversation_row(candidate)) return candidate;
        }
        return null;
    }

    private void finish_removing_conversation(Conversation conversation) {
        pending_removal_source_ids.unset(conversation);
        removing_conversations.remove(conversation);
    }

    private void detach_conversation_row(Conversation conversation,
            ConversationSelectorRow conversation_row) {
        if (!rows.has_key(conversation) || rows[conversation] != conversation_row) {
            return;
        }
        conversation.notify["pinned"].disconnect(list_box.invalidate_sort);
        rows.unset(conversation);
        conversation_row.cleanup();
    }

    private void schedule_physical_row_removal(Conversation conversation, ConversationSelectorRow conversation_row) {
        int64 scheduled_us = UiTiming.now_us();
        uint remove_source_id = 0;
        WeakRef selector_weak = WeakRef(this);
        // Let the redraw requested by fallback selection run before GTK tears
        // the old row hierarchy down. The callback is queued from inside the
        // DEFAULT_IDLE fallback, so it remains a separate main-loop phase. A
        // slightly higher priority prevents the new timeline's DEFAULT_IDLE
        // item initialization from delaying the old row removal again.
        remove_source_id = Idle.add_full(GLib.Priority.DEFAULT_IDLE - 1, () => {
            ConversationSelector? selector = (ConversationSelector?) selector_weak.get();
            if (selector == null) return Source.REMOVE;
            return ((!) selector).run_physical_row_removal(conversation,
                conversation_row, remove_source_id, scheduled_us);
        });
        pending_removal_source_ids[conversation] = remove_source_id;
    }

    private bool run_physical_row_removal(Conversation conversation,
            ConversationSelectorRow conversation_row, uint remove_source_id,
            int64 scheduled_us) {
        if (disposed || !removing_conversations.contains(conversation) ||
                !pending_removal_source_ids.has_key(conversation) ||
                pending_removal_source_ids[conversation] != remove_source_id) {
            return Source.REMOVE;
        }
        pending_removal_source_ids.unset(conversation);

        UiTiming.log_ms("ConversationSelector.remove_conversation: physical_row_removal_wait",
            scheduled_us);
        int64 started_us = UiTiming.now_us();
        if (conversation_row.get_parent() == list_box) {
            ListBoxRow? current_selection = list_box.get_selected_row();
            bool previous_ignore_selection_changes = ignore_selection_changes;
            ignore_selection_changes = true;
            detach_conversation_row(conversation, conversation_row);
            // Once the old row is detached from our map, a nested activation
            // may safely create its replacement while GTK unparents this row.
            removing_conversations.remove(conversation);
            list_box.remove(conversation_row);
            if (current_selection != null && current_selection != conversation_row &&
                    current_selection.get_parent() == list_box &&
                    list_box.get_selected_row() != current_selection) {
                list_box.select_row(current_selection);
            }
            ignore_selection_changes = previous_ignore_selection_changes;
        }
        removing_conversations.remove(conversation);
        UiTiming.log_ms("ConversationSelector.remove_conversation: physical_row_removal", started_us);
        return Source.REMOVE;
    }

    private bool run_fallback_and_schedule_row_removal(Conversation conversation,
            ConversationSelectorRow conversation_row, bool was_selected,
            uint fallback_source_id, int64 scheduled_us) {
        if (disposed || !pending_removal_source_ids.has_key(conversation) ||
                pending_removal_source_ids[conversation] != fallback_source_id) {
            return Source.REMOVE;
        }
        pending_removal_source_ids.unset(conversation);

        ListBoxRow? current_selection = list_box.get_selected_row();
        bool needs_fallback = current_selection == conversation_row ||
            (was_selected && !is_active_conversation_row(current_selection));
        if (needs_fallback) {
            list_box.select_row(get_fallback_conversation_row(conversation_row));
        }
        if (!removing_conversations.contains(conversation)) {
            return Source.REMOVE;
        }
        conversation_row.set_selectable(false);
        UiTiming.log_ms("ConversationSelector.remove_conversation: fallback_idle", scheduled_us);

        schedule_physical_row_removal(conversation, conversation_row);
        return Source.REMOVE;
    }

    private void schedule_fallback_and_row_removal(Conversation conversation,
            ConversationSelectorRow conversation_row, bool was_selected) {
        int64 scheduled_us = UiTiming.now_us();
        uint fallback_source_id = 0;
        WeakRef selector_weak = WeakRef(this);
        // Leave the close/popover action stack before selecting. DEFAULT_IDLE
        // keeps the content switch behind GTK's higher-priority redraw work.
        fallback_source_id = Idle.add_full(GLib.Priority.DEFAULT_IDLE, () => {
            ConversationSelector? selector = (ConversationSelector?) selector_weak.get();
            if (selector == null) return Source.REMOVE;
            return ((!) selector).run_fallback_and_schedule_row_removal(conversation,
                conversation_row, was_selected, fallback_source_id, scheduled_us);
        });
        pending_removal_source_ids[conversation] = fallback_source_id;
    }

    public override void dispose() {
        if (!disposed) {
            disposed = true;
            if (row_update_source_id != 0) {
                Source.remove(row_update_source_id);
                row_update_source_id = 0;
            }
            if (invalidate_sort_source_id != 0) {
                Source.remove(invalidate_sort_source_id);
                invalidate_sort_source_id = 0;
            }
            if (startup_row_timing_flush_source_id != 0) {
                Source.remove(startup_row_timing_flush_source_id);
                startup_row_timing_flush_source_id = 0;
            }
            foreach (uint source_id in pending_removal_source_ids.values) {
                if (source_id != 0) Source.remove(source_id);
            }
            pending_removal_source_ids.clear();
            removing_conversations.clear();

            // A row's module signal closures can retain the row. Detach them
            // explicitly while disposing instead of relying on finalization.
            ArrayList<Conversation> conversations_to_detach =
                new ArrayList<Conversation>();
            foreach (Conversation conversation in rows.keys) {
                conversations_to_detach.add(conversation);
            }
            foreach (Conversation conversation in conversations_to_detach) {
                if (!rows.has_key(conversation)) continue;
                ConversationSelectorRow conversation_row = rows[conversation];
                detach_conversation_row(conversation, conversation_row);
            }
        }
        base.dispose();
    }

    private void remove_conversation(Conversation conversation) {
        // Guard: already being removed
        if (removing_conversations.contains(conversation)) return;
        removing_conversations.add(conversation);

        if (rows.has_key(conversation)) {
            ConversationSelectorRow conversation_row = rows[conversation];

            bool was_selected = list_box.get_selected_row() == conversation_row;
            conversation_row.set_sensitive(false);
            conversation_row.dismiss_popover();

            if (conversation_row.get_parent() == list_box) {
                schedule_fallback_and_row_removal(conversation, conversation_row, was_selected);
                return;
            }
            detach_conversation_row(conversation, conversation_row);
        }

        finish_removing_conversation(conversation);
    }

    public void loop_conversations(bool backwards) {
        ListBoxRow? selected = list_box.get_selected_row();
        if (selected == null) return;
        int index = selected.get_index();
        int direction = backwards ? -1 : 1;
        for (int offset = 1; offset <= rows.size; offset++) {
            int new_index = ((index + direction * offset) % rows.size +
                rows.size) % rows.size;
            ListBoxRow? next_select_row = list_box.get_row_at_index(new_index);
            if (is_active_conversation_row(next_select_row)) {
                list_box.select_row(next_select_row);
                return;
            }
        }
    }

    private int sort(ListBoxRow row1, ListBoxRow row2) {
        ConversationSelectorRow cr1 = row1 as ConversationSelectorRow;
        ConversationSelectorRow cr2 = row2 as ConversationSelectorRow;
        if (cr1 != null && cr2 != null) {
            Conversation c1 = cr1.conversation;
            Conversation c2 = cr2.conversation;

            int pin_comp = c2.pinned - c1.pinned;
            if (pin_comp != 0) return pin_comp;

            if (c1.last_active == null) return -1;
            if (c2.last_active == null) return 1;
            int comp = c2.last_active.compare(c1.last_active);
            if (comp == 0) {
                return Util.get_conversation_display_name(stream_interactor, c1)
                    .collate(Util.get_conversation_display_name(stream_interactor, c2));
            } else {
                return comp;
            }
        }
        return 0;
    }
}

}
