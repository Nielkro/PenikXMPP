using Gtk;

namespace Dino.Ui.ConversationSummary {

// A card's text column wraps at the width left beside its icon. Nested
// GtkBoxes also ask for width at a hypothetical height; keep that inverse
// query from repeatedly rewrapping every label in the column.
internal class ConversationContentHost : Widget {
    private Align content_halign;
    private Align content_valign;
    private Binding? visibility_binding;

    public ConversationContentHost(Widget content) {
        content_halign = content.halign;
        content_valign = content.valign;
        halign = content_halign;
        valign = content_valign;
        // Alignment belongs to the host. A non-filling inner child would let
        // gtk_widget_allocate() perform the inverse measurement again.
        content.halign = Align.FILL;
        content.valign = Align.FILL;
        content.set_parent(this);
        visibility_binding = content.bind_property("visible", this, "visible",
            BindingFlags.SYNC_CREATE);
    }

    private void detach_content() {
        if (visibility_binding != null) {
            ((!) visibility_binding).unbind();
            visibility_binding = null;
        }
        Widget? content = get_first_child();
        if (content == null) return;
        Util.clear_focus_before_detach((!) content);
        ((!) content).halign = content_halign;
        ((!) content).valign = content_valign;
        ((!) content).unparent();
    }

    public override void compute_expand_internal(out bool hexpand, out bool vexpand) {
        Widget? content = get_first_child();
        hexpand = content != null && ((!) content).compute_expand(Orientation.HORIZONTAL);
        vexpand = content != null && ((!) content).compute_expand(Orientation.VERTICAL);
    }

    public override SizeRequestMode get_request_mode() {
        Widget? content = get_first_child();
        return content != null ? ((!) content).get_request_mode() : SizeRequestMode.CONSTANT_SIZE;
    }

    public override void measure(Orientation orientation, int for_size,
            out int minimum, out int natural,
            out int minimum_baseline, out int natural_baseline) {
        minimum = natural = 0;
        minimum_baseline = natural_baseline = -1;
        Widget? content = get_first_child();
        if (content == null || !((!) content).should_layout()) return;
        if (orientation == Orientation.HORIZONTAL &&
                ((!) content).get_request_mode() == SizeRequestMode.HEIGHT_FOR_WIDTH) {
            for_size = -1;
        }
        ((!) content).measure(orientation, for_size, out minimum, out natural,
            out minimum_baseline, out natural_baseline);
        if (orientation == Orientation.HORIZONTAL) minimum_baseline = natural_baseline = -1;
        natural = int.max(minimum, natural);
    }

    public override void size_allocate(int width, int height, int baseline) {
        Widget? content = get_first_child();
        if (content != null && ((!) content).should_layout()) {
            ((!) content).allocate(width, height, baseline, null);
        }
    }

    public override void dispose() {
        detach_content();
        base.dispose();
    }
}

}
