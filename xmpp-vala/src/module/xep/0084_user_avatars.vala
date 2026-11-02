namespace Xmpp.Xep.UserAvatars {
    private const string NS_URI = "urn:xmpp:avatar";
    private const string NS_URI_DATA = NS_URI + ":data";
    private const string NS_URI_METADATA = NS_URI + ":metadata";

    private bool is_sha1_hash(string hash) {
        if (hash.length != 40) return false;
        for (int i = 0; i < hash.length; i++) {
            char c = hash[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                    (c >= 'A' && c <= 'F'))) return false;
        }
        return true;
    }

    public class AvatarPublishResult : Object {
        public bool ok { get; private set; }
        public bool ambiguous { get; private set; }

        public AvatarPublishResult(bool ok, bool ambiguous = false) {
            this.ok = ok;
            this.ambiguous = ambiguous;
        }
    }

    public class AvatarMetadataResult : Object {
        public bool ok { get; private set; }
        public string? hash { get; private set; }

        public AvatarMetadataResult(bool ok, string? hash = null) {
            this.ok = ok;
            this.hash = hash;
        }
    }

    public async bool publish_png(XmppStream stream, uint8[] image, int width,
            int height) {
        var result = yield publish_png_with_result(stream, image, width, height, null);
        return result != null && result.ok;
    }

    // A cancelled GTask may return null, including after a server-side write.
    public async AvatarPublishResult? publish_png_with_result(
            XmppStream stream, uint8[] image, int width, int height,
            Cancellable? cancellable = null) {
        string sha1 = Checksum.compute_for_data(ChecksumType.SHA1, image);
        StanzaNode data_node = new StanzaNode.build("data", NS_URI_DATA).add_self_xmlns()
                .put_node(new StanzaNode.text(Base64.encode(image)));
        Pubsub.Module pubsub = stream.get_module<Pubsub.Module>(
            Pubsub.Module.IDENTITY);

        // XEP-0084 requires the data item to be available before metadata is
        // announced.  Await and check the first IQ so subscribers can never be
        // pointed at an item that the server rejected or has not stored yet.
        Pubsub.PublishResult? data_result = yield pubsub
            .publish_with_result_cancellable(stream, null, NS_URI_DATA, sha1,
                data_node, null, true, true, cancellable);
        if (data_result == null || !data_result.ok) {
            // Without a metadata publish, even an ambiguously stored data item
            // cannot become the advertised avatar.
            return new AvatarPublishResult(false);
        }

        StanzaNode metadata_node = new StanzaNode.build("metadata", NS_URI_METADATA).add_self_xmlns();
        StanzaNode info_node = new StanzaNode.build("info", NS_URI_METADATA)
                .put_attribute("bytes", image.length.to_string())
                .put_attribute("id", sha1)
                .put_attribute("width", width.to_string())
                .put_attribute("height", height.to_string())
                .put_attribute("type", "image/png");
        metadata_node.put_node(info_node);
        Pubsub.PublishResult? metadata_result = yield pubsub
            .publish_with_result_cancellable(stream, null, NS_URI_METADATA,
                sha1, metadata_node, null, true, true, cancellable);
        if (metadata_result == null) return new AvatarPublishResult(false, true);
        return new AvatarPublishResult(metadata_result.ok,
            metadata_result.ambiguous);
    }

    public async bool unset_avatar(XmppStream stream) {
        var result = yield unset_avatar_with_result(stream, null);
        return result != null && result.ok;
    }

    public async AvatarPublishResult? unset_avatar_with_result(
            XmppStream stream, Cancellable? cancellable = null) {
        // XEP-0084 disables an avatar by publishing an empty metadata item.
        // Deleting the complete PEP node is not equivalent and is rejected by
        // some services.
        StanzaNode metadata_node = new StanzaNode.build("metadata",
            NS_URI_METADATA).add_self_xmlns();
        Pubsub.PublishResult? result = yield stream.get_module<Pubsub.Module>(
            Pubsub.Module.IDENTITY).publish_with_result_cancellable(stream,
                null, NS_URI_METADATA, null, metadata_node, null, true, true,
                cancellable);
        if (result == null) return new AvatarPublishResult(false, true);
        return new AvatarPublishResult(result.ok, result.ambiguous);
    }

    public async AvatarMetadataResult? fetch_current_avatar(
            XmppStream stream, Jid jid, Cancellable? cancellable = null) {
        Pubsub.RequestAllResult? result = yield stream.get_module<Pubsub.Module>(
            Pubsub.Module.IDENTITY).request_all_with_result_cancellable(stream,
                jid, NS_URI_METADATA, 1, Pubsub.RequestPurpose.STATE_SYNC,
                cancellable);
        // Reconnect cancels the caller's token. GTask can then suppress even
        // PubSub's structured error; this must not become an avatar removal.
        if (result == null) return new AvatarMetadataResult(false);
        if (result.items == null) {
            return result.is_item_not_found()
                ? new AvatarMetadataResult(true)
                : new AvatarMetadataResult(false);
        }
        if (((!) result.items).is_empty) {
            return new AvatarMetadataResult(true);
        }

        StanzaNode item = ((!) result.items)[0];
        if (item.sub_nodes.size != 1) return new AvatarMetadataResult(false);
        StanzaNode metadata = item.sub_nodes[0];
        if (metadata.name != "metadata" ||
                metadata.ns_uri != NS_URI_METADATA) {
            return new AvatarMetadataResult(false);
        }

        Gee.List<StanzaNode> info_nodes = metadata.get_subnodes("info",
            NS_URI_METADATA);
        if (info_nodes.is_empty) return new AvatarMetadataResult(true);

        string? item_id = item.get_attribute("id");
        foreach (StanzaNode info in info_nodes) {
            string? hash = info.get_attribute("id");
            string? type = info.get_attribute("type");
            if (hash != null && is_sha1_hash((!) hash) &&
                    (item_id == null || item_id == hash) &&
                    (type == "image/png" || type == "image/jpeg")) {
                return new AvatarMetadataResult(true, (!) hash);
            }
        }
        return new AvatarMetadataResult(false);
    }

    public async Bytes? fetch_image(XmppStream stream, Jid jid, string hash) {
        // Request the specific item by hash ID instead of fetching all items.
        // This avoids getting the wrong avatar version when multiple exist.
        StanzaNode? data_node = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).request_item(stream, jid, NS_URI_DATA, hash, Pubsub.RequestPurpose.OPPORTUNISTIC_METADATA);
        if (data_node == null) {
            return null;
        }

        string? content_str = data_node.get_string_content();
        if (content_str == null || content_str.strip() == "") return null;

        Bytes image = new Bytes.take(Base64.decode(content_str));
        string sha1 = Checksum.compute_for_bytes(ChecksumType.SHA1, image);
        if (sha1 != hash) {
            warning("sha sum did not match for avatar from %s expected=%s actual=%s", jid.to_string(), hash, sha1);
            return null;
        }
        return image;
    }

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0084_user_avatars");

        public signal void received_avatar_hash(XmppStream stream, Jid jid, string id);
        public signal void avatar_removed(XmppStream stream, Jid jid);

        public override void attach(XmppStream stream) {
            stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).add_filtered_notification(stream, NS_URI_METADATA, on_pupsub_item, null, on_pubsub_delete);
        }

        public override void detach(XmppStream stream) {
            stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).remove_filtered_notification(stream, NS_URI_METADATA);
        }

        public void on_pupsub_item(XmppStream stream, Jid jid, string hash, StanzaNode? node) {
            if (node == null) return;
            if (node.name != "metadata" || node.ns_uri != NS_URI_METADATA) {
                return;
            }

            Gee.List<StanzaNode> info_nodes = node.get_subnodes("info",
                NS_URI_METADATA);
            if (info_nodes.is_empty) {
                avatar_removed(stream, jid);
                return;
            }

            if (!is_sha1_hash(hash)) return;

            foreach (var info_node in info_nodes) {
                if (info_node.get_attribute("id") == hash) {
                    string? type = info_node == null ? null : info_node.get_attribute("type");
                    if (type != "image/png" && type != "image/jpeg") return;
                    received_avatar_hash(stream, jid, hash);
                    return;
                }
            }
        }

        public void on_pubsub_delete(XmppStream stream, Jid jid) {
            avatar_removed(stream, jid);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }
}
