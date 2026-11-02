using Gee;
using Gdk;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui.OccupantMenu {
public class View : Popover {

    private const int DEFERRED_LIST_CLEANUP_DELAY_MS = 1500;
    private const int DEFERRED_LIST_CLEANUP_RETRY_MS = 50;
    // GTK before 4.18.5 leaves a pending tooltip query bound to a popover
    // surface after popdown. Keep the hidden native alive until GTK's longest
    // tooltip delay (500 ms) has expired; GTK upstream issue #5844 fixed this
    // in gtk_popover_unmap() for newer runtimes.
    private const uint GTK_TOOLTIP_SAFE_DETACH_DELAY_MS = 550;
    // Keep the fixed footer aligned with the visible list content rather than
    // the wider Windows scroller allocation that also includes its scrollbar.
    private const int LIST_CONTENT_WIDTH = 316;

    private StreamInteractor stream_interactor;
    private Conversation conversation;
    private MucManager muc_manager;

    private Stack stack = new Stack() { vhomogeneous=false };
    private Box list_box = new Box(Orientation.VERTICAL, 1);
    private List? list = null;
    private ArrayList<List> deferred_list_cleanups = new ArrayList<List>();
    private uint deferred_list_cleanup_source = 0;
    private ListBox invite_list = new ListBox() {
        activate_on_single_click = true,
        selection_mode = SelectionMode.NONE,
        width_request = LIST_CONTENT_WIDTH,
        halign = Align.START,
        margin_top = 4,
        margin_bottom = 8
    };
    private Box? jid_menu = null;

    private Jid? selected_jid;
    // Bind actions to the identity which owned a room/nick when the menu was
    // opened. A room nickname is not an identity and may be reused after a
    // leave; the transient MUC peer identity changes at that boundary.
    private string? selected_peer_identity;
    private Jid? selected_affiliation_target;
    private Jid? selected_block_target;
    private MucManager.MucOwnerMutationContext? selected_room_context;
    private bool cleaned_up = false;
    private bool deferred_cleanup_pending = false;
    private bool cleanup_started = false;
    private DeferredPopoverAction? pending_popdown_action = null;
    private ulong pending_popdown_closed_handler_id = 0;
    private bool detach_after_popdown = false;
    private int64 safe_detach_after_us = 0;
    private uint safe_detach_source = 0;
    private ulong real_jid_visibility_revoked_handler_id = 0;
    private ulong room_info_updated_handler_id = 0;
    private ulong occupant_affiliation_updated_handler_id = 0;
    private WeakRef avatar_anchor = WeakRef(null);
    private WeakRef avatar_root = WeakRef(null);
    private WeakRef avatar_surface = WeakRef(null);
    private bool avatar_context_menu = false;
    private ulong avatar_anchor_unmap_handler_id = 0;
    private ulong avatar_root_unmap_handler_id = 0;
    private ulong avatar_window_active_handler_id = 0;
    private ulong avatar_surface_state_handler_id = 0;
    private uint avatar_window_inactive_source = 0;
#if !WINDOWS
    private bool avatar_surface_was_focused = false;
#endif

    private class DeferredPopoverAction : Object {
        private SourceFunc? callback;

        public DeferredPopoverAction(owned SourceFunc callback) {
            this.callback = (owned) callback;
        }

        public bool run() {
            SourceFunc? callback = (owned) this.callback;
            if (callback == null) return false;
            return ((!) callback)();
        }
    }

    public View(StreamInteractor stream_interactor, Conversation conversation) {
        this.stream_interactor = stream_interactor;
        this.conversation = conversation;
        this.muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        real_jid_visibility_revoked_handler_id =
            muc_manager.room_real_jid_visibility_revoked.connect(
                on_room_real_jid_visibility_revoked);
        room_info_updated_handler_id =
            muc_manager.room_info_updated.connect(
                on_invite_permission_state_changed);
        occupant_affiliation_updated_handler_id =
            muc_manager.occupant_affiliation_updated.connect((account, room,
                    occupant, affiliation) => {
                on_invite_permission_state_changed(account, room);
            });
        // A modal popover consumes the first click outside of it. In
        // particular, clicking another conversation only closed the member
        // list and required a second click to select that conversation. The
        // titlebar owner closes this view explicitly, so keep the member list
        // non-modal and let the original click reach its target. Standalone
        // avatar menus use for_avatar() and native modal dismissal instead.
        this.autohide = false;
        this.focusable = true;

        EventControllerKey key_events = new EventControllerKey();
        key_events.key_pressed.connect((keyval, keycode, state) => {
            if (keyval != Gdk.Key.Escape) return false;
            popdown_for_lifecycle();
            return true;
        });
        ((Gtk.Widget) this).add_controller(key_events);

        this.show.connect(initialize_list);
        this.closed.connect(on_closed);
        this.notify["visible"].connect(() => {
            if (cleaned_up || deferred_cleanup_pending || cleanup_started || !this.visible) return;

            if (list != null) list.resume_auto_loading_if_needed();

            Idle.add(() => {
                if (!cleaned_up && this.visible) this.child_focus(Gtk.DirectionType.TAB_FORWARD);
                return false;
            });
        });

        invite_list.append(new ListRow.label("+", _("Invite")).get_widget());
        invite_list.add_css_class("boxed-list");
        invite_list.can_focus = false;
        list_box.append(invite_list);
        invite_list.row_activated.connect(on_invite_clicked);
        update_invite_visibility();

        stack.add_named(list_box, "list");
        set_child(stack);
        stack.visible_child_name = "list";

    }

    public View.for_avatar(StreamInteractor stream_interactor,
            Conversation conversation, Gtk.Widget anchor) {
        this(stream_interactor, conversation);
        // Unlike the titlebar member list, this single-use context menu has
        // no outside-click controller. Let GTK dismiss it on outside clicks,
        // and Escape on both Linux and Windows.
        avatar_context_menu = true;
        this.autohide = true;
        avatar_anchor.set(anchor);
        Gtk.Widget? root = anchor.get_root() as Gtk.Widget;
        avatar_root.set(root);
        avatar_anchor_unmap_handler_id = anchor.unmap.connect(close_avatar_context);
        if (root != null && root != anchor) {
            avatar_root_unmap_handler_id = ((!) root).unmap.connect(close_avatar_context);
        }
        Gtk.Window? window = root as Gtk.Window;
        if (window != null) {
#if WINDOWS
            avatar_window_active_handler_id = ((!) window).notify["is-active"].connect(
                on_avatar_window_active_changed);
#endif
            Gdk.Surface? surface = ((!) window).get_surface();
            if (surface is Gdk.Toplevel) {
                avatar_surface.set(surface);
#if !WINDOWS
                avatar_surface_was_focused =
                    (((Gdk.Toplevel) surface).get_state() & Gdk.ToplevelState.FOCUSED) != 0;
#endif
                avatar_surface_state_handler_id = ((!) surface).notify["state"].connect(
                    on_avatar_surface_state_changed);
            }
        }
    }

    private void disconnect_avatar_lifecycle() {
        Gtk.Widget? anchor = (Gtk.Widget?) avatar_anchor.get();
        Gtk.Widget? root = (Gtk.Widget?) avatar_root.get();
        Gdk.Surface? surface = (Gdk.Surface?) avatar_surface.get();
        ulong anchor_handler = avatar_anchor_unmap_handler_id;
        ulong root_handler = avatar_root_unmap_handler_id;
        ulong active_handler = avatar_window_active_handler_id;
        ulong state_handler = avatar_surface_state_handler_id;
        avatar_anchor_unmap_handler_id = 0;
        avatar_root_unmap_handler_id = 0;
        avatar_window_active_handler_id = 0;
        avatar_surface_state_handler_id = 0;
        avatar_anchor.set(null);
        avatar_root.set(null);
        avatar_surface.set(null);
        cancel_avatar_inactive_watch();
        if (anchor != null && anchor_handler != 0 &&
                SignalHandler.is_connected((!) anchor, anchor_handler)) {
            SignalHandler.disconnect((!) anchor, anchor_handler);
        }
        if (root != null && root_handler != 0 &&
                SignalHandler.is_connected((!) root, root_handler)) {
            SignalHandler.disconnect((!) root, root_handler);
        }
        if (root != null && active_handler != 0 &&
                SignalHandler.is_connected((!) root, active_handler)) {
            SignalHandler.disconnect((!) root, active_handler);
        }
        if (surface != null && state_handler != 0 &&
                SignalHandler.is_connected((!) surface, state_handler)) {
            SignalHandler.disconnect((!) surface, state_handler);
        }
    }

    private void close_avatar_context() {
        // Disconnect first: popdown emits closed synchronously and may start
        // detaching the popup while the anchor/window is being unmapped.
        disconnect_avatar_lifecycle();
        if (!cleaned_up && this.get_parent() != null && this.visible) {
            popdown_for_lifecycle();
        }
    }

    private void on_avatar_surface_state_changed() {
        Gdk.Toplevel? toplevel = avatar_surface.get() as Gdk.Toplevel;
        if (toplevel == null) return;
        Gdk.ToplevelState state = ((!) toplevel).get_state();
        // Minimizing a native window does not necessarily unmap its GTK
        // widget. In particular its popup can retain native focus.
        if ((state & Gdk.ToplevelState.MINIMIZED) != 0) {
            close_avatar_context();
            return;
        }
#if !WINDOWS
        // Gtk.Window.is_active changes transiently while GTK grabs the modal
        // popup, and can remain true after another application is activated.
        // Follow the compositor/window-manager state of the owning surface.
        bool focused = (state & Gdk.ToplevelState.FOCUSED) != 0;
        bool lost_focus = avatar_surface_was_focused && !focused;
        avatar_surface_was_focused = focused;
        if (lost_focus) close_avatar_context();
#endif
    }

#if WINDOWS
    private void on_avatar_window_active_changed() {
        Gtk.Window? window = avatar_root.get() as Gtk.Window;
        if (window == null || ((!) window).is_active) {
            cancel_avatar_inactive_watch();
            return;
        }
        if (!this.visible || cleaned_up) return;
        // A Win32 popup can deactivate its own main window. Match the member
        // list policy: close only after focus moves outside this process.
        if (avatar_window_inactive_source == 0) {
            avatar_window_inactive_source = Timeout.add_full(Priority.DEFAULT,
                50, run_avatar_inactive_watch);
        }
    }

    private bool run_avatar_inactive_watch() {
        Gtk.Window? window = avatar_root.get() as Gtk.Window;
        if (window == null || ((!) window).is_active || !this.visible || cleaned_up) {
            avatar_window_inactive_source = 0;
            return Source.REMOVE;
        }
        if (!SystrayWin32.foreground_window_is_external()) return Source.CONTINUE;
        avatar_window_inactive_source = 0;
        close_avatar_context();
        return Source.REMOVE;
    }
#endif

    private void cancel_avatar_inactive_watch() {
        if (avatar_window_inactive_source == 0) return;
        Source.remove(avatar_window_inactive_source);
        avatar_window_inactive_source = 0;
    }

    public void set_conversation(Conversation conversation) {
        if (cleaned_up) return;
        if (this.conversation.account.equals(conversation.account) &&
                this.conversation.counterpart.equals(conversation.counterpart) &&
                this.conversation.type_ == conversation.type_) {
            return;
        }

        if (this.visible && this.get_parent() != null && this.get_native() != null) {
            popdown_for_lifecycle();
        }

        stack.transition_type = StackTransitionType.NONE;
        stack.visible_child_name = "list";
        invite_list.unselect_all();
        clear_selected_target_binding();

        if (list != null) {
            List old_list = (!) list;
            old_list.deactivate_for_deferred_cleanup();
            old_list.visible = false;
            old_list.sensitive = false;
            list = null;
            defer_list_cleanup(old_list);
        }

        this.conversation = conversation;
        update_invite_visibility();
    }

    public override void dispose() {
        if (safe_detach_source != 0) {
            Source.remove(safe_detach_source);
            safe_detach_source = 0;
        }
        cleanup();
        base.dispose();
    }

    public void cleanup() {
        while (cleanup_step()) {}
    }

    public bool cleanup_step() {
        if (cleaned_up) return false;
        disconnect_avatar_lifecycle();
        if (real_jid_visibility_revoked_handler_id != 0) {
            SignalHandler.disconnect(muc_manager,
                real_jid_visibility_revoked_handler_id);
            real_jid_visibility_revoked_handler_id = 0;
        }
        if (room_info_updated_handler_id != 0) {
            SignalHandler.disconnect(muc_manager,
                room_info_updated_handler_id);
            room_info_updated_handler_id = 0;
        }
        if (occupant_affiliation_updated_handler_id != 0) {
            SignalHandler.disconnect(muc_manager,
                occupant_affiliation_updated_handler_id);
            occupant_affiliation_updated_handler_id = 0;
        }
        cancel_pending_popdown_action();
        bool timing = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
        if (deferred_list_cleanup_source != 0) {
            Source.remove(deferred_list_cleanup_source);
            deferred_list_cleanup_source = 0;
        }
        if (deferred_list_cleanups.size > 0) {
            List old_list = deferred_list_cleanups[0];
            if (old_list.cleanup_step()) return true;
            if (old_list.get_parent() == list_box) {
                list_box.remove(old_list);
            }
            deferred_list_cleanups.remove_at(0);
            return true;
        }
        if (!cleanup_started) {
            cleanup_started = true;
            if (this.get_parent() != null && this.get_native() != null) {
                popdown_for_lifecycle();
            }
        }
        if (list != null) {
            int64 t_list_cleanup_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
            if (list.cleanup_step()) return true;
            if (timing) {
                Dino.Ui.UiTiming.log_ms("OccupantMenu.View.cleanup_step: list_cleanup_complete", t_list_cleanup_us);
            }
            list = null;
        }
        // Menu-button closures retain their action receiver. Terminal cleanup
        // must release those children as well as the room/list observers.
        if (jid_menu != null) {
            stack.remove((!) jid_menu);
            jid_menu = null;
        }
        cleaned_up = true;
        if (timing) {
            Dino.Ui.UiTiming.log_ms("OccupantMenu.View.cleanup_step: total cleaned_up=%s".printf(cleaned_up.to_string()), t_total_us);
        }
        return false;
    }

    private void defer_list_cleanup(List old_list) {
        deferred_list_cleanups.add(old_list);
        if (deferred_list_cleanup_source == 0) {
            deferred_list_cleanup_source = Timeout.add_full(deferred_cleanup_priority(), DEFERRED_LIST_CLEANUP_DELAY_MS, () => run_deferred_list_cleanup());
        }
    }

    private int deferred_cleanup_priority() {
#if WINDOWS
        // Each cleanup step is time-budgeted. Do not let the initial MUC
        // presence burst retain several complete hidden lists on Windows.
        return Priority.DEFAULT;
#else
        return Priority.LOW;
#endif
    }

    private bool run_deferred_list_cleanup() {
        deferred_list_cleanup_source = 0;
        if (deferred_list_cleanups.size == 0) return false;

        bool timing = Dino.Ui.UiTiming.enabled();
        int64 t_cleanup_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
        List old_list = deferred_list_cleanups[0];
        bool needs_more = old_list.cleanup_step();
        if (!needs_more) {
            if (old_list.get_parent() == list_box) {
                list_box.remove(old_list);
            }
            deferred_list_cleanups.remove_at(0);
        }
        if (timing) {
            Dino.Ui.UiTiming.log_ms("OccupantMenu.View.deferred_list_cleanup: queue=%d needs_more=%s".printf(deferred_list_cleanups.size, needs_more.to_string()), t_cleanup_us);
        }

        if (deferred_list_cleanups.size > 0) {
            deferred_list_cleanup_source = Timeout.add_full(deferred_cleanup_priority(), DEFERRED_LIST_CLEANUP_RETRY_MS, () => run_deferred_list_cleanup());
        }
        return false;
    }

    public void deactivate_for_deferred_cleanup() {
        if (cleaned_up || deferred_cleanup_pending) return;
        bool timing = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
        release_focus_to_parent();
        deferred_cleanup_pending = true;
        if (list != null) {
            int64 t_list_deactivate_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
            list.deactivate_for_deferred_cleanup();
            if (timing) {
                Dino.Ui.UiTiming.log_ms("OccupantMenu.View.deactivate_for_deferred_cleanup: list", t_list_deactivate_us);
            }
        }
        if (timing) {
            Dino.Ui.UiTiming.log_ms("OccupantMenu.View.deactivate_for_deferred_cleanup: total", t_total_us);
        }
    }

    public void reset() {
        if (cleaned_up || deferred_cleanup_pending || cleanup_started) return;
        bool timing = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
        release_focus_to_parent();
        stack.transition_type = StackTransitionType.NONE;
        stack.visible_child_name = "list";
        if (list != null) {
            int64 t_suspend_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
            list.suspend_for_popover_close();
            if (timing) {
                Dino.Ui.UiTiming.log_ms("OccupantMenu.View.reset: suspend_for_popover_close", t_suspend_us);
            }
            list.clear_selection();
        }
        invite_list.unselect_all();
        clear_selected_target_binding();
        if (timing) {
            Dino.Ui.UiTiming.log_ms("OccupantMenu.View.reset: total", t_total_us);
        }
    }

    // Defer popdown() so button gesture controllers finish cleanly
    // (avoids GTK 'Broken accounting of active state' warning)
    private void hide_deferred() {
        GLib.Idle.add(() => {
            if (cleaned_up || deferred_cleanup_pending) return false;
            // Only pop down if the popover is still parented and has a valid surface.
            // set_visible(false) can leave the native popup surface around without
            // correctly releasing the popover/menu-button grab on GTK4.
            if (this.get_parent() != null && this.get_native() != null) {
                popdown_for_lifecycle();
            }
            return false;
        });
    }

    private static bool needs_popover_tooltip_detach_workaround() {
        uint major = Gtk.get_major_version();
        uint minor = Gtk.get_minor_version();
        uint micro = Gtk.get_micro_version();
        return major == 4 && (minor < 18 || (minor == 18 && micro < 5));
    }

    private void mark_safe_detach_deadline() {
        if (!needs_popover_tooltip_detach_workaround() ||
                this.get_parent() == null) return;

        safe_detach_after_us = int64.max(safe_detach_after_us,
            GLib.get_monotonic_time() +
                (int64) GTK_TOOLTIP_SAFE_DETACH_DELAY_MS * 1000);
    }

    private void on_closed() {
        disconnect_avatar_lifecycle();
        // GtkMenuButton can close its popover internally without going through
        // popdown_for_lifecycle(). Mark the transition here as well so a fast
        // room switch cannot detach the old native while GTK still has a
        // tooltip query pending for its surface.
        mark_safe_detach_deadline();
        reset();
    }

    private void release_focus_to_parent() {
        Gtk.Root? root = this.get_root();
        if (root == null) return;

        Widget? cursor = ((!) root).get_focus();
        while (cursor != null) {
            Widget current = (!) cursor;
            if (current == this) {
                Widget? parent = this.get_parent();
                if (parent != null && ((!) parent).grab_focus()) return;
                ((!) root).set_focus(null);
                return;
            }
            cursor = current.get_parent();
        }
    }

    public void popdown_for_lifecycle() {
        if (needs_popover_tooltip_detach_workaround() && this.get_realized() &&
                this.visible) {
            mark_safe_detach_deadline();
        }
        popdown();
    }

    public uint get_safe_detach_delay_ms() {
        int64 remaining_us = safe_detach_after_us - GLib.get_monotonic_time();
        if (remaining_us <= 0) return 0;
        return (uint) ((remaining_us + 999) / 1000);
    }

    private void schedule_safe_detach() {
        if ((!avatar_context_menu && this.get_parent() == null) ||
                safe_detach_source != 0) return;

        uint delay_ms = get_safe_detach_delay_ms();
        WeakRef view_weak = WeakRef(this);
        if (delay_ms > 0) {
            safe_detach_source = Timeout.add_full(GLib.Priority.LOW, delay_ms, () => {
                View? view = (View?) view_weak.get();
                return view != null ? ((!) view).run_safe_detach() : Source.REMOVE;
            });
        } else {
            safe_detach_source = Idle.add_full(GLib.Priority.LOW, () => {
                View? view = (View?) view_weak.get();
                return view != null ? ((!) view).run_safe_detach() : Source.REMOVE;
            });
        }
    }

    private bool run_safe_detach() {
        safe_detach_source = 0;
        if (get_safe_detach_delay_ms() > 0) {
            schedule_safe_detach();
            return Source.REMOVE;
        }
        if (this.visible) return Source.REMOVE;
        if (avatar_context_menu && cleanup_step()) {
            // Retire a large room's hidden list in bounded steps, retaining
            // the stable parent until its callbacks have been released.
            schedule_safe_detach();
            return Source.REMOVE;
        }
        if (this.get_parent() != null) {
            this.unparent();
        }
        return Source.REMOVE;
    }

    private void disconnect_pending_popdown_handler() {
        if (pending_popdown_closed_handler_id == 0) return;
        ulong handler_id = pending_popdown_closed_handler_id;
        pending_popdown_closed_handler_id = 0;
        if (SignalHandler.is_connected(this, handler_id)) {
            SignalHandler.disconnect(this, handler_id);
        }
    }

    private void cancel_pending_popdown_action() {
        disconnect_pending_popdown_handler();
        pending_popdown_action = null;
        detach_after_popdown = false;
    }

    private void finish_pending_popdown(bool run_action) {
        disconnect_pending_popdown_handler();

        DeferredPopoverAction? action = pending_popdown_action;
        pending_popdown_action = null;
        bool should_detach = detach_after_popdown;
        detach_after_popdown = false;

        if (run_action && action != null) {
            DeferredPopoverAction action_to_run = (!) action;
            Idle.add_full(GLib.Priority.LOW, action_to_run.run);
        }
        if (should_detach) {
            schedule_safe_detach();
        }
    }

    private void register_popdown_closed_handler(bool run_action) {
        WeakRef view_weak = WeakRef(this);
        pending_popdown_closed_handler_id = this.closed.connect(() => {
            View? view = (View) view_weak.get();
            if (view == null) return;
            view.finish_pending_popdown(run_action);
        });
    }

    private void run_after_popdown(owned SourceFunc callback) {
        if (cleaned_up || deferred_cleanup_pending) return;
        if (pending_popdown_action != null || pending_popdown_closed_handler_id != 0) return;

        var action = new DeferredPopoverAction((owned) callback);
        if (this.get_parent() == null || this.get_native() == null || !this.visible) {
            Idle.add_full(GLib.Priority.LOW, action.run);
            return;
        }

        pending_popdown_action = action;
        detach_after_popdown = false;
        register_popdown_closed_handler(true);
        hide_deferred();
    }

    public void detach_safely_after_close() {
        // The caller is already in the closed signal. Do not cancel a
        // run_after_popdown() action which still has to run later in this
        // signal emission.
        schedule_safe_detach();
    }

    public void close_and_detach() {
        cancel_pending_popdown_action();

        if (this.get_parent() == null) return;
        if (this.get_native() == null || !this.visible) {
            schedule_safe_detach();
            return;
        }

        detach_after_popdown = true;
        register_popdown_closed_handler(false);
        popdown_for_lifecycle();
    }

    private void initialize_list() {
        if (cleaned_up || deferred_cleanup_pending || cleanup_started) return;
        update_invite_visibility();
        bool timing = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing ? Dino.Ui.UiTiming.now_us() : 0;
        if (list == null) {
            list = new List(stream_interactor, conversation);
            list_box.prepend(list);

            list.occupant_activated.connect((jid, display_name) => {
                show_menu(jid, display_name);
            });
        } else {
            list.resume_auto_loading_if_needed();
        }
        if (timing) {
            Dino.Ui.UiTiming.log_ms("OccupantMenu.View.initialize_list: total list_exists=%s".printf((list != null).to_string()), t_total_us);
        }
    }

    private void show_list() {
        if (cleaned_up) return;
        if (list != null) list.clear_selection();
        clear_selected_target_binding();
        stack.transition_type = StackTransitionType.SLIDE_RIGHT;
        stack.visible_child_name = "list";
    }

    private void on_room_real_jid_visibility_revoked(Account account,
            Jid room_jid) {
        if (cleaned_up || deferred_cleanup_pending || cleanup_started ||
                !conversation.account.equals(account) ||
                !conversation.counterpart.equals_bare(room_jid)) return;

        // MucManager has already scrubbed the sensitive identity state before
        // this signal. Close the detail surface synchronously as well: its
        // header and action closures otherwise retain the previously
        // disclosed bare JID until the popover is reopened.
        cancel_pending_popdown_action();
        if (list != null) list.clear_selection();
        clear_selected_target_binding();
        stack.transition_type = StackTransitionType.NONE;
        stack.visible_child_name = "list";
        if (jid_menu != null) {
            stack.remove((!) jid_menu);
            jid_menu = null;
        }
    }

    private void clear_selected_target_binding() {
        selected_jid = null;
        selected_peer_identity = null;
        selected_affiliation_target = null;
        selected_block_target = null;
        selected_room_context = null;
    }

    public void show_menu(Jid jid, string name_) {
        if (cleaned_up) return;
        if (Dino.Ui.UiTiming.enabled()) {
            GLib.message("UI-TIMING OccupantMenu.View.show_menu: jid=%s", jid.to_string());
        }
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        bool target_is_live = muc_manager.is_current_occupant(
            conversation.account, conversation.counterpart, jid);
        Jid? affiliation_target = muc_manager.get_affiliation_target(
            conversation.account, conversation.counterpart, jid);

        selected_jid = jid;
        selected_peer_identity = target_is_live
            ? muc_manager.get_private_message_peer_identity(conversation.account, jid)
            : null;
        selected_affiliation_target = affiliation_target != null
            ? ((!) affiliation_target).bare_jid : null;
        selected_block_target = affiliation_target != null &&
                !((!) affiliation_target).equals_bare(conversation.counterpart)
            ? ((!) affiliation_target).bare_jid : null;
        selected_room_context = muc_manager.capture_current_muc_context(
            conversation.account, conversation.counterpart);
        stack.transition_type = StackTransitionType.SLIDE_LEFT;

        string name = Markup.escape_text(name_);
        Jid? real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(jid, conversation.account);
        if (real_jid != null) name += "\n<span font=\'8\'>%s</span>".printf(Markup.escape_text(real_jid.bare_jid.to_string()));

        Box header_box = new Box(Orientation.HORIZONTAL, 5);
        // Only show back button if we have a list to go back to
        if (list != null) {
            header_box.append(new Image.from_icon_name("pan-start-symbolic"));
        }
        header_box.append(new Label(name) {
            xalign = 0, use_markup = true, hexpand = true,
            ellipsize = Pango.EllipsizeMode.END, max_width_chars = 28,
            tooltip_text = real_jid == null ? name_ : "%s\n%s".printf(name_, real_jid.bare_jid.to_string())
        });
        Button header_button = new Button() { has_frame=false };
        header_button.child = header_box;

        Box outer_box = new Box(Orientation.VERTICAL, 0); // Reduced spacing to 0
        outer_box.append(header_button);
        if (list != null) {
            header_button.clicked.connect(show_list);
        } else {
            header_button.clicked.connect(() => {
                if (selected_jid == null) return;
                // Capture and validate state before popover destruction. A
                // reused room nickname must never open details for its new
                // occupant through an old menu.
                Jid selected = selected_jid;
                string? bound_identity = selected_peer_identity;
                Jid? bound_affiliation_target = selected_affiliation_target;
                MucManager.MucOwnerMutationContext? bound_room_context =
                    selected_room_context;
                Account account = conversation.account;
                Jid room = conversation.counterpart;
                StreamInteractor si = stream_interactor;
                if (!selected_target_binding_is_current(muc_manager, account,
                        room, selected, bound_identity,
                        bound_affiliation_target, bound_room_context, false)) {
                    hide_deferred();
                    show_muc_action_error(_("The selected user is no longer in the room."));
                    return;
                }
                run_after_popdown(() => {
                    if (!selected_target_binding_is_current(
                            si.get_module<MucManager>(MucManager.IDENTITY),
                            account, room, selected, bound_identity,
                            bound_affiliation_target, bound_room_context,
                            false)) {
                        show_muc_action_error(_("The selected user is no longer in the room."));
                        return false;
                    }
                    Conversation conv;
                    if (bound_affiliation_target != null) {
                        // A disclosed bare real JID is stable and may open the
                        // normal contact-details surface.
                        conv = si.get_module<ConversationManager>(
                            ConversationManager.IDENTITY).create_conversation(
                                (!) bound_affiliation_target, account,
                                Conversation.Type.CHAT);
                    } else {
                        // Without a disclosed real JID, room/nick is only a
                        // live MUC-PM address. Keep its identity binding and do
                        // not create a blockable roster-style CHAT.
                        conv = si.get_module<ConversationManager>(
                            ConversationManager.IDENTITY).create_conversation(
                                selected, account,
                                Conversation.Type.GROUPCHAT_PM,
                                bound_identity);
                    }
                    Application app = GLib.Application.get_default() as Application;
                    var conversation_details = ConversationDetails.setup_dialog(conv, si);
                    conversation_details.present(app.window);
                    return false;
                });
            });
        }

        Jid? own_jid = muc_manager.get_own_jid(conversation.counterpart, conversation.account);
        bool is_self = (own_jid != null && jid.equals(own_jid));
        if (!is_self && affiliation_target != null &&
                ((!) affiliation_target).equals_bare(
                    conversation.account.bare_jid)) {
            is_self = true;
        }
        bool target_binding_available = selected_room_context != null &&
            (!jid.is_full() || selected_peer_identity != null);

        // A MUC PM is addressed to room@service/nick.  An offline member row
        // contains a bare real JID and is intentionally not a PM target.
        if (!is_self && target_is_live && target_binding_available) {
            outer_box.append(create_menu_button(_("Start private conversation"), private_conversation_button_clicked));
        }
        Xmpp.Xep.Muc.Role? role = null;
        if (own_jid != null) {
            role = muc_manager.get_role((!) own_jid, conversation.account);
        }

        Xmpp.Xep.Muc.Affiliation? my_affiliation = null;
        bool my_affiliation_known = own_jid != null &&
            muc_manager.has_affiliation(conversation.counterpart,
                (!) own_jid, conversation.account);
        if (my_affiliation_known) {
            my_affiliation = muc_manager.get_affiliation(conversation.counterpart, (!) own_jid, conversation.account);
        }
        if (!my_affiliation_known && muc_manager.has_affiliation(
                conversation.counterpart, conversation.account.bare_jid,
                conversation.account)) {
            my_affiliation = muc_manager.get_affiliation(conversation.counterpart,
                conversation.account.bare_jid, conversation.account);
            my_affiliation_known = true;
        }

        Xmpp.Xep.Muc.Affiliation? target_affiliation = null;
        bool target_affiliation_known = muc_manager.has_affiliation(
            conversation.counterpart, jid, conversation.account);
        if (target_affiliation_known) {
            target_affiliation = muc_manager.get_affiliation(
                conversation.counterpart, jid, conversation.account);
        }
        if (affiliation_target != null && muc_manager.has_affiliation(
                conversation.counterpart, (!) affiliation_target,
                conversation.account)) {
            target_affiliation = muc_manager.get_affiliation(
                conversation.counterpart, (!) affiliation_target,
                conversation.account);
            target_affiliation_known = true;
        }
        bool actor_is_owner = my_affiliation == Xmpp.Xep.Muc.Affiliation.OWNER;
        bool actor_is_admin = my_affiliation == Xmpp.Xep.Muc.Affiliation.ADMIN;
        bool target_is_owner = target_affiliation == Xmpp.Xep.Muc.Affiliation.OWNER;
        bool target_is_admin = target_affiliation == Xmpp.Xep.Muc.Affiliation.ADMIN;
        bool target_is_protected_affiliation = target_is_owner || target_is_admin;

        // Blocking (XEP-0191)
        if (!is_self && target_binding_available && selected_block_target != null &&
                stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_supported(conversation.account)) {
            Jid block_target = (!) selected_block_target;
            bool is_blocked = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_blocked(conversation.account, block_target);
            if (is_blocked) {
                outer_box.append(create_menu_button(_("Unblock Contact"), unblock_button_clicked));
            } else {
                outer_box.append(create_menu_button(_("Block Contact"), block_button_clicked));
            }
        }

        Xmpp.Xep.Muc.Role? target_role = target_is_live
            ? muc_manager.get_role(jid, conversation.account) : null;

        // === Moderation section (Role-based actions, XEP-0045 Section 8) ===
        if (!is_self && target_is_live && target_binding_available &&
                target_affiliation_known &&
                role == Xmpp.Xep.Muc.Role.MODERATOR) {
            bool has_moderation_header = false;
            bool target_is_participant_or_visitor =
                target_role == Xmpp.Xep.Muc.Role.PARTICIPANT ||
                target_role == Xmpp.Xep.Muc.Role.VISITOR;
            // Moderators may remove participants/visitors.  A moderator role
            // itself can be removed only by an admin/owner, and admins/owners
            // are protected by their persistent affiliation.
            if (muc_manager.kick_possible(conversation.account, jid)) {
                if (!has_moderation_header) {
                    outer_box.append(new Separator(Orientation.HORIZONTAL));
                    outer_box.append(create_section_label(_("Moderation")));
                    has_moderation_header = true;
                }
                outer_box.append(create_menu_button(_("Kick"), kick_button_clicked));
            }

            // Mute changes only the current role (voice), never affiliation.
            if (target_is_participant_or_visitor) {
                if (!has_moderation_header) {
                    outer_box.append(new Separator(Orientation.HORIZONTAL));
                    outer_box.append(create_section_label(_("Moderation")));
                    has_moderation_header = true;
                }
                if (target_role == Xmpp.Xep.Muc.Role.VISITOR &&
                        muc_manager.voice_change_possible(conversation.account,
                            jid, "participant")) {
                    outer_box.append(create_menu_button(_("Unmute"), () => voice_button_clicked("participant")));
                } else if (target_role == Xmpp.Xep.Muc.Role.PARTICIPANT &&
                        muc_manager.voice_change_possible(conversation.account,
                            jid, "visitor")) {
                    outer_box.append(create_menu_button(_("Mute"), () => voice_button_clicked("visitor")));
                }
            }

            // Grant/revoke moderator status is an admin use case, not a
            // privilege of an unaffiliated temporary moderator.
            if ((actor_is_owner || actor_is_admin) && !target_is_protected_affiliation &&
                    (target_affiliation == Xmpp.Xep.Muc.Affiliation.MEMBER ||
                     target_affiliation == Xmpp.Xep.Muc.Affiliation.NONE ||
                     target_affiliation == null)) {
                if (!has_moderation_header) {
                    outer_box.append(new Separator(Orientation.HORIZONTAL));
                    outer_box.append(create_section_label(_("Moderation")));
                    has_moderation_header = true;
                }
                if (target_role == Xmpp.Xep.Muc.Role.MODERATOR &&
                        muc_manager.voice_change_possible(conversation.account,
                            jid, "participant")) {
                    outer_box.append(create_menu_button(_("Revoke Moderator"), () => voice_button_clicked("participant")));
                } else if (target_role != Xmpp.Xep.Muc.Role.MODERATOR &&
                        muc_manager.voice_change_possible(conversation.account,
                            jid, "moderator")) {
                    outer_box.append(create_menu_button(_("Make Moderator"), () => voice_button_clicked("moderator")));
                }
            }
        }

        // === Administration section (Affiliation-based actions, XEP-0045 Section 9/10) ===
        bool can_administer_affiliation = !is_self && target_binding_available &&
            affiliation_target != null &&
            target_affiliation_known &&
            (actor_is_owner || (actor_is_admin && !target_is_owner && !target_is_admin));
        if (can_administer_affiliation) {
            outer_box.append(new Separator(Orientation.HORIZONTAL));
            outer_box.append(create_section_label(_("Administration")));

            // Ban is a bare-JID affiliation change. XEP-0045 Table 7 allows
            // an owner to ban another owner; an admin may manage only member
            // and unaffiliated targets. Self-actions are excluded above.
            bool can_ban = actor_is_owner || (!target_is_owner && !target_is_admin);
            if (target_affiliation == Xmpp.Xep.Muc.Affiliation.OUTCAST) {
                outer_box.append(create_menu_button(_("Unban"), () => set_affiliation_button_clicked("none")));
            } else if (can_ban) {
                outer_box.append(create_menu_button(_("Ban (Permanent)"), ban_button_clicked));
            }

            if (actor_is_owner) {
                if (target_is_owner) {
                    outer_box.append(create_menu_button(_("Revoke Owner"), () => set_affiliation_button_clicked("admin")));
                } else {
                    outer_box.append(create_menu_button(_("Make Owner"), () => set_affiliation_button_clicked("owner")));
                }
                if (target_is_admin) {
                    outer_box.append(create_menu_button(_("Revoke Admin"), () => set_affiliation_button_clicked("member")));
                } else if (!target_is_owner) {
                    outer_box.append(create_menu_button(_("Make Admin"), () => set_affiliation_button_clicked("admin")));
                }
            }

            if (!target_is_owner && !target_is_admin &&
                    target_affiliation != Xmpp.Xep.Muc.Affiliation.MEMBER) {
                outer_box.append(create_menu_button(_("Make Member"), () => set_affiliation_button_clicked("member")));
            } else if (target_affiliation == Xmpp.Xep.Muc.Affiliation.MEMBER) {
                outer_box.append(create_menu_button(_("Revoke Membership"), () => set_affiliation_button_clicked("none")));
            }
        }

        if (jid_menu != null) stack.remove(jid_menu);
        stack.add_named(outer_box, "menu");
        stack.visible_child_name = "menu";
        jid_menu = outer_box;
    }

    private Button create_menu_button(string label_text, owned clicked_cb callback) {
        Button button = new Button();
        button.has_frame = false;
        Label label = new Label(label_text);
        label.xalign = 0;
        label.hexpand = true;
        button.child = label;
        button.clicked.connect(() => callback());
        return button;
    }

    private Label create_section_label(string text) {
        var label = new Label(text);
        label.xalign = 0;
        label.margin_start = 5;
        label.margin_top = 5;
        label.margin_bottom = 5;
        label.use_markup = true;
        var attr_list = new Pango.AttrList();
        attr_list.insert(Pango.attr_weight_new(Pango.Weight.BOLD));
        label.attributes = attr_list;
        return label;
    }

    private delegate void clicked_cb();

    private void private_conversation_button_clicked() {
        if (selected_jid == null) return;
        Jid jid = selected_jid;
        Account account = conversation.account;
        Jid room = conversation.counterpart;
        string? bound_identity = selected_peer_identity;
        Jid? bound_affiliation_target = selected_affiliation_target;
        MucManager.MucOwnerMutationContext? bound_room_context =
            selected_room_context;
        StreamInteractor si = stream_interactor;
        if (!live_target_binding_is_current(si.get_module<MucManager>(MucManager.IDENTITY),
                account, room, jid, bound_identity, bound_affiliation_target,
                bound_room_context)) {
            hide_deferred();
            show_muc_action_error(_("The selected user is no longer in the room."));
            return;
        }
        run_after_popdown(() => {
            if (!live_target_binding_is_current(si.get_module<MucManager>(MucManager.IDENTITY),
                    account, room, jid, bound_identity,
                    bound_affiliation_target, bound_room_context)) {
                show_muc_action_error(_("The selected user is no longer in the room."));
                return false;
            }
            Conversation conv = si.get_module<ConversationManager>(ConversationManager.IDENTITY).create_conversation(jid, account, Conversation.Type.GROUPCHAT_PM);
            si.get_module<ConversationManager>(ConversationManager.IDENTITY).start_conversation(conv);
            Application app = GLib.Application.get_default() as Application;
            app.controller.select_conversation(conv);
            return false;
        });
    }

    private void kick_button_clicked() {
        if (selected_jid == null) return;
        Jid target = selected_jid;
        Account account = conversation.account;
        Jid room = conversation.counterpart;
        StreamInteractor si = stream_interactor;
        string? bound_identity = selected_peer_identity;
        Jid? bound_affiliation_target = selected_affiliation_target;
        MucManager.MucOwnerMutationContext? bound_room_context =
            selected_room_context;
        hide_deferred();
        perform_role_change.begin(si, account, room, target, bound_identity,
            bound_affiliation_target, bound_room_context, "none",
            _("Kicked by moderator"));
    }

    private void ban_button_clicked() {
        if (selected_jid == null || selected_affiliation_target == null) {
            hide_deferred();
            show_muc_action_error(_("The server did not disclose a JID for this room user."));
            return;
        }
        Jid selected = selected_jid;
        Jid target = selected_affiliation_target;
        string? bound_identity = selected_peer_identity;
        MucManager.MucOwnerMutationContext? bound_room_context =
            selected_room_context;
        Account account = conversation.account;
        Jid room = conversation.counterpart;
        StreamInteractor si = stream_interactor;
        hide_deferred();
        perform_affiliation_change.begin(si, account, room, selected,
            bound_identity, target, bound_room_context, "outcast");
    }

    private void block_button_clicked() {
        if (selected_jid == null || selected_block_target == null) return;
        Jid selected = selected_jid;
        Jid block_target = selected_block_target;
        string? bound_identity = selected_peer_identity;
        Jid? bound_affiliation_target = selected_affiliation_target;
        MucManager.MucOwnerMutationContext? bound_room_context =
            selected_room_context;
        Account account = conversation.account;
        Jid room = conversation.counterpart;
        StreamInteractor si = stream_interactor;
        hide_deferred();
        perform_block_change.begin(si, account, room, selected, bound_identity,
            bound_affiliation_target, bound_room_context, block_target, true);
    }

    private void unblock_button_clicked() {
        if (selected_jid == null || selected_block_target == null) return;
        Jid selected = selected_jid;
        Jid block_target = selected_block_target;
        string? bound_identity = selected_peer_identity;
        Jid? bound_affiliation_target = selected_affiliation_target;
        MucManager.MucOwnerMutationContext? bound_room_context =
            selected_room_context;
        Account account = conversation.account;
        Jid room = conversation.counterpart;
        StreamInteractor si = stream_interactor;
        hide_deferred();
        perform_block_change.begin(si, account, room, selected, bound_identity,
            bound_affiliation_target, bound_room_context, block_target, false);
    }

    private void set_affiliation_button_clicked(string affiliation) {
        if (selected_jid == null || selected_affiliation_target == null) {
            hide_deferred();
            show_muc_action_error(_("The server did not disclose a JID for this room user."));
            return;
        }
        Jid selected = selected_jid;
        Jid target = selected_affiliation_target;
        string? bound_identity = selected_peer_identity;
        MucManager.MucOwnerMutationContext? bound_room_context =
            selected_room_context;
        Account account = conversation.account;
        Jid room = conversation.counterpart;
        StreamInteractor si = stream_interactor;
        hide_deferred();
        perform_affiliation_change.begin(si, account, room, selected,
            bound_identity, target, bound_room_context, affiliation);
    }

    private void voice_button_clicked(string role) {
        if (selected_jid == null) return;
        Jid target = selected_jid;
        Account account = conversation.account;
        Jid room = conversation.counterpart;
        StreamInteractor si = stream_interactor;
        string? bound_identity = selected_peer_identity;
        Jid? bound_affiliation_target = selected_affiliation_target;
        MucManager.MucOwnerMutationContext? bound_room_context =
            selected_room_context;
        hide_deferred();
        perform_role_change.begin(si, account, room, target, bound_identity,
            bound_affiliation_target, bound_room_context, role);
    }

    private void on_invite_clicked() {
        Jid room = conversation.counterpart;
        Account account = conversation.account;
        StreamInteractor si = stream_interactor;
        if (!muc_manager.mediated_invite_possible(account, room)) {
            update_invite_visibility();
            return;
        }
        run_after_popdown(() => {
            Application app = GLib.Application.get_default() as Application;
            var invite_conversation = si.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(room, account, Conversation.Type.GROUPCHAT);
            if (invite_conversation != null) {
                Util.show_muc_invite_dialog(invite_conversation, si, app.window);
            }
            return false;
        });
    }

    private void update_invite_visibility() {
        invite_list.visible = muc_manager.mediated_invite_possible(
            conversation.account, conversation.counterpart);
    }

    private void on_invite_permission_state_changed(Account account,
            Jid room) {
        if (cleaned_up || cleanup_started || deferred_cleanup_pending ||
                !account.equals(conversation.account) ||
                !room.equals_bare(conversation.counterpart)) return;
        update_invite_visibility();
    }

    private static async void perform_role_change(StreamInteractor si, Account account,
            Jid room, Jid target, string? bound_identity,
            Jid? bound_affiliation_target,
            MucManager.MucOwnerMutationContext? bound_room_context,
            string role,
            string? reason = null) {
        try {
            MucManager muc_manager = si.get_module<MucManager>(MucManager.IDENTITY);
            bool allowed = live_target_binding_is_current(muc_manager, account,
                room, target, bound_identity, bound_affiliation_target,
                bound_room_context) &&
                (role == "none"
                    ? muc_manager.kick_possible(account, target)
                    : muc_manager.voice_change_possible(account, target, role));
            if (!allowed || bound_room_context == null) {
                show_muc_action_error(_("The room action is not permitted for the current user state."));
                return;
            }
            yield muc_manager.change_role_checked_in_context(account,
                (!) bound_room_context, target.resourcepart, role, reason);
        } catch (GLib.Error e) {
            show_muc_action_error(e.message);
        }
    }

    private static async void perform_affiliation_change(StreamInteractor si,
            Account account, Jid room, Jid selected, string? bound_identity,
            Jid target,
            MucManager.MucOwnerMutationContext? bound_room_context,
            string affiliation) {
        try {
            MucManager muc_manager = si.get_module<MucManager>(MucManager.IDENTITY);
            if (!affiliation_change_is_currently_allowed(muc_manager, account,
                    room, selected, bound_identity, target,
                    bound_room_context, affiliation) ||
                    bound_room_context == null) {
                show_muc_action_error(_("The room action is not permitted for the current user state."));
                return;
            }
            yield muc_manager.set_affiliation_checked_in_context(account,
                (!) bound_room_context, target, affiliation);
        } catch (GLib.Error e) {
            show_muc_action_error(e.message);
        }
    }

    private static async void perform_block_change(StreamInteractor si,
            Account account, Jid room, Jid selected, string? bound_identity,
            Jid? bound_affiliation_target,
            MucManager.MucOwnerMutationContext? bound_room_context,
            Jid block_target, bool block) {
        try {
            MucManager muc_manager = si.get_module<MucManager>(MucManager.IDENTITY);
            if (block_target.is_full() || bound_affiliation_target == null ||
                    !block_target.equals_bare((!) bound_affiliation_target) ||
                    block_target.equals_bare(room) ||
                    !selected_target_binding_is_current(muc_manager, account, room,
                    selected, bound_identity, bound_affiliation_target,
                    bound_room_context, false)) {
                show_muc_action_error(_("The selected user is no longer in the room."));
                return;
            }

            BlockingManager blocking_manager = si.get_module<BlockingManager>(BlockingManager.IDENTITY);
            if (block) {
                yield blocking_manager.block_checked(account, block_target);
            } else {
                yield blocking_manager.unblock_checked(account, block_target);
            }
        } catch (GLib.Error e) {
            show_muc_action_error(e.message);
        }
    }

    private static bool live_target_binding_is_current(MucManager muc_manager,
            Account account, Jid room, Jid target, string? bound_identity,
            Jid? bound_affiliation_target,
            MucManager.MucOwnerMutationContext? bound_room_context) {
        return selected_target_binding_is_current(muc_manager, account, room,
            target, bound_identity, bound_affiliation_target,
            bound_room_context, true);
    }

    private static bool selected_target_binding_is_current(MucManager muc_manager,
            Account account, Jid room, Jid selected, string? bound_identity,
            Jid? bound_affiliation_target,
            MucManager.MucOwnerMutationContext? bound_room_context,
            bool require_live) {
        if (bound_room_context == null ||
                !((!) bound_room_context).room.equals_bare(room) ||
                !muc_manager.is_current_muc_context(account,
                    (!) bound_room_context)) {
            return false;
        }
        if (selected.is_full()) {
            if (!muc_manager.is_current_occupant(account, room, selected) ||
                    bound_identity == null ||
                    !muc_manager.private_message_peer_identity_matches(account,
                        selected, (!) bound_identity)) {
                return false;
            }

            // If the room disclosed a persistent affiliation JID when the
            // menu opened, it must still identify the same occupant now.
            if (bound_affiliation_target != null) {
                Jid? current_target = muc_manager.get_affiliation_target(account,
                    room, selected);
                if (current_target == null ||
                        !((!) current_target).equals_bare(
                            (!) bound_affiliation_target)) {
                    return false;
                }
            }
            return true;
        }

        if (require_live || bound_affiliation_target == null) return false;
        return selected.equals_bare((!) bound_affiliation_target);
    }

    private static bool affiliation_change_is_currently_allowed(
            MucManager muc_manager, Account account, Jid room, Jid selected,
            string? bound_identity, Jid target,
            MucManager.MucOwnerMutationContext? bound_room_context,
            string affiliation) {
        if (!selected_target_binding_is_current(muc_manager, account, room,
                selected, bound_identity, target, bound_room_context, false))
            return false;

        Jid? own_jid = muc_manager.get_own_jid(room, account);
        if (own_jid == null || ((!) own_jid).equals(selected) ||
                target.equals_bare(account.bare_jid) ||
                !muc_manager.has_affiliation(room, (!) own_jid, account)) {
            return false;
        }

        // affiliation=none has no persistent bare-JID list entry. For a live
        // unaffiliated occupant, use the still-authoritative room/nick state
        // after the stable identity check above.
        Jid source_lookup = target;
        if (!muc_manager.has_affiliation(room, source_lookup, account)) {
            if (!selected.is_full() ||
                    !muc_manager.has_affiliation(room, selected, account)) {
                return false;
            }
            source_lookup = selected;
        }

        Xmpp.Xep.Muc.Affiliation? requested = affiliation_from_id(affiliation);
        Xmpp.Xep.Muc.Affiliation? actor = muc_manager.get_affiliation(room,
            (!) own_jid, account);
        Xmpp.Xep.Muc.Affiliation? source = muc_manager.get_affiliation(room,
            source_lookup, account);
        return requested != null && actor != null && source != null &&
            MucManager.can_request_affiliation_change((!) actor, (!) source,
                (!) requested);
    }

    private static Xmpp.Xep.Muc.Affiliation? affiliation_from_id(
            string affiliation) {
        switch (affiliation) {
            case "owner": return Xmpp.Xep.Muc.Affiliation.OWNER;
            case "admin": return Xmpp.Xep.Muc.Affiliation.ADMIN;
            case "member": return Xmpp.Xep.Muc.Affiliation.MEMBER;
            case "outcast": return Xmpp.Xep.Muc.Affiliation.OUTCAST;
            case "none": return Xmpp.Xep.Muc.Affiliation.NONE;
            default: return null;
        }
    }

    private static void show_muc_action_error(string detail) {
        var dialog = new Adw.AlertDialog(_("Room action failed"), detail);
        dialog.add_response("close", _("Close"));
        Application? app = GLib.Application.get_default() as Application;
        dialog.present(app != null ? ((!) app).window : null);
    }
}

}
