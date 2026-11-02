using Dino.Entities;
using Xmpp;
using Gee;
using Crypto;

namespace Dino.Plugins.HttpFiles {

class EncryptedHttpFileSendData : HttpFileSendData {
    public uint8[] key;
    public uint8[] iv;
}

public class HttpFileSender : FileSender, Object {
    private const int AES_GCM_AUTH_TAG_BYTES = 16;

    private StreamInteractor stream_interactor;
    private Database db;
    private Dino.AccountHttpSessionPool session_pool;
    private GLib.MainContext soup_context;
    private HashMap<Account, long> max_file_sizes = new HashMap<Account, long>(Account.hash_func, Account.equals_func);

    public HttpFileSender(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;

        // libsoup is bound to the thread-default main context at creation time.
        // Ensure we always use this session from the same context.
        this.soup_context = GLib.MainContext.ref_thread_default();
        this.session_pool = new Dino.AccountHttpSessionPool("http-upload");
        stream_interactor.stream_negotiated.connect(on_stream_negotiated);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).build_message_stanza.connect(check_add_sfs_element);
    }

    public void shutdown() {
        session_pool.shutdown();
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

    public async FileSendData? prepare_send_file(Conversation conversation, FileTransfer file_transfer, FileMeta file_meta) throws FileSendError {
        HttpFileSendData send_data;
        bool encrypt_upload_payload = should_encrypt_upload_payload(file_transfer.encryption, file_meta);
        int64 upload_size = get_upload_request_size(encrypt_upload_payload, file_meta);
        long? max_file_size = get_max_file_size(file_transfer.account);
        if (max_file_size != null && !is_upload_request_size_within_limit(upload_size, (!) max_file_size)) {
            throw new FileSendError.UPLOAD_FAILED("File exceeds HTTP upload size limit");
        }
        if (encrypt_upload_payload) {
            var enc_data = new EncryptedHttpFileSendData();
            enc_data.key = new uint8[32];
            enc_data.iv = new uint8[12];
            Crypto.randomize(enc_data.key);
            Crypto.randomize(enc_data.iv);
            // Always append the 16-byte GCM auth tag to the encrypted upload.
            // The aesgcm:// URL format requires the tag appended to ciphertext.
            // ESFS receivers also handle it (tries with-tag first, falls back to tag-less).
            send_data = enc_data;
        } else {
            send_data = new HttpFileSendData();
        }

        if (send_data == null) return null;

        Xmpp.XmppStream? stream = stream_interactor.get_stream(file_transfer.account);
        if (stream == null) return null;

        try {
            debug("http-files: requesting upload slot name='%s' size=%lld mime=%s",
                  file_transfer.server_file_name,
                  upload_size,
                  file_meta.mime_type ?? "(null)");
            var slot_result = yield stream_interactor.module_manager.get_module<Xmpp.Xep.HttpFileUpload.Module>(file_transfer.account, Xmpp.Xep.HttpFileUpload.Module.IDENTITY).request_slot_with_cancellable(stream, file_transfer.server_file_name, upload_size, file_meta.mime_type, file_transfer.cancellable);
            validate_upload_slot_urls(slot_result.url_get, slot_result.url_put);
            send_data.url_down = slot_result.url_get;
            send_data.url_up = slot_result.url_put;
            send_data.headers = slot_result.headers;
            debug("http-files: got slot url_get=%s url_put=%s", sanitize_url_for_log(send_data.url_down), sanitize_url_for_log(send_data.url_up));
        } catch (Xep.HttpFileUpload.HttpFileTransferError e) {
            throw new FileSendError.UPLOAD_FAILED("Http file upload XMPP error: %s".printf(e.message));
        } catch (IOError e) {
            throw new FileSendError.UPLOAD_FAILED("Upload slot request failed: %s".printf(e.message));
        }

        return send_data;
    }

    public async void send_file(Conversation conversation, FileTransfer file_transfer, FileSendData file_send_data, FileMeta file_meta) throws FileSendError {
        HttpFileSendData? send_data = file_send_data as HttpFileSendData;
        if (send_data == null) return;

        debug("http-files: send_file start encryption=%d conv_encryption=%d can_reference? computing...", (int) file_transfer.encryption, (int) conversation.encryption);

        bool can_reference_element = conversation.type_ == Conversation.Type.CHAT || 
                                      conversation.type_ == Conversation.Type.GROUPCHAT_PM || (
                // The stable stanza ID XEP is not clear about an announcing MUC having to attach stanza-ids, thus we also check for MAM, which requires this.
                stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY).has_feature_cached(conversation.account, conversation.counterpart, Xep.UniqueStableStanzaIDs.NS_URI) &&
                stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY).has_feature_cached(conversation.account, conversation.counterpart, Xmpp.MessageArchiveManagement.NS_URI)
            );

        // Share unencrypted files via SFS (only if we'll be able to reference messages)
        if (should_send_as_sfs(file_transfer.encryption, can_reference_element)) {
            yield send_unencrypted_sfs_file(conversation, file_transfer, send_data, file_meta);
        }
        // Share encrypted files without SFS
        else {
            yield send_body_url_file(conversation, file_transfer, send_data, file_meta);
        }
    }

    private async void send_unencrypted_sfs_file(Conversation conversation, FileTransfer file_transfer, HttpFileSendData send_data, FileMeta file_meta) throws FileSendError {
        debug("http-files: sending as SFS+attachment (unencrypted), url=%s", sanitize_url_for_log(send_data.url_down));

        file_transfer.set_transfer_phase(FileTransfer.Phase.ANNOUNCING);
        Entities.Message file_share_message = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).create_out_message(null, conversation);
        prepare_unencrypted_sfs_share(file_transfer, file_share_message);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).send_xmpp_message(file_share_message, conversation);

        yield upload(file_transfer, send_data, file_meta);
        throw_if_transfer_cancelled(file_transfer);

        file_transfer.set_transfer_phase(FileTransfer.Phase.ANNOUNCING);
        MessageStanza stanza = build_unencrypted_sfs_attachment_stanza(conversation, file_transfer, send_data, file_share_message);

        var stream = stream_interactor.get_stream(conversation.account);
        if (stream == null) throw new FileSendError.UPLOAD_FAILED("No stream");

        stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, stanza);
    }

    internal static void prepare_unencrypted_sfs_share(FileTransfer file_transfer, Entities.Message file_share_message) {
        file_transfer.info = file_share_message.id.to_string();
        file_transfer.message_db_id = file_share_message.id;
        file_transfer.file_sharing_id = Xmpp.random_uuid();
    }

    internal static MessageStanza build_unencrypted_sfs_attachment_stanza(Conversation conversation, FileTransfer file_transfer, HttpFileSendData send_data, Entities.Message file_share_message) {
        file_transfer.add_sfs_source(new Xep.StatelessFileSharing.HttpSource() { url = send_data.url_down });

        MessageStanza stanza = new MessageStanza() {
            to = conversation.counterpart,
            type_ = conversation.type_ == GROUPCHAT ? MessageStanza.TYPE_GROUPCHAT : MessageStanza.TYPE_CHAT
        };
        stanza.body = send_data.url_down;
        Xep.OutOfBandData.add_url_to_message(stanza, send_data.url_down);

        var sources = new ArrayList<Xep.StatelessFileSharing.Source>();
        sources.add(new Xep.StatelessFileSharing.HttpSource() { url = send_data.url_down });
        string attach_to_id = MessageStorage.get_reference_id(file_share_message);
        Xep.StatelessFileSharing.set_sfs_attachment(stanza, attach_to_id, file_transfer.file_sharing_id, sources);
        return stanza;
    }

    private async void send_body_url_file(Conversation conversation, FileTransfer file_transfer, HttpFileSendData send_data, FileMeta file_meta) throws FileSendError {
        debug("http-files: sending encrypted or non-referenceable; uploading first url=%s", sanitize_url_for_log(send_data.url_down));

        yield upload(file_transfer, send_data, file_meta);
        throw_if_transfer_cancelled(file_transfer);

        Encryption message_encryption = prepare_body_url_announcement(send_data, file_transfer);

        file_transfer.set_transfer_phase(FileTransfer.Phase.ANNOUNCING);
        Entities.Message message = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).create_out_message(send_data.url_down, conversation);
        file_transfer.info = message.id.to_string();
        file_transfer.message_db_id = message.id;

        // PGP file transfers keep the HTTP URL inside the OpenPGP-encrypted body.
        // Do not add an outer OOB element here: XEP-0027/XEP-0374 only encrypt
        // their own payload, not arbitrary cleartext stanza children.

        message.encryption = message_encryption;
        debug("http-files: sending message body url=%s message.encryption=%d", sanitize_url_for_log(send_data.url_down), (int) message.encryption);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).send_xmpp_message(message, conversation);
    }

    internal static Encryption prepare_body_url_announcement(HttpFileSendData send_data, FileTransfer file_transfer) {
        if (send_data is EncryptedHttpFileSendData) {
            set_legacy_aesgcm_body_url(send_data);
        }

        // For encrypted sends, keep the file URL only in the encrypted body.
        // Do not add outer SFS/ESFS here: this code runs before the OMEMO
        // module decides whether the stanza will use OMEMO 2/SCE or legacy
        // OMEMO 1. OMEMO 1 encrypts only the message body, so outer SFS/ESFS
        // would leak URL, key and IV in cleartext.
        if (file_transfer.file_sharing_id == null || file_transfer.file_sharing_id == "") {
            file_transfer.file_sharing_id = Xmpp.random_uuid();
        }

        // Keep the local sent transfer source usable without persisting the
        // aesgcm fragment. This source is not announced on the wire for
        // encrypted sends.
        string sfs_url = strip_encrypted_url_secret(send_data.url_down);
        debug("http-files: derived transport url for SFS sources=%s", sanitize_url_for_log(sfs_url));
        file_transfer.add_sfs_source(new Xep.StatelessFileSharing.HttpSource() { url = sfs_url });

        return get_body_url_message_encryption(file_transfer.encryption, send_data.encrypt_message);
    }

    private static void set_legacy_aesgcm_body_url(HttpFileSendData send_data) {
        EncryptedHttpFileSendData enc_data = (EncryptedHttpFileSendData) send_data;
        string iv_hex = "";
        foreach (uint8 b in enc_data.iv) iv_hex += "%02x".printf(b);
        string key_hex = "";
        foreach (uint8 b in enc_data.key) key_hex += "%02x".printf(b);

        string path_part = send_data.url_down;
        if (path_part.has_prefix("https://")) {
            path_part = path_part.substring("https://".length);
        } else if (path_part.has_prefix("http://")) {
            path_part = path_part.substring("http://".length);
        }

        send_data.url_down = "aesgcm://%s#%s%s".printf(path_part, iv_hex, key_hex);
    }

    private static string strip_encrypted_url_secret(string url) {
        string sfs_url = url;
        if (sfs_url.has_prefix("aesgcm://")) {
            sfs_url = "https://" + sfs_url.substring("aesgcm://".length);
        }
        int fragment_index = sfs_url.index_of("#");
        if (fragment_index >= 0) {
            sfs_url = sfs_url.substring(0, fragment_index);
        }
        return sfs_url;
    }

    private static void throw_if_transfer_cancelled(FileTransfer file_transfer) throws FileSendError {
        if (file_transfer.cancellable.is_cancelled()) {
            throw new FileSendError.UPLOAD_FAILED("File transfer was cancelled");
        }
    }

    public async bool can_send(Conversation conversation, FileTransfer file_transfer) {
        long? max_file_size = get_max_file_size(conversation.account);
        if (max_file_size == null) return false;
        if (!has_safe_encrypted_groupchat_send_target(conversation, file_transfer)) return false;

        return can_send_file_size_with_limit(file_transfer.encryption, file_transfer.size, (!) max_file_size);
    }

    public async long get_file_size_limit(Conversation conversation) {
        long? max_size = get_max_file_size(conversation.account);
        if (max_size != null) {
            return max_size;
        }
        return -1;
    }

    private long? get_max_file_size(Account account) {
        lock (max_file_sizes) {
            return max_file_sizes[account];
        }
    }

    public async bool can_encrypt(Conversation conversation, FileTransfer file_transfer) {
        // PGP file encryption is handled by PgpFileEncryptor (GPG-encrypted .pgp files)
        // for interoperability with other clients (Monocles, Conversations, etc.)
        return can_encrypt_transfer_payload(file_transfer.encryption);
    }

    private bool has_safe_encrypted_groupchat_send_target(Conversation conversation, FileTransfer file_transfer) {
        if (file_transfer.encryption != Encryption.OMEMO) return true;

        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            warning("http-files: refusing OMEMO file upload for private MUC PM %s", conversation.counterpart.to_string());
            return false;
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return true;

        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (!muc_manager.has_live_private_room_features(conversation.account, conversation.counterpart)) {
            warning("http-files: refusing OMEMO file upload for MUC %s without live private-room features", conversation.counterpart.to_string());
            return false;
        }

        if (!muc_manager.has_complete_private_muc_affiliation_snapshot(conversation.account, conversation.counterpart)) {
            warning("http-files: refusing OMEMO file upload for private MUC %s without a complete member/admin/owner list", conversation.counterpart.to_string());
            return false;
        }

        Gee.List<Jid>? members = muc_manager.get_private_muc_member_affiliation_snapshot(conversation.account, conversation.counterpart);
        if (members == null || !has_non_self_member((!) members, conversation.account.bare_jid)) {
            warning("http-files: refusing OMEMO file upload for private MUC %s without non-self members", conversation.counterpart.to_string());
            return false;
        }
        return true;
    }

    private static bool has_non_self_member(Gee.List<Jid> members, Jid own_jid) {
        foreach (Jid member in members) {
            if (!member.equals_bare(own_jid)) return true;
        }
        return false;
    }

    public async bool is_upload_available(Conversation conversation) {
        lock (max_file_sizes) {
            return max_file_sizes.has_key(conversation.account);
        }
    }

#if !SOUP_3_0
    private static void transfer_more_bytes(InputStream stream, Soup.MessageBody body) {
        uint8[] bytes = new uint8[4096];
        ssize_t read = stream.read(bytes);
        if (read == 0) {
            body.complete();
            return;
        }
        bytes.length = (int)read;
        body.append_buffer(new Soup.Buffer.take(bytes));
    }
#endif

    private async void upload(FileTransfer file_transfer, HttpFileSendData file_send_data, FileMeta file_meta) throws FileSendError {
        Xmpp.XmppStream? stream = stream_interactor.get_stream(file_transfer.account);
        throw_if_upload_stream_unavailable(stream != null);

        if (file_transfer.phase != FileTransfer.Phase.UPLOADING) {
            file_transfer.set_transfer_phase(FileTransfer.Phase.UPLOADING);
        }
        file_transfer.phase_total_bytes = file_meta.size;

        yield ensure_soup_context();
        Soup.Session session = (Soup.Session) session_pool.get_session(file_transfer.account);

        validate_upload_url(file_send_data.url_up);

        InputStream upload_stream = file_transfer.input_stream;
        bool encrypt_upload_payload = file_send_data is EncryptedHttpFileSendData;
        int64 upload_size = get_upload_request_size(encrypt_upload_payload, file_meta);

        if (encrypt_upload_payload) {
            var enc_data = (EncryptedHttpFileSendData) file_send_data;
            try {
                var cipher = new SymmetricCipher("AES256-GCM");
                cipher.set_key(enc_data.key);
                cipher.set_iv(enc_data.iv);
                /* Always include the 16-byte GCM auth tag so both ESFS and
                 * legacy aesgcm:// receivers can decrypt the file correctly.
                 * The ESFS receiver tries with-tag first, then falls back to tag-less. */
                int tag_len = AES_GCM_AUTH_TAG_BYTES;
                var encrypter = new SymmetricCipherEncrypter((owned) cipher, tag_len);
                var cis = new ConverterInputStream(upload_stream, encrypter);
                cis.close_base_stream = false;
                upload_stream = cis;
            } catch (Crypto.Error e) {
                throw new FileSendError.UPLOAD_FAILED("Encryption setup failed: %s".printf(e.message));
            }
        }

        yield send_upload_request(session, db, file_transfer, file_send_data, file_meta, upload_stream, upload_size);
    }

    internal static async void send_upload_request(Soup.Session session, Database? db, FileTransfer file_transfer, HttpFileSendData file_send_data, FileMeta file_meta, InputStream upload_stream, int64 upload_size) throws FileSendError {
        Soup.Message put_message = create_upload_message(file_send_data.url_up);

#if SOUP_3_0
        if (db != null) {
            Database certificate_db = (!) db;
            string transfer_host = "";
            try {
                transfer_host = Uri.parse(file_send_data.url_up, UriFlags.NONE).get_host();
            } catch (GLib.Error e) {
                warning("Failed to parse URI: %s", e.message);
            }
            put_message.accept_certificate.connect((peer_cert, errors) => { return ConnectionManager.on_invalid_certificate(transfer_host, peer_cert, errors, certificate_db); });
        }
        put_message.set_request_body(file_meta.mime_type, upload_stream, (ssize_t) upload_size);
#else

        put_message.request_headers.set_content_type(file_meta.mime_type, null);
        put_message.request_headers.set_content_length(upload_size);
        put_message.request_body.set_accumulate(false);
        put_message.wrote_headers.connect(() => transfer_more_bytes(upload_stream, put_message.request_body));
        put_message.wrote_chunk.connect(() => transfer_more_bytes(upload_stream, put_message.request_body));
#endif
        foreach (var entry in file_send_data.headers.entries) {
            put_message.request_headers.append(entry.key, entry.value);
        }
        try {
            debug("http-files: uploading via PUT %s (%lld bytes)", sanitize_url_for_log(file_send_data.url_up), (int64) upload_size);
#if SOUP_3_0
            yield session.send_async(put_message, GLib.Priority.LOW, file_transfer.cancellable);
#else
            yield session.send_async(put_message, file_transfer.cancellable);
#endif
            if (put_message.status_code < 200 || put_message.status_code >= 300) {
                throw new FileSendError.UPLOAD_FAILED("HTTP status code %s".printf(put_message.status_code.to_string()));
            }
            debug("http-files: upload finished status=%u", put_message.status_code);
        } catch (GLib.Error e) {
            throw new FileSendError.UPLOAD_FAILED("HTTP upload error: %s".printf(e.message));
        }
    }

    internal static void validate_upload_url(string url_up) throws FileSendError {
        /* GLib.Uri accepts some malformed authority forms that libsoup rejects.
         * Validate the network URI contract before constructing Soup.Message. */
        if (!HttpFileUrl.is_valid_network_url(url_up)) {
            throw new FileSendError.UPLOAD_FAILED(
                "Invalid upload URL: HTTP(S) URL with a non-empty host required");
        }
    }

    internal static void validate_upload_slot_urls(string url_down, string url_up)
            throws FileSendError {
        Soup.Message? get_probe = HttpFileUrl.create_message("GET", url_down);
        Soup.Message? put_probe = HttpFileUrl.create_message("PUT", url_up);
        if (get_probe == null || put_probe == null) {
            throw new FileSendError.UPLOAD_FAILED(
                "Invalid upload slot URL: libsoup rejected the HTTP(S) URL");
        }
    }

    internal static Soup.Message create_upload_message(string url_up) throws FileSendError {
        validate_upload_url(url_up);
        Soup.Message? message = HttpFileUrl.create_message("PUT", url_up);
        if (message == null) {
            throw new FileSendError.UPLOAD_FAILED(
                "Invalid upload URL: libsoup rejected the HTTP(S) URL");
        }
        return (!) message;
    }

    public static string sanitize_url_for_log(string? url) {
        if (url == null) return "(null)";
        string s = url;
        int hash = s.index_of("#");
        if (hash >= 0) s = s.substring(0, hash) + "#...";
        // Avoid spewing huge query strings in logs.
        int q = s.index_of("?");
        if (q >= 0 && q < s.length) {
            s = s.substring(0, q) + "?...";
        }
        return s;
    }

    internal static bool should_attach_sfs_metadata(Entities.Message message) {
        return message.encryption == Encryption.NONE;
    }

    internal static bool should_send_as_sfs(Encryption transfer_encryption, bool can_reference_element) {
        return transfer_encryption == Encryption.NONE && can_reference_element;
    }

    internal static bool can_encrypt_transfer_payload(Encryption transfer_encryption) {
        return transfer_encryption != Encryption.NONE && transfer_encryption != Encryption.PGP;
    }

    internal static bool should_encrypt_upload_payload(Encryption transfer_encryption, FileMeta file_meta) {
        return transfer_encryption != Encryption.NONE && !file_meta.upload_payload_is_encrypted;
    }

    internal static int64 get_upload_slot_size(Encryption transfer_encryption, FileMeta file_meta) {
        return get_upload_request_size(should_encrypt_upload_payload(transfer_encryption, file_meta), file_meta);
    }

    internal static int64 get_upload_request_size(bool encrypt_upload_payload, FileMeta file_meta) {
        return encrypt_upload_payload ? file_meta.size + AES_GCM_AUTH_TAG_BYTES : file_meta.size;
    }

    internal static int64 get_can_send_upload_size(Encryption transfer_encryption, int64 file_size) {
        if (can_encrypt_transfer_payload(transfer_encryption)) {
            return file_size + AES_GCM_AUTH_TAG_BYTES;
        }
        return file_size;
    }

    internal static bool is_upload_request_size_within_limit(int64 upload_size, long max_file_size) {
        if (upload_size < 0 || max_file_size <= 0) return false;
        return upload_size <= max_file_size;
    }

    internal static bool can_send_file_size_with_limit(Encryption transfer_encryption, int64 file_size, long max_file_size) {
        if (file_size < 0 || max_file_size <= 0) return false;
        int64 upload_size = get_can_send_upload_size(transfer_encryption, file_size);
        if (transfer_encryption == Encryption.PGP) {
            return upload_size < max_file_size;
        }
        return is_upload_request_size_within_limit(upload_size, max_file_size);
    }

    internal static void throw_if_upload_stream_unavailable(bool stream_available) throws FileSendError {
        if (!stream_available) {
            throw new FileSendError.UPLOAD_FAILED("No stream available for HTTP upload");
        }
    }

    internal static Encryption get_body_url_message_encryption(Encryption transfer_encryption, bool encrypt_message) {
        if (!encrypt_message) return Encryption.NONE;
        return transfer_encryption;
    }

    private void on_stream_negotiated(Account account, XmppStream stream) {
        stream_interactor.module_manager.get_module<Xmpp.Xep.HttpFileUpload.Module>(account, Xmpp.Xep.HttpFileUpload.Module.IDENTITY).feature_available.connect((stream, max_file_size) => {
            lock (max_file_sizes) {
                max_file_sizes[account] = max_file_size;
            }
            upload_available(account);
        });
    }

    internal static bool apply_file_transfer_stanza_metadata(Entities.Message message, Xmpp.MessageStanza message_stanza, FileTransfer file_transfer) {
        bool attached_sfs_metadata = false;
        // NOTE: Encrypted HTTP file sends keep the URL and metadata in the encrypted body.
        // Outer SFS/OOB metadata would leak cleartext file-transfer details.
        // A copied body URL also has a local download record. On an offline
        // retry that record must not turn the body-only announcement into an
        // SFS share without sources, which would hide the usable URL at receivers.
        bool body_url_only = file_transfer.info != null &&
            file_transfer.info.has_prefix("url:") && file_transfer.sfs_sources.is_empty;
        if (should_attach_sfs_metadata(message) && !body_url_only) {
            Xep.StatelessFileSharing.set_sfs_element(message_stanza, file_transfer.file_sharing_id, file_transfer.file_metadata, file_transfer.sfs_sources);
            attached_sfs_metadata = true;
        }

        if (file_transfer.is_sticker && file_transfer.sticker_pack_id != null) {
            var sticker = new Xmpp.Xep.Stickers.StickerReference();
            sticker.pack_id = file_transfer.sticker_pack_id;
            // Only include jid/node if this sticker pack is not from our own PEP node
            if (file_transfer.sticker_pack_jid != null) sticker.jid = file_transfer.sticker_pack_jid;
            if (file_transfer.sticker_pack_node != null) sticker.node = file_transfer.sticker_pack_node;
            Xmpp.Xep.Stickers.set_sticker(message_stanza, sticker);
        }

        Xep.MessageProcessingHints.set_message_hint(message_stanza, Xep.MessageProcessingHints.HINT_STORE);
        return attached_sfs_metadata;
    }

    private void check_add_sfs_element(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation) {
        FileTransfer? file_transfer = stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY).get_file_by_message_id(message.id, conversation);
        if (file_transfer == null) return;

        apply_file_transfer_stanza_metadata(message, message_stanza, file_transfer);
    }

    public int get_id() { return 0; }

    public float get_priority() { return 100; }
}

}
