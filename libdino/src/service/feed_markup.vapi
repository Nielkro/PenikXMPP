namespace Dino.Feeds {
// GLib's Vala 0.56 binding drops const on these arrays. Keep the callback ABI
// exact for newer MinGW compilers as well as the supported Linux toolchain.
[CCode (has_typedef = false)]
internal delegate void MarkupStart(GLib.MarkupParseContext context, string name,
    [CCode (array_length = false, array_null_terminated = true, type = "const gchar**")] string[] names,
    [CCode (array_length = false, array_null_terminated = true, type = "const gchar**")] string[] values) throws GLib.MarkupError;

[CCode (cname = "GMarkupParser", has_type_id = false, cheader_filename = "glib.h")]
internal struct MarkupCallbacks {
    [CCode (delegate_target = false)] public unowned MarkupStart start_element;
    [CCode (delegate_target = false)] public unowned GLib.MarkupParserEndElementFunc end_element;
    [CCode (delegate_target = false)] public unowned GLib.MarkupParserTextFunc text;
    [CCode (delegate_target = false)] public unowned GLib.MarkupParserPassthroughFunc passthrough;
    [CCode (delegate_target = false)] public unowned GLib.MarkupParserErrorFunc error;
}

[CCode (cname = "g_markup_parse_context_new", cheader_filename = "glib.h")]
internal extern GLib.MarkupParseContext markup_context_new(ref MarkupCallbacks callbacks,
    GLib.MarkupParseFlags flags, void* user_data, GLib.DestroyNotify? destroy);

}
