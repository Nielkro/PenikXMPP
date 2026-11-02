using Dino.Entities;
using Qlite;

namespace Dino {

public class Util {
    public static Message.Type get_message_type_for_conversation(Conversation conversation) {
        switch (conversation.type_) {
            case Conversation.Type.CHAT:
                return Entities.Message.Type.CHAT;
            case Conversation.Type.GROUPCHAT:
                return Entities.Message.Type.GROUPCHAT;
            case Conversation.Type.GROUPCHAT_PM:
                return Entities.Message.Type.GROUPCHAT_PM;
            default:
                assert_not_reached();
        }
    }

    public static Conversation.Type get_conversation_type_for_message(Message message) {
        switch (message.type_) {
            case Entities.Message.Type.CHAT:
                return Conversation.Type.CHAT;
            case Entities.Message.Type.GROUPCHAT:
                return Conversation.Type.GROUPCHAT;
            case Entities.Message.Type.GROUPCHAT_PM:
                return Conversation.Type.GROUPCHAT_PM;
            default:
                assert_not_reached();
        }
    }

    public static bool is_pixbuf_supported_mime_type(string mime_type) {
        if (mime_type == null) return false;

        // Flatpak runtime crashes have been observed when the SVG loader is invoked.
        // Treat SVG as unsupported to avoid pulling in the loader.
        string lower = mime_type.ascii_down();
        if (lower == "image/svg+xml" || lower == "image/svg" || lower == "application/svg+xml") {
            return false;
        }
        if (lower == "image/apng") lower = "image/png";

        foreach (Gdk.PixbufFormat pixbuf_format in Gdk.Pixbuf.get_formats()) {
            foreach (string pixbuf_mime in pixbuf_format.get_mime_types()) {
                if (pixbuf_mime == mime_type || pixbuf_mime == lower) return true;
            }
        }
        return false;
    }

    public static bool is_supported_image_filename(string? file_name) {
        if (file_name == null) return false;
        string lower = FileTransfer.sanitize_file_name(file_name).ascii_down();
        if (lower.has_suffix(".svg") || lower.has_suffix(".svgz")) return false;

        return lower.has_suffix(".jpg") ||
               lower.has_suffix(".jpeg") ||
               lower.has_suffix(".png") ||
               lower.has_suffix(".gif") ||
               lower.has_suffix(".webp") ||
               lower.has_suffix(".bmp") ||
               lower.has_suffix(".tif") ||
               lower.has_suffix(".tiff") ||
               lower.has_suffix(".ico") ||
               lower.has_suffix(".apng");
    }

    public static bool can_preview_image(string? mime_type, string? file_name) {
        if (mime_type != null && is_pixbuf_supported_mime_type(mime_type)) return true;

        string? file_mime_type = Dino.mime_type_from_filename(file_name);
        return file_mime_type != null && is_pixbuf_supported_mime_type(file_mime_type);
    }
}

}
