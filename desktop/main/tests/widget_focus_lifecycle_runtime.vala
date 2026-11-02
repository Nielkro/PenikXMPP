using Gtk;

namespace Dino.Ui.Test {

private class FocusClearingWindow : Window {
    public bool focus_was_cleared_before_unmap { get; private set; default = false; }

    public override void unmap() {
        Gtk.Root? root = get_root();
        Util.clear_focus_before_detach(this);
        focus_was_cleared_before_unmap =
            root != null && ((!) root).get_focus() == null;
        base.unmap();
    }
}

class WidgetFocusLifecycleRuntimeTest : Gee.TestCase {
    public WidgetFocusLifecycleRuntimeTest() {
        base("WidgetFocusLifecycleRuntime");
        add_test("focused_subtree_is_cleared_before_detach",
            test_focused_subtree_is_cleared_before_detach);
        add_test("entry_row_apply_clears_before_disable",
            test_entry_row_apply_clears_before_disable);
        add_test("entry_row_apply_preserves_focus",
            test_entry_row_apply_preserves_focus);
        add_test("focused_entry_is_cleared_before_unmap",
            test_focused_entry_is_cleared_before_unmap);
    }

    private void test_focused_subtree_is_cleared_before_detach() {
        var window = new Window();
        var row = new Box(Orientation.VERTICAL, 0);
        Box? edit_subtree = new Box(Orientation.VERTICAL, 0);
        Entry? editor = new Entry();
        var fallback = new Label("message body") { selectable = true };

        ((!) edit_subtree).append((!) editor);
        row.append((!) edit_subtree);
        row.append(fallback);
        window.child = row;
        window.set_default_size(320, 160);
        window.present();
        iterate_for(30);

        fail_if_not(((!) editor).grab_focus(),
            "the synthetic editor must own keyboard focus");
        Gtk.Root? root = ((!) edit_subtree).get_root();
        unowned Widget? focused_widget = root != null ? ((!) root).get_focus() : null;
        fail_if(focused_widget == null ||
                !(focused_widget == edit_subtree ||
                  ((!) focused_widget).is_ancestor((!) edit_subtree)),
            "the test must start with focus inside the detachable subtree");

        Util.clear_focus_before_detach((!) edit_subtree);
        fail_if(((!) root).get_focus() != null,
            "focus must be cleared synchronously before detaching the subtree");

        row.remove((!) edit_subtree);
        editor = null;
        edit_subtree = null;
        iterate_for(80);

        window.destroy();
        iterate_for(20);
    }

    private void test_entry_row_apply_clears_before_disable() {
        var window = new Window();
        var edit_subtree = new Box(Orientation.VERTICAL, 0);
        var entry_model = new ViewModel.PreferencesRow.Entry() {
            title = "Room description",
            text = "Before"
        };
        var row = Util.row_to_preference_row(entry_model);
        fail_if(row == null || !(row is Adw.EntryRow),
            "the production preference-row factory must return an entry row");
        var editor = (Adw.EntryRow) (!) row;

        entry_model.changed.connect(() => {
            Util.clear_focus_before_detach(edit_subtree);
            edit_subtree.sensitive = false;
        });

        edit_subtree.append(editor);
        window.child = edit_subtree;
        window.set_default_size(320, 160);
        window.present();
        iterate_for(30);

        fail_if_not(editor.grab_focus(),
            "the synthetic entry row must own keyboard focus");
        Gtk.Root? root = edit_subtree.get_root();
        fail_if(root == null || ((!) root).get_focus() == null,
            "the test must start with an active GtkText focus delegate");

        editor.text = "After";
        editor.apply();
        fail_if(edit_subtree.sensitive,
            "the real apply callback must disable the preferences subtree");
        fail_if(((!) root).get_focus() != null,
            "focus must be cleared before disabling the preferences subtree");

        // Cover at least one normal cursor-blink interval. With stale focus,
        // GTK 4.14 emits "did not receive a focus-out event" here.
        iterate_for(1400);

        window.destroy();
        iterate_for(20);
    }

    private void test_entry_row_apply_preserves_focus() {
        var window = new Window();
        var entry_model = new ViewModel.PreferencesRow.Entry() {
            title = "Display name",
            text = "Before"
        };
        var row = Util.row_to_preference_row(entry_model);
        fail_if(row == null || !(row is Adw.EntryRow),
            "the production preference-row factory must return an entry row");
        var editor = (Adw.EntryRow) (!) row;
        bool changed = false;
        entry_model.changed.connect(() => { changed = true; });

        window.child = editor;
        window.set_default_size(320, 160);
        window.present();
        iterate_for(30);

        fail_if_not(editor.grab_focus(),
            "the production entry row must own keyboard focus");
        editor.text = "After";
        editor.apply();
        fail_if_not(changed, "apply must notify the production view model");

        Gtk.Root? root = editor.get_root();
        unowned Widget? focused_widget =
            root != null ? ((!) root).get_focus() : null;
        fail_if(focused_widget == null ||
                !(focused_widget == editor ||
                  ((!) focused_widget).is_ancestor(editor)),
            "a normal apply must keep focus inside the entry row");

        window.destroy();
        iterate_for(20);
    }

    private void test_focused_entry_is_cleared_before_unmap() {
        var window = new FocusClearingWindow();
        var editor = new Adw.EntryRow() { title = "Topic" };
        window.child = editor;
        window.set_default_size(320, 160);
        window.present();
        iterate_for(30);

        fail_if_not(editor.grab_focus(),
            "the synthetic entry row must own keyboard focus");
        Gtk.Root? root = editor.get_root();
        fail_if(root == null || ((!) root).get_focus() == null,
            "the test must start with an active GtkText focus delegate");

        window.visible = false;
        iterate_for(1400);
        fail_if_not(window.focus_was_cleared_before_unmap,
            "focus must be cleared before the widget default unmap handler");

        window.destroy();
        iterate_for(20);
    }

    private void iterate_for(uint milliseconds) {
        MainContext context = MainContext.default();
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < deadline) {
            while (context.pending()) context.iteration(false);
            Thread.usleep(1000);
        }
        while (context.pending()) context.iteration(false);
    }
}

}
