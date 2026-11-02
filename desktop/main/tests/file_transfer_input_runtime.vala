using Gtk;

namespace Dino.Ui.Test {

[CCode (cname = "gtk_drop_target_async_get_formats", cheader_filename = "gtk/gtk.h")]
private static extern unowned Gdk.ContentFormats?
    peek_runtime_drop_target_formats(Gtk.DropTargetAsync target);

class FileTransferInputRuntimeTest : Gee.TestCase {
    [CCode (cname = "gdk_content_formats_new", cheader_filename = "gdk/gdk.h")]
    private static extern Gdk.ContentFormats content_formats_new_const(
        [CCode (array_length_type = "guint", type = "const char**")] string[] mime_types);

    private const string ROOTWINDOW_DROP_MIME =
        "application/x-rootwindow-drop";

    public FileTransferInputRuntimeTest() {
        base("FileTransferInputRuntime");
        add_test("x11_rootwindow_controller_removal_is_narrow",
            test_x11_rootwindow_controller_removal_is_narrow);
    }

    private void test_x11_rootwindow_controller_removal_is_narrow() {
        var window = new Gtk.Window();
        if (!runtime_needs_legacy_rootwindow_workaround(window)) {
            window.destroy();
            GLib.Test.skip("the legacy GtkWindow rootwindow controller workaround is not active on this backend and GTK version");
            return;
        }

        Gtk.DropTargetAsync dino_copy_target =
            create_dino_copy_target();
        fail_if(is_legacy_rootwindow_drop_target(dino_copy_target),
            "DinoX's COPY target must not match the legacy MOVE+BUBBLE controller");
        ((Gtk.Widget) window).add_controller(dino_copy_target);
        var unrelated_move_target = new Gtk.DropTargetAsync(
                content_formats_new_const({ "application/x-dinox-unrelated" }),
                Gdk.DragAction.MOVE) {
            propagation_phase = Gtk.PropagationPhase.BUBBLE
        };
        fail_if(is_legacy_rootwindow_drop_target(unrelated_move_target),
            "an unrelated MOVE+BUBBLE target must not match without application/x-rootwindow-drop");
        ((Gtk.Widget) window).add_controller(unrelated_move_target);

        GLib.ListModel controllers = window.observe_controllers();
        var retained_controllers = new Gee.ArrayList<Gtk.EventController>();
        Gtk.EventController? legacy_candidate = null;
        int legacy_candidate_count = 0;

        for (uint i = 0; i < controllers.get_n_items(); i++) {
            Object? item = controllers.get_item(i);
            Gtk.EventController? controller = item as Gtk.EventController;
            if (controller == null) continue;

            if (is_legacy_rootwindow_drop_target((!) controller)) {
                legacy_candidate = (!) controller;
                legacy_candidate_count++;
            } else {
                retained_controllers.add((!) controller);
            }
        }

        if (fail_if_not_eq_int(1, legacy_candidate_count,
                "affected GTK/X11 must expose exactly one private MOVE+BUBBLE rootwindow controller") ||
                fail_if_not(legacy_candidate != null,
                "the unique legacy rootwindow controller must be retained for removal")) {
            window.destroy();
            return;
        }

        Gtk.EventController candidate = (!) legacy_candidate;
        Gtk.DropTargetAsync? async_candidate =
            candidate as Gtk.DropTargetAsync;
        if (fail_if_not(async_candidate != null,
                "the legacy rootwindow candidate must be GtkDropTargetAsync")) {
            window.destroy();
            return;
        }
        fail_if_not(has_legacy_rootwindow_drop_format((!) async_candidate),
            "the real GtkWindow candidate must expose application/x-rootwindow-drop");
        GLib.Test.message("observed GtkWindow rootwindow format: application/x-rootwindow-drop");
        fail_if(((!) async_candidate).actions != Gdk.DragAction.MOVE,
            "the legacy rootwindow candidate must use MOVE");
        fail_if(candidate.propagation_phase != Gtk.PropagationPhase.BUBBLE,
            "the legacy rootwindow candidate must use BUBBLE propagation");

        uint controller_count_before = controllers.get_n_items();
        ((Gtk.Widget) window).remove_controller(candidate);

        fail_if_not_eq_int((int) controller_count_before - 1,
            (int) controllers.get_n_items(),
            "removing the workaround candidate must remove exactly one controller");
        fail_if_not_eq_int(0, count_legacy_candidates(controllers),
            "the unique legacy rootwindow controller must be gone");
        fail_if(model_contains_controller(controllers, candidate),
            "the removed legacy rootwindow controller must no longer be attached");
        fail_if_not(model_contains_controller(controllers, dino_copy_target),
            "DinoX's COPY target must remain attached");
        fail_if_not(model_contains_controller(controllers,
                unrelated_move_target),
            "the unrelated MOVE+BUBBLE target must remain attached");
        foreach (Gtk.EventController retained in retained_controllers) {
            fail_if_not(model_contains_controller(controllers, retained),
                "every non-candidate controller must remain attached");
        }

        // This is deliberately only a controller-removal proof. It does not
        // claim to fix the separate, still-open GTK X11 GdkDrop issue #3755.
        window.destroy();
    }

    private int count_legacy_candidates(GLib.ListModel controllers) {
        int count = 0;
        for (uint i = 0; i < controllers.get_n_items(); i++) {
            Object? item = controllers.get_item(i);
            Gtk.EventController? controller = item as Gtk.EventController;
            if (controller != null &&
                    is_legacy_rootwindow_drop_target((!) controller)) {
                count++;
            }
        }
        return count;
    }

    private bool model_contains_controller(GLib.ListModel controllers,
            Gtk.EventController expected) {
        for (uint i = 0; i < controllers.get_n_items(); i++) {
            Object? item = controllers.get_item(i);
            if (item == expected) return true;
        }
        return false;
    }

    private bool runtime_needs_legacy_rootwindow_workaround(Gtk.Window window) {
        if (FileUtils.test("/.flatpak-info", FileTest.EXISTS) ||
                window.get_display().get_type().name() != "GdkX11Display" ||
                Gtk.get_major_version() != 4) {
            return false;
        }
        uint minor = Gtk.get_minor_version();
        return minor < 20 ||
                (minor == 20 && Gtk.get_micro_version() < 1);
    }

    private Gtk.DropTargetAsync create_dino_copy_target() {
        // FileTransferInputTest covers the production factory and matcher.
        // This runtime probe mirrors only their DnD discriminators so the
        // Xvfb target stays focused on GtkWindow's real controller hierarchy.
        var builder = new Gdk.ContentFormatsBuilder();
        builder.add_mime_type("application/vnd.portal.filetransfer");
        builder.add_mime_type("application/vnd.portal.files");
        builder.add_gtype(typeof(Gdk.FileList));
        builder.add_gtype(typeof(File));
        builder.add_mime_type("text/uri-list");
        return new Gtk.DropTargetAsync(builder.to_formats(),
                Gdk.DragAction.COPY) {
            propagation_phase = Gtk.PropagationPhase.CAPTURE
        };
    }

    private bool is_legacy_rootwindow_drop_target(
            Gtk.EventController controller) {
        Gtk.DropTargetAsync? target = controller as Gtk.DropTargetAsync;
        return target != null &&
                ((!) target).actions == Gdk.DragAction.MOVE &&
                controller.propagation_phase == Gtk.PropagationPhase.BUBBLE &&
                has_legacy_rootwindow_drop_format((!) target);
    }

    private bool has_legacy_rootwindow_drop_format(
            Gtk.DropTargetAsync target) {
        unowned Gdk.ContentFormats? formats =
            peek_runtime_drop_target_formats(target);
        return formats != null &&
                ((!) formats).contain_mime_type(ROOTWINDOW_DROP_MIME);
    }
}

}
