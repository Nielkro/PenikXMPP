using Gee;
using Gdk;
using Gtk;
using Xmpp;

using Dino.Entities;

namespace Dino.Ui {

    public class FileTransmissionProgress : Adw.Bin {

        public enum State {
            UNKNOWN_SOURCE,
            DOWNLOAD_NOT_STARTED,
            DOWNLOAD_NOT_STARTED_FAILED_BEFORE,
            DOWNLOADING,
            PROCESSING,
            UPLOADING,
            UPLOAD_FAILED
        }

        public int64 file_size { get; set; }
        public int64 transferred_size { get; set; }
        public State state { get; set; }

        private const int LINE_WIDTH = 4;

        private Button button = new Button();

        private Adw.TimedAnimation progress_animation;
        private ulong notify_file_size_handler_id = 0;
        private ulong notify_transferred_handler_id = 0;
        private ulong notify_state_handler_id = 0;
        private uint indeterminate_source_id = 0;

        construct {
            add_css_class("circular-osd");
            button.add_css_class("circular");
            button.margin_start = button.margin_end = button.margin_top = button.margin_bottom = LINE_WIDTH;
            this.set_child(button);

            this.button.clicked.connect(on_button_clicked);

            notify_transferred_handler_id = this.notify["transferred-size"].connect(update_progress);
            notify_file_size_handler_id = this.notify["file-size"].connect(update_progress);
            notify_state_handler_id = this.notify["state"].connect(on_state_changed);
            on_state_changed();

            setup_animation();
        }

        private void setup_animation() {
            progress_animation = new Adw.TimedAnimation(this, 0.0, 0.0, 250, new Adw.CallbackAnimationTarget(queue_draw)) { easing = Adw.Easing.LINEAR };
            progress_animation.done.connect(update_progress);
        }

        private void on_state_changed() {
            sensitive = state != UNKNOWN_SOURCE && state != UPLOAD_FAILED;

            switch (this.state) {
                case UNKNOWN_SOURCE:
                case DOWNLOAD_NOT_STARTED:
                    button.icon_name = "document-save-symbolic";
                    break;
                case DOWNLOADING:
                case PROCESSING:
                case UPLOADING:
                    button.icon_name = "small-x-symbolic";
                    break;
                case DOWNLOAD_NOT_STARTED_FAILED_BEFORE:
                case UPLOAD_FAILED:
                    button.icon_name = "dialog-warning-symbolic";
                    break;
            }
            update_indeterminate_animation();
        }

        private void update_progress() {
            update_indeterminate_animation();
            if (file_size <= 0 || progress_animation == null) return;
            double next_value = ((double)transferred_size / (double)file_size).clamp(0, 1);
            if (progress_animation != null && progress_animation.value_to != next_value) {
                progress_animation.value_from = progress_animation.value;
                progress_animation.value_to = next_value;
                progress_animation.reset();
                progress_animation.play();
            }
        }

        private void update_indeterminate_animation() {
            bool active = get_mapped() && should_show_activity_arc();
            if (active && indeterminate_source_id == 0) {
                indeterminate_source_id = Timeout.add(50, () => {
                    if (!get_mapped() || !should_show_activity_arc()) {
                        indeterminate_source_id = 0;
                        return Source.REMOVE;
                    }
                    queue_draw();
                    return Source.CONTINUE;
                });
            } else if (!active && indeterminate_source_id != 0) {
                Source.remove(indeterminate_source_id);
                indeterminate_source_id = 0;
            }
        }

        public override void map() {
            base.map();
            update_indeterminate_animation();
        }

        public override void unmap() {
            base.unmap();
            update_indeterminate_animation();
        }

        private bool should_show_activity_arc() {
            bool transfer_state = state == DOWNLOADING || state == UPLOADING;
            bool processing_state = state == PROCESSING;
            return processing_state || (transfer_state && (file_size <= 0 || transferred_size <= 0));
        }

#if GTK_4_14
        private static extern Gsk.Path create_progress_arc(Gsk.Path circle, float percentage);
#endif

        public override void snapshot(Gtk.Snapshot snapshot) {
            // Check if widget has a valid allocation before snapping
            if (get_width() <= 0 || get_height() <= 0) {
                return;
            }
            base.snapshot(snapshot);

            bool transfer_state = state == State.DOWNLOADING || state == State.UPLOADING;
            bool processing_state = state == State.PROCESSING;
            bool show_activity_arc = processing_state || (transfer_state && (file_size <= 0 || transferred_size <= 0));
            bool show_transfer_arc = transfer_state && file_size > 0 && progress_animation.value > 0.01;
            if (show_activity_arc || show_transfer_arc) {

                float radius = float.max(int.min(get_width(), get_height()) / 2, 1);
                float line_width = (float) LINE_WIDTH;
                double start_angle = -0.5 * Math.PI;
                double end_angle = (progress_animation.value - 0.25) * 2 * Math.PI;
                double t = (GLib.get_monotonic_time() % 1200000) / 1200000.0;
                if (show_activity_arc) {
                    start_angle = (t * 2.0 * Math.PI) - 0.5 * Math.PI;
                    end_angle = start_angle + (0.35 * 2.0 * Math.PI);
                }

                snapshot.translate({get_width() / 2, get_height() / 2});
                if (show_activity_arc) {
                    snapshot.rotate((float)((GLib.get_monotonic_time() % 1200000) / 1200000.0 * 360.0));
                }
#if GTK_4_14
                var fg_color = get_color();
                // TODO: get_style_context().lookup_color is deprecated. 
                // We fallback to fg_color until we have a better way to get accent_color in code.
                // get_style_context().lookup_color("accent_color", out fg_color);
                var builder = new Gsk.PathBuilder();
                builder.add_circle({0, 0}, radius - line_width / 2);
                var circle_path = builder.to_path();
                var stroke = new Gsk.Stroke(line_width);
                stroke.set_line_cap(Gsk.LineCap.ROUND);
                var arc_path = create_progress_arc(circle_path, show_activity_arc ? 0.35f : (float) progress_animation.value);
                snapshot.append_stroke(arc_path, stroke, fg_color);
#else
                var fg_color = get_style_context().get_color();
                get_style_context().lookup_color("accent_color", out fg_color);
                var context = snapshot.append_cairo({{-radius, -radius}, {radius*2, radius*2}});
                context.set_line_cap(Cairo.LineCap.ROUND);
                context.set_line_width(line_width);
                context.set_source_rgba(fg_color.red, fg_color.green, fg_color.blue, fg_color.alpha);
                context.arc(0, 0, radius - line_width / 2, start_angle, end_angle);
                context.stroke();
#endif
            }
        }

        private void on_button_clicked() {
            switch (this.state) {
                case UNKNOWN_SOURCE:
                case UPLOAD_FAILED:
                    break;
                case DOWNLOAD_NOT_STARTED_FAILED_BEFORE:
                case DOWNLOAD_NOT_STARTED:
                    this.activate_action("file.download", null);
                    break;
                case DOWNLOADING:
                case PROCESSING:
                case UPLOADING:
                    this.activate_action("file.cancel", null);
                    break;
            }
        }

        public override void dispose() {
            // Break reference cycles: disconnect this.notify signals
            if (notify_file_size_handler_id != 0) { this.disconnect(notify_file_size_handler_id); notify_file_size_handler_id = 0; }
            if (notify_transferred_handler_id != 0) { this.disconnect(notify_transferred_handler_id); notify_transferred_handler_id = 0; }
            if (notify_state_handler_id != 0) { this.disconnect(notify_state_handler_id); notify_state_handler_id = 0; }
            if (indeterminate_source_id != 0) { Source.remove(indeterminate_source_id); indeterminate_source_id = 0; }
            progress_animation = null;
            base.dispose();
        }
    }
}
