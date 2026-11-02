using Gtk;

namespace Dino.Ui.ConversationSummary {

// A stale FOCUS_WITHIN flag must not make the history scroll towards a header
// menu. Check the actual focus ancestry instead, and keep native popovers out
// of the chat's coordinate system. Keyboard navigation inside the history
// still uses GTK's normal scroll-into-view implementation.
internal class ChatFocusScroll : Object {
    private WeakRef viewport_ref;
    private WeakRef root_ref;
    private ulong viewport_handler = 0;
    private ulong focus_handler = 0;

    public ChatFocusScroll(Gtk.Viewport viewport) {
        viewport_ref = WeakRef(viewport);
        root_ref = WeakRef(null);
        viewport.scroll_to_focus = false;
        viewport_handler = watch_root(this, viewport);
        update_root();
    }

    private static ulong watch_root(ChatFocusScroll guard, Gtk.Viewport viewport) {
        var owner = WeakRef(guard);
        return viewport.notify["root"].connect(() => {
            var current = owner.get() as ChatFocusScroll;
            if (current != null) current.update_root();
        });
    }

    private static ulong watch_focus(ChatFocusScroll guard, Gtk.Root root) {
        var owner = WeakRef(guard);
        return root.notify["focus-widget"].connect(() => {
            var current = owner.get() as ChatFocusScroll;
            if (current != null) current.reveal_chat_focus();
        });
    }

    private void update_root() {
        disconnect_root();
        var viewport = viewport_ref.get() as Gtk.Viewport;
        Gtk.Root? root = viewport != null ? viewport.get_root() : null;
        root_ref.set(root);
        if (root != null) focus_handler = watch_focus(this, root);
    }

    private void reveal_chat_focus() {
        var viewport = viewport_ref.get() as Gtk.Viewport;
        var root = root_ref.get() as Gtk.Root;
        Widget? focused = root != null ? root.get_focus() : null;
        if (viewport == null || !viewport.get_mapped() || focused == null ||
                !focused.is_ancestor(viewport) || focused.get_native() != viewport.get_native()) return;
        // GtkText is the focus delegate of GtkEntry and GtkSearchEntry.
        if (focused is Gtk.Text) focused = focused.get_parent();
        if (focused == null) return;
#if GTK_4_12
        viewport.scroll_to(focused, null);
#else
        // Older supported GTK releases do not expose scroll_to(). Keep the
        // same visibility rule using the child's content coordinates.
        Graphene.Rect bounds;
        Widget? child = viewport.get_child();
        if (child == null) return;
        if (focused.compute_bounds(child, out bounds)) {
            viewport.hadjustment.clamp_page(bounds.origin.x, bounds.origin.x + bounds.size.width);
            viewport.vadjustment.clamp_page(bounds.origin.y, bounds.origin.y + bounds.size.height);
        }
#endif
    }

    private void disconnect_root() {
        var root = root_ref.get() as Gtk.Root;
        if (root != null && focus_handler != 0) root.disconnect(focus_handler);
        focus_handler = 0;
        root_ref.set(null);
    }

    public override void dispose() {
        var viewport = viewport_ref.get() as Gtk.Viewport;
        if (viewport != null && viewport_handler != 0) viewport.disconnect(viewport_handler);
        viewport_handler = 0;
        disconnect_root();
        base.dispose();
    }
}

// GtkViewport thaws adjustment notifications after allocating its child. A
// range handler may then change the value too late for that allocation. Finish
// the translation in our parent layout, before GTK snapshots the message tree.
internal class ChatScrollLayout : Gtk.LayoutManager {
    private WeakRef scrolled_ref;
    private WeakRef rows_ref;
    public bool preserve_visible_row { get; set; default = false; }
    public bool restoring_position { get; private set; default = false; }

    public ChatScrollLayout(ScrolledWindow scrolled, Widget? rows = null) {
        scrolled_ref = WeakRef(scrolled);
        rows_ref = WeakRef(rows);
    }

    public override SizeRequestMode get_request_mode(Widget widget) {
        Widget? child = widget.get_first_child();
        return child != null ? child.get_request_mode() : SizeRequestMode.CONSTANT_SIZE;
    }

    public override void measure(Widget widget, Orientation orientation, int for_size,
            out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum = natural = 0;
        minimum_baseline = natural_baseline = -1;
        Widget? child = widget.get_first_child();
        if (child != null && child.should_layout())
            child.measure(orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
    }

    public override void allocate(Widget widget, int width, int height, int baseline) {
        Widget? child = widget.get_first_child();
        if (child == null || !child.should_layout()) return;
        var scrolled = scrolled_ref.get() as ScrolledWindow;
        if (scrolled == null) {
            child.allocate(width, height, baseline, null);
            return;
        }
        var viewport = scrolled.get_child() as Gtk.Viewport;
        Widget? body = viewport != null ? viewport.get_child() : null;
        var adjustment = scrolled.vadjustment;
        Widget? anchor = null;
        double anchor_offset = 0;
        var rows = rows_ref.get() as Widget;
        // Capture an already allocated visible row before the new layout.
        // A late preview below it must not move it; one above it must move
        // the adjustment by that row's actual displacement, not total height.
        if (preserve_visible_row && body != null && rows != null &&
                adjustment.upper - adjustment.page_size - adjustment.value > 1) {
            for (Widget? row = rows.get_first_child(); row != null; row = row.get_next_sibling()) {
                Graphene.Rect old_bounds;
                if (!row.get_mapped() || row.get_height() == 0) continue;
                if (!row.compute_bounds(body, out old_bounds)) continue;
                if (old_bounds.origin.y + old_bounds.size.height <= adjustment.value) continue;
                if (old_bounds.origin.y >= adjustment.value + adjustment.page_size) break;
                anchor = row;
                anchor_offset = old_bounds.origin.y - adjustment.value;
                break;
            }
        }
        child.allocate(width, height, baseline, null);
        if (anchor != null && anchor.get_parent() == rows) {
            Graphene.Rect new_bounds;
            if (anchor.compute_bounds(body, out new_bounds)) {
                double target = (new_bounds.origin.y - anchor_offset).clamp(adjustment.lower,
                    double.max(adjustment.lower, adjustment.upper - adjustment.page_size));
                // Setting even the same value cancels GTK's focus-scroll
                // animation. Only restore an anchor that actually moved.
                if ((adjustment.value - target).abs() > 0.01) {
                    restoring_position = true;
                    adjustment.value = target;
                    restoring_position = false;
                }
            }
        }
        if (body == null || adjustment.upper <= adjustment.page_size) return;
        Graphene.Rect bounds;
        if (body.compute_bounds(viewport, out bounds) &&
                (bounds.origin.y + adjustment.value).abs() > 0.5) {
            viewport.queue_allocate();
            // Exactly one repair pass; no idle loop or continuous redraw.
            child.allocate(width, height, baseline, null);
        }
    }
}

// One owner for programmatic motion; a chat switch must stop every old writer
// of the shared adjustment before the next conversation is laid out.
internal class ChatScrollMotion : Object {
    public delegate void Completed();
    private WeakRef scrolled_ref;
    private Adw.TimedAnimation? animation;
    private ulong done_handler = 0;

    public ChatScrollMotion(ScrolledWindow scrolled) {
        scrolled_ref = WeakRef(scrolled);
    }

    public void snap_to_bottom() {
        var scrolled = scrolled_ref.get() as ScrolledWindow;
        if (scrolled == null) return;
        var adjustment = scrolled.vadjustment;
        // Called during layout, not from an idle after GTK painted the old
        // position. This also avoids a second visible frame for each new row.
        adjustment.value = double.max(adjustment.lower, adjustment.upper - adjustment.page_size);
    }

    public void animate_to(double target, uint duration, owned Completed completed) {
        cancel();
        var scrolled = scrolled_ref.get() as ScrolledWindow;
        if (scrolled == null) return;
        var adjustment = scrolled.vadjustment;
        double end = target.clamp(adjustment.lower,
            double.max(adjustment.lower, adjustment.upper - adjustment.page_size));
        animation = new Adw.TimedAnimation(scrolled, adjustment.value, end, duration,
            new Adw.PropertyAnimationTarget(adjustment, "value"));
        connect_completion(this, (owned) completed);
        animation.play();
    }

    private static void connect_completion(ChatScrollMotion owner, owned Completed completed) {
        var motion_ref = WeakRef(owner);
        owner.done_handler = owner.animation.done.connect(() => {
            var motion = motion_ref.get() as ChatScrollMotion;
            if (motion == null) return;
            motion.cancel();
            completed();
        });
    }

    public void cancel() {
        if (animation == null) return;
        if (done_handler != 0) animation.disconnect(done_handler);
        done_handler = 0;
        if (animation.state == Adw.AnimationState.PLAYING) animation.pause();
        animation = null;
    }

    public override void dispose() {
        cancel();
        base.dispose();
    }
}

}
