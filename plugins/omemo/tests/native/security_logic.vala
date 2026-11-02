using Dino.Plugins.Omemo;
using Dino.Entities;
using Xmpp;

/**
 * Security Logic Tests -- Tier 3 Security Audit
 *
 * Tests for three security-critical decision functions:
 *
 * 1. classify_prekey_update() -- Identity key change detection (Bug #19)
 *    CWE-295/322: Key change accepted without user confirmation
 *
 * 2. is_encrypt_result_safe_to_send() -- Encrypt error body validation
 *    CWE-311/319: Plaintext leak on encryption failure
 *
 * 3. classify_decrypt_failure_stage() -- Ratchet advance detection
 *    CWE-755: Inconsistent state on partial failure
 */

namespace Omemo.Test {

/* ================================================================
 * Suite 1: PreKeyUpdateClassifier (6 tests)
 * Target: classify_prekey_update() from update_db_for_prekey()
 * ================================================================ */
class PreKeyUpdateClassifierTest : Gee.TestCase {
    public PreKeyUpdateClassifierTest() {
        base("PreKeyUpdateClassifier");

        add_test("SEC_prekey_new_device", test_new_device);
        add_test("SEC_prekey_new_device_null_key", test_new_device_null_key);
        add_test("SEC_prekey_same_key_no_change", test_same_key_no_change);
        add_test("SEC_prekey_key_changed", test_key_changed);
        add_test("SEC_prekey_key_changed_is_not_no_change", test_key_changed_not_no_change);
        add_test("SEC_prekey_empty_vs_populated", test_empty_vs_populated);
    }

    /* New device (device_exists=false) → INSERT_NEW regardless of keys */
    void test_new_device() {
        var action = classify_prekey_update(null, "AAAA", false);
        fail_if_not(action == PreKeyUpdateAction.INSERT_NEW,
            "new device should be INSERT_NEW");
    }

    /* Device exists but stored key is null → INSERT_NEW (first key learn) */
    void test_new_device_null_key() {
        var action = classify_prekey_update(null, "BBBB", true);
        fail_if_not(action == PreKeyUpdateAction.INSERT_NEW,
            "existing device with null key should be INSERT_NEW");
    }

    /* Device exists, same key → NO_CHANGE */
    void test_same_key_no_change() {
        string key = "AAAABBBBCCCCDDDDEEEE";
        var action = classify_prekey_update(key, key, true);
        fail_if_not(action == PreKeyUpdateAction.NO_CHANGE,
            "same key should be NO_CHANGE");
    }

    /* Device exists, different key → KEY_CHANGED (Bug #19: accepted silently) */
    void test_key_changed() {
        var action = classify_prekey_update("OLD_KEY_BASE64", "NEW_KEY_BASE64", true);
        fail_if_not(action == PreKeyUpdateAction.KEY_CHANGED,
            "different key should be KEY_CHANGED");
    }

    /* KEY_CHANGED must NOT be classified as NO_CHANGE (regression guard) */
    void test_key_changed_not_no_change() {
        var action = classify_prekey_update("KEY_A", "KEY_B", true);
        fail_if(action == PreKeyUpdateAction.NO_CHANGE,
            "changed key must not be NO_CHANGE");
    }

    /* Empty string key vs populated key → KEY_CHANGED */
    void test_empty_vs_populated() {
        var action = classify_prekey_update("", "REAL_KEY", true);
        fail_if_not(action == PreKeyUpdateAction.KEY_CHANGED,
            "empty existing key vs real key should be KEY_CHANGED");
    }
}


/* ================================================================
 * Suite 2: EncryptSafetyCheck (8 tests)
 * Target: is_encrypt_result_safe_to_send() from encrypt()
 * ================================================================ */
class EncryptSafetyCheckTest : Gee.TestCase {
    public EncryptSafetyCheckTest() {
        base("EncryptSafetyCheck");

        add_test("SEC_encrypt_success_safe_to_send", test_success_safe);
        add_test("SEC_encrypt_failure_must_not_send", test_failure_not_safe);
        add_test("SEC_encrypt_null_body_not_safe", test_null_body);
        add_test("SEC_encrypt_plaintext_leak_detected", test_plaintext_leak);
        add_test("SEC_encrypt_error_body_not_safe", test_error_body);
        add_test("SEC_encrypt_success_null_original_ok", test_null_original);
        add_test("SEC_encrypt_false_with_marker_not_safe", test_false_with_marker);
        add_test("SEC_encrypt_true_with_error_body_not_safe", test_true_error_body);
    }

    /* encrypted=true, correct marker body → safe */
    void test_success_safe() {
        bool safe = is_encrypt_result_safe_to_send(
            true, "[This message is OMEMO encrypted]", "Hello secret!");
        fail_if_not(safe, "successful encryption should be safe to send");
    }

    /* encrypted=false → never safe, regardless of body */
    void test_failure_not_safe() {
        bool safe = is_encrypt_result_safe_to_send(
            false, "[OMEMO encryption failed]", "Hello secret!");
        fail_if(safe, "failed encryption must not be sent");
    }

    /* encrypted=true but body is null → not safe */
    void test_null_body() {
        bool safe = is_encrypt_result_safe_to_send(
            true, null, "Hello secret!");
        fail_if(safe, "null body should not be safe");
    }

    /* encrypted=true but body == original plaintext → CATASTROPHIC LEAK */
    void test_plaintext_leak() {
        string secret = "Transfer $50000 to account 12345";
        bool safe = is_encrypt_result_safe_to_send(true, secret, secret);
        fail_if(safe, "body == original plaintext is a catastrophic leak");
    }

    /* Body is the error string "[OMEMO encryption failed]" → not safe */
    void test_error_body() {
        bool safe = is_encrypt_result_safe_to_send(
            true, "[OMEMO encryption failed]", "secret");
        fail_if(safe, "error body should not be safe even if encrypted=true");
    }

    /* encrypted=true, marker body, original_body=null → safe (empty message) */
    void test_null_original() {
        bool safe = is_encrypt_result_safe_to_send(
            true, "[This message is OMEMO encrypted]", null);
        fail_if_not(safe, "null original body with marker should be safe");
    }

    /* encrypted=false but body is the correct marker → still not safe */
    void test_false_with_marker() {
        bool safe = is_encrypt_result_safe_to_send(
            false, "[This message is OMEMO encrypted]", "secret");
        fail_if(safe, "encrypted=false must not send even with marker body");
    }

    /* encrypted=true but body is error string → inconsistent state, not safe */
    void test_true_error_body() {
        bool safe = is_encrypt_result_safe_to_send(
            true, "[OMEMO encryption failed]", "secret");
        fail_if(safe, "error body with encrypted=true is inconsistent — not safe");
    }
}


/* ================================================================
 * Suite 3: DecryptFailureStageTest (12 tests)
 * Target: classify_decrypt_failure_stage() from decrypt_key_raw/decrypt_envelope
 * ================================================================ */
class DecryptFailureStageTest : Gee.TestCase {
    public DecryptFailureStageTest() {
        base("DecryptFailureStage");

        /* Pre-ratchet errors (safe to retry) */
        add_test("SEC_stage_no_session_pre_ratchet", test_no_session);
        add_test("SEC_stage_invalid_message_pre_ratchet", test_invalid_message);
        add_test("SEC_stage_legacy_message_pre_ratchet", test_legacy_message);
        add_test("SEC_stage_deserialize_pre_ratchet", test_deserialize);
        add_test("SEC_stage_db_update_failed_pre_ratchet", test_db_update);

        /* Post-ratchet errors (ratchet consumed, cannot retry) */
        add_test("SEC_stage_hmac_failed_post_ratchet", test_hmac_failed);
        add_test("SEC_stage_aes_failed_post_ratchet", test_aes_failed);
        add_test("SEC_stage_sce_parse_post_ratchet", test_sce_parse);
        add_test("SEC_stage_key_too_short_post_ratchet", test_key_short);
        add_test("SEC_stage_hkdf_failed_post_ratchet", test_hkdf_failed);
        add_test("SEC_stage_hmac_compute_post_ratchet", test_hmac_compute);

        /* Unknown error → conservative assumption */
        add_test("SEC_stage_unknown_error_assume_post", test_unknown);
    }

    /* --- Pre-ratchet (safe to retry) --- */

    void test_no_session() {
        var stage = classify_decrypt_failure_stage("SG_ERR_NO_SESSION for alice@example.com/1234");
        fail_if_not(stage == DecryptFailureStage.PRE_RATCHET,
            "SG_ERR_NO_SESSION should be PRE_RATCHET");
    }

    void test_invalid_message() {
        var stage = classify_decrypt_failure_stage("SG_ERR_INVALID_MESSAGE: bad format");
        fail_if_not(stage == DecryptFailureStage.PRE_RATCHET,
            "SG_ERR_INVALID_MESSAGE should be PRE_RATCHET");
    }

    void test_legacy_message() {
        var stage = classify_decrypt_failure_stage("SG_ERR_LEGACY_MESSAGE: version mismatch");
        fail_if_not(stage == DecryptFailureStage.PRE_RATCHET,
            "SG_ERR_LEGACY_MESSAGE should be PRE_RATCHET");
    }

    void test_deserialize() {
        var stage = classify_decrypt_failure_stage("Failed to deserialize pre-key message");
        fail_if_not(stage == DecryptFailureStage.PRE_RATCHET,
            "deserialize error should be PRE_RATCHET");
    }

    void test_db_update() {
        var stage = classify_decrypt_failure_stage("Failed updating db for prekey");
        fail_if_not(stage == DecryptFailureStage.PRE_RATCHET,
            "DB update failure should be PRE_RATCHET");
    }

    /* --- Post-ratchet (cannot retry) --- */

    void test_hmac_failed() {
        var stage = classify_decrypt_failure_stage("HMAC verification failed");
        fail_if_not(stage == DecryptFailureStage.POST_RATCHET,
            "HMAC verification failed should be POST_RATCHET");
    }

    void test_aes_failed() {
        var stage = classify_decrypt_failure_stage("AES-256-CBC decrypt failed");
        fail_if_not(stage == DecryptFailureStage.POST_RATCHET,
            "AES-256-CBC decrypt failed should be POST_RATCHET");
    }

    void test_sce_parse() {
        var stage = classify_decrypt_failure_stage("Failed to parse SCE envelope");
        fail_if_not(stage == DecryptFailureStage.POST_RATCHET,
            "SCE parse failure should be POST_RATCHET");
    }

    void test_key_short() {
        var stage = classify_decrypt_failure_stage("Decrypted key too short (got 16, need 48)");
        fail_if_not(stage == DecryptFailureStage.POST_RATCHET,
            "key too short should be POST_RATCHET");
    }

    void test_hkdf_failed() {
        var stage = classify_decrypt_failure_stage("HKDF failed");
        fail_if_not(stage == DecryptFailureStage.POST_RATCHET,
            "HKDF failed should be POST_RATCHET");
    }

    void test_hmac_compute() {
        var stage = classify_decrypt_failure_stage("HMAC computation failed");
        fail_if_not(stage == DecryptFailureStage.POST_RATCHET,
            "HMAC computation failed should be POST_RATCHET");
    }

    /* --- Unknown → conservative assumption --- */

    void test_unknown() {
        var stage = classify_decrypt_failure_stage("Something completely unexpected happened");
        fail_if_not(stage == DecryptFailureStage.UNKNOWN_ASSUME_POST,
            "unknown error should be UNKNOWN_ASSUME_POST (conservative)");
    }
}


class Omemo2RuntimeFlagTest : Gee.TestCase {
    public Omemo2RuntimeFlagTest() {
        base("Omemo2RuntimeFlag");

        add_test("OMEMO2_runtime_is_disabled", test_runtime_disabled);
        add_test("OMEMO2_enable_request_is_ignored", test_enable_request_ignored);
    }

    void test_runtime_disabled() {
        fail_if(TrustManager.omemo2_enabled_by_default(),
            "OMEMO2 runtime must remain disabled by default");
    }

    void test_enable_request_ignored() {
        TrustManager.set_omemo2_runtime_test_override(false);
        with_test_dbs("dinox-omemo2-runtime-flag", (dino_db, omemo_db) => {
            var stream_interactor = new Dino.StreamInteractor.for_tests(dino_db);
            Dino.MessageProcessor.start(stream_interactor, dino_db);

            var trust_manager = new TrustManager(stream_interactor, omemo_db);
            trust_manager.omemo2_enabled = true;
            fail_if(trust_manager.omemo2_enabled,
                "OMEMO2 enable request must be ignored while runtime support is disabled");
        });
        TrustManager.set_omemo2_runtime_test_override(true);
    }
}


class Omemo2DefaultOffTrustTest : Gee.TestCase {
    public Omemo2DefaultOffTrustTest() {
        base("Omemo2DefaultOffTrust");

        add_test("OMEMO2_default_off_ignores_v2_only_known_address", test_default_off_ignores_v2_only_known_address);
        add_test("OMEMO2_enable_request_still_ignores_v2_only_known_address", test_enable_request_still_ignores_v2_only_known_address);
        add_test("OMEMO2_disabled_cleanup_deactivates_v2_only_state", test_disabled_cleanup_deactivates_v2_only_state);
    }

    private void with_v2_only_address(bool request_omemo2_enabled, bool expected_known) {
        TrustManager.set_omemo2_runtime_test_override(false);
        with_test_dbs("dinox-omemo2-default-off", (dino_db, omemo_db) => {
            var stream_interactor = new Dino.StreamInteractor.for_tests(dino_db);
            Dino.MessageProcessor.start(stream_interactor, dino_db);

            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist(dino_db);
            var contact = new Jid("bob@example.test");

            int identity_id = insert_identity(omemo_db, account.id, 1001);
            insert_meta_device(omemo_db, identity_id, contact.bare_jid.to_string(), 2002, false, true, true);

            var trust_manager = new TrustManager(stream_interactor, omemo_db);
            trust_manager.omemo2_enabled = request_omemo2_enabled;

            bool actual_known = trust_manager.is_known_address(account, contact);
            fail_if(actual_known != expected_known,
                "v2-only address known state mismatch after enable_request=%s".printf(request_omemo2_enabled.to_string()));
        });
        TrustManager.set_omemo2_runtime_test_override(true);
    }

    void test_default_off_ignores_v2_only_known_address() {
        with_v2_only_address(false, false);
    }

    void test_enable_request_still_ignores_v2_only_known_address() {
        with_v2_only_address(true, false);
    }

    void test_disabled_cleanup_deactivates_v2_only_state() {
        with_test_omemo_db("dinox-omemo2-disabled-cleanup", (omemo_db) => {
            int identity_id = insert_identity(omemo_db, 1, 1001);

            insert_meta_device(omemo_db, identity_id, "alice@example.test", 2001, false, true, true);
            insert_meta_device(omemo_db, identity_id, "alice@example.test", 2002, true, true, true);
            insert_meta_device(omemo_db, identity_id, "alice@example.test", 2003, true, false, true);

            fail_if_not_eq_int((int) omemo_db.identity_meta.count_active_omemo2_devices(identity_id), 2,
                "test setup should have two active OMEMO2 devices");

            omemo_db.identity_meta.disable_omemo2_runtime_state(identity_id);

            Qlite.Row? v2_only = omemo_db.identity_meta.get_device(identity_id, "alice@example.test", 2001);
            Qlite.Row? mixed = omemo_db.identity_meta.get_device(identity_id, "alice@example.test", 2002);
            Qlite.Row? legacy = omemo_db.identity_meta.get_device(identity_id, "alice@example.test", 2003);

            fail_if(v2_only == null || ((!) v2_only)[omemo_db.identity_meta.now_active],
                "disabled OMEMO2 cleanup must deactivate v2-only devices");
            fail_if(v2_only == null || ((!) v2_only)[omemo_db.identity_meta.supports_omemo2],
                "disabled OMEMO2 cleanup must clear v2 support from v2-only devices");

            fail_if(mixed == null || !((!) mixed)[omemo_db.identity_meta.now_active],
                "mixed v1/v2 device must remain active as a legacy device");
            fail_if(mixed == null || !((!) mixed)[omemo_db.identity_meta.supports_omemo1],
                "mixed v1/v2 device must keep legacy support");
            fail_if(mixed == null || ((!) mixed)[omemo_db.identity_meta.supports_omemo2],
                "mixed v1/v2 device must have v2 support cleared while runtime is disabled");

            fail_if(legacy == null || !((!) legacy)[omemo_db.identity_meta.now_active],
                "legacy-only device must remain active");
            fail_if_not_eq_int((int) omemo_db.identity_meta.count_active_omemo2_devices(identity_id), 0,
                "disabled OMEMO2 cleanup must leave no active v2 devices");
        });
    }
}


class OmemoSendStateTest : Gee.TestCase {
    public OmemoSendStateTest() {
        base("OmemoSendState");

        add_test("OMEMO_send_waits_for_any_unknown_own_device", test_waits_for_unknown_own_device);
        add_test("OMEMO_send_does_not_wait_for_classified_lost_own_device", test_does_not_wait_for_lost_own_device);
        add_test("OMEMO_direct_send_waits_for_any_unknown_recipient_device", test_direct_waits_for_unknown_recipient_device);
        add_test("OMEMO_direct_send_does_not_wait_for_classified_lost_recipient_device", test_direct_does_not_wait_for_lost_recipient_device);
        add_test("OMEMO_private_muc_keeps_partial_delivery_for_classified_lost_devices", test_private_muc_keeps_partial_delivery_policy);
        add_test("OMEMO_private_muc_waits_until_pending_peer_sessions_resolve", test_private_muc_waits_for_first_peer);
        add_test("OMEMO_private_muc_without_trusted_peer_devices_is_not_ready", test_private_muc_without_peer_devices);
        add_test("OMEMO_private_muc_all_lost_peer_devices_are_not_ready", test_private_muc_all_peer_devices_lost);
    }

    void test_waits_for_unknown_own_device() {
        var state = new Xmpp.Xep.Omemo.EncryptState();
        state.encrypted = true;
        state.own_list = true;
        state.own_devices = 3;
        state.own_success = 2;
        state.own_unknown = 1;
        state.other_devices = 1;
        state.other_success = 1;

        fail_if(!Manager.should_wait_for_own_sessions(state),
            "DinoX must wait when any active own device still needs a session repair decision");
    }

    void test_does_not_wait_for_lost_own_device() {
        var state = new Xmpp.Xep.Omemo.EncryptState();
        state.encrypted = true;
        state.own_list = true;
        state.own_devices = 3;
        state.own_success = 2;
        state.own_lost = 1;
        state.own_unknown = 0;
        state.other_devices = 1;
        state.other_success = 1;

        fail_if(Manager.should_wait_for_own_sessions(state),
            "DinoX may send after a broken own device has been classified as lost/ignored");
    }

    void test_direct_waits_for_unknown_recipient_device() {
        var state = new Xmpp.Xep.Omemo.EncryptState();
        state.encrypted = true;
        state.other_devices = 2;
        state.other_success = 1;
        state.other_unknown = 1;

        fail_if(!Manager.should_wait_for_counterpart_sessions(state),
            "a direct message must wait until every active recipient device has a session");
    }

    void test_direct_does_not_wait_for_lost_recipient_device() {
        var state = new Xmpp.Xep.Omemo.EncryptState();
        state.encrypted = true;
        state.other_devices = 2;
        state.other_success = 1;
        state.other_lost = 1;

        fail_if(Manager.should_wait_for_counterpart_sessions(state),
            "a direct message may skip a device only after it is explicitly classified as lost");
    }

    void test_private_muc_keeps_partial_delivery_policy() {
        var state = new Xmpp.Xep.Omemo.EncryptState();
        state.encrypted = true;
        state.other_devices = 2;
        state.other_success = 1;
        state.other_lost = 1;

        fail_if(Manager.should_wait_for_counterpart_sessions(state),
            "private MUC delivery may skip a member device only after its loss is explicitly classified");
    }

    private Xmpp.Xep.Omemo.EncryptState own_ready_group_state() {
        return new Xmpp.Xep.Omemo.EncryptState() {
            encrypted = true,
            own_list = true,
            own_devices = 2,
            own_success = 2
        };
    }

    void test_private_muc_waits_for_first_peer() {
        var message = new Message(null) {
            type_ = Message.Type.GROUPCHAT,
            marked = Message.Marked.UNSENT
        };
        var pending = own_ready_group_state();
        pending.other_devices = 2;
        pending.other_unknown = 2;
        var send = new Manager.MessageState(message, pending);
        fail_if(send.will_send_now,
            "a group packet containing only own wrapped keys must not be sent");
        fail_if(message.marked != Message.Marked.UNSENT,
            "pending peer sessions must keep the message available for retry");
        fail_if(send.should_retry_now(),
            "the first attempt must wait for its bundle/session completion");

        // One warm member must not make another member's unprepared session
        // silently lose the first group message.
        var partial = own_ready_group_state();
        partial.other_devices = 2;
        partial.other_success = 1;
        partial.other_unknown = 1;
        send.update_from_encrypt_status(message, partial);
        fail_if(send.will_send_now || message.marked != Message.Marked.UNSENT,
            "the first actual peer key must retain the wait for another unknown session");
        var ready = own_ready_group_state();
        ready.other_devices = 2;
        ready.other_success = 2;
        send.update_from_encrypt_status(message, ready);
        fail_if_not(send.will_send_now,
            "the same pending group message may send when every unknown session has resolved");
    }

    void test_private_muc_without_peer_devices() {
        var message = new Message(null) { type_ = Message.Type.GROUPCHAT };
        var send = new Manager.MessageState(message, own_ready_group_state());
        fail_if(send.will_send_now,
            "an empty trusted peer set must not make own-only encryption ready");
        fail_if(message.marked != Message.Marked.WONTSEND,
            "no pending peer work remains, so the failure must be visible");
    }

    void test_private_muc_all_peer_devices_lost() {
        var message = new Message(null) { type_ = Message.Type.GROUPCHAT };
        var failed = own_ready_group_state();
        failed.other_devices = 2;
        failed.other_lost = 2;
        var send = new Manager.MessageState(message, failed);
        fail_if(send.will_send_now,
            "explicitly lost peer devices cannot be replaced by own recipients");
        fail_if(message.marked != Message.Marked.WONTSEND);
    }
}


class ConversationClearCryptoStateTest : Gee.TestCase {
    public ConversationClearCryptoStateTest() {
        base("ConversationClearCryptoState");

        add_test("OMEMO_history_clear_preserves_sessions_devices_and_trust", test_history_clear_preserves_crypto_state);
    }

    void test_history_clear_preserves_crypto_state() {
        with_test_dbs("dinox-omemo-chat-clear-state", (dino_db, omemo_db) => {
            var stream_interactor = new Dino.StreamInteractor.for_tests(dino_db);
            Dino.MessageProcessor.start(stream_interactor, dino_db);

            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist(dino_db);
            var contact = new Jid("bob@example.test");
            var conversation = new Conversation(contact, account, Conversation.Type.CHAT);

            int identity_id = insert_identity(omemo_db, account.id, 1001);
            insert_meta_device(omemo_db, identity_id, contact.bare_jid.to_string(), 2001, true, false, true);
            omemo_db.trust.upsert()
                .value(omemo_db.trust.identity_id, identity_id, true)
                .value(omemo_db.trust.address_name, contact.bare_jid.to_string(), true)
                .value(omemo_db.trust.blind_trust, true)
                .perform();
            omemo_db.session.upsert()
                .value(omemo_db.session.identity_id, identity_id, true)
                .value(omemo_db.session.address_name, contact.bare_jid.to_string(), true)
                .value(omemo_db.session.device_id, 2001, true)
                .value(omemo_db.session.record_base64, "persisted-ratchet-session")
                .perform();

            fail_if_not_eq_int((int) omemo_db.session.select()
                    .with(omemo_db.session.identity_id, "=", identity_id)
                    .with(omemo_db.session.address_name, "=", contact.bare_jid.to_string())
                    .count(), 1,
                "test setup must contain one contact OMEMO session");
            fail_if_not_eq_int((int) omemo_db.identity_meta.with_address(identity_id, contact.bare_jid.to_string()).count(), 1,
                "test setup must contain one contact OMEMO device");
            fail_if_not_eq_int((int) omemo_db.trust.select()
                    .with(omemo_db.trust.identity_id, "=", identity_id)
                    .with(omemo_db.trust.address_name, "=", contact.bare_jid.to_string())
                    .count(), 1,
                "test setup must contain one contact OMEMO trust row");

            var trust_manager = new TrustManager(stream_interactor, omemo_db);
            var encryptors = new Gee.HashMap<Account, OmemoEncryptor>(Account.hash_func, Account.equals_func);
            var manager = Manager.create_for_tests(stream_interactor, omemo_db, trust_manager, encryptors);

            manager.on_conversation_cleared(conversation);

            fail_if_not_eq_int((int) omemo_db.session.select()
                    .with(omemo_db.session.identity_id, "=", identity_id)
                    .with(omemo_db.session.address_name, "=", contact.bare_jid.to_string())
                    .count(), 1,
                "local history clear must preserve existing OMEMO ratchet sessions");
            fail_if_not_eq_int((int) omemo_db.identity_meta.with_address(identity_id, contact.bare_jid.to_string()).count(), 1,
                "local history clear must preserve OMEMO device knowledge");
            fail_if_not_eq_int((int) omemo_db.trust.select()
                    .with(omemo_db.trust.identity_id, "=", identity_id)
                    .with(omemo_db.trust.address_name, "=", contact.bare_jid.to_string())
                    .count(), 1,
                "local history clear must preserve OMEMO trust decisions");
        });
    }
}


class ContactDetailsTrustIconTest : Gee.TestCase {
    public ContactDetailsTrustIconTest() {
        base("ContactDetailsTrustIcon");

        add_test("OMEMO_contact_details_uses_portable_trust_icons", test_portable_trust_icons);
    }

    void test_portable_trust_icons() {
        fail_if_not_eq_str(contact_details_trust_icon_name(TrustLevel.VERIFIED),
            "dino-security-high-symbolic",
            "verified devices must use DinoX's packaged security icon");
        fail_if_not_eq_str(contact_details_trust_icon_name(TrustLevel.TRUSTED),
            "check-plain-symbolic",
            "trusted devices must use DinoX's packaged acceptance icon");
        fail_if_not_eq_str(contact_details_trust_icon_name(TrustLevel.UNTRUSTED),
            "dialog-warning-symbolic",
            "untrusted devices must keep the portable warning icon");
        fail_if_not_eq_str(contact_details_trust_icon_name(TrustLevel.UNKNOWN),
            "dialog-question-symbolic",
            "unknown devices must keep the portable question icon");
    }
}


private delegate void TestDbFunc(Dino.Database dino_db, Dino.Plugins.Omemo.Database omemo_db) throws Error;
private delegate void TestOmemoDbFunc(Dino.Plugins.Omemo.Database omemo_db) throws Error;

private void with_test_dbs(string prefix, owned TestDbFunc func) {
    string temp_dir = Path.build_filename(Environment.get_tmp_dir(), prefix + "-" + Uuid.string_random());
    string dino_db_path = Path.build_filename(temp_dir, "dino.db");
    string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

    Dino.Database? dino_db = null;
    Dino.Plugins.Omemo.Database? omemo_db = null;

    try {
        DirUtils.create_with_parents(temp_dir, 0700);
        dino_db = new Dino.Database(dino_db_path, prefix);
        omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
        func((!) dino_db, (!) omemo_db);
    } catch (Error e) {
        fail_if(true, prefix + " failed: " + e.message);
    } finally {
        if (omemo_db != null) ((!) omemo_db).close();
        if (dino_db != null) ((!) dino_db).close();
        cleanup_file(omemo_db_path);
        cleanup_file(omemo_db_path + "-shm");
        cleanup_file(omemo_db_path + "-wal");
        cleanup_file(dino_db_path);
        cleanup_file(dino_db_path + "-shm");
        cleanup_file(dino_db_path + "-wal");
        DirUtils.remove(temp_dir);
    }
}

private void with_test_omemo_db(string prefix, owned TestOmemoDbFunc func) {
    string temp_dir = Path.build_filename(Environment.get_tmp_dir(), prefix + "-" + Uuid.string_random());
    string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

    Dino.Plugins.Omemo.Database? omemo_db = null;

    try {
        DirUtils.create_with_parents(temp_dir, 0700);
        omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
        func((!) omemo_db);
    } catch (Error e) {
        fail_if(true, prefix + " failed: " + e.message);
    } finally {
        if (omemo_db != null) ((!) omemo_db).close();
        cleanup_file(omemo_db_path);
        cleanup_file(omemo_db_path + "-shm");
        cleanup_file(omemo_db_path + "-wal");
        DirUtils.remove(temp_dir);
    }
}

private int insert_identity(Dino.Plugins.Omemo.Database db, int account_id, int device_id) {
    return (int) db.identity.upsert()
        .value(db.identity.account_id, account_id, true)
        .value(db.identity.device_id, device_id)
        .value(db.identity.identity_key_private_base64, "private")
        .value(db.identity.identity_key_public_base64, "public")
        .perform();
}

private void insert_meta_device(Dino.Plugins.Omemo.Database db, int identity_id, string jid, int device_id,
        bool supports_omemo1, bool supports_omemo2, bool now_active) {
    db.identity_meta.upsert()
        .value(db.identity_meta.identity_id, identity_id, true)
        .value(db.identity_meta.address_name, jid, true)
        .value(db.identity_meta.device_id, device_id, true)
        .value(db.identity_meta.identity_key_public_base64, "key-" + device_id.to_string())
        .value(db.identity_meta.trust_level, TrustLevel.TRUSTED)
        .value(db.identity_meta.supports_omemo1, supports_omemo1)
        .value(db.identity_meta.supports_omemo2, supports_omemo2)
        .value(db.identity_meta.now_active, now_active)
        .perform();
}

private void cleanup_file(string path) {
    try {
        File.new_for_path(path).delete();
    } catch (Error e) {
        // Ignore
    }
}

} // namespace Omemo.Test
