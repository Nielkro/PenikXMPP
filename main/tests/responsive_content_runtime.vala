using Gtk;
using Dino.Entities;
using Dino.Ui.ConversationSummary;

namespace Dino.Ui.Test {

class ResponsiveContentRuntimeTest : Gee.TestCase {
    private static string[] reactions = {
        "👍", "❤️", "😄", "🎉", "😮", "😢", "🔥", "✅", "👏", "🚀",
        "🌈", "💡"
    };

    public ResponsiveContentRuntimeTest() {
        base("ResponsiveContentRuntime");
        add_test("reaction_controls_reflow_without_widening_the_chat", test_reaction_reflow);
        add_test("short_reaction_row_stays_adjacent_in_the_real_message_grid", test_reaction_grid);
        add_test("reaction_grid_reflows_and_restores_the_same_controls", test_reaction_grid_resize);
        add_test("reaction_updates_preserve_menu_focus_and_activation", test_reaction_controls);
        add_test("reaction_removal_and_refill_leave_no_empty_cells", test_reaction_removal);
        add_test("long_file_status_wraps_without_hiding_transfer_actions", test_file_status);
    }

    private static Gee.ArrayList<string> participant_names() {
        var names = new Gee.ArrayList<string>();
        names.add("Participant");
        return names;
    }

    private static ReactionsWidget populated_reactions() {
        var widget = new ReactionsWidget();
        foreach (string reaction in reactions) {
            widget.update_reaction(reaction, 17, false, participant_names());
        }
        return widget;
    }

    private static FlowBox flow_layout(ReactionsWidget widget) {
        return (FlowBox) widget.get_first_child();
    }

    private static int preferred_height(Widget widget, int width) {
        int minimum, natural, minimum_baseline, natural_baseline;
        widget.measure(Orientation.VERTICAL, width, out minimum, out natural,
            out minimum_baseline, out natural_baseline);
        return natural;
    }

    private static void drain() {
        var context = MainContext.default();
        while (context.pending()) context.iteration(false);
    }

    private static void settle() {
        int64 deadline = get_monotonic_time() + 100000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private class ReactionRow : Object {
        public Builder builder;
        public Grid grid;
        public Label body;
        public ReactionsWidget widget;
        public Adw.Window window;

        public ReactionRow(ReactionsWidget widget, int width) {
            this.widget = widget;
            builder = new Builder.from_resource("/im/dinox/dinox/conversation_item_widget.ui");
            grid = (Grid) builder.get_object("main_grid");
            grid.add_css_class("message-box");
            grid.add_css_class("has-skeleton");
            ((Label) builder.get_object("name_label")).label = "Sender";
            ((Label) builder.get_object("time_label")).label = "12:34";
            body = new Label("A real message body shares one expanding grid column with its reactions.") {
                xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR,
                hexpand = true
            };
            // These are the same single-column attachments used by
            // ConversationItemSkeleton.set_widget(), not direct allocation
            // of the reaction widget that bypasses its real parent.
            grid.attach(body, 2, 1, 1, 1);
            grid.attach(widget, 2, 2, 1, 1);
            window = new Adw.Window();
            window.add_css_class("dino-main");
            window.content = grid;
            window.set_default_size(width, 400);
            window.present();
            settle();
        }

        public void close() {
            widget.cleanup();
            window.destroy();
            settle();
        }
    }

    private static Graphene.Rect cell_bounds(FlowBox flow, int position) {
        Graphene.Rect bounds;
        fail_if_not(flow.get_child_at_index(position).compute_bounds(flow, out bounds));
        return bounds;
    }

    private static void check_reaction_bounds(ReactionRow row) {
        var flow = flow_layout(row.widget);
        Graphene.Rect flow_bounds;
        fail_if_not(flow.compute_bounds(row.grid, out flow_bounds));
        fail_if(flow_bounds.origin.x < -0.5f ||
                flow_bounds.origin.x + flow_bounds.size.width > row.grid.get_width() + 0.5f,
            "the reaction flow must stay within the actual message grid");
        for (Widget? cell = flow.get_first_child(); cell != null;
                cell = cell.get_next_sibling()) {
            Graphene.Rect bounds;
            fail_if_not(cell.compute_bounds(flow, out bounds));
            fail_if(bounds.origin.x < -0.5f ||
                    bounds.origin.x + bounds.size.width > flow.get_width() + 0.5f ||
                    bounds.origin.y < -0.5f ||
                    bounds.origin.y + bounds.size.height > flow.get_height() + 0.5f,
                "native parent allocation must contain every reaction and the add menu");
        }
    }

    private void test_reaction_grid() {
        var original_direction = Widget.get_default_direction();
        try {
            foreach (int width in new int[] { 1000, 500 }) {
                foreach (TextDirection direction in new TextDirection[] {
                        TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    var widget = new ReactionsWidget();
                    widget.update_reaction(reactions[0], 1, false, participant_names());
                    widget.update_reaction(reactions[1], 2, true, participant_names());
                    var row = new ReactionRow(widget, width);
                    try {
                        var flow = flow_layout(widget);
                        Graphene.Rect first = cell_bounds(flow, 0);
                        Graphene.Rect second = cell_bounds(flow, 1);
                        Graphene.Rect menu = cell_bounds(flow, 2);
                        fail_if(Math.fabs(first.origin.y - second.origin.y) > 0.5 ||
                                Math.fabs(first.origin.y - menu.origin.y) > 0.5,
                            "two reactions and the add menu must stay on one line when the real chat has room");
                        float first_gap = direction == TextDirection.RTL
                            ? first.origin.x - second.origin.x - second.size.width
                            : second.origin.x - first.origin.x - first.size.width;
                        float second_gap = direction == TextDirection.RTL
                            ? second.origin.x - menu.origin.x - menu.size.width
                            : menu.origin.x - second.origin.x - second.size.width;
                        fail_if(first_gap < -0.5f || first_gap > 5.5f ||
                                second_gap < -0.5f || second_gap > 5.5f,
                            "short reaction rows must remain adjacent instead of spreading across the chat");
                        fail_if(row.window.get_width() > width);
                        check_reaction_bounds(row);
                        Graphene.Rect body_bounds, flow_bounds;
                        fail_if_not(row.body.compute_bounds(row.grid, out body_bounds));
                        fail_if_not(flow.compute_bounds(row.grid, out flow_bounds));
                        float start_gap = direction == TextDirection.RTL
                            ? body_bounds.origin.x + body_bounds.size.width -
                                flow_bounds.origin.x - flow_bounds.size.width
                            : flow_bounds.origin.x - body_bounds.origin.x;
                        fail_if(Math.fabs(start_gap) > 0.5,
                            "compact reactions must start at the message text edge in either direction");
                    } finally { row.close(); }
                }
            }
        } finally { Widget.set_default_direction(original_direction); }
    }

    private void test_reaction_grid_resize() {
        var widget = populated_reactions();
        var row = new ReactionRow(widget, 1000);
        try {
            var flow = flow_layout(widget);
            var first = flow.get_child_at_index(0).get_child();
            var menu_cell = flow.get_child_at_index(reactions.length);
            var first_bounds = cell_bounds(flow, 0);
            var second_bounds = cell_bounds(flow, 1);
            fail_if(Math.fabs(first_bounds.origin.y - second_bounds.origin.y) > 0.5,
                "wide real grids must arrange reaction controls horizontally");
            fail_if_not(first.grab_focus());
            row.window.set_default_size(180, 600);
            settle();
            int narrow_height = flow.get_height();
            first_bounds = cell_bounds(flow, 0);
            var last_bounds = cell_bounds(flow, reactions.length);
            fail_if(last_bounds.origin.y <= first_bounds.origin.y,
                "many reactions must wrap only when the real content column becomes narrow");
            fail_if(row.window.get_width() > 180,
                "reaction controls must not set a wider minimum chat width");
            check_reaction_bounds(row);
            row.window.set_default_size(1000, 400);
            settle();
            fail_if(flow.get_height() >= narrow_height,
                "widening the same real row must restore fewer reaction lines");
            fail_if_not(flow.get_child_at_index(0).get_child() == first &&
                    flow.get_child_at_index(reactions.length) == menu_cell,
                "resizing must preserve native reaction and popover control identities");
            fail_if_not(row.window.get_focus() == first,
                "resizing must preserve the existing native reaction focus");
            check_reaction_bounds(row);
        } finally { row.close(); }
    }

    private void test_reaction_reflow() {
        var widget = populated_reactions();
        var window = new Window();
        window.add_css_class("dino-main");
        window.set_child(widget);
        window.present();
        drain();

        int minimum, natural, minimum_baseline, natural_baseline;
        widget.measure(Orientation.HORIZONTAL, -1, out minimum, out natural,
            out minimum_baseline, out natural_baseline);
        fail_if(minimum > 180,
            "many reaction pills must not become the minimum conversation width");
        int wide_height = preferred_height(widget, 420);
        int narrow_height = preferred_height(widget, 180);
        fail_if(narrow_height <= wide_height,
            "native reaction layout must add rows as the chat narrows");
        widget.allocate(180, narrow_height, -1, null);
        var flow = flow_layout(widget);
        for (Widget? child = flow.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            Graphene.Rect bounds;
            fail_if_not(child.compute_bounds(flow, out bounds));
            fail_if(bounds.origin.x < -0.5f || bounds.origin.x + bounds.size.width > 180.5f,
                "every reaction and the add menu must remain within the chat");
        }
        window.set_child(null);
        widget.cleanup();
        window.destroy();
    }

    private void test_reaction_controls() {
        var widget = new ReactionsWidget();
        widget.update_reaction(reactions[0], 1, true, participant_names());
        var window = new Window();
        window.add_css_class("dino-main");
        window.set_child(widget);
        window.present();
        drain();
        var flow = flow_layout(widget);
        var first_cell = flow.get_child_at_index(0);
        var first = first_cell.get_child() as Button;
        var menu_cell = flow.get_child_at_index(1);
        var menu = menu_cell.get_child() as MenuButton;
        if (fail_if_not(first != null && menu != null)) {
            window.destroy();
            widget.cleanup();
            return;
        }
        fail_if(first_cell.focusable || menu_cell.focusable,
            "layout cells must not duplicate native control focus targets");
        fail_if_not(((Button) first).grab_focus());
        int activations = 0;
        widget.emoji_clicked.connect((reaction) => {
            if (reaction == reactions[0]) activations++;
        });
        ((Button) first).clicked();
        fail_if_not_eq_int(1, activations,
            "a reaction remains a native, single-activation button");
        foreach (string reaction in reactions) {
            widget.update_reaction(reaction, 2, false, participant_names());
        }
        fail_if_not(flow.get_child_at_index(reactions.length) == menu_cell,
            "incoming reactions must preserve the menu and its popover parent");
        fail_if_not(window.get_focus() == first,
            "incoming reactions must not move keyboard focus");
        fail_if(((MenuButton) menu).popover != null,
            "displaying and updating historical reactions must not construct an emoji chooser");
        fail_if_not(((Button) first).tooltip_text.contains("Participant"));
        for (int position = 1; position <= reactions.length; position++) {
            fail_if_not(window.child_focus(DirectionType.TAB_FORWARD),
                "each reaction and the add menu must remain keyboard-reachable");
            var control = flow.get_child_at_index(position).get_child();
            var focus = window.get_focus();
            fail_if_not(focus != null &&
                (focus == control || focus.is_ancestor(control)),
                "Tab must visit the native controls in reaction order");
        }
        ((MenuButton) menu).popup();
        settle();
        var popup = ((MenuButton) menu).popover;
        if (fail_if_not(popup is EmojiChooser && ((!) popup).get_mapped(),
                "the first native menu opening must create and map the emoji chooser")) {
            widget.cleanup();
            window.set_child(null);
            window.destroy();
            return;
        }
        var retained_chooser = (EmojiChooser) popup;
        Util.clear_focus_before_detach(retained_chooser);
        ((MenuButton) menu).popdown();
        settle();
        ((MenuButton) menu).popup();
        settle();
        fail_if_not(((MenuButton) menu).popover == retained_chooser &&
            retained_chooser.get_mapped(),
            "reopening the reaction menu must reuse the same native chooser");
        widget.update_reaction(reactions[0], 17, true, participant_names());
        fail_if_not(((MenuButton) menu).popover == retained_chooser &&
            flow.get_child_at_index(reactions.length) == menu_cell,
            "reaction updates must preserve the opened chooser and its menu button");
        int picked = 0;
        widget.emoji_picked.connect((emoji) => picked++);
        retained_chooser.emoji_picked("🌈");
        fail_if_not_eq_int(1, picked,
            "the lazy chooser must forward a picked emoji exactly once");
        Util.clear_focus_before_detach(retained_chooser);
        ((MenuButton) menu).popdown();
        settle();
        widget.cleanup();
        fail_if(((MenuButton) menu).popover != null ||
                ((MenuButton) menu).get_parent() != null,
            "cleanup must detach the chooser and a retained menu button");
        retained_chooser.emoji_picked("🔥");
        fail_if_not_eq_int(1, picked,
            "a retained chooser must stop forwarding emoji after cleanup");
        widget.update_reaction("🌈", 1, true, participant_names());
        settle();
        fail_if(flow.get_first_child() != null || ((MenuButton) menu).popover != null,
            "late reaction updates must not revive a cleaned menu or its popup");
        window.set_child(null);
        window.destroy();
    }

    private void test_reaction_removal() {
        var widget = populated_reactions();
        var window = new Window();
        window.add_css_class("dino-main");
        window.set_child(widget);
        window.present();
        drain();
        var flow = flow_layout(widget);
        var menu_cell = flow.get_child_at_index(reactions.length);
        var unopened_menu = (MenuButton) menu_cell.get_child();
        fail_if(unopened_menu.popover != null,
            "an unopened reaction menu must have no chooser to clean up");
        var removed_control = flow.get_child_at_index(2).get_child();
        fail_if_not(removed_control.grab_focus());
        widget.remove_reaction(reactions[2]);
        widget.remove_reaction(reactions[7]);
        widget.update_reaction("⭐", 1, true, participant_names());
        fail_if_not(window.child_focus(DirectionType.TAB_FORWARD),
            "Tab must remain usable immediately after deleting a focused reaction");
        var focus = window.get_focus();
        fail_if_not(focus != null && focus != removed_control &&
            focus.is_ancestor(flow), "focus must belong to a remaining native control");
        int cells = 0;
        for (Widget? child = flow.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            fail_if_not(child is FlowBoxChild && ((FlowBoxChild) child).get_child() != null,
                "removed reactions must not leave empty cells");
            cells++;
        }
        fail_if_not_eq_int(reactions.length, cells);
        fail_if_not(flow.get_child_at_index(cells - 1) == menu_cell);
        fail_if_not(menu_cell.get_child().grab_focus());
        widget.cleanup();
        widget.cleanup();
        fail_if(unopened_menu.popover != null,
            "cleanup must leave a retained unopened menu without a chooser");
        fail_if(window.get_focus() != null,
            "cleanup must release keyboard focus before detaching the add menu");
        fail_if(flow.get_first_child() != null,
            "cleanup must remove both controls and their layout cells");
        widget.update_reaction("🌈", 1, true, participant_names());
        fail_if(flow.get_first_child() != null,
            "late updates must not revive a disposed reaction layout");
        window.set_child(null);
        window.destroy();
    }

    private void test_file_status() {
        var widget = new FileDefaultWidget();
        widget.name_label.label = "document.pdf";
        widget.update_file_info("application/pdf", FileTransfer.State.NOT_STARTED,
            FileTransfer.Phase.NONE, null, FileTransfer.DIRECTION_RECEIVED,
            42, 0, 0, false, false, true);
        fail_if_not(widget.mime_label.wrap &&
            widget.mime_label.wrap_mode == Pango.WrapMode.WORD_CHAR);
        fail_if_not_eq_str(FileDefaultWidget.get_missing_download_source_text(true),
            widget.mime_label.label);
        widget.mime_label.label += " " + string.nfill(160, 'x');
        int minimum, natural, minimum_baseline, natural_baseline;
        widget.measure(Orientation.HORIZONTAL, -1, out minimum, out natural,
            out minimum_baseline, out natural_baseline);
        fail_if(minimum >= 320,
            "long status, translations and unbroken tokens must remain shrinkable");
        fail_if(preferred_height(widget.mime_label, 200) <=
            preferred_height(widget.mime_label, 400),
            "file status must grow vertically rather than clip information");
        widget.update_file_info("application/pdf", FileTransfer.State.IN_PROGRESS,
            FileTransfer.Phase.DOWNLOADING, null, FileTransfer.DIRECTION_RECEIVED,
            42, 10, 42);
        fail_if_not(widget.transfer_action_button.visible);
        fail_if_not_eq_str("file.cancel", widget.transfer_action_button.action_name);
        widget.dispose();
    }
}

}
