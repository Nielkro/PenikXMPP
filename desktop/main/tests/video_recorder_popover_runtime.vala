using Gtk;

namespace Dino.Ui.Test {

class VideoRecorderPopoverRuntimeTest : Gee.TestCase {

    private class FakeVideoRecorderBackend : Object,
            Dino.Ui.ChatInput.MediaMessageRecorderBackend,
            Dino.Ui.ChatInput.VideoMessageRecorderBackend {
        public Dino.Ui.ChatInput.MediaMessageKind kind {
            get { return Dino.Ui.ChatInput.MediaMessageKind.VIDEO; }
        }
        public Dino.Ui.ChatInput.MediaMessageRecorderState state {
            get { return Dino.Ui.ChatInput.MediaMessageRecorderState.RECORDING; }
        }
        public string? current_output_path {
            get { return null; }
        }

        public void start_recording(string output_path) throws Error {}
        public void stop_recording() {}
        public void cancel_recording() {}
        public Gdk.Texture? get_preview_texture() { return null; }
    }

    public VideoRecorderPopoverRuntimeTest() {
        base("VideoRecorderPopoverRuntime");
        add_test("send_activation_is_deferred_and_coalesced",
            test_send_activation_is_deferred_and_coalesced);
    }

    private void test_send_activation_is_deferred_and_coalesced() {
        var recorder = new FakeVideoRecorderBackend();
        var anchor = new Button();
        var popover = new Dino.Ui.ChatInput.VideoRecorderPopover(recorder);
        popover.set_parent(anchor);

        int send_count = 0;
        popover.send_clicked.connect(() => {
            send_count++;
        });

        popover.request_send();
        popover.request_send();
        fail_if_not_eq_int(0, send_count,
            "send must wait until the triggering GTK pointer event has completed");
        drain_main_context();
        fail_if_not_eq_int(1, send_count,
            "rapid send activation must be coalesced into one recorder finalization");

        popover.request_send();
        drain_main_context();
        fail_if_not_eq_int(1, send_count,
            "a dispatched popover send action must remain single-shot");

        popover.unparent();
        drain_main_context();
    }

    private void drain_main_context() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
    }
}

}
