using Gee;
using Gdk;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

class OccupantsEntry : Plugins.ConversationTitlebarEntry, Object {
    public string id { get { return "occupants"; } }
    public double order { get { return 3; } }

    StreamInteractor stream_interactor;
    private Conversation? conversation;

    private MenuButton button = new MenuButton() { icon_name="system-users-symbolic", tooltip_text=Util.string_if_tooltips_active(_("Members")), visible=false };

    private OccupantMenu.View menu = null;
    private bool creating_menu = false;
    private ulong menu_closed_handler = 0;
    private ArrayList<OccupantMenu.View> deferred_menu_cleanups = new ArrayList<OccupantMenu.View>();
    private uint deferred_menu_cleanup_source = 0;
    private EventControllerLegacy? outside_click_controller = null;
    private ulong outside_click_window_active_handler = 0;
    private uint outside_popdown_source = 0;
    private uint window_inactive_watch_source = 0;
    private GestureClick? menu_click_guard = null;
    private bool member_button_pointer_sequence_active = false;
    private bool menu_pointer_sequence_active = false;
    private Conversation? pending_menu_open_conversation = null;
    private uint pending_menu_open_source = 0;
    private bool cleanup_pointer_activation_claimed = false;
    private ulong muc_joined_handler = 0;
    private ulong muc_left_handler = 0;
    private ulong muc_self_removed_handler = 0;
    private ulong connection_state_handler = 0;
    private ulong stream_resumed_handler = 0;
    private const uint DEFERRED_MENU_CLEANUP_DELAY_MS = 50;
    private const uint DEFERRED_MENU_CLEANUP_SLICE_DELAY_MS = 16;
    private const uint WINDOW_INACTIVE_WATCH_INTERVAL_MS = 50;
    private const int DEFERRED_MENU_CLEANUP_WORK_BUDGET_US = 4000;

    public OccupantsEntry(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        button.notify["active"].connect(() => {
            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message("UI-TIMING OccupantsEntry.button_active: active=%s sensitive=%s menu_exists=%s cleanup_queue=%d",
                    button.active.to_string(), button.sensitive.to_string(), (menu != null).to_string(),
                    deferred_menu_cleanups.size);
            }
        });

        GestureClick cleanup_click_gesture = new GestureClick() {
            button = Gdk.BUTTON_PRIMARY,
            propagation_phase = PropagationPhase.CAPTURE
        };
        cleanup_click_gesture.pressed.connect((n_press, x, y) => {
            member_button_pointer_sequence_active = true;
            cleanup_pointer_activation_claimed = false;
            if (menu != null || deferred_menu_cleanups.size == 0 || !is_groupchat_selected()) return;

            // Claim before GtkMenuButton's internal toggle gesture can reopen
            // the previous room's still-parented native popover.
            cleanup_pointer_activation_claimed = true;
            cleanup_click_gesture.set_state(EventSequenceState.CLAIMED);
            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message("UI-TIMING OccupantsEntry.member_button_press: claimed cleanup_queue=%d",
                    deferred_menu_cleanups.size);
            }
        });
        cleanup_click_gesture.released.connect((n_press, x, y) => {
            bool activation_claimed = cleanup_pointer_activation_claimed;
            member_button_pointer_sequence_active = false;
            if (!activation_claimed) return;

            cleanup_pointer_activation_claimed = false;
            cleanup_click_gesture.set_state(EventSequenceState.CLAIMED);
            if (x >= 0 && x <= button.get_width() && y >= 0 && y <= button.get_height()) {
                queue_pending_menu_open();
            }
        });
        cleanup_click_gesture.cancel.connect((sequence) => {
            member_button_pointer_sequence_active = false;
            cleanup_pointer_activation_claimed = false;
        });
        cleanup_click_gesture.unpaired_release.connect((x, y, released_button, sequence) => {
            member_button_pointer_sequence_active = false;
            cleanup_pointer_activation_claimed = false;
        });
        button.add_controller(cleanup_click_gesture);

        EventControllerKey cleanup_key_controller = new EventControllerKey() {
            propagation_phase = PropagationPhase.CAPTURE
        };
        cleanup_key_controller.key_pressed.connect((keyval, keycode, state) => {
            if (menu != null || deferred_menu_cleanups.size == 0 || !is_groupchat_selected()) return false;
            if (keyval != Gdk.Key.space && keyval != Gdk.Key.Return && keyval != Gdk.Key.KP_Enter) return false;

            queue_pending_menu_open();
            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message("UI-TIMING OccupantsEntry.member_button_key: queued keyval=%u", keyval);
            }
            return true;
        });
        button.add_controller(cleanup_key_controller);
        install_lazy_popup_func();

        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        muc_joined_handler = muc_manager.joined.connect(on_room_joined);
        muc_left_handler = muc_manager.left_signal.connect(on_room_left);
        muc_self_removed_handler = muc_manager.self_removed.connect(on_room_self_removed);
        connection_state_handler = stream_interactor.connection_manager
            .connection_state_changed.connect(on_connection_state_changed);
        stream_resumed_handler = stream_interactor.stream_resumed.connect(
            on_stream_resumed);
    }

    ~OccupantsEntry() {
        cancel_pending_menu_open();
        cancel_outside_popdown();
        cancel_window_inactive_watch();
        detach_menu_click_guard(menu);
        detach_outside_click_controller();
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (muc_joined_handler != 0 && SignalHandler.is_connected(muc_manager, muc_joined_handler)) {
            SignalHandler.disconnect(muc_manager, muc_joined_handler);
        }
        if (muc_left_handler != 0 && SignalHandler.is_connected(muc_manager, muc_left_handler)) {
            SignalHandler.disconnect(muc_manager, muc_left_handler);
        }
        if (muc_self_removed_handler != 0 && SignalHandler.is_connected(muc_manager, muc_self_removed_handler)) {
            SignalHandler.disconnect(muc_manager, muc_self_removed_handler);
        }
        if (connection_state_handler != 0 && SignalHandler.is_connected(
                stream_interactor.connection_manager,
                connection_state_handler)) {
            SignalHandler.disconnect(stream_interactor.connection_manager,
                connection_state_handler);
        }
        if (stream_resumed_handler != 0 && SignalHandler.is_connected(
                stream_interactor, stream_resumed_handler)) {
            SignalHandler.disconnect(stream_interactor,
                stream_resumed_handler);
        }
    }

    public new void set_conversation(Conversation conversation) {
        bool conversation_changed = this.conversation == null ||
            !((!) this.conversation).account.equals(conversation.account) ||
            !((!) this.conversation).counterpart.equals(conversation.counterpart) ||
            ((!) this.conversation).type_ != conversation.type_;
        if (conversation_changed) cancel_pending_menu_open();
        // A Popover is a native popup surface on Windows. Reusing the same
        // surface while its previous MUC list is being detached can make GTK
        // close the freshly reopened popup on the first click. Keep one View
        // bound to one conversation and clean the old one up independently.
        if (conversation_changed && menu != null) {
            clear_menu();
        } else if (conversation_changed && button.active) {
            button.active = false;
        }
        this.conversation = conversation;

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            button.visible = true;
            button.sensitive = is_groupchat_joined_selected();
        } else {
            if (button.active) button.active = false;
            if (menu != null) menu.popdown_for_lifecycle();
            button.visible = false;
        }
    }

    public new void unset_conversation() {
        cancel_pending_menu_open();
        clear_menu();
        conversation = null;
        button.visible = false;
    }

    private void clear_menu() {
        cancel_outside_popdown();
        cancel_window_inactive_watch();
        bool timing = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
        OccupantMenu.View? old_menu = menu;
        ulong old_menu_closed_handler = menu_closed_handler;
        detach_menu_click_guard(old_menu);
        menu = null;
        menu_closed_handler = 0;

        if (old_menu != null && old_menu_closed_handler != 0 &&
                SignalHandler.is_connected((!) old_menu, old_menu_closed_handler)) {
            SignalHandler.disconnect((!) old_menu, old_menu_closed_handler);
        }
        if (old_menu != null) {
            int64 t_deactivate_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
            old_menu.deactivate_for_deferred_cleanup();
            if (timing) {
                Dino.Ui.UiTiming.log_ms("OccupantsEntry.clear_menu: deactivate_for_deferred_cleanup", t_deactivate_us);
            }
        }
        if (old_menu != null) {
            int64 t_popdown_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
            old_menu.popdown_for_lifecycle();
            if (timing) {
                Dino.Ui.UiTiming.log_ms("OccupantsEntry.clear_menu: popdown", t_popdown_us);
            }
            defer_menu_cleanup(old_menu);
        }
        if (button.active) button.active = false;
        if (old_menu != null) {
            // Keep the hidden popover parented until its ListView has been
            // drained in bounded cleanup slices. Removing a populated native
            // popover here blocks the conversation selection synchronously.
            // The button itself stays interactive; an activation during this
            // window is queued for the newly selected room.
            button.sensitive = is_groupchat_joined_selected();
        } else if (deferred_menu_cleanups.size == 0) {
            Util.set_menu_button_popover(button, null);
            install_lazy_popup_func();
            button.sensitive = is_groupchat_joined_selected();
        }
        if (timing) {
            Dino.Ui.UiTiming.log_ms("OccupantsEntry.clear_menu: total queued=%d".printf(deferred_menu_cleanups.size), t_total_us);
        }
    }

    private bool is_groupchat_selected() {
        return conversation != null && ((!) conversation).type_ == Conversation.Type.GROUPCHAT;
    }

    private bool is_groupchat_joined_selected() {
        if (!is_groupchat_selected()) return false;
        Conversation selected = (!) conversation;
        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
            .is_joined(selected.counterpart, selected.account);
    }

    private bool matches_selected_room(Account account, Jid room_jid) {
        return conversation != null && ((!) conversation).type_ == Conversation.Type.GROUPCHAT &&
            ((!) conversation).account.equals(account) &&
            ((!) conversation).counterpart.bare_jid.equals(room_jid.bare_jid);
    }

    private void on_room_joined(Account account, Jid room_jid) {
        if (!matches_selected_room(account, room_jid)) return;
        // A rejoin starts a new occupant generation.  Never reuse a View that
        // may still own rows or callbacks from the previous visit.
        cancel_pending_menu_open();
        if (menu != null) clear_menu();
        button.sensitive = true;
    }

    private void on_room_left(Account account, Jid room_jid) {
        if (!matches_selected_room(account, room_jid)) return;
        cancel_pending_menu_open();
        if (menu != null) clear_menu();
        button.sensitive = false;
    }

    private void on_room_self_removed(Account account, Jid room_jid,
            Xmpp.Xep.Muc.StatusCode code, string? reason) {
        on_room_left(account, room_jid);
    }

    private bool matches_selected_account(Account account) {
        return conversation != null &&
            ((!) conversation).type_ == Conversation.Type.GROUPCHAT &&
            ((!) conversation).account.equals(account);
    }

    private void on_connection_state_changed(Account account,
            ConnectionManager.ConnectionState state) {
        if (!matches_selected_account(account)) return;

        if (state != ConnectionManager.ConnectionState.CONNECTED) {
            cancel_pending_menu_open();
            if (menu != null) {
                clear_menu();
            } else if (button.active) {
                button.active = false;
            }
            button.sensitive = false;
            return;
        }

        // A retained stream does not emit MucManager.joined again. Re-evaluate
        // the selected room as soon as that exact transport becomes sendable.
        if (menu == null && button.active) button.active = false;
        button.sensitive = is_groupchat_joined_selected();
    }

    private void on_stream_resumed(Account account, XmppStream stream) {
        if (!matches_selected_account(account) ||
                stream_interactor.get_stream(account) != stream) return;

        // XEP-0198 can restore the MUC flags only after CONNECTED was emitted.
        // Refresh once more after MucManager has replayed the resumed stream.
        if (menu == null && button.active) button.active = false;
        button.sensitive = is_groupchat_joined_selected();
    }

    private void defer_menu_cleanup(OccupantMenu.View old_menu) {
        deferred_menu_cleanups.add(old_menu);
        if (deferred_menu_cleanup_source == 0) {
            deferred_menu_cleanup_source = Timeout.add_full(Priority.DEFAULT, DEFERRED_MENU_CLEANUP_DELAY_MS, () => run_deferred_menu_cleanup());
        }
    }

    private void release_cleaned_menu(OccupantMenu.View old_menu) {
        if (button.get_popover() != old_menu) return;

        int64 started_us = Dino.Ui.UiTiming.enabled() ? Dino.Ui.UiTiming.now_us() : 0;
        Util.set_menu_button_popover(button, null);
        install_lazy_popup_func();
        button.sensitive = is_groupchat_joined_selected() && deferred_menu_cleanups.size == 0;
        schedule_pending_menu_open_if_ready();
        if (Dino.Ui.UiTiming.enabled()) {
            Dino.Ui.UiTiming.log_ms("OccupantsEntry.release_cleaned_menu: unset_popover", started_us);
        }
    }

    private bool run_deferred_menu_cleanup() {
        deferred_menu_cleanup_source = 0;
        if (deferred_menu_cleanups.size == 0) return false;

        int64 t_cleanup_us = Dino.Ui.UiTiming.now_us();
        int steps = 0;
        bool needs_more = false;
        while (deferred_menu_cleanups.size > 0) {
            OccupantMenu.View old_menu = deferred_menu_cleanups[0];
            needs_more = old_menu.cleanup_step();
            steps++;
            if (!needs_more) {
                uint safe_detach_delay_ms = old_menu.get_safe_detach_delay_ms();
                if (safe_detach_delay_ms > 0) {
                    deferred_menu_cleanup_source = Timeout.add_full(Priority.DEFAULT,
                        safe_detach_delay_ms, () => run_deferred_menu_cleanup());
                    return false;
                }
                deferred_menu_cleanups.remove_at(0);
                release_cleaned_menu(old_menu);
            }
            if (Dino.Ui.UiTiming.now_us() - t_cleanup_us >= DEFERRED_MENU_CLEANUP_WORK_BUDGET_US) break;
        }
        if (Dino.Ui.UiTiming.enabled()) {
            Dino.Ui.UiTiming.log_ms("OccupantsEntry.deferred_menu_cleanup: queue=%d steps=%d needs_more=%s".printf(deferred_menu_cleanups.size, steps, needs_more.to_string()), t_cleanup_us);
        }

        if (deferred_menu_cleanups.size > 0) {
            deferred_menu_cleanup_source = Timeout.add_full(Priority.DEFAULT, DEFERRED_MENU_CLEANUP_SLICE_DELAY_MS, () => run_deferred_menu_cleanup());
        }
        return false;
    }

    private void install_lazy_popup_func() {
        button.set_create_popup_func(() => {
            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message("UI-TIMING OccupantsEntry.create_popup: active=%s sensitive=%s menu_exists=%s",
                    button.active.to_string(), button.sensitive.to_string(), (menu != null).to_string());
            }
            ensure_menu();
        });
    }

    private void ensure_outside_click_controller() {
        Widget? current_root = button.get_root() as Widget;
        Widget? installed_root = outside_click_controller != null
            ? ((!) outside_click_controller).get_widget() : null;
        if (current_root == null || current_root == installed_root) return;

        detach_outside_click_controller();

        Widget root = (!) current_root;
        EventControllerLegacy controller = new EventControllerLegacy();
        controller.propagation_phase = PropagationPhase.CAPTURE;
        WeakRef entry_weak = WeakRef(this);
        controller.event.connect((event) => {
            OccupantsEntry? entry = (OccupantsEntry?) entry_weak.get();
            if (entry == null) return false;
            return ((!) entry).on_root_event(event);
        });
        root.add_controller(controller);
        outside_click_controller = controller;

        Gtk.Window? window = root as Gtk.Window;
        if (window != null) {
            WeakRef entry_weak_for_window = WeakRef(this);
            outside_click_window_active_handler = ((!) window).notify["is-active"].connect(() => {
                OccupantsEntry? entry = (OccupantsEntry?) entry_weak_for_window.get();
                if (entry == null) return;
                ((!) entry).on_window_active_changed();
            });
        }
    }

    private void detach_outside_click_controller() {
        cancel_window_inactive_watch();
        Gtk.Window? controller_window = outside_click_controller != null
            ? ((!) outside_click_controller).get_widget() as Gtk.Window : null;
        if (controller_window != null && outside_click_window_active_handler != 0 &&
                SignalHandler.is_connected((!) controller_window, outside_click_window_active_handler)) {
            SignalHandler.disconnect((!) controller_window, outside_click_window_active_handler);
        }
        outside_click_window_active_handler = 0;
        if (outside_click_controller != null) {
            Widget? controller_root = ((!) outside_click_controller).get_widget();
            if (controller_root != null) {
                ((!) controller_root).remove_controller((!) outside_click_controller);
            }
        }
        outside_click_controller = null;
    }

    private void on_window_active_changed() {
        Gtk.Window? window = outside_click_controller != null
            ? ((!) outside_click_controller).get_widget() as Gtk.Window : null;
        if (window == null) return;
        if (((!) window).is_active) {
            cancel_window_inactive_watch();
            return;
        }

        OccupantMenu.View? active_menu = menu;
        if (active_menu == null || !((!) active_menu).visible) return;

#if WINDOWS
        if (window_inactive_watch_source == 0) {
            window_inactive_watch_source = Timeout.add_full(Priority.DEFAULT,
                WINDOW_INACTIVE_WATCH_INTERVAL_MS, run_window_inactive_watch);
        }
#else
        close_menu_for_inactive_window((!) active_menu);
#endif
    }

#if WINDOWS
    private bool run_window_inactive_watch() {
        Gtk.Window? window = outside_click_controller != null
            ? ((!) outside_click_controller).get_widget() as Gtk.Window : null;
        OccupantMenu.View? active_menu = menu;
        if (window == null || ((!) window).is_active || active_menu == null ||
                !((!) active_menu).visible) {
            window_inactive_watch_source = 0;
            return Source.REMOVE;
        }

        if (!SystrayWin32.foreground_window_is_external()) {
            return Source.CONTINUE;
        }

        window_inactive_watch_source = 0;
        close_menu_for_inactive_window((!) active_menu);
        return Source.REMOVE;
    }
#endif

    private void close_menu_for_inactive_window(OccupantMenu.View active_menu) {
        cancel_pending_menu_open();
        cancel_outside_popdown();
        int64 started_us = Dino.Ui.UiTiming.enabled() ? Dino.Ui.UiTiming.now_us() : 0;
        active_menu.popdown_for_lifecycle();
        if (Dino.Ui.UiTiming.enabled()) {
            Dino.Ui.UiTiming.log_ms("OccupantsEntry.window_inactive: popdown", started_us);
        }
    }

    private void cancel_window_inactive_watch() {
        if (window_inactive_watch_source == 0) return;
        Source.remove(window_inactive_watch_source);
        window_inactive_watch_source = 0;
    }

    private bool same_conversation(Conversation? first, Conversation? second) {
        return first != null && second != null &&
            ((!) first).account.equals(((!) second).account) &&
            ((!) first).counterpart.equals(((!) second).counterpart) &&
            ((!) first).type_ == ((!) second).type_;
    }

    private void cancel_pending_menu_open() {
        member_button_pointer_sequence_active = false;
        cleanup_pointer_activation_claimed = false;
        if (pending_menu_open_source != 0) {
            Source.remove(pending_menu_open_source);
            pending_menu_open_source = 0;
        }
        pending_menu_open_conversation = null;
    }

    private void queue_pending_menu_open() {
        if (!is_groupchat_joined_selected()) return;
        pending_menu_open_conversation = conversation;
        if (Dino.Ui.UiTiming.enabled()) {
            GLib.message("UI-TIMING OccupantsEntry.member_button_release: queued cleanup_queue=%d",
                deferred_menu_cleanups.size);
        }
        schedule_pending_menu_open_if_ready();
    }

    private void schedule_pending_menu_open_if_ready() {
        if (pending_menu_open_conversation == null || pending_menu_open_source != 0 ||
                !button.sensitive || button.get_popover() != null ||
                deferred_menu_cleanups.size != 0) {
            return;
        }
        if (!same_conversation(pending_menu_open_conversation, conversation)) {
            cancel_pending_menu_open();
            return;
        }

        WeakRef entry_weak = WeakRef(this);
        pending_menu_open_source = Idle.add_full(Priority.DEFAULT_IDLE, () => {
            OccupantsEntry? entry = (OccupantsEntry?) entry_weak.get();
            if (entry == null) return false;

            ((!) entry).pending_menu_open_source = 0;
            if (!((!) entry).same_conversation(((!) entry).pending_menu_open_conversation,
                    ((!) entry).conversation) || !((!) entry).button.sensitive ||
                    ((!) entry).button.get_popover() != null ||
                    ((!) entry).deferred_menu_cleanups.size != 0) {
                ((!) entry).pending_menu_open_conversation = null;
                return false;
            }

            ((!) entry).pending_menu_open_conversation = null;
            int64 started_us = Dino.Ui.UiTiming.enabled() ? Dino.Ui.UiTiming.now_us() : 0;
            ((!) entry).button.popup();
            if (Dino.Ui.UiTiming.enabled()) {
                Dino.Ui.UiTiming.log_ms("OccupantsEntry.member_button_release: opened_queued", started_us);
            }
            return false;
        });
    }

    private void cancel_outside_popdown() {
        if (outside_popdown_source == 0) return;
        Source.remove(outside_popdown_source);
        outside_popdown_source = 0;
    }

    private void attach_menu_click_guard(OccupantMenu.View active_menu) {
        detach_menu_click_guard(menu);

        GestureClick guard = new GestureClick() {
            button = Gdk.BUTTON_PRIMARY,
            propagation_phase = PropagationPhase.CAPTURE
        };
        guard.pressed.connect((n_press, x, y) => {
            menu_pointer_sequence_active = true;
        });
        guard.released.connect((n_press, x, y) => {
            menu_pointer_sequence_active = false;
        });
        guard.cancel.connect((sequence) => {
            menu_pointer_sequence_active = false;
        });
        guard.unpaired_release.connect((x, y, released_button, sequence) => {
            menu_pointer_sequence_active = false;
        });
        ((Gtk.Widget) active_menu).add_controller(guard);
        menu_click_guard = guard;
    }

    private void detach_menu_click_guard(OccupantMenu.View? active_menu) {
        menu_pointer_sequence_active = false;
        if (active_menu != null && menu_click_guard != null) {
            ((Gtk.Widget) ((!) active_menu)).remove_controller((!) menu_click_guard);
        }
        menu_click_guard = null;
    }

    private void schedule_outside_popdown(OccupantMenu.View active_menu) {
        if (outside_popdown_source != 0) return;

        int64 scheduled_us = Dino.Ui.UiTiming.enabled() ? Dino.Ui.UiTiming.now_us() : 0;
        WeakRef entry_weak = WeakRef(this);
        WeakRef menu_weak = WeakRef(active_menu);
        outside_popdown_source = Idle.add_full(Priority.DEFAULT_IDLE, () => {
            OccupantsEntry? entry = (OccupantsEntry?) entry_weak.get();
            OccupantMenu.View? scheduled_menu = (OccupantMenu.View?) menu_weak.get();
            if (entry == null) return false;

            ((!) entry).outside_popdown_source = 0;
            if (scheduled_menu == null || ((!) entry).menu != scheduled_menu ||
                    !((!) scheduled_menu).visible) {
                return false;
            }

            int64 popdown_us = Dino.Ui.UiTiming.enabled() ? Dino.Ui.UiTiming.now_us() : 0;
            ((!) scheduled_menu).popdown_for_lifecycle();
            if (Dino.Ui.UiTiming.enabled()) {
                Dino.Ui.UiTiming.log_ms("OccupantsEntry.outside_release: dispatch_wait", scheduled_us);
                Dino.Ui.UiTiming.log_ms("OccupantsEntry.outside_release: deferred_popdown", popdown_us);
            }
            return false;
        });
        if (Dino.Ui.UiTiming.enabled()) {
            GLib.message("UI-TIMING OccupantsEntry.outside_release: scheduled_after_dispatch");
        }
    }

    private bool on_root_event(Gdk.Event event) {
        Gdk.EventType event_type = event.get_event_type();
        if (event_type != Gdk.EventType.BUTTON_RELEASE && event_type != Gdk.EventType.TOUCH_END) {
            return false;
        }

        if (member_button_pointer_sequence_active || menu_pointer_sequence_active) {
            bool from_member_button = member_button_pointer_sequence_active;
            member_button_pointer_sequence_active = false;
            menu_pointer_sequence_active = false;
            cancel_outside_popdown();
            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message("UI-TIMING OccupantsEntry.owned_release: source=%s",
                    from_member_button ? "member-button" : "member-popover");
            }
            return false;
        }

        bool targets_member_button = false;
        bool has_event_position = false;
        bool has_button_bounds = false;
        double event_x = 0;
        double event_y = 0;
        Graphene.Rect button_bounds;
        Widget? current_root = button.get_root() as Widget;
        if (current_root != null) {
            has_event_position = event.get_position(out event_x, out event_y);
            has_button_bounds = button.compute_bounds((!) current_root, out button_bounds);
            if (has_event_position && has_button_bounds) {
                targets_member_button = event_x >= button_bounds.origin.x &&
                    event_x <= button_bounds.origin.x + button_bounds.size.width &&
                    event_y >= button_bounds.origin.y &&
                    event_y <= button_bounds.origin.y + button_bounds.size.height;
            }
        }
        if (Dino.Ui.UiTiming.enabled() && deferred_menu_cleanups.size > 0) {
            GLib.message("UI-TIMING OccupantsEntry.root_release: position=%s bounds=%s member_button=%s sensitive=%s cleanup_queue=%d",
                has_event_position.to_string(), has_button_bounds.to_string(),
                targets_member_button.to_string(), button.sensitive.to_string(),
                deferred_menu_cleanups.size);
        }
        if (targets_member_button) {
            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message("UI-TIMING OccupantsEntry.member_button_release: sensitive=%s menu_exists=%s cleanup_queue=%d",
                    button.sensitive.to_string(), (menu != null).to_string(), deferred_menu_cleanups.size);
            }
            // The button-local capture gesture owns queued activation. Keep
            // this root-level branch diagnostic only so a release without a
            // matching press cannot synthesize a click.
            return false;
        }

        OccupantMenu.View? active_menu = menu;
        if (active_menu == null || !((!) active_menu).visible) return false;

        Gtk.Native? menu_native = ((!) active_menu).get_native();
        if (menu_native != null && event.get_surface() == ((!) menu_native).get_surface()) {
            return false;
        }

        // Do not destroy the popup surface from the capture phase of the same
        // pointer release that should select a conversation underneath it.
        // Waiting only until idle after BUTTON_PRESS is still too early: GTK's
        // ListBox selection gesture completes on release and can be cancelled
        // when the native popup disappears between press and release.
        schedule_outside_popdown((!) active_menu);
        return false;
    }

    private void ensure_menu() {
        bool timing = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
        ensure_outside_click_controller();
        if (creating_menu) {
            if (timing) Dino.Ui.UiTiming.log_ms("OccupantsEntry.ensure_menu: skipped_creating", t_total_us);
            return;
        }
        if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT ||
                !is_groupchat_joined_selected()) {
            // GtkMenuButton leaves itself active when a lazy create-popup
            // callback returns without assigning a popover. The room may have
            // gone offline between the press and this callback.
            if (button.active) button.active = false;
            button.sensitive = is_groupchat_joined_selected();
            if (timing) Dino.Ui.UiTiming.log_ms("OccupantsEntry.ensure_menu: skipped_no_groupchat", t_total_us);
            return;
        }
        if (menu != null) {
            if (timing) Dino.Ui.UiTiming.log_ms("OccupantsEntry.ensure_menu: reused", t_total_us);
            return;
        }

        creating_menu = true;
        OccupantMenu.View new_menu = new OccupantMenu.View(stream_interactor, conversation);
        attach_menu_click_guard(new_menu);
        menu = new_menu;
        menu_closed_handler = new_menu.closed.connect(on_menu_closed);
        Util.set_menu_button_popover(button, new_menu);
        creating_menu = false;
        if (timing) Dino.Ui.UiTiming.log_ms("OccupantsEntry.ensure_menu: created", t_total_us);
    }

    private void on_menu_closed() {
        cancel_window_inactive_watch();
        menu_pointer_sequence_active = false;
        // A close requested by the previous MUC may arrive after the same
        // popover has already been reopened for the newly selected room.
        if (button.active && (menu == null || !((!) menu).visible)) button.active = false;
    }

    public Object? get_widget(Plugins.WidgetType type) {
        if (type != Plugins.WidgetType.GTK4) return null;
        return button;
    }
}

}
