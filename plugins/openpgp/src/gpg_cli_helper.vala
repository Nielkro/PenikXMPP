/*
 * GPG CLI Helper - Uses GPG command line instead of GPGME
 * This is more reliable on Windows/MINGW where GPGME has issues with homedir.
 * 
 * Copyright (C) 2025-2026 DinoX
 */

using Gee;

namespace GPGHelper {

private const string XEP0373_BACKUP_CODE_ALPHABET = "123456789ABCDEFGHIJKLMNPQRSTUVWXYZ";
private const int XEP0373_BACKUP_CODE_LENGTH = 24;
private const int XEP0373_BACKUP_CODE_CHUNK_SIZE = 4;
private const int XEP0373_BACKUP_CODE_RANDOM_BATCH_SIZE = 64;

[CCode (cname = "g_subprocess_newv", cheader_filename = "gio/gio.h")]
private extern static Subprocess subprocess_newv_const([CCode (array_length = false, array_null_terminated = true, type = "const gchar* const*")] string[] argv, SubprocessFlags flags) throws Error;

#if !WINDOWS
private static bool path_is_in_directory(string path, string directory) {
    string dir_prefix = directory.has_suffix("/") ? directory : directory + "/";
    return path == directory || path.has_prefix(dir_prefix);
}

private static bool should_drop_appimage_library_path(string[] argv) {
    string? appdir = Environment.get_variable("APPDIR");
    if (appdir == null || appdir.length == 0) return false;
    if (Environment.get_variable("APPIMAGE") == null) return false;
    if (argv.length == 0 || argv[0] == null || argv[0].length == 0) return true;

    string? resolved_binary = Path.is_absolute(argv[0]) ? argv[0] : Environment.find_program_in_path(argv[0]);
    return resolved_binary == null || !path_is_in_directory(resolved_binary, appdir);
}
#endif

private static Subprocess new_subprocess(string[] argv, SubprocessFlags flags) throws Error {
#if WINDOWS
    return subprocess_newv_const(argv, flags);
#else
    var launcher = new SubprocessLauncher(flags);
    if (should_drop_appimage_library_path(argv)) {
        launcher.unsetenv("LD_LIBRARY_PATH");
    }
    return launcher.spawnv(argv);
#endif
}

private static string[] string_collection_to_array(Gee.Collection<string> values) {
    string[] parts = new string[values.size];
    int i = 0;
    foreach (string value in values) {
        parts[i++] = value;
    }
    return parts;
}

private static string join_strings(string separator, Gee.Collection<string> values) {
    return string.joinv(separator, string_collection_to_array(values));
}

private static string keyid_from_fingerprint(string fingerprint) {
    return fingerprint.length >= 16 ? fingerprint.substring(fingerprint.length - 16).up() : fingerprint.up();
}

private static bool openpgp_key_ids_match(string expected_key, string actual_key) {
    string expected = normalize_openpgp_key_id(expected_key);
    string actual = normalize_openpgp_key_id(actual_key);
    if (expected.length == 0 || actual.length == 0) return false;
    return expected == actual || expected.has_suffix(actual) || actual.has_suffix(expected);
}

private static string normalize_openpgp_key_id(string value) {
    return value.up().replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "");
}

internal static string json_escape(string value) {
    string safe = value.validate() ? value : value.make_valid();
    StringBuilder escaped = new StringBuilder();
    int byte_index = 0;
    unichar c;
    while (safe.get_next_char(ref byte_index, out c)) {
        switch (c) {
            case '"':
                escaped.append("\\\"");
                break;
            case '\\':
                escaped.append("\\\\");
                break;
            case '\b':
                escaped.append("\\b");
                break;
            case '\f':
                escaped.append("\\f");
                break;
            case '\n':
                escaped.append("\\n");
                break;
            case '\r':
                escaped.append("\\r");
                break;
            case '\t':
                escaped.append("\\t");
                break;
            default:
                if (c < 0x20) {
                    escaped.append("\\u%04x".printf((uint)c));
                } else {
                    escaped.append_unichar(c);
                }
                break;
        }
    }
    return escaped.str;
}

internal static string? json_get_string_field(string json, string field_name) {
    string marker = "\"" + field_name + "\"";
    int marker_pos = json.index_of(marker);
    if (marker_pos < 0) return null;

    int colon_pos = json.index_of(":", marker_pos + marker.length);
    if (colon_pos < 0) return null;

    int start = json.index_of("\"", colon_pos + 1);
    if (start < 0) return null;
    start++;

    StringBuilder value = new StringBuilder();
    bool escape = false;
    for (int i = start; i < json.length; i++) {
        char c = json[i];
        if (escape) {
            switch (c) {
                case 'n':
                    value.append_c('\n');
                    break;
                case 'r':
                    value.append_c('\r');
                    break;
                case 't':
                    value.append_c('\t');
                    break;
                default:
                    value.append_c(c);
                    break;
            }
            escape = false;
        } else if (c == '\\') {
            escape = true;
        } else if (c == '"') {
            return value.str;
        } else {
            value.append_c(c);
        }
    }
    return null;
}

internal static Gee.List<string> json_collect_email_keys(string json) {
    var emails = new ArrayList<string>();
    int pos = 0;
    while (pos < json.length) {
        int quote_start = json.index_of("\"", pos);
        if (quote_start < 0) break;
        int quote_end = json.index_of("\"", quote_start + 1);
        if (quote_end < 0) break;
        string key = json.substring(quote_start + 1, quote_end - quote_start - 1);
        int colon_pos = json.index_of(":", quote_end + 1);
        if (colon_pos < 0) break;
        string between = json.substring(quote_end + 1, colon_pos - quote_end - 1).strip();
        if (between.length == 0 && key.contains("@") && !emails.contains(key)) {
            emails.add(key);
        }
        pos = quote_end + 1;
    }
    return emails;
}

internal static string? email_from_uid(string uid) {
    string decoded_uid = decode_gpg_colon_escapes(uid);
    int start = decoded_uid.index_of("<");
    int end = decoded_uid.index_of(">", start + 1);
    if (start >= 0 && end > start) {
        string email = decoded_uid.substring(start + 1, end - start - 1).strip();
        if (email.contains("@") && !email.down().has_prefix("xmpp:")) return email;
    }
    return parse_inline_email_from_uid(decoded_uid);
}

private static string? parse_inline_email_from_uid(string decoded_uid) {
    string stripped = decoded_uid.strip();
    if (stripped.has_prefix("xmpp:") || stripped.length == 0) return null;
    if (stripped.contains("@") && is_plain_email_candidate(stripped)) {
        return stripped;
    }

    int at = stripped.index_of("@");
    while (at >= 0) {
        int start = at - 1;
        while (start >= 0 && !is_uid_token_delimiter(stripped[start])) {
            start--;
        }
        int end = at + 1;
        while (end < stripped.length && !is_uid_token_delimiter(stripped[end])) {
            end++;
        }
        if (end <= start + 1) {
            at = stripped.index_of("@", at + 1);
            continue;
        }

        string candidate = stripped.substring(start + 1, end - (start + 1)).strip();
        if (candidate.length > 0 && is_plain_email_candidate(candidate)) {
            return candidate;
        }
        at = stripped.index_of("@", at + 1);
    }

    return null;
}

private static bool is_uid_token_delimiter(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r'
        || c == '<' || c == '>' || c == '(' || c == ')' || c == '[' || c == ']'
        || c == '{' || c == '}' || c == ',' || c == ';' || c == '\"'
        || c == '\'';
}

private static bool is_plain_email_candidate(string email_candidate) {
    string email = email_candidate.strip();
    if (email.length == 0) return false;
    string lower = email.down();
    if (lower.has_prefix("xmpp:") || lower.has_prefix("mailto:")) return false;
    if (email[0] == '@' || email[email.length - 1] == '@') return false;

    int at = email.index_of("@");
    if (at <= 0 || at >= email.length - 1) return false;
    if (email.contains(" ")) return false;
    if (email.contains(":")) return false;

    string domain = email.substring(at + 1);
    if (domain[0] == '.' || domain[domain.length - 1] == '.') return false;

    return true;
}

internal static string decode_gpg_colon_escapes(string value) {
    StringBuilder decoded = new StringBuilder();
    for (int i = 0; i < value.length; i++) {
        if (value[i] == '\\' && i + 3 < value.length && value[i + 1] == 'x') {
            int high = hex_value(value[i + 2]);
            int low = hex_value(value[i + 3]);
            if (high >= 0 && low >= 0) {
                decoded.append_c((char) ((high << 4) | low));
                i += 3;
                continue;
            }
        }
        decoded.append_c(value[i]);
    }
    return decoded.str;
}

private static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

internal static string xmpp_user_id_for_jid(string bare_jid) {
    string jid = sanitize_gpg_batch_value(bare_jid);
    if (jid.has_prefix("xmpp:")) return jid;
    return "xmpp:" + jid;
}

internal static bool uid_matches_xmpp_jid(string uid, string bare_jid) {
    return decode_gpg_colon_escapes(uid).strip() == xmpp_user_id_for_jid(bare_jid);
}

private static string sanitize_gpg_batch_value(string value) {
    return value.replace("\r", " ").replace("\n", " ").strip();
}

internal static string to_windows_path(string path) {
    if (path.has_prefix("/") && path.length > 2 && path[2] == '/') {
        string drive = path.substring(1, 1).ascii_up();
        return drive + ":\\" + path.substring(3).replace("/", "\\");
    }
    return path.replace("/", "\\");
}

private static bool initialized = false;
private static string? gpg_binary = null;
private static string? gpg_homedir = null;
private const uint GPG_KEY_OPERATION_TIMEOUT_SECONDS = 45;

// GPG Worker Queue — all GPG subprocess calls are serialized through a single
// worker thread.  This eliminates mutex double-release bugs, deadlock risks,
// and prevents Windows crashes from concurrent GPG subprocess spawning.
private static AsyncQueue<GpgJob>? job_queue = null;
private static Thread<void*>? worker_thread = null;
private static Mutex result_mutex;
private static Cond result_cond;
private static int worker_started = 0;

private static Mutex secret_keys_mutex;
private static Mutex passphrase_mutex;

// Cache for has_secret_keys() - thread-safe check
private static bool has_secret_keys_checked = false;
private static bool has_secret_keys_cached = false;
private static AsyncQueue<SecretKeyAsyncRequest>? secret_key_async_queue = null;
private static Thread<void*>? secret_key_async_worker_thread = null;
private static int secret_key_async_worker_started = 0;
private static Mutex shutdown_mutex;
private static bool shutdown_requested = false;
private static Mutex active_subprocess_mutex;
private static ArrayList<ActiveGpgSubprocess>? active_gpg_subprocesses = null;
private const int GPG_HELPER_SHUTDOWN_EXIT_STATUS = -3;
private const string GPG_HELPER_SHUTDOWN_MESSAGE = "GPG helper is shutting down";

public interface PassphraseProvider : Object {
    public abstract string? request_passphrase(string fingerprint, string operation);
}
private static PassphraseProvider? passphrase_provider = null;
private static HashMap<string, string>? passphrase_cache = null;

/**
 * Job submitted to the GPG worker queue.
 */
public class GpgJob : Object {
    public string[] extra_args;
    public string? stdin_data;
    public bool allow_interactive;
    public uint timeout_seconds;
    public string caller;

    // Results (set by worker thread)
    public string stdout_str = "";
    public string stderr_str = "";
    public int exit_status = -1;
    public bool result = false;
    public bool completed = false;
    public bool is_shutdown = false;

    public GpgJob(string[] args, string? stdin_input, bool interactive, string caller_name, uint timeout = 0) {
        this.extra_args = args;
        this.stdin_data = stdin_input;
        this.allow_interactive = interactive;
        this.timeout_seconds = timeout;
        this.caller = caller_name;
    }

    public GpgJob.shutdown() {
        this.extra_args = new string[0];
        this.stdin_data = null;
        this.allow_interactive = false;
        this.timeout_seconds = 0;
        this.caller = "shutdown";
        this.is_shutdown = true;
    }
}

private class GpgTimeoutState : Object {
    private Mutex mutex;
    private bool completed = false;
    private bool timed_out = false;
    private Thread<void*>? timeout_thread = null;

    public bool is_completed() {
        mutex.lock();
        bool result = completed;
        mutex.unlock();
        return result;
    }

    public bool mark_timed_out() {
        mutex.lock();
        if (completed) {
            mutex.unlock();
            return false;
        }
        timed_out = true;
        mutex.unlock();
        return true;
    }

    public void mark_completed() {
        mutex.lock();
        completed = true;
        mutex.unlock();
    }

    public bool has_timed_out() {
        mutex.lock();
        bool result = timed_out;
        mutex.unlock();
        return result;
    }

    public void set_timeout_thread(Thread<void*> thread) {
        timeout_thread = thread;
    }

    public void join_timeout_thread() {
        Thread<void*>? thread = timeout_thread;
        timeout_thread = null;
        if (thread != null) {
            ((!) thread).join();
        }
    }
}

private class SecretKeyAsyncRequest : Object {
    public SourceFunc? callback;
    public bool result = false;
    public bool is_shutdown = false;

    public SecretKeyAsyncRequest(owned SourceFunc callback) {
        this.callback = (owned) callback;
    }

    public SecretKeyAsyncRequest.shutdown() {
        this.callback = null;
        this.is_shutdown = true;
    }

    public void resume(bool result) {
        this.result = result;
        SourceFunc? owned_callback = (owned) callback;
        if (owned_callback != null) {
            Idle.add((owned) owned_callback);
        }
    }
}

private class ActiveGpgSubprocess : Object {
    public Subprocess subprocess;
    public Cancellable cancellable;

    public ActiveGpgSubprocess(Subprocess subprocess, Cancellable cancellable) {
        this.subprocess = subprocess;
        this.cancellable = cancellable;
    }
}

private static bool is_shutdown_requested() {
    shutdown_mutex.lock();
    bool result = shutdown_requested;
    shutdown_mutex.unlock();
    return result;
}

public static bool is_shutting_down() {
    return is_shutdown_requested();
}

private static void complete_job(GpgJob job, bool result, int exit_status, string stdout_str, string stderr_str) {
    job.result = result;
    job.exit_status = exit_status;
    job.stdout_str = stdout_str;
    job.stderr_str = stderr_str;

    result_mutex.lock();
    job.completed = true;
    result_cond.broadcast();
    result_mutex.unlock();
}

private static void register_active_subprocess(Subprocess subprocess, Cancellable cancellable) {
    bool should_cancel = false;
    active_subprocess_mutex.lock();
    if (active_gpg_subprocesses == null) {
        active_gpg_subprocesses = new ArrayList<ActiveGpgSubprocess>();
    }
    ((!) active_gpg_subprocesses).add(new ActiveGpgSubprocess(subprocess, cancellable));
    should_cancel = is_shutdown_requested();
    active_subprocess_mutex.unlock();

    if (should_cancel) {
        cancellable.cancel();
        subprocess.force_exit();
    }
}

private static void clear_active_subprocess(Subprocess subprocess) {
    active_subprocess_mutex.lock();
    if (active_gpg_subprocesses != null) {
        for (int i = ((!) active_gpg_subprocesses).size - 1; i >= 0; i--) {
            if (((!) active_gpg_subprocesses)[i].subprocess == subprocess) {
                ((!) active_gpg_subprocesses).remove_at(i);
            }
        }
    }
    active_subprocess_mutex.unlock();
}

private static void cancel_active_subprocess() {
    active_subprocess_mutex.lock();
    if (active_gpg_subprocesses != null) {
        foreach (ActiveGpgSubprocess handle in (!) active_gpg_subprocesses) {
            handle.cancellable.cancel();
            handle.subprocess.force_exit();
        }
    }
    active_subprocess_mutex.unlock();
}

public static void register_external_subprocess_for_shutdown(Subprocess subprocess, Cancellable cancellable) {
    register_active_subprocess(subprocess, cancellable);
}

public static void clear_external_subprocess_for_shutdown(Subprocess subprocess) {
    clear_active_subprocess(subprocess);
}

/**
 * Ensure the single GPG worker thread is running.
 * Thread-safe using atomic compare-and-swap.
 */
private static void ensure_worker_started() {
    if (AtomicInt.compare_and_exchange(ref worker_started, 0, 1)) {
        job_queue = new AsyncQueue<GpgJob>();
        worker_thread = new Thread<void*>("gpg-worker", gpg_worker_func);
        debug("GPGHelper: Worker thread started");
    }
}

/**
 * Ensure the single async secret-key check worker is running.
 *
 * Startup can replay many OpenPGP messages from MAM.  Spawning one helper
 * thread per message is unnecessary because GPG calls are serialized anyway,
 * and on Windows it creates a burst of thread/idle callbacks during startup.
 */
private static void ensure_secret_key_async_worker_started() {
    if (AtomicInt.compare_and_exchange(ref secret_key_async_worker_started, 0, 1)) {
        secret_key_async_queue = new AsyncQueue<SecretKeyAsyncRequest>();
        secret_key_async_worker_thread = new Thread<void*>("gpg-secret-key-worker", secret_key_async_worker_func);
        debug("GPGHelper: Secret-key async worker started");
    }
}

private static void* secret_key_async_worker_func() {
    while (true) {
        SecretKeyAsyncRequest request = secret_key_async_queue.pop();
        if (request.is_shutdown) break;
        request.resume(is_shutdown_requested() ? false : has_secret_keys());
    }
    debug("GPGHelper: Secret-key async worker stopped");
    return null;
}

/**
 * GPG worker thread — pops jobs from the queue and executes them one at a time.
 * Only ONE GPG subprocess is ever active, eliminating all concurrency issues.
 */
private static void* gpg_worker_func() {
    debug("GPGHelper: Worker thread running (thread %s)", ((int64) Thread.self<void*>()).to_string());
    while (true) {
        GpgJob job = job_queue.pop();

        if (job.is_shutdown) {
            complete_job(job, true, 0, "", "");
            break;
        }

        if (is_shutdown_requested()) {
            complete_job(job, false, GPG_HELPER_SHUTDOWN_EXIT_STATUS, "", GPG_HELPER_SHUTDOWN_MESSAGE);
            continue;
        }

        debug("GPGHelper [%s]: Worker executing job", job.caller);

        job.result = run_gpg_internal(
            job.extra_args, job.stdin_data,
            out job.stdout_str, out job.stderr_str,
            out job.exit_status, job.allow_interactive, job.timeout_seconds
        );

        debug("GPGHelper [%s]: Worker completed (exit=%d)", job.caller, job.exit_status);

        complete_job(job, job.result, job.exit_status, job.stdout_str, job.stderr_str);
    }
    debug("GPGHelper: Worker thread stopped");
    return null;
}

/**
 * Simple key structure that mimics GPG.Key for compatibility
 */
public class Key : Object {
    public string fpr { get; set; }
    public string keyid { get; set; }
    public string uid { get; set; }
    public string email { get; set; }
    public bool secret { get; set; }
    public bool can_encrypt { get; set; default = true; }
    public bool can_sign { get; set; default = true; }
    public bool expired { get; set; default = false; }
    public bool revoked { get; set; default = false; }
    
    public Key(string fingerprint) {
        this.fpr = fingerprint;
        this.keyid = fingerprint.length >= 16 ? fingerprint.substring(fingerprint.length - 16) : fingerprint;
    }
}

public errordomain KeyManagementError {
    REVOCATION_CERTIFICATE_MISSING,
    REVOCATION_CERTIFICATE_INVALID,
    REVOCATION_FAILED,
    DELETE_FAILED
}

/**
 * Decrypted data container
 */
public class DecryptedData {
    public uint8[] data { get; set; }
    public string filename { get; set; }
    public string? signer_fingerprint { get; set; }
    public bool signature_valid { get; set; default = false; }
}

public class DecryptedFile {
    public string path { get; set; }
    public int64 size { get; set; default = -1; }
    public string filename { get; set; }
    public string? signer_fingerprint { get; set; }
    public bool signature_valid { get; set; default = false; }
}

public class ImportResult {
    public bool imported { get; set; default = false; }
    public Gee.List<string> fingerprints { get; private set; default = new ArrayList<string>(); }
}

public class KeyDataInfo {
    public bool valid_key_data { get; set; default = false; }
    public bool contains_secret_key { get; set; default = false; }
    public Gee.List<string> fingerprints { get; private set; default = new ArrayList<string>(); }
    public Gee.List<string> secret_fingerprints { get; private set; default = new ArrayList<string>(); }
    public Gee.List<string> user_ids { get; private set; default = new ArrayList<string>(); }
}

public class DecryptImportResult {
    public bool imported { get; set; default = false; }
    public bool already_present { get; set; default = false; }
    public KeyDataInfo key_info { get; set; default = new KeyDataInfo(); }
}

public static void set_passphrase_provider(PassphraseProvider? provider) {
    passphrase_mutex.lock();
    passphrase_provider = provider;
    passphrase_mutex.unlock();
}

public static void cache_passphrase(string fingerprint, string passphrase) {
    if (fingerprint.length == 0 || passphrase.length == 0) return;
    string fp = normalize_fingerprint(fingerprint);
    passphrase_mutex.lock();
    if (passphrase_cache == null) passphrase_cache = new HashMap<string, string>();
    passphrase_cache[fp] = passphrase;
    passphrase_mutex.unlock();
}

public static void clear_passphrase(string fingerprint) {
    string fp = normalize_fingerprint(fingerprint);
    passphrase_mutex.lock();
    if (passphrase_cache != null) passphrase_cache.unset(fp);
    passphrase_mutex.unlock();
}

public static void clear_passphrases() {
    passphrase_mutex.lock();
    if (passphrase_cache != null) passphrase_cache.clear();
    passphrase_provider = null;
    passphrase_mutex.unlock();
}

public static bool shutdown_workers(uint timeout_ms = 2000) {
    var shutdown_job = new GpgJob.shutdown();

    shutdown_mutex.lock();
    shutdown_requested = true;
    if (secret_key_async_queue != null) {
        secret_key_async_queue.push(new SecretKeyAsyncRequest.shutdown());
    }
    if (job_queue != null) {
        job_queue.push(shutdown_job);
    }
    shutdown_mutex.unlock();

    cancel_active_subprocess();

    bool drained = true;
    if (job_queue != null) {
        result_mutex.lock();
        int64 end_time = get_monotonic_time() + (int64) timeout_ms * 1000;
        while (!shutdown_job.completed) {
            if (!result_cond.wait_until(result_mutex, end_time)) {
                break;
            }
        }
        drained = shutdown_job.completed;
        result_mutex.unlock();

        if (drained && worker_thread != null) {
            ((!) worker_thread).join();
            worker_thread = null;
            job_queue = null;
        }
    }

    if (drained && secret_key_async_worker_thread != null) {
        ((!) secret_key_async_worker_thread).join();
        secret_key_async_worker_thread = null;
        secret_key_async_queue = null;
    }

    return drained;
}

private static string? get_cached_passphrase(string fingerprint) {
    string fp = normalize_fingerprint(fingerprint);
    passphrase_mutex.lock();
    string? passphrase = passphrase_cache != null && passphrase_cache.has_key(fp) ? passphrase_cache[fp] : null;
    passphrase_mutex.unlock();
    return passphrase;
}

private static string? request_passphrase(string fingerprint, string operation) {
    string? cached = get_cached_passphrase(fingerprint);
    if (cached != null) return cached;

    PassphraseProvider? provider = null;
    passphrase_mutex.lock();
    provider = passphrase_provider;
    passphrase_mutex.unlock();
    if (provider == null) return null;

    return provider.request_passphrase(normalize_fingerprint(fingerprint), operation);
}

private static void add_loopback_passphrase_args(ArrayList<string> args) {
    args.add("--batch");
    args.add("--yes");
    args.add("--pinentry-mode");
    args.add("loopback");
    args.add("--passphrase-fd");
    args.add("0");
}

private static bool is_bad_passphrase_error(string stderr_str) {
    // Status codes are stable across GnuPG UI languages and operating systems.
    // The source occupies the upper bits of a libgpg-error value.
    foreach (string raw_line in stderr_str.split("\n")) {
        string line = raw_line.strip();
        if (line.has_prefix("[GNUPG:] BAD_PASSPHRASE") || line.has_prefix("[GNUPG:] MISSING_PASSPHRASE")) return true;
        if (!line.has_prefix("[GNUPG:] ERROR ")) continue;
        string[] parts = line.split(" ");
        uint encoded_error = 0;
        if (parts.length < 4 || !uint.try_parse(parts[parts.length - 1], out encoded_error)) continue;
        uint error_code = encoded_error & 0xffff;
        if (error_code == (uint) GPGError.ErrorCode.BAD_PASSPHRASE ||
                error_code == (uint) GPGError.ErrorCode.CANCELED || error_code == 177) { // GPG_ERR_NO_PASSPHRASE
            return true;
        }
    }
    return stderr_str.contains("Bad passphrase") ||
        stderr_str.contains("bad passphrase") ||
        stderr_str.contains("No passphrase given") ||
        stderr_str.contains("No pinentry") ||
        stderr_str.contains("CANCELED");
}

/**
 * Initialize the GPG helper - find gpg binary and set homedir
 */
private static void initialize() {
    // Ensure the worker queue is running
    ensure_worker_started();
    
    if (initialized) return;
    
    // Find GPG binary. Packaged Windows builds must prefer the bundled GnuPG
    // tools next to dinox.exe; PATH is only a development fallback.
#if WINDOWS
    string? exe_dir = Environment.get_variable("DINOX_EXE_DIR");
    if (exe_dir != null && exe_dir.length > 0) {
        string bundled_gpg = Path.build_filename(exe_dir, "bin", "gpg.exe");
        if (FileUtils.test(bundled_gpg, FileTest.EXISTS)) {
            gpg_binary = to_windows_path(bundled_gpg);
        }
    }
#endif
    if (gpg_binary == null) {
        gpg_binary = Environment.find_program_in_path("gpg");
    }
    if (gpg_binary == null) {
        gpg_binary = "gpg";
    }
    
    // Get homedir from environment
    gpg_homedir = Environment.get_variable("GNUPGHOME");
#if WINDOWS
    if (gpg_homedir != null && gpg_homedir.length > 0) {
        gpg_homedir = to_windows_path(gpg_homedir);
    }
#endif
    
    // CRITICAL: Verify homedir exists before any GPG operation
    // After Panic Wipe, the directory may be deleted but env var still set
    if (gpg_homedir != null && gpg_homedir.length > 0) {
        if (!FileUtils.test(gpg_homedir, FileTest.IS_DIR)) {
            debug("GPGHelper: GNUPGHOME does not exist: %s, creating...", gpg_homedir);
            if (DirUtils.create_with_parents(gpg_homedir, 0700) != 0) {
                // Keep the failed app-scoped path. Every command validates it
                // before spawning; a missing home must never select ~/.gnupg.
                debug("GPGHelper: Cannot create app-scoped GNUPGHOME: %s", gpg_homedir);
            }
        }
    }
    
    debug("GPGHelper (CLI): Initialized with gpg=%s, homedir=%s", 
            gpg_binary, gpg_homedir ?? "unconfigured");
    
    initialized = true;
}

public static string get_binary_path() {
    initialize();
    return gpg_binary;
}

public static string? get_homedir_path() {
    initialize();
    return gpg_homedir;
}

internal static void set_homedir_path_for_tests(string? homedir) {
    gpg_homedir = homedir;
    initialized = true;
    invalidate_secret_keys_cache();
}

/**
 * Build base GPG command with homedir
 * @param allow_interactive: legacy flag kept for call compatibility. External
 * pinentry is intentionally disabled; private-key operations must use
 * DinoX-managed loopback passphrases.
 */
private static string[] get_base_command(bool allow_interactive = false) throws GLib.Error {
    initialize();

    // Validate on every invocation, including after Panic Wipe or an external
    // removal. GnuPG's implicit system home is never a DinoX fallback.
    if (gpg_homedir == null || gpg_homedir.length == 0 ||
            !FileUtils.test(gpg_homedir, FileTest.IS_DIR)) {
        throw new IOError.NOT_FOUND("DinoX OpenPGP keyring directory is unavailable");
    }
    
    var args = new ArrayList<string>();
    args.add(gpg_binary);
    args.add("--no-secmem-warning");

    args.add("--homedir");
    args.add(gpg_homedir);
    
    // Always run GPG in batch mode. DinoX supplies passphrases through
    // --pinentry-mode loopback where needed, never through system pinentry.
    args.add("--batch");
    args.add("--yes");
    
    return string_collection_to_array(args);
}

/**
 * Write string data to a file with restrictive permissions (0600).
 * Prevents other users from reading sensitive cryptographic material in temp files.
 */
public static void secure_write_file(string path, string data) throws GLib.Error {
    var file = File.new_for_path(path);
    var os = file.create(FileCreateFlags.PRIVATE);
    if (data.length > 0) {
        os.write(data.data);
    }
    os.close();
}

/**
 * Write binary data to a file with restrictive permissions (0600).
 */
public static void secure_write_data(string path, uint8[] data) throws GLib.Error {
    var file = File.new_for_path(path);
    var os = file.create(FileCreateFlags.PRIVATE);
    if (data.length > 0) {
        os.write(data);
    }
    os.close();
}

/**
 * Securely delete a file by overwriting contents with zeros before unlinking.
 * Prevents recovery of sensitive plaintext or key material from disk.
 */
public static void secure_delete_file(string path) {
    if (!FileUtils.test(path, FileTest.EXISTS)) return;
    try {
        var file = File.new_for_path(path);
        var info = file.query_info("standard::size", FileQueryInfoFlags.NONE);
        int64 size = info.get_size();
        if (size > 0) {
            var os = file.replace(null, false, FileCreateFlags.PRIVATE);
            uint8[] zeros = new uint8[4096];
            int64 written = 0;
            while (written < size) {
                int chunk = (int) int64.min(4096, size - written);
                os.write(zeros[0:chunk]);
                written += chunk;
            }
            os.close();
        }
    } catch (Error e) {
        // Best effort - proceed to remove
    }
    FileUtils.remove(path);
}

/**
 * Internal GPG run WITHOUT mutex (caller must hold the lock)
 */
private static GpgTimeoutState install_subprocess_timeout(Subprocess subprocess, Cancellable cancellable, uint timeout_seconds) {
    var timeout_state = new GpgTimeoutState();
    if (timeout_seconds == 0) return timeout_state;

    Thread<void*> timeout_thread = new Thread<void*>("gpg-timeout", () => {
        int64 deadline = get_monotonic_time() + (int64) timeout_seconds * 1000000;
        while (!timeout_state.is_completed() && get_monotonic_time() < deadline) {
            Thread.usleep(100000);
        }
        if (timeout_state.mark_timed_out()) {
            warning("GPGHelper: GPG subprocess timed out after %u seconds; terminating it", timeout_seconds);
            cancellable.cancel();
            subprocess.force_exit();
        }
        return null;
    });
    timeout_state.set_timeout_thread(timeout_thread);
    return timeout_state;
}

private static void remove_subprocess_timeout(GpgTimeoutState timeout_state) {
    timeout_state.mark_completed();
    timeout_state.join_timeout_thread();
}

private static bool run_gpg_internal(string[] extra_args, string? stdin_data, out string stdout_str, out string stderr_str, out int exit_status, bool allow_interactive = false, uint timeout_seconds = 0) {
    stdout_str = "";
    stderr_str = "";
    exit_status = -1;

    try {
        var args = new ArrayList<string>();
        foreach (string arg in get_base_command(allow_interactive)) {
            args.add(arg);
        }
        foreach (string arg in extra_args) {
            if (arg != null) args.add(arg);
        }
        string[] cmd = string_collection_to_array(args);
        debug("GPGHelper.run_gpg_internal: Running: %s", string.joinv(" ", cmd));
        if (allow_interactive) {
            // Interactive mode (with Pinentry)
            // If stdin_data is provided, pipe it; otherwise NO PIPES to avoid Windows GLib crash
            if (stdin_data != null && stdin_data.length > 0) {
                debug("GPGHelper.run_gpg_internal: Interactive mode WITH stdin data (%d bytes)", stdin_data.length);
                var subprocess = new_subprocess(cmd, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                var cancellable = new Cancellable();
                register_active_subprocess(subprocess, cancellable);
                var timeout_state = install_subprocess_timeout(subprocess, cancellable, timeout_seconds);
                Bytes? stdout_bytes = null;
                Bytes? stderr_bytes = null;
                var input_bytes = new Bytes(stdin_data.data);
                try {
                    subprocess.communicate(input_bytes, cancellable, out stdout_bytes, out stderr_bytes);
                } catch (Error e) {
                    if (timeout_state.has_timed_out()) {
                        stdout_str = "";
                        stderr_str = "GPG operation timed out";
                        exit_status = -2;
                        return false;
                    }
                    if (is_shutdown_requested()) {
                        stdout_str = "";
                        stderr_str = GPG_HELPER_SHUTDOWN_MESSAGE;
                        exit_status = GPG_HELPER_SHUTDOWN_EXIT_STATUS;
                        return false;
                    }
                    throw e;
                } finally {
                    remove_subprocess_timeout(timeout_state);
                    clear_active_subprocess(subprocess);
                }
                if (timeout_state.has_timed_out()) {
                    stdout_str = "";
                    stderr_str = "GPG operation timed out";
                    exit_status = -2;
                    return false;
                }
                
                if (stdout_bytes != null) {
                    stdout_str = (string) stdout_bytes.get_data();
                    if (stdout_str == null) stdout_str = "";
                }
                if (stderr_bytes != null) {
                    stderr_str = (string) stderr_bytes.get_data();
                    if (stderr_str == null) stderr_str = "";
                }
                
                if (subprocess.get_if_exited()) {
                    exit_status = subprocess.get_exit_status();
                } else {
                    exit_status = -1;
                }
                return exit_status == 0;
            } else {
                debug("GPGHelper.run_gpg_internal: Interactive mode, creating subprocess...");
                var subprocess = new_subprocess(cmd, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                var cancellable = new Cancellable();
                register_active_subprocess(subprocess, cancellable);
                var timeout_state = install_subprocess_timeout(subprocess, cancellable, timeout_seconds);
                debug("GPGHelper.run_gpg_internal: Waiting for subprocess...");
                try {
                    subprocess.wait(cancellable);
                } catch (Error e) {
                    if (timeout_state.has_timed_out()) {
                        stdout_str = "";
                        stderr_str = "GPG operation timed out";
                        exit_status = -2;
                        return false;
                    }
                    if (is_shutdown_requested()) {
                        stdout_str = "";
                        stderr_str = GPG_HELPER_SHUTDOWN_MESSAGE;
                        exit_status = GPG_HELPER_SHUTDOWN_EXIT_STATUS;
                        return false;
                    }
                    throw e;
                } finally {
                    remove_subprocess_timeout(timeout_state);
                    clear_active_subprocess(subprocess);
                }
                debug("GPGHelper.run_gpg_internal: Subprocess finished");
                if (timeout_state.has_timed_out()) {
                    stdout_str = "";
                    stderr_str = "GPG operation timed out";
                    exit_status = -2;
                    return false;
                }
                
                if (subprocess.get_if_exited()) {
                    exit_status = subprocess.get_exit_status();
                } else {
                    exit_status = -1;
                }
                
                stdout_str = "";
                stderr_str = "";
                return exit_status == 0;
            }
        } else {
            // Non-interactive mode (batch): Pipes are safe
            debug("GPGHelper.run_gpg_internal: Batch mode, creating subprocess with pipes...");
            SubprocessFlags flags = SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE;
            var subprocess = new_subprocess(cmd, flags);
            var cancellable = new Cancellable();
            register_active_subprocess(subprocess, cancellable);
            var timeout_state = install_subprocess_timeout(subprocess, cancellable, timeout_seconds);
            
            Bytes? stdout_bytes = null;
            Bytes? stderr_bytes = null;
            Bytes? input_bytes = (stdin_data != null && stdin_data.length > 0) ? new Bytes(stdin_data.data) : new Bytes(new uint8[0]);
            debug("GPGHelper.run_gpg_internal: Communicating with subprocess...");
            try {
                subprocess.communicate(input_bytes, cancellable, out stdout_bytes, out stderr_bytes);
            } catch (Error e) {
                if (timeout_state.has_timed_out()) {
                    stdout_str = "";
                    stderr_str = "GPG operation timed out";
                    exit_status = -2;
                    return false;
                }
                if (is_shutdown_requested()) {
                    stdout_str = "";
                    stderr_str = GPG_HELPER_SHUTDOWN_MESSAGE;
                    exit_status = GPG_HELPER_SHUTDOWN_EXIT_STATUS;
                    return false;
                }
                throw e;
            } finally {
                remove_subprocess_timeout(timeout_state);
                clear_active_subprocess(subprocess);
            }
            debug("GPGHelper.run_gpg_internal: Communication complete");
            if (timeout_state.has_timed_out()) {
                stdout_str = "";
                stderr_str = "GPG operation timed out";
                exit_status = -2;
                return false;
            }
            
            if (stdout_bytes != null) {
                stdout_str = (string) stdout_bytes.get_data();
                if (stdout_str == null) stdout_str = "";
            }
            if (stderr_bytes != null) {
                stderr_str = (string) stderr_bytes.get_data();
                if (stderr_str == null) stderr_str = "";
            }
            
            if (subprocess.get_if_exited()) {
                exit_status = subprocess.get_exit_status();
            } else {
                exit_status = -1;
            }
            
            debug("GPGHelper.run_gpg_internal: Exit status=%d, stdout_len=%d, stderr_len=%d", 
                  exit_status, stdout_str.length, stderr_str.length);
            return exit_status == 0;
        }
    } catch (Error e) {
        debug("GPGHelper.run_gpg_internal: Exception: %s", e.message);
        stdout_str = "";
        if (is_shutdown_requested()) {
            stderr_str = GPG_HELPER_SHUTDOWN_MESSAGE;
            exit_status = GPG_HELPER_SHUTDOWN_EXIT_STATUS;
        } else {
            stderr_str = e.message;
            exit_status = -1;
        }
        return false;
    }
}

/**
 * Submit a GPG operation to the worker queue and wait for completion.
 * Serializes all GPG subprocess calls through the single worker thread.
 * Safe to call from any thread — the caller blocks until the operation completes.
 */
private static bool run_gpg_sync(string[] extra_args, string? stdin_data, out string stdout_str, out string stderr_str, out int exit_status, bool allow_interactive = false, uint timeout_seconds = 0) {
    var job = new GpgJob(extra_args, stdin_data, allow_interactive, "run_gpg_sync", timeout_seconds);

    shutdown_mutex.lock();
    if (shutdown_requested) {
        shutdown_mutex.unlock();
        stdout_str = "";
        stderr_str = GPG_HELPER_SHUTDOWN_MESSAGE;
        exit_status = GPG_HELPER_SHUTDOWN_EXIT_STATUS;
        return false;
    }

    ensure_worker_started();
    job_queue.push(job);
    shutdown_mutex.unlock();

    // Wait for the worker to complete this job
    result_mutex.lock();
    if (timeout_seconds > 0) {
        int64 end_time = get_monotonic_time() + ((int64) timeout_seconds + 5) * 1000000;
        while (!job.completed) {
            if (!result_cond.wait_until(result_mutex, end_time)) {
                break;
            }
        }
    } else {
        while (!job.completed) {
            result_cond.wait(result_mutex);
        }
    }
    bool completed = job.completed;
    result_mutex.unlock();

    if (!completed) {
        stdout_str = "";
        stderr_str = "GPG operation timed out";
        exit_status = -2;
        return false;
    }

    stdout_str = job.stdout_str;
    stderr_str = job.stderr_str;
    exit_status = job.exit_status;
    return job.result;
}

/**
 * Encrypt text to ASCII armor for given key fingerprints
 */
public static string encrypt_armor(string plain, Key[] keys, int flags = 0) throws GLib.Error {
    initialize();
    
    debug("GPGHelper.encrypt_armor: Encrypting to %d keys", keys.length);
    
    if (keys.length == 0) {
        throw new IOError.FAILED("GPG encrypt failed: No recipient keys provided");
    }
    
    var args = new ArrayList<string>();
    args.add("--armor");
    args.add("--encrypt");
    args.add("--trust-model");
    args.add("always");
    
    foreach (Key key in keys) {
        args.add("-r");
        args.add(key.fpr);
        debug("GPGHelper.encrypt_armor: Adding recipient %s", key.fpr);
    }
    
    // Write plaintext to temp file
    string temp_in = Path.build_filename(Environment.get_tmp_dir(), "dinox-enc-in-%d".printf(Random.int_range(0, 1000000)));
    string temp_out = temp_in + ".asc";
    debug("GPGHelper.encrypt_armor: Writing to temp file %s", temp_in);
    secure_write_file(temp_in, plain);
    debug("GPGHelper.encrypt_armor: Temp file written, size=%d", plain.length);
    
    args.add("-o");
    args.add(temp_out);
    args.add(temp_in);
    
    string stdout_str, stderr_str;
    int exit_status;
    debug("GPGHelper.encrypt_armor: Calling GPG...");
    // Serialized through the worker queue — no manual lock needed
    run_gpg_sync(string_collection_to_array(args), null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    debug("GPGHelper.encrypt_armor: GPG returned, exit=%d", exit_status);
    
    secure_delete_file(temp_in);
    
    if (exit_status != 0) {
        secure_delete_file(temp_out);
        debug("GPGHelper.encrypt_armor: GPG failed: %s", stderr_str);
        throw new IOError.FAILED("GPG encrypt failed: %s", stderr_str);
    }
    
    debug("GPGHelper.encrypt_armor: Reading output file %s", temp_out);
    string result;
    FileUtils.get_contents(temp_out, out result);
    secure_delete_file(temp_out);
    
    debug("GPGHelper.encrypt_armor: Success, result length=%d", result.length);
    return result;
}

private static string? get_sign_encrypt_passphrase(Key sign_key) throws GLib.Error {
    if (key_requires_passphrase(sign_key.fpr)) {
        string? passphrase = request_passphrase(sign_key.fpr, "sign");
        if (passphrase == null || passphrase.length == 0) {
            throw new IOError.FAILED("GPG sign+encrypt failed: passphrase required");
        }
        return passphrase;
    }
    return "";
}

private static Key get_private_signing_key(string requested_key, string operation) throws GLib.Error {
    Key? private_key = null;
    try {
        private_key = get_private_key(requested_key);
    } catch (Error e) {
        throw new IOError.FAILED("%s failed: configured signing key %s is not usable: %s".printf(operation, requested_key, e.message));
    }

    if (private_key == null || !openpgp_key_ids_match(requested_key, ((!) private_key).fpr)) {
        throw new IOError.FAILED("%s failed: configured signing key %s is not available in the private keyring".printf(operation, requested_key));
    }

    if (((!) private_key).revoked || ((!) private_key).expired || !((!) private_key).can_sign) {
        throw new IOError.FAILED("%s failed: configured signing key %s is revoked, expired, or cannot sign".printf(operation, requested_key));
    }

    return (!) private_key;
}

private static Key get_signing_key(Key[] recipients, Key? sign_key) throws GLib.Error {
    if (sign_key != null) return get_private_signing_key(sign_key.fpr, "GPG sign+encrypt");
    if (recipients.length == 0) throw new IOError.FAILED("GPG sign+encrypt failed: no signing key configured");

    // DinoX always puts the account key first.  Do not fall through to another
    // local recipient key, otherwise messages could be signed by the wrong JID.
    return get_private_signing_key(recipients[0].fpr, "GPG sign+encrypt");
}

private static ArrayList<string> build_sign_encrypt_args(Key[] recipients, Key sign_key, bool armor) {
    var args = new ArrayList<string>();
    add_loopback_passphrase_args(args);
    if (armor) args.add("--armor");
    args.add("--sign");
    args.add("--encrypt");
    args.add("--trust-model");
    args.add("always");

    args.add("-u");
    args.add(sign_key.fpr);

    foreach (Key key in recipients) {
        args.add("-r");
        args.add(key.fpr);
    }

    return args;
}

/**
 * Sign and encrypt text to ASCII armor (legacy helper).
 */
public static string sign_and_encrypt(string plain, Key[] recipients, Key? sign_key = null) throws GLib.Error {
    initialize();

    Key signing_key = get_signing_key(recipients, sign_key);
    string passphrase = get_sign_encrypt_passphrase(signing_key);
    var args = build_sign_encrypt_args(recipients, signing_key, true);
    
    // Write plaintext to temp file
    string temp_in = Path.build_filename(Environment.get_tmp_dir(), "dinox-signenc-in-%d".printf(Random.int_range(0, 1000000)));
    string temp_out = temp_in + ".asc";
    secure_write_file(temp_in, plain);
    
    args.add("-o");
    args.add(temp_out);
    args.add(temp_in);
    
    string stdout_str, stderr_str;
    int exit_status;
    // Serialized through the worker queue
    run_gpg_sync(string_collection_to_array(args), passphrase + "\n", out stdout_str, out stderr_str, out exit_status);
    
    secure_delete_file(temp_in);
    
    if (exit_status != 0) {
        secure_delete_file(temp_out);
        if (is_bad_passphrase_error(stderr_str)) clear_passphrase(signing_key.fpr);
        throw new IOError.FAILED("GPG sign+encrypt failed: %s", stderr_str);
    }
    if (passphrase.length > 0) cache_passphrase(signing_key.fpr, passphrase);
    
    string signenc_result;
    FileUtils.get_contents(temp_out, out signenc_result);
    secure_delete_file(temp_out);
    
    return signenc_result;
}

/**
 * Sign and encrypt text to raw OpenPGP bytes.
 *
 * XEP-0374 transports Base64-encoded OpenPGP binary packets in <openpgp/>.
 * It must not contain ASCII armor headers, armor line wrapping, or the armor CRC.
 */
public static uint8[] sign_and_encrypt_data(string plain, Key[] recipients, Key? sign_key = null) throws GLib.Error {
    initialize();

    Key signing_key = get_signing_key(recipients, sign_key);
    string passphrase = get_sign_encrypt_passphrase(signing_key);
    var args = build_sign_encrypt_args(recipients, signing_key, false);

    string temp_in = Path.build_filename(Environment.get_tmp_dir(), "dinox-signenc-in-%d".printf(Random.int_range(0, 1000000)));
    string temp_out = temp_in + ".gpg";
    secure_write_file(temp_in, plain);

    args.add("-o");
    args.add(temp_out);
    args.add(temp_in);

    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(string_collection_to_array(args), passphrase + "\n", out stdout_str, out stderr_str, out exit_status);

    secure_delete_file(temp_in);

    if (exit_status != 0) {
        secure_delete_file(temp_out);
        if (is_bad_passphrase_error(stderr_str)) clear_passphrase(signing_key.fpr);
        throw new IOError.FAILED("GPG sign+encrypt failed: %s", stderr_str);
    }
    if (passphrase.length > 0) cache_passphrase(signing_key.fpr, passphrase);

    uint8[] signenc_result;
    FileUtils.get_data(temp_out, out signenc_result);
    secure_delete_file(temp_out);

    return signenc_result;
}

/**
 * Encrypt file to binary for given key fingerprints
 */
public static uint8[] encrypt_file(string uri, Key[] keys, int flags, string file_name) throws GLib.Error {
    string temp_out = Path.build_filename(Environment.get_tmp_dir(), "dinox-enc-out-%d.gpg".printf(Random.int_range(0, 1000000)));
    try {
        encrypt_file_to_path(uri, temp_out, keys, flags, file_name);

        uint8[] result;
        FileUtils.get_data(temp_out, out result);
        return result;
    } finally {
        secure_delete_file(temp_out);
    }
}

public static int64 encrypt_file_to_path(string input_path, string output_path, Key[] keys, int flags, string file_name) throws GLib.Error {
    initialize();

    Key sign_key = get_file_signing_key(keys);
    string passphrase = "";
    if (key_requires_passphrase(sign_key.fpr)) {
        string? requested_passphrase = request_passphrase(sign_key.fpr, "sign");
        if (requested_passphrase == null || requested_passphrase.length == 0) {
            throw new IOError.FAILED("GPG encrypt file failed: passphrase required");
        }
        passphrase = (!) requested_passphrase;
    }

    var args = new ArrayList<string>();
    add_loopback_passphrase_args(args);
    args.add("--sign");
    args.add("--encrypt");
    args.add("--trust-model");
    args.add("always");
    args.add("--set-filename");
    args.add(file_name);
    args.add("-u");
    args.add(sign_key.fpr);
    
    foreach (Key key in keys) {
        args.add("-r");
        args.add(key.fpr);
    }
    
    args.add("-o");
    args.add(output_path);
    args.add(input_path);
    
    string stdout_str, stderr_str;
    int exit_status;
    // Serialized through the worker queue
    run_gpg_sync(string_collection_to_array(args), passphrase + "\n", out stdout_str, out stderr_str, out exit_status);
    
    if (exit_status != 0) {
        secure_delete_file(output_path);
        if (is_bad_passphrase_error(stderr_str)) clear_passphrase(sign_key.fpr);
        throw new IOError.FAILED("GPG encrypt file failed: %s", stderr_str);
    }
    if (passphrase.length > 0) cache_passphrase(sign_key.fpr, passphrase);

    return query_file_size(output_path);
}

private static Key get_file_signing_key(Key[] keys) throws GLib.Error {
    if (keys.length == 0) throw new IOError.FAILED("GPG encrypt file failed: no signing key configured");

    // Same contract as messages: the first key is the configured account key.
    // If it is gone/unusable, fail closed instead of signing with another
    // recipient key that happens to exist locally.
    return get_private_signing_key(keys[0].fpr, "GPG encrypt file");
}

private static int64 query_file_size(string path) throws GLib.Error {
    File file = File.new_for_path(path);
    FileInfo info = file.query_info("standard::size", FileQueryInfoFlags.NONE);
    return info.get_size();
}

/**
 * Check if we have the secret key needed to decrypt a message.
 * Uses --list-packets in batch mode to extract recipient key IDs,
 * then checks if we have any of those keys.
 * This avoids starting pinentry for messages we can't decrypt anyway.
 */
private static string? find_decryption_key(string temp_in) {
    // Use --list-packets to see which keys the message is encrypted to
    // This is a batch operation that doesn't require passphrase
    string[] args = { "--list-packets", "--list-only", temp_in };
    
    string stdout_str, stderr_str;
    int exit_status;
    // Serialized through the worker queue
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status, false);
    
    // GPG outputs key IDs in format like:
    // :pubkey enc packet: version 3, algo 16, keyid 282580F966E14B2E
    // We need to extract those keyids and check if we have any of them
    
    var recipient_keyids = new ArrayList<string>();
    string combined_output = stdout_str + "\n" + stderr_str;
    
    foreach (string line in combined_output.split("\n")) {
        if (line.contains("keyid ")) {
            int keyid_pos = line.index_of("keyid ");
            if (keyid_pos >= 0) {
                string keyid_part = line.substring(keyid_pos + 6).strip();
                // keyid is 16 hex chars
                if (keyid_part.length >= 16) {
                    string keyid = keyid_part.substring(0, 16);
                    recipient_keyids.add(keyid.up());
                    debug("GPGHelper: Message encrypted to keyid %s", keyid);
                }
            }
        }
    }
    
    if (recipient_keyids.size == 0) {
        // Couldn't determine recipients, try to decrypt anyway
        debug("GPGHelper: Could not determine message recipients");
        return null;
    }
    
    string[] secret_args = { "--list-secret-keys", "--with-colons", "--with-fingerprint" };
    run_gpg_sync(secret_args, null, out stdout_str, out stderr_str, out exit_status, false);
    string? decrypt_key_fpr = find_secret_primary_for_recipient_keyids(stdout_str + "\n" + stderr_str, recipient_keyids);
    if (decrypt_key_fpr != null) {
        debug("GPGHelper: We have secret key %s for this message", decrypt_key_fpr);
        return decrypt_key_fpr;
    }
    
    debug("GPGHelper: We don't have any secret key for recipients: %s", 
          join_strings(", ", recipient_keyids));
    return "";
}

internal static string? find_secret_primary_for_recipient_keyids(string gpg_colons_output, Gee.Collection<string> recipient_keyids) {
    string? current_primary_fpr = null;
    bool expect_primary_fpr = false;
    bool expect_subkey_fpr = false;

    foreach (string line in gpg_colons_output.split("\n")) {
        var parts = line.split(":");
        if (parts.length < 10) continue;

        string record_type = parts[0];
        if (record_type == "sec") {
            current_primary_fpr = null;
            expect_primary_fpr = true;
            expect_subkey_fpr = false;
        } else if (record_type == "ssb") {
            expect_primary_fpr = false;
            expect_subkey_fpr = true;
        } else if (record_type == "fpr") {
            string fingerprint = parts[9];
            if (fingerprint.length == 0) {
                expect_primary_fpr = false;
                expect_subkey_fpr = false;
                continue;
            }

            if (expect_primary_fpr) {
                current_primary_fpr = fingerprint;
                expect_primary_fpr = false;
                if (recipient_keyids.contains(keyid_from_fingerprint(fingerprint))) {
                    return fingerprint;
                }
            } else if (expect_subkey_fpr) {
                expect_subkey_fpr = false;
                if (current_primary_fpr != null && recipient_keyids.contains(keyid_from_fingerprint(fingerprint))) {
                    return current_primary_fpr;
                }
            }
        }
    }

    return null;
}

/**
 * Decrypt ASCII armored text
 */
public static string decrypt(string encr) throws GLib.Error {
    initialize();
    
    string temp_in = Path.build_filename(Environment.get_tmp_dir(), "dinox-dec-in-%d.asc".printf(Random.int_range(0, 1000000)));
    string temp_out = Path.build_filename(Environment.get_tmp_dir(), "dinox-dec-out-%d".printf(Random.int_range(0, 1000000)));
    secure_write_file(temp_in, encr);
    
    // First check if we have the secret key needed.
    string? decrypt_key_fpr = find_decryption_key(temp_in);
    if (decrypt_key_fpr == "") {
        secure_delete_file(temp_in);
        throw new IOError.FAILED("GPG decrypt failed: no secret key available for this message");
    }

    string? passphrase = "";
    if (decrypt_key_fpr != null && key_requires_passphrase(decrypt_key_fpr)) {
        passphrase = request_passphrase(decrypt_key_fpr, "decrypt");
        if (passphrase == null || passphrase.length == 0) {
            secure_delete_file(temp_in);
            throw new IOError.FAILED("GPG decrypt failed: passphrase required");
        }
    }

    string stdout_str, stderr_str;
    int exit_status;
    bool decryption_ok = false;
    
    var args = new ArrayList<string>();
    add_loopback_passphrase_args(args);
    args.add("--decrypt");
    args.add("--status-fd");
    args.add("2");
    args.add("--ignore-crc-error");
    args.add("-o");
    args.add(temp_out);
    args.add(temp_in);
    debug("GPGHelper.decrypt: Trying DinoX loopback mode...");
    run_gpg_sync(string_collection_to_array(args), passphrase + "\n", out stdout_str, out stderr_str, out exit_status, false);
    
    decryption_ok = stderr_str.contains("[GNUPG:] DECRYPTION_OKAY") || 
                    stderr_str.contains("[GNUPG:] GOODMDC");
    
    secure_delete_file(temp_in);
    
    if (!decryption_ok && exit_status != 0) {
        if (FileUtils.test(temp_out, FileTest.EXISTS)) {
            secure_delete_file(temp_out);
        }
        if (decrypt_key_fpr != null && is_bad_passphrase_error(stderr_str)) clear_passphrase(decrypt_key_fpr);
        throw new IOError.FAILED("GPG decrypt failed (exit %d): no secret key or passphrase error", exit_status);
    }
    if (decrypt_key_fpr != null && passphrase.length > 0) cache_passphrase(decrypt_key_fpr, passphrase);
    
    if (!FileUtils.test(temp_out, FileTest.EXISTS)) {
        throw new IOError.FAILED("GPG decrypt failed: output file not created");
    }
    
    string result;
    FileUtils.get_contents(temp_out, out result);
    secure_delete_file(temp_out);
    debug("GPGHelper.decrypt: Success, decrypted %d chars", result.length);
    
    return result;
}

/**
 * Decrypt binary data
 */
public static DecryptedData decrypt_data(uint8[] data) throws GLib.Error {
    initialize();
    
    string temp_in = Path.build_filename(Environment.get_tmp_dir(), "dinox-dec-in-%d.gpg".printf(Random.int_range(0, 1000000)));
    string temp_out = Path.build_filename(Environment.get_tmp_dir(), "dinox-dec-out-%d".printf(Random.int_range(0, 1000000)));

    try {
        secure_write_data(temp_in, data);
        DecryptedFile decrypted_file = decrypt_file_to_path(temp_in, temp_out);

        uint8[] result_data;
        FileUtils.get_data(temp_out, out result_data);
        debug("GPGHelper.decrypt_data: Success, decrypted %d bytes", result_data.length);

        return new DecryptedData() {
            data = result_data,
            filename = decrypted_file.filename,
            signer_fingerprint = decrypted_file.signer_fingerprint,
            signature_valid = decrypted_file.signature_valid
        };
    } finally {
        secure_delete_file(temp_in);
        secure_delete_file(temp_out);
    }
}

public static DecryptedFile decrypt_file_to_path(string encrypted_path, string output_path) throws GLib.Error {
    initialize();

    string? decrypt_key_fpr = find_decryption_key(encrypted_path);
    if (decrypt_key_fpr == "") {
        throw new IOError.FAILED("GPG decrypt data failed: no secret key available for this message");
    }

    string passphrase = "";
    if (decrypt_key_fpr != null && key_requires_passphrase(decrypt_key_fpr)) {
        string? requested_passphrase = request_passphrase(decrypt_key_fpr, "decrypt");
        if (requested_passphrase == null || requested_passphrase.length == 0) {
            throw new IOError.FAILED("GPG decrypt data failed: passphrase required");
        }
        passphrase = (!) requested_passphrase;
    }

    string stdout_str, stderr_str;
    int exit_status;

    var args = new ArrayList<string>();
    add_loopback_passphrase_args(args);
    args.add("--decrypt");
    args.add("--status-fd");
    args.add("2");
    args.add("--ignore-crc-error");
    args.add("-o");
    args.add(output_path);
    args.add(encrypted_path);
    debug("GPGHelper.decrypt_file_to_path: Trying DinoX loopback mode...");
    run_gpg_sync(string_collection_to_array(args), passphrase + "\n", out stdout_str, out stderr_str, out exit_status, false);

    bool decryption_ok = stderr_str.contains("[GNUPG:] DECRYPTION_OKAY") ||
                         stderr_str.contains("[GNUPG:] GOODMDC");

    if (!decryption_ok && exit_status != 0) {
        secure_delete_file(output_path);
        if (decrypt_key_fpr != null && is_bad_passphrase_error(stderr_str)) clear_passphrase(decrypt_key_fpr);
        throw new IOError.FAILED("GPG decrypt data failed (exit %d): no secret key or passphrase error", exit_status);
    }
    if (decrypt_key_fpr != null && passphrase.length > 0) cache_passphrase(decrypt_key_fpr, passphrase);

    if (!FileUtils.test(output_path, FileTest.EXISTS)) {
        throw new IOError.FAILED("GPG decrypt data failed: output file not created");
    }

    string filename = parse_plaintext_filename_from_status(stderr_str);
    string? signer_fingerprint = parse_valid_signature_fingerprint_from_status(stderr_str);

    return new DecryptedFile() {
        path = output_path,
        size = query_file_size(output_path),
        filename = filename,
        signer_fingerprint = signer_fingerprint,
        signature_valid = signer_fingerprint != null
    };
}

internal static string? parse_valid_signature_fingerprint_from_status(string status_output) {
    foreach (string raw_line in status_output.split("\n")) {
        string line = raw_line.strip();
        if (!line.contains("[GNUPG:] VALIDSIG")) continue;

        var parts = line.split(" ");
        // GnuPG's VALIDSIG status reports the signing key fingerprint first.
        // When the signature was made by a signing subkey, the owning primary
        // key fingerprint is reported as the final fingerprint field. DinoX
        // stores and verifies XEP-0373 contact identities by primary
        // fingerprint, so prefer the last full fingerprint in the status line.
        for (int i = parts.length - 1; i >= 2; i--) {
            string normalized = normalize_openpgp_key_id(parts[i]);
            if (is_full_openpgp_fingerprint(normalized)) {
                return normalized;
            }
        }
    }

    return null;
}

private static bool is_full_openpgp_fingerprint(string value) {
    if (value.length != 40) return false;
    for (int i = 0; i < value.length; i++) {
        char c = value[i];
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) {
            return false;
        }
    }
    return true;
}

internal static string parse_plaintext_filename_from_status(string status_output) {
    foreach (string raw_line in status_output.split("\n")) {
        string line = raw_line.strip();
        if (!line.contains("[GNUPG:] PLAINTEXT")) continue;

        var parts = line.split(" ");
        if (parts.length < 5) return "";

        string raw_filename = parts[4].strip();
        string? decoded = GLib.Uri.unescape_string(raw_filename);
        return (decoded ?? raw_filename).strip();
    }
    return "";
}

/**
 * Sign text (clear signature)
 */
public static string sign(string plain, int mode, Key? key = null) throws GLib.Error {
    initialize();
    
    // Check if key requires passphrase
    // With the worker queue there is no deadlock risk — each call is an independent queue submission
    bool needs_passphrase = true;
    if (key != null) {
        needs_passphrase = key_requires_passphrase(key.fpr);
    }
    string? passphrase = "";
    if (needs_passphrase) {
        if (key == null) {
            throw new IOError.FAILED("GPG sign failed: no signing key configured");
        }
        passphrase = request_passphrase(key.fpr, "sign");
        if (passphrase == null || passphrase.length == 0) {
            throw new IOError.FAILED("GPG sign failed: passphrase required");
        }
    }
    
    string temp_in = Path.build_filename(Environment.get_tmp_dir(), "dinox-sign-in-%d".printf(Random.int_range(0, 1000000)));
    string temp_out = Path.build_filename(Environment.get_tmp_dir(), "dinox-sign-out-%d.asc".printf(Random.int_range(0, 1000000)));
    secure_write_file(temp_in, plain);
    
    var args = new ArrayList<string>();
    args.add("--armor");
    // XEP-0027 requires detached signature, not clearsign
    args.add("--detach-sign");
    
    add_loopback_passphrase_args(args);
    
    if (key != null) {
        args.add("-u");
        args.add(key.fpr);
    }
    
    args.add("-o");
    args.add(temp_out);
    args.add(temp_in);
    
    string stdout_str, stderr_str;
    int exit_status;
    // Serialized through the worker queue
    run_gpg_sync(string_collection_to_array(args), passphrase + "\n", out stdout_str, out stderr_str, out exit_status);
    
    secure_delete_file(temp_in);
    
    if (exit_status != 0) {
        secure_delete_file(temp_out);
        if (key != null && is_bad_passphrase_error(stderr_str)) clear_passphrase(key.fpr);
        throw new IOError.FAILED("GPG sign failed: %s", stderr_str);
    }
    if (key != null && passphrase.length > 0) cache_passphrase(key.fpr, passphrase);
    
    string result;
    FileUtils.get_contents(temp_out, out result);
    secure_delete_file(temp_out);
    
    return result;
}

/**
 * Result of signature verification
 */
public class SignatureVerifyResult {
    public string? key_id { get; set; }
    public bool verified { get; set; default = false; }  // true if signature is valid and key is in keyring
    public bool key_missing { get; set; default = false; }  // true if key is not in keyring
    
    public SignatureVerifyResult() {}
}

/**
 * Verify signature and get signing key fingerprint
 * Returns detailed result including whether key is in keyring
 */
public static SignatureVerifyResult verify_signature(string signature, string? text) throws GLib.Error {
    initialize();
    
    var result = new SignatureVerifyResult();
    
    string temp_sig = Path.build_filename(Environment.get_tmp_dir(), "dinox-verify-sig-%d.asc".printf(Random.int_range(0, 1000000)));
    string temp_status = Path.build_filename(Environment.get_tmp_dir(), "dinox-verify-status-%d.txt".printf(Random.int_range(0, 1000000)));
    secure_write_file(temp_sig, signature);
    
    var args = new ArrayList<string>();
    args.add("--verify");
    args.add("--status-file");
    args.add(temp_status);
    args.add(temp_sig);
    
    string? temp_text = null;
    if (text != null) {
        temp_text = Path.build_filename(Environment.get_tmp_dir(), "dinox-verify-txt-%d".printf(Random.int_range(0, 1000000)));
        secure_write_file(temp_text, text);
        args.add(temp_text);
    }
    
    string stdout_str, stderr_str;
    int exit_status;
    // Serialized through the worker queue
    run_gpg_sync(string_collection_to_array(args), null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    
    secure_delete_file(temp_sig);
    if (temp_text != null) {
        secure_delete_file(temp_text);
    }
    
    // Read status from file
    string status_output = "";
    if (FileUtils.test(temp_status, FileTest.EXISTS)) {
        try {
            FileUtils.get_contents(temp_status, out status_output);
        } catch (Error e) {
            debug("GPGHelper.verify_signature: Could not read status file: %s", e.message);
        }
        secure_delete_file(temp_status);
    }
    
    // Parse fingerprint from status output
    foreach (string line in status_output.split("\n")) {
        if (line.contains("[GNUPG:] VALIDSIG")) {
            var parts = line.split(" ");
            if (parts.length >= 3) {
                result.key_id = parts[2];
                result.verified = true;
                debug("GPGHelper.verify_signature: VALID signature from key: %s", parts[2]);
                return result;
            }
        }
        if (line.contains("[GNUPG:] GOODSIG")) {
            var parts = line.split(" ");
            if (parts.length >= 3) {
                result.key_id = parts[2];
                result.verified = true;
                debug("GPGHelper.verify_signature: GOOD signature from key: %s", parts[2]);
                return result;
            }
        }
    }
    
    // Key not in keyring - extract key ID anyway
    foreach (string line in status_output.split("\n")) {
        if (line.contains("[GNUPG:] ERRSIG")) {
            var parts = line.split(" ");
            if (parts.length >= 3) {
                result.key_id = parts[2];
                result.key_missing = true;
                debug("GPGHelper.verify_signature: Key %s NOT in keyring (ERRSIG)", parts[2]);
                return result;
            }
        }
        if (line.contains("[GNUPG:] NO_PUBKEY")) {
            var parts = line.split(" ");
            if (parts.length >= 3) {
                result.key_id = parts[2];
                result.key_missing = true;
                debug("GPGHelper.verify_signature: Key %s NOT in keyring (NO_PUBKEY)", parts[2]);
                return result;
            }
        }
    }
    
    debug("GPGHelper.verify_signature: Could not find any key ID in output");
    return result;
}

/**
 * Verify signature and get signing key fingerprint (simple version for compatibility)
 */
public static string? get_sign_key(string signature, string? text) throws GLib.Error {
    var result = verify_signature(signature, text);
    return result.key_id;
}

/**
 * Check if the user has any secret (private) keys.
 * Returns true if at least one secret key exists, false otherwise.
 * This is used to avoid attempting decryption when no keys are available.
 * Result is cached to avoid repeated GPG calls.
 * Thread-safe implementation to prevent race conditions.
 */
public static bool has_secret_keys() {
    if (is_shutdown_requested()) return false;

    // Quick check for cached result
    secret_keys_mutex.lock();
    if (has_secret_keys_checked) {
        bool result = has_secret_keys_cached;
        secret_keys_mutex.unlock();
        return result;
    }
    secret_keys_mutex.unlock();
    
    // Not cached, need to query GPG.
    // Do this OUTSIDE secret_keys_mutex to avoid blocking on the queue
    bool found_keys = false;
    try {
        var keys = get_keylist(null, true);  // secret_only = true
        found_keys = keys.size > 0;
        debug("GPGHelper.has_secret_keys: %s", found_keys ? "yes" : "no");
    } catch (Error e) {
        warning("GPGHelper.has_secret_keys: Error checking for keys: %s", e.message);
        found_keys = false;
    }
    
    // Update cache while holding the mutex
    secret_keys_mutex.lock();
    has_secret_keys_cached = found_keys;
    has_secret_keys_checked = true;
    secret_keys_mutex.unlock();
    
    return found_keys;
}

/**
 * Async wrapper for has_secret_keys().
 *
 * Incoming messages can be replayed in bulk during startup.  Calling the
 * synchronous helper from the receive pipeline would block the main context
 * while GnuPG starts a cold agent or scans the keyring, which is especially
 * visible on Windows after a fresh dist build.
 */
public static async bool has_secret_keys_async() {
    shutdown_mutex.lock();
    if (shutdown_requested) {
        shutdown_mutex.unlock();
        return false;
    }

    secret_keys_mutex.lock();
    if (has_secret_keys_checked) {
        bool cached = has_secret_keys_cached;
        secret_keys_mutex.unlock();
        shutdown_mutex.unlock();
        return cached;
    }
    secret_keys_mutex.unlock();

    ensure_secret_key_async_worker_started();
    SecretKeyAsyncRequest request = new SecretKeyAsyncRequest(has_secret_keys_async.callback);
    ((!) secret_key_async_queue).push(request);
    shutdown_mutex.unlock();
    yield;
    return request.result;
}

/**
 * Invalidate the has_secret_keys cache (call after key import/generation)
 * Thread-safe implementation.
 */
public static void invalidate_secret_keys_cache() {
    secret_keys_mutex.lock();
    has_secret_keys_checked = false;
    secret_keys_mutex.unlock();
}

/**
 * Get list of keys
 */
public static Gee.List<Key> get_keylist(string? pattern = null, bool secret_only = false) throws GLib.Error {
    initialize();
    
    var args = new ArrayList<string>();
    if (secret_only) {
        args.add("--list-secret-keys");
    } else {
        args.add("--list-keys");
    }
    args.add("--with-colons");
    args.add("--with-fingerprint");
    if (pattern != null && pattern.length > 0) {
        args.add(pattern);
    }
    
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(string_collection_to_array(args), null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    
    if (exit_status != 0 && !stderr_str.contains("No public key") && !stderr_str.contains("No secret key")) {
        // Only throw if it's a real error, not "key not found"
        if (stderr_str.length > 0 && !stderr_str.contains("not found")) {
            debug("GPG list keys warning: %s", stderr_str);
        }
    }
    
    return parse_keylist_output(stdout_str);
}

/**
 * Parse GPG --with-colons output into a list of Key objects.
 *
 * Pure function — no GPG binary needed. Extracted from get_keylist()
 * for testability.
 *
 * Record types handled:
 *   pub/sec  → new Key, read validity (e=expired, r=revoked)
 *   fpr      → fingerprint, derive keyid (last 16 chars)
 *   uid      → user ID + email extraction from <…>
 *   ssb/sub  → skip subkey fingerprints
 */
internal static Gee.List<Key> parse_keylist_output(string gpg_stdout) {
    var keys = new ArrayList<Key>();
    Key? current_key = null;
    bool expect_fpr = false;
    
    foreach (string line in gpg_stdout.split("\n")) {
        var parts = line.split(":");
        if (parts.length < 2) continue;
        
        string record_type = parts[0];
        
        if (record_type == "sec" || record_type == "pub") {
            // Start of a new key
            expect_fpr = true;
            if (parts.length >= 5) {
                // Check validity
                string validity = parts[1];
                bool expired = validity == "e";
                bool revoked = validity == "r";
                
                current_key = new Key("");
                current_key.secret = (record_type == "sec");
                current_key.expired = expired;
                current_key.revoked = revoked;
            }
        } else if (record_type == "fpr" && expect_fpr && current_key != null) {
            if (parts.length >= 10) {
                current_key.fpr = parts[9];
                current_key.keyid = current_key.fpr.length >= 16 ? 
                    current_key.fpr.substring(current_key.fpr.length - 16) : current_key.fpr;
            }
            expect_fpr = false;
        } else if (record_type == "uid" && current_key != null && current_key.uid == null) {
            if (parts.length >= 10) {
                current_key.uid = decode_gpg_colon_escapes(parts[9]);
                // Extract email
                if (current_key.uid.contains("<") && current_key.uid.contains(">")) {
                    int start = current_key.uid.index_of("<") + 1;
                    int end = current_key.uid.index_of(">");
                    if (end > start) {
                        current_key.email = current_key.uid.substring(start, end - start);
                    }
                } else if (current_key.uid.has_prefix("xmpp:")) {
                    current_key.email = null;
                }
                // Add key to list when we have uid
                if (current_key.fpr.length > 0) {
                    keys.add(current_key);
                }
            }
        } else if (record_type == "ssb" || record_type == "sub") {
            // Subkey - don't collect fpr
            expect_fpr = false;
        }
    }
    
    return keys;
}

/**
 * Get a public key by fingerprint or key ID
 */
public static Key? get_public_key(string sig) throws GLib.Error {
    var keys = get_keylist(sig, false);
    foreach (Key k in keys) {
        if (k.fpr == sig || k.keyid == sig || k.fpr.has_suffix(sig)) {
            return k;
        }
    }
    return keys.size > 0 ? keys[0] : null;
}

/**
 * Get a private key by fingerprint or key ID
 */
public static Key? get_private_key(string sig) throws GLib.Error {
    var keys = get_keylist(sig, true);
    foreach (Key k in keys) {
        if (k.fpr == sig || k.keyid == sig || k.fpr.has_suffix(sig)) {
            return k;
        }
    }
    return keys.size > 0 ? keys[0] : null;
}

/**
 * Export public key in ASCII armor format
 */
public static string? export_public_key(string key_id) throws GLib.Error {
    initialize();
    
    string[] args = { "--armor", "--export", key_id };
    
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    
    if (exit_status != 0 || stdout_str.length == 0) {
        debug("GPG export failed: %s", stderr_str);
        return null;
    }
    
    return stdout_str;
}

/**
 * Export public key as raw OpenPGP key material and return Base64.
 * XEP-0373 transports raw key bytes in <data/>, not ASCII armor.
 */
public static string? export_public_key_data_base64(string key_id) throws GLib.Error {
    initialize();

    string temp_out = Path.build_filename(Environment.get_tmp_dir(), "dinox-pubkey-%d.gpg".printf(Random.int_range(0, 1000000)));
    string[] args = { "--export", "-o", temp_out, key_id };

    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);

    if (exit_status != 0 || !FileUtils.test(temp_out, FileTest.EXISTS)) {
        secure_delete_file(temp_out);
        debug("GPG raw export failed: %s", stderr_str);
        return null;
    }

    uint8[] key_data;
    FileUtils.get_data(temp_out, out key_data);
    secure_delete_file(temp_out);

    if (key_data.length == 0) return null;
    return Base64.encode(key_data);
}

/**
 * Import a key from ASCII armor
 */
public static bool import_key(string armored_key) throws GLib.Error {
    initialize();
    
    // Validate that the key looks like ASCII armor
    string trimmed = armored_key.strip();
    if (!trimmed.has_prefix("-----BEGIN PGP")) {
        warning("GPGHelper: import_key: Invalid key format - not ASCII armored");
        return false;
    }
    if (!trimmed.has_suffix("-----")) {
        warning("GPGHelper: import_key: Invalid key format - incomplete ASCII armor");
        return false;
    }
    
    // Normalize line endings for cross-platform compatibility
    string normalized = trimmed.replace("\r\n", "\n");
    
    // Additional validation: check for invalid characters in base64 body
    // radix64 uses standard base64 alphabet: A-Z, a-z, 0-9, +, /, =
    // If we find - or _ in the body (not in headers), it's base64url which GPG doesn't understand
    int body_start = normalized.index_of("\n\n");
    if (body_start < 0) {
        // Try single newline after header line
        int first_nl = normalized.index_of("\n");
        if (first_nl > 0) {
            body_start = first_nl;
        }
    }
    if (body_start > 0) {
        string body = normalized.substring(body_start);
        int end_marker = body.index_of("-----END");
        if (end_marker > 0) {
            string key_body = body.substring(0, end_marker);
            // Check for base64url characters that will cause radix64 errors
            // Character 0x2d is '-' (dash)
            if (key_body.contains("-") || key_body.contains("_")) {
                debug("GPGHelper: import_key: Key contains base64url characters (- or _), skipping to avoid radix64 errors");
                return false;
            }
        }
    }
    
    string temp_key = Path.build_filename(Environment.get_tmp_dir(), "dinox-import-%d.asc".printf(Random.int_range(0, 1000000)));
    try {
        secure_write_file(temp_key, normalized);
    } catch (Error e) {
        warning("GPGHelper: import_key: Failed to write temp file: %s", e.message);
        return false;
    }
    
    string[] args = { "--import", temp_key };
    
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    
    secure_delete_file(temp_key);
    
    // Don't crash on radix64 errors - just log and return false
    if (exit_status != 0) {
        if (stderr_str != null && (stderr_str.contains("radix64") || stderr_str.contains("invalid packet"))) {
            debug("GPGHelper: import_key: Key has invalid encoding (radix64/packet error), ignoring");
            return false;
        }
        debug("GPGHelper: import_key: GPG returned error %d: %s", exit_status, stderr_str ?? "unknown");
        return false;
    }
    
    // Invalidate has_secret_keys cache so incoming messages can be decrypted immediately
    invalidate_secret_keys_cache();
    debug("GPGHelper: import_key: Success, secret keys cache invalidated");
    
    return true;
}

/**
 * Import raw XEP-0373 Base64 key data.  For compatibility this also accepts
 * older DinoX data where the Base64 payload decodes to ASCII armor.
 */
public static bool import_key_data_base64(string base64_key_data) throws GLib.Error {
    ImportResult result = import_key_data_base64_with_result(base64_key_data);
    return result.imported;
}

public static ImportResult import_key_data_base64_with_result(string base64_key_data) throws GLib.Error {
    initialize();
    var result = new ImportResult();

    string clean = base64_key_data.strip().replace("\n", "").replace("\r", "").replace(" ", "").replace("\t", "");
    if (clean.length == 0) return result;

    uint8[] key_data = Base64.decode(clean);
    if (key_data.length == 0) return result;

    string temp_key = Path.build_filename(Environment.get_tmp_dir(), "dinox-import-%d.gpg".printf(Random.int_range(0, 1000000)));
    try {
        secure_write_data(temp_key, key_data);
    } catch (Error e) {
        warning("GPGHelper: import_key_data_base64: Failed to write temp file: %s", e.message);
        return result;
    }

    string[] args = { "--status-fd", "2", "--import", temp_key };
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);

    secure_delete_file(temp_key);

    if (exit_status != 0) {
        debug("GPGHelper: import_key_data_base64: GPG returned error %d: %s", exit_status, stderr_str ?? "unknown");
        return result;
    }

    result.imported = true;
    foreach (string fingerprint in parse_imported_fingerprints_from_status(stderr_str)) {
        result.fingerprints.add(fingerprint);
    }
    invalidate_secret_keys_cache();
    debug("GPGHelper: import_key_data_base64: Success, imported fingerprints=%d", result.fingerprints.size);
    return result;
}

public static KeyDataInfo inspect_key_data_base64(string base64_key_data) throws GLib.Error {
    initialize();
    var info = new KeyDataInfo();

    string clean = base64_key_data.strip().replace("\n", "").replace("\r", "").replace(" ", "").replace("\t", "");
    if (clean.length == 0) return info;

    uint8[] key_data = Base64.decode(clean);
    if (key_data.length == 0) return info;

    string temp_key = Path.build_filename(Environment.get_tmp_dir(), "dinox-inspect-key-%d.gpg".printf(Random.int_range(0, 1000000)));
    try {
        secure_write_data(temp_key, key_data);
    } catch (Error e) {
        secure_delete_file(temp_key);
        warning("GPGHelper: inspect_key_data_base64: Failed to write temp file: %s", e.message);
        return info;
    }

    string[] args = {
        "--batch",
        "--import-options", "show-only",
        "--with-colons",
        "--with-fingerprint",
        "--import", temp_key
    };
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);

    secure_delete_file(temp_key);

    parse_key_data_info_from_colons(stdout_str, info);
    parse_key_data_info_from_colons(stderr_str, info);
    info.valid_key_data = info.fingerprints.size > 0;

    if (exit_status != 0 && !info.valid_key_data) {
        debug("GPGHelper: inspect_key_data_base64: Not OpenPGP key data or not inspectable");
    }

    return info;
}

private static void parse_key_data_info_from_colons(string output, KeyDataInfo info) {
    bool expect_primary_fingerprint = false;
    bool expect_secret_fingerprint = false;

    foreach (string raw_line in output.split("\n")) {
        string line = raw_line.strip();
        if (line.length == 0) continue;

        string[] parts = line.split(":");
        if (parts.length < 2) continue;

        string record_type = parts[0];
        if (record_type.has_prefix("sec")) {
            info.contains_secret_key = true;
            expect_primary_fingerprint = true;
            expect_secret_fingerprint = true;
        } else if (record_type.has_prefix("pub")) {
            expect_primary_fingerprint = true;
            expect_secret_fingerprint = false;
        } else if (record_type.has_prefix("ssb") || record_type.has_prefix("sub")) {
            expect_primary_fingerprint = false;
            expect_secret_fingerprint = false;
        } else if (record_type == "fpr" && expect_primary_fingerprint) {
            if (parts.length > 9 && parts[9].strip().length > 0) {
                string fingerprint = normalize_fingerprint(parts[9].strip());
                add_key_data_info_fingerprint(info, fingerprint);
                if (expect_secret_fingerprint && !info.secret_fingerprints.contains(fingerprint)) {
                    info.secret_fingerprints.add(fingerprint);
                }
            }
            expect_primary_fingerprint = false;
            expect_secret_fingerprint = false;
        } else if (record_type == "uid") {
            if (parts.length > 9 && parts[9].strip().length > 0) {
                info.user_ids.add(decode_gpg_colon_escapes(parts[9]));
            }
        }
    }
}

private static void add_key_data_info_fingerprint(KeyDataInfo info, string fingerprint) {
    foreach (string existing in info.fingerprints) {
        if (existing == fingerprint) return;
    }
    info.fingerprints.add(fingerprint);
}

internal static Gee.List<string> parse_imported_fingerprints_from_status(string status_output) {
    var fingerprints = new ArrayList<string>();
    foreach (string raw_line in status_output.split("\n")) {
        string line = raw_line.strip();
        if (!line.contains("[GNUPG:] IMPORT_OK")) continue;

        var parts = line.split(" ");
        if (parts.length >= 4 && parts[3].length > 0) {
            fingerprints.add(parts[3].strip());
        }
    }
    return fingerprints;
}

internal enum SecretKeyUserIdMode {
    EMAIL,
    XMPP
}

internal static string build_secret_key_batch(string name, string identity, string passphrase, SecretKeyUserIdMode mode) {
    var batch = new StringBuilder();
    batch.append("Key-Type: RSA\n");
    batch.append("Key-Length: 4096\n");
    batch.append("Subkey-Type: RSA\n");
    batch.append("Subkey-Length: 4096\n");
    if (mode == SecretKeyUserIdMode.XMPP) {
        batch.append(@"Name-Real: $(xmpp_user_id_for_jid(identity))\n");
    } else {
        batch.append(@"Name-Real: $(sanitize_gpg_batch_value(name))\n");
        batch.append(@"Name-Email: $(sanitize_gpg_batch_value(identity))\n");
    }
    batch.append("Expire-Date: 2y\n");
    if (passphrase.length == 0) {
        batch.append("%no-protection\n");
    }
    batch.append("%commit\n");
    return batch.str;
}

public static bool generate_secret_key(string name, string email, string passphrase, out string stdout_str, out string stderr_str) throws GLib.Error {
    return generate_secret_key_with_user_id_mode(name, email, passphrase, SecretKeyUserIdMode.EMAIL, out stdout_str, out stderr_str);
}

public static bool generate_xmpp_secret_key(string name, string bare_jid, string passphrase, out string stdout_str, out string stderr_str) throws GLib.Error {
    return generate_secret_key_with_user_id_mode(name, bare_jid, passphrase, SecretKeyUserIdMode.XMPP, out stdout_str, out stderr_str);
}

public static string? export_and_encrypt_secret_key(string fingerprint, string passphrase) throws GLib.Error {
    initialize();
    string normalized_passphrase = normalize_xep0373_backup_code(passphrase);
    if (normalized_passphrase.length == 0) {
        throw new IOError.FAILED("Invalid backup code format");
    }
    Key? private_key = get_private_key(fingerprint);
    if (private_key == null || !openpgp_key_ids_match(fingerprint, ((!) private_key).fpr)) {
        throw new IOError.NOT_FOUND("Secret key is not available in the DinoX keyring");
    }
    string key_fingerprint = ((!) private_key).fpr;
    string temp_secret_file = Path.build_filename(Environment.get_tmp_dir(), "dinox-secret-backup-" + Uuid.string_random());
    string temp_file = temp_secret_file + ".pgp";
    try {
        var export_args = new ArrayList<string>();
        add_loopback_passphrase_args(export_args);
        export_args.add("--status-fd");
        export_args.add("2");
        export_args.add("--output");
        export_args.add(temp_secret_file);
        export_args.add("--export-secret-keys");
        export_args.add(key_fingerprint);

        string key_passphrase = get_cached_passphrase(key_fingerprint) ?? "";
        string stdout_str;
        string stderr_str;
        int exit_status;
        bool export_ok = run_gpg_sync(string_collection_to_array(export_args), key_passphrase + "\n",
            out stdout_str, out stderr_str, out exit_status, false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
        if (!export_ok && exit_status > 0 && is_bad_passphrase_error(stderr_str)) {
            clear_passphrase(key_fingerprint);
            string? requested_passphrase = request_passphrase(key_fingerprint, "export");
            if (requested_passphrase == null || requested_passphrase.length == 0) {
                throw new IOError.CANCELLED("Secret key export was cancelled");
            }
            key_passphrase = requested_passphrase;
            secure_delete_file(temp_secret_file);
            export_ok = run_gpg_sync(string_collection_to_array(export_args), key_passphrase + "\n",
                out stdout_str, out stderr_str, out exit_status, false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
        }
        if (!export_ok || !FileUtils.test(temp_secret_file, FileTest.EXISTS)) {
            if (is_bad_passphrase_error(stderr_str)) clear_passphrase(key_fingerprint);
            throw new IOError.FAILED("Failed to export secret key: " + stderr_str);
        }
        if (key_passphrase.length > 0) {
            cache_passphrase(key_fingerprint, key_passphrase);
            // XEP-0373 §5.4 requires unprotected transferable secret packets;
            // only the outer backup is encrypted with the backup code. Never
            // remove protection from the original, shared DinoX keyring.
            remove_backup_key_protection(temp_secret_file, key_fingerprint, key_passphrase);
        }

        string[] encrypt_args = { "--symmetric", "--pinentry-mode", "loopback", "--passphrase-fd", "0",
            "--cipher-algo", "AES256", "--output", temp_file, temp_secret_file };
        bool ok = run_gpg_sync(encrypt_args, normalized_passphrase + "\n",
            out stdout_str, out stderr_str, out exit_status, false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
        if (!ok) throw new IOError.FAILED("Failed to encrypt secret key: " + stderr_str);

        uint8[] binary_encrypted_data;
        FileUtils.get_data(temp_file, out binary_encrypted_data);
        return Base64.encode(binary_encrypted_data);
    } finally {
        secure_delete_file(temp_secret_file);
        secure_delete_file(temp_file);
    }
}

private static string resolve_gpgconf_for_backup() {
    string candidate = Path.build_filename(Path.get_dirname(gpg_binary),
#if WINDOWS
        "gpgconf.exe"
#else
        "gpgconf"
#endif
    );
    if (FileUtils.test(candidate, FileTest.EXISTS)) return candidate;
    return Environment.find_program_in_path("gpgconf") ?? "gpgconf";
}

private static void delete_backup_keyring_directory(File directory) throws GLib.Error {
    var children = directory.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
    GLib.Error? enumeration_error = null;
    try {
        FileInfo? child;
        while ((child = children.next_file()) != null) {
            var file = directory.get_child(((!) child).get_name());
            if (((!) child).get_file_type() == FileType.DIRECTORY) {
                delete_backup_keyring_directory(file);
            } else if (((!) child).get_file_type() == FileType.SYMBOLIC_LINK) {
                file.delete();
            } else {
                secure_delete_file(file.get_path());
            }
        }
    } catch (GLib.Error e) {
        enumeration_error = e;
    }
    try {
        children.close();
    } catch (GLib.Error e) {
        if (enumeration_error == null) enumeration_error = e;
    }
    if (enumeration_error != null) throw (!) enumeration_error;
    directory.delete();
}

private static void remove_backup_key_protection(string exported_key_path, string fingerprint, string key_passphrase) throws GLib.Error {
    string temporary_home = DirUtils.make_tmp("dx-pgp-backup-XXXXXX");
#if WINDOWS
    temporary_home = to_windows_path(temporary_home);
#endif
    GLib.Error? backup_error = null;
    GLib.Error? cleanup_error = null;
    bool stopped = false;
    try {
        string stdout_str;
        string stderr_str;
        int exit_status;
        // The later --homedir overrides the app home for this one serialized
        // job. It never changes the globally selected home or any account key.
        string[] import_args = { "--no-options", "--homedir", temporary_home,
            "--pinentry-mode", "loopback", "--passphrase-fd", "0", "--import", exported_key_path };
        if (!run_gpg_sync(import_args, key_passphrase + "\n", out stdout_str, out stderr_str, out exit_status,
                false, GPG_KEY_OPERATION_TIMEOUT_SECONDS)) {
            throw new IOError.FAILED("Failed to prepare secret key backup: " + stderr_str);
        }
        string[] list_args = { "--no-options", "--homedir", temporary_home,
            "--with-colons", "--list-secret-keys", fingerprint };
        if (!run_gpg_sync(list_args, null, out stdout_str, out stderr_str, out exit_status,
                false, GPG_KEY_OPERATION_TIMEOUT_SECONDS)) {
            throw new IOError.FAILED("Failed to inspect secret key backup: " + stderr_str);
        }
        var unlock_input = new StringBuilder(key_passphrase + "\n");
        int secret_packets = 0;
        foreach (string line in stdout_str.split("\n")) {
            if (line.has_prefix("sec:") || line.has_prefix("ssb:")) {
                // GnuPG reuses the old passphrase but asks for a new one for
                // each primary/subkey packet. EOF cancels instead of clearing.
                unlock_input.append_c('\n');
                secret_packets++;
            }
        }
        if (secret_packets == 0) throw new IOError.FAILED("Secret key backup has no private key packets");
        string[] unlock_args = { "--no-options", "--homedir", temporary_home, "--status-fd", "2",
            "--pinentry-mode", "loopback", "--command-fd", "0", "--change-passphrase", fingerprint };
        if (!run_gpg_sync(unlock_args, unlock_input.str, out stdout_str, out stderr_str, out exit_status,
                false, GPG_KEY_OPERATION_TIMEOUT_SECONDS) ||
                stderr_str.contains("[GNUPG:] ERROR") || stderr_str.contains("[GNUPG:] FAILURE")) {
            throw new IOError.FAILED("Failed to prepare unprotected secret key backup: " + stderr_str);
        }
        secure_delete_file(exported_key_path);
        string[] export_args = { "--no-options", "--homedir", temporary_home,
            "--pinentry-mode", "loopback", "--passphrase-fd", "0",
            "--output", exported_key_path, "--export-secret-keys", fingerprint };
        if (!run_gpg_sync(export_args, "\n", out stdout_str, out stderr_str, out exit_status,
                false, GPG_KEY_OPERATION_TIMEOUT_SECONDS)) {
            throw new IOError.FAILED("Failed to export unprotected secret key backup: " + stderr_str);
        }
    } catch (GLib.Error e) {
        backup_error = e;
    } finally {
        int exit_status;
        string stderr_str;
        string[] stop_args = { resolve_gpgconf_for_backup(), "--homedir", temporary_home, "--kill", "all" };
        stopped = Dino.Plugins.OpenPgp.run_bounded_subprocess(stop_args, null, 5,
            out exit_status, out stderr_str, "temporary backup keyring shutdown");
        try {
            delete_backup_keyring_directory(File.new_for_path(temporary_home));
        } catch (GLib.Error e) {
            cleanup_error = e;
        }
    }
    // Retain the actual backup failure; cleanup problems must not replace it.
    if (backup_error != null) throw (!) backup_error;
    if (cleanup_error != null) throw (!) cleanup_error;
    if (!stopped) throw new IOError.FAILED("Failed to stop temporary backup GnuPG components");
}

public static string generate_xep0373_backup_code() throws GLib.Error {
    initialize();

    StringBuilder code = new StringBuilder();
    int produced = 0;
    int alphabet_len = XEP0373_BACKUP_CODE_ALPHABET.length;
    int rejection_limit = 256 - (256 % alphabet_len);

    while (produced < XEP0373_BACKUP_CODE_LENGTH) {
        uint8[] random_bytes = read_xep0373_backup_random_bytes(XEP0373_BACKUP_CODE_RANDOM_BATCH_SIZE);
        foreach (uint8 value in random_bytes) {
            if (value >= rejection_limit) continue;
            if (produced > 0 && produced % XEP0373_BACKUP_CODE_CHUNK_SIZE == 0) {
                code.append_c('-');
            }
            code.append_c(XEP0373_BACKUP_CODE_ALPHABET[(int) (value % alphabet_len)]);
            produced++;
            if (produced >= XEP0373_BACKUP_CODE_LENGTH) break;
        }
    }

    return code.str;
}

private static uint8[] read_xep0373_backup_random_bytes(int byte_count) throws GLib.Error {
    string stdout_str;
    string stderr_str;
    int exit_status;
    string[] random_args = { "--armor", "--gen-random", "2", "%d".printf(byte_count) };
    bool ok = run_gpg_sync(random_args, null, out stdout_str, out stderr_str, out exit_status,
        false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    if (!ok || stdout_str.strip().length == 0) {
        throw new IOError.FAILED("Failed to generate backup code randomness: " + stderr_str);
    }

    string clean = stdout_str.strip().replace("\n", "").replace("\r", "").replace(" ", "").replace("\t", "");
    uint8[] decoded = GLib.Base64.decode(clean);
    if (decoded.length == 0) {
        throw new IOError.FAILED("Failed to decode backup code randomness");
    }
    return decoded;
}

public static string normalize_xep0373_backup_code(string passphrase) {
    StringBuilder compact = new StringBuilder();
    for (int i = 0; i < passphrase.length; i++) {
        char c = passphrase[i];
        if (c == '-' || c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        if (c >= 'a' && c <= 'z') c = (char) (c - 32);
        if (XEP0373_BACKUP_CODE_ALPHABET.index_of_char(c) < 0) return "";
        compact.append_c(c);
    }

    if (compact.len != XEP0373_BACKUP_CODE_LENGTH) return "";

    StringBuilder grouped = new StringBuilder();
    for (int i = 0; i < compact.len; i++) {
        if (i > 0 && i % XEP0373_BACKUP_CODE_CHUNK_SIZE == 0) {
            grouped.append_c('-');
        }
        grouped.append_c(compact.str[i]);
    }

    return grouped.str;
}

public static bool decrypt_and_import_secret_key(string base64_payload, string passphrase) throws GLib.Error {
    DecryptImportResult result = decrypt_and_import_secret_key_with_result(base64_payload, passphrase, null);
    return result.imported || result.already_present;
}

public static DecryptImportResult decrypt_and_import_secret_key_with_result(string base64_payload, string passphrase, Gee.Set<string>? already_available_secret_fingerprints = null) throws GLib.Error {
    initialize();
    var result = new DecryptImportResult();
    string normalized_passphrase = normalize_xep0373_backup_code(passphrase);
    if (normalized_passphrase.length == 0) {
        throw new IOError.FAILED("Invalid backup code format");
    }
    string temp_file = Path.build_filename(Environment.get_tmp_dir(), "dinox-secret-import-" + Uuid.string_random());
    string temp_secret_file = temp_file + ".plain";
    try {
        secure_write_data(temp_file, Base64.decode(base64_payload));
        string stdout_str;
        string stderr_str;
        int exit_status;
        string[] decrypt_args = { "--decrypt", "--status-fd", "2", "--no-symkey-cache",
            "--pinentry-mode", "loopback", "--passphrase-fd", "0", "--output", temp_secret_file, temp_file };
        bool ok = run_gpg_sync(decrypt_args, normalized_passphrase + "\n",
            out stdout_str, out stderr_str, out exit_status, false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
        // DinoX used lower-case codes before the interoperability fix. Keep
        // those backups readable, but always prefer the XEP's canonical code.
        // Never retry a timed-out, cancelled or successfully decrypted job.
        string legacy_passphrase = normalized_passphrase.down();
        if (!ok && exit_status > 0 && legacy_passphrase != normalized_passphrase &&
                stderr_str.contains("[GNUPG:] DECRYPTION_FAILED") &&
                !stderr_str.contains("[GNUPG:] DECRYPTION_OKAY")) {
            secure_delete_file(temp_secret_file);
            ok = run_gpg_sync(decrypt_args, legacy_passphrase + "\n",
                out stdout_str, out stderr_str, out exit_status, false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
        }
        if (!ok || !FileUtils.test(temp_secret_file, FileTest.EXISTS)) {
            throw new IOError.FAILED("Failed to decrypt secret key (incorrect backup code?): " + stderr_str);
        }
        uint8[] decrypted_key_data;
        FileUtils.get_data(temp_secret_file, out decrypted_key_data);
        result.key_info = inspect_key_data(decrypted_key_data);
        if (!result.key_info.valid_key_data || !result.key_info.contains_secret_key) {
            throw new IOError.FAILED("Decrypted backup did not contain secret key data");
        }
        if (already_available_secret_fingerprints != null && result.key_info.secret_fingerprints.size > 0) {
            bool all_present = true;
            foreach (string fingerprint in result.key_info.secret_fingerprints) {
                if (!((!) already_available_secret_fingerprints).contains(normalize_fingerprint(fingerprint))) {
                    all_present = false;
                    break;
                }
            }
            if (all_present) {
                result.already_present = true;
                return result;
            }
        }
        // The backup code belongs to the outer message, not to its secret
        // packets (which conforming backups export without passphrase).
        string[] import_args = { "--import", "--status-fd", "2", "--pinentry-mode", "loopback",
            "--passphrase-fd", "0", temp_secret_file };
        string import_stdout;
        string import_stderr;
        int import_exit_status;
        bool import_ok = run_gpg_sync(import_args, "\n", out import_stdout, out import_stderr, out import_exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
        if (!import_ok) {
            throw new IOError.FAILED("Failed to import decrypted secret key: " + import_stderr);
        }
        invalidate_secret_keys_cache();
        result.imported = true;
        foreach (string fingerprint in parse_imported_fingerprints_from_status(import_stderr)) {
            add_key_data_info_fingerprint(result.key_info, normalize_fingerprint(fingerprint));
        }
        return result;
    } finally {
        secure_delete_file(temp_file);
        secure_delete_file(temp_secret_file);
    }
}

private static KeyDataInfo inspect_key_data(uint8[] key_data) throws GLib.Error {
    initialize();
    var info = new KeyDataInfo();
    if (key_data.length == 0) return info;

    string temp_key = Path.build_filename(Environment.get_tmp_dir(), "dinox-inspect-key-%d.gpg".printf(Random.int_range(0, 1000000)));
    try {
        secure_write_data(temp_key, key_data);
    } catch (Error e) {
        warning("GPGHelper: inspect_key_data: Failed to write temp file: %s", e.message);
        secure_delete_file(temp_key);
        return info;
    }

    string[] args = {
        "--batch",
        "--import-options", "show-only",
        "--with-colons",
        "--with-fingerprint",
        "--import", temp_key
    };
    string inspect_stdout, inspect_stderr;
    int inspect_exit;
    run_gpg_sync(args, null, out inspect_stdout, out inspect_stderr, out inspect_exit,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    secure_delete_file(temp_key);

    parse_key_data_info_from_colons(inspect_stdout, info);
    parse_key_data_info_from_colons(inspect_stderr, info);
    info.valid_key_data = info.fingerprints.size > 0;
    return info;
}

private static bool generate_secret_key_with_user_id_mode(string name, string identity, string passphrase, SecretKeyUserIdMode mode, out string stdout_str, out string stderr_str) throws GLib.Error {
    initialize();

    string batch_path = "";
    stdout_str = "";
    stderr_str = "";

    try {
        batch_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-gpg-batch-%d".printf(Random.int_range(0, 1000000)));
        secure_write_file(batch_path, build_secret_key_batch(name, identity, passphrase, mode));

        var args = new ArrayList<string>();
        args.add("--pinentry-mode");
        args.add("loopback");
        if (passphrase.length > 0) {
            args.add("--passphrase-fd");
            args.add("0");
        }
        args.add("--gen-key");
        args.add(batch_path);

        int exit_status = -1;
        bool ok = run_gpg_sync(
            string_collection_to_array(args),
            passphrase.length > 0 ? passphrase + "\n" : "",
            out stdout_str,
            out stderr_str,
            out exit_status
        );

        if (ok) {
            invalidate_secret_keys_cache();
        }
        return ok;
    } finally {
        if (batch_path != "") {
            secure_delete_file(batch_path);
        }
    }
}

internal static Gee.List<string> parse_user_ids_for_key(string gpg_stdout, string? key_id = null) {
    var user_ids = new ArrayList<string>();
    bool in_primary_key = false;
    bool expect_primary_fingerprint = false;
    bool current_key_matches = key_id == null || ((!) key_id).length == 0;

    foreach (string line in gpg_stdout.split("\n")) {
        var parts = line.split(":");
        if (parts.length < 2) continue;

        string record_type = parts[0];
        if (record_type == "pub" || record_type == "sec") {
            in_primary_key = true;
            expect_primary_fingerprint = true;
            current_key_matches = key_id == null || ((!) key_id).length == 0;
        } else if (record_type == "fpr" && in_primary_key && expect_primary_fingerprint) {
            if (parts.length >= 10 && key_id != null && ((!) key_id).length > 0) {
                current_key_matches = openpgp_key_ids_match((!) key_id, parts[9]);
            }
            expect_primary_fingerprint = false;
        } else if (record_type == "uid" && in_primary_key && current_key_matches) {
            if (parts.length >= 10) {
                user_ids.add(decode_gpg_colon_escapes(parts[9]));
            }
        } else if (record_type == "sub" || record_type == "ssb") {
            in_primary_key = false;
            expect_primary_fingerprint = false;
        }
    }

    return user_ids;
}

public static Gee.List<string> get_key_user_ids(string key_id) throws GLib.Error {
    initialize();

    string[] args = { "--list-keys", "--with-colons", "--with-fingerprint", key_id };
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    if (exit_status != 0) {
        if (exit_status == -2 && stderr_str.contains("GPG operation timed out")) {
            throw new IOError.TIMED_OUT(
                "GPG operation timed out while listing user IDs for key %s",
                key_id
            );
        }
        debug("GPGHelper: Failed to list user IDs for key %s: %s", key_id, stderr_str);
        return new ArrayList<string>();
    }
    return parse_user_ids_for_key(stdout_str, key_id);
}

public static bool key_has_xmpp_uid(string key_id, string bare_jid) throws GLib.Error {
    foreach (string uid in get_key_user_ids(key_id)) {
        if (uid_matches_xmpp_jid(uid, bare_jid)) return true;
    }
    return false;
}

public static bool key_has_email_uid(string key_id) throws GLib.Error {
    foreach (string uid in get_key_user_ids(key_id)) {
        if (email_from_uid(uid) != null) return true;
    }
    return false;
}

private static string normalize_fingerprint(string fingerprint) {
    return fingerprint.up().replace(" ", "");
}

private static string get_revocation_certificate_path(string fingerprint) throws GLib.Error {
    initialize();
    if (gpg_homedir == null || gpg_homedir.length == 0) {
        throw new KeyManagementError.REVOCATION_CERTIFICATE_MISSING("No private OpenPGP home is configured");
    }
    return Path.build_filename(gpg_homedir, "openpgp-revocs.d", normalize_fingerprint(fingerprint) + ".rev");
}

private static string extract_revocation_certificate(string revocation_file_content) throws GLib.Error {
    string normalized = revocation_file_content.replace("\r\n", "\n");
    normalized = normalized.replace("\n:-----BEGIN PGP PUBLIC KEY BLOCK-----", "\n-----BEGIN PGP PUBLIC KEY BLOCK-----");
    if (normalized.has_prefix(":-----BEGIN PGP PUBLIC KEY BLOCK-----")) {
        normalized = normalized.substring(1);
    }

    int begin = normalized.index_of("-----BEGIN PGP PUBLIC KEY BLOCK-----");
    int end = normalized.index_of("-----END PGP PUBLIC KEY BLOCK-----");
    if (begin < 0 || end < begin) {
        throw new KeyManagementError.REVOCATION_CERTIFICATE_INVALID("Stored revocation certificate is not a valid OpenPGP block");
    }

    end += "-----END PGP PUBLIC KEY BLOCK-----".length;
    return normalized.substring(begin, end - begin) + "\n";
}

/**
 * Default keyserver for key lookups
 */
public const string DEFAULT_KEYSERVER = "hkps://keys.openpgp.org";
private static string? keyserver_for_tests = null;

internal static void set_keyserver_for_tests(string? keyserver) {
    keyserver_for_tests = keyserver;
}

private static string get_effective_keyserver(string keyserver) {
    if (keyserver == DEFAULT_KEYSERVER && keyserver_for_tests != null && ((!) keyserver_for_tests).length > 0) {
        return (!) keyserver_for_tests;
    }
    return keyserver;
}

private static bool using_keyserver_for_tests(string keyserver) {
    return keyserver == DEFAULT_KEYSERVER && keyserver_for_tests != null && ((!) keyserver_for_tests).length > 0;
}

/**
 * Revoke a GPG key by generating and importing a revocation certificate.
 * After this the key is marked as revoked in the local keyring.
 * @param fingerprint: Full fingerprint of the key to revoke
 * @param reason: Revocation reason code (0=no reason, 1=compromised, 2=superseded, 3=no longer used)
 * @param comment: Optional human-readable comment for the revocation
 * @return true if revocation was successful
 */
public static bool revoke_key(string fingerprint, int reason = 0, string comment = "") throws GLib.Error {
    initialize();

    debug("GPGHelper: Revoking key %s (reason=%d)", fingerprint, reason);

    // GnuPG 2.x refuses --gen-revoke in --batch mode. For DinoX-managed
    // keys, use the revocation certificate that GnuPG created with the key.
    string revocation_path = get_revocation_certificate_path(fingerprint);
    string revocation_file_content;
    try {
        FileUtils.get_contents(revocation_path, out revocation_file_content);
    } catch (Error e) {
        debug("GPGHelper: No revocation certificate for %s at %s: %s", fingerprint, revocation_path, e.message);
        throw new KeyManagementError.REVOCATION_CERTIFICATE_MISSING(
            "No local revocation certificate found for this key. Imported legacy keys cannot be revoked automatically.");
    }

    string stdout_str = extract_revocation_certificate(revocation_file_content);

    debug("GPGHelper: Got revocation certificate, importing...");

    // Import the revocation certificate to mark the key as revoked
    string[] import_args = { "--batch", "--yes", "--import" };
    string import_stdout, import_stderr;
    int import_exit;
    run_gpg_sync(import_args, stdout_str, out import_stdout, out import_stderr, out import_exit);

    if (import_exit != 0) {
        debug("GPGHelper: Failed to import revocation certificate: %s", import_stderr);
        throw new KeyManagementError.REVOCATION_FAILED(
            "Failed to import revocation certificate: %s", import_stderr);
    }

    debug("GPGHelper: Key %s successfully revoked", fingerprint);
    invalidate_secret_keys_cache();
    return true;
}

public static bool delete_secret_and_public_key(string fingerprint) throws GLib.Error {
    initialize();

    string[] args = { "--delete-secret-and-public-key", fingerprint };
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status);

    if (exit_status != 0) {
        debug("GPGHelper: Delete key failed: %s", stderr_str);
        throw new KeyManagementError.DELETE_FAILED("Delete failed: %s", stderr_str);
    }

    invalidate_secret_keys_cache();
    return true;
}

/**
 * Upload a public key to a keyserver
 * @param key_id: The key ID or fingerprint to upload
 * @param keyserver: The keyserver URL (default: keys.openpgp.org)
 * @return true if successful
 */
public static bool upload_key_to_keyserver(string key_id, string keyserver = DEFAULT_KEYSERVER) throws GLib.Error {
    initialize();
    
    debug("GPGHelper: Uploading key %s to keyserver %s", key_id, keyserver);

    if (!key_has_email_uid(key_id)) {
        debug("GPGHelper: Refusing keyserver upload for %s: key has no email user ID", key_id);
        return false;
    }

    if (keyserver == DEFAULT_KEYSERVER || keyserver.contains("keys.openpgp.org")) {
        if (upload_key_to_openpgp_org_api(key_id)) {
            return true;
        }
        debug("GPGHelper: keys.openpgp.org API upload failed, falling back to GPG keyserver upload");
    }
    
    string[] args = { "--keyserver", keyserver, "--send-keys", key_id };
    
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status);
    
    if (exit_status != 0) {
        debug("GPGHelper: Failed to upload key to keyserver: %s", stderr_str);
        return false;
    }
    
    debug("GPGHelper: Successfully uploaded key %s to %s", key_id, keyserver);
    return true;
}

private static bool upload_key_to_openpgp_org_api(string key_id) {
    string? armored_key = null;
    try {
        armored_key = export_public_key(key_id);
    } catch (Error e) {
        debug("GPGHelper: VKS upload export failed for %s: %s", key_id, e.message);
        return false;
    }
    if (armored_key == null || ((!) armored_key).strip().length == 0) {
        debug("GPGHelper: VKS upload has no exported key for %s", key_id);
        return false;
    }

    string temp_json = Path.build_filename(Environment.get_tmp_dir(), "dinox-keyupload-%d.json".printf(Random.int_range(0, 1000000)));
    string temp_response = Path.build_filename(Environment.get_tmp_dir(), "dinox-keyupload-response-%d.json".printf(Random.int_range(0, 1000000)));
    try {
        secure_write_file(temp_json, "{\"keytext\":\"" + json_escape((!) armored_key) + "\"}");
    } catch (Error e) {
        debug("GPGHelper: VKS upload request file failed: %s", e.message);
        secure_delete_file(temp_json);
        secure_delete_file(temp_response);
        return false;
    }

    string curl_path = "curl";
#if WINDOWS
    curl_path = "curl.exe";
#endif
    string[] upload_args = {
        curl_path,
        "-sS", "-f",
        "-H", "Content-Type: application/json",
        "--data-binary", "@" + temp_json,
        "-o", temp_response,
        "https://keys.openpgp.org/vks/v1/upload"
    };

    bool upload_ok = false;
    string response = "";
    try {
        var subprocess = new_subprocess(upload_args, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        Bytes? stdout_bytes = null;
        Bytes? stderr_bytes = null;
        subprocess.communicate(new Bytes(new uint8[0]), null, out stdout_bytes, out stderr_bytes);
        int curl_exit = subprocess.get_if_exited() ? subprocess.get_exit_status() : -1;
        if (curl_exit != 0) {
            string curl_stderr = stderr_bytes != null ? (string) stderr_bytes.get_data() : "";
            debug("GPGHelper: VKS upload failed (exit=%d): %s", curl_exit, curl_stderr ?? "");
        } else {
            upload_ok = true;
            try {
                FileUtils.get_contents(temp_response, out response);
            } catch (Error e) {
                debug("GPGHelper: VKS upload response read failed: %s", e.message);
            }
        }
    } catch (Error e) {
        debug("GPGHelper: VKS upload curl execution failed: %s", e.message);
    }

    secure_delete_file(temp_json);
    secure_delete_file(temp_response);

    if (!upload_ok) return false;

    request_openpgp_org_email_verification(key_id, response);
    debug("GPGHelper: Successfully uploaded key %s via keys.openpgp.org VKS API", key_id);
    return true;
}

private static void request_openpgp_org_email_verification(string key_id, string upload_response) {
    string? token = json_get_string_field(upload_response, "token");
    if (token == null || ((!) token).length == 0) {
        debug("GPGHelper: VKS upload response did not include a verification token");
        return;
    }

    Gee.List<string> emails = json_collect_email_keys(upload_response);
    if (emails.size == 0) {
        try {
            Key? key = get_public_key(key_id);
            if (key != null && key.email != null && key.email.length > 0) {
                emails.add(key.email);
            } else if (key != null && key.uid != null) {
                string? email = email_from_uid(key.uid);
                if (email != null) emails.add((!) email);
            }
        } catch (Error e) {
            debug("GPGHelper: Could not inspect key UID for VKS verification: %s", e.message);
        }
    }

    foreach (string email in emails) {
        if (!email.contains("@")) continue;
        if (request_openpgp_org_email_verification_for((!) token, email)) {
            debug("GPGHelper: Requested keys.openpgp.org verification mail for %s", email);
        }
    }
}

private static bool request_openpgp_org_email_verification_for(string token, string email) {
    string temp_json = Path.build_filename(Environment.get_tmp_dir(), "dinox-keyverify-%d.json".printf(Random.int_range(0, 1000000)));
    try {
        secure_write_file(temp_json, "{\"token\":\"" + json_escape(token) + "\",\"addresses\":[\"" + json_escape(email) + "\"]}");
    } catch (Error e) {
        debug("GPGHelper: VKS verification request file failed: %s", e.message);
        secure_delete_file(temp_json);
        return false;
    }

    string curl_path = "curl";
#if WINDOWS
    curl_path = "curl.exe";
#endif
    string[] verify_args = {
        curl_path,
        "-sS", "-f",
        "-H", "Content-Type: application/json",
        "--data-binary", "@" + temp_json,
        "https://keys.openpgp.org/vks/v1/request-verify"
    };

    bool ok = false;
    try {
        var subprocess = new_subprocess(verify_args, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
        Bytes? stdout_bytes = null;
        Bytes? stderr_bytes = null;
        subprocess.communicate(new Bytes(new uint8[0]), null, out stdout_bytes, out stderr_bytes);
        int curl_exit = subprocess.get_if_exited() ? subprocess.get_exit_status() : -1;
        ok = curl_exit == 0;
        if (!ok) {
            string curl_stderr = stderr_bytes != null ? (string) stderr_bytes.get_data() : "";
            debug("GPGHelper: VKS verification request failed (exit=%d): %s", curl_exit, curl_stderr ?? "");
        }
    } catch (Error e) {
        debug("GPGHelper: VKS verification curl execution failed: %s", e.message);
    }

    secure_delete_file(temp_json);
    return ok;
}

/**
 * Download a key from a keyserver
 * @param key_id: The key ID or fingerprint to download
 * @param keyserver: The keyserver URL (default: keys.openpgp.org)
 * @return true if key was found and imported
 */
public static bool download_key_from_keyserver(string key_id, string keyserver = DEFAULT_KEYSERVER) throws GLib.Error {
    initialize();
    bool using_test_keyserver = using_keyserver_for_tests(keyserver);
    string effective_keyserver = get_effective_keyserver(keyserver);
    
    debug("GPGHelper: Searching for key %s on keyserver %s", key_id, effective_keyserver);
    
    // Use --recv-keys with the key ID directly (no interactive selection needed)
    // For fingerprints and key IDs, this works without user interaction
    string[] args = { 
        "--keyserver", effective_keyserver,
        "--keyserver-options", "import-minimal,no-self-sigs-only",
        "--recv-keys", key_id 
    };
    
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status,
            false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
    
    // If that failed, try alternative methods
    // keys.openpgp.org may return "no data" or "no user ID" for keys without verified email
    if (exit_status != 0) {
        debug("GPGHelper: HKP failed for %s, stderr: %s", key_id, stderr_str);
        if (using_test_keyserver) {
            return false;
        }
        
        // Always try API and Ubuntu keyserver as fallback when HKP fails
        debug("GPGHelper: Key %s not found via HKP, trying direct API download...", key_id);
        
        // Try to download directly via keys.openpgp.org API (works even without verified UID)
        if (download_key_from_openpgp_org_api(key_id)) {
            return true;
        }
        
        // Try Ubuntu keyserver as fallback (doesn't strip UIDs)
        debug("GPGHelper: Trying alternative keyserver (Ubuntu)...");
        string alt_keyserver = "hkps://keyserver.ubuntu.com";
        string[] alt_args = { "--keyserver", alt_keyserver, "--recv-keys", key_id };
        run_gpg_sync(alt_args, null, out stdout_str, out stderr_str, out exit_status,
                false, GPG_KEY_OPERATION_TIMEOUT_SECONDS);
        
        if (exit_status == 0) {
            debug("GPGHelper: Successfully imported key %s from %s", key_id, alt_keyserver);
            return true;
        }
    }
    
    if (exit_status != 0) {
        debug("GPGHelper: Key %s not found on keyserver or import failed: %s", key_id, stderr_str);
        return false;
    }
    
    debug("GPGHelper: Successfully imported key %s from %s", key_id, effective_keyserver);
    return true;
}

/**
 * Download key directly from keys.openpgp.org API
 * This works even for keys without verified email (no UID)
 */
private static bool download_key_from_openpgp_org_api(string key_id) {
    // Normalize key ID to uppercase and remove 0x prefix
    string normalized_id = key_id.up().replace("0X", "").replace(" ", "");
        
        // keys.openpgp.org API endpoint
        // Use by-fingerprint for full fingerprints (40 chars), by-keyid for short IDs (16 chars)
        string url;
        if (normalized_id.length >= 40) {
            url = "https://keys.openpgp.org/vks/v1/by-fingerprint/" + normalized_id;
        } else {
            url = "https://keys.openpgp.org/vks/v1/by-keyid/" + normalized_id;
        }
        
        debug("GPGHelper: Fetching key from API: %s", url);
        
        // Create temp file for binary key data
        string temp_key = Path.build_filename(Environment.get_tmp_dir(), 
                                              "dinox-keyimport-%d.gpg".printf(Random.int_range(0, 1000000)));
        
        // Use curl to download to file (API returns binary data, not ASCII-armored)
        string curl_path = "curl";
#if WINDOWS
        curl_path = "curl.exe";
#endif
        
        string[] curl_args = { curl_path, "-s", "-f", "-o", temp_key, url };
        
        // Use Subprocess instead of Process.spawn_sync for Windows stability
        try {
            var subprocess = new_subprocess(curl_args, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            Bytes? stdout_bytes = null;
            Bytes? stderr_bytes = null;
            subprocess.communicate(new Bytes(new uint8[0]), null, out stdout_bytes, out stderr_bytes);
            
            int curl_exit = subprocess.get_if_exited() ? subprocess.get_exit_status() : -1;
            
            if (curl_exit != 0) {
                string curl_stderr = stderr_bytes != null ? (string) stderr_bytes.get_data() : "";
                debug("GPGHelper: API download failed (exit=%d): %s", curl_exit, curl_stderr ?? "");
                secure_delete_file(temp_key);
                return false;
            }
        } catch (Error e) {
            debug("GPGHelper: curl execution failed: %s", e.message);
            secure_delete_file(temp_key);
            return false;
        }
        
        // Check file size
        int64 file_size = 0;
        try {
            var file = File.new_for_path(temp_key);
            var info = file.query_info("standard::size", FileQueryInfoFlags.NONE);
            file_size = info.get_size();
        } catch (Error e) {
            debug("GPGHelper: Could not get file size: %s", e.message);
        }
        
        if (file_size < 100) {
            debug("GPGHelper: Downloaded key file too small: %s bytes", file_size.to_string());
            secure_delete_file(temp_key);
            return false;
        }
        
        debug("GPGHelper: Got key from API, size: %s bytes", file_size.to_string());
        
        // Import the key from file
        // Use import-minimal to accept keys without user ID (keys.openpgp.org strips unverified UIDs)
        string[] import_args = { "--import-options", "import-minimal", "--import", temp_key };
        string import_stdout, import_stderr;
        int import_exit;
        run_gpg_sync(import_args, null, out import_stdout, out import_stderr, out import_exit);
        
        secure_delete_file(temp_key);
        
        // Check if import succeeded - GPG may still skip keys without UID
        if (import_stderr.contains("ohne User-ID") || import_stderr.contains("no user ID")) {
            debug("GPGHelper: Key has no User-ID, trying with keep-ownertrust...");
            // Key has no UID - this is a limitation of keys.openpgp.org
            // The key cannot be used for encryption without a UID
            // Return false so we try other sources
            return false;
        }
        
        if (import_exit == 0 || import_stderr.contains("imported") || import_stderr.contains("importiert")) {
            debug("GPGHelper: Successfully imported key %s from API", key_id);
            return true;
        } else {
            debug("GPGHelper: Import from API failed: %s", import_stderr);
            return false;
        }
}

/**
 * Search for a key on keyserver by email or key ID
 * Returns list of key IDs found
 */
public static Gee.List<string> search_keyserver(string query, string keyserver = DEFAULT_KEYSERVER) throws GLib.Error {
    initialize();
    
    var results = new ArrayList<string>();
    
    debug("GPGHelper: Searching keyserver %s for: %s", keyserver, query);
    
    string[] args = { "--keyserver", keyserver, "--search-keys", "--batch", "--with-colons", query };
    
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, null, out stdout_str, out stderr_str, out exit_status);
    
    // Parse output for key IDs
    foreach (string line in stdout_str.split("\n")) {
        if (line.has_prefix("pub:")) {
            var parts = line.split(":");
            if (parts.length > 1 && parts[1].length > 0) {
                results.add(parts[1]);
            }
        }
    }
    
    debug("GPGHelper: Found %d key(s) on keyserver", results.size);
    return results;
}

/**
 * Check if a private key requires a passphrase
 * @param key_fpr: The key fingerprint to check
 * @return true if the key requires a passphrase, false if it has no passphrase
 */
public static bool key_requires_passphrase(string key_fpr) {
    initialize();
    
    // Try to sign with an empty passphrase in loopback mode
    // If it succeeds, the key has no passphrase protection
    string temp_in = Path.build_filename(Environment.get_tmp_dir(), "dinox-pwcheck-%d".printf(Random.int_range(0, 1000000)));
    string temp_out = temp_in + ".asc";
    
    try {
        secure_write_file(temp_in, "test");
    } catch (Error e) {
        return true;  // Assume protected on error
    }
    
    string[] args = {
        "--batch", "--yes", "--pinentry-mode", "loopback",
        "--passphrase-fd", "0",
        "-u", key_fpr,
        "--sign", "--armor", "-o", temp_out, temp_in
    };
    
    string stdout_str, stderr_str;
    int exit_status;
    run_gpg_sync(args, "\n", out stdout_str, out stderr_str, out exit_status, false);
    
    // Cleanup temp files
    secure_delete_file(temp_in);
    secure_delete_file(temp_out);
    
    if (exit_status == 0) {
        // Empty passphrase worked = key has no passphrase
        debug("GPGHelper: Key %s has NO passphrase protection", key_fpr);
        return false;
    } else {
        // Empty passphrase failed = key is protected
        debug("GPGHelper: Key %s requires passphrase", key_fpr);
        return true;
    }
}

}
