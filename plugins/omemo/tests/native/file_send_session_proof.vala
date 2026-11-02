using Dino.Entities;
using Dino.Plugins.HttpFiles;
using Gee;
using Omemo;
using Qlite;
using Xmpp;

[CCode (cname = "g_type_class_ref", cheader_filename = "glib-object.h")]
extern unowned void* _force_class_init(GLib.Type type);

namespace Omemo.Test {

[CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
private extern void set_server_message_response(Soup.ServerMessage msg, string? content_type, Soup.MemoryUse resp_use, string response_body, size_t response_length);

private void set_server_string_response(Soup.ServerMessage msg, string content_type, string response_body) {
    set_server_message_response(msg, content_type, Soup.MemoryUse.COPY, response_body, response_body.length);
}

class FileSendSessionProofTest : Gee.TestCase {
    private const string NS_HTTP_UPLOAD_0 = "urn:xmpp:http:upload:0";
    private const string NS_OMEMO_LEGACY = "eu.siacs.conversations.axolotl";
    private const string NS_OMEMO_V2 = "urn:xmpp:omemo:2";
    private const string NS_DISCO_INFO = "http://jabber.org/protocol/disco#info";
    private const string NS_PRIVATE_XML_STORAGE = "jabber:iq:private";
    private const string NS_BOOKMARKS = "storage:bookmarks";
    private const string NS_PUBSUB_OWNER = "http://jabber.org/protocol/pubsub#owner";
    private const string NS_MUC_ADMIN = "http://jabber.org/protocol/muc#admin";
    private const string NS_MUC_USER = "http://jabber.org/protocol/muc#user";
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

    public FileSendSessionProofTest() {
        base("FileSendSessionProof");
        add_test("OMEMO_feed_group_retry_keeps_room_and_stops_empty_list_loop", test_feed_group_retry);
        add_test("OMEMO_file_http_send_uses_real_legacy_session_body_only", test_file_http_send_uses_real_legacy_session_body_only);
        add_test("OMEMO2_file_http_send_uses_sce_only_for_v2_only_devices", test_file_http_send_uses_sce_only_for_v2_only_devices);
        add_test("OMEMO2_file_http_send_falls_back_to_legacy_when_recipient_has_v1_device", test_file_http_send_falls_back_to_legacy_when_recipient_has_v1_device);
        add_test("OMEMO_public_file_manager_http_send_uses_real_legacy_session_body_only", test_public_file_manager_http_send_uses_real_legacy_session_body_only);
        add_test("OMEMO_public_file_manager_http_send_cancel_after_put_blocks_body_announcement", test_public_file_manager_http_send_cancel_after_put_blocks_body_announcement);
        add_test("OMEMO_public_file_manager_http_send_cancel_while_request_body_stream_blocks", test_public_file_manager_http_send_cancel_while_request_body_stream_blocks);
        add_test("OMEMO2_public_file_manager_http_send_uses_real_sce_session_body_only", test_public_file_manager_http_send_uses_real_sce_session_body_only);
        add_test("OMEMO2_public_file_manager_http_send_cancel_after_put_blocks_sce_body_announcement", test_public_file_manager_http_send_cancel_after_put_blocks_sce_body_announcement);
        add_test("OMEMO2_public_file_manager_http_send_cancel_while_request_body_stream_blocks", test_public_file_manager_http_send_cancel_while_request_body_stream_blocks_omemo2);
        add_test("OMEMO2_public_file_manager_http_send_falls_back_to_legacy_for_mixed_devices", test_public_file_manager_http_send_falls_back_to_legacy_for_mixed_devices);
        add_test("OMEMO_private_muc_file_manager_http_send_without_member_list_fails_before_upload", test_private_muc_file_manager_http_send_without_member_list_fails_before_upload);
        add_test("OMEMO_private_muc_http_sender_with_incomplete_snapshot_fails_before_upload", test_private_muc_http_sender_with_incomplete_snapshot_fails_before_upload);
        add_test("OMEMO_private_muc_file_manager_http_send_with_forbidden_admin_owner_snapshot_fails_before_upload", test_private_muc_file_manager_http_send_with_forbidden_admin_owner_snapshot_fails_before_upload);
        add_test("OMEMO_private_muc_file_manager_http_send_with_self_only_snapshot_fails_before_upload", test_private_muc_file_manager_http_send_with_self_only_snapshot_fails_before_upload);
        add_test("OMEMO_private_muc_file_manager_http_send_with_known_members_uses_real_legacy_session_body_only", test_private_muc_file_manager_http_send_with_known_members_uses_real_legacy_session_body_only);
        add_test("OMEMO2_private_muc_file_manager_http_send_with_known_members_uses_real_sce_session_body_only", test_private_muc_file_manager_http_send_with_known_members_uses_real_sce_session_body_only);
        add_test("OMEMO_private_muc_readiness_lifecycle_boundaries", test_private_muc_readiness_lifecycle_boundaries);
        add_test("OMEMO_private_muc_readiness_blocks_input_until_ready", test_private_muc_readiness_blocks_input_until_ready);
        add_test("OMEMO_private_muc_readiness_rejects_changed_member_snapshot", test_private_muc_readiness_rejects_changed_member_snapshot);
        add_test("OMEMO_private_muc_member_bundle_denial_fails_only_current_account_send", () => test_private_muc_bundle_denial_scope(0, false));
        add_test("OMEMO_private_muc_member_bundle_denial_ignores_incomplete_snapshot", () => test_private_muc_bundle_denial_scope(1, false));
        add_test("OMEMO_private_muc_member_bundle_denial_ignores_public_room", () => test_private_muc_bundle_denial_scope(2, false));
        add_test("OMEMO_private_muc_own_bundle_denial_fails_only_current_account_send", () => test_private_muc_bundle_denial_scope(0, true));
        add_test("OMEMO_private_muc_own_bundle_denial_ignores_incomplete_snapshot", () => test_private_muc_bundle_denial_scope(1, true));
        add_test("OMEMO_private_muc_own_bundle_denial_ignores_public_room", () => test_private_muc_bundle_denial_scope(2, true));
        add_test("OMEMO_private_muc_cold_member_bundle_retries_same_group_message", test_private_muc_cold_member_bundle_retries_same_group_message);
    }

    private void test_private_muc_cold_member_bundle_retries_same_group_message() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-omemo-private-muc-cold-member-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");
        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        Dino.Plugins.Omemo.Manager? omemo_manager = null;
        Dino.Plugins.Omemo.StreamModule? attached_module = null;
        TestXmppStream? attached_stream = null;
        Account? sender_account = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("cold private MUC proof requires native OMEMO");
            }
            Context context = Dino.Plugins.Omemo.Plugin.get_context();
            dino_db = new Dino.Database(dino_db_path, "omemo-private-muc-cold-member-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(interactor, (!) dino_db);
            var account = new Account(new Jid("alice@example.test"), "test-only");
            sender_account = account;
            account.persist((!) dino_db);
            var bob = new Account(new Jid("bob@example.test"), "test-only");
            bob.persist((!) dino_db);
            var carol = new Account(new Jid("carol@example.test"), "test-only");
            carol.persist((!) dino_db);
            var room = new Jid("private-room@conference.example.test");
            mark_room_private_in_entity_info((!) dino_db, account, room);
            var persisted = new Conversation(room, account, Conversation.Type.GROUPCHAT) {
                encryption = Encryption.OMEMO,
                send_typing = Conversation.Setting.OFF,
                send_marker = Conversation.Setting.OFF
            };
            persisted.persist((!) dino_db);
            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            Store carol_store = setup_test_store_context(context);
            alice_store.identity_key_store.local_registration_id = 101;
            bob_store.identity_key_store.local_registration_id = 202;
            carol_store.identity_key_store.local_registration_id = 303;
            int alice_identity = install_identity((!) omemo_db, account, alice_store);
            int bob_identity = install_identity((!) omemo_db, bob, bob_store);
            int carol_identity = install_identity((!) omemo_db, carol, carol_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity, account.bare_jid, alice_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity, bob.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity, carol.bare_jid, carol_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity, account.bare_jid, alice_store);
            add_trusted_omemo1_device((!) omemo_db, carol_identity, account.bare_jid, alice_store);
            StanzaNode carol_bundle = make_native_legacy_bundle_for_tests(context,
                carol_store, 63001, 64001);
            var trust = new Dino.Plugins.Omemo.TrustManager(interactor, (!) omemo_db);
            var encryptors = new HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor>(
                Account.hash_func, Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust, alice_store);
            var manager = Dino.Plugins.Omemo.Manager.start(interactor, (!) omemo_db, trust, encryptors);
            omemo_manager = manager;
            manager.auto_publish_own_device_lists = false;
            var module = new Dino.Plugins.Omemo.StreamModule(alice_store);
            module.auto_publish_own_device_list = false;
            ulong initialize_handler = interactor.module_manager.initialize_account_modules.connect(
                (owner, modules) => { if (owner.equals(account)) modules.add(module); });
            interactor.module_manager.initialize(account);
            SignalHandler.disconnect(interactor.module_manager, initialize_handler);
            interactor.account_added(account);
            // Normal account initialization installed persistent native stores.
            // Only Bob is warm; Carol's first session must come from the IQ.
            prepare_pre_key_session(context, alice_store, bob.bare_jid, bob_store, 63002, 64002);
            TestXmppStream stream = create_connected_http_omemo_upload_stream(interactor,
                account, alice_store, false, module);
            attached_stream = stream;
            module.attach(stream);
            attached_module = module;
            attach_private_muc_modules_for_tests(interactor, account, stream, room, "alice");
            Gee.List<Jid>? snapshot = query_private_muc_snapshot_for_tests(interactor,
                account, stream, room, member_list(account.bare_jid, bob.bare_jid, carol.bare_jid),
                member_list(), member_list());
            assert_member_list_contains_bare(snapshot, carol.bare_jid,
                "the cold recipient must belong to the complete current private-room snapshot");
            var conversations = interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            Conversation? conversation = conversations.get_conversation(room, account, Conversation.Type.GROUPCHAT);
            if (conversation == null) throw new IOError.FAILED("cold MUC proof requires the real group conversation");
            fail_if(module.has_legacy_session_for_send(carol.bare_jid, 303),
                "Carol must not have a sender session before the first group send");
            stream.hold_legacy_bundle_for = carol.bare_jid;
            string body = "The first private group message must reach Bob and Carol.";
            var message = new Message(body) {
                account = account, counterpart = room, ourpart = account.full_jid,
                stanza_id = Uuid.string_random(), direction = Message.DIRECTION_SENT,
                encryption = Encryption.OMEMO, type_ = Message.Type.GROUPCHAT,
                marked = Message.Marked.UNSENT
            };
            var processor = interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            processor.send_xmpp_message(message, (!) conversation);
            drain_pending_events();
            fail_if(message.marked != Message.Marked.UNSENT,
                "a warm Bob session must not send a group packet before Carol's bundle arrives");
            fail_if(find_legacy_omemo_message(stream) != null,
                "no partial group message may be written while Carol's session is unknown");
            StanzaNode? request = stream.take_held_legacy_bundle_request();
            if (request == null) throw new IOError.FAILED("the real send hook did not fetch Carol's missing bundle");
            fail_if_not_eq_int(stream.legacy_bundle_request_count, 1,
                "one cold member must produce exactly one bundle IQ");
            fail_if_not_eq_str(((!) request).get_attribute("to"), carol.bare_jid.to_string());
            StanzaNode? pubsub = ((!) request).get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
            StanzaNode? request_items = pubsub != null
                ? ((!) pubsub).get_subnode("items", Xmpp.Xep.Pubsub.NS_URI) : null;
            if (request_items == null) throw new IOError.FAILED("missing native bundle IQ items");
            fail_if_not_eq_str(((!) request_items).get_attribute("node"),
                NS_OMEMO_LEGACY + ".bundles:303");
            foreach (StanzaNode written in stream.written_nodes) {
                fail_if(written.name == "message",
                    "the cold attempt must not write an encrypted or plaintext fallback packet");
            }
            var result = build_empty_iq_result_for_request((!) request);
            result.put_node(new StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                    .put_attribute("node", NS_OMEMO_LEGACY + ".bundles:303")
                    .put_node(new StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI)
                        .put_attribute("id", "current").put_node(carol_bundle))));
            stream.emit_iq_result(result);
            drain_pending_events();
            fail_if_not(module.has_legacy_session_for_send(carol.bare_jid, 303),
                "the authenticated native bundle callback must create Carol's session");
            StanzaNode? wire = find_legacy_omemo_message(stream);
            if (wire == null) throw new IOError.FAILED("bundle completion did not retry the queued group message");
            int written_messages = 0;
            foreach (StanzaNode written in stream.written_nodes) {
                if (written.name == "message") written_messages++;
            }
            fail_if_not_eq_int(written_messages, 1,
                "bundle completion must write exactly one group message without a manual second send");
            fail_if_not_eq_str(((!) wire).get_attribute("id"), message.stanza_id,
                "the automatically retried packet must retain the original message ID");
            fail_if_not_eq_str(((!) wire).get_attribute("to"), room.to_string());
            fail_if_not_eq_str(((!) wire).get_attribute("type"), MessageStanza.TYPE_GROUPCHAT);
            StanzaNode? encrypted = ((!) wire).get_subnode("encrypted", NS_OMEMO_LEGACY);
            if (encrypted == null) throw new IOError.FAILED("retried MUC packet lacks an encrypted envelope");
            assert_omemo_key_recipient((!) encrypted, 202, "Bob must receive the first group message's key");
            assert_omemo_key_recipient((!) encrypted, 303, "Carol must receive the first group message's key");
            fail_if(omemo1_payload_has_device((!) encrypted, 101),
                "the current sender must remain excluded from group key wrapping");
            var bob_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(bob, interactor, trust, (!) omemo_db, bob_store);
            var carol_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(carol, interactor, trust, (!) omemo_db, carol_store);
            fail_if_not_eq_str(decrypt_legacy_omemo_payload(bob_decryptor, (!) encrypted, account.bare_jid), body);
            fail_if_not_eq_str(decrypt_legacy_omemo_payload(carol_decryptor, (!) encrypted, account.bare_jid), body,
                "Carol must decrypt the first packet without sending a message herself");
        } catch (Error error) {
            fail_if_reached("cold private MUC send pipeline proof failed: " + error.message);
        } finally {
            if (omemo_manager != null && sender_account != null) {
                ((!) omemo_manager).forget_pending_messages_for_account((!) sender_account);
            }
            if (attached_module != null && attached_stream != null) {
                ((!) attached_module).detach((!) attached_stream);
            }
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

    private static StanzaNode make_native_legacy_bundle_for_tests(Context context,
            Store store, int prekey_id, int signed_id) throws Error {
        PreKeyRecord prekey;
        throw_by_code(PreKeyRecord.create(out prekey, prekey_id, context.generate_key_pair()));
        store.store_pre_key(prekey);
        SignedPreKeyRecord signed_key = context.generate_signed_pre_key(store.identity_key_pair, signed_id);
        store.store_signed_pre_key(signed_key);
        return new StanzaNode.build("bundle", NS_OMEMO_LEGACY)
            .put_node(new StanzaNode.build("identityKey", NS_OMEMO_LEGACY)
                .put_node(new StanzaNode.text(Base64.encode(store.identity_key_pair.public.serialize()))))
            .put_node(new StanzaNode.build("signedPreKeyPublic", NS_OMEMO_LEGACY)
                .put_attribute("signedPreKeyId", signed_id.to_string())
                .put_node(new StanzaNode.text(Base64.encode(signed_key.key_pair.public.serialize()))))
            .put_node(new StanzaNode.build("signedPreKeySignature", NS_OMEMO_LEGACY)
                .put_node(new StanzaNode.text(Base64.encode(signed_key.signature))))
            .put_node(new StanzaNode.build("prekeys", NS_OMEMO_LEGACY)
                .put_node(new StanzaNode.build("preKeyPublic", NS_OMEMO_LEGACY)
                    .put_attribute("preKeyId", prekey_id.to_string())
                    .put_node(new StanzaNode.text(Base64.encode(prekey.key_pair.public.serialize())))));
    }

    private void test_feed_group_retry() {
        string directory = "";
        Dino.Database? app_db = null;
        Dino.Plugins.Omemo.Database? db = null;
        Dino.Feeds.Service? feeds = null;
        Dino.MucManager? muc = null;
        TestXmppStream? stream = null;
        Dino.Plugins.Omemo.StreamModule? module = null;
        try {
            directory = DirUtils.make_tmp("dinox-feed-omemo-XXXXXX");
            app_db = new Dino.Database(Path.build_filename(directory, "app.db"), "test-only");
            db = new Dino.Plugins.Omemo.Database(Path.build_filename(directory, "omemo.db"));
            Context context = Dino.Plugins.Omemo.Plugin.get_context();
            var interactor = new Dino.StreamInteractor.for_tests((!) app_db);
            start_public_file_send_modules(interactor, (!) app_db);
            interactor.add_module(new Dino.ContentItemStore.for_tests(interactor, (!) app_db));
            var account = new Account(new Jid("alice@example.test"), "test-only") { enabled = true };
            account.persist((!) app_db);
            var room = new Jid("test@conference.example.test");
            var bob = new Jid("bob@example.test");
            var carol = new Jid("carol@example.test");
            mark_room_private_in_entity_info((!) app_db, account, room);
            // Persist the ambiguous direct record first: an untyped retry
            // lookup used to select it instead of the pending group message.
            var direct = new Conversation(room, account, Conversation.Type.CHAT);
            direct.persist((!) app_db);
            var group = new Conversation(room, account, Conversation.Type.GROUPCHAT) {
                active = true, encryption = Encryption.OMEMO,
                send_typing = Conversation.Setting.OFF
            };
            group.persist((!) app_db);
            Store own_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            Store carol_store = setup_test_store_context(context);
            own_store.identity_key_store.local_registration_id = 101;
            bob_store.identity_key_store.local_registration_id = 202;
            carol_store.identity_key_store.local_registration_id = 303;
            int identity = install_identity((!) db, account, own_store);
            add_trusted_omemo1_device((!) db, identity, account.bare_jid, own_store);
            add_trusted_omemo1_device((!) db, identity, bob, bob_store);
            prepare_pre_key_session(context, own_store, bob, bob_store, 61001, 62001);
            var trust = new Dino.Plugins.Omemo.TrustManager(interactor, (!) db);
            var encryptors = new HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor>(Account.hash_func, Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust, own_store);
            var manager = Dino.Plugins.Omemo.Manager.create_for_tests(interactor, (!) db, trust, encryptors);
            interactor.module_manager.initialize(account);
            interactor.account_added(account);
            stream = create_connected_http_omemo_upload_stream(interactor, account, own_store);
            stream.negotiation_complete = true;
            module = stream.get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY);
            module.auto_publish_own_device_list = false;
            module.attach(stream);
            module.device_list_loaded.connect((jid, devices) => manager.device_list_loaded_for_tests(account, jid, devices));
            stream.hold_legacy_devicelist_for = carol;
            attach_private_muc_modules_for_tests(interactor, account, stream, room, "alice");
            query_private_muc_snapshot_for_tests(interactor, account, stream, room,
                member_list(account.bare_jid, bob, carol), member_list(), member_list());
            muc = interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            var processor = interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            Message? pending = null;
            int attempts = 0;
            processor.pre_message_send.connect((message, stanza, conversation) => {
                pending = message;
                attempts++;
                fail_if(conversation.type_ != Conversation.Type.GROUPCHAT ||
                    stanza.type_ != MessageStanza.TYPE_GROUPCHAT, "A group retry changed into a direct send");
                manager.pre_message_send_for_tests(message, stanza, conversation);
            });
            Dino.Feeds.Service.start(interactor, (!) app_db);
            feeds = interactor.get_module<Dino.Feeds.Service>(Dino.Feeds.Service.IDENTITY);
            stream.written_nodes.clear();
            GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING, "*recipient carol@example.test not known*");
            feeds.send(group, "Feed: Grüße und Привет");
            GLib.Test.assert_expected_messages();
            drain_pending_events();
            fail_if(pending == null || pending.marked != Message.Marked.UNSENT);
            var own_list = new ArrayList<int32>(); own_list.add(101);
            GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING, "*recipient carol@example.test not known*");
            manager.device_list_loaded_for_tests(account, account.bare_jid, own_list);
            GLib.Test.assert_expected_messages();
            drain_pending_events();
            int requests = 0;
            foreach (StanzaNode node in stream.written_nodes) {
                fail_if(node.name == "message", "Unready feed message reached the wire");
                StanzaNode? pubsub = node.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
                StanzaNode? items = pubsub != null ? pubsub.get_subnode("items", Xmpp.Xep.Pubsub.NS_URI) : null;
                if (items == null || items.get_attribute("node") != NS_OMEMO_LEGACY + ".devicelist") continue;
                requests++;
                fail_if(node.get_attribute("to") != carol.to_string(), "Known members or the room were queried again");
            }
            fail_if(requests != 1 || attempts != 2, "Pending device-list fetch must be coalesced");
            StanzaNode? held = stream.take_held_legacy_devicelist_request();
            fail_if(held == null);
            if (held != null) {
                var items = new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                    .put_attribute("node", NS_OMEMO_LEGACY + ".devicelist");
                stream.emit_iq_result(build_empty_pubsub_items_result_for_request((!) held, items));
                drain_pending_events();
            }
            fail_if(pending.marked != Message.Marked.WONTSEND || pending.delivery_error_text == null,
                "An authoritative empty list must stop the pending send with a visible error");
            int stopped = attempts;
            manager.device_list_loaded_for_tests(account, account.bare_jid, own_list);
            fail_if(attempts != stopped, "A terminal send must not loop on later device replies");
            add_trusted_omemo1_device((!) db, identity, carol, carol_store);
            prepare_pre_key_session(context, own_store, carol, carol_store, 61002, 62002);
            processor.send_xmpp_message((!) pending, group, true);
            drain_pending_events();
            int sent = 0;
            foreach (StanzaNode node in stream.written_nodes) {
                if (node.name != "message") continue;
                sent++;
                fail_if(node.get_attribute("type") != MessageStanza.TYPE_GROUPCHAT ||
                    node.get_attribute("to") != room.to_string());
                fail_if(node.get_subnode("encrypted", NS_OMEMO_LEGACY) == null ||
                    node.get_deep_string_content("body") == pending.body);
            }
            fail_if(sent != 1 || pending.marked != Message.Marked.SENT,
                "Explicit retry with available devices must send exactly one encrypted group message");
            manager.forget_pending_messages_for_account(account);
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (feeds != null) feeds.shutdown();
            if (muc != null) muc.shutdown();
            if (stream != null) {
                if (module != null) module.detach(stream);
                stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
                drain_pending_events();
            }
            if (db != null) db.close();
            if (app_db != null) app_db.close();
            foreach (string name in new string[] {"app.db", "omemo.db"}) {
                foreach (string suffix in new string[] {"", "-wal", "-shm"}) cleanup_file(Path.build_filename(directory, name + suffix));
            }
            if (directory != "") DirUtils.remove(directory);
        }
    }

    // This manager boundary test uses a real current room-info/affiliation
    // snapshot and native session state. It does not upload a file or claim
    // that the explicitly injected access-denied signal is a network reply.
    private void test_private_muc_bundle_denial_scope(int room_context, bool own_keys) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-omemo-private-muc-denial-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");
        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("private MUC denial proof requires native OMEMO");
            }
            Context context = Dino.Plugins.Omemo.Plugin.get_context();
            dino_db = new Dino.Database(dino_db_path, "omemo-private-muc-denial-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(interactor, (!) dino_db);
            var account = new Account(new Jid("alice@example.test"), "test-only");
            account.persist((!) dino_db);
            var other_account = new Account(new Jid("other-account@example.test"), "test-only");
            other_account.persist((!) dino_db);
            var room = new Jid("private-room@conference.example.test");
            var bob = new Jid("bob@example.test");
            var carol = new Jid("carol@example.test");
            var unrelated = new Jid("unrelated@example.test");
            Jid denied_jid = own_keys ? account.bare_jid : carol;
            mark_room_private_in_entity_info((!) dino_db, account, room);
            var conversation = new Conversation(room, account, Conversation.Type.GROUPCHAT) {
                encryption = Encryption.OMEMO,
                send_typing = Conversation.Setting.OFF,
                send_marker = Conversation.Setting.OFF
            };
            conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            Store carol_store = setup_test_store_context(context);
            Store unrelated_store = setup_test_store_context(context);
            alice_store.identity_key_store.local_registration_id = 101;
            bob_store.identity_key_store.local_registration_id = 202;
            carol_store.identity_key_store.local_registration_id = 303;
            unrelated_store.identity_key_store.local_registration_id = 303;
            prepare_pre_key_session(context, alice_store, bob, bob_store, 61001, 62001);
            int identity_id = install_identity((!) omemo_db, account, alice_store);
            add_trusted_omemo1_device((!) omemo_db, identity_id, account.bare_jid, alice_store);
            add_trusted_omemo1_device((!) omemo_db, identity_id, bob, bob_store);
            add_trusted_omemo1_device((!) omemo_db, identity_id, denied_jid, carol_store);
            add_trusted_omemo1_device((!) omemo_db, identity_id, unrelated, unrelated_store);
            var trust = new Dino.Plugins.Omemo.TrustManager(interactor, (!) omemo_db);
            var encryptors = new HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor>(
                Account.hash_func, Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust, alice_store);
            var manager = Dino.Plugins.Omemo.Manager.create_for_tests(interactor,
                (!) omemo_db, trust, encryptors);
            interactor.module_manager.initialize(account);
            interactor.account_added(account);
            TestXmppStream stream = create_connected_http_omemo_upload_stream(interactor,
                account, alice_store);
            attach_private_muc_modules_for_tests(interactor, account, stream, room, "alice");
            var forbidden = new HashSet<string>();
            if (room_context == 1) forbidden.add("admin");
            Gee.List<Jid>? snapshot = query_private_muc_snapshot_for_tests(interactor,
                account, stream, room, own_keys ? member_list(account.bare_jid, bob)
                    : member_list(account.bare_jid, bob, carol),
                member_list(), member_list(), forbidden, room_context != 2);
            drain_pending_events();
            var muc = interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(muc.has_complete_private_muc_affiliation_snapshot(account, room) != (room_context == 0),
                "denial proof must establish the requested current snapshot validity");
            fail_if(muc.has_live_private_room_features(account, room) != (room_context != 2),
                "public-room proof must use a real public room-info response");
            if (room_context == 0) {
                assert_member_list_contains_bare(snapshot, denied_jid,
                    "the denied device must belong to an actual current private-room member");
            }

            var module = stream.get_module<Dino.Plugins.Omemo.StreamModule>(
                Dino.Plugins.Omemo.StreamModule.IDENTITY);
            fail_if(module.has_legacy_session_for_send(denied_jid, 303),
                "the denied member must still need a native receiving session");
            fail_if_not(module.has_legacy_session_for_send(bob, 202),
                "another room member must already have a usable native session");
            var wait = new Xmpp.Xep.Omemo.EncryptState() {
                encrypted = true, own_list = true,
                own_devices = own_keys ? 2 : 1, own_unknown = own_keys ? 1 : 0,
                other_devices = own_keys ? 1 : 2, other_success = 1,
                other_unknown = own_keys ? 0 : 1
            };
            var message = new Message("pending private MUC encrypted message") {
                account = account, counterpart = room, encryption = Encryption.OMEMO,
                type_ = Message.Type.GROUPCHAT, marked = Message.Marked.UNSENT
            };
            var other = new Message("another account's pending encrypted message") {
                account = other_account, counterpart = room, encryption = Encryption.OMEMO,
                type_ = Message.Type.GROUPCHAT, marked = Message.Marked.UNSENT
            };
            var state = manager.update_send_state(message, wait);
            var other_state = manager.update_send_state(other, wait);
            fail_if(state.will_send_now || message.marked != Message.Marked.UNSENT,
                "the missing active member session must keep this group send queued");
            manager.on_bundle_access_denied(account, account.bare_jid, 101, true);
            fail_if(message.marked != Message.Marked.UNSENT ||
                    manager.update_send_state(message, wait) != state,
                "current-sender metadata denial must not fail a group waiting for another device");
            manager.on_bundle_access_denied(account, unrelated, 303, true);
            fail_if(message.marked != Message.Marked.UNSENT ||
                    manager.update_send_state(message, wait) != state,
                "a trusted device outside the current member snapshot must preserve the queued attempt");
            manager.on_bundle_access_denied(account, denied_jid.with_resource("phone"), 303, true);
            if (room_context == 0) {
                fail_if(message.marked != Message.Marked.ERROR || message.delivery_error_text == null,
                    "denied access to a needed current member session must visibly fail the group send");
                fail_if(message.encryption != Encryption.OMEMO,
                    "access denial must never select a plaintext fallback");
                fail_if(manager.update_send_state(message, wait) == state,
                    "denied group sends must leave the automatic retry queue");
            } else {
                fail_if(message.marked != Message.Marked.UNSENT ||
                        manager.update_send_state(message, wait) != state,
                    "an invalid/private-incomplete or public context cannot authorize a member denial");
            }
            fail_if(other.marked != Message.Marked.UNSENT ||
                    manager.update_send_state(other, wait) != other_state,
                "the same denial must not alter another account's queued group send");
            var row = ((!) omemo_db).identity_meta.get_device(identity_id, denied_jid.to_string(), 303);
            fail_if(row == null || !((!) row)[((!) omemo_db).identity_meta.now_active]);
            fail_if(row != null && ((!) row)[((!) omemo_db).identity_meta.trust_level] !=
                Dino.Plugins.Omemo.TrustLevel.TRUSTED);
            fail_if(module.is_ignored_device(denied_jid, 303),
                "authorization denial must not classify an active trusted member device as lost");
            foreach (StanzaNode written in stream.written_nodes) {
                fail_if(written.name == "message",
                    "a denial decision must not write an encrypted or plaintext group message");
            }
            manager.forget_pending_messages_for_account(account);
            manager.forget_pending_messages_for_account(other_account);
        } catch (Error error) {
            fail_if_reached("private MUC bundle denial scope proof failed: " + error.message);
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

    private void test_private_muc_readiness_blocks_input_until_ready() {
        Dino.Plugins.InputFieldStatus verifying = Dino.Plugins.Omemo
            .EncryptionListEntry.private_muc_verification_input_status();
        fail_if(verifying.message_type !=
                Dino.Plugins.InputFieldStatus.MessageType.INFO,
            "private MUC verification must be visible as an informational status");
        fail_if(verifying.input_state !=
                Dino.Plugins.InputFieldStatus.InputState.NO_SEND,
            "private MUC verification must block sending before the snapshot is ready");

        Dino.Plugins.InputFieldStatus ready = Dino.Plugins.Omemo
            .EncryptionListEntry.private_muc_ready_input_status();
        fail_if(ready.message_type !=
                Dino.Plugins.InputFieldStatus.MessageType.NONE,
            "ready private MUC must clear the verification status");
        fail_if(ready.input_state !=
                Dino.Plugins.InputFieldStatus.InputState.NORMAL,
            "ready private MUC must restore normal sending");
    }

    private void test_private_muc_readiness_rejects_changed_member_snapshot() {
        try {
            Jid alice = new Jid("alice@example.test");
            Jid bob = new Jid("bob@example.test");
            Jid carol = new Jid("carol@example.test");
            Gee.List<Jid> original = member_list(alice, bob);
            Gee.List<Jid> reordered = member_list(bob, alice);
            Gee.List<Jid> changed = member_list(alice, carol);

            fail_if(!Dino.Plugins.Omemo.Manager
                    .same_private_muc_member_snapshot(original, reordered),
                "member snapshot comparison must be order-independent");
            fail_if(Dino.Plugins.Omemo.Manager
                    .same_private_muc_member_snapshot(original, changed),
                "an old readiness operation must reject a changed recipient set");
        } catch (InvalidJidError e) {
            fail_if(true, "private MUC readiness fixture contains an invalid JID");
        }
    }

    private void test_file_http_send_uses_real_legacy_session_body_only() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-file-session-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "OMEMO file-send session proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-file-send-session-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            alice_store.identity_key_store.local_registration_id = 101;
            alice_other_store.identity_key_store.local_registration_id = 303;
            bob_store.identity_key_store.local_registration_id = 202;

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 31001, 32001);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 31002, 32002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            // Real account initialization also advertises the current device.
            // It must not require a Signal session back to itself.
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            var manager = Dino.Plugins.Omemo.Manager.create_for_tests(stream_interactor, (!) omemo_db, trust_manager, encryptors);

            var stream = new TestXmppStream(new Jid("example.test"));
            stream.add_module(new Dino.Plugins.Omemo.StreamModule(alice_store));
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            string body_url = "aesgcm://upload.example.test/file.bin#00112233445566778899aabb" +
                "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
            var message = new Dino.Entities.Message(body_url);
            message.account = account;
            message.counterpart = bob_account.bare_jid;
            message.encryption = Dino.Entities.Encryption.OMEMO;
            message.marked = Dino.Entities.Message.Marked.SENDING;
            message.type_ = Dino.Entities.Message.Type.CHAT;

            var stanza = new MessageStanza("omemo-file-session-proof");
            message.stanza_id = stanza.id;
            stanza.to = bob_account.bare_jid;
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.body = body_url;

            manager.pre_message_send_for_tests(message, stanza, conversation);

            fail_if(message.marked == Dino.Entities.Message.Marked.UNSENT || message.marked == Dino.Entities.Message.Marked.WONTSEND,
                "real OMEMO file body-url send must be sendable with seeded trusted v1 devices and sessions");
            fail_if_not_eq_str("[This message is OMEMO encrypted]", stanza.body,
                "real OMEMO manager must replace the aesgcm file body URL with the OMEMO fallback body");

            StanzaNode? encrypted_node = stanza.stanza.get_subnode("encrypted", NS_OMEMO_LEGACY);
            fail_if(encrypted_node == null,
                "real OMEMO manager must write the legacy OMEMO encrypted payload");
            if (encrypted_node == null) return;

            assert_omemo_key_recipient((!) encrypted_node, (int) bob_store.local_registration_id,
                "real OMEMO file body-url payload must be encrypted to the recipient device");
            assert_omemo_key_recipient((!) encrypted_node, (int) alice_other_store.local_registration_id,
                "real OMEMO file body-url payload must also be encrypted to an own trusted device");
            fail_if(omemo1_payload_has_device((!) encrypted_node, (int) alice_store.local_registration_id),
                "the sending device must not receive a wrapped key or require a session to itself");

            string wire = stanza.stanza.to_string();
            fail_if(wire.contains(body_url) || wire.contains("aesgcm://") || wire.contains("#00112233445566778899aabb"),
                "real OMEMO file body-url send must not expose the aesgcm URL or secret outside the encrypted payload");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_stream = new TestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Xmpp.Iq.Module());
            bob_stream.add_module(new Xmpp.Xep.Pubsub.Module());
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_store));
            bob_stream_interactor.connection_manager.set_connected_stream_for_tests(bob_account, bob_stream);
            var bob_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_store);

            string decrypted_body_url = decrypt_legacy_omemo_payload(bob_decryptor, (!) encrypted_node, account.bare_jid);
            fail_if_not_eq_str(body_url, decrypted_body_url,
                "recipient must decrypt the real OMEMO payload back to the original aesgcm body URL");

            string guard_reason = "";
            fail_if(!Dino.MessageProcessor.outgoing_stanza_matches_encryption(Dino.Entities.Encryption.OMEMO, stanza, out guard_reason),
                "MessageProcessor encryption guard must accept the real OMEMO payload: " + guard_reason);
        } catch (Error e) {
            fail_if(true, @"real OMEMO file-send session proof failed: $(e.message)");
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

    private void test_file_http_send_uses_sce_only_for_v2_only_devices() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo2-file-session-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "OMEMO2 file-send SCE proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo2-file-send-session-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            alice_store.identity_key_store.local_registration_id = 101;
            alice_other_store.identity_key_store.local_registration_id = 303;
            bob_store.identity_key_store.local_registration_id = 202;

            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_store, 35001, 36001);
            prepare_pre_key_session_v2(context, alice_store, account.bare_jid, alice_other_store, 35002, 36002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo2_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            var encryptors_v2 = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, trust_manager, alice_store);
            var manager = Dino.Plugins.Omemo.Manager.create_for_tests(stream_interactor, (!) omemo_db, trust_manager, encryptors, encryptors_v2);

            var stream = new TestXmppStream(new Jid("example.test"));
            stream.add_module(new Dino.Plugins.Omemo.StreamModule(alice_store));
            stream.add_module(new Dino.Plugins.Omemo.StreamModule2(alice_store));
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            string body_url = "aesgcm://upload.example.test/omemo2-file.bin#102132435465768798a9bacb" +
                "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
            var message = new Dino.Entities.Message(body_url);
            message.account = account;
            message.counterpart = bob_account.bare_jid;
            message.encryption = Dino.Entities.Encryption.OMEMO;
            message.marked = Dino.Entities.Message.Marked.SENDING;
            message.type_ = Dino.Entities.Message.Type.CHAT;

            var stanza = new MessageStanza("omemo2-file-session-proof");
            message.stanza_id = stanza.id;
            stanza.to = bob_account.bare_jid;
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.body = body_url;

            manager.pre_message_send_for_tests(message, stanza, conversation);

            fail_if(message.marked == Dino.Entities.Message.Marked.UNSENT || message.marked == Dino.Entities.Message.Marked.WONTSEND,
                "real OMEMO2 file body-url send must be sendable with seeded trusted v2-only devices and sessions");
            fail_if_not_eq_str("[This message is OMEMO encrypted]", stanza.body,
                "real OMEMO2 manager must replace the aesgcm file body URL with the OMEMO fallback body");
            fail_if(stanza.stanza.get_subnode("encrypted", NS_OMEMO_LEGACY) != null,
                "v2-only devices must not be sent as legacy OMEMO");

            StanzaNode? encrypted_node = stanza.stanza.get_subnode("encrypted", NS_OMEMO_V2);
            fail_if(encrypted_node == null,
                "v2-only devices must use an OMEMO2/SCE encrypted payload");
            if (encrypted_node == null) return;

            assert_omemo2_key_recipient((!) encrypted_node, bob_account.bare_jid, (int) bob_store.local_registration_id,
                "real OMEMO2 file body-url payload must be encrypted to the recipient v2 device");
            assert_omemo2_key_recipient((!) encrypted_node, account.bare_jid, (int) alice_other_store.local_registration_id,
                "real OMEMO2 file body-url payload must also be encrypted to an own trusted v2 device");

            string wire = stanza.stanza.to_string();
            fail_if(wire.contains(body_url) || wire.contains("aesgcm://") || wire.contains("#102132435465768798a9bacb"),
                "real OMEMO2 file body-url send must not expose the aesgcm URL or secret outside the SCE payload");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_decryptor = new Dino.Plugins.Omemo.Omemo2Decrypt(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_store);
            string decrypted_body_url = decrypt_omemo2_payload(bob_decryptor, (!) encrypted_node, bob_account.bare_jid, account.bare_jid);
            fail_if_not_eq_str(body_url, decrypted_body_url,
                "recipient must decrypt the real OMEMO2/SCE payload back to the original aesgcm body URL");

            string guard_reason = "";
            fail_if(!Dino.MessageProcessor.outgoing_stanza_matches_encryption(Dino.Entities.Encryption.OMEMO, stanza, out guard_reason),
                "MessageProcessor encryption guard must accept the real OMEMO2 payload: " + guard_reason);
        } catch (Error e) {
            fail_if(true, @"real OMEMO2 file-send SCE proof failed: $(e.message)");
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

    private void test_file_http_send_falls_back_to_legacy_when_recipient_has_v1_device() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo2-file-fallback-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "OMEMO2 fallback proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo2-file-send-fallback-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_legacy_store = setup_test_store_context(context);
            Store alice_other_v2_store = setup_test_store_context(context);
            Store bob_legacy_store = setup_test_store_context(context);
            Store bob_v2_store = setup_test_store_context(context);

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_legacy_store, 37001, 38001);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_legacy_store, 37002, 38002);
            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_v2_store, 37003, 38003);
            prepare_pre_key_session_v2(context, alice_store, account.bare_jid, alice_other_v2_store, 37004, 38004);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_legacy_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_legacy_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_legacy_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_v2_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_v2_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            var encryptors_v2 = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, trust_manager, alice_store);
            var manager = Dino.Plugins.Omemo.Manager.create_for_tests(stream_interactor, (!) omemo_db, trust_manager, encryptors, encryptors_v2);

            var stream = new TestXmppStream(new Jid("example.test"));
            stream.add_module(new Dino.Plugins.Omemo.StreamModule(alice_store));
            stream.add_module(new Dino.Plugins.Omemo.StreamModule2(alice_store));
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            string body_url = "aesgcm://upload.example.test/mixed-device-file.bin#aabbccddeeff001122334455" +
                "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";
            var message = new Dino.Entities.Message(body_url);
            message.account = account;
            message.counterpart = bob_account.bare_jid;
            message.encryption = Dino.Entities.Encryption.OMEMO;
            message.marked = Dino.Entities.Message.Marked.SENDING;
            message.type_ = Dino.Entities.Message.Type.CHAT;

            var stanza = new MessageStanza("omemo2-file-fallback-proof");
            stanza.to = bob_account.bare_jid;
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.body = body_url;

            manager.pre_message_send_for_tests(message, stanza, conversation);

            fail_if(message.marked == Dino.Entities.Message.Marked.UNSENT || message.marked == Dino.Entities.Message.Marked.WONTSEND,
                "mixed OMEMO1/OMEMO2 recipient devices must remain sendable through the legacy fallback");
            fail_if(stanza.stanza.get_subnode("encrypted", NS_OMEMO_V2) != null,
                "a recipient with any OMEMO1 device must not be sent an OMEMO2/SCE file body-url payload");

            StanzaNode? encrypted_node = stanza.stanza.get_subnode("encrypted", NS_OMEMO_LEGACY);
            fail_if(encrypted_node == null,
                "a recipient with any OMEMO1 device must fall back to the legacy OMEMO payload");
            if (encrypted_node == null) return;

            assert_omemo_key_recipient((!) encrypted_node, (int) bob_legacy_store.local_registration_id,
                "mixed-device fallback must encrypt the body URL to the recipient legacy device");
            assert_omemo_key_recipient((!) encrypted_node, (int) alice_other_legacy_store.local_registration_id,
                "mixed-device fallback must encrypt the body URL to an own trusted legacy device");
            fail_if(omemo1_payload_has_device((!) encrypted_node, (int) bob_v2_store.local_registration_id),
                "legacy fallback must not try to use the recipient OMEMO2-only device as a legacy key target");

            string wire = stanza.stanza.to_string();
            fail_if(wire.contains(body_url) || wire.contains("aesgcm://") || wire.contains("#aabbccddeeff001122334455"),
                "legacy fallback file body-url send must not expose the aesgcm URL or secret outside the encrypted payload");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_stream = new TestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Xmpp.Iq.Module());
            bob_stream.add_module(new Xmpp.Xep.Pubsub.Module());
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_legacy_store));
            bob_stream_interactor.connection_manager.set_connected_stream_for_tests(bob_account, bob_stream);
            var bob_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_legacy_store);

            string decrypted_body_url = decrypt_legacy_omemo_payload(bob_decryptor, (!) encrypted_node, account.bare_jid);
            fail_if_not_eq_str(body_url, decrypted_body_url,
                "legacy fallback recipient must decrypt the real OMEMO payload back to the original aesgcm body URL");
        } catch (Error e) {
            fail_if(true, @"real OMEMO2 fallback proof failed: $(e.message)");
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

    private void test_public_file_manager_http_send_uses_real_legacy_session_body_only() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-public-file-send-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "public-filemanager-omemo.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "public FileManager to real OMEMO manager HTTPS payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "public OMEMO FileManager send proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-public-filemanager-http-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;
            conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 33001, 34001);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 33002, 34002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            var omemo_manager = Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors);
            var file_encryption = new Dino.Security.FileEncryption("omemo-public-filemanager-http-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "public OMEMO FileManager send proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);
            // This proof installs the server result directly in the DB. Mark
            // it current only after stream_negotiated cleared old freshness.
            omemo_manager.mark_legacy_devicelist_loaded_for_tests(account, account.bare_jid);
            omemo_manager.mark_legacy_devicelist_loaded_for_tests(account, bob_account.bare_jid);
            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "public OMEMO FileManager send proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "public OMEMO FileManager send proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public OMEMO FileManager send proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public OMEMO FileManager send proof must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(stream, "public-filemanager-omemo.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-omemo");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), conversation, (file_transfer) => {
                file_transfer.server_file_name = "public-filemanager-omemo.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "public OMEMO FileManager send must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "public OMEMO FileManager send must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "public OMEMO FileManager send must select the real HTTP sender");
            fail_if(!capture.handled,
                "public OMEMO FileManager send must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method,
                "public OMEMO FileManager send must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "public OMEMO FileManager send must set the upload content type");
            fail_if_not_eq_str("Bearer real-omemo", capture.authorization ?? "",
                "public OMEMO FileManager send must forward allowed slot headers");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "public OMEMO direct HTTP-GCM upload must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "public OMEMO direct HTTP-GCM upload body must include the 16-byte tag");
            fail_if(bytes_equal(payload, capture.body),
                "public OMEMO direct HTTP-GCM upload must not upload plaintext bytes");

            StanzaNode? omemo_message = find_legacy_omemo_message(stream);
            fail_if(omemo_message == null,
                "public OMEMO FileManager send must write a real legacy OMEMO payload stanza");
            if (omemo_message == null) return;

            StanzaNode? encrypted_node = ((!) omemo_message).get_subnode("encrypted", NS_OMEMO_LEGACY);
            fail_if(encrypted_node == null,
                "public OMEMO FileManager send must contain the legacy OMEMO encrypted node");
            if (encrypted_node == null) return;

            assert_omemo_key_recipient((!) encrypted_node, (int) bob_store.local_registration_id,
                "public OMEMO FileManager send must encrypt the body URL to the recipient device");
            assert_omemo_key_recipient((!) encrypted_node, (int) alice_other_store.local_registration_id,
                "public OMEMO FileManager send must encrypt the body URL to an own trusted device");

            StanzaNode? body_node = ((!) omemo_message).get_subnode("body");
            fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is OMEMO encrypted]",
                "public OMEMO FileManager send must expose only the OMEMO fallback body outside encryption");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_stream = new TestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Xmpp.Iq.Module());
            bob_stream.add_module(new Xmpp.Xep.Pubsub.Module());
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_store));
            bob_stream_interactor.connection_manager.set_connected_stream_for_tests(bob_account, bob_stream);
            var bob_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_store);

            string body_url = decrypt_legacy_omemo_payload(bob_decryptor, (!) encrypted_node, account.bare_jid);
            AesgcmUrlParts url_parts = parse_aesgcm_url(body_url);
            fail_if_not_eq_str(download_url, url_parts.https_url,
                "public OMEMO FileManager send must encrypt the uploaded download URL in the OMEMO body");
            uint8[] decrypted = decrypt_aesgcm_with_attached_tag(capture.body, url_parts.key, url_parts.iv);
            assert_bytes_equal(payload, decrypted,
                "public OMEMO FileManager send captured PUT body must decrypt with the IV/key from the real OMEMO body URL");

            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, body_url,
                "public OMEMO FileManager body-only send");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful public OMEMO FileManager send must complete");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful public OMEMO FileManager send must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful public OMEMO FileManager send must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful public OMEMO FileManager send must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful public OMEMO FileManager send must assign a local file-sharing id");
            fail_if(!file_transfer.input_stream.is_closed(),
                "public OMEMO FileManager send must close the upload stream");
            assert_single_http_source(file_transfer, download_url,
                "public OMEMO FileManager send must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret((!) dino_db, file_transfer, download_url,
                "public OMEMO FileManager send must persist exactly one fragment-free local HTTP source");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "public OMEMO FileManager send must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "public OMEMO FileManager send must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "public OMEMO FileManager send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "public OMEMO FileManager send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "public OMEMO FileManager send must persist successful upload as complete");
        } catch (Error e) {
            fail_if(true, @"public OMEMO FileManager send proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_public_file_manager_http_send_cancel_after_put_blocks_body_announcement() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-public-file-cancel-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "public-filemanager-omemo-cancel.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "public FileManager OMEMO cancel after HTTPS PUT payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "public OMEMO FileManager cancel-after-PUT proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-public-filemanager-http-cancel-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;
            conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 43001, 44001);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 43002, 44002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors);

            var file_encryption = new Dino.Security.FileEncryption("omemo-public-filemanager-http-cancel-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "public OMEMO FileManager cancel-after-PUT proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "public OMEMO FileManager cancel-after-PUT proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public OMEMO FileManager cancel-after-PUT proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public OMEMO FileManager cancel-after-PUT proof must publish a stored outgoing path before transport");
            });

            var capture = new HttpsUploadCapture();
            TlsCertificate tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
            server = new Soup.Server("server-header", "DinoX-OMEMO-HTTPS-Cancel-Test/1.0", null);
            ((!) server).set_tls_certificate(tls_cert);
            ((!) server).add_handler("/upload/cancel-after-put.bin", (srv, msg, path, query) => {
                capture.handled = true;
                capture.written_count_at_upload = stream.written_nodes.size;
                capture.method = msg.get_method();
                capture.content_type = msg.get_request_headers().get_one("Content-Type");
                capture.authorization = msg.get_request_headers().get_one("Authorization");
                capture.content_length = msg.get_request_headers().get_content_length();
                capture.body = copy_bytes(msg.get_request_body().flatten());
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                msg.set_status(201, null);
                set_server_string_response(msg, "text/plain", "cancelled");
            });
            ((!) server).listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
            string upload_url = get_https_server_url((!) server, "/upload/cancel-after-put.bin");
            string download_url = get_https_server_url((!) server, "/download/cancel-after-put.bin");
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "public OMEMO FileManager cancel-after-PUT proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            respond_to_matching_slot_request_when_written(stream, "public-filemanager-omemo-cancel.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-omemo-cancel");
                    stream.emit_iq_result(result_iq);
                });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), conversation, (file_transfer) => {
                file_transfer.server_file_name = "public-filemanager-omemo-cancel.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "public OMEMO FileManager cancel-after-PUT proof must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "public OMEMO FileManager cancel-after-PUT proof must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "public OMEMO FileManager cancel-after-PUT proof must select the real HTTP sender");
            fail_if(!capture.handled,
                "public OMEMO cancel-after-PUT proof must reach the local HTTPS PUT endpoint before cancellation");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public OMEMO cancel-after-PUT proof must cancel the transfer after the server receives the PUT request");
            fail_if_not_eq_str("PUT", capture.method,
                "public OMEMO cancel-after-PUT proof must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "public OMEMO cancel-after-PUT proof must set the upload content type");
            fail_if_not_eq_str("Bearer real-omemo-cancel", capture.authorization ?? "",
                "public OMEMO cancel-after-PUT proof must forward allowed slot headers before cancellation");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "public OMEMO cancel-after-PUT proof must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "public OMEMO cancel-after-PUT proof must upload an AES-GCM body including the 16-byte tag before cancellation");
            fail_if(bytes_equal(payload, capture.body),
                "public OMEMO cancel-after-PUT proof must not upload plaintext bytes");
            fail_if(find_http_upload_slot_request(stream) == null,
                "public OMEMO cancel-after-PUT proof must request an XEP-0363 slot before upload");
            fail_if(find_legacy_omemo_message(stream) != null,
                "public OMEMO cancel-after-PUT proof must not announce a legacy OMEMO body URL after cancellation");
            fail_if(find_omemo2_message(stream) != null,
                "public OMEMO cancel-after-PUT proof must not announce an OMEMO2 body URL after cancellation");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, download_url,
                "public OMEMO cancel-after-PUT body-only boundary");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO cancel-after-PUT proof must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO cancel-after-PUT proof must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public OMEMO cancel-after-PUT proof must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public OMEMO cancel-after-PUT proof must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public OMEMO cancel-after-PUT proof must not assign a file-sharing id before the body-url announcement step");
            fail_if(capture.written_count_at_upload < 0,
                "public OMEMO cancel-after-PUT proof must capture the stanza boundary at PUT time");
            assert_no_message_stanzas_before_boundary(stream, capture.written_count_at_upload,
                "public OMEMO cancel-after-PUT proof must not write any message stanza before the PUT boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the OMEMO upload stream after canceling the real HTTP sender at PUT time");
            assert_no_http_sources(file_transfer,
                "cancelled public OMEMO body-url upload must not add a local HTTP source");
            assert_no_persisted_sources((!) dino_db, file_transfer,
                "cancelled public OMEMO body-url upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "public OMEMO cancel-after-PUT proof must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "public OMEMO cancel-after-PUT proof must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO cancel-after-PUT proof must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public OMEMO cancel-after-PUT proof must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public OMEMO cancel-after-PUT proof must not emit COMPLETE");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO cancel-after-PUT proof must persist cancellation as failed");
        } catch (Error e) {
            fail_if(true, @"public OMEMO FileManager cancel-after-PUT proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_public_file_manager_http_send_cancel_while_request_body_stream_blocks() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-public-file-blocked-body-cancel-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "public-filemanager-omemo-blocked-body-cancel.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;
        uint timeout_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = string.nfill(256 * 1024, 'o');
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "public OMEMO FileManager blocked-body cancellation proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-public-filemanager-http-blocked-body-cancel-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;
            conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 47001, 48001);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 47002, 48002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors);

            var file_encryption = new Dino.Security.FileEncryption("omemo-public-filemanager-http-blocked-body-cancel-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "public OMEMO FileManager blocked-body cancellation proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);

            Dino.Entities.FileTransfer? published_transfer = null;
            BlockedBodyUploadInputStream? blocking_stream = null;
            bool upload_stream_replaced = false;
            bool timed_out = false;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "public OMEMO blocked-body cancellation proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public OMEMO blocked-body cancellation proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public OMEMO blocked-body cancellation proof must publish a stored outgoing path before transport");
            });

            var capture = new BlockedBodyUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_body_stream_cancel_server(capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "public OMEMO blocked-body cancellation proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            respond_to_matching_slot_request_when_written(stream, "public-filemanager-omemo-blocked-body-cancel.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-omemo-blocked-body-cancel");
                    stream.emit_iq_result(result_iq);
                });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            timeout_id = Timeout.add(5000, () => {
                timed_out = true;
                timeout_id = 0;
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                return Source.REMOVE;
            });

            uint8[] first_chunk = "partial public OMEMO blocked upload body".data;
            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), conversation, (file_transfer) => {
                file_transfer.server_file_name = "public-filemanager-omemo-blocked-body-cancel.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => {
                    phases.add(file_transfer.phase);
                    if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.UPLOADING && !upload_stream_replaced) {
                        upload_stream_replaced = true;
                        blocking_stream = new BlockedBodyUploadInputStream(first_chunk, file_transfer.cancellable, capture);
                        file_transfer.input_stream = (!) blocking_stream;
                    }
                });
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(timed_out,
                "public OMEMO blocked-body cancellation must be driven by the controlled stream read, not the timeout guard");
            fail_if(published_transfer == null,
                "public OMEMO blocked-body cancellation proof must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "public OMEMO blocked-body cancellation proof must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "public OMEMO blocked-body cancellation proof must select the real HTTP sender");
            fail_if(!upload_stream_replaced || blocking_stream == null,
                "public OMEMO blocked-body cancellation proof must replace the transport stream at the UPLOADING boundary");
            BlockedBodyUploadInputStream blocked_stream = (!) blocking_stream;
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public OMEMO blocked-body cancellation proof must cancel the transfer while the request body is blocked");
            fail_if(!capture.request_started,
                "public OMEMO blocked-body cancellation proof must open a local HTTPS request before cancellation");
            fail_if(!capture.headers_seen,
                "public OMEMO blocked-body cancellation proof must prove the server received PUT headers before the body completed");
            fail_if(capture.request_read,
                "public OMEMO blocked-body cancellation proof must cancel before libsoup considers the full request body read");
            fail_if(capture.handler_called,
                "public OMEMO blocked-body cancellation proof must not reach the normal PUT handler after a full request body");
            fail_if(!blocked_stream.first_chunk_seen,
                "public OMEMO blocked-body stream must send an initial body chunk before cancellation");
            fail_if(!blocked_stream.blocking_read_seen,
                "public OMEMO blocked-body stream must reach the blocking read after the initial chunk");
            fail_if(!blocked_stream.blocking_read_saw_cancellable,
                "public OMEMO blocked-body stream reads must receive a cancellable that observes transfer cancellation");
            fail_if(blocked_stream.blocking_read_missing_cancellable,
                "public OMEMO blocked-body stream must not be read without a cancellable");
            fail_if(!blocked_stream.cancelled_after_headers_seen,
                "public OMEMO blocked-body stream must trigger cancellation only after the server sees request headers");
            fail_if(!blocked_stream.cancel_seen,
                "public OMEMO blocked-body stream must observe cancellation while blocked");
            fail_if_not_eq_str("PUT", capture.method,
                "public OMEMO blocked-body cancellation proof must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "public OMEMO blocked-body cancellation proof must preserve the plaintext MIME type in the request");
            fail_if_not_eq_str("Bearer real-omemo-blocked-body-cancel", capture.authorization ?? "",
                "public OMEMO blocked-body cancellation proof must forward allowed slot headers before cancellation");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "public OMEMO blocked-body cancellation proof must keep the declared plaintext size plus the 16-byte tag");
            fail_if(find_http_upload_slot_request(stream) == null,
                "public OMEMO blocked-body cancellation proof must request an XEP-0363 slot before upload");
            fail_if(find_legacy_omemo_message(stream) != null,
                "public OMEMO blocked-body cancellation proof must not announce a legacy OMEMO body URL after cancellation");
            fail_if(find_omemo2_message(stream) != null,
                "public OMEMO blocked-body cancellation proof must not announce an OMEMO2/SCE body URL after cancellation");
            assert_no_message_stanzas(stream,
                "public OMEMO blocked-body cancellation proof must not write any body-url message stanza");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, upload_url,
                "public OMEMO blocked-body body-only boundary");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO blocked-body cancellation proof must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO blocked-body cancellation proof must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public OMEMO blocked-body cancellation proof must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public OMEMO blocked-body cancellation proof must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public OMEMO blocked-body cancellation proof must not assign a file-sharing id before the body-url announcement step");
            fail_if(capture.written_count_at_headers < 0,
                "public OMEMO blocked-body cancellation proof must capture the stanza boundary at PUT header time");
            assert_no_message_stanzas_before_boundary(stream, capture.written_count_at_headers,
                "public OMEMO blocked-body cancellation proof must not write any message stanza before the PUT header boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the OMEMO upload stream after canceling the real HTTP sender while the body is blocked");
            fail_if(!blocked_stream.closed,
                "FileManager must close the underlying public OMEMO blocked upload stream after cancellation");
            assert_no_http_sources(file_transfer,
                "cancelled public OMEMO blocked-body upload must not add a local HTTP source");
            assert_no_persisted_sources((!) dino_db, file_transfer,
                "cancelled public OMEMO blocked-body upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "public OMEMO blocked-body cancellation proof must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "public OMEMO blocked-body cancellation proof must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO blocked-body cancellation proof must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public OMEMO blocked-body cancellation proof must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public OMEMO blocked-body cancellation proof must not emit COMPLETE");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO blocked-body cancellation proof must persist cancellation as failed");
        } catch (Error e) {
            fail_if(true, @"public OMEMO FileManager blocked-body cancellation proof failed: $(e.message)");
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_public_file_manager_http_send_uses_real_sce_session_body_only() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo2-public-file-send-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "public-filemanager-omemo2.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "public FileManager to real OMEMO2 SCE HTTPS payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "public OMEMO2 FileManager send proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo2-public-filemanager-http-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;
            conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);

            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_store, 39001, 40001);
            prepare_pre_key_session_v2(context, alice_store, account.bare_jid, alice_other_store, 39002, 40002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo2_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            var encryptors_v2 = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors, encryptors_v2);

            var file_encryption = new Dino.Security.FileEncryption("omemo2-public-filemanager-http-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "public OMEMO2 FileManager send proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store, true);
            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "public OMEMO2 FileManager send proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "public OMEMO2 FileManager send proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public OMEMO2 FileManager send proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public OMEMO2 FileManager send proof must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(stream, "public-filemanager-omemo2.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-omemo2");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), conversation, (file_transfer) => {
                file_transfer.server_file_name = "public-filemanager-omemo2.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "public OMEMO2 FileManager send must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "public OMEMO2 FileManager send must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "public OMEMO2 FileManager send must select the real HTTP sender");
            fail_if(!capture.handled,
                "public OMEMO2 FileManager send must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method,
                "public OMEMO2 FileManager send must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "public OMEMO2 FileManager send must set the upload content type");
            fail_if_not_eq_str("Bearer real-omemo2", capture.authorization ?? "",
                "public OMEMO2 FileManager send must forward allowed slot headers");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "public OMEMO2 direct HTTP-GCM upload must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "public OMEMO2 direct HTTP-GCM upload body must include the 16-byte tag");
            fail_if(bytes_equal(payload, capture.body),
                "public OMEMO2 direct HTTP-GCM upload must not upload plaintext bytes");

            StanzaNode? omemo_message = find_omemo2_message(stream);
            fail_if(omemo_message == null,
                "public OMEMO2 FileManager send must write a real OMEMO2/SCE payload stanza");
            if (omemo_message == null) return;

            fail_if(((!) omemo_message).get_subnode("encrypted", NS_OMEMO_LEGACY) != null,
                "public OMEMO2 FileManager send must not fall back to legacy OMEMO for v2-only devices");

            StanzaNode? encrypted_node = ((!) omemo_message).get_subnode("encrypted", NS_OMEMO_V2);
            fail_if(encrypted_node == null,
                "public OMEMO2 FileManager send must contain the OMEMO2/SCE encrypted node");
            if (encrypted_node == null) return;

            assert_omemo2_key_recipient((!) encrypted_node, bob_account.bare_jid, (int) bob_store.local_registration_id,
                "public OMEMO2 FileManager send must encrypt the body URL to the recipient v2 device");
            assert_omemo2_key_recipient((!) encrypted_node, account.bare_jid, (int) alice_other_store.local_registration_id,
                "public OMEMO2 FileManager send must encrypt the body URL to an own trusted v2 device");

            StanzaNode? body_node = ((!) omemo_message).get_subnode("body");
            fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is OMEMO encrypted]",
                "public OMEMO2 FileManager send must expose only the OMEMO fallback body outside encryption");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_decryptor = new Dino.Plugins.Omemo.Omemo2Decrypt(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_store);

            string body_url = decrypt_omemo2_payload(bob_decryptor, (!) encrypted_node, bob_account.bare_jid, account.bare_jid);
            AesgcmUrlParts url_parts = parse_aesgcm_url(body_url);
            fail_if_not_eq_str(download_url, url_parts.https_url,
                "public OMEMO2 FileManager send must encrypt the uploaded download URL in the OMEMO2/SCE body");
            uint8[] decrypted = decrypt_aesgcm_with_attached_tag(capture.body, url_parts.key, url_parts.iv);
            assert_bytes_equal(payload, decrypted,
                "public OMEMO2 FileManager send captured PUT body must decrypt with the IV/key from the real OMEMO2 body URL");

            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, body_url,
                "public OMEMO2 FileManager body-only send");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful public OMEMO2 FileManager send must complete");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful public OMEMO2 FileManager send must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful public OMEMO2 FileManager send must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful public OMEMO2 FileManager send must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful public OMEMO2 FileManager send must assign a local file-sharing id");
            fail_if(!file_transfer.input_stream.is_closed(),
                "public OMEMO2 FileManager send must close the upload stream");
            assert_single_http_source(file_transfer, download_url,
                "public OMEMO2 FileManager send must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret((!) dino_db, file_transfer, download_url,
                "public OMEMO2 FileManager send must persist exactly one fragment-free local HTTP source");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "public OMEMO2 FileManager send must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "public OMEMO2 FileManager send must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "public OMEMO2 FileManager send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "public OMEMO2 FileManager send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "public OMEMO2 FileManager send must persist successful upload as complete");
        } catch (Error e) {
            fail_if(true, @"public OMEMO2 FileManager send proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_public_file_manager_http_send_cancel_after_put_blocks_sce_body_announcement() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo2-public-file-cancel-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "public-filemanager-omemo2-cancel.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "public FileManager OMEMO2 cancel after HTTPS PUT payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "public OMEMO2 FileManager cancel-after-PUT proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo2-public-filemanager-http-cancel-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;
            conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);

            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_store, 45001, 46001);
            prepare_pre_key_session_v2(context, alice_store, account.bare_jid, alice_other_store, 45002, 46002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo2_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            var encryptors_v2 = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors, encryptors_v2);

            var file_encryption = new Dino.Security.FileEncryption("omemo2-public-filemanager-http-cancel-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "public OMEMO2 FileManager cancel-after-PUT proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store, true);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "public OMEMO2 FileManager cancel-after-PUT proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public OMEMO2 FileManager cancel-after-PUT proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public OMEMO2 FileManager cancel-after-PUT proof must publish a stored outgoing path before transport");
            });

            var capture = new HttpsUploadCapture();
            TlsCertificate tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
            server = new Soup.Server("server-header", "DinoX-OMEMO2-HTTPS-Cancel-Test/1.0", null);
            ((!) server).set_tls_certificate(tls_cert);
            ((!) server).add_handler("/upload/cancel-after-put-omemo2.bin", (srv, msg, path, query) => {
                capture.handled = true;
                capture.written_count_at_upload = stream.written_nodes.size;
                capture.method = msg.get_method();
                capture.content_type = msg.get_request_headers().get_one("Content-Type");
                capture.authorization = msg.get_request_headers().get_one("Authorization");
                capture.content_length = msg.get_request_headers().get_content_length();
                capture.body = copy_bytes(msg.get_request_body().flatten());
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                msg.set_status(201, null);
                set_server_string_response(msg, "text/plain", "cancelled");
            });
            ((!) server).listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
            string upload_url = get_https_server_url((!) server, "/upload/cancel-after-put-omemo2.bin");
            string download_url = get_https_server_url((!) server, "/download/cancel-after-put-omemo2.bin");
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "public OMEMO2 FileManager cancel-after-PUT proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            respond_to_matching_slot_request_when_written(stream, "public-filemanager-omemo2-cancel.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-omemo2-cancel");
                    stream.emit_iq_result(result_iq);
                });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), conversation, (file_transfer) => {
                file_transfer.server_file_name = "public-filemanager-omemo2-cancel.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(published_transfer == null,
                "public OMEMO2 FileManager cancel-after-PUT proof must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "public OMEMO2 FileManager cancel-after-PUT proof must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "public OMEMO2 FileManager cancel-after-PUT proof must select the real HTTP sender");
            fail_if(!capture.handled,
                "public OMEMO2 cancel-after-PUT proof must reach the local HTTPS PUT endpoint before cancellation");
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public OMEMO2 cancel-after-PUT proof must cancel the transfer after the server receives the PUT request");
            fail_if_not_eq_str("PUT", capture.method,
                "public OMEMO2 cancel-after-PUT proof must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "public OMEMO2 cancel-after-PUT proof must set the upload content type");
            fail_if_not_eq_str("Bearer real-omemo2-cancel", capture.authorization ?? "",
                "public OMEMO2 cancel-after-PUT proof must forward allowed slot headers before cancellation");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "public OMEMO2 cancel-after-PUT proof must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "public OMEMO2 cancel-after-PUT proof must upload an AES-GCM body including the 16-byte tag before cancellation");
            fail_if(bytes_equal(payload, capture.body),
                "public OMEMO2 cancel-after-PUT proof must not upload plaintext bytes");
            fail_if(find_http_upload_slot_request(stream) == null,
                "public OMEMO2 cancel-after-PUT proof must request an XEP-0363 slot before upload");
            fail_if(find_legacy_omemo_message(stream) != null,
                "public OMEMO2 cancel-after-PUT proof must not fall back to a legacy OMEMO body URL after cancellation");
            fail_if(find_omemo2_message(stream) != null,
                "public OMEMO2 cancel-after-PUT proof must not announce an OMEMO2/SCE body URL after cancellation");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, download_url,
                "public OMEMO2 cancel-after-PUT body-only boundary");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO2 cancel-after-PUT proof must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO2 cancel-after-PUT proof must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public OMEMO2 cancel-after-PUT proof must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public OMEMO2 cancel-after-PUT proof must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public OMEMO2 cancel-after-PUT proof must not assign a file-sharing id before the body-url announcement step");
            fail_if(capture.written_count_at_upload < 0,
                "public OMEMO2 cancel-after-PUT proof must capture the stanza boundary at PUT time");
            assert_no_message_stanzas_before_boundary(stream, capture.written_count_at_upload,
                "public OMEMO2 cancel-after-PUT proof must not write any message stanza before the PUT boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the OMEMO2 upload stream after canceling the real HTTP sender at PUT time");
            assert_no_http_sources(file_transfer,
                "cancelled public OMEMO2 body-url upload must not add a local HTTP source");
            assert_no_persisted_sources((!) dino_db, file_transfer,
                "cancelled public OMEMO2 body-url upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "public OMEMO2 cancel-after-PUT proof must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "public OMEMO2 cancel-after-PUT proof must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO2 cancel-after-PUT proof must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public OMEMO2 cancel-after-PUT proof must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public OMEMO2 cancel-after-PUT proof must not emit COMPLETE");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO2 cancel-after-PUT proof must persist cancellation as failed");
        } catch (Error e) {
            fail_if(true, @"public OMEMO2 FileManager cancel-after-PUT proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_public_file_manager_http_send_cancel_while_request_body_stream_blocks_omemo2() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo2-public-file-blocked-body-cancel-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "public-filemanager-omemo2-blocked-body-cancel.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;
        uint timeout_id = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = string.nfill(256 * 1024, '2');
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "public OMEMO2 FileManager blocked-body cancellation proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo2-public-filemanager-http-blocked-body-cancel-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;
            conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);

            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_store, 49001, 50001);
            prepare_pre_key_session_v2(context, alice_store, account.bare_jid, alice_other_store, 49002, 50002);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo2_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            var encryptors_v2 = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors, encryptors_v2);

            var file_encryption = new Dino.Security.FileEncryption("omemo2-public-filemanager-http-blocked-body-cancel-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "public OMEMO2 FileManager blocked-body cancellation proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store, true);

            Dino.Entities.FileTransfer? published_transfer = null;
            BlockedBodyUploadInputStream? blocking_stream = null;
            bool upload_stream_replaced = false;
            bool timed_out = false;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "public OMEMO2 blocked-body cancellation proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public OMEMO2 blocked-body cancellation proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public OMEMO2 blocked-body cancellation proof must publish a stored outgoing path before transport");
            });

            var capture = new BlockedBodyUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_body_stream_cancel_server(capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "public OMEMO2 blocked-body cancellation proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            respond_to_matching_slot_request_when_written(stream, "public-filemanager-omemo2-blocked-body-cancel.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-omemo2-blocked-body-cancel");
                    stream.emit_iq_result(result_iq);
                });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_DEBUG, "*Send file cancelled*");

            timeout_id = Timeout.add(5000, () => {
                timed_out = true;
                timeout_id = 0;
                if (published_transfer != null) {
                    ((!) published_transfer).cancellable.cancel();
                }
                return Source.REMOVE;
            });

            uint8[] first_chunk = "partial public OMEMO2 blocked upload body".data;
            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), conversation, (file_transfer) => {
                file_transfer.server_file_name = "public-filemanager-omemo2-blocked-body-cancel.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => {
                    phases.add(file_transfer.phase);
                    if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.UPLOADING && !upload_stream_replaced) {
                        upload_stream_replaced = true;
                        blocking_stream = new BlockedBodyUploadInputStream(first_chunk, file_transfer.cancellable, capture);
                        file_transfer.input_stream = (!) blocking_stream;
                    }
                });
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            GLib.Test.assert_expected_messages();
            drain_pending_events();

            fail_if(timed_out,
                "public OMEMO2 blocked-body cancellation must be driven by the controlled stream read, not the timeout guard");
            fail_if(published_transfer == null,
                "public OMEMO2 blocked-body cancellation proof must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "public OMEMO2 blocked-body cancellation proof must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "public OMEMO2 blocked-body cancellation proof must select the real HTTP sender");
            fail_if(!upload_stream_replaced || blocking_stream == null,
                "public OMEMO2 blocked-body cancellation proof must replace the transport stream at the UPLOADING boundary");
            BlockedBodyUploadInputStream blocked_stream = (!) blocking_stream;
            fail_if(!file_transfer.cancellable.is_cancelled(),
                "public OMEMO2 blocked-body cancellation proof must cancel the transfer while the request body is blocked");
            fail_if(!capture.request_started,
                "public OMEMO2 blocked-body cancellation proof must open a local HTTPS request before cancellation");
            fail_if(!capture.headers_seen,
                "public OMEMO2 blocked-body cancellation proof must prove the server received PUT headers before the body completed");
            fail_if(capture.request_read,
                "public OMEMO2 blocked-body cancellation proof must cancel before libsoup considers the full request body read");
            fail_if(capture.handler_called,
                "public OMEMO2 blocked-body cancellation proof must not reach the normal PUT handler after a full request body");
            fail_if(!blocked_stream.first_chunk_seen,
                "public OMEMO2 blocked-body stream must send an initial body chunk before cancellation");
            fail_if(!blocked_stream.blocking_read_seen,
                "public OMEMO2 blocked-body stream must reach the blocking read after the initial chunk");
            fail_if(!blocked_stream.blocking_read_saw_cancellable,
                "public OMEMO2 blocked-body stream reads must receive a cancellable that observes transfer cancellation");
            fail_if(blocked_stream.blocking_read_missing_cancellable,
                "public OMEMO2 blocked-body stream must not be read without a cancellable");
            fail_if(!blocked_stream.cancelled_after_headers_seen,
                "public OMEMO2 blocked-body stream must trigger cancellation only after the server sees request headers");
            fail_if(!blocked_stream.cancel_seen,
                "public OMEMO2 blocked-body stream must observe cancellation while blocked");
            fail_if_not_eq_str("PUT", capture.method,
                "public OMEMO2 blocked-body cancellation proof must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "public OMEMO2 blocked-body cancellation proof must preserve the plaintext MIME type in the request");
            fail_if_not_eq_str("Bearer real-omemo2-blocked-body-cancel", capture.authorization ?? "",
                "public OMEMO2 blocked-body cancellation proof must forward allowed slot headers before cancellation");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "public OMEMO2 blocked-body cancellation proof must keep the declared plaintext size plus the 16-byte tag");
            StanzaNode? slot_request = find_http_upload_slot_request(stream);
            fail_if(slot_request == null,
                "public OMEMO2 blocked-body cancellation proof must request an XEP-0363 slot before upload");
            if (slot_request != null) {
                StanzaNode? request = ((!) slot_request).get_subnode("request", NS_HTTP_UPLOAD_0);
                fail_if(request == null,
                    "public OMEMO2 blocked-body cancellation proof must keep the HTTP upload request node");
                if (request != null) {
                    fail_if_not_eq_str("public-filemanager-omemo2-blocked-body-cancel.txt", ((!) request).get_attribute("filename") ?? "",
                        "public OMEMO2 blocked-body cancellation proof must request the expected slot filename");
                    fail_if_not_eq_str((payload.length + 16).to_string(), ((!) request).get_attribute("size") ?? "",
                        "public OMEMO2 blocked-body cancellation proof must request plaintext size plus the 16-byte tag");
                    fail_if_not_eq_str("text/plain", ((!) request).get_attribute("content-type") ?? "",
                        "public OMEMO2 blocked-body cancellation proof must request the plaintext MIME type");
                }
            }
            fail_if(find_legacy_omemo_message(stream) != null,
                "public OMEMO2 blocked-body cancellation proof must not fall back to a legacy OMEMO body URL after cancellation");
            fail_if(find_omemo2_message(stream) != null,
                "public OMEMO2 blocked-body cancellation proof must not announce an OMEMO2/SCE body URL after cancellation");
            assert_no_message_stanzas(stream,
                "public OMEMO2 blocked-body cancellation proof must not write any body-url message stanza");
            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, upload_url,
                "public OMEMO2 blocked-body body-only boundary");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO2 blocked-body cancellation proof must fail the public FileManager send");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO2 blocked-body cancellation proof must persist FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "public OMEMO2 blocked-body cancellation proof must surface a stable cancelled transfer error");
            fail_if(file_transfer.info != null && ((!) file_transfer.info) != "",
                "public OMEMO2 blocked-body cancellation proof must not link a body-url message");
            fail_if(file_transfer.file_sharing_id != null && ((!) file_transfer.file_sharing_id) != "",
                "public OMEMO2 blocked-body cancellation proof must not assign a file-sharing id before the body-url announcement step");
            fail_if(capture.written_count_at_headers < 0,
                "public OMEMO2 blocked-body cancellation proof must capture the stanza boundary at PUT header time");
            assert_no_message_stanzas_before_boundary(stream, capture.written_count_at_headers,
                "public OMEMO2 blocked-body cancellation proof must not write any message stanza before the PUT header boundary");
            fail_if(!file_transfer.input_stream.is_closed(),
                "FileManager must close the OMEMO2 upload stream after canceling the real HTTP sender while the body is blocked");
            fail_if(!blocked_stream.closed,
                "FileManager must close the underlying public OMEMO2 blocked upload stream after cancellation");
            assert_no_http_sources(file_transfer,
                "cancelled public OMEMO2 blocked-body upload must not add a local HTTP source");
            assert_no_persisted_sources((!) dino_db, file_transfer,
                "cancelled public OMEMO2 blocked-body upload must not persist an HTTP source");

            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "public OMEMO2 blocked-body cancellation proof must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "public OMEMO2 blocked-body cancellation proof must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "public OMEMO2 blocked-body cancellation proof must fail from the upload phase before body-url announcement");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "public OMEMO2 blocked-body cancellation proof must not enter ANNOUNCING after cancellation");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "public OMEMO2 blocked-body cancellation proof must not emit COMPLETE");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "public OMEMO2 blocked-body cancellation proof must persist cancellation as failed");
        } catch (Error e) {
            fail_if(true, @"public OMEMO2 FileManager blocked-body cancellation proof failed: $(e.message)");
        } finally {
            if (timeout_id != 0) Source.remove(timeout_id);
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_public_file_manager_http_send_falls_back_to_legacy_for_mixed_devices() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo2-public-file-fallback-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "public-filemanager-omemo2-fallback.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "public FileManager mixed OMEMO devices HTTPS fallback payload\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "public mixed-device OMEMO FileManager fallback proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo2-public-filemanager-http-fallback-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Dino.Entities.Conversation(new Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.OMEMO;
            conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;

            Store alice_store = setup_test_store_context(context);
            Store alice_other_legacy_store = setup_test_store_context(context);
            Store alice_other_v2_store = setup_test_store_context(context);
            Store bob_legacy_store = setup_test_store_context(context);
            Store bob_v2_store = setup_test_store_context(context);

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_legacy_store, 41001, 42001);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_legacy_store, 41002, 42002);
            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_v2_store, 41003, 42003);
            prepare_pre_key_session_v2(context, alice_store, account.bare_jid, alice_other_v2_store, 41004, 42004);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_legacy_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_legacy_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_legacy_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_v2_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_v2_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            var encryptors_v2 = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            var omemo_manager = Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors, encryptors_v2);

            var file_encryption = new Dino.Security.FileEncryption("omemo2-public-filemanager-http-fallback-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "public mixed-device OMEMO FileManager fallback proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store, true);
            omemo_manager.mark_legacy_devicelist_loaded_for_tests(account, account.bare_jid);
            omemo_manager.mark_legacy_devicelist_loaded_for_tests(account, bob_account.bare_jid);
            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "public mixed-device OMEMO FileManager fallback proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "public mixed-device OMEMO FileManager fallback proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "public mixed-device OMEMO FileManager fallback proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "public mixed-device OMEMO FileManager fallback proof must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(stream, "public-filemanager-omemo2-fallback.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-omemo2-fallback");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), conversation, (file_transfer) => {
                file_transfer.server_file_name = "public-filemanager-omemo2-fallback.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "public mixed-device OMEMO FileManager fallback must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "public mixed-device OMEMO FileManager fallback must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "public mixed-device OMEMO FileManager fallback must select the real HTTP sender");
            fail_if(!capture.handled,
                "public mixed-device OMEMO FileManager fallback must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method,
                "public mixed-device OMEMO FileManager fallback must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "public mixed-device OMEMO FileManager fallback must set the upload content type");
            fail_if_not_eq_str("Bearer real-omemo2-fallback", capture.authorization ?? "",
                "public mixed-device OMEMO FileManager fallback must forward allowed slot headers");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "public mixed-device OMEMO direct HTTP-GCM upload must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "public mixed-device OMEMO direct HTTP-GCM upload body must include the 16-byte tag");
            fail_if(bytes_equal(payload, capture.body),
                "public mixed-device OMEMO direct HTTP-GCM upload must not upload plaintext bytes");

            fail_if(find_omemo2_message(stream) != null,
                "public mixed-device OMEMO FileManager fallback must not send OMEMO2/SCE when any recipient OMEMO1 device exists");
            StanzaNode? omemo_message = find_legacy_omemo_message(stream);
            fail_if(omemo_message == null,
                "public mixed-device OMEMO FileManager fallback must write a real legacy OMEMO payload stanza");
            if (omemo_message == null) return;

            StanzaNode? encrypted_node = ((!) omemo_message).get_subnode("encrypted", NS_OMEMO_LEGACY);
            fail_if(encrypted_node == null,
                "public mixed-device OMEMO FileManager fallback must contain the legacy OMEMO encrypted node");
            if (encrypted_node == null) return;

            assert_omemo_key_recipient((!) encrypted_node, (int) bob_legacy_store.local_registration_id,
                "public mixed-device OMEMO FileManager fallback must encrypt the body URL to the recipient legacy device");
            assert_omemo_key_recipient((!) encrypted_node, (int) alice_other_legacy_store.local_registration_id,
                "public mixed-device OMEMO FileManager fallback must encrypt the body URL to an own trusted legacy device");
            fail_if(omemo1_payload_has_device((!) encrypted_node, (int) bob_v2_store.local_registration_id),
                "public mixed-device OMEMO FileManager fallback must not use the recipient OMEMO2-only device as a legacy key target");
            fail_if(omemo1_payload_has_device((!) encrypted_node, (int) alice_other_v2_store.local_registration_id),
                "public mixed-device OMEMO FileManager fallback must not use the own OMEMO2-only device as a legacy key target");

            StanzaNode? body_node = ((!) omemo_message).get_subnode("body");
            fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is OMEMO encrypted]",
                "public mixed-device OMEMO FileManager fallback must expose only the OMEMO fallback body outside encryption");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_stream = new TestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Xmpp.Iq.Module());
            bob_stream.add_module(new Xmpp.Xep.Pubsub.Module());
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_legacy_store));
            bob_stream_interactor.connection_manager.set_connected_stream_for_tests(bob_account, bob_stream);
            var bob_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_legacy_store);

            string body_url = decrypt_legacy_omemo_payload(bob_decryptor, (!) encrypted_node, account.bare_jid);
            AesgcmUrlParts url_parts = parse_aesgcm_url(body_url);
            fail_if_not_eq_str(download_url, url_parts.https_url,
                "public mixed-device OMEMO FileManager fallback must encrypt the uploaded download URL in the legacy OMEMO body");
            uint8[] decrypted = decrypt_aesgcm_with_attached_tag(capture.body, url_parts.key, url_parts.iv);
            assert_bytes_equal(payload, decrypted,
                "public mixed-device OMEMO FileManager fallback captured PUT body must decrypt with the IV/key from the real legacy OMEMO body URL");

            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, body_url,
                "public mixed-device OMEMO FileManager fallback body-only send");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful public mixed-device OMEMO FileManager fallback must complete");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful public mixed-device OMEMO FileManager fallback must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful public mixed-device OMEMO FileManager fallback must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful public mixed-device OMEMO FileManager fallback must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful public mixed-device OMEMO FileManager fallback must assign a local file-sharing id");
            fail_if(!file_transfer.input_stream.is_closed(),
                "public mixed-device OMEMO FileManager fallback must close the upload stream");
            assert_single_http_source(file_transfer, download_url,
                "public mixed-device OMEMO FileManager fallback must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret((!) dino_db, file_transfer, download_url,
                "public mixed-device OMEMO FileManager fallback must persist exactly one fragment-free local HTTP source");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "public mixed-device OMEMO FileManager fallback must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "public mixed-device OMEMO FileManager fallback must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "public mixed-device OMEMO FileManager fallback must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "public mixed-device OMEMO FileManager fallback must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "public mixed-device OMEMO FileManager fallback must persist successful upload as complete");
        } catch (Error e) {
            fail_if(true, @"public mixed-device OMEMO FileManager fallback proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_private_muc_readiness_lifecycle_boundaries() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-omemo-private-muc-prefetch-privacy-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        Dino.StreamInteractor? fixture_interactor = null;
        Account? fixture_account = null;

        // Keep this race proof on the legacy request that it deliberately
        // holds. The process-wide test default is restored in finally.
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(false);
        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED(
                    "private MUC prefetch privacy proof requires libomemo context");
            }
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path,
                "omemo-private-muc-prefetch-privacy-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests(
                (!) dino_db);
            fixture_interactor = stream_interactor;
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Account(new Jid("alice@example.test"),
                "secret");
            account.persist((!) dino_db);
            fixture_account = account;
            var room_jid = new Jid(
                "private-room@conference.example.test");
            var bob_jid = new Jid("bob@example.test");
            var persisted_conversation = new Conversation(room_jid, account,
                Conversation.Type.GROUPCHAT);
            persisted_conversation.nickname = "alice";
            persisted_conversation.encryption = Encryption.OMEMO;
            persisted_conversation.send_typing = Conversation.Setting.OFF;
            persisted_conversation.send_marker = Conversation.Setting.OFF;
            persisted_conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            install_identity((!) omemo_db, account, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(
                stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Account,
                Dino.Plugins.Omemo.OmemoEncryptor>(Account.hash_func,
                    Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(
                account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager omemo_manager =
                Dino.Plugins.Omemo.Manager.start(stream_interactor,
                    (!) omemo_db, trust_manager, encryptors);

            var account_omemo_module =
                new Dino.Plugins.Omemo.StreamModule(alice_store);
            ulong initialize_handler = stream_interactor.module_manager
                .initialize_account_modules.connect(
                    (initialized_account, modules) => {
                        if (initialized_account.equals(account)) {
                            modules.add(account_omemo_module);
                        }
                    });
            stream_interactor.module_manager.initialize(account);
            SignalHandler.disconnect(stream_interactor.module_manager,
                initialize_handler);
            stream_interactor.account_added(account);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(
                stream_interactor, account, alice_store, false,
                account_omemo_module);
            account_omemo_module.attach(stream);
            attach_private_muc_modules_for_tests(stream_interactor, account,
                stream, room_jid, "alice", false);

            bool room_is_private = true;
            bool self_presence_sent = false;
            string room_occupant = room_jid.bare_jid.to_string() + "/alice";
            StanzaNode self_presence =
                build_private_muc_self_presence_for_tests(room_jid, "alice",
                    account.full_jid);
            ulong room_responder = stream.wrote_node.connect((outgoing) => {
                if (outgoing.name == "presence" &&
                        outgoing.get_attribute("type") !=
                            Xmpp.Presence.Stanza.TYPE_UNAVAILABLE &&
                        outgoing.get_attribute("to") == room_occupant) {
                    if (!self_presence_sent) {
                        self_presence_sent = true;
                        stream.emit_presence(self_presence);
                    }
                    return;
                }
                if (outgoing.name != "iq" ||
                        outgoing.get_attribute("type") !=
                            Xmpp.Iq.Stanza.TYPE_GET ||
                        outgoing.get_attribute("to") !=
                            room_jid.bare_jid.to_string()) return;

                StanzaNode? disco = outgoing.get_subnode("query",
                    NS_DISCO_INFO);
                if (disco != null) {
                    stream.emit_iq_result(room_is_private
                        ? build_private_muc_room_info_result_for_request(
                            outgoing, room_jid)
                        : build_public_muc_room_info_result_for_request(
                            outgoing, room_jid));
                    return;
                }

                StanzaNode? admin_query = outgoing.get_subnode("query",
                    NS_MUC_ADMIN);
                if (admin_query == null) return;
                StanzaNode? item = ((!) admin_query).get_subnode("item",
                    NS_MUC_ADMIN);
                if (item == null) return;
                string affiliation = ((!) item).get_attribute(
                    "affiliation") ?? "";
                Gee.List<Jid> members = affiliation == "member"
                    ? member_list(account.bare_jid, bob_jid)
                    : member_list();
                stream.emit_iq_result(
                    build_muc_affiliation_result_for_request(outgoing,
                        room_jid, affiliation, members));
            });

            Dino.MucManager? maybe_muc_manager = stream_interactor.get_module<
                Dino.MucManager>(Dino.MucManager.IDENTITY);
            if (maybe_muc_manager == null) {
                throw new IOError.FAILED(
                    "private MUC prefetch privacy proof requires MucManager");
            }
            Dino.MucManager muc_manager = (!) maybe_muc_manager;

            Xmpp.Xep.Muc.JoinResult? joined = null;
            var join_loop = new MainLoop();
            bool join_timed_out = false;
            uint join_timeout_id = 0;
            join_timeout_id = Timeout.add_seconds(5, () => {
                join_timed_out = true;
                join_timeout_id = 0;
                join_loop.quit();
                return Source.REMOVE;
            });
            muc_manager.join.begin(account, room_jid, "alice", null, true,
                null, false, false,
                (obj, res) => {
                    joined = muc_manager.join.end(res);
                    if (join_timeout_id != 0) {
                        Source.remove(join_timeout_id);
                        join_timeout_id = 0;
                    }
                    join_loop.quit();
                });
            join_loop.run();
            if (join_timeout_id != 0) Source.remove(join_timeout_id);
            if (join_timed_out || joined == null || ((!) joined).nick == null) {
                throw new IOError.TIMED_OUT(
                    "private MUC prefetch privacy proof join did not complete");
            }
            drain_pending_events();

            if (!muc_manager.has_live_private_room_features(account,
                    room_jid) ||
                    !muc_manager.has_complete_private_muc_affiliation_snapshot(
                        account, room_jid)) {
                throw new IOError.FAILED(
                    "private MUC prefetch privacy proof requires a verified live private-room snapshot");
            }
            Gee.List<Jid>? snapshot =
                muc_manager.get_private_muc_member_affiliation_snapshot(
                    account, room_jid);
            if (snapshot == null || ((!) snapshot).size != 2) {
                throw new IOError.FAILED(
                    "private MUC prefetch privacy proof requires self and Bob in the verified snapshot");
            }
            assert_member_list_contains_bare(snapshot, account.bare_jid,
                "private MUC prefetch privacy proof must retain self");
            assert_member_list_contains_bare(snapshot, bob_jid,
                "private MUC prefetch privacy proof must include Bob");

            Dino.ConversationManager? conversation_manager =
                stream_interactor.get_module<Dino.ConversationManager>(
                    Dino.ConversationManager.IDENTITY);
            if (conversation_manager == null) {
                throw new IOError.FAILED(
                    "private MUC prefetch privacy proof requires ConversationManager");
            }
            Conversation? maybe_conversation = ((!) conversation_manager)
                .get_conversation(room_jid, account,
                    Conversation.Type.GROUPCHAT);
            if (maybe_conversation == null) {
                throw new IOError.FAILED(
                    "private MUC prefetch privacy proof requires the joined conversation");
            }
            Conversation conversation = (!) maybe_conversation;

            Xmpp.Xep.Muc.Module? maybe_muc_module = stream.get_module<
                Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
            if (maybe_muc_module == null) {
                throw new IOError.FAILED(
                    "private MUC prefetch privacy proof requires the MUC stream module");
            }
            Xmpp.Xep.Muc.Module muc_module = (!) maybe_muc_module;

            bool held_request_seen = false;
            string? transition_failure = null;
            stream.hold_legacy_devicelist_for = bob_jid;
            ulong held_handler = stream.legacy_devicelist_held.connect(
                (held_request) => {
                    if (held_request_seen) return;
                    held_request_seen = true;
                    Idle.add(() => {
                        room_is_private = false;
                        muc_module.query_room_info.begin(stream, room_jid,
                            (obj, res) => {
                                bool refreshed =
                                    muc_module.query_room_info.end(res);
                                if (!refreshed) {
                                    transition_failure =
                                        "public room-info transition was not accepted";
                                } else if (muc_manager
                                        .has_live_private_room_features(
                                            account, room_jid)) {
                                    transition_failure =
                                        "public room-info transition left private-room proof live";
                                }

                                StanzaNode? request = stream
                                    .take_held_legacy_devicelist_request();
                                if (request == null) {
                                    transition_failure =
                                        "held Bob device-list request disappeared";
                                } else {
                                    stream.emit_iq_result(
                                        build_legacy_devicelist_result_for_request(
                                            (!) request, bob_jid, 47001));
                                }
                            });
                        return Source.REMOVE;
                    });
                });

            Dino.Plugins.Omemo.PrivateMucKeyReadinessResult? readiness = null;
            Dino.Plugins.Omemo.PrivateMucKeyReadinessResult?
                coalesced_readiness = null;
            int readiness_completed = 0;
            var readiness_loop = new MainLoop();
            bool readiness_timed_out = false;
            uint readiness_timeout_id = 0;
            readiness_timeout_id = Timeout.add_seconds(8, () => {
                readiness_timed_out = true;
                readiness_timeout_id = 0;
                readiness_loop.quit();
                return Source.REMOVE;
            });
            omemo_manager.ensure_private_muc_keys_for_conversation.begin(
                conversation, (obj, res) => {
                    readiness = omemo_manager
                        .ensure_private_muc_keys_for_conversation.end(res);
                    readiness_completed++;
                    if (readiness_completed == 2 &&
                            readiness_timeout_id != 0) {
                        Source.remove(readiness_timeout_id);
                        readiness_timeout_id = 0;
                        readiness_loop.quit();
                    }
                });
            omemo_manager.ensure_private_muc_keys_for_conversation.begin(
                conversation, (obj, res) => {
                    coalesced_readiness = omemo_manager
                        .ensure_private_muc_keys_for_conversation.end(res);
                    readiness_completed++;
                    if (readiness_completed == 2 &&
                            readiness_timeout_id != 0) {
                        Source.remove(readiness_timeout_id);
                        readiness_timeout_id = 0;
                        readiness_loop.quit();
                    }
                });
            readiness_loop.run();
            if (readiness_timeout_id != 0) {
                Source.remove(readiness_timeout_id);
            }
            SignalHandler.disconnect(stream, held_handler);

            if (readiness_timed_out) {
                throw new IOError.TIMED_OUT(
                    "private MUC device-list prefetch did not finish");
            }
            if (!held_request_seen) {
                throw new IOError.FAILED(
                    "private MUC readiness did not query Bob's legacy device list");
            }
            if (stream.legacy_devicelist_request_count != 1) {
                throw new IOError.FAILED(
                    "parallel private MUC readiness callers must share exactly one fresh device-list request");
            }
            if (transition_failure != null) {
                throw new IOError.FAILED((!) transition_failure);
            }
            if (readiness == null || ((!) readiness).status !=
                    Dino.Plugins.Omemo.PrivateMucKeyReadinessStatus.NOT_PRIVATE) {
                throw new IOError.FAILED(
                    "privacy transition during device prefetch must return NOT_PRIVATE, never READY");
            }
            if (coalesced_readiness == null ||
                    ((!) coalesced_readiness).status !=
                        Dino.Plugins.Omemo.PrivateMucKeyReadinessStatus.NOT_PRIVATE) {
                throw new IOError.FAILED(
                    "a coalesced readiness waiter must receive the same privacy-transition result");
            }

            // Restore the same room and member set, then start a device pass
            // that is superseded by another private room-info generation.
            // Member equality alone must never let the old pass become READY.
            room_is_private = true;
            bool restore_done = false;
            bool restore_ok = false;
            var restore_loop = new MainLoop();
            uint restore_timeout_id = Timeout.add_seconds(5, () => {
                restore_loop.quit();
                return Source.REMOVE;
            });
            muc_module.query_room_info.begin(stream, room_jid,
                (obj, res) => {
                    restore_ok = muc_module.query_room_info.end(res);
                    restore_done = true;
                    if (restore_timeout_id != 0) {
                        Source.remove(restore_timeout_id);
                        restore_timeout_id = 0;
                    }
                    restore_loop.quit();
                });
            restore_loop.run();
            if (restore_timeout_id != 0) Source.remove(restore_timeout_id);
            drain_pending_events();
            if (!restore_done || !restore_ok ||
                    !muc_manager.has_live_private_room_features(account,
                        room_jid) ||
                    !muc_manager.has_complete_private_muc_affiliation_snapshot(
                        account, room_jid)) {
                throw new IOError.FAILED(
                    "private MUC lifecycle proof could not restore the verified private snapshot");
            }

            uint revision_before_boundary = muc_manager
                .get_private_muc_affiliation_snapshot_revision(account,
                    room_jid);
            int requests_before_boundary =
                stream.legacy_devicelist_request_count;
            bool boundary_started = false;
            bool boundary_completed = false;
            string? boundary_failure = null;
            uint boundary_poll_id = 0;
            stream.hold_legacy_devicelist_for = bob_jid;
            ulong boundary_held_handler = stream.legacy_devicelist_held.connect(
                (held_request) => {
                    if (boundary_started) return;
                    boundary_started = true;
                    Idle.add(() => {
                        muc_module.query_room_info.begin(stream, room_jid,
                            (obj, res) => {
                                if (!muc_module.query_room_info.end(res)) {
                                    boundary_failure =
                                        "same-private room-info refresh failed";
                                    StanzaNode? failed_request = stream
                                        .take_held_legacy_devicelist_request();
                                    if (failed_request != null) {
                                        stream.emit_iq_result(
                                            build_legacy_devicelist_result_for_request(
                                                (!) failed_request, bob_jid,
                                                47002));
                                    }
                                    return;
                                }
                                boundary_poll_id = Timeout.add(10, () => {
                                    uint revision = muc_manager
                                        .get_private_muc_affiliation_snapshot_revision(
                                            account, room_jid);
                                    if (revision <= revision_before_boundary ||
                                            !muc_manager
                                                .has_complete_private_muc_affiliation_snapshot(
                                                    account, room_jid)) {
                                        return Source.CONTINUE;
                                    }
                                    boundary_completed = true;
                                    StanzaNode? request = stream
                                        .take_held_legacy_devicelist_request();
                                    if (request == null) {
                                        boundary_failure =
                                            "same-private refresh lost the held device-list request";
                                    } else {
                                        stream.emit_iq_result(
                                            build_legacy_devicelist_result_for_request(
                                                (!) request, bob_jid,
                                                47002));
                                    }
                                    boundary_poll_id = 0;
                                    return Source.REMOVE;
                                });
                            });
                        return Source.REMOVE;
                    });
                });

            Dino.Plugins.Omemo.PrivateMucKeyReadinessResult?
                stale_readiness = null;
            var stale_loop = new MainLoop();
            bool stale_timed_out = false;
            uint stale_timeout_id = Timeout.add_seconds(8, () => {
                stale_timed_out = true;
                stale_loop.quit();
                return Source.REMOVE;
            });
            omemo_manager.ensure_private_muc_keys_for_conversation.begin(
                conversation, (obj, res) => {
                    stale_readiness = omemo_manager
                        .ensure_private_muc_keys_for_conversation.end(res);
                    if (stale_timeout_id != 0) {
                        Source.remove(stale_timeout_id);
                        stale_timeout_id = 0;
                    }
                    stale_loop.quit();
                });
            stale_loop.run();
            if (stale_timeout_id != 0) Source.remove(stale_timeout_id);
            if (boundary_poll_id != 0) Source.remove(boundary_poll_id);
            SignalHandler.disconnect(stream, boundary_held_handler);
            if (stale_timed_out || !boundary_started ||
                    !boundary_completed || boundary_failure != null) {
                throw new IOError.FAILED(boundary_failure ??
                    "same-private snapshot boundary did not complete");
            }
            if (stream.legacy_devicelist_request_count !=
                    requests_before_boundary + 1) {
                throw new IOError.FAILED(
                    "the pre-boundary readiness pass must issue exactly one device-list request");
            }
            if (stale_readiness == null || ((!) stale_readiness).status !=
                    Dino.Plugins.Omemo.PrivateMucKeyReadinessStatus.STALE) {
                throw new IOError.FAILED(
                    "a private-to-private snapshot revision must stale the older device pass even when members are unchanged");
            }

            int requests_before_fresh = stream.legacy_devicelist_request_count;
            ulong fresh_held_handler = stream.legacy_devicelist_held.connect(
                (held_request) => {
                    Idle.add(() => {
                        StanzaNode? request = stream
                            .take_held_legacy_devicelist_request();
                        if (request != null) {
                            stream.emit_iq_result(
                                build_legacy_devicelist_result_for_request(
                                    (!) request, bob_jid, 47003));
                        }
                        return Source.REMOVE;
                    });
                });
            Dino.Plugins.Omemo.PrivateMucKeyReadinessResult?
                fresh_readiness = null;
            var fresh_loop = new MainLoop();
            bool fresh_timed_out = false;
            uint fresh_timeout_id = Timeout.add_seconds(8, () => {
                fresh_timed_out = true;
                fresh_loop.quit();
                return Source.REMOVE;
            });
            omemo_manager.ensure_private_muc_keys_for_conversation.begin(
                conversation, (obj, res) => {
                    fresh_readiness = omemo_manager
                        .ensure_private_muc_keys_for_conversation.end(res);
                    if (fresh_timeout_id != 0) {
                        Source.remove(fresh_timeout_id);
                        fresh_timeout_id = 0;
                    }
                    fresh_loop.quit();
                });
            fresh_loop.run();
            if (fresh_timeout_id != 0) Source.remove(fresh_timeout_id);
            SignalHandler.disconnect(stream, fresh_held_handler);
            if (fresh_timed_out || fresh_readiness == null ||
                    ((!) fresh_readiness).status !=
                        Dino.Plugins.Omemo.PrivateMucKeyReadinessStatus.READY ||
                    stream.legacy_devicelist_request_count !=
                        requests_before_fresh + 1) {
                throw new IOError.FAILED(
                    "a fresh post-boundary device pass must become READY exactly once");
            }

            // Empty lists produce MEMBER_UNSUPPORTED after the bounded retry.
            // Inject a non-empty notification before that pass has installed
            // its retry watch, then let later empty IQ results settle it as
            // unsupported. The availability generation must preserve this
            // early event and wake exactly one fresh readiness pass.
            stream.hold_legacy_devicelist_for = null;
            var newly_advertised_devices = new ArrayList<int32>();
            newly_advertised_devices.add(47004);
            bool availability_injected_during_probe = false;
            ulong availability_probe_handler = stream.wrote_node.connect(
                (outgoing) => {
                    if (availability_injected_during_probe ||
                            outgoing.name != "iq" ||
                            outgoing.get_attribute("type") !=
                                Xmpp.Iq.Stanza.TYPE_GET ||
                            outgoing.get_attribute("to") !=
                                bob_jid.bare_jid.to_string()) return;
                    StanzaNode? pubsub = outgoing.get_subnode("pubsub",
                        Xmpp.Xep.Pubsub.NS_URI);
                    StanzaNode? items = pubsub != null
                        ? ((!) pubsub).get_subnode("items",
                            Xmpp.Xep.Pubsub.NS_URI) : null;
                    if (items == null || ((!) items).get_attribute("node") !=
                            NS_OMEMO_LEGACY + ".devicelist") return;
                    availability_injected_during_probe = true;
                    Idle.add(() => {
                        account_omemo_module.device_list_loaded(bob_jid,
                            newly_advertised_devices);
                        return Source.REMOVE;
                    });
                });
            Dino.Plugins.Omemo.PrivateMucKeyReadinessResult?
                unsupported_readiness = null;
            var unsupported_loop = new MainLoop();
            bool unsupported_timed_out = false;
            uint unsupported_timeout_id = Timeout.add_seconds(8, () => {
                unsupported_timed_out = true;
                unsupported_loop.quit();
                return Source.REMOVE;
            });
            omemo_manager.ensure_private_muc_keys_for_conversation.begin(
                conversation, (obj, res) => {
                    unsupported_readiness = omemo_manager
                        .ensure_private_muc_keys_for_conversation.end(res);
                    if (unsupported_timeout_id != 0) {
                        Source.remove(unsupported_timeout_id);
                        unsupported_timeout_id = 0;
                    }
                    unsupported_loop.quit();
                });
            unsupported_loop.run();
            if (unsupported_timeout_id != 0) {
                Source.remove(unsupported_timeout_id);
            }
            SignalHandler.disconnect(stream, availability_probe_handler);
            if (unsupported_timed_out || unsupported_readiness == null ||
                    !availability_injected_during_probe ||
                    ((!) unsupported_readiness).status !=
                        Dino.Plugins.Omemo.PrivateMucKeyReadinessStatus.MEMBER_UNSUPPORTED ||
                    ((!) unsupported_readiness).member == null ||
                    !((!) ((!) unsupported_readiness).member).equals_bare(
                        bob_jid)) {
                throw new IOError.FAILED(
                    "empty Bob device lists must settle as MEMBER_UNSUPPORTED");
            }

            int readiness_change_count = 0;
            Dino.Plugins.Omemo.PrivateMucKeyReadinessResult?
                recovered_readiness = null;
            var recovery_loop = new MainLoop();
            bool recovery_timed_out = false;
            uint recovery_timeout_id = Timeout.add_seconds(8, () => {
                recovery_timed_out = true;
                recovery_loop.quit();
                return Source.REMOVE;
            });
            stream.hold_legacy_devicelist_for = bob_jid;
            ulong recovery_held_handler = stream.legacy_devicelist_held.connect(
                (held_request) => {
                    Idle.add(() => {
                        StanzaNode? request = stream
                            .take_held_legacy_devicelist_request();
                        if (request != null) {
                            stream.emit_iq_result(
                                build_legacy_devicelist_result_for_request(
                                    (!) request, bob_jid, 47004));
                        }
                        return Source.REMOVE;
                    });
                });
            ulong readiness_change_handler = omemo_manager
                .private_muc_readiness_changed.connect(
                    (changed_account, changed_room) => {
                        if (!changed_account.equals(account) ||
                                !changed_room.equals_bare(room_jid)) return;
                        readiness_change_count++;
                        if (readiness_change_count != 1) return;
                        omemo_manager
                            .ensure_private_muc_keys_for_conversation.begin(
                                conversation, (obj, res) => {
                                    recovered_readiness = omemo_manager
                                        .ensure_private_muc_keys_for_conversation
                                            .end(res);
                                    if (recovery_timeout_id != 0) {
                                        Source.remove(recovery_timeout_id);
                                        recovery_timeout_id = 0;
                                    }
                                    recovery_loop.quit();
                                });
                    });
            recovery_loop.run();
            if (recovery_timeout_id != 0) Source.remove(recovery_timeout_id);
            SignalHandler.disconnect(stream, recovery_held_handler);
            if (recovery_timed_out || readiness_change_count != 1 ||
                    recovered_readiness == null ||
                    ((!) recovered_readiness).status !=
                        Dino.Plugins.Omemo.PrivateMucKeyReadinessStatus.READY) {
                throw new IOError.FAILED(
                    "a newly advertised Bob device must wake one fresh private-MUC readiness pass to READY");
            }
            account_omemo_module.device_list_loaded(bob_jid,
                newly_advertised_devices);
            drain_pending_events();
            if (readiness_change_count != 1) {
                throw new IOError.FAILED(
                    "the member-device readiness watch must be one-shot");
            }
            SignalHandler.disconnect(omemo_manager,
                readiness_change_handler);

            SignalHandler.disconnect(stream, room_responder);
        } catch (Error e) {
            fail_if(true,
                @"private MUC prefetch privacy proof failed: $(e.message)");
        } finally {
            Dino.Plugins.Omemo.TrustManager
                .set_omemo2_runtime_test_override(true);
            if (fixture_interactor != null) {
                var interactor = (!) fixture_interactor;
                if (fixture_account != null) {
                    var account = (!) fixture_account;
                    // Clear the joined room and pending OMEMO work while
                    // their databases still exist, even after a failed proof.
                    interactor.account_removed(account);
                    interactor.connection_manager
                        .remove_managed_account_for_tests(account);
                    interactor.module_manager.remove(account);
                    fail_if(interactor.get_accounts().contains(account),
                        "closed lifecycle fixture must not retain a connected account for later MUC self-pings");
                }
                var muc_manager = interactor.get_module<Dino.MucManager>(
                    Dino.MucManager.IDENTITY);
                if (muc_manager != null) ((!) muc_manager).shutdown();
            }
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

    private void test_private_muc_file_manager_http_send_without_member_list_fails_before_upload() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-private-muc-file-send-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-unknown-members-omemo.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "private MUC OMEMO FileManager must not upload without known members\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "private MUC OMEMO FileManager send boundary proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-private-muc-filemanager-http-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var room_jid = new Jid("private-room@conference.example.test");
            mark_room_private_in_entity_info((!) dino_db, account, room_jid);
            var persisted_conversation = new Dino.Entities.Conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            persisted_conversation.encryption = Dino.Entities.Encryption.OMEMO;
            persisted_conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 43001, 44001);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors);

            var file_encryption = new Dino.Security.FileEncryption("omemo-private-muc-filemanager-http-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "private MUC OMEMO FileManager boundary proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "private MUC OMEMO FileManager boundary proof requires ConversationManager");
            if (conversation_manager == null) return;
            var conversation = ((!) conversation_manager).get_conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            fail_if(conversation == null,
                "private MUC OMEMO FileManager boundary proof requires the persisted groupchat conversation");
            if (conversation == null) return;

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);
            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "private MUC OMEMO FileManager boundary proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "private MUC OMEMO FileManager boundary proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "private MUC OMEMO FileManager boundary proof must publish a persisted outgoing transfer before failure");
                fail_if(file_transfer.path == null,
                    "private MUC OMEMO FileManager boundary proof must publish a stored outgoing path before failure");
            });

            respond_to_matching_slot_request_when_written(stream, "private-muc-unknown-members-omemo.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer must-not-upload");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            GLib.Test.expect_message(null, GLib.LogLevelFlags.LEVEL_WARNING,
                "*http-files: refusing OMEMO file upload for MUC * without live private-room features");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*send_file: no sender/encryptor available*");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: No sender/encryptor combination available*");
            ((!) manager).send_file.begin(File.new_for_path(input_path), (!) conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-unknown-members-omemo.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();
            GLib.Test.assert_expected_messages();

            fail_if(published_transfer == null,
                "private MUC OMEMO FileManager boundary proof must publish the locally saved transfer before failing");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "private MUC OMEMO FileManager boundary proof must freeze the transfer as OMEMO");
            fail_if(capture.handled,
                "private MUC OMEMO FileManager send without a known member list must not reach the HTTPS PUT endpoint");
            fail_if(find_http_upload_slot_request(stream) != null,
                "private MUC OMEMO FileManager send without a known member list must fail before XEP-0363 slot request");
            fail_if(find_legacy_omemo_message(stream) != null || find_omemo2_message(stream) != null,
                "private MUC OMEMO FileManager send without a known member list must not write an OMEMO payload stanza");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "private MUC OMEMO FileManager send without a known member list must fail before slot, upload or announce phases");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "private MUC OMEMO FileManager send without a known member list must not complete");
            fail_if(file_transfer.state == Dino.Entities.FileTransfer.State.COMPLETE,
                "private MUC OMEMO FileManager send without a known member list must not persist COMPLETE state");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "private MUC OMEMO FileManager send without a known member list must fail before upload");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "private MUC OMEMO FileManager send without a known member list must persist FAILED state");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.FAILED,
                "private MUC OMEMO FileManager send must fail only after local storage publication");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "private MUC OMEMO FileManager send without a known member list must persist the failed upload boundary");
        } catch (Error e) {
            fail_if(true, @"private MUC OMEMO FileManager send boundary proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_private_muc_http_sender_with_incomplete_snapshot_fails_before_upload() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-private-muc-incomplete-snapshot-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");

        Dino.Database? dino_db = null;
        HttpFileSender? sender = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "private MUC OMEMO incomplete-snapshot proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-private-muc-incomplete-snapshot-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var room_jid = new Jid("private-room@conference.example.test");
            var bob_jid = new Jid("bob@example.test");
            var persisted_conversation = new Dino.Entities.Conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            persisted_conversation.encryption = Dino.Entities.Encryption.OMEMO;
            persisted_conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            sender = new HttpFileSender(stream_interactor, (!) dino_db);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);
            attach_private_muc_modules_for_tests(stream_interactor, account, stream, room_jid, "alice");
            var forbidden_affiliations = new HashSet<string>();
            forbidden_affiliations.add("admin");
            Gee.List<Jid>? queried_snapshot =
                query_private_muc_snapshot_for_tests(stream_interactor,
                    account, stream, room_jid,
                    member_list(account.bare_jid, bob_jid), member_list(),
                    member_list(), forbidden_affiliations);
            fail_if(queried_snapshot != null,
                "private MUC OMEMO incomplete-snapshot proof must reject a failed admin affiliation query");

            var muc_manager = stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(muc_manager.has_complete_private_muc_affiliation_snapshot(account, room_jid),
                "private MUC OMEMO incomplete-snapshot proof must not complete member/admin/owner certainty");
            Gee.List<Jid>? snapshot_members = muc_manager.get_private_muc_member_affiliation_snapshot(account, room_jid);
            fail_if(snapshot_members != null,
                "private MUC OMEMO incomplete-snapshot proof must not expose a complete recipient snapshot");

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.encryption = Dino.Entities.Encryption.OMEMO;
            file_transfer.size = 64;

            bool can_send = true;
            var can_send_loop = new MainLoop();
            GLib.Test.expect_message(null, GLib.LogLevelFlags.LEVEL_WARNING,
                "*http-files: refusing OMEMO file upload for private MUC * without a complete member/admin/owner list");
            ((!) sender).can_send.begin(persisted_conversation, file_transfer, (obj, res) => {
                can_send = ((!) sender).can_send.end(res);
                can_send_loop.quit();
            });
            can_send_loop.run();
            GLib.Test.assert_expected_messages();

            fail_if(can_send,
                "private MUC OMEMO HTTP sender must reject incomplete affiliation snapshots before upload");
            fail_if(find_http_upload_slot_request(stream) != null,
                "private MUC OMEMO incomplete-snapshot proof must not request an upload slot");
            fail_if(find_legacy_omemo_message(stream) != null || find_omemo2_message(stream) != null,
                "private MUC OMEMO incomplete-snapshot proof must not write an OMEMO payload stanza");
        } catch (Error e) {
            fail_if(true, @"private MUC OMEMO incomplete-snapshot proof failed: $(e.message)");
        } finally {
            if (sender != null) ((!) sender).shutdown();
            if (dino_db != null) ((!) dino_db).close();
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_private_muc_file_manager_http_send_with_forbidden_admin_owner_snapshot_fails_before_upload() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-private-muc-forbidden-snapshot-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-forbidden-snapshot-omemo.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "private MUC OMEMO FileManager must not upload after forbidden admin-owner affiliation snapshot\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "private MUC OMEMO forbidden-snapshot proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-private-muc-forbidden-snapshot-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var room_jid = new Jid("private-room@conference.example.test");
            mark_room_private_in_entity_info((!) dino_db, account, room_jid);
            var persisted_conversation = new Dino.Entities.Conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            persisted_conversation.encryption = Dino.Entities.Encryption.OMEMO;
            persisted_conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 43201, 44201);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 43202, 44202);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors);

            var file_encryption = new Dino.Security.FileEncryption("omemo-private-muc-forbidden-snapshot-filemanager-http-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "private MUC OMEMO forbidden-snapshot proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "private MUC OMEMO forbidden-snapshot proof requires ConversationManager");
            if (conversation_manager == null) return;
            var conversation = ((!) conversation_manager).get_conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            fail_if(conversation == null,
                "private MUC OMEMO forbidden-snapshot proof requires the persisted groupchat conversation");
            if (conversation == null) return;

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);
            attach_private_muc_modules_for_tests(stream_interactor, account, stream, room_jid, "alice");
            var forbidden_affiliations = new HashSet<string>();
            forbidden_affiliations.add("admin");
            forbidden_affiliations.add("owner");
            Gee.List<Jid>? queried_snapshot =
                query_private_muc_snapshot_for_tests(stream_interactor,
                    account, stream, room_jid,
                    member_list(account.bare_jid,
                        bob_account.bare_jid), member_list(), member_list(),
                    forbidden_affiliations);
            fail_if(queried_snapshot != null,
                "private MUC OMEMO forbidden-snapshot proof must fail the aggregate when admin and owner queries are forbidden");
            drain_pending_events();

            var muc_manager = stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(!muc_manager.has_live_private_room_features(account, room_jid),
                "private MUC OMEMO forbidden-snapshot proof must keep live private-room features");
            fail_if(muc_manager.has_complete_private_muc_affiliation_snapshot(account, room_jid),
                "private MUC OMEMO forbidden-snapshot proof must not mark member/admin/owner certainty complete after forbidden admin-owner IQs");
            Gee.List<Jid>? snapshot_members = muc_manager.get_private_muc_member_affiliation_snapshot(account, room_jid);
            fail_if(snapshot_members != null,
                "private MUC OMEMO forbidden-snapshot proof must not expose the partial member result as a complete recipient snapshot");

            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "private MUC OMEMO forbidden-snapshot proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "private MUC OMEMO forbidden-snapshot proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "private MUC OMEMO forbidden-snapshot proof must publish a persisted outgoing transfer before failure");
                fail_if(file_transfer.path == null,
                    "private MUC OMEMO forbidden-snapshot proof must publish a stored outgoing path before failure");
            });

            respond_to_matching_slot_request_when_written(stream, "private-muc-forbidden-snapshot-omemo.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer must-not-upload");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            GLib.Test.expect_message(null, GLib.LogLevelFlags.LEVEL_WARNING,
                "*http-files: refusing OMEMO file upload for private MUC * without a complete member/admin/owner list");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*send_file: no sender/encryptor available*");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: No sender/encryptor combination available*");
            ((!) manager).send_file.begin(File.new_for_path(input_path), (!) conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-forbidden-snapshot-omemo.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });
            send_loop.run();
            drain_pending_events();
            GLib.Test.assert_expected_messages();

            fail_if(published_transfer == null,
                "private MUC OMEMO forbidden-snapshot proof must publish the locally saved transfer before failing");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "private MUC OMEMO forbidden-snapshot proof must freeze the transfer as OMEMO");
            fail_if(capture.handled,
                "private MUC OMEMO forbidden-snapshot proof must not reach the HTTPS PUT endpoint");
            fail_if(find_http_upload_slot_request(stream) != null,
                "private MUC OMEMO forbidden-snapshot proof must fail before XEP-0363 slot request");
            fail_if(find_legacy_omemo_message(stream) != null || find_omemo2_message(stream) != null,
                "private MUC OMEMO forbidden-snapshot proof must not write an OMEMO payload stanza");
            assert_no_message_stanzas(stream,
                "private MUC OMEMO forbidden-snapshot proof must not write any message stanza");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "private MUC OMEMO forbidden-snapshot proof must fail before slot, upload or announce phases");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "private MUC OMEMO forbidden-snapshot proof must not complete");
            fail_if(file_transfer.state == Dino.Entities.FileTransfer.State.COMPLETE,
                "private MUC OMEMO forbidden-snapshot proof must not persist COMPLETE state");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "private MUC OMEMO forbidden-snapshot proof must fail before upload");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "private MUC OMEMO forbidden-snapshot proof must persist FAILED state");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.FAILED,
                "private MUC OMEMO forbidden-snapshot proof must fail only after local storage publication");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "private MUC OMEMO forbidden-snapshot proof must persist the failed upload boundary");
        } catch (Error e) {
            fail_if(true, @"private MUC OMEMO forbidden-snapshot proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_private_muc_file_manager_http_send_with_self_only_snapshot_fails_before_upload() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-private-muc-self-only-snapshot-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-self-only-omemo.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "private MUC OMEMO FileManager must not upload a self-only room\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "private MUC OMEMO self-only proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-private-muc-self-only-snapshot-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var room_jid = new Jid("private-room@conference.example.test");
            var persisted_conversation = new Dino.Entities.Conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            persisted_conversation.encryption = Dino.Entities.Encryption.OMEMO;
            persisted_conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 43101, 44101);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors);

            var file_encryption = new Dino.Security.FileEncryption("omemo-private-muc-self-only-filemanager-http-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "private MUC OMEMO self-only proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "private MUC OMEMO self-only proof requires ConversationManager");
            if (conversation_manager == null) return;
            var conversation = ((!) conversation_manager).get_conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            fail_if(conversation == null,
                "private MUC OMEMO self-only proof requires the persisted groupchat conversation");
            if (conversation == null) return;

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);
            attach_private_muc_modules_for_tests(stream_interactor, account, stream, room_jid, "alice");
            Gee.List<Jid>? queried_members = query_private_muc_snapshot_for_tests(stream_interactor, account, stream, room_jid,
                member_list(account.bare_jid),
                member_list(),
                member_list());
            fail_if(queried_members == null || ((!) queried_members).size != 1,
                "private MUC OMEMO self-only proof must seed a complete self-only snapshot");

            var muc_manager = stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(!muc_manager.has_complete_private_muc_affiliation_snapshot(account, room_jid),
                "private MUC OMEMO self-only proof must complete member/admin/owner certainty");
            Gee.List<Jid>? snapshot_members = muc_manager.get_private_muc_member_affiliation_snapshot(account, room_jid);
            assert_member_list_contains_bare(snapshot_members, account.bare_jid,
                "private MUC OMEMO self-only proof must keep the self JID in the raw snapshot");
            fail_if(((!) snapshot_members).size != 1,
                "private MUC OMEMO self-only proof must not include any non-self recipient");

            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "private MUC OMEMO self-only proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "private MUC OMEMO self-only proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "private MUC OMEMO self-only proof must publish a persisted outgoing transfer before failure");
                fail_if(file_transfer.path == null,
                    "private MUC OMEMO self-only proof must publish a stored outgoing path before failure");
            });

            respond_to_matching_slot_request_when_written(stream, "private-muc-self-only-omemo.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer must-not-upload");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            GLib.Test.expect_message(null, GLib.LogLevelFlags.LEVEL_WARNING,
                "*http-files: refusing OMEMO file upload for private MUC * without non-self members");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*send_file: no sender/encryptor available*");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: No sender/encryptor combination available*");
            ((!) manager).send_file.begin(File.new_for_path(input_path), (!) conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-self-only-omemo.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });
            send_loop.run();
            drain_pending_events();
            GLib.Test.assert_expected_messages();

            fail_if(published_transfer == null,
                "private MUC OMEMO self-only proof must publish the locally saved transfer before failing");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "private MUC OMEMO self-only proof must freeze the transfer as OMEMO");
            fail_if(capture.handled,
                "private MUC OMEMO self-only proof must not reach the HTTPS PUT endpoint");
            fail_if(find_http_upload_slot_request(stream) != null,
                "private MUC OMEMO self-only proof must not request an upload slot");
            fail_if(find_legacy_omemo_message(stream) != null || find_omemo2_message(stream) != null,
                "private MUC OMEMO self-only proof must not write an OMEMO payload stanza");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.ANNOUNCING),
                "private MUC OMEMO self-only proof must fail before slot, upload or announce phases");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "private MUC OMEMO self-only proof must not complete");
            fail_if(file_transfer.state == Dino.Entities.FileTransfer.State.COMPLETE,
                "private MUC OMEMO self-only proof must not persist COMPLETE state");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "private MUC OMEMO self-only proof must fail before upload");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "private MUC OMEMO self-only proof must persist FAILED state");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.FAILED,
                "private MUC OMEMO self-only proof must fail only after local storage publication");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "private MUC OMEMO self-only proof must persist the failed upload boundary");
        } catch (Error e) {
            fail_if(true, @"private MUC OMEMO self-only proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_private_muc_file_manager_http_send_with_known_members_uses_real_legacy_session_body_only() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-private-muc-known-members-file-send-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-known-members-omemo.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "private MUC FileManager to real OMEMO manager HTTPS payload with known members\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "private MUC OMEMO FileManager send proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-private-muc-known-members-filemanager-http-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var carol_account = new Dino.Entities.Account(new Jid("carol@example.test"), "secret");
            carol_account.persist((!) dino_db);
            var room_jid = new Jid("private-room@conference.example.test");
            mark_room_private_in_entity_info((!) dino_db, account, room_jid);
            var persisted_conversation = new Dino.Entities.Conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            persisted_conversation.encryption = Dino.Entities.Encryption.OMEMO;
            persisted_conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            Store carol_store = setup_test_store_context(context);

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 45001, 46001);
            prepare_pre_key_session(context, alice_store, carol_account.bare_jid, carol_store, 45002, 46002);
            prepare_pre_key_session(context, alice_store, account.bare_jid, alice_other_store, 45003, 46003);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            int carol_identity_id = install_identity((!) omemo_db, carol_account, carol_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, carol_account.bare_jid, carol_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);
            add_trusted_omemo1_device((!) omemo_db, carol_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors);

            var file_encryption = new Dino.Security.FileEncryption("omemo-private-muc-known-members-filemanager-http-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "private MUC OMEMO FileManager send proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "private MUC OMEMO FileManager send proof requires ConversationManager");
            if (conversation_manager == null) return;
            var conversation = ((!) conversation_manager).get_conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            fail_if(conversation == null,
                "private MUC OMEMO FileManager send proof requires the persisted groupchat conversation");
            if (conversation == null) return;

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store);
            attach_private_muc_modules_for_tests(stream_interactor, account, stream, room_jid, "alice");
            Gee.List<Jid>? queried_members = query_private_muc_snapshot_for_tests(stream_interactor, account, stream, room_jid,
                member_list(account.bare_jid, bob_account.bare_jid),
                member_list(carol_account.bare_jid),
                member_list(bob_account.bare_jid));
            fail_if(queried_members == null || ((!) queried_members).size != 3,
                "private MUC OMEMO FileManager send proof must query the complete member/admin/owner affiliation snapshot");
            drain_pending_events();
            var muc_manager = stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(!muc_manager.has_complete_private_muc_affiliation_snapshot(account, room_jid),
                "private MUC OMEMO FileManager send proof must complete the member/admin/owner snapshot");
            Gee.List<Jid>? snapshot_members = muc_manager.get_private_muc_member_affiliation_snapshot(account, room_jid);
            assert_member_list_contains_bare(snapshot_members, bob_account.bare_jid,
                "private MUC OMEMO FileManager send proof must include Bob in the complete snapshot");
            assert_member_list_contains_bare(snapshot_members, carol_account.bare_jid,
                "private MUC OMEMO FileManager send proof must include Carol in the complete snapshot");

            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "private MUC OMEMO FileManager send proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "private MUC OMEMO FileManager send proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "private MUC OMEMO FileManager send proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "private MUC OMEMO FileManager send proof must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(stream, "private-muc-known-members-omemo.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-private-muc-omemo");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), (!) conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-known-members-omemo.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "private MUC OMEMO FileManager send proof must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "private MUC OMEMO FileManager send proof must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "private MUC OMEMO FileManager send proof must select the real HTTP sender");
            fail_if(!capture.handled,
                "private MUC OMEMO FileManager send proof must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method,
                "private MUC OMEMO FileManager send proof must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "private MUC OMEMO FileManager send proof must set the upload content type");
            fail_if_not_eq_str("Bearer real-private-muc-omemo", capture.authorization ?? "",
                "private MUC OMEMO FileManager send proof must forward allowed slot headers");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "private MUC OMEMO direct HTTP-GCM upload must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "private MUC OMEMO direct HTTP-GCM upload body must include the 16-byte tag");
            fail_if(bytes_equal(payload, capture.body),
                "private MUC OMEMO direct HTTP-GCM upload must not upload plaintext bytes");

            StanzaNode? omemo_message = find_legacy_omemo_message(stream);
            fail_if(omemo_message == null,
                "private MUC OMEMO FileManager send proof must write a real legacy OMEMO payload stanza");
            if (omemo_message == null) return;
            fail_if(find_omemo2_message(stream) != null,
                "private MUC OMEMO1 FileManager send proof must not use OMEMO2/SCE in the legacy-only setup");
            fail_if(((!) omemo_message).get_attribute("to") != room_jid.to_string(),
                "private MUC OMEMO FileManager send proof must address the encrypted body URL to the room");
            fail_if(((!) omemo_message).get_attribute("type") != MessageStanza.TYPE_GROUPCHAT,
                "private MUC OMEMO FileManager send proof must announce the encrypted body URL as a groupchat stanza");

            StanzaNode? encrypted_node = ((!) omemo_message).get_subnode("encrypted", NS_OMEMO_LEGACY);
            fail_if(encrypted_node == null,
                "private MUC OMEMO FileManager send proof must contain the legacy OMEMO encrypted node");
            if (encrypted_node == null) return;

            assert_omemo_key_recipient((!) encrypted_node, (int) bob_store.local_registration_id,
                "private MUC OMEMO FileManager send proof must encrypt the body URL to Bob's known member device");
            assert_omemo_key_recipient((!) encrypted_node, (int) carol_store.local_registration_id,
                "private MUC OMEMO FileManager send proof must encrypt the body URL to Carol's known member device");
            assert_omemo_key_recipient((!) encrypted_node, (int) alice_other_store.local_registration_id,
                "private MUC OMEMO FileManager send proof must encrypt the body URL to an own trusted device");

            StanzaNode? body_node = ((!) omemo_message).get_subnode("body");
            fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is OMEMO encrypted]",
                "private MUC OMEMO FileManager send proof must expose only the OMEMO fallback body outside encryption");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_stream = new TestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Xmpp.Iq.Module());
            bob_stream.add_module(new Xmpp.Xep.Pubsub.Module());
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_store));
            bob_stream_interactor.connection_manager.set_connected_stream_for_tests(bob_account, bob_stream);
            var bob_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_store);

            string body_url = decrypt_legacy_omemo_payload(bob_decryptor, (!) encrypted_node, account.bare_jid);
            AesgcmUrlParts url_parts = parse_aesgcm_url(body_url);
            fail_if_not_eq_str(download_url, url_parts.https_url,
                "private MUC OMEMO FileManager send proof must encrypt the uploaded download URL in the OMEMO body");

            var carol_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(carol_stream_interactor, (!) dino_db);
            var carol_trust_manager = new Dino.Plugins.Omemo.TrustManager(carol_stream_interactor, (!) omemo_db);
            var carol_stream = new TestXmppStream(new Jid("example.test"));
            carol_stream.add_module(new Xmpp.Iq.Module());
            carol_stream.add_module(new Xmpp.Xep.Pubsub.Module());
            carol_stream.add_module(new Dino.Plugins.Omemo.StreamModule(carol_store));
            carol_stream_interactor.connection_manager.set_connected_stream_for_tests(carol_account, carol_stream);
            var carol_decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(carol_account, carol_stream_interactor, carol_trust_manager, (!) omemo_db, carol_store);

            string carol_body_url = decrypt_legacy_omemo_payload(carol_decryptor, (!) encrypted_node, account.bare_jid);
            fail_if_not_eq_str(body_url, carol_body_url,
                "private MUC OMEMO FileManager send proof must encrypt the same body URL to Carol's known member device");

            uint8[] decrypted = decrypt_aesgcm_with_attached_tag(capture.body, url_parts.key, url_parts.iv);
            assert_bytes_equal(payload, decrypted,
                "private MUC OMEMO FileManager send captured PUT body must decrypt with the IV/key from the real OMEMO body URL");

            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, body_url,
                "private MUC OMEMO FileManager body-only send");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private MUC OMEMO FileManager send must complete");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful private MUC OMEMO FileManager send must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful private MUC OMEMO FileManager send must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful private MUC OMEMO FileManager send must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful private MUC OMEMO FileManager send must assign a local file-sharing id");
            fail_if(!file_transfer.input_stream.is_closed(),
                "private MUC OMEMO FileManager send must close the upload stream");
            assert_single_http_source(file_transfer, download_url,
                "private MUC OMEMO FileManager send must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret((!) dino_db, file_transfer, download_url,
                "private MUC OMEMO FileManager send must persist exactly one fragment-free local HTTP source");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "private MUC OMEMO FileManager send must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "private MUC OMEMO FileManager send must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "private MUC OMEMO FileManager send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "private MUC OMEMO FileManager send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "private MUC OMEMO FileManager send must persist successful upload as complete");
        } catch (Error e) {
            fail_if(true, @"private MUC OMEMO FileManager send proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_private_muc_file_manager_http_send_with_known_members_uses_real_sce_session_body_only() {
        if (skip_if_local_https_sockets_unavailable()) return;

        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo2-private-muc-known-members-file-send-" + Uuid.string_random());
        string input_path = Path.build_filename(temp_dir, "private-muc-known-members-omemo2.txt");
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        HttpFileSender? sender = null;
        Soup.Server? server = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            string payload_text = "private MUC FileManager to real OMEMO2 SCE HTTPS payload with known members\n";
            uint8[] payload = payload_text.data;
            FileUtils.set_contents(input_path, payload_text);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "private MUC OMEMO2 FileManager send proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo2-private-muc-known-members-filemanager-http-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            start_public_file_send_modules(stream_interactor, (!) dino_db);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Dino.Entities.Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var carol_account = new Dino.Entities.Account(new Jid("carol@example.test"), "secret");
            carol_account.persist((!) dino_db);
            var dave_account = new Dino.Entities.Account(new Jid("dave@example.test"), "secret");
            dave_account.persist((!) dino_db);
            var room_jid = new Jid("private-room@conference.example.test");
            mark_room_private_in_entity_info((!) dino_db, account, room_jid);
            var persisted_conversation = new Dino.Entities.Conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            persisted_conversation.encryption = Dino.Entities.Encryption.OMEMO;
            persisted_conversation.send_typing = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.send_marker = Dino.Entities.Conversation.Setting.OFF;
            persisted_conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store alice_other_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            Store carol_store = setup_test_store_context(context);
            Store dave_store = setup_test_store_context(context);

            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_store, 47001, 48001);
            prepare_pre_key_session_v2(context, alice_store, carol_account.bare_jid, carol_store, 47002, 48002);
            prepare_pre_key_session_v2(context, alice_store, account.bare_jid, alice_other_store, 47003, 48003);
            prepare_pre_key_session_v2(context, alice_store, dave_account.bare_jid, dave_store, 47004, 48004);

            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            int carol_identity_id = install_identity((!) omemo_db, carol_account, carol_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, account.bare_jid, alice_other_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, carol_account.bare_jid, carol_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, dave_account.bare_jid, dave_store);
            add_trusted_omemo2_device((!) omemo_db, bob_identity_id, account.bare_jid, alice_store);
            add_trusted_omemo2_device((!) omemo_db, carol_identity_id, account.bare_jid, alice_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var encryptors = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.OmemoEncryptor>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            var encryptors_v2 = new HashMap<Dino.Entities.Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Dino.Entities.Account.hash_func, Dino.Entities.Account.equals_func);
            encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, trust_manager, alice_store);
            encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, trust_manager, alice_store);
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
            _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
            _force_class_init(typeof(Dino.Plugins.Omemo.Manager));
            Dino.Plugins.Omemo.Manager.start(stream_interactor, (!) omemo_db, trust_manager, encryptors, encryptors_v2);

            var file_encryption = new Dino.Security.FileEncryption("omemo2-private-muc-known-members-filemanager-http-test");
            Dino.FileManager.start(stream_interactor, (!) dino_db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "private MUC OMEMO2 FileManager send proof requires FileManager");
            if (manager == null) return;

            sender = new HttpFileSender(stream_interactor, (!) dino_db);
            ((!) manager).add_sender((!) sender);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "private MUC OMEMO2 FileManager send proof requires ConversationManager");
            if (conversation_manager == null) return;
            var conversation = ((!) conversation_manager).get_conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            fail_if(conversation == null,
                "private MUC OMEMO2 FileManager send proof requires the persisted groupchat conversation");
            if (conversation == null) return;

            TestXmppStream stream = create_connected_http_omemo_upload_stream(stream_interactor, account, alice_store, true);
            attach_private_muc_modules_for_tests(stream_interactor, account, stream, room_jid, "alice");
            Gee.List<Jid>? queried_members = query_private_muc_snapshot_for_tests(stream_interactor, account, stream, room_jid,
                member_list(account.bare_jid, bob_account.bare_jid),
                member_list(carol_account.bare_jid),
                member_list(bob_account.bare_jid));
            fail_if(queried_members == null || ((!) queried_members).size != 3,
                "private MUC OMEMO2 FileManager send proof must query the complete member/admin/owner affiliation snapshot");
            drain_pending_events();

            var muc_manager = stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            fail_if(!muc_manager.has_complete_private_muc_affiliation_snapshot(account, room_jid),
                "private MUC OMEMO2 FileManager send proof must complete the member/admin/owner snapshot");
            Gee.List<Jid>? snapshot_members = muc_manager.get_private_muc_member_affiliation_snapshot(account, room_jid);
            assert_member_list_contains_bare(snapshot_members, bob_account.bare_jid,
                "private MUC OMEMO2 FileManager send proof must include Bob in the complete snapshot");
            assert_member_list_contains_bare(snapshot_members, carol_account.bare_jid,
                "private MUC OMEMO2 FileManager send proof must include Carol in the complete snapshot");
            assert_member_list_lacks_bare(snapshot_members, dave_account.bare_jid,
                "private MUC OMEMO2 FileManager send proof must not seed trusted non-members as private-MUC members");

            var capture = new HttpsUploadCapture();
            string upload_url;
            string download_url;
            TlsCertificate tls_cert;
            server = start_https_upload_server(201, capture, stream, out upload_url, out download_url, out tls_cert);
            string? upload_host = Uri.parse(upload_url, UriFlags.NONE).get_host();
            fail_if(upload_host == null || ((!) upload_host) == "",
                "private MUC OMEMO2 FileManager send proof must extract the upload host for certificate pinning");
            Dino.CertificateManager.pin_to_db((!) dino_db, (!) upload_host, tls_cert, TlsCertificateFlags.UNKNOWN_CA);

            Dino.Entities.FileTransfer? published_transfer = null;
            var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
                fail_if(received_conversation != conversation,
                    "private MUC OMEMO2 FileManager send proof must publish the target conversation");
                fail_if(file_transfer.id == -1,
                    "private MUC OMEMO2 FileManager send proof must publish a persisted outgoing transfer before transport");
                fail_if(file_transfer.path == null,
                    "private MUC OMEMO2 FileManager send proof must publish a stored outgoing path before transport");
            });

            respond_to_matching_slot_request_when_written(stream, "private-muc-known-members-omemo2.txt",
                (payload.length + 16).to_string(), "text/plain", (outgoing) => {
                    var result_iq = build_slot_result_for_request(outgoing, download_url, upload_url);
                    append_slot_header(result_iq, "Authorization", "Bearer real-private-muc-omemo2");
                    stream.emit_iq_result(result_iq);
                });

            var send_loop = new MainLoop();
            ((!) manager).send_file.begin(File.new_for_path(input_path), (!) conversation, (file_transfer) => {
                file_transfer.server_file_name = "private-muc-known-members-omemo2.txt";
                file_transfer.mime_type = "text/plain";
                file_transfer.size = (int64) payload.length;
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            }, (obj, res) => {
                ((!) manager).send_file.end(res);
                send_loop.quit();
            });

            send_loop.run();
            drain_pending_events();

            fail_if(published_transfer == null,
                "private MUC OMEMO2 FileManager send proof must publish the locally saved transfer before HTTP upload");
            var file_transfer = (!) published_transfer;
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "private MUC OMEMO2 FileManager send proof must freeze the transfer as OMEMO");
            fail_if(file_transfer.provider != ((!) sender).get_id(),
                "private MUC OMEMO2 FileManager send proof must select the real HTTP sender");
            fail_if(find_http_upload_slot_request(stream) == null,
                "private MUC OMEMO2 FileManager send proof must request a XEP-0363 slot");
            fail_if(!capture.handled,
                "private MUC OMEMO2 FileManager send proof must reach the local HTTPS PUT endpoint");
            fail_if_not_eq_str("PUT", capture.method,
                "private MUC OMEMO2 FileManager send proof must use PUT");
            fail_if_not_eq_str("text/plain", capture.content_type ?? "",
                "private MUC OMEMO2 FileManager send proof must set the upload content type");
            fail_if_not_eq_str("Bearer real-private-muc-omemo2", capture.authorization ?? "",
                "private MUC OMEMO2 FileManager send proof must forward allowed slot headers");
            fail_if_not_eq_int(payload.length + 16, (int) capture.content_length,
                "private MUC OMEMO2 direct HTTP-GCM upload must send plaintext size plus the 16-byte tag");
            fail_if_not_eq_int(payload.length + 16, capture.body.length,
                "private MUC OMEMO2 direct HTTP-GCM upload body must include the 16-byte tag");
            fail_if(bytes_equal(payload, capture.body),
                "private MUC OMEMO2 direct HTTP-GCM upload must not upload plaintext bytes");

            StanzaNode? omemo_message = find_omemo2_message(stream);
            fail_if(omemo_message == null,
                "private MUC OMEMO2 FileManager send proof must write a real OMEMO2/SCE payload stanza");
            if (omemo_message == null) return;
            fail_if(find_legacy_omemo_message(stream) != null,
                "private MUC OMEMO2 FileManager send proof must not use legacy OMEMO for v2-only members");
            fail_if(((!) omemo_message).get_attribute("to") != room_jid.to_string(),
                "private MUC OMEMO2 FileManager send proof must address the encrypted body URL to the room");
            fail_if(((!) omemo_message).get_attribute("type") != MessageStanza.TYPE_GROUPCHAT,
                "private MUC OMEMO2 FileManager send proof must announce the encrypted body URL as a groupchat stanza");

            StanzaNode? encrypted_node = ((!) omemo_message).get_subnode("encrypted", NS_OMEMO_V2);
            fail_if(encrypted_node == null,
                "private MUC OMEMO2 FileManager send proof must contain the OMEMO2/SCE encrypted node");
            if (encrypted_node == null) return;

            assert_omemo2_key_recipient((!) encrypted_node, bob_account.bare_jid, (int) bob_store.local_registration_id,
                "private MUC OMEMO2 FileManager send proof must encrypt the body URL to Bob's known v2 member device");
            assert_omemo2_key_recipient((!) encrypted_node, carol_account.bare_jid, (int) carol_store.local_registration_id,
                "private MUC OMEMO2 FileManager send proof must encrypt the body URL to Carol's known v2 member device");
            assert_omemo2_key_recipient((!) encrypted_node, account.bare_jid, (int) alice_other_store.local_registration_id,
                "private MUC OMEMO2 FileManager send proof must encrypt the body URL to an own trusted v2 device");
            assert_omemo2_key_recipient_absent((!) encrypted_node, dave_account.bare_jid, (int) dave_store.local_registration_id,
                "private MUC OMEMO2 FileManager send proof must not encrypt the body URL to trusted non-members");
            fail_if(count_omemo2_key_recipients((!) encrypted_node) != 3,
                "private MUC OMEMO2 FileManager send proof must target exactly Bob, Carol and one own trusted v2 device");

            StanzaNode? body_node = ((!) omemo_message).get_subnode("body");
            fail_if(body_node == null || ((!) body_node).get_string_content() != "[This message is OMEMO encrypted]",
                "private MUC OMEMO2 FileManager send proof must expose only the OMEMO fallback body outside encryption");

            var bob_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_stream_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_stream_interactor, (!) omemo_db);
            var bob_decryptor = new Dino.Plugins.Omemo.Omemo2Decrypt(bob_account, bob_stream_interactor, bob_trust_manager, (!) omemo_db, bob_store);

            string body_url = decrypt_omemo2_payload(bob_decryptor, (!) encrypted_node, bob_account.bare_jid, account.bare_jid);
            AesgcmUrlParts url_parts = parse_aesgcm_url(body_url);
            fail_if_not_eq_str(download_url, url_parts.https_url,
                "private MUC OMEMO2 FileManager send proof must encrypt the uploaded download URL in the OMEMO2/SCE body");

            var carol_stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(carol_stream_interactor, (!) dino_db);
            var carol_trust_manager = new Dino.Plugins.Omemo.TrustManager(carol_stream_interactor, (!) omemo_db);
            var carol_decryptor = new Dino.Plugins.Omemo.Omemo2Decrypt(carol_account, carol_stream_interactor, carol_trust_manager, (!) omemo_db, carol_store);

            string carol_body_url = decrypt_omemo2_payload(carol_decryptor, (!) encrypted_node, carol_account.bare_jid, account.bare_jid);
            fail_if_not_eq_str(body_url, carol_body_url,
                "private MUC OMEMO2 FileManager send proof must encrypt the same body URL to Carol's known v2 member device");

            uint8[] decrypted = decrypt_aesgcm_with_attached_tag(capture.body, url_parts.key, url_parts.iv);
            assert_bytes_equal(payload, decrypted,
                "private MUC OMEMO2 FileManager send captured PUT body must decrypt with the IV/key from the real OMEMO2 body URL");

            assert_no_cleartext_transfer_url_or_outer_file_stanzas(stream, download_url, body_url,
                "private MUC OMEMO2 FileManager body-only send");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful private MUC OMEMO2 FileManager send must complete");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful private MUC OMEMO2 FileManager send must persist COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful private MUC OMEMO2 FileManager send must not retain a phase error");
            fail_if(file_transfer.info == null || ((!) file_transfer.info) == "",
                "successful private MUC OMEMO2 FileManager send must link the encrypted body-url message");
            fail_if(file_transfer.file_sharing_id == null || ((!) file_transfer.file_sharing_id) == "",
                "successful private MUC OMEMO2 FileManager send must assign a local file-sharing id");
            fail_if(!file_transfer.input_stream.is_closed(),
                "private MUC OMEMO2 FileManager send must close the upload stream");
            assert_single_http_source(file_transfer, download_url,
                "private MUC OMEMO2 FileManager send must keep one fragment-free local HTTP source");
            assert_only_persisted_http_source_without_secret((!) dino_db, file_transfer, download_url,
                "private MUC OMEMO2 FileManager send must persist exactly one fragment-free local HTTP source");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "private MUC OMEMO2 FileManager send must store the local copy before slot request");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "private MUC OMEMO2 FileManager send must request the slot before HTTPS upload");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.ANNOUNCING,
                "private MUC OMEMO2 FileManager send must upload before announcing the encrypted body URL");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ANNOUNCING, Dino.Entities.FileTransfer.Phase.COMPLETE,
                "private MUC OMEMO2 FileManager send must finish in COMPLETE after body-url announcement");
            assert_persisted_transfer_state((!) dino_db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "private MUC OMEMO2 FileManager send must persist successful upload as complete");
        } catch (Error e) {
            fail_if(true, @"private MUC OMEMO2 FileManager send proof failed: $(e.message)");
        } finally {
            if (server != null) ((!) server).disconnect();
            if (sender != null) ((!) sender).shutdown();
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            if (stored_path != null) cleanup_file(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            cleanup_file(input_path);
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private static void prepare_pre_key_session(Context context, Store sender_store, Jid peer_jid, Store peer_store, uint32 pre_key_id, int signed_pre_key_id) throws Error {
        ECKeyPair peer_pre_key_pair = context.generate_key_pair();
        ECKeyPair peer_signed_pre_key_pair = context.generate_key_pair();
        IdentityKeyPair peer_identity_key_pair = peer_store.identity_key_pair;
        uint8[] peer_signed_pre_key_signature = context.calculate_signature(peer_identity_key_pair.private, peer_signed_pre_key_pair.public.serialize());
        PreKeyBundle peer_pre_key = create_pre_key_bundle(peer_store.local_registration_id, (int) peer_store.local_registration_id,
            pre_key_id, peer_pre_key_pair.public, signed_pre_key_id, peer_signed_pre_key_pair.public, peer_signed_pre_key_signature, peer_identity_key_pair.public);

        Address peer_address = new Address(peer_jid.bare_jid.to_string(), (int) peer_store.local_registration_id);
        sender_store.create_session_builder(peer_address).process_pre_key_bundle(peer_pre_key);
        peer_address.device_id = 0;

        PreKeyRecord peer_pre_key_record;
        throw_by_code(PreKeyRecord.create(out peer_pre_key_record, pre_key_id, peer_pre_key_pair));
        peer_store.store_pre_key(peer_pre_key_record);

        SignedPreKeyRecord peer_signed_pre_key_record;
        throw_by_code(SignedPreKeyRecord.create(out peer_signed_pre_key_record, signed_pre_key_id,
            new DateTime.now_utc().to_unix(), peer_signed_pre_key_pair, peer_signed_pre_key_signature, null));
        peer_store.store_signed_pre_key(peer_signed_pre_key_record);
    }

    private static void prepare_pre_key_session_v2(Context context, Store sender_store, Jid peer_jid, Store peer_store, uint32 pre_key_id, int signed_pre_key_id) throws Error {
        ECKeyPair peer_pre_key_pair = context.generate_key_pair();
        ECKeyPair peer_signed_pre_key_pair = context.generate_key_pair();
        IdentityKeyPair peer_identity_key_pair = peer_store.identity_key_pair;
        uint8[] peer_signed_pre_key_signature = context.calculate_signature(peer_identity_key_pair.private, peer_signed_pre_key_pair.public.serialize_omemo());
        PreKeyBundle peer_pre_key = create_pre_key_bundle(peer_store.local_registration_id, (int) peer_store.local_registration_id,
            pre_key_id, peer_pre_key_pair.public, signed_pre_key_id, peer_signed_pre_key_pair.public, peer_signed_pre_key_signature, peer_identity_key_pair.public);

        Address peer_address = new Address(peer_jid.bare_jid.to_string(), (int) peer_store.local_registration_id);
        SessionBuilder builder = sender_store.create_session_builder(peer_address);
        builder.version = 4;
        builder.process_pre_key_bundle(peer_pre_key);
        peer_address.device_id = 0;

        PreKeyRecord peer_pre_key_record;
        throw_by_code(PreKeyRecord.create(out peer_pre_key_record, pre_key_id, peer_pre_key_pair));
        peer_store.store_pre_key(peer_pre_key_record);

        SignedPreKeyRecord peer_signed_pre_key_record;
        throw_by_code(SignedPreKeyRecord.create(out peer_signed_pre_key_record, signed_pre_key_id,
            new DateTime.now_utc().to_unix(), peer_signed_pre_key_pair, new uint8[1], peer_signed_pre_key_signature));
        peer_store.store_signed_pre_key(peer_signed_pre_key_record);
    }

    private static int install_identity(Dino.Plugins.Omemo.Database db, Dino.Entities.Account account, Store store) {
        return (int) db.identity.upsert()
            .value(db.identity.account_id, account.id, true)
            .value(db.identity.device_id, (int) store.local_registration_id)
            .value(db.identity.identity_key_private_base64, Base64.encode(store.identity_key_store.identity_key_private.get_data()))
            .value(db.identity.identity_key_public_base64, Base64.encode(store.identity_key_store.identity_key_public.get_data()))
            .perform();
    }

    private static void add_trusted_omemo1_device(Dino.Plugins.Omemo.Database db, int identity_id, Jid jid, Store device_store) {
        db.identity_meta.upsert()
            .value(db.identity_meta.identity_id, identity_id, true)
            .value(db.identity_meta.address_name, jid.bare_jid.to_string(), true)
            .value(db.identity_meta.device_id, (int) device_store.local_registration_id, true)
            .value(db.identity_meta.identity_key_public_base64, Base64.encode(device_store.identity_key_store.identity_key_public.get_data()))
            .value(db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.TRUSTED)
            .value(db.identity_meta.now_active, true)
            .value(db.identity_meta.supports_omemo1, true)
            .value(db.identity_meta.supports_omemo2, false)
            .value(db.identity_meta.last_active, (long) new DateTime.now_utc().to_unix())
            .perform();
    }

    private static void add_trusted_omemo2_device(Dino.Plugins.Omemo.Database db, int identity_id, Jid jid, Store device_store) {
        db.identity_meta.upsert()
            .value(db.identity_meta.identity_id, identity_id, true)
            .value(db.identity_meta.address_name, jid.bare_jid.to_string(), true)
            .value(db.identity_meta.device_id, (int) device_store.local_registration_id, true)
            .value(db.identity_meta.identity_key_public_base64, Base64.encode(device_store.identity_key_store.identity_key_public.get_data()))
            .value(db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.TRUSTED)
            .value(db.identity_meta.now_active, true)
            .value(db.identity_meta.supports_omemo1, false)
            .value(db.identity_meta.supports_omemo2, true)
            .value(db.identity_meta.last_active, (long) new DateTime.now_utc().to_unix())
            .perform();
    }

    private static void mark_room_private_in_entity_info(Dino.Database db, Dino.Entities.Account account, Jid room_jid) {
        string entity = "omemo-private-muc-filemanager-test-" + Uuid.string_random();
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

    private static void assert_omemo_key_recipient(StanzaNode encrypted_node, int device_id, string reason) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", NS_OMEMO_LEGACY);
        fail_if(header_node == null, reason + ": missing OMEMO header");
        if (header_node == null) return;

        foreach (StanzaNode key_node in ((!) header_node).get_subnodes("key", NS_OMEMO_LEGACY)) {
            if (key_node.get_attribute_int("rid") == device_id) return;
        }
        fail_if(true, reason);
    }

    private static bool omemo1_payload_has_device(StanzaNode encrypted_node, int device_id) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", NS_OMEMO_LEGACY);
        if (header_node == null) return false;

        foreach (StanzaNode key_node in ((!) header_node).get_subnodes("key", NS_OMEMO_LEGACY)) {
            if (key_node.get_attribute_int("rid") == device_id) return true;
        }
        return false;
    }

    private static void assert_omemo2_key_recipient(StanzaNode encrypted_node, Jid jid, int device_id, string reason) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", NS_OMEMO_V2);
        fail_if(header_node == null, reason + ": missing OMEMO2 header");
        if (header_node == null) return;

        string jid_string = jid.bare_jid.to_string();
        foreach (StanzaNode keys_node in ((!) header_node).get_subnodes("keys", NS_OMEMO_V2)) {
            if (keys_node.get_attribute("jid") != jid_string) continue;
            foreach (StanzaNode key_node in keys_node.get_subnodes("key", NS_OMEMO_V2)) {
                if (key_node.get_attribute_int("rid") == device_id) return;
            }
        }
        fail_if(true, reason);
    }

    private static void assert_omemo2_key_recipient_absent(StanzaNode encrypted_node, Jid jid, int device_id, string reason) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", NS_OMEMO_V2);
        fail_if(header_node == null, reason + ": missing OMEMO2 header");
        if (header_node == null) return;

        string jid_string = jid.bare_jid.to_string();
        foreach (StanzaNode keys_node in ((!) header_node).get_subnodes("keys", NS_OMEMO_V2)) {
            if (keys_node.get_attribute("jid") != jid_string) continue;
            foreach (StanzaNode key_node in keys_node.get_subnodes("key", NS_OMEMO_V2)) {
                fail_if(key_node.get_attribute_int("rid") == device_id, reason);
            }
        }
    }

    private static int count_omemo2_key_recipients(StanzaNode encrypted_node) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", NS_OMEMO_V2);
        if (header_node == null) return 0;

        int count = 0;
        foreach (StanzaNode keys_node in ((!) header_node).get_subnodes("keys", NS_OMEMO_V2)) {
            foreach (StanzaNode key_node in keys_node.get_subnodes("key", NS_OMEMO_V2)) {
                if (key_node.name == "key") count++;
            }
        }
        return count;
    }

    private static string decrypt_legacy_omemo_payload(Dino.Plugins.Omemo.OmemoDecryptor decryptor, StanzaNode encrypted_node, Jid sender_jid) throws Error {
        Xmpp.Xep.Omemo.ParsedData? parsed = decryptor.parse_node(encrypted_node);
        if (parsed == null) throw new IOError.FAILED("recipient could not parse OMEMO encrypted node");
        Xmpp.Xep.Omemo.ParsedData data = (!) parsed;

        foreach (Bytes encrypted_key in data.our_potential_encrypted_keys.keys) {
            data.is_prekey = data.our_potential_encrypted_keys[encrypted_key];
            data.encrypted_key = encrypted_key.get_data();
            uint8[] key = decryptor.decrypt_key(data, sender_jid);
            return decryptor.decrypt(data.ciphertext, key, data.iv);
        }

        throw new IOError.FAILED("recipient OMEMO payload did not contain a key for the recipient device");
    }

    private static string decrypt_omemo2_payload(Dino.Plugins.Omemo.Omemo2Decrypt decryptor, StanzaNode encrypted_node, Jid recipient_jid, Jid sender_jid) throws Error {
        Xmpp.Xep.Omemo.Omemo2ParsedData? parsed = decryptor.parse_node(encrypted_node, recipient_jid);
        if (parsed == null) throw new IOError.FAILED("recipient could not parse OMEMO2 encrypted node");
        Xmpp.Xep.Omemo.Omemo2ParsedData data = (!) parsed;
        if (data.ciphertext == null) throw new IOError.FAILED("recipient OMEMO2 payload did not contain ciphertext");

        uint8[] key = decryptor.decrypt_key(data, sender_jid);
        string body = "";
        Error? decrypt_error = null;
        var loop = new MainLoop();
        bool decrypt_timed_out = false;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(2, () => {
            decrypt_timed_out = true;
            timeout_id = 0;
            loop.quit();
            return Source.REMOVE;
        });
        decryptor.decrypt.begin((!) data.ciphertext, key, (obj, res) => {
            try {
                body = decryptor.decrypt.end(res);
            } catch (Error e) {
                decrypt_error = e;
            }
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            loop.quit();
        });
        loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        if (decrypt_timed_out) {
            throw new IOError.TIMED_OUT("recipient OMEMO2 payload decrypt did not finish");
        }
        if (decrypt_error != null) throw (!) decrypt_error;
        return body;
    }

    private static void start_public_file_send_modules(Dino.StreamInteractor stream_interactor, Dino.Database db) {
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

        Dino.MessageStorage.start(stream_interactor, db);
        Dino.FileTransferStorage.start(stream_interactor, db);
        Dino.MessageProcessor.start(stream_interactor, db);
        Dino.EntityInfo.start(stream_interactor, db);
        Dino.RosterManager.start(stream_interactor, db);
        Dino.Calls.start(stream_interactor, db);
        Dino.ConversationManager.start(stream_interactor, db);
        Dino.PresenceManager.start(stream_interactor, db);
        Dino.MucManager.start(stream_interactor);
    }

    private static TestXmppStream create_connected_http_omemo_upload_stream(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account, Store alice_store, bool include_omemo2 = false,
            Dino.Plugins.Omemo.StreamModule? omemo_module_override = null) throws Error {
        var stream = new TestXmppStream(new Jid("example.test"));
        var iq_module = stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(account, Xmpp.Iq.Module.IDENTITY);
        if (iq_module == null) {
            throw new IOError.FAILED("missing IQ module in public OMEMO FileManager send test setup");
        }
        stream.add_module((!) iq_module);
        ((!) iq_module).attach(stream);

        var message_module = stream_interactor.module_manager.get_module<Xmpp.MessageModule>(account, Xmpp.MessageModule.IDENTITY);
        if (message_module == null) {
            throw new IOError.FAILED("missing message module in public OMEMO FileManager send test setup");
        }
        stream.add_module((!) message_module);
        ((!) message_module).attach(stream);

        var service_discovery_module = stream_interactor.module_manager.get_module<Xmpp.Xep.ServiceDiscovery.Module>(
            account, Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        if (service_discovery_module == null) {
            throw new IOError.FAILED("missing service discovery module in public OMEMO FileManager send test setup");
        }
        stream.add_module((!) service_discovery_module);
        ((!) service_discovery_module).attach(stream);

        Dino.Plugins.Omemo.StreamModule omemo_module =
            omemo_module_override ??
                new Dino.Plugins.Omemo.StreamModule(alice_store);
        stream.add_module(omemo_module);
        if (include_omemo2) {
            var omemo2_module = new Dino.Plugins.Omemo.StreamModule2(alice_store);
            stream.add_module(omemo2_module);
        }

        attach_omemo_bookmark_modules_for_tests(stream_interactor, account, stream);
        install_empty_omemo_bookmarks_responder_for_tests(stream, account.bare_jid);

        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream.add_flag(new Xmpp.Xep.HttpFileUpload.Flag(new Jid("upload.example.test"), NS_HTTP_UPLOAD_0));
        stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

        var upload_module = stream_interactor.module_manager.get_module<Xmpp.Xep.HttpFileUpload.Module>(
            account, Xmpp.Xep.HttpFileUpload.Module.IDENTITY);
        if (upload_module == null) {
            throw new IOError.FAILED("missing HTTP upload module in public OMEMO FileManager send test setup");
        }
        stream.stream_negotiated(stream);
        ((!) upload_module).feature_available(stream, long.MAX);
        return stream;
    }

    private static void attach_omemo_bookmark_modules_for_tests(Dino.StreamInteractor stream_interactor,
            Dino.Entities.Account account, TestXmppStream stream) throws Error {
        _force_class_init(typeof(Xmpp.Xep.PrivateXmlStorage.Module));
        _force_class_init(typeof(Xmpp.Xep.Bookmarks.Module));
        _force_class_init(typeof(Xmpp.Xep.Pubsub.Module));
        _force_class_init(typeof(Xmpp.Xep.Bookmarks2.Module));

        var private_xml_module = stream_interactor.module_manager.get_module<Xmpp.Xep.PrivateXmlStorage.Module>(
            account, Xmpp.Xep.PrivateXmlStorage.Module.IDENTITY);
        if (private_xml_module == null) {
            throw new IOError.FAILED("missing private XML storage module in OMEMO FileManager send test setup");
        }
        if (stream.get_module<Xmpp.Xep.PrivateXmlStorage.Module>(Xmpp.Xep.PrivateXmlStorage.Module.IDENTITY) == null) {
            stream.add_module((!) private_xml_module);
            ((!) private_xml_module).attach(stream);
        }

        var bookmarks_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Bookmarks.Module>(
            account, Xmpp.Xep.Bookmarks.Module.IDENTITY);
        if (bookmarks_module == null) {
            throw new IOError.FAILED("missing legacy bookmarks module in OMEMO FileManager send test setup");
        }
        if (stream.get_module<Xmpp.Xep.Bookmarks.Module>(Xmpp.Xep.Bookmarks.Module.IDENTITY) == null) {
            stream.add_module((!) bookmarks_module);
            ((!) bookmarks_module).attach(stream);
        }

        var pubsub_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Pubsub.Module>(
            account, Xmpp.Xep.Pubsub.Module.IDENTITY);
        if (pubsub_module == null) {
            throw new IOError.FAILED("missing PubSub module in OMEMO FileManager send test setup");
        }
        if (stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY) == null) {
            stream.add_module((!) pubsub_module);
            ((!) pubsub_module).attach(stream);
        }

        var bookmarks2_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Bookmarks2.Module>(
            account, Xmpp.Xep.Bookmarks2.Module.IDENTITY);
        if (bookmarks2_module == null) {
            throw new IOError.FAILED("missing PEP bookmarks module in OMEMO FileManager send test setup");
        }
        if (stream.get_module<Xmpp.Xep.Bookmarks2.Module>(Xmpp.Xep.Bookmarks2.Module.IDENTITY) == null) {
            stream.add_module((!) bookmarks2_module);
            ((!) bookmarks2_module).attach(stream);
        }
    }

    private static void install_empty_omemo_bookmarks_responder_for_tests(TestXmppStream stream, Jid account_bare_jid) {
        stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            string? iq_type = outgoing.get_attribute("type");

            if (iq_type == Xmpp.Iq.Stanza.TYPE_GET) {
                StanzaNode? disco_query = outgoing.get_subnode("query", NS_DISCO_INFO);
                if (disco_query != null && outgoing.get_attribute("to") == account_bare_jid.to_string()) {
                    stream.emit_iq_result(build_empty_disco_info_result_for_request(outgoing, account_bare_jid));
                    return;
                }

                StanzaNode? pubsub = outgoing.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
                StanzaNode? items = pubsub != null ? ((!) pubsub).get_subnode("items", Xmpp.Xep.Pubsub.NS_URI) : null;
                if (items != null) {
                    if (stream.maybe_hold_legacy_bundle_request(outgoing, (!) items)) return;
                    if (stream.maybe_hold_legacy_devicelist_request(
                            outgoing, (!) items)) return;
                    stream.emit_iq_result(build_empty_pubsub_items_result_for_request(outgoing, (!) items));
                    return;
                }

                StanzaNode? owner_pubsub = outgoing.get_subnode("pubsub", NS_PUBSUB_OWNER);
                StanzaNode? configure = owner_pubsub != null ? ((!) owner_pubsub).get_subnode("configure", NS_PUBSUB_OWNER) : null;
                if (configure != null) {
                    stream.emit_iq_result(build_empty_pubsub_owner_config_result_for_request(outgoing, (!) configure));
                    return;
                }

                StanzaNode? private_query = outgoing.get_subnode("query", NS_PRIVATE_XML_STORAGE);
                if (private_query == null) return;
                if (((!) private_query).get_subnode("storage", NS_BOOKMARKS) == null) return;

                stream.emit_iq_result(build_empty_omemo_bookmarks_result_for_request(outgoing));
            } else if (iq_type == Xmpp.Iq.Stanza.TYPE_SET) {
                if (outgoing.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI) != null ||
                        outgoing.get_subnode("pubsub", NS_PUBSUB_OWNER) != null) {
                    stream.emit_iq_result(build_empty_iq_result_for_request(outgoing));
                }
            }
        });
    }

    private static void attach_private_muc_modules_for_tests(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account,
            TestXmppStream stream, Jid room_jid, string own_nick,
            bool seed_own_nick = true) throws Error {
        var presence_module = stream_interactor.module_manager.get_module<Xmpp.Presence.Module>(account, Xmpp.Presence.Module.IDENTITY);
        if (presence_module == null) {
            throw new IOError.FAILED("missing presence module in private MUC OMEMO FileManager send test setup");
        }
        stream.add_module((!) presence_module);
        ((!) presence_module).attach(stream);

        var muc_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Muc.Module>(account, Xmpp.Xep.Muc.Module.IDENTITY);
        if (muc_module == null) {
            throw new IOError.FAILED("missing MUC module in private MUC OMEMO FileManager send test setup");
        }
        stream.add_module((!) muc_module);
        ((!) muc_module).attach(stream);

        var ping_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Ping.Module>(account, Xmpp.Xep.Ping.Module.IDENTITY);
        if (ping_module == null) {
            throw new IOError.FAILED("missing ping module in private MUC OMEMO FileManager send test setup");
        }
        stream.add_module((!) ping_module);
        ((!) ping_module).attach(stream);

        Xmpp.Xep.Muc.Flag? muc_flag = stream.get_flag(Xmpp.Xep.Muc.Flag.IDENTITY);
        if (muc_flag == null) {
            throw new IOError.FAILED("missing MUC flag after attaching private MUC test modules");
        }
        if (seed_own_nick) {
            ((!) muc_flag).set_muc_nick(room_jid.with_resource(own_nick));
        }
    }

    private static Gee.List<Jid>? query_private_muc_snapshot_for_tests(Dino.StreamInteractor stream_interactor,
            Account account, TestXmppStream stream, Jid room_jid,
            Gee.List<Jid> members, Gee.List<Jid> admins,
            Gee.List<Jid> owners,
            Gee.Set<string>? forbidden_affiliations = null,
            bool room_is_private = true) {
        Dino.MucManager? muc_manager = stream_interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
        fail_if(muc_manager == null, "private MUC OMEMO FileManager send proof requires MucManager");
        if (muc_manager == null) return null;

        Jid room_bare_jid = room_jid.bare_jid;
        ulong handler_id = 0;
        handler_id = stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            if (outgoing.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_GET) return;
            if (outgoing.get_attribute("to") != room_bare_jid.to_string()) return;

            StanzaNode? info_query = outgoing.get_subnode("query", NS_DISCO_INFO);
            if (info_query != null) {
                stream.emit_iq_result(room_is_private
                    ? build_private_muc_room_info_result_for_request(outgoing, room_bare_jid)
                    : build_public_muc_room_info_result_for_request(outgoing, room_bare_jid));
                return;
            }

            StanzaNode? query = outgoing.get_subnode("query", NS_MUC_ADMIN);
            if (query == null) return;
            StanzaNode? item = ((!) query).get_subnode("item", NS_MUC_ADMIN);
            if (item == null) return;

            string affiliation = ((!) item).get_attribute("affiliation") ?? "";
            if (forbidden_affiliations != null &&
                    ((!) forbidden_affiliations).contains(affiliation)) {
                stream.emit_iq_result(
                    build_muc_affiliation_forbidden_error_for_request(
                        outgoing, room_bare_jid));
                return;
            }
            if (affiliation == "member") {
                stream.emit_iq_result(build_muc_affiliation_result_for_request(outgoing, room_bare_jid, "member", members));
            } else if (affiliation == "admin") {
                stream.emit_iq_result(build_muc_affiliation_result_for_request(outgoing, room_bare_jid, "admin", admins));
            } else if (affiliation == "owner") {
                stream.emit_iq_result(build_muc_affiliation_result_for_request(outgoing, room_bare_jid, "owner", owners));
            }
        });

        Gee.List<Jid>? snapshot = null;
        var query_loop = new MainLoop();
        bool query_timed_out = false;
        uint timeout_id = Timeout.add_seconds(2, () => {
            query_timed_out = true;
            query_loop.quit();
            return Source.REMOVE;
        });
        ((!) muc_manager).query_private_muc_affiliation_snapshot.begin(account, room_jid, (obj, res) => {
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
            SignalHandler.disconnect(stream, handler_id);
        }
        fail_if(query_timed_out,
            "private MUC OMEMO FileManager send proof must answer the complete member/admin/owner snapshot IQs without hanging");
        return snapshot;
    }

    private static StanzaNode build_private_muc_room_info_result_for_request(StanzaNode request_iq, Jid room_jid) {
        var result_iq = new StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT)
            .put_attribute("from", room_jid.to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);

        var query = new StanzaNode.build("query", NS_DISCO_INFO).add_self_xmlns()
            .put_node(new StanzaNode.build("identity", NS_DISCO_INFO)
                .put_attribute("category", "conference")
                .put_attribute("type", "text")
                .put_attribute("name", "OMEMO private MUC FileManager test"));
        query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO).put_attribute("var", "muc_membersonly"));
        query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO).put_attribute("var", "muc_nonanonymous"));
        result_iq.put_node(query);
        return result_iq;
    }

    private static StanzaNode build_public_muc_room_info_result_for_request(
            StanzaNode request_iq, Jid room_jid) {
        var result_iq = new StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT)
            .put_attribute("from", room_jid.to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);

        var query = new StanzaNode.build("query", NS_DISCO_INFO)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("identity", NS_DISCO_INFO)
                .put_attribute("category", "conference")
                .put_attribute("type", "text")
                .put_attribute("name", "OMEMO public MUC transition test"))
            .put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", "muc_nonanonymous"));
        result_iq.put_node(query);
        return result_iq;
    }

    private static StanzaNode build_private_muc_self_presence_for_tests(
            Jid room_jid, string nick, Jid account_jid) throws Error {
        var item = new StanzaNode.build("item", NS_MUC_USER)
            .put_attribute("jid", account_jid.to_string())
            .put_attribute("affiliation", "owner")
            .put_attribute("role", "moderator");
        var muc_user = new StanzaNode.build("x", NS_MUC_USER)
            .add_self_xmlns()
            .put_node(item)
            .put_node(new StanzaNode.build("status", NS_MUC_USER)
                .put_attribute("code", "110"));
        return new StanzaNode.build("presence")
            .put_attribute("from",
                room_jid.bare_jid.with_resource(nick).to_string())
            .put_attribute("to", account_jid.to_string())
            .put_node(muc_user);
    }

    private static StanzaNode build_empty_disco_info_result_for_request(StanzaNode request_iq, Jid from_jid) {
        var result_iq = new StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT)
            .put_attribute("from", from_jid.to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? from = request_iq.get_attribute("from");
        if (from != null) result_iq.put_attribute("to", (!) from);

        result_iq.put_node(new StanzaNode.build("query", NS_DISCO_INFO).add_self_xmlns());
        return result_iq;
    }

    private static StanzaNode build_empty_omemo_bookmarks_result_for_request(StanzaNode request_iq) {
        var result_iq = new StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? to = request_iq.get_attribute("to");
        if (to != null) result_iq.put_attribute("from", (!) to);

        result_iq.put_node(new StanzaNode.build("query", NS_PRIVATE_XML_STORAGE).add_self_xmlns()
            .put_node(new StanzaNode.build("storage", NS_BOOKMARKS).add_self_xmlns()));
        return result_iq;
    }

    private static StanzaNode build_empty_pubsub_items_result_for_request(StanzaNode request_iq, StanzaNode request_items) {
        var result_iq = build_empty_iq_result_for_request(request_iq);
        string node = request_items.get_attribute("node");
        result_iq.put_node(new StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI).add_self_xmlns()
            .put_node(new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI).put_attribute("node", node)));
        return result_iq;
    }

    private static StanzaNode build_legacy_devicelist_result_for_request(
            StanzaNode request_iq, Jid owner, int32 device_id) {
        string node = NS_OMEMO_LEGACY + ".devicelist";
        var list = new StanzaNode.build("list", NS_OMEMO_LEGACY)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("device", NS_OMEMO_LEGACY)
                .put_attribute("id", device_id.to_string()));
        var item = new StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI)
            .put_attribute("id", "current")
            .put_node(list);
        var items = new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
            .put_attribute("node", node)
            .put_node(item);
        StanzaNode result_iq = build_empty_iq_result_for_request(request_iq);
        result_iq.put_attribute("from", owner.bare_jid.to_string());
        result_iq.put_node(new StanzaNode.build("pubsub",
            Xmpp.Xep.Pubsub.NS_URI).add_self_xmlns().put_node(items));
        return result_iq;
    }

    private static StanzaNode build_empty_pubsub_owner_config_result_for_request(StanzaNode request_iq, StanzaNode request_configure) {
        var result_iq = build_empty_iq_result_for_request(request_iq);
        string node = request_configure.get_attribute("node");
        result_iq.put_node(new StanzaNode.build("pubsub", NS_PUBSUB_OWNER).add_self_xmlns()
            .put_node(new StanzaNode.build("configure", NS_PUBSUB_OWNER).put_attribute("node", node)
                .put_node(new StanzaNode.build("x", "jabber:x:data").add_self_xmlns().put_attribute("type", "form"))));
        return result_iq;
    }

    private static StanzaNode build_empty_iq_result_for_request(StanzaNode request_iq) {
        var result_iq = new StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? to = request_iq.get_attribute("to");
        if (to != null) result_iq.put_attribute("from", (!) to);
        string? from = request_iq.get_attribute("from");
        if (from != null) result_iq.put_attribute("to", (!) from);
        return result_iq;
    }

    private static StanzaNode build_muc_affiliation_result_for_request(StanzaNode request_iq, Jid room_jid,
            string affiliation, Gee.List<Jid> members) {
        var result_iq = new StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT)
            .put_attribute("from", room_jid.to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);

        var query = new StanzaNode.build("query", NS_MUC_ADMIN).add_self_xmlns();
        foreach (Jid member in members) {
            query.put_node(new StanzaNode.build("item", NS_MUC_ADMIN)
                .put_attribute("affiliation", affiliation)
                .put_attribute("jid", member.to_string()));
        }
        result_iq.put_node(query);
        return result_iq;
    }

    private static StanzaNode build_muc_affiliation_forbidden_error_for_request(StanzaNode request_iq, Jid room_jid) {
        var result_iq = new StanzaNode.build("iq")
            .put_attribute("type", Xmpp.Stanza.TYPE_ERROR)
            .put_attribute("from", room_jid.to_string());
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? from = request_iq.get_attribute("from");
        if (from != null) result_iq.put_attribute("to", (!) from);

        var error = new ErrorStanza.build(ErrorStanza.TYPE_AUTH, ErrorStanza.CONDITION_FORBIDDEN,
            "affiliation list is not available", null);
        result_iq.put_node(error.error_node);
        return result_iq;
    }

    private static Gee.List<Jid> member_list(Jid? first_member = null, Jid? second_member = null, Jid? third_member = null) {
        var members = new Gee.ArrayList<Jid>(Jid.equals_bare_func);
        if (first_member != null) members.add((!) first_member);
        if (second_member != null) members.add((!) second_member);
        if (third_member != null) members.add((!) third_member);
        return members;
    }

    private static void assert_member_list_contains_bare(Gee.List<Jid>? members, Jid expected, string reason) {
        fail_if(members == null, reason);
        if (members == null) return;

        foreach (Jid member in (!) members) {
            if (member.equals_bare(expected)) return;
        }
        fail_if(true, reason);
    }

    private static void assert_member_list_lacks_bare(Gee.List<Jid>? members, Jid unexpected, string reason) {
        fail_if(members == null, reason);
        if (members == null) return;

        foreach (Jid member in (!) members) {
            fail_if(member.equals_bare(unexpected), reason);
        }
    }

    private delegate void WrittenIqHandler(StanzaNode outgoing);

    private static void respond_to_matching_slot_request_when_written(TestXmppStream stream, string filename, string size, string content_type, owned WrittenIqHandler handler) {
        ulong handler_id = 0;
        handler_id = stream.wrote_node.connect((outgoing) => {
            if (outgoing.name != "iq") return;
            StanzaNode? request = outgoing.get_subnode("request", NS_HTTP_UPLOAD_0);
            if (request == null) return;
            if (((!) request).get_attribute("filename") != filename) return;
            if (((!) request).get_attribute("size") != size) return;
            if (((!) request).get_attribute("content-type") != content_type) return;

            SignalHandler.disconnect(stream, handler_id);
            handler(outgoing);
        });
    }

    private static StanzaNode build_slot_result_for_request(StanzaNode request_iq, string url_get, string url_put) {
        var result_iq = new StanzaNode.build("iq").put_attribute("type", Xmpp.Iq.Stanza.TYPE_RESULT);
        string? id = request_iq.get_attribute("id");
        if (id != null) result_iq.put_attribute("id", (!) id);
        string? to = request_iq.get_attribute("to");
        if (to != null) result_iq.put_attribute("from", (!) to);

        var slot = new StanzaNode.build("slot", NS_HTTP_UPLOAD_0).add_self_xmlns();
        slot.put_node(new StanzaNode.build("get", NS_HTTP_UPLOAD_0).put_attribute("url", url_get));
        slot.put_node(new StanzaNode.build("put", NS_HTTP_UPLOAD_0).put_attribute("url", url_put));
        result_iq.put_node(slot);
        return result_iq;
    }

    private static void append_slot_header(StanzaNode result_iq, string name, string value) {
        StanzaNode? slot = result_iq.get_subnode("slot", NS_HTTP_UPLOAD_0);
        fail_if(slot == null, "slot result must contain slot node");
        if (slot == null) return;

        StanzaNode? put = ((!) slot).get_subnode("put", NS_HTTP_UPLOAD_0);
        fail_if(put == null, "slot result must contain put node");
        if (put == null) return;

        ((!) put).put_node(new StanzaNode.build("header", NS_HTTP_UPLOAD_0)
            .put_attribute("name", name)
            .put_node(new StanzaNode.text(value)));
    }

    private static void drain_pending_events() {
        for (int i = 0; i < 8; i++) {
            while (MainContext.default().pending()) {
                MainContext.default().iteration(false);
            }
        }
    }

    private static StanzaNode? find_legacy_omemo_message(TestXmppStream stream) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("encrypted", NS_OMEMO_LEGACY) != null) {
                return node;
            }
        }
        return null;
    }

    private static StanzaNode? find_omemo2_message(TestXmppStream stream) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name == "message" && node.get_subnode("encrypted", NS_OMEMO_V2) != null) {
                return node;
            }
        }
        return null;
    }

    private static StanzaNode? find_http_upload_slot_request(TestXmppStream stream) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name == "iq" && node.get_subnode("request", NS_HTTP_UPLOAD_0) != null) {
                return node;
            }
        }
        return null;
    }

    private static void assert_no_message_stanzas(TestXmppStream stream, string reason) {
        foreach (StanzaNode node in stream.written_nodes) {
            fail_if(node.name == "message", reason);
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

    private static void assert_no_cleartext_transfer_url_or_outer_file_stanzas(TestXmppStream stream, string download_url, string sensitive_body_url, string reason) {
        foreach (StanzaNode node in stream.written_nodes) {
            if (node.name != "message") continue;

            fail_if(node.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null,
                @"$(reason): unexpected outer SFS file-sharing element");
            fail_if(node.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI) != null,
                @"$(reason): unexpected outer SFS sources attachment");
            fail_if(node.get_subnode("attach-to", Xmpp.Xep.MessageAttaching.NS_URI) != null,
                @"$(reason): unexpected outer message-attachment element");
            fail_if(node.get_subnode("x", Xmpp.Xep.OutOfBandData.NS_URI) != null,
                @"$(reason): unexpected outer OOB URL element");

            StanzaNode? body_node = node.get_subnode("body");
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

    private static bool skip_if_local_https_sockets_unavailable() {
        TlsCertificate tls_cert;
        try {
            tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        } catch (Error e) {
            fail_if(true, @"Local HTTPS upload test certificate fixture must parse: $(e.message)");
            return false;
        }

        string error_message;
        if (local_https_test_sockets_available(tls_cert, out error_message)) return false;

        GLib.Test.skip("Local HTTPS upload test sockets unavailable: %s".printf(error_message));
        return true;
    }

    private static bool local_https_test_sockets_available(TlsCertificate tls_cert, out string error_message) {
        error_message = "";
        Soup.Server? probe = null;
        try {
            probe = new Soup.Server("server-header", "DinoX-OMEMO-HTTPS-Probe/1.0", null);
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

    private static Soup.Server start_https_upload_server(uint response_status, HttpsUploadCapture capture, TestXmppStream stream, out string upload_url, out string download_url, out TlsCertificate tls_cert) throws Error {
        tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        var server = new Soup.Server("server-header", "DinoX-OMEMO-HTTPS-Test/1.0", null);
        server.set_tls_certificate(tls_cert);
        server.add_handler("/upload/plain.bin", (srv, msg, path, query) => {
            capture.handled = true;
            capture.written_count_at_upload = stream.written_nodes.size;
            capture.method = msg.get_method();
            capture.content_type = msg.get_request_headers().get_one("Content-Type");
            capture.authorization = msg.get_request_headers().get_one("Authorization");
            capture.content_length = msg.get_request_headers().get_content_length();
            capture.body = copy_bytes(msg.get_request_body().flatten());
            msg.set_status(response_status, null);
            set_server_string_response(msg, "text/plain", "ok");
        });
        server.listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
        upload_url = get_https_server_url(server, "/upload/plain.bin");
        download_url = get_https_server_url(server, "/download/plain.bin");
        return server;
    }

    private static Soup.Server start_https_body_stream_cancel_server(BlockedBodyUploadCapture capture, TestXmppStream stream, out string upload_url, out string download_url, out TlsCertificate tls_cert) throws Error {
        tls_cert = new TlsCertificate.from_pem(TEST_TLS_CERT_PEM + TEST_TLS_KEY_PEM, -1);
        var server = new Soup.Server("server-header", "DinoX-OMEMO-HTTPS-Body-Cancel-Test/1.0", null);
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
        server.add_handler("/upload/blocking-omemo.bin", (srv, msg, path, query) => {
            capture.mark_handler_called();
            msg.set_status(500, null);
            set_server_string_response(msg, "text/plain", "unexpected complete body");
        });
        server.listen(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0), Soup.ServerListenOptions.HTTPS);
        upload_url = get_https_server_url(server, "/upload/blocking-omemo.bin");
        download_url = get_https_server_url(server, "/download/blocking-omemo.bin");
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

    private static bool bytes_equal(uint8[] expected, uint8[] actual) {
        if (expected.length != actual.length) return false;
        for (int i = 0; i < expected.length; i++) {
            if (expected[i] != actual[i]) return false;
        }
        return true;
    }

    private static void assert_bytes_equal(uint8[] expected, uint8[] actual, string reason) {
        fail_if_not_eq_int(expected.length, actual.length, reason);
        int length = int.min(expected.length, actual.length);
        for (int i = 0; i < length; i++) {
            if (expected[i] != actual[i]) {
                fail_if(true, @"$(reason): byte $(i) expected $(expected[i]) got $(actual[i])");
                return;
            }
        }
    }

    private static AesgcmUrlParts parse_aesgcm_url(string url) throws Error {
        if (!url.has_prefix("aesgcm://")) {
            throw new IOError.FAILED("aesgcm URL must use aesgcm:// scheme");
        }
        int fragment_index = url.index_of("#");
        if (fragment_index < 0) {
            throw new IOError.FAILED("aesgcm URL must carry IV and key in the fragment");
        }

        string url_without_scheme = url.substring("aesgcm://".length, fragment_index - "aesgcm://".length);
        string secret_hex = url.substring(fragment_index + 1);
        if (secret_hex.length != 88) {
            throw new IOError.FAILED("aesgcm URL secret must be 12-byte IV plus 32-byte key encoded as hex");
        }

        uint8[] secret = parse_hex_bytes(secret_hex);
        uint8[] iv = new uint8[12];
        uint8[] key = new uint8[32];
        for (int i = 0; i < 12; i++) iv[i] = secret[i];
        for (int i = 0; i < 32; i++) key[i] = secret[12 + i];

        return new AesgcmUrlParts("https://" + url_without_scheme, iv, key);
    }

    private static uint8[] parse_hex_bytes(string hex) throws Error {
        if (hex.length % 2 != 0) {
            throw new IOError.FAILED("hex string must have an even length");
        }
        uint8[] bytes = new uint8[hex.length / 2];
        for (int i = 0; i < bytes.length; i++) {
            int high = hex_nibble(hex[i * 2]);
            int low = hex_nibble(hex[i * 2 + 1]);
            if (high < 0 || low < 0) {
                throw new IOError.FAILED("hex string contains a non-hex character");
            }
            bytes[i] = (uint8) ((high << 4) | low);
        }
        return bytes;
    }

    private static int hex_nibble(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    private static uint8[] decrypt_aesgcm_with_attached_tag(uint8[] encrypted, uint8[] key, uint8[] iv) throws Error {
        var cipher = new Crypto.SymmetricCipher("AES256-GCM");
        cipher.set_key(key);
        cipher.set_iv(iv);
        var input = new MemoryInputStream.from_data(encrypted);
        var decrypted_stream = new ConverterInputStream(input, new Crypto.SymmetricCipherDecrypter((owned) cipher, 16));
        return read_all(decrypted_stream);
    }

    private static uint8[] read_all(InputStream stream) throws Error {
        var data = new GLib.ByteArray();
        uint8[] chunk = new uint8[4096];
        while (true) {
            ssize_t read = stream.read(chunk);
            if (read <= 0) break;
            data.append(chunk[0:(int) read]);
        }
        stream.close();
        return data.data;
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
        fail_if(!row.is_present(), "public OMEMO FileManager transfer must be present in the database");
        var persisted_state = (Dino.Entities.FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        fail_if(persisted_state != expected_state, reason);
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

    private static void assert_only_persisted_http_source_without_secret(Dino.Database db, Dino.Entities.FileTransfer file_transfer, string expected_url, string reason) {
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

    private static void cleanup_file(string path) {
        if (FileUtils.test(path, FileTest.EXISTS)) {
            FileUtils.remove(path);
        }
    }

    private class TestXmppStream : Xmpp.XmppStream {
        public signal void wrote_node(StanzaNode node);
        public signal void legacy_devicelist_held(StanzaNode request);

        public StanzaNode? last_written { get; private set; default = null; }
        public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode>();
        public Jid? hold_legacy_devicelist_for { get; set; default = null; }
        public Jid? hold_legacy_bundle_for { get; set; default = null; }
        public int legacy_bundle_request_count { get; private set; default = 0; }
        private StanzaNode? held_legacy_bundle_request = null;
        public int legacy_devicelist_request_count { get; private set;
            default = 0; }
        private StanzaNode? held_legacy_devicelist_request = null;

        public TestXmppStream(Jid remote_name) {
            base(remote_name);
        }

        public override async void connect() throws IOError {
        }

        public override async void disconnect() throws IOError {
        }

        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("test stream has no reader");
        }

        public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            last_written = node;
            written_nodes.add(node);
            wrote_node(node);
        }

        public override async void setup() throws IOError {
        }

        public void emit_iq_result(StanzaNode node) {
            received_iq_stanza(this, node);
        }

        public void emit_presence(StanzaNode node) {
            received_presence_stanza(this, node);
        }

        public bool maybe_hold_legacy_bundle_request(StanzaNode request, StanzaNode items) {
            if (hold_legacy_bundle_for == null || request.get_attribute("to") !=
                    ((!) hold_legacy_bundle_for).bare_jid.to_string() ||
                    !(items.get_attribute("node") ?? "").has_prefix(NS_OMEMO_LEGACY + ".bundles:")) return false;
            legacy_bundle_request_count++;
            held_legacy_bundle_request = request;
            return true;
        }

        public StanzaNode? take_held_legacy_bundle_request() {
            StanzaNode? request = held_legacy_bundle_request;
            held_legacy_bundle_request = null;
            return request;
        }

        public bool maybe_hold_legacy_devicelist_request(
                StanzaNode request, StanzaNode request_items) {
            if (hold_legacy_devicelist_for == null ||
                    request.get_attribute("to") !=
                        ((!) hold_legacy_devicelist_for).bare_jid.to_string() ||
                    request_items.get_attribute("node") !=
                        NS_OMEMO_LEGACY + ".devicelist") {
                return false;
            }
            legacy_devicelist_request_count++;
            if (held_legacy_devicelist_request != null) return false;

            held_legacy_devicelist_request = request;
            legacy_devicelist_held(request);
            return true;
        }

        public StanzaNode? take_held_legacy_devicelist_request() {
            StanzaNode? request = held_legacy_devicelist_request;
            held_legacy_devicelist_request = null;
            return request;
        }

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

        public BlockedBodyUploadInputStream(uint8[] first_chunk, Cancellable transfer_cancellable, BlockedBodyUploadCapture capture) {
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
                throw new IOError.FAILED("public OMEMO blocked upload stream read did not receive cancellable");
            }

            blocking_read_saw_cancellable = true;
            if (!cancel_thread_started) {
                cancel_thread_started = true;
                new Thread<void*>("omemo-http-body-cancel", () => {
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
                throw new IOError.FAILED("public OMEMO blocked upload stream read did not receive the transfer cancellable");
            }

            cancel_seen = true;
            throw new IOError.CANCELLED("transfer cancelled while public OMEMO upload request body was blocked");
        }

        public override bool close(Cancellable? cancellable = null) throws IOError {
            closed = true;
            return true;
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
    }

    private class AesgcmUrlParts : Object {
        public string https_url;
        public uint8[] iv;
        public uint8[] key;

        public AesgcmUrlParts(string https_url, owned uint8[] iv, owned uint8[] key) {
            this.https_url = https_url;
            this.iv = (owned) iv;
            this.key = (owned) key;
        }
    }
}

}
