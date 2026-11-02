namespace Dino.Ui {

// Keep the native system setting live when the profile has no override.
public class WindowControlPlacement : Object {
    public static void apply(string placement) {
        var settings = Gtk.Settings.get_default();
        if (settings == null) return;
        // GTK packs title buttons in reading order. Explicit left/right choices
        // refer to the physical side of the window, including Arabic layouts.
        bool rtl = Gtk.Widget.get_default_direction() == Gtk.TextDirection.RTL;
        switch (placement) {
            case "left":
                settings.gtk_decoration_layout = rtl ? ":maximize,minimize,close" : "close,minimize,maximize:";
                break;
            case "right":
                settings.gtk_decoration_layout = rtl ? "close,maximize,minimize:" : ":minimize,maximize,close";
                break;
            default:
                settings.reset_property("gtk-decoration-layout");
                break;
        }
    }
}

}
