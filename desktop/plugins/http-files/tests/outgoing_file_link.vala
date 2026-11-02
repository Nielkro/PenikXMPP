using Dino.Entities;
using Xmpp;

namespace Dino.Plugins.HttpFiles.Test {

class OutgoingFileLinkTest : Gee.TestCase {
    public OutgoingFileLinkTest() {
        base("OutgoingFileLink");
        add_test("pasted_encrypted_video_becomes_one_persistent_file", test_direct);
        add_test("pasted_encrypted_video_in_groupchat", test_group);
        add_test("pasted_encrypted_video_in_group_private_message", test_group_private);
        add_test("offline_link_retry_preserves_body_only_file_announcement", test_offline_retry);
        add_test("cancel_metadata_does_not_start_a_download", test_cancel);
        add_test("text_edits_hidden_and_other_conversations_are_untouched", test_ignored);
        add_test("existing_upload_is_not_registered_twice", test_existing);
        add_test("shutdown_disconnects_outgoing_handler", test_shutdown);
    }

    void test_direct() { check_file(Conversation.Type.CHAT); }
    void test_group() { check_file(Conversation.Type.GROUPCHAT); }
    void test_group_private() { check_file(Conversation.Type.GROUPCHAT_PM); }

    void test_offline_retry() {
        LinkContext? context = null;
        try {
            context = new LinkContext(Conversation.Type.CHAT);
            var c = (!) context;
            foreach (var encryption in new Encryption[] { Encryption.NONE, Encryption.OMEMO, Encryption.PGP }) {
                var message = c.message(LinkContext.URL);
                message.encryption = encryption;
                c.processor.send_xmpp_message(message, c.conversation);
                fail_if(message.marked != Message.Marked.UNSENT, "offline message must remain queued");
                c.processor.message_sent(message, c.conversation);
                c.finish_metadata();
                fail_if(c.storage.get_file_by_message_id(message.id, c.conversation) == null,
                    "queued copied link must already have its local file representation");

                // On reconnect the sender rebuilds the stanza after the local
                // FileTransfer exists. Exercise the actual sender signal hook.
                var stanza = new MessageStanza(message.stanza_id);
                stanza.body = message.body;
                c.processor.build_message_stanza(message, stanza, c.conversation);
                fail_if_not_eq_str(LinkContext.URL, stanza.body ?? "", "retry must preserve the encrypted URL and key");
                fail_if(Xmpp.Xep.StatelessFileSharing.get_file_shares(stanza) != null,
                    "local copied-link representation must not add a source-less SFS announcement on retry");
                fail_if(Xmpp.Xep.StatelessFileSharing.get_source_attachments(stanza) != null,
                    "retry must not invent an SFS source attachment");
                fail_if(Xmpp.Xep.OutOfBandData.get_url_from_message(stanza) != null,
                    "retry must keep the existing body-only announcement");
            }
        } catch (Error e) {
            fail_if(true, "outgoing file retry test failed: " + e.message);
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    void check_file(Conversation.Type type) {
        LinkContext? context = null;
        try {
            context = new LinkContext(type);
            var c = (!) context;
            var message = c.message("  " + LinkContext.URL + "\n");
            c.processor.message_sent(message, c.conversation);
            c.finish_metadata();
            var items = c.store.get_n_latest(c.conversation, 10);
            fail_if_not_eq_int(1, items.size, "only the file, not its URL text, must remain visible");
            if (items.size != 1 || !(items[0] is Dino.FileItem)) {
                fail_if(true, "outgoing link must be a real FileItem");
                return;
            }
            var transfer = ((Dino.FileItem) items[0]).file_transfer;
            fail_if_not_eq_str("video.mp4", transfer.file_name);
            fail_if_not_eq_str("video/mp4", transfer.mime_type ?? "");
            fail_if_not_eq_str("url:" + LinkContext.URL, transfer.info);
            fail_if_not_eq_int(message.id, transfer.message_db_id);
            fail_if(transfer.direction != FileTransfer.DIRECTION_SENT, "pasted file must stay our own message");
            fail_if(transfer.encryption != Encryption.OMEMO, "AES-GCM payload must use existing file decryptors");
            fail_if(!transfer.is_sent_remote_download_offer(Dino.FileManager.SFS_PROVIDER_ID, Dino.FileManager.HTTP_PROVIDER_ID),
                "own remote file must offer Download instead of Upload");
            fail_if(transfer.state != FileTransfer.State.NOT_STARTED || transfer.size != 6000000,
                "large files must keep the existing automatic download limit");
            fail_if_not(c.provider.saw_file_before_metadata, "file card must exist before fetching metadata");
            c.processor.message_sent(message, c.conversation);
            fail_if_not_eq_int(1, c.provider.metadata_requests, "duplicate signal must not fetch metadata again");
            fail_if_not_eq_int(1, c.store.get_n_latest(c.conversation, 10).size);

            var reloaded = new FileTransfer.from_row(c.db,
                c.db.file_transfer.select().with(c.db.file_transfer.id, "=", transfer.id).single().row().inner,
                Dino.FileManager.get_storage_dir());
            fail_if_not_eq_int(message.id, reloaded.resolve_message_db_id());
            fail_if_not_eq_str(LinkContext.URL,
                ((HttpFileReceiveData) c.provider.get_file_receive_data(reloaded)).url,
                "reopening the chat must retain the complete encrypted download source");
        } catch (Error e) {
            fail_if(true, "outgoing file test failed: " + e.message);
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    void test_ignored() {
        LinkContext? context = null;
        try {
            context = new LinkContext(Conversation.Type.CHAT);
            var c = (!) context;
            foreach (string text in new string[] {
                    "https://example.test/video.mp4", "Look: " + LinkContext.URL,
                    LinkContext.URL + "\nanother line", "aesgcm:///video.mp4#abcd" }) {
                c.processor.message_sent(c.message(text), c.conversation);
            }
            var edited = c.message(LinkContext.URL);
            edited.edit_to = "older-message";
            c.processor.message_sent(edited, c.conversation);
            var quoted = c.message(LinkContext.URL);
            quoted.set_quoted_item(123);
            c.processor.message_sent(quoted, c.conversation);
            var received = c.message(LinkContext.URL);
            received.direction = Message.DIRECTION_RECEIVED;
            c.processor.message_sent(received, c.conversation);
            var hidden = c.message(LinkContext.URL, true);
            c.processor.message_sent(hidden, c.conversation);
            var other_chat = new Conversation(new Jid("carol@example.test"), c.account, Conversation.Type.CHAT);
            other_chat.persist(c.db);
            c.processor.message_sent(c.message(LinkContext.URL), other_chat);
            var other_account = new Account(new Jid("other@example.test"), "secret");
            other_account.persist(c.db);
            var other_account_chat = new Conversation(c.conversation.counterpart, other_account, Conversation.Type.CHAT);
            other_account_chat.persist(c.db);
            c.processor.message_sent(c.message(LinkContext.URL), other_account_chat);
            fail_if(c.db.file_transfer.select().single().row().is_present(), "ignored messages must not create transfers");
            fail_if_not_eq_int(0, c.provider.metadata_requests);
        } catch (Error e) {
            fail_if(true, "outgoing file exclusions failed: " + e.message);
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    void test_existing() {
        LinkContext? context = null;
        try {
            context = new LinkContext(Conversation.Type.CHAT);
            var c = (!) context;
            var message = c.message(LinkContext.URL);
            var meta = new Dino.FileMeta() { file_name = "video.mp4", message_db_id = message.id };
            var transfer = c.manager.create_file_transfer_from_provider_incoming(c.provider,
                "url:" + LinkContext.URL, message.from, message.time, message.local_time,
                c.conversation, new HttpFileReceiveData() { url = LinkContext.URL }, meta);
            c.storage.add_file(transfer);
            c.processor.message_sent(message, c.conversation);
            int count = 0;
            foreach (var row in c.db.file_transfer.select()) {
                fail_if(row[c.db.file_transfer.id] <= 0);
                count++;
            }
            fail_if_not_eq_int(1, count);
            fail_if_not_eq_int(0, c.provider.metadata_requests);
        } catch (Error e) {
            fail_if(true, "existing outgoing transfer test failed: " + e.message);
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    void test_shutdown() {
        LinkContext? context = null;
        try {
            context = new LinkContext(Conversation.Type.CHAT);
            var c = (!) context;
            c.provider.shutdown();
            c.processor.message_sent(c.message(LinkContext.URL), c.conversation);
            fail_if_not_eq_int(0, c.provider.metadata_requests);
            fail_if_not(c.store.get_n_latest(c.conversation, 1)[0] is Dino.MessageItem);
        } catch (Error e) {
            fail_if(true, "provider shutdown test failed: " + e.message);
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    void test_cancel() {
        LinkContext? context = null;
        try {
            context = new LinkContext(Conversation.Type.CHAT);
            var c = (!) context;
            c.provider.cancel_metadata = true;
            c.processor.message_sent(c.message(LinkContext.URL), c.conversation);
            c.finish_metadata();
            var transfer = ((Dino.FileItem) c.store.get_n_latest(c.conversation, 1)[0]).file_transfer;
            fail_if_not(c.provider.saw_preparing, "metadata request must be visible and cancellable");
            fail_if_not(transfer.cancellable.is_cancelled());
            fail_if(transfer.state != FileTransfer.State.NOT_STARTED || transfer.next_retry_time != 0,
                "cancelled metadata must not restart or schedule an automatic download");
            fail_if_not_eq_int(1, c.store.get_n_latest(c.conversation, 10).size);
        } catch (Error e) {
            fail_if(true, "metadata cancellation test failed: " + e.message);
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private class LinkProvider : FileProvider {
        public int metadata_requests = 0;
        public bool saw_file_before_metadata = false;
        public bool saw_preparing = false;
        public bool cancel_metadata = false;
        public FileTransfer? last_transfer = null;
        private Dino.ContentItemStore store;
        private Conversation conversation;

        public LinkProvider(Dino.StreamInteractor interactor, Dino.Database db, Conversation conversation) {
            base(interactor, db);
            this.store = interactor.get_module<Dino.ContentItemStore>(Dino.ContentItemStore.IDENTITY);
            this.conversation = conversation;
        }

        public override async Dino.FileMeta get_meta_info(FileTransfer transfer, Dino.FileReceiveData data,
                Dino.FileMeta meta) throws Dino.FileReceiveError, IOError {
            metadata_requests++;
            last_transfer = transfer;
            var items = store.get_n_latest(conversation, 1);
            saw_file_before_metadata = items.size == 1 && items[0] is Dino.FileItem;
            saw_preparing = transfer.phase == FileTransfer.Phase.PREPARING;
            // No network, no automatic payload download. This exercises the
            // production registration, metadata and size-limit path.
            meta.size = cancel_metadata ? 1024 : 6000000;
            if (cancel_metadata) transfer.cancellable.cancel();
            return meta;
        }
    }

    private class LinkContext : Object {
        public const string URL = "aesgcm://upload.example.test/video.mp4#00112233445566778899aabb000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        public Dino.Database db;
        public Account account;
        public Conversation conversation;
        public Dino.MessageProcessor processor;
        public Dino.ContentItemStore store;
        public Dino.FileTransferStorage storage;
        public Dino.FileManager manager;
        public LinkProvider provider;
        private HttpFileSender sender;
        private string db_path;

        public LinkContext(Conversation.Type type) throws Error {
            db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-outgoing-link-" + Uuid.string_random() + ".db");
            db = new Dino.Database(db_path, "outgoing-link-test");
            var interactor = new Dino.StreamInteractor.for_tests(db);
            Dino.MessageStorage.start(interactor, db);
            Dino.FileTransferStorage.start(interactor, db);
            Dino.MessageProcessor.start(interactor, db);
            Dino.PresenceManager.start(interactor, db);
            Dino.Calls.start(interactor, db);
            Dino.ConversationManager.start(interactor, db);
            Dino.MucManager.start(interactor, db);
            Dino.FileManager.start(interactor, db, new Dino.Security.FileEncryption("outgoing-link-test"));
            Dino.ContentItemStore.start(interactor, db);
            processor = interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            store = interactor.get_module<Dino.ContentItemStore>(Dino.ContentItemStore.IDENTITY);
            storage = interactor.get_module<Dino.FileTransferStorage>(Dino.FileTransferStorage.IDENTITY);
            manager = interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            account = new Account(new Jid("alice@example.test"), "secret");
            account.persist(db);
            conversation = new Conversation(new Jid(type == Conversation.Type.GROUPCHAT
                ? "room@conference.example.test" : (type == Conversation.Type.GROUPCHAT_PM
                    ? "room@conference.example.test/bob" : "bob@example.test")), account, type);
            conversation.persist(db);
            provider = new LinkProvider(interactor, db, conversation);
            manager.add_provider(provider);
            sender = new HttpFileSender(interactor, db);
        }

        public Message message(string body, bool hidden = false) {
            var message = processor.create_out_message(body, conversation);
            store.insert_message(message, conversation, hidden);
            return message;
        }

        public void close() {
            finish_metadata();
            provider.shutdown();
            sender.shutdown();
            db.close();
            FileUtils.remove(db_path);
        }

        public void finish_metadata() {
            bool timed_out = false;
            uint timeout = Timeout.add_seconds(3, () => {
                timed_out = true;
                return Source.REMOVE;
            });
            while (provider.last_transfer != null &&
                    provider.last_transfer.phase == FileTransfer.Phase.PREPARING && !timed_out) {
                MainContext.default().iteration(true);
            }
            if (!timed_out) Source.remove(timeout);
            fail_if(timed_out, "metadata completion did not settle before closing the test database");
        }
    }
}
}
