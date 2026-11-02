namespace Dino.Plugins.GoogleWebrtc {

#if WINDOWS
[Compact]
[CCode (cname = "DinoXMediaFoundationWriter", free_function = "dinox_mf_writer_free", cheader_filename = "media_foundation_writer.h", has_type_id = false)]
internal class MediaFoundationWriterHandle {
}
#endif

}
