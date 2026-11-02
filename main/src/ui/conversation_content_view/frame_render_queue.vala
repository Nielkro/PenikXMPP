using Gtk;

namespace Dino.Ui.ConversationSummary {

// Idle sources of the same priority are dispatched together. A chat's initial
// rows must instead yield to layout and paint between small batches, including
// while the navigation page is animating into view.
internal class FrameRenderQueue : Object {
    public delegate void Work();

    private class Entry : Object {
        public Work run;
        public Entry(owned Work run) { this.run = (owned) run; }
    }

    private const int64 BUDGET_US = 4000;
    // GTK measures the new rows after this callback. Bound their number too:
    // cheap widget constructors can still create expensive text layouts.
    private const int MAX_ROWS_PER_FRAME = 4;
    private Gee.LinkedList<Entry> entries = new Gee.LinkedList<Entry>();
    private WeakRef widget_ref;
    private uint tick_id = 0;
    private uint generation = 0;
    private ulong map_handler = 0;
    private ulong unmap_handler = 0;

    public bool pending { get { return !entries.is_empty; } }

    public FrameRenderQueue(Widget widget) {
        widget_ref = WeakRef(widget);
        connect_mapping(this, widget);
    }

    private static void connect_mapping(FrameRenderQueue owner, Widget widget) {
        var queue_ref = WeakRef(owner);
        owner.map_handler = widget.map.connect(() => {
            var queue = queue_ref.get() as FrameRenderQueue;
            if (queue != null && queue.pending) start_tick(queue);
        });
        owner.unmap_handler = widget.unmap.connect(() => {
            var queue = queue_ref.get() as FrameRenderQueue;
            if (queue != null) queue.pause();
        });
    }

    public void add(owned Work work) {
        entries.add(new Entry((owned) work));
        if (tick_id == 0) start_tick(this);
    }

    private static void start_tick(FrameRenderQueue owner) {
        if (owner.tick_id != 0) return;
        var widget = owner.widget_ref.get() as Widget;
        if (widget == null) {
            owner.cancel();
            return;
        }
        if (!widget.get_mapped()) return;
        var queue_ref = WeakRef(owner);
        owner.tick_id = widget.add_tick_callback((widget, clock) => {
            var queue = queue_ref.get() as FrameRenderQueue;
            return queue != null && queue.run_frame(widget);
        });
    }

    private bool run_frame(Widget widget) {
        if (!widget.get_mapped()) return Source.CONTINUE;
        uint current_generation = generation;
        int64 deadline = get_monotonic_time() + BUDGET_US;
        int rows = 0;
        while (!entries.is_empty && rows < MAX_ROWS_PER_FRAME) {
            var entry = entries.remove_at(0);
            entry.run();
            rows++;
            // A callback may clear/reload the conversation. Its replacement
            // queue owns a different tick and must not be drained by this one.
            if (generation != current_generation) return Source.REMOVE;
            if (get_monotonic_time() >= deadline) break;
        }
        if (pending) return Source.CONTINUE;
        tick_id = 0;
        return Source.REMOVE;
    }

    private void pause() {
        generation++;
        var widget = widget_ref.get() as Widget;
        if (tick_id != 0 && widget != null) widget.remove_tick_callback(tick_id);
        tick_id = 0;
    }

    public void cancel() {
        pause();
        entries.clear();
    }

    public override void dispose() {
        cancel();
        var widget = widget_ref.get() as Widget;
        if (widget != null) {
            if (map_handler != 0) widget.disconnect(map_handler);
            if (unmap_handler != 0) widget.disconnect(unmap_handler);
        }
        map_handler = unmap_handler = 0;
        base.dispose();
    }
}

}
