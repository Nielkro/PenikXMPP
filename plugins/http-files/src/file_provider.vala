using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino.Plugins.HttpFiles {

public class FileProvider : Dino.FileProvider, Object {

    private StreamInteractor stream_interactor;
    private Dino.Database dino_db;
    private Dino.AccountHttpSessionPool session_pool;
    private GLib.MainContext soup_context;
    private ulong message_sent_handler_id = 0;
    public static Regex http_url_regex = /^https?:\/\/([^\s#]*)$/; // Spaces are invalid in URLs and we can't use fragments for downloads
    // OMEMO aesgcm:// links carry the secret (iv+key) in the fragment. Different clients may
    // encode the fragment differently (hex, base64, urlsafe base64), so only validate the
    // rough structure here and let the OMEMO decryptor parse the secret.
    public static Regex omemo_url_regex = /^aesgcm:\/\/([^\s#]+)#([^\s]+)$/;

    public static string sanitize_for_log(string? s) {
        if (s == null) return "(null)";
        string out = s;
        // Never log secrets in fragments.
        int hash = out.index_of("#");
        if (hash >= 0) out = out.substring(0, hash) + "#...";
        // Keep logs small.
        if (out.length > 200) out = out.substring(0, 200) + "...";
        return out;
    }

    public FileProvider(StreamInteractor stream_interactor, Dino.Database dino_db) {
        this.stream_interactor = stream_interactor;
        this.dino_db = dino_db;

        // libsoup is bound to the thread-default main context at creation time.
        // We may be called from non-UI contexts, so always hop back before using the session.
        this.soup_context = GLib.MainContext.ref_thread_default();
        this.session_pool = new Dino.AccountHttpSessionPool("http-download");
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(new ReceivedMessageListener(this));
        message_sent_handler_id = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).message_sent.connect(on_message_sent);
    }

    public void shutdown() {
        if (message_sent_handler_id != 0) {
            stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).disconnect(message_sent_handler_id);
            message_sent_handler_id = 0;
        }
        session_pool.shutdown();
    }

    private void on_message_sent(Entities.Message message, Conversation conversation) {
        // Sending text does not run the received-message pipeline. A copied
        // encrypted file URL must still get the local file representation.
        // Keep quotes, edits and ordinary web links as text.
        if (message.direction != Entities.Message.DIRECTION_SENT ||
                message.body == null || message.edit_to != null ||
                message.quoted_item_id != 0 || message.id <= 0 ||
                message.account.id != conversation.account.id ||
                message.type_ != Util.get_message_type_for_conversation(conversation)) return;
        string url = message.body.strip();
        if (!omemo_url_regex.match(url)) return;
        int fragment = url.index_of("#");
        if (!HttpFileUrl.is_valid_network_url("https://" + url.substring(9, fragment - 9))) return;

        var storage = stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY);
        var content_store = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        var manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
        if (storage == null || content_store == null || manager == null ||
                storage.get_file_by_message_id(message.id, conversation) != null) return;
        var row = content_store.get_content_item_row_for_message(conversation, message);
        if (row == null || row[dino_db.content_item.hide] ||
                row[dino_db.content_item.content_type] != 1) return;
        var item = content_store.get_item_by_id(conversation, row[dino_db.content_item.id]);
        if (!(item is MessageItem)) return;

        var data = new HttpFileReceiveData() { url = url };
        var meta = new HttpFileMeta();
        meta.file_name = extract_file_name_from_url(url);
        meta.mime_type = Dino.normalize_display_mime_type(null, meta.file_name);
        meta.message = message;
        meta.message_db_id = message.id;
        meta.encryption_protocol = message.encryption_protocol;
        try {
            content_store.set_item_hide_checked(item, true);
        } catch (Error e) {
            warning("Could not replace outgoing file link: %s", e.message);
            return;
        }
        // Registration and announcement happen synchronously before the first
        // metadata await. A second signal cannot create a duplicate transfer.
        manager.receive_file_from_provider.begin(this, "url:" + url,
            message.from, message.time, message.local_time, conversation,
            data, meta, true);
    }

    private async void ensure_soup_context() {
        // `get_thread_default()` may be null even while running on the default main
        // context. `MainContext.invoke()` may execute callbacks immediately in some
        // situations; if that happens before we reach `yield`, it can cause re-entrant
        // recursion in Vala async state machines. Use an explicit Source attached to
        // the desired context to guarantee asynchronous resumption.
        if (soup_context.is_owner()) return;
        var idle = new GLib.IdleSource();
        idle.set_callback(() => {
            ensure_soup_context.callback();
            return GLib.Source.REMOVE;
        });
        idle.attach(soup_context);
        yield;
    }

    private class ReceivedMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "STORE" };
        public override string action_group { get { return "MESSAGE_REINTERPRETING"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private FileProvider outer;
        private StreamInteractor stream_interactor;

        public ReceivedMessageListener(FileProvider outer) {
            this.outer = outer;
            this.stream_interactor = outer.stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            if (Xep.StatelessFileSharing.get_file_shares(stanza) != null || Xep.StatelessFileSharing.get_source_attachments(stanza) != null) {
                return false;
            }

            string? oob_url = Xmpp.Xep.OutOfBandData.get_url_from_message(stanza);

            // Determine the file URL candidate:
            // - If OOB element present: use that URL (standard file transfer)
            // - If no OOB but body is an aesgcm:// URL: treat as OMEMO file transfer
            // - If no OOB but body is a single http(s):// URL: treat as file transfer
            //   (many clients use HTTP Upload without OOB element)
            string? url_candidate = null;
            bool from_body_only = false;
            if (oob_url != null) {
                url_candidate = oob_url;
            } else if (message.body != null && FileProvider.omemo_url_regex.match(message.body)) {
                url_candidate = message.body;
            } else if (message.body != null && FileProvider.http_url_regex.match(message.body.strip())) {
                url_candidate = message.body.strip();
                from_body_only = true;
            }

            bool normal_file = url_candidate != null &&
                    HttpFileUrl.is_valid_network_url(url_candidate) &&
                    FileProvider.http_url_regex.match(url_candidate);
            bool omemo_file = url_candidate != null && FileProvider.omemo_url_regex.match(url_candidate);
            if (normal_file || omemo_file) {
                // Body-only URLs (no OOB element) might be regular webpage links
                // sent by other clients (Gajim, Monal, Conversations, etc.) rather
                // than file transfers.  Do a HEAD request to check Content-Type.
                if (from_body_only && normal_file) {
                    bool is_webpage = yield outer.check_is_webpage(url_candidate, conversation.account);
                    if (is_webpage) {
                        debug("http-files: body-only URL is a webpage, treating as text message: %s",
                              FileProvider.sanitize_for_log(url_candidate));
                        return false;
                    }
                }

                debug("http-files: incoming legacy file message normal=%s omemo=%s url_from=%s url=%s body='%s'",
                      normal_file.to_string(),
                      omemo_file.to_string(),
                      oob_url != null ? "oob" : "body",
                      FileProvider.sanitize_for_log(url_candidate),
                      FileProvider.sanitize_for_log(message.body));
                outer.on_file_message(message, stanza, conversation, url_candidate);
                return true;
            }
            return false;
        }
    }

    private void on_file_message(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation, string url) {
        // Store the URL directly so we don't depend on message.body being non-empty.
        // Messages with OOB element but no <body> would otherwise lose the URL.
        string additional_info = "url:" + url;

        var receive_data = new HttpFileReceiveData();
        receive_data.url = url;

        var file_meta = new HttpFileMeta();
        file_meta.file_name = extract_file_name_from_url(url);
        file_meta.message = message;
        file_meta.message_db_id = message.id;
        file_meta.encryption_protocol = message.encryption_protocol;
        
        // Try to get metadata from SFS element
        var file_shares = Xep.StatelessFileSharing.get_file_shares(stanza);
        if (file_shares != null && !file_shares.is_empty) {
            var sfs_metadata = file_shares[0].metadata;
            if (sfs_metadata != null) {
                if (sfs_metadata.mime_type != null) file_meta.mime_type = sfs_metadata.mime_type;
                if (sfs_metadata.name != null) file_meta.file_name = sfs_metadata.name;
                if (sfs_metadata.size != -1) file_meta.size = sfs_metadata.size;
            }
        }

        file_incoming(additional_info, message.from, message.time, message.local_time, conversation, receive_data, file_meta);
    }

    /**
     * Quick HEAD check to determine if a URL points to a webpage.
     * Returns true if Content-Type is text/html or application/xhtml+xml.
     * Returns false on error or any other Content-Type (assume downloadable file).
     */
    public async bool check_is_webpage(string url, Account? account = null) {
        if (!HttpFileUrl.is_valid_network_url(url)) return false;

        yield ensure_soup_context();
        Soup.Session session = (Soup.Session) (account != null
            ? session_pool.get_session((!) account)
            : session_pool.get_default_session());

        Soup.Message? nullable_head_message = HttpFileUrl.create_message("HEAD", url);
        if (nullable_head_message == null) return false;
        Soup.Message head_message = (!) nullable_head_message;
        head_message.request_headers.append("Accept-Encoding", "identity");

#if SOUP_3_0
        string transfer_host = "";
        try {
            transfer_host = Uri.parse(url, UriFlags.NONE).get_host();
        } catch (Error e) { }
        head_message.accept_certificate.connect((peer_cert, errors) => {
            return ConnectionManager.on_invalid_certificate(transfer_host, peer_cert, errors, dino_db);
        });
#endif

        try {
#if SOUP_3_0
            yield session.send_async(head_message, GLib.Priority.LOW, null);
#else
            yield session.send_async(head_message, null);
#endif
        } catch (Error e) {
            return false;
        }

        uint status = head_message.status_code;
        if (status < 200 || status >= 300) {
            return false;
        }

        string? content_type = null;
        head_message.response_headers.foreach((name, val) => {
            if (name.ascii_down() == "content-type") content_type = val;
        });

        if (content_type == null) return false;

        string ct_lower = content_type.ascii_down().strip();
        return ct_lower.has_prefix("text/html") || ct_lower.has_prefix("application/xhtml");
    }

    public virtual async FileMeta get_meta_info(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws FileReceiveError, IOError {
        HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
        if (http_receive_data == null) return file_meta;

        if (http_receive_data.url == null || http_receive_data.url.strip() == "") {
            throw new FileReceiveError.GET_METADATA_FAILED("Empty URL");
        }

        // GLib.Uri accepts some malformed authority forms that libsoup rejects.
        if (!HttpFileUrl.is_valid_network_url(http_receive_data.url)) {
            throw new FileReceiveError.GET_METADATA_FAILED("Malformed URL: %s".printf(sanitize_for_log(http_receive_data.url)));
        }

        yield ensure_soup_context();
        Soup.Session session = (Soup.Session) session_pool.get_session(file_transfer.account);

        Soup.Message? nullable_head_message = HttpFileUrl.create_message("HEAD", http_receive_data.url);
        if (nullable_head_message == null) {
            throw new FileReceiveError.GET_METADATA_FAILED(
                "Malformed URL: %s".printf(sanitize_for_log(http_receive_data.url)));
        }
        Soup.Message head_message = (!) nullable_head_message;
        head_message.request_headers.append("Accept-Encoding", "identity");

#if SOUP_3_0
        string transfer_host = "";
        try {
            transfer_host = Uri.parse(http_receive_data.url, UriFlags.NONE).get_host();
        } catch (Error e) {
            warning("Failed to parse URI: %s", e.message);
        }
        head_message.accept_certificate.connect((peer_cert, errors) => { return ConnectionManager.on_invalid_certificate(transfer_host, peer_cert, errors, dino_db); });
#endif


        // Keep transport error codes intact: messages are localized and cannot
        // reliably tell FileManager whether the request should be retried.
        yield send_metadata_head(session, head_message, file_transfer);

        uint head_status = head_message.status_code;
        if (head_status < 200 || head_status >= 300) {
            throw new FileReceiveError.GET_METADATA_FAILED("HEAD request returned HTTP %u".printf(head_status));
        }

        string? content_type = null, content_length = null;
        head_message.response_headers.foreach((name, val) => {
            if (name.ascii_down() == "content-type") content_type = val;
            if (name.ascii_down() == "content-length") content_length = val;
        });
        file_meta.mime_type = Dino.normalize_mime_type(content_type, file_meta.file_name);
        if (content_length != null) {
            file_meta.size = int64.parse(content_length);
        }

        return file_meta;
    }

    internal static async void send_metadata_head(Soup.Session session, Soup.Message head_message, FileTransfer file_transfer) throws IOError {
        try {
#if SOUP_3_0
            yield session.send_async(head_message, GLib.Priority.LOW, file_transfer.cancellable);
#else
            yield session.send_async(head_message, file_transfer.cancellable);
#endif
        } catch (IOError e) {
            e.message = "HEAD request failed: %s: %s".printf(head_message.get_uri().get_host(), e.message);
            throw e;
        } catch (Error e) {
            throw new IOError.FAILED("HEAD request failed: %s: %s", head_message.get_uri().get_host(), e.message);
        }
    }

    public Encryption get_encryption(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) {
        return classify_receive_payload_encryption(receive_data, file_meta);
    }

    internal static Encryption classify_receive_payload_encryption(FileReceiveData receive_data, FileMeta file_meta) {
        if ((receive_data as EsfsHttpFileReceiveData) != null) {
            return Encryption.OMEMO;
        }

        HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
        if (http_receive_data != null && http_receive_data.url != null && omemo_url_regex.match(http_receive_data.url)) {
            return Encryption.OMEMO;
        }

        return Encryption.NONE;
    }

    public async InputStream download(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws IOError {
        HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
        if (http_receive_data == null) {
            throw new IOError.INVALID_ARGUMENT("Missing HTTP receive data");
        }

        if (http_receive_data.url == null || http_receive_data.url.strip() == "") {
            throw new IOError.INVALID_ARGUMENT("Empty download URL");
        }

        // Validate the complete network URI contract before passing to libsoup.
        if (!HttpFileUrl.is_valid_network_url(http_receive_data.url)) {
            throw new IOError.INVALID_ARGUMENT("Malformed download URL: %s".printf(sanitize_for_log(http_receive_data.url)));
        }

        yield ensure_soup_context();
        Soup.Session session = (Soup.Session) session_pool.get_session(file_transfer.account);

        Soup.Message? nullable_get_message = HttpFileUrl.create_message("GET", http_receive_data.url);
        if (nullable_get_message == null) {
            throw new IOError.INVALID_ARGUMENT(
                "Malformed download URL: %s".printf(sanitize_for_log(http_receive_data.url)));
        }
        Soup.Message get_message = (!) nullable_get_message;

#if SOUP_3_0
        string transfer_host = "";
        try {
            transfer_host = Uri.parse(http_receive_data.url, UriFlags.NONE).get_host();
        } catch (Error e) {
            warning("Failed to parse URI: %s", e.message);
        }
        get_message.accept_certificate.connect((peer_cert, errors) => { return ConnectionManager.on_invalid_certificate(transfer_host, peer_cert, errors, dino_db); });
#endif

        try {
#if SOUP_3_0
            InputStream stream = yield session.send_async(get_message, GLib.Priority.LOW, file_transfer.cancellable);
#else
            InputStream stream = yield session.send_async(get_message, file_transfer.cancellable);
#endif
            uint status = get_message.status_code;
            if (status < 200 || status >= 300) {
                throw new IOError.FAILED("HTTP download failed: status %u".printf(status));
            }
            if (file_meta.size != -1) {
                return new LimitInputStream(stream, file_meta.size);
            } else {
                return stream;
            }
        } catch (IOError e) {
            // Include only the host: upload paths and query strings may carry
            // access tokens, and encrypted links contain key material.
            e.message = "HTTP download failed: %s: %s".printf(get_message.get_uri().get_host(), e.message);
            throw e;
        } catch (Error e) {
            throw new IOError.FAILED("HTTP download failed: %s: %s", get_message.get_uri().get_host(), e.message);
        }

    }

    public FileMeta get_file_meta(FileTransfer file_transfer) throws FileReceiveError {
        if (file_transfer.provider == FileManager.SFS_PROVIDER_ID) {
            var file_meta = new HttpFileMeta();
            file_meta.size = file_transfer.size;
            file_meta.mime_type = file_transfer.mime_type;
            file_meta.file_name = file_transfer.file_name;
            file_meta.message = null;
            file_meta.encryption_protocol = file_transfer.encryption_protocol;
            return file_meta;
        }

        // Legacy HTTP file transfers may persist the URL in info.
        if (file_transfer.info != null && file_transfer.info.has_prefix("url:")) {
            string url = file_transfer.info.substring("url:".length);
            var file_meta = new HttpFileMeta();
            file_meta.size = file_transfer.size;
            file_meta.mime_type = file_transfer.mime_type;
            file_meta.file_name = extract_file_name_from_url(url);
            file_meta.message = null;
            file_meta.encryption_protocol = file_transfer.encryption_protocol;
            return file_meta;
        }

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(file_transfer.counterpart.bare_jid, file_transfer.account);
        if (conversation == null) throw new FileReceiveError.GET_METADATA_FAILED("No conversation");

        int message_db_id = file_transfer.resolve_message_db_id();
        if (message_db_id <= 0) {
            throw new FileReceiveError.GET_METADATA_FAILED(
                "No backing message relation");
        }
        Message? message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_id(message_db_id, conversation);
        if (message == null) throw new FileReceiveError.GET_METADATA_FAILED("No message");

        var file_meta = new HttpFileMeta();
        file_meta.size = file_transfer.size;
        file_meta.mime_type = file_transfer.mime_type;
        file_meta.encryption_protocol = file_transfer.encryption_protocol;

        if (message.body != null && message.body.strip() != "") {
            file_meta.file_name = extract_file_name_from_url(message.body);
        } else {
            file_meta.file_name = file_transfer.file_name ?? "unknown";
        }

        file_meta.message = message;

        return file_meta;
    }

    public FileReceiveData? get_file_receive_data(FileTransfer file_transfer) {
        if (file_transfer.provider == FileManager.SFS_PROVIDER_ID) {
            Xep.StatelessFileSharing.Source? source = get_preferred_sfs_source(file_transfer.sfs_sources, file_transfer.encryption);
            var esfs_source = source as Xep.StatelessFileSharing.EsfsHttpSource;
            if (esfs_source != null) {
                var receive_data = new EsfsHttpFileReceiveData();
                receive_data.url = esfs_source.url;
                receive_data.esfs_key = esfs_source.key;
                receive_data.esfs_iv = esfs_source.iv;
                receive_data.esfs_cipher = esfs_source.cipher_uri;
                return receive_data;
            }
            var http_source = source as Xep.StatelessFileSharing.HttpSource;
            if (http_source != null) {
                var receive_data = new HttpFileReceiveData();
                receive_data.url = http_source.url;
                return receive_data;
            }
            return null;
        }

        if (file_transfer.info != null && file_transfer.info.has_prefix("url:")) {
            var receive_data = new HttpFileReceiveData();
            receive_data.url = file_transfer.info.substring("url:".length);
            return receive_data;
        }

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(file_transfer.counterpart.bare_jid, file_transfer.account);
        if (conversation == null) return null;

        int message_db_id = file_transfer.resolve_message_db_id();
        if (message_db_id <= 0) return null;
        Message? message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_id(message_db_id, conversation);
        if (message == null) return null;

        var receive_data = new HttpFileReceiveData();
        // message.body may be empty for OOB-only stanzas — fall back to null
        // so the caller can handle the error gracefully instead of crashing.
        if (message.body != null && message.body.strip() != "") {
            receive_data.url = message.body;
        } else {
            warning("http-files: message %d has empty body, cannot determine download URL", message_db_id);
            return null;
        }

        return receive_data;
    }

    public bool has_usable_download_source(FileTransfer file_transfer) {
        return file_transfer.has_usable_download_source(FileManager.SFS_PROVIDER_ID);
    }

    internal static Xep.StatelessFileSharing.Source? get_preferred_sfs_source(Gee.List<Xep.StatelessFileSharing.Source> sources, Encryption file_encryption) {
        Xep.StatelessFileSharing.EsfsHttpSource? first_esfs = null;
        Xep.StatelessFileSharing.HttpSource? first_http = null;

        foreach (Xep.StatelessFileSharing.Source source in sources) {
            var esfs_source = source as Xep.StatelessFileSharing.EsfsHttpSource;
            if (esfs_source != null &&
                    first_esfs == null &&
                    FileTransfer.is_structurally_usable_sfs_source(esfs_source, file_encryption)) {
                first_esfs = esfs_source;
                continue;
            }
            var http_source = source as Xep.StatelessFileSharing.HttpSource;
            if (http_source != null &&
                    first_http == null &&
                    FileTransfer.is_structurally_usable_sfs_source(http_source, file_encryption)) {
                first_http = http_source;
            }
        }

        if (first_esfs != null) return first_esfs;
        return first_http;
    }

    public string extract_file_name_from_url(string url) {
        string ret = url;
        if (ret.contains("#")) {
            ret = ret.substring(0, ret.last_index_of("#"));
        }
        ret = Uri.unescape_string(ret.substring(ret.last_index_of("/") + 1));
        return ret;
    }

    public int get_id() { return 0; }
}

}
