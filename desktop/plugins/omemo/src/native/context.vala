namespace Omemo {

// Keep only fixed reason labels, never native log text (which can contain JIDs).
// Multiple archived sessions may be tried for one packet, so retain all reasons.
internal class SignalDecryptTrace {
    internal string stage = "signal-parse";
    internal int signal_version = -1;
    internal int64 counter = -1;
    private Gee.ArrayList<string> reasons = new Gee.ArrayList<string>();

    internal void observe(string message) {
        string? reason = null;
        if (message == "Bad MAC" || message == "Message mac not verified") reason = "mac-mismatch";
        else if (message == "No valid sessions") reason = "no-valid-session";
        else if (message == "Uninitialized session!") reason = "uninitialized-session";
        else if (message == "Over 2000 messages into the future!") reason = "counter-gap";
        else if (message == "Incomplete message") reason = "incomplete-message";
        else if (message == "Message body does not exist") reason = "missing-message-body";
        else if (message.has_prefix("Unknown version: ")) reason = "invalid-message-version";
        else if (message.has_prefix("Unsupported legacy version: ")) reason = "legacy-message-version";
        else if (message.has_prefix("Message version ") && message.contains(", but session version ")) reason = "session-version-mismatch";
        else if (message.has_prefix("Received message with old counter: ")) reason = "old-counter";
        else if (message.has_prefix("No session for: ")) reason = "no-session";
        else if (message == "Error attempting to verify message mac") reason = "mac-check-error";
        if (reason != null && !reasons.contains((!) reason)) reasons.add((!) reason);
    }

    internal string describe() {
        string[] reason_labels = new string[reasons.size];
        int i = 0;
        foreach (string reason in reasons) {
            reason_labels[i++] = reason;
        }
        return "stage=%s;reasons=%s;signal_version=%d;counter=%s".printf(
                stage, reasons.size == 0 ? "unclassified" : string.joinv(",", reason_labels),
                signal_version, counter.to_string());
    }
}

// Report only a failed native store lookup, never infer it from key presence:
// a matching current/archived session can decrypt without loading either key.
internal class PreKeyDecryptTrace {
    internal string stage = "prekey-session-create";
    internal bool has_pre_key_id = false;
    internal int64 pre_key_id = -1;
    internal int64 signed_pre_key_id = -1;
    private string reason = "unclassified";
    private int64 missing_key_id = -1;

    internal void start(PreKeyOmemoMessage message) {
        stage = "prekey-session-create";
        has_pre_key_id = message.has_pre_key_id();
        pre_key_id = has_pre_key_id ? (int64) message.pre_key_id : -1;
        signed_pre_key_id = message.signed_pre_key_id;
        reason = "unclassified";
        missing_key_id = -1;
    }

    internal void observe_missing_key(uint32 key_id, bool signed_pre_key) {
        reason = signed_pre_key ? "own-signed-prekey-missing"
                : "own-one-time-prekey-missing";
        missing_key_id = key_id;
    }

    internal string describe() {
        return "stage=%s;reason=%s;has_prekey_id=%s;prekey_id=%s;signed_prekey_id=%s;missing_key_id=%s".printf(
                stage, reason, has_pre_key_id.to_string(),
                pre_key_id.to_string(), signed_pre_key_id.to_string(),
                missing_key_id.to_string());
    }
}

public class Context {
    internal NativeContext native_context;
    private RecMutex mutex = RecMutex();
    private SignalDecryptTrace? active_signal_trace;
    private PreKeyDecryptTrace? active_prekey_trace;
    private Store? active_prekey_store;
    private bool verbose_logging;

    static void locking_function_lock(void* user_data) {
        Context ctx = (Context) user_data;
        ctx.mutex.lock();
    }

    static void locking_function_unlock(void* user_data) {
        Context ctx = (Context) user_data;
        ctx.mutex.unlock();
    }

    static void native_log(LogLevel level, string message, size_t len, void* user_data) {
        Context ctx = (Context) user_data;
        ctx.mutex.lock();
        if (ctx.active_signal_trace != null) ((!) ctx.active_signal_trace).observe(message);
        if (ctx.verbose_logging) printerr(@"$level: $message\n");
        ctx.mutex.unlock();
    }

    public Context(bool log = false) throws Error {
        throw_by_code(NativeContext.create(out native_context, this), "Error initializing native context");
        throw_by_code(native_context.set_locking_functions(locking_function_lock, locking_function_unlock), "Error initializing native locking functions");
        verbose_logging = log;
        throw_by_code(native_context.set_log_function(native_log), "Error initializing native diagnostics");
        setup_crypto_provider(native_context);
    }

    // Serialize capture with native operations using the same recursive mutex.
    // The normal decrypt still owns validation, ratchet updates and persistence.
    // A caller-owned trace remains readable after Error; Vala out parameters do
    // not reliably reach the caller when a throwing method fails.
    internal uint8[] decrypt_signal_message(Store store, Address address,
            uint8[] serialized, SignalDecryptTrace trace) throws Error {
        if (store.context != this) {
            throw new GLib.Error(Quark.from_string("omemo-context"), ErrorCode.INVAL,
                    "Signal decryption context does not match its store");
        }
        mutex.lock();
        SignalDecryptTrace? previous_trace = active_signal_trace;
        active_signal_trace = trace;
        try {
            OmemoMessage message = deserialize_signal_message(serialized);
            trace.signal_version = message.message_version;
            trace.counter = message.counter;
            trace.stage = "session-create";
            SessionCipher cipher = store.create_session_cipher(address);
            trace.stage = "signal-decrypt";
            return cipher.decrypt_message(message);
        } finally {
            active_signal_trace = previous_trace;
            mutex.unlock();
        }
    }

    internal uint8[] decrypt_pre_key_message(Store store, Address address,
            PreKeyOmemoMessage message, PreKeyDecryptTrace trace) throws Error {
        if (store.context != this) {
            throw new GLib.Error(Quark.from_string("omemo-context"), ErrorCode.INVAL,
                    "PREKEY decryption context does not match its store");
        }
        mutex.lock();
        PreKeyDecryptTrace? previous_trace = active_prekey_trace;
        Store? previous_store = active_prekey_store;
        active_prekey_trace = trace;
        active_prekey_store = store;
        try {
            trace.start(message);
            SessionCipher cipher = store.create_session_cipher(address);
            trace.stage = "prekey-decrypt";
            return cipher.decrypt_pre_key_message(message);
        } finally {
            active_prekey_trace = previous_trace;
            active_prekey_store = previous_store;
            mutex.unlock();
        }
    }

    // These callbacks run under the native recursive mutex. Bind capture to
    // this operation's store so another account cannot supply its reason.
    internal void observe_missing_pre_key(Store store, uint32 key_id,
            bool signed_pre_key) {
        mutex.lock();
        if (active_prekey_trace != null && active_prekey_store == store) {
            ((!) active_prekey_trace).observe_missing_key(key_id, signed_pre_key);
        }
        mutex.unlock();
    }

    public Store create_store(bool persistence_ready = true) {
        return new Store(this, persistence_ready);
    }

    public void randomize(uint8[] data) throws Error {
        throw_by_code(native_random(data));
    }

    public SignedPreKeyRecord generate_signed_pre_key(IdentityKeyPair identity_key_pair, int32 id, uint64 timestamp = 0) throws Error {
        if (timestamp == 0) timestamp = new DateTime.now_utc().to_unix();
        SignedPreKeyRecord res;
        throw_by_code(Protocol.KeyHelper.generate_signed_pre_key(out res, identity_key_pair, id, timestamp, native_context));
        return res;
    }

    public Gee.Set<PreKeyRecord> generate_pre_keys(uint start, uint count) throws Error {
        Gee.Set<PreKeyRecord> res = new Gee.HashSet<PreKeyRecord>();
        for(uint i = start; i < start+count; i++) {
            ECKeyPair pair = generate_key_pair();
            PreKeyRecord record;
            throw_by_code(PreKeyRecord.create(out record, i, pair));
            res.add(record);
        }
        return res;
    }

    public ECPublicKey decode_public_key(uint8[] bytes) throws Error {
        ECPublicKey public_key;
        throw_by_code(curve_decode_point(out public_key, bytes, native_context), "Error decoding public key");
        return public_key;
    }

    /**
     * Decode a bare 32-byte X25519 (Montgomery) public key.
     * Used for OMEMO 2 bundle keys which are X25519, not Ed25519.
     * curve_decode_point() auto-detects 32-byte keys as Ed25519 which is wrong for OMEMO 2.
     */
    public ECPublicKey decode_public_key_mont(uint8[] bytes) throws Error {
        ECPublicKey public_key;
        throw_by_code(curve_decode_point_mont(out public_key, bytes, native_context), "Error decoding public key (mont)");
        return public_key;
    }

    public ECPrivateKey decode_private_key(uint8[] bytes) throws Error {
        ECPrivateKey private_key;
        throw_by_code(curve_decode_private_point(out private_key, bytes, native_context), "Error decoding private key");
        return private_key;
    }

    public ECKeyPair generate_key_pair() throws Error {
        ECKeyPair key_pair;
        throw_by_code(curve_generate_key_pair(native_context, out key_pair), "Error generating key pair");
        return key_pair;
    }

    public uint8[] calculate_signature(ECPrivateKey signing_key, uint8[] message) throws Error {
        Buffer signature;
        throw_by_code(Curve.calculate_signature(native_context, out signature, signing_key, message), "Error calculating signature");
        return signature.data;
    }

    public OmemoMessage deserialize_signal_message(uint8[] data) throws Error {
        OmemoMessage res;
        throw_by_code(message_deserialize(out res, data, native_context));
        return res;
    }

    public OmemoMessage deserialize_omemo_message(uint8[] data) throws Error {
        OmemoMessage res;
        throw_by_code(message_deserialize_omemo(out res, data, native_context));
        return res;
    }

    public OmemoMessage copy_message(CiphertextMessage original) throws Error {
        OmemoMessage res;
        throw_by_code(message_copy(out res, (OmemoMessage) original, native_context));
        return res;
    }

    public PreKeyOmemoMessage deserialize_signal_pre_key_message(uint8[] data) throws Error {
        PreKeyOmemoMessage res;
        throw_by_code(pre_key_message_deserialize(out res, data, native_context));
        return res;
    }

    public PreKeyOmemoMessage deserialize_omemo_pre_key_message(uint8[] data, uint32 remote_registration_id) throws Error {
        PreKeyOmemoMessage res;
        throw_by_code(pre_key_message_deserialize_omemo(out res, data, remote_registration_id, native_context));
        return res;
    }

    public PreKeyOmemoMessage copy_pre_key_message(CiphertextMessage original) throws Error {
        PreKeyOmemoMessage res;
        throw_by_code(pre_key_message_copy(out res, (PreKeyOmemoMessage) original, native_context));
        return res;
    }
}

}
