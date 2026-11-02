using Gdk;
using Gee;

using Xmpp;
using Xmpp.Xep;
using Dino.Entities;

public class Dino.StatelessFileSharing : StreamInteractionModule, Object {
    public static ModuleIdentity<StatelessFileSharing> IDENTITY = new ModuleIdentity<StatelessFileSharing>("sfs");
    public string id { get { return IDENTITY.id; } }

    public const int SFS_PROVIDER_ID = 2;
    private const int64 AUTO_DOWNLOAD_MAX_BYTES = 5000000;
    private const int MAX_PENDING_SOURCE_MESSAGES_PER_CONVERSATION = 64;
    private const int MAX_PENDING_SOURCE_ATTACHMENTS_PER_MESSAGE = 8;

    private HashMap<Conversation, HashMap<string, ArrayList<PendingSourceAttachment>>> pending_source_attachments =
            new HashMap<Conversation, HashMap<string, ArrayList<PendingSourceAttachment>>>(Conversation.hash_func, Conversation.equals_func);

    public StreamInteractor stream_interactor {
        owned get { return Application.get_default().stream_interactor; }
        private set { }
    }

    public FileManager file_manager {
        owned get { return stream_interactor.get_module<FileManager>(FileManager.IDENTITY); }
        private set { }
    }

    public Database db {
        owned get { return Application.get_default().db; }
        private set { }
    }

    private StatelessFileSharing(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;

        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(new ReceivedMessageListener(this));
    }

    public static void start(StreamInteractor stream_interactor, Database db) {
        StatelessFileSharing m = new StatelessFileSharing(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    public async void create_file_transfer(Conversation conversation, Message message, string? file_sharing_id, Xep.FileMetadataElement.FileMetadata metadata, Gee.List<Xep.StatelessFileSharing.Source>? sources, Xmpp.Xep.Stickers.StickerReference? sticker) {
        debug("SFS: create transfer conversation=%s message_id=%d stanza_id=%s server_id=%s file_id=%s from=%s mime=%s size=%lld sources=%d",
                conversation.counterpart.to_string(), message.id, message.stanza_id ?? "(none)", message.server_id ?? "(none)",
                file_sharing_id ?? "(none)", message.from != null ? message.from.to_string() : "(none)",
                metadata.mime_type ?? "(none)", metadata.size, sources != null ? sources.size : 0);

        FileTransfer file_transfer = new FileTransfer();
        file_transfer.file_sharing_id = file_sharing_id;
        file_transfer.account = message.account;
        file_transfer.counterpart = message.counterpart;
        file_transfer.ourpart = message.ourpart;
        file_transfer.direction = message.direction;
        file_transfer.time = message.time;
        file_transfer.local_time = message.local_time;
        file_transfer.provider = SFS_PROVIDER_ID;
        file_transfer.encryption = message.encryption;
        file_transfer.encryption_protocol = message.encryption_protocol;
        file_transfer.file_metadata = metadata;
        file_transfer.info = message.id.to_string();
        file_transfer.message_db_id = message.id;
        if (sources != null) {
            file_transfer.sfs_sources = sources;
        }

        if (sticker != null) {
            file_transfer.is_sticker = true;
            file_transfer.sticker_pack_id = sticker.pack_id;
            file_transfer.sticker_pack_jid = sticker.jid;
            file_transfer.sticker_pack_node = sticker.node;
        }

        stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY).add_file(file_transfer);

        conversation.last_active = file_transfer.time;
        file_manager.received_file(file_transfer, conversation);
        replay_pending_sources_for_transfer(conversation, message, file_transfer);

        // SFS sources may arrive directly with the message. Keep the same small/trusted auto-download
        // path that later source attachments use.
        if (file_manager.is_sender_trustworthy(file_transfer, conversation) &&
                file_transfer.is_auto_download_candidate(SFS_PROVIDER_ID, AUTO_DOWNLOAD_MAX_BYTES)) {
            file_manager.auto_download_file.begin(file_transfer);
        }
    }

    public void on_received_sources(Jid from, Conversation conversation, string attach_to_message_id, string? attach_to_file_id, Gee.List<Xep.StatelessFileSharing.Source> sources) {
        Message? message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_referencing_id(attach_to_message_id, conversation);
        if (message == null) {
            cache_pending_sources(from, conversation, attach_to_message_id, attach_to_file_id, sources);
            debug("SFS: cached sources for unknown message conversation=%s attach_to=%s file_id=%s from=%s sources=%d",
                    conversation.counterpart.to_string(), attach_to_message_id, attach_to_file_id ?? "(none)",
                    from.to_string(), sources != null ? sources.size : 0);
            return;
        }

        if (!apply_sources_to_message(from, conversation, message, attach_to_message_id, attach_to_file_id, sources)) {
            cache_pending_sources(from, conversation, attach_to_message_id, attach_to_file_id, sources);
        }
    }

    private bool apply_sources_to_message(Jid from, Conversation conversation, Message message, string attach_to_message_id, string? attach_to_file_id, Gee.List<Xep.StatelessFileSharing.Source> sources) {
        FileTransfer? file_transfer = null;
        if (attach_to_file_id != null) {
            file_transfer = stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY).get_files_by_message_and_file_id(message.id, attach_to_file_id, conversation);
        } else {
            file_transfer = stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY).get_file_by_message_id(message.id, conversation);
        }
        if (file_transfer == null) {
            debug("SFS: cached sources for message without transfer conversation=%s message_id=%d attach_to=%s file_id=%s from=%s sources=%d",
                    conversation.counterpart.to_string(), message.id, attach_to_message_id, attach_to_file_id ?? "(none)",
                    from.to_string(), sources != null ? sources.size : 0);
            return false;
        }

        apply_sources_to_transfer(from, conversation, attach_to_message_id, attach_to_file_id, sources, file_transfer);
        return true;
    }

    private void apply_sources_to_transfer(Jid from, Conversation conversation, string attach_to_message_id, string? attach_to_file_id, Gee.List<Xep.StatelessFileSharing.Source> sources, FileTransfer file_transfer) {
        // "If no <hash/> is provided or the <hash/> elements provided use unsupported algorithms, receiving clients MUST ignore
        // any attached sources from other senders and only obtain the file from the sources announced by the original sender."
        // For now, we only allow the original sender for attached sources.
        if (!from.equals(file_transfer.from)) {
            warning("SFS: ignoring sources from non-original sender conversation=%s attach_to=%s file_id=%s source_from=%s original_from=%s sources=%d",
                    conversation.counterpart.to_string(), attach_to_message_id, attach_to_file_id ?? "(none)",
                    from.to_string(), file_transfer.from != null ? file_transfer.from.to_string() : "(none)",
                    sources != null ? sources.size : 0);
            return;
        }

        foreach (var source in sources) {
            file_transfer.add_sfs_source(source);
        }

        if (file_manager.is_sender_trustworthy(file_transfer, conversation) &&
                file_transfer.is_auto_download_candidate(SFS_PROVIDER_ID, AUTO_DOWNLOAD_MAX_BYTES)) {
            file_manager.auto_download_file.begin(file_transfer);
        }
    }

    private void cache_pending_sources(Jid from, Conversation conversation, string attach_to_message_id, string? attach_to_file_id, Gee.List<Xep.StatelessFileSharing.Source> sources) {
        if (sources == null || sources.is_empty) return;

        HashMap<string, ArrayList<PendingSourceAttachment>>? pending_by_message = pending_source_attachments[conversation];
        if (pending_by_message == null) {
            pending_by_message = new HashMap<string, ArrayList<PendingSourceAttachment>>();
            pending_source_attachments[conversation] = (!) pending_by_message;
        }

        ArrayList<PendingSourceAttachment>? attachments = ((!) pending_by_message)[attach_to_message_id];
        if (attachments == null) {
            if (((!) pending_by_message).size >= MAX_PENDING_SOURCE_MESSAGES_PER_CONVERSATION) {
                warning("SFS: dropping pending sources because cache is full conversation=%s attach_to=%s file_id=%s from=%s sources=%d",
                        conversation.counterpart.to_string(), attach_to_message_id, attach_to_file_id ?? "(none)",
                        from.to_string(), sources.size);
                return;
            }
            attachments = new ArrayList<PendingSourceAttachment>();
            ((!) pending_by_message)[attach_to_message_id] = (!) attachments;
        } else if (((!) attachments).size >= MAX_PENDING_SOURCE_ATTACHMENTS_PER_MESSAGE) {
            warning("SFS: dropping pending sources because message cache entry is full conversation=%s attach_to=%s file_id=%s from=%s sources=%d",
                    conversation.counterpart.to_string(), attach_to_message_id, attach_to_file_id ?? "(none)",
                    from.to_string(), sources.size);
            return;
        }

        ((!) attachments).add(new PendingSourceAttachment(from, attach_to_file_id, sources));
    }

    private void replay_pending_sources_for_transfer(Conversation conversation, Message message, FileTransfer file_transfer) {
        HashMap<string, ArrayList<PendingSourceAttachment>>? pending_by_message = pending_source_attachments[conversation];
        if (pending_by_message == null) return;

        ArrayList<string> reference_ids = new ArrayList<string>();
        if (message.stanza_id != null && message.stanza_id != "") reference_ids.add((!) message.stanza_id);
        if (message.server_id != null && message.server_id != "" && !reference_ids.contains((!) message.server_id)) reference_ids.add((!) message.server_id);

        foreach (string reference_id in reference_ids) {
            ArrayList<PendingSourceAttachment>? attachments = ((!) pending_by_message)[reference_id];
            if (attachments == null) continue;

            ArrayList<PendingSourceAttachment> still_pending = new ArrayList<PendingSourceAttachment>();
            foreach (PendingSourceAttachment attachment in (!) attachments) {
                if (attachment.file_id != null && file_transfer.file_sharing_id != attachment.file_id) {
                    still_pending.add(attachment);
                    continue;
                }
                apply_sources_to_transfer(attachment.from, conversation, reference_id, attachment.file_id, attachment.sources, file_transfer);
            }

            if (still_pending.is_empty) {
                ((!) pending_by_message).unset(reference_id);
            } else {
                ((!) pending_by_message)[reference_id] = still_pending;
            }
        }

        if (((!) pending_by_message).is_empty) {
            pending_source_attachments.unset(conversation);
        }
    }

    private class PendingSourceAttachment : Object {
        public Jid from { get; private set; }
        public string? file_id { get; private set; }
        public Gee.List<Xep.StatelessFileSharing.Source> sources { get; private set; }

        public PendingSourceAttachment(Jid from, string? file_id, Gee.List<Xep.StatelessFileSharing.Source> sources) {
            this.from = from;
            this.file_id = file_id;
            this.sources = new ArrayList<Xep.StatelessFileSharing.Source>(Xep.StatelessFileSharing.Source.equals_func);
            this.sources.add_all(sources);
        }
    }

    private class ReceivedMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "STORE" };
        public override string action_group { get { return "MESSAGE_REINTERPRETING"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StatelessFileSharing outer;
        private StreamInteractor stream_interactor;

        public ReceivedMessageListener(StatelessFileSharing outer) {
            this.outer = outer;
            this.stream_interactor = outer.stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            Gee.List<Xep.StatelessFileSharing.FileShare> file_shares = Xep.StatelessFileSharing.get_attachment_file_shares(stanza);
            if (file_shares != null) {
                Xmpp.Xep.Stickers.StickerReference? sticker = Xmpp.Xep.Stickers.get_sticker(stanza);

                // Interop: accept file shares even if hashes are missing/unsupported.
                // Hashes are used for verification and for accepting third-party sources,
                // but the file share itself is still useful to display and download from
                // the original sender.
                foreach (Xep.StatelessFileSharing.FileShare file_share in file_shares) {
                    outer.create_file_transfer.begin(conversation, message, file_share.id, file_share.metadata, file_share.sources, sticker);
                }
                // Emoji resources are inline replacements for body text. Even
                // a mixed message with ordinary attachments must retain that text.
                return Xep.MessageMarkup.get_emoji_hashes(stanza).is_empty;
            }

            var source_attachments = Xep.StatelessFileSharing.get_source_attachments(stanza);
            if (source_attachments != null) {
                foreach (var source_attachment in source_attachments) {
                    if (source_attachment.sources == null || source_attachment.sources.is_empty) continue;
                    outer.on_received_sources(stanza.from, conversation, source_attachment.to_message_id, source_attachment.to_file_transfer_id, source_attachment.sources);
                }
                return Xep.MessageMarkup.get_emoji_hashes(stanza).is_empty;
            }

            // Don't process messages that are fallback for legacy clients
            if (!Xep.MessageMarkup.get_emoji_hashes(stanza).is_empty) return false;
            if (Xep.StatelessFileSharing.is_sfs_fallback_message(stanza)) {
                return true;
            }

            return false;
        }
    }
}
