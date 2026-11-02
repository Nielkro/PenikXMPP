using Gtk;

namespace Dino.Ui {
public class SizingBin : Widget {
    public int min_width { get; set; default = -1; }
    public int target_width { get; set; default = -1; }
    public int max_width { get; set; default = -1; }
    public int min_height { get; set; default = -1; }
    public int target_height { get; set; default = -1; }
    public int max_height { get; set; default = -1; }

    public override void compute_expand_internal(out bool hexpand, out bool vexpand) {
        hexpand = false;
        vexpand = false;
        Widget child = get_first_child();
        while (child != null) {
            hexpand = hexpand || child.compute_expand(Orientation.HORIZONTAL);
            vexpand = vexpand || child.compute_expand(Orientation.VERTICAL);
            child = child.get_next_sibling();
        }
    }

    public override void size_allocate(int width, int height, int baseline) {
        if (max_height != -1) height = int.min(height, max_height);
        if (max_width != -1) width = int.min(width, max_width);
        Widget child = get_first_child();
        while (child != null) {
            if (child.should_layout()) {
                child.allocate(width, height, baseline, null);
            }
            child = child.get_next_sibling();
        }
    }

    public override void measure(Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        // Measure at the same cross-axis size that size_allocate() will give
        // the child. In particular, wrapped text inside a width-limited bin
        // must reserve the height of that limited width even in a wide host.
        if (orientation == Orientation.VERTICAL && max_width >= 0) {
            // Even the unconstrained height must account for the maximum
            // width: this child can never receive an infinitely wide line.
            for_size = for_size < 0 ? max_width : int.min(for_size, max_width);
        } else if (orientation == Orientation.HORIZONTAL && max_height >= 0) {
            for_size = for_size < 0 ? max_height : int.min(for_size, max_height);
        }
        if (orientation == Orientation.HORIZONTAL) {
            minimum = min_width >= 0 ? min_width : 0;
            natural = target_width >= 0 ? target_width : minimum;
        } else {
            minimum = min_height >= 0 ? min_height : 0;
            natural = target_height >= 0 ? target_height : minimum;
        }
        minimum_baseline = -1;
        natural_baseline = -1;
        Widget child = get_first_child();
        while (child != null) {
            if (child.should_layout()) {
                int child_min = 0;
                int child_nat = 0;
                int child_min_baseline = -1;
                int child_nat_baseline = -1;
                child.measure(orientation, for_size, out child_min, out child_nat, out child_min_baseline, out child_nat_baseline);
                minimum = int.max(minimum, child_min);
                natural = int.max(natural, child_nat);
                if (child_min_baseline > 0) {
                    minimum_baseline = int.max(minimum_baseline, child_min_baseline);
                }
                if (child_nat_baseline > 0) {
                    natural_baseline = int.max(natural_baseline, child_nat_baseline);
                }
            }
            child = child.get_next_sibling();
        }
        // GTK4 only supports vertical baselines — suppress for horizontal
        if (orientation == Orientation.HORIZONTAL) {
            minimum_baseline = -1;
            natural_baseline = -1;
        }
        if (orientation == Orientation.HORIZONTAL) {
            if (max_width != -1) natural = int.min(natural, max_width);
        } else {
            if (max_height != -1) natural = int.min(natural, max_height);
        }
        natural = int.max(natural, minimum);
    }

    public override SizeRequestMode get_request_mode() {
        Widget child = get_first_child();
        if (child != null) {
            return child.get_request_mode();
        }
        return SizeRequestMode.CONSTANT_SIZE;
    }

    public override void dispose() {
        Widget? child = this.get_first_child();
        while (child != null) {
            Widget? next = child.get_next_sibling();
            child.unparent();
            child = next;
        }
        base.dispose();
    }
}
}
