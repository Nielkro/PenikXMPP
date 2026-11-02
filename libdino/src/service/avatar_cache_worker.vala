using Dino.Security;

namespace Dino {

internal errordomain AvatarCacheWorkerError {
    NOT_FOUND,
    CORRUPT,
    TOO_LARGE,
    QUEUE_FULL
}

internal class AvatarCacheWorkerResult : Object {
    internal Bytes bytes { get; private set; }
    internal int64 worker_thread_id { get; private set; }
    internal bool ran_on_worker { get; private set; }
    internal bool committed { get; private set; }

    internal AvatarCacheWorkerResult(Bytes bytes, int64 worker_thread_id,
            int64 caller_thread_id, bool committed = true) {
        this.bytes = bytes;
        this.worker_thread_id = worker_thread_id;
        this.ran_on_worker = worker_thread_id != caller_thread_id;
        this.committed = committed;
    }
}

/**
 * Small process-wide worker pool for encrypted avatar cache I/O.
 *
 * Jobs only carry immutable paths/bytes and the immutable FileEncryption
 * service. GTK objects, XMPP streams, mutable Gee containers, and callbacks
 * remain on the caller's main context.
 */
internal class AvatarCacheWorker : Object {
    internal const int THREAD_COUNT = 2;
    internal const int MAX_OUTSTANDING_JOBS = 128;
    private const int64 MAX_PLAINTEXT_AVATAR_BYTES = 8 * 1024 * 1024;
    private const int64 MAX_ENCRYPTED_AVATAR_BYTES = MAX_PLAINTEXT_AVATAR_BYTES + 64;

    private static AsyncQueue<AvatarCacheWorkerJob>? job_queue;
    private static Thread<void*>? worker_one;
    private static Thread<void*>? worker_two;
    private static Mutex start_mutex;
    private static Mutex outstanding_mutex;
    private static Mutex store_generation_mutex;
    private static bool started = false;
    private static int outstanding_jobs = 0;
    private static int executed_load_jobs = 0;
    private static int store_generation = 0;

    internal static int get_executed_load_jobs() {
        outstanding_mutex.lock();
        int result = executed_load_jobs;
        outstanding_mutex.unlock();
        return result;
    }

    internal static async AvatarCacheWorkerResult load(string path, FileEncryption encryption) throws Error {
        return yield load_internal(path, encryption, null);
    }

    internal static async AvatarCacheWorkerResult load_verified(string path,
            FileEncryption encryption, string expected_sha1) throws Error {
        return yield load_internal(path, encryption, expected_sha1);
    }

    private static async AvatarCacheWorkerResult load_internal(string path,
            FileEncryption encryption, string? expected_sha1) throws Error {
        ensure_started();
        SourceFunc callback = load_internal.callback;
        MainContext callback_context = MainContext.ref_thread_default();
        if (!try_reserve_slot()) {
            var idle = new IdleSource();
            idle.set_callback((owned) callback);
            idle.attach(callback_context);
            yield;
            throw new AvatarCacheWorkerError.QUEUE_FULL("Avatar cache worker queue is full");
        }

        int64 caller_thread_id = (int64) Thread.self<void*>();
        var job = new AvatarCacheWorkerJob.load(path, encryption,
            expected_sha1, caller_thread_id, (owned) callback,
            (owned) callback_context);
        ((!) job_queue).push(job);

        yield;

        if (job.error != null) throw (!) job.error;
        return (!) job.result;
    }

    internal static async AvatarCacheWorkerResult store(string path, FileEncryption encryption, Bytes bytes) throws Error {
        int generation = get_store_generation();
        return yield store_if_generation_internal(path, encryption, bytes,
            generation, null);
    }

    internal static async AvatarCacheWorkerResult store_verified(string path,
            FileEncryption encryption, Bytes bytes,
            string expected_sha1) throws Error {
        int generation = get_store_generation();
        return yield store_if_generation_internal(path, encryption, bytes,
            generation, expected_sha1);
    }

    internal static async AvatarCacheWorkerResult store_if_generation(
            string path, FileEncryption encryption, Bytes bytes,
            int generation) throws Error {
        return yield store_if_generation_internal(path, encryption, bytes,
            generation, null);
    }

    private static async AvatarCacheWorkerResult store_if_generation_internal(
            string path, FileEncryption encryption, Bytes bytes,
            int generation, string? expected_sha1) throws Error {
        ensure_started();
        SourceFunc callback = store_if_generation_internal.callback;
        MainContext callback_context = MainContext.ref_thread_default();
        if (!try_reserve_slot()) {
            var idle = new IdleSource();
            idle.set_callback((owned) callback);
            idle.attach(callback_context);
            yield;
            throw new AvatarCacheWorkerError.QUEUE_FULL("Avatar cache worker queue is full");
        }

        int64 caller_thread_id = (int64) Thread.self<void*>();
        var job = new AvatarCacheWorkerJob.store(path, encryption, bytes,
            expected_sha1, generation, caller_thread_id, (owned) callback,
            (owned) callback_context);
        ((!) job_queue).push(job);

        yield;

        if (job.error != null) throw (!) job.error;
        return (!) job.result;
    }

    internal static int get_store_generation() {
        store_generation_mutex.lock();
        try {
            return store_generation;
        } finally {
            store_generation_mutex.unlock();
        }
    }

    internal static void invalidate_pending_stores() {
        store_generation_mutex.lock();
        try {
            advance_store_generation_locked();
        } finally {
            store_generation_mutex.unlock();
        }
    }

    /**
     * Hold the exact generation-check/promotion boundary for a deterministic
     * in-flight purge test. Production stores do not consult a test flag or
     * take any additional lock beyond their existing commit mutex.
     */
    internal static int hold_store_promotion_for_tests() {
        store_generation_mutex.lock();
        return store_generation;
    }

    internal static void invalidate_and_release_store_promotion_for_tests() {
        advance_store_generation_locked();
        store_generation_mutex.unlock();
    }

    private static void advance_store_generation_locked() {
        store_generation = store_generation == int.MAX
            ? 1 : store_generation + 1;
    }

    private static void ensure_started() {
        start_mutex.lock();
        try {
            if (started) return;

            job_queue = new AsyncQueue<AvatarCacheWorkerJob>();
            worker_one = new Thread<void*>("avatar-cache-1", worker_func);
            worker_two = new Thread<void*>("avatar-cache-2", worker_func);
            started = true;
            debug("AvatarCacheWorker: started %d bounded workers", THREAD_COUNT);
        } finally {
            start_mutex.unlock();
        }
    }

    private static bool try_reserve_slot() {
        outstanding_mutex.lock();
        try {
            if (outstanding_jobs >= MAX_OUTSTANDING_JOBS) return false;
            outstanding_jobs++;
            return true;
        } finally {
            outstanding_mutex.unlock();
        }
    }

    internal static void release_slot() {
        outstanding_mutex.lock();
        outstanding_jobs--;
        outstanding_mutex.unlock();
    }

    private static void* worker_func() {
        AsyncQueue<AvatarCacheWorkerJob>? queue = job_queue;
        while (queue != null) {
            AvatarCacheWorkerJob job = ((!) queue).pop();
            job.run();
        }
        return null;
    }

    internal static AvatarCacheWorkerResult load_sync(string path,
            FileEncryption encryption, int64 caller_thread_id,
            string? expected_sha1 = null) throws Error {
        outstanding_mutex.lock();
        executed_load_jobs++;
        outstanding_mutex.unlock();

        File file = File.new_for_path(path);
        FileInfo info;
        try {
            info = file.query_info("standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        } catch (IOError.NOT_FOUND error) {
            throw new AvatarCacheWorkerError.NOT_FOUND("Avatar cache entry does not exist");
        }

        if (info.get_file_type() != FileType.REGULAR) {
            throw new AvatarCacheWorkerError.CORRUPT("Avatar cache entry is not a regular file");
        }
        if (info.get_size() > MAX_ENCRYPTED_AVATAR_BYTES) {
            try { file.delete(); } catch (Error error) {}
            throw new AvatarCacheWorkerError.TOO_LARGE("Encrypted avatar cache entry exceeds the size limit");
        }

        uint8[] encrypted;
        if (!FileUtils.get_data(path, out encrypted)) {
            throw new AvatarCacheWorkerError.NOT_FOUND("Avatar cache entry disappeared while reading");
        }

        uint8[] plaintext;
        try {
            plaintext = encryption.decrypt_data(encrypted);
        } catch (Error error) {
            try { file.delete(); } catch (Error delete_error) {}
            throw new AvatarCacheWorkerError.CORRUPT(@"Failed to decrypt avatar cache entry: $(error.message)");
        }
        Bytes bytes = new Bytes(plaintext);
        if (expected_sha1 != null && Checksum.compute_for_bytes(
                ChecksumType.SHA1, bytes) != expected_sha1) {
            try { file.delete(); } catch (Error delete_error) {}
            throw new AvatarCacheWorkerError.CORRUPT(
                "Avatar cache entry does not match its content hash");
        }
        return new AvatarCacheWorkerResult(bytes,
            (int64) Thread.self<void*>(), caller_thread_id);
    }

    internal static AvatarCacheWorkerResult store_sync(string path,
            FileEncryption encryption, Bytes bytes, int generation,
            int64 caller_thread_id, string? expected_sha1 = null)
            throws Error {
        if ((int64) bytes.get_size() > MAX_PLAINTEXT_AVATAR_BYTES) {
            throw new AvatarCacheWorkerError.TOO_LARGE("Avatar plaintext exceeds the cache size limit");
        }
        if (expected_sha1 != null && Checksum.compute_for_bytes(
                ChecksumType.SHA1, bytes) != expected_sha1) {
            throw new AvatarCacheWorkerError.CORRUPT(
                "Avatar plaintext does not match its content hash");
        }

        unowned uint8[] plaintext = bytes.get_data();
        uint8[] ciphertext = encryption.encrypt_data(plaintext);
        File file = File.new_for_path(path);
        File? parent = file.get_parent();
        if (parent != null) {
            try {
                ((!) parent).make_directory_with_parents();
            } catch (IOError.EXISTS error) {
                // Already available.
            }
        }

        File staging_file = File.new_for_path(path + ".pending-" +
            Uuid.string_random());
        bool promoted = false;
        try {
            string? new_etag;
            staging_file.replace_contents(ciphertext, null, false,
                FileCreateFlags.PRIVATE | FileCreateFlags.REPLACE_DESTINATION,
                out new_etag, null);

            // The potentially slow encryption and write happen outside this
            // mutex. Only the generation check plus same-filesystem rename are
            // serialized against cache purge, keeping the GTK main thread
            // responsive while preserving strict before/after ordering.
            store_generation_mutex.lock();
            try {
                if (generation != store_generation) {
                    return new AvatarCacheWorkerResult(bytes,
                        (int64) Thread.self<void*>(), caller_thread_id, false);
                }
                staging_file.move(file, FileCopyFlags.OVERWRITE, null, null);
                promoted = true;
                return new AvatarCacheWorkerResult(bytes,
                    (int64) Thread.self<void*>(), caller_thread_id);
            } finally {
                store_generation_mutex.unlock();
            }
        } finally {
            if (!promoted) {
                try { staging_file.delete(); } catch (Error error) {}
            }
        }
    }
}

private enum AvatarCacheWorkerOperation {
    LOAD,
    STORE
}

private class AvatarCacheWorkerJob : Object {
    internal Error? error { get; private set; }
    internal AvatarCacheWorkerResult? result { get; private set; }

    private AvatarCacheWorkerOperation operation;
    private string path;
    private FileEncryption encryption;
    private Bytes? bytes;
    private string? expected_sha1;
    private int store_generation;
    private int64 caller_thread_id;
    private SourceFunc callback;
    private MainContext callback_context;

    internal AvatarCacheWorkerJob.load(string path, FileEncryption encryption,
            string? expected_sha1, int64 caller_thread_id,
            owned SourceFunc callback, owned MainContext callback_context) {
        this.operation = AvatarCacheWorkerOperation.LOAD;
        this.path = path;
        this.encryption = encryption;
        this.expected_sha1 = expected_sha1;
        this.caller_thread_id = caller_thread_id;
        this.callback = (owned) callback;
        this.callback_context = (owned) callback_context;
    }

    internal AvatarCacheWorkerJob.store(string path, FileEncryption encryption,
            Bytes bytes, string? expected_sha1, int store_generation,
            int64 caller_thread_id,
            owned SourceFunc callback, owned MainContext callback_context) {
        this.operation = AvatarCacheWorkerOperation.STORE;
        this.path = path;
        this.encryption = encryption;
        this.bytes = bytes;
        this.expected_sha1 = expected_sha1;
        this.store_generation = store_generation;
        this.caller_thread_id = caller_thread_id;
        this.callback = (owned) callback;
        this.callback_context = (owned) callback_context;
    }

    internal void run() {
        try {
            if (operation == AvatarCacheWorkerOperation.LOAD) {
                result = AvatarCacheWorker.load_sync(path, encryption,
                    caller_thread_id, expected_sha1);
            } else {
                result = AvatarCacheWorker.store_sync(path, encryption,
                    (!) bytes, store_generation, caller_thread_id,
                    expected_sha1);
            }
        } catch (Error caught_error) {
            error = caught_error;
        } finally {
            AvatarCacheWorker.release_slot();
        }

        var idle = new IdleSource();
        idle.set_callback((owned) callback);
        idle.attach(callback_context);
    }
}

}
