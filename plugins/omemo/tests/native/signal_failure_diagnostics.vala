namespace Omemo.Test {

// These are native Signal v3 reproductions, not simulated error codes. Failed
// receive attempts must retain the byte-for-byte stored ratchet and must not
// turn a damaged packet into a reason to discard a working session.
class SignalFailureDiagnosticsTest : Gee.TestCase {
    private const string SECRET = "signal-diagnostic-private-plaintext-marker";

    internal SignalFailureDiagnosticsTest() {
        base("SignalFailureDiagnostics");
        add_test("bad_mac_is_1005_and_next_valid_message_preserves_session", test_bad_mac);
        add_test("restored_old_receiver_ratchet_rejects_new_session_messages", test_stale_receiver);
        add_test("unrelated_ratchet_for_same_address_is_1005", test_unrelated_receiver);
        add_test("real_counter_gap_over_2000_persists_until_receiver_catches_up", test_counter_gap);
        add_test("duplicate_and_missing_session_keep_distinct_error_codes", test_duplicate_and_missing);
        add_test("invalid_version_and_incomplete_message_are_parse_failures", test_parse_failures);
        add_test("uninitialized_and_wrong_version_sessions_are_distinguished", test_session_failures);
        add_test("diagnostics_do_not_leak_across_calls_or_native_contexts", test_diagnostic_isolation);
        add_test("native_log_text_is_reduced_to_fixed_labels", test_allowlist_injection);
        add_test("prekey_missing_signed_key_reports_actual_load", test_prekey_missing_signed_key);
        add_test("prekey_missing_one_time_key_reports_actual_load", test_prekey_missing_one_time_key);
        add_test("prekey_both_missing_reports_first_signed_key_load", test_prekey_both_missing);
        add_test("prekey_matching_session_does_not_reload_consumed_keys", test_prekey_matching_session);
        add_test("prekey_archived_session_does_not_reload_consumed_keys", test_prekey_archived_session);
        add_test("prekey_optional_one_time_id_is_absent_without_failure", test_prekey_optional_id);
        add_test("prekey_diagnostics_are_store_bound_and_reset_across_contexts", test_prekey_isolation);
    }

    private class Fixture : Object {
        internal Context context;
        internal Store alice;
        internal Store bob;
        internal Address alice_address;
        internal Address bob_address;
        internal string last_diagnostic = "none";

        internal Fixture() throws Error {
            context = new Context();
            alice = setup_test_store_context(context);
            bob = setup_test_store_context(context);
            alice.identity_key_store.local_registration_id = 11;
            bob.identity_key_store.local_registration_id = 22;
            alice_address = new Address("alice@example.test", 11);
            bob_address = new Address("bob@example.test", 22);
            establish(101);
        }

        internal void establish(int32 key_id) throws Error {
            ECKeyPair pre_key_pair = context.generate_key_pair();
            PreKeyRecord pre_key;
            throw_by_code(PreKeyRecord.create(out pre_key, key_id, pre_key_pair));
            bob.store_pre_key(pre_key);
            IdentityKeyPair identity = bob.identity_key_pair;
            SignedPreKeyRecord signed_key = context.generate_signed_pre_key(identity, key_id + 1);
            bob.store_signed_pre_key(signed_key);
            ECKeyPair signed_pair = signed_key.key_pair;
            PreKeyBundle bundle = create_pre_key_bundle(22, 22, key_id,
                    pre_key_pair.public, key_id + 1, signed_pair.public,
                    signed_key.signature, identity.public);
            SessionBuilder builder = alice.create_session_builder(bob_address);
            builder.process_pre_key_bundle(bundle);
            SessionCipher alice_cipher = alice.create_session_cipher(bob_address);
            CiphertextMessage first = alice_cipher.encrypt("initial handshake".data);
            SessionCipher bob_cipher = bob.create_session_cipher(alice_address);
            bob_cipher.decrypt_pre_key_message(context.deserialize_signal_pre_key_message(first.serialized));
            CiphertextMessage ack = bob_cipher.encrypt("handshake acknowledged".data);
            alice_cipher.decrypt_message(context.deserialize_signal_message(ack.serialized));
        }

        internal uint8[] send(string plaintext = SECRET) throws Error {
            SessionCipher cipher = alice.create_session_cipher(bob_address);
            CiphertextMessage message = cipher.encrypt(plaintext.data);
            if (message.type != CiphertextType.SIGNAL) {
                throw new IOError.FAILED("Diagnostic fixture requires an established Signal session");
            }
            return copy_bytes(message.serialized);
        }

        internal uint8[] receive(uint8[] packet, out string diagnostic) throws Error {
            var trace = new SignalDecryptTrace();
            diagnostic = "none";
            last_diagnostic = "none";
            try {
                uint8[] plaintext = context.decrypt_signal_message(bob, alice_address, packet, trace);
                diagnostic = trace.describe();
                return plaintext;
            } catch (Error e) {
                // Vala does not copy out parameters back to a caller when a
                // method throws. Retain the trace in fixture state instead.
                last_diagnostic = trace.describe();
                throw e;
            }
        }

        internal uint8[] snapshot() throws Error {
            uint8[]? stored = bob.session_store.load_session(alice_address);
            if (stored == null) throw new IOError.FAILED("Diagnostic fixture has no receiver session");
            return copy_bytes((!) stored);
        }

        internal void restore(uint8[] snapshot) throws Error {
            bob.session_store.store_session(alice_address, snapshot);
        }
    }

    private static uint8[] copy_bytes(uint8[] input) {
        uint8[] result = new uint8[input.length];
        Memory.copy(result, input, input.length);
        return result;
    }

    private static uint8[] corrupt_mac(uint8[] packet) {
        uint8[] damaged = copy_bytes(packet);
        // Signal v3 appends an eight-byte MAC after its protobuf payload.
        // Changing its last byte keeps the message version/counter parsable.
        damaged[damaged.length - 1] ^= 1;
        return damaged;
    }

    private void assert_private_allowlisted_diagnostic(string diagnostic, Fixture fixture, uint8[] packet) {
        fail_if(diagnostic.contains(SECRET), "diagnostic must not contain the decrypted plaintext");
        fail_if(diagnostic.contains(fixture.alice_address.name), "diagnostic must not include peer identifiers from native logs");
        fail_if(diagnostic.contains(Base64.encode(packet)), "diagnostic must not contain the serialized packet");
        fail_if(diagnostic.contains(Base64.encode(fixture.alice.identity_key_store.identity_key_private.get_data())),
                "diagnostic must not contain a private identity key");
        fail_if(diagnostic.contains(Base64.encode(fixture.bob.identity_key_store.identity_key_public.get_data())),
                "diagnostic must not contain public key material");
        if (diagnostic == "none") return;
        try {
            string reasons = "(unclassified|mac-mismatch|counter-gap|uninitialized-session|session-version-mismatch|" +
                    "invalid-message-version|incomplete-message|no-valid-session|missing-message-body|" +
                    "legacy-message-version|old-counter|no-session|mac-check-error)";
            var allowed = new Regex("^(stage=(signal-parse|session-create|signal-decrypt)|" +
                    "reasons=" + reasons + "(," + reasons + ")*|" +
                    "signal_version=(-1|[0-9]+)|counter=(-1|[0-9]+))$");
            foreach (string field in diagnostic.replace(";", " ").split(" ")) {
                if (field.length > 0) fail_if_not(allowed.match(field), "diagnostic fields must be explicitly allowlisted");
            }
        } catch (RegexError e) { fail_if_reached(e.message); }
    }

    private string expect_failure(Fixture fixture, uint8[] packet, ErrorCode code,
            string stage, string? reason = null, bool parsed = true) {
        string diagnostic = "";
        bool failed = false;
        try {
            fixture.receive(packet, out diagnostic);
        } catch (Error e) {
            failed = true;
            diagnostic = fixture.last_diagnostic;
            fail_if_not_eq_int(e.code, code, "diagnostic wrapper must preserve the native error code");
        }
        fail_if_not(failed, "the native reproduction must actually fail");
        fail_if_not(diagnostic.contains("stage=" + stage), "diagnostic must identify the failing parse/decrypt stage");
        if (reason != null) fail_if_not(diagnostic.contains((!) reason), "diagnostic must contain the native failure reason");
        if (parsed) {
            try {
                OmemoMessage message = fixture.context.deserialize_signal_message(packet);
                fail_if_not(diagnostic.contains("signal_version=" + message.message_version.to_string()));
                fail_if_not(diagnostic.contains("counter=" + message.counter.to_string()));
            } catch (Error e) { fail_if_reached(e.message); }
        }
        assert_private_allowlisted_diagnostic(diagnostic, fixture, packet);
        return diagnostic;
    }

    private void assert_unchanged(Fixture fixture, uint8[] before) throws Error {
        fail_if_not_eq_uint8_arr(before, fixture.snapshot(), "failed native decrypt must not persist a changed receiver ratchet");
    }

    private void test_bad_mac() {
        try {
            var fixture = new Fixture();
            uint8[] first = fixture.send();
            uint8[] second = fixture.send("second valid message");
            uint8[] before = fixture.snapshot();
            string failure = expect_failure(fixture, corrupt_mac(first), ErrorCode.INVALID_MESSAGE,
                    "signal-decrypt", "mac-mismatch");
            fail_if_not(failure.contains("no-valid-session"));
            assert_unchanged(fixture, before);
            string diagnostic;
            fail_if_not_eq_uint8_arr("second valid message".data, fixture.receive(second, out diagnostic),
                    "a damaged first packet must not prevent decrypting the next valid packet");
            fail_if(diagnostic.contains("mac-mismatch"), "the next success must not inherit the preceding error reason");
            // The skipped key for the original undamaged first message remains
            // available, proving that the failed attempt did not consume it.
            fail_if_not_eq_uint8_arr(SECRET.data, fixture.receive(first, out diagnostic));
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_stale_receiver() {
        try {
            var fixture = new Fixture();
            uint8[] old_receiver = fixture.snapshot();
            // Simulate a new valid session followed by restoring an older
            // receiver backup. Device IDs and identity keys remain identical.
            fixture.alice.delete_session(fixture.bob_address);
            fixture.bob.delete_session(fixture.alice_address);
            fixture.establish(201);
            uint8[] current_receiver = fixture.snapshot();
            uint8[] first = fixture.send();
            uint8[] second = fixture.send("next message on current session");
            fixture.restore(old_receiver);
            expect_failure(fixture, first, ErrorCode.INVALID_MESSAGE, "signal-decrypt", "mac-mismatch");
            assert_unchanged(fixture, old_receiver);
            expect_failure(fixture, second, ErrorCode.INVALID_MESSAGE, "signal-decrypt", "mac-mismatch");
            assert_unchanged(fixture, old_receiver);
            fixture.restore(current_receiver);
            string diagnostic;
            fail_if_not_eq_uint8_arr(SECRET.data, fixture.receive(first, out diagnostic),
                    "restoring the matching receiver state must recover the unchanged packet");
            fail_if_not_eq_uint8_arr("next message on current session".data, fixture.receive(second, out diagnostic));
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_unrelated_receiver() {
        try {
            var fixture = new Fixture();
            var unrelated = new Fixture();
            uint8[] matching = fixture.snapshot();
            uint8[] unrelated_record = unrelated.snapshot();
            uint8[] packet = fixture.send();
            fixture.restore(unrelated_record);
            expect_failure(fixture, packet, ErrorCode.INVALID_MESSAGE, "signal-decrypt", "mac-mismatch");
            assert_unchanged(fixture, unrelated_record);
            fixture.restore(matching);
            string diagnostic;
            fail_if_not_eq_uint8_arr(SECRET.data, fixture.receive(packet, out diagnostic));
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_counter_gap() {
        try {
            var fixture = new Fixture();
            uint8[] first = fixture.send("first missing message");
            OmemoMessage parsed_first = fixture.context.deserialize_signal_message(first);
            fail_if_not_eq_int((int) parsed_first.counter, 0, "fixture must start a fresh sending chain");
            uint8[] far = {};
            // These are genuine correctly authenticated messages. Keep only
            // the first and the two beyond libomemo-c's skipped-key limit.
            for (int counter = 1; counter <= 2001; counter++) far = fixture.send();
            uint8[] next = fixture.send("message after oversized gap");
            OmemoMessage parsed_far = fixture.context.deserialize_signal_message(far);
            fail_if_not_eq_int((int) parsed_far.counter, 2001);
            uint8[] before = fixture.snapshot();
            string diagnostic = expect_failure(fixture, far, ErrorCode.INVALID_MESSAGE, "signal-decrypt", "counter-gap");
            fail_if(diagnostic.contains("mac-mismatch"), "the counter limit is checked before MAC verification");
            assert_unchanged(fixture, before);
            expect_failure(fixture, next, ErrorCode.INVALID_MESSAGE, "signal-decrypt", "counter-gap");
            assert_unchanged(fixture, before);
            // Delivering the authentic first packet moves the gap to exactly
            // 2000. Both previously failing messages then decrypt unchanged.
            fail_if_not_eq_uint8_arr("first missing message".data, fixture.receive(first, out diagnostic));
            fail_if_not_eq_uint8_arr(SECRET.data, fixture.receive(far, out diagnostic));
            fail_if_not_eq_uint8_arr("message after oversized gap".data, fixture.receive(next, out diagnostic));
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_duplicate_and_missing() {
        try {
            var fixture = new Fixture();
            uint8[] packet = fixture.send();
            string diagnostic;
            fixture.receive(packet, out diagnostic);
            uint8[] before = fixture.snapshot();
            diagnostic = expect_failure(fixture, packet, ErrorCode.DUPLICATE_MESSAGE, "signal-decrypt");
            fail_if(diagnostic.contains("mac-mismatch") || diagnostic.contains("counter-gap"));
            assert_unchanged(fixture, before);
            fixture.bob.delete_session(fixture.alice_address);
            diagnostic = expect_failure(fixture, packet, ErrorCode.NO_SESSION, "signal-decrypt");
            fail_if(diagnostic.contains("mac-mismatch") || diagnostic.contains("no-valid-session"),
                    "an absent session must remain distinct from exhausted incompatible sessions");
            fail_if(fixture.bob.contains_session(fixture.alice_address), "diagnosis must not create a missing session");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_parse_failures() {
        try {
            var fixture = new Fixture();
            uint8[] before = fixture.snapshot();
            uint8[] future_version = fixture.send();
            future_version[0] = 0xf3;
            expect_failure(fixture, future_version, ErrorCode.INVALID_MESSAGE, "signal-parse", "invalid-message-version", false);
            assert_unchanged(fixture, before);
            // Valid protobuf containing only counter=0, followed by eight MAC
            // bytes: deserialization reports missing ratchet key/ciphertext.
            uint8[] incomplete = { 0x33, 0x10, 0x00, 0, 0, 0, 0, 0, 0, 0, 0 };
            expect_failure(fixture, incomplete, ErrorCode.INVALID_MESSAGE, "signal-parse", "incomplete-message", false);
            assert_unchanged(fixture, before);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_session_failures() {
        try {
            var fixture = new Fixture();
            uint8[] packet = fixture.send();
            uint8[] matching = fixture.snapshot();
            SessionRecord wrong_version = fixture.bob.load_session(fixture.alice_address);
            SessionState state = wrong_version.state;
            state.session_version = 4;
            throw_by_code(Protocol.Session.store_session(fixture.bob.native_context, fixture.alice_address, wrong_version));
            uint8[] changed = fixture.snapshot();
            expect_failure(fixture, packet, ErrorCode.INVALID_MESSAGE, "signal-decrypt", "session-version-mismatch");
            assert_unchanged(fixture, changed);
            fixture.bob.delete_session(fixture.alice_address);
            SessionRecord empty = fixture.bob.load_session(fixture.alice_address);
            throw_by_code(Protocol.Session.store_session(fixture.bob.native_context, fixture.alice_address, empty));
            uint8[] empty_snapshot = fixture.snapshot();
            expect_failure(fixture, packet, ErrorCode.INVALID_MESSAGE, "signal-decrypt", "uninitialized-session");
            assert_unchanged(fixture, empty_snapshot);
            fixture.restore(matching);
            string diagnostic;
            fail_if_not_eq_uint8_arr(SECRET.data, fixture.receive(packet, out diagnostic));
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_diagnostic_isolation() {
        try {
            var first = new Fixture();
            var second = new Fixture();
            uint8[] packet = first.send();
            expect_failure(first, corrupt_mac(packet), ErrorCode.INVALID_MESSAGE, "signal-decrypt", "mac-mismatch");
            uint8[] other_packet = second.send();
            uint8[] future_version = copy_bytes(other_packet);
            future_version[0] = 0xf3;
            string diagnostic = expect_failure(second, future_version, ErrorCode.INVALID_MESSAGE,
                    "signal-parse", "invalid-message-version", false);
            fail_if(diagnostic.contains("mac-mismatch") || diagnostic.contains("no-valid-session"),
                    "another native context must not inherit the first context's failure");
            // Native logging outside the wrapper must not seed a later call.
            try {
                first.bob.create_session_cipher(first.alice_address).decrypt_message(
                        first.context.deserialize_signal_message(corrupt_mac(packet)));
            } catch (Error e) { fail_if_not_eq_int(e.code, ErrorCode.INVALID_MESSAGE); }
            fail_if_not_eq_uint8_arr(SECRET.data, first.receive(packet, out diagnostic));
            fail_if(diagnostic.contains("mac-mismatch") || diagnostic.contains("invalid-message-version") ||
                    diagnostic.contains("no-valid-session"), "success must not reuse earlier or out-of-scope reasons");
            assert_private_allowlisted_diagnostic(diagnostic, first, packet);
            fail_if_not_eq_uint8_arr(SECRET.data, second.receive(other_packet, out diagnostic));
            fail_if(diagnostic.contains("mac-mismatch") || diagnostic.contains("invalid-message-version"));
            assert_private_allowlisted_diagnostic(diagnostic, second, other_packet);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_allowlist_injection() {
        try {
            var fixture = new Fixture();
            uint8[] packet = fixture.send();
            var trace = new SignalDecryptTrace();
            trace.observe("Unknown version: " + SECRET);
            trace.observe("No session for: " + fixture.alice_address.name + ":11");
            trace.observe("unrecognized native output " + Base64.encode(packet));
            trace.observe("Bad MAC");
            trace.observe("Bad MAC");
            string diagnostic = trace.describe();
            fail_if_not(diagnostic.contains("invalid-message-version"));
            fail_if_not(diagnostic.contains("no-session"));
            fail_if_not(diagnostic.contains("mac-mismatch"));
            fail_if(diagnostic.contains("mac-mismatch,mac-mismatch"), "repeated native notices must be coalesced");
            assert_private_allowlisted_diagnostic(diagnostic, fixture, packet);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private class PreKeyFixture : Object {
        internal Context context;
        internal Store alice;
        internal Store bob;
        internal Address alice_address;
        internal Address bob_address;

        internal PreKeyFixture(Context? shared_context = null) throws Error {
            context = shared_context ?? new Context();
            alice = setup_test_store_context(context);
            bob = setup_test_store_context(context);
            alice.identity_key_store.local_registration_id = 11;
            bob.identity_key_store.local_registration_id = 22;
            alice_address = new Address("alice-prekey@example.test", 11);
            bob_address = new Address("bob-prekey@example.test", 22);
        }

        internal void build(int32 key_id = 101, bool one_time_key = true)
                throws Error {
            ECKeyPair pre_key_pair = context.generate_key_pair();
            if (one_time_key) {
                PreKeyRecord pre_key;
                throw_by_code(PreKeyRecord.create(out pre_key, key_id,
                        pre_key_pair));
                bob.store_pre_key(pre_key);
            }
            SignedPreKeyRecord signed_key = context.generate_signed_pre_key(
                    bob.identity_key_pair, key_id + 1);
            bob.store_signed_pre_key(signed_key);
            alice.create_session_builder(bob_address).process_pre_key_bundle(
                    create_pre_key_bundle(22, 22, key_id,
                        one_time_key ? pre_key_pair.public : null, key_id + 1,
                        signed_key.key_pair.public, signed_key.signature,
                        bob.identity_key_pair.public));
        }

        internal uint8[] send(string plaintext = SECRET) throws Error {
            CiphertextMessage message = alice.create_session_cipher(bob_address)
                    .encrypt(plaintext.data);
            if (message.type != CiphertextType.PREKEY) {
                throw new IOError.FAILED("Fixture requires an unacknowledged PREKEY session");
            }
            return copy_bytes(message.serialized);
        }

        internal uint8[] receive(uint8[] packet, PreKeyDecryptTrace trace)
                throws Error {
            return context.decrypt_pre_key_message(bob, alice_address,
                    context.deserialize_signal_pre_key_message(packet), trace);
        }
    }

    private void assert_private_prekey_diagnostic(string diagnostic,
            PreKeyFixture fixture, uint8[] packet) throws Error {
        fail_if(diagnostic.contains(SECRET));
        fail_if(diagnostic.contains(fixture.alice_address.name));
        fail_if(diagnostic.contains(fixture.bob_address.name));
        fail_if(diagnostic.contains(Base64.encode(packet)));
        foreach (Store store in new Store[]{fixture.alice, fixture.bob}) {
            fail_if(diagnostic.contains(Base64.encode(
                    store.identity_key_store.identity_key_private.get_data())));
            fail_if(diagnostic.contains(Base64.encode(
                    store.identity_key_store.identity_key_public.get_data())));
        }
        PreKeyOmemoMessage message = fixture.context
                .deserialize_signal_pre_key_message(packet);
        fail_if(diagnostic.contains(Base64.encode(message.base_key.serialize())));
        fail_if(diagnostic.contains(Base64.encode(message.identity_key.serialize())));
        if (message.has_pre_key_id()) {
            uint8[]? record = fixture.bob.pre_key_store.load_pre_key(message.pre_key_id);
            if (record != null) fail_if(diagnostic.contains(Base64.encode((!) record)));
        }
        uint8[]? signed_record = fixture.bob.signed_pre_key_store
                .load_signed_pre_key(message.signed_pre_key_id);
        if (signed_record != null) fail_if(diagnostic.contains(Base64.encode((!) signed_record)));
        var allowed = new Regex("^(stage=(prekey-session-create|prekey-decrypt)|" +
                "reason=(unclassified|own-signed-prekey-missing|own-one-time-prekey-missing)|" +
                "has_prekey_id=(true|false)|" +
                "(prekey_id|signed_prekey_id|missing_key_id)=(-1|[0-9]+))$");
        foreach (string field in diagnostic.split(";")) {
            fail_if_not(allowed.match(field), "PREKEY diagnostics must contain only allowlisted fields");
        }
    }

    private void assert_optional_bytes_equal(uint8[]? before, uint8[]? after,
            string label) {
        if (before == null) {
            fail_if(after != null, label + " must remain absent");
        } else if (!fail_if(after == null, label + " must remain present")) {
            fail_if_not_eq_uint8_arr((!) before, (!) after,
                    label + " must remain byte-for-byte unchanged");
        }
    }

    private void run_missing_prekey(bool missing_signed, bool missing_one_time) {
        try {
            var fixture = new PreKeyFixture();
            fixture.build(51);
            fixture.receive(fixture.send("prior authenticated session"),
                    new PreKeyDecryptTrace());
            fixture.build();
            uint8[] packet = fixture.send();
            if (missing_signed) fixture.bob.signed_pre_key_store.delete_signed_pre_key(102);
            if (missing_one_time) fixture.bob.pre_key_store.delete_pre_key(101);
            uint8[]? session_before = fixture.bob.session_store.load_session(fixture.alice_address);
            uint8[]? pre_key_before = fixture.bob.pre_key_store.load_pre_key(101);
            uint8[]? signed_key_before = fixture.bob.signed_pre_key_store.load_signed_pre_key(102);
            uint8[]? identity_before = fixture.bob.identity_key_store.load_identity(fixture.alice_address);
            var trace = new PreKeyDecryptTrace();
            bool failed = false;
            try {
                fixture.receive(packet, trace);
            } catch (Error e) {
                failed = true;
                fail_if_not_eq_int(e.code, ErrorCode.INVALID_KEY_ID,
                        "actual native missing-key error must remain -1003");
            }
            fail_if_not(failed, "real native PREKEY must fail without a required private key");
            string diagnostic = trace.describe();
            string reason = missing_signed ? "own-signed-prekey-missing"
                    : "own-one-time-prekey-missing";
            fail_if_not(diagnostic.contains("stage=prekey-decrypt;reason=" + reason + ";"));
            fail_if_not(diagnostic.contains("has_prekey_id=true;prekey_id=101;signed_prekey_id=102;"));
            fail_if_not(diagnostic.has_suffix("missing_key_id=" + (missing_signed ? "102" : "101")));
            assert_private_prekey_diagnostic(diagnostic, fixture, packet);
            GLib.Test.message("PREKEY native failure detail: %s", diagnostic);
            assert_optional_bytes_equal(session_before,
                    fixture.bob.session_store.load_session(fixture.alice_address), "session");
            assert_optional_bytes_equal(pre_key_before,
                    fixture.bob.pre_key_store.load_pre_key(101), "one-time key");
            assert_optional_bytes_equal(signed_key_before,
                    fixture.bob.signed_pre_key_store.load_signed_pre_key(102), "signed key");
            assert_optional_bytes_equal(identity_before,
                    fixture.bob.identity_key_store.load_identity(fixture.alice_address), "remote identity");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_prekey_missing_signed_key() { run_missing_prekey(true, false); }
    private void test_prekey_missing_one_time_key() { run_missing_prekey(false, true); }
    private void test_prekey_both_missing() { run_missing_prekey(true, true); }

    private void run_matching_prekey_session(bool archive) {
        try {
            var fixture = new PreKeyFixture();
            fixture.build();
            uint8[] first = fixture.send("initial PREKEY");
            uint8[] second = fixture.send();
            var trace = new PreKeyDecryptTrace();
            fail_if_not_eq_uint8_arr("initial PREKEY".data, fixture.receive(first, trace));
            fail_if(fixture.bob.contains_pre_key(101), "first authenticated packet must consume its one-time key");
            if (archive) {
                fixture.build(201);
                fail_if_not_eq_uint8_arr("new session".data,
                        fixture.receive(fixture.send("new session"), trace));
            }
            // Matching current/archived states bypass BOTH native key loads.
            fixture.bob.signed_pre_key_store.delete_signed_pre_key(102);
            fail_if_not_eq_uint8_arr(SECRET.data, fixture.receive(second, trace));
            string diagnostic = trace.describe();
            fail_if_not(diagnostic.contains("reason=unclassified;"));
            fail_if_not(diagnostic.has_suffix("missing_key_id=-1"));
            assert_private_prekey_diagnostic(diagnostic, fixture, second);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_prekey_matching_session() { run_matching_prekey_session(false); }
    private void test_prekey_archived_session() { run_matching_prekey_session(true); }

    private void test_prekey_optional_id() {
        try {
            var fixture = new PreKeyFixture();
            fixture.build(101, false);
            uint8[] packet = fixture.send();
            var trace = new PreKeyDecryptTrace();
            fail_if_not_eq_uint8_arr(SECRET.data, fixture.receive(packet, trace));
            fail_if_not(trace.describe().contains("reason=unclassified;has_prekey_id=false;prekey_id=-1;signed_prekey_id=102;missing_key_id=-1"));
            assert_private_prekey_diagnostic(trace.describe(), fixture, packet);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private class ProbingSignedPreKeyStore : SimpleSignedPreKeyStore {
        internal Store other_store;
        internal int probes = 0;

        internal ProbingSignedPreKeyStore(Store other_store) {
            this.other_store = other_store;
        }

        public override uint8[]? load_signed_pre_key(uint32 key_id) throws Error {
            try {
                other_store.load_pre_key(987654);
                throw new IOError.FAILED("Foreign store probe must miss its one-time key");
            } catch (Error e) {
                if (e.code != ErrorCode.INVALID_KEY_ID) throw e;
                probes++;
            }
            return base.load_signed_pre_key(key_id);
        }
    }

    private void test_prekey_isolation() {
        try {
            var first = new PreKeyFixture();
            var second = new PreKeyFixture(first.context);
            var third = new PreKeyFixture();
            first.build();
            second.build(201);
            third.build(301);
            uint8[] packet = first.send();
            uint8[] second_packet = second.send();
            uint8[] third_packet = third.send();
            var trace = new PreKeyDecryptTrace();
            first.bob.pre_key_store.delete_pre_key(101);
            try {
                first.receive(packet, trace);
                fail_if_reached("missing one-time key must fail");
            } catch (Error e) { fail_if_not_eq_int(e.code, ErrorCode.INVALID_KEY_ID); }
            fail_if_not(trace.describe().contains("reason=own-one-time-prekey-missing;"));
            string retained_failure = trace.describe();

            // A real native callback on another store runs while the wrapper
            // is active. It must not contaminate this successful operation.
            var probing = new ProbingSignedPreKeyStore(first.bob);
            probing.store_signed_pre_key(202,
                    second.bob.signed_pre_key_store.load_signed_pre_key(202));
            second.bob.signed_pre_key_store = probing;
            var second_trace = new PreKeyDecryptTrace();
            fail_if_not_eq_uint8_arr(SECRET.data, second.receive(second_packet, second_trace));
            fail_if_not(probing.probes > 0);
            fail_if(second_trace.describe().contains("own-one-time-prekey-missing"));
            fail_if_not_eq_str(retained_failure, trace.describe(), "caller-owned failure must survive other stores");
            assert_private_prekey_diagnostic(second_trace.describe(), second, second_packet);

            // Calls after success/failure, outside the wrapper and on another
            // context must not retain or inject a reason, even with trace reuse.
            string retained_success = second_trace.describe();
            try { second.bob.load_pre_key(456789); }
            catch (Error e) { fail_if_not_eq_int(e.code, ErrorCode.INVALID_KEY_ID); }
            fail_if_not_eq_str(retained_success, second_trace.describe(),
                    "native lookup outside the successful wrapper must not change its trace");
            try { first.bob.load_pre_key(456789); }
            catch (Error e) { fail_if_not_eq_int(e.code, ErrorCode.INVALID_KEY_ID); }
            fail_if_not_eq_uint8_arr(SECRET.data, third.receive(third_packet, trace));
            fail_if_not(trace.describe().contains("reason=unclassified;"));
            fail_if_not(trace.describe().contains("prekey_id=301;signed_prekey_id=302;missing_key_id=-1"));
            assert_private_prekey_diagnostic(trace.describe(), third, third_packet);
            fail_if_not_eq_uint8_arr(SECRET.data, second.receive(second.send(), second_trace));
            fail_if(second_trace.describe().contains("missing_key_id=987654"));
        } catch (Error e) { fail_if_reached(e.message); }
    }
}

}
