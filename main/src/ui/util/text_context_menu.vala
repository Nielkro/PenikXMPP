using Gtk;

namespace Dino.Ui.Util {

// As in ChatTextView, defer pointer context menus until button release. GTK
// 4.14/4.16 can lose active-state accounting when a held pointer enters the
// popover it just opened. Keep GTK's menu, clipboard and keyboard actions.
internal class TextContextMenu : Object {
    private weak Widget widget;
    private GestureClick click;
    private bool pending;
    private uint popup_source;
    private int pointer_x;
    private int pointer_y;

    public static void attach(Widget widget) {
        // EntryRow and SpinRow delegate through Entry/SpinButton to GtkText.
        // Use the Editable contract instead of depending on internal children.
        while (widget is Editable) {
            var next = ((Editable) widget).get_delegate() as Widget;
            if (next == null || next == widget) break;
            widget = next;
        }
        if (!(widget is Text) && !(widget is TextView)) return;
        if (widget.get_data<TextContextMenu>("dinox-text-context-menu") != null) return;
        var guard = new TextContextMenu(widget);
        widget.add_controller(guard.click);
        widget.set_data("dinox-text-context-menu", guard);
        widget.unmap.connect(guard.cancel_pending);
        widget.state_flags_changed.connect(guard.on_state_changed);
        if (widget is Text) ((Text) widget).changed.connect(guard.cancel_pending);
        else ((TextView) widget).buffer.changed.connect(guard.cancel_pending);
    }

    private TextContextMenu(Widget widget) {
        this.widget = widget;
        click = new GestureClick() { button = 0, propagation_phase = PropagationPhase.CAPTURE,
            name = "dino-text-context-menu-release" };
        click.pressed.connect(on_pressed);
        click.released.connect(on_released);
        click.cancel.connect(cancel_pending);
        // Do not cancel on "stopped": a long-held or moving click still has
        // a release, even after GTK resets the multi-click counter.
    }

    public override void dispose() {
        cancel_pending();
        base.dispose();
    }

    private void cancel_pending() {
        pending = false;
        if (popup_source != 0) {
            Source.remove(popup_source);
            popup_source = 0;
        }
    }

    private void on_state_changed(StateFlags previous) {
        if (widget == null || !widget.is_sensitive()) cancel_pending();
    }

    private void on_pressed(int n_press, double x, double y) {
        unowned Gdk.Event? event = click.get_current_event();
        if (widget == null || event == null || !event.triggers_context_menu()) return;
        cancel_pending();
        click.set_state(EventSequenceState.CLAIMED);
        pointer_x = (int) x;
        pointer_y = (int) y;
        if (widget is Text) {
            ((Text) widget).grab_focus_without_selecting();
        } else {
            var view = (TextView) widget;
            view.grab_focus();
            view.reset_im_context();
            view.window_to_buffer_coords(TextWindowType.WIDGET, (int) x, (int) y,
                out pointer_x, out pointer_y);
        }
        pending = true;
    }

    private void on_released() {
        if (!pending || popup_source != 0) return;
        popup_source = queue_popup(this);
    }

    private static uint queue_popup(TextContextMenu guard) {
        WeakRef weak_guard = WeakRef(guard);
        return Idle.add(() => {
            var current = weak_guard.get() as TextContextMenu;
            if (current != null) current.open_menu();
            return Source.REMOVE;
        });
    }

    private void open_menu() {
        popup_source = 0;
        bool show = pending;
        pending = false;
        if (!show || widget == null || !widget.get_mapped() ||
                widget.get_root() == null || !widget.is_sensitive()) return;
        if (!widget.activate_action("menu.popup", null)) return;
        int x = pointer_x, y = pointer_y;
        if (widget is TextView) {
            ((TextView) widget).buffer_to_window_coords(TextWindowType.WIDGET,
                pointer_x, pointer_y, out x, out y);
        }
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            if (child is PopoverMenu) {
                ((PopoverMenu) child).set_pointing_to({ x, y, 1, 1 });
                ((PopoverMenu) child).present();
                break;
            }
        }
    }
}
}
