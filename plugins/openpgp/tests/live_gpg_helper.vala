namespace OpenPgp.Test {

[CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
private extern void set_server_message_response(Soup.ServerMessage msg, string? content_type, Soup.MemoryUse resp_use, string response_body, size_t response_length);

private void set_server_string_response(Soup.ServerMessage msg, string content_type, string response_body) {
    set_server_message_response(msg, content_type, Soup.MemoryUse.COPY, response_body, response_body.length);
}

[CCode (cname = "g_type_class_ref", cheader_filename = "glib-object.h")]
extern unowned void* _force_class_init(GLib.Type type);

public class LiveGPGHelperTest : Gee.TestCase {
    private const string NS_OPENPGP = "urn:xmpp:openpgp:0";
    private const string NS_OPENPGP_LEGACY = "jabber:x:encrypted";
    private const string NS_HTTP_UPLOAD_0 = "urn:xmpp:http:upload:0";
    private const string NS_DISCO_INFO = "http://jabber.org/protocol/disco#info";
    private const string NS_MUC_ADMIN = "http://jabber.org/protocol/muc#admin";
    private const string NS_MUC_USER = "http://jabber.org/protocol/muc#user";
    private const string NS_PRIVATE_XML_STORAGE = "jabber:iq:private";
    private const string NS_BOOKMARKS = "storage:bookmarks";
    private const string PGP_MIME_TYPE = "application/pgp-encrypted";
    private delegate void HttpsUploadHook();
    // Local-only self-signed certificate for the HTTPS upload test server.
    private const string TEST_TLS_CERT_PEM =
        "-----BEGIN CERTIFICATE-----\n" +
        "MIIDJTCCAg2gAwIBAgIUAhF95gtnalr8y81Axt8frgTCgvkwDQYJKoZIhvcNAQEL\n" +
        "BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDUyMTExMTYxOVoXDTI2MDYy\n" +
        "MDExMTYxOVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF\n" +
        "AAOCAQ8AMIIBCgKCAQEAyQevtKaCNgbZHMvi27zJkn55fXRdy9XTN/xXH+Obonop\n" +
        "9P73QymYNst1MaUEmL9pSUOjzW6Iu7Ee/Jb1VqKGyW79WVobVpe8+b1j4Mr5BMTJ\n" +
        "nunYQSpQzmNQB8C9+WeVQ/PY6xZUth74fChZyDY73gAGzdeKdbQBLCxPNkyeD9Og\n" +
        "PSeva9p0jCpZRYqZ3VR6jADlIyTzVh5f2zRpH7bG9Dg0FURyi+wAH+7aWqA6arnE\n" +
        "ZjzAXGcEyqvZKsLcsTsOBw6ERdQkSi32okbx0wqnY0GZULQOED+9UrQPi0iklsgx\n" +
        "jqzB9uJoXPN7eT/l3FJec50umUovkeH0SzHYyIS0AwIDAQABo28wbTAdBgNVHQ4E\n" +
        "FgQUzJ8OLEvDkZIle0qvYkO8/jXP1fkwHwYDVR0jBBgwFoAUzJ8OLEvDkZIle0qv\n" +
        "YkO8/jXP1fkwDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SH\n" +
        "BH8AAAEwDQYJKoZIhvcNAQELBQADggEBAICTb927FYJeKDxfeSqxv5J7BuvoH2+B\n" +
        "JB0bD8Lt62p/d2wcHzSY52VTJN8jS6iLqy4sS+R2OVTRcYJoLy0edkmll36YHGpC\n" +
        "CqC31HoYoS+zzoyVTLoCvB/EMNUJVIdO5yaHOXLU3mhnKS4f77Gu24805jofkz7X\n" +
        "8OD5kAKEGhNDQXnMW/j61LD3KJ8Z4rcOd7/jwkQiTbI8Xw7pbV2dtZuq7i0pEjeO\n" +
        "USrSIlFc/PcBb1ZwEYQYziSJRx4F3KJudTt16WXMHJfILCGcMfNqzTQjP2zZ5a0P\n" +
        "ohhMeUAxA2dLsSyZixHPR2mD89hxS9VaAnDFXZLJkQP8HmgNYCPgUB4=\n" +
        "-----END CERTIFICATE-----\n";
    private const string TEST_TLS_KEY_PEM =
        "-----BEGIN PRIVATE KEY-----\n" +
        "MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDJB6+0poI2Btkc\n" +
        "y+LbvMmSfnl9dF3L1dM3/Fcf45uiein0/vdDKZg2y3UxpQSYv2lJQ6PNboi7sR78\n" +
        "lvVWoobJbv1ZWhtWl7z5vWPgyvkExMme6dhBKlDOY1AHwL35Z5VD89jrFlS2Hvh8\n" +
        "KFnINjveAAbN14p1tAEsLE82TJ4P06A9J69r2nSMKllFipndVHqMAOUjJPNWHl/b\n" +
        "NGkftsb0ODQVRHKL7AAf7tpaoDpqucRmPMBcZwTKq9kqwtyxOw4HDoRF1CRKLfai\n" +
        "RvHTCqdjQZlQtA4QP71StA+LSKSWyDGOrMH24mhc83t5P+XcUl5znS6ZSi+R4fRL\n" +
        "MdjIhLQDAgMBAAECggEAEeORHNv1jPXTPsiphKp9X3/JgA+P9zJG0pEUdn4ZHLGO\n" +
        "56idFTw8bNSlgztVhOHOCAFKY5IF/eAwyzZqjGdeSjEjv153pB8dms9IXFODkST3\n" +
        "2IajqIZ2j8WIdIaQATa/MoxRzcQV2enSOXr+JLhaxhJHiLkfYgKYjIQNSnfLJJcL\n" +
        "FLZY5hNK7NXdtMLbD2GPxV6boP20RjJ2G75QgAWBltwXNH5EIaSbkdwFIbJWA76H\n" +
        "BoDmTuKIW/sG+1PrrgLQajXLVD9HujTP8QUzyNA1SEFzAy4qd3xixr5O3f0TQY2v\n" +
        "ylAD93o+sBdQQZop4IIwIR4swxCgau6xxAUvj0IN5QKBgQD+6uRhKumk3kyIsno+\n" +
        "3xwfi9beR6a4adyu5kk7NaLDeSQ6FcQzQHQKxGltS5gNlBc0bppupZiXg/acA9oE\n" +
        "fMnyv0YPiwSdiqWceXQc4XREobrbQY5hrKOLP65NfLyC5kypSgckRcKjN8n9Odmg\n" +
        "E2zJR2y+eWQ47M4DnUbwgzN9hQKBgQDJ4jdCjwPuuvYPtIlhrUdHKrWnIMGEKOTH\n" +
        "mAu8SEVhDnLAKkVFbl51WRS8PQ3wMj7CuBageU9ZVDzJ3TvKgfw6AuMXNNeu9lys\n" +
        "TlKKKTNDZdw7dP4M446ueKggV566hKeHIHr4sIxtumR/KzXr6GugtnaHRhxWvG9H\n" +
        "svsjAJr95wKBgD2quSDAbtERbdZLxsLa2kTPYWVYU/6crWQqFWEbcopzDc53YYU8\n" +
        "fFX2ecKU3O27+3kVoIpPyQAuTkQjsmQPhBMTLnGoIa+y0KlvwCUUbToFHdzYmQcL\n" +
        "6mxPNW1NVZUc/UKew+eEcLdnUZfOnNTaniB7BNV3LEWRE61QKM8aDiS5AoGAZ/42\n" +
        "VvvSm8QFAlwONJmM0PUIM7ok1Q43ozUIPom/61oE9EYR/sz2rV4g10JgDq3jNGyd\n" +
        "gzZaEHrbAWUL6qoAomVgU1DuFXtki4Gg9Ph6JqquwpXmU/9YPTl76YUZB51TqsCp\n" +
        "d7eB7vgH0pYQpZ/I6TV0YwRTjr5sWDOzN/mU3VsCgYAX89eyEiaR8m/qZ/DooR9f\n" +
        "ltRlBftqOr5zeBNOwYUCwYLWRxEKjw2ZI0U2PC5qiw3gP1DaoQoyJOwlmBZzOjt0\n" +
        "7XYQGMGaC7zV+4fHZF5+eHWPGBwBKLi3oQiTrG0oGUXsuADHSElC2BdoUCPioU8I\n" +
        "QLGGyD3xP6tEjJJnA1idVw==\n" +
        "-----END PRIVATE KEY-----\n";

    public LiveGPGHelperTest() {
        base("LiveGPGHelper");
        add_test("sign_encrypt_real_keyring", test_sign_encrypt_real_keyring);
        add_test("xep0374_archive_guard_is_existing_chat_and_account_scoped", test_xep0374_archive_guard);
        add_test("xep0374_archive_cached_contact_key_receives", () => test_xep0374_archive_cached_key_sync(0));
        add_test("xep0374_archive_cached_own_key_receives_sent_echo", () => test_xep0374_archive_cached_key_sync(1));
        add_test("xep0374_archive_cached_key_rejects_wrong_signer", () => test_xep0374_archive_cached_key_sync(2));
        add_test("xep0374_archive_cached_key_rejects_wrong_recipient", () => test_xep0374_archive_cached_key_sync(3));
        add_test("encrypt_file_to_path_real_keyring", test_encrypt_file_to_path_real_keyring);
        add_test("pgp_file_encryptor_legacy_real_manager_real_keyring", test_pgp_file_encryptor_legacy_real_manager_real_keyring_sync);
        add_test("pgp_file_encryptor_xep0374_real_manager_real_keyring", test_pgp_file_encryptor_xep0374_real_manager_real_keyring_sync);
        add_test("xep0027_presence_discovery_file_send_ready", test_xep0027_presence_discovery_file_send_ready_sync);
        add_test("xep0027_keyserver_fetch_file_send_ready", test_xep0027_keyserver_fetch_file_send_ready_sync);
        add_test("xep0373_pubsub_publish_fetch_file_send_ready", test_xep0373_pubsub_publish_fetch_file_send_ready_sync);
        add_test("file_manager_http_send_xep0374_real_encryptor_invalid_upload", test_file_manager_http_send_xep0374_real_encryptor_invalid_upload_sync);
        add_test("file_manager_http_send_xep0374_real_encryptor_https_put_success", test_file_manager_http_send_xep0374_real_encryptor_https_put_success_sync);
        add_test("file_manager_http_send_xep0374_real_encryptor_cancel_after_put_blocks_body_announcement", test_file_manager_http_send_xep0374_real_encryptor_cancel_after_put_blocks_body_announcement_sync);
        add_test("file_manager_http_send_xep0374_real_encryptor_cancel_while_request_body_stream_blocks", test_file_manager_http_send_xep0374_real_encryptor_cancel_while_request_body_stream_blocks_sync);
        add_test("file_manager_http_send_xep0027_real_encryptor_cancel_while_request_body_stream_blocks", test_file_manager_http_send_xep0027_real_encryptor_cancel_while_request_body_stream_blocks_sync);
        add_test("file_manager_http_send_xep0027_real_encryptor_cancel_after_put_blocks_body_announcement", test_file_manager_http_send_xep0027_real_encryptor_cancel_after_put_blocks_body_announcement_sync);
        add_test("file_manager_http_send_xep0374_private_muc_real_encryptor_https_put_success", test_file_manager_http_send_xep0374_private_muc_real_encryptor_https_put_success_sync);
        add_test("file_manager_http_send_xep0374_private_muc_pm_real_encryptor_https_put_success", test_file_manager_http_send_xep0374_private_muc_pm_real_encryptor_https_put_success_sync);
        add_test("file_manager_http_send_xep0027_private_muc_pm_real_encryptor_https_put_success", test_file_manager_http_send_xep0027_private_muc_pm_real_encryptor_https_put_success_sync);
        add_test("file_manager_http_send_xep0027_private_muc_real_encryptor_https_put_success", test_file_manager_http_send_xep0027_private_muc_real_encryptor_https_put_success_sync);
        add_test("file_manager_http_send_xep0374_private_muc_rejects_account_key_without_account_uid", test_file_manager_http_send_xep0374_private_muc_rejects_account_key_without_account_uid_sync);
        add_test("file_manager_http_send_xep0027_real_encryptor_https_put_success", test_file_manager_http_send_xep0027_real_encryptor_https_put_success_sync);
        add_test("file_manager_http_send_openpgp_groupchat_rejected_before_slot", test_file_manager_http_send_openpgp_groupchat_rejected_before_slot_sync);
        add_test("file_manager_http_send_openpgp_private_muc_rejected_before_slot", test_file_manager_http_send_openpgp_private_muc_rejected_before_slot_sync);
        add_test("openpgp_private_muc_file_recipient_candidates_reject_private_muc_pm", test_openpgp_private_muc_file_recipient_candidates_reject_private_muc_pm);
        add_test("openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_requires_real_jid", test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_requires_real_jid);
        add_test("openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_requires_private_room", test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_requires_private_room);
        add_test("openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_accepts_real_jid", test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_accepts_real_jid);
        add_test("openpgp_private_muc_pm_file_recipient_key_readiness_xep0027_accepts_real_jid", test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0027_accepts_real_jid);
        add_test("openpgp_private_muc_pm_normal_text_send_does_not_require_file_snapshot", test_openpgp_private_muc_pm_normal_text_send_does_not_require_file_snapshot);
        add_test("openpgp_private_muc_receive_recipient_candidates_distinguish_groupchat_and_pm", test_openpgp_private_muc_receive_recipient_candidates_distinguish_groupchat_and_pm);
        add_test("openpgp_private_muc_pm_file_decryptor_validates_real_jid_signer", test_openpgp_private_muc_pm_file_decryptor_validates_real_jid_signer);
        add_test("openpgp_private_muc_pm_file_decryptor_rejects_without_real_jid", test_openpgp_private_muc_pm_file_decryptor_rejects_without_real_jid);
        add_test("openpgp_private_muc_groupchat_file_decryptor_validates_real_jid_signer", test_openpgp_private_muc_groupchat_file_decryptor_validates_real_jid_signer);
        add_test("openpgp_private_muc_groupchat_file_decryptor_rejects_without_real_jid", test_openpgp_private_muc_groupchat_file_decryptor_rejects_without_real_jid);
        add_test("openpgp_private_muc_file_recipient_candidates_reject_public_room", test_openpgp_private_muc_file_recipient_candidates_reject_public_room);
        add_test("openpgp_private_muc_file_recipient_candidates_reject_stale_private_room_cache", test_openpgp_private_muc_file_recipient_candidates_reject_stale_private_room_cache);
        add_test("openpgp_private_muc_file_recipient_candidates_reject_stale_live_room_features", test_openpgp_private_muc_file_recipient_candidates_reject_stale_live_room_features);
        add_test("openpgp_private_muc_file_recipient_candidates_reject_after_local_leave", test_openpgp_private_muc_file_recipient_candidates_reject_after_local_leave);
        add_test("openpgp_private_muc_file_recipient_candidates_reject_incomplete_affiliation_snapshot", test_openpgp_private_muc_file_recipient_candidates_reject_incomplete_affiliation_snapshot);
        add_test("openpgp_private_muc_file_recipient_candidates_replace_requeried_affiliation", test_openpgp_private_muc_file_recipient_candidates_replace_requeried_affiliation);
        add_test("openpgp_private_muc_file_recipient_candidates_ignore_non_member_affiliations", test_openpgp_private_muc_file_recipient_candidates_ignore_non_member_affiliations);
        add_test("openpgp_private_muc_file_recipient_candidates_apply_authoritative_presence_delta", test_openpgp_private_muc_file_recipient_candidates_apply_authoritative_presence_delta);
        add_test("openpgp_private_muc_file_recipient_candidates_reject_self_only_members", test_openpgp_private_muc_file_recipient_candidates_reject_self_only_members);
        add_test("openpgp_private_muc_file_recipient_candidates_accept_known_members", test_openpgp_private_muc_file_recipient_candidates_accept_known_members);
        add_test("openpgp_private_muc_affiliation_snapshot_queries_member_admin_owner", test_openpgp_private_muc_affiliation_snapshot_queries_member_admin_owner);
        add_test("openpgp_private_muc_affiliation_snapshot_accepts_fromless_results", test_openpgp_private_muc_affiliation_snapshot_accepts_fromless_results);
        add_test("openpgp_private_muc_affiliation_snapshot_rejects_mismatched_result_from", test_openpgp_private_muc_affiliation_snapshot_rejects_mismatched_result_from);
        add_test("openpgp_private_muc_affiliation_snapshot_rejects_full_result_from", test_openpgp_private_muc_affiliation_snapshot_rejects_full_result_from);
        add_test("openpgp_private_muc_affiliation_snapshot_error_keeps_snapshot_incomplete", test_openpgp_private_muc_affiliation_snapshot_error_keeps_snapshot_incomplete);
        add_test("openpgp_private_muc_file_recipient_key_readiness_xep0374_requires_verified_keys", test_openpgp_private_muc_file_recipient_key_readiness_xep0374_requires_verified_keys);
        add_test("openpgp_private_muc_file_recipient_key_readiness_xep0374_requires_refreshed_keys", test_openpgp_private_muc_file_recipient_key_readiness_xep0374_requires_refreshed_keys);
        add_test("openpgp_private_muc_file_recipient_key_readiness_xep0374_ignores_support_without_key", test_openpgp_private_muc_file_recipient_key_readiness_xep0374_ignores_support_without_key);
        add_test("openpgp_private_muc_file_recipient_key_readiness_xep0027_requires_announced_keys", test_openpgp_private_muc_file_recipient_key_readiness_xep0027_requires_announced_keys);
        add_test("openpgp_private_muc_file_recipient_key_fprs_xep0374_requires_ready_keys", test_openpgp_private_muc_file_recipient_key_fprs_xep0374_requires_ready_keys);
        add_test("openpgp_private_muc_file_recipient_key_fprs_xep0027_requires_announced_keys", test_openpgp_private_muc_file_recipient_key_fprs_xep0027_requires_announced_keys);
    }

    private static void prepare_archive_receive_chat(FileManagerHttpSetup setup) throws Error {
        var manager = (!) setup.stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(Dino.Plugins.OpenPgp.Manager.IDENTITY);
        // Reuse the real account/module binding from the presence fixture;
        // no private signing key is configured for presence in this setup.
        setup.stream = create_connected_legacy_presence_stream(setup.stream_interactor,
            setup.account, setup.openpgp_db, manager, false);
        var iq = (!) setup.stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(setup.account, Xmpp.Iq.Module.IDENTITY);
        setup.stream.add_module(iq);
        iq.attach(setup.stream);
        var disco = (!) setup.stream_interactor.module_manager.get_module<Xmpp.Xep.ServiceDiscovery.Module>(
            setup.account, Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        setup.stream.add_module(disco);
        disco.attach(setup.stream);
        attach_openpgp_bookmark_modules_for_tests(setup.stream_interactor, setup.account, setup.stream);
        install_empty_openpgp_bookmarks_responder_for_tests(setup.stream);
        var archive_stream = setup.stream;
        ulong disco_handler_id = 0;
        disco_handler_id = archive_stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq" || outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET ||
                    outgoing.get_subnode("query", NS_DISCO_INFO) == null) return;
            var result = new Xmpp.StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT)
                .put_attribute("id", outgoing.get_attribute("id"))
                .put_attribute("from", outgoing.get_attribute("to"));
            result.put_node(new Xmpp.StanzaNode.build("query", NS_DISCO_INFO).add_self_xmlns());
            archive_stream.emit_iq_result(result);
        });
        archive_stream.stream_negotiated(archive_stream);
        var conversations = (!) setup.stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
        setup.conversation = conversations.create_conversation(new Xmpp.Jid("bob@example.test"),
            setup.account, Dino.Entities.Conversation.Type.CHAT);
        setup.conversation.encryption = Dino.Entities.Encryption.OMEMO;
        manager.forget_xep0373_key_refresh(setup.account, setup.conversation.counterpart);
        drain_pending_events();
        SignalHandler.disconnect(archive_stream, disco_handler_id);
    }

    private static Xmpp.MessageStanza archive_receive_stanza(FileManagerHttpSetup setup,
            bool own_sent = false, Xmpp.Jid? archive_source = null) throws Xmpp.InvalidJidError {
        var stanza = new Xmpp.MessageStanza(Xmpp.random_uuid());
        stanza.type_ = Xmpp.MessageStanza.TYPE_CHAT;
        stanza.from = own_sent ? setup.account.full_jid : setup.conversation.counterpart.with_resource("phone");
        stanza.to = own_sent ? setup.conversation.counterpart : setup.account.full_jid;
        stanza.body = "untrusted OpenPGP wire fallback";
        stanza.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(archive_source ?? setup.account.bare_jid,
            new DateTime.now_utc(), "mam-" + stanza.id, "archive-receive-test"));
        return stanza;
    }

    private static void assert_archive_guard_rejected(Dino.Plugins.OpenPgp.Manager manager,
            Dino.Entities.Account account, Xmpp.MessageStanza stanza, string reason) {
        GLib.Test.expect_message("OpenPGP", GLib.LogLevelFlags.LEVEL_WARNING, "*refusing XEP-0374 stanza*");
        fail_if(manager.incoming_xep0374_message_matches_openpgp_conversation(account, stanza), reason);
        GLib.Test.assert_expected_messages();
    }

    private void test_xep0374_archive_guard() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup("alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            prepare_archive_receive_chat((!) setup);
            var manager = (!) ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(Dino.Plugins.OpenPgp.Manager.IDENTITY);
            int wire_count = ((!) setup).stream.written_nodes.size;
            var archive = archive_receive_stanza((!) setup);
            fail_if_not(manager.incoming_xep0374_message_matches_openpgp_conversation(((!) setup).account, archive),
                "An existing account CHAT must receive authenticated own-archive XEP-0374 after switching to OMEMO");
            fail_if_not(manager.incoming_xep0374_message_matches_openpgp_conversation(((!) setup).account,
                archive_receive_stanza((!) setup, true)), "Own sent history must resolve the target CHAT without changing its mode");

            var live = new Xmpp.MessageStanza.from_stanza(archive.stanza, ((!) setup).account.full_jid);
            assert_archive_guard_rejected(manager, ((!) setup).account, live, "Live PGP must still be blocked in an OMEMO CHAT");
            live.add_flag(new Xmpp.Xep.MessageCarbons.MessageFlag(Xmpp.Xep.MessageCarbons.MessageFlag.TYPE_RECEIVED));
            assert_archive_guard_rejected(manager, ((!) setup).account, live, "A Carbon must not bypass the live mode rule");
            assert_archive_guard_rejected(manager, ((!) setup).account,
                archive_receive_stanza((!) setup, false, new Xmpp.Jid("foreign@example.test")),
                "A foreign MAM archive must not bypass the mode rule");
            var unknown = archive_receive_stanza((!) setup);
            unknown.from = new Xmpp.Jid("stranger@example.test/phone");
            assert_archive_guard_rejected(manager, ((!) setup).account, unknown,
                "An account archive must not implicitly authorize an unknown conversation");
            var other = new Dino.Entities.Account(new Xmpp.Jid("other@example.test"), "secret");
            other.persist(((!) setup).core_db);
            var other_archive = new Xmpp.MessageStanza("other-account-archive");
            other_archive.from = ((!) setup).conversation.counterpart;
            other_archive.to = other.full_jid;
            other_archive.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(other.bare_jid,
                new DateTime.now_utc(), "mam-other", "query-other"));
            assert_archive_guard_rejected(manager, other, other_archive,
                "A conversation from the first account must not authorize the same peer for another account");
            fail_if(((!) setup).conversation.encryption != Dino.Entities.Encryption.OMEMO,
                "Archive eligibility must not mutate the selected encryption");
            fail_if(((!) setup).stream.written_nodes.size != wire_count,
                "Archive eligibility must not generate key discovery or other wire traffic");
        } catch (Error e) { fail_if(true, e.message); }
        finally { if (setup != null) ((!) setup).cleanup(); }
    }

    private void test_xep0374_archive_cached_key_sync(int scenario) {
        bool completed = false;
        test_xep0374_archive_cached_key.begin(scenario, (obj, res) => {
            test_xep0374_archive_cached_key.end(res);
            completed = true;
        });
        while (!completed) MainContext.default().iteration(true);
    }

    private async void test_xep0374_archive_cached_key(int scenario) {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) return;
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup("alice@example.test", signer, recipient);
            prepare_archive_receive_chat((!) setup);
            var manager = (!) ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(Dino.Plugins.OpenPgp.Manager.IDENTITY);
            fail_if(manager.contact_xmpp_key_was_refreshed_this_session(((!) setup).account, ((!) setup).conversation.counterpart),
                "Archive fixture must start with cached contact trust and no session refresh");
            bool own_sent = scenario == 1;
            bool accepted = scenario < 2;
            var stanza = archive_receive_stanza((!) setup, own_sent);
            var signcrypt_recipient = own_sent || scenario == 3
                ? ((!) setup).conversation.counterpart : ((!) setup).account.bare_jid;
            var signcrypt = new Xmpp.Xep.OpenPgpContent.SigncryptElement.with_body(signcrypt_recipient, "verified archived OpenPGP body");
            string actual_signer = own_sent || scenario == 2 ? signer : recipient;
            GPGHelper.Key[] keys = { require_private_key(actual_signer), require_public_key(signer), require_public_key(recipient) };
            uint8[] encrypted = GPGHelper.sign_and_encrypt_data(signcrypt.to_stanza_node().to_xml(), keys, null);
            stanza.stanza.put_node(new Xmpp.StanzaNode.build("openpgp", NS_OPENPGP).add_self_xmlns()
                .put_node(new Xmpp.StanzaNode.text(Base64.encode(encrypted))));
            int wire_count = ((!) setup).stream.written_nodes.size;
            if (!accepted) {
                GLib.Test.expect_message("OpenPGP", GLib.LogLevelFlags.LEVEL_WARNING,
                    scenario == 2 ? "*signer does not match stored XMPP key*" : "*recipient does not match local account*");
                GLib.Test.expect_message("OpenPGP", GLib.LogLevelFlags.LEVEL_WARNING, "*XEP-0374 decryption returned null*");
            }
            var message_module = (!) ((!) setup).stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY);
            yield message_module.received_pipeline.run(((!) setup).stream, stanza);
            if (!accepted) GLib.Test.assert_expected_messages();
            var flag = Dino.Plugins.OpenPgp.MessageFlag.get_flag(stanza);
            fail_if(flag == null || ((!) flag).decrypted != accepted,
                "The real stream decrypt pipeline must accept only signature- and recipient-verified history");
            fail_if_not_eq_str(stanza.body ?? "", accepted ? "verified archived OpenPGP body" : "untrusted OpenPGP wire fallback",
                "Only verified XEP-0374 history may replace the wire body");
            fail_if(manager.contact_xmpp_key_was_refreshed_this_session(((!) setup).account, ((!) setup).conversation.counterpart),
                "Archive receive must not convert cached contact trust into a fresh PEP lookup");
            fail_if(((!) setup).stream.written_nodes.size != wire_count,
                "Archive decryption must not perform automatic PEP fetches");
            fail_if(((!) setup).conversation.encryption != Dino.Entities.Encryption.OMEMO,
                "Historical decryption must not switch the live conversation away from OMEMO");
        } catch (Error e) { fail_if(true, "Archive cached-key receive failed: " + e.message); }
        finally { if (setup != null) ((!) setup).cleanup(); }
    }

    private void test_sign_encrypt_real_keyring() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        try {
            GPGHelper.Key signer_key = require_private_key(signer);
            GPGHelper.Key recipient_key = require_public_key(recipient);
            GPGHelper.Key[] keys = {
                signer_key,
                recipient_key
            };
            uint8[] encrypted = GPGHelper.sign_and_encrypt_data("<signcrypt>test</signcrypt>", keys, null);
            fail_if(encrypted.length == 0, "sign_and_encrypt_data returned empty output");
            GPGHelper.DecryptedData decrypted = GPGHelper.decrypt_data(encrypted);
            string decrypted_text = (string) decrypted.data;
            fail_if_not(decrypted_text.has_prefix("<signcrypt>test</signcrypt>"),
                "decrypt_data did not return the original signcrypt XML");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "sign_and_encrypt_data must sign with the configured full primary fingerprint");
        } catch (Error e) {
            GLib.Test.message("sign_encrypt/decrypt failed: %s", e.message);
            GLib.Test.fail();
        }
    }

    private void test_encrypt_file_to_path_real_keyring() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-gpg-file-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "plain-source");
        string encrypted_path = Path.build_filename(temp_dir, "upload.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "decrypted-output");
        string plaintext = "DinoX OpenPGP file transfer payload\nbody-url=https://upload.example.test/file\n";

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary GPG file-test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            GPGHelper.Key signer_key = require_private_key(signer);
            GPGHelper.Key recipient_key = require_public_key(recipient);
            GPGHelper.Key[] keys = {
                signer_key,
                recipient_key
            };
            int64 encrypted_size = GPGHelper.encrypt_file_to_path(input_path, encrypted_path, keys, 0, "report.txt");

            fail_if(encrypted_size <= 0, "encrypt_file_to_path returned an empty output size");
            fail_if(!FileUtils.test(encrypted_path, FileTest.EXISTS),
                "encrypt_file_to_path did not create an encrypted file");

            uint8[] encrypted_data;
            FileUtils.get_data(encrypted_path, out encrypted_data);
            fail_if(contains_bytes(encrypted_data, plaintext.data),
                "encrypted OpenPGP file payload must not contain the cleartext bytes");

            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(encrypted_path, decrypted_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_path, out decrypted_text);

            fail_if_not_eq_str(decrypted_text, plaintext,
                "decrypt_file_to_path did not restore the original file payload");
            fail_if_not_eq_str(decrypted.filename, "report.txt",
                "encrypt_file_to_path must preserve the original filename in the OpenPGP payload");
            fail_if_not(decrypted.signature_valid,
                "encrypt_file_to_path output must carry a valid OpenPGP signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "encrypt_file_to_path must sign with the first/account key's full primary fingerprint");
        } catch (Error e) {
            GLib.Test.message("encrypt_file_to_path/decrypt_file_to_path failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            GPGHelper.secure_delete_file(decrypted_path);
            GPGHelper.secure_delete_file(encrypted_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_pgp_file_encryptor_legacy_real_manager_real_keyring_sync() {
        var loop = new MainLoop();
        test_pgp_file_encryptor_legacy_real_manager_real_keyring.begin((obj, res) => {
            test_pgp_file_encryptor_legacy_real_manager_real_keyring.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_pgp_file_encryptor_legacy_real_manager_real_keyring() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-encryptor-" + Uuid.string_random());
        string core_db_path = Path.build_filename(temp_dir, "core.db");
        string openpgp_db_path = Path.build_filename(temp_dir, "openpgp.db");
        string input_path = Path.build_filename(temp_dir, "plain-source");
        string encrypted_copy_path = Path.build_filename(temp_dir, "encrypted-copy.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "decrypted-output");
        string plaintext = "DinoX PgpFileEncryptor legacy payload\nbody-url=https://upload.example.test/legacy\n";
        Dino.Database? core_db = null;
        Dino.Plugins.OpenPgp.Database? openpgp_db = null;
        Dino.Entities.FileTransfer? transfer = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary PGP encryptor test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);

            core_db = new Dino.Database(core_db_path, "openpgp-live-pgp-encryptor-test");
            openpgp_db = new Dino.Plugins.OpenPgp.Database(openpgp_db_path, null);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) core_db);
            Dino.MessageProcessor.start(stream_interactor, (!) core_db);
            Dino.Plugins.OpenPgp.Manager.start(stream_interactor, (!) openpgp_db);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) core_db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.PGP;

            ((!) openpgp_db).set_account_legacy_key(account, signer);
            ((!) openpgp_db).set_contact_key(account, conversation.counterpart.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);

            transfer = new Dino.Entities.FileTransfer();
            ((!) transfer).account = account;
            ((!) transfer).counterpart = conversation.counterpart;
            ((!) transfer).ourpart = account.full_jid;
            ((!) transfer).direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
            ((!) transfer).file_name = "report.txt";
            ((!) transfer).server_file_name = "report.txt";
            ((!) transfer).encryption = Dino.Entities.Encryption.PGP;
            ((!) transfer).size = plaintext.length;
            ((!) transfer).input_stream = File.new_for_path(input_path).read();

            var encryptor = new Dino.Plugins.OpenPgp.PgpFileEncryptor(stream_interactor);
            Dino.FileMeta file_meta = yield encryptor.encrypt_file(conversation, (!) transfer);

            fail_if_not_eq_int((int) file_meta.encryption, (int) Dino.Entities.Encryption.PGP,
                "PgpFileEncryptor must mark encrypted file metadata as PGP");
            fail_if_not_eq_str(file_meta.mime_type, "application/pgp-encrypted",
                "PgpFileEncryptor must publish the OpenPGP encrypted MIME type");
            fail_if(!file_meta.upload_payload_is_encrypted,
                "PgpFileEncryptor must mark the upload payload as already encrypted");
            fail_if(file_meta.size <= 0,
                "PgpFileEncryptor must return the encrypted payload size");
            fail_if_not_eq_str(((!) transfer).server_file_name, "report.txt.pgp",
                "PgpFileEncryptor must preserve the original upload name with a .pgp suffix");
            fail_if_not_eq_str(((!) transfer).encryption_protocol, Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027,
                "PgpFileEncryptor must store the selected legacy OpenPGP file protocol on the transfer");

            write_stream_to_file(((!) transfer).input_stream, encrypted_copy_path);
            uint8[] encrypted_data;
            FileUtils.get_data(encrypted_copy_path, out encrypted_data);
            fail_if((int64) encrypted_data.length != file_meta.size,
                "copied encrypted stream size must match the returned file metadata size");
            fail_if(contains_bytes(encrypted_data, plaintext.data),
                "PgpFileEncryptor encrypted stream must not contain the cleartext bytes");
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, recipient);

            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(encrypted_copy_path, decrypted_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_path, out decrypted_text);

            fail_if_not_eq_str(decrypted_text, plaintext,
                "PgpFileEncryptor encrypted stream must decrypt back to the original payload");
            fail_if_not_eq_str(decrypted.filename, "report.txt",
                "PgpFileEncryptor must preserve the original filename in the OpenPGP payload");
            fail_if_not(decrypted.signature_valid,
                "PgpFileEncryptor output must carry a valid OpenPGP signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "PgpFileEncryptor must sign with the selected legacy account key");
        } catch (Error e) {
            GLib.Test.message("PgpFileEncryptor legacy live-keyring test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (transfer != null) {
                try {
                    ((!) transfer).input_stream.close();
                } catch (Error e) {
                    // Best-effort cleanup for the encrypted TempFileInputStream.
                }
            }
            if (openpgp_db != null) ((!) openpgp_db).close();
            if (core_db != null) ((!) core_db).close();
            GPGHelper.secure_delete_file(decrypted_path);
            GPGHelper.secure_delete_file(encrypted_copy_path);
            GPGHelper.secure_delete_file(input_path);
            FileUtils.remove(core_db_path + "-shm");
            FileUtils.remove(core_db_path + "-wal");
            FileUtils.remove(openpgp_db_path + "-shm");
            FileUtils.remove(openpgp_db_path + "-wal");
            FileUtils.remove(openpgp_db_path);
            FileUtils.remove(core_db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_pgp_file_encryptor_xep0374_real_manager_real_keyring_sync() {
        var loop = new MainLoop();
        test_pgp_file_encryptor_xep0374_real_manager_real_keyring.begin((obj, res) => {
            test_pgp_file_encryptor_xep0374_real_manager_real_keyring.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_pgp_file_encryptor_xep0374_real_manager_real_keyring() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-xep0374-encryptor-" + Uuid.string_random());
        string core_db_path = Path.build_filename(temp_dir, "core.db");
        string openpgp_db_path = Path.build_filename(temp_dir, "openpgp.db");
        string input_path = Path.build_filename(temp_dir, "plain-source");
        string encrypted_copy_path = Path.build_filename(temp_dir, "encrypted-copy.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "decrypted-output");
        string plaintext = "DinoX PgpFileEncryptor XEP-0374 payload\nbody-url=https://upload.example.test/xep0374\n";
        Dino.Database? core_db = null;
        Dino.Plugins.OpenPgp.Database? openpgp_db = null;
        Dino.Entities.FileTransfer? transfer = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary XEP-0374 PGP encryptor test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            core_db = new Dino.Database(core_db_path, "openpgp-live-pgp-xep0374-encryptor-test");
            openpgp_db = new Dino.Plugins.OpenPgp.Database(openpgp_db_path, null);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) core_db);
            Dino.MessageProcessor.start(stream_interactor, (!) core_db);
            Dino.Plugins.OpenPgp.Manager.start(stream_interactor, (!) openpgp_db);

            var account = new Dino.Entities.Account(new Xmpp.Jid(account_bare_jid), "secret");
            account.persist((!) core_db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.PGP;

            ((!) openpgp_db).set_account_xmpp_key(account, signer);
            ((!) openpgp_db).set_contact_key(account, conversation.counterpart.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) openpgp_db).mark_contact_xmpp_key_verified(account, conversation.counterpart.bare_jid);

            Dino.Plugins.OpenPgp.Manager? manager = stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the XEP-0374 encryptor test");
            }
            string block_reason;
            fail_if(((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out block_reason),
                "XEP-0374 PgpFileEncryptor must require a fresh XEP-0373 contact-key refresh before encrypting");
            fail_if(!block_reason.contains("not been refreshed"),
                "XEP-0374 pre-refresh block reason must mention the missing contact-key refresh");
            ((!) manager).mark_xep0373_key_received(account, conversation.counterpart.bare_jid);
            string allow_reason;
            fail_if(!((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out allow_reason),
                "XEP-0374 PgpFileEncryptor must allow encryption after the XEP-0373 contact-key refresh is marked");

            transfer = new Dino.Entities.FileTransfer();
            ((!) transfer).account = account;
            ((!) transfer).counterpart = conversation.counterpart;
            ((!) transfer).ourpart = account.full_jid;
            ((!) transfer).direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
            ((!) transfer).file_name = "report.txt";
            ((!) transfer).server_file_name = "report.txt";
            ((!) transfer).encryption = Dino.Entities.Encryption.PGP;
            ((!) transfer).size = plaintext.length;
            ((!) transfer).input_stream = File.new_for_path(input_path).read();

            var encryptor = new Dino.Plugins.OpenPgp.PgpFileEncryptor(stream_interactor);
            Dino.FileMeta file_meta = yield encryptor.encrypt_file(conversation, (!) transfer);

            fail_if_not_eq_int((int) file_meta.encryption, (int) Dino.Entities.Encryption.PGP,
                "PgpFileEncryptor must mark encrypted file metadata as PGP");
            fail_if_not_eq_str(file_meta.mime_type, "application/pgp-encrypted",
                "PgpFileEncryptor must publish the OpenPGP encrypted MIME type");
            fail_if(!file_meta.upload_payload_is_encrypted,
                "PgpFileEncryptor must mark the upload payload as already encrypted");
            fail_if(file_meta.size <= 0,
                "PgpFileEncryptor must return the encrypted payload size");
            fail_if_not_eq_str(((!) transfer).server_file_name, "report.txt.pgp",
                "PgpFileEncryptor must preserve the original upload name with a .pgp suffix");
            fail_if_not_eq_str(((!) transfer).encryption_protocol, Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374,
                "PgpFileEncryptor must store the selected XEP-0374 OpenPGP file protocol on the transfer");

            write_stream_to_file(((!) transfer).input_stream, encrypted_copy_path);
            uint8[] encrypted_data;
            FileUtils.get_data(encrypted_copy_path, out encrypted_data);
            fail_if((int64) encrypted_data.length != file_meta.size,
                "copied encrypted stream size must match the returned file metadata size");
            fail_if(contains_bytes(encrypted_data, plaintext.data),
                "PgpFileEncryptor encrypted stream must not contain the cleartext bytes");
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, signer);
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, recipient);

            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(encrypted_copy_path, decrypted_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_path, out decrypted_text);

            fail_if_not_eq_str(decrypted_text, plaintext,
                "PgpFileEncryptor encrypted stream must decrypt back to the original payload");
            fail_if_not_eq_str(decrypted.filename, "report.txt",
                "PgpFileEncryptor must preserve the original filename in the OpenPGP payload");
            fail_if_not(decrypted.signature_valid,
                "PgpFileEncryptor output must carry a valid OpenPGP signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "PgpFileEncryptor must sign with the selected XEP-0374 account key");
        } catch (Error e) {
            GLib.Test.message("PgpFileEncryptor XEP-0374 live-keyring test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (transfer != null) {
                try {
                    ((!) transfer).input_stream.close();
                } catch (Error e) {
                    // Best-effort cleanup for the encrypted TempFileInputStream.
                }
            }
            if (openpgp_db != null) ((!) openpgp_db).close();
            if (core_db != null) ((!) core_db).close();
            GPGHelper.secure_delete_file(decrypted_path);
            GPGHelper.secure_delete_file(encrypted_copy_path);
            GPGHelper.secure_delete_file(input_path);
            FileUtils.remove(core_db_path + "-shm");
            FileUtils.remove(core_db_path + "-wal");
            FileUtils.remove(openpgp_db_path + "-shm");
            FileUtils.remove(openpgp_db_path + "-wal");
            FileUtils.remove(openpgp_db_path);
            FileUtils.remove(core_db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_xep0373_pubsub_publish_fetch_file_send_ready_sync() {
        var loop = new MainLoop();
        test_xep0373_pubsub_publish_fetch_file_send_ready.begin((obj, res) => {
            test_xep0373_pubsub_publish_fetch_file_send_ready.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_xep0373_pubsub_publish_fetch_file_send_ready() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string contact_bare_jid = "bob@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-xep0373-pubsub-" + Uuid.string_random());
        string core_db_path = Path.build_filename(temp_dir, "core.db");
        string openpgp_db_path = Path.build_filename(temp_dir, "openpgp.db");
        string input_path = Path.build_filename(temp_dir, "plain-source");
        string encrypted_copy_path = Path.build_filename(temp_dir, "encrypted-copy.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "decrypted-output");
        string plaintext = "DinoX XEP-0373 PubSub fetch prepares OpenPGP file send\n";
        Dino.Database? core_db = null;
        Dino.Plugins.OpenPgp.Database? openpgp_db = null;
        Dino.Entities.FileTransfer? transfer = null;
        Xep0373PubsubResponder? responder = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary XEP-0373 PubSub test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);
            require_xmpp_uid(recipient, contact_bare_jid);

            string? own_key_data_base64 = GPGHelper.export_public_key_data_base64(signer);
            string? contact_key_data_base64 = GPGHelper.export_public_key_data_base64(recipient);
            if (own_key_data_base64 == null || ((!) own_key_data_base64).length == 0 ||
                    contact_key_data_base64 == null || ((!) contact_key_data_base64).length == 0) {
                throw new IOError.FAILED("Live OpenPGP PubSub test could not export raw XEP-0373 public key data");
            }
            delete_secret_and_public_key(recipient);
            fail_if(GPGHelper.get_public_key(recipient) != null,
                "XEP-0373 PubSub fetch test must start without the contact key in the local keyring");
            fail_if(GPGHelper.get_private_key(recipient) != null,
                "XEP-0373 PubSub fetch test must remove the contact secret key before importing remote public key data");

            core_db = new Dino.Database(core_db_path, "openpgp-live-xep0373-pubsub-test");
            openpgp_db = new Dino.Plugins.OpenPgp.Database(openpgp_db_path, null);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) core_db);
            Dino.MessageProcessor.start(stream_interactor, (!) core_db);
            Dino.Plugins.OpenPgp.Manager.start(stream_interactor, (!) openpgp_db);

            var account = new Dino.Entities.Account(new Xmpp.Jid(account_bare_jid), "secret");
            account.persist((!) core_db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid(contact_bare_jid), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.PGP;

            ((!) openpgp_db).set_account_xmpp_key(account, signer);

            Dino.Plugins.OpenPgp.Manager? manager = stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the XEP-0373 PubSub test");
            }

            TestXmppStream stream = create_connected_openpgp_pubsub_stream(stream_interactor, account);
            var xep0373_manager = new Dino.Plugins.OpenPgp.Xep0373KeyManager(stream_interactor, (!) openpgp_db);
            ((!) manager).xep0373_manager = xep0373_manager;
            xep0373_manager.key_received.connect((received_account, jid, fingerprint, key_data) => {
                ((!) openpgp_db).set_contact_key(received_account, jid.bare_jid, fingerprint,
                    Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, false);
                ((!) manager).mark_xep0373_key_received(received_account, jid);
                ((!) manager).notify_key_state_changed(received_account, jid.bare_jid);
            });

            string prefetch_reason;
            fail_if(((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out prefetch_reason),
                "OpenPGP file send readiness must be blocked before XEP-0373 fetch/import marks the contact key fresh");
            fail_if(!prefetch_reason.contains("OpenPGP-for-XMPP key"),
                "pre-fetch block reason must stay scoped to missing OpenPGP-for-XMPP contact-key readiness");

            responder = new Xep0373PubsubResponder(stream, signer, (!) own_key_data_base64, recipient, (!) contact_key_data_base64);

            Xmpp.Xep.OpenPgp.Module? openpgp_pubsub_module = stream.get_module<Xmpp.Xep.OpenPgp.Module>(
                Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (openpgp_pubsub_module == null) {
                throw new IOError.FAILED("XEP-0373 PubSub module was not attached to the test stream");
            }

            bool published = yield ((!) openpgp_pubsub_module).publish_key_data(stream, signer, (!) own_key_data_base64);
            fail_if(!published,
                "XEP-0373 publish_key_data must complete both key-data and metadata PubSub publishes");
            fail_if(!((!) responder).own_key_data_published,
                "XEP-0373 publish must send raw public-key data to the fingerprint-specific PubSub node");
            fail_if(!((!) responder).own_metadata_published,
                "XEP-0373 publish must update the public-keys metadata node with item id current");
            fail_if(!((!) responder).own_publish_options_open_persistent,
                "XEP-0373 publish must request open, persistent, single-item PubSub nodes");
            fail_if(GPGHelper.get_public_key(recipient) != null,
                "XEP-0373 own-key publish must not make the contact key available before PubSub fetch");

            bool imported = yield xep0373_manager.request_keys_if_needed(account, conversation.counterpart.bare_jid);
            fail_if(!imported,
                "XEP-0373 lazy request must import the advertised contact key from PubSub");
            fail_if(GPGHelper.get_public_key(recipient) == null,
                "XEP-0373 lazy request must import the advertised contact key into the local keyring");
            fail_if(((!) responder).metadata_request_count != 1,
                "XEP-0373 lazy request must fetch the contact public-keys metadata once");
            fail_if(((!) responder).key_data_request_count != 1,
                "XEP-0373 lazy request must fetch the advertised contact key-data node once");
            fail_if(!((!) openpgp_db).has_contact_xmpp_key(account, conversation.counterpart.bare_jid),
                "XEP-0373 key_received wiring must store the fetched contact key as XMPP key state");
            fail_if_not_eq_str(recipient, normalize_openpgp_fingerprint(((!) openpgp_db).get_contact_xmpp_key(account, conversation.counterpart.bare_jid) ?? ""),
                "XEP-0373 fetch must store the advertised full contact fingerprint");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373,
                ((!) openpgp_db).get_contact_key_source(account, conversation.counterpart.bare_jid),
                "XEP-0373 fetch must store the contact key with the XEP-0373 source");
            fail_if(((!) openpgp_db).has_contact_legacy_key(account, conversation.counterpart.bare_jid),
                "XEP-0373 fetch must not populate legacy XEP-0027 contact-key state");
            fail_if(!((!) manager).contact_xmpp_key_was_refreshed_this_session(account, conversation.counterpart),
                "XEP-0373 fetch must mark the contact key fresh for this send session");

            int metadata_requests_after_import = ((!) responder).metadata_request_count;
            bool duplicate_imported = yield xep0373_manager.request_keys_if_needed(account, conversation.counterpart.bare_jid);
            fail_if(duplicate_imported,
                "XEP-0373 lazy request must not repeat a contact-key fetch after the session already refreshed it");
            fail_if(((!) responder).metadata_request_count != metadata_requests_after_import,
                "XEP-0373 duplicate lazy request must not emit another PubSub metadata request");

            string unverified_reason;
            fail_if(((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out unverified_reason),
                "OpenPGP file send readiness must stay blocked until the freshly fetched XEP-0373 contact key is verified");
            fail_if(!unverified_reason.contains("not verified"),
                "post-fetch pre-verify block reason must stay scoped to unverified XEP-0373 contact-key trust");
            ((!) openpgp_db).mark_contact_xmpp_key_verified(account, conversation.counterpart.bare_jid);

            string ready_reason;
            fail_if(!((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out ready_reason),
                "OpenPGP file send readiness must be allowed after the XEP-0373 PubSub fetch/import and verification boundaries");

            transfer = new Dino.Entities.FileTransfer();
            ((!) transfer).account = account;
            ((!) transfer).counterpart = conversation.counterpart;
            ((!) transfer).ourpart = account.full_jid;
            ((!) transfer).direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
            ((!) transfer).file_name = "pubsub-report.txt";
            ((!) transfer).server_file_name = "pubsub-report.txt";
            ((!) transfer).encryption = Dino.Entities.Encryption.PGP;
            ((!) transfer).size = plaintext.length;
            ((!) transfer).input_stream = File.new_for_path(input_path).read();

            var encryptor = new Dino.Plugins.OpenPgp.PgpFileEncryptor(stream_interactor);
            Dino.FileMeta file_meta = yield encryptor.encrypt_file(conversation, (!) transfer);
            fail_if_not_eq_str(((!) transfer).encryption_protocol, Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374,
                "OpenPGP file send after XEP-0373 fetch must use the XEP-0374 file protocol");
            fail_if_not_eq_str(file_meta.mime_type, "application/pgp-encrypted",
                "OpenPGP file send after XEP-0373 fetch must still produce PGP upload metadata");
            fail_if(!file_meta.upload_payload_is_encrypted,
                "OpenPGP file send after XEP-0373 fetch must mark the upload payload as already encrypted");

            write_stream_to_file(((!) transfer).input_stream, encrypted_copy_path);
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, signer,
                "XEP-0373 fetched file-send packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, recipient,
                "XEP-0373 fetched file-send packet must include the PubSub-fetched contact recipient key");
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(encrypted_copy_path, decrypted_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "OpenPGP file send after XEP-0373 PubSub fetch must decrypt back to the original payload");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "OpenPGP file send after XEP-0373 PubSub fetch must be signed by the account key");
        } catch (Error e) {
            GLib.Test.message("XEP-0373 PubSub file-send readiness live-keyring test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (responder != null) ((!) responder).detach();
            if (transfer != null) {
                try {
                    ((!) transfer).input_stream.close();
                } catch (Error e) {
                    // Best-effort cleanup for the encrypted TempFileInputStream.
                }
            }
            if (openpgp_db != null) ((!) openpgp_db).close();
            if (core_db != null) ((!) core_db).close();
            GPGHelper.secure_delete_file(decrypted_path);
            GPGHelper.secure_delete_file(encrypted_copy_path);
            GPGHelper.secure_delete_file(input_path);
            FileUtils.remove(core_db_path + "-shm");
            FileUtils.remove(core_db_path + "-wal");
            FileUtils.remove(openpgp_db_path + "-shm");
            FileUtils.remove(openpgp_db_path + "-wal");
            FileUtils.remove(openpgp_db_path);
            FileUtils.remove(core_db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_xep0027_presence_discovery_file_send_ready_sync() {
        var loop = new MainLoop();
        test_xep0027_presence_discovery_file_send_ready.begin((obj, res) => {
            test_xep0027_presence_discovery_file_send_ready.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_xep0027_presence_discovery_file_send_ready() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string contact_bare_jid = "bob@example.test";
        string contact_full_jid = contact_bare_jid + "/dinox";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-xep0027-presence-" + Uuid.string_random());
        string core_db_path = Path.build_filename(temp_dir, "core.db");
        string openpgp_db_path = Path.build_filename(temp_dir, "openpgp.db");
        string input_path = Path.build_filename(temp_dir, "plain-source");
        string encrypted_copy_path = Path.build_filename(temp_dir, "encrypted-copy.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "decrypted-output");
        string plaintext = "DinoX XEP-0027 signed-presence discovery prepares legacy OpenPGP file send\n";
        Dino.Database? core_db = null;
        Dino.Plugins.OpenPgp.Database? openpgp_db = null;
        Dino.Entities.FileTransfer? transfer = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary XEP-0027 signed-presence test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_private_key(recipient);
            require_email_uid(signer);
            require_email_uid(recipient);

            core_db = new Dino.Database(core_db_path, "openpgp-live-xep0027-presence-test");
            openpgp_db = new Dino.Plugins.OpenPgp.Database(openpgp_db_path, null);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) core_db);
            Dino.MessageProcessor.start(stream_interactor, (!) core_db);
            Dino.Plugins.OpenPgp.Manager.start(stream_interactor, (!) openpgp_db);

            var account = new Dino.Entities.Account(new Xmpp.Jid(account_bare_jid), "secret");
            account.persist((!) core_db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid(contact_bare_jid), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.PGP;

            ((!) openpgp_db).set_account_legacy_key(account, signer);

            Dino.Plugins.OpenPgp.Manager? manager = stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the XEP-0027 presence test");
            }

            TestXmppStream stream = create_connected_legacy_presence_stream(stream_interactor, account, (!) openpgp_db, (!) manager);
            string pre_presence_reason;
            fail_if(((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out pre_presence_reason),
                "XEP-0027 file send readiness must be blocked before signed presence announces the contact key");
            fail_if(!pre_presence_reason.contains("no legacy OpenPGP/XEP-0027 key"),
                "pre-presence block reason must stay scoped to missing legacy contact-key readiness");

            ((!) openpgp_db).set_contact_key(account, conversation.counterpart.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_KEYSERVER, false, false);
            fail_if(!((!) openpgp_db).has_contact_legacy_key(account, conversation.counterpart.bare_jid),
                "stored keyserver state must populate only the legacy contact-key slot");
            fail_if(((!) openpgp_db).contact_legacy_key_is_announced(account, conversation.counterpart.bare_jid),
                "stored keyserver state must not be treated as currently announced before signed presence");
            fail_if(((!) openpgp_db).has_contact_xmpp_key(account, conversation.counterpart.bare_jid),
                "stored keyserver state must not populate XEP-0373/XEP-0374 contact-key state");
            string inactive_stored_reason;
            fail_if(((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out inactive_stored_reason),
                "XEP-0027 file send readiness must remain blocked for a stored but inactive keyserver key");
            fail_if(!inactive_stored_reason.contains("not currently active"),
                "stored-but-inactive block reason must mention inactive legacy XEP-0027 presence state");

            string presence_status = "available for DinoX XEP-0027 file-transfer proof";
            string signature = create_legacy_presence_signature(presence_status, recipient);
            stream.emit_presence_stanza(create_legacy_presence_stanza(contact_full_jid, presence_status, signature).stanza);

            string ready_reason = "";
            bool ready = wait_for_legacy_readiness((!) manager, conversation, 15000, out ready_reason);
            fail_if(!ready,
                "verified XEP-0027 signed presence must activate legacy OpenPGP file send readiness; last reason: %s".printf(ready_reason));
            fail_if(!((!) openpgp_db).has_contact_legacy_key(account, conversation.counterpart.bare_jid),
                "verified XEP-0027 signed presence must store a legacy contact key");
            fail_if_not_eq_str(recipient, normalize_openpgp_fingerprint(((!) openpgp_db).get_contact_legacy_key(account, conversation.counterpart.bare_jid) ?? ""),
                "verified XEP-0027 signed presence must store the contact's full legacy fingerprint");
            fail_if(!((!) openpgp_db).contact_legacy_key_is_announced(account, conversation.counterpart.bare_jid),
                "verified XEP-0027 signed presence must mark the legacy contact key as currently announced");
            string legacy_source = ((!) openpgp_db).get_contact_key_source(account, conversation.counterpart.bare_jid);
            fail_if(!Dino.Plugins.OpenPgp.Database.is_legacy_source(legacy_source),
                "verified XEP-0027 signed presence must keep the contact key in legacy/keyserver source state");
            fail_if(((!) openpgp_db).has_contact_xmpp_key(account, conversation.counterpart.bare_jid),
                "XEP-0027 signed presence must not populate XEP-0373/XEP-0374 contact-key state");

            transfer = new Dino.Entities.FileTransfer();
            ((!) transfer).account = account;
            ((!) transfer).counterpart = conversation.counterpart;
            ((!) transfer).ourpart = account.full_jid;
            ((!) transfer).direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
            ((!) transfer).file_name = "legacy-presence-report.txt";
            ((!) transfer).server_file_name = "legacy-presence-report.txt";
            ((!) transfer).encryption = Dino.Entities.Encryption.PGP;
            ((!) transfer).size = plaintext.length;
            ((!) transfer).input_stream = File.new_for_path(input_path).read();

            var encryptor = new Dino.Plugins.OpenPgp.PgpFileEncryptor(stream_interactor);
            Dino.FileMeta file_meta = yield encryptor.encrypt_file(conversation, (!) transfer);
            fail_if_not_eq_str(((!) transfer).encryption_protocol, Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027,
                "OpenPGP file send after XEP-0027 signed presence must use the legacy file protocol");
            fail_if_not_eq_str(file_meta.mime_type, "application/pgp-encrypted",
                "OpenPGP file send after XEP-0027 signed presence must still produce PGP upload metadata");
            fail_if(!file_meta.upload_payload_is_encrypted,
                "OpenPGP file send after XEP-0027 signed presence must mark the upload payload as already encrypted");

            write_stream_to_file(((!) transfer).input_stream, encrypted_copy_path);
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, signer,
                "XEP-0027 signed-presence file-send packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, recipient,
                "XEP-0027 signed-presence file-send packet must include the announced contact recipient key");
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(encrypted_copy_path, decrypted_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "OpenPGP file send after XEP-0027 signed presence must decrypt back to the original payload");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "OpenPGP file send after XEP-0027 signed presence must be signed by the account key");

            stream.emit_presence_stanza(create_unavailable_presence_stanza(contact_full_jid).stanza);
            fail_if(!wait_for_legacy_announcement_state((!) openpgp_db, account, conversation.counterpart.bare_jid, false, 5000),
                "unavailable presence must clear only the current XEP-0027 announcement state");
            fail_if(!((!) openpgp_db).has_contact_legacy_key(account, conversation.counterpart.bare_jid),
                "unavailable presence must preserve the stored legacy contact key");
            string inactive_reason;
            fail_if(((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out inactive_reason),
                "XEP-0027 file send readiness must block again after the contact presence becomes unavailable");
            fail_if(!inactive_reason.contains("not currently active"),
                "post-unavailable block reason must mention inactive legacy XEP-0027 presence state");
        } catch (Error e) {
            GLib.Test.message("XEP-0027 signed-presence file-send readiness live-keyring test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (transfer != null) {
                try {
                    ((!) transfer).input_stream.close();
                } catch (Error e) {
                    // Best-effort cleanup for the encrypted TempFileInputStream.
                }
            }
            if (openpgp_db != null) ((!) openpgp_db).close();
            if (core_db != null) ((!) core_db).close();
            GPGHelper.secure_delete_file(decrypted_path);
            GPGHelper.secure_delete_file(encrypted_copy_path);
            GPGHelper.secure_delete_file(input_path);
            FileUtils.remove(core_db_path + "-shm");
            FileUtils.remove(core_db_path + "-wal");
            FileUtils.remove(openpgp_db_path + "-shm");
            FileUtils.remove(openpgp_db_path + "-wal");
            FileUtils.remove(openpgp_db_path);
            FileUtils.remove(core_db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_xep0027_keyserver_fetch_file_send_ready_sync() {
        var loop = new MainLoop();
        test_xep0027_keyserver_fetch_file_send_ready.begin((obj, res) => {
            test_xep0027_keyserver_fetch_file_send_ready.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_xep0027_keyserver_fetch_file_send_ready() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string contact_bare_jid = "bob@example.test";
        string contact_full_jid = contact_bare_jid + "/remote-keyserver";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-xep0027-keyserver-" + Uuid.string_random());
        string client_gnupg_home = Path.build_filename(temp_dir, "client-gnupg");
        string core_db_path = Path.build_filename(temp_dir, "core.db");
        string openpgp_db_path = Path.build_filename(temp_dir, "openpgp.db");
        string input_path = Path.build_filename(temp_dir, "plain-source");
        string encrypted_copy_path = Path.build_filename(temp_dir, "encrypted-copy.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "decrypted-output");
        string incoming_plain_path = Path.build_filename(temp_dir, "incoming-plain-source");
        string incoming_encrypted_path = Path.build_filename(temp_dir, "incoming-remote.pgp");
        string incoming_decrypted_path = Path.build_filename(temp_dir, "incoming-decrypted-output");
        string plaintext = "DinoX XEP-0027 keyserver fetch prepares legacy OpenPGP file send\n";
        string incoming_plaintext = "DinoX XEP-0027 keyserver fetch validates incoming OpenPGP file receive\n";
        string? original_gnupg_home = null;
        Dino.Database? core_db = null;
        Dino.Plugins.OpenPgp.Database? openpgp_db = null;
        Dino.Entities.FileTransfer? transfer = null;
        Dino.Entities.FileTransfer? received_transfer = null;
        Soup.Server? keyserver = null;
        bool homedir_overridden = false;

        try {
            original_gnupg_home = GPGHelper.get_homedir_path();
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1 ||
                    DirUtils.create_with_parents(client_gnupg_home, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary XEP-0027 keyserver test directory");
            }
            FileUtils.set_contents(input_path, plaintext);
            FileUtils.set_contents(incoming_plain_path, incoming_plaintext);

            require_private_key(signer);
            require_private_key(recipient);
            require_email_uid(signer);
            require_email_uid(recipient);

            string? recipient_public_key = GPGHelper.export_public_key(recipient);
            if (recipient_public_key == null || ((!) recipient_public_key).length == 0) {
                throw new IOError.FAILED("Live XEP-0027 keyserver test could not export the recipient public key");
            }
            string signer_secret_key = export_secret_key_for_tests(signer);
            GPGHelper.Key incoming_signer_key = require_private_key(recipient);
            GPGHelper.Key incoming_recipient_key = require_public_key(signer);
            GPGHelper.Key[] incoming_keys = {
                incoming_signer_key,
                incoming_recipient_key
            };
            GPGHelper.encrypt_file_to_path(incoming_plain_path, incoming_encrypted_path, incoming_keys, 0,
                "remote-keyserver-report.txt");

            string presence_status = "available for DinoX XEP-0027 remote keyserver file-transfer proof";
            string signature = create_legacy_presence_signature(presence_status, recipient);

            var keyserver_capture = new HkpKeyserverCapture();
            string keyserver_url;
            keyserver = start_hkp_keyserver((!) recipient_public_key, keyserver_capture, out keyserver_url);

            GPGHelper.set_homedir_path_for_tests(client_gnupg_home);
            GPGHelper.set_keyserver_for_tests(keyserver_url);
            homedir_overridden = true;

            fail_if(!GPGHelper.import_key(signer_secret_key),
                "XEP-0027 keyserver test must import the account secret key into the isolated client keyring");
            fail_if(GPGHelper.get_public_key(recipient) != null,
                "XEP-0027 keyserver test must start without the contact public key in the isolated client keyring");

            core_db = new Dino.Database(core_db_path, "openpgp-live-xep0027-keyserver-test");
            openpgp_db = new Dino.Plugins.OpenPgp.Database(openpgp_db_path, null);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) core_db);
            Dino.MessageProcessor.start(stream_interactor, (!) core_db);
            Dino.Plugins.OpenPgp.Manager.start(stream_interactor, (!) openpgp_db);

            var account = new Dino.Entities.Account(new Xmpp.Jid(account_bare_jid), "secret");
            account.persist((!) core_db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid(contact_bare_jid), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.PGP;

            ((!) openpgp_db).set_account_legacy_key(account, signer);

            Dino.Plugins.OpenPgp.Manager? manager = stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the XEP-0027 keyserver test");
            }

            TestXmppStream stream = create_connected_legacy_presence_stream(stream_interactor, account, (!) openpgp_db, (!) manager);
            string pre_fetch_reason;
            fail_if(((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out pre_fetch_reason),
                "XEP-0027 file send readiness must be blocked before the contact key is fetched from keyserver");
            fail_if(!pre_fetch_reason.contains("no legacy OpenPGP/XEP-0027 key"),
                "pre-keyserver block reason must stay scoped to missing legacy contact-key readiness");

            stream.emit_presence_stanza(create_legacy_presence_stanza(contact_full_jid, presence_status, signature).stanza);

            fail_if(!wait_for_legacy_announcement_state((!) openpgp_db, account, conversation.counterpart.bare_jid, true, 20000),
                "verified XEP-0027 signed presence must fetch/import the missing keyserver key and mark it announced");
            string ready_reason = "";
            fail_if(!((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out ready_reason),
                "verified XEP-0027 signed presence must enable file send readiness after keyserver import; last reason: %s".printf(ready_reason));
            fail_if(keyserver_capture.request_count == 0,
                "XEP-0027 keyserver readiness must request the missing contact key from the configured keyserver");
            fail_if(keyserver_capture.last_method != "GET" || keyserver_capture.last_path != "/pks/lookup",
                "XEP-0027 keyserver readiness must use the configured local HKP lookup endpoint");
            fail_if(GPGHelper.get_public_key(recipient) == null,
                "XEP-0027 keyserver readiness must import the remote contact key into the isolated client keyring");
            fail_if(!((!) openpgp_db).has_contact_legacy_key(account, conversation.counterpart.bare_jid),
                "XEP-0027 keyserver fetch must store a legacy contact key");
            fail_if_not_eq_str(recipient, normalize_openpgp_fingerprint(((!) openpgp_db).get_contact_legacy_key(account, conversation.counterpart.bare_jid) ?? ""),
                "XEP-0027 keyserver fetch must store the imported full contact fingerprint");
            fail_if(!((!) openpgp_db).contact_legacy_key_is_announced(account, conversation.counterpart.bare_jid),
                "XEP-0027 keyserver fetch must mark the imported key as currently announced");
            fail_if(((!) openpgp_db).has_contact_xmpp_key(account, conversation.counterpart.bare_jid),
                "XEP-0027 keyserver fetch must not populate XEP-0373/XEP-0374 contact-key state");

            transfer = new Dino.Entities.FileTransfer();
            ((!) transfer).account = account;
            ((!) transfer).counterpart = conversation.counterpart;
            ((!) transfer).ourpart = account.full_jid;
            ((!) transfer).direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
            ((!) transfer).file_name = "legacy-keyserver-report.txt";
            ((!) transfer).server_file_name = "legacy-keyserver-report.txt";
            ((!) transfer).encryption = Dino.Entities.Encryption.PGP;
            ((!) transfer).size = plaintext.length;
            ((!) transfer).input_stream = File.new_for_path(input_path).read();

            var encryptor = new Dino.Plugins.OpenPgp.PgpFileEncryptor(stream_interactor);
            Dino.FileMeta file_meta = yield encryptor.encrypt_file(conversation, (!) transfer);
            fail_if_not_eq_str(((!) transfer).encryption_protocol, Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027,
                "OpenPGP file send after XEP-0027 keyserver fetch must use the legacy file protocol");
            fail_if_not_eq_str(file_meta.mime_type, "application/pgp-encrypted",
                "OpenPGP file send after XEP-0027 keyserver fetch must produce PGP upload metadata");
            fail_if(!file_meta.upload_payload_is_encrypted,
                "OpenPGP file send after XEP-0027 keyserver fetch must mark the upload payload as already encrypted");

            write_stream_to_file(((!) transfer).input_stream, encrypted_copy_path);
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, signer,
                "XEP-0027 keyserver file-send packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(encrypted_copy_path, recipient,
                "XEP-0027 keyserver file-send packet must include the fetched contact recipient key");
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(encrypted_copy_path, decrypted_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "OpenPGP file send after XEP-0027 keyserver fetch must decrypt back to the original payload");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "OpenPGP file send after XEP-0027 keyserver fetch must be signed by the account key");

            received_transfer = new Dino.Entities.FileTransfer();
            ((!) received_transfer).account = account;
            ((!) received_transfer).counterpart = conversation.counterpart;
            ((!) received_transfer).ourpart = account.full_jid;
            ((!) received_transfer).direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            ((!) received_transfer).file_name = "remote-keyserver-report.txt.pgp";
            ((!) received_transfer).server_file_name = "remote-keyserver-report.txt.pgp";
            ((!) received_transfer).encryption = Dino.Entities.Encryption.PGP;
            ((!) received_transfer).encryption_protocol = Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027;

            var decryptor = new Dino.Plugins.OpenPgp.PgpFileDecryptor(stream_interactor, (!) openpgp_db);
            InputStream clear_receive_stream = yield decryptor.decrypt_file(
                File.new_for_path(incoming_encrypted_path).read(),
                conversation,
                (!) received_transfer,
                new Dino.FileReceiveData());
            write_stream_to_file(clear_receive_stream, incoming_decrypted_path);
            clear_receive_stream.close();
            string incoming_decrypted_text;
            FileUtils.get_contents(incoming_decrypted_path, out incoming_decrypted_text);
            fail_if_not_eq_str(incoming_plaintext, incoming_decrypted_text,
                "OpenPGP file receive after XEP-0027 keyserver fetch must decrypt the remote signed payload");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027, ((!) received_transfer).encryption_protocol,
                "OpenPGP file receive after XEP-0027 keyserver fetch must preserve the legacy file protocol");
        } catch (Error e) {
            GLib.Test.message("XEP-0027 keyserver file-send readiness live-keyring test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            GPGHelper.set_keyserver_for_tests(null);
            if (homedir_overridden) {
                GPGHelper.set_homedir_path_for_tests(original_gnupg_home);
            }
            if (keyserver != null) ((!) keyserver).disconnect();
            if (transfer != null) {
                try {
                    ((!) transfer).input_stream.close();
                } catch (Error e) {
                    // Best-effort cleanup for the encrypted TempFileInputStream.
                }
            }
            if (openpgp_db != null) ((!) openpgp_db).close();
            if (core_db != null) ((!) core_db).close();
            GPGHelper.secure_delete_file(incoming_decrypted_path);
            GPGHelper.secure_delete_file(incoming_encrypted_path);
            GPGHelper.secure_delete_file(incoming_plain_path);
            GPGHelper.secure_delete_file(decrypted_path);
            GPGHelper.secure_delete_file(encrypted_copy_path);
            GPGHelper.secure_delete_file(input_path);
            FileUtils.remove(core_db_path + "-shm");
            FileUtils.remove(core_db_path + "-wal");
            FileUtils.remove(openpgp_db_path + "-shm");
            FileUtils.remove(openpgp_db_path + "-wal");
            FileUtils.remove(openpgp_db_path);
            FileUtils.remove(core_db_path);
            DirUtils.remove(client_gnupg_home);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_file_manager_http_send_xep0374_real_encryptor_invalid_upload_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0374_real_encryptor_invalid_upload.begin((obj, res) => {
            test_file_manager_http_send_xep0374_real_encryptor_invalid_upload.end(res);
            loop.quit();
        });
        loop.run();
    }

    private void test_file_manager_http_send_openpgp_groupchat_rejected_before_slot_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_openpgp_muc_semantic_rejected_before_slot.begin(
            Dino.Entities.Conversation.Type.GROUPCHAT,
            "public-room@conference.example.test",
            "public groupchat",
            "openpgp-groupchat-boundary.txt",
            "OpenPGP MUC file transfers require live private members-only non-anonymous room features",
            (obj, res) => {
                test_file_manager_http_send_openpgp_muc_semantic_rejected_before_slot.end(res);
                loop.quit();
            });
        loop.run();
    }

    private void test_file_manager_http_send_openpgp_private_muc_rejected_before_slot_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_openpgp_muc_semantic_rejected_before_slot.begin(
            Dino.Entities.Conversation.Type.GROUPCHAT_PM,
            "private-room@conference.example.test/bob",
            "private-MUC PM",
            "openpgp-private-muc-boundary.txt",
            "OpenPGP MUC-PM file transfers require a cached real JID for the room occupant",
            (obj, res) => {
                test_file_manager_http_send_openpgp_muc_semantic_rejected_before_slot.end(res);
                loop.quit();
            });
        loop.run();
    }

    private void test_file_manager_http_send_xep0374_private_muc_rejects_account_key_without_account_uid_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0374_private_muc_rejects_account_key_without_account_uid.begin((obj, res) => {
            test_file_manager_http_send_xep0374_private_muc_rejects_account_key_without_account_uid.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_file_manager_http_send_xep0374_private_muc_rejects_account_key_without_account_uid() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-private-muc-invalid-account-key-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-openpgp-invalid-account-key.txt");
        string plaintext = "DinoX private-MUC OpenPGP invalid account-key fail-closed\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        ulong wrote_node_handler_id = 0;
        bool saw_slot_request = false;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary private-MUC invalid account-key test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_public_key(recipient);
            require_xmpp_uid(recipient, "bob@example.test");

            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            setup = create_file_manager_http_setup(account_bare_jid, recipient, recipient);
            ((!) setup).conversation = new Dino.Entities.Conversation(
                room_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the private-MUC invalid account-key test");
            }
            ((!) pgp_manager).mark_xep0373_key_received(((!) setup).account, bob_jid);
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            wrote_node_handler_id = ((!) setup).stream.wrote_node.connect((outgoing) => {
                if (outgoing.name == "iq" && outgoing.get_subnode("request", NS_HTTP_UPLOAD_0) != null) {
                    saw_slot_request = true;
                }
            });

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*send_file: file encryption rejected:*required xmpp:*");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error:*required xmpp:*");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-openpgp-invalid-account-key.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "private-MUC invalid account-key test must publish only the local stored transfer before failing");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(saw_slot_request,
                "private-MUC invalid account-key test must fail before requesting an HTTP upload slot");
            fail_if(stream_has_message_stanza(((!) setup).stream),
                "private-MUC invalid account-key test must fail before announcing a body URL message");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ENCRYPTING),
                "private-MUC invalid account-key test must fail before the external encryptor opens the payload stream");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "private-MUC invalid account-key test must fail before slot, upload, announce or complete");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "private-MUC invalid account-key transfer must end in FAILED");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "private-MUC invalid account-key transfer must persist FAILED state");
            fail_if(file_transfer.phase_error == null || !((!) file_transfer.phase_error).contains("required xmpp: user ID"),
                "private-MUC invalid account-key transfer must surface the account-key UID validation failure");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "private-MUC invalid account-key transfer must not link an announced body-url message");
            assert_no_persisted_sources(((!) setup).core_db, file_transfer,
                "private-MUC invalid account-key transfer must not persist HTTP sources");
        } catch (Error e) {
            GLib.Test.message("private-MUC invalid account-key FileManager test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null && wrote_node_handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, wrote_node_handler_id);
            }
            if (setup != null) ((!) setup).cleanup();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private async void test_file_manager_http_send_openpgp_muc_semantic_rejected_before_slot(
        Dino.Entities.Conversation.Type conversation_type,
        string counterpart_jid,
        string label,
        string file_basename,
        string expected_error) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-groupchat-filemanager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, file_basename);
        string plaintext = "DinoX OpenPGP %s file-send fail-closed boundary\n".printf(label);
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        ulong wrote_node_handler_id = 0;
        bool saw_slot_request = false;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary OpenPGP %s FileManager test directory".printf(label));
            }
            FileUtils.set_contents(input_path, plaintext);

            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            ((!) setup).conversation = new Dino.Entities.Conversation(
                new Xmpp.Jid(counterpart_jid),
                ((!) setup).account,
                conversation_type);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;

            if (conversation_type == Dino.Entities.Conversation.Type.GROUPCHAT) {
                Xmpp.Jid room_jid = ((!) setup).conversation.counterpart.bare_jid;
                Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
                attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
                query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, false);
                emit_openpgp_muc_presence_for_tests(((!) setup).stream, room_jid.with_resource("bob"), bob_jid, "member");
                Dino.MucManager? muc_manager = ((!) setup).stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
                fail_if(muc_manager == null,
                    "OpenPGP public groupchat fail-closed proof requires MucManager");
                Xmpp.Jid? cached_real_jid = ((!) muc_manager).get_real_jid(room_jid.with_resource("bob"), ((!) setup).account);
                fail_if(cached_real_jid == null || !((!) cached_real_jid).equals_bare(bob_jid),
                    "OpenPGP public groupchat fail-closed proof requires Bob's cached MUC real JID");
                require_openpgp_manager((!) setup).mark_xep0373_key_received(((!) setup).account, bob_jid);
                drain_pending_events();
            } else if (conversation_type == Dino.Entities.Conversation.Type.GROUPCHAT_PM) {
                // Reach the OpenPGP recipient check with a valid live PM target,
                // while deliberately withholding the occupant's real JID.
                ((!) setup).account.enabled = true;
                Xmpp.Jid occupant_jid = ((!) setup).conversation.counterpart;
                Xmpp.Jid room_jid = occupant_jid.bare_jid;
                attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
                emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, null, "member");
                drain_pending_events();
                Dino.MucManager? muc_manager = ((!) setup).stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
                if (muc_manager == null) {
                    throw new IOError.FAILED("OpenPGP MUC-PM fail-closed proof requires MucManager");
                }
                // This fixture bypasses the room-join worker, so provide only
                // its anonymous session identity through the existing test hook.
                ((!) muc_manager).remember_private_message_peer_identity_for_tests(
                    ((!) setup).account, occupant_jid, "session:openpgp-missing-real-jid");
                ((!) setup).conversation.muc_pm_peer_identity = ((!) muc_manager).get_private_message_peer_identity(
                    ((!) setup).account, occupant_jid);
                fail_if(!((!) muc_manager).is_current_occupant(((!) setup).account, room_jid, occupant_jid),
                    "OpenPGP MUC-PM fail-closed proof requires a current occupant in the joined room");
                fail_if(((!) setup).conversation.muc_pm_peer_identity == null,
                    "OpenPGP MUC-PM fail-closed proof requires a bound live PM identity");
                fail_if(((!) muc_manager).get_real_jid(occupant_jid, ((!) setup).account) != null,
                    "OpenPGP MUC-PM fail-closed proof must retain the missing real-JID recipient");
            }
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            wrote_node_handler_id = ((!) setup).stream.wrote_node.connect((outgoing) => {
                if (outgoing.name == "iq" && outgoing.get_subnode("request", NS_HTTP_UPLOAD_0) != null) {
                    saw_slot_request = true;
                }
            });

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*send_file: file encryption rejected:*");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: %s*".printf(expected_error));

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = file_basename;
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "OpenPGP %s file-send boundary must publish only the local stored transfer before failing".printf(label));
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(saw_slot_request,
                "OpenPGP %s file sends must fail before requesting an HTTP upload slot".printf(label));
            fail_if(stream_has_message_stanza(((!) setup).stream),
                "OpenPGP %s file sends must fail before announcing a body URL message".printf(label));
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "OpenPGP %s file sends must end in FAILED".printf(label));
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "OpenPGP %s file sends must persist FAILED state".printf(label));
            fail_if(file_transfer.phase_error == null || !((!) file_transfer.phase_error).contains(expected_error),
                "OpenPGP %s file-send boundary must surface the fail-closed pipeline error".printf(label));
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "OpenPGP %s file-send boundary must not link an announced body-url message".printf(label));
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "OpenPGP %s file-send boundary must not assign a wire file-sharing id".printf(label));
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "OpenPGP %s file-send boundary must fail before slot, upload, announce or complete".printf(label));
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the OpenPGP %s upload stream after fail-closed rejection".printf(label));
            assert_no_persisted_sources(((!) setup).core_db, file_transfer,
                "OpenPGP %s fail-closed send must not persist HTTP sources".printf(label));
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist OpenPGP %s fail-closed sends as failed".printf(label));
        } catch (Error e) {
            GLib.Test.message("OpenPGP %s FileManager fail-closed boundary test failed: %s", label, e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null && wrote_node_handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, wrote_node_handler_id);
            }
            if (setup != null) ((!) setup).cleanup();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_reject_private_muc_pm() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            var manager = require_openpgp_manager((!) setup);
            var private_muc_pm = new Dino.Entities.Conversation(
                new Xmpp.Jid("private-room@conference.example.test/bob"),
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(private_muc_pm, out recipients, out reason),
                "OpenPGP private-MUC PM recipient candidate model must fail closed without a real-JID recipient");
            fail_if(!reason.contains("real JID"),
                "OpenPGP private-MUC PM recipient candidate model must require a cached occupant real JID");
        } catch (Error e) {
            GLib.Test.message("OpenPGP GROUPCHAT_PM recipient boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_requires_real_jid() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            var manager = require_openpgp_manager((!) setup);
            var private_muc_pm = new Dino.Entities.Conversation(
                new Xmpp.Jid("private-room@conference.example.test/bob"),
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            private_muc_pm.encryption = Dino.Entities.Encryption.PGP;

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(manager.try_get_private_muc_file_recipient_key_readiness(private_muc_pm, out recipients, out reason),
                "OpenPGP MUC-PM XEP-0374 recipient readiness must fail closed without a cached occupant real JID");
            fail_if(!reason.contains("real JID"),
                "OpenPGP MUC-PM XEP-0374 recipient readiness must expose the missing real-JID boundary");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP MUC-PM XEP-0374 recipient readiness must not fetch keys while resolving the PM boundary");
        } catch (Error e) {
            GLib.Test.message("OpenPGP MUC-PM XEP-0374 missing-real-JID readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_requires_private_room() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("public-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();

            var manager = require_openpgp_manager((!) setup);
            attach_xep0373_manager_for_private_muc_readiness_tests((!) setup, manager);
            manager.mark_xep0373_key_received(((!) setup).account, bob_jid);
            var private_muc_pm = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            private_muc_pm.encryption = Dino.Entities.Encryption.PGP;

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(manager.try_get_private_muc_file_recipient_key_readiness(private_muc_pm, out recipients, out reason),
                "OpenPGP MUC-PM XEP-0374 recipient readiness must fail closed without live private-room features");
            fail_if(!reason.contains("private members-only non-anonymous"),
                "OpenPGP MUC-PM XEP-0374 recipient readiness must expose the private-room feature boundary");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP MUC-PM XEP-0374 private-room feature check must not fetch keys");
        } catch (Error e) {
            GLib.Test.message("OpenPGP MUC-PM XEP-0374 private-room readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0374_accepts_real_jid() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, true);
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();

            var manager = require_openpgp_manager((!) setup);
            attach_xep0373_manager_for_private_muc_readiness_tests((!) setup, manager);
            manager.mark_xep0373_key_received(((!) setup).account, bob_jid);
            var private_muc_pm = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            private_muc_pm.encryption = Dino.Entities.Encryption.PGP;

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(!manager.try_get_private_muc_file_recipient_key_readiness(private_muc_pm, out recipients, out reason),
                "OpenPGP MUC-PM XEP-0374 recipient readiness must accept a refreshed real-JID recipient key");
            fail_if(recipients.size != 1,
                "OpenPGP MUC-PM XEP-0374 recipient readiness must return exactly one real recipient");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP MUC-PM XEP-0374 recipient readiness must resolve the room nick to Bob's real bare JID");

            GPGHelper.Key[] keys = manager.get_private_muc_file_recipient_key_fprs(private_muc_pm);
            fail_if_not_eq_int(2, keys.length,
                "OpenPGP MUC-PM XEP-0374 key resolver must return account plus real recipient keys");
            fail_if_not_eq_str("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", keys[0].fpr,
                "OpenPGP MUC-PM XEP-0374 key resolver must keep the account key first");
            fail_if_not_eq_str("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", keys[1].fpr,
                "OpenPGP MUC-PM XEP-0374 key resolver must use Bob's real-JID XEP-0373 key");
            fail_if(!manager.get_private_muc_file_body_url_recipient_jid(private_muc_pm).equals_bare(bob_jid),
                "OpenPGP MUC-PM XEP-0374 body-url recipient snapshot must use Bob's real bare JID");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP MUC-PM XEP-0374 recipient readiness must stay side-effect-free after success");
        } catch (Error e) {
            GLib.Test.message("OpenPGP MUC-PM XEP-0374 real-JID readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_pm_file_recipient_key_readiness_xep0027_accepts_real_jid() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, true);
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();

            var manager = require_openpgp_manager((!) setup);
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account,
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            var private_muc_pm = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            private_muc_pm.encryption = Dino.Entities.Encryption.PGP;

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(!manager.try_get_private_muc_file_recipient_key_readiness(private_muc_pm, out recipients, out reason),
                "OpenPGP MUC-PM XEP-0027 recipient readiness must accept an announced real-JID legacy key");
            fail_if(recipients.size != 1,
                "OpenPGP MUC-PM XEP-0027 recipient readiness must return exactly one real recipient");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP MUC-PM XEP-0027 recipient readiness must resolve the room nick to Bob's real bare JID");

            GPGHelper.Key[] keys = manager.get_private_muc_file_recipient_key_fprs(private_muc_pm);
            fail_if_not_eq_int(2, keys.length,
                "OpenPGP MUC-PM XEP-0027 key resolver must return account plus real recipient keys");
            fail_if_not_eq_str("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", keys[0].fpr,
                "OpenPGP MUC-PM XEP-0027 key resolver must keep the account key first");
            fail_if_not_eq_str("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", keys[1].fpr,
                "OpenPGP MUC-PM XEP-0027 key resolver must use Bob's real-JID legacy key");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP MUC-PM XEP-0027 recipient readiness must stay side-effect-free after success");
        } catch (Error e) {
            GLib.Test.message("OpenPGP MUC-PM XEP-0027 real-JID readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_pm_normal_text_send_does_not_require_file_snapshot() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        FileManagerHttpSetup? setup = null;
        try {
            string account_bare_jid = "alice@example.test";
            string plaintext = "normal OpenPGP MUC-PM text without file body-url snapshot";
            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            attach_openpgp_stream_module((!) setup);
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();

            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, occupant_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, room_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

            Dino.Plugins.OpenPgp.Manager manager = require_openpgp_manager((!) setup);
            manager.mark_xep0373_key_received(((!) setup).account, occupant_jid);
            manager.mark_xep0373_key_received(((!) setup).account, room_jid);

            var message = new Dino.Entities.Message(plaintext);
            message.account = ((!) setup).account;
            message.counterpart = occupant_jid;
            message.ourpart = ((!) setup).account.full_jid;
            message.direction = Dino.Entities.Message.DIRECTION_SENT;
            message.encryption = Dino.Entities.Encryption.PGP;
            message.marked = Dino.Entities.Message.Marked.SENDING;
            message.type_ = Dino.Entities.Message.Type.GROUPCHAT_PM;
            message.stanza_id = "openpgp-muc-pm-normal-text";

            var stanza = new Xmpp.MessageStanza("openpgp-muc-pm-normal-text");
            stanza.to = occupant_jid;
            stanza.type_ = Xmpp.MessageStanza.TYPE_CHAT;
            stanza.body = plaintext;

            manager.pre_message_send_for_tests(message, stanza, ((!) setup).conversation);

            fail_if(message.marked == Dino.Entities.Message.Marked.WONTSEND ||
                    message.marked == Dino.Entities.Message.Marked.UNSENT,
                "normal OpenPGP MUC-PM text must not be blocked by the file body-url snapshot gate");
            fail_if_not_eq_str("[This message is encrypted with OpenPGP for XMPP (XEP-0373/0374)]", stanza.body,
                "normal OpenPGP MUC-PM text must use the regular XEP-0374 fallback body");
            fail_if(stanza.stanza.get_subnode("x", NS_OPENPGP_LEGACY) != null,
                "normal OpenPGP MUC-PM text must not fall back to legacy markup in XMPP-key mode");

            Xmpp.StanzaNode? openpgp_node = stanza.stanza.get_subnode("openpgp", NS_OPENPGP);
            fail_if(openpgp_node == null,
                "normal OpenPGP MUC-PM text must write an XEP-0374 payload");
            if (openpgp_node == null) return;

            uint8[] encrypted_signcrypt = Base64.decode(((!) openpgp_node).get_string_content());
            GPGHelper.DecryptedData decrypted = GPGHelper.decrypt_data(encrypted_signcrypt);
            fail_if_not(decrypted.signature_valid,
                "normal OpenPGP MUC-PM text must carry a valid OpenPGP signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "normal OpenPGP MUC-PM text must be signed by the account key");

            string signcrypt_xml = (string) decrypted.data;
            Xmpp.StanzaNode signcrypt_node = parse_stanza_node_sync(signcrypt_xml);
            Xmpp.Xep.OpenPgpContent.SigncryptElement? signcrypt = Xmpp.Xep.OpenPgpContent.SigncryptElement.from_stanza_node(signcrypt_node);
            fail_if(signcrypt == null,
                "normal OpenPGP MUC-PM text decrypted XML must be a signcrypt element");
            if (signcrypt != null) {
                fail_if(((!) signcrypt).to == null || !((!) ((!) signcrypt).to).equals(occupant_jid),
                    "normal OpenPGP MUC-PM text must keep the regular signcrypt recipient as room/nick");
                fail_if_not_eq_str(plaintext, ((!) signcrypt).get_body_text() ?? "",
                    "normal OpenPGP MUC-PM text must encrypt the original message body");
            }

            string guard_reason = "";
            fail_if(!Dino.MessageProcessor.outgoing_stanza_matches_encryption(Dino.Entities.Encryption.PGP, stanza, out guard_reason),
                "MessageProcessor encryption guard must accept normal OpenPGP MUC-PM text: " + guard_reason);
        } catch (Error e) {
            GLib.Test.message("OpenPGP MUC-PM normal text send regression test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_receive_recipient_candidates_distinguish_groupchat_and_pm() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid sender_occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid sender_real_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid own_occupant_jid = room_jid.with_resource("alice");

            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, true);
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, sender_occupant_jid, sender_real_jid, "member");
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, own_occupant_jid, ((!) setup).account.bare_jid, "member");
            drain_pending_events();

            var listener = new Dino.Plugins.OpenPgp.ReceivedPipelineDecryptListener();
            Gee.List<Xmpp.Jid>? groupchat_recipients = listener.get_expected_signcrypt_recipients_for_tests(
                ((!) setup).stream,
                sender_occupant_jid,
                ((!) setup).account.full_jid,
                ((!) setup).account.full_jid,
                Xmpp.MessageStanza.TYPE_GROUPCHAT);
            fail_if(groupchat_recipients == null || ((!) groupchat_recipients).size != 1,
                "OpenPGP private-MUC groupchat receive must expect exactly the room recipient");
            assert_jid_list_contains_exact(groupchat_recipients, room_jid.bare_jid,
                "OpenPGP private-MUC groupchat receive must accept room-bare signcrypt recipients");

            Gee.List<Xmpp.Jid>? pm_recipients = listener.get_expected_signcrypt_recipients_for_tests(
                ((!) setup).stream,
                sender_occupant_jid,
                ((!) setup).account.full_jid,
                ((!) setup).account.full_jid,
                Xmpp.MessageStanza.TYPE_CHAT);
            fail_if(pm_recipients == null || ((!) pm_recipients).size != 2,
                "OpenPGP private-MUC PM receive must expect account-bare and own occupant recipients");
            assert_jid_list_contains_exact(pm_recipients, ((!) setup).account.bare_jid,
                "OpenPGP private-MUC PM file body-url receive must accept the account-bare recipient");
            assert_jid_list_contains_exact(pm_recipients, own_occupant_jid,
                "OpenPGP private-MUC PM normal text receive must accept the own room/nick recipient");
            assert_jid_list_lacks_exact(pm_recipients, room_jid.bare_jid,
                "OpenPGP private-MUC PM receive must not accept a groupchat room-bare recipient");

            Gee.List<Xmpp.Jid>? own_pm_recipients = listener.get_expected_signcrypt_recipients_for_tests(
                ((!) setup).stream,
                own_occupant_jid,
                sender_occupant_jid,
                ((!) setup).account.full_jid,
                Xmpp.MessageStanza.TYPE_CHAT);
            fail_if(own_pm_recipients == null || ((!) own_pm_recipients).size != 2,
                "OpenPGP private-MUC PM own echo must expect target room/nick and target real-JID recipients");
            assert_jid_list_contains_exact(own_pm_recipients, sender_occupant_jid,
                "OpenPGP private-MUC PM own normal text echo must accept the target room/nick recipient");
            assert_jid_list_contains_exact(own_pm_recipients, sender_real_jid.bare_jid,
                "OpenPGP private-MUC PM own file body-url echo must accept the target real bare JID");
            assert_jid_list_lacks_exact(own_pm_recipients, ((!) setup).account.bare_jid,
                "OpenPGP private-MUC PM own echo must not treat the local account as the recipient");

            Gee.List<Xmpp.Jid>? own_groupchat_recipients = listener.get_expected_signcrypt_recipients_for_tests(
                ((!) setup).stream,
                own_occupant_jid,
                ((!) setup).account.full_jid,
                ((!) setup).account.full_jid,
                Xmpp.MessageStanza.TYPE_GROUPCHAT);
            fail_if(own_groupchat_recipients == null || ((!) own_groupchat_recipients).size != 1,
                "OpenPGP private-MUC groupchat own echo must still expect exactly the room recipient");
            assert_jid_list_contains_exact(own_groupchat_recipients, room_jid.bare_jid,
                "OpenPGP private-MUC groupchat own echo must accept room-bare signcrypt recipients");
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC receive recipient candidate test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_pm_file_decryptor_validates_real_jid_signer() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();

            ((!) setup).conversation = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            var transfer = new Dino.Entities.FileTransfer();
            transfer.account = ((!) setup).account;
            transfer.counterpart = occupant_jid;
            transfer.ourpart = ((!) setup).account.full_jid;
            transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            transfer.encryption = Dino.Entities.Encryption.PGP;
            transfer.encryption_protocol = Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374;

            var clear_data = new GPGHelper.DecryptedData() {
                data = {},
                filename = "document.pdf",
                signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                signature_valid = true
            };

            var decryptor = new Dino.Plugins.OpenPgp.PgpFileDecryptor(((!) setup).stream_interactor, ((!) setup).openpgp_db);
            decryptor.validate_file_signature(((!) setup).conversation, transfer, clear_data);
        } catch (Error e) {
            GLib.Test.message("OpenPGP MUC-PM real-JID signer validation test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_pm_file_decryptor_rejects_without_real_jid() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");

            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, room_jid, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, occupant_jid, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

            ((!) setup).conversation = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            var transfer = new Dino.Entities.FileTransfer();
            transfer.account = ((!) setup).account;
            transfer.counterpart = occupant_jid;
            transfer.ourpart = ((!) setup).account.full_jid;
            transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            transfer.encryption = Dino.Entities.Encryption.PGP;
            transfer.encryption_protocol = Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374;

            var clear_data = new GPGHelper.DecryptedData() {
                data = {},
                filename = "document.pdf",
                signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                signature_valid = true
            };

            var decryptor = new Dino.Plugins.OpenPgp.PgpFileDecryptor(((!) setup).stream_interactor, ((!) setup).openpgp_db);
            bool rejected = false;
            try {
                decryptor.validate_file_signature(((!) setup).conversation, transfer, clear_data);
            } catch (Dino.FileReceiveError.DECRYPTION_FAILED e) {
                rejected = true;
            }
            fail_if(!rejected,
                "OpenPGP MUC-PM file signature verification must not fall back to room/nick or room-bare keys without a cached real JID");
        } catch (Error e) {
            GLib.Test.message("OpenPGP MUC-PM missing-real-JID signer rejection test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_groupchat_file_decryptor_validates_real_jid_signer() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();

            ((!) setup).conversation = new Dino.Entities.Conversation(
                room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;

            var transfer = new Dino.Entities.FileTransfer();
            transfer.account = ((!) setup).account;
            transfer.counterpart = occupant_jid;
            transfer.ourpart = room_jid.with_resource("alice");
            transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            transfer.encryption = Dino.Entities.Encryption.PGP;
            transfer.encryption_protocol = Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374;

            var clear_data = new GPGHelper.DecryptedData() {
                data = {},
                filename = "document.pdf",
                signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                signature_valid = true
            };

            var decryptor = new Dino.Plugins.OpenPgp.PgpFileDecryptor(((!) setup).stream_interactor, ((!) setup).openpgp_db);
            decryptor.validate_file_signature(((!) setup).conversation, transfer, clear_data);
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC groupchat real-JID signer validation test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_groupchat_file_decryptor_rejects_without_real_jid() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");

            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, room_jid, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, occupant_jid, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

            ((!) setup).conversation = new Dino.Entities.Conversation(
                room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;

            var transfer = new Dino.Entities.FileTransfer();
            transfer.account = ((!) setup).account;
            transfer.counterpart = occupant_jid;
            transfer.ourpart = room_jid.with_resource("alice");
            transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            transfer.encryption = Dino.Entities.Encryption.PGP;
            transfer.encryption_protocol = Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374;

            var clear_data = new GPGHelper.DecryptedData() {
                data = {},
                filename = "document.pdf",
                signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                signature_valid = true
            };

            var decryptor = new Dino.Plugins.OpenPgp.PgpFileDecryptor(((!) setup).stream_interactor, ((!) setup).openpgp_db);
            bool rejected = false;
            try {
                decryptor.validate_file_signature(((!) setup).conversation, transfer, clear_data);
            } catch (Dino.FileReceiveError.DECRYPTION_FAILED e) {
                rejected = true;
            }
            fail_if(!rejected,
                "OpenPGP private-MUC groupchat file signature verification must not fall back to room/nick or room-bare keys without a cached real JID");
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC groupchat missing-real-JID signer rejection test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_reject_public_room() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("public-room@conference.example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, false);
            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject public or unverified rooms");
            fail_if(!reason.contains("private members-only non-anonymous room"),
                "OpenPGP private-MUC file recipient candidate model must require private room semantics");
        } catch (Error e) {
            GLib.Test.message("OpenPGP public-MUC recipient boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_reject_stale_private_room_cache() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            mark_openpgp_room_private_in_entity_info(((!) setup).core_db, ((!) setup).account, room_jid);
            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject stale offline private-room feature cache");
            fail_if(!reason.contains("live private"),
                "OpenPGP private-MUC file recipient candidate model must require live room features");
        } catch (Error e) {
            GLib.Test.message("OpenPGP stale-cache private-MUC recipient boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_reject_stale_live_room_features() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must accept the initial live private-room snapshot");

            bool refreshed = query_openpgp_room_info_error_for_tests((!) setup, room_jid);
            fail_if(refreshed,
                "OpenPGP private-MUC snapshot refresh must fail when live room-info refresh fails");
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject stale live room features after failed refresh");
            fail_if(!reason.contains("live private"),
                "OpenPGP private-MUC file recipient candidate model must expose stale live-feature certainty");
        } catch (Error e) {
            GLib.Test.message("OpenPGP stale-live-feature private-MUC recipient boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_reject_after_local_leave() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must accept the initial live private-room snapshot");

            Xmpp.Xep.Muc.Module? muc_module = ((!) setup).stream.get_module<Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
            fail_if(muc_module == null, "OpenPGP private-MUC local leave proof requires an attached MUC module");
            if (muc_module == null) return;
            ((!) muc_module).exit(((!) setup).stream, room_jid);

            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject a locally left room");
            fail_if(!reason.contains("live private"),
                "OpenPGP private-MUC file recipient candidate model must clear live room features on local leave");
        } catch (Error e) {
            GLib.Test.message("OpenPGP local-leave private-MUC recipient boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_reject_incomplete_affiliation_snapshot() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, true);
            query_openpgp_muc_affiliation_for_tests(((!) setup).stream, room_jid, "member", bob_jid);

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject incomplete member/admin/owner snapshots");
            fail_if(!reason.contains("member, admin and owner"),
                "OpenPGP private-MUC file recipient candidate model must expose incomplete affiliation snapshot certainty");
        } catch (Error e) {
            GLib.Test.message("OpenPGP incomplete-affiliation private-MUC recipient boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_replace_requeried_affiliation() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, true);
            query_openpgp_muc_affiliation_for_tests(((!) setup).stream, room_jid, "member", bob_jid);
            query_openpgp_muc_affiliation_for_tests(((!) setup).stream, room_jid, "admin");
            query_openpgp_muc_affiliation_for_tests(((!) setup).stream, room_jid, "owner");

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must accept the initial complete snapshot");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC file recipient candidate model must include the initial member");

            query_openpgp_muc_affiliation_for_tests(((!) setup).stream, room_jid, "member", carol_jid);
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must keep completion after successful member re-query");
            assert_jid_list_lacks_bare(recipients, bob_jid,
                "OpenPGP private-MUC file recipient candidate model must remove stale same-affiliation members after re-query");
            assert_jid_list_contains_bare(recipients, carol_jid,
                "OpenPGP private-MUC file recipient candidate model must include the refreshed member after re-query");
            fail_if(recipients.size != 1,
                "OpenPGP private-MUC file recipient candidate model must replace, not append, re-queried member affiliations");
        } catch (Error e) {
            GLib.Test.message("OpenPGP re-queried-affiliation private-MUC recipient test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_ignore_non_member_affiliations() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid eve_jid = new Xmpp.Jid("eve@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());
            query_openpgp_muc_affiliation_for_tests(((!) setup).stream, room_jid, "outcast", eve_jid);

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must accept the complete member snapshot");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC file recipient candidate model must keep member/admin/owner members");
            assert_jid_list_lacks_bare(recipients, eve_jid,
                "OpenPGP private-MUC file recipient candidate model must ignore cached non-member affiliations");
            fail_if(recipients.size != 1,
                "OpenPGP private-MUC file recipient candidate model must not include outcast entries in the recipient snapshot");
        } catch (Error e) {
            GLib.Test.message("OpenPGP non-member-affiliation private-MUC recipient test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_apply_authoritative_presence_delta() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid mallory_jid = new Xmpp.Jid("mallory@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, room_jid.with_resource("mallory"), mallory_jid, "member");

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must accept the complete member query snapshot");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC file recipient candidate model must include queried members");
            assert_jid_list_contains_bare(recipients, mallory_jid,
                "OpenPGP private-MUC file recipient candidate model must apply authoritative real-JID MUC presence deltas");
            fail_if(recipients.size != 2,
                "OpenPGP private-MUC file recipient candidate model must keep the completed baseline current with authoritative deltas");
        } catch (Error e) {
            GLib.Test.message("OpenPGP presence-cache private-MUC recipient test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_reject_self_only_members() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(((!) setup).account.bare_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must not treat a self-only member cache as a safe send target");
            fail_if(!reason.contains("at least one other known member"),
                "OpenPGP private-MUC file recipient candidate model must expose the self-only boundary");
        } catch (Error e) {
            GLib.Test.message("OpenPGP self-only private-MUC recipient boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_candidates_accept_known_members() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            Gee.List<Xmpp.Jid>? snapshot = query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(((!) setup).account.bare_jid, bob_jid),
                openpgp_jid_list(carol_jid),
                openpgp_jid_list(bob_jid));
            fail_if(snapshot == null || ((!) snapshot).size != 3,
                "OpenPGP private-MUC recipient candidate proof must query a complete member/admin/owner snapshot");

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must accept a private room with cached non-self member candidates");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC file recipient candidate model must include Bob");
            assert_jid_list_contains_bare(recipients, carol_jid,
                "OpenPGP private-MUC file recipient candidate model must include Carol");
            assert_jid_list_lacks_bare(recipients, ((!) setup).account.bare_jid,
                "OpenPGP private-MUC file recipient candidate model must not include the sender as a room recipient");
            fail_if(recipients.size != 2,
                "OpenPGP private-MUC file recipient candidate model must return exactly the cached non-self members");
        } catch (Error e) {
            GLib.Test.message("OpenPGP known-member private-MUC recipient test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_affiliation_snapshot_queries_member_admin_owner() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            Xmpp.Jid dave_jid = new Xmpp.Jid("dave@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");

            var request_order = new Gee.ArrayList<string>();
            var request_destinations = new Gee.ArrayList<string>();
            Gee.List<Xmpp.Jid>? snapshot = query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid.with_resource("alice"),
                openpgp_jid_list(((!) setup).account.bare_jid, bob_jid),
                openpgp_jid_list(carol_jid),
                openpgp_jid_list(bob_jid, dave_jid),
                request_order,
                request_destinations);

            fail_if(snapshot == null,
                "OpenPGP private-MUC affiliation proof must return a complete member/admin/owner snapshot");
            fail_if(((!) snapshot).size != 4,
                "OpenPGP private-MUC affiliation proof must dedupe member/admin/owner JIDs into a bare snapshot");
            assert_jid_list_contains_bare(snapshot, ((!) setup).account.bare_jid,
                "OpenPGP private-MUC affiliation proof must keep the raw self JID in the snapshot before recipient filtering");
            assert_jid_list_contains_bare(snapshot, bob_jid,
                "OpenPGP private-MUC affiliation proof must include member/owner duplicate once");
            assert_jid_list_contains_bare(snapshot, carol_jid,
                "OpenPGP private-MUC affiliation proof must include admins");
            assert_jid_list_contains_bare(snapshot, dave_jid,
                "OpenPGP private-MUC affiliation proof must include owners");

            fail_if(request_order.size != 4,
                "OpenPGP private-MUC affiliation proof must issue exactly room-info, member, admin and owner queries");
            fail_if_not_eq_str(request_order.get(0), "room-info",
                "OpenPGP private-MUC affiliation proof must refresh room features before affiliation queries");
            fail_if_not_eq_str(request_order.get(1), "member",
                "OpenPGP private-MUC affiliation proof must query members first");
            fail_if_not_eq_str(request_order.get(2), "admin",
                "OpenPGP private-MUC affiliation proof must query admins second");
            fail_if_not_eq_str(request_order.get(3), "owner",
                "OpenPGP private-MUC affiliation proof must query owners third");
            foreach (string destination in request_destinations) {
                fail_if_not_eq_str(destination, room_jid.to_string(),
                    "OpenPGP private-MUC affiliation proof must address the bare room JID");
            }

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must accept the completed member/admin/owner snapshot");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC file recipient candidate model must include Bob after the affiliation snapshot");
            assert_jid_list_contains_bare(recipients, carol_jid,
                "OpenPGP private-MUC file recipient candidate model must include Carol after the affiliation snapshot");
            assert_jid_list_contains_bare(recipients, dave_jid,
                "OpenPGP private-MUC file recipient candidate model must include Dave after the affiliation snapshot");
            assert_jid_list_lacks_bare(recipients, ((!) setup).account.bare_jid,
                "OpenPGP private-MUC file recipient candidate model must filter the sender after the raw snapshot");
            fail_if(recipients.size != 3,
                "OpenPGP private-MUC file recipient candidate model must return exactly non-self member/admin/owner recipients");
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC affiliation IQ boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_affiliation_snapshot_accepts_fromless_results() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");

            Gee.List<Xmpp.Jid>? snapshot = query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid.with_resource("alice"),
                openpgp_jid_list(((!) setup).account.bare_jid, bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list(carol_jid),
                null,
                null,
                true);

            fail_if(snapshot == null || ((!) snapshot).size != 3,
                "OpenPGP private-MUC affiliation proof must accept from-less affiliation IQ results for the requested room");
            Dino.MucManager? muc_manager = ((!) setup).stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(muc_manager == null,
                "OpenPGP from-less affiliation proof requires MucManager");
            fail_if(muc_manager == null || !((!) muc_manager).has_complete_private_muc_affiliation_snapshot(((!) setup).account, room_jid),
                "OpenPGP from-less affiliation proof must store completion under the requested room JID");
            Gee.List<Xmpp.Jid>? cached_members = ((!) muc_manager).get_private_muc_member_affiliation_snapshot(((!) setup).account, room_jid);
            assert_jid_list_contains_bare(cached_members, bob_jid,
                "OpenPGP from-less affiliation proof must cache Bob under the requested room JID");
            assert_jid_list_contains_bare(cached_members, carol_jid,
                "OpenPGP from-less affiliation proof must cache Carol under the requested room JID");

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(!manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must use from-less affiliation results stored for the requested room");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC file recipient candidate model must include Bob from from-less affiliation results");
            assert_jid_list_contains_bare(recipients, carol_jid,
                "OpenPGP private-MUC file recipient candidate model must include Carol from from-less affiliation results");
            assert_jid_list_lacks_bare(recipients, ((!) setup).account.bare_jid,
                "OpenPGP private-MUC file recipient candidate model must still filter the sender from from-less affiliation results");
            fail_if(recipients.size != 2,
                "OpenPGP private-MUC file recipient candidate model must return exactly non-self recipients from from-less results");
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC from-less affiliation IQ boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_affiliation_snapshot_rejects_mismatched_result_from() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid wrong_room_jid = new Xmpp.Jid("wrong-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");

            for (int i = 0; i < 3; i++) {
                GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Ignoring affiliation result for private-room@conference.example.test from unexpected JID wrong-room@conference.example.test");
            }
            Gee.List<Xmpp.Jid>? snapshot = query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list(),
                null,
                null,
                false,
                wrong_room_jid);
            GLib.Test.assert_expected_messages();

            fail_if(snapshot != null,
                "OpenPGP private-MUC affiliation proof must reject affiliation IQ results from a different room");
            Dino.MucManager? muc_manager = ((!) setup).stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(muc_manager == null,
                "OpenPGP mismatched-from affiliation proof requires MucManager");
            fail_if(muc_manager != null && ((!) muc_manager).has_complete_private_muc_affiliation_snapshot(((!) setup).account, room_jid),
                "OpenPGP mismatched-from affiliation proof must not complete the requested-room snapshot");

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject mismatched-from affiliation results");
            fail_if(!reason.contains("member, admin and owner"),
                "OpenPGP private-MUC file recipient candidate model must expose incomplete snapshot after mismatched-from result");
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC mismatched-from affiliation IQ boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_affiliation_snapshot_rejects_full_result_from() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid room_full_from_jid = room_jid.with_resource("mallory");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");

            for (int i = 0; i < 3; i++) {
                GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Ignoring affiliation result for private-room@conference.example.test from unexpected JID private-room@conference.example.test/mallory");
            }
            Gee.List<Xmpp.Jid>? snapshot = query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list(),
                null,
                null,
                false,
                room_full_from_jid);
            GLib.Test.assert_expected_messages();

            fail_if(snapshot != null,
                "OpenPGP private-MUC affiliation proof must reject full-JID affiliation IQ results for the requested bare room");
            Dino.MucManager? muc_manager = ((!) setup).stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(muc_manager == null,
                "OpenPGP full-from affiliation proof requires MucManager");
            fail_if(muc_manager != null && ((!) muc_manager).has_complete_private_muc_affiliation_snapshot(((!) setup).account, room_jid),
                "OpenPGP full-from affiliation proof must not complete the requested-room snapshot");

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject full-JID affiliation results");
            fail_if(!reason.contains("member, admin and owner"),
                "OpenPGP private-MUC file recipient candidate model must expose incomplete snapshot after full-JID result");
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC full-from affiliation IQ boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_affiliation_snapshot_error_keeps_snapshot_incomplete() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");

            Gee.List<Xmpp.Jid>? snapshot = query_openpgp_private_muc_snapshot_affiliation_error_for_tests((!) setup, room_jid,
                "admin",
                openpgp_jid_list(bob_jid));

            fail_if(snapshot != null,
                "OpenPGP private-MUC affiliation proof must fail when a required affiliation query returns an error");
            Dino.MucManager? muc_manager = ((!) setup).stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(muc_manager == null,
                "OpenPGP affiliation-error proof requires MucManager");
            fail_if(muc_manager != null && ((!) muc_manager).has_complete_private_muc_affiliation_snapshot(((!) setup).account, room_jid),
                "OpenPGP affiliation-error proof must keep member/admin/owner certainty incomplete");

            var manager = require_openpgp_manager((!) setup);
            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);

            Gee.List<Xmpp.Jid> recipients;
            string reason;
            fail_if(manager.try_get_private_muc_file_recipient_candidates(groupchat, out recipients, out reason),
                "OpenPGP private-MUC file recipient candidate model must reject permission-limited affiliation snapshots");
            fail_if(!reason.contains("member, admin and owner"),
                "OpenPGP private-MUC file recipient candidate model must expose incomplete snapshot after affiliation error");
        } catch (Error e) {
            GLib.Test.message("OpenPGP private-MUC affiliation IQ error boundary test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_key_readiness_xep0374_requires_verified_keys() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(((!) setup).account.bare_jid, bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            attach_xep0373_manager_for_private_muc_readiness_tests((!) setup, manager);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.reset_contact_xmpp_key_verification(((!) setup).account, bob_jid.bare_jid);
            manager.mark_xep0373_key_received(((!) setup).account, bob_jid);

            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(manager.try_get_private_muc_file_recipient_key_readiness(groupchat, out recipients, out reason),
                "OpenPGP private-MUC XEP-0374 recipient readiness must reject freshly fetched keys that are not verified");
            fail_if(!reason.contains("unverified") || !reason.contains(bob_jid.to_string()),
                "OpenPGP private-MUC XEP-0374 recipient readiness must expose unverified per-recipient key trust");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0374 recipient readiness must not fetch keys while rejecting unverified trust state");
        } catch (Error e) {
            GLib.Test.message("OpenPGP XEP-0374 unverified private-MUC recipient key-readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_key_readiness_xep0374_requires_refreshed_keys() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(((!) setup).account.bare_jid, bob_jid),
                openpgp_jid_list(carol_jid),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            attach_xep0373_manager_for_private_muc_readiness_tests((!) setup, manager);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.mark_contact_xmpp_key_verified(((!) setup).account, bob_jid.bare_jid);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, carol_jid.bare_jid,
                "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.mark_contact_xmpp_key_verified(((!) setup).account, carol_jid.bare_jid);
            manager.mark_xep0373_key_received(((!) setup).account, bob_jid);

            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(manager.try_get_private_muc_file_recipient_key_readiness(groupchat, out recipients, out reason),
                "OpenPGP private-MUC XEP-0374 recipient readiness must reject stored keys that were not refreshed this session");
            fail_if(!reason.contains("stale") || !reason.contains(carol_jid.to_string()),
                "OpenPGP private-MUC XEP-0374 recipient readiness must expose stale per-recipient key state");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0374 recipient readiness must not trigger PubSub or other network writes");

            manager.mark_xep0373_key_received(((!) setup).account, carol_jid);
            baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(!manager.try_get_private_muc_file_recipient_key_readiness(groupchat, out recipients, out reason),
                "OpenPGP private-MUC XEP-0374 recipient readiness must accept complete refreshed recipient keys");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC XEP-0374 recipient readiness must include Bob");
            assert_jid_list_contains_bare(recipients, carol_jid,
                "OpenPGP private-MUC XEP-0374 recipient readiness must include Carol");
            fail_if(recipients.size != 2,
                "OpenPGP private-MUC XEP-0374 recipient readiness must return exactly the ready non-self recipients");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0374 recipient readiness must stay side-effect-free after success");
        } catch (Error e) {
            GLib.Test.message("OpenPGP XEP-0374 private-MUC recipient key-readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_key_readiness_xep0374_ignores_support_without_key() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            attach_xep0373_manager_for_private_muc_readiness_tests((!) setup, manager);
            ((!) setup).openpgp_db.clear_contact_xmpp_key(((!) setup).account, bob_jid.bare_jid);
            ((!) setup).openpgp_db.set_contact_supports_xep0374(((!) setup).account, bob_jid.bare_jid, true);
            manager.mark_xep0373_key_received(((!) setup).account, bob_jid);

            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(manager.try_get_private_muc_file_recipient_key_readiness(groupchat, out recipients, out reason),
                "OpenPGP private-MUC XEP-0374 recipient readiness must reject passive support state without a stored XEP-0373 key");
            fail_if(!reason.contains("missing") || !reason.contains(bob_jid.to_string()),
                "OpenPGP private-MUC XEP-0374 recipient readiness must expose missing stored key state");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0374 recipient readiness must not fetch keys for passive support state");
        } catch (Error e) {
            GLib.Test.message("OpenPGP XEP-0374 support-only private-MUC recipient key-readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_key_readiness_xep0027_requires_announced_keys() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(carol_jid),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account,
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_KEYSERVER, false, false);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, carol_jid.bare_jid,
                "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);

            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            Gee.List<Xmpp.Jid> recipients;
            string reason;
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(manager.try_get_private_muc_file_recipient_key_readiness(groupchat, out recipients, out reason),
                "OpenPGP private-MUC XEP-0027 recipient readiness must reject stored legacy keys that are not currently announced");
            fail_if(!reason.contains("inactive") || !reason.contains(bob_jid.to_string()),
                "OpenPGP private-MUC XEP-0027 recipient readiness must expose inactive per-recipient key state");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0027 recipient readiness must stay side-effect-free on inactive keys");

            ((!) setup).openpgp_db.set_contact_legacy_key_announced(((!) setup).account, bob_jid.bare_jid, true);
            baseline_writes = ((!) setup).stream.written_nodes.size;
            fail_if(!manager.try_get_private_muc_file_recipient_key_readiness(groupchat, out recipients, out reason),
                "OpenPGP private-MUC XEP-0027 recipient readiness must accept announced legacy keys for all recipients");
            assert_jid_list_contains_bare(recipients, bob_jid,
                "OpenPGP private-MUC XEP-0027 recipient readiness must include Bob");
            assert_jid_list_contains_bare(recipients, carol_jid,
                "OpenPGP private-MUC XEP-0027 recipient readiness must include Carol");
            fail_if(recipients.size != 2,
                "OpenPGP private-MUC XEP-0027 recipient readiness must return exactly the ready non-self recipients");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0027 recipient readiness must stay side-effect-free after success");
        } catch (Error e) {
            GLib.Test.message("OpenPGP XEP-0027 private-MUC recipient key-readiness test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_key_fprs_xep0374_requires_ready_keys() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(carol_jid),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            attach_xep0373_manager_for_private_muc_readiness_tests((!) setup, manager);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.mark_contact_xmpp_key_verified(((!) setup).account, bob_jid.bare_jid);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, carol_jid.bare_jid,
                "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            ((!) setup).openpgp_db.mark_contact_xmpp_key_verified(((!) setup).account, carol_jid.bare_jid);
            manager.mark_xep0373_key_received(((!) setup).account, bob_jid);

            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            try {
                manager.get_private_muc_file_recipient_key_fprs(groupchat);
                fail_if(true,
                    "OpenPGP private-MUC XEP-0374 key resolver must reject stale recipient keys before returning key material");
            } catch (Error e) {
                fail_if(!e.message.contains("stale") || !e.message.contains(carol_jid.to_string()),
                    "OpenPGP private-MUC XEP-0374 key resolver must expose stale per-recipient key state");
            }
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0374 key resolver must not trigger PubSub or other network writes");

            manager.mark_xep0373_key_received(((!) setup).account, carol_jid);
            baseline_writes = ((!) setup).stream.written_nodes.size;
            GPGHelper.Key[] keys = manager.get_private_muc_file_recipient_key_fprs(groupchat);
            fail_if_not_eq_int(3, keys.length,
                "OpenPGP private-MUC XEP-0374 key resolver must return account plus Bob and Carol keys");
            fail_if_not_eq_str("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", keys[0].fpr,
                "OpenPGP private-MUC XEP-0374 key resolver must keep the account key first");
            assert_openpgp_key_list_contains(keys,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                "OpenPGP private-MUC XEP-0374 key resolver must include Bob's XEP-0373 key");
            assert_openpgp_key_list_contains(keys,
                "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                "OpenPGP private-MUC XEP-0374 key resolver must include Carol's XEP-0373 key");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0374 key resolver must stay side-effect-free after success");
        } catch (Error e) {
            GLib.Test.message("OpenPGP XEP-0374 private-MUC recipient key resolver test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private void test_openpgp_private_muc_file_recipient_key_fprs_xep0027_requires_announced_keys() {
        FileManagerHttpSetup? setup = null;
        try {
            setup = create_file_manager_http_setup(
                "alice@example.test",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            Xmpp.Jid carol_jid = new Xmpp.Jid("carol@example.test");
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(carol_jid),
                openpgp_jid_list());

            var manager = require_openpgp_manager((!) setup);
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account,
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_KEYSERVER, false, false);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, carol_jid.bare_jid,
                "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);

            var groupchat = new Dino.Entities.Conversation(room_jid, ((!) setup).account, Dino.Entities.Conversation.Type.GROUPCHAT);
            int baseline_writes = ((!) setup).stream.written_nodes.size;
            try {
                manager.get_private_muc_file_recipient_key_fprs(groupchat);
                fail_if(true,
                    "OpenPGP private-MUC XEP-0027 key resolver must reject inactive legacy recipient keys before returning key material");
            } catch (Error e) {
                fail_if(!e.message.contains("inactive") || !e.message.contains(bob_jid.to_string()),
                    "OpenPGP private-MUC XEP-0027 key resolver must expose inactive per-recipient key state");
            }
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0027 key resolver must stay side-effect-free on inactive keys");

            ((!) setup).openpgp_db.set_contact_legacy_key_announced(((!) setup).account, bob_jid.bare_jid, true);
            baseline_writes = ((!) setup).stream.written_nodes.size;
            GPGHelper.Key[] keys = manager.get_private_muc_file_recipient_key_fprs(groupchat);
            fail_if_not_eq_int(3, keys.length,
                "OpenPGP private-MUC XEP-0027 key resolver must return account plus Bob and Carol keys");
            fail_if_not_eq_str("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", keys[0].fpr,
                "OpenPGP private-MUC XEP-0027 key resolver must keep the account key first");
            assert_openpgp_key_list_contains(keys,
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                "OpenPGP private-MUC XEP-0027 key resolver must include Bob's announced legacy key");
            assert_openpgp_key_list_contains(keys,
                "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                "OpenPGP private-MUC XEP-0027 key resolver must include Carol's announced legacy key");
            drain_pending_events();
            fail_if_not_eq_int(baseline_writes, ((!) setup).stream.written_nodes.size,
                "OpenPGP private-MUC XEP-0027 key resolver must stay side-effect-free after success");
        } catch (Error e) {
            GLib.Test.message("OpenPGP XEP-0027 private-MUC recipient key resolver test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (setup != null) ((!) setup).cleanup();
        }
    }

    private async void test_file_manager_http_send_xep0374_real_encryptor_invalid_upload() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-filemanager-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-openpgp-runtime.txt");
        string plaintext = "DinoX FileManager HTTP runtime with real XEP-0374 PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager OpenPGP runtime test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the FileManager runtime test");
            }
            ((!) pgp_manager).mark_xep0373_key_received(((!) setup).account, ((!) setup).conversation.counterpart.bare_jid);
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real OpenPGP HTTP test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real OpenPGP HTTP test must publish a stored outgoing path before transport");
            });

            slot_capture = respond_to_real_pgp_slot_request(((!) setup).stream,
                "real-openpgp-runtime.txt.pgp",
                "application/pgp-encrypted");

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: Http file upload XMPP error:*Received invalid HTTPS URL from server*");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-openpgp-runtime.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "FileManager real OpenPGP HTTP test must publish the local encrypted-at-rest copy before transport");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "real PgpFileEncryptor must request an HTTP upload slot after encryption");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size <= plaintext.length,
                "real PgpFileEncryptor must produce an encrypted upload payload before the HTTP slot request");
            fail_if_not_eq_str("real-openpgp-runtime.txt.pgp", file_transfer.server_file_name ?? "",
                "real PgpFileEncryptor must request the HTTP slot with the .pgp upload filename");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374, file_transfer.encryption_protocol ?? "",
                "real PgpFileEncryptor must store the XEP-0374 file protocol before HTTP upload");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the real OpenPGP upload-capable path");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "invalid HTTP upload URL must fail the public FileManager send after real OpenPGP encryption");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "invalid HTTP upload URL must persist as failed transfer state after real OpenPGP encryption");
            fail_if(file_transfer.phase_error == null || !((!) file_transfer.phase_error).contains("Received invalid HTTPS URL from server"),
                "XEP-0363 slot validation error must surface on the OpenPGP FileManager transfer");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "real OpenPGP send must not announce a body URL after upload validation fails");
            fail_if(stream_has_message_stanza(((!) setup).stream),
                "real OpenPGP upload validation failure must not write a body-url message stanza");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the real OpenPGP upload stream after HTTP sender failure");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before real OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "real PgpFileEncryptor must finish before the HTTP slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.FAILED,
                "invalid XEP-0363 slot URLs must fail before HTTP upload");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING),
                "an invalid upload slot must never enter the upload phase");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "real OpenPGP HTTP upload validation failure must not emit COMPLETE");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist the real OpenPGP HTTP sender upload validation failure");
        } catch (Error e) {
            GLib.Test.message("FileManager real XEP-0374 OpenPGP HTTP runtime test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_file_manager_http_send_xep0374_real_encryptor_https_put_success_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0374_real_encryptor_https_put_success.begin((obj, res) => {
            test_file_manager_http_send_xep0374_real_encryptor_https_put_success.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_file_manager_http_send_xep0374_real_encryptor_https_put_success() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-filemanager-success-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-openpgp-runtime-success.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-upload.txt");
        string plaintext = "DinoX FileManager HTTP runtime success with real XEP-0374 PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager OpenPGP HTTPS test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            attach_openpgp_stream_module((!) setup);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the FileManager HTTPS runtime test");
            }
            ((!) pgp_manager).mark_xep0373_key_received(((!) setup).account, ((!) setup).conversation.counterpart.bare_jid);
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var upload_capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("OpenPGP HTTPS test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "real-openpgp-runtime-success.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-xep0374");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-openpgp-runtime-success.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "FileManager real OpenPGP HTTPS test must publish the local encrypted-at-rest copy before transport");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "real PgpFileEncryptor must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the real XEP-0374 OpenPGP HTTPS path");
            fail_if(!upload_capture.handled,
                "real XEP-0374 OpenPGP HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "real XEP-0374 OpenPGP HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "real XEP-0374 OpenPGP HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-xep0374", upload_capture.authorization ?? "",
                "real XEP-0374 OpenPGP HTTP sender must forward allowed slot headers");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "real XEP-0374 OpenPGP slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "real XEP-0374 OpenPGP captured PUT body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "real XEP-0374 OpenPGP HTTPS PUT body must not contain plaintext bytes");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "real XEP-0374 OpenPGP captured PUT body must decrypt to the original payload");
            fail_if_not_eq_str("real-openpgp-runtime-success.txt", decrypted.filename,
                "real XEP-0374 OpenPGP captured PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "real XEP-0374 OpenPGP captured PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "real XEP-0374 OpenPGP captured PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "real XEP-0374 OpenPGP captured PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "real XEP-0374 OpenPGP captured PUT packet must include the contact recipient key");

            assert_real_xep0374_body_url_message(((!) setup).stream, download_url, ((!) setup).conversation.counterpart, signer, recipient);

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful real XEP-0374 OpenPGP HTTPS upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful real XEP-0374 OpenPGP HTTPS upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful real XEP-0374 OpenPGP HTTPS upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful real XEP-0374 OpenPGP upload must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful real XEP-0374 OpenPGP upload must assign a local file-sharing id");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374, file_transfer.encryption_protocol ?? "",
                "successful real XEP-0374 OpenPGP upload must record the XEP-0374 file protocol");
            fail_if_not_eq_str("real-openpgp-runtime-success.txt.pgp", file_transfer.server_file_name ?? "",
                "real XEP-0374 PgpFileEncryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful real XEP-0374 OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful real XEP-0374 OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(((!) setup).core_db, file_transfer, download_url,
                "successful real XEP-0374 OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before real XEP-0374 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "real PgpFileEncryptor must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before real XEP-0374 OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "real XEP-0374 OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful real XEP-0374 OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful real XEP-0374 OpenPGP HTTPS upload as complete");
        } catch (Error e) {
            GLib.Test.message("FileManager real XEP-0374 OpenPGP HTTPS runtime test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_file_manager_http_send_xep0027_real_encryptor_https_put_success_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0027_real_encryptor_https_put_success.begin((obj, res) => {
            test_file_manager_http_send_xep0027_real_encryptor_https_put_success.end(res);
            loop.quit();
        });
        loop.run();
    }

    private void test_file_manager_http_send_xep0374_real_encryptor_cancel_after_put_blocks_body_announcement_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0374_real_encryptor_cancel_after_put_blocks_body_announcement.begin((obj, res) => {
            test_file_manager_http_send_xep0374_real_encryptor_cancel_after_put_blocks_body_announcement.end(res);
            loop.quit();
        });
        loop.run();
    }

    private void test_file_manager_http_send_xep0374_real_encryptor_cancel_while_request_body_stream_blocks_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0374_real_encryptor_cancel_while_request_body_stream_blocks.begin((obj, res) => {
            test_file_manager_http_send_xep0374_real_encryptor_cancel_while_request_body_stream_blocks.end(res);
            loop.quit();
        });
        loop.run();
    }

    private void test_file_manager_http_send_xep0027_real_encryptor_cancel_while_request_body_stream_blocks_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0027_real_encryptor_cancel_while_request_body_stream_blocks.begin((obj, res) => {
            test_file_manager_http_send_xep0027_real_encryptor_cancel_while_request_body_stream_blocks.end(res);
            loop.quit();
        });
        loop.run();
    }

    private void test_file_manager_http_send_xep0027_real_encryptor_cancel_after_put_blocks_body_announcement_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0027_real_encryptor_cancel_after_put_blocks_body_announcement.begin((obj, res) => {
            test_file_manager_http_send_xep0027_real_encryptor_cancel_after_put_blocks_body_announcement.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_file_manager_http_send_xep0374_real_encryptor_cancel_after_put_blocks_body_announcement() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-filemanager-cancel-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-openpgp-runtime-cancel.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-cancel-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-cancel-upload.txt");
        string plaintext = "DinoX FileManager HTTP cancel after full PUT with real XEP-0374 PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager OpenPGP HTTPS cancel test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            attach_openpgp_stream_module((!) setup);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the FileManager HTTPS cancel test");
            }
            ((!) pgp_manager).mark_xep0373_key_received(((!) setup).account, ((!) setup).conversation.counterpart.bare_jid);
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != ((!) setup).conversation,
                    "public XEP-0374 OpenPGP cancel-after-PUT test must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public XEP-0374 OpenPGP cancel-after-PUT test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public XEP-0374 OpenPGP cancel-after-PUT test must publish a stored outgoing path before transport");
            });

            var upload_capture = new HttpsUploadCapture();
            upload_capture.on_upload = () => {
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
            };
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("OpenPGP HTTPS cancel test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "real-openpgp-runtime-cancel.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-xep0374-cancel");

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-openpgp-runtime-cancel.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "public XEP-0374 OpenPGP cancel-after-PUT test must publish the locally saved transfer before HTTPS upload");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "real XEP-0374 PgpFileEncryptor cancel test must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the public XEP-0374 OpenPGP cancel path");
            fail_if(!upload_capture.handled,
                "public XEP-0374 OpenPGP cancel-after-PUT test must reach the local HTTPS PUT endpoint before cancellation");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public XEP-0374 OpenPGP cancel-after-PUT test must cancel the transfer after the server captures the PUT body");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "public XEP-0374 OpenPGP cancel-after-PUT test must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "public XEP-0374 OpenPGP cancel-after-PUT test must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-xep0374-cancel", upload_capture.authorization ?? "",
                "public XEP-0374 OpenPGP cancel-after-PUT test must forward allowed slot headers before cancellation");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "public XEP-0374 OpenPGP cancel-after-PUT slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "public XEP-0374 OpenPGP cancel-after-PUT captured body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "public XEP-0374 OpenPGP cancel-after-PUT body must not contain plaintext bytes");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "public XEP-0374 OpenPGP cancel-after-PUT body must decrypt to the original payload");
            fail_if_not_eq_str("real-openpgp-runtime-cancel.txt", decrypted.filename,
                "public XEP-0374 OpenPGP cancel-after-PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "public XEP-0374 OpenPGP cancel-after-PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "public XEP-0374 OpenPGP cancel-after-PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "public XEP-0374 OpenPGP cancel-after-PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "public XEP-0374 OpenPGP cancel-after-PUT packet must include the contact recipient key");

            fail_if(find_openpgp_message(((!) setup).stream) != null,
                "public XEP-0374 OpenPGP cancel-after-PUT test must not announce a body-url OpenPGP stanza after cancellation");
            fail_if(find_legacy_openpgp_message(((!) setup).stream) != null,
                "public XEP-0374 OpenPGP cancel-after-PUT test must not fall back to a legacy body-url stanza after cancellation");
            fail_if(stream_has_message_stanza(((!) setup).stream),
                "public XEP-0374 OpenPGP cancel-after-PUT test must not write any body-url message stanza after cancellation");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(((!) setup).stream, download_url, download_url,
                "public XEP-0374 OpenPGP cancel-after-PUT body-only boundary");
            assert_no_outgoing_wire_text(((!) setup).stream, download_url,
                "public XEP-0374 OpenPGP cancel-after-PUT test must not leak the download URL on outgoing wire");
            assert_no_outgoing_wire_text(((!) setup).stream, upload_url,
                "public XEP-0374 OpenPGP cancel-after-PUT test must not echo the upload URL on outgoing wire");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public XEP-0374 OpenPGP cancel-after-PUT test must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public XEP-0374 OpenPGP cancel-after-PUT test must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public XEP-0374 OpenPGP cancel-after-PUT test must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public XEP-0374 OpenPGP cancel-after-PUT test must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public XEP-0374 OpenPGP cancel-after-PUT test must not assign a file-sharing id before the body-url announcement step");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374, file_transfer.encryption_protocol ?? "",
                "public XEP-0374 OpenPGP cancel-after-PUT test must still record the XEP-0374 file protocol");
            fail_if_not_eq_str("real-openpgp-runtime-cancel.txt.pgp", file_transfer.server_file_name ?? "",
                "real XEP-0374 PgpFileEncryptor cancel test must request the slot with the encrypted .pgp server filename");
            fail_if(upload_capture.written_count_at_upload < 0,
                "public XEP-0374 OpenPGP cancel-after-PUT test must capture the stanza boundary at PUT time");
            assert_no_message_stanzas_before_boundary(((!) setup).stream, upload_capture.written_count_at_upload,
                "public XEP-0374 OpenPGP cancel-after-PUT test must not write any message stanza before the PUT boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the XEP-0374 OpenPGP upload stream after canceling the real HTTP sender at PUT time");
            assert_no_http_sources(file_transfer,
                "cancelled public XEP-0374 OpenPGP body-url upload must not add a local HTTP source");
            assert_no_persisted_sources(((!) setup).core_db, file_transfer,
                "cancelled public XEP-0374 OpenPGP body-url upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before real XEP-0374 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "real XEP-0374 PgpFileEncryptor cancel test must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before the cancel-after-PUT HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public XEP-0374 OpenPGP cancel-after-PUT test must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public XEP-0374 OpenPGP cancel-after-PUT test must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public XEP-0374 OpenPGP cancel-after-PUT test must not emit COMPLETE");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist public XEP-0374 OpenPGP cancel-after-PUT sends as failed");
        } catch (Error e) {
            GLib.Test.message("FileManager real XEP-0374 OpenPGP HTTPS cancel-after-PUT test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private async void test_file_manager_http_send_xep0374_real_encryptor_cancel_while_request_body_stream_blocks() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-filemanager-blocked-body-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-openpgp-runtime-blocked-body.txt");
        string plaintext = "DinoX FileManager HTTP blocked-body cancel with real XEP-0374 PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;
        uint timeout_id = 0;
        bool timed_out = false;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager OpenPGP HTTPS blocked-body cancel test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            attach_openpgp_stream_module((!) setup);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the FileManager HTTPS blocked-body cancel test");
            }
            ((!) pgp_manager).mark_xep0373_key_received(((!) setup).account, ((!) setup).conversation.counterpart.bare_jid);
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != ((!) setup).conversation,
                    "public XEP-0374 OpenPGP blocked-body cancel test must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public XEP-0374 OpenPGP blocked-body cancel test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public XEP-0374 OpenPGP blocked-body cancel test must publish a stored outgoing path before transport");
            });

            var upload_capture = new BlockedBodyUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_body_stream_cancel_server(upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("OpenPGP HTTPS blocked-body cancel test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "real-openpgp-runtime-blocked-body.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-xep0374-blocked-body");

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            // Include real GPG subprocess startup and local encryption on slow Windows VMs.
            // The blocked stream still drives cancellation; this is only the outer safety guard.
            timeout_id = Timeout.add(30000, () => {
                timed_out = true;
                timeout_id = 0;
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                return Source.REMOVE;
            });

            bool upload_stream_replaced = false;
            BlockedBodyUploadInputStream? blocking_stream = null;
            uint8[]? encrypted_first_chunk = null;
            string? stream_replace_error = null;
            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-openpgp-runtime-blocked-body.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => {
                    phases.add(file_transfer.phase);
                    if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.UPLOADING && !upload_stream_replaced) {
                        upload_stream_replaced = true;
                        try {
                            InputStream encrypted_upload_stream = file_transfer.input_stream;
                            encrypted_first_chunk = read_stream_chunk(encrypted_upload_stream, 128, file_transfer.cancellable);
                            encrypted_upload_stream.close(file_transfer.cancellable);
                            if (encrypted_first_chunk == null || ((!) encrypted_first_chunk).length == 0) {
                                throw new IOError.FAILED("real XEP-0374 PGP upload stream produced no encrypted bytes");
                            }
                            blocking_stream = new BlockedBodyUploadInputStream((!) encrypted_first_chunk,
                                file_transfer.cancellable, upload_capture);
                            file_transfer.input_stream = (!) blocking_stream;
                        } catch (Error e) {
                            stream_replace_error = e.message;
                            file_transfer.cancellable.cancel();
                        }
                    }
                });
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            if (timed_out) {
                throw new IOError.TIMED_OUT("XEP-0374 blocked-body test reached its send deadline before controlled cancellation");
            }
            // Failed prerequisites must not turn a useful test failure into a null dereference.
            if (published_transfer == null || blocking_stream == null || encrypted_first_chunk == null) {
                throw new IOError.FAILED("XEP-0374 blocked-body test did not reach the prepared upload stream: " + (stream_replace_error ?? "no stream"));
            }
            fail_if(stream_replace_error != null,
                "public XEP-0374 OpenPGP blocked-body test must replace the encrypted upload stream: " + (stream_replace_error ?? ""));
            fail_if(published_transfer == null,
                "public XEP-0374 OpenPGP blocked-body cancel test must publish the locally saved transfer before HTTPS upload");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "real XEP-0374 PgpFileEncryptor blocked-body test must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the public XEP-0374 OpenPGP blocked-body path");
            fail_if(!upload_stream_replaced || blocking_stream == null,
                "public XEP-0374 OpenPGP blocked-body test must replace the transport stream at the UPLOADING boundary");
            BlockedBodyUploadInputStream blocked_stream = (!) blocking_stream;
            fail_if(encrypted_first_chunk == null || ((!) encrypted_first_chunk).length == 0,
                "public XEP-0374 OpenPGP blocked-body stream must start with bytes from the real encrypted PGP upload stream");
            fail_if(contains_bytes((!) encrypted_first_chunk, plaintext.data),
                "public XEP-0374 OpenPGP blocked-body first chunk must not contain plaintext bytes");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public XEP-0374 OpenPGP blocked-body test must cancel the transfer while the request body is blocked");
            fail_if(!upload_capture.request_started,
                "public XEP-0374 OpenPGP blocked-body test must open a local HTTPS request before cancellation");
            fail_if(!upload_capture.headers_seen,
                "public XEP-0374 OpenPGP blocked-body test must prove the server received PUT headers before the body completed");
            fail_if(upload_capture.request_read,
                "public XEP-0374 OpenPGP blocked-body test must cancel before libsoup considers the full request body read");
            fail_if(upload_capture.handler_called,
                "public XEP-0374 OpenPGP blocked-body test must not reach the normal PUT handler after a full request body");
            fail_if(!blocked_stream.first_chunk_seen,
                "public XEP-0374 OpenPGP blocked-body stream must send an initial encrypted body chunk before cancellation");
            fail_if(!blocked_stream.blocking_read_seen,
                "public XEP-0374 OpenPGP blocked-body stream must reach the blocking read after the initial chunk");
            fail_if(!blocked_stream.blocking_read_saw_cancellable,
                "public XEP-0374 OpenPGP blocked-body stream reads must receive a cancellable that observes transfer cancellation");
            fail_if(blocked_stream.blocking_read_missing_cancellable,
                "public XEP-0374 OpenPGP blocked-body stream must not be read without a cancellable");
            fail_if(!blocked_stream.cancelled_after_headers_seen,
                "public XEP-0374 OpenPGP blocked-body stream must trigger cancellation only after the server sees request headers");
            fail_if(!blocked_stream.cancel_seen,
                "public XEP-0374 OpenPGP blocked-body stream must observe cancellation while blocked");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "public XEP-0374 OpenPGP blocked-body test must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "public XEP-0374 OpenPGP blocked-body test must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-xep0374-blocked-body", upload_capture.authorization ?? "",
                "public XEP-0374 OpenPGP blocked-body test must forward allowed slot headers before cancellation");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.content_length,
                "public XEP-0374 OpenPGP blocked-body slot size must match the declared encrypted PUT Content-Length");
            fail_if(upload_capture.content_length <= plaintext.length,
                "public XEP-0374 OpenPGP blocked-body Content-Length must describe the encrypted .pgp upload, not the plaintext file");
            fail_if(upload_capture.content_length <= ((!) encrypted_first_chunk).length,
                "public XEP-0374 OpenPGP blocked-body test must cancel before the controlled stream can provide a full body");

            fail_if(find_openpgp_message(((!) setup).stream) != null,
                "public XEP-0374 OpenPGP blocked-body test must not announce a body-url OpenPGP stanza after cancellation");
            fail_if(find_legacy_openpgp_message(((!) setup).stream) != null,
                "public XEP-0374 OpenPGP blocked-body test must not fall back to a legacy body-url stanza after cancellation");
            fail_if(stream_has_message_stanza(((!) setup).stream),
                "public XEP-0374 OpenPGP blocked-body test must not write any body-url message stanza after cancellation");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(((!) setup).stream, download_url, download_url,
                "public XEP-0374 OpenPGP blocked-body body-only boundary");
            assert_no_outgoing_wire_text(((!) setup).stream, download_url,
                "public XEP-0374 OpenPGP blocked-body test must not leak the download URL on outgoing wire");
            assert_no_outgoing_wire_text(((!) setup).stream, upload_url,
                "public XEP-0374 OpenPGP blocked-body test must not echo the upload URL on outgoing wire");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public XEP-0374 OpenPGP blocked-body test must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public XEP-0374 OpenPGP blocked-body test must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public XEP-0374 OpenPGP blocked-body test must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public XEP-0374 OpenPGP blocked-body test must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public XEP-0374 OpenPGP blocked-body test must not assign a file-sharing id before the body-url announcement step");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374, file_transfer.encryption_protocol ?? "",
                "public XEP-0374 OpenPGP blocked-body test must still record the XEP-0374 file protocol");
            fail_if_not_eq_str("real-openpgp-runtime-blocked-body.txt.pgp", file_transfer.server_file_name ?? "",
                "real XEP-0374 PgpFileEncryptor blocked-body test must request the slot with the encrypted .pgp server filename");
            fail_if(upload_capture.written_count_at_headers < 0,
                "public XEP-0374 OpenPGP blocked-body test must capture the stanza boundary at PUT header time");
            assert_no_message_stanzas_before_boundary(((!) setup).stream, upload_capture.written_count_at_headers,
                "public XEP-0374 OpenPGP blocked-body test must not write any message stanza before the PUT header boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the XEP-0374 OpenPGP upload stream after canceling the real HTTP sender while the body is blocked");
            fail_if(!blocked_stream.closed,
                "FileManager must close the underlying XEP-0374 OpenPGP blocked upload stream after cancellation");
            assert_no_http_sources(file_transfer,
                "cancelled public XEP-0374 OpenPGP blocked-body upload must not add a local HTTP source");
            assert_no_persisted_sources(((!) setup).core_db, file_transfer,
                "cancelled public XEP-0374 OpenPGP blocked-body upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before real XEP-0374 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "real XEP-0374 PgpFileEncryptor blocked-body test must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before the blocked-body HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public XEP-0374 OpenPGP blocked-body test must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public XEP-0374 OpenPGP blocked-body test must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public XEP-0374 OpenPGP blocked-body test must not emit COMPLETE");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist public XEP-0374 OpenPGP blocked-body sends as failed");
        } catch (Error e) {
            GLib.Test.message("FileManager real XEP-0374 OpenPGP HTTPS blocked-body cancel test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private async void test_file_manager_http_send_xep0027_real_encryptor_cancel_while_request_body_stream_blocks() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-filemanager-legacy-blocked-body-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-openpgp-legacy-runtime-blocked-body.txt");
        string plaintext = "DinoX FileManager HTTP blocked-body cancel with real legacy XEP-0027 PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;
        uint timeout_id = 0;
        bool timed_out = false;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager legacy OpenPGP HTTPS blocked-body cancel test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_email_uid(signer);
            require_email_uid(recipient);

            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account, signer);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, ((!) setup).conversation.counterpart.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            attach_openpgp_stream_module((!) setup);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the FileManager legacy HTTPS blocked-body cancel test");
            }
            string allow_reason;
            fail_if(!((!) pgp_manager).can_encrypt_for_selected_openpgp_mode(((!) setup).conversation, out allow_reason),
                "legacy XEP-0027 FileManager HTTPS blocked-body cancel test must be allowed by the selected legacy account/contact key state");
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != ((!) setup).conversation,
                    "public legacy XEP-0027 OpenPGP blocked-body cancel test must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public legacy XEP-0027 OpenPGP blocked-body cancel test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public legacy XEP-0027 OpenPGP blocked-body cancel test must publish a stored outgoing path before transport");
            });

            var upload_capture = new BlockedBodyUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_body_stream_cancel_server(upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("legacy OpenPGP HTTPS blocked-body cancel test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "real-openpgp-legacy-runtime-blocked-body.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-xep0027-blocked-body");

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            // Include real GPG subprocess startup and local encryption on slow Windows VMs.
            // The blocked stream still drives cancellation; this is only the outer safety guard.
            timeout_id = Timeout.add(30000, () => {
                timed_out = true;
                timeout_id = 0;
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                return Source.REMOVE;
            });

            bool upload_stream_replaced = false;
            BlockedBodyUploadInputStream? blocking_stream = null;
            uint8[]? encrypted_first_chunk = null;
            string? stream_replace_error = null;
            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-openpgp-legacy-runtime-blocked-body.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => {
                    phases.add(file_transfer.phase);
                    if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.UPLOADING && !upload_stream_replaced) {
                        upload_stream_replaced = true;
                        try {
                            InputStream encrypted_upload_stream = file_transfer.input_stream;
                            encrypted_first_chunk = read_stream_chunk(encrypted_upload_stream, 128, file_transfer.cancellable);
                            encrypted_upload_stream.close(file_transfer.cancellable);
                            if (encrypted_first_chunk == null || ((!) encrypted_first_chunk).length == 0) {
                                throw new IOError.FAILED("real legacy XEP-0027 PGP upload stream produced no encrypted bytes");
                            }
                            blocking_stream = new BlockedBodyUploadInputStream((!) encrypted_first_chunk,
                                file_transfer.cancellable, upload_capture);
                            file_transfer.input_stream = (!) blocking_stream;
                        } catch (Error e) {
                            stream_replace_error = e.message;
                            file_transfer.cancellable.cancel();
                        }
                    }
                });
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            if (timed_out) {
                throw new IOError.TIMED_OUT("XEP-0027 blocked-body test reached its send deadline before controlled cancellation");
            }
            // Failed prerequisites must not turn a useful test failure into a null dereference.
            if (published_transfer == null || blocking_stream == null || encrypted_first_chunk == null) {
                throw new IOError.FAILED("XEP-0027 blocked-body test did not reach the prepared upload stream: " + (stream_replace_error ?? "no stream"));
            }
            fail_if(stream_replace_error != null,
                "public legacy XEP-0027 OpenPGP blocked-body test must replace the encrypted upload stream: " + (stream_replace_error ?? ""));
            fail_if(published_transfer == null,
                "public legacy XEP-0027 OpenPGP blocked-body cancel test must publish the locally saved transfer before HTTPS upload");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "real legacy XEP-0027 PgpFileEncryptor blocked-body test must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the public legacy XEP-0027 OpenPGP blocked-body path");
            fail_if(!upload_stream_replaced || blocking_stream == null,
                "public legacy XEP-0027 OpenPGP blocked-body test must replace the transport stream at the UPLOADING boundary");
            BlockedBodyUploadInputStream blocked_stream = (!) blocking_stream;
            fail_if(encrypted_first_chunk == null || ((!) encrypted_first_chunk).length == 0,
                "public legacy XEP-0027 OpenPGP blocked-body stream must start with bytes from the real encrypted PGP upload stream");
            fail_if(contains_bytes((!) encrypted_first_chunk, plaintext.data),
                "public legacy XEP-0027 OpenPGP blocked-body first chunk must not contain plaintext bytes");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public legacy XEP-0027 OpenPGP blocked-body test must cancel the transfer while the request body is blocked");
            fail_if(!upload_capture.request_started,
                "public legacy XEP-0027 OpenPGP blocked-body test must open a local HTTPS request before cancellation");
            fail_if(!upload_capture.headers_seen,
                "public legacy XEP-0027 OpenPGP blocked-body test must prove the server received PUT headers before the body completed");
            fail_if(upload_capture.request_read,
                "public legacy XEP-0027 OpenPGP blocked-body test must cancel before libsoup considers the full request body read");
            fail_if(upload_capture.handler_called,
                "public legacy XEP-0027 OpenPGP blocked-body test must not reach the normal PUT handler after a full request body");
            fail_if(!blocked_stream.first_chunk_seen,
                "public legacy XEP-0027 OpenPGP blocked-body stream must send an initial encrypted body chunk before cancellation");
            fail_if(!blocked_stream.blocking_read_seen,
                "public legacy XEP-0027 OpenPGP blocked-body stream must reach the blocking read after the initial chunk");
            fail_if(!blocked_stream.blocking_read_saw_cancellable,
                "public legacy XEP-0027 OpenPGP blocked-body stream reads must receive a cancellable that observes transfer cancellation");
            fail_if(blocked_stream.blocking_read_missing_cancellable,
                "public legacy XEP-0027 OpenPGP blocked-body stream must not be read without a cancellable");
            fail_if(!blocked_stream.cancelled_after_headers_seen,
                "public legacy XEP-0027 OpenPGP blocked-body stream must trigger cancellation only after the server sees request headers");
            fail_if(!blocked_stream.cancel_seen,
                "public legacy XEP-0027 OpenPGP blocked-body stream must observe cancellation while blocked");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "public legacy XEP-0027 OpenPGP blocked-body test must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "public legacy XEP-0027 OpenPGP blocked-body test must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-xep0027-blocked-body", upload_capture.authorization ?? "",
                "public legacy XEP-0027 OpenPGP blocked-body test must forward allowed slot headers before cancellation");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.content_length,
                "public legacy XEP-0027 OpenPGP blocked-body slot size must match the declared encrypted PUT Content-Length");
            fail_if(upload_capture.content_length <= plaintext.length,
                "public legacy XEP-0027 OpenPGP blocked-body Content-Length must describe the encrypted .pgp upload, not the plaintext file");
            fail_if(upload_capture.content_length <= ((!) encrypted_first_chunk).length,
                "public legacy XEP-0027 OpenPGP blocked-body test must cancel before the controlled stream can provide a full body");

            fail_if(find_legacy_openpgp_message(((!) setup).stream) != null,
                "public legacy XEP-0027 OpenPGP blocked-body test must not announce a legacy body-url stanza after cancellation");
            fail_if(find_openpgp_message(((!) setup).stream) != null,
                "public legacy XEP-0027 OpenPGP blocked-body test must not fall forward to an XEP-0374 body-url stanza after cancellation");
            fail_if(stream_has_message_stanza(((!) setup).stream),
                "public legacy XEP-0027 OpenPGP blocked-body test must not write any body-url message stanza after cancellation");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(((!) setup).stream, download_url, download_url,
                "public legacy XEP-0027 OpenPGP blocked-body body-only boundary");
            assert_no_outgoing_wire_text(((!) setup).stream, download_url,
                "public legacy XEP-0027 OpenPGP blocked-body test must not leak the download URL on outgoing wire");
            assert_no_outgoing_wire_text(((!) setup).stream, upload_url,
                "public legacy XEP-0027 OpenPGP blocked-body test must not echo the upload URL on outgoing wire");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public legacy XEP-0027 OpenPGP blocked-body test must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public legacy XEP-0027 OpenPGP blocked-body test must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public legacy XEP-0027 OpenPGP blocked-body test must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public legacy XEP-0027 OpenPGP blocked-body test must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public legacy XEP-0027 OpenPGP blocked-body test must not assign a file-sharing id before the body-url announcement step");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027, file_transfer.encryption_protocol ?? "",
                "public legacy XEP-0027 OpenPGP blocked-body test must still record the XEP-0027 file protocol");
            fail_if_not_eq_str("real-openpgp-legacy-runtime-blocked-body.txt.pgp", file_transfer.server_file_name ?? "",
                "real legacy XEP-0027 PgpFileEncryptor blocked-body test must request the slot with the encrypted .pgp server filename");
            fail_if(upload_capture.written_count_at_headers < 0,
                "public legacy XEP-0027 OpenPGP blocked-body test must capture the stanza boundary at PUT header time");
            assert_no_message_stanzas_before_boundary(((!) setup).stream, upload_capture.written_count_at_headers,
                "public legacy XEP-0027 OpenPGP blocked-body test must not write any message stanza before the PUT header boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the legacy XEP-0027 OpenPGP upload stream after canceling the real HTTP sender while the body is blocked");
            fail_if(!blocked_stream.closed,
                "FileManager must close the underlying legacy XEP-0027 OpenPGP blocked upload stream after cancellation");
            assert_no_http_sources(file_transfer,
                "cancelled public legacy XEP-0027 OpenPGP blocked-body upload must not add a local HTTP source");
            assert_no_persisted_sources(((!) setup).core_db, file_transfer,
                "cancelled public legacy XEP-0027 OpenPGP blocked-body upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before real legacy XEP-0027 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "real legacy XEP-0027 PgpFileEncryptor blocked-body test must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before the legacy blocked-body HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public legacy XEP-0027 OpenPGP blocked-body test must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public legacy XEP-0027 OpenPGP blocked-body test must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public legacy XEP-0027 OpenPGP blocked-body test must not emit COMPLETE");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist public legacy XEP-0027 OpenPGP blocked-body sends as failed");
        } catch (Error e) {
            GLib.Test.message("FileManager real legacy XEP-0027 OpenPGP HTTPS blocked-body cancel test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private async void test_file_manager_http_send_xep0027_real_encryptor_cancel_after_put_blocks_body_announcement() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-filemanager-legacy-cancel-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-openpgp-legacy-runtime-cancel.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-legacy-cancel-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-legacy-cancel-upload.txt");
        string plaintext = "DinoX FileManager HTTP cancel after full PUT with real legacy XEP-0027 PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager legacy OpenPGP HTTPS cancel test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_email_uid(signer);
            require_email_uid(recipient);

            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account, signer);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, ((!) setup).conversation.counterpart.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            attach_openpgp_stream_module((!) setup);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the FileManager legacy HTTPS cancel test");
            }
            string allow_reason;
            fail_if(!((!) pgp_manager).can_encrypt_for_selected_openpgp_mode(((!) setup).conversation, out allow_reason),
                "legacy XEP-0027 FileManager HTTPS cancel test must be allowed by the selected legacy account/contact key state");
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != ((!) setup).conversation,
                    "public legacy XEP-0027 OpenPGP cancel-after-PUT test must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public legacy XEP-0027 OpenPGP cancel-after-PUT test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public legacy XEP-0027 OpenPGP cancel-after-PUT test must publish a stored outgoing path before transport");
            });

            var upload_capture = new HttpsUploadCapture();
            upload_capture.on_upload = () => {
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
            };
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("legacy OpenPGP HTTPS cancel test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "real-openpgp-legacy-runtime-cancel.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-xep0027-cancel");

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-openpgp-legacy-runtime-cancel.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must publish the locally saved transfer before HTTPS upload");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "real legacy XEP-0027 PgpFileEncryptor cancel test must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the public legacy XEP-0027 OpenPGP cancel path");
            fail_if(!upload_capture.handled,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must reach the local HTTPS PUT endpoint before cancellation");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must cancel the transfer after the server captures the PUT body");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-xep0027-cancel", upload_capture.authorization ?? "",
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must forward allowed slot headers before cancellation");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT captured body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "public legacy XEP-0027 OpenPGP cancel-after-PUT body must not contain plaintext bytes");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT body must decrypt to the original payload");
            fail_if_not_eq_str("real-openpgp-legacy-runtime-cancel.txt", decrypted.filename,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT packet must include the contact recipient key");

            fail_if(find_legacy_openpgp_message(((!) setup).stream) != null,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not announce a legacy body-url stanza after cancellation");
            fail_if(find_openpgp_message(((!) setup).stream) != null,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not fall forward to an XEP-0374 body-url stanza after cancellation");
            fail_if(stream_has_message_stanza(((!) setup).stream),
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not write any body-url message stanza after cancellation");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(((!) setup).stream, download_url, download_url,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT body-only boundary");
            assert_no_outgoing_wire_text(((!) setup).stream, download_url,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not leak the download URL on outgoing wire");
            assert_no_outgoing_wire_text(((!) setup).stream, upload_url,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not echo the upload URL on outgoing wire");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not assign a file-sharing id before the body-url announcement step");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027, file_transfer.encryption_protocol ?? "",
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must still record the XEP-0027 file protocol");
            fail_if_not_eq_str("real-openpgp-legacy-runtime-cancel.txt.pgp", file_transfer.server_file_name ?? "",
                "real legacy XEP-0027 PgpFileEncryptor cancel test must request the slot with the encrypted .pgp server filename");
            fail_if(upload_capture.written_count_at_upload < 0,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must capture the stanza boundary at PUT time");
            assert_no_message_stanzas_before_boundary(((!) setup).stream, upload_capture.written_count_at_upload,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not write any message stanza before the PUT boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the legacy XEP-0027 OpenPGP upload stream after canceling the real HTTP sender at PUT time");
            assert_no_http_sources(file_transfer,
                "cancelled public legacy XEP-0027 OpenPGP body-url upload must not add a local HTTP source");
            assert_no_persisted_sources(((!) setup).core_db, file_transfer,
                "cancelled public legacy XEP-0027 OpenPGP body-url upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before real legacy XEP-0027 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "real legacy XEP-0027 PgpFileEncryptor cancel test must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before the legacy cancel-after-PUT HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public legacy XEP-0027 OpenPGP cancel-after-PUT test must not emit COMPLETE");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "FileManager must persist public legacy XEP-0027 OpenPGP cancel-after-PUT sends as failed");
        } catch (Error e) {
            GLib.Test.message("FileManager real legacy XEP-0027 OpenPGP HTTPS cancel-after-PUT test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_file_manager_http_send_xep0374_private_muc_real_encryptor_https_put_success_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0374_private_muc_real_encryptor_https_put_success.begin((obj, res) => {
            test_file_manager_http_send_xep0374_private_muc_real_encryptor_https_put_success.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_file_manager_http_send_xep0374_private_muc_real_encryptor_https_put_success() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-private-muc-success-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-openpgp-runtime-success.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-private-muc-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-private-muc-upload.txt");
        string plaintext = "DinoX FileManager HTTP runtime success with real XEP-0374 private-MUC PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager private-MUC OpenPGP HTTPS test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation = new Dino.Entities.Conversation(
                room_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            attach_openpgp_stream_module((!) setup);
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the private-MUC HTTPS runtime test");
            }
            ((!) pgp_manager).mark_xep0373_key_received(((!) setup).account, bob_jid);
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var upload_capture = new HttpsUploadCapture();
            bool contact_key_cleared_after_upload = false;
            upload_capture.on_upload = () => {
                ((!) setup).openpgp_db.clear_contact_xmpp_key(((!) setup).account, bob_jid.bare_jid);
                contact_key_cleared_after_upload = true;
            };
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("private-MUC OpenPGP HTTPS test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager private-MUC OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager private-MUC OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "private-muc-openpgp-runtime-success.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-private-muc-xep0374");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-openpgp-runtime-success.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "FileManager private-MUC OpenPGP HTTPS test must publish the local encrypted-at-rest copy before transport");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "private-MUC real XEP-0374 PgpFileEncryptor must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the private-MUC XEP-0374 OpenPGP HTTPS path");
            fail_if(!upload_capture.handled,
                "private-MUC real XEP-0374 OpenPGP HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "private-MUC real XEP-0374 OpenPGP HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "private-MUC real XEP-0374 OpenPGP HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-private-muc-xep0374", upload_capture.authorization ?? "",
                "private-MUC real XEP-0374 OpenPGP HTTP sender must forward allowed slot headers");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "private-MUC real XEP-0374 OpenPGP slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "private-MUC real XEP-0374 OpenPGP captured PUT body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "private-MUC real XEP-0374 OpenPGP HTTPS PUT body must not contain plaintext bytes");
            fail_if(!contact_key_cleared_after_upload,
                "private-MUC real XEP-0374 OpenPGP HTTPS test must mutate key state after upload to prove snapshot-based announcement");
            fail_if(((!) setup).openpgp_db.has_contact_xmpp_key(((!) setup).account, bob_jid.bare_jid),
                "private-MUC real XEP-0374 OpenPGP HTTPS test must clear the live DB key before body-url announcement");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "private-MUC real XEP-0374 OpenPGP captured PUT body must decrypt to the original payload");
            fail_if_not_eq_str("private-muc-openpgp-runtime-success.txt", decrypted.filename,
                "private-MUC real XEP-0374 OpenPGP captured PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "private-MUC real XEP-0374 OpenPGP captured PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "private-MUC real XEP-0374 OpenPGP captured PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "private-MUC real XEP-0374 OpenPGP captured PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "private-MUC real XEP-0374 OpenPGP captured PUT packet must include the room member recipient key");

            assert_real_xep0374_body_url_message(((!) setup).stream, download_url, room_jid, signer, recipient);

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC real XEP-0374 OpenPGP HTTPS upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful private-MUC real XEP-0374 OpenPGP HTTPS upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful private-MUC real XEP-0374 OpenPGP HTTPS upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful private-MUC real XEP-0374 OpenPGP upload must link the encrypted body-url message");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374, file_transfer.encryption_protocol ?? "",
                "successful private-MUC real XEP-0374 OpenPGP upload must record the XEP-0374 file protocol");
            fail_if_not_eq_str("private-muc-openpgp-runtime-success.txt.pgp", file_transfer.server_file_name ?? "",
                "private-MUC real XEP-0374 PgpFileEncryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful private-MUC real XEP-0374 OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful private-MUC real XEP-0374 OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(((!) setup).core_db, file_transfer, download_url,
                "successful private-MUC real XEP-0374 OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before private-MUC real XEP-0374 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "private-MUC real XEP-0374 PgpFileEncryptor must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before private-MUC real XEP-0374 OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "private-MUC real XEP-0374 OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC real XEP-0374 OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful private-MUC real XEP-0374 OpenPGP HTTPS upload as complete");
        } catch (Error e) {
            GLib.Test.message("FileManager private-MUC real XEP-0374 OpenPGP HTTPS runtime test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_file_manager_http_send_xep0374_private_muc_pm_real_encryptor_https_put_success_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0374_private_muc_pm_real_encryptor_https_put_success.begin((obj, res) => {
            test_file_manager_http_send_xep0374_private_muc_pm_real_encryptor_https_put_success.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_file_manager_http_send_xep0374_private_muc_pm_real_encryptor_https_put_success() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-private-muc-pm-success-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-pm-openpgp-runtime-success.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-private-muc-pm-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-private-muc-pm-upload.txt");
        string plaintext = "DinoX FileManager HTTP runtime success with real XEP-0374 MUC-PM PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager private-MUC PM OpenPGP HTTPS test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_xmpp_uid(signer, account_bare_jid);

            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient, true);
            ((!) setup).conversation = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            attach_openpgp_stream_module((!) setup);
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, true);
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();
            bind_live_private_message_target_for_tests((!) setup, occupant_jid);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the private-MUC PM HTTPS runtime test");
            }
            ((!) pgp_manager).mark_xep0373_key_received(((!) setup).account, bob_jid);
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var upload_capture = new HttpsUploadCapture();
            bool contact_key_cleared_after_upload = false;
            upload_capture.on_upload = () => {
                ((!) setup).openpgp_db.clear_contact_xmpp_key(((!) setup).account, bob_jid.bare_jid);
                contact_key_cleared_after_upload = true;
            };
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("private-MUC PM OpenPGP HTTPS test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager private-MUC PM OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager private-MUC PM OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "private-muc-pm-openpgp-runtime-success.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-private-muc-pm-xep0374");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-pm-openpgp-runtime-success.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "FileManager private-MUC PM OpenPGP HTTPS test must publish the local encrypted-at-rest copy before transport");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "private-MUC PM real XEP-0374 PgpFileEncryptor must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the private-MUC PM XEP-0374 OpenPGP HTTPS path");
            fail_if(!upload_capture.handled,
                "private-MUC PM real XEP-0374 OpenPGP HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "private-MUC PM real XEP-0374 OpenPGP HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "private-MUC PM real XEP-0374 OpenPGP HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-private-muc-pm-xep0374", upload_capture.authorization ?? "",
                "private-MUC PM real XEP-0374 OpenPGP HTTP sender must forward allowed slot headers");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "private-MUC PM real XEP-0374 OpenPGP slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "private-MUC PM real XEP-0374 OpenPGP captured PUT body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "private-MUC PM real XEP-0374 OpenPGP HTTPS PUT body must not contain plaintext bytes");
            fail_if(!contact_key_cleared_after_upload,
                "private-MUC PM real XEP-0374 OpenPGP HTTPS test must mutate key state after upload to prove snapshot-based announcement");
            fail_if(((!) setup).openpgp_db.has_contact_xmpp_key(((!) setup).account, bob_jid.bare_jid),
                "private-MUC PM real XEP-0374 OpenPGP HTTPS test must clear the live DB key before body-url announcement");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "private-MUC PM real XEP-0374 OpenPGP captured PUT body must decrypt to the original payload");
            fail_if_not_eq_str("private-muc-pm-openpgp-runtime-success.txt", decrypted.filename,
                "private-MUC PM real XEP-0374 OpenPGP captured PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "private-MUC PM real XEP-0374 OpenPGP captured PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "private-MUC PM real XEP-0374 OpenPGP captured PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "private-MUC PM real XEP-0374 OpenPGP captured PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "private-MUC PM real XEP-0374 OpenPGP captured PUT packet must include the real PM recipient key");

            assert_real_xep0374_body_url_message(((!) setup).stream, download_url, bob_jid.bare_jid, signer, recipient);
            Xmpp.StanzaNode? openpgp_message = find_openpgp_message(((!) setup).stream);
            fail_if(openpgp_message == null ||
                    ((!) openpgp_message).get_attribute("to") != occupant_jid.to_string(),
                "private-MUC PM real XEP-0374 body-url stanza must keep the outer stanza addressed to room/nick");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC PM real XEP-0374 OpenPGP HTTPS upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful private-MUC PM real XEP-0374 OpenPGP HTTPS upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful private-MUC PM real XEP-0374 OpenPGP HTTPS upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful private-MUC PM real XEP-0374 OpenPGP upload must link the encrypted body-url message");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374, file_transfer.encryption_protocol ?? "",
                "successful private-MUC PM real XEP-0374 OpenPGP upload must record the XEP-0374 file protocol");
            fail_if_not_eq_str("private-muc-pm-openpgp-runtime-success.txt.pgp", file_transfer.server_file_name ?? "",
                "private-MUC PM real XEP-0374 PgpFileEncryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful private-MUC PM real XEP-0374 OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful private-MUC PM real XEP-0374 OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(((!) setup).core_db, file_transfer, download_url,
                "successful private-MUC PM real XEP-0374 OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before private-MUC PM real XEP-0374 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "private-MUC PM real XEP-0374 PgpFileEncryptor must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before private-MUC PM real XEP-0374 OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "private-MUC PM real XEP-0374 OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC PM real XEP-0374 OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful private-MUC PM real XEP-0374 OpenPGP HTTPS upload as complete");
        } catch (Error e) {
            GLib.Test.message("FileManager private-MUC PM real XEP-0374 OpenPGP HTTPS runtime test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_file_manager_http_send_xep0027_private_muc_pm_real_encryptor_https_put_success_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0027_private_muc_pm_real_encryptor_https_put_success.begin((obj, res) => {
            test_file_manager_http_send_xep0027_private_muc_pm_real_encryptor_https_put_success.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_file_manager_http_send_xep0027_private_muc_pm_real_encryptor_https_put_success() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-private-muc-pm-legacy-success-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-pm-openpgp-legacy-runtime-success.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-private-muc-pm-legacy-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-private-muc-pm-legacy-upload.txt");
        string plaintext = "DinoX FileManager HTTP runtime success with real XEP-0027 MUC-PM PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager private-MUC PM legacy OpenPGP HTTPS test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_email_uid(signer);
            require_email_uid(recipient);

            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient, true);
            ((!) setup).conversation = new Dino.Entities.Conversation(
                occupant_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account, signer);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            attach_openpgp_stream_module((!) setup);
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_room_info_for_tests(((!) setup).stream, room_jid, true);
            emit_openpgp_muc_presence_for_tests(((!) setup).stream, occupant_jid, bob_jid, "member");
            drain_pending_events();
            bind_live_private_message_target_for_tests((!) setup, occupant_jid);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the private-MUC PM legacy HTTPS runtime test");
            }
            string allow_reason;
            fail_if(!((!) pgp_manager).can_encrypt_for_selected_openpgp_mode(((!) setup).conversation, out allow_reason),
                "private-MUC PM legacy XEP-0027 HTTPS test must be allowed by the selected legacy account/contact key state");
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var upload_capture = new HttpsUploadCapture();
            bool legacy_contact_deactivated_after_upload = false;
            upload_capture.on_upload = () => {
                ((!) setup).openpgp_db.set_contact_legacy_key_announced(((!) setup).account, bob_jid.bare_jid, false);
                legacy_contact_deactivated_after_upload = true;
            };
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("private-MUC PM legacy OpenPGP HTTPS test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager private-MUC PM legacy OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager private-MUC PM legacy OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "private-muc-pm-openpgp-legacy-runtime-success.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-private-muc-pm-xep0027");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-pm-openpgp-legacy-runtime-success.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "FileManager private-MUC PM legacy OpenPGP HTTPS test must publish the local encrypted-at-rest copy before transport");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "private-MUC PM real XEP-0027 PgpFileEncryptor must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the private-MUC PM XEP-0027 OpenPGP HTTPS path");
            fail_if(!upload_capture.handled,
                "private-MUC PM real XEP-0027 OpenPGP HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "private-MUC PM real XEP-0027 OpenPGP HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "private-MUC PM real XEP-0027 OpenPGP HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-private-muc-pm-xep0027", upload_capture.authorization ?? "",
                "private-MUC PM real XEP-0027 OpenPGP HTTP sender must forward allowed slot headers");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "private-MUC PM real XEP-0027 OpenPGP slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "private-MUC PM real XEP-0027 OpenPGP captured PUT body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "private-MUC PM real XEP-0027 OpenPGP HTTPS PUT body must not contain plaintext bytes");
            fail_if(!legacy_contact_deactivated_after_upload,
                "private-MUC PM real XEP-0027 OpenPGP HTTPS test must mutate legacy key state after upload to prove snapshot-based announcement");
            fail_if(((!) setup).openpgp_db.contact_legacy_key_is_announced(((!) setup).account, bob_jid.bare_jid),
                "private-MUC PM real XEP-0027 OpenPGP HTTPS test must deactivate the live legacy contact key before body-url announcement");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "private-MUC PM real XEP-0027 OpenPGP captured PUT body must decrypt to the original payload");
            fail_if_not_eq_str("private-muc-pm-openpgp-legacy-runtime-success.txt", decrypted.filename,
                "private-MUC PM real XEP-0027 OpenPGP captured PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "private-MUC PM real XEP-0027 OpenPGP captured PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "private-MUC PM real XEP-0027 OpenPGP captured PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "private-MUC PM real XEP-0027 OpenPGP captured PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "private-MUC PM real XEP-0027 OpenPGP captured PUT packet must include the real PM recipient key");

            assert_real_xep0027_body_url_message(((!) setup).stream, download_url, signer, recipient);
            Xmpp.StanzaNode? legacy_message = find_legacy_openpgp_message(((!) setup).stream);
            fail_if(legacy_message == null ||
                    ((!) legacy_message).get_attribute("to") != occupant_jid.to_string(),
                "private-MUC PM real XEP-0027 body-url stanza must keep the outer stanza addressed to room/nick");

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC PM real XEP-0027 OpenPGP HTTPS upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful private-MUC PM real XEP-0027 OpenPGP HTTPS upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful private-MUC PM real XEP-0027 OpenPGP HTTPS upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful private-MUC PM real XEP-0027 OpenPGP upload must link the encrypted body-url message");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027, file_transfer.encryption_protocol ?? "",
                "successful private-MUC PM real XEP-0027 OpenPGP upload must record the XEP-0027 file protocol");
            fail_if_not_eq_str("private-muc-pm-openpgp-legacy-runtime-success.txt.pgp", file_transfer.server_file_name ?? "",
                "private-MUC PM real XEP-0027 PgpFileEncryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful private-MUC PM real XEP-0027 OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful private-MUC PM real XEP-0027 OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(((!) setup).core_db, file_transfer, download_url,
                "successful private-MUC PM real XEP-0027 OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before private-MUC PM real XEP-0027 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "private-MUC PM real XEP-0027 PgpFileEncryptor must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before private-MUC PM real XEP-0027 OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "private-MUC PM real XEP-0027 OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC PM real XEP-0027 OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful private-MUC PM real XEP-0027 OpenPGP HTTPS upload as complete");
        } catch (Error e) {
            GLib.Test.message("FileManager private-MUC PM real XEP-0027 OpenPGP HTTPS runtime test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_file_manager_http_send_xep0027_private_muc_real_encryptor_https_put_success_sync() {
        var loop = new MainLoop();
        test_file_manager_http_send_xep0027_private_muc_real_encryptor_https_put_success.begin((obj, res) => {
            test_file_manager_http_send_xep0027_private_muc_real_encryptor_https_put_success.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_file_manager_http_send_xep0027_private_muc_real_encryptor_https_put_success() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-private-muc-legacy-success-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-openpgp-legacy-runtime-success.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-private-muc-legacy-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-private-muc-legacy-upload.txt");
        string plaintext = "DinoX FileManager HTTP runtime success with real XEP-0027 private-MUC PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager private-MUC legacy OpenPGP HTTPS test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_email_uid(signer);
            require_email_uid(recipient);

            Xmpp.Jid room_jid = new Xmpp.Jid("private-room@conference.example.test");
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation = new Dino.Entities.Conversation(
                room_jid,
                ((!) setup).account,
                Dino.Entities.Conversation.Type.GROUPCHAT);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account, signer);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, bob_jid.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            attach_openpgp_stream_module((!) setup);
            attach_openpgp_muc_modules_for_tests((!) setup, room_jid, "alice");
            query_openpgp_private_muc_snapshot_for_tests((!) setup, room_jid,
                openpgp_jid_list(bob_jid),
                openpgp_jid_list(),
                openpgp_jid_list());

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the private-MUC legacy HTTPS runtime test");
            }
            string allow_reason;
            fail_if(!((!) pgp_manager).can_encrypt_for_selected_openpgp_mode(((!) setup).conversation, out allow_reason),
                "private-MUC legacy XEP-0027 HTTPS test must be allowed by the selected legacy account/contact key state");
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var upload_capture = new HttpsUploadCapture();
            bool legacy_contact_deactivated_after_upload = false;
            upload_capture.on_upload = () => {
                ((!) setup).openpgp_db.set_contact_legacy_key_announced(((!) setup).account, bob_jid.bare_jid, false);
                legacy_contact_deactivated_after_upload = true;
            };
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("private-MUC legacy OpenPGP HTTPS test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager private-MUC legacy OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager private-MUC legacy OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "private-muc-openpgp-legacy-runtime-success.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-private-muc-xep0027");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-openpgp-legacy-runtime-success.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "FileManager private-MUC legacy OpenPGP HTTPS test must publish the local encrypted-at-rest copy before transport");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "private-MUC real XEP-0027 PgpFileEncryptor must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the private-MUC XEP-0027 OpenPGP HTTPS path");
            fail_if(!upload_capture.handled,
                "private-MUC real XEP-0027 OpenPGP HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "private-MUC real XEP-0027 OpenPGP HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "private-MUC real XEP-0027 OpenPGP HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-private-muc-xep0027", upload_capture.authorization ?? "",
                "private-MUC real XEP-0027 OpenPGP HTTP sender must forward allowed slot headers");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "private-MUC real XEP-0027 OpenPGP slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "private-MUC real XEP-0027 OpenPGP captured PUT body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "private-MUC real XEP-0027 OpenPGP HTTPS PUT body must not contain plaintext bytes");
            fail_if(!legacy_contact_deactivated_after_upload,
                "private-MUC real XEP-0027 OpenPGP HTTPS test must mutate legacy key state after upload to prove snapshot-based announcement");
            fail_if(((!) setup).openpgp_db.contact_legacy_key_is_announced(((!) setup).account, bob_jid.bare_jid),
                "private-MUC real XEP-0027 OpenPGP HTTPS test must deactivate the live legacy contact key before body-url announcement");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "private-MUC real XEP-0027 OpenPGP captured PUT body must decrypt to the original payload");
            fail_if_not_eq_str("private-muc-openpgp-legacy-runtime-success.txt", decrypted.filename,
                "private-MUC real XEP-0027 OpenPGP captured PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "private-MUC real XEP-0027 OpenPGP captured PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "private-MUC real XEP-0027 OpenPGP captured PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "private-MUC real XEP-0027 OpenPGP captured PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "private-MUC real XEP-0027 OpenPGP captured PUT packet must include the room member recipient key");

            assert_real_xep0027_body_url_message(((!) setup).stream, download_url, signer, recipient);

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC real XEP-0027 OpenPGP HTTPS upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful private-MUC real XEP-0027 OpenPGP HTTPS upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful private-MUC real XEP-0027 OpenPGP HTTPS upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful private-MUC real XEP-0027 OpenPGP upload must link the encrypted body-url message");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027, file_transfer.encryption_protocol ?? "",
                "successful private-MUC real XEP-0027 OpenPGP upload must record the XEP-0027 file protocol");
            fail_if_not_eq_str("private-muc-openpgp-legacy-runtime-success.txt.pgp", file_transfer.server_file_name ?? "",
                "private-MUC real XEP-0027 PgpFileEncryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful private-MUC real XEP-0027 OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful private-MUC real XEP-0027 OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(((!) setup).core_db, file_transfer, download_url,
                "successful private-MUC real XEP-0027 OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before private-MUC real XEP-0027 OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "private-MUC real XEP-0027 PgpFileEncryptor must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before private-MUC real XEP-0027 OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "private-MUC real XEP-0027 OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private-MUC real XEP-0027 OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful private-MUC real XEP-0027 OpenPGP HTTPS upload as complete");
        } catch (Error e) {
            GLib.Test.message("FileManager private-MUC real XEP-0027 OpenPGP HTTPS runtime test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private async void test_file_manager_http_send_xep0027_real_encryptor_https_put_success() {
        string signer;
        string recipient;
        if (!read_live_gpg_env(out signer, out recipient)) {
            return;
        }
        if (skip_if_local_https_sockets_unavailable()) {
            return;
        }

        string account_bare_jid = "alice@example.test";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-live-pgp-filemanager-legacy-success-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "real-openpgp-legacy-runtime-success.txt");
        string uploaded_pgp_path = Path.build_filename(temp_dir, "uploaded-legacy-body.pgp");
        string decrypted_upload_path = Path.build_filename(temp_dir, "decrypted-legacy-upload.txt");
        string plaintext = "DinoX FileManager HTTP runtime success with real legacy XEP-0027 PgpFileEncryptor\n";
        FileManagerHttpSetup? setup = null;
        string? stored_path = null;
        SlotRequestCapture? slot_capture = null;
        Soup.Server? server = null;

        try {
            if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
                throw new IOError.FAILED("Failed to create temporary FileManager legacy OpenPGP HTTPS test directory");
            }
            FileUtils.set_contents(input_path, plaintext);

            require_private_key(signer);
            require_public_key(recipient);
            require_email_uid(signer);
            require_email_uid(recipient);

            setup = create_file_manager_http_setup(account_bare_jid, signer, recipient);
            ((!) setup).conversation.encryption = Dino.Entities.Encryption.PGP;
            ((!) setup).openpgp_db.set_account_legacy_key(((!) setup).account, signer);
            ((!) setup).openpgp_db.set_contact_key(((!) setup).account, ((!) setup).conversation.counterpart.bare_jid, recipient,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            attach_openpgp_stream_module((!) setup);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) setup).stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager module was not registered for the FileManager legacy HTTPS runtime test");
            }
            string allow_reason;
            fail_if(!((!) pgp_manager).can_encrypt_for_selected_openpgp_mode(((!) setup).conversation, out allow_reason),
                "legacy XEP-0027 FileManager HTTPS test must be allowed by the selected legacy account/contact key state");
            ((!) setup).file_manager.add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor(((!) setup).stream_interactor));

            var upload_capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, upload_capture, ((!) setup).stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = GLib.Uri.parse(upload_url, GLib.UriFlags.NONE).get_host();
            if (upload_host == null || ((!) upload_host) == "") {
                throw new IOError.FAILED("legacy OpenPGP HTTPS test could not extract upload host for certificate pinning");
            }
            Dino.CertificateManager.pin_to_db(((!) setup).core_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) setup).file_manager.received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(file_transfer.id == -1,
                    "FileManager real legacy OpenPGP HTTPS test must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "FileManager real legacy OpenPGP HTTPS test must publish a stored outgoing path before transport");
            });

            slot_capture = respond_to_real_pgp_slot_request_with_urls(((!) setup).stream,
                "real-openpgp-legacy-runtime-success.txt.pgp",
                PGP_MIME_TYPE,
                download_url,
                upload_url,
                "Authorization",
                "Bearer local-openpgp-xep0027");

            var send_loop = new MainLoop();
            ((!) setup).file_manager.send_file.begin(File.new_for_path(input_path), ((!) setup).conversation, (file_transfer) => {
                file_transfer.server_file_name = "real-openpgp-legacy-runtime-success.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = plaintext.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) setup).file_manager.send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            if (slot_capture != null && ((!) slot_capture).handler_id != 0) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }

            fail_if(published_transfer == null,
                "FileManager real legacy OpenPGP HTTPS test must publish the local encrypted-at-rest copy before transport");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(slot_capture == null || !((!) slot_capture).matched,
                "real legacy PgpFileEncryptor must request an HTTP upload slot before the local HTTPS PUT");
            fail_if(file_transfer.provider != ((!) setup).sender.get_id(),
                "FileManager must select the real HTTP sender for the real legacy OpenPGP HTTPS path");
            fail_if(!upload_capture.handled,
                "real legacy OpenPGP HTTP sender must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", upload_capture.method,
                "real legacy OpenPGP HTTP sender must use PUT");
            fail_if_not_eq_str(PGP_MIME_TYPE, upload_capture.content_type ?? "",
                "real legacy OpenPGP HTTP sender must set the PGP request content type");
            fail_if_not_eq_str("Bearer local-openpgp-xep0027", upload_capture.authorization ?? "",
                "real legacy OpenPGP HTTP sender must forward allowed slot headers");
            fail_if(slot_capture == null || ((!) slot_capture).requested_size != upload_capture.body.length,
                "real legacy OpenPGP slot size must match the captured encrypted PUT body length");
            fail_if_not_eq_int(upload_capture.body.length, (int) upload_capture.content_length,
                "real legacy OpenPGP captured PUT body must match Content-Length");
            fail_if(contains_bytes(upload_capture.body, plaintext.data),
                "real legacy OpenPGP HTTPS PUT body must not contain plaintext bytes");

            FileUtils.set_data(uploaded_pgp_path, upload_capture.body);
            GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_pgp_path, decrypted_upload_path);
            string decrypted_text;
            FileUtils.get_contents(decrypted_upload_path, out decrypted_text);
            fail_if_not_eq_str(plaintext, decrypted_text,
                "real legacy OpenPGP captured PUT body must decrypt to the original payload");
            fail_if_not_eq_str("real-openpgp-legacy-runtime-success.txt", decrypted.filename,
                "real legacy OpenPGP captured PUT body must preserve the original filename");
            fail_if_not(decrypted.signature_valid,
                "real legacy OpenPGP captured PUT body must carry a valid signature");
            fail_if(decrypted.signer_fingerprint == null ||
                    normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
                "real legacy OpenPGP captured PUT body must be signed by the account key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, signer,
                "real legacy OpenPGP captured PUT packet must include the account recipient key");
            assert_encrypted_packet_contains_recipient_key(uploaded_pgp_path, recipient,
                "real legacy OpenPGP captured PUT packet must include the contact recipient key");

            assert_real_xep0027_body_url_message(((!) setup).stream, download_url, signer, recipient);

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful real legacy OpenPGP HTTPS upload must complete the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful real legacy OpenPGP HTTPS upload must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful real legacy OpenPGP HTTPS upload must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful real legacy OpenPGP upload must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful real legacy OpenPGP upload must assign a local file-sharing id");
            fail_if_not_eq_str(Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027, file_transfer.encryption_protocol ?? "",
                "successful real legacy OpenPGP upload must record the XEP-0027 file protocol");
            fail_if_not_eq_str("real-openpgp-legacy-runtime-success.txt.pgp", file_transfer.server_file_name ?? "",
                "real legacy PgpFileEncryptor must request the slot with the encrypted .pgp server filename");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the upload stream after successful real legacy OpenPGP upload");
            assert_single_http_source(file_transfer, download_url,
                "successful real legacy OpenPGP upload must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret(((!) setup).core_db, file_transfer, download_url,
                "successful real legacy OpenPGP upload must persist exactly one fragment-free local HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.ENCRYPTING,
                "FileManager must store the local outgoing copy before real legacy OpenPGP file encryption");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "real legacy PgpFileEncryptor must finish before the HTTPS slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "FileManager must request the XEP-0363 slot before real legacy OpenPGP HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "real legacy OpenPGP HTTP send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful real legacy OpenPGP HTTP send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state(((!) setup).core_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "FileManager must persist successful real legacy OpenPGP HTTPS upload as complete");
        } catch (Error e) {
            GLib.Test.message("FileManager real legacy OpenPGP HTTPS runtime test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (slot_capture != null && ((!) slot_capture).handler_id != 0 && setup != null) {
                SignalHandler.disconnect(((!) setup).stream, ((!) slot_capture).handler_id);
                ((!) slot_capture).handler_id = 0;
            }
            if (setup != null) ((!) setup).cleanup();
            if (server != null) ((!) server).disconnect();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            GPGHelper.secure_delete_file(decrypted_upload_path);
            GPGHelper.secure_delete_file(uploaded_pgp_path);
            GPGHelper.secure_delete_file(input_path);
            DirUtils.remove(temp_dir);
        }
    }

    private static void write_stream_to_file(InputStream input_stream, string output_path) throws Error {
        File output_file = File.new_for_path(output_path);
        OutputStream? output_stream = null;
        Error? stream_error = null;
        try {
            output_stream = output_file.create(FileCreateFlags.PRIVATE);
            uint8[] buffer = new uint8[8192];
            ssize_t read_bytes;
            while ((read_bytes = input_stream.read(buffer)) > 0) {
                size_t bytes_written;
                ((!) output_stream).write_all(buffer[0:(int) read_bytes], out bytes_written);
            }
        } catch (Error e) {
            stream_error = e;
        } finally {
            if (output_stream != null) {
                try {
                    ((!) output_stream).close();
                } catch (Error e) {
                    if (stream_error == null) stream_error = e;
                }
            }
        }
        if (stream_error != null) throw (!) stream_error;
    }

    private static FileManagerHttpSetup create_file_manager_http_setup(string account_bare_jid, string signer, string recipient, bool register_account = false) throws Error {
        _force_class_init(typeof(Dino.MessageProcessor));
        _force_class_init(typeof(Dino.MessageStorage));
        _force_class_init(typeof(Dino.FileTransferStorage));
        _force_class_init(typeof(Dino.FileManager));
        _force_class_init(typeof(Dino.EntityInfo));
        _force_class_init(typeof(Dino.RosterManager));
        _force_class_init(typeof(Dino.Calls));
        _force_class_init(typeof(Dino.ConversationManager));
        _force_class_init(typeof(Dino.PresenceManager));
        _force_class_init(typeof(Dino.MucManager));
        _force_class_init(typeof(Xmpp.Iq.Module));
        _force_class_init(typeof(Xmpp.MessageModule));
        _force_class_init(typeof(Xmpp.Bind.Flag));
        _force_class_init(typeof(Xmpp.Xep.ServiceDiscovery.Module));
        _force_class_init(typeof(Xmpp.Xep.HttpFileUpload.Module));

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-filemanager-http-" + Uuid.string_random());
        if (DirUtils.create_with_parents(temp_dir, 0700) == -1) {
            throw new IOError.FAILED("Failed to create temporary OpenPGP FileManager HTTP setup directory");
        }
        string core_db_path = Path.build_filename(temp_dir, "core.db");
        string openpgp_db_path = Path.build_filename(temp_dir, "openpgp.db");

        var core_db = new Dino.Database(core_db_path, "openpgp-filemanager-http-test");
        var openpgp_db = new Dino.Plugins.OpenPgp.Database(openpgp_db_path, null);
        var stream_interactor = new Dino.StreamInteractor.for_tests(core_db);
        Dino.MessageStorage.start(stream_interactor, core_db);
        Dino.FileTransferStorage.start(stream_interactor, core_db);
        Dino.MessageProcessor.start(stream_interactor, core_db);
        Dino.EntityInfo.start(stream_interactor, core_db);
        Dino.RosterManager.start(stream_interactor, core_db);
        Dino.Calls.start(stream_interactor, core_db);
        Dino.ConversationManager.start(stream_interactor, core_db);
        Dino.PresenceManager.start(stream_interactor, core_db);
        Dino.MucManager.start(stream_interactor);
        Dino.Plugins.OpenPgp.Manager.start(stream_interactor, openpgp_db);
        var file_encryption = new Dino.Security.FileEncryption("openpgp-filemanager-http-test");
        Dino.FileManager.start(stream_interactor, core_db, file_encryption);

        Dino.FileManager? file_manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
        if (file_manager == null) {
            throw new IOError.FAILED("missing FileManager in real OpenPGP HTTP sender test setup");
        }

        var sender = new Dino.Plugins.HttpFiles.HttpFileSender(stream_interactor, core_db);
        ((!) file_manager).add_sender(sender);

        var account = new Dino.Entities.Account(new Xmpp.Jid(account_bare_jid), "secret");
        account.persist(core_db);
        var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
        conversation.encryption = Dino.Entities.Encryption.PGP;
        conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
        conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

        openpgp_db.set_account_xmpp_key(account, signer);
        openpgp_db.set_contact_key(account, conversation.counterpart.bare_jid, recipient,
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
        openpgp_db.mark_contact_xmpp_key_verified(account, conversation.counterpart.bare_jid);

        if (register_account) {
            _force_class_init(typeof(Dino.Plugins.OpenPgp.Module));
            var manager = stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(Dino.Plugins.OpenPgp.Manager.IDENTITY);
            stream_interactor.module_manager.initialize_account_modules.connect((init_account, modules) => {
                modules.add(new Dino.Plugins.OpenPgp.Module(openpgp_db, init_account, null, manager, null));
            });
            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);
        }

        TestXmppStream stream = create_connected_http_upload_stream(stream_interactor, account);
        return new FileManagerHttpSetup(temp_dir, core_db_path, openpgp_db_path, core_db, openpgp_db,
            stream_interactor, (!) file_manager, sender, account, conversation, stream);
    }

    private static TestXmppStream create_connected_http_upload_stream(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account) throws Error {
        var stream = new TestXmppStream(new Xmpp.Jid("example.test"));
        var iq_module = stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(account, Xmpp.Iq.Module.IDENTITY);
        if (iq_module == null) {
            throw new IOError.FAILED("missing IQ module in real OpenPGP HTTP sender test setup");
        }
        stream.add_module((!) iq_module);
        ((!) iq_module).attach(stream);

        var message_module = stream_interactor.module_manager.get_module<Xmpp.MessageModule>(account, Xmpp.MessageModule.IDENTITY);
        if (message_module == null) {
            throw new IOError.FAILED("missing message module in real OpenPGP HTTP sender test setup");
        }
        stream.add_module((!) message_module);
        ((!) message_module).attach(stream);

        var service_discovery_module = stream_interactor.module_manager.get_module<Xmpp.Xep.ServiceDiscovery.Module>(
            account, Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        if (service_discovery_module == null) {
            throw new IOError.FAILED("missing service discovery module in real OpenPGP HTTP sender test setup");
        }
        stream.add_module((!) service_discovery_module);
        ((!) service_discovery_module).attach(stream);

        attach_openpgp_bookmark_modules_for_tests(stream_interactor, account, stream);
        install_empty_openpgp_bookmarks_responder_for_tests(stream);

        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream.add_flag(new Xmpp.Xep.HttpFileUpload.Flag(new Xmpp.Jid("upload.example.test"), "urn:xmpp:http:upload:0"));
        stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

        var upload_module = stream_interactor.module_manager.get_module<Xmpp.Xep.HttpFileUpload.Module>(
            account, Xmpp.Xep.HttpFileUpload.Module.IDENTITY);
        if (upload_module == null) {
            throw new IOError.FAILED("missing HTTP upload module in real OpenPGP HTTP sender test setup");
        }
        stream.stream_negotiated(stream);
        ((!) upload_module).feature_available(stream, long.MAX);
        return stream;
    }

    private static void attach_openpgp_bookmark_modules_for_tests(Dino.StreamInteractor stream_interactor,
            Dino.Entities.Account account, TestXmppStream stream) throws Error {
        _force_class_init(typeof(Xmpp.Xep.PrivateXmlStorage.Module));
        _force_class_init(typeof(Xmpp.Xep.Bookmarks.Module));
        _force_class_init(typeof(Xmpp.Xep.Pubsub.Module));
        _force_class_init(typeof(Xmpp.Xep.Bookmarks2.Module));

        var private_xml_module = stream_interactor.module_manager.get_module<Xmpp.Xep.PrivateXmlStorage.Module>(
            account, Xmpp.Xep.PrivateXmlStorage.Module.IDENTITY);
        if (private_xml_module == null) {
            throw new IOError.FAILED("missing private XML storage module in OpenPGP HTTP sender test setup");
        }
        if (stream.get_module<Xmpp.Xep.PrivateXmlStorage.Module>(Xmpp.Xep.PrivateXmlStorage.Module.IDENTITY) == null) {
            stream.add_module((!) private_xml_module);
            ((!) private_xml_module).attach(stream);
        }

        var bookmarks_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Bookmarks.Module>(
            account, Xmpp.Xep.Bookmarks.Module.IDENTITY);
        if (bookmarks_module == null) {
            throw new IOError.FAILED("missing legacy bookmarks module in OpenPGP HTTP sender test setup");
        }
        if (stream.get_module<Xmpp.Xep.Bookmarks.Module>(Xmpp.Xep.Bookmarks.Module.IDENTITY) == null) {
            stream.add_module((!) bookmarks_module);
            ((!) bookmarks_module).attach(stream);
        }

        var pubsub_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Pubsub.Module>(
            account, Xmpp.Xep.Pubsub.Module.IDENTITY);
        if (pubsub_module == null) {
            throw new IOError.FAILED("missing PubSub module in OpenPGP HTTP sender test setup");
        }
        if (stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY) == null) {
            stream.add_module((!) pubsub_module);
            ((!) pubsub_module).attach(stream);
        }

        var bookmarks2_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Bookmarks2.Module>(
            account, Xmpp.Xep.Bookmarks2.Module.IDENTITY);
        if (bookmarks2_module == null) {
            throw new IOError.FAILED("missing PEP bookmarks module in OpenPGP HTTP sender test setup");
        }
        if (stream.get_module<Xmpp.Xep.Bookmarks2.Module>(Xmpp.Xep.Bookmarks2.Module.IDENTITY) == null) {
            stream.add_module((!) bookmarks2_module);
            ((!) bookmarks2_module).attach(stream);
        }
    }

    private static void install_empty_openpgp_bookmarks_responder_for_tests(TestXmppStream stream) {
        stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            if (outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET) return;

            Xmpp.StanzaNode? query = outgoing.get_subnode("query", NS_PRIVATE_XML_STORAGE);
            if (query == null) return;
            if (((!) query).get_subnode("storage", NS_BOOKMARKS) == null) return;

            stream.emit_iq_result(build_empty_openpgp_bookmarks_result_for_request(outgoing));
        });
    }

    private static Xmpp.StanzaNode build_empty_openpgp_bookmarks_result_for_request(Xmpp.StanzaNode request_iq) {
        var result_iq = new Xmpp.StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? to = request_iq.get_attribute("to");
        if (to != null) result_iq.put_attribute("from", (!) to);

        result_iq.put_node(new Xmpp.StanzaNode.build("query", NS_PRIVATE_XML_STORAGE).add_self_xmlns()
            .put_node(new Xmpp.StanzaNode.build("storage", NS_BOOKMARKS).add_self_xmlns()));
        return result_iq;
    }

    private static TestXmppStream create_connected_openpgp_pubsub_stream(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account) throws Error {
        _force_class_init(typeof(Xmpp.Iq.Module));
        _force_class_init(typeof(Xmpp.MessageModule));
        _force_class_init(typeof(Xmpp.Bind.Flag));
        _force_class_init(typeof(Xmpp.Xep.Pubsub.Module));
        _force_class_init(typeof(Xmpp.Xep.OpenPgp.Module));

        var stream = new TestXmppStream(new Xmpp.Jid("example.test"));
        var iq_module = stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(account, Xmpp.Iq.Module.IDENTITY);
        if (iq_module == null) {
            throw new IOError.FAILED("missing IQ module in XEP-0373 PubSub test setup");
        }
        stream.add_module((!) iq_module);
        ((!) iq_module).attach(stream);

        var message_module = stream_interactor.module_manager.get_module<Xmpp.MessageModule>(account, Xmpp.MessageModule.IDENTITY);
        if (message_module == null) {
            throw new IOError.FAILED("missing message module in XEP-0373 PubSub test setup");
        }
        stream.add_module((!) message_module);
        ((!) message_module).attach(stream);

        stream.add_module(new Xmpp.Xep.Pubsub.Module());
        stream.add_module(new Xmpp.Xep.OpenPgp.Module());

        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        stream.stream_negotiated(stream);
        return stream;
    }

    private static TestXmppStream create_connected_legacy_presence_stream(Dino.StreamInteractor stream_interactor,
            Dino.Entities.Account account, Dino.Plugins.OpenPgp.Database openpgp_db,
            Dino.Plugins.OpenPgp.Manager pgp_manager, bool announce_negotiated = true) throws Error {
        _force_class_init(typeof(Xmpp.Presence.Module));
        _force_class_init(typeof(Xmpp.MessageModule));
        _force_class_init(typeof(Xmpp.Bind.Flag));
        _force_class_init(typeof(Dino.Plugins.OpenPgp.Module));

        stream_interactor.module_manager.initialize_account_modules.connect((init_account, modules) => {
            if (!Dino.Entities.Account.equals_func(init_account, account)) return;
            modules.add(new Dino.Plugins.OpenPgp.Module(openpgp_db, account, null, pgp_manager, null));
        });
        stream_interactor.module_manager.initialize(account);
        stream_interactor.account_added(account);

        var stream = new TestXmppStream(new Xmpp.Jid("example.test"));
        var presence_module = stream_interactor.module_manager.get_module<Xmpp.Presence.Module>(
            account, Xmpp.Presence.Module.IDENTITY);
        if (presence_module == null) {
            throw new IOError.FAILED("missing presence module in XEP-0027 signed-presence test setup");
        }
        stream.add_module((!) presence_module);
        ((!) presence_module).attach(stream);

        var message_module = stream_interactor.module_manager.get_module<Xmpp.MessageModule>(
            account, Xmpp.MessageModule.IDENTITY);
        if (message_module == null) {
            throw new IOError.FAILED("missing message module in XEP-0027 signed-presence test setup");
        }
        stream.add_module((!) message_module);
        ((!) message_module).attach(stream);

        var openpgp_module = stream_interactor.module_manager.get_module<Dino.Plugins.OpenPgp.Module>(
            account, Dino.Plugins.OpenPgp.Module.IDENTITY);
        if (openpgp_module == null) {
            throw new IOError.FAILED("missing XEP-0027 OpenPGP module in signed-presence test setup");
        }
        stream.add_module((!) openpgp_module);
        ((!) openpgp_module).attach(stream);

        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        if (announce_negotiated) stream.stream_negotiated(stream);
        return stream;
    }

    private static void attach_openpgp_stream_module(FileManagerHttpSetup setup) throws Error {
        var presence_module = new Xmpp.Presence.Module();
        setup.stream.add_module(presence_module);
        presence_module.attach(setup.stream);

        Dino.Plugins.OpenPgp.Manager? pgp_manager = setup.stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
            Dino.Plugins.OpenPgp.Manager.IDENTITY);
        if (pgp_manager == null) {
            throw new IOError.FAILED("missing OpenPGP manager before attaching the test stream OpenPGP module");
        }

        var openpgp_module = new Dino.Plugins.OpenPgp.Module(setup.openpgp_db, setup.account, null, (!) pgp_manager, null);
        setup.stream.add_module(openpgp_module);
        openpgp_module.attach(setup.stream);
    }

    private static SlotRequestCapture respond_to_real_pgp_slot_request(TestXmppStream stream, string filename, string content_type) {
        return respond_to_real_pgp_slot_request_with_urls(stream, filename, content_type,
            "https://upload.example.test/get/" + filename,
            "https://[",
            null,
            null);
    }

    private static SlotRequestCapture respond_to_real_pgp_slot_request_with_urls(TestXmppStream stream, string filename,
            string content_type, string url_get, string url_put, string? header_name, string? header_value) {
        var capture = new SlotRequestCapture();
        capture.handler_id = stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            Xmpp.StanzaNode? request = outgoing.get_subnode("request", NS_HTTP_UPLOAD_0);
            if (request == null) return;
            if (((!) request).get_attribute("filename") != filename) return;
            if (((!) request).get_attribute("content-type") != content_type) return;

            string? size_attr = ((!) request).get_attribute("size");
            if (size_attr != null) {
                capture.requested_size = int64.parse((!) size_attr);
            }
            capture.matched = true;
            var result_iq = build_slot_result_for_request(outgoing, url_get, url_put);
            if (header_name != null && header_value != null) {
                append_slot_header(result_iq, (!) header_name, (!) header_value);
            }
            stream.emit_iq_result(result_iq);
            if (capture.handler_id != 0) {
                SignalHandler.disconnect(stream, capture.handler_id);
                capture.handler_id = 0;
            }
        });
        return capture;
    }

    private static Xmpp.StanzaNode build_slot_result_for_request(Xmpp.StanzaNode request_iq, string url_get, string url_put) {
        var result_iq = new Xmpp.StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? to = request_iq.get_attribute("to");
        if (to != null) result_iq.put_attribute("from", (!) to);

        var slot = new Xmpp.StanzaNode.build("slot", NS_HTTP_UPLOAD_0).add_self_xmlns();
        slot.put_node(new Xmpp.StanzaNode.build("get", NS_HTTP_UPLOAD_0).put_attribute("url", url_get));
        slot.put_node(new Xmpp.StanzaNode.build("put", NS_HTTP_UPLOAD_0).put_attribute("url", url_put));
        result_iq.put_node(slot);
        return result_iq;
    }

    private static void append_slot_header(Xmpp.StanzaNode result_iq, string name, string value) {
        Xmpp.StanzaNode? slot = result_iq.get_subnode("slot", NS_HTTP_UPLOAD_0);
        fail_if(slot == null, "slot result must contain slot node");
        if (slot == null) return;

        Xmpp.StanzaNode? put = ((!) slot).get_subnode("put", NS_HTTP_UPLOAD_0);
        fail_if(put == null, "slot result must contain put node");
        if (put == null) return;

        ((!) put).put_node(new Xmpp.StanzaNode.build("header", NS_HTTP_UPLOAD_0)
            .put_attribute("name", name)
            .put_node(new Xmpp.StanzaNode.text(value)));
    }

    private static bool stream_has_message_stanza(TestXmppStream stream) {
        foreach (Xmpp.StanzaNode node in stream.written_nodes) {
            if (node.name == "message") return true;
        }
        return false;
    }

    private static void drain_pending_events() {
        for (int i = 0; i < 8; i++) {
            while (MainContext.default().pending()) {
                MainContext.default().iteration(false);
            }
        }
    }

    private static void assert_no_message_stanzas_before_boundary(TestXmppStream stream, int boundary, string reason) {
        fail_if(boundary < 0 || boundary > stream.written_nodes.size,
            @"$(reason): invalid boundary $(boundary) for $(stream.written_nodes.size) written nodes");
        int count = int.min(boundary, stream.written_nodes.size);
        for (int i = 0; i < count; i++) {
            fail_if(stream.written_nodes[i].name == "message", reason);
        }
    }

    private static void assert_no_outgoing_wire_text(TestXmppStream stream, string text, string reason) {
        foreach (Xmpp.StanzaNode node in stream.written_nodes) {
            fail_if(node.to_string().contains(text), reason);
        }
    }

    private static string create_legacy_presence_signature(string status_text, string signer_fingerprint) throws Error {
        GPGHelper.Key signer_key = require_private_key(signer_fingerprint);
        string armored_signature = GPGHelper.sign(status_text, 1, signer_key);
        string? signature = Dino.Plugins.OpenPgp.Module.extract_signature_from_armor(armored_signature);
        if (signature == null || ((!) signature).length == 0) {
            throw new IOError.FAILED("Live XEP-0027 signed-presence test could not extract detached signature data");
        }
        return (!) signature;
    }

    private static string export_secret_key_for_tests(string fingerprint) throws Error {
        string secret_key = run_gpg_stdout({ "--armor", "--export-secret-keys", fingerprint });
        if (secret_key.length == 0 || !secret_key.contains("-----BEGIN PGP PRIVATE KEY BLOCK-----")) {
            throw new IOError.FAILED("Live OpenPGP test could not export the account secret key");
        }
        return secret_key;
    }

    private static Xmpp.Presence.Stanza create_legacy_presence_stanza(string from_full_jid, string status_text,
            string signature) throws Error {
        var presence = new Xmpp.Presence.Stanza();
        presence.from = new Xmpp.Jid(from_full_jid);
        presence.type_ = Xmpp.Presence.Stanza.TYPE_AVAILABLE;
        presence.status = status_text;
        presence.stanza.put_node(new Xmpp.StanzaNode.build("x", "jabber:x:signed")
            .add_self_xmlns()
            .put_node(new Xmpp.StanzaNode.text(signature)));
        return presence;
    }

    private static Xmpp.Presence.Stanza create_unavailable_presence_stanza(string from_full_jid) throws Error {
        var presence = new Xmpp.Presence.Stanza();
        presence.from = new Xmpp.Jid(from_full_jid);
        presence.type_ = Xmpp.Presence.Stanza.TYPE_UNAVAILABLE;
        return presence;
    }

    private static bool wait_for_legacy_readiness(Dino.Plugins.OpenPgp.Manager manager,
            Dino.Entities.Conversation conversation, int timeout_ms, out string reason) {
        reason = "";
        for (int elapsed = 0; elapsed <= timeout_ms; elapsed += 20) {
            drain_pending_events();
            if (manager.can_encrypt_for_selected_openpgp_mode(conversation, out reason)) {
                return true;
            }
            Thread.usleep(20 * 1000);
        }
        drain_pending_events();
        return manager.can_encrypt_for_selected_openpgp_mode(conversation, out reason);
    }

    private static bool wait_for_legacy_announcement_state(Dino.Plugins.OpenPgp.Database db,
            Dino.Entities.Account account, Xmpp.Jid jid, bool expected, int timeout_ms) {
        for (int elapsed = 0; elapsed <= timeout_ms; elapsed += 20) {
            drain_pending_events();
            if (db.contact_legacy_key_is_announced(account, jid) == expected) {
                return true;
            }
            Thread.usleep(20 * 1000);
        }
        drain_pending_events();
        return db.contact_legacy_key_is_announced(account, jid) == expected;
    }

    private static void assert_phase_order(Gee.List<Dino.Entities.FileTransfer.Phase> phases, Dino.Entities.FileTransfer.Phase before, Dino.Entities.FileTransfer.Phase after, string reason) {
        int before_index = -1;
        int after_index = -1;
        for (int i = 0; i < phases.size; i++) {
            if (phases[i] == before && before_index < 0) before_index = i;
            if (phases[i] == after && after_index < 0) after_index = i;
        }
        fail_if(before_index < 0 || after_index < 0 || before_index >= after_index, reason);
    }

    private static void assert_persisted_transfer_state(Dino.Database db, Dino.Entities.FileTransfer file_transfer, Dino.Entities.FileTransfer.State expected_state, string reason) {
        Qlite.RowOption row = db.file_transfer.select()
                .with(db.file_transfer.id, "=", file_transfer.id)
                .single()
                .row();
        fail_if(!row.is_present(), "real OpenPGP HTTP sender transfer must be present in the database");
        var persisted_state = (Dino.Entities.FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        fail_if(persisted_state != expected_state, reason);
    }

    private static bool skip_if_local_https_sockets_unavailable() {
        bool require_live = Environment.get_variable("DINOX_OPENPGP_TEST_REQUIRE_LIVE") == "1";
        TlsCertificate tls_cert;
        try {
            tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        } catch (Error e) {
            fail_if(true, @"Local HTTPS upload test certificate fixture must parse: $(e.message)");
            return false;
        }

        string error_message;
        if (local_https_test_sockets_available(tls_cert, out error_message)) return false;

        string message = "Local HTTPS upload test sockets unavailable: %s".printf(error_message);
        if (require_live) {
            GLib.Test.message(message);
            GLib.Test.fail();
        } else {
            GLib.Test.skip(message);
        }
        return true;
    }

    private static bool local_https_test_sockets_available(TlsCertificate tls_cert, out string error_message) {
        error_message = "";
        Soup.Server? probe = null;
        try {
            probe = new Soup.Server("server-header", "DinoX-OpenPGP-HTTPS-Probe/1.0", null);
            ((!) probe).set_tls_certificate(tls_cert);
            ((!) probe).listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
            return true;
        } catch (Error e) {
            error_message = e.message;
            return false;
        } finally {
            if (probe != null) ((!) probe).disconnect();
        }
    }

    private static Soup.Server start_https_upload_server(uint response_status, HttpsUploadCapture capture,
            TestXmppStream stream, out string upload_url, out string download_url, out TlsCertificate tls_cert) throws Error {
        tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        var server = new Soup.Server("server-header", "DinoX-OpenPGP-HTTPS-Test/1.0", null);
        server.set_tls_certificate(tls_cert);
        server.add_handler("/upload/openpgp.bin", (srv, msg, path, query) => {
            capture.handled = true;
            capture.written_count_at_upload = stream.written_nodes.size;
            capture.method = msg.get_method();
            capture.content_type = msg.get_request_headers().get_one("Content-Type");
            capture.authorization = msg.get_request_headers().get_one("Authorization");
            capture.content_length = msg.get_request_headers().get_content_length();
            capture.body = copy_bytes(msg.get_request_body().flatten());
            if (capture.on_upload != null) {
                ((!) capture.on_upload)();
            }
            msg.set_status(response_status, null);
            set_server_string_response(msg, "text/plain", "ok");
        });
        server.listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
        upload_url = get_https_server_url(server, "/upload/openpgp.bin");
        download_url = get_https_server_url(server, "/download/openpgp.bin");
        return server;
    }

    private static Soup.Server start_https_body_stream_cancel_server(BlockedBodyUploadCapture capture,
            TestXmppStream stream, out string upload_url, out string download_url, out TlsCertificate tls_cert) throws Error {
        tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        var server = new Soup.Server("server-header", "DinoX-OpenPGP-HTTPS-Body-Cancel-Test/1.0", null);
        server.set_tls_certificate(tls_cert);
        server.request_started.connect((msg) => {
            capture.mark_request_started();
            msg.got_headers.connect(() => {
                capture.mark_headers_seen(msg, stream);
            });
        });
        server.request_read.connect((msg) => {
            capture.mark_request_read();
        });
        server.add_handler("/upload/openpgp-blocking.bin", (srv, msg, path, query) => {
            capture.mark_handler_called();
            msg.set_status(500, null);
            set_server_string_response(msg, "text/plain", "unexpected complete body");
        });
        server.listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
        upload_url = get_https_server_url(server, "/upload/openpgp-blocking.bin");
        download_url = get_https_server_url(server, "/download/openpgp-blocking.bin");
        return server;
    }

    private static Soup.Server start_hkp_keyserver(string armored_key, HkpKeyserverCapture capture,
            out string keyserver_url) throws Error {
        var server = new Soup.Server("server-header", "DinoX-OpenPGP-HKP-Test/1.0", null);
        server.add_handler("/pks/lookup", (srv, msg, path, query) => {
            capture.request_count++;
            capture.last_method = msg.get_method();
            capture.last_path = path;
            msg.set_status(200, null);
            set_server_string_response(msg, "application/pgp-keys", armored_key);
        });
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        keyserver_url = get_hkp_server_url(server);
        return server;
    }

    private static string get_https_server_url(Soup.Server server, string path) {
        foreach (Uri uri in server.get_uris()) {
            string base_url = uri.to_string();
            if (base_url.has_suffix("/")) {
                base_url = base_url.substring(0, base_url.length - 1);
            }
            return base_url + path;
        }
        GLib.error("Local HTTPS upload test server did not expose a URI");
    }

    private static string get_hkp_server_url(Soup.Server server) {
        foreach (Uri uri in server.get_uris()) {
            string base_url = uri.to_string();
            if (base_url.has_suffix("/")) {
                base_url = base_url.substring(0, base_url.length - 1);
            }
            if (base_url.has_prefix("http://")) {
                return "hkp://" + base_url.substring("http://".length);
            }
            return base_url;
        }
        GLib.error("Local HKP keyserver test did not expose a URI");
    }

    private static uint8[] copy_bytes(Bytes bytes) {
        unowned uint8[]? raw_maybe = bytes.get_data();
        if (raw_maybe == null) return new uint8[0];

        unowned uint8[] raw = (!) raw_maybe;
        uint8[] copy = new uint8[raw.length];
        for (int i = 0; i < raw.length; i++) {
            copy[i] = raw[i];
        }
        return copy;
    }

    private static uint8[] read_stream_chunk(InputStream stream, int max_len, Cancellable? cancellable = null) throws Error {
        uint8[] buffer = new uint8[max_len];
        ssize_t read = stream.read(buffer, cancellable);
        if (read <= 0) return new uint8[0];

        uint8[] chunk = new uint8[(int) read];
        for (int i = 0; i < chunk.length; i++) {
            chunk[i] = buffer[i];
        }
        return chunk;
    }

    private static Xmpp.StanzaNode? find_openpgp_message(TestXmppStream stream) {
        foreach (Xmpp.StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("openpgp", NS_OPENPGP) != null) {
                return node;
            }
        }
        return null;
    }

    private static Xmpp.StanzaNode? find_legacy_openpgp_message(TestXmppStream stream) {
        foreach (Xmpp.StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("x", NS_OPENPGP_LEGACY) != null) {
                return node;
            }
        }
        return null;
    }

    private static void assert_real_xep0374_body_url_message(TestXmppStream stream, string download_url,
            Xmpp.Jid expected_recipient, string signer, string recipient) throws Error {
        Xmpp.StanzaNode? openpgp_message = find_openpgp_message(stream);
        fail_if(openpgp_message == null,
            "real XEP-0374 OpenPGP send must write an OpenPGP payload stanza");
        if (openpgp_message == null) return;

        Xmpp.StanzaNode? body_node = ((!) openpgp_message).get_subnode("body");
        fail_if(body_node == null ||
                ((!) body_node).get_string_content() != "[This message is encrypted with OpenPGP for XMPP (XEP-0373/0374)]",
            "real XEP-0374 OpenPGP sent stanza must expose only the OpenPGP fallback body outside the encrypted payload");
        Xmpp.StanzaNode? openpgp_node = ((!) openpgp_message).get_subnode("openpgp", NS_OPENPGP);
        fail_if(openpgp_node == null,
            "real XEP-0374 OpenPGP sent stanza must carry an XEP-0374 payload node");
        fail_if(((!) openpgp_message).get_subnode("x", NS_OPENPGP_LEGACY) != null,
            "real XEP-0374 OpenPGP send must not fall back to legacy XEP-0027 payload markup");

        if (openpgp_node == null) return;
        uint8[] encrypted_signcrypt = Base64.decode(((!) openpgp_node).get_string_content());
        assert_encrypted_packet_data_contains_recipient_key(encrypted_signcrypt, signer,
            "real XEP-0374 body-url packet must include the account recipient key");
        assert_encrypted_packet_data_contains_recipient_key(encrypted_signcrypt, recipient,
            "real XEP-0374 body-url packet must include the contact recipient key");
        GPGHelper.DecryptedData decrypted = GPGHelper.decrypt_data(encrypted_signcrypt);
        fail_if_not(decrypted.signature_valid,
            "real XEP-0374 body-url stanza must carry a valid OpenPGP signature");
        fail_if(decrypted.signer_fingerprint == null ||
                normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != signer,
            "real XEP-0374 body-url stanza must be signed by the account key");

        string signcrypt_xml = (string) decrypted.data;
        Xmpp.StanzaNode signcrypt_node = parse_stanza_node_sync(signcrypt_xml);
        Xmpp.Xep.OpenPgpContent.SigncryptElement? signcrypt = Xmpp.Xep.OpenPgpContent.SigncryptElement.from_stanza_node(signcrypt_node);
        fail_if(signcrypt == null,
            "real XEP-0374 body-url decrypted XML must be a signcrypt element");
        if (signcrypt != null) {
            fail_if(((!) signcrypt).to == null || !((!) ((!) signcrypt).to).equals_bare(expected_recipient),
                "real XEP-0374 body-url signcrypt recipient must match the expected recipient");
            fail_if_not_eq_str(download_url, ((!) signcrypt).get_body_text() ?? "",
                "real XEP-0374 body-url signcrypt body must contain the HTTPS download URL");
        }

        assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, download_url,
            "real XEP-0374 body-only send must not expose file metadata outside the OpenPGP payload");
    }

    private static void assert_real_xep0027_body_url_message(TestXmppStream stream, string download_url,
            string signer, string recipient) throws Error {
        Xmpp.StanzaNode? legacy_message = find_legacy_openpgp_message(stream);
        fail_if(legacy_message == null,
            "real legacy XEP-0027 OpenPGP send must write a legacy encrypted payload stanza");
        if (legacy_message == null) return;

        Xmpp.StanzaNode? body_node = ((!) legacy_message).get_subnode("body");
        fail_if(body_node == null ||
                ((!) body_node).get_string_content() != "[This message is OpenPGP encrypted (see XEP-0027)]",
            "real legacy XEP-0027 OpenPGP sent stanza must expose only the legacy fallback body outside the encrypted payload");
        Xmpp.StanzaNode? legacy_node = ((!) legacy_message).get_subnode("x", NS_OPENPGP_LEGACY);
        fail_if(legacy_node == null,
            "real legacy XEP-0027 OpenPGP sent stanza must carry a legacy encrypted payload node");
        fail_if(((!) legacy_message).get_subnode("openpgp", NS_OPENPGP) != null,
            "real legacy XEP-0027 OpenPGP send must not use XEP-0374 payload markup");

        if (legacy_node == null) return;
        string encrypted_body_url_armor = build_legacy_openpgp_armor(((!) legacy_node).get_string_content());
        assert_encrypted_armor_contains_recipient_key(encrypted_body_url_armor, signer,
            "real legacy XEP-0027 body-url packet must include the account recipient key");
        assert_encrypted_armor_contains_recipient_key(encrypted_body_url_armor, recipient,
            "real legacy XEP-0027 body-url packet must include the contact recipient key");

        string decrypted_body_url = GPGHelper.decrypt(encrypted_body_url_armor);
        fail_if_not_eq_str(download_url, decrypted_body_url,
            "real legacy XEP-0027 body-url encrypted payload must contain the HTTPS download URL");

        assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, download_url,
            "real legacy XEP-0027 body-only send must not expose file metadata outside the OpenPGP payload");
    }

    private static string build_legacy_openpgp_armor(string packet_text) {
        return "-----BEGIN PGP MESSAGE-----\n\n" + packet_text.strip() + "\n-----END PGP MESSAGE-----";
    }

    private static Xmpp.StanzaNode parse_stanza_node_sync(string xml) throws Error {
        var reader = new Xmpp.StanzaReader.for_string(xml);
        var loop = new MainLoop();
        Xmpp.StanzaNode? node = null;
        Error? parse_error = null;
        reader.read_stanza_node.begin((obj, res) => {
            try {
                node = reader.read_stanza_node.end(res);
            } catch (Error e) {
                parse_error = e;
            }
            loop.quit();
        });
        loop.run();
        if (parse_error != null) throw (!) parse_error;
        if (node == null) throw new IOError.FAILED("Failed to parse OpenPGP signcrypt XML");
        return (!) node;
    }

    private static void assert_no_cleartext_transfer_url_or_outer_file_stanzas(TestXmppStream stream, string download_url,
            string sensitive_body_url, string reason) {
        foreach (Xmpp.StanzaNode node in stream.written_nodes) {
            if (node.name != "message") continue;

            fail_if(node.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null,
                @"$(reason): unexpected outer SFS file-sharing element");
            fail_if(node.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI) != null,
                @"$(reason): unexpected outer SFS sources attachment");
            fail_if(node.get_subnode("attach-to", Xmpp.Xep.MessageAttaching.NS_URI) != null,
                @"$(reason): unexpected outer message-attachment element");
            fail_if(node.get_subnode("x", Xmpp.Xep.OutOfBandData.NS_URI) != null,
                @"$(reason): unexpected outer OOB URL element");

            Xmpp.StanzaNode? body_node = node.get_subnode("body");
            if (body_node != null) {
                string body = ((!) body_node).get_string_content();
                fail_if(body.has_prefix("aesgcm://") || body.contains(download_url) || body.contains(sensitive_body_url),
                    @"$(reason): unexpected cleartext transfer URL in message body");
            }

            string wire = node.to_string();
            fail_if(wire.contains(download_url) || wire.contains(sensitive_body_url),
                @"$(reason): unexpected cleartext transfer URL in outer stanza XML");
        }
    }

    private static void assert_single_http_source(Dino.Entities.FileTransfer file_transfer, string expected_url, string reason) {
        fail_if(file_transfer.sfs_sources.size != 1, reason);
        var http_source = file_transfer.sfs_sources[0] as Xmpp.Xep.StatelessFileSharing.HttpSource;
        fail_if(http_source == null, reason);
        fail_if_not_eq_str(expected_url, ((!) http_source).url, reason);
    }

    private static void assert_no_http_sources(Dino.Entities.FileTransfer file_transfer, string reason) {
        fail_if(file_transfer.sfs_sources.size != 0, reason);
    }

    private static void assert_only_persisted_http_source_without_secret(Dino.Database db,
            Dino.Entities.FileTransfer file_transfer, string expected_url, string reason) {
        int rows = 0;
        foreach (Qlite.Row row in db.sfs_sources.select().with(db.sfs_sources.file_transfer_id, "=", file_transfer.id)) {
            rows++;
            string type = row[db.sfs_sources.type];
            string data = row[db.sfs_sources.data];
            fail_if(type != "http", @"$(reason): unexpected persisted source type $(type)");
            fail_if_not_eq_str(expected_url, data, reason);
            fail_if(data.has_prefix("aesgcm://") || data.contains("#"),
                @"$(reason): persisted local source must not carry aesgcm secrets or fragments");
        }
        fail_if(rows != 1, reason);
    }

    private static void assert_no_persisted_sources(Dino.Database db, Dino.Entities.FileTransfer file_transfer, string reason) {
        foreach (Qlite.Row row in db.sfs_sources.select().with(db.sfs_sources.file_transfer_id, "=", file_transfer.id)) {
            fail_if(true, @"$(reason): unexpected persisted source type $(row[db.sfs_sources.type])");
        }
    }

    private static Dino.Plugins.OpenPgp.Manager require_openpgp_manager(FileManagerHttpSetup setup) throws Error {
        Dino.Plugins.OpenPgp.Manager? manager = setup.stream_interactor.get_module<Dino.Plugins.OpenPgp.Manager>(
            Dino.Plugins.OpenPgp.Manager.IDENTITY);
        if (manager == null) {
            throw new IOError.FAILED("missing OpenPGP manager in private-MUC recipient test setup");
        }
        return (!) manager;
    }

    private static void bind_live_private_message_target_for_tests(FileManagerHttpSetup setup,
            Xmpp.Jid occupant) throws Error {
        var muc_manager = setup.stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
        string? identity = muc_manager.get_private_message_peer_identity(setup.account, occupant);
        if (identity == null) {
            throw new IOError.FAILED("OpenPGP MUC-PM fixture must have a joined room and a present, identified recipient");
        }
        setup.account.enabled = true;
        // A live private conversation also has a parent room in the manager;
        // message dispatch checks the current room's occupant list.
        setup.stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY)
            .create_conversation(occupant.bare_jid, setup.account, Dino.Entities.Conversation.Type.GROUPCHAT);
        setup.conversation.muc_pm_peer_identity = (!) identity;
    }

    private static Xmpp.Xep.Muc.Flag attach_openpgp_muc_modules_for_tests(FileManagerHttpSetup setup,
            Xmpp.Jid room_jid, string own_nick) throws Error {
        _force_class_init(typeof(Xmpp.Presence.Module));
        _force_class_init(typeof(Xmpp.Xep.Muc.Module));

        var presence_module = setup.stream_interactor.module_manager.get_module<Xmpp.Presence.Module>(
            setup.account, Xmpp.Presence.Module.IDENTITY);
        if (presence_module == null) {
            throw new IOError.FAILED("missing presence module in OpenPGP private-MUC recipient test setup");
        }
        if (setup.stream.get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY) == null) {
            setup.stream.add_module((!) presence_module);
            ((!) presence_module).attach(setup.stream);
        }

        var muc_module = setup.stream_interactor.module_manager.get_module<Xmpp.Xep.Muc.Module>(
            setup.account, Xmpp.Xep.Muc.Module.IDENTITY);
        if (muc_module == null) {
            throw new IOError.FAILED("missing MUC module in OpenPGP private-MUC recipient test setup");
        }
        if (setup.stream.get_module<Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY) == null) {
            setup.stream.add_module((!) muc_module);
            ((!) muc_module).attach(setup.stream);
        }

        Xmpp.Xep.Muc.Flag? muc_flag = setup.stream.get_flag(Xmpp.Xep.Muc.Flag.IDENTITY);
        if (muc_flag == null) {
            throw new IOError.FAILED("missing MUC flag after attaching OpenPGP private-MUC test modules");
        }
        ((!) muc_flag).set_muc_nick(room_jid.with_resource(own_nick));
        return (!) muc_flag;
    }

    private static void mark_openpgp_room_private_in_entity_info(Dino.Database db, Dino.Entities.Account account,
            Xmpp.Jid room_jid) {
        string entity = "openpgp-private-muc-file-recipient-test-" + Uuid.string_random();
        db.entity.upsert()
            .value<int>(db.entity.account_id, account.id, true)
            .value<int>(db.entity.jid_id, db.get_jid_id(room_jid), true)
            .value<string>(db.entity.resource, "", true)
            .value<long>(db.entity.last_seen, (long) new DateTime.now_utc().to_unix())
            .value<string>(db.entity.caps_hash, entity)
            .perform();
        db.entity_feature.insert()
            .value(db.entity_feature.entity, entity)
            .value(db.entity_feature.feature, "muc_membersonly")
            .perform();
        db.entity_feature.insert()
            .value(db.entity_feature.entity, entity)
            .value(db.entity_feature.feature, "muc_nonanonymous")
            .perform();
    }

    private static void query_openpgp_room_info_for_tests(TestXmppStream stream, Xmpp.Jid room_jid, bool private_room) {
        Xmpp.Xep.Muc.Module? muc_module = stream.get_module<Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        fail_if(muc_module == null, "OpenPGP private-MUC recipient proof requires an attached MUC module");
        if (muc_module == null) return;

        ulong info_handler_id = 0;
        info_handler_id = stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            if (outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET) return;
            if (outgoing.get_attribute("to") != room_jid.to_string()) return;

            Xmpp.StanzaNode? query = outgoing.get_subnode("query", NS_DISCO_INFO);
            if (query == null) return;

            SignalHandler.disconnect(stream, info_handler_id);
            info_handler_id = 0;
            stream.emit_iq_result(build_openpgp_room_info_result_for_request(outgoing, room_jid, private_room));
        });

        ulong updated_handler_id = 0;
        var query_loop = new MainLoop();
        bool query_timed_out = false;
        bool room_info_updated = false;
        uint timeout_id = Timeout.add_seconds(2, () => {
            query_timed_out = true;
            query_loop.quit();
            return Source.REMOVE;
        });
        updated_handler_id = ((!) muc_module).room_info_updated.connect((updated_stream, updated_room) => {
            if (updated_stream != stream || !updated_room.equals_bare(room_jid)) return;
            room_info_updated = true;
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            query_loop.quit();
        });
        ((!) muc_module).query_room_info.begin(stream, room_jid, (obj, res) => {
            ((!) muc_module).query_room_info.end(res);
            if (!room_info_updated) {
                if (timeout_id != 0) {
                    Source.remove(timeout_id);
                    timeout_id = 0;
                }
                query_loop.quit();
            }
        });
        query_loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        if (info_handler_id != 0) {
            SignalHandler.disconnect(stream, info_handler_id);
        }
        if (updated_handler_id != 0) {
            SignalHandler.disconnect((!) muc_module, updated_handler_id);
        }
        fail_if(query_timed_out,
            "OpenPGP private-MUC recipient proof must answer the room-info IQ without hanging");
        fail_if(!room_info_updated,
            "OpenPGP private-MUC recipient proof must refresh live room features");
    }

    private static Gee.List<Xmpp.Jid>? query_openpgp_private_muc_snapshot_for_tests(FileManagerHttpSetup setup,
            Xmpp.Jid room_jid, Gee.List<Xmpp.Jid> members, Gee.List<Xmpp.Jid> admins, Gee.List<Xmpp.Jid> owners,
            Gee.List<string>? request_order = null, Gee.List<string>? request_destinations = null,
            bool affiliation_results_without_from = false, Xmpp.Jid? affiliation_result_from = null) {
        Dino.MucManager? muc_manager = setup.stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
        fail_if(muc_manager == null, "OpenPGP private-MUC recipient proof requires MucManager");
        if (muc_manager == null) return null;

        Xmpp.Jid room_bare_jid = room_jid.bare_jid;
        ulong handler_id = 0;
        handler_id = setup.stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            if (outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET) return;
            if (outgoing.get_attribute("to") != room_bare_jid.to_string()) return;

            Xmpp.StanzaNode? info_query = outgoing.get_subnode("query", NS_DISCO_INFO);
            if (info_query != null) {
                if (request_order != null) ((!) request_order).add("room-info");
                if (request_destinations != null) ((!) request_destinations).add(outgoing.get_attribute("to") ?? "");
                setup.stream.emit_iq_result(build_openpgp_room_info_result_for_request(outgoing, room_bare_jid, true));
                return;
            }

            Xmpp.StanzaNode? query = outgoing.get_subnode("query", NS_MUC_ADMIN);
            if (query == null) return;
            Xmpp.StanzaNode? item = ((!) query).get_subnode("item", NS_MUC_ADMIN);
            if (item == null) return;

            string affiliation = ((!) item).get_attribute("affiliation") ?? "";
            if (affiliation == "member") {
                if (request_order != null) ((!) request_order).add("member");
                if (request_destinations != null) ((!) request_destinations).add(outgoing.get_attribute("to") ?? "");
                setup.stream.emit_iq_result(build_openpgp_muc_affiliation_result_for_request(outgoing, room_bare_jid, "member", members,
                    affiliation_results_without_from, affiliation_result_from));
            } else if (affiliation == "admin") {
                if (request_order != null) ((!) request_order).add("admin");
                if (request_destinations != null) ((!) request_destinations).add(outgoing.get_attribute("to") ?? "");
                setup.stream.emit_iq_result(build_openpgp_muc_affiliation_result_for_request(outgoing, room_bare_jid, "admin", admins,
                    affiliation_results_without_from, affiliation_result_from));
            } else if (affiliation == "owner") {
                if (request_order != null) ((!) request_order).add("owner");
                if (request_destinations != null) ((!) request_destinations).add(outgoing.get_attribute("to") ?? "");
                setup.stream.emit_iq_result(build_openpgp_muc_affiliation_result_for_request(outgoing, room_bare_jid, "owner", owners,
                    affiliation_results_without_from, affiliation_result_from));
            }
        });

        Gee.List<Xmpp.Jid>? snapshot = null;
        var query_loop = new MainLoop();
        bool query_timed_out = false;
        uint timeout_id = Timeout.add_seconds(2, () => {
            query_timed_out = true;
            query_loop.quit();
            return Source.REMOVE;
        });
        ((!) muc_manager).query_private_muc_affiliation_snapshot.begin(setup.account, room_jid, (obj, res) => {
            snapshot = ((!) muc_manager).query_private_muc_affiliation_snapshot.end(res);
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            query_loop.quit();
        });
        query_loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        if (handler_id != 0) {
            SignalHandler.disconnect(setup.stream, handler_id);
        }
        fail_if(query_timed_out,
            "OpenPGP private-MUC recipient proof must answer the private-MUC snapshot IQs without hanging");
        return snapshot;
    }

    private static Gee.List<Xmpp.Jid>? query_openpgp_private_muc_snapshot_affiliation_error_for_tests(
            FileManagerHttpSetup setup, Xmpp.Jid room_jid, string error_affiliation, Gee.List<Xmpp.Jid> members) {
        Dino.MucManager? muc_manager = setup.stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
        fail_if(muc_manager == null, "OpenPGP private-MUC affiliation-error proof requires MucManager");
        if (muc_manager == null) return null;

        Xmpp.Jid room_bare_jid = room_jid.bare_jid;
        bool saw_error_affiliation = false;
        ulong handler_id = 0;
        handler_id = setup.stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            if (outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET) return;
            if (outgoing.get_attribute("to") != room_bare_jid.to_string()) return;

            Xmpp.StanzaNode? info_query = outgoing.get_subnode("query", NS_DISCO_INFO);
            if (info_query != null) {
                setup.stream.emit_iq_result(build_openpgp_room_info_result_for_request(outgoing, room_bare_jid, true));
                return;
            }

            Xmpp.StanzaNode? query = outgoing.get_subnode("query", NS_MUC_ADMIN);
            if (query == null) return;
            Xmpp.StanzaNode? item = ((!) query).get_subnode("item", NS_MUC_ADMIN);
            if (item == null) return;

            string affiliation = ((!) item).get_attribute("affiliation") ?? "";
            if (affiliation == error_affiliation) {
                saw_error_affiliation = true;
                setup.stream.emit_iq_result(build_openpgp_iq_error_for_request(outgoing, room_bare_jid));
            } else {
                Gee.List<Xmpp.Jid> result_jids = affiliation == "member"
                    ? members : openpgp_jid_list();
                setup.stream.emit_iq_result(build_openpgp_muc_affiliation_result_for_request(
                    outgoing, room_bare_jid, affiliation, result_jids));
            }
        });

        Gee.List<Xmpp.Jid>? snapshot = null;
        var query_loop = new MainLoop();
        bool query_timed_out = false;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(2, () => {
            query_timed_out = true;
            timeout_id = 0;
            query_loop.quit();
            return Source.REMOVE;
        });
        ((!) muc_manager).query_private_muc_affiliation_snapshot.begin(setup.account, room_jid, (obj, res) => {
            snapshot = ((!) muc_manager).query_private_muc_affiliation_snapshot.end(res);
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            query_loop.quit();
        });
        query_loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        if (handler_id != 0) {
            SignalHandler.disconnect(setup.stream, handler_id);
        }
        fail_if(query_timed_out,
            "OpenPGP private-MUC affiliation-error proof must answer the snapshot IQs without hanging");
        fail_if(!saw_error_affiliation,
            "OpenPGP private-MUC affiliation-error proof must reach the configured error affiliation");
        return snapshot;
    }

    private static bool query_openpgp_room_info_error_for_tests(
            FileManagerHttpSetup setup, Xmpp.Jid room_jid) {
        Xmpp.Xep.Muc.Module? muc_module = setup.stream.get_module<Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        fail_if(muc_module == null,
            "OpenPGP private-MUC recipient proof requires an attached MUC module");
        if (muc_module == null) return false;

        bool saw_room_info_query = false;
        bool saw_affiliation_query = false;
        ulong handler_id = 0;
        handler_id = setup.stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            if (outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET) return;
            if (outgoing.get_attribute("to") != room_jid.to_string()) return;

            Xmpp.StanzaNode? info_query = outgoing.get_subnode("query", NS_DISCO_INFO);
            if (info_query != null) {
                saw_room_info_query = true;
                setup.stream.emit_iq_result(build_openpgp_iq_error_for_request(outgoing, room_jid));
                return;
            }

            Xmpp.StanzaNode? affiliation_query = outgoing.get_subnode("query", NS_MUC_ADMIN);
            if (affiliation_query != null) saw_affiliation_query = true;
        });

        bool refreshed = false;
        var query_loop = new MainLoop();
        bool query_timed_out = false;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(2, () => {
            query_timed_out = true;
            timeout_id = 0;
            query_loop.quit();
            return Source.REMOVE;
        });
        ((!) muc_module).query_room_info.begin(setup.stream, room_jid, (obj, res) => {
            refreshed = ((!) muc_module).query_room_info.end(res);
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            query_loop.quit();
        });
        query_loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        if (handler_id != 0) {
            SignalHandler.disconnect(setup.stream, handler_id);
        }
        fail_if(query_timed_out,
            "OpenPGP private-MUC recipient proof must answer the failed room-info IQ without hanging");
        fail_if(!saw_room_info_query,
            "OpenPGP private-MUC recipient proof must issue a fresh room-info IQ before testing a failed refresh");
        fail_if(saw_affiliation_query,
            "OpenPGP private-MUC recipient proof must not query affiliations after failed live room-info refresh");
        return refreshed;
    }

    private static Gee.List<Xmpp.Jid>? query_openpgp_muc_affiliation_for_tests(TestXmppStream stream,
            Xmpp.Jid room_jid, string affiliation, Xmpp.Jid? first_jid = null, Xmpp.Jid? second_jid = null,
            Xmpp.Jid? third_jid = null) {
        Xmpp.Xep.Muc.Module? muc_module = stream.get_module<Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        fail_if(muc_module == null, "OpenPGP private-MUC recipient proof requires an attached MUC module");
        if (muc_module == null) return null;

        Gee.List<Xmpp.Jid> jids = openpgp_jid_list(first_jid, second_jid, third_jid);

        ulong handler_id = 0;
        handler_id = stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            if (outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET) return;
            if (outgoing.get_attribute("to") != room_jid.to_string()) return;

            Xmpp.StanzaNode? query = outgoing.get_subnode("query", NS_MUC_ADMIN);
            if (query == null) return;
            Xmpp.StanzaNode? item = ((!) query).get_subnode("item", NS_MUC_ADMIN);
            if (item == null || ((!) item).get_attribute("affiliation") != affiliation) return;

            SignalHandler.disconnect(stream, handler_id);
            handler_id = 0;
            stream.emit_iq_result(build_openpgp_muc_affiliation_result_for_request(outgoing, room_jid, affiliation, jids));
        });

        Gee.List<Xmpp.Jid>? queried_jids = null;
        var query_loop = new MainLoop();
        bool query_timed_out = false;
        uint timeout_id = Timeout.add_seconds(2, () => {
            query_timed_out = true;
            query_loop.quit();
            return Source.REMOVE;
        });
        ((!) muc_module).query_affiliation.begin(stream, room_jid, affiliation, (obj, res) => {
            queried_jids = ((!) muc_module).query_affiliation.end(res);
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            query_loop.quit();
        });
        query_loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        if (handler_id != 0) {
            SignalHandler.disconnect(stream, handler_id);
        }
        fail_if(query_timed_out,
            "OpenPGP private-MUC recipient proof must answer the affiliation IQ without hanging");
        return queried_jids;
    }

    private static void emit_openpgp_muc_presence_for_tests(TestXmppStream stream, Xmpp.Jid occupant_jid,
            Xmpp.Jid? real_jid, string affiliation) {
        var item = new Xmpp.StanzaNode.build("item", NS_MUC_USER)
            .put_attribute("affiliation", affiliation)
            .put_attribute("role", "participant");
        if (real_jid != null) item.put_attribute("jid", ((!) real_jid).to_string());
        var presence = new Xmpp.StanzaNode.build("presence")
            .put_attribute("from", occupant_jid.to_string())
            .put_node(new Xmpp.StanzaNode.build("x", NS_MUC_USER).add_self_xmlns()
                .put_node(item));
        stream.emit_presence_stanza(presence);
    }

    private static Gee.List<Xmpp.Jid> openpgp_jid_list(Xmpp.Jid? first_jid = null, Xmpp.Jid? second_jid = null,
            Xmpp.Jid? third_jid = null) {
        var jids = new Gee.ArrayList<Xmpp.Jid>(Xmpp.Jid.equals_bare_func);
        if (first_jid != null) jids.add((!) first_jid);
        if (second_jid != null) jids.add((!) second_jid);
        if (third_jid != null) jids.add((!) third_jid);
        return jids;
    }

    private static void attach_xep0373_manager_for_private_muc_readiness_tests(FileManagerHttpSetup setup,
            Dino.Plugins.OpenPgp.Manager manager) {
        _force_class_init(typeof(Xmpp.Xep.Pubsub.Module));
        _force_class_init(typeof(Xmpp.Xep.OpenPgp.Module));

        if (setup.stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY) == null) {
            setup.stream.add_module(new Xmpp.Xep.Pubsub.Module());
        }
        if (setup.stream.get_module<Xmpp.Xep.OpenPgp.Module>(Xmpp.Xep.OpenPgp.Module.IDENTITY) == null) {
            setup.stream.add_module(new Xmpp.Xep.OpenPgp.Module());
        }
        manager.xep0373_manager = new Dino.Plugins.OpenPgp.Xep0373KeyManager(setup.stream_interactor, setup.openpgp_db);
    }

    private static Xmpp.StanzaNode build_openpgp_room_info_result_for_request(Xmpp.StanzaNode request_iq,
            Xmpp.Jid room_jid, bool private_room) {
        var result_iq = new Xmpp.StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT)
            .put_attribute("from", room_jid.to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);

        var query = new Xmpp.StanzaNode.build("query", NS_DISCO_INFO).add_self_xmlns()
            .put_node(new Xmpp.StanzaNode.build("identity", NS_DISCO_INFO)
                .put_attribute("category", "conference")
                .put_attribute("type", "text")
                .put_attribute("name", "OpenPGP private MUC recipient test"));
        if (private_room) {
            query.put_node(new Xmpp.StanzaNode.build("feature", NS_DISCO_INFO).put_attribute("var", "muc_membersonly"));
            query.put_node(new Xmpp.StanzaNode.build("feature", NS_DISCO_INFO).put_attribute("var", "muc_nonanonymous"));
        } else {
            query.put_node(new Xmpp.StanzaNode.build("feature", NS_DISCO_INFO).put_attribute("var", "muc_open"));
            query.put_node(new Xmpp.StanzaNode.build("feature", NS_DISCO_INFO).put_attribute("var", "muc_public"));
        }
        result_iq.put_node(query);
        return result_iq;
    }

    private static Xmpp.StanzaNode build_openpgp_muc_affiliation_result_for_request(Xmpp.StanzaNode request_iq,
            Xmpp.Jid room_jid, string affiliation, Gee.List<Xmpp.Jid> members, bool omit_from = false,
            Xmpp.Jid? result_from = null) {
        var result_iq = new Xmpp.StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
        if (!omit_from) result_iq.put_attribute("from", (result_from ?? room_jid).to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);

        var query = new Xmpp.StanzaNode.build("query", NS_MUC_ADMIN).add_self_xmlns();
        foreach (Xmpp.Jid member in members) {
            query.put_node(new Xmpp.StanzaNode.build("item", NS_MUC_ADMIN)
                .put_attribute("affiliation", affiliation)
                .put_attribute("jid", member.to_string()));
        }
        result_iq.put_node(query);
        return result_iq;
    }

    private static Xmpp.StanzaNode build_openpgp_iq_error_for_request(Xmpp.StanzaNode request_iq, Xmpp.Jid room_jid) {
        var error_iq = new Xmpp.StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Stanza.TYPE_ERROR)
            .put_attribute("from", room_jid.to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) error_iq.put_attribute("id", (!) id);

        error_iq.put_node(new Xmpp.StanzaNode.build("error")
            .put_attribute("type", "cancel")
            .put_node(new Xmpp.StanzaNode.build("service-unavailable", "urn:ietf:params:xml:ns:xmpp-stanzas")));
        return error_iq;
    }

    private static void assert_jid_list_contains_bare(Gee.List<Xmpp.Jid>? members, Xmpp.Jid expected, string reason) {
        fail_if(members == null, reason);
        if (members == null) return;

        foreach (Xmpp.Jid member in (!) members) {
            if (member.equals_bare(expected)) return;
        }
        fail_if(true, reason);
    }

    private static void assert_jid_list_contains_exact(Gee.List<Xmpp.Jid>? members, Xmpp.Jid expected, string reason) {
        fail_if(members == null, reason);
        if (members == null) return;

        foreach (Xmpp.Jid member in (!) members) {
            if (member.equals(expected)) return;
        }
        fail_if(true, reason);
    }

    private static void assert_jid_list_lacks_bare(Gee.List<Xmpp.Jid>? members, Xmpp.Jid unexpected, string reason) {
        fail_if(members == null, reason);
        if (members == null) return;

        foreach (Xmpp.Jid member in (!) members) {
            fail_if(member.equals_bare(unexpected), reason);
        }
    }

    private static void assert_jid_list_lacks_exact(Gee.List<Xmpp.Jid>? members, Xmpp.Jid unexpected, string reason) {
        fail_if(members == null, reason);
        if (members == null) return;

        foreach (Xmpp.Jid member in (!) members) {
            fail_if(member.equals(unexpected), reason);
        }
    }

    private static void assert_openpgp_key_list_contains(GPGHelper.Key[] keys, string expected_fingerprint, string reason) {
        foreach (GPGHelper.Key key in keys) {
            if (key.fpr == expected_fingerprint) return;
        }
        fail_if(true, reason);
    }

    private static bool read_live_gpg_env(out string signer, out string recipient) {
        signer = "";
        recipient = "";
        bool require_live = Environment.get_variable("DINOX_OPENPGP_TEST_REQUIRE_LIVE") == "1";
        string? signer_env = Environment.get_variable("DINOX_OPENPGP_TEST_SIGNER");
        string? recipient_env = Environment.get_variable("DINOX_OPENPGP_TEST_RECIPIENT");
        string? gnupg_home = Environment.get_variable("GNUPGHOME");
        bool isolated_home = Environment.get_variable("DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME") == "1";

        if (signer_env == null || recipient_env == null || ((!) signer_env).length == 0 || ((!) recipient_env).length == 0) {
            return skip_or_fail(require_live,
                "DINOX_OPENPGP_TEST_SIGNER and DINOX_OPENPGP_TEST_RECIPIENT are not set");
        }
        if (gnupg_home == null || ((!) gnupg_home).length == 0 || !FileUtils.test((!) gnupg_home, FileTest.IS_DIR)) {
            return skip_or_fail(require_live,
                "GNUPGHOME must point to an explicit isolated test keyring for live OpenPGP tests");
        }
        if (!isolated_home) {
            return skip_or_fail(require_live,
                "DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME=1 is required for live OpenPGP tests");
        }

        signer = normalize_openpgp_fingerprint((!) signer_env);
        recipient = normalize_openpgp_fingerprint((!) recipient_env);
        if (!is_full_openpgp_fingerprint(signer) || !is_full_openpgp_fingerprint(recipient)) {
            return skip_or_fail(require_live,
                "DINOX_OPENPGP_TEST_SIGNER and DINOX_OPENPGP_TEST_RECIPIENT must be full 40-hex primary fingerprints");
        }
        if (signer == recipient) {
            return skip_or_fail(require_live,
                "DINOX_OPENPGP_TEST_SIGNER and DINOX_OPENPGP_TEST_RECIPIENT must be distinct primary fingerprints");
        }
        return true;
    }

    private static bool skip_or_fail(bool fail_required, string message) {
        if (fail_required) {
            GLib.Test.message(message);
            GLib.Test.fail();
        } else {
            GLib.Test.skip(message);
        }
        return false;
    }

    private static GPGHelper.Key require_private_key(string fingerprint) throws Error {
        GPGHelper.Key? key = GPGHelper.get_private_key(fingerprint);
        if (key == null) {
            throw new IOError.FAILED("Live OpenPGP signer key is not available in the isolated private keyring");
        }
        string actual_fingerprint = normalize_openpgp_fingerprint(((!) key).fpr);
        if (actual_fingerprint != fingerprint) {
            throw new IOError.FAILED("Live OpenPGP signer did not resolve to the configured full primary fingerprint");
        }
        return (!) key;
    }

    private static GPGHelper.Key require_public_key(string fingerprint) throws Error {
        GPGHelper.Key? key = GPGHelper.get_public_key(fingerprint);
        if (key == null) {
            throw new IOError.FAILED("Live OpenPGP recipient key is not available in the isolated public keyring");
        }
        string actual_fingerprint = normalize_openpgp_fingerprint(((!) key).fpr);
        if (actual_fingerprint != fingerprint) {
            throw new IOError.FAILED("Live OpenPGP recipient did not resolve to the configured full primary fingerprint");
        }
        return (!) key;
    }

    private static void require_xmpp_uid(string fingerprint, string bare_jid) throws Error {
        if (!GPGHelper.key_has_xmpp_uid(fingerprint, bare_jid)) {
            throw new IOError.FAILED("Live OpenPGP XEP-0374 signer key must contain the xmpp:%s user ID".printf(bare_jid));
        }
    }

    private static void require_email_uid(string fingerprint) throws Error {
        if (!GPGHelper.key_has_email_uid(fingerprint)) {
            throw new IOError.FAILED("Live legacy OpenPGP/XEP-0027 signer key must contain an email user ID");
        }
    }

    private static void delete_secret_and_public_key(string fingerprint) throws Error {
        run_gpg_capture({ "--yes", "--delete-secret-and-public-key", fingerprint });
        GPGHelper.invalidate_secret_keys_cache();
    }

    private static bool contains_bytes(uint8[] haystack, uint8[] needle) {
        if (needle.length == 0) return true;
        if (haystack.length < needle.length) return false;

        for (int i = 0; i <= haystack.length - needle.length; i++) {
            bool found = true;
            for (int j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    private static void assert_encrypted_packet_contains_recipient_key(string encrypted_path, string recipient_fingerprint,
            string reason = "OpenPGP encrypted file packet does not contain the configured recipient key") throws Error {
        Gee.HashSet<string> recipient_key_ids = collect_public_key_ids(recipient_fingerprint);
        Gee.HashSet<string> packet_key_ids = collect_encrypted_packet_key_ids(encrypted_path);

        foreach (string recipient_key_id in recipient_key_ids) {
            if (packet_key_ids.contains(recipient_key_id)) return;
        }

        throw new IOError.FAILED(reason);
    }

    private static void assert_encrypted_packet_data_contains_recipient_key(uint8[] encrypted_data, string recipient_fingerprint,
            string reason) throws Error {
        string temp_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-packet-" + Uuid.string_random() + ".pgp");
        try {
            FileUtils.set_data(temp_path, encrypted_data);
            assert_encrypted_packet_contains_recipient_key(temp_path, recipient_fingerprint, reason);
        } finally {
            GPGHelper.secure_delete_file(temp_path);
        }
    }

    private static void assert_encrypted_armor_contains_recipient_key(string encrypted_armor, string recipient_fingerprint,
            string reason) throws Error {
        string temp_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-packet-" + Uuid.string_random() + ".asc");
        try {
            FileUtils.set_contents(temp_path, encrypted_armor);
            assert_encrypted_packet_contains_recipient_key(temp_path, recipient_fingerprint, reason);
        } finally {
            GPGHelper.secure_delete_file(temp_path);
        }
    }

    private static Gee.HashSet<string> collect_public_key_ids(string fingerprint) throws Error {
        string output = run_gpg_capture({ "--with-colons", "--with-fingerprint", "--list-keys", fingerprint });
        var key_ids = new Gee.HashSet<string>();
        foreach (string line in output.split("\n")) {
            string[] parts = line.split(":");
            if ((parts[0] == "pub" || parts[0] == "sub") && parts.length > 4 && parts[4].length > 0) {
                key_ids.add(normalize_openpgp_key_id(parts[4]));
            } else if (parts[0] == "fpr" && parts.length > 9 && parts[9].length >= 16) {
                string fpr = normalize_openpgp_fingerprint(parts[9]);
                key_ids.add(fpr.substring(fpr.length - 16));
            }
        }
        if (key_ids.size == 0) {
            throw new IOError.FAILED("Could not resolve OpenPGP recipient packet key ids");
        }
        return key_ids;
    }

    private static Gee.HashSet<string> collect_encrypted_packet_key_ids(string encrypted_path) throws Error {
        string output = run_gpg_capture({ "--list-packets", "--list-only", encrypted_path });
        var key_ids = new Gee.HashSet<string>();
        foreach (string raw_line in output.split("\n")) {
            string line = raw_line.strip();
            int keyid_pos = line.index_of("keyid ");
            if (keyid_pos < 0) continue;
            string value = line.substring(keyid_pos + "keyid ".length).strip();
            int end = 0;
            while (end < value.length && is_openpgp_hex_char(value[end])) {
                end++;
            }
            if (end > 0) key_ids.add(normalize_openpgp_key_id(value.substring(0, end)));
        }
        if (key_ids.size == 0) {
            throw new IOError.FAILED("Could not parse OpenPGP encrypted packet recipients");
        }
        return key_ids;
    }

    private static string run_gpg_capture(string[] extra_args) throws Error {
        string stdout_str;
        string stderr_str;
        run_gpg_for_current_homedir(extra_args, out stdout_str, out stderr_str);
        return stdout_str + "\n" + stderr_str;
    }

    private static string run_gpg_stdout(string[] extra_args) throws Error {
        string stdout_str;
        string stderr_str;
        run_gpg_for_current_homedir(extra_args, out stdout_str, out stderr_str);
        return stdout_str;
    }

    private static void run_gpg_for_current_homedir(string[] extra_args, out string stdout_str,
            out string stderr_str) throws Error {
        string? homedir = GPGHelper.get_homedir_path();
        if (homedir == null || ((!) homedir).length == 0) {
            throw new IOError.FAILED("Live OpenPGP tests require an explicit GNUPGHOME");
        }

        string[] argv = new string[5 + extra_args.length];
        argv[0] = GPGHelper.get_binary_path();
        argv[1] = "--homedir";
        argv[2] = (!) homedir;
        argv[3] = "--batch";
        argv[4] = "--yes";
        for (int i = 0; i < extra_args.length; i++) {
            argv[5 + i] = extra_args[i];
        }

        int exit_status;
        Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, out stdout_str, out stderr_str, out exit_status);
        if (exit_status != 0) {
            throw new IOError.FAILED("GPG packet inspection failed: %s".printf(stderr_str));
        }
    }

    private static bool is_full_openpgp_fingerprint(string value) {
        if (value.length != 40) return false;
        for (int i = 0; i < value.length; i++) {
            char c = value[i];
            if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
        }
        return true;
    }

    private static string normalize_openpgp_fingerprint(string value) {
        return normalize_openpgp_key_id(value);
    }

    private static string normalize_openpgp_key_id(string value) {
        return value.up().replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "");
    }

    private static bool is_openpgp_hex_char(char c) {
        return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f');
    }

    private class FileManagerHttpSetup : Object {
        public string temp_dir;
        public string core_db_path;
        public string openpgp_db_path;
        public Dino.Database core_db;
        public Dino.Plugins.OpenPgp.Database openpgp_db;
        public Dino.StreamInteractor stream_interactor;
        public Dino.FileManager file_manager;
        public Dino.Plugins.HttpFiles.HttpFileSender sender;
        public Dino.Entities.Account account;
        public Dino.Entities.Conversation conversation;
        public TestXmppStream stream;

        public FileManagerHttpSetup(string temp_dir, string core_db_path, string openpgp_db_path,
                Dino.Database core_db, Dino.Plugins.OpenPgp.Database openpgp_db,
                Dino.StreamInteractor stream_interactor, Dino.FileManager file_manager,
                Dino.Plugins.HttpFiles.HttpFileSender sender, Dino.Entities.Account account,
                Dino.Entities.Conversation conversation, TestXmppStream stream) {
            this.temp_dir = temp_dir;
            this.core_db_path = core_db_path;
            this.openpgp_db_path = openpgp_db_path;
            this.core_db = core_db;
            this.openpgp_db = openpgp_db;
            this.stream_interactor = stream_interactor;
            this.file_manager = file_manager;
            this.sender = sender;
            this.account = account;
            this.conversation = conversation;
            this.stream = stream;
        }

        public void cleanup() {
            sender.shutdown();
            file_manager.dispose();
            openpgp_db.close();
            core_db.close();
            FileUtils.remove(core_db_path + "-shm");
            FileUtils.remove(core_db_path + "-wal");
            FileUtils.remove(openpgp_db_path + "-shm");
            FileUtils.remove(openpgp_db_path + "-wal");
            FileUtils.remove(openpgp_db_path);
            FileUtils.remove(core_db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private class SlotRequestCapture : Object {
        public ulong handler_id = 0;
        public bool matched = false;
        public int64 requested_size = -1;
    }

    private class Xep0373PubsubResponder : Object {
        private TestXmppStream stream;
        private string own_fingerprint;
        private string own_key_data_base64;
        private string contact_fingerprint;
        private string contact_key_data_base64;
        private ulong handler_id = 0;

        public bool own_key_data_published = false;
        public bool own_metadata_published = false;
        public bool own_publish_options_open_persistent = false;
        public int metadata_request_count = 0;
        public int key_data_request_count = 0;

        public Xep0373PubsubResponder(TestXmppStream stream, string own_fingerprint, string own_key_data_base64,
                string contact_fingerprint, string contact_key_data_base64) {
            this.stream = stream;
            this.own_fingerprint = normalize_openpgp_fingerprint(own_fingerprint);
            this.own_key_data_base64 = own_key_data_base64;
            this.contact_fingerprint = normalize_openpgp_fingerprint(contact_fingerprint);
            this.contact_key_data_base64 = contact_key_data_base64;
            this.handler_id = stream.wrote_node.connect(on_written_node);
        }

        public void detach() {
            if (handler_id != 0) {
                SignalHandler.disconnect(stream, handler_id);
                handler_id = 0;
            }
        }

        private void on_written_node(Xmpp.StanzaNode outgoing) {
            if (outgoing.name != "iq") return;
            Xmpp.StanzaNode? pubsub = outgoing.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
            if (pubsub == null) return;

            string type = outgoing.get_attribute("type") ?? "";
            bool handled = false;
            if (type == Xmpp.Iq.Stanza.TYPE_SET) {
                handled = handle_publish(outgoing, (!) pubsub);
            } else if (type == Xmpp.Iq.Stanza.TYPE_GET) {
                handled = handle_request(outgoing, (!) pubsub);
            }
            if (!handled) {
                fail_if(true, "Unexpected XEP-0373 PubSub IQ in file-send readiness test: " + outgoing.to_string());
                stream.emit_iq_result(build_iq_result(outgoing));
            }
        }

        private bool handle_publish(Xmpp.StanzaNode outgoing, Xmpp.StanzaNode pubsub) {
            Xmpp.StanzaNode? publish = pubsub.get_subnode("publish", Xmpp.Xep.Pubsub.NS_URI);
            if (publish == null) return false;

            string node = ((!) publish).get_attribute("node") ?? "";
            Xmpp.StanzaNode? item = ((!) publish).get_subnode("item", Xmpp.Xep.Pubsub.NS_URI);
            if (item == null) return false;

            string own_key_node = Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS + ":" + own_fingerprint;
            if (node == own_key_node) {
                string item_id = ((!) item).get_attribute("id") ?? "";
                fail_if(item_id.length == 0,
                    "XEP-0373 key-data publish must use a stable item id");
                Xmpp.StanzaNode? pubkey = ((!) item).get_subnode("pubkey", Xmpp.Xep.OpenPgp.NS_URI);
                fail_if(pubkey == null,
                    "XEP-0373 key-data publish must carry a pubkey payload");
                Xmpp.StanzaNode? data = pubkey != null ? ((!) pubkey).get_subnode("data", Xmpp.Xep.OpenPgp.NS_URI) : null;
                fail_if(data == null || ((!) data).get_string_content() != own_key_data_base64,
                    "XEP-0373 key-data publish must carry raw Base64 OpenPGP key material");
                own_key_data_published = true;
                own_publish_options_open_persistent = publish_options_are_open_persistent_single_item(pubsub);
            } else if (node == Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS) {
                string item_id = ((!) item).get_attribute("id") ?? "";
                fail_if_not_eq_str("current", item_id,
                    "XEP-0373 metadata publish must use the fixed current item id");
                Xmpp.StanzaNode? list = ((!) item).get_subnode("public-keys-list", Xmpp.Xep.OpenPgp.NS_URI);
                fail_if(list == null,
                    "XEP-0373 metadata publish must carry a public-keys-list payload");
                Xmpp.StanzaNode? metadata = list != null ? ((!) list).get_subnode("pubkey-metadata", Xmpp.Xep.OpenPgp.NS_URI) : null;
                fail_if(metadata == null || normalize_openpgp_fingerprint(((!) metadata).get_attribute("v4-fingerprint") ?? "") != own_fingerprint,
                    "XEP-0373 metadata publish must advertise the selected account fingerprint");
                own_metadata_published = true;
                own_publish_options_open_persistent = own_publish_options_open_persistent &&
                    publish_options_are_open_persistent_single_item(pubsub);
            }

            stream.emit_iq_result(build_iq_result(outgoing));
            return node == own_key_node || node == Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS;
        }

        private bool handle_request(Xmpp.StanzaNode outgoing, Xmpp.StanzaNode pubsub) {
            Xmpp.StanzaNode? items = pubsub.get_subnode("items", Xmpp.Xep.Pubsub.NS_URI);
            if (items == null) return false;

            string node = ((!) items).get_attribute("node") ?? "";
            if (node == Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS) {
                Xmpp.StanzaNode? requested_item = ((!) items).get_subnode("item", Xmpp.Xep.Pubsub.NS_URI);
                // Own publication merges every metadata item. Contact lazy
                // fetching still requests the conventional current item first.
                bool own_metadata_request = requested_item == null;
                if (!own_metadata_request) {
                    metadata_request_count++;
                    fail_if(((!) requested_item).get_attribute("id") != "current",
                        "XEP-0373 contact metadata fetch must request the current metadata item first");
                }

                var result = build_iq_result(outgoing);
                var result_pubsub = new Xmpp.StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI).add_self_xmlns();
                var result_items = new Xmpp.StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                    .put_attribute("node", Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS);
                if (!own_metadata_request || own_metadata_published) {
                    var item = new Xmpp.StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI).put_attribute("id", "current");
                    var list = new Xmpp.StanzaNode.build("public-keys-list", Xmpp.Xep.OpenPgp.NS_URI).add_self_xmlns()
                        .put_node(new Xmpp.StanzaNode.build("pubkey-metadata", Xmpp.Xep.OpenPgp.NS_URI)
                            .put_attribute("v4-fingerprint", own_metadata_request ? own_fingerprint : contact_fingerprint)
                            .put_attribute("date", new DateTime.now_utc().format_iso8601()));
                    item.put_node(list);
                    result_items.put_node(item);
                }
                result_pubsub.put_node(result_items);
                result.put_node(result_pubsub);
                stream.emit_iq_result(result);
                return true;
            } else if (node == Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS + ":" + contact_fingerprint) {
                key_data_request_count++;
                fail_if(((!) items).get_attribute("max_items") != "1",
                    "XEP-0373 key-data fetch must request only the newest key-data item");

                var result = build_iq_result(outgoing);
                var result_pubsub = new Xmpp.StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI).add_self_xmlns();
                var result_items = new Xmpp.StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                    .put_attribute("node", node);
                var item = new Xmpp.StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI).put_attribute("id", "current");
                var pubkey = new Xmpp.StanzaNode.build("pubkey", Xmpp.Xep.OpenPgp.NS_URI).add_self_xmlns()
                    .put_node(new Xmpp.StanzaNode.build("data", Xmpp.Xep.OpenPgp.NS_URI)
                        .put_node(new Xmpp.StanzaNode.text(contact_key_data_base64)));
                item.put_node(pubkey);
                result_items.put_node(item);
                result_pubsub.put_node(result_items);
                result.put_node(result_pubsub);
                stream.emit_iq_result(result);
                return true;
            }
            return false;
        }

        private static Xmpp.StanzaNode build_iq_result(Xmpp.StanzaNode request) {
            var result = new Xmpp.StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
            string? id = request.get_attribute("id");
            if (id != null) result.put_attribute("id", (!) id);
            string? from = request.get_attribute("to");
            if (from != null) result.put_attribute("from", (!) from);
            string? to = request.get_attribute("from");
            if (to != null) result.put_attribute("to", (!) to);
            return result;
        }

        private static bool publish_options_are_open_persistent_single_item(Xmpp.StanzaNode pubsub) {
            return publish_options_contains(pubsub, "pubsub#access_model", Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN) &&
                publish_options_contains(pubsub, "pubsub#persist_items", "true") &&
                publish_options_contains(pubsub, "pubsub#max_items", "1");
        }

        private static bool publish_options_contains(Xmpp.StanzaNode pubsub, string var_name, string expected_value) {
            Xmpp.StanzaNode? options = pubsub.get_subnode("publish-options", Xmpp.Xep.Pubsub.NS_URI);
            if (options == null) return false;

            Xmpp.StanzaNode? form = ((!) options).get_subnode("x", "jabber:x:data");
            if (form == null) form = ((!) options).get_subnode("x");
            if (form == null) return false;

            Gee.List<Xmpp.StanzaNode> fields = ((!) form).get_subnodes("field", "jabber:x:data");
            if (fields.size == 0) fields = ((!) form).get_subnodes("field");
            foreach (Xmpp.StanzaNode field in fields) {
                if ((field.get_attribute("var") ?? "") != var_name) continue;
                Xmpp.StanzaNode? value = field.get_subnode("value", "jabber:x:data");
                if (value == null) value = field.get_subnode("value");
                if (value != null && ((!) value).get_string_content() == expected_value) return true;
            }
            return false;
        }
    }

    private class HttpsUploadCapture : Object {
        public bool handled = false;
        public string method = "";
        public string? content_type = null;
        public string? authorization = null;
        public int64 content_length = -1;
        public int written_count_at_upload = -1;
        public uint8[] body = new uint8[0];
        public HttpsUploadHook? on_upload = null;
    }

    private class BlockedBodyUploadCapture : Object {
        private DinoTest.Mutex mutex = DinoTest.Mutex();

        public bool request_started = false;
        public bool headers_seen = false;
        public bool request_read = false;
        public bool handler_called = false;
        public string method = "";
        public string? content_type = null;
        public string? authorization = null;
        public int64 content_length = -1;
        public int written_count_at_headers = -1;

        public void mark_request_started() {
            mutex.lock();
            request_started = true;
            mutex.unlock();
        }

        public void mark_headers_seen(Soup.ServerMessage msg, TestXmppStream stream) {
            mutex.lock();
            headers_seen = true;
            method = msg.get_method();
            content_type = msg.get_request_headers().get_one("Content-Type");
            authorization = msg.get_request_headers().get_one("Authorization");
            content_length = msg.get_request_headers().get_content_length();
            written_count_at_headers = stream.written_nodes.size;
            mutex.unlock();
        }

        public void mark_request_read() {
            mutex.lock();
            request_read = true;
            mutex.unlock();
        }

        public void mark_handler_called() {
            mutex.lock();
            handler_called = true;
            mutex.unlock();
        }

        public bool headers_observed() {
            mutex.lock();
            bool result = headers_seen;
            mutex.unlock();
            return result;
        }
    }

    private class BlockedBodyUploadInputStream : DinoNative.InputStream {
        private uint8[] first_chunk;
        private Cancellable transfer_cancellable;
        private BlockedBodyUploadCapture capture;
        private int first_chunk_offset = 0;
        private bool cancel_thread_started = false;

        public bool first_chunk_seen = false;
        public bool blocking_read_seen = false;
        public bool blocking_read_saw_cancellable = false;
        public bool blocking_read_missing_cancellable = false;
        public bool cancelled_after_headers_seen = false;
        public bool cancel_seen = false;
        public bool closed = false;

        public BlockedBodyUploadInputStream(uint8[] first_chunk, Cancellable transfer_cancellable,
                BlockedBodyUploadCapture capture) {
            this.transfer_cancellable = transfer_cancellable;
            this.capture = capture;
            this.first_chunk = new uint8[first_chunk.length];
            for (int i = 0; i < first_chunk.length; i++) {
                this.first_chunk[i] = first_chunk[i];
            }
        }

        public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (buffer.length == 0) return 0;

            if (first_chunk_offset < first_chunk.length) {
                first_chunk_seen = true;
                int to_copy = int.min(buffer.length, first_chunk.length - first_chunk_offset);
                for (int i = 0; i < to_copy; i++) {
                    ((uint8*) buffer)[i] = first_chunk[first_chunk_offset + i];
                }
                first_chunk_offset += to_copy;
                return to_copy;
            }

            blocking_read_seen = true;
            if (cancellable == null) {
                blocking_read_missing_cancellable = true;
                throw new IOError.FAILED("OpenPGP blocked upload stream read did not receive cancellable");
            }

            blocking_read_saw_cancellable = true;
            if (!cancel_thread_started) {
                cancel_thread_started = true;
                new Thread<void*>("openpgp-http-body-cancel", () => {
                    int64 header_deadline = get_monotonic_time() + 1000 * 1000;
                    while (!capture.headers_observed() && get_monotonic_time() < header_deadline) {
                        Thread.usleep(10 * 1000);
                    }
                    cancelled_after_headers_seen = capture.headers_observed();
                    transfer_cancellable.cancel();
                    return null;
                });
            }

            int64 deadline = get_monotonic_time() + 1000 * 1000;
            while (!cancellable.is_cancelled() && get_monotonic_time() < deadline) {
                Thread.usleep(10 * 1000);
            }
            if (!cancellable.is_cancelled()) {
                throw new IOError.FAILED("OpenPGP blocked upload stream read did not receive the transfer cancellable");
            }

            cancel_seen = true;
            throw new IOError.CANCELLED("transfer cancelled while OpenPGP upload request body was blocked");
        }

        public override bool close(Cancellable? cancellable = null) throws IOError {
            closed = true;
            return true;
        }
    }

    private class HkpKeyserverCapture : Object {
        public int request_count = 0;
        public string? last_method = null;
        public string? last_path = null;
    }

    private class TestXmppStream : Xmpp.XmppStream {
        public signal void wrote_node(Xmpp.StanzaNode node);

        public Xmpp.StanzaNode? last_written { get; private set; default = null; }
        public Gee.ArrayList<Xmpp.StanzaNode> written_nodes = new Gee.ArrayList<Xmpp.StanzaNode>();

        public TestXmppStream(Xmpp.Jid remote_name) {
            base(remote_name);
        }

        public override async void connect() throws IOError {
        }

        public override async void disconnect() throws IOError {
        }

        public override async Xmpp.StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("test stream has no reader");
        }

        public override async void write_async(Xmpp.StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            last_written = node;
            written_nodes.add(node);
            wrote_node(node);
        }

        public override async void setup() throws IOError {
        }

        public void emit_iq_result(Xmpp.StanzaNode node) {
            received_iq_stanza(this, node);
        }

        public void emit_presence_stanza(Xmpp.StanzaNode node) {
            received_presence_stanza(this, node);
        }
    }
}

}
