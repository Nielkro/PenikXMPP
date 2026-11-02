using Xmpp;
using Gee;
using Qlite;

using Dino.Entities;

namespace Dino {

    public class FileTransferStorage : StreamInteractionModule, Object {
        public static ModuleIdentity<FileTransferStorage> IDENTITY = new ModuleIdentity<FileTransferStorage>("file_store");
        public string id { get { return IDENTITY.id; } }

        private StreamInteractor stream_interactor;
        private Database db;

        private WeakMap<int, FileTransfer> files_by_db_id = new WeakMap<int, FileTransfer>();
        private WeakMap<int, FileTransfer> files_by_message_id = new WeakMap<int, FileTransfer>();
        private WeakMap<string, FileTransfer> files_by_message_and_file_id = new WeakMap<string, FileTransfer>();
        private WeakMap<int, FileTransfer> observed_message_relation_files =
            new WeakMap<int, FileTransfer>();

        public static void start(StreamInteractor stream_interactor, Database db) {
            FileTransferStorage m = new FileTransferStorage(stream_interactor, db);
            stream_interactor.add_module(m);
        }

        private FileTransferStorage(StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.db = db;
            recover_interrupted_transfers_after_restart();
        }

        private void recover_interrupted_transfers_after_restart() {
            db.file_transfer.update()
                .with(db.file_transfer.state, "=", (int) FileTransfer.State.IN_PROGRESS)
                .set(db.file_transfer.state, (int) FileTransfer.State.FAILED)
                .perform();
        }

        public void add_file(FileTransfer file_transfer) {
            file_transfer.persist(db);
            cache_file(file_transfer);
        }

        public FileTransfer? get_file_by_id(int id, Conversation conversation) {
            FileTransfer? file_transfer = files_by_db_id[id];
            if (file_transfer != null) {
                return file_transfer;
            }

            RowOption row_option = db.file_transfer.select()
                .with(db.file_transfer.id, "=", id)
                .single()
                .row();

            return create_file_from_row_opt(row_option, conversation);
        }

        /** Load a fresh transfer identity without consulting or changing caches. */
        internal FileTransfer? get_persisted_file_by_id(int id,
                Conversation conversation) {
            RowOption row_option = db.file_transfer.select()
                .with(db.file_transfer.id, "=", id)
                .single()
                .row();
            if (!row_option.is_present()) return null;

            try {
                FileTransfer file_transfer = new FileTransfer.from_row(db,
                    row_option.inner, FileManager.get_storage_dir());
                if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                    file_transfer.ourpart = conversation.counterpart
                        .with_resource(file_transfer.ourpart.resourcepart);
                }
                return file_transfer;
            } catch (InvalidJidError e) {
                warning("Got persisted file transfer with invalid Jid: %s",
                    e.message);
            }
            return null;
        }

        // Database version 51 stores the relation independently from transport
        // info. The second query keeps older numeric-info rows readable.
        public FileTransfer? get_file_by_message_id(int id, Conversation conversation) {
            FileTransfer? file_transfer = files_by_message_id[id];
            if (file_transfer != null) {
                if (((!) file_transfer).resolve_message_db_id() == id) {
                    return file_transfer;
                }
                files_by_message_id.unset(id);
            }

            RowOption row_option = db.file_transfer.select()
                .with(db.file_transfer.message_id, "=", id)
                .single()
                .row();
            if (!row_option.is_present()) {
                foreach (int legacy_provider in new int[] {
                        FileManager.HTTP_PROVIDER_ID,
                        FileManager.SFS_PROVIDER_ID }) {
                    row_option = db.file_transfer.select()
                        .with(db.file_transfer.info, "=", id.to_string())
                        .with(db.file_transfer.message_id, "<=", 0)
                        .with(db.file_transfer.provider, "=", legacy_provider)
                        .single()
                        .row();
                    if (row_option.is_present()) break;
                }
            }

            file_transfer = create_file_from_row_opt(row_option, conversation);
            if (file_transfer != null &&
                    ((!) file_transfer).resolve_message_db_id() == id) {
                return file_transfer;
            }
            return null;
        }

        public FileTransfer? get_files_by_message_and_file_id(int message_id, string file_sharing_id, Conversation conversation) {
            string combined_identifier = message_id.to_string() + file_sharing_id;
            FileTransfer? file_transfer = files_by_message_and_file_id[combined_identifier];

            if (file_transfer != null &&
                    (((!) file_transfer).resolve_message_db_id() != message_id ||
                    ((!) file_transfer).file_sharing_id != file_sharing_id)) {
                files_by_message_and_file_id.unset(combined_identifier);
                file_transfer = null;
            }

            if (file_transfer == null) {
                RowOption row_option = db.file_transfer.select()
                        .with(db.file_transfer.message_id, "=", message_id)
                        .with(db.file_transfer.file_sharing_id, "=", file_sharing_id)
                        .single()
                        .row();

                if (!row_option.is_present()) {
                    foreach (int legacy_provider in new int[] {
                            FileManager.HTTP_PROVIDER_ID,
                            FileManager.SFS_PROVIDER_ID }) {
                        row_option = db.file_transfer.select()
                                .with(db.file_transfer.info, "=", message_id.to_string())
                                .with(db.file_transfer.message_id, "<=", 0)
                                .with(db.file_transfer.provider, "=", legacy_provider)
                                .with(db.file_transfer.file_sharing_id, "=", file_sharing_id)
                                .single()
                                .row();
                        if (row_option.is_present()) break;
                    }
                }

                file_transfer = create_file_from_row_opt(row_option, conversation);
            }

            // There can be collisions in the combined identifier, check it's the correct FileTransfer
            if (file_transfer != null &&
                    file_transfer.resolve_message_db_id() == message_id &&
                    file_transfer.file_sharing_id == file_sharing_id) {
                return file_transfer;
            }
            return (FileTransfer?)null;
        }

        public Gee.List<FileTransfer> get_scheduled_retry_files() {
            Gee.List<FileTransfer> ret = new ArrayList<FileTransfer>();
            foreach (Row row in db.file_transfer.select().with(db.file_transfer.next_retry_time, ">", (long) 0)) {
                int id = row[db.file_transfer.id];
                FileTransfer? file_transfer = files_by_db_id[id];
                if (file_transfer == null) {
                    try {
                        file_transfer = new FileTransfer.from_row(db, row, FileManager.get_storage_dir());
                        cache_file((!) file_transfer);
                    } catch (InvalidJidError e) {
                        warning("Got scheduled retry file transfer with invalid Jid: %s", e.message);
                    }
                }
                if (file_transfer != null) ret.add((!) file_transfer);
            }
            return ret;
        }

        private FileTransfer? create_file_from_row_opt(RowOption row_opt, Conversation conversation) {
            if (!row_opt.is_present()) return null;

            int file_transfer_id = row_opt.inner[db.file_transfer.id];
            FileTransfer? cached_file_transfer = files_by_db_id[file_transfer_id];
            if (cached_file_transfer != null) {
                cache_message_relation((!) cached_file_transfer);
                return cached_file_transfer;
            }

            try {
                FileTransfer file_transfer = new FileTransfer.from_row(db, row_opt.inner, FileManager.get_storage_dir());

                if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                    file_transfer.ourpart = conversation.counterpart.with_resource(file_transfer.ourpart.resourcepart);
                }

                cache_file(file_transfer);
                return file_transfer;
            } catch (InvalidJidError e) {
                warning("Got file transfer with invalid Jid: %s", e.message);
            }
            return null;
        }

        private void cache_file(FileTransfer file_transfer) {
            files_by_db_id[file_transfer.id] = file_transfer;

            cache_message_relation(file_transfer);
            observe_live_message_relation(file_transfer);
        }

        private void cache_message_relation(FileTransfer file_transfer) {
            int message_db_id = file_transfer.resolve_message_db_id();
            if (message_db_id > 0) {
                files_by_message_id[message_db_id] = file_transfer;

                if (file_transfer.file_sharing_id != null) {
                    string combined_identifier = message_db_id.to_string() + file_transfer.file_sharing_id;
                    files_by_message_and_file_id[combined_identifier] = file_transfer;
                }
            }
        }

        private void observe_live_message_relation(FileTransfer file_transfer) {
            FileTransfer? observed =
                observed_message_relation_files[file_transfer.id];
            if (observed == file_transfer) return;
            observed_message_relation_files[file_transfer.id] = file_transfer;

            file_transfer.notify["message-db-id"].connect((sender, property) => {
                cache_message_relation((FileTransfer) sender);
            });
            file_transfer.notify["info"].connect((sender, property) => {
                cache_message_relation((FileTransfer) sender);
            });
            file_transfer.notify["file-sharing-id"].connect((sender, property) => {
                cache_message_relation((FileTransfer) sender);
            });
        }
    }
}
