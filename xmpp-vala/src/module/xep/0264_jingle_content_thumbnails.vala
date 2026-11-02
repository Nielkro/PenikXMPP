namespace Xmpp.Xep.JingleContentThumbnails {
    public const string NS_URI = "urn:xmpp:thumbs:1";

    public Gee.List<Thumbnail> get_thumbnails(StanzaNode node) {
        var thumbnails = new Gee.ArrayList<Thumbnail>();
        foreach (StanzaNode thumbnail_node in node.get_subnodes("thumbnail", Xep.JingleContentThumbnails.NS_URI)) {
            var thumbnail = Thumbnail.from_stanza_node(thumbnail_node);
            if (thumbnail != null) {
                thumbnails.add(thumbnail);
            }
        }
        return thumbnails;
    }

    public class Thumbnail {
        public Bytes data;
        public string? media_type;
        public int width;
        public int height;

        public string to_data_uri() {
            string? metadata = media_type == null ? null : Xmpp.encode_data_uri_media_type(media_type);
            if (metadata == null) metadata = "application/octet-stream";
            return "data:" + metadata + ";base64," + Base64.encode(data.get_data());
        }

        public StanzaNode to_stanza_node() {
            StanzaNode node = new StanzaNode.build("thumbnail", NS_URI).add_self_xmlns()
                    .put_attribute("uri", to_data_uri());
            if (this.media_type != null && Xmpp.encode_data_uri_media_type(this.media_type) != null) {
                node.put_attribute("media-type", this.media_type);
            }
            if (this.width != -1) {
                node.put_attribute("width", this.width.to_string());
            }
            if (this.height != -1) {
                node.put_attribute("height", this.height.to_string());
            }
            return node;
        }

        public static Thumbnail? from_stanza_node(StanzaNode node) {
            string uri = node.get_attribute("uri");
            if (uri == null) return null;

            string? uri_media_type;
            Bytes? data = Xmpp.get_data_for_uri_with_media_type(uri, out uri_media_type);
            if (data == null) return null;

            Thumbnail thumbnail = new Thumbnail();
            thumbnail.data = data;
            string? declared_media_type = node.get_attribute("media-type");
            thumbnail.media_type = declared_media_type != null && Xmpp.encode_data_uri_media_type(declared_media_type) != null ?
                    declared_media_type : uri_media_type;
            thumbnail.width = node.get_attribute_int("width");
            thumbnail.height = node.get_attribute_int("height");
            return thumbnail;
        }
    }
}
