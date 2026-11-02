// Opt-in views of the existing GIO types, not new runtime classes. Vala's
// gio-2.0 binding spells the buffer in virtual function pointers as guint8*,
// while gio/gio.h declares void* / const void*. Both the implementation
// parameter and the inherited vfunc declaration must have the native type.
// Ordinary GLib.InputStream/OutputStream users keep their original binding.
namespace DinoNative {
    [CCode (cname = "GInputStream", lower_case_cprefix = "g_input_stream_", type_id = "G_TYPE_INPUT_STREAM", cheader_filename = "gio/gio.h")]
    public abstract class InputStream : GLib.InputStream {
        [CCode (has_construct_function = false)]
        protected InputStream();
        [CCode (vfunc_name = "read_fn")]
        public new abstract ssize_t read([CCode (type = "void*", array_length_type = "gsize")] uint8[] buffer, GLib.Cancellable? cancellable = null) throws GLib.IOError;
        public new virtual async ssize_t read_async([CCode (type = "void*", array_length_type = "gsize")] uint8[]? buffer, int io_priority = GLib.Priority.DEFAULT, GLib.Cancellable? cancellable = null) throws GLib.IOError;
    }

    [CCode (cname = "GOutputStream", lower_case_cprefix = "g_output_stream_", type_id = "G_TYPE_OUTPUT_STREAM", cheader_filename = "gio/gio.h")]
    public abstract class OutputStream : GLib.OutputStream {
        [CCode (has_construct_function = false)]
        protected OutputStream();
        [CCode (vfunc_name = "write_fn")]
        public new abstract ssize_t write([CCode (type = "const void*", array_length_type = "gsize")] uint8[] buffer, GLib.Cancellable? cancellable = null) throws GLib.IOError;
        public new virtual async ssize_t write_async([CCode (type = "const void*", array_length_type = "gsize")] uint8[]? buffer, int io_priority = GLib.Priority.DEFAULT, GLib.Cancellable? cancellable = null) throws GLib.IOError;
    }
}
