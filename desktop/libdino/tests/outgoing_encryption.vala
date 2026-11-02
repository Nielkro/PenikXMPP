using Dino.Entities;
using Xmpp;

namespace Dino.Test {

class OutgoingEncryptionTest : Gee.TestCase {

    public OutgoingEncryptionTest() {
        base("OutgoingEncryption");
        add_test("OUTENC_plain_allows_plain_stanza", test_plain_allows_plain);
        add_test("OUTENC_plain_allows_retraction_control_stanza", test_plain_allows_retraction);
        add_test("OUTENC_plain_blocks_omemo_payload", test_plain_blocks_omemo);
        add_test("OUTENC_pgp_requires_openpgp_payload", test_pgp_requires_openpgp);
        add_test("OUTENC_omemo_requires_omemo_payload", test_omemo_requires_omemo);
        add_test("OUTENC_blocks_mixed_omemo_openpgp_payloads", test_blocks_mixed);
        add_test("INENC_plain_messages_are_allowed_in_encrypted_conversations", test_incoming_plain_allowed);
        add_test("INENC_encrypted_messages_must_match_conversation_mode", test_incoming_encrypted_must_match);
        add_test("INENC_plain_chat_receives_omemo_and_openpgp", test_incoming_encrypted_allowed_in_plain_chat);
        add_test("INENC_explicit_chat_encryption_rejects_other_protocol", test_incoming_explicit_chat_encryption);
        add_test("INENC_muc_and_private_muc_policy_stays_strict", test_incoming_muc_encryption);
        add_test("INENC_plain_chat_stores_decrypted_omemo", () => test_incoming_plain_chat_pipeline("authenticated OMEMO body"));
        add_test("INENC_plain_chat_keeps_local_omemo_failure_diagnostic", () => test_incoming_plain_chat_pipeline("[This OMEMO message could not be decrypted]"));
        add_test("INENC_plain_chat_filters_bodyless_omemo", () => test_incoming_plain_chat_pipeline(null));
        add_test("INENC_account_archive_provenance_is_account_scoped", test_account_archive_provenance);
        add_test("INENC_xep0374_archive_keeps_selected_omemo", () => test_incoming_plain_chat_pipeline(
            "verified historical PGP body", Encryption.OMEMO, Encryption.PGP, "openpgp:xep0374", true));
        add_test("INENC_own_xep0374_archive_keeps_selected_omemo", () => test_incoming_plain_chat_pipeline(
            "verified historical sent PGP body", Encryption.OMEMO, Encryption.PGP, "openpgp:xep0374", true, true));
        add_test("INENC_live_xep0374_keeps_strict_mode", () => test_incoming_plain_chat_pipeline(
            "verified live PGP body", Encryption.OMEMO, Encryption.PGP, "openpgp:xep0374", false, false, false));
        add_test("INENC_legacy_archive_keeps_strict_mode", () => test_incoming_plain_chat_pipeline(
            "verified historical legacy body", Encryption.OMEMO, Encryption.PGP, "openpgp:xep0027", true, false, false));
        add_test("INENC_omemo_archive_keeps_strict_mode", () => test_incoming_plain_chat_pipeline(
            "verified historical OMEMO body", Encryption.PGP, Encryption.OMEMO, null, true, false, false));
        add_test("INENC_policy_errors_are_rendered_as_specific_delivery_text", test_policy_error_text);
        add_test("GROUPCHAT_PM_recipient_unavailable_is_visible", test_groupchat_pm_recipient_unavailable_is_visible);
        add_test("RETRACTION_groupchat_prefers_room_stanza_id", test_groupchat_retraction_prefers_room_stanza_id);
        add_test("RETRACTION_groupchat_falls_back_to_origin_id", test_groupchat_retraction_falls_back_to_origin_id);
        add_test("RETRACTION_non_groupchat_keeps_origin_id", test_non_groupchat_retraction_keeps_origin_id);
        add_test("RETRACTION_live_muc_echo_updates_cached_room_stanza_id",
            test_live_muc_echo_updates_cached_room_stanza_id);
        add_test("RETRACTION_muc_correction_chain_uses_all_room_ids", test_muc_correction_chain_uses_all_room_ids);
        add_test("RETRACTION_muc_moderation_rejects_correction_chains", test_muc_moderation_rejects_correction_chains);
        add_test("RETRACTION_chat_correction_chain_uses_each_origin_id", test_chat_correction_chain_uses_each_origin_id);
        add_test("RETRACTION_revision_ids_require_complete_unique_chain", test_revision_ids_require_complete_unique_chain);
        add_test("RETRACTION_file_relation_uses_message_id_not_transport_info", test_file_relation_uses_message_id_not_transport_info);
        add_test("RETRACTION_reflected_chain_hides_content_item_once", test_reflected_chain_hides_content_item_once);
    }

    private void test_plain_allows_plain() {
        MessageStanza stanza = new MessageStanza("plain");
        stanza.body = "hello";
        string reason = "";
        fail_if_not(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.NONE, stanza, out reason), reason);
    }

    private void test_plain_allows_retraction() {
        MessageStanza stanza = new MessageStanza("retract");
        stanza.body = "This message was retracted.";
        Xmpp.Xep.MessageRetraction.set_retract_id(stanza, "original-message-id");
        string reason = "";
        fail_if_not(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.NONE, stanza, out reason),
            "XEP-0424 retraction control stanzas without encrypted payload must pass the outgoing guard: %s".printf(reason));
    }

    private void test_plain_blocks_omemo() {
        MessageStanza stanza = new MessageStanza("plain-omemo");
        stanza.stanza.put_node(new StanzaNode.build("encrypted", "eu.siacs.conversations.axolotl").add_self_xmlns());
        string reason = "";
        fail_if(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.NONE, stanza, out reason),
            "Unencrypted selection must not allow OMEMO payloads");
    }

    private void test_pgp_requires_openpgp() {
        MessageStanza stanza = new MessageStanza("pgp");
        stanza.stanza.put_node(new StanzaNode.build("openpgp", "urn:xmpp:openpgp:0").add_self_xmlns());
        string reason = "";
        fail_if_not(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.PGP, stanza, out reason), reason);

        MessageStanza plain_stanza = new MessageStanza("pgp-plain");
        fail_if(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.PGP, plain_stanza, out reason),
            "OpenPGP selection must require an OpenPGP payload");
    }

    private void test_omemo_requires_omemo() {
        MessageStanza stanza = new MessageStanza("omemo");
        stanza.stanza.put_node(new StanzaNode.build("encrypted", "urn:xmpp:omemo:2").add_self_xmlns());
        string reason = "";
        fail_if_not(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.OMEMO, stanza, out reason), reason);

        MessageStanza plain_stanza = new MessageStanza("omemo-plain");
        fail_if(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.OMEMO, plain_stanza, out reason),
            "OMEMO selection must require an OMEMO payload");
    }

    private void test_blocks_mixed() {
        MessageStanza stanza = new MessageStanza("mixed");
        stanza.stanza.put_node(new StanzaNode.build("encrypted", "eu.siacs.conversations.axolotl").add_self_xmlns());
        stanza.stanza.put_node(new StanzaNode.build("openpgp", "urn:xmpp:openpgp:0").add_self_xmlns());
        string reason = "";
        fail_if(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.OMEMO, stanza, out reason),
            "Stanzas with both OMEMO and OpenPGP payloads must be blocked");
        fail_if(MessageProcessor.outgoing_stanza_matches_encryption(Encryption.PGP, stanza, out reason),
            "Stanzas with both OMEMO and OpenPGP payloads must be blocked");
    }

    private void test_incoming_plain_allowed() {
        string reason = "";
        fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.NONE, Encryption.OMEMO, out reason), reason);
        fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.NONE, Encryption.PGP, out reason), reason);
        foreach (Conversation.Type type in new Conversation.Type[] {
                Conversation.Type.CHAT, Conversation.Type.GROUPCHAT,
                Conversation.Type.GROUPCHAT_PM }) {
            foreach (Encryption selected in new Encryption[] {
                    Encryption.NONE, Encryption.PGP, Encryption.OMEMO,
                    Encryption.UNKNOWN }) {
                fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(
                    Encryption.NONE, selected, out reason, type), reason);
                fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(
                    Encryption.UNKNOWN, selected, out reason, type), reason);
            }
        }
    }

    private void test_incoming_encrypted_must_match() {
        string reason = "";
        fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.OMEMO, Encryption.OMEMO, out reason), reason);
        fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.PGP, Encryption.PGP, out reason), reason);
        fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.PGP, Encryption.OMEMO, out reason),
            "Incoming OpenPGP must be dropped while the conversation expects OMEMO");
        fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.OMEMO, Encryption.PGP, out reason),
            "Incoming OMEMO must be dropped while the conversation expects OpenPGP");
        fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.PGP, Encryption.NONE, out reason),
            "Unspecified conversation types must retain the strict incoming policy");
        fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(Encryption.OMEMO, Encryption.NONE, out reason),
            "Unspecified conversation types must retain the strict incoming policy");
    }

    private void test_incoming_encrypted_allowed_in_plain_chat() {
        string reason = "stale rejection";
        fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(
            Encryption.OMEMO, Encryption.NONE, out reason, Conversation.Type.CHAT), reason);
        fail_if(reason != "", "Accepted incoming OMEMO must clear the rejection reason");
        fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(
            Encryption.PGP, Encryption.NONE, out reason, Conversation.Type.CHAT), reason);
        fail_if(reason != "", "Accepted incoming OpenPGP must clear the rejection reason");
    }

    private void test_incoming_explicit_chat_encryption() {
        string reason = "";
        fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(
            Encryption.OMEMO, Encryption.PGP, out reason, Conversation.Type.CHAT),
            "An explicit OpenPGP conversation must still reject incoming OMEMO");
        fail_if(reason == "", "Rejected encryption mismatches must explain their reason");
        fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(
            Encryption.PGP, Encryption.OMEMO, out reason, Conversation.Type.CHAT),
            "An explicit OMEMO conversation must still reject incoming OpenPGP");
        fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(
            Encryption.OMEMO, Encryption.UNKNOWN, out reason, Conversation.Type.CHAT),
            "Unknown conversation encryption must not imply the plaintext preference exception");
    }

    private void test_incoming_muc_encryption() {
        string reason = "";
        foreach (Conversation.Type type in new Conversation.Type[] {
                Conversation.Type.GROUPCHAT, Conversation.Type.GROUPCHAT_PM }) {
            fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(
                Encryption.OMEMO, Encryption.NONE, out reason, type),
                "MUCs and private MUC conversations must retain the strict plaintext policy");
            fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(
                Encryption.PGP, Encryption.NONE, out reason, type),
                "MUCs and private MUC conversations must retain the strict plaintext policy");
            fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(
                Encryption.OMEMO, Encryption.PGP, out reason, type),
                "MUCs and private MUC conversations must reject a different encrypted protocol");
            fail_if(MessageProcessor.incoming_message_matches_conversation_encryption(
                Encryption.PGP, Encryption.OMEMO, out reason, type),
                "MUCs and private MUC conversations must reject a different encrypted protocol");
            fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(
                Encryption.OMEMO, Encryption.OMEMO, out reason, type), reason);
            fail_if_not(MessageProcessor.incoming_message_matches_conversation_encryption(
                Encryption.PGP, Encryption.PGP, out reason, type), reason);
        }
    }

    private void test_account_archive_provenance() {
        try {
            var account = new Account(new Jid("alice@example.test"), "secret");
            var other = new Account(new Jid("other@example.test"), "secret");
            var peer = new Jid("bob@example.test/phone");
            var live = new MessageStanza("archive-context-live");
            live.from = peer;
            live.to = account.full_jid;
            live.stanza.put_node(new StanzaNode.build("delay", "urn:xmpp:delay")
                .add_self_xmlns().put_attribute("stamp", "2026-01-01T00:00:00Z"));
            fail_if(MessageProcessor.is_account_archive_message(account, live),
                "A delayed live message must not acquire the archive exception");
            live.add_flag(new Xmpp.Xep.MessageCarbons.MessageFlag(Xmpp.Xep.MessageCarbons.MessageFlag.TYPE_RECEIVED));
            fail_if(MessageProcessor.is_account_archive_message(account, live),
                "A Carbon alone must retain live encryption policy");

            var archive = new MessageStanza("archive-context-own");
            archive.from = peer;
            archive.to = account.full_jid;
            archive.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(account.bare_jid, new DateTime.now_utc(), "mam-1", "query-1"));
            fail_if_not(MessageProcessor.is_account_archive_message(account, archive),
                "An account's own validated archive must be recognized");
            fail_if(MessageProcessor.is_account_archive_message(other, archive),
                "The same archive flag must not authorize another account");
            archive.from = account.full_jid;
            archive.to = peer;
            fail_if_not(MessageProcessor.is_account_archive_message(account, archive),
                "Own sent archive messages must use the same account archive context");
            archive.from = peer;
            archive.to = other.full_jid;
            fail_if(MessageProcessor.is_account_archive_message(account, archive),
                "Archive messages must contain an endpoint belonging to the account");
            var missing_endpoint = new MessageStanza("archive-context-missing-endpoint");
            missing_endpoint.from = peer;
            missing_endpoint.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(account.bare_jid,
                new DateTime.now_utc(), "mam-missing", "query-missing"));
            fail_if(MessageProcessor.is_account_archive_message(account, missing_endpoint),
                "An archive message without both endpoints must be rejected");

            var foreign = new MessageStanza("archive-context-foreign");
            foreign.from = peer;
            foreign.to = account.full_jid;
            foreign.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(other.bare_jid, new DateTime.now_utc(), "mam-2", "query-2"));
            fail_if(MessageProcessor.is_account_archive_message(account, foreign),
                "A foreign archive must not authorize account history processing");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_incoming_plain_chat_pipeline(string? processed_body,
            Encryption selected = Encryption.NONE, Encryption decrypted_encryption = Encryption.OMEMO,
            string? protocol = null, bool account_archive = false, bool own_sent = false, bool expect_store = true) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-incoming-encryption-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "incoming-encryption-test");
            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Conversation(new Jid("bob@example.test"),
                account, Conversation.Type.CHAT);
            conversation.encryption = selected;
            conversation.persist((!) db);

            var stream_interactor = new StreamInteractor.for_tests((!) db);
            MessageStorage.start(stream_interactor, (!) db);
            MessageProcessor.start(stream_interactor, (!) db);
            MessageProcessor processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            var decrypt_result = new IncomingDecryptResultTestListener(processed_body, decrypted_encryption, protocol);
            var after_store = new IncomingEncryptionStopAfterStore();
            processor.received_pipeline.connect(decrypt_result);
            processor.received_pipeline.connect(after_store);

            var message = new Message("untrusted wire fallback");
            message.account = account;
            message.counterpart = conversation.counterpart.with_resource("phone");
            message.ourpart = account.bare_jid.with_resource("desktop");
            message.direction = own_sent ? Message.DIRECTION_SENT : Message.DIRECTION_RECEIVED;
            message.type_ = Message.Type.CHAT;
            message.time = new DateTime.now_utc();
            message.local_time = message.time;
            message.stanza_id = Uuid.string_random();
            var stanza = new MessageStanza((!) message.stanza_id);
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.from = own_sent ? message.ourpart : message.counterpart;
            stanza.to = own_sent ? message.counterpart : message.ourpart;
            stanza.body = message.body;
            if (decrypted_encryption == Encryption.PGP) {
                stanza.stanza.put_node(new StanzaNode.build(protocol == "openpgp:xep0027" ? "x" : "openpgp",
                    protocol == "openpgp:xep0027" ? "jabber:x:encrypted" : "urn:xmpp:openpgp:0").add_self_xmlns());
            } else {
                stanza.stanza.put_node(new StanzaNode.build("encrypted",
                    "eu.siacs.conversations.axolotl").add_self_xmlns());
            }
            if (account_archive) {
                stanza.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(account.bare_jid,
                    message.time, "mam-" + message.stanza_id, "archive-pipeline"));
            }
            if (!expect_store) {
                GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                    "*dropping incoming encrypted message because it does not match*");
            }

            bool stopped = false;
            bool completed = false;
            var loop = new MainLoop();
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            processor.received_pipeline.run.begin(message, stanza,
                conversation, null, (obj, res) => {
                    stopped = processor.received_pipeline.run.end(res);
                    completed = true;
                    if (timeout_id != 0) {
                        Source.remove(timeout_id);
                        timeout_id = 0;
                    }
                    loop.quit();
                });
            if (!completed) loop.run();
            if (!expect_store) GLib.Test.assert_expected_messages();
            if (timeout_id != 0) Source.remove(timeout_id);
            fail_if_not(completed, "The real incoming message pipeline must finish");
            fail_if_not(stopped, "The test fixture must stop at the empty filter or after STORE");
            fail_if_not(decrypt_result.ran, "The DECRYPT boundary must run before encryption policy");
            fail_if(after_store.ran != (processed_body != null && expect_store),
                "Only messages with processed bodies may reach the real STORE listener");

            if (processed_body != null && expect_store) {
                Message? stored = ((!) db).get_message_by_id(message.id);
                fail_if(stored == null,
                    "Accepted incoming content must reach the real STORE listener");
                if (stored != null) {
                    fail_if(((!) stored).body != processed_body,
                        "STORE must keep the decryptor result, never the untrusted wire fallback");
                    fail_if(((!) stored).encryption != decrypted_encryption,
                        "The stored message must retain its original encryption tag");
                    fail_if(((!) stored).encryption_protocol != protocol,
                        "The stored message must retain its original encryption protocol");
                    fail_if(((!) stored).direction != message.direction,
                        "The stored archive message must retain its sent/received direction");
                }
            } else {
                fail_if(((!) db).message.select().count() != 0,
                    "Rejected or bodyless messages must not reach persistence");
            }
            fail_if(conversation.encryption != selected,
                "Receiving history must not change the live outgoing encryption preference");
            int? persisted_encryption = ((!) db).conversation.select(
                    { ((!) db).conversation.encryption })
                    .with(((!) db).conversation.id, "=", conversation.id)
                    .single().row().get(((!) db).conversation.encryption);
            fail_if(persisted_encryption != (int) selected,
                "Receiving history must not change the persisted outgoing encryption preference");
        } catch (Error e) {
            fail_if_reached("Unexpected incoming encryption pipeline error: %s".printf(e.message));
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_policy_error_text() {
        StanzaNode policy_node = new StanzaNode.build("encryption-policy", "im.dinox:errors:encryption-policy:0")
            .add_self_xmlns()
            .put_attribute("expected", "openpgp")
            .put_attribute("received", "omemo");
        ErrorStanza error = new ErrorStanza.build(
            ErrorStanza.TYPE_MODIFY,
            ErrorStanza.CONDITION_NOT_ACCEPTABLE,
            "Recipient expects OpenPGP encryption",
            policy_node);

        string text = MessageProcessor.get_delivery_error_text(error);
        fail_if(text.index_of("OpenPGP") < 0, "Policy delivery text must mention the expected encryption mode");
        fail_if(text.index_of("OMEMO") >= 0, "Sender guidance must focus on the expected recipient mode");
    }

    private void test_groupchat_pm_recipient_unavailable_is_visible() {
        ErrorStanza unavailable = new ErrorStanza.build(
            ErrorStanza.TYPE_CANCEL,
            ErrorStanza.CONDITION_RECIPIENT_UNAVAILABLE,
            "Recipient unavailable",
            null);

        var direct_message = new Message("direct");
        direct_message.type_ = Message.Type.CHAT;
        direct_message.marked = Message.Marked.SENT;
        MessageProcessor.apply_delivery_error(direct_message, unavailable);
        fail_if(direct_message.marked != Message.Marked.SENT,
            "recipient-unavailable must retain the existing offline-chat behavior for normal CHAT");

        var private_muc_message = new Message("private MUC");
        private_muc_message.type_ = Message.Type.GROUPCHAT_PM;
        private_muc_message.marked = Message.Marked.SENT;
        MessageProcessor.apply_delivery_error(private_muc_message, unavailable);
        fail_if(private_muc_message.marked != Message.Marked.ERROR,
            "recipient-unavailable must be visible as ERROR for GROUPCHAT_PM");
        fail_if(private_muc_message.delivery_error_text == null ||
                ((!) private_muc_message.delivery_error_text).index_of("Recipient unavailable") < 0,
            "GROUPCHAT_PM delivery errors must retain the server-provided reason");
    }

    private void test_groupchat_retraction_prefers_room_stanza_id() {
        var message = new Message("groupchat");
        message.stanza_id = "origin-id";
        message.server_id = "room-stanza-id";

        string? selected = MessageDeletion.get_retraction_reference_id(
            Conversation.Type.GROUPCHAT, message);
        fail_if(selected != "room-stanza-id",
            "MUC retractions must reference the room-assigned stanza-id");

        MessageStanza stanza = new MessageStanza("retract-groupchat");
        Xmpp.Xep.MessageRetraction.set_retract_id(stanza, (!) selected);
        fail_if(Xmpp.Xep.MessageRetraction.get_retract_id(stanza) != "room-stanza-id",
            "The serialized XEP-0424 retraction must carry the room-assigned stanza-id");
    }

    private void test_groupchat_retraction_falls_back_to_origin_id() {
        var message = new Message("groupchat fallback");
        message.stanza_id = "origin-id";
        message.server_id = "";

        string? selected = MessageDeletion.get_retraction_reference_id(
            Conversation.Type.GROUPCHAT, message);
        fail_if(selected != "origin-id",
            "MUC retractions must retain the origin-id fallback for rooms without stable stanza IDs");
    }

    private void test_non_groupchat_retraction_keeps_origin_id() {
        var message = new Message("direct");
        message.stanza_id = "origin-id";
        message.server_id = "server-id";
        message.edit_to = "chain-root-id";

        string? direct_selected = MessageDeletion.get_retraction_reference_id(
            Conversation.Type.CHAT, message);
        fail_if(direct_selected != "origin-id",
            "1:1 correction retractions must reference this revision's message/origin ID, not edit_to");

        string? private_muc_selected = MessageDeletion.get_retraction_reference_id(
            Conversation.Type.GROUPCHAT_PM, message);
        fail_if(private_muc_selected != "origin-id",
            "private MUC correction retractions must reference this revision's message/origin ID");
    }

    private void test_live_muc_echo_updates_cached_room_stanza_id() {
        const string ORIGIN_ID = "2cdaf631-48ce-4d88-b2f6-920114518559";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-muc-retraction-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "muc-retraction-echo-test");

            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var room = new Jid("room@conference.example.test");
            var conversation = new Conversation(room, account,
                Conversation.Type.GROUPCHAT);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            MessageProcessor.start(stream_interactor, (!) db);
            MessageStorage.start(stream_interactor, (!) db);
            Calls.start(stream_interactor, (!) db);
            ConversationManager.start(stream_interactor, (!) db);
            PresenceManager.start(stream_interactor, (!) db);
            MucManager.start(stream_interactor, (!) db);
            stream_interactor.module_manager.initialize(account);

            var fake_stream = new RetractionBuildTestXmppStream(
                new Jid("example.test"));
            attach_retraction_stream_modules(stream_interactor, account,
                fake_stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, fake_stream);
            Xep.Muc.Flag? flag = fake_stream.get_flag(Xep.Muc.Flag.IDENTITY);
            if (flag == null) {
                throw new IOError.FAILED(
                    "MUC echo test setup must attach a MUC flag");
            }
            ((!) flag).set_muc_nick(room.with_resource("Alice"));

            var outgoing = new Message("fresh MUC message");
            outgoing.account = account;
            outgoing.counterpart = room;
            outgoing.ourpart = room.with_resource("Alice");
            outgoing.direction = Message.DIRECTION_SENT;
            outgoing.type_ = Message.Type.GROUPCHAT;
            outgoing.time = new DateTime.now_utc();
            outgoing.local_time = outgoing.time;
            outgoing.marked = Message.Marked.SENT;
            outgoing.stanza_id = ORIGIN_ID;

            MessageStorage storage = stream_interactor.get_module<MessageStorage>(
                MessageStorage.IDENTITY);
            storage.add_message(outgoing, conversation);

            var echo = new Message("fresh MUC message");
            echo.account = account;
            echo.counterpart = room;
            echo.ourpart = outgoing.ourpart;
            echo.direction = Message.DIRECTION_SENT;
            echo.type_ = Message.Type.GROUPCHAT;
            var echo_stanza = new MessageStanza("server-rewritten-wire-id");
            echo_stanza.from = outgoing.ourpart;
            echo_stanza.type_ = MessageStanza.TYPE_GROUPCHAT;
            echo_stanza.body = echo.body;
            Xep.UniqueStableStanzaIDs.set_origin_id(echo_stanza, ORIGIN_ID);
            echo_stanza.stanza.put_node(new StanzaNode.build("stanza-id",
                    Xep.UniqueStableStanzaIDs.NS_URI).add_self_xmlns()
                .put_attribute("id", "room-stanza-id")
                .put_attribute("by", room.to_string()));
            MessageProcessor.assign_sender_ids(echo, echo_stanza);

            fail_if(echo.stanza_id != ORIGIN_ID ||
                    echo.sender_stanza_id != "server-rewritten-wire-id",
                "a rewritten MUC echo must retain its origin id separately");
            fail_if(storage.get_message_by_stanza_id((!) echo.stanza_id,
                    conversation) != outgoing,
                "the normalized MUC echo id must resolve the live outgoing message");

            MessageProcessor processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            bool stopped = false;
            bool completed = false;
            var loop = new MainLoop();
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            processor.received_pipeline.run.begin(echo, echo_stanza,
                conversation, null, (obj, res) => {
                    stopped = processor.received_pipeline.run.end(res);
                    completed = true;
                    if (timeout_id != 0) {
                        Source.remove(timeout_id);
                        timeout_id = 0;
                    }
                    loop.quit();
                });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            fail_if_not(completed,
                "the reflected MUC message pipeline must complete");
            fail_if_not(stopped,
                "the reflected MUC message must stop as a stable-ID duplicate");
            fail_if(outgoing.marked != Message.Marked.RECEIVED,
                "the MUC self-echo must mark the exact live outgoing message as delivered before deduplication");
            fail_if(outgoing.server_id != "room-stanza-id",
                "the live MessageItem object must receive the room stanza-id from its echo");
            fail_if(storage.get_message_by_server_id("room-stanza-id",
                    conversation) != outgoing,
                "the room stanza-id cache must resolve to the live outgoing Message object");
            fail_if(MessageDeletion.get_retraction_reference_id(
                    Conversation.Type.GROUPCHAT, outgoing) != "room-stanza-id",
                "deleting the fresh live MUC message must use its room stanza-id");

            storage.update_server_id(outgoing.id, "conflicting-room-stanza-id",
                conversation);
            fail_if(outgoing.server_id != "room-stanza-id",
                "a later conflicting echo must not replace an established stable room ID");
        } catch (Error e) {
            fail_if_reached(@"Live MUC retraction echo test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_muc_correction_chain_uses_all_room_ids() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-muc-correction-retraction-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        StreamInteractor? stream_interactor = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "muc-correction-retraction-test");

            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var other_account = new Account(new Jid("other@example.test"), "secret");
            other_account.persist((!) db);
            var room = new Jid("room@conference.example.test");
            var other_room = new Jid("other@conference.example.test");
            var conversation = new Conversation(room, account,
                Conversation.Type.GROUPCHAT);
            conversation.send_typing = Conversation.Setting.OFF;
            conversation.persist((!) db);
            stream_interactor = new StreamInteractor.for_tests((!) db);
            MessageProcessor.start((!) stream_interactor, (!) db);
            MessageStorage.start((!) stream_interactor, (!) db);
            Calls.start((!) stream_interactor, (!) db);
            ConversationManager.start((!) stream_interactor, (!) db);
            PresenceManager.start((!) stream_interactor, (!) db);
            MucManager.start((!) stream_interactor, (!) db);
            ((!) stream_interactor).add_module(FileManager.create_for_tests());
            ContentItemStore.start((!) stream_interactor, (!) db);
            MessageDeletion.start((!) stream_interactor, (!) db);
            MessageStorage storage = ((!) stream_interactor).get_module<MessageStorage>(
                MessageStorage.IDENTITY);
            DateTime base_time = new DateTime.from_unix_utc(1700000000);

            Message s0 = persist_retraction_test_message((!) db, account,
                room, room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "S0", "room-S0", null, base_time);
            Message s1 = persist_retraction_test_message((!) db, account,
                room, room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "S1", "room-S1", "S0",
                base_time.add_seconds(1));
            Message s2 = persist_retraction_test_message((!) db, account,
                room, room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "S2", "room-S2", "S0",
                base_time.add_seconds(2));

            // Same chain root in another sender/account/conversation must not
            // leak into the selected message's physical revision chain.
            persist_retraction_test_message((!) db, account,
                room.with_resource("Mallory"), room.with_resource("Alice"),
                Message.DIRECTION_RECEIVED, Message.Type.GROUPCHAT,
                "X-sender", "room-X-sender", "S0",
                base_time.add_seconds(3));
            persist_retraction_test_message((!) db, account,
                other_room, other_room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "X-room", "room-X-room", "S0", base_time.add_seconds(4));
            persist_retraction_test_message((!) db, other_account,
                room, room.with_resource("Other"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "X-account", "room-X-account", "S0",
                base_time.add_seconds(5));
            persist_retraction_test_message((!) db, account,
                room.with_resource("Mallory"), room.with_resource("Alice"),
                Message.DIRECTION_RECEIVED, Message.Type.GROUPCHAT,
                "S0", "room-X-root-collision", null,
                base_time.add_seconds(6));

            Gee.List<Message> chain = storage.get_revision_chain(conversation, s2);
            fail_if(chain.size != 3,
                "MUC chain must contain only S0/S1/S2 from the same account, room and sender");
            fail_if(chain[0].id != s0.id || chain[1].id != s1.id ||
                    chain[2].id != s2.id,
                "MUC physical revisions must be ordered S0, S1, S2");

            Gee.List<string> ids;
            fail_if_not(MessageDeletion.try_get_complete_retraction_reference_ids(
                    Conversation.Type.GROUPCHAT, true, chain, out ids),
                "A complete SID-capable MUC chain must be globally retractable");
            fail_if(ids.size != 3 || ids[0] != "room-S0" ||
                    ids[1] != "room-S1" || ids[2] != "room-S2",
                "Every MUC revision must use its own room-assigned stanza ID in chain order");

            var fake_stream = new RetractionBuildTestXmppStream(
                new Jid("example.test"));
            ((!) stream_interactor).module_manager.initialize(account);
            attach_retraction_stream_modules((!) stream_interactor,
                account, fake_stream);
            ((!) stream_interactor).connection_manager
                .set_connected_stream_for_tests(account, fake_stream);
            MessageProcessor processor = ((!) stream_interactor)
                .get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            var built_retraction_ids = new Gee.ArrayList<string>();
            processor.pre_message_send.connect((control_message, stanza,
                    sent_conversation) => {
                string? retraction_id = Xmpp.Xep.MessageRetraction
                    .get_retract_id(stanza);
                if (retraction_id != null) {
                    built_retraction_ids.add((!) retraction_id);
                }
            });

            int content_item_id = (int) ((!) db).add_content_item(conversation,
                base_time, base_time, 1, s2.id, false);
            var displayed_item = new MessageItem(s2, conversation,
                content_item_id);
            MessageDeletion deletion = ((!) stream_interactor)
                .get_module<MessageDeletion>(MessageDeletion.IDENTITY);
            fail_if_not(deletion.delete_globally(conversation,
                    displayed_item),
                "A complete MUC revision chain must be dispatched globally");
            drain_retraction_test_context();

            fail_if(built_retraction_ids.size != 3 ||
                    built_retraction_ids[0] != "room-S0" ||
                    built_retraction_ids[1] != "room-S1" ||
                    built_retraction_ids[2] != "room-S2",
                "delete_globally must build exactly one XEP-0424 control stanza for each unique MUC revision");

            persist_retraction_test_message((!) db, account,
                room, room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "P0", "room-P0", null,
                base_time.add_seconds(10));
            Message p1 = persist_retraction_test_message((!) db, account,
                room, room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "P1", null, "P0",
                base_time.add_seconds(11));
            int pending_item_id = (int) ((!) db).add_content_item(
                conversation, p1.time, p1.local_time, 1, p1.id, false);
            var pending_item = new MessageItem(p1, conversation,
                pending_item_id);

            fail_if(deletion.can_delete_for_everyone(conversation,
                    pending_item),
                "Delete for everyone must stay unavailable until every MUC revision has its room ID");
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*Refusing incomplete global retraction*");
            bool pending_deleted = deletion.delete_globally(conversation,
                pending_item);
            GLib.Test.assert_expected_messages();
            fail_if(pending_deleted,
                "The backend must reject a stale global-delete request for an incomplete chain");
            fail_if(built_retraction_ids.size != 3,
                "An incomplete chain must not send a partial set of retraction stanzas");
            bool? pending_hidden = ((!) db).content_item.select(
                    {((!) db).content_item.hide})
                .with(((!) db).content_item.id, "=", pending_item_id)
                .single().row().get(((!) db).content_item.hide);
            fail_if(pending_hidden == null || ((!) pending_hidden),
                "A rejected global deletion must not hide the message locally");
        } catch (Error e) {
            fail_if_reached(@"MUC correction retraction-chain test failed: $(e.message)");
        } finally {
            if (stream_interactor != null) {
                MucManager? muc_manager = ((!) stream_interactor)
                    .get_module<MucManager>(MucManager.IDENTITY);
                if (muc_manager != null) ((!) muc_manager).shutdown();
            }
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_muc_moderation_rejects_correction_chains() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-muc-moderation-chain-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        StreamInteractor? stream_interactor = null;
        Account? account = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "muc-moderation-chain-test");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            MessageProcessor.start((!) stream_interactor, (!) db);
            MessageStorage.start((!) stream_interactor, (!) db);
            EntityInfo.start((!) stream_interactor, (!) db);
            Calls.start((!) stream_interactor, (!) db);
            ConversationManager.start((!) stream_interactor, (!) db);
            PresenceManager.start((!) stream_interactor, (!) db);
            MucManager.start((!) stream_interactor, (!) db);
            ((!) stream_interactor).add_module(FileManager.create_for_tests());
            ContentItemStore.start((!) stream_interactor, (!) db);
            MessageCorrection.start((!) stream_interactor, (!) db);
            Replies.start((!) stream_interactor, (!) db);
            MessageDeletion.start((!) stream_interactor, (!) db);

            account = new Account(new Jid("alice@example.test"), "secret");
            ((!) account).enabled = true;
            ((!) account).persist((!) db);
            ((!) stream_interactor).module_manager.initialize((!) account);
            ((!) stream_interactor).account_added((!) account);

            var room = new Jid("room@conference.example.test");
            var conversation = new Conversation(room, (!) account,
                Conversation.Type.GROUPCHAT);
            conversation.nickname = "Alice";
            conversation.send_typing = Conversation.Setting.OFF;
            conversation.persist((!) db);

            const string MODERATION_CAPS =
                "muc-moderation-correction-chain-test";
            ((!) db).entity.upsert()
                .value<int>(((!) db).entity.account_id, ((!) account).id,
                    true)
                .value<int>(((!) db).entity.jid_id,
                    ((!) db).get_jid_id(room), true)
                .value<string>(((!) db).entity.resource, "", true)
                .value<string>(((!) db).entity.caps_hash,
                    MODERATION_CAPS)
                .value<long>(((!) db).entity.last_seen,
                    (long) (new DateTime.now_utc()).to_unix())
                .perform();
            ((!) db).entity_feature.insert()
                .value<string>(((!) db).entity_feature.entity,
                    MODERATION_CAPS)
                .value<string>(((!) db).entity_feature.feature,
                    Xmpp.Xep.MessageModeration.NS_URI)
                .perform();

            var fake_stream = new RetractionBuildTestXmppStream(
                new Jid("example.test"));
            attach_retraction_stream_modules((!) stream_interactor,
                (!) account, fake_stream);
            ((!) stream_interactor).connection_manager
                .set_connected_stream_for_tests((!) account, fake_stream);

            Xmpp.Xep.Muc.Flag? flag = fake_stream.get_flag(
                Xmpp.Xep.Muc.Flag.IDENTITY);
            fail_if(flag == null,
                "Moderation test setup must attach a MUC flag");
            ((!) flag).set_muc_nick(room.with_resource("Alice"));
            fake_stream.emit_presence(
                build_retraction_moderator_self_presence(room,
                    ((!) account).full_jid));
            drain_retraction_test_context();
            fail_if(((!) stream_interactor).get_module<MucManager>(
                    MucManager.IDENTITY).get_own_role(conversation) !=
                    Xmpp.Xep.Muc.Role.MODERATOR,
                "The test occupant must be established as the live room moderator");

            DateTime base_time = new DateTime.from_unix_utc(1700000500);
            persist_retraction_test_message((!) db,
                (!) account, room.with_resource("Mallory"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "foreign-S0", "room-foreign-S0",
                null, base_time);
            persist_retraction_test_message((!) db, (!) account,
                room.with_resource("Mallory"), room.with_resource("Alice"),
                Message.DIRECTION_RECEIVED, Message.Type.GROUPCHAT,
                "foreign-S1", "room-foreign-S1", "foreign-S0",
                base_time.add_seconds(1));
            Message s2 = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("Mallory"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "foreign-S2", "room-foreign-S2",
                "foreign-S0", base_time.add_seconds(2));
            int content_item_id = (int) ((!) db).add_content_item(
                conversation, base_time, base_time, 1, s2.id, false);
            var displayed_item = new MessageItem(s2, conversation,
                content_item_id);
            MessageDeletion deletion = ((!) stream_interactor)
                .get_module<MessageDeletion>(MessageDeletion.IDENTITY);

            fail_if(deletion.can_delete_for_everyone(conversation,
                    displayed_item),
                "A corrected foreign message must not offer a non-atomic XEP-0425 batch");
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*Refusing incomplete MUC moderation*");
            fail_if(deletion.delete_globally(conversation, displayed_item),
                "The backend must reject corrected foreign moderation even after a stale dialog");
            GLib.Test.assert_expected_messages();
            fail_if(!fake_stream.moderation_ids.is_empty,
                "Rejecting a correction chain must happen before any partial moderation IQ");
            bool? hidden = ((!) db).content_item.select(
                    {((!) db).content_item.hide})
                .with(((!) db).content_item.id, "=", content_item_id)
                .single().row().get(((!) db).content_item.hide);
            fail_if(hidden == null || ((!) hidden),
                "A rejected corrected-message moderation must remain visible");

            Message single = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("Single"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "single", "room-single", null,
                base_time.add_seconds(4));
            int single_item_id = (int) ((!) db).add_content_item(
                conversation, single.time, single.local_time, 1,
                single.id, false);
            var single_item = new MessageItem(single, conversation,
                single_item_id);
            fail_if_not(deletion.can_delete_for_everyone(conversation,
                    single_item),
                "An unedited foreign message must remain moderatable");
            fail_if_not(deletion.delete_globally(conversation, single_item),
                "A single-revision moderation plan must be dispatched");
            drain_retraction_test_context();
            fail_if(fake_stream.moderation_ids.size != 1 ||
                    fake_stream.moderation_ids[0] != "room-single",
                "Unedited moderation must use its one room-assigned stanza ID");
            fail_if(!fake_stream.moderation_payloads_valid,
                "The XEP-0425 request must target the room and contain its XEP-0424 retract child");
            bool? single_hidden = ((!) db).content_item.select(
                    {((!) db).content_item.hide})
                .with(((!) db).content_item.id, "=", single_item_id)
                .single().row().get(((!) db).content_item.hide);
            fail_if(single_hidden == null || !((!) single_hidden),
                "A confirmed single-revision moderation must hide the ContentItem");

            fake_stream.fail_moderation_id = "room-denied";
            Message denied = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("Denied"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "denied", "room-denied", null,
                base_time.add_seconds(6));
            int denied_item_id = (int) ((!) db).add_content_item(
                conversation, denied.time, denied.local_time, 1,
                denied.id, false);
            var denied_item = new MessageItem(denied, conversation,
                denied_item_id);
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*MUC moderation did not confirm every revision*");
            fail_if_not(deletion.delete_globally(conversation, denied_item),
                "A complete moderation plan must be accepted for asynchronous dispatch");
            drain_retraction_test_context();
            GLib.Test.assert_expected_messages();
            bool? denied_hidden = ((!) db).content_item.select(
                    {((!) db).content_item.hide})
                .with(((!) db).content_item.id, "=", denied_item_id)
                .single().row().get(((!) db).content_item.hide);
            fail_if(denied_hidden == null || ((!) denied_hidden),
                "A rejected single-revision moderation must not be reported as locally removed");
            fake_stream.fail_moderation_id = null;

            MessageProcessor processor = ((!) stream_interactor)
                .get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            var built_retraction_ids = new Gee.ArrayList<string>();
            processor.pre_message_send.connect((control_message, stanza,
                    sent_conversation) => {
                string? retraction_id = Xmpp.Xep.MessageRetraction
                    .get_retract_id(stanza);
                if (retraction_id != null) {
                    built_retraction_ids.add((!) retraction_id);
                }
            });

            Message async_confirmed = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("AsyncConfirmed"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "async-confirmed",
                "room-async-confirmed", null, base_time.add_seconds(12));
            int async_confirmed_item_id = (int) ((!) db).add_content_item(
                conversation, async_confirmed.time, async_confirmed.local_time,
                1, async_confirmed.id, false);
            var async_confirmed_item = new MessageItem(async_confirmed,
                conversation, async_confirmed_item_id);
            MessageDeletionItemResult async_confirmed_result =
                run_detailed_deletion(deletion, conversation,
                    async_confirmed_item);
            fail_if(!async_confirmed_result.success ||
                    async_confirmed_result.mode !=
                        MessageDeletionGlobalMode.MODERATION ||
                    !async_confirmed_result.dispatch_attempted ||
                    !async_confirmed_result.dispatch_accepted ||
                    async_confirmed_result.server_confirmed == null ||
                    !((!) async_confirmed_result.server_confirmed) ||
                    async_confirmed_result.attempted_request_count != 1 ||
                    async_confirmed_result.confirmed_request_count != 1 ||
                    !retraction_test_item_is_hidden((!) db,
                        async_confirmed_item_id),
                "Detailed moderation must report the terminal positive IQ result and hide only then");

            fake_stream.fail_moderation_id = "room-async-denied";
            Message async_denied = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("AsyncDenied"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "async-denied", "room-async-denied",
                null, base_time.add_seconds(13));
            int async_denied_item_id = (int) ((!) db).add_content_item(
                conversation, async_denied.time, async_denied.local_time,
                1, async_denied.id, false);
            var async_denied_item = new MessageItem(async_denied,
                conversation, async_denied_item_id);
            MessageDeletionItemResult async_denied_result =
                run_detailed_deletion(deletion, conversation,
                    async_denied_item);
            fail_if(async_denied_result.success ||
                    async_denied_result.status !=
                        MessageDeletionItemStatus.SERVER_REJECTED ||
                    !async_denied_result.dispatch_attempted ||
                    async_denied_result.dispatch_accepted ||
                    async_denied_result.server_confirmed == null ||
                    ((!) async_denied_result.server_confirmed) ||
                    retraction_test_item_is_hidden((!) db,
                        async_denied_item_id),
                "Detailed moderation must expose a negative IQ result and leave the row visible");
            fake_stream.fail_moderation_id = null;

            Message async_own = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT, "async-own",
                "room-async-own", null, base_time.add_seconds(14));
            int async_own_item_id = (int) ((!) db).add_content_item(
                conversation, async_own.time, async_own.local_time, 1,
                async_own.id, false);
            var async_own_item = new MessageItem(async_own, conversation,
                async_own_item_id);
            int own_retractions_before = built_retraction_ids.size;
            MessageDeletionItemResult async_own_result =
                run_detailed_deletion(deletion, conversation, async_own_item);
            fail_if(!async_own_result.success || async_own_result.mode !=
                        MessageDeletionGlobalMode.RETRACTION ||
                    !async_own_result.dispatch_accepted ||
                    async_own_result.server_confirmed != null ||
                    async_own_result.accepted_request_count != 1 ||
                    built_retraction_ids.size != own_retractions_before + 1 ||
                    built_retraction_ids[own_retractions_before] !=
                        "room-async-own" ||
                    !retraction_test_item_is_hidden((!) db,
                        async_own_item_id),
                "Detailed own retraction must distinguish local dispatch acceptance from server confirmation");

            Message preflight_valid = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("PreflightValid"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "preflight-valid",
                "room-preflight-valid", null, base_time.add_seconds(15));
            int preflight_valid_item_id = (int) ((!) db).add_content_item(
                conversation, preflight_valid.time, preflight_valid.local_time,
                1, preflight_valid.id, false);
            var preflight_valid_item = new MessageItem(preflight_valid,
                conversation, preflight_valid_item_id);
            Message preflight_root = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "preflight-root", "room-preflight-root", null,
                base_time.add_seconds(16));
            int preflight_root_item_id = (int) ((!) db).add_content_item(
                conversation, preflight_root.time, preflight_root.local_time,
                1, preflight_root.id, false);
            var preflight_root_item = new MessageItem(preflight_root,
                conversation, preflight_root_item_id);
            var invalid_snapshot = new Gee.ArrayList<ContentItem>();
            invalid_snapshot.add(preflight_valid_item);
            invalid_snapshot.add(displayed_item);
            invalid_snapshot.add(preflight_root_item);
            int preflight_moderations_before = fake_stream.moderation_ids.size;
            int preflight_retractions_before = built_retraction_ids.size;
            MessageDeletionBatchResult preflight_result = run_deletion_batch(
                deletion, conversation, invalid_snapshot);
            fail_if(preflight_result.preflight_passed ||
                    preflight_result.success || preflight_result.partial_success ||
                    preflight_result.requested_count != 3 ||
                    preflight_result.succeeded_count != 0 ||
                    preflight_result.failed_count != 1 ||
                    preflight_result.not_attempted_count != 2 ||
                    preflight_result.attempted_request_count != 0 ||
                    preflight_result.item_results[0].status !=
                        MessageDeletionItemStatus.NOT_ATTEMPTED ||
                    preflight_result.item_results[1].status !=
                        MessageDeletionItemStatus.PREFLIGHT_REJECTED ||
                    preflight_result.item_results[2].status !=
                        MessageDeletionItemStatus.NOT_ATTEMPTED ||
                    fake_stream.moderation_ids.size !=
                        preflight_moderations_before ||
                    built_retraction_ids.size != preflight_retractions_before ||
                    retraction_test_item_is_hidden((!) db,
                        preflight_valid_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        preflight_root_item_id),
                "One initially unsuitable batch item must prevent every network dispatch");

            Message partial_reply_one = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("PartialOne"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "partial-one", "room-partial-one",
                null, base_time.add_seconds(17));
            int partial_reply_one_item_id = (int) ((!) db).add_content_item(
                conversation, partial_reply_one.time,
                partial_reply_one.local_time, 1, partial_reply_one.id, false);
            var partial_reply_one_item = new MessageItem(partial_reply_one,
                conversation, partial_reply_one_item_id);
            Message partial_reply_two = persist_retraction_test_message((!) db,
                (!) account, room.with_resource("PartialTwo"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "partial-two", "room-partial-two",
                null, base_time.add_seconds(18));
            int partial_reply_two_item_id = (int) ((!) db).add_content_item(
                conversation, partial_reply_two.time,
                partial_reply_two.local_time, 1, partial_reply_two.id, false);
            var partial_reply_two_item = new MessageItem(partial_reply_two,
                conversation, partial_reply_two_item_id);
            Message partial_root = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "partial-root", "room-partial-root", null,
                base_time.add_seconds(19));
            int partial_root_item_id = (int) ((!) db).add_content_item(
                conversation, partial_root.time, partial_root.local_time, 1,
                partial_root.id, false);
            var partial_root_item = new MessageItem(partial_root, conversation,
                partial_root_item_id);
            partial_reply_one.set_quoted_item(partial_root_item_id,
                "room-partial-root", partial_root.from);
            partial_reply_two.set_quoted_item(partial_root_item_id,
                "room-partial-root", partial_root.from);
            var partial_replies = new Gee.ArrayList<ContentItem>();
            partial_replies.add(partial_reply_one_item);
            partial_replies.add(partial_reply_two_item);

            var reversed_partial_replies = new Gee.ArrayList<ContentItem>();
            reversed_partial_replies.add(partial_reply_two_item);
            reversed_partial_replies.add(partial_reply_one_item);
            int reversed_moderations_before = fake_stream.moderation_ids.size;
            int reversed_retractions_before = built_retraction_ids.size;
            MessageDeletionBatchResult reversed_result =
                run_deletion_with_replies(deletion, conversation,
                    reversed_partial_replies, partial_root_item);
            fail_if(reversed_result.preflight_passed ||
                    reversed_result.attempted_request_count != 0 ||
                    fake_stream.moderation_ids.size !=
                        reversed_moderations_before ||
                    built_retraction_ids.size != reversed_retractions_before,
                "The hardened root-last API must reject a reordered direct-reply snapshot before dispatch");

            int partial_moderations_before = fake_stream.moderation_ids.size;
            int partial_retractions_before = built_retraction_ids.size;
            fake_stream.fail_moderation_id = "room-partial-two";
            MessageDeletionBatchResult partial_result =
                run_deletion_with_replies(deletion, conversation,
                    partial_replies, partial_root_item);
            fake_stream.fail_moderation_id = null;
            fail_if(!partial_result.preflight_passed || partial_result.success ||
                    !partial_result.partial_success ||
                    partial_result.succeeded_count != 1 ||
                    partial_result.failed_count != 1 ||
                    partial_result.not_attempted_count != 1 ||
                    partial_result.item_results[0].status !=
                        MessageDeletionItemStatus.SUCCEEDED ||
                    partial_result.item_results[1].status !=
                        MessageDeletionItemStatus.SERVER_REJECTED ||
                    partial_result.item_results[2].status !=
                        MessageDeletionItemStatus.NOT_ATTEMPTED ||
                    fake_stream.moderation_ids.size !=
                        partial_moderations_before + 2 ||
                    fake_stream.moderation_ids[partial_moderations_before] !=
                        "room-partial-one" ||
                    fake_stream.moderation_ids[
                        partial_moderations_before + 1] != "room-partial-two" ||
                    built_retraction_ids.size != partial_retractions_before ||
                    !retraction_test_item_is_hidden((!) db,
                        partial_reply_one_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        partial_reply_two_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        partial_root_item_id),
                "A second-reply IQ failure must stop the sequence before retracting the root");

            Message revalidate_reply_one = persist_retraction_test_message(
                (!) db, (!) account, room.with_resource("RevalidateOne"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "revalidate-one",
                "room-revalidate-one", null, base_time.add_seconds(20));
            int revalidate_reply_one_item_id = (int) ((!) db).add_content_item(
                conversation, revalidate_reply_one.time,
                revalidate_reply_one.local_time, 1, revalidate_reply_one.id,
                false);
            var revalidate_reply_one_item = new MessageItem(
                revalidate_reply_one, conversation,
                revalidate_reply_one_item_id);
            Message revalidate_reply_two = persist_retraction_test_message(
                (!) db, (!) account, room.with_resource("RevalidateTwo"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "revalidate-two",
                "room-revalidate-two", null, base_time.add_seconds(21));
            int revalidate_reply_two_item_id = (int) ((!) db).add_content_item(
                conversation, revalidate_reply_two.time,
                revalidate_reply_two.local_time, 1, revalidate_reply_two.id,
                false);
            var revalidate_reply_two_item = new MessageItem(
                revalidate_reply_two, conversation,
                revalidate_reply_two_item_id);
            Message revalidate_replacement = persist_retraction_test_message(
                (!) db, (!) account, room.with_resource("RevalidateTwo"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "revalidate-two-edited",
                "room-revalidate-two-edited", null,
                base_time.add_seconds(22));
            Message revalidate_root = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "revalidate-root", "room-revalidate-root", null,
                base_time.add_seconds(23));
            int revalidate_root_item_id = (int) ((!) db).add_content_item(
                conversation, revalidate_root.time, revalidate_root.local_time,
                1, revalidate_root.id, false);
            var revalidate_root_item = new MessageItem(revalidate_root,
                conversation, revalidate_root_item_id);
            var revalidate_snapshot = new Gee.ArrayList<ContentItem>();
            revalidate_snapshot.add(revalidate_reply_one_item);
            revalidate_snapshot.add(revalidate_reply_two_item);
            revalidate_snapshot.add(revalidate_root_item);
            int revalidate_moderations_before = fake_stream.moderation_ids.size;
            int revalidate_retractions_before = built_retraction_ids.size;
            ulong revalidate_handler =
                fake_stream.before_moderation_response.connect(
                    (moderation_id) => {
                        if (moderation_id != "room-revalidate-one") return;
                        ((!) db).content_item.update()
                            .with(((!) db).content_item.id, "=",
                                revalidate_reply_two_item_id)
                            .set(((!) db).content_item.foreign_id,
                                revalidate_replacement.id)
                            .perform();
                    });
            MessageDeletionBatchResult revalidate_result = run_deletion_batch(
                deletion, conversation, revalidate_snapshot);
            if (GLib.SignalHandler.is_connected(fake_stream,
                    revalidate_handler)) {
                GLib.SignalHandler.disconnect(fake_stream,
                    revalidate_handler);
            }
            fail_if(!revalidate_result.preflight_passed ||
                    revalidate_result.success ||
                    !revalidate_result.partial_success ||
                    revalidate_result.succeeded_count != 1 ||
                    revalidate_result.failed_count != 1 ||
                    revalidate_result.not_attempted_count != 1 ||
                    revalidate_result.item_results[0].status !=
                        MessageDeletionItemStatus.SUCCEEDED ||
                    revalidate_result.item_results[1].status !=
                        MessageDeletionItemStatus.REVALIDATION_REJECTED ||
                    revalidate_result.item_results[2].status !=
                        MessageDeletionItemStatus.NOT_ATTEMPTED ||
                    fake_stream.moderation_ids.size !=
                        revalidate_moderations_before + 1 ||
                    fake_stream.moderation_ids[revalidate_moderations_before] !=
                        "room-revalidate-one" ||
                    built_retraction_ids.size != revalidate_retractions_before ||
                    !retraction_test_item_is_hidden((!) db,
                        revalidate_reply_one_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        revalidate_reply_two_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        revalidate_root_item_id),
                "A DB identity change while awaiting the first IQ must stop before the stale reply and root");

            var empty_snapshot = new Gee.ArrayList<ContentItem>();
            int empty_moderations_before = fake_stream.moderation_ids.size;
            int empty_writes_before = fake_stream.retraction_write_ids.size;
            MessageDeletionBatchResult empty_result = run_deletion_batch(
                deletion, conversation, empty_snapshot);
            fail_if(empty_result.preflight_passed || empty_result.success ||
                    empty_result.requested_count != 0 ||
                    fake_stream.moderation_ids.size !=
                        empty_moderations_before ||
                    fake_stream.retraction_write_ids.size !=
                        empty_writes_before,
                "An empty generic deletion batch must fail without dispatch");

            Message write_failure_root = persist_retraction_test_message(
                (!) db, (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "write-failure-root", "room-write-failure-root", null,
                base_time.add_seconds(24));
            int write_failure_root_item_id = (int) ((!) db).add_content_item(
                conversation, write_failure_root.time,
                write_failure_root.local_time, 1, write_failure_root.id,
                false);
            var write_failure_root_item = new MessageItem(write_failure_root,
                conversation, write_failure_root_item_id);
            Message write_failure_s0 = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "write-failure-s0", "room-write-failure-s0", null,
                base_time.add_seconds(25));
            persist_retraction_test_message((!) db, (!) account, room,
                room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "write-failure-s1",
                "room-write-failure-s1", "write-failure-s0",
                base_time.add_seconds(26));
            Message write_failure_s2 = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "write-failure-s2", "room-write-failure-s2",
                "write-failure-s0", base_time.add_seconds(27));
            int write_failure_reply_item_id = (int) ((!) db).add_content_item(
                conversation, write_failure_s0.time, write_failure_s0.time, 1,
                write_failure_s2.id, false);
            var write_failure_reply_item = new MessageItem(write_failure_s2,
                conversation, write_failure_reply_item_id);
            write_failure_s2.set_quoted_item(write_failure_root_item_id,
                "room-write-failure-root", write_failure_root.from);
            var write_failure_replies = new Gee.ArrayList<ContentItem>();
            write_failure_replies.add(write_failure_reply_item);
            int write_failure_writes_before =
                fake_stream.retraction_write_ids.size;
            fake_stream.fail_retraction_write_id =
                "room-write-failure-s1";
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Failed to send message: scripted retraction write failure*");
            MessageDeletionBatchResult write_failure_result =
                run_deletion_with_replies(deletion, conversation,
                    write_failure_replies, write_failure_root_item);
            GLib.Test.assert_expected_messages();
            fake_stream.fail_retraction_write_id = null;
            fail_if(!write_failure_result.preflight_passed ||
                    write_failure_result.success ||
                    !write_failure_result.partial_success ||
                    write_failure_result.succeeded_count != 0 ||
                    write_failure_result.failed_count != 1 ||
                    write_failure_result.not_attempted_count != 1 ||
                    write_failure_result.accepted_request_count != 1 ||
                    write_failure_result.item_results[0].status !=
                        MessageDeletionItemStatus.DISPATCH_REJECTED ||
                    !write_failure_result.item_results[0].partial_dispatch ||
                    write_failure_result.item_results[0]
                        .attempted_request_count != 2 ||
                    write_failure_result.item_results[0]
                        .accepted_request_count != 1 ||
                    write_failure_result.item_results[1].status !=
                        MessageDeletionItemStatus.NOT_ATTEMPTED ||
                    fake_stream.retraction_write_ids.size !=
                        write_failure_writes_before + 2 ||
                    fake_stream.retraction_write_ids[
                        write_failure_writes_before] !=
                        "room-write-failure-s0" ||
                    fake_stream.retraction_write_ids[
                        write_failure_writes_before + 1] !=
                        "room-write-failure-s1" ||
                    retraction_test_item_is_hidden((!) db,
                        write_failure_reply_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        write_failure_root_item_id),
                "A terminal write failure in revision two must report partial dispatch and stop before revision three and the root");

            persist_retraction_test_message((!) db, (!) account, room,
                room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "echo-chain-s0",
                "room-echo-chain-s0", null, base_time.add_seconds(28));
            persist_retraction_test_message((!) db, (!) account, room,
                room.with_resource("Alice"), Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT, "echo-chain-s1",
                "room-echo-chain-s1", "echo-chain-s0",
                base_time.add_seconds(29));
            Message echo_chain_s2 = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "echo-chain-s2", "room-echo-chain-s2", "echo-chain-s0",
                base_time.add_seconds(30));
            int echo_chain_item_id = (int) ((!) db).add_content_item(
                conversation, echo_chain_s2.time, echo_chain_s2.local_time, 1,
                echo_chain_s2.id, false);
            var echo_chain_item = new MessageItem(echo_chain_s2, conversation,
                echo_chain_item_id);
            int echo_chain_deleted_events = 0;
            ulong echo_deleted_handler = deletion.item_deleted.connect(
                (deleted_item) => {
                    if (deleted_item.id == echo_chain_item_id) {
                        echo_chain_deleted_events++;
                    }
                });
            ulong echo_write_handler =
                fake_stream.before_retraction_write_result.connect(
                    (retraction_id) => {
                        if (retraction_id == "room-echo-chain-s0") {
                            deletion.delete_locally(conversation,
                                echo_chain_item,
                                conversation.account.bare_jid);
                        }
                    });
            int echo_writes_before = fake_stream.retraction_write_ids.size;
            MessageDeletionItemResult echo_chain_result =
                run_detailed_deletion(deletion, conversation, echo_chain_item);
            if (GLib.SignalHandler.is_connected(fake_stream,
                    echo_write_handler)) {
                GLib.SignalHandler.disconnect(fake_stream,
                    echo_write_handler);
            }
            if (GLib.SignalHandler.is_connected(deletion,
                    echo_deleted_handler)) {
                GLib.SignalHandler.disconnect(deletion,
                    echo_deleted_handler);
            }
            fail_if(!echo_chain_result.success ||
                    echo_chain_result.partial_dispatch ||
                    echo_chain_result.attempted_request_count != 3 ||
                    echo_chain_result.accepted_request_count != 3 ||
                    fake_stream.retraction_write_ids.size !=
                        echo_writes_before + 3 ||
                    fake_stream.retraction_write_ids[echo_writes_before] !=
                        "room-echo-chain-s0" ||
                    fake_stream.retraction_write_ids[
                        echo_writes_before + 1] != "room-echo-chain-s1" ||
                    fake_stream.retraction_write_ids[
                        echo_writes_before + 2] != "room-echo-chain-s2" ||
                    !retraction_test_item_is_hidden((!) db,
                        echo_chain_item_id) || echo_chain_deleted_events != 1,
                "A reflected local hide after revision one must not suppress remaining revision writes or duplicate the hide event");

            Message late_reply_root = persist_retraction_test_message((!) db,
                (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "late-reply-root", "room-late-reply-root", null,
                base_time.add_seconds(31));
            int late_reply_root_item_id = (int) ((!) db).add_content_item(
                conversation, late_reply_root.time, late_reply_root.local_time,
                1, late_reply_root.id, false);
            var late_reply_root_item = new MessageItem(late_reply_root,
                conversation, late_reply_root_item_id);
            Message initial_direct_reply = persist_retraction_test_message(
                (!) db, (!) account, room.with_resource("InitialReply"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "initial-direct-reply",
                "room-initial-direct-reply", null,
                base_time.add_seconds(32));
            int initial_direct_reply_item_id =
                (int) ((!) db).add_content_item(conversation,
                    initial_direct_reply.time, initial_direct_reply.local_time,
                    1, initial_direct_reply.id, false);
            var initial_direct_reply_item = new MessageItem(
                initial_direct_reply, conversation,
                initial_direct_reply_item_id);
            initial_direct_reply.set_quoted_item(late_reply_root_item_id,
                "room-late-reply-root", late_reply_root.from);
            var late_reply_snapshot = new Gee.ArrayList<ContentItem>();
            late_reply_snapshot.add(initial_direct_reply_item);
            int inserted_late_reply_item_id = -1;
            Jid inserted_late_reply_from = room.with_resource("LateReply");
            Jid inserted_late_reply_to = room.with_resource("Alice");
            ulong late_reply_handler =
                fake_stream.before_moderation_response.connect(
                    (moderation_id) => {
                        if (moderation_id !=
                                "room-initial-direct-reply") return;
                        Message inserted_late_reply =
                            persist_retraction_test_message((!) db,
                                (!) account,
                                inserted_late_reply_from,
                                inserted_late_reply_to,
                                Message.DIRECTION_RECEIVED,
                                Message.Type.GROUPCHAT, "inserted-late-reply",
                                "room-inserted-late-reply", null,
                                base_time.add_seconds(33));
                        inserted_late_reply_item_id = (int) ((!) db)
                            .add_content_item(conversation,
                                inserted_late_reply.time,
                                inserted_late_reply.local_time, 1,
                                inserted_late_reply.id, false);
                        inserted_late_reply.set_quoted_item(
                            late_reply_root_item_id,
                            "room-late-reply-root", late_reply_root.from);
                    });
            int late_reply_writes_before =
                fake_stream.retraction_write_ids.size;
            MessageDeletionBatchResult late_reply_result =
                run_deletion_with_replies(deletion, conversation,
                    late_reply_snapshot, late_reply_root_item);
            if (GLib.SignalHandler.is_connected(fake_stream,
                    late_reply_handler)) {
                GLib.SignalHandler.disconnect(fake_stream,
                    late_reply_handler);
            }
            fail_if(!late_reply_result.preflight_passed ||
                    late_reply_result.success ||
                    !late_reply_result.partial_success ||
                    late_reply_result.succeeded_count != 1 ||
                    late_reply_result.failed_count != 1 ||
                    late_reply_result.item_results[0].status !=
                        MessageDeletionItemStatus.SUCCEEDED ||
                    late_reply_result.item_results[1].status !=
                        MessageDeletionItemStatus.REVALIDATION_REJECTED ||
                    inserted_late_reply_item_id < 0 ||
                    fake_stream.retraction_write_ids.size !=
                        late_reply_writes_before ||
                    !retraction_test_item_is_hidden((!) db,
                        initial_direct_reply_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        late_reply_root_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        inserted_late_reply_item_id),
                "A new direct reply arriving during the first IQ must revalidate-fail the root before its write");

            Message externally_hidden_root =
                persist_retraction_test_message((!) db, (!) account, room,
                    room.with_resource("Alice"), Message.DIRECTION_SENT,
                    Message.Type.GROUPCHAT, "externally-hidden-root",
                    "room-externally-hidden-root", null,
                    base_time.add_seconds(34));
            int externally_hidden_root_item_id = (int) ((!) db)
                .add_content_item(conversation, externally_hidden_root.time,
                    externally_hidden_root.local_time, 1,
                    externally_hidden_root.id, false);
            var externally_hidden_root_item = new MessageItem(
                externally_hidden_root, conversation,
                externally_hidden_root_item_id);
            Message externally_hidden_reply =
                persist_retraction_test_message((!) db, (!) account,
                    room.with_resource("HiddenRootReply"),
                    room.with_resource("Alice"),
                    Message.DIRECTION_RECEIVED, Message.Type.GROUPCHAT,
                    "externally-hidden-reply",
                    "room-externally-hidden-reply", null,
                    base_time.add_seconds(35));
            int externally_hidden_reply_item_id = (int) ((!) db)
                .add_content_item(conversation,
                    externally_hidden_reply.time,
                    externally_hidden_reply.local_time, 1,
                    externally_hidden_reply.id, false);
            var externally_hidden_reply_item = new MessageItem(
                externally_hidden_reply, conversation,
                externally_hidden_reply_item_id);
            externally_hidden_reply.set_quoted_item(
                externally_hidden_root_item_id,
                "room-externally-hidden-root",
                externally_hidden_root.from);
            var externally_hidden_snapshot =
                new Gee.ArrayList<ContentItem>();
            externally_hidden_snapshot.add(externally_hidden_reply_item);
            ulong externally_hidden_handler =
                fake_stream.before_moderation_response.connect(
                    (moderation_id) => {
                        if (moderation_id !=
                                "room-externally-hidden-reply") return;
                        deletion.delete_locally(conversation,
                            externally_hidden_root_item,
                            conversation.account.bare_jid);
                    });
            int externally_hidden_writes_before =
                fake_stream.retraction_write_ids.size;
            MessageDeletionBatchResult externally_hidden_result =
                run_deletion_with_replies(deletion, conversation,
                    externally_hidden_snapshot,
                    externally_hidden_root_item);
            if (GLib.SignalHandler.is_connected(fake_stream,
                    externally_hidden_handler)) {
                GLib.SignalHandler.disconnect(fake_stream,
                    externally_hidden_handler);
            }
            fail_if(!externally_hidden_result.preflight_passed ||
                    externally_hidden_result.success ||
                    !externally_hidden_result.partial_success ||
                    externally_hidden_result.succeeded_count != 1 ||
                    externally_hidden_result.failed_count != 1 ||
                    externally_hidden_result.item_results[0].status !=
                        MessageDeletionItemStatus.SUCCEEDED ||
                    externally_hidden_result.item_results[1].status !=
                        MessageDeletionItemStatus.REVALIDATION_REJECTED ||
                    !externally_hidden_result.item_results[1].locally_hidden ||
                    fake_stream.retraction_write_ids.size !=
                        externally_hidden_writes_before ||
                    !retraction_test_item_is_hidden((!) db,
                        externally_hidden_reply_item_id) ||
                    !retraction_test_item_is_hidden((!) db,
                        externally_hidden_root_item_id),
                "A root hidden while a reply is awaiting confirmation must report its real local state without dispatching the root");

            Message corrected_reply_root = persist_retraction_test_message(
                (!) db, (!) account, room, room.with_resource("Alice"),
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT,
                "corrected-reply-root", "room-corrected-reply-root", null,
                base_time.add_seconds(36));
            int corrected_reply_root_item_id = (int) ((!) db)
                .add_content_item(conversation, corrected_reply_root.time,
                    corrected_reply_root.local_time, 1,
                    corrected_reply_root.id, false);
            var corrected_reply_root_item = new MessageItem(
                corrected_reply_root, conversation,
                corrected_reply_root_item_id);
            Message completed_reply_one = persist_retraction_test_message(
                (!) db, (!) account, room.with_resource("FirstReply"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "completed-reply-one",
                "room-completed-reply-one", null,
                base_time.add_seconds(37));
            int completed_reply_one_item_id = (int) ((!) db)
                .add_content_item(conversation, completed_reply_one.time,
                    completed_reply_one.local_time, 1,
                    completed_reply_one.id, false);
            var completed_reply_one_item = new MessageItem(
                completed_reply_one, conversation,
                completed_reply_one_item_id);
            completed_reply_one.set_quoted_item(
                corrected_reply_root_item_id,
                "room-corrected-reply-root", corrected_reply_root.from);
            Message completed_reply_two = persist_retraction_test_message(
                (!) db, (!) account, room.with_resource("SecondReply"),
                room.with_resource("Alice"), Message.DIRECTION_RECEIVED,
                Message.Type.GROUPCHAT, "completed-reply-two",
                "room-completed-reply-two", null,
                base_time.add_seconds(38));
            int completed_reply_two_item_id = (int) ((!) db)
                .add_content_item(conversation, completed_reply_two.time,
                    completed_reply_two.local_time, 1,
                    completed_reply_two.id, false);
            var completed_reply_two_item = new MessageItem(
                completed_reply_two, conversation,
                completed_reply_two_item_id);
            completed_reply_two.set_quoted_item(
                corrected_reply_root_item_id,
                "room-corrected-reply-root", corrected_reply_root.from);
            var corrected_reply_snapshot = new Gee.ArrayList<ContentItem>();
            corrected_reply_snapshot.add(completed_reply_one_item);
            corrected_reply_snapshot.add(completed_reply_two_item);
            Jid completed_reply_one_sender =
                room.with_resource("FirstReply");
            Jid completed_reply_our_jid = room.with_resource("Alice");
            ulong corrected_reply_handler =
                fake_stream.before_moderation_response.connect(
                    (moderation_id) => {
                        if (moderation_id !=
                                "room-completed-reply-two") return;
                        Message late_correction =
                            persist_retraction_test_message((!) db,
                                (!) account,
                                completed_reply_one_sender,
                                completed_reply_our_jid,
                                Message.DIRECTION_RECEIVED,
                                Message.Type.GROUPCHAT,
                                "completed-reply-one-correction",
                                "room-completed-reply-one-correction",
                                "completed-reply-one",
                                base_time.add_seconds(39));
                        ((!) db).content_item.update()
                            .with(((!) db).content_item.id, "=",
                                completed_reply_one_item_id)
                            .set(((!) db).content_item.foreign_id,
                                late_correction.id)
                            .perform();
                    });
            int corrected_reply_writes_before =
                fake_stream.retraction_write_ids.size;
            MessageDeletionBatchResult corrected_reply_result =
                run_deletion_with_replies(deletion, conversation,
                    corrected_reply_snapshot, corrected_reply_root_item);
            if (GLib.SignalHandler.is_connected(fake_stream,
                    corrected_reply_handler)) {
                GLib.SignalHandler.disconnect(fake_stream,
                    corrected_reply_handler);
            }
            fail_if(!corrected_reply_result.preflight_passed ||
                    corrected_reply_result.success ||
                    !corrected_reply_result.partial_success ||
                    corrected_reply_result.succeeded_count != 1 ||
                    corrected_reply_result.failed_count != 1 ||
                    corrected_reply_result.not_attempted_count != 1 ||
                    corrected_reply_result.item_results[0].status !=
                        MessageDeletionItemStatus.REVALIDATION_REJECTED ||
                    !corrected_reply_result.item_results[0].locally_hidden ||
                    corrected_reply_result.item_results[1].status !=
                        MessageDeletionItemStatus.SUCCEEDED ||
                    corrected_reply_result.item_results[2].status !=
                        MessageDeletionItemStatus.NOT_ATTEMPTED ||
                    fake_stream.retraction_write_ids.size !=
                        corrected_reply_writes_before ||
                    !retraction_test_item_is_hidden((!) db,
                        completed_reply_one_item_id) ||
                    !retraction_test_item_is_hidden((!) db,
                        completed_reply_two_item_id) ||
                    retraction_test_item_is_hidden((!) db,
                        corrected_reply_root_item_id),
                "A new correction on an already hidden reply must invalidate its completed plan and stop before the root");

            var private_conversation = new Conversation(
                room.with_resource("Mallory"), (!) account,
                Conversation.Type.GROUPCHAT_PM);
            private_conversation.muc_pm_peer_identity =
                "jid:mallory@example.test";
            private_conversation.persist((!) db);
            Message private_message = persist_retraction_test_message(
                (!) db, (!) account, room.with_resource("Mallory"),
                ((!) account).full_jid, Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT_PM, "pm-origin", "pm-server",
                null, base_time.add_seconds(10));
            int private_item_id = (int) ((!) db).add_content_item(
                private_conversation, private_message.time,
                private_message.local_time, 1, private_message.id, false);
            var private_item = new MessageItem(private_message,
                private_conversation, private_item_id);

            fail_if(deletion.can_delete_for_everyone(private_conversation,
                    private_item),
                "A stale or unavailable MUC-PM target must not offer global deletion");
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*Refusing incomplete global retraction*");
            bool private_deleted = deletion.delete_globally(
                private_conversation, private_item);
            GLib.Test.assert_expected_messages();
            fail_if(private_deleted,
                "The backend must reject stale MUC-PM global deletion before building a retraction");
            bool? private_hidden = ((!) db).content_item.select(
                    {((!) db).content_item.hide})
                .with(((!) db).content_item.id, "=", private_item_id)
                .single().row().get(((!) db).content_item.hide);
            fail_if(private_hidden == null || ((!) private_hidden),
                "A rejected MUC-PM retraction must remain visible locally");
        } catch (Error e) {
            fail_if_reached(@"MUC moderation-chain test failed: $(e.message)");
        } finally {
            if (stream_interactor != null) {
                ((!) stream_interactor).connection_manager.disconnect_all();
                if (account != null) ((!) stream_interactor)
                    .account_removed((!) account);
                MucManager? muc_manager = ((!) stream_interactor)
                    .get_module<MucManager>(MucManager.IDENTITY);
                if (muc_manager != null) ((!) muc_manager).shutdown();
                drain_retraction_test_context();
            }
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_chat_correction_chain_uses_each_origin_id() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-chat-correction-retraction-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "chat-correction-retraction-test");

            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var bob = new Jid("bob@example.test");
            var charlie = new Jid("charlie@example.test");
            var conversation = new Conversation(bob, account,
                Conversation.Type.CHAT);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            MessageStorage.start(stream_interactor, (!) db);
            MessageStorage storage = stream_interactor.get_module<MessageStorage>(
                MessageStorage.IDENTITY);
            DateTime base_time = new DateTime.from_unix_utc(1700001000);

            Message original = persist_retraction_test_message((!) db, account,
                bob, account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT, "O", "mam-O",
                null, base_time);
            Message c1 = persist_retraction_test_message((!) db, account,
                bob, account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT, "C1", "mam-C1",
                "O", base_time.add_seconds(1));
            Message c2 = persist_retraction_test_message((!) db, account,
                bob, account.bare_jid.with_resource("phone"),
                Message.DIRECTION_SENT, Message.Type.CHAT, "C2", "mam-C2",
                "O", base_time.add_seconds(2));

            persist_retraction_test_message((!) db, account,
                bob.with_resource("laptop"), account.bare_jid,
                Message.DIRECTION_RECEIVED, Message.Type.CHAT, "X-sender",
                "mam-X-sender", "O", base_time.add_seconds(3));
            persist_retraction_test_message((!) db, account,
                charlie, account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT, "X-chat",
                "mam-X-chat", "O", base_time.add_seconds(4));
            persist_retraction_test_message((!) db, account,
                bob.with_resource("laptop"), account.bare_jid,
                Message.DIRECTION_RECEIVED, Message.Type.CHAT, "O",
                "mam-X-root-collision", null, base_time.add_seconds(5));

            Gee.List<Message> chain = storage.get_revision_chain(conversation, c2);
            fail_if(chain.size != 3 || chain[0].id != original.id ||
                    chain[1].id != c1.id || chain[2].id != c2.id,
                "Direct-chat chain must contain O/C1/C2 in order and exclude other sender/chat collisions");

            Gee.List<string> ids;
            fail_if_not(MessageDeletion.try_get_complete_retraction_reference_ids(
                    Conversation.Type.CHAT, false, chain, out ids),
                "A complete direct-chat correction chain must be globally retractable");
            fail_if(ids.size != 3 || ids[0] != "O" || ids[1] != "C1" ||
                    ids[2] != "C2",
                "Every direct-chat correction must use its own sender stanza ID, never its MAM ID or edit_to");

            Message orphan = persist_retraction_test_message((!) db,
                account, bob, account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT, "orphan-C1",
                "mam-orphan-C1", "missing-root",
                base_time.add_seconds(10));
            Gee.List<Message> orphan_chain = storage.get_revision_chain(
                conversation, orphan);
            fail_if(!orphan_chain.is_empty,
                "A correction whose explicit root is missing must expose no partial revision chain");
            fail_if(MessageDeletion.try_get_complete_retraction_reference_ids(
                    Conversation.Type.CHAT, false, orphan_chain, out ids),
                "A missing XEP-0308 root must reject global deletion instead of retracting only corrections");

            persist_retraction_test_message((!) db, account, bob,
                account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT,
                "ambiguous-root", "mam-ambiguous-root-a", null,
                base_time.add_seconds(12));
            persist_retraction_test_message((!) db, account, bob,
                account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT,
                "ambiguous-root", "mam-ambiguous-root-b", null,
                base_time.add_seconds(13));
            Message ambiguous_correction =
                persist_retraction_test_message((!) db, account, bob,
                    account.bare_jid.with_resource("desktop"),
                    Message.DIRECTION_SENT, Message.Type.CHAT,
                    "ambiguous-correction", "mam-ambiguous-correction",
                    "ambiguous-root", base_time.add_seconds(14));
            Gee.List<Message> ambiguous_chain = storage.get_revision_chain(
                conversation, ambiguous_correction);
            fail_if(!ambiguous_chain.is_empty ||
                    MessageDeletion.try_get_complete_retraction_reference_ids(
                        Conversation.Type.CHAT, false, ambiguous_chain,
                        out ids),
                "Two physical roots with the same sender/id must reject the complete correction chain");

            var private_room = new Jid(
                "room@conference.example.test/Bob");
            var other_private_room = new Jid(
                "room@conference.example.test/Carol");
            var private_conversation = new Conversation(private_room,
                account, Conversation.Type.GROUPCHAT_PM);
            Message pm0 = persist_retraction_test_message((!) db, account,
                private_room, account.full_jid, Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT_PM, "PM0", "room-pm-0", null,
                base_time.add_seconds(20));
            Message pm1 = persist_retraction_test_message((!) db, account,
                private_room, account.full_jid, Message.DIRECTION_SENT,
                Message.Type.GROUPCHAT_PM, "PM1", "room-pm-1", "PM0",
                base_time.add_seconds(21));
            persist_retraction_test_message((!) db, account,
                other_private_room, account.full_jid,
                Message.DIRECTION_SENT, Message.Type.GROUPCHAT_PM,
                "PM-other-nick", "room-pm-other", "PM0",
                base_time.add_seconds(22));
            Gee.List<Message> private_chain = storage.get_revision_chain(
                private_conversation, pm1);
            fail_if(private_chain.size != 2 ||
                    private_chain[0].id != pm0.id ||
                    private_chain[1].id != pm1.id,
                "A MUC-PM correction chain must stay scoped to the exact room nickname");
            fail_if_not(MessageDeletion
                    .try_get_complete_retraction_reference_ids(
                        Conversation.Type.GROUPCHAT_PM, false,
                        private_chain, out ids),
                "A complete MUC-PM chain must remain retractable by sender IDs");
            fail_if(ids.size != 2 || ids[0] != "PM0" ||
                    ids[1] != "PM1",
                "MUC-PM revisions use their own sender IDs, never room server IDs");
        } catch (Error e) {
            fail_if_reached(@"Chat correction retraction-chain test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_revision_ids_require_complete_unique_chain() {
        var revisions = new Gee.ArrayList<Message>();

        var first = new Message("first");
        first.stanza_id = "origin-first";
        first.server_id = "room-duplicate";
        revisions.add(first);

        var duplicate = new Message("duplicate");
        duplicate.stanza_id = "origin-duplicate";
        duplicate.server_id = "room-duplicate";
        duplicate.edit_to = "origin-first";
        revisions.add(duplicate);

        var missing = new Message("missing");
        missing.stanza_id = "";
        missing.server_id = "";
        missing.edit_to = "origin-first";
        revisions.add(missing);

        var fallback = new Message("fallback");
        fallback.stanza_id = "origin-fallback";
        fallback.edit_to = "origin-first";
        revisions.add(fallback);

        Gee.List<string> ids;
        fail_if(MessageDeletion.try_get_complete_retraction_reference_ids(
                Conversation.Type.GROUPCHAT, true, revisions, out ids),
            "Missing or duplicate room IDs must reject the whole chain, never produce a partial plan");
        fail_if(!ids.is_empty,
            "A rejected global deletion plan must expose no partial IDs");

        var pre_echo = new Gee.ArrayList<Message>();
        var pending = new Message("pending echo");
        pending.stanza_id = "origin-pending";
        pre_echo.add(pending);

        fail_if(MessageDeletion.try_get_complete_retraction_reference_ids(
                Conversation.Type.GROUPCHAT, true, pre_echo, out ids),
            "SID-capable or unknown MUCs must not fall back to origin-id before the room echo");
        fail_if_not(MessageDeletion.try_get_complete_retraction_reference_ids(
                Conversation.Type.GROUPCHAT, false, pre_echo, out ids),
            "A confirmed no-SID MUC may use the sender message ID");
        fail_if(ids.size != 1 || ids[0] != "origin-pending",
            "The confirmed no-SID fallback must retain the physical revision's own origin ID");

        fail_if_not(MessageDeletion.groupchat_requires_server_ids(false,
                false),
            "Unknown or stale room-info must require room-assigned IDs");
        fail_if_not(MessageDeletion.groupchat_requires_server_ids(true,
                true),
            "A current room advertising stable IDs must require them");
        fail_if(MessageDeletion.groupchat_requires_server_ids(true,
                false),
            "Only a current, confirmed no-SID room may use origin IDs");
    }

    private void test_file_relation_uses_message_id_not_transport_info() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-file-retraction-relation-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        StreamInteractor? stream_interactor = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "file-retraction-relation-test");
            var account = new Account(new Jid("alice@example.test"),
                "secret");
            account.persist((!) db);
            var bob = new Jid("bob@example.test");
            var conversation = new Conversation(bob, account,
                Conversation.Type.CHAT);
            conversation.send_typing = Conversation.Setting.OFF;
            conversation.persist((!) db);

            stream_interactor = new StreamInteractor.for_tests((!) db);
            MessageProcessor.start((!) stream_interactor, (!) db);
            MessageStorage.start((!) stream_interactor, (!) db);
            Calls.start((!) stream_interactor, (!) db);
            ((!) stream_interactor).add_module(FileManager.create_for_tests());
            FileTransferStorage.start((!) stream_interactor, (!) db);
            ContentItemStore.start((!) stream_interactor, (!) db);
            MessageDeletion.start((!) stream_interactor, (!) db);

            ((!) stream_interactor).module_manager.initialize(account);
            var fake_stream = new RetractionBuildTestXmppStream(
                new Jid("example.test"));
            attach_retraction_stream_modules((!) stream_interactor, account,
                fake_stream);
            ((!) stream_interactor).connection_manager
                .set_connected_stream_for_tests(account, fake_stream);

            DateTime time = new DateTime.from_unix_utc(1700001500);
            Message message = persist_retraction_test_message((!) db, account,
                bob, account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT,
                "file-origin-id", null, null, time);
            MessageDeletion deletion = ((!) stream_interactor)
                .get_module<MessageDeletion>(MessageDeletion.IDENTITY);

            var related_transfer = new FileTransfer();
            related_transfer.account = account;
            related_transfer.counterpart = bob;
            related_transfer.ourpart = account.bare_jid.with_resource(
                "desktop");
            related_transfer.direction = FileTransfer.DIRECTION_SENT;
            related_transfer.time = time;
            related_transfer.local_time = time;
            related_transfer.file_name = "related.bin";
            related_transfer.message_db_id = message.id;
            related_transfer.info = null;
            related_transfer.persist((!) db);
            int related_item_id = (int) ((!) db).add_content_item(
                conversation, time, time, 2, related_transfer.id, false);
            var related_item = new FileItem(related_transfer, conversation,
                related_item_id, message);

            var sibling_transfer = new FileTransfer();
            sibling_transfer.account = account;
            sibling_transfer.counterpart = bob;
            sibling_transfer.ourpart = account.bare_jid.with_resource(
                "desktop");
            sibling_transfer.direction = FileTransfer.DIRECTION_SENT;
            sibling_transfer.time = time;
            sibling_transfer.local_time = time;
            sibling_transfer.file_name = "related-second.bin";
            sibling_transfer.message_db_id = message.id;
            sibling_transfer.info = null;
            sibling_transfer.persist((!) db);
            int sibling_item_id = (int) ((!) db).add_content_item(
                conversation, time, time, 2, sibling_transfer.id, false);

            fail_if_not(deletion.can_delete_for_everyone(conversation,
                    related_item),
                "an explicit message_id relation must allow file retraction when transport info is null");

            var charlie = new Jid("charlie@example.test");
            var foreign_conversation = new Conversation(charlie, account,
                Conversation.Type.CHAT);
            foreign_conversation.persist((!) db);
            Message foreign_message = persist_retraction_test_message((!) db,
                account, charlie,
                account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT,
                "foreign-file-origin-id", null, null,
                time.add_seconds(1));
            MessageStorage storage = ((!) stream_interactor).get_module<
                MessageStorage>(MessageStorage.IDENTITY);
            fail_if(storage.get_message_by_id(foreign_message.id,
                    foreign_conversation) == null,
                "the foreign fixture message must be present in its own conversation cache");

            var foreign_relation_transfer = new FileTransfer();
            foreign_relation_transfer.account = account;
            foreign_relation_transfer.counterpart = bob;
            foreign_relation_transfer.ourpart = account.bare_jid.with_resource(
                "desktop");
            foreign_relation_transfer.direction = FileTransfer.DIRECTION_SENT;
            foreign_relation_transfer.time = time.add_seconds(2);
            foreign_relation_transfer.local_time = time.add_seconds(2);
            foreign_relation_transfer.file_name = "foreign-relation.bin";
            foreign_relation_transfer.message_db_id = foreign_message.id;
            foreign_relation_transfer.info = null;
            foreign_relation_transfer.persist((!) db);
            int foreign_relation_item_id = (int) ((!) db).add_content_item(
                conversation, foreign_relation_transfer.time,
                foreign_relation_transfer.local_time, 2,
                foreign_relation_transfer.id, false);
            var foreign_relation_item = new FileItem(
                foreign_relation_transfer, conversation,
                foreign_relation_item_id);

            fail_if(deletion.can_delete_for_everyone(conversation,
                    foreign_relation_item),
                "a file relation to another conversation must remain fail-closed even when that message is cached");
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*Refusing incomplete global retraction*");
            fail_if(deletion.delete_globally(conversation,
                    foreign_relation_item),
                "the backend must reject a positive but cross-conversation file relation");
            GLib.Test.assert_expected_messages();

            var unrelated_transfer = new FileTransfer();
            unrelated_transfer.account = account;
            unrelated_transfer.counterpart = bob;
            unrelated_transfer.ourpart = account.bare_jid.with_resource(
                "desktop");
            unrelated_transfer.direction = FileTransfer.DIRECTION_SENT;
            unrelated_transfer.time = time.add_seconds(1);
            unrelated_transfer.local_time = time.add_seconds(1);
            unrelated_transfer.file_name = "unrelated.bin";
            unrelated_transfer.message_db_id = -1;
            unrelated_transfer.info = null;
            unrelated_transfer.persist((!) db);
            int unrelated_item_id = (int) ((!) db).add_content_item(
                conversation, unrelated_transfer.time,
                unrelated_transfer.local_time, 2, unrelated_transfer.id,
                false);
            var unrelated_item = new FileItem(unrelated_transfer,
                conversation, unrelated_item_id);

            fail_if(deletion.can_delete_for_everyone(conversation,
                    unrelated_item),
                "a file without an explicit or legacy message relation must remain fail-closed");
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*Refusing incomplete global retraction*");
            fail_if(deletion.delete_globally(conversation, unrelated_item),
                "a stale backend deletion request without a real file-message relation must be rejected");
            GLib.Test.assert_expected_messages();

            Message spoof_target = persist_retraction_test_message((!) db,
                account, bob,
                account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT,
                "caller-controlled-target", null, null,
                time.add_seconds(3));
            var caller_transfer = new FileTransfer();
            caller_transfer.id = related_transfer.id;
            caller_transfer.account = account;
            caller_transfer.counterpart = bob;
            caller_transfer.ourpart = account.bare_jid.with_resource(
                "desktop");
            caller_transfer.direction = FileTransfer.DIRECTION_SENT;
            caller_transfer.time = time;
            caller_transfer.local_time = time;
            caller_transfer.file_name = "caller-controlled.bin";
            caller_transfer.message_db_id = spoof_target.id;
            caller_transfer.info = null;
            var caller_item = new FileItem(caller_transfer, conversation,
                related_item_id, spoof_target);

            fail_if(!deletion.can_delete_for_everyone(conversation,
                    caller_item),
                "a valid persisted file row must remain retractable through a reconstructed UI item");
            int writes_before = fake_stream.retraction_write_ids.size;
            fail_if(!deletion.delete_globally(conversation, caller_item),
                "the global-delete backend must resolve the persisted transfer and message identity");
            drain_retraction_test_context();
            fail_if(fake_stream.retraction_write_ids.size !=
                    writes_before + 1 ||
                    fake_stream.retraction_write_ids[writes_before] !=
                        "file-origin-id",
                "a caller-supplied FileTransfer relation must not replace the persisted retraction target");
            foreach (int item_id in new int[] {
                    related_item_id, sibling_item_id }) {
                bool? hidden = ((!) db).content_item.select(
                        {((!) db).content_item.hide})
                    .with(((!) db).content_item.id, "=", item_id)
                    .single().row().get(((!) db).content_item.hide);
                fail_if(hidden == null || !((!) hidden),
                    "deleting one attachment must hide every file item backed by the same SFS message");
            }
        } catch (Error e) {
            fail_if_reached(@"File retraction relation test failed: $(e.message)");
        } finally {
            if (stream_interactor != null) {
                ((!) stream_interactor).connection_manager.disconnect_all();
                drain_retraction_test_context();
            }
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_reflected_chain_hides_content_item_once() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-reflected-chain-retraction-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string file_path = Path.build_filename(temp_dir, "cleanup.txt");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "reflected-chain-retraction-test");

            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var bob = new Jid("bob@example.test");
            var conversation = new Conversation(bob, account,
                Conversation.Type.CHAT);
            conversation.persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            MessageProcessor.start(stream_interactor, (!) db);
            MessageStorage.start(stream_interactor, (!) db);
            var deletion = new MessageDeletion(stream_interactor, (!) db);

            DateTime time = new DateTime.from_unix_utc(1700002000);
            Message message = persist_retraction_test_message((!) db, account,
                bob, account.bare_jid.with_resource("desktop"),
                Message.DIRECTION_SENT, Message.Type.CHAT, "O", "mam-O",
                null, time);
            int content_item_id = (int) ((!) db).add_content_item(conversation,
                time, time, 1, message.id, false);
            var content_item = new MessageItem(message, conversation,
                content_item_id);
            int removal_signals = 0;
            deletion.item_deleted.connect((deleted_item) => {
                if (deleted_item.id == content_item_id) removal_signals++;
            });

            // Mirrors the original plus two correction retraction echoes.
            deletion.delete_locally(conversation, content_item,
                account.bare_jid);
            deletion.delete_locally(conversation, content_item,
                account.bare_jid);
            deletion.delete_locally(conversation, content_item,
                account.bare_jid);

            fail_if(removal_signals != 1,
                "Three reflected physical retractions must remove the shared ContentItem exactly once");
            fail_if(message.body != "",
                "Idempotent UI removal must still clear the underlying message body");
            bool? hidden = ((!) db).content_item.select({((!) db).content_item.hide})
                .with(((!) db).content_item.id, "=", content_item_id)
                .single().row().get(((!) db).content_item.hide);
            fail_if(hidden == null || !((!) hidden),
                "The shared ContentItem must remain persisted as hidden");

            // File cleanup intentionally stays before the idempotent hide
            // guard, so an existing payload is removed even on a repeated
            // cleanup request for an already-hidden row.
            FileUtils.set_contents(file_path, "payload");
            var file_transfer = new FileTransfer();
            file_transfer.account = account;
            file_transfer.counterpart = bob;
            file_transfer.ourpart = account.bare_jid;
            file_transfer.direction = FileTransfer.DIRECTION_SENT;
            file_transfer.time = time;
            file_transfer.local_time = time;
            file_transfer.file_name = "cleanup.txt";
            file_transfer.path = file_path;
            int file_item_id = (int) ((!) db).add_content_item(conversation,
                time, time, 2, 999999, true);
            var file_item = new FileItem(file_transfer, conversation,
                file_item_id);
            deletion.delete_locally(conversation, file_item,
                account.bare_jid);
            fail_if(FileUtils.test(file_path, FileTest.EXISTS),
                "Idempotent hidden-row handling must not skip file cleanup");
        } catch (Error e) {
            fail_if_reached(@"Reflected correction-chain idempotence test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(file_path);
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private static void attach_retraction_stream_modules(
            StreamInteractor stream_interactor, Account account,
            RetractionBuildTestXmppStream stream) throws Error {
        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        attach_retraction_stream_module<Xmpp.Iq.Module>(stream_interactor,
            account, stream, Xmpp.Iq.Module.IDENTITY);
        attach_retraction_stream_module<Xmpp.MessageModule>(stream_interactor,
            account, stream, Xmpp.MessageModule.IDENTITY);
        attach_retraction_stream_module<Xmpp.Presence.Module>(
            stream_interactor, account, stream,
            Xmpp.Presence.Module.IDENTITY);
        attach_retraction_stream_module<Xmpp.Xep.ServiceDiscovery.Module>(
            stream_interactor, account, stream,
            Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        attach_retraction_stream_module<Xmpp.Xep.Muc.Module>(
            stream_interactor, account, stream,
            Xmpp.Xep.Muc.Module.IDENTITY);
    }

    private static void attach_retraction_stream_module<T>(
            StreamInteractor stream_interactor, Account account,
            RetractionBuildTestXmppStream stream,
            Xmpp.SimpleModuleIdentity identity) throws Error {
        T? module = stream_interactor.module_manager.get_module<T>(account,
            identity);
        if (module == null) {
            throw new IOError.FAILED(
                "test setup missing XMPP module %s".printf(identity.id));
        }
        var stream_module = (Xmpp.XmppStreamModule) ((!) module);
        stream.add_module(stream_module);
        stream_module.attach(stream);
    }

    private static StanzaNode build_retraction_moderator_self_presence(
            Jid room, Jid account_jid) throws Error {
        const string NS_MUC_USER =
            "http://jabber.org/protocol/muc#user";
        var item = new StanzaNode.build("item", NS_MUC_USER)
            .put_attribute("jid", account_jid.to_string())
            .put_attribute("affiliation", "member")
            .put_attribute("role", "moderator");
        var x_node = new StanzaNode.build("x", NS_MUC_USER)
            .add_self_xmlns()
            .put_node(item)
            .put_node(new StanzaNode.build("status", NS_MUC_USER)
                .put_attribute("code", "110"));
        return new StanzaNode.build("presence")
            .put_attribute("from",
                room.bare_jid.with_resource("Alice").to_string())
            .put_attribute("to", account_jid.to_string())
            .put_node(x_node);
    }

    private static void drain_retraction_test_context() {
        MainContext context = MainContext.@default();
        while (context.pending()) context.iteration(false);
    }

    private MessageDeletionItemResult run_detailed_deletion(
            MessageDeletion deletion, Conversation conversation,
            ContentItem content_item) {
        var loop = new MainLoop();
        MessageDeletionItemResult? result = null;
        bool completed = false;
        uint timeout_id = Timeout.add_seconds(5, () => {
            loop.quit();
            return Source.REMOVE;
        });
        deletion.delete_globally_detailed.begin(conversation, content_item,
            (obj, res) => {
                result = deletion.delete_globally_detailed.end(res);
                completed = true;
                loop.quit();
            });
        if (!completed) loop.run();
        if (completed) Source.remove(timeout_id);
        fail_if(!completed || result == null,
            "Detailed global deletion did not complete within the causal test timeout");
        assert(result != null);
        return (!) result;
    }

    private MessageDeletionBatchResult run_deletion_batch(
            MessageDeletion deletion, Conversation conversation,
            Gee.List<ContentItem> ordered_snapshot) {
        var loop = new MainLoop();
        MessageDeletionBatchResult? result = null;
        bool completed = false;
        uint timeout_id = Timeout.add_seconds(5, () => {
            loop.quit();
            return Source.REMOVE;
        });
        deletion.delete_globally_batch_detailed.begin(conversation,
            ordered_snapshot, (obj, res) => {
                result = deletion.delete_globally_batch_detailed.end(res);
                completed = true;
                loop.quit();
            });
        if (!completed) loop.run();
        if (completed) Source.remove(timeout_id);
        fail_if(!completed || result == null,
            "Global-deletion batch did not complete within the causal test timeout");
        assert(result != null);
        return (!) result;
    }

    private MessageDeletionBatchResult run_deletion_with_replies(
            MessageDeletion deletion, Conversation conversation,
            Gee.List<ContentItem> direct_replies_snapshot,
            ContentItem root) {
        var loop = new MainLoop();
        MessageDeletionBatchResult? result = null;
        bool completed = false;
        uint timeout_id = Timeout.add_seconds(5, () => {
            loop.quit();
            return Source.REMOVE;
        });
        deletion.delete_globally_with_replies_detailed.begin(conversation,
            direct_replies_snapshot, root, (obj, res) => {
                result = deletion.delete_globally_with_replies_detailed.end(
                    res);
                completed = true;
                loop.quit();
            });
        if (!completed) loop.run();
        if (completed) Source.remove(timeout_id);
        fail_if(!completed || result == null,
            "Root-last reply deletion did not complete within the causal test timeout");
        assert(result != null);
        return (!) result;
    }

    private static bool retraction_test_item_is_hidden(Database db,
            int content_item_id) {
        bool? hidden = db.content_item.select({db.content_item.hide})
            .with(db.content_item.id, "=", content_item_id)
            .single().row().get(db.content_item.hide);
        return hidden != null && (!) hidden;
    }

    private Message persist_retraction_test_message(Database db, Account account,
            Jid counterpart, Jid ourpart, bool direction, Message.Type type,
            string stanza_id, string? server_id, string? edit_to,
            DateTime time) {
        var message = new Message(stanza_id);
        message.account = account;
        message.counterpart = counterpart;
        message.ourpart = ourpart;
        message.direction = direction;
        message.type_ = type;
        message.time = time;
        message.local_time = time;
        message.marked = Message.Marked.SENT;
        message.stanza_id = stanza_id;
        message.server_id = server_id;
        message.edit_to = edit_to;
        message.persist(db);

        if (edit_to != null) {
            db.message_correction.insert()
                .value(db.message_correction.message_id, message.id)
                .value(db.message_correction.to_stanza_id, (!) edit_to)
                .perform();
        }
        return message;
    }
}

// Exercise the core pipeline at the DECRYPT result boundary without claiming
// a crypto or trust test. The real plugin supplies authenticated plaintext,
// a fixed local failure diagnostic, or no body; it never exposes the wire
// fallback as decrypted content when decryption fails.
private class IncomingDecryptResultTestListener : MessageListener {
    public bool ran = false;
    private string? processed_body;
    private Encryption processed_encryption;
    private string? protocol;
    private string[] dependencies = {};
    public override string action_group { get { return "DECRYPT"; } }
    public override string[] after_actions { get { return dependencies; } }

    public IncomingDecryptResultTestListener(string? processed_body,
            Encryption processed_encryption = Encryption.OMEMO, string? protocol = null) {
        this.processed_body = processed_body;
        this.processed_encryption = processed_encryption;
        this.protocol = protocol;
    }

    public override async bool run(Message message, MessageStanza stanza,
            Conversation conversation) {
        ran = true;
        message.body = processed_body;
        message.encryption = processed_encryption;
        message.encryption_protocol = protocol;
        return false;
    }
}

// This fixture has no UI ContentItemStore. Keep the real encryption filters
// and message persistence, then stop before the content-item/UI listeners.
private class IncomingEncryptionStopAfterStore : MessageListener {
    public bool ran = false;
    private string[] dependencies = { "STORE" };
    public override string action_group { get { return "MESSAGE_REINTERPRETING"; } }
    public override string[] after_actions { get { return dependencies; } }

    public override async bool run(Message message, MessageStanza stanza,
            Conversation conversation) {
        ran = true;
        return true;
    }
}

private class RetractionBuildTestXmppStream : XmppStream {
    public signal void before_moderation_response(string moderation_id);
    public signal void before_retraction_write_result(string retraction_id);

    public Gee.ArrayList<string> moderation_ids { get; private set;
        default = new Gee.ArrayList<string>(); }
    public Gee.ArrayList<string> retraction_write_ids { get; private set;
        default = new Gee.ArrayList<string>(); }
    public bool moderation_payloads_valid { get; private set;
        default = true; }
    public string? fail_moderation_id { get; set; default = null; }
    public string? fail_retraction_write_id { get; set; default = null; }

    public RetractionBuildTestXmppStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("retraction-build test stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();

        if (node.name == "message") {
            StanzaNode? retract = node.get_subnode("retract",
                Xmpp.Xep.MessageRetraction.NS_URI);
            string? retraction_id = retract != null
                ? ((!) retract).get_attribute("id") : null;
            if (retraction_id != null) {
                retraction_write_ids.add((!) retraction_id);
                before_retraction_write_result((!) retraction_id);
                if (fail_retraction_write_id == retraction_id) {
                    throw new IOError.FAILED(
                        "scripted retraction write failure");
                }
            }
            return;
        }

        if (node.name != "iq") return;
        StanzaNode? moderate = node.get_subnode("moderate",
            Xmpp.Xep.MessageModeration.NS_URI);
        if (moderate == null) return;

        string? moderation_id = ((!) moderate).get_attribute("id");
        if (moderation_id != null) moderation_ids.add((!) moderation_id);
        if (moderation_id == null || node.get_attribute("to") == null ||
                ((!) moderate).get_subnode("retract",
                    Xmpp.Xep.MessageRetraction.NS_URI) == null) {
            moderation_payloads_valid = false;
        }

        string? request_id = node.get_attribute("id");
        string? request_to = node.get_attribute("to");
        Xmpp.Bind.Flag? bind = get_flag(Xmpp.Bind.Flag.IDENTITY);
        if (request_id == null || request_to == null || bind == null ||
                ((!) bind).my_jid == null) {
            moderation_payloads_valid = false;
            return;
        }

        bool fail_moderation = fail_moderation_id != null &&
            moderation_id == fail_moderation_id;
        StanzaNode response = new StanzaNode.build("iq")
            .put_attribute("type", fail_moderation ? "error" : "result")
            .put_attribute("id", (!) request_id)
            .put_attribute("from", (!) request_to)
            .put_attribute("to", ((!) bind).my_jid.to_string());
        if (fail_moderation) {
            response.put_node(new StanzaNode.build("error")
                .put_attribute("type", "auth")
                .put_node(new StanzaNode.build("forbidden",
                        "urn:ietf:params:xml:ns:xmpp-stanzas")
                    .add_self_xmlns()));
        }
        Idle.add(() => {
            if (moderation_id != null) {
                before_moderation_response((!) moderation_id);
            }
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }

    public void emit_presence(StanzaNode node) {
        received_presence_stanza(this, node);
    }

    public override async void setup() throws IOError {
    }
}

}
