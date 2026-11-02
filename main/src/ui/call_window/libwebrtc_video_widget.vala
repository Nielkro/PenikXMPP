using Gtk;

/**
 * Minimal GTK render target for remote Google/libwebrtc video frames.
 *
 * This widget intentionally does not use DinoX's RTP/GStreamer video widget.
 * libwebrtc delivers already decoded BGRA frame copies through the wrapper ABI;
 * GTK only receives a Gdk.MemoryTexture on the main thread.
 */
public class Dino.Ui.LibwebrtcVideoWidget : Gtk.Widget {
    private Gtk.Picture? picture;
    private int current_width = 0;
    private int current_height = 0;

    public signal void resolution_changed(int width, int height);

    public LibwebrtcVideoWidget() {
        layout_manager = new Gtk.BinLayout();
        picture = new Gtk.Picture();
        ((!) picture).content_fit = Gtk.ContentFit.CONTAIN;
        ((!) picture).can_shrink = true;
        ((!) picture).insert_after(this, null);
        add_css_class("libwebrtc-video");
    }

    public void display_frame(Plugins.JmiCallVideoFrame frame) {
        if (picture == null || frame.width <= 0 || frame.height <= 0 || frame.stride < frame.width * 4) {
            return;
        }

        Gdk.Texture texture = new Gdk.MemoryTexture(
            frame.width,
            frame.height,
            Gdk.MemoryFormat.B8G8R8A8,
            frame.data,
            frame.stride);
        ((!) picture).paintable = texture;

        if (current_width != frame.width || current_height != frame.height) {
            current_width = frame.width;
            current_height = frame.height;
            resolution_changed(current_width, current_height);
        }
    }

    public void detach() {
        if (picture != null) {
            ((!) picture).paintable = null;
        }
        current_width = 0;
        current_height = 0;
    }

    public override void dispose() {
        detach();
        if (picture != null) {
            ((!) picture).unparent();
            picture = null;
        }
        base.dispose();
    }
}
