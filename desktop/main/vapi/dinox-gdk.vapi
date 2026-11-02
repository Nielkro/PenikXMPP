// Opt-in declarations of existing GDK types. Keep read_finish's instance,
// error/result ownership and the original async state-machine semantics.
namespace DinoNative {
    [CCode (cname = "GdkClipboard", lower_case_cprefix = "gdk_clipboard_", type_id = "GDK_TYPE_CLIPBOARD", cheader_filename = "gdk/gdk.h")]
    public class Clipboard : Gdk.Clipboard {
        public new async GLib.InputStream? read_async(
            [CCode (array_length = false, array_null_terminated = true, type = "const char**")] string[] mime_types,
            int io_priority, GLib.Cancellable? cancellable, out unowned string mime_type) throws GLib.Error;
    }
    [CCode (cname = "GdkDrop", lower_case_cprefix = "gdk_drop_", type_id = "GDK_TYPE_DROP", cheader_filename = "gdk/gdk.h")]
    public class Drop : Gdk.Drop {
        public new async GLib.InputStream? read_async(
            [CCode (array_length = false, array_null_terminated = true, type = "const char**")] string[] mime_types,
            int io_priority, GLib.Cancellable? cancellable, out unowned string mime_type) throws GLib.Error;
    }
}
