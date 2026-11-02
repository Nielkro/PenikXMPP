using Dino.Plugins.Omemo;
using Omemo;
using Qlite;

[CCode (cname = "g_type_class_ref", cheader_filename = "glib-object.h")]
extern unowned void* _force_class_init(GLib.Type type);

namespace Omemo.PersistenceTest {

[CCode (cname = "g_subprocess_newv", cheader_filename = "gio/gio.h")]
private extern static Subprocess subprocess_newv_const(
    [CCode (array_length = false, array_null_terminated = true, type = "const gchar* const*")] string[] argv,
    SubprocessFlags flags) throws Error;

private errordomain PersistenceError {
    FAILED
}

private const string CRASH_CHILD_MODE = "--hard-exit-receiver-child";
private const string PREKEY_CRASH_CHILD_MODE =
    "--hard-exit-prekey-receiver-child";
private const string CRASH_CHILD_PLAINTEXT =
    "ratchet persisted immediately before hard process exit";
private const int64 CRASH_CHILD_SAFETY_TIMEOUT_USEC =
    20 * TimeSpan.SECOND;
private static string? test_program_path = null;

private static void require(bool condition, string message) throws PersistenceError {
    if (!condition) {
        throw new PersistenceError.FAILED(message);
    }
}

private static uint8[] copy_bytes(uint8[] source) {
    uint8[] copy = new uint8[source.length];
    Memory.copy(copy, source, source.length);
    return copy;
}

private static void require_bytes_equal(uint8[] expected, uint8[] actual,
        string message) throws PersistenceError {
    require(expected.length == actual.length, @"$message (length $(expected.length) != $(actual.length))");
    require(Base64.encode(expected) == Base64.encode(actual), message);
}

private class PersistentPeer : Object {
    internal string db_path { get; private set; }
    internal string jid { get; private set; }
    internal int account_id { get; private set; }
    internal int device_id { get; private set; }
    internal int identity_id { get; private set; default = -1; }

    internal Dino.Plugins.Omemo.Database? db { get; private set; }
    internal Context? context { get; private set; }
    internal Store? store { get; private set; }

    internal PersistentPeer(string db_path, string jid, int account_id,
            int device_id, Context context) throws Error {
        this.db_path = db_path;
        this.jid = jid;
        this.account_id = account_id;
        this.device_id = device_id;
        this.context = context;
        create_new();
    }

    internal PersistentPeer.open_existing(string db_path, string jid,
            int account_id, Context context) throws Error {
        this.db_path = db_path;
        this.jid = jid;
        this.account_id = account_id;
        this.context = context;
        reopen(context);
    }

    internal Address address() {
        return new Address(jid, device_id);
    }

    private void create_new() throws Error {
        db = new Dino.Plugins.Omemo.Database(db_path);
        store = ((!) context).create_store();

        ((!) store).identity_key_store.local_registration_id = (uint32) device_id;
        ECKeyPair identity = ((!) context).generate_key_pair();
        ((!) store).identity_key_store.identity_key_private =
            new Bytes(identity.private.serialize());
        ((!) store).identity_key_store.identity_key_public =
            new Bytes(identity.public.serialize());

        ((!) db).identity.upsert()
            .value(((!) db).identity.account_id, account_id, true)
            .value(((!) db).identity.device_id, device_id)
            .value(((!) db).identity.identity_key_private_base64,
                Base64.encode(((!) store).identity_key_store.identity_key_private.get_data()))
            .value(((!) db).identity.identity_key_public_base64,
                Base64.encode(((!) store).identity_key_store.identity_key_public.get_data()))
            .perform_checked();

        Row? row = ((!) db).identity.select()
            .with(((!) db).identity.account_id, "=", account_id)
            .single().iterator().get_next_checked();
        require(row != null, "failed to persist OMEMO identity");
        identity_id = ((!) row)[((!) db).identity.id];
        attach_backed_stores();
    }

    internal void reopen(Context context) throws Error {
        close();

        db = new Dino.Plugins.Omemo.Database(db_path);
        Row? row = ((!) db).identity.select()
            .with(((!) db).identity.account_id, "=", account_id)
            .single().iterator().get_next_checked();
        require(row != null, "persisted OMEMO identity is missing after reopen");

        identity_id = ((!) row)[((!) db).identity.id];
        device_id = ((!) row)[((!) db).identity.device_id];
        this.context = context;
        store = ((!) context).create_store();
        ((!) store).identity_key_store.local_registration_id = (uint32) device_id;
        ((!) store).identity_key_store.identity_key_private = new Bytes(
            Base64.decode(((!) row)[((!) db).identity.identity_key_private_base64]));
        ((!) store).identity_key_store.identity_key_public = new Bytes(
            Base64.decode(((!) row)[((!) db).identity.identity_key_public_base64]));
        attach_backed_stores();
    }

    private void attach_backed_stores() {
        ((!) store).signed_pre_key_store = new BackedSignedPreKeyStore(
            (!) db, identity_id);
        ((!) store).pre_key_store = new BackedPreKeyStore((!) db, identity_id);
        ((!) store).session_store = new BackedSessionStore((!) db, identity_id);
    }

    internal void close() {
        store = null;
        context = null;
        if (db != null) {
            ((!) db).close();
            db = null;
        }
    }

    internal int synchronous_mode() throws Error {
        Row? row = ((!) db).query_sql("PRAGMA synchronous").get_next_checked();
        require(row != null, "PRAGMA synchronous returned no row");
        return (int) ((!) row).get_integer("synchronous");
    }

    internal uint8[] database_session(Address remote) throws Error {
        Row? row = ((!) db).session.select()
            .with(((!) db).session.identity_id, "=", identity_id)
            .with(((!) db).session.address_name, "=", remote.name)
            .with(((!) db).session.device_id, "=", remote.device_id)
            .single().iterator().get_next_checked();
        require(row != null, @"persisted session for $(remote.name)/$(remote.device_id) is missing");
        return Base64.decode(((!) row)[((!) db).session.record_base64]);
    }

    internal bool database_contains_session(Address remote) throws Error {
        return ((!) db).session.select()
            .with(((!) db).session.identity_id, "=", identity_id)
            .with(((!) db).session.address_name, "=", remote.name)
            .with(((!) db).session.device_id, "=", remote.device_id)
            .single().iterator().get_next_checked() != null;
    }

    internal uint8[] memory_session(Address remote) throws Error {
        uint8[]? record = ((!) store).session_store.load_session(remote);
        require(record != null, @"in-memory session for $(remote.name)/$(remote.device_id) is missing");
        return copy_bytes((!) record);
    }

    internal uint8[] database_pre_key(uint32 pre_key_id) throws Error {
        Row? row = ((!) db).pre_key.select()
            .with(((!) db).pre_key.identity_id, "=", identity_id)
            .with(((!) db).pre_key.pre_key_id, "=", (int) pre_key_id)
            .single().iterator().get_next_checked();
        require(row != null, @"persisted pre-key $pre_key_id is missing");
        return Base64.decode(((!) row)[((!) db).pre_key.record_base64]);
    }

    internal bool database_contains_pre_key(uint32 pre_key_id) throws Error {
        return ((!) db).pre_key.select()
            .with(((!) db).pre_key.identity_id, "=", identity_id)
            .with(((!) db).pre_key.pre_key_id, "=", (int) pre_key_id)
            .single().iterator().get_next_checked() != null;
    }

    internal uint8[] memory_pre_key(uint32 pre_key_id) throws Error {
        uint8[]? record = ((!) store).pre_key_store.load_pre_key(pre_key_id);
        require(record != null, @"in-memory pre-key $pre_key_id is missing");
        return copy_bytes((!) record);
    }

    internal uint8[] database_signed_pre_key(uint32 pre_key_id) throws Error {
        Row? row = ((!) db).signed_pre_key.select()
            .with(((!) db).signed_pre_key.identity_id, "=", identity_id)
            .with(((!) db).signed_pre_key.signed_pre_key_id, "=", (int) pre_key_id)
            .single().iterator().get_next_checked();
        require(row != null, @"persisted signed pre-key $pre_key_id is missing");
        return Base64.decode(((!) row)[((!) db).signed_pre_key.record_base64]);
    }

    internal uint8[] memory_signed_pre_key(uint32 pre_key_id) throws Error {
        uint8[]? record = ((!) store).signed_pre_key_store.load_signed_pre_key(pre_key_id);
        require(record != null, @"in-memory signed pre-key $pre_key_id is missing");
        return copy_bytes((!) record);
    }

    internal void require_session_consistent(Address remote) throws Error {
        require_bytes_equal(database_session(remote), memory_session(remote),
            @"database and in-memory session diverged for $(remote.name)/$(remote.device_id)");
        SessionRecord record = ((!) store).load_session(remote);
        require(record.state.session_version == 3,
            @"persisted legacy session has version $(record.state.session_version), expected 3");
    }
}

private class PersistenceFixture : Object {
    internal string temp_dir { get; private set; }
    internal PersistentPeer alice { get; private set; }
    internal PersistentPeer bob { get; private set; }
    private Context? context;

    internal PersistenceFixture() throws Error {
        temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-legacy-session-persistence-" + Uuid.string_random());
        require(DirUtils.create_with_parents(temp_dir, 0700) == 0,
            "failed to create persistence test directory");
        context = new Context();
        alice = new PersistentPeer(Path.build_filename(temp_dir, "alice-omemo.db"),
            "alice@example.test", 101, 1101, (!) context);
        bob = new PersistentPeer(Path.build_filename(temp_dir, "bob-omemo.db"),
            "bob@example.test", 202, 2202, (!) context);
    }

    internal void reopen_all() throws Error {
        alice.close();
        bob.close();
        context = null;

        context = new Context();
        alice.reopen((!) context);
        bob.reopen((!) context);
    }

    internal void close_alice() throws Error {
        alice.close();
        require(alice.db == null && alice.store == null &&
                alice.context == null,
            "Alice's OMEMO store did not close completely");
    }

    internal void reopen_alice() throws Error {
        // Bob represents the still-running remote client. Alice must recreate
        // her native context and reload the ratchet only from SQLCipher.
        context = new Context();
        alice.reopen((!) context);
    }

    internal void close_bob() throws Error {
        bob.close();
        require(bob.db == null && bob.store == null && bob.context == null,
            "Bob's OMEMO store did not close completely");
    }

    internal void reopen_bob() throws Error {
        // Alice represents the still-running remote client. Bob must recreate
        // his native context and reload all key/session stores from SQLCipher.
        context = new Context();
        bob.reopen((!) context);
    }

    internal void cleanup() {
        alice.close();
        bob.close();
        context = null;
        cleanup_database(alice.db_path);
        cleanup_database(bob.db_path);
        DirUtils.remove(temp_dir);
    }

    private static void cleanup_database(string path) {
        FileUtils.remove(path);
        FileUtils.remove(path + "-shm");
        FileUtils.remove(path + "-wal");
    }
}

private class LegacyDecryptRuntime : Object {
    internal Dino.Plugins.Omemo.OmemoDecryptor? decryptor { get; private set; }

    private string db_path;
    private Dino.Database? db;
    private Dino.StreamInteractor? stream_interactor;
    private Dino.Plugins.Omemo.TrustManager? trust_manager;
    private Dino.Entities.Account? account;

    internal LegacyDecryptRuntime(string temp_dir, PersistentPeer receiver)
            throws Error {
        require(Dino.Plugins.Omemo.Plugin.ensure_context(),
            "legacy decrypt runtime could not initialize libomemo-c");
        db_path = Path.build_filename(temp_dir, "dino-decrypt-runtime.db");
        db = new Dino.Database(db_path, "legacy-prekey-persistence-test");
        stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
        Dino.MessageProcessor.start((!) stream_interactor, (!) db);
        account = new Dino.Entities.Account(
            new Xmpp.Jid(receiver.jid), "secret");
        ((!) account).id = receiver.account_id;
        trust_manager = new Dino.Plugins.Omemo.TrustManager(
            (!) stream_interactor, (!) receiver.db);
        decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(
            (!) account, (!) stream_interactor, (!) trust_manager,
            (!) receiver.db, (!) receiver.store);
    }

    internal void close() {
        decryptor = null;
        trust_manager = null;
        account = null;
        stream_interactor = null;
        if (db != null) {
            ((!) db).close();
            db = null;
        }
        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-shm");
        FileUtils.remove(db_path + "-wal");
    }
}

private static Xmpp.Xep.Omemo.ParsedData legacy_prekey_data(
        PersistentPeer sender, uint8[] serialized) {
    Xmpp.Xep.Omemo.ParsedData data = new Xmpp.Xep.Omemo.ParsedData();
    data.sid = sender.device_id;
    data.is_prekey = true;
    data.encrypted_key = copy_bytes(serialized);
    data.ciphertext = new uint8[0];
    data.iv = new uint8[0];
    return data;
}

private static string identity_meta_snapshot(
        Dino.Plugins.Omemo.Database db, int identity_id,
        string address_name, int device_id) {
    Row? row = db.identity_meta.get_device(
        identity_id, address_name, device_id);
    return row == null ? "ABSENT" : ((!) row).to_string();
}

private static void require_optional_bytes_equal(uint8[]? expected,
        uint8[]? actual, string message) throws PersistenceError {
    require((expected == null) == (actual == null),
        message + " (presence differs)");
    if (expected != null) {
        require_bytes_equal((!) expected, (!) actual, message);
    }
}

private static void remove_peer_database(PersistentPeer peer) {
    peer.close();
    FileUtils.remove(peer.db_path);
    FileUtils.remove(peer.db_path + "-shm");
    FileUtils.remove(peer.db_path + "-wal");
}

private static void persist_known_sender_identity(PersistentPeer receiver,
        PersistentPeer sender) throws Error {
    ((!) receiver.db).identity_meta.upsert()
        .value(((!) receiver.db).identity_meta.identity_id,
            receiver.identity_id, true)
        .value(((!) receiver.db).identity_meta.address_name,
            sender.jid, true)
        .value(((!) receiver.db).identity_meta.device_id,
            sender.device_id, true)
        .value(((!) receiver.db).identity_meta.identity_key_public_base64,
            Base64.encode(((!) sender.store).identity_key_store
                .identity_key_public.get_data()))
        .value(((!) receiver.db).identity_meta.trust_level,
            Dino.Plugins.Omemo.TrustLevel.TRUSTED)
        .value(((!) receiver.db).identity_meta.now_active, true)
        .value(((!) receiver.db).identity_meta.supports_omemo1, true)
        .value(((!) receiver.db).identity_meta.supports_omemo2, false)
        .perform_checked();
}

private static void prepare_unconfirmed_legacy_session(PersistentPeer sender,
        PersistentPeer receiver) throws Error {
    Address receiver_address = receiver.address();
    ECKeyPair receiver_pre_key = ((!) receiver.context).generate_key_pair();
    ECKeyPair receiver_signed_pre_key = ((!) receiver.context).generate_key_pair();
    IdentityKeyPair receiver_identity = ((!) receiver.store).identity_key_pair;
    uint8[] signature = ((!) receiver.context).calculate_signature(
        receiver_identity.private, receiver_signed_pre_key.public.serialize());
    PreKeyBundle bundle = create_pre_key_bundle(
        ((!) receiver.store).local_registration_id,
        receiver.device_id,
        31337,
        receiver_pre_key.public,
        22,
        receiver_signed_pre_key.public,
        signature,
        receiver_identity.public);

    ((!) sender.store).create_session_builder(receiver_address)
        .process_pre_key_bundle(bundle);

    PreKeyRecord receiver_pre_key_record;
    throw_by_code(PreKeyRecord.create(out receiver_pre_key_record, 31337,
        receiver_pre_key));
    ((!) receiver.store).store_pre_key(receiver_pre_key_record);

    SignedPreKeyRecord receiver_signed_pre_key_record;
    throw_by_code(SignedPreKeyRecord.create(out receiver_signed_pre_key_record,
        22, new DateTime.now_utc().to_unix(), receiver_signed_pre_key,
        signature, null));
    ((!) receiver.store).store_signed_pre_key(receiver_signed_pre_key_record);

    sender.require_session_consistent(receiver_address);
    require_bytes_equal(receiver.database_pre_key(31337),
        receiver.memory_pre_key(31337),
        "receiver pre-key was not persisted before going offline");
    require_bytes_equal(receiver.database_signed_pre_key(22),
        receiver.memory_signed_pre_key(22),
        "receiver signed pre-key was not persisted before going offline");
}

private static void establish_confirmed_legacy_session(PersistenceFixture fixture)
        throws Error {
    PersistentPeer alice = fixture.alice;
    PersistentPeer bob = fixture.bob;
    Address bob_address = bob.address();
    Address alice_address = alice.address();

    prepare_unconfirmed_legacy_session(alice, bob);

    SessionCipher alice_cipher = ((!) alice.store).create_session_cipher(bob_address);
    CiphertextMessage first = alice_cipher.encrypt("initial-prekey".data);
    require(first.type == CiphertextType.PREKEY,
        "initial legacy message must be a PREKEY message");
    PreKeyOmemoMessage incoming = ((!) bob.context)
        .deserialize_signal_pre_key_message(first.serialized);
    SessionCipher bob_cipher = ((!) bob.store).create_session_cipher(alice_address);
    uint8[] initial_plaintext = bob_cipher.decrypt_pre_key_message(incoming);
    require_bytes_equal("initial-prekey".data, initial_plaintext,
        "Bob could not decrypt initial PREKEY message");

    CiphertextMessage confirmation = bob_cipher.encrypt("confirmation".data);
    require(confirmation.type == CiphertextType.SIGNAL,
        "confirmation must use the established SIGNAL session");
    OmemoMessage confirmation_copy = ((!) alice.context)
        .deserialize_signal_message(confirmation.serialized);
    uint8[] confirmation_plaintext = alice_cipher.decrypt_message(confirmation_copy);
    require_bytes_equal("confirmation".data, confirmation_plaintext,
        "Alice could not decrypt the session confirmation");

    alice.require_session_consistent(bob_address);
    bob.require_session_consistent(alice_address);
}

private static void reopen_and_require_sessions_unchanged(
        PersistenceFixture fixture) throws Error {
    Address bob_address = fixture.bob.address();
    Address alice_address = fixture.alice.address();
    uint8[] alice_before = fixture.alice.database_session(bob_address);
    uint8[] bob_before = fixture.bob.database_session(alice_address);

    fixture.reopen_all();

    require_bytes_equal(alice_before,
        fixture.alice.database_session(bob_address),
        "Alice's persisted session changed while closed");
    require_bytes_equal(alice_before,
        fixture.alice.memory_session(bob_address),
        "Alice did not reload the persisted session after reopen");
    require_bytes_equal(bob_before,
        fixture.bob.database_session(alice_address),
        "Bob's persisted session changed while closed");
    require_bytes_equal(bob_before,
        fixture.bob.memory_session(alice_address),
        "Bob did not reload the persisted session after reopen");
    fixture.alice.require_session_consistent(bob_address);
    fixture.bob.require_session_consistent(alice_address);
}

private static uint8[] encrypt_wire_message(PersistentPeer sender,
        PersistentPeer receiver, string plaintext, out CiphertextType type)
        throws Error {
    Address receiver_address = receiver.address();
    CiphertextMessage ciphertext = ((!) sender.store)
        .create_session_cipher(receiver_address).encrypt(plaintext.data);
    type = ciphertext.type;
    return copy_bytes(ciphertext.serialized);
}

private static uint8[] encrypt_signal(PersistentPeer sender,
        PersistentPeer receiver, string plaintext) throws Error {
    CiphertextType type;
    uint8[] serialized = encrypt_wire_message(sender, receiver, plaintext,
        out type);
    require(type == CiphertextType.SIGNAL,
        "established legacy session unexpectedly emitted PREKEY ciphertext");
    return serialized;
}

private static string decrypt_pre_key(PersistentPeer receiver,
        PersistentPeer sender, uint8[] ciphertext) throws Error {
    PreKeyOmemoMessage message = ((!) receiver.context)
        .deserialize_signal_pre_key_message(ciphertext);
    Address sender_address = sender.address();
    SessionCipher cipher = ((!) receiver.store)
        .create_session_cipher(sender_address);
    uint8[] plaintext = cipher.decrypt_pre_key_message(message);
    uint8[] terminated = new uint8[plaintext.length + 1];
    Memory.copy(terminated, plaintext, plaintext.length);
    return (string) terminated;
}

private static string decrypt_signal(PersistentPeer receiver,
        PersistentPeer sender, uint8[] ciphertext) throws Error {
    return decrypt_signal_from_address(receiver, sender.jid,
        sender.device_id, ciphertext);
}

private static string decrypt_signal_from_address(PersistentPeer receiver,
        string sender_jid, int sender_device_id, uint8[] ciphertext)
        throws Error {
    OmemoMessage message = ((!) receiver.context)
        .deserialize_signal_message(ciphertext);
    Address sender_address = new Address(sender_jid, sender_device_id);
    SessionCipher cipher = ((!) receiver.store)
        .create_session_cipher(sender_address);
    uint8[] plaintext = cipher.decrypt_message(message);
    uint8[] terminated = new uint8[plaintext.length + 1];
    Memory.copy(terminated, plaintext, plaintext.length);
    return (string) terminated;
}

private static void test_unready_store_blocks_native_access() throws Error {
    Context context = new Context();
    Store store = context.create_store(false);
    store.identity_key_store.local_registration_id = 7711;
    Address remote = new Address("blocked@example.test", 8822);

    require(!store.is_persistence_ready,
        "create_store(false) unexpectedly returned a ready store");
    require(store.local_registration_id == 0,
        "unready store exposed its local registration id");
    require(Protocol.Session.contains_session(store.native_context, remote) ==
            (int) ErrorCode.UNKNOWN,
        "native session access was not blocked before persistence became ready");
    require(Protocol.PreKey.contains_key(store.native_context, 17) ==
            (int) ErrorCode.UNKNOWN,
        "native pre-key access was not blocked before persistence became ready");

    store.mark_persistence_ready();
    require(store.is_persistence_ready,
        "mark_persistence_ready did not open the persistent store gate");
    require(store.local_registration_id == 7711,
        "ready store did not expose its local registration id");
    require(Protocol.Session.contains_session(store.native_context, remote) == 0,
        "native session access did not recover after persistence became ready");
    require(Protocol.PreKey.contains_key(store.native_context, 17) == 0,
        "native pre-key access did not recover after persistence became ready");
}

private static void test_identity_changing_prekey_preserves_all_state()
        throws Error {
    PersistenceFixture? fixture = null;
    PersistentPeer? imposter = null;
    LegacyDecryptRuntime? runtime = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        Address alice_address = alice.address();
        persist_known_sender_identity(bob, alice);

        Context imposter_context = new Context();
        imposter = new PersistentPeer(
            Path.build_filename(((!) fixture).temp_dir,
                "imposter-omemo.db"),
            alice.jid, 303, alice.device_id, imposter_context);
        prepare_unconfirmed_legacy_session((!) imposter, bob);
        CiphertextType type;
        uint8[] serialized = encrypt_wire_message((!) imposter, bob,
            "0123456789abcdef", out type);
        require(type == CiphertextType.PREKEY,
            "identity-changing test message was not PREKEY");

        uint8[] session_database_before = bob.database_session(alice_address);
        uint8[] session_memory_before = bob.memory_session(alice_address);
        uint8[] pre_key_database_before = bob.database_pre_key(31337);
        uint8[] pre_key_memory_before = bob.memory_pre_key(31337);
        uint8[]? identity_before = ((!) bob.store).identity_key_store
            .load_identity(alice_address);
        string meta_before = identity_meta_snapshot((!) bob.db,
            bob.identity_id, alice.jid, alice.device_id);

        int stored_sessions = 0;
        int deleted_pre_keys = 0;
        int changed_identities = 0;
        ((!) bob.store).session_store.session_stored.connect((session) => {
            stored_sessions++;
        });
        ((!) bob.store).pre_key_store.pre_key_deleted.connect((key) => {
            deleted_pre_keys++;
        });
        ((!) bob.store).identity_key_store.trusted_identity_added.connect((id) => {
            changed_identities++;
        });
        ((!) bob.store).identity_key_store.trusted_identity_updated.connect((id) => {
            changed_identities++;
        });

        runtime = new LegacyDecryptRuntime(((!) fixture).temp_dir, bob);
        bool failed = false;
        try {
            ((!) runtime).decryptor.decrypt_key(
                legacy_prekey_data((!) imposter, serialized),
                new Xmpp.Jid(alice.jid));
        } catch (Error e) {
            failed = true;
            require(e.code == (int) ErrorCode.UNTRUSTED_IDENTITY,
                @"identity-changing PREKEY returned $(e.code), expected SG_ERR_UNTRUSTED_IDENTITY");
        }
        require(failed,
            "identity-changing PREKEY unexpectedly authenticated");
        require(stored_sessions == 0 && deleted_pre_keys == 0 &&
                changed_identities == 0,
            "identity-changing PREKEY reached a native mutation callback");
        require_bytes_equal(session_database_before,
            bob.database_session(alice_address),
            "identity-changing PREKEY changed the persisted session");
        require_bytes_equal(session_memory_before,
            bob.memory_session(alice_address),
            "identity-changing PREKEY changed the in-memory session");
        require_bytes_equal(pre_key_database_before,
            bob.database_pre_key(31337),
            "identity-changing PREKEY consumed the persisted pre-key");
        require_bytes_equal(pre_key_memory_before,
            bob.memory_pre_key(31337),
            "identity-changing PREKEY consumed the in-memory pre-key");
        require_optional_bytes_equal(identity_before,
            ((!) bob.store).identity_key_store.load_identity(alice_address),
            "identity-changing PREKEY changed the native identity store");
        require(identity_meta_snapshot((!) bob.db, bob.identity_id,
                alice.jid, alice.device_id) == meta_before,
            "identity-changing PREKEY changed identity_meta");
    } finally {
        if (runtime != null) ((!) runtime).close();
        if (imposter != null) remove_peer_database((!) imposter);
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_identity_meta_failure_rolls_back_authenticated_prekey()
        throws Error {
    PersistenceFixture? fixture = null;
    LegacyDecryptRuntime? runtime = null;
    bool trigger_installed = false;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        Address alice_address = alice.address();

        // Rebuild an unconfirmed sender session with the same identity and
        // device id. The receiver still holds its established ratchet, so a
        // failed metadata commit must restore that exact prior record.
        prepare_unconfirmed_legacy_session(alice, bob);
        CiphertextType type;
        uint8[] serialized = encrypt_wire_message(alice, bob,
            "0123456789abcdef", out type);
        require(type == CiphertextType.PREKEY,
            "identity-meta rollback test message was not PREKEY");

        uint8[] session_database_before = bob.database_session(alice_address);
        uint8[] session_memory_before = bob.memory_session(alice_address);
        uint8[] pre_key_database_before = bob.database_pre_key(31337);
        uint8[] pre_key_memory_before = bob.memory_pre_key(31337);
        uint8[]? identity_before = ((!) bob.store).identity_key_store
            .load_identity(alice_address);
        string meta_before = identity_meta_snapshot((!) bob.db,
            bob.identity_id, alice.jid, alice.device_id);
        require(meta_before == "ABSENT",
            "identity-meta rollback fixture unexpectedly has sender metadata");

        int stored_sessions = 0;
        int deleted_pre_keys = 0;
        ((!) bob.store).session_store.session_stored.connect((session) => {
            stored_sessions++;
        });
        ((!) bob.store).pre_key_store.pre_key_deleted.connect((key) => {
            deleted_pre_keys++;
        });

        ((!) bob.db).exec("CREATE TRIGGER fail_identity_meta_insert " +
            "BEFORE INSERT ON identity_meta BEGIN " +
            "SELECT RAISE(FAIL, 'forced identity-meta write failure'); END");
        trigger_installed = true;
        runtime = new LegacyDecryptRuntime(((!) fixture).temp_dir, bob);
        int display_signals = 0;
        bool display_scope_matches = true;
        ((!) runtime).decryptor.device_trust_state_changed.connect((account, jid) => {
            display_signals++;
            display_scope_matches = display_scope_matches &&
                account.id == bob.account_id && jid.to_string() == alice.jid;
        });

        bool failed = false;
        try {
            ((!) runtime).decryptor.decrypt_key(
                legacy_prekey_data(alice, serialized),
                new Xmpp.Jid(alice.jid));
        } catch (Error e) {
            failed = true;
            require(e.message.contains("forced identity-meta write failure"),
                "authenticated PREKEY failed outside the forced identity_meta seam: " +
                e.message);
        }
        require(failed,
            "PREKEY succeeded although identity_meta persistence failed");
        require(stored_sessions > 0 && deleted_pre_keys > 0,
            "forced identity_meta failure occurred before native PREKEY authentication");
        require(display_signals == 0,
            "rolled back PREKEY emitted a trust display event");

        ((!) bob.db).exec("DROP TRIGGER fail_identity_meta_insert");
        trigger_installed = false;
        require_bytes_equal(session_database_before,
            bob.database_session(alice_address),
            "identity_meta failure changed the persisted session");
        require_bytes_equal(session_memory_before,
            bob.memory_session(alice_address),
            "identity_meta failure changed the in-memory session");
        require_bytes_equal(pre_key_database_before,
            bob.database_pre_key(31337),
            "identity_meta failure changed the persisted pre-key");
        require_bytes_equal(pre_key_memory_before,
            bob.memory_pre_key(31337),
            "identity_meta failure changed the in-memory pre-key");
        require_optional_bytes_equal(identity_before,
            ((!) bob.store).identity_key_store.load_identity(alice_address),
            "identity_meta failure changed the native identity store");
        require(identity_meta_snapshot((!) bob.db, bob.identity_id,
                alice.jid, alice.device_id) == meta_before,
            "identity_meta failure left device metadata behind");
        ((!) runtime).decryptor.decrypt_key(legacy_prekey_data(alice, serialized),
            new Xmpp.Jid(alice.jid));
        require(display_signals == 1,
            "committed new PREKEY identity did not emit one trust display event");
        uint8[] next = encrypt_wire_message(alice, bob,
            "fedcba9876543210", out type);
        require(type == CiphertextType.PREKEY,
            "unchanged-identity display fixture needs another PREKEY");
        ((!) runtime).decryptor.decrypt_key(legacy_prekey_data(alice, next),
            new Xmpp.Jid(alice.jid));
        require(display_signals == 1,
            "unchanged incoming identity must not repeat trust display events");
        require(display_scope_matches,
            "PREKEY trust display event escaped its account or sender");
    } finally {
        if (trigger_installed && fixture != null &&
                ((!) fixture).bob.db != null) {
            try {
                ((!) ((!) fixture).bob.db).exec(
                    "DROP TRIGGER IF EXISTS fail_identity_meta_insert");
            } catch (Error cleanup_error) {
            }
        }
        if (runtime != null) ((!) runtime).close();
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_full_synchronous() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        require(((!) fixture).alice.synchronous_mode() == 2,
            "OMEMO SQLCipher database must use PRAGMA synchronous=FULL (2)");
        ((!) fixture).reopen_all();
        require(((!) fixture).alice.synchronous_mode() == 2,
            "reopened OMEMO SQLCipher database must retain synchronous=FULL (2)");
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_first_incoming_after_reopen() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);
        uint8[] ciphertext = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "first incoming after reopen");

        reopen_and_require_sessions_unchanged((!) fixture);
        string plaintext = decrypt_signal(((!) fixture).alice,
            ((!) fixture).bob, ciphertext);
        require(plaintext == "first incoming after reopen",
            "first incoming message after reopen was not decrypted");
        ((!) fixture).alice.require_session_consistent(((!) fixture).bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_first_outgoing_after_reopen() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);

        reopen_and_require_sessions_unchanged((!) fixture);
        uint8[] ciphertext = encrypt_signal(((!) fixture).alice,
            ((!) fixture).bob, "first outgoing after reopen");
        string plaintext = decrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, ciphertext);
        require(plaintext == "first outgoing after reopen",
            "first outgoing message after reopen could not be decrypted");
        ((!) fixture).alice.require_session_consistent(((!) fixture).bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_second_reopen_advances_ratchet() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);

        uint8[] first_ciphertext = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "after first reopen");
        reopen_and_require_sessions_unchanged((!) fixture);
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                first_ciphertext) == "after first reopen",
            "message after first reopen was not decrypted");
        uint8[] first_record = ((!) fixture).alice.database_session(
            ((!) fixture).bob.address());

        uint8[] second_ciphertext = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "after second reopen");
        reopen_and_require_sessions_unchanged((!) fixture);
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                second_ciphertext) == "after second reopen",
            "message after second reopen was not decrypted");
        uint8[] second_record = ((!) fixture).alice.database_session(
            ((!) fixture).bob.address());

        require(Base64.encode(first_record) != Base64.encode(second_record),
            "ratchet record did not advance across the second reopen");
        ((!) fixture).alice.require_session_consistent(((!) fixture).bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_offline_queue_in_order_after_reopen() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);

        ((!) fixture).close_alice();
        uint8[] first = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "offline message 1");
        uint8[] second = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "offline message 2");
        uint8[] third = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "offline message 3");
        uint8[] fourth = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "offline message 4");

        ((!) fixture).reopen_alice();
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                first) == "offline message 1",
            "first queued message after reopen was not decrypted");
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                second) == "offline message 2",
            "second queued message after reopen was not decrypted");
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                third) == "offline message 3",
            "third queued message after reopen was not decrypted");
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                fourth) == "offline message 4",
            "fourth queued message after reopen was not decrypted");
        ((!) fixture).alice.require_session_consistent(
            ((!) fixture).bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_offline_queue_out_of_order_after_reopen()
        throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);

        ((!) fixture).close_alice();
        uint8[] first = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "out-of-order message 1");
        uint8[] second = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "out-of-order message 2");
        uint8[] third = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "out-of-order message 3");
        uint8[] fourth = encrypt_signal(((!) fixture).bob,
            ((!) fixture).alice, "out-of-order message 4");

        ((!) fixture).reopen_alice();
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                fourth) == "out-of-order message 4",
            "fourth queued message could not establish skipped keys after reopen");
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                third) == "out-of-order message 3",
            "third queued message could not use a skipped key after reopen");
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                second) == "out-of-order message 2",
            "second queued message could not use a skipped key after reopen");
        require(decrypt_signal(((!) fixture).alice, ((!) fixture).bob,
                first) == "out-of-order message 1",
            "first queued message could not use a skipped key after reopen");
        ((!) fixture).alice.require_session_consistent(
            ((!) fixture).bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_unconfirmed_prekey_queue_after_reopen() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        prepare_unconfirmed_legacy_session(alice, bob);

        ((!) fixture).close_bob();
        CiphertextType first_type;
        CiphertextType second_type;
        CiphertextType third_type;
        CiphertextType fourth_type;
        uint8[] first = encrypt_wire_message(alice, bob,
            "unconfirmed pre-key message 1", out first_type);
        uint8[] second = encrypt_wire_message(alice, bob,
            "unconfirmed pre-key message 2", out second_type);
        uint8[] third = encrypt_wire_message(alice, bob,
            "unconfirmed pre-key message 3", out third_type);
        uint8[] fourth = encrypt_wire_message(alice, bob,
            "unconfirmed pre-key message 4", out fourth_type);
        Test.message("unconfirmed offline ciphertext types: %d,%d,%d,%d (PREKEY=%d)",
            (int) first_type, (int) second_type, (int) third_type,
            (int) fourth_type, (int) CiphertextType.PREKEY);
        require(first_type == CiphertextType.PREKEY &&
                second_type == CiphertextType.PREKEY &&
                third_type == CiphertextType.PREKEY &&
                fourth_type == CiphertextType.PREKEY,
            "an unconfirmed legacy session did not emit four PREKEY ciphertexts");

        ((!) fixture).reopen_bob();
        require(decrypt_pre_key(bob, alice, first) ==
                "unconfirmed pre-key message 1",
            "first queued PREKEY message after reopen was not decrypted");
        require(decrypt_pre_key(bob, alice, second) ==
                "unconfirmed pre-key message 2",
            "second queued PREKEY message after reopen was not decrypted");
        require(decrypt_pre_key(bob, alice, third) ==
                "unconfirmed pre-key message 3",
            "third queued PREKEY message after reopen was not decrypted");
        require(decrypt_pre_key(bob, alice, fourth) ==
                "unconfirmed pre-key message 4",
            "fourth queued PREKEY message after reopen was not decrypted");
        bob.require_session_consistent(alice.address());
        alice.require_session_consistent(bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_unconfirmed_prekey_queue_out_of_order_after_reopen()
        throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        prepare_unconfirmed_legacy_session(alice, bob);

        ((!) fixture).close_bob();
        CiphertextType first_type;
        CiphertextType second_type;
        CiphertextType third_type;
        CiphertextType fourth_type;
        uint8[] first = encrypt_wire_message(alice, bob,
            "unconfirmed out-of-order PREKEY 1", out first_type);
        uint8[] second = encrypt_wire_message(alice, bob,
            "unconfirmed out-of-order PREKEY 2", out second_type);
        uint8[] third = encrypt_wire_message(alice, bob,
            "unconfirmed out-of-order PREKEY 3", out third_type);
        uint8[] fourth = encrypt_wire_message(alice, bob,
            "unconfirmed out-of-order PREKEY 4", out fourth_type);
        require(first_type == CiphertextType.PREKEY &&
                second_type == CiphertextType.PREKEY &&
                third_type == CiphertextType.PREKEY &&
                fourth_type == CiphertextType.PREKEY,
            "unconfirmed out-of-order fixture did not emit four PREKEY ciphertexts");

        ((!) fixture).reopen_bob();
        require(decrypt_pre_key(bob, alice, fourth) ==
                "unconfirmed out-of-order PREKEY 4",
            "fourth queued PREKEY did not establish skipped keys after reopen");
        require(decrypt_pre_key(bob, alice, third) ==
                "unconfirmed out-of-order PREKEY 3",
            "third queued PREKEY did not use its skipped key after reopen");
        require(decrypt_pre_key(bob, alice, second) ==
                "unconfirmed out-of-order PREKEY 2",
            "second queued PREKEY did not use its skipped key after reopen");
        require(decrypt_pre_key(bob, alice, first) ==
                "unconfirmed out-of-order PREKEY 1",
            "first queued PREKEY did not use its skipped key after reopen");
        bob.require_session_consistent(alice.address());
        alice.require_session_consistent(bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_same_sender_prekey_to_signal_across_reopen()
        throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        prepare_unconfirmed_legacy_session(alice, bob);

        int sender_device_id = alice.device_id;
        uint8[] sender_identity = copy_bytes(
            ((!) alice.store).identity_key_store.identity_key_public.get_data());
        CiphertextType prekey_type;
        uint8[] prekey = encrypt_wire_message(alice, bob,
            "pre-key before first reopen", out prekey_type);
        require(prekey_type == CiphertextType.PREKEY,
            "first message from the unconfirmed sender was not PREKEY");
        PreKeyOmemoMessage parsed_prekey = ((!) alice.context)
            .deserialize_signal_pre_key_message(prekey);
        require_bytes_equal(sender_identity,
            parsed_prekey.identity_key.serialize(),
            "PREKEY wire identity does not match the sender identity");

        ((!) fixture).close_bob();
        ((!) fixture).reopen_bob();
        require(decrypt_pre_key(bob, alice, prekey) ==
                "pre-key before first reopen",
            "PREKEY message was not decrypted after receiver reopen");

        uint8[] confirmation = encrypt_signal(bob, alice,
            "receiver confirmation");
        require(decrypt_signal(alice, bob, confirmation) ==
                "receiver confirmation",
            "sender did not accept the receiver session confirmation");

        ((!) fixture).close_bob();
        uint8[] signal = encrypt_signal(alice, bob,
            "signal after second reopen");
        ((!) fixture).reopen_bob();
        require(decrypt_signal(bob, alice, signal) ==
                "signal after second reopen",
            "SIGNAL message from the same sender was not decrypted after reopen");
        require(alice.device_id == sender_device_id,
            "sender device id changed during PREKEY-to-SIGNAL transition");
        require_bytes_equal(sender_identity,
            ((!) alice.store).identity_key_store.identity_key_public.get_data(),
            "sender identity changed during PREKEY-to-SIGNAL transition");
        Address sender_address = alice.address();
        SessionRecord receiver_session = ((!) bob.store)
            .load_session(sender_address);
        require_bytes_equal(sender_identity,
            receiver_session.state.remote_identity_key.serialize(),
            "receiver ratchet no longer contains the PREKEY sender identity");
        bob.require_session_consistent(sender_address);
        alice.require_session_consistent(bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void write_child_result(string result_path, string contents)
        throws Error {
    string temporary_path = result_path + ".tmp";
    FileUtils.set_contents(temporary_path, contents);
    if (FileUtils.rename(temporary_path, result_path) != 0) {
        FileUtils.remove(temporary_path);
        throw new PersistenceError.FAILED(
            "hard-exit child could not publish its result marker");
    }
}

private static int run_hard_exit_receiver_child(string[] args) {
    string? result_path = args.length >= 9 ? args[8] : null;
    try {
        require(args.length == 9,
            "hard-exit child received an invalid argument count");

        int receiver_account_id;
        int sender_device_id;
        require(int.try_parse(args[4], out receiver_account_id),
            "hard-exit child received an invalid receiver account id");
        require(int.try_parse(args[6], out sender_device_id),
            "hard-exit child received an invalid sender device id");

        Context context = new Context();
        PersistentPeer receiver = new PersistentPeer.open_existing(
            args[2], args[3], receiver_account_id, context);
        Address sender_address = new Address(args[5], sender_device_id);
        uint8[]? persisted_record = null;
        ((!) receiver.store).session_store.session_stored.connect((session) => {
            if (session.name == sender_address.name &&
                    session.device_id == sender_address.device_id) {
                persisted_record = copy_bytes(session.record);
            }
        });

        string plaintext = decrypt_signal_from_address(receiver,
            sender_address.name, sender_address.device_id,
            Base64.decode(args[7]));
        require(plaintext == CRASH_CHILD_PLAINTEXT,
            "hard-exit child could not decrypt the ratchet message");
        require(persisted_record != null,
            "hard-exit child observed no persisted session callback");
        require_bytes_equal((!) persisted_record,
            receiver.database_session(sender_address),
            "persisted callback record differs from the SQLCipher session");

        write_child_result((!) result_path,
            "READY\n" + Base64.encode((!) persisted_record));

        // The parent deliberately terminates this process without allowing
        // stack unwinding, object disposal or an orderly database close.
        new MainLoop().run();
        return 3;
    } catch (Error e) {
        if (result_path != null) {
            try {
                write_child_result((!) result_path, "ERROR\n" + e.message);
            } catch (Error marker_error) {
            }
        }
        return 2;
    }
}

private static int run_hard_exit_prekey_receiver_child(string[] args) {
    string? result_path = args.length >= 9 ? args[8] : null;
    LegacyDecryptRuntime? runtime = null;
    try {
        require(args.length == 9,
            "hard-exit PREKEY child received an invalid argument count");

        int receiver_account_id;
        int sender_device_id;
        require(int.try_parse(args[4], out receiver_account_id),
            "hard-exit PREKEY child received an invalid receiver account id");
        require(int.try_parse(args[6], out sender_device_id),
            "hard-exit PREKEY child received an invalid sender device id");

        Context context = new Context();
        PersistentPeer receiver = new PersistentPeer.open_existing(
            args[2], args[3], receiver_account_id, context);
        Address sender_address = new Address(args[5], sender_device_id);
        runtime = new LegacyDecryptRuntime(
            Path.get_dirname(args[2]), receiver);

        ((!) receiver.store).session_store.session_stored.connect((session) => {
            if (session.name != sender_address.name ||
                    session.device_id != sender_address.device_id) {
                return;
            }
            try {
                write_child_result((!) result_path, "READY\n");
            } catch (Error marker_error) {
                return;
            }

            // Stop inside libomemo-c's session callback: SQLCipher has seen
            // the session UPSERT, but decrypt_key() has not yet consumed the
            // one-time pre-key, written identity_meta or released its
            // SAVEPOINT. The parent kills this process at exactly this seam.
            new MainLoop().run();
        });

        Xmpp.Xep.Omemo.ParsedData data = new Xmpp.Xep.Omemo.ParsedData();
        data.sid = sender_device_id;
        data.is_prekey = true;
        data.encrypted_key = Base64.decode(args[7]);
        data.ciphertext = new uint8[0];
        data.iv = new uint8[0];
        ((!) runtime).decryptor.decrypt_key(data,
            new Xmpp.Jid(sender_address.name));
        throw new PersistenceError.FAILED(
            "hard-exit PREKEY child completed beyond the transaction seam");
    } catch (Error e) {
        if (result_path != null) {
            try {
                write_child_result((!) result_path, "ERROR\n" + e.message);
            } catch (Error marker_error) {
            }
        }
        if (runtime != null) ((!) runtime).close();
        return 2;
    }
}

private static string wait_for_child_result(string result_path,
        out int64 elapsed_usec) throws Error {
    int64 started = GLib.get_monotonic_time();
    while (GLib.get_monotonic_time() - started <
            CRASH_CHILD_SAFETY_TIMEOUT_USEC) {
        if (FileUtils.test(result_path, FileTest.EXISTS)) {
            string contents;
            FileUtils.get_contents(result_path, out contents);
            elapsed_usec = GLib.get_monotonic_time() - started;
            return contents;
        }
        Thread.usleep(10 * 1000);
    }
    elapsed_usec = GLib.get_monotonic_time() - started;
    throw new PersistenceError.FAILED(
        "hard-exit child produced no result before the test safety timeout");
}

private static void force_exit_and_wait(Subprocess child) {
    child.force_exit();
    try {
        child.wait();
    } catch (Error e) {
    }
}

private static void test_ratchet_commit_survives_hard_process_exit()
        throws Error {
    PersistenceFixture? fixture = null;
    Subprocess? child = null;
    string? result_path = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        Address bob_address = bob.address();
        uint8[] receiver_record_before = alice.database_session(bob_address);
        uint8[] first = encrypt_signal(bob, alice,
            CRASH_CHILD_PLAINTEXT);
        uint8[] second = encrypt_signal(bob, alice,
            "ratchet message after hard process exit");

        ((!) fixture).close_alice();
        require(test_program_path != null &&
                ((!) test_program_path).length > 0,
            "test executable path is unavailable for hard-exit child");
        result_path = Path.build_filename(((!) fixture).temp_dir,
            "hard-exit-child-result");
        string[] child_argv = {
            (!) test_program_path,
            CRASH_CHILD_MODE,
            alice.db_path,
            alice.jid,
            alice.account_id.to_string(),
            bob.jid,
            bob.device_id.to_string(),
            Base64.encode(first),
            (!) result_path
        };
        child = subprocess_newv_const(child_argv,
            SubprocessFlags.STDOUT_SILENCE |
            SubprocessFlags.STDERR_SILENCE);

        int64 elapsed_usec;
        string child_result = wait_for_child_result((!) result_path,
            out elapsed_usec);
        Test.message("hard-exit child reached persisted callback in %.1f ms",
            elapsed_usec / 1000.0);
        if (child_result.has_prefix("ERROR\n")) {
            throw new PersistenceError.FAILED(
                "hard-exit child failed: " + child_result.substring(6));
        }
        require(child_result.has_prefix("READY\n"),
            "hard-exit child returned an invalid result marker");
        uint8[] child_persisted_record = Base64.decode(
            child_result.substring(6).strip());
        require(Base64.encode(receiver_record_before) !=
                Base64.encode(child_persisted_record),
            "hard-exit child did not advance the receiver ratchet");

        force_exit_and_wait((!) child);
        require(!((!) child).get_successful(),
            "hard-exit child unexpectedly completed successfully");
        child = null;

        ((!) fixture).reopen_alice();
        require_bytes_equal(child_persisted_record,
            alice.database_session(bob_address),
            "hard process exit lost the acknowledged SQLCipher ratchet state");
        require_bytes_equal(child_persisted_record,
            alice.memory_session(bob_address),
            "new OMEMO context did not reload the hard-exit ratchet state");
        require(decrypt_signal(alice, bob, second) ==
                "ratchet message after hard process exit",
            "next ratchet message failed after hard process exit and reopen");
        alice.require_session_consistent(bob_address);
    } finally {
        if (child != null) force_exit_and_wait((!) child);
        if (result_path != null) {
            FileUtils.remove((!) result_path);
            FileUtils.remove((!) result_path + ".tmp");
        }
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_prekey_transaction_rolls_back_on_hard_process_exit()
        throws Error {
    PersistenceFixture? fixture = null;
    LegacyDecryptRuntime? runtime = null;
    Subprocess? child = null;
    string? result_path = null;
    try {
        fixture = new PersistenceFixture();
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        Address alice_address = alice.address();
        prepare_unconfirmed_legacy_session(alice, bob);

        CiphertextType type;
        uint8[] serialized = encrypt_wire_message(alice, bob,
            "0123456789abcdef", out type);
        require(type == CiphertextType.PREKEY,
            "hard-exit transaction fixture did not produce PREKEY ciphertext");
        require(!bob.database_contains_session(alice_address),
            "receiver unexpectedly had a sender session before PREKEY decrypt");
        uint8[] pre_key_before = bob.database_pre_key(31337);
        string meta_before = identity_meta_snapshot((!) bob.db,
            bob.identity_id, alice.jid, alice.device_id);

        ((!) fixture).close_bob();
        require(test_program_path != null &&
                ((!) test_program_path).length > 0,
            "test executable path is unavailable for PREKEY hard-exit child");
        result_path = Path.build_filename(((!) fixture).temp_dir,
            "hard-exit-prekey-child-result");
        string[] child_argv = {
            (!) test_program_path,
            PREKEY_CRASH_CHILD_MODE,
            bob.db_path,
            bob.jid,
            bob.account_id.to_string(),
            alice.jid,
            alice.device_id.to_string(),
            Base64.encode(serialized),
            (!) result_path
        };
        child = subprocess_newv_const(child_argv,
            SubprocessFlags.STDOUT_SILENCE |
            SubprocessFlags.STDERR_SILENCE);

        int64 elapsed_usec;
        string child_result = wait_for_child_result((!) result_path,
            out elapsed_usec);
        Test.message("PREKEY hard-exit child reached open SAVEPOINT in %.1f ms",
            elapsed_usec / 1000.0);
        if (child_result.has_prefix("ERROR\n")) {
            throw new PersistenceError.FAILED(
                "PREKEY hard-exit child failed: " +
                child_result.substring(6));
        }
        require(child_result.has_prefix("READY\n"),
            "PREKEY hard-exit child returned an invalid result marker");

        force_exit_and_wait((!) child);
        require(!((!) child).get_successful(),
            "PREKEY hard-exit child unexpectedly completed successfully");
        child = null;

        ((!) fixture).reopen_bob();
        require(!bob.database_contains_session(alice_address),
            "hard process exit committed a partial PREKEY session");
        require(!((!) bob.store).session_store.contains_session(alice_address),
            "reopened memory exposed a partial PREKEY session");
        require_bytes_equal(pre_key_before, bob.database_pre_key(31337),
            "hard process exit consumed the persisted one-time pre-key");
        require_bytes_equal(pre_key_before, bob.memory_pre_key(31337),
            "reopened memory lost the one-time pre-key");
        require(identity_meta_snapshot((!) bob.db, bob.identity_id,
                alice.jid, alice.device_id) == meta_before,
            "hard process exit committed partial PREKEY device metadata");

        // The same encrypted PREKEY remains usable after SQLite rolls the
        // uncommitted SAVEPOINT back during reopen.
        runtime = new LegacyDecryptRuntime(((!) fixture).temp_dir, bob);
        uint8[] decrypted = ((!) runtime).decryptor.decrypt_key(
            legacy_prekey_data(alice, serialized),
            new Xmpp.Jid(alice.jid));
        require_bytes_equal("0123456789abcdef".data, decrypted,
            "PREKEY could not be retried after hard-exit rollback");
        require(bob.database_contains_session(alice_address),
            "successful PREKEY retry did not persist the sender session");
        require(!bob.database_contains_pre_key(31337),
            "successful PREKEY retry did not consume the one-time pre-key");
        bob.require_session_consistent(alice_address);
    } finally {
        if (child != null) force_exit_and_wait((!) child);
        if (runtime != null) ((!) runtime).close();
        if (result_path != null) {
            FileUtils.remove((!) result_path);
            FileUtils.remove((!) result_path + ".tmp");
        }
        if (fixture != null) {
            string child_db = Path.build_filename(
                ((!) fixture).temp_dir, "dino-decrypt-runtime.db");
            FileUtils.remove(child_db);
            FileUtils.remove(child_db + "-shm");
            FileUtils.remove(child_db + "-wal");
            ((!) fixture).cleanup();
        }
    }
}

private static void test_write_failure_is_fail_closed() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        establish_confirmed_legacy_session((!) fixture);
        PersistentPeer alice = ((!) fixture).alice;
        PersistentPeer bob = ((!) fixture).bob;
        Address bob_address = bob.address();
        uint8[] database_before = alice.database_session(bob_address);
        uint8[] memory_before = alice.memory_session(bob_address);

        ((!) alice.db).exec("CREATE TRIGGER fail_session_update " +
            "BEFORE UPDATE ON session BEGIN " +
            "SELECT RAISE(FAIL, 'forced session write failure'); END");

        Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
            "*Native OMEMO store callback failed:*forced session write failure*");
        bool failed = false;
        try {
            ((!) alice.store).create_session_cipher(bob_address)
                .encrypt("must not escape".data);
        } catch (Error e) {
            failed = true;
            require(e.code == (int) ErrorCode.UNKNOWN,
                @"session write failure returned $(e.code), expected SG_ERR_UNKNOWN");
        }
        Test.assert_expected_messages();
        require(failed,
            "encryption succeeded although the ratchet state could not be persisted");
        require_bytes_equal(database_before, alice.database_session(bob_address),
            "failed encryption changed the persisted session");
        require_bytes_equal(memory_before, alice.memory_session(bob_address),
            "failed encryption changed the in-memory session");

        ((!) alice.db).exec("DROP TRIGGER fail_session_update");
        reopen_and_require_sessions_unchanged((!) fixture);

        uint8[] recovered = encrypt_signal(alice, bob,
            "recovered after persistence failure");
        require(decrypt_signal(bob, alice, recovered) ==
                "recovered after persistence failure",
            "session did not recover after the forced persistence failure");
        alice.require_session_consistent(bob.address());
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static PreKeyRecord create_pre_key(PersistentPeer peer,
        uint32 pre_key_id) throws Error {
    PreKeyRecord record;
    throw_by_code(PreKeyRecord.create(out record, pre_key_id,
        ((!) peer.context).generate_key_pair()));
    return record;
}

private static void test_pre_key_update_failure_is_fail_closed() throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        PersistentPeer alice = ((!) fixture).alice;
        const uint32 PRE_KEY_ID = 41001;

        ((!) alice.store).store_pre_key(create_pre_key(alice, PRE_KEY_ID));
        uint8[] database_before = alice.database_pre_key(PRE_KEY_ID);
        uint8[] memory_before = alice.memory_pre_key(PRE_KEY_ID);
        PreKeyRecord replacement = create_pre_key(alice, PRE_KEY_ID);

        ((!) alice.db).exec("CREATE TRIGGER fail_pre_key_update " +
            "BEFORE UPDATE ON pre_key BEGIN " +
            "SELECT RAISE(FAIL, 'forced pre-key write failure'); END");

        Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
            "*Native OMEMO store callback failed:*forced pre-key write failure*");
        bool failed = false;
        try {
            ((!) alice.store).store_pre_key(replacement);
        } catch (Error e) {
            failed = true;
            require(e.code == (int) ErrorCode.UNKNOWN,
                @"pre-key write failure returned $(e.code), expected SG_ERR_UNKNOWN");
        }
        Test.assert_expected_messages();
        require(failed,
            "pre-key replacement succeeded although persistence failed");
        require_bytes_equal(database_before, alice.database_pre_key(PRE_KEY_ID),
            "failed pre-key replacement changed the persisted record");
        require_bytes_equal(memory_before, alice.memory_pre_key(PRE_KEY_ID),
            "failed pre-key replacement changed the in-memory record");

        ((!) alice.db).exec("DROP TRIGGER fail_pre_key_update");
        ((!) alice.store).store_pre_key(replacement);
        require_bytes_equal(alice.database_pre_key(PRE_KEY_ID),
            alice.memory_pre_key(PRE_KEY_ID),
            "pre-key store did not recover after persistence failure");
        require(Base64.encode(database_before) !=
                Base64.encode(alice.database_pre_key(PRE_KEY_ID)),
            "successful pre-key replacement did not update the record");
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_signed_pre_key_update_failure_is_fail_closed()
        throws Error {
    PersistenceFixture? fixture = null;
    try {
        fixture = new PersistenceFixture();
        PersistentPeer alice = ((!) fixture).alice;
        const uint32 SIGNED_PRE_KEY_ID = 42001;

        SignedPreKeyRecord original = ((!) alice.context).generate_signed_pre_key(
            ((!) alice.store).identity_key_pair, (int32) SIGNED_PRE_KEY_ID);
        ((!) alice.store).store_signed_pre_key(original);
        uint8[] database_before = alice.database_signed_pre_key(
            SIGNED_PRE_KEY_ID);
        uint8[] memory_before = alice.memory_signed_pre_key(
            SIGNED_PRE_KEY_ID);
        SignedPreKeyRecord replacement = ((!) alice.context)
            .generate_signed_pre_key(((!) alice.store).identity_key_pair,
                (int32) SIGNED_PRE_KEY_ID);

        ((!) alice.db).exec("CREATE TRIGGER fail_signed_pre_key_update " +
            "BEFORE UPDATE ON signed_pre_key BEGIN " +
            "SELECT RAISE(FAIL, 'forced signed pre-key write failure'); END");

        Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
            "*Native OMEMO store callback failed:*forced signed pre-key write failure*");
        bool failed = false;
        try {
            ((!) alice.store).store_signed_pre_key(replacement);
        } catch (Error e) {
            failed = true;
            require(e.code == (int) ErrorCode.UNKNOWN,
                @"signed pre-key write failure returned $(e.code), expected SG_ERR_UNKNOWN");
        }
        Test.assert_expected_messages();
        require(failed,
            "signed pre-key replacement succeeded although persistence failed");
        require_bytes_equal(database_before,
            alice.database_signed_pre_key(SIGNED_PRE_KEY_ID),
            "failed signed pre-key replacement changed the persisted record");
        require_bytes_equal(memory_before,
            alice.memory_signed_pre_key(SIGNED_PRE_KEY_ID),
            "failed signed pre-key replacement changed the in-memory record");

        ((!) alice.db).exec("DROP TRIGGER fail_signed_pre_key_update");
        ((!) alice.store).store_signed_pre_key(replacement);
        require_bytes_equal(alice.database_signed_pre_key(SIGNED_PRE_KEY_ID),
            alice.memory_signed_pre_key(SIGNED_PRE_KEY_ID),
            "signed pre-key store did not recover after persistence failure");
        require(Base64.encode(database_before) !=
                Base64.encode(alice.database_signed_pre_key(SIGNED_PRE_KEY_ID)),
            "successful signed pre-key replacement did not update the record");
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private class ManagerStoreLifecycleFixture : Object {
    internal string temp_dir { get; private set; }
    internal Dino.Database dino_db { get; private set; }
    internal Dino.Plugins.Omemo.Database omemo_db { get; private set; }
    internal Dino.StreamInteractor stream_interactor { get; private set; }
    internal Dino.Entities.Account account { get; private set; }
    internal Store store { get; private set; }

    private Dino.Plugins.Omemo.TrustManager trust_manager;
    private Dino.Plugins.Omemo.Manager manager;
    private OmemoStoreReadinessGate readiness_gate = new OmemoStoreReadinessGate();

    internal ManagerStoreLifecycleFixture(string localpart) throws Error {
        require(Dino.Plugins.Omemo.Plugin.ensure_context(),
            "manager lifecycle fixture could not initialize libomemo-c");

        temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-omemo-manager-store-lifecycle-" + Uuid.string_random());
        require(DirUtils.create_with_parents(temp_dir, 0700) == 0,
            "failed to create manager lifecycle test directory");

        dino_db = new Dino.Database(
            Path.build_filename(temp_dir, "dino.db"),
            "omemo-manager-store-lifecycle-test");
        omemo_db = new Dino.Plugins.Omemo.Database(
            Path.build_filename(temp_dir, "omemo.db"));
        stream_interactor = new Dino.StreamInteractor.for_tests(dino_db);
        start_manager_dependencies(stream_interactor, dino_db);

        account = new Dino.Entities.Account(
            new Xmpp.Jid(localpart + "@example.test"), "secret");
        Store? initialized_store = null;
        stream_interactor.module_manager.initialize_account_modules.connect(
                (candidate, modules) => {
            Store candidate_store = Dino.Plugins.Omemo.Plugin.get_context()
                .create_store(false);
            readiness_gate.watch_store(candidate, candidate_store);
            modules.add(new Dino.Plugins.Omemo.StreamModule(candidate_store));
            if (candidate.equals(account)) initialized_store = candidate_store;
        });

        trust_manager = new Dino.Plugins.Omemo.TrustManager(
            stream_interactor, omemo_db);
        manager = Dino.Plugins.Omemo.Manager.start(
            stream_interactor, omemo_db, trust_manager,
            new Gee.HashMap<Dino.Entities.Account,
                Dino.Plugins.Omemo.OmemoEncryptor>(
                    Dino.Entities.Account.hash_func,
                    Dino.Entities.Account.equals_func));
        manager.auto_publish_own_device_lists = false;

        stream_interactor.module_manager.initialize(account);
        require(initialized_store != null,
            "manager lifecycle fixture did not create the account store");
        store = (!) initialized_store;
    }

    internal void add_account() {
        stream_interactor.account_added(account);
    }

    internal void remove_account() {
        stream_interactor.account_removed(account);
    }

    internal void persist_account() {
        account.persist(dino_db);
    }

    internal int64 identity_count() {
        return omemo_db.identity.select()
            .with(omemo_db.identity.account_id, "=", account.id)
            .count();
    }

    internal Row? identity_row() {
        return omemo_db.identity.select()
            .with(omemo_db.identity.account_id, "=", account.id)
            .single().row().inner;
    }

    internal void insert_mismatched_identity() throws Error {
        ECKeyPair private_pair = Dino.Plugins.Omemo.Plugin.get_context()
            .generate_key_pair();
        ECKeyPair public_pair = Dino.Plugins.Omemo.Plugin.get_context()
            .generate_key_pair();
        omemo_db.identity.upsert()
            .value(omemo_db.identity.account_id, account.id, true)
            .value(omemo_db.identity.device_id, 424242)
            .value(omemo_db.identity.identity_key_private_base64,
                Base64.encode(private_pair.private.serialize()))
            .value(omemo_db.identity.identity_key_public_base64,
                Base64.encode(public_pair.public.serialize()))
            .perform_checked();
    }

    internal void require_valid_identity() throws Error {
        Row? row = identity_row();
        require(row != null,
            "manager initialization did not persist an OMEMO identity");
        require(identity_count() == 1,
            "manager initialization persisted more than one OMEMO identity");

        uint32 registration_id = (uint32) ((!) row)[omemo_db.identity.device_id];
        require(registration_id > 0,
            "persisted OMEMO registration id is invalid");
        require(store.local_registration_id == registration_id,
            "ready store and persisted registration id differ");

        uint8[] private_data = Base64.decode(
            ((!) row)[omemo_db.identity.identity_key_private_base64]);
        uint8[] public_data = Base64.decode(
            ((!) row)[omemo_db.identity.identity_key_public_base64]);
        require(private_data.length > 0 && public_data.length > 0,
            "persisted OMEMO identity key is empty");
        ECPrivateKey private_key = Dino.Plugins.Omemo.Plugin.get_context()
            .decode_private_key(private_data);
        ECPublicKey public_key = Dino.Plugins.Omemo.Plugin.get_context()
            .decode_public_key(public_data);
        ECPublicKey derived_public = generate_public_key(private_key);
        require(derived_public.compare(public_key) == 0,
            "persisted OMEMO public/private identity keys do not match");
    }

    internal void cleanup() {
        omemo_db.close();
        dino_db.close();
        remove_database(Path.build_filename(temp_dir, "omemo.db"));
        remove_database(Path.build_filename(temp_dir, "dino.db"));
        DirUtils.remove(temp_dir);
    }

    private static void remove_database(string path) {
        FileUtils.remove(path);
        FileUtils.remove(path + "-shm");
        FileUtils.remove(path + "-wal");
        FileUtils.remove(path + "-journal");
    }
}

private static void start_manager_dependencies(
        Dino.StreamInteractor stream_interactor, Dino.Database db) {
    _force_class_init(typeof(Dino.MessageProcessor));
    _force_class_init(typeof(Dino.MessageStorage));
    _force_class_init(typeof(Dino.RosterManager));
    _force_class_init(typeof(Dino.Calls));
    _force_class_init(typeof(Dino.ConversationManager));
    _force_class_init(typeof(Dino.PresenceManager));
    _force_class_init(typeof(Dino.MucManager));
    _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
    _force_class_init(typeof(Dino.Plugins.Omemo.Manager));

    Dino.MessageStorage.start(stream_interactor, db);
    Dino.MessageProcessor.start(stream_interactor, db);
    Dino.Calls.start(stream_interactor, db);
    Dino.ConversationManager.start(stream_interactor, db);
    Dino.RosterManager.start(stream_interactor, db);
    Dino.PresenceManager.start(stream_interactor, db);
    Dino.MucManager.start(stream_interactor, db);
}

private static void test_manager_store_waits_for_persisted_account()
        throws Error {
    ManagerStoreLifecycleFixture? fixture = null;
    try {
        fixture = new ManagerStoreLifecycleFixture("pending-store");
        require(((!) fixture).account.id == -1,
            "new lifecycle account unexpectedly has a persisted id");

        ((!) fixture).add_account();

        require(!((!) fixture).store.is_persistence_ready,
            "id=-1 account exposed a ready OMEMO store");
        require(((!) fixture).store.local_registration_id == 0,
            "id=-1 account exposed a native registration id");
        require(((!) fixture).identity_count() == 0,
            "id=-1 account persisted an OMEMO identity");
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_manager_store_initializes_once_after_persist()
        throws Error {
    ManagerStoreLifecycleFixture? fixture = null;
    try {
        fixture = new ManagerStoreLifecycleFixture("persisted-store");
        ((!) fixture).add_account();
        ((!) fixture).persist_account();

        require(((!) fixture).account.id > 0,
            "account persistence did not assign a positive id");
        require(((!) fixture).store.is_persistence_ready,
            "persisted account did not make its OMEMO store ready");
        ((!) fixture).require_valid_identity();

        IdentityKeyStore identity_store = ((!) fixture).store.identity_key_store;
        SessionStore session_store = ((!) fixture).store.session_store;
        PreKeyStore pre_key_store = ((!) fixture).store.pre_key_store;
        SignedPreKeyStore signed_pre_key_store =
            ((!) fixture).store.signed_pre_key_store;
        uint32 registration_id = ((!) fixture).store.local_registration_id;
        uint8[] private_key = copy_bytes(
            identity_store.identity_key_private.get_data());
        uint8[] public_key = copy_bytes(
            identity_store.identity_key_public.get_data());

        ((!) fixture).account.notify_property("id");

        require(((!) fixture).store.is_persistence_ready,
            "redundant id notification made the OMEMO store unavailable");
        require(((!) fixture).store.identity_key_store == identity_store &&
                ((!) fixture).store.session_store == session_store &&
                ((!) fixture).store.pre_key_store == pre_key_store &&
                ((!) fixture).store.signed_pre_key_store == signed_pre_key_store,
            "redundant id notification reinitialized an OMEMO store");
        require(((!) fixture).store.local_registration_id == registration_id,
            "redundant id notification changed the registration id");
        require_bytes_equal(private_key,
            ((!) fixture).store.identity_key_store.identity_key_private.get_data(),
            "redundant id notification changed the private identity key");
        require_bytes_equal(public_key,
            ((!) fixture).store.identity_key_store.identity_key_public.get_data(),
            "redundant id notification changed the public identity key");
        ((!) fixture).require_valid_identity();
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_manager_store_removed_before_persist_stays_unavailable()
        throws Error {
    ManagerStoreLifecycleFixture? fixture = null;
    try {
        fixture = new ManagerStoreLifecycleFixture("removed-pending-store");
        ((!) fixture).add_account();
        ((!) fixture).remove_account();
        ((!) fixture).persist_account();

        require(((!) fixture).account.id > 0,
            "removed test account did not receive a later positive id");
        require(!((!) fixture).store.is_persistence_ready,
            "removed account initialized its OMEMO store after a later id change");
        require(((!) fixture).store.local_registration_id == 0,
            "removed account exposed a registration id after a later id change");
        require(((!) fixture).identity_count() == 0,
            "removed account persisted an OMEMO identity after a later id change");
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private static void test_manager_store_rejects_invalid_persisted_identity()
        throws Error {
    ManagerStoreLifecycleFixture? fixture = null;
    try {
        fixture = new ManagerStoreLifecycleFixture("invalid-store");
        ((!) fixture).persist_account();
        ((!) fixture).insert_mismatched_identity();

        Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
            "*rejected an invalid persisted identity*");
        ((!) fixture).add_account();
        Test.assert_expected_messages();

        require(!((!) fixture).store.is_persistence_ready,
            "invalid persisted identity exposed a ready OMEMO store");
        require(((!) fixture).store.local_registration_id == 0,
            "invalid persisted identity exposed a registration id");
        require(((!) fixture).identity_count() == 1,
            "invalid persisted identity was silently replaced or duplicated");
    } finally {
        if (fixture != null) ((!) fixture).cleanup();
    }
}

private class RetainedStoreTestStream : Xmpp.XmppStream {
    internal RetainedStoreTestStream() throws Error {
        base(new Xmpp.Jid("example.test"));
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async Xmpp.StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("isolated store lifecycle test");
    }
    public override async void write_async(Xmpp.StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError { }
}

private static void test_store_readiness_replacement_scope() throws Error {
    var gate = new OmemoStoreReadinessGate();
    var context = new Context();
    var account = new Dino.Entities.Account(new Xmpp.Jid("first@example.test"), "test");
    var other = new Dino.Entities.Account(new Xmpp.Jid("other@example.test"), "test");
    var original = context.create_store();
    var unrelated = context.create_store();
    int changes = 0;
    gate.readiness_changed.connect((candidate) => {
        if (candidate == account) changes++;
    });
    gate.watch_store(account, original);
    gate.watch_store(other, unrelated);
    require(gate.is_ready(account) && gate.is_ready(other),
        "initial ready stores were not recognized");
    int before = changes;
    gate.watch_store(account, original);
    require(changes == before && original.is_persistence_ready,
        "watching the same store again invalidated it or duplicated callbacks");

    var replacement = context.create_store(false);
    gate.watch_store(account, replacement);
    require(changes == before && !gate.is_ready(account),
        "replacement is ready prematurely or notified during module construction");
    require(!original.is_persistence_ready && gate.is_ready(other),
        "replacement did not retire only its own account's store");
    replacement.mark_persistence_ready();
    require(gate.is_ready(account) && changes == before + 1,
        "replacement initialization did not restore readiness");
    gate.forget_account(account);
    require(!gate.is_ready(account) && gate.is_ready(other),
        "forgetting one account affected another account");
    before = changes;
    replacement.mark_persistence_unavailable();
    require(changes == before,
        "forgotten store still emits account readiness notifications");
}

private static void test_replaced_store_rejects_retained_operations()
        throws Error {
    ManagerStoreLifecycleFixture? fixture = null;
    PersistentPeer? remote = null;
    try {
        fixture = new ManagerStoreLifecycleFixture("replaced-store");
        var f = (!) fixture;
        f.persist_account();
        f.account.enabled = true;
        f.stream_interactor.connection_manager.intercept_connect_stream_for_tests();
        f.stream_interactor.connect_account(f.account);
        Store first_store = f.stream_interactor.module_manager
            .get_module<StreamModule>(f.account, StreamModule.IDENTITY).store;
        uint32 device_id = first_store.local_registration_id;
        uint8[] identity_key = first_store.identity_key_pair.public.serialize();
        new LegacyRegistrationGuard(f.omemo_db, f.account.id)
            .mark_published_checked((int32) device_id);
        first_store.registration_pending = false;

        Context ctx = Dino.Plugins.Omemo.Plugin.get_context();
        remote = new PersistentPeer(Path.build_filename(f.temp_dir, "remote.db"),
            "peer@example.test", 202, 2202, ctx);
        var bob = (!) remote;
        var bob_store = (!) bob.store;
        var address_a = new Address(f.account.bare_jid.to_string(), (int) device_id);
        var address_b = bob.address();
        PreKeyRecord prekey;
        throw_by_code(PreKeyRecord.create(out prekey, 31337,
            ctx.generate_key_pair()));
        bob_store.store_pre_key(prekey);
        SignedPreKeyRecord signed = ctx.generate_signed_pre_key(
            bob_store.identity_key_pair, 22);
        bob_store.store_signed_pre_key(signed);
        first_store.create_session_builder(address_b).process_pre_key_bundle(
            create_pre_key_bundle(bob.device_id, bob.device_id,
                31337, prekey.key_pair.public, 22, signed.key_pair.public,
                signed.signature, bob_store.identity_key_pair.public));
        SessionCipher retained_cipher = first_store.create_session_cipher(address_b);
        var hello = retained_cipher.encrypt("hello".data);
        bob_store.create_session_cipher(address_a).decrypt_pre_key_message(
            ctx.deserialize_signal_pre_key_message(hello.serialized));
        var ack = bob_store.create_session_cipher(address_a).encrypt("ack".data);
        retained_cipher.decrypt_message(ctx.deserialize_signal_message(ack.serialized));
        var ready = retained_cipher.encrypt("ready".data);
        bob_store.create_session_cipher(address_a).decrypt_message(
            ctx.deserialize_signal_message(ready.serialized));

        // Another enabled account uses the same application/OMEMO databases
        // and the same peer/device. Only the local identity separates rows.
        var second_account = new Dino.Entities.Account(
            new Xmpp.Jid("second-local@example.test"), "test");
        second_account.persist(f.dino_db);
        second_account.enabled = true;
        f.stream_interactor.connect_account(second_account);
        Store second = f.stream_interactor.module_manager
            .get_module<StreamModule>(second_account, StreamModule.IDENTITY).store;
        uint32 second_device_id = second.local_registration_id;
        new LegacyRegistrationGuard(f.omemo_db, second_account.id)
            .mark_published_checked((int32) second_device_id);
        second.registration_pending = false;
        var address_second = new Address(second_account.bare_jid.to_string(),
            (int) second_device_id);
        PreKeyRecord second_prekey;
        throw_by_code(PreKeyRecord.create(out second_prekey, 31338,
            ctx.generate_key_pair()));
        bob_store.store_pre_key(second_prekey);
        second.create_session_builder(address_b).process_pre_key_bundle(
            create_pre_key_bundle(bob.device_id, bob.device_id,
                31338, second_prekey.key_pair.public, 22, signed.key_pair.public,
                signed.signature, bob_store.identity_key_pair.public));
        var second_cipher = second.create_session_cipher(address_b);
        var second_hello = second_cipher.encrypt("other account".data);
        bob_store.create_session_cipher(address_second).decrypt_pre_key_message(
            ctx.deserialize_signal_pre_key_message(second_hello.serialized));
        var second_ack = bob_store.create_session_cipher(address_second).encrypt("ack".data);
        second_cipher.decrypt_message(ctx.deserialize_signal_message(second_ack.serialized));
        uint8[] second_before = second.session_store.load_session(address_b);
        int second_identity_id = f.omemo_db.identity.get_id_checked(second_account.id);
        require(second_identity_id != f.omemo_db.identity.get_id_checked(f.account.id),
            "different accounts share a persisted OMEMO identity row");
        var second_pending = bob_store.create_session_cipher(address_second)
            .encrypt("message for second account".data);

        var old_stream = new RetainedStoreTestStream();
        var trust = new TrustManager(f.stream_interactor, f.omemo_db);
        old_stream.add_module(new OmemoDecryptor(f.account, f.stream_interactor,
            trust, f.omemo_db, first_store));
        var jet = new Dino.Plugins.JetOmemo.Module();
        uint8[] before = first_store.session_store.load_session(address_b);
        SessionStore retained_sessions = first_store.session_store;

        // Use the same disable/re-enable service calls as PreferencesDialog.
        // Network establishment is intercepted; account and OMEMO setup are real.
        f.account.enabled = false;
        bool disconnected = false;
        f.stream_interactor.connection_manager.disconnect_account.begin(f.account,
            (_, result) => {
                f.stream_interactor.connection_manager.disconnect_account.end(result);
                disconnected = true;
            });
        while (!disconnected) MainContext.default().iteration(true);
        f.account.enabled = true;

        // connect_account initializes replacement protocol modules when an
        // account is re-enabled. A late Jingle callback may still own the old
        // stream, decryptor or native cipher. It must not advance a second
        // in-memory ratchet backed by the same database row.
        f.stream_interactor.connect_account(f.account);
        Store current = f.stream_interactor.module_manager
            .get_module<StreamModule>(f.account, StreamModule.IDENTITY).store;
        require(current != first_store, "fixture did not replace the account store");
        require(!first_store.is_persistence_ready,
            "replaced OMEMO store remains writable beside its replacement");
        require(current.is_persistence_ready, "replacement store is unavailable");
        require(current.local_registration_id == device_id,
            "replacing modules changed the device number");
        require_bytes_equal(identity_key, current.identity_key_pair.public.serialize(),
            "replacing modules changed the identity key");
        require_bytes_equal(before, current.session_store.load_session(address_b),
            "replacing modules changed the persisted session");

        bool rejected = false;
        try { retained_cipher.encrypt("obsolete send".data); }
        catch (Error e) { rejected = true; }
        require(rejected, "retained native cipher can still write the old store");
        rejected = false;
        try { retained_sessions.store_session(address_b, before); }
        catch (Error e) { rejected = true; }
        require(rejected, "retained backed session store can still overwrite state");

        var packet = bob_store.create_session_cipher(address_a)
            .encrypt("0123456789012345".data);
        var encoded = new Xmpp.Xep.Omemo.EncryptionData((uint32) bob.device_id);
        encoded.iv = new uint8[12];
        encoded.add_device_key((int) device_id, packet.serialized,
            packet.type == CiphertextType.PREKEY);
        var security = new Xmpp.StanzaNode.build("security", "urn:xmpp:jingle:jet:0")
            .put_node(encoded.get_encrypted_node());
        rejected = false;
        try {
            jet.decode_envolop(old_stream, f.account.bare_jid,
                new Xmpp.Jid(bob.jid), security);
        } catch (Xmpp.Xep.Jingle.IqError e) { rejected = true; }
        require(rejected, "late JET callback advanced the obsolete session");

        var current_stream = new RetainedStoreTestStream();
        current_stream.add_module(new OmemoDecryptor(f.account,
            f.stream_interactor, trust, f.omemo_db, current));
        var decoded = jet.decode_envolop(current_stream, f.account.bare_jid,
            new Xmpp.Jid(bob.jid), security);
        require_bytes_equal("0123456789012345".data, decoded.transport_key,
            "current JET decryptor could not decrypt the untouched packet");
        var reply = current.create_session_cipher(address_b).encrypt("reply".data);
        bob_store.create_session_cipher(address_a).decrypt_message(
            ctx.deserialize_signal_message(reply.serialized));
        var next = bob_store.create_session_cipher(address_a).encrypt("next chat".data);
        var plain = ctx.decrypt_signal_message(current, address_b,
            next.serialized, new SignalDecryptTrace());
        require_bytes_equal("next chat".data, plain,
            "chat decryption failed after current JET session advancement");

        require(second == f.stream_interactor.module_manager
                .get_module<StreamModule>(second_account, StreamModule.IDENTITY).store &&
            second.is_persistence_ready && second.local_registration_id == second_device_id,
            "toggling the first account replaced or invalidated the second account");
        require_bytes_equal(second_before, second.session_store.load_session(address_b),
            "first account traffic changed the other account's cached peer session");
        Row? second_row = f.omemo_db.session.select()
            .with(f.omemo_db.session.identity_id, "=", second_identity_id)
            .with(f.omemo_db.session.address_name, "=", bob.jid)
            .with(f.omemo_db.session.device_id, "=", bob.device_id)
            .single().iterator().get_next_checked();
        require(second_row != null, "other account's peer session was removed");
        require_bytes_equal(second_before,
            Base64.decode(((!) second_row)[f.omemo_db.session.record_base64]),
            "first account traffic changed the other account's persisted peer session");
        var second_plain = ctx.decrypt_signal_message(second, address_b,
            second_pending.serialized, new SignalDecryptTrace());
        require_bytes_equal("message for second account".data, second_plain,
            "second account could not receive its pending encrypted message");
        var second_reply = second_cipher.encrypt("second account reply".data);
        var second_received = bob_store.create_session_cipher(address_second)
            .decrypt_message(ctx.deserialize_signal_message(second_reply.serialized));
        require_bytes_equal("second account reply".data, second_received,
            "second account could not send after toggling the first account");
    } finally {
        if (remote != null) ((!) remote).close();
        if (fixture != null) {
            string remote_path = Path.build_filename(((!) fixture).temp_dir, "remote.db");
            FileUtils.remove(remote_path);
            FileUtils.remove(remote_path + "-wal");
            FileUtils.remove(remote_path + "-shm");
            ((!) fixture).cleanup();
        }
    }
}

private delegate void CheckedTest() throws Error;

private static void run_checked(CheckedTest test) {
    try {
        test();
    } catch (Error e) {
        Test.message("%s", e.message);
        Test.fail();
    }
}

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    if (args.length > 1 && args[1] == CRASH_CHILD_MODE) {
        return run_hard_exit_receiver_child(args);
    }
    if (args.length > 1 && args[1] == PREKEY_CRASH_CHILD_MODE) {
        return run_hard_exit_prekey_receiver_child(args);
    }
    test_program_path = args[0];
    Test.init(ref args);
    Test.set_nonfatal_assertions();
    Test.add_func("/LegacySessionPersistence/store_replacement_readiness_is_account_scoped",
        () => run_checked(test_store_readiness_replacement_scope));
    Test.add_func("/LegacySessionPersistence/replaced_account_store_rejects_retained_jet_and_cipher",
        () => run_checked(test_replaced_store_rejects_retained_operations));
    Test.add_func("/LegacySessionPersistence/unready_store_blocks_native_access",
        () => run_checked(test_unready_store_blocks_native_access));
    Test.add_func("/LegacySessionPersistence/identity_changing_prekey_preserves_all_state",
        () => run_checked(test_identity_changing_prekey_preserves_all_state));
    Test.add_func("/LegacySessionPersistence/identity_meta_failure_rolls_back_authenticated_prekey",
        () => run_checked(test_identity_meta_failure_rolls_back_authenticated_prekey));
    Test.add_func("/LegacySessionPersistence/sqlcipher_synchronous_full",
        () => run_checked(test_full_synchronous));
    Test.add_func("/LegacySessionPersistence/first_incoming_after_reopen",
        () => run_checked(test_first_incoming_after_reopen));
    Test.add_func("/LegacySessionPersistence/first_outgoing_after_reopen",
        () => run_checked(test_first_outgoing_after_reopen));
    Test.add_func("/LegacySessionPersistence/second_reopen_advances_ratchet",
        () => run_checked(test_second_reopen_advances_ratchet));
    Test.add_func("/LegacySessionPersistence/offline_queue_in_order_after_reopen",
        () => run_checked(test_offline_queue_in_order_after_reopen));
    Test.add_func("/LegacySessionPersistence/offline_queue_out_of_order_after_reopen",
        () => run_checked(test_offline_queue_out_of_order_after_reopen));
    Test.add_func("/LegacySessionPersistence/unconfirmed_prekey_queue_after_reopen",
        () => run_checked(test_unconfirmed_prekey_queue_after_reopen));
    Test.add_func("/LegacySessionPersistence/unconfirmed_prekey_queue_out_of_order_after_reopen",
        () => run_checked(test_unconfirmed_prekey_queue_out_of_order_after_reopen));
    Test.add_func("/LegacySessionPersistence/same_sender_prekey_to_signal_across_reopen",
        () => run_checked(test_same_sender_prekey_to_signal_across_reopen));
    Test.add_func("/LegacySessionPersistence/ratchet_commit_survives_hard_process_exit",
        () => run_checked(test_ratchet_commit_survives_hard_process_exit));
    Test.add_func("/LegacySessionPersistence/prekey_transaction_rolls_back_on_hard_process_exit",
        () => run_checked(test_prekey_transaction_rolls_back_on_hard_process_exit));
    Test.add_func("/LegacySessionPersistence/write_failure_is_fail_closed",
        () => run_checked(test_write_failure_is_fail_closed));
    Test.add_func("/LegacySessionPersistence/pre_key_update_failure_is_fail_closed",
        () => run_checked(test_pre_key_update_failure_is_fail_closed));
    Test.add_func("/LegacySessionPersistence/signed_pre_key_update_failure_is_fail_closed",
        () => run_checked(test_signed_pre_key_update_failure_is_fail_closed));
    Test.add_func("/LegacySessionPersistence/manager_store_waits_for_persisted_account",
        () => run_checked(test_manager_store_waits_for_persisted_account));
    Test.add_func("/LegacySessionPersistence/manager_store_initializes_once_after_persist",
        () => run_checked(test_manager_store_initializes_once_after_persist));
    Test.add_func("/LegacySessionPersistence/manager_store_removed_before_persist_stays_unavailable",
        () => run_checked(test_manager_store_removed_before_persist_stays_unavailable));
    Test.add_func("/LegacySessionPersistence/manager_store_rejects_invalid_persisted_identity",
        () => run_checked(test_manager_store_rejects_invalid_persisted_identity));
    return Test.run();
}

}
