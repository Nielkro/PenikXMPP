using Gdk;
using Gee;

using Xmpp;
using Xmpp.Xep;
using Dino.Entities;
using Dino.Security;
// using Dino.Util;

namespace Dino {

public enum OutgoingFileSource {
    EXTERNAL_PLAINTEXT,
    DINOX_MANAGED_STORAGE
}

public class PlaintextFileLease : Object {
    public File file { get; private set; }

    public delegate void DeleteFunc(File file) throws Error;

    private string? directory;
    private DeleteFunc? delete_func;
    private bool released = false;

    internal PlaintextFileLease(File file, string? directory, owned DeleteFunc? delete_func = null) {
        this.file = file;
        this.directory = directory;
        this.delete_func = (owned) delete_func;
    }

    public void release() {
        if (released) return;
        released = true;

        string? lease_directory = directory;
        directory = null;

        string? file_error = null;
        string? directory_error = null;
        DeleteFunc? cleanup_delete_func = (owned) delete_func;
        delete_func = null;

        if (!cleanup_once(file, lease_directory, cleanup_delete_func, out file_error, out directory_error)) {
            schedule_cleanup_retry(file, lease_directory, (owned) cleanup_delete_func, 1);
        }
    }

    private static bool cleanup_once(File file, string? directory, DeleteFunc? delete_func, out string? file_error, out string? directory_error) {
        file_error = null;
        directory_error = null;

        bool file_removed = true;
        try {
            if (delete_func != null) {
                ((!) delete_func)(file);
            } else {
                file.delete(null);
            }
        } catch (IOError.NOT_FOUND e) {
        } catch (Error e) {
            file_removed = false;
            file_error = e.message;
        }

        bool directory_removed = true;
        if (directory != null && FileUtils.test((!) directory, FileTest.EXISTS) &&
                DirUtils.remove((!) directory) == -1) {
            directory_removed = false;
            directory_error = FileUtils.error_from_errno(errno).to_string();
        }

        return file_removed && directory_removed;
    }

    private static void schedule_cleanup_retry(File file, string? directory, owned DeleteFunc? delete_func, uint retry_attempt) {
        uint delay_ms = get_retry_delay_ms(retry_attempt);
        if (delay_ms == 0) return;
        DeleteFunc? retry_delete_func = (owned) delete_func;

        Timeout.add(delay_ms, () => {
            string? file_error = null;
            string? directory_error = null;
            if (!cleanup_once(file, directory, retry_delete_func, out file_error, out directory_error)) {
                uint next_attempt = retry_attempt + 1;
                if (get_retry_delay_ms(next_attempt) == 0) {
                    debug_cleanup_give_up(file, directory, retry_attempt + 1, file_error, directory_error);
                } else {
                    schedule_cleanup_retry(file, directory, (owned) retry_delete_func, next_attempt);
                }
            }
            return Source.REMOVE;
        });
    }

    private static uint get_retry_delay_ms(uint retry_attempt) {
        switch (retry_attempt) {
            case 1: return 1000;
            case 2: return 5000;
            case 3: return 15000;
            case 4: return 30000;
            case 5: return 60000;
            case 6: return 120000;
            case 7: return 180000;
            default: return 0;
        }
    }

    private static void debug_cleanup_give_up(File file, string? directory, uint attempts, string? file_error, string? directory_error) {
        debug("Giving up deleting plaintext lease file \"%s\" and directory \"%s\" after %u attempts: file=%s directory=%s",
                file.get_path() ?? file.get_uri(),
                directory ?? "(none)",
                attempts,
                file_error ?? "already removed",
                directory_error ?? "already removed");
    }
}

private class PlaintextFileLeaseInputStream : InputStream, VerifiedPlaintextMetaCarrier {
    private PlaintextFileLease lease;
    private FileInputStream inner;
    private VerifiedPlaintextMeta? verified_plaintext_meta;
    private bool closed = false;

    public PlaintextFileLeaseInputStream(PlaintextFileLease lease, VerifiedPlaintextMeta? verified_plaintext_meta = null) throws Error {
        this.lease = lease;
        this.verified_plaintext_meta = verified_plaintext_meta;
        this.inner = lease.file.read();
    }

    public VerifiedPlaintextMeta? get_verified_plaintext_meta() {
        return verified_plaintext_meta;
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        return inner.read(buffer, cancellable);
    }

    public override async ssize_t read_async(uint8[]? buffer, int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.read_async(buffer, io_priority, cancellable);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        if (closed) return true;
        closed = true;

        IOError? close_error = null;
        try {
            inner.close(cancellable);
        } catch (IOError e) {
            close_error = e;
        }

        lease.release();

        if (close_error != null) throw (!) close_error;
        return true;
    }

    public override async bool close_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (closed) return true;
        closed = true;

        IOError? close_error = null;
        try {
            yield inner.close_async(io_priority, cancellable);
        } catch (IOError e) {
            close_error = e;
        }

        lease.release();

        if (close_error != null) throw (!) close_error;
        return true;
    }
}

public class PlaintextFileLeaseTarget : Object {
    public File file { get; private set; }
    internal string? directory { get; private set; }

    private PlaintextFileLease.DeleteFunc? delete_func;

    internal PlaintextFileLeaseTarget(File file, string directory, owned PlaintextFileLease.DeleteFunc? delete_func = null) {
        this.file = file;
        this.directory = directory;
        this.delete_func = (owned) delete_func;
    }

    public InputStream open_input_stream(VerifiedPlaintextMeta? verified_plaintext_meta = null) throws Error {
        if (directory == null) {
            throw new IOError.FAILED("Plaintext lease target is already consumed");
        }

        string lease_directory = (!) directory;
        directory = null;
        var lease = new PlaintextFileLease(file, lease_directory, (owned) delete_func);
        delete_func = null;

        try {
            return new PlaintextFileLeaseInputStream(lease, verified_plaintext_meta);
        } catch (Error e) {
            lease.release();
            throw e;
        }
    }

    public void discard() {
        if (directory == null) return;

        var lease = new PlaintextFileLease(file, directory, (owned) delete_func);
        directory = null;
        delete_func = null;
        lease.release();
    }
}

private class ReceivePipelinePlan : Object {
    public FileReceiveData receive_data { get; private set; }
    public FileMeta file_meta { get; private set; }
    public FileDecryptor? file_decryptor { get; private set; }
    public bool decrypts_before_return { get; private set; }

    public ReceivePipelinePlan(FileReceiveData receive_data, FileMeta file_meta, FileDecryptor? file_decryptor) {
        this.receive_data = receive_data;
        this.file_meta = file_meta;
        this.file_decryptor = file_decryptor;
        this.decrypts_before_return = file_decryptor != null && ((!) file_decryptor).decrypts_before_return();
    }

    public FileTransfer.Phase get_store_phase() {
        return FileTransfer.receive_store_phase_for(file_decryptor != null, decrypts_before_return);
    }

    public int64 get_store_progress_total(FileTransfer file_transfer) {
        return file_decryptor == null ? file_transfer.size : -1;
    }
}

private class ReceiveDownloadStage : Object {
    public InputStream input_stream;
    public File? encrypted_download_file;
    public Binding? progress_binding;

    public ReceiveDownloadStage(InputStream input_stream, File? encrypted_download_file, Binding? progress_binding) {
        this.input_stream = input_stream;
        this.encrypted_download_file = encrypted_download_file;
        this.progress_binding = progress_binding;
    }
}

private const uint FILE_TRANSFER_STALL_CHECK_SECONDS = 5;
private const uint FILE_TRANSFER_STALL_TIMEOUT_SECONDS = 90;
private const int FILE_TRANSFER_AUTO_RETRY_MAX_ATTEMPTS = 3;
private const int64 USEC_PER_SECOND = 1000000;
private const string FILE_TRANSFER_STALL_TIMEOUT_ERROR = "File transfer timed out";
private const string RECEIVED_MEDIA_EMPTY_ERROR = "Received media file is empty";

private class TransferProgressWatchdog : Object {
    public bool timed_out { get; private set; default=false; }

    private FileTransfer file_transfer;
    private string operation;
    private int64 last_transferred_bytes = 0;
    private int64 last_phase_total_bytes = -1;
    private int64 last_progress_time_us = 0;
    private uint source_id = 0;

    public TransferProgressWatchdog(FileTransfer file_transfer, string operation) {
        this.file_transfer = file_transfer;
        this.operation = operation;
        this.last_transferred_bytes = file_transfer.transferred_bytes;
        this.last_phase_total_bytes = file_transfer.phase_total_bytes;
        this.last_progress_time_us = get_monotonic_time();
        this.source_id = Timeout.add_seconds(FILE_TRANSFER_STALL_CHECK_SECONDS, check_progress);
    }

    public void stop() {
        if (source_id == 0) return;
        Source.remove(source_id);
        source_id = 0;
    }

    private bool check_progress() {
        if (file_transfer.cancellable.is_cancelled() ||
                file_transfer.state != FileTransfer.State.IN_PROGRESS ||
                file_transfer.phase == FileTransfer.Phase.NONE ||
                file_transfer.phase == FileTransfer.Phase.COMPLETE ||
                file_transfer.phase == FileTransfer.Phase.FAILED) {
            source_id = 0;
            return false;
        }

        int64 now_us = get_monotonic_time();
        if (file_transfer.transferred_bytes != last_transferred_bytes ||
                file_transfer.phase_total_bytes != last_phase_total_bytes) {
            last_transferred_bytes = file_transfer.transferred_bytes;
            last_phase_total_bytes = file_transfer.phase_total_bytes;
            last_progress_time_us = now_us;
            return true;
        }

        if (now_us - last_progress_time_us < ((int64) FILE_TRANSFER_STALL_TIMEOUT_SECONDS * USEC_PER_SECOND)) {
            return true;
        }

        timed_out = true;
        warning("File transfer stalled during %s for %u seconds: %s",
                operation,
                FILE_TRANSFER_STALL_TIMEOUT_SECONDS,
                file_transfer.file_name ?? "(unknown)");
        if (!file_transfer.cancellable.is_cancelled()) {
            file_transfer.cancellable.cancel();
        }
        source_id = 0;
        return false;
    }
}

private enum ReceiveDownloadMode {
    USER,
    AUTOMATIC
}

private class ReceiveStoreTarget : Object {
    public File? pending_file;
    public File final_file;
    public OutputStream? pending_output;

    public ReceiveStoreTarget(File pending_file, File final_file, OutputStream pending_output) {
        this.pending_file = pending_file;
        this.final_file = final_file;
        this.pending_output = pending_output;
    }
}

private class ReceivePendingStoreStage : Object {
    public uint8[] plaintext_prefix;
    public int64 plaintext_size;
    public VerifiedPlaintextMeta? verified_plaintext_meta;

    public ReceivePendingStoreStage(uint8[] plaintext_prefix, int64 plaintext_size, VerifiedPlaintextMeta? verified_plaintext_meta = null) {
        this.plaintext_prefix = plaintext_prefix;
        this.plaintext_size = plaintext_size;
        this.verified_plaintext_meta = verified_plaintext_meta;
    }
}

private class ReceiveStoredStage : Object {
    public File file;
    public uint8[] plaintext_prefix;
    public int64 plaintext_size;
    public VerifiedPlaintextMeta? verified_plaintext_meta;

    public ReceiveStoredStage(File file, uint8[] plaintext_prefix, int64 plaintext_size, VerifiedPlaintextMeta? verified_plaintext_meta = null) {
        this.file = file;
        this.plaintext_prefix = plaintext_prefix;
        this.plaintext_size = plaintext_size;
        this.verified_plaintext_meta = verified_plaintext_meta;
    }
}

private class SendPipelinePlan : Object {
    public FileSender file_sender { get; private set; }
    public FileEncryptor? file_encryptor { get; private set; }
    public FileMeta file_meta { get; set; }

    public SendPipelinePlan(FileSender file_sender, FileEncryptor? file_encryptor, FileMeta file_meta) {
        this.file_sender = file_sender;
        this.file_encryptor = file_encryptor;
        this.file_meta = file_meta;
    }
}

private class IncomingReceiveClassification : Object {
    public Encryption provider_encryption { get; private set; }
    public string? provider_encryption_protocol { get; private set; }
    public FileDecryptor? file_decryptor { get; private set; }
    public Encryption decryptor_encryption { get; private set; }
    public Encryption transfer_encryption { get; private set; }

    public IncomingReceiveClassification(Encryption provider_encryption, string? provider_encryption_protocol, FileDecryptor? file_decryptor) {
        this.provider_encryption = provider_encryption;
        this.provider_encryption_protocol = provider_encryption_protocol;
        this.file_decryptor = file_decryptor;
        this.decryptor_encryption = file_decryptor != null ? ((!) file_decryptor).get_encryption() : Encryption.NONE;
        this.transfer_encryption = FileTransfer.resolve_received_encryption(provider_encryption, decryptor_encryption);
    }
}

// Runtime provenance of an outgoing private-room attachment. It survives
// retries on this FileTransfer and cannot be rebound to a new nick owner.
private class FileSendTargetScope : Object {
    private Account account;
    private int account_id;
    private string account_jid;
    private int conversation_id;
    private Conversation.Type conversation_type;
    private Jid counterpart;
    private string? peer_identity;
    private DateTime? history_cleared_at;
    private WeakRef target_weak;
    private WeakRef transfer_weak;
    private WeakRef muc_weak;
    private WeakRef manager_weak;
    public bool invalidated { get; private set; default = false; }

    public FileSendTargetScope(Conversation target, FileTransfer transfer,
            MucManager? muc_manager, FileManager manager) throws InvalidJidError {
        account = target.account;
        account_id = account.id;
        account_jid = account.bare_jid.to_string();
        conversation_id = target.id;
        conversation_type = target.type_;
        counterpart = new Jid.components(target.counterpart.localpart,
            target.counterpart.domainpart, target.counterpart.resourcepart);
        peer_identity = target.muc_pm_peer_identity;
        history_cleared_at = target.history_cleared_at;
        target_weak = WeakRef(target);
        transfer_weak = WeakRef(transfer);
        muc_weak = WeakRef(muc_manager);
        manager_weak = WeakRef(manager);
        target.notify["muc-pm-peer-identity"].connect(on_peer_identity_changed);
        account.notify["id"].connect(on_account_changed);
        account.notify["bare-jid"].connect(on_account_changed);
        account.notify["enabled"].connect(on_account_changed);
        if (muc_manager != null) {
            muc_manager.occupant_removed.connect(on_occupant_removed);
            muc_manager.left_signal.connect(on_room_left);
            muc_manager.room_occupants_changed_batch.connect(on_room_occupants_changed);
            muc_manager.private_room_occupant_updated.connect(on_occupant_updated);
        }
        if (peer_identity == null || !counterpart.is_full()) invalidate();
    }

    private bool same_thread(Conversation target) {
        if (invalidated || target.account != account || account.id != account_id ||
                account.bare_jid.to_string() != account_jid || !account.enabled ||
                target.id != conversation_id || target.type_ != conversation_type ||
                !target.counterpart.equals(counterpart) || target.muc_pm_peer_identity == null) return false;
        if (target.muc_pm_peer_identity == peer_identity) return true;
        if (history_cleared_at == null || target.history_cleared_at == null) {
            return history_cleared_at == target.history_cleared_at;
        }
        return ((!) history_cleared_at).compare((!) target.history_cleared_at) == 0;
    }

    public bool check(Conversation target, FileTransfer transfer) {
        if (!same_thread(target) || transfer.account != account ||
                !transfer.counterpart.equals(counterpart)) {
            invalidate();
            return false;
        }
        var muc_manager = muc_weak.get() as MucManager;
        if (muc_manager != null && (peer_identity == null ||
                !muc_manager.is_joined(counterpart.bare_jid, account) ||
                !muc_manager.is_current_occupant(account, counterpart.bare_jid, counterpart) ||
                !muc_manager.private_message_peer_identity_matches(account, counterpart, (!) peer_identity))) {
            invalidate();
            return false;
        }
        return true;
    }

    private void invalidate() {
        if (invalidated) return;
        invalidated = true;
        var transfer = transfer_weak.get() as FileTransfer;
        // Completed attachments are archived/playable local files. Mark their
        // original target stale for a future retry without cancelling playback.
        if (transfer != null && transfer.phase != FileTransfer.Phase.COMPLETE) {
            var manager = manager_weak.get() as FileManager;
            if (manager != null) manager.cancel_download(transfer);
            else transfer.cancellable.cancel();
            transfer.clear_retry_schedule();
        }
    }

    private void on_peer_identity_changed(Object source, ParamSpec property) {
        Conversation target = (Conversation) source;
        if (same_thread(target)) peer_identity = target.muc_pm_peer_identity;
        else invalidate();
    }

    private void on_account_changed() {
        var target = target_weak.get() as Conversation;
        if (target == null || !same_thread(target)) invalidate();
    }

    private void recheck_live_target() {
        var target = target_weak.get() as Conversation;
        var transfer = transfer_weak.get() as FileTransfer;
        if (target == null || transfer == null) return;
        check(target, transfer);
    }

    private void on_occupant_removed(Account changed_account, Jid room,
            Jid occupant, Xep.Muc.StatusCode code) {
        if (changed_account == account && occupant.equals(counterpart)) invalidate();
    }

    private void on_room_left(Account changed_account, Jid room) {
        if (changed_account == account && room.equals_bare(counterpart)) invalidate();
    }

    private void on_room_occupants_changed(Account changed_account, Jid room, MucRoomDelta delta) {
        if (changed_account == account && room.equals_bare(counterpart)) recheck_live_target();
    }

    private void on_occupant_updated(Account changed_account, Jid room, Jid occupant) {
        if (changed_account == account && occupant.equals(counterpart)) recheck_live_target();
    }
}

public class FileManager : StreamInteractionModule, Object {
    public static ModuleIdentity<FileManager> IDENTITY = new ModuleIdentity<FileManager>("file");
    public string id { get { return IDENTITY.id; } }

    public signal void upload_available(Account account);
    public signal void received_file(FileTransfer file_transfer, Conversation conversation);

    private StreamInteractor stream_interactor;
    private Database db;
    private FileEncryption file_encryption;
    private Gee.List<FileSender> file_senders = new ArrayList<FileSender>();
    private Gee.List<FileEncryptor> file_encryptors = new ArrayList<FileEncryptor>();
    private Gee.List<FileDecryptor> file_decryptors = new ArrayList<FileDecryptor>();
    private Gee.List<FileProvider> file_providers = new ArrayList<FileProvider>();
    private Gee.List<FileMetadataProvider> file_metadata_providers = new ArrayList<FileMetadataProvider>();
    private HashMap<int, uint> scheduled_retry_sources = new HashMap<int, uint>();
    private HashMap<string, FileTransfer> live_received_transfers_by_source = new HashMap<string, FileTransfer>();
    private uint persisted_retry_arm_source_id = 0;
    private const string SEND_TARGET_SCOPE_DATA = "dinox-file-send-target-scope";
    private const string PM_ATTACHMENT_TARGET_CHANGED_ERROR =
        "Private-room attachment recipient changed; choose the file again";

    public StatelessFileSharing sfs {
        owned get { return stream_interactor.get_module<StatelessFileSharing>(StatelessFileSharing.IDENTITY); }
        private set { }
    }

    public static void start(StreamInteractor stream_interactor, Database db, FileEncryption file_encryption) {
        FileManager m = new FileManager(stream_interactor, db, file_encryption);
        stream_interactor.add_module(m);
    }

    internal static FileManager create_for_tests() {
        return new FileManager.for_tests();
    }

    public static string get_storage_dir() {
        return Path.build_filename(Dino.get_storage_dir(), "files");
    }

    public static bool hashes_match(string expected, string computed) {
        return normalize_hash_value(expected) == normalize_hash_value(computed);
    }

    public static InputStream create_plaintext_file_lease_input_stream(File plaintext_file, string? plaintext_directory, VerifiedPlaintextMeta? verified_plaintext_meta = null, owned PlaintextFileLease.DeleteFunc? delete_func = null) throws Error {
        validate_plaintext_lease_input_source(plaintext_file, plaintext_directory);

        var lease = new PlaintextFileLease(plaintext_file, plaintext_directory, (owned) delete_func);
        try {
            return new PlaintextFileLeaseInputStream(lease, verified_plaintext_meta);
        } catch (Error e) {
            lease.release();
            throw e;
        }
    }

    public static PlaintextFileLeaseTarget create_plaintext_file_lease_target(string purpose, owned PlaintextFileLease.DeleteFunc? delete_func = null) throws IOError {
        return create_plaintext_file_lease_target_for_root(purpose, null, (owned) delete_func);
    }

    public static PlaintextFileLeaseTarget create_named_plaintext_file_lease_target(string purpose,
            string file_name, owned PlaintextFileLease.DeleteFunc? delete_func = null) throws IOError {
        return create_plaintext_file_lease_target_for_root(
                purpose, null, (owned) delete_func, file_name);
    }

    internal static PlaintextFileLeaseTarget create_plaintext_file_lease_target_for_tests(string purpose, string plaintext_lease_root, owned PlaintextFileLease.DeleteFunc? delete_func = null, string? file_name = null) throws IOError {
        return create_plaintext_file_lease_target_for_root(purpose, plaintext_lease_root, (owned) delete_func, file_name);
    }

    private static PlaintextFileLeaseTarget create_plaintext_file_lease_target_for_root(string purpose, string? plaintext_lease_root, owned PlaintextFileLease.DeleteFunc? delete_func = null, string? file_name = null) throws IOError {
        string plaintext_directory = create_plaintext_lease_dir(purpose, plaintext_lease_root);
        string plaintext_file_name = file_name ?? GLib.Uuid.string_random();
        if (plaintext_file_name == "" || plaintext_file_name == "." || plaintext_file_name == ".." ||
                plaintext_file_name.index_of_char('/') >= 0 || plaintext_file_name.index_of_char('\\') >= 0) {
            DirUtils.remove(plaintext_directory);
            throw new IOError.INVALID_ARGUMENT("Plaintext lease filename must be a single non-empty path component");
        }
        File plaintext_file = File.new_for_path(Path.build_filename(plaintext_directory, plaintext_file_name));
        return new PlaintextFileLeaseTarget(plaintext_file, plaintext_directory, (owned) delete_func);
    }

    private static void validate_plaintext_lease_input_source(File plaintext_file, string? plaintext_directory) throws Error {
        string? plaintext_path = plaintext_file.get_path();
        if (plaintext_path == null || ((!) plaintext_path) == "" || !Path.is_absolute((!) plaintext_path)) {
            throw new IOError.PERMISSION_DENIED("Plaintext lease file must be an absolute local path");
        }

        if (plaintext_directory == null || ((!) plaintext_directory) == "" || !Path.is_absolute((!) plaintext_directory)) {
            throw new IOError.PERMISSION_DENIED("Plaintext lease directory must be an absolute local path");
        }

        File lease_directory = File.new_for_path((!) plaintext_directory);
        File? parent = plaintext_file.get_parent();
        if (parent == null || !((!) parent).equal(lease_directory)) {
            throw new IOError.PERMISSION_DENIED("Plaintext lease file must be directly inside its lease directory");
        }

        FileInfo directory_info = lease_directory.query_info(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (directory_info.get_file_type() != FileType.DIRECTORY) {
            throw new IOError.PERMISSION_DENIED("Plaintext lease directory must be a directory");
        }

        FileInfo file_info = plaintext_file.query_info(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (file_info.get_file_type() != FileType.REGULAR) {
            throw new IOError.PERMISSION_DENIED("Plaintext lease file must be a regular file");
        }
    }

    private static string normalize_hash_value(string hash) {
        string normalized = hash.replace("-", "+").replace("_", "/");
        while (normalized.length % 4 != 0) normalized += "=";
        return normalized;
    }

    private FileManager.for_tests() {
    }

    private FileManager(StreamInteractor stream_interactor, Database db, FileEncryption file_encryption) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.file_encryption = file_encryption;

        DirUtils.create_with_parents(get_storage_dir(), 0700);

        // DinoX reaches FileManager after application single-instance registration
        // (Gtk.Application on Unix, Win32 mutex before UI startup on Windows).
        // Active plaintext leases therefore belong to this process; entries found
        // at startup are stale leftovers from crashes or previous external viewers.
        cleanup_plaintext_lease_root(get_plaintext_lease_root());

        this.add_provider(new JingleFileProvider(stream_interactor));
        this.add_sender(new JingleFileSender(stream_interactor));
        this.add_metadata_provider(new GenericFileMetadataProvider());
        this.add_metadata_provider(new ImageFileMetadataProvider());

        // Test StreamInteractors own short-lived temporary databases. Scheduling
        // an application-startup idle there can outlive the individual test and
        // query a database that has already been closed. Tests exercise retries
        // explicitly; only the real application needs persisted retry arming.
        if (!stream_interactor.is_test_instance) {
            persisted_retry_arm_source_id = Idle.add(() => {
                persisted_retry_arm_source_id = 0;
                arm_persisted_scheduled_transfer_retries();
                return Source.REMOVE;
            });
        }
    }

    public override void dispose() {
        if (persisted_retry_arm_source_id != 0) {
            Source.remove(persisted_retry_arm_source_id);
            persisted_retry_arm_source_id = 0;
        }

        var source_ids = new ArrayList<uint>();
        foreach (uint source_id in scheduled_retry_sources.values) {
            source_ids.add(source_id);
        }
        scheduled_retry_sources.clear();
        foreach (uint source_id in source_ids) {
            if (source_id != 0) Source.remove(source_id);
        }

        base.dispose();
    }

    public async PlaintextFileLease create_plaintext_file_lease(FileTransfer file_transfer, string purpose = "open") throws Error {
        ensure_plaintext_release_allowed(file_transfer);

        File? source_file = file_transfer.get_file();
        if (source_file == null || !source_file.query_exists()) {
            throw new IOError.NOT_FOUND("Stored file is not available");
        }

        PlaintextFileLease lease = yield create_plaintext_source_lease((!) source_file, file_transfer.file_name, purpose, file_transfer.cancellable);
        if (!file_transfer.is_plaintext_release_allowed()) {
            lease.release();
            throw new IOError.PERMISSION_DENIED("File transfer is not complete yet");
        }
        return lease;
    }

    private async PlaintextFileLease create_plaintext_source_lease(File source_file, string? original_file_name, string purpose, Cancellable? cancellable = null) throws Error {
        return yield create_plaintext_source_lease_for_encryption(file_encryption, source_file, original_file_name, purpose, null, cancellable);
    }

    private static async PlaintextFileLease create_plaintext_source_lease_for_encryption(FileEncryption source_file_encryption, File source_file, string? original_file_name, string purpose, string? plaintext_lease_root = null, Cancellable? cancellable = null) throws Error {
        string lease_dir = create_plaintext_lease_dir(purpose, plaintext_lease_root);
        string temp_name = GLib.Uuid.string_random() + get_filename_extension(original_file_name);
        string pending_name = "." + temp_name + ".part";
        File pending_file = File.new_for_path(Path.build_filename(lease_dir, pending_name));
        File target_file = File.new_for_path(Path.build_filename(lease_dir, temp_name));
        OutputStream output = pending_file.create(FileCreateFlags.PRIVATE);

        try {
            yield source_file_encryption.decrypt_file_to_stream(source_file, output, cancellable);
            pending_file.move(target_file, FileCopyFlags.NONE, cancellable);
            return new PlaintextFileLease(target_file, lease_dir);
        } catch (Error e) {
            try { pending_file.delete(null); } catch (Error delete_error) {}
            try { target_file.delete(null); } catch (Error delete_error) {}
            DirUtils.remove(lease_dir);
            throw e;
        }
    }

    public async void export_plaintext_file(FileTransfer file_transfer, File target_file) throws Error {
        ensure_plaintext_release_allowed(file_transfer);

        File? source_file = file_transfer.get_file();
        if (source_file == null || !source_file.query_exists()) {
            throw new IOError.NOT_FOUND("Stored file is not available");
        }

        yield export_plaintext_source_to_target(file_encryption, (!) source_file, file_transfer.file_name, target_file, null, file_transfer.cancellable, file_transfer);
    }

    internal static async void export_plaintext_source_to_target_for_tests(FileEncryption file_encryption, File source_file, File target_file, string plaintext_lease_root, Cancellable? cancellable = null) throws Error {
        yield export_plaintext_source_to_target(file_encryption, source_file, source_file.get_basename(), target_file, plaintext_lease_root, cancellable);
    }

    private static async void export_plaintext_source_to_target(FileEncryption file_encryption, File source_file, string? original_file_name, File target_file, string? plaintext_lease_root, Cancellable? cancellable, FileTransfer? release_guard = null) throws Error {
        PlaintextFileLease? lease = null;
        try {
            // Keep the pre-authentication plaintext phase inside DinoX's
            // private lease root. The user-selected target directory only sees
            // plaintext after the at-rest GCM tag has been verified.
            lease = yield create_plaintext_source_lease_for_encryption(file_encryption, source_file, original_file_name, "export", plaintext_lease_root, cancellable);
            if (release_guard != null && !((!) release_guard).is_plaintext_release_allowed()) {
                throw new IOError.PERMISSION_DENIED("File transfer is not complete yet");
            }
            yield copy_verified_plaintext_to_export_target(((!) lease).file, target_file, cancellable);
        } finally {
            if (lease != null) {
                ((!) lease).release();
            }
        }
    }

    private static async void copy_verified_plaintext_to_export_target(File plaintext_file, File target_file, Cancellable? cancellable) throws Error {
        File? parent = target_file.get_parent();
        string? basename = target_file.get_basename();
        if (parent == null || basename == null || ((!) basename) == "") {
            throw new IOError.FAILED("Export target is not writable");
        }

        string pending_name = ".dinox-export-" + GLib.Uuid.string_random() + ".part";
        File pending_file = ((!) parent).get_child(pending_name);
        bool pending_moved = false;

        try {
            yield plaintext_file.copy_async(pending_file, FileCopyFlags.NONE, Priority.LOW, cancellable, null);
            pending_file.move(target_file, FileCopyFlags.OVERWRITE, cancellable);
            pending_moved = true;
        } catch (Error e) {
            if (!pending_moved) {
                try { pending_file.delete(null); } catch (Error delete_error) {}
            }
            throw e;
        }
    }

    private static void ensure_plaintext_release_allowed(FileTransfer file_transfer) throws IOError {
        if (!file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.PERMISSION_DENIED("File transfer is not complete yet");
        }
    }

    private static string get_plaintext_lease_root() {
        return Path.build_filename(Environment.get_user_cache_dir(), "dinox", "temp_plaintext");
    }

    private static string create_plaintext_lease_dir(string purpose, string? plaintext_lease_root = null) throws IOError {
        string root = Path.build_filename(plaintext_lease_root ?? get_plaintext_lease_root(), sanitize_temp_component(purpose));
        DirUtils.create_with_parents(root, 0700);

        string lease_dir = Path.build_filename(root, GLib.Uuid.string_random());
        if (DirUtils.create(lease_dir, 0700) == -1) {
            throw new IOError.FAILED("Could not create plaintext lease directory \"%s\": %s",
                    lease_dir, FileUtils.error_from_errno(errno).to_string());
        }
        return lease_dir;
    }

    internal static void cleanup_plaintext_lease_root_for_tests(string root) {
        cleanup_plaintext_lease_root(root);
    }

    private static void cleanup_plaintext_lease_root(string root) {
        if (!is_plaintext_lease_root(root)) {
            debug("Ignoring plaintext lease cleanup for unexpected root \"%s\"", root);
            return;
        }

        File root_file = File.new_for_path(root);
        cleanup_plaintext_lease_entry(root_file, true);
    }

    private static bool is_plaintext_lease_root(string root) {
        if (!Path.is_absolute(root)) return false;
        if (root == get_plaintext_lease_root()) return true;

        return is_test_plaintext_lease_root(root);
    }

    private static bool is_test_plaintext_lease_root(string root) {
        string temp_dir = Environment.get_tmp_dir();
        string expected_prefix = Path.build_filename(temp_dir, "dinox-file-manager-");
        if (!root.has_prefix(expected_prefix)) return false;

        string root_basename = Path.get_basename(root);
        string parent = Path.get_dirname(root);
        string test_root = Path.get_dirname(parent);
        return root_basename == "temp_plaintext" &&
            Path.get_basename(parent) == "dinox" &&
            Path.get_dirname(test_root) == temp_dir &&
            Path.get_basename(test_root).has_prefix("dinox-file-manager-");
    }

    private static void cleanup_plaintext_lease_entry(File file, bool is_root = false) {
        FileInfo info;
        try {
            info = file.query_info(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        } catch (IOError.NOT_FOUND e) {
            return;
        } catch (Error e) {
            debug("Failed to query plaintext lease path \"%s\": %s", file.get_path() ?? "(unknown)", e.message);
            return;
        }

        FileType file_type = info.get_file_type();
        if (file_type == FileType.DIRECTORY) {
            FileEnumerator? enumerator = null;
            try {
                enumerator = file.enumerate_children(FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                        FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? child_info;
                while ((child_info = enumerator.next_file()) != null) {
                    cleanup_plaintext_lease_entry(file.get_child(((!) child_info).get_name()));
                }
            } catch (Error e) {
                debug("Failed to enumerate plaintext lease directory \"%s\": %s", file.get_path() ?? "(unknown)", e.message);
            } finally {
                if (enumerator != null) {
                    try {
                        ((!) enumerator).close();
                    } catch (Error e) {
                        debug("Failed to close plaintext lease directory \"%s\": %s", file.get_path() ?? "(unknown)", e.message);
                    }
                }
            }

            try {
                file.delete();
            } catch (Error e) {
                debug("Failed to delete plaintext lease directory \"%s\": %s", file.get_path() ?? "(unknown)", e.message);
            }
        } else if (!is_root && file_type == FileType.REGULAR) {
            secure_delete_plaintext_lease_file(file);
        } else {
            debug("Skipping non-regular plaintext lease path \"%s\"", file.get_path() ?? "(unknown)");
        }
    }

    private static void secure_delete_plaintext_lease_file(File file) {
        try {
            FileInfo info = file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            int64 size = info.get_size();
            if (size > 0) {
                OutputStream output = file.replace(null, false, FileCreateFlags.PRIVATE);
                uint8[] zeros = new uint8[4096];
                int64 written = 0;
                while (written < size) {
                    int chunk = (int) int64.min(4096, size - written);
                    output.write(zeros[0:chunk]);
                    written += chunk;
                }
                output.close();
            }
        } catch (Error e) {
            debug("Failed to overwrite plaintext lease file \"%s\" before deletion: %s", file.get_path() ?? "(unknown)", e.message);
        }

        try {
            file.delete();
        } catch (Error e) {
            debug("Failed to delete plaintext lease file \"%s\": %s", file.get_path() ?? "(unknown)", e.message);
        }
    }

    private static string sanitize_temp_component(string? value) {
        string source = (value ?? "open").strip();
        StringBuilder clean = new StringBuilder();
        for (int i = 0; i < source.length; i++) {
            char c = source[i];
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
                clean.append_c(c);
            } else {
                clean.append_c('_');
            }
        }
        string result = clean.str;
        return result == "" ? "open" : result;
    }

    private static string get_filename_extension(string? file_name) {
        if (file_name == null || !((!) file_name).contains(".")) return "";
        string basename = Path.get_basename((!) file_name);
        string[] parts = basename.split(".");
        if (parts.length < 2) return "";
        string ext = parts[parts.length - 1];
        if (ext == "" || ext.length > 24) return "";
        return "." + ext;
    }

    public const int HTTP_PROVIDER_ID = 0;
    public const int JINGLE_PROVIDER_ID = 1;
    public const int SFS_PROVIDER_ID = 2;
    public const int NO_REQUIRED_FILE_SENDER_ID = -1;
    public const string DIRECT_TRANSFER_UNAVAILABLE_ERROR = "Direct file transfer is no longer available; ask the sender to send it again";

    private static string get_provider_source_key(int provider_id, string info) {
        return "%d:%s".printf(provider_id, info);
    }

    public FileProvider? select_file_provider(FileTransfer file_transfer) {
        bool http_usable = file_transfer.provider == SFS_PROVIDER_ID;
        foreach (FileProvider file_provider in this.file_providers) {
            if (file_transfer.provider == file_provider.get_id()) {
                return file_provider;
            }
            if (http_usable && file_provider.get_id() == HTTP_PROVIDER_ID) {
                return file_provider;
            }
        }
        return null;
    }

    public bool has_usable_download_source(FileTransfer file_transfer) {
        if (file_transfer.direction == FileTransfer.DIRECTION_SENT &&
                (file_transfer.provider != SFS_PROVIDER_ID || file_transfer.has_local_file_copy())) {
            return true;
        }
        if (file_transfer.provider == JINGLE_PROVIDER_ID && file_transfer.state != FileTransfer.State.NOT_STARTED) return false;
        if (file_transfer.provider == JINGLE_PROVIDER_ID &&
                !file_transfer.has_usable_download_source(SFS_PROVIDER_ID, JINGLE_PROVIDER_ID)) return false;

        FileProvider? file_provider = select_file_provider(file_transfer);
        if (file_provider == null) return false;
        return ((!) file_provider).has_usable_download_source(file_transfer);
    }

    public delegate void FileSizeLimitResolved(int sender_id, long limit);

    public async HashMap<int, long> get_file_size_limits(Conversation conversation, int64 file_size = 0) {
        return yield get_file_size_limits_progressive(conversation, file_size, (sender_id, limit) => {});
    }

    public async HashMap<int, long> get_file_size_limits_progressive(Conversation conversation,
            int64 file_size, owned FileSizeLimitResolved on_resolved) {
        HashMap<int, long> ret = new HashMap<int, long>();
        FileTransfer probe_transfer = create_sender_probe_transfer(conversation, file_size);
        foreach (FileSender sender in file_senders) {
            long limit = yield sender.get_file_size_limit(conversation);
            if (!yield can_use_sender_for_transfer(sender, conversation, probe_transfer)) {
                limit = -1;
            }
            ret[sender.get_id()] = limit;
            on_resolved(sender.get_id(), limit);
        }
        return ret;
    }

    private static FileTransfer create_sender_probe_transfer(Conversation conversation, int64 file_size) {
        FileTransfer file_transfer = new FileTransfer();
        file_transfer.account = conversation.account;
        file_transfer.counterpart = conversation.counterpart;
        file_transfer.direction = FileTransfer.DIRECTION_SENT;
        file_transfer.encryption = conversation.encryption;
        file_transfer.size = file_size;
        return file_transfer;
    }

    private async bool can_use_sender_for_transfer(FileSender sender, Conversation conversation, FileTransfer file_transfer) {
        if (!yield sender.can_send(conversation, file_transfer)) return false;
        if (file_transfer.encryption == Encryption.NONE) return true;
        if (yield sender.can_encrypt(conversation, file_transfer)) return true;

        FileEncryptor? file_encryptor = select_file_encryptor(conversation, file_transfer);
        return file_encryptor != null && file_encryptor_accepts_sender((!) file_encryptor, sender.get_id());
    }

    private void bind_outgoing_send_target(Conversation conversation, FileTransfer transfer) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT_PM ||
                transfer.get_data<FileSendTargetScope>(SEND_TARGET_SCOPE_DATA) != null) return;
        MucManager? muc_manager = stream_interactor != null ?
            stream_interactor.get_module<MucManager>(MucManager.IDENTITY) : null;
        try {
            var scope = new FileSendTargetScope(conversation, transfer, muc_manager, this);
            transfer.set_data<FileSendTargetScope>(SEND_TARGET_SCOPE_DATA, (owned) scope);
        } catch (InvalidJidError error) {
            transfer.cancellable.cancel();
        }
    }

    private void throw_if_send_target_changed(Conversation conversation, FileTransfer transfer,
            bool honor_cancellation = true) throws IOError {
        FileSendTargetScope? scope = transfer.get_data<FileSendTargetScope>(SEND_TARGET_SCOPE_DATA);
        if ((scope == null && conversation.type_ == Conversation.Type.GROUPCHAT_PM) ||
                (scope != null && !((!) scope).check(conversation, transfer))) {
            transfer.cancellable.cancel();
            cancel_scheduled_transfer_retry(transfer);
            transfer.clear_retry_schedule();
            throw new IOError.CANCELLED(PM_ATTACHMENT_TARGET_CHANGED_ERROR);
        }
        if (honor_cancellation) throw_if_transfer_cancelled(transfer);
    }

    private static string send_cancellation_reason(FileTransfer transfer) {
        FileSendTargetScope? scope = transfer.get_data<FileSendTargetScope>(SEND_TARGET_SCOPE_DATA);
        return scope != null && ((!) scope).invalidated ? PM_ATTACHMENT_TARGET_CHANGED_ERROR : "cancelled";
    }

    public delegate void OutgoingFileTransferConfigurator(FileTransfer file_transfer);

    public async void send_file(File file, Conversation conversation, owned OutgoingFileTransferConfigurator? configure = null) {
        yield send_file_with_source(file, conversation, OutgoingFileSource.EXTERNAL_PLAINTEXT, (owned) configure);
    }

    public async void send_file_with_source(File file, Conversation conversation, OutgoingFileSource source,
            owned OutgoingFileTransferConfigurator? configure = null) {
        debug("FileManager.send_file: called for %s", file.get_path());
        File file_to_use = file;
        PlaintextFileLease? source_plaintext_lease = null;
        FileTransfer file_transfer = new FileTransfer();
        file_transfer.account = conversation.account;
        file_transfer.counterpart = conversation.counterpart;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            file_transfer.ourpart = stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                .get_own_jid(conversation.counterpart, conversation.account) ?? conversation.account.bare_jid;
        } else {
            file_transfer.ourpart = conversation.account.full_jid;
        }
        file_transfer.direction = FileTransfer.DIRECTION_SENT;
        if (file_transfer.cancel_token == null || file_transfer.cancel_token == "") {
            file_transfer.cancel_token = Uuid.string_random();
        }
        file_transfer.time = new DateTime.now_utc();
        file_transfer.local_time = new DateTime.now_utc();
        file_transfer.encryption = conversation.encryption;
        file_transfer.set_transfer_phase(FileTransfer.Phase.PREPARING);
        // Capture before the first plaintext-lease or metadata operation yields.
        bind_outgoing_send_target(conversation, file_transfer);

        try {
            throw_if_send_target_changed(conversation, file_transfer);
            if (source == OutgoingFileSource.DINOX_MANAGED_STORAGE) {
                try {
                    source_plaintext_lease = yield create_plaintext_source_lease(
                        file, file.get_basename(), "send", file_transfer.cancellable);
                    file_to_use = ((!) source_plaintext_lease).file;
                } catch (Error e) {
                    if (file_transfer.cancellable.is_cancelled()) {
                        file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, send_cancellation_reason(file_transfer));
                    } else {
                        warning("Failed to decrypt file for sending: %s", e.message);
                        file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, e.message);
                    }
                    return;
                }
            }
            throw_if_send_target_changed(conversation, file_transfer);
            Xep.FileMetadataElement.FileMetadata metadata = new Xep.FileMetadataElement.FileMetadata();
            foreach (FileMetadataProvider provider in this.file_metadata_providers) {
                if (provider.supports_file(file_to_use)) {
                    yield provider.fill_metadata(file_to_use, metadata);
                    throw_if_send_target_changed(conversation, file_transfer);
                }
            }
            if (file_to_use != file) metadata.name = file.get_basename();
            file_transfer.file_metadata = metadata;
            debug("send_file: preparing '%s' size=%lld mime=%s conv_encryption=%d conv_type=%d",
                file_transfer.file_name, (int64) file_transfer.size,
                file_transfer.mime_type ?? "(null)", (int) conversation.encryption,
                (int) conversation.type_);
            if (configure != null) configure(file_transfer);
            throw_if_send_target_changed(conversation, file_transfer);
            yield send_prepared_file(conversation, file_transfer, file_to_use);
        } catch (IOError error) {
            file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, send_cancellation_reason(file_transfer));
        } finally {
            if (source_plaintext_lease != null) ((!) source_plaintext_lease).release();
        }
    }

    private async void send_prepared_file(Conversation conversation, FileTransfer file_transfer, File file_to_use) {
        try {
            yield store_outgoing_file_before_send(file_transfer, conversation, file_to_use);
        } catch (Error e) {
            if (file_transfer.cancellable.is_cancelled()) {
                debug("Send file cancelled while saving local copy");
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, send_cancellation_reason(file_transfer));
            } else {
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, e.message);
                warning("Error saving outgoing file: %s", e.message);
            }
            if (file_transfer.input_stream != null) {
                try {
                    yield file_transfer.input_stream.close_async();
                } catch (Error close_error) {
                    debug("Failed to close outgoing file input after local save error: %s", close_error.message);
                }
            }
            return;
        }

        try {
            yield send_file_transport_pipeline(conversation, file_transfer);
        } catch (Error e) {
            if (is_user_cancelled_transfer_error(file_transfer, e)) {
                debug("Send file cancelled");
                file_transfer.clear_retry_schedule();
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, send_cancellation_reason(file_transfer));
            } else {
                warning("Send file error: %s", e.message);
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, e.message);
                schedule_send_retry(file_transfer, conversation, e);
            }

            // Clean up the input stream to prevent segfault (fixes #1764)
            if (file_transfer.input_stream != null) {
                try {
                    yield file_transfer.input_stream.close_async();
                } catch (Error close_error) {
                    debug("Failed to close input stream: %s", close_error.message);
                }
            }
        }
    }

    private async void send_file_transport_pipeline(Conversation conversation, FileTransfer file_transfer) throws Error {
        throw_if_send_target_changed(conversation, file_transfer);
        SendPipelinePlan send_plan = yield prepare_send_pipeline(conversation, file_transfer);
        throw_if_send_target_changed(conversation, file_transfer);
        file_transfer.provider = send_plan.file_sender.get_id();
        yield encrypt_outgoing_file_if_needed(conversation, file_transfer, send_plan);
        throw_if_send_target_changed(conversation, file_transfer);
        FileSendData file_send_data = yield prepare_send_data(conversation, file_transfer, send_plan);
        throw_if_send_target_changed(conversation, file_transfer);
        yield send_outgoing_file_data(conversation, file_transfer, send_plan, file_send_data);
        throw_if_send_target_changed(conversation, file_transfer);

        // Explicitly close the stream as we prevent libsoup/cis from closing the base stream
        if (file_transfer.input_stream != null) {
            try { yield file_transfer.input_stream.close_async(); } catch (Error e) {}
        }

        file_transfer.set_transfer_phase(FileTransfer.Phase.COMPLETE);
        cancel_scheduled_transfer_retry(file_transfer);
        file_transfer.clear_retry_schedule();
    }

    private async void store_outgoing_file_before_send(FileTransfer file_transfer, Conversation conversation, File file_to_use) throws Error {
        Binding? progress_binding = null;
        string? unpublished_saved_path = null;
        try {
            file_transfer.set_transfer_phase(FileTransfer.Phase.STORING);
            file_transfer.transferred_bytes = 0;
            debug("FileManager: Opening stream for local encryption...");
            file_transfer.input_stream = yield file_to_use.read_async();
            file_transfer.input_stream = track_input_progress(file_transfer, file_transfer.input_stream, file_transfer.size, ref progress_binding);

            debug("FileManager: Saving encrypted local copy...");
            yield save_file(file_transfer);
            unpublished_saved_path = file_transfer.path;
            throw_if_transfer_cancelled(file_transfer);
            finish_progress_tracking(file_transfer, file_transfer.size, ref progress_binding);
            debug("FileManager: Local copy saved.");

            // save_file consumed the stream, so re-open it for the transport step.
            try {
                ((InputStream) file_transfer.input_stream).close();
            } catch (Error e) {}

            debug("FileManager: Re-opening stream for upload...");
            file_transfer.input_stream = yield file_to_use.read_async();
            debug("FileManager: Stream re-opened.");

            throw_if_send_target_changed(conversation, file_transfer);
            stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY).add_file(file_transfer);
            unpublished_saved_path = null;
            conversation.last_active = file_transfer.time;
            received_file(file_transfer, conversation);
        } finally {
            if (unpublished_saved_path != null) {
                delete_unpublished_outgoing_file(file_transfer, get_storage_dir(), unpublished_saved_path);
            }
            stop_progress_tracking(ref progress_binding);
        }
    }

    public async void download_file(FileTransfer file_transfer) {
        cancel_scheduled_transfer_retry(file_transfer);
        file_transfer.clear_retry_schedule();
        yield start_receive_download(file_transfer, ReceiveDownloadMode.USER);
    }

    public void cancel_download(FileTransfer file_transfer) {
        cancel_scheduled_transfer_retry(file_transfer);
        file_transfer.clear_retry_schedule();

        if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) {
            file_transfer.cancellable.cancel();
            if (file_transfer.provider == JINGLE_PROVIDER_ID && stream_interactor != null) {
                Xep.JingleFileTransfer.Module? jingle_module = stream_interactor.module_manager.get_module<Xep.JingleFileTransfer.Module>(file_transfer.account, Xep.JingleFileTransfer.Module.IDENTITY);
                if (jingle_module != null) {
                    bool cancelled = false;
                    if (file_transfer.id > 0) {
                        cancelled = ((!) jingle_module).cancel_send_transfer(file_transfer.id);
                    }
                    if (!cancelled && file_transfer.cancel_token != null && file_transfer.cancel_token != "") {
                        ((!) jingle_module).cancel_send_transfer_token((!) file_transfer.cancel_token);
                    }
                }
            }
            return;
        }

        if (!file_transfer.cancellable.is_cancelled()) {
            file_transfer.cancellable.cancel();
        }

        FileProvider? file_provider = this.select_file_provider(file_transfer);
        if (file_provider == null) {
            if (file_transfer.input_stream != null) {
                try {
                    ((!) file_transfer.input_stream).close();
                } catch (Error close_error) {
                    debug("Failed to close receive input stream during cancel_download: %s", close_error.message);
                }
            }
            return;
        }

        JingleFileProvider? jingle_file_provider = file_provider as JingleFileProvider;
        if (jingle_file_provider != null) {
            ((!) jingle_file_provider).cancel_receive_transfer(file_transfer.info);
            file_transfer.set_transient_download_source_available(false);
            file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, DIRECT_TRANSFER_UNAVAILABLE_ERROR);
        }
    }

    public async void auto_download_file(FileTransfer file_transfer) {
        yield start_receive_download(file_transfer, ReceiveDownloadMode.AUTOMATIC);
    }

    private async void start_receive_download(FileTransfer file_transfer, ReceiveDownloadMode mode) {
        Conversation? conversation = resolve_file_transfer_conversation(file_transfer);
        if (conversation == null) {
            set_receive_download_start_failure(file_transfer, mode, "No conversation available for this transfer");
            return;
        }

        FileProvider? file_provider = this.select_file_provider(file_transfer);
        if (file_provider == null) {
            set_receive_download_start_failure(file_transfer, mode, "No file provider available for this transfer");
            return;
        }
        if (!has_usable_download_source(file_transfer)) {
            if (file_transfer.provider == JINGLE_PROVIDER_ID) {
                file_transfer.set_transient_download_source_available(false);
            }
            set_receive_download_start_failure(file_transfer, mode, get_missing_download_source_error(file_transfer));
            return;
        }

        yield download_file_internal((!) file_provider, file_transfer, (!) conversation, mode);
    }

    private void set_receive_download_start_failure(FileTransfer file_transfer, ReceiveDownloadMode mode, string message) {
        if (mode == ReceiveDownloadMode.AUTOMATIC) {
            debug("Auto-download skipped for '%s': %s", file_transfer.file_name ?? "(unknown)", message);
            file_transfer.set_transfer_phase(FileTransfer.Phase.NONE);
            return;
        }

        file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, message);
    }

    private string get_missing_download_source_error(FileTransfer file_transfer) {
        return file_transfer.provider == JINGLE_PROVIDER_ID ?
            DIRECT_TRANSFER_UNAVAILABLE_ERROR :
            "Download source missing";
    }

    private static bool is_soft_auto_download_error(Error error) {
        if (error is IOError && is_transient_transfer_error(error)) return true;
        string message = error.message ?? "";
        return message.has_prefix("HTTP download failed:") ||
                message.has_prefix("HEAD request failed:") ||
                message.has_prefix("HEAD request returned HTTP");
    }

    public async void retry_send_file(FileTransfer file_transfer) {
        cancel_scheduled_transfer_retry(file_transfer);
        file_transfer.clear_retry_schedule();

        Conversation? conversation = resolve_file_transfer_conversation(file_transfer);
        if (conversation == null) {
            file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, "No conversation available for this transfer");
            return;
        }

        yield retry_send_file_internal((!) conversation, file_transfer);
    }

    internal async void retry_send_file_for_tests(Conversation conversation, FileTransfer file_transfer) {
        yield retry_send_file_internal(conversation, file_transfer);
    }

    private async void retry_send_file_internal(Conversation conversation, FileTransfer file_transfer) {
        try {
            // A user retry may reset ordinary cancellation, never original
            // recipient provenance after that peer has been replaced.
            throw_if_send_target_changed(conversation, file_transfer, false);
        } catch (IOError error) {
            file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED,
                conversation.type_ == Conversation.Type.GROUPCHAT_PM ?
                    PM_ATTACHMENT_TARGET_CHANGED_ERROR : send_cancellation_reason(file_transfer));
            return;
        }
        if (!file_transfer.can_retry_send_attempt()) {
            file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, "File transfer is not retryable");
            return;
        }

        File? source_file = file_transfer.get_file();
        if (source_file == null || !((!) source_file).query_exists()) {
            file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, "Stored file is not available");
            return;
        }

        PlaintextFileLease? source_plaintext_lease = null;
        InputStream? retry_stream = null;
        try {
            file_transfer.prepare_transfer_attempt();
            file_transfer.set_transfer_phase(FileTransfer.Phase.PREPARING);
            source_plaintext_lease = yield create_plaintext_source_lease((!) source_file, file_transfer.file_name, "send-retry", file_transfer.cancellable);
            retry_stream = yield ((!) source_plaintext_lease).file.read_async(Priority.LOW, file_transfer.cancellable);
            file_transfer.input_stream = (!) retry_stream;

            yield send_file_transport_pipeline(conversation, file_transfer);
        } catch (Error e) {
            if (is_user_cancelled_transfer_error(file_transfer, e)) {
                debug("Retry send file cancelled");
                file_transfer.clear_retry_schedule();
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, send_cancellation_reason(file_transfer));
            } else {
                warning("Retry send file error: %s", e.message);
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, e.message);
                schedule_send_retry(file_transfer, conversation, e);
            }
        } finally {
            if (retry_stream != null && !((!) retry_stream).is_closed()) {
                try {
                    yield ((!) retry_stream).close_async(Priority.LOW, null);
                } catch (Error close_error) {
                    debug("Failed to close retry input stream: %s", close_error.message);
                }
            }
            if (source_plaintext_lease != null) {
                ((!) source_plaintext_lease).release();
            }
        }
    }

    private Conversation? resolve_file_transfer_conversation(FileTransfer file_transfer) {
        ConversationManager? conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (conversation_manager == null) return null;

        if (file_transfer.counterpart.resourcepart != null && file_transfer.counterpart.resourcepart != "") {
            Conversation? pm_conversation = ((!) conversation_manager).get_conversation(
                file_transfer.counterpart,
                file_transfer.account,
                Conversation.Type.GROUPCHAT_PM);
            if (pm_conversation != null) return pm_conversation;
        }

        return ((!) conversation_manager).get_conversation(file_transfer.counterpart.bare_jid, file_transfer.account);
    }

    private async SendPipelinePlan prepare_send_pipeline(Conversation conversation, FileTransfer file_transfer) throws FileSendError {
        var file_meta = new FileMeta();
        file_meta.size = file_transfer.size;
        file_meta.mime_type = file_transfer.mime_type;

        string? encryption_rejection_reason = null;
        SendPipelinePlan? send_plan = yield select_send_pipeline(conversation, file_transfer, file_meta, out encryption_rejection_reason);
        if (send_plan == null) {
            if (encryption_rejection_reason != null && ((!) encryption_rejection_reason) != "") {
                warning("send_file: file encryption rejected: %s", (!) encryption_rejection_reason);
                throw new FileSendError.ENCRYPTION_FAILED((!) encryption_rejection_reason);
            }
            warning("send_file: no sender/encryptor available (encryption=%d size=%lld)",
                    (int) file_transfer.encryption,
                    (int64) file_transfer.size);
            throw new FileSendError.UPLOAD_FAILED("No sender/encryptor combination available");
        }

        SendPipelinePlan plan = (!) send_plan;
        debug("send_file: selected sender id=%d prio=%f encryptor=%s",
              plan.file_sender.get_id(),
              plan.file_sender.get_priority(),
              plan.file_encryptor != null ? ((!) plan.file_encryptor).get_type().name() : "(none)");
        return plan;
    }

    private async SendPipelinePlan? select_send_pipeline(Conversation conversation, FileTransfer file_transfer, FileMeta file_meta,
            out string? encryption_rejection_reason) throws FileSendError {
        encryption_rejection_reason = null;
        foreach (FileSender sender in file_senders) {
            if (file_transfer.preferred_file_sender_id != NO_REQUIRED_FILE_SENDER_ID &&
                    sender.get_id() != file_transfer.preferred_file_sender_id) {
                continue;
            }

            bool can_send = yield sender.can_send(conversation, file_transfer);
            if (file_transfer.cancellable.is_cancelled()) {
                throw new FileSendError.UPLOAD_FAILED("File transfer was cancelled");
            }
            if (!can_send) continue;

            if (file_transfer.encryption == Encryption.NONE) {
                return new SendPipelinePlan(sender, null, file_meta);
            }

            bool sender_can_encrypt = yield sender.can_encrypt(conversation, file_transfer);
            if (file_transfer.cancellable.is_cancelled()) {
                throw new FileSendError.UPLOAD_FAILED("File transfer was cancelled");
            }
            if (sender_can_encrypt) {
                return new SendPipelinePlan(sender, null, file_meta);
            }

            FileEncryptor? file_encryptor = select_file_encryptor(conversation, file_transfer);
            if (file_encryptor == null) {
                string? reason = get_file_encryptor_rejection_reason(conversation, file_transfer);
                if (reason != null && ((!) reason) != "") encryption_rejection_reason = reason;
                continue;
            }

            int required_sender_id = get_required_file_sender_id((!) file_encryptor);
            if (required_sender_id != NO_REQUIRED_FILE_SENDER_ID && sender.get_id() != required_sender_id) {
                debug("Skipping sender id=%d for file encryptor requiring sender id=%d",
                        sender.get_id(), required_sender_id);
                continue;
            }

            return new SendPipelinePlan(sender, file_encryptor, file_meta);
        }

        return null;
    }

    private FileEncryptor? select_file_encryptor(Conversation conversation, FileTransfer file_transfer) {
        foreach (FileEncryptor encryptor in file_encryptors) {
            if (encryptor.can_encrypt_file(conversation, file_transfer)) {
                return encryptor;
            }
        }
        return null;
    }

    private string? get_file_encryptor_rejection_reason(Conversation conversation, FileTransfer file_transfer) {
        foreach (FileEncryptor encryptor in file_encryptors) {
            FileEncryptorRejectionReason? rejection_reason = encryptor as FileEncryptorRejectionReason;
            if (rejection_reason == null) continue;

            string? reason = ((!) rejection_reason).get_file_encryption_rejection_reason(conversation, file_transfer);
            if (reason != null && ((!) reason) != "") return reason;
        }
        return null;
    }

    private async FileSendData prepare_send_data(Conversation conversation, FileTransfer file_transfer, SendPipelinePlan send_plan) throws Error {
        file_transfer.set_transfer_phase(FileTransfer.Phase.REQUESTING_SLOT);
        FileSendData? file_send_data = yield send_plan.file_sender.prepare_send_file(conversation, file_transfer, send_plan.file_meta);
        throw_if_transfer_cancelled(file_transfer);

        if (file_send_data == null) {
            throw new FileSendError.UPLOAD_FAILED("Failed to prepare file upload (no send data returned)");
        }

        if (send_plan.file_encryptor != null) {
            file_send_data = ((!) send_plan.file_encryptor).preprocess_send_file(conversation, file_transfer, (!) file_send_data, send_plan.file_meta);
            if (file_send_data == null) {
                throw new FileSendError.UPLOAD_FAILED("Selected sender is incompatible with file encryption");
            }
        }
        throw_if_transfer_cancelled(file_transfer);

        return (!) file_send_data;
    }

    internal async void send_file_transport_pipeline_for_tests(Conversation conversation, FileTransfer file_transfer) throws Error {
        bind_outgoing_send_target(conversation, file_transfer);
        yield send_file_transport_pipeline(conversation, file_transfer);
    }

    private async void encrypt_outgoing_file_if_needed(Conversation conversation, FileTransfer file_transfer, SendPipelinePlan send_plan) throws Error {
        if (send_plan.file_encryptor == null) return;

        Binding? progress_binding = null;
        try {
            file_transfer.set_transfer_phase(FileTransfer.Phase.ENCRYPTING);
            file_transfer.transferred_bytes = 0;
            file_transfer.input_stream = track_input_progress(file_transfer, file_transfer.input_stream, file_transfer.size, ref progress_binding);
            send_plan.file_meta = yield ((!) send_plan.file_encryptor).encrypt_file(conversation, file_transfer);
            validate_external_file_encryptor_meta(file_transfer, send_plan.file_meta);
            throw_if_transfer_cancelled(file_transfer);
            finish_progress_tracking(file_transfer, file_transfer.size, ref progress_binding);
        } finally {
            stop_progress_tracking(ref progress_binding);
        }
    }

    public static bool file_encryptor_accepts_sender(FileEncryptor file_encryptor, int sender_id) {
        int required_sender_id = get_required_file_sender_id(file_encryptor);
        return required_sender_id == NO_REQUIRED_FILE_SENDER_ID || required_sender_id == sender_id;
    }

    private static int get_required_file_sender_id(FileEncryptor file_encryptor) {
        FileEncryptorSenderRequirement? sender_requirement = file_encryptor as FileEncryptorSenderRequirement;
        if (sender_requirement == null) return NO_REQUIRED_FILE_SENDER_ID;
        return ((!) sender_requirement).get_required_file_sender_id();
    }

    public static void validate_external_file_encryptor_meta(FileTransfer file_transfer, FileMeta file_meta) throws FileSendError {
        if (file_transfer.encryption != Encryption.NONE && !file_meta.upload_payload_is_encrypted) {
            throw new FileSendError.ENCRYPTION_FAILED("External file encryptor did not mark the upload payload as encrypted");
        }
    }

    private async void send_outgoing_file_data(Conversation conversation, FileTransfer file_transfer, SendPipelinePlan send_plan, FileSendData file_send_data) throws Error {
        Binding? progress_binding = null;
        TransferProgressWatchdog? progress_watchdog = null;
        try {
            file_transfer.set_transfer_phase(FileTransfer.Phase.UPLOADING);
            file_transfer.transferred_bytes = 0;
            file_transfer.input_stream = track_input_progress(file_transfer, file_transfer.input_stream, send_plan.file_meta.size, ref progress_binding);
            progress_watchdog = new TransferProgressWatchdog(file_transfer, "upload");
            try {
                yield send_plan.file_sender.send_file(conversation, file_transfer, file_send_data, send_plan.file_meta);
                throw_if_progress_watchdog_timed_out(progress_watchdog);
            } catch (IOError.CANCELLED e) {
                throw_if_progress_watchdog_timed_out(progress_watchdog);
                throw e;
            } finally {
                stop_transfer_progress_watchdog(ref progress_watchdog);
            }
            throw_if_transfer_cancelled(file_transfer);
            finish_progress_tracking(file_transfer, send_plan.file_meta.size, ref progress_binding);
        } finally {
            stop_transfer_progress_watchdog(ref progress_watchdog);
            stop_progress_tracking(ref progress_binding);
        }
    }

    public async bool is_upload_available(Conversation? conversation) {
        if (conversation == null) return false;

        foreach (FileSender file_sender in file_senders) {
            if (yield file_sender.is_upload_available(conversation)) return true;
        }
        return false;
    }

    public void add_provider(FileProvider file_provider) {
        file_providers.add(file_provider);
        file_provider.file_incoming.connect((info, from, time, local_time, conversation, receive_data, file_meta) => {
            receive_file_from_provider.begin(file_provider, info, from, time, local_time, conversation, receive_data, file_meta, false, (_, res) => {
                receive_file_from_provider.end(res);
            });
        });
        file_provider.download_source_changed.connect((info) => {
            on_download_source_changed(file_provider, info);
        });
    }

    private void on_download_source_changed(FileProvider file_provider, string info) {
        string key = get_provider_source_key(file_provider.get_id(), info);
        FileTransfer? file_transfer = live_received_transfers_by_source[key];
        if (file_transfer == null) return;

        if (((!) file_transfer).provider == JINGLE_PROVIDER_ID &&
                ((!) file_transfer).direction == FileTransfer.DIRECTION_RECEIVED) {
            ((!) file_transfer).set_transient_download_source_available(false);
            live_received_transfers_by_source.unset(key);
        }

        if (((!) file_transfer).provider == JINGLE_PROVIDER_ID &&
                ((!) file_transfer).direction == FileTransfer.DIRECTION_RECEIVED &&
                ((!) file_transfer).state == FileTransfer.State.NOT_STARTED &&
                !has_usable_download_source((!) file_transfer)) {
            ((!) file_transfer).set_transfer_phase(FileTransfer.Phase.FAILED, DIRECT_TRANSFER_UNAVAILABLE_ERROR);
            cancel_scheduled_transfer_retry((!) file_transfer);
            ((!) file_transfer).clear_retry_schedule();
        }
        ((!) file_transfer).sources_changed();
    }

    public void add_sender(FileSender file_sender) {
        file_senders.add(file_sender);
        file_sender.upload_available.connect((account) => {
            upload_available(account);
        });
        file_senders.sort((a, b) => {
            return (int) (b.get_priority() - a.get_priority());
        });
    }

    public void add_file_encryptor(FileEncryptor encryptor) {
        file_encryptors.add(encryptor);
    }

    public void add_file_decryptor(FileDecryptor decryptor) {
        file_decryptors.add(decryptor);
    }

    public void add_metadata_provider(FileMetadataProvider file_metadata_provider) {
        file_metadata_providers.add(file_metadata_provider);
    }

    public bool is_sender_trustworthy(FileTransfer file_transfer, Conversation conversation) {
        if (file_transfer.direction == FileTransfer.DIRECTION_SENT) return true;

        Jid relevant_jid = conversation.counterpart;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            relevant_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(file_transfer.from, conversation.account);
        }
        if (relevant_jid == null) return false;

        bool in_roster = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).get_roster_item(conversation.account, relevant_jid) != null;
        return in_roster;
    }

    private async FileMeta get_file_meta(FileProvider file_provider, FileTransfer file_transfer, Conversation conversation, FileReceiveData receive_data_) throws FileReceiveError, IOError {
        FileReceiveData receive_data = receive_data_;
        FileMeta file_meta = file_provider.get_file_meta(file_transfer);

        if (file_meta.size == -1) {
            foreach (FileDecryptor file_decryptor in file_decryptors) {
                if (file_decryptor.can_decrypt_file(conversation, file_transfer, receive_data)) {
                    receive_data = file_decryptor.prepare_get_meta_info(conversation, file_transfer, receive_data);
                    break;
                }
            }

            file_meta = yield file_provider.get_meta_info(file_transfer, receive_data, file_meta);

            file_meta.apply_transport_fields_to_transfer(file_transfer);
            apply_incoming_receive_classification(
                    file_transfer,
                    classify_incoming_receive(file_provider, conversation, file_transfer, receive_data, file_meta),
                    true);
        }
        return file_meta;
    }

    internal static async FileMeta prepare_provider_metadata_for_tests(FileProvider file_provider, FileTransfer file_transfer, FileReceiveData receive_data) throws FileReceiveError, IOError {
        FileMeta file_meta = file_provider.get_file_meta(file_transfer);
        if (file_meta.size == -1) {
            file_meta = yield file_provider.get_meta_info(file_transfer, receive_data, file_meta);
            file_meta.apply_transport_fields_to_transfer(file_transfer);
        }
        return file_meta;
    }

    private FileDecryptor? select_file_decryptor(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
        foreach (FileDecryptor decryptor in file_decryptors) {
            if (decryptor.can_decrypt_file(conversation, file_transfer, receive_data)) {
                return decryptor;
            }
        }
        return null;
    }

    private async ReceivePipelinePlan prepare_receive_pipeline(FileProvider file_provider, FileTransfer file_transfer, Conversation conversation, FileReceiveData initial_receive_data) throws FileReceiveError, IOError {
        FileReceiveData receive_data = initial_receive_data;
        FileDecryptor? file_decryptor = select_file_decryptor(conversation, file_transfer, receive_data);

        if (file_decryptor != null) {
            receive_data = ((!) file_decryptor).prepare_get_meta_info(conversation, file_transfer, receive_data);
        }

        FileMeta file_meta = yield get_file_meta(file_provider, file_transfer, conversation, receive_data);

        if (file_decryptor == null) {
            file_decryptor = select_file_decryptor(conversation, file_transfer, receive_data);
        }

        if (file_decryptor != null) {
            int64 transport_size = file_meta.size;
            file_meta = ((!) file_decryptor).prepare_download_file(conversation, file_transfer, receive_data, file_meta);
            file_meta.apply_safe_fields_to_transfer(file_transfer);
            file_meta.size = transport_size;
        }

        return new ReceivePipelinePlan(receive_data, file_meta, file_decryptor);
    }

    internal async bool prepare_receive_pipeline_has_decryptor_for_tests(FileProvider file_provider, FileTransfer file_transfer, Conversation conversation, FileReceiveData initial_receive_data) throws FileReceiveError, IOError {
        ReceivePipelinePlan receive_plan = yield prepare_receive_pipeline(file_provider, file_transfer, conversation, initial_receive_data);
        return receive_plan.file_decryptor != null;
    }

    private async void download_file_internal(FileProvider file_provider, FileTransfer file_transfer, Conversation conversation, ReceiveDownloadMode mode) {
        if (!file_transfer.can_start_receive_attempt(SFS_PROVIDER_ID, HTTP_PROVIDER_ID)) {
            debug("Ignoring download request for '%s' in state %d",
                    file_transfer.file_name ?? "(unknown)", (int) file_transfer.state);
            return;
        }

        File? encrypted_download_file = null;
        InputStream? active_input_stream = null;
        Binding? progress_binding = null;
        try {
            // Get meta info
            FileReceiveData? receive_data = file_provider.get_file_receive_data(file_transfer);
            if (receive_data == null) {
                debug("Don't have download data (yet)");
                return;
            }
            file_transfer.prepare_transfer_attempt();
            file_transfer.set_transfer_phase(FileTransfer.Phase.PREPARING);
            file_transfer.transferred_bytes = 0;
            ReceivePipelinePlan receive_plan = yield prepare_receive_pipeline(file_provider, file_transfer, conversation, receive_data);

            ReceiveDownloadStage download_stage = yield download_receive_stream(file_provider, file_transfer, conversation, receive_plan);
            InputStream input_stream = download_stage.input_stream;
            encrypted_download_file = download_stage.encrypted_download_file;
            progress_binding = download_stage.progress_binding;
            active_input_stream = input_stream;

            // The store phase owns the stream and uses its own progress binding.
            stop_progress_tracking(ref progress_binding);
            active_input_stream = null;
            yield store_receive_stream_to_local(file_transfer, input_stream, receive_plan);

            delete_unreleased_download(encrypted_download_file, file_transfer.file_name);
            encrypted_download_file = null;
            cancel_scheduled_transfer_retry(file_transfer);
            file_transfer.clear_retry_schedule();
        } catch (IOError.CANCELLED e) {
            debug("cancelled");
            stop_progress_tracking(ref progress_binding);
            yield cleanup_unreleased_receive_files(file_transfer, active_input_stream, null, null, null, encrypted_download_file);
            file_transfer.clear_retry_schedule();
            if (file_transfer.provider == JINGLE_PROVIDER_ID) {
                file_transfer.set_transient_download_source_available(false);
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, DIRECT_TRANSFER_UNAVAILABLE_ERROR);
            } else {
                file_transfer.set_transfer_phase(FileTransfer.Phase.NONE);
            }
        } catch (FileReceiveError.DECRYPTION_FAILED e) {
            warning("Error downloading file: %s", e.message);
            stop_progress_tracking(ref progress_binding);
            file_transfer.clear_retry_schedule();
            if (file_transfer.provider == JINGLE_PROVIDER_ID) {
                file_transfer.set_transient_download_source_available(false);
            }
            file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, e.message);
            yield cleanup_unreleased_receive_files(file_transfer, active_input_stream, null, null, null, encrypted_download_file);
        } catch (Error e) {
            stop_progress_tracking(ref progress_binding);
            bool direct_transfer_consumed = file_transfer.provider == JINGLE_PROVIDER_ID;
            if (direct_transfer_consumed) {
                file_transfer.set_transient_download_source_available(false);
            }
            if (!direct_transfer_consumed && mode == ReceiveDownloadMode.AUTOMATIC && is_soft_auto_download_error(e)) {
                debug("Auto-download failed for '%s': %s", file_transfer.file_name ?? "(unknown)", e.message);
                file_transfer.set_transfer_phase(FileTransfer.Phase.NONE);
                schedule_receive_retry(file_transfer, file_provider, conversation, mode, e);
            } else {
                warning("Error downloading file: %s", e.message);
                file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED,
                    direct_transfer_consumed ? DIRECT_TRANSFER_UNAVAILABLE_ERROR : e.message);
                schedule_receive_retry(file_transfer, file_provider, conversation, mode, e);
            }
            yield cleanup_unreleased_receive_files(file_transfer, active_input_stream, null, null, null, encrypted_download_file);
        }
    }

    private async ReceiveDownloadStage download_receive_stream(FileProvider file_provider, FileTransfer file_transfer, Conversation conversation, ReceivePipelinePlan receive_plan) throws Error {
        ReceiveDownloadStage payload_stage = yield download_receive_payload(file_provider, file_transfer, receive_plan.receive_data, receive_plan.file_meta);
        return yield decrypt_receive_payload_if_needed(file_transfer, conversation, receive_plan, payload_stage, get_storage_dir());
    }

    private async ReceiveDownloadStage download_receive_payload(FileProvider file_provider, FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws Error {
        InputStream? active_input_stream = null;
        Binding? progress_binding = null;

        try {
            file_transfer.set_transfer_phase(FileTransfer.Phase.DOWNLOADING);
            InputStream download_input_stream = yield file_provider.download(file_transfer, receive_data, file_meta);
            InputStream input_stream = track_input_progress(file_transfer, download_input_stream, file_meta.size, ref progress_binding);
            active_input_stream = input_stream;

            return new ReceiveDownloadStage(input_stream, null, progress_binding);
        } catch (Error e) {
            stop_progress_tracking(ref progress_binding);
            yield close_active_input_stream(active_input_stream, null);
            throw e;
        }
    }

    internal static async void decrypt_received_payload_for_tests(FileTransfer file_transfer, Conversation conversation, InputStream input_stream, FileMeta file_meta, FileDecryptor file_decryptor, string storage_dir) throws Error {
        var receive_plan = new ReceivePipelinePlan(new FileReceiveData(), file_meta, file_decryptor);
        ReceiveDownloadStage? decrypted_stage = null;
        try {
            decrypted_stage = yield decrypt_receive_payload_if_needed(
                    file_transfer, conversation, receive_plan, new ReceiveDownloadStage(input_stream, null, null), storage_dir);
        } finally {
            if (decrypted_stage != null) {
                ReceiveDownloadStage stage = (!) decrypted_stage;
                yield close_active_input_stream(stage.input_stream, null);
                delete_unreleased_download(stage.encrypted_download_file, file_transfer.file_name);
            }
        }
    }

    internal static async File decrypt_and_store_received_file_for_tests(FileEncryption file_encryption, FileTransfer file_transfer, Conversation conversation, InputStream input_stream, FileMeta file_meta, FileDecryptor file_decryptor, string storage_dir) throws Error {
        var receive_plan = new ReceivePipelinePlan(new FileReceiveData(), file_meta, file_decryptor);
        ReceiveDownloadStage? decrypted_stage = null;
        try {
            decrypted_stage = yield decrypt_receive_payload_if_needed(
                    file_transfer, conversation, receive_plan, new ReceiveDownloadStage(input_stream, null, null), storage_dir);
            ReceiveDownloadStage stage = (!) decrypted_stage;
            ReceiveStoredStage stored_stage = yield store_receive_stream_to_storage(
                    file_encryption, file_transfer, stage.input_stream, receive_plan, storage_dir);
            delete_unreleased_download(stage.encrypted_download_file, file_transfer.file_name);
            stage.encrypted_download_file = null;
            return stored_stage.file;
        } finally {
            if (decrypted_stage != null) {
                ReceiveDownloadStage stage = (!) decrypted_stage;
                yield close_active_input_stream(stage.input_stream, null);
                delete_unreleased_download(stage.encrypted_download_file, file_transfer.file_name);
            }
        }
    }

    private static async ReceiveDownloadStage decrypt_receive_payload_if_needed(FileTransfer file_transfer, Conversation conversation, ReceivePipelinePlan receive_plan, ReceiveDownloadStage download_stage, string storage_dir) throws Error {
        FileDecryptor? file_decryptor = receive_plan.file_decryptor;
        if (file_decryptor == null) {
            return download_stage;
        }

        File? encrypted_download_file = null;
        OutputStream? encrypted_download_output = null;
        InputStream? active_input_stream = download_stage.input_stream;
        Binding? progress_binding = download_stage.progress_binding;

        try {
            InputStream input_stream = download_stage.input_stream;

            string encrypted_pending_filename = ".download-encrypted-" + Random.next_int().to_string("%x") + "-" + Random.next_int().to_string("%x") + ".part";
            encrypted_download_file = File.new_for_path(Path.build_filename(storage_dir, encrypted_pending_filename));
            encrypted_download_output = ((!) encrypted_download_file).create(FileCreateFlags.PRIVATE);
            TransferProgressWatchdog? progress_watchdog = new TransferProgressWatchdog(file_transfer, "download");
            try {
                yield copy_stream_to_output(input_stream, (!) encrypted_download_output, file_transfer.cancellable);
                throw_if_progress_watchdog_timed_out(progress_watchdog);
            } catch (IOError.CANCELLED e) {
                throw_if_progress_watchdog_timed_out(progress_watchdog);
                throw e;
            } finally {
                stop_transfer_progress_watchdog(ref progress_watchdog);
            }
            finish_progress_tracking(file_transfer, receive_plan.file_meta.size, ref progress_binding);
            yield input_stream.close_async(Priority.LOW, file_transfer.cancellable);
            active_input_stream = null;
            yield ((!) encrypted_download_output).close_async(Priority.LOW, file_transfer.cancellable);
            encrypted_download_output = null;

            input_stream = yield ((!) encrypted_download_file).read_async(Priority.LOW, file_transfer.cancellable);
            active_input_stream = input_stream;
            file_transfer.set_transfer_phase(FileTransfer.Phase.DECRYPTING);
            file_transfer.transferred_bytes = 0;
            if (receive_plan.decrypts_before_return) {
                input_stream = track_input_progress(file_transfer, input_stream, receive_plan.file_meta.size, ref progress_binding);
                active_input_stream = input_stream;
            }
            input_stream = yield ((!) file_decryptor).decrypt_file(input_stream, conversation, file_transfer, receive_plan.receive_data);
            if (receive_plan.decrypts_before_return) {
                finish_progress_tracking(file_transfer, receive_plan.file_meta.size, ref progress_binding);
            }
            active_input_stream = input_stream;

            return new ReceiveDownloadStage(input_stream, encrypted_download_file, null);
        } catch (Error e) {
            stop_progress_tracking(ref progress_binding);
            yield close_active_input_stream(active_input_stream, null);
            close_pending_output(encrypted_download_output);
            delete_unreleased_download(encrypted_download_file, file_transfer.file_name);
            throw e;
        }
    }

    private async ReceiveStoredStage store_receive_stream_to_local(FileTransfer file_transfer, InputStream input_stream, ReceivePipelinePlan receive_plan) throws Error {
        return yield store_receive_stream_to_storage(file_encryption, file_transfer, input_stream, receive_plan, get_storage_dir());
    }

    internal static async File store_received_file_for_tests(FileEncryption file_encryption, FileTransfer file_transfer, InputStream input_stream, string storage_dir) throws Error {
        var file_meta = new FileMeta();
        file_meta.file_name = file_transfer.file_name;
        file_meta.mime_type = file_transfer.mime_type;
        file_meta.size = file_transfer.size;

        var receive_plan = new ReceivePipelinePlan(new FileReceiveData(), file_meta, null);
        ReceiveStoredStage stored_stage = yield store_receive_stream_to_storage(file_encryption, file_transfer, input_stream, receive_plan, storage_dir);
        return stored_stage.file;
    }

    private static async ReceiveStoredStage store_receive_stream_to_storage(FileEncryption file_encryption, FileTransfer file_transfer, InputStream input_stream, ReceivePipelinePlan receive_plan, string storage_dir) throws Error {
        ReceiveStoreTarget? store_target = null;
        VerifiedPlaintextMeta? verified_plaintext_meta = get_verified_plaintext_meta(input_stream);

        try {
            store_target = prepare_receive_store_target(file_transfer, storage_dir);
            ReceiveStoreTarget target = (!) store_target;
            OutputStream pending_output = (!) target.pending_output;
            ReceivePendingStoreStage pending_stage = yield encrypt_receive_stream_to_pending(file_encryption, file_transfer, input_stream, receive_plan, pending_output, verified_plaintext_meta);
            yield pending_output.close_async(Priority.LOW, file_transfer.cancellable);
            target.pending_output = null;

            File committed_file = yield verify_and_commit_received_file(file_transfer, file_encryption, (!) target.pending_file, target.final_file, pending_stage.plaintext_size, pending_stage.plaintext_prefix, pending_stage.verified_plaintext_meta);
            target.pending_file = null;

            return new ReceiveStoredStage(committed_file, pending_stage.plaintext_prefix, pending_stage.plaintext_size, pending_stage.verified_plaintext_meta);
        } catch (Error e) {
            if (store_target != null) {
                close_pending_output(((!) store_target).pending_output);
                delete_unreleased_download(((!) store_target).pending_file, file_transfer.file_name);
            }
            throw e;
        }
    }

    private static ReceiveStoreTarget prepare_receive_store_target(FileTransfer file_transfer, string storage_dir) throws Error {
        // Save file into a private pending path first. The transfer is only
        // published to the chat item after decrypt/hash verification passed.
        string safe_basename = Path.get_basename(file_transfer.file_name);
        string filename = Random.next_int().to_string("%x") + "_" + safe_basename;
        string pending_filename = ".download-" + Random.next_int().to_string("%x") + "-" + filename + ".part";
        File pending_file = File.new_for_path(Path.build_filename(storage_dir, pending_filename));
        File final_file = File.new_for_path(Path.build_filename(storage_dir, filename));
        OutputStream pending_output = pending_file.create(FileCreateFlags.PRIVATE);
        return new ReceiveStoreTarget(pending_file, final_file, pending_output);
    }

    private static async ReceivePendingStoreStage encrypt_receive_stream_to_pending(FileEncryption file_encryption, FileTransfer file_transfer, InputStream input_stream, ReceivePipelinePlan receive_plan, OutputStream pending_output, VerifiedPlaintextMeta? verified_plaintext_meta) throws Error {
        InputStream? active_input_stream = input_stream;
        Binding? progress_binding = null;
        TransferProgressWatchdog? progress_watchdog = null;

        try {
            file_transfer.set_transfer_phase(receive_plan.get_store_phase());
            file_transfer.transferred_bytes = 0;
            InputStream tracked_input_stream = track_input_progress(file_transfer, input_stream, receive_plan.get_store_progress_total(file_transfer), ref progress_binding);
            var sniffing_stream = new PrefixSniffingInputStream(tracked_input_stream);
            active_input_stream = sniffing_stream;
            progress_watchdog = new TransferProgressWatchdog(file_transfer, "store");
            try {
                yield FileTransferWorker.run("store-received-file", () => {
                    file_encryption.encrypt_stream_sync(sniffing_stream, pending_output, file_transfer.cancellable);
                });
                throw_if_progress_watchdog_timed_out(progress_watchdog);
            } catch (IOError.CANCELLED e) {
                throw_if_progress_watchdog_timed_out(progress_watchdog);
                throw e;
            } finally {
                stop_transfer_progress_watchdog(ref progress_watchdog);
            }
            uint8[] plaintext_prefix = sniffing_stream.get_prefix();
            int64 plaintext_size = sniffing_stream.get_passed_bytes();
            finish_progress_tracking(file_transfer, plaintext_size, ref progress_binding);

            yield sniffing_stream.close_async(Priority.LOW, file_transfer.cancellable);
            active_input_stream = null;

            return new ReceivePendingStoreStage(plaintext_prefix, plaintext_size, verified_plaintext_meta);
        } catch (Error e) {
            stop_transfer_progress_watchdog(ref progress_watchdog);
            stop_progress_tracking(ref progress_binding);
            yield close_active_input_stream(active_input_stream, null);
            throw e;
        }
    }

    private static VerifiedPlaintextMeta? get_verified_plaintext_meta(InputStream input_stream) {
        VerifiedPlaintextMetaCarrier? carrier = input_stream as VerifiedPlaintextMetaCarrier;
        if (carrier == null) return null;
        return ((!) carrier).get_verified_plaintext_meta();
    }

    private static void apply_verified_plaintext_meta_after_store(FileTransfer file_transfer, VerifiedPlaintextMeta? meta) {
        if (meta == null) return;
        ((!) meta).apply_to_transfer(file_transfer);
    }

    public static async File verify_and_commit_received_file(FileTransfer file_transfer, FileEncryption file_encryption, File pending_file, File final_file, int64 plaintext_size, uint8[] plaintext_prefix, VerifiedPlaintextMeta? verified_plaintext_meta) throws FileReceiveError, Error {
        yield verify_received_pending_file(file_transfer, file_encryption, pending_file, plaintext_size);
        File committed_file = yield commit_verified_received_file(file_transfer, pending_file, final_file);
        publish_committed_received_file(file_transfer, committed_file, plaintext_size, plaintext_prefix, verified_plaintext_meta);
        return committed_file;
    }

    private static async void verify_received_pending_file(FileTransfer file_transfer, FileEncryption file_encryption, File pending_file, int64 plaintext_size) throws FileReceiveError, Error {
        bool empty_media_payload = is_empty_received_media_payload(file_transfer, plaintext_size);
        if (requires_received_file_verification(file_transfer) || empty_media_payload) {
            file_transfer.set_transfer_phase(FileTransfer.Phase.VERIFYING);
        }
        if (empty_media_payload) {
            throw new FileReceiveError.DECRYPTION_FAILED(RECEIVED_MEDIA_EMPTY_ERROR);
        }
        yield verify_pending_download_hashes(file_encryption, file_transfer, pending_file, plaintext_size);
    }

    private static bool is_empty_received_media_payload(FileTransfer file_transfer, int64 plaintext_size) {
        if (plaintext_size != 0) return false;
        string? normalized_mime = Dino.normalize_display_mime_type(file_transfer.mime_type, file_transfer.file_name);
        return is_media_mime(normalized_mime);
    }

    private static async File commit_verified_received_file(FileTransfer file_transfer, File pending_file, File final_file) throws Error {
        yield FileTransferWorker.run_publish("commit-received-file", () => {
            pending_file.move(final_file, FileCopyFlags.NONE, file_transfer.cancellable);
        });
        return final_file;
    }

    private static void publish_committed_received_file(FileTransfer file_transfer, File final_file, int64 plaintext_size, uint8[] plaintext_prefix, VerifiedPlaintextMeta? verified_plaintext_meta) {
        apply_verified_plaintext_meta_after_store(file_transfer, verified_plaintext_meta);
        file_transfer.path = final_file.get_basename();
        file_transfer.size = plaintext_size;

        file_transfer.set_transfer_phase(FileTransfer.Phase.PREVIEWING);
        update_mime_type_after_verified_store(file_transfer, plaintext_prefix);
        file_transfer.set_transfer_phase(FileTransfer.Phase.COMPLETE);
    }

    private static bool requires_received_file_verification(FileTransfer file_transfer) {
        if (file_transfer.encryption != Encryption.NONE) return true;
        return !Xep.CryptographicHashes.get_supported_hashes(file_transfer.hashes).is_empty;
    }

    private static InputStream track_input_progress(FileTransfer file_transfer, InputStream input, int64 total_bytes, ref Binding? progress_binding) {
        stop_progress_tracking(ref progress_binding);
        file_transfer.phase_total_bytes = total_bytes;

        LimitInputStream? limit_stream = input as LimitInputStream;
        if (limit_stream == null) {
            limit_stream = new LimitInputStream(input, total_bytes);
        }

        progress_binding = ((!) limit_stream).bind_property("retrieved-bytes", file_transfer, "transferred-bytes", BindingFlags.SYNC_CREATE);
        return (!) limit_stream;
    }

    private static void stop_progress_tracking(ref Binding? progress_binding) {
        if (progress_binding == null) return;
        ((!) progress_binding).unbind();
        progress_binding = null;
    }

    private static void finish_progress_tracking(FileTransfer file_transfer, int64 total_bytes, ref Binding? progress_binding) {
        if (total_bytes >= 0) {
            file_transfer.phase_total_bytes = total_bytes;
            file_transfer.transferred_bytes = total_bytes;
        }
        stop_progress_tracking(ref progress_binding);
    }

    private static void stop_transfer_progress_watchdog(ref TransferProgressWatchdog? progress_watchdog) {
        if (progress_watchdog == null) return;
        ((!) progress_watchdog).stop();
        progress_watchdog = null;
    }

    private static void throw_if_progress_watchdog_timed_out(TransferProgressWatchdog? progress_watchdog) throws IOError {
        if (progress_watchdog != null && ((!) progress_watchdog).timed_out) {
            throw new IOError.TIMED_OUT(FILE_TRANSFER_STALL_TIMEOUT_ERROR);
        }
    }

    public void arm_scheduled_transfer_retry(FileTransfer file_transfer) {
        if (file_transfer.next_retry_time <= 0) return;

        Conversation? conversation = resolve_file_transfer_conversation(file_transfer);
        if (conversation == null) return;

        if (file_transfer.can_start_receive_attempt(SFS_PROVIDER_ID, HTTP_PROVIDER_ID)) {
            FileProvider? file_provider = select_file_provider(file_transfer);
            if (file_provider == null) return;
            arm_receive_retry(file_transfer, (!) file_provider, (!) conversation, ReceiveDownloadMode.AUTOMATIC);
        } else if (file_transfer.can_retry_send_attempt()) {
            arm_send_retry(file_transfer, (!) conversation);
        }
    }

    private void arm_persisted_scheduled_transfer_retries() {
        FileTransferStorage? storage = stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY);
        if (storage == null) return;

        foreach (FileTransfer file_transfer in ((!) storage).get_scheduled_retry_files()) {
            arm_scheduled_transfer_retry(file_transfer);
        }
    }

    private void schedule_receive_retry(FileTransfer file_transfer, FileProvider file_provider, Conversation conversation, ReceiveDownloadMode mode, Error error) {
        if (!should_schedule_transfer_retry(file_transfer, error)) {
            file_transfer.next_retry_time = 0;
            return;
        }

        uint delay_seconds = get_transfer_retry_delay_seconds(file_transfer.retry_count);
        file_transfer.schedule_retry(delay_seconds);
        debug("Scheduling receive retry %d/%d in %u seconds for '%s': %s",
                file_transfer.retry_count,
                FILE_TRANSFER_AUTO_RETRY_MAX_ATTEMPTS,
                delay_seconds,
                file_transfer.file_name ?? "(unknown)",
                error.message);
        arm_receive_retry(file_transfer, file_provider, conversation, mode);
    }

    private void schedule_send_retry(FileTransfer file_transfer, Conversation conversation, Error error) {
        if (!should_schedule_transfer_retry(file_transfer, error)) {
            file_transfer.next_retry_time = 0;
            return;
        }

        uint delay_seconds = get_transfer_retry_delay_seconds(file_transfer.retry_count);
        file_transfer.schedule_retry(delay_seconds);
        debug("Scheduling send retry %d/%d in %u seconds for '%s': %s",
                file_transfer.retry_count,
                FILE_TRANSFER_AUTO_RETRY_MAX_ATTEMPTS,
                delay_seconds,
                file_transfer.file_name ?? "(unknown)",
                error.message);
        arm_send_retry(file_transfer, conversation);
    }

    private bool should_schedule_transfer_retry(FileTransfer file_transfer, Error error) {
        if (file_transfer.retry_count >= FILE_TRANSFER_AUTO_RETRY_MAX_ATTEMPTS) return false;
        if (!is_transient_transfer_error(error)) return false;

        if (file_transfer.can_start_receive_attempt(SFS_PROVIDER_ID, HTTP_PROVIDER_ID)) {
            return has_usable_download_source(file_transfer);
        }

        return file_transfer.can_retry_send_attempt();
    }

    private static bool is_transient_transfer_error(Error error) {
        // GIO messages follow the user's locale. Use the stable error code;
        // keep the text fallback only for providers which still wrap errors.
        if (error is IOError) {
            switch (error.code) {
                case IOError.TIMED_OUT:
                case IOError.CONNECTION_CLOSED:
                case IOError.CONNECTION_REFUSED:
                case IOError.NOT_CONNECTED:
                case IOError.HOST_UNREACHABLE:
                case IOError.NETWORK_UNREACHABLE:
                    return true;
                case IOError.FAILED:
                    break;
                default:
                    return false;
            }
        }
        string message = (error.message ?? "").down();
        if (message.contains("cancelled") || message.contains("canceled")) return false;
        if (message.contains("hash verification failed")) return false;
        if (message.contains("signature")) return false;
        if (message.contains("wrong signer")) return false;
        if (message.contains("decrypt")) return false;
        if (message.contains("no trusted openpgp key")) return false;
        if (message.contains("no sender")) return false;
        if (message.contains("incompatible with file encryption")) return false;

        return message.contains("timed out") ||
                message.contains("timeout") ||
                message.contains("zeitüberschreitung") ||
                message.contains("socket") ||
                message.contains("connection") ||
                message.contains("transport") ||
                message.contains("temporarily") ||
                message.contains("http upload") ||
                message.contains("http download") ||
                message.contains("upload slot");
    }

    private static bool is_user_cancelled_transfer_error(FileTransfer file_transfer, Error error) {
        return file_transfer.cancellable.is_cancelled() && !is_progress_watchdog_timeout_error(error);
    }

    private static bool is_progress_watchdog_timeout_error(Error error) {
        return error.message == FILE_TRANSFER_STALL_TIMEOUT_ERROR;
    }

    private static uint get_transfer_retry_delay_seconds(int retry_count) {
        switch (retry_count) {
            case 0: return 15;
            case 1: return 60;
            default: return 180;
        }
    }

    private uint get_retry_delay_until(long next_retry_time) {
        long now = (long) new DateTime.now_utc().to_unix();
        if (next_retry_time <= now) return 0;
        long delay = next_retry_time - now;
        return delay > 3600 ? 3600 : (uint) delay;
    }

    private void arm_receive_retry(FileTransfer file_transfer, FileProvider file_provider, Conversation conversation, ReceiveDownloadMode mode) {
        int retry_key = file_transfer.id;
        if (retry_key <= 0) return;

        cancel_scheduled_transfer_retry(file_transfer);
        uint delay_seconds = get_retry_delay_until(file_transfer.next_retry_time);
        uint source_id;
        if (delay_seconds == 0) {
            source_id = Idle.add(() => {
                scheduled_retry_sources.unset(retry_key);
                if (file_transfer.next_retry_time <= 0) return Source.REMOVE;
                if (!file_transfer.can_start_receive_attempt(SFS_PROVIDER_ID, HTTP_PROVIDER_ID)) return Source.REMOVE;
                if (!has_usable_download_source(file_transfer)) return Source.REMOVE;

                download_file_internal.begin(file_provider, file_transfer, conversation, mode, (_, res) => {
                    download_file_internal.end(res);
                });
                return Source.REMOVE;
            });
        } else {
            source_id = Timeout.add_seconds(delay_seconds, () => {
                scheduled_retry_sources.unset(retry_key);
                if (file_transfer.next_retry_time <= 0) return Source.REMOVE;
                if (!file_transfer.can_start_receive_attempt(SFS_PROVIDER_ID, HTTP_PROVIDER_ID)) return Source.REMOVE;
                if (!has_usable_download_source(file_transfer)) return Source.REMOVE;

                download_file_internal.begin(file_provider, file_transfer, conversation, mode, (_, res) => {
                    download_file_internal.end(res);
                });
                return Source.REMOVE;
            });
        }
        scheduled_retry_sources[retry_key] = source_id;
    }

    private void arm_send_retry(FileTransfer file_transfer, Conversation conversation) {
        int retry_key = file_transfer.id;
        if (retry_key <= 0) return;

        cancel_scheduled_transfer_retry(file_transfer);
        uint delay_seconds = get_retry_delay_until(file_transfer.next_retry_time);
        uint source_id;
        if (delay_seconds == 0) {
            source_id = Idle.add(() => {
                scheduled_retry_sources.unset(retry_key);
                if (file_transfer.next_retry_time <= 0) return Source.REMOVE;
                if (!file_transfer.can_retry_send_attempt()) return Source.REMOVE;

                retry_send_file_internal.begin(conversation, file_transfer, (_, res) => {
                    retry_send_file_internal.end(res);
                });
                return Source.REMOVE;
            });
        } else {
            source_id = Timeout.add_seconds(delay_seconds, () => {
                scheduled_retry_sources.unset(retry_key);
                if (file_transfer.next_retry_time <= 0) return Source.REMOVE;
                if (!file_transfer.can_retry_send_attempt()) return Source.REMOVE;

                retry_send_file_internal.begin(conversation, file_transfer, (_, res) => {
                    retry_send_file_internal.end(res);
                });
                return Source.REMOVE;
            });
        }
        scheduled_retry_sources[retry_key] = source_id;
    }

    private void cancel_scheduled_transfer_retry(FileTransfer file_transfer) {
        int retry_key = file_transfer.id;
        if (retry_key <= 0 || !scheduled_retry_sources.has_key(retry_key)) return;

        uint source_id = scheduled_retry_sources[retry_key];
        if (source_id != 0) Source.remove(source_id);
        scheduled_retry_sources.unset(retry_key);
    }

    private async void cleanup_unreleased_receive_files(FileTransfer file_transfer, InputStream? active_input_stream, OutputStream? pending_output, OutputStream? encrypted_download_output, File? pending_file, File? encrypted_download_file) {
        yield close_active_input_stream(active_input_stream, null);
        close_pending_output(pending_output);
        close_pending_output(encrypted_download_output);
        delete_unreleased_download(pending_file, file_transfer.file_name);
        delete_unreleased_download(encrypted_download_file, file_transfer.file_name);
    }

    private static async void verify_pending_download_hashes(FileEncryption file_encryption, FileTransfer file_transfer, File pending_file, int64 plaintext_size) throws FileReceiveError, Error {
        var supported_hashes = Xep.CryptographicHashes.get_supported_hashes(file_transfer.hashes);
        if (supported_hashes.is_empty) return;

        Binding? progress_binding = null;
        try {
            var checksum_types = new ArrayList<ChecksumType>();
            var hashes = new HashMap<ChecksumType, string>();
            foreach (var hash in supported_hashes) {
                var checksum_type = Xep.CryptographicHashes.hash_string_to_type(hash.algo);
                checksum_types.add(checksum_type);
                hashes[checksum_type] = hash.val;
            }

            // Hash the decrypted plaintext (decrypt at-rest encryption, then hash).
            var checksum_stream = new ChecksumOutputStream(checksum_types);
            var progress_stream = new ProgressOutputStream(checksum_stream);
            file_transfer.phase_total_bytes = plaintext_size;
            progress_binding = progress_stream.bind_property("written-bytes", file_transfer, "transferred-bytes", BindingFlags.SYNC_CREATE);
            yield FileTransferWorker.run("verify-received-file-hash", () => {
                file_encryption.decrypt_file_to_stream_sync(pending_file, progress_stream, file_transfer.cancellable);
            });
            finish_progress_tracking(file_transfer, plaintext_size, ref progress_binding);
            var computed_hashes = checksum_stream.get_hashes();

            foreach (var checksum_type in hashes.keys) {
                string expected = hashes[checksum_type];
                string computed = computed_hashes[checksum_type];

                if (!hashes_match(expected, computed)) {
                    warning("Hash mismatch for '%s': %s expected %s, got %s",
                            file_transfer.file_name, checksum_type.to_string(),
                            hashes[checksum_type], computed_hashes[checksum_type]);
                    throw new FileReceiveError.DECRYPTION_FAILED("Downloaded file hash verification failed");
                }
            }
        } finally {
            stop_progress_tracking(ref progress_binding);
        }
    }

    private static async void copy_stream_to_output(InputStream input, OutputStream output, Cancellable? cancellable = null) throws GLib.Error {
        uint8[] buffer = new uint8[65536];
        while (true) {
            ssize_t read = yield input.read_async(buffer, Priority.LOW, cancellable);
            if (read <= 0) break;
            yield output.write_all_async(buffer[0:(int) read], Priority.LOW, cancellable, null);
        }
    }

    private static void throw_if_transfer_cancelled(FileTransfer file_transfer) throws IOError {
        if (file_transfer.cancellable.is_cancelled()) {
            throw new IOError.CANCELLED("File transfer was cancelled");
        }
    }

    private static async void close_active_input_stream(InputStream? input, Cancellable? cancellable) {
        if (input == null) return;
        try {
            yield ((!) input).close_async(Priority.LOW, cancellable);
        } catch (Error close_error) {
            debug("Failed to close active download input stream: %s", close_error.message);
        }
    }

    private static void close_pending_output(OutputStream? output) {
        if (output == null) return;
        try {
            ((!) output).close(null);
        } catch (Error close_error) {
            debug("Failed to close unreleased download output: %s", close_error.message);
        }
    }

    private static void delete_unreleased_download(File? file, string? display_name) {
        if (file == null) return;
        try {
            ((!) file).delete(null);
        } catch (IOError.NOT_FOUND delete_error) {
            debug("Unreleased downloaded file '%s' was already removed: %s",
                    display_name ?? "(unknown)", delete_error.message);
        } catch (Error delete_error) {
            warning("Failed to delete unreleased downloaded file '%s': %s",
                    display_name ?? "(unknown)", delete_error.message);
        }
    }

    private static void update_mime_type_after_verified_store(FileTransfer file_transfer, uint8[] plaintext_prefix) {
        string? current = Dino.normalize_display_mime_type(file_transfer.mime_type, file_transfer.file_name);
        string? by_data = null;
        string? by_name = null;

        if (plaintext_prefix.length > 0) {
            bool data_uncertain;
            by_data = Dino.normalize_display_mime_type(ContentType.guess(null, plaintext_prefix, out data_uncertain), file_transfer.file_name);
            if (data_uncertain && !is_media_mime(by_data)) {
                by_data = null;
            }
        }

        bool name_uncertain;
        by_name = Dino.normalize_display_mime_type(ContentType.guess(file_transfer.file_name, null, out name_uncertain), file_transfer.file_name);
        if (name_uncertain && !is_media_mime(by_name)) {
            by_name = null;
        }

        string? selected = null;
        if (is_media_mime(by_data)) {
            selected = by_data;
        } else if (is_media_mime(by_name)) {
            selected = by_name;
        } else if (is_meaningful_mime(current)) {
            selected = current;
        } else if (is_meaningful_mime(by_data)) {
            selected = by_data;
        } else if (is_meaningful_mime(by_name)) {
            selected = by_name;
        }

        if (selected != null && selected != file_transfer.mime_type) {
            file_transfer.mime_type = selected;
        }
    }

    private static bool is_media_mime(string? mime_type) {
        if (mime_type == null) return false;
        string lower = ((!) mime_type).ascii_down();
        return lower.has_prefix("image/") || lower.has_prefix("video/") || lower.has_prefix("audio/");
    }

    private static bool is_meaningful_mime(string? mime_type) {
        if (mime_type == null || mime_type == "") return false;
        string lower = ((!) mime_type).ascii_down();
        return lower != "application/octet-stream" &&
            lower != "binary/octet-stream" &&
            !lower.has_prefix("application/x-ext-");
    }

    public FileTransfer create_file_transfer_from_provider_incoming(FileProvider file_provider, string info, Jid from, DateTime time, DateTime local_time, Conversation conversation, FileReceiveData receive_data, FileMeta file_meta) {
        FileTransfer file_transfer = create_incoming_file_transfer_shell(file_provider, info, from, time, local_time, conversation, file_meta);
        IncomingReceiveClassification classification = classify_incoming_receive(file_provider, conversation, file_transfer, receive_data, file_meta);
        apply_incoming_receive_classification(file_transfer, classification, false);

        return file_transfer;
    }

    private FileTransfer create_incoming_file_transfer_shell(FileProvider file_provider, string info, Jid from, DateTime time, DateTime local_time, Conversation conversation, FileMeta file_meta) {
        FileTransfer file_transfer = new FileTransfer();
        file_transfer.account = conversation.account;
        if (conversation.type_.is_muc_semantic() && !from.equals_bare(conversation.account.bare_jid)) {
            file_transfer.ourpart = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(conversation.counterpart, conversation.account) ?? conversation.account.bare_jid;
            file_transfer.direction = from.equals(file_transfer.ourpart) ? FileTransfer.DIRECTION_SENT : FileTransfer.DIRECTION_RECEIVED;
        } else {
            if (from.equals_bare(conversation.account.bare_jid)) {
                file_transfer.ourpart = from;
                file_transfer.direction = FileTransfer.DIRECTION_SENT;
            } else {
                file_transfer.ourpart = conversation.account.full_jid;
                file_transfer.direction = FileTransfer.DIRECTION_RECEIVED;
            }
        }
        file_transfer.counterpart = file_transfer.direction == FileTransfer.DIRECTION_RECEIVED ? from : conversation.counterpart;
        file_transfer.time = time;
        file_transfer.local_time = local_time;
        file_transfer.provider = file_provider.get_id();
        apply_incoming_file_meta_to_transfer_shell(file_transfer, file_meta);
        file_transfer.info = info;

        return file_transfer;
    }

    internal static void apply_incoming_file_meta_to_transfer_for_tests(FileTransfer file_transfer, FileMeta file_meta) {
        apply_incoming_file_meta_to_transfer_shell(file_transfer, file_meta);
    }

    private static void apply_incoming_file_meta_to_transfer_shell(FileTransfer file_transfer, FileMeta file_meta) {
        file_transfer.file_name = file_meta.file_name;
        file_transfer.mime_type = file_meta.mime_type != null && ((!) file_meta.mime_type).strip() != "" ? ((!) file_meta.mime_type).strip() : null;
        file_transfer.size = (int)file_meta.size;
        file_transfer.message_db_id = file_meta.message_db_id;
    }

    private IncomingReceiveClassification classify_incoming_receive(FileProvider file_provider, Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) {
        Encryption provider_encryption = file_provider.get_encryption(file_transfer, receive_data, file_meta);
        if (provider_encryption != Encryption.NONE) {
            return new IncomingReceiveClassification(provider_encryption, file_meta.encryption_protocol, null);
        }

        // Only let decryptors set the encryption type if the provider didn't already
        // determine it. This prevents e.g. the OMEMO decryptor from overwriting PGP
        // when both use aesgcm:// URLs for file transport.
        FileDecryptor? file_decryptor = select_file_decryptor(conversation, file_transfer, receive_data);

        return new IncomingReceiveClassification(provider_encryption, file_meta.encryption_protocol, file_decryptor);
    }

    private static void apply_incoming_receive_classification(FileTransfer file_transfer, IncomingReceiveClassification classification, bool only_if_unclassified) {
        bool can_apply_classification = !only_if_unclassified || file_transfer.encryption == Encryption.NONE;
        if (classification.transfer_encryption != Encryption.NONE &&
                can_apply_classification) {
            file_transfer.encryption = classification.transfer_encryption;
        }
        if (classification.provider_encryption_protocol != null &&
                can_apply_classification) {
            file_transfer.encryption_protocol = classification.provider_encryption_protocol;
        }
    }

    // A pasted outgoing file link already has a visible message. Announce its
    // replacement before waiting for network metadata, so the file card stays
    // visible and uses the same size limit and decryptors as incoming files.
    public async void receive_file_from_provider(FileProvider file_provider, string info, Jid from, DateTime time, DateTime local_time, Conversation conversation, FileReceiveData receive_data, FileMeta file_meta, bool announce_immediately = false) {
        FileTransfer file_transfer = create_file_transfer_from_provider_incoming(file_provider, info, from, time, local_time, conversation, receive_data, file_meta);
        if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
                file_transfer.provider == JINGLE_PROVIDER_ID) {
            live_received_transfers_by_source[get_provider_source_key(file_provider.get_id(), info)] = file_transfer;
            file_transfer.set_transient_download_source_available(true);
        }
        stream_interactor.get_module<FileTransferStorage>(FileTransferStorage.IDENTITY).add_file(file_transfer);
        bool fetch_metadata = is_sender_trustworthy(file_transfer, conversation);
        if (announce_immediately) {
            if (fetch_metadata) file_transfer.set_transfer_phase(FileTransfer.Phase.PREPARING);
            conversation.last_active = file_transfer.time;
            received_file(file_transfer, conversation);
        }

        if (fetch_metadata) {
            try {
                if (announce_immediately) throw_if_transfer_cancelled(file_transfer);
                yield get_file_meta(file_provider, file_transfer, conversation, receive_data);
                if (announce_immediately) {
                    throw_if_transfer_cancelled(file_transfer);
                    file_transfer.set_transfer_phase(FileTransfer.Phase.NONE);
                }
            } catch (Error e) {
                if (announce_immediately && e is IOError.CANCELLED) {
                    file_transfer.set_transfer_phase(FileTransfer.Phase.NONE);
                    file_transfer.clear_retry_schedule();
                    return;
                }
                if (is_soft_auto_download_error(e)) {
                    debug("Auto-download metadata failed for '%s': %s", file_transfer.file_name ?? "(unknown)", e.message);
                    file_transfer.set_transfer_phase(FileTransfer.Phase.NONE);
                    schedule_receive_retry(file_transfer, file_provider, conversation, ReceiveDownloadMode.AUTOMATIC, e);
                } else {
                    warning("Error downloading file: %s", e.message);
                    file_transfer.set_transfer_phase(FileTransfer.Phase.FAILED, e.message);
                    schedule_receive_retry(file_transfer, file_provider, conversation, ReceiveDownloadMode.AUTOMATIC, e);
                }
                if (announce_immediately) return;
            }
            if (file_transfer.size >= 0 && file_transfer.size < 5000000) {
                download_file_internal.begin(file_provider, file_transfer, conversation, ReceiveDownloadMode.AUTOMATIC, (_, res) => {
                    download_file_internal.end(res);
                });
            }
        }

        if (!announce_immediately) {
            conversation.last_active = file_transfer.time;
            received_file(file_transfer, conversation);
        }
    }

    private async void save_file(FileTransfer file_transfer) throws FileSendError {
        yield save_outgoing_file(file_encryption, file_transfer, file_transfer.input_stream, get_storage_dir());
    }

    internal static async File save_outgoing_file_for_tests(FileEncryption file_encryption, FileTransfer file_transfer, InputStream input_stream, string storage_dir, string? forced_filename = null) throws FileSendError {
        return yield save_outgoing_file(file_encryption, file_transfer, input_stream, storage_dir, forced_filename);
    }

    internal static void delete_unpublished_outgoing_file_for_tests(FileTransfer file_transfer, string storage_dir, string? storage_path) {
        delete_unpublished_outgoing_file(file_transfer, storage_dir, storage_path);
    }

    private static async File save_outgoing_file(FileEncryption file_encryption, FileTransfer file_transfer, InputStream input_stream, string storage_dir, string? forced_filename = null) throws FileSendError {
        File pending_file;
        File final_file;
        bool pending_owned = false;
        bool final_owned = false;
        try {
            string filename = forced_filename ?? Random.next_int().to_string("%x") + "_" + file_transfer.file_name;
            string pending_filename = ".send-" + Random.next_int().to_string("%x") + "-" + filename + ".part";
            pending_file = File.new_for_path(Path.build_filename(storage_dir, pending_filename));
            final_file = File.new_for_path(Path.build_filename(storage_dir, filename));
            
            yield FileTransferWorker.run("save-outgoing-file", () => {
                encrypt_outgoing_stream_to_pending_sync(file_encryption, input_stream, pending_file, file_transfer.cancellable);
            });
            pending_owned = true;

            yield FileTransferWorker.run_publish("commit-outgoing-file", () => {
                pending_file.move(final_file, FileCopyFlags.NONE, file_transfer.cancellable);
            });
            pending_owned = false;
            final_owned = true;
            throw_if_transfer_cancelled(file_transfer);
            file_transfer.path = filename;
            return final_file;
        } catch (Error e) {
            if (pending_owned) {
                delete_unreleased_send_file(pending_file, file_transfer.file_name);
            }
            if (final_owned && file_transfer.path == null) {
                delete_unreleased_send_file(final_file, file_transfer.file_name);
            }
            throw new FileSendError.SAVE_FAILED("Saving file error: %s".printf(e.message));
        }
    }

    private static void encrypt_outgoing_stream_to_pending_sync(FileEncryption file_encryption, InputStream input_stream, File pending_file, Cancellable? cancellable) throws Error {
        OutputStream? output = null;
        bool pending_owned = false;
        bool completed = false;
        try {
            output = pending_file.create(FileCreateFlags.PRIVATE, cancellable);
            pending_owned = true;
            file_encryption.encrypt_stream_sync(input_stream, (!) output, cancellable);
            ((!) output).close(cancellable);
            output = null;
            completed = true;
        } finally {
            if (output != null) {
                try {
                    ((!) output).close(null);
                } catch (Error close_error) {
                    debug("Failed to close unreleased outgoing file output: %s", close_error.message);
                }
            }
            if (pending_owned && !completed) {
                delete_unreleased_send_file(pending_file, pending_file.get_basename());
            }
        }
    }

    private static void delete_unpublished_outgoing_file(FileTransfer file_transfer, string storage_dir, string? storage_path) {
        if (storage_path == null) return;
        delete_unreleased_send_file(File.new_for_path(Path.build_filename(storage_dir, (!) storage_path)), file_transfer.file_name);
        if (file_transfer.path == storage_path) {
            file_transfer.path = null;
        }
    }

    private static void delete_unreleased_send_file(File? file, string? display_name) {
        if (file == null) return;
        try {
            ((!) file).delete(null);
        } catch (Error delete_error) {
            debug("Failed to delete unreleased outgoing file '%s': %s",
                    display_name ?? "(unknown)", delete_error.message);
        }
    }
}

public errordomain FileSendError {
    ENCRYPTION_FAILED,
    UPLOAD_FAILED,
    SAVE_FAILED
}

// Get rid of this Error and pass IoErrors instead - DOWNLOAD_FAILED already removed
public errordomain FileReceiveError {
    GET_METADATA_FAILED,
    DECRYPTION_FAILED
}

public class FileMeta {
    public int64 size = -1;
    public string? mime_type = null;
    public string? file_name = null;
    public Encryption encryption = Encryption.NONE;
    public string? encryption_protocol = null;
    public bool upload_payload_is_encrypted = false;
    public int message_db_id = -1;

    public void apply_safe_fields_to_transfer(FileTransfer file_transfer) {
        if (file_name != null && ((!) file_name).strip() != "") {
            file_transfer.file_name = (!) file_name;
        }

        if (mime_type != null && ((!) mime_type).strip() != "") {
            file_transfer.mime_type = ((!) mime_type).strip();
        }
    }

    public void apply_transport_fields_to_transfer(FileTransfer file_transfer) {
        apply_safe_fields_to_transfer(file_transfer);
        if (size >= 0) {
            file_transfer.size = size;
        }
    }
}

public class HttpFileMeta : FileMeta {
    public Message message;
}

public class FileSendData { }

public class HttpFileSendData : FileSendData {
    public string url_down { get; set; }
    public string url_up { get; set; }
    public HashMap<string, string> headers { get; set; }

    public bool encrypt_message { get; set; default=true; }
}

public class FileReceiveData { }

public class HttpFileReceiveData : FileReceiveData {
    public string url { get; set; }
}

public class EsfsHttpFileReceiveData : HttpFileReceiveData {
    public uint8[] esfs_key { get; set; }
    public uint8[] esfs_iv { get; set; }
    public string esfs_cipher { get; set; default = ""; }
}

public class VerifiedPlaintextMeta : Object {
    public string? file_name { get; set; }
    public string? mime_type { get; set; }

    public void apply_to_transfer(FileTransfer file_transfer) {
        if (file_name != null && ((!) file_name).strip() != "") {
            string basename = Path.get_basename(((!) file_name).strip());
            if (basename != "") {
                file_transfer.file_name = basename;
            }
        }

        if (mime_type != null && ((!) mime_type).strip() != "") {
            file_transfer.mime_type = ((!) mime_type).strip();
        }
    }
}

public interface VerifiedPlaintextMetaCarrier : Object {
    public abstract VerifiedPlaintextMeta? get_verified_plaintext_meta();
}

public interface FileProvider : Object {
    public signal void file_incoming(string info, Jid from, DateTime time, DateTime local_time, Conversation conversation, FileReceiveData receive_data, FileMeta file_meta);
    public signal void download_source_changed(string info);

    public abstract Encryption get_encryption(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta);
    public abstract FileMeta get_file_meta(FileTransfer file_transfer) throws FileReceiveError;
    public abstract FileReceiveData? get_file_receive_data(FileTransfer file_transfer);
    public abstract bool has_usable_download_source(FileTransfer file_transfer);

    public abstract async FileMeta get_meta_info(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws FileReceiveError, IOError;
    public abstract async InputStream download(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws IOError;

    public abstract int get_id();
}

public interface FileSender : Object {
    public signal void upload_available(Account account);

    public abstract async bool is_upload_available(Conversation conversation);
    public abstract async long get_file_size_limit(Conversation conversation);
    public abstract async bool can_send(Conversation conversation, FileTransfer file_transfer);
    public abstract async FileSendData? prepare_send_file(Conversation conversation, FileTransfer file_transfer, FileMeta file_meta) throws FileSendError;
    public abstract async void send_file(Conversation conversation, FileTransfer file_transfer, FileSendData file_send_data, FileMeta file_meta) throws FileSendError;
    public abstract async bool can_encrypt(Conversation conversation, FileTransfer file_transfer);

    public abstract int get_id();
    public abstract float get_priority();
}

public interface FileEncryptor : Object {
    public abstract bool can_encrypt_file(Conversation conversation, FileTransfer file_transfer);
    public abstract async FileMeta encrypt_file(Conversation conversation, FileTransfer file_transfer) throws FileSendError;
    public abstract FileSendData? preprocess_send_file(Conversation conversation, FileTransfer file_transfer, FileSendData file_send_data, FileMeta file_meta) throws FileSendError;
}

public interface FileEncryptorRejectionReason : Object {
    public abstract string? get_file_encryption_rejection_reason(Conversation conversation, FileTransfer file_transfer);
}

public interface FileEncryptorSenderRequirement : Object {
    public abstract int get_required_file_sender_id();
}

public interface FileDecryptor : Object {
    public abstract Encryption get_encryption();
    public abstract FileReceiveData prepare_get_meta_info(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data);
    public abstract FileMeta prepare_download_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta);
    public abstract bool can_decrypt_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data);
    public abstract bool decrypts_before_return();
    public abstract async InputStream decrypt_file(InputStream encrypted_stream, Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) throws FileReceiveError;
}

}
