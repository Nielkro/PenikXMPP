using Dino.Entities;
using Qlite;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

class ReplyIntegrityTest : Gee.TestCase {

    public ReplyIntegrityTest() {
        base("Replies");
        add_test("raw_target_survives_late_sender_checked_resolution",
            test_raw_target_survives_late_sender_checked_resolution);
        add_test("present_parent_id_collision_resolves_by_sender",
            test_present_parent_id_collision_resolves_by_sender);
        add_test("same_sender_id_collision_fails_closed",
            test_same_sender_id_collision_fails_closed);
        add_test("duplicate_target_resolves_pending_reply",
            test_duplicate_target_resolves_pending_reply);
        add_test("stable_id_dedup_is_type_and_pm_resource_scoped",
            test_stable_id_dedup_is_type_and_pm_resource_scoped);
        add_test("groupchat_mam_id_collision_preserves_distinct_room_messages",
            test_groupchat_mam_id_collision_preserves_distinct_room_messages);
        add_test("groupchat_room_references_ignore_colliding_mam_ids",
            test_groupchat_room_references_ignore_colliding_mam_ids);
        add_test("direct_lookup_deduplicates_corrections_files_and_orphans",
            test_direct_lookup_deduplicates_corrections_files_and_orphans);
        add_test("file_url_transport_uses_explicit_message_relation",
            test_file_url_transport_uses_explicit_message_relation);
        add_test("explicit_file_relation_disables_numeric_info_fallback",
            test_explicit_file_relation_disables_numeric_info_fallback);
        add_test("jingle_numeric_info_is_not_a_message_relation",
            test_jingle_numeric_info_is_not_a_message_relation);
        add_test("corrected_reply_uses_latest_explicit_parent",
            test_corrected_reply_uses_latest_explicit_parent);
        add_test("orphan_correction_keeps_its_explicit_reply_edge",
            test_orphan_correction_keeps_its_explicit_reply_edge);
        add_test("reply_sender_selection_uses_quoted_item",
            test_reply_sender_selection_uses_quoted_item);
        add_test("groupchat_reply_uses_original_room_stanza_id",
            test_groupchat_reply_uses_original_room_stanza_id);
        add_test("sender_matching_is_bare_only_for_direct_chat",
            test_sender_matching_is_bare_only_for_direct_chat);
    }

    private void test_present_parent_id_collision_resolves_by_sender() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("present-id-collision");
            DateTime base_time = new DateTime.from_unix_utc(1701500000);

            Message correct_parent = context.persist_message_for(
                context.conversation, "correct parent", false,
                "colliding-origin", base_time);
            correct_parent.ourpart = context.account.full_jid;
            correct_parent.counterpart = context.conversation.counterpart;
            int correct_parent_item_id = context.add_message_item(
                correct_parent);

            Message wrong_newer_parent = context.persist_message(
                "wrong newer parent", true, "colliding-origin", null,
                base_time.add_seconds(1));
            context.add_message_item(wrong_newer_parent);

            Message reply = context.persist_message("reply", true,
                "reply-to-collision", null, base_time.add_seconds(2));
            context.add_message_item(reply);
            MessageStanza reply_stanza = new MessageStanza(
                "reply-to-collision");
            Xmpp.Xep.Replies.set_reply_to(reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo(
                    context.conversation.counterpart,
                    "colliding-origin"));
            context.replies.process_incoming_for_tests(reply, reply_stanza,
                context.conversation);

            fail_if(reply.quoted_item_id != correct_parent_item_id,
                "A newer colliding id from another sender must not shadow the declared reply target");
        } catch (Error e) {
            fail_if_reached(@"Present parent collision test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_file_url_transport_uses_explicit_message_relation() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("file-url-message-relation");
            DateTime time = new DateTime.from_unix_utc(1701550000);
            Message message = context.persist_message("https://upload.example.test/photo.jpg",
                false, "file-origin", null, time);

            var transfer = new FileTransfer();
            transfer.account = context.account;
            transfer.counterpart = (!) message.counterpart;
            transfer.ourpart = context.account.bare_jid.with_resource(
                "desktop");
            transfer.direction = FileTransfer.DIRECTION_RECEIVED;
            transfer.time = time;
            transfer.local_time = time;
            transfer.file_name = "photo.jpg";
            transfer.size = 42;
            transfer.info = "url:https://upload.example.test/photo.jpg";
            transfer.message_db_id = message.id;
            transfer.persist(context.db);
            int file_item_id = context.db.add_content_item(
                context.conversation, time, time, 2, transfer.id, false);

            ContentItem? item = context.content_item_store.get_item_by_id(
                context.conversation, file_item_id);
            fail_if(item == null,
                "a URL-backed file content item must remain materializable");
            fail_if(context.content_item_store.get_message_id_for_content_item(
                    context.conversation, (!) item) != "file-origin",
                "reply and reaction actions must resolve through the explicit message relation, not transport info");
            ContentItem? reverse_item = context.content_item_store
                .get_content_item_for_message(context.conversation, message);
            fail_if(reverse_item == null || ((!) reverse_item).id != file_item_id,
                "message-to-content lookup must return the URL-backed file row");

            Message reply = context.persist_message("reply to file", false,
                "file-reply", null, time.add_seconds(1));
            context.add_message_item(reply);
            var reply_stanza = new MessageStanza("file-reply");
            Xmpp.Xep.Replies.set_reply_to(reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo((!) message.from,
                    "file-origin"));
            context.replies.process_incoming_for_tests(reply, reply_stanza,
                context.conversation);
            fail_if(reply.quoted_item_id != file_item_id,
                "incoming replies must resolve URL-backed files through the explicit message relation");
        } catch (Error e) {
            fail_if_reached(@"File URL message relation test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_explicit_file_relation_disables_numeric_info_fallback() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("explicit-file-relation-collision");
            DateTime time = new DateTime.from_unix_utc(1701570000);
            Message file_message = context.persist_message(
                "https://upload.example.test/actual.jpg", false,
                "actual-file", null, time);
            Message unrelated_message = context.persist_message(
                "plain text", false, "unrelated-message", null,
                time.add_seconds(1));
            int unrelated_item_id = context.add_message_item(
                unrelated_message);

            var transfer = new FileTransfer();
            transfer.account = context.account;
            transfer.counterpart = (!) file_message.counterpart;
            transfer.ourpart = context.account.bare_jid.with_resource(
                "desktop");
            transfer.direction = FileTransfer.DIRECTION_RECEIVED;
            transfer.time = time;
            transfer.local_time = time;
            transfer.file_name = "actual.jpg";
            transfer.size = 42;
            // Simulate stale transport data that happens to look like another
            // local message id. Once an explicit relation exists, it wins.
            transfer.info = unrelated_message.id.to_string();
            transfer.message_db_id = file_message.id;
            transfer.persist(context.db);
            int file_item_id = context.db.add_content_item(
                context.conversation, time, time, 2, transfer.id, false);

            ContentItem? file_item = context.content_item_store
                .get_content_item_for_message(context.conversation,
                    file_message);
            fail_if(file_item == null || ((!) file_item).id != file_item_id,
                "the explicit relation must resolve the file message");
            ContentItem? unrelated_item = context.content_item_store
                .get_content_item_for_message(context.conversation,
                    unrelated_message);
            fail_if(unrelated_item == null ||
                    ((!) unrelated_item).id != unrelated_item_id,
                "numeric transport info on an explicitly related transfer must not shadow an unrelated message");

            Message reply = context.persist_message("reply to plain text",
                false, "reply-to-unrelated", null, time.add_seconds(2));
            context.add_message_item(reply);
            var reply_stanza = new MessageStanza("reply-to-unrelated");
            Xmpp.Xep.Replies.set_reply_to(reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo((!) unrelated_message.from,
                    "unrelated-message"));
            context.replies.process_incoming_for_tests(reply, reply_stanza,
                context.conversation);
            fail_if(reply.quoted_item_id != unrelated_item_id,
                "reply lookup must ignore numeric info when the transfer has an explicit relation");
        } catch (Error e) {
            fail_if_reached(@"Explicit file relation collision test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_jingle_numeric_info_is_not_a_message_relation() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("jingle-numeric-info");
            DateTime time = new DateTime.from_unix_utc(1701580000);
            Message message = context.persist_message("plain message", false,
                "plain-origin", null, time);
            int message_item_id = context.add_message_item(message);

            var transfer = new FileTransfer();
            transfer.account = context.account;
            transfer.counterpart = (!) message.counterpart;
            transfer.ourpart = context.account.bare_jid.with_resource(
                "desktop");
            transfer.direction = FileTransfer.DIRECTION_RECEIVED;
            transfer.time = time.add_seconds(1);
            transfer.local_time = transfer.time;
            transfer.file_name = "jingle.bin";
            transfer.size = 42;
            transfer.provider = FileManager.JINGLE_PROVIDER_ID;
            transfer.info = message.id.to_string();
            transfer.message_db_id = -1;
            transfer.persist(context.db);
            int file_item_id = context.db.add_content_item(
                context.conversation, transfer.time, transfer.local_time, 2,
                transfer.id, false);

            ContentItem? file_item = context.content_item_store.get_item_by_id(
                context.conversation, file_item_id);
            fail_if(file_item == null,
                "the Jingle transfer fixture must remain materializable");
            fail_if(context.content_item_store.get_message_for_content_item(
                    context.conversation, (!) file_item) != null,
                "a numeric Jingle session id must not resolve to a backing chat message");
            fail_if(context.stream_interactor.get_module<FileTransferStorage>(
                    FileTransferStorage.IDENTITY).get_file_by_message_id(
                        message.id, context.conversation) != null,
                "FileTransferStorage must not expose a Jingle session id as a legacy message relation");

            ContentItem? reverse_item = context.content_item_store
                .get_content_item_for_message(context.conversation, message);
            fail_if(reverse_item == null ||
                    ((!) reverse_item).id != message_item_id,
                "reverse lookup must keep the real MessageItem when Jingle info collides with its database id");

            Message reply = context.persist_message("reply", false,
                "reply-to-plain", null, time.add_seconds(2));
            context.add_message_item(reply);
            var stanza = new MessageStanza("reply-to-plain");
            Xmpp.Xep.Replies.set_reply_to(stanza,
                new Xmpp.Xep.Replies.ReplyTo((!) message.from,
                    "plain-origin"));
            context.replies.process_incoming_for_tests(reply, stanza,
                context.conversation);
            fail_if(reply.quoted_item_id != message_item_id,
                "reply resolution must ignore a colliding numeric Jingle transport identifier");
        } catch (Error e) {
            fail_if_reached(@"Jingle numeric relation test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_same_sender_id_collision_fails_closed() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("same-sender-id-collision");
            DateTime base_time = new DateTime.from_unix_utc(1701600000);

            Message first_parent = context.persist_message("first", false,
                "same-sender-collision", null, base_time);
            context.add_message_item(first_parent);
            Message second_parent = context.persist_message("second", false,
                "same-sender-collision", null, base_time.add_seconds(1));
            context.add_message_item(second_parent);

            Message reply = context.persist_message("ambiguous reply", true,
                "ambiguous-reply", null, base_time.add_seconds(2));
            context.add_message_item(reply);
            MessageStanza stanza = new MessageStanza("ambiguous-reply");
            Xmpp.Xep.Replies.set_reply_to(stanza,
                new Xmpp.Xep.Replies.ReplyTo(
                    context.conversation.counterpart.with_resource("phone"),
                    "same-sender-collision"));
            context.replies.process_incoming_for_tests(reply, stanza,
                context.conversation);

            fail_if(reply.quoted_item_id != 0,
                "Two logical messages from the same full sender with one id must remain ambiguous");

            // Both colliding physical roots can project onto the same current
            // ContentItem after a correction. The physical id is still
            // ambiguous and must not become resolvable through that collapse.
            Message colliding_correction = context.persist_message(
                "corrected collision", false, "collision-correction", null,
                base_time.add_seconds(2));
            colliding_correction.edit_to = "same-sender-collision";
            context.db.message_correction.insert()
                .value(context.db.message_correction.message_id,
                    colliding_correction.id)
                .value(context.db.message_correction.to_stanza_id,
                    "same-sender-collision")
                .perform();
            context.db.content_item.update()
                .with(context.db.content_item.foreign_id, "=",
                    first_parent.id)
                .set(context.db.content_item.foreign_id,
                    colliding_correction.id)
                .perform();
            Message collapsed_reply = context.persist_message(
                "collapsed ambiguous reply", true,
                "collapsed-ambiguous-reply", null,
                base_time.add_seconds(3));
            context.add_message_item(collapsed_reply);
            var collapsed_stanza = new MessageStanza(
                "collapsed-ambiguous-reply");
            Xmpp.Xep.Replies.set_reply_to(collapsed_stanza,
                new Xmpp.Xep.Replies.ReplyTo(
                    context.conversation.counterpart.with_resource("phone"),
                    "same-sender-collision"));
            context.replies.process_incoming_for_tests(collapsed_reply,
                collapsed_stanza, context.conversation);
            fail_if(collapsed_reply.quoted_item_id != 0,
                "Two colliding physical roots must remain ambiguous even when both map to one corrected ContentItem");

            Message pending_reply = context.persist_message("late reply",
                true, "late-collision-reply", null,
                base_time.add_seconds(4));
            context.add_message_item(pending_reply);
            MessageStanza pending_stanza = new MessageStanza(
                "late-collision-reply");
            Xmpp.Xep.Replies.set_reply_to(pending_stanza,
                new Xmpp.Xep.Replies.ReplyTo(
                    context.conversation.counterpart.with_resource("phone"),
                    "late-same-sender-collision"));
            context.replies.process_incoming_for_tests(pending_reply,
                pending_stanza, context.conversation);

            Message late_first = context.persist_message("late first", false,
                "late-same-sender-collision", null,
                base_time.add_seconds(5));
            int late_first_item_id = context.add_message_item(late_first);
            context.replies.process_incoming_for_tests(late_first,
                new MessageStanza("late-same-sender-collision"),
                context.conversation);
            fail_if(pending_reply.quoted_item_id != late_first_item_id,
                "One late sender-scoped target should resolve the raw reply");

            Message late_second = context.persist_message("late second",
                false, "late-same-sender-collision", null,
                base_time.add_seconds(6));
            context.add_message_item(late_second);
            context.replies.process_incoming_for_tests(late_second,
                new MessageStanza("late-same-sender-collision"),
                context.conversation);
            fail_if(pending_reply.quoted_item_id != 0,
                "A later same-sender/id collision must restore the unresolved raw edge");
        } catch (Error e) {
            fail_if_reached(@"Same-sender collision test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_duplicate_target_resolves_pending_reply() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("duplicate-target-resolution");
            DateTime base_time = new DateTime.from_unix_utc(1701750000);
            string parent_origin =
                "11111111-1111-4111-8111-111111111111";

            Message pending_reply = context.persist_message("reply", false,
                "pending-reply", null, base_time);
            context.add_message_item(pending_reply);
            MessageStanza reply_stanza = new MessageStanza("pending-reply");
            Xmpp.Xep.Replies.set_reply_to(reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo(
                    context.account.bare_jid.with_resource("desktop"),
                    "room-assigned-parent"));
            context.replies.process_incoming_for_tests(pending_reply,
                reply_stanza, context.conversation);
            fail_if(pending_reply.quoted_item_id != 0,
                "The raw reply must initially remain unresolved");

            Message canonical_parent = context.persist_message("parent",
                true, parent_origin, null, base_time.add_seconds(1));
            int parent_item_id = context.add_message_item(canonical_parent);

            var echo = new Message("parent");
            echo.account = context.account;
            echo.counterpart = context.conversation.counterpart;
            echo.ourpart = context.account.bare_jid.with_resource("desktop");
            echo.direction = Message.DIRECTION_SENT;
            echo.type_ = Message.Type.CHAT;
            echo.time = base_time.add_seconds(2);
            echo.local_time = echo.time;
            echo.stanza_id = parent_origin;
            echo.server_id = "room-assigned-parent";

            bool has_stable_id;
            bool duplicate = context.message_processor
                .is_stable_id_duplicate(echo,
                    new MessageStanza(parent_origin), context.conversation,
                    out has_stable_id);
            fail_if(!duplicate || !has_stable_id ||
                    canonical_parent.server_id != "room-assigned-parent",
                "The duplicate echo must update the canonical target's server id");
            fail_if(pending_reply.quoted_item_id != parent_item_id,
                "A deduplicated target must still resolve pending raw reply metadata");

            string duplicate_reply_id =
                "22222222-2222-4222-8222-222222222222";
            Message canonical_reply = context.persist_message(
                "reply stored before crash", false, duplicate_reply_id,
                null, base_time.add_seconds(3));
            context.add_message_item(canonical_reply);
            fail_if(context.db.reply.select({context.db.reply.message_id})
                    .with(context.db.reply.message_id, "=",
                        canonical_reply.id).count() != 0,
                "The crash-recovery fixture must start without reply metadata");

            var replayed_reply = new Message("reply stored before crash");
            replayed_reply.account = context.account;
            replayed_reply.counterpart = canonical_reply.counterpart;
            replayed_reply.ourpart = canonical_reply.ourpart;
            replayed_reply.direction = canonical_reply.direction;
            replayed_reply.type_ = canonical_reply.type_;
            replayed_reply.time = base_time.add_seconds(4);
            replayed_reply.local_time = replayed_reply.time;
            replayed_reply.stanza_id = duplicate_reply_id;
            var replayed_reply_stanza = new MessageStanza(
                duplicate_reply_id);
            Xmpp.Xep.Replies.set_reply_to(replayed_reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo(canonical_parent.from,
                    parent_origin));
            duplicate = context.message_processor.is_stable_id_duplicate(
                replayed_reply, replayed_reply_stanza,
                context.conversation, out has_stable_id);
            fail_if(!duplicate || !has_stable_id,
                "The replayed reply must take the stable-id duplicate path");
            assert_reply_row(context.db, canonical_reply.id, parent_item_id,
                parent_origin, canonical_parent.from.to_string());

            // A later replay without XEP-0461 must not erase metadata already
            // recovered from the immutable stored stanza.
            duplicate = context.message_processor.is_stable_id_duplicate(
                replayed_reply, new MessageStanza(duplicate_reply_id),
                context.conversation, out has_stable_id);
            fail_if(!duplicate || !has_stable_id,
                "The metadata-preservation replay must still deduplicate");
            assert_reply_row(context.db, canonical_reply.id, parent_item_id,
                parent_origin, canonical_parent.from.to_string());

            string raw_reply_id =
                "33333333-3333-4333-8333-333333333333";
            Message raw_canonical_reply = context.persist_message(
                "raw reply stored before crash", false, raw_reply_id, null,
                base_time.add_seconds(5));
            context.add_message_item(raw_canonical_reply);
            raw_canonical_reply.set_quoted_reference(parent_origin,
                (!) canonical_parent.from);
            assert_reply_row(context.db, raw_canonical_reply.id, 0,
                parent_origin, canonical_parent.from.to_string());
            var raw_replay = new Message("raw reply stored before crash");
            raw_replay.account = context.account;
            raw_replay.counterpart = raw_canonical_reply.counterpart;
            raw_replay.ourpart = raw_canonical_reply.ourpart;
            raw_replay.direction = raw_canonical_reply.direction;
            raw_replay.type_ = raw_canonical_reply.type_;
            raw_replay.time = base_time.add_seconds(6);
            raw_replay.local_time = raw_replay.time;
            raw_replay.stanza_id = raw_reply_id;
            duplicate = context.message_processor.is_stable_id_duplicate(
                raw_replay, new MessageStanza(raw_reply_id),
                context.conversation, out has_stable_id);
            fail_if(!duplicate || !has_stable_id,
                "The raw-edge crash replay must deduplicate");
            assert_reply_row(context.db, raw_canonical_reply.id,
                parent_item_id, parent_origin,
                canonical_parent.from.to_string());

            Message legacy_older = context.persist_message(
                "older legacy reply", false, "legacy-collision", null,
                base_time.add_seconds(10));
            context.add_message_item(legacy_older);
            Message legacy_newer = context.persist_message(
                "newer unrelated body", false, "legacy-collision", null,
                base_time.add_seconds(11));
            context.add_message_item(legacy_newer);
            var legacy_replay = new Message("older legacy reply");
            legacy_replay.account = context.account;
            legacy_replay.counterpart = legacy_older.counterpart;
            legacy_replay.ourpart = legacy_older.ourpart;
            legacy_replay.direction = legacy_older.direction;
            legacy_replay.type_ = legacy_older.type_;
            legacy_replay.time = legacy_older.time;
            legacy_replay.local_time = legacy_older.local_time;
            legacy_replay.stanza_id = "legacy-collision";
            var legacy_stanza = new MessageStanza("legacy-collision");
            Xmpp.Xep.Replies.set_reply_to(legacy_stanza,
                new Xmpp.Xep.Replies.ReplyTo((!) canonical_parent.from,
                    parent_origin));
            fail_if(!context.message_processor.is_duplicate_for_tests(
                    legacy_replay, legacy_stanza, context.conversation),
                "The non-UUID legacy replay must deduplicate by its exact body/time candidate");
            assert_reply_row(context.db, legacy_older.id, parent_item_id,
                parent_origin, canonical_parent.from.to_string());
            fail_if(context.db.reply.select({context.db.reply.message_id})
                    .with(context.db.reply.message_id, "=",
                        legacy_newer.id).count() != 0,
                "A colliding newer non-UUID message must not receive the older replay's reply edge");
        } catch (Error e) {
            fail_if_reached(@"Duplicate target resolution test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_stable_id_dedup_is_type_and_pm_resource_scoped() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("stable-id-dedup-scope");
            DateTime base_time = new DateTime.from_unix_utc(1701850000);
            Jid room = new Jid("room@conference.example.test");
            var groupchat = new Conversation(room, context.account,
                Conversation.Type.GROUPCHAT);
            groupchat.persist(context.db);
            var bob_pm = new Conversation(room.with_resource("Bob"),
                context.account, Conversation.Type.GROUPCHAT_PM);
            bob_pm.persist(context.db);
            var carol_pm = new Conversation(room.with_resource("Carol"),
                context.account, Conversation.Type.GROUPCHAT_PM);
            carol_pm.persist(context.db);

            context.persist_message_for(groupchat, "group message", false,
                "group-origin", base_time, "shared-room-id",
                room.with_resource("Bob"));

            var incoming_pm = new Message("private message");
            incoming_pm.account = context.account;
            incoming_pm.counterpart = room.with_resource("Bob");
            incoming_pm.ourpart = room.with_resource("Alice");
            incoming_pm.direction = Message.DIRECTION_RECEIVED;
            incoming_pm.type_ = Message.Type.GROUPCHAT_PM;
            incoming_pm.time = base_time.add_seconds(1);
            incoming_pm.local_time = incoming_pm.time;
            incoming_pm.stanza_id = "pm-origin";
            incoming_pm.server_id = "shared-room-id";
            bool has_stable_id;
            fail_if(context.message_processor.is_stable_id_duplicate(
                    incoming_pm, new MessageStanza("pm-origin"), bob_pm,
                    out has_stable_id) || !has_stable_id,
                "A GROUPCHAT room id must not deduplicate a GROUPCHAT_PM stanza");

            string shared_uuid =
                "44444444-4444-4444-8444-444444444444";
            context.persist_message_for(bob_pm, "Bob PM", false,
                shared_uuid, base_time.add_seconds(2), null,
                room.with_resource("Bob"));

            var carol_replay = new Message("Bob PM");
            carol_replay.account = context.account;
            carol_replay.counterpart = room.with_resource("Carol");
            carol_replay.ourpart = room.with_resource("Alice");
            carol_replay.direction = Message.DIRECTION_RECEIVED;
            carol_replay.type_ = Message.Type.GROUPCHAT_PM;
            carol_replay.time = base_time.add_seconds(2);
            carol_replay.local_time = carol_replay.time;
            carol_replay.stanza_id = shared_uuid;
            fail_if(context.message_processor.is_stable_id_duplicate(
                    carol_replay, new MessageStanza(shared_uuid), carol_pm,
                    out has_stable_id) || !has_stable_id,
                "A PM stanza id from one room occupant must not deduplicate another occupant's PM");

            var bob_replay = new Message("Bob PM");
            bob_replay.account = context.account;
            bob_replay.counterpart = room.with_resource("Bob");
            bob_replay.ourpart = room.with_resource("Alice");
            bob_replay.direction = Message.DIRECTION_RECEIVED;
            bob_replay.type_ = Message.Type.GROUPCHAT_PM;
            bob_replay.time = base_time.add_seconds(2);
            bob_replay.local_time = bob_replay.time;
            bob_replay.stanza_id = shared_uuid;
            fail_if(!context.message_processor.is_stable_id_duplicate(
                    bob_replay, new MessageStanza(shared_uuid), bob_pm,
                    out has_stable_id) || !has_stable_id,
                "The exact same room occupant PM must still deduplicate");
        } catch (Error e) {
            fail_if_reached(@"Stable-id dedup scope test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_groupchat_mam_id_collision_preserves_distinct_room_messages() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("groupchat-mam-id-collision",
                Conversation.Type.GROUPCHAT);
            DateTime base_time = new DateTime.from_unix_utc(1701870000);
            Jid room = context.conversation.counterpart.bare_jid;
            string origin_a = "55555555-5555-4555-8555-555555555555";
            string origin_b = "66666666-6666-4666-8666-666666666666";

            // A live stanza's server_id contains the room-assigned stanza id.
            Message room_live_a = context.persist_message_for(
                context.conversation, "live room message A", false,
                origin_a, base_time, "colliding-id");
            room_live_a.sender_stanza_id = origin_a;
            room_live_a.set_stable_reference("colliding-id", room);

            int message_b_id = -1;
            for (int attempt = 0; attempt < 3; attempt++) {
                // Own-MAM can independently assign the same scalar id to B.
                // Its authoritative room stanza id and origin id identify a
                // different message; later attempts replay that exact B.
                var incoming_b = new Message("archived room message B");
                incoming_b.account = context.account;
                incoming_b.counterpart = room.with_resource("Bob");
                incoming_b.ourpart = room.with_resource("Alice");
                incoming_b.direction = Message.DIRECTION_RECEIVED;
                incoming_b.type_ = Message.Type.GROUPCHAT;
                incoming_b.time = base_time.add_seconds(1);
                incoming_b.local_time = incoming_b.time;
                incoming_b.stanza_id = origin_b;
                incoming_b.sender_stanza_id = origin_b;
                incoming_b.server_id = "colliding-id";
                incoming_b.set_stable_reference("different-room-id", room);

                bool has_stable_id;
                bool duplicate = context.message_processor
                    .is_stable_id_duplicate(incoming_b,
                        new MessageStanza(origin_b), context.conversation,
                        out has_stable_id);
                fail_if(duplicate != (attempt > 0) || !has_stable_id,
                    "A colliding Own-MAM id must preserve distinct room messages and deduplicate exact replays of B");

                fail_if(room_live_a.body != "live room message A" ||
                        room_live_a.stanza_id != origin_a ||
                        room_live_a.sender_stanza_id != origin_a ||
                        room_live_a.server_id != "colliding-id" ||
                        room_live_a.stable_id != "colliding-id" ||
                        room_live_a.stable_id_by == null ||
                        !((!) room_live_a.stable_id_by).equals(room),
                    "Neither B nor its replays may overwrite the cached live message A");
                RowOption stored_a = context.db.message.select()
                    .with(context.db.message.id, "=", room_live_a.id)
                    .single().row();
                fail_if(!stored_a.is_present(),
                    "The live message A must remain persisted");
                if (!stored_a.is_present()) return;
                fail_if(stored_a[context.db.message.body] !=
                            "live room message A" ||
                        stored_a[context.db.message.stanza_id] != origin_a ||
                        stored_a[context.db.message.sender_stanza_id] !=
                            origin_a ||
                        stored_a[context.db.message.server_id] !=
                            "colliding-id" ||
                        stored_a[context.db.message.stable_id] !=
                            "colliding-id" ||
                        stored_a[context.db.message.stable_id_by] !=
                            room.to_string(),
                    "Neither B nor its replays may overwrite A's persisted references");

                if (!duplicate) {
                    context.message_storage.add_message(incoming_b,
                        context.conversation);
                    if (attempt == 0) message_b_id = incoming_b.id;
                }
                fail_if(message_b_id == -1 ||
                        context.db.message.select()
                            .with(context.db.message.account_id, "=",
                                context.account.id)
                            .with(context.db.message.counterpart_id, "=",
                                context.db.get_jid_id(room))
                            .with(context.db.message.type_, "=",
                                (int) Message.Type.GROUPCHAT).count() != 2,
                    "A and B must persist separately, with no additional row for B's replays");
                RowOption stored_b = context.db.message.select()
                    .with(context.db.message.id, "=", message_b_id)
                    .single().row();
                fail_if(!stored_b.is_present(),
                    "The distinct Own-MAM message B must remain persisted");
                if (!stored_b.is_present()) return;
                fail_if(stored_b[context.db.message.body] !=
                            "archived room message B" ||
                        stored_b[context.db.message.stanza_id] != origin_b ||
                        stored_b[context.db.message.sender_stanza_id] !=
                            origin_b ||
                        stored_b[context.db.message.server_id] !=
                            "colliding-id" ||
                        stored_b[context.db.message.stable_id] !=
                            "different-room-id" ||
                        stored_b[context.db.message.stable_id_by] !=
                            room.to_string(),
                    "B's exact replays must preserve B's own persisted references");
            }
        } catch (Error e) {
            fail_if_reached(@"Groupchat MAM id collision test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_groupchat_room_references_ignore_colliding_mam_ids() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("groupchat-mam-reference-collision",
                Conversation.Type.GROUPCHAT);
            DateTime base_time = new DateTime.from_unix_utc(1701890000);
            Jid room = context.conversation.counterpart.bare_jid;
            Jid bob = room.with_resource("Bob");
            string origin_a = "77777777-7777-4777-8777-777777777777";
            string origin_b = "88888888-8888-4888-8888-888888888888";

            Message room_live_a = context.persist_message_for(
                context.conversation, "live room message A", false,
                origin_a, base_time, "100", bob);
            room_live_a.set_stable_reference("100", room);
            int item_a_id = context.add_message_item(room_live_a);

            // Resolve A's edge before B arrives: B's unrelated Own-MAM id
            // must never invalidate this already correct room reference.
            Message early_reply_a = context.persist_message("early reply to A",
                false, "early-reply-a", null, base_time.add_seconds(1));
            context.add_message_item(early_reply_a);
            var early_reply_stanza = new MessageStanza("early-reply-a");
            Xmpp.Xep.Replies.set_reply_to(early_reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo(bob, "100"));
            context.replies.process_incoming_for_tests(early_reply_a,
                early_reply_stanza, context.conversation);
            fail_if(early_reply_a.quoted_item_id != item_a_id,
                "The early room reference to A must resolve before B exists");
            assert_reply_row(context.db, early_reply_a.id, item_a_id,
                "100", bob.to_string());

            Message pending_reply_b = context.persist_message("pending reply to B",
                true, "pending-reply-b", null, base_time.add_seconds(2));
            context.add_message_item(pending_reply_b);
            var pending_reply_stanza = new MessageStanza("pending-reply-b");
            Xmpp.Xep.Replies.set_reply_to(pending_reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo(bob, "200"));
            context.replies.process_incoming_for_tests(pending_reply_b,
                pending_reply_stanza, context.conversation);
            fail_if(pending_reply_b.quoted_item_id != 0,
                "A reply to B's room id must remain pending until B arrives");
            assert_reply_row(context.db, pending_reply_b.id, 0,
                "200", bob.to_string());

            // Both parents deliberately have the same exact occupant sender,
            // so sender matching cannot conceal the colliding archive id.
            Message room_archived_b = context.persist_message_for(
                context.conversation, "archived room message B", false,
                origin_b, base_time.add_seconds(3), "100", bob);
            room_archived_b.set_stable_reference("200", room);
            int item_b_id = context.add_message_item(room_archived_b);
            context.replies.resolve_pending_replies_to(room_archived_b,
                context.conversation);
            fail_if(pending_reply_b.quoted_item_id != item_b_id,
                "B's arrival must resolve the pending reply through B's room id");
            assert_reply_row(context.db, pending_reply_b.id, item_b_id,
                "200", bob.to_string());
            fail_if(early_reply_a.quoted_item_id != item_a_id,
                "B's foreign Own-MAM id must not invalidate the existing reply to A");
            assert_reply_row(context.db, early_reply_a.id, item_a_id,
                "100", bob.to_string());

            Message? lookup_a = context.message_storage
                .get_message_by_server_id("100", context.conversation);
            Message? lookup_b = context.message_storage
                .get_message_by_server_id("200", context.conversation);
            fail_if(lookup_a == null || ((!) lookup_a).id != room_live_a.id ||
                    lookup_b == null || ((!) lookup_b).id != room_archived_b.id,
                "Room-id lookup must distinguish A and B despite B shadowing the scalar server-id cache");

            ContentItem? item_a = context.content_item_store.get_item_by_id(
                context.conversation, item_a_id);
            ContentItem? item_b = context.content_item_store.get_item_by_id(
                context.conversation, item_b_id);
            fail_if(item_a == null || item_b == null,
                "Both distinct parent ContentItems must remain materializable");
            if (item_a == null || item_b == null) return;
            fail_if(context.content_item_store.get_message_id_for_content_item(
                        context.conversation, (!) item_a) != "100" ||
                    context.content_item_store.get_message_id_for_content_item(
                        context.conversation, (!) item_b) != "200",
                "Outgoing groupchat references must use each parent's room id, not its Own-MAM id");

            Message late_reply_a = context.persist_message("late reply to A",
                false, "late-reply-a", null, base_time.add_seconds(4));
            context.add_message_item(late_reply_a);
            var late_reply_stanza = new MessageStanza("late-reply-a");
            Xmpp.Xep.Replies.set_reply_to(late_reply_stanza,
                new Xmpp.Xep.Replies.ReplyTo(bob, "100"));
            context.replies.process_incoming_for_tests(late_reply_a,
                late_reply_stanza, context.conversation);
            fail_if(late_reply_a.quoted_item_id != item_a_id,
                "A new incoming reply to A's room id must resolve to A despite B's colliding archive id and sender");
            assert_reply_row(context.db, late_reply_a.id, item_a_id,
                "100", bob.to_string());
        } catch (Error e) {
            fail_if_reached(@"Groupchat MAM reference collision test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_raw_target_survives_late_sender_checked_resolution() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("late-resolution");
            DateTime base_time = new DateTime.from_unix_utc(1701000000);

            Message valid_reply = context.persist_message("valid reply",
                false, "reply-valid", null, base_time.add_seconds(1));
            int valid_reply_item_id = context.add_message_item(valid_reply);
            MessageStanza valid_stanza = new MessageStanza("reply-valid");
            Xmpp.Xep.Replies.set_reply_to(valid_stanza,
                new Xmpp.Xep.Replies.ReplyTo(context.account.bare_jid,
                    "parent-origin"));
            context.replies.process_incoming_for_tests(valid_reply,
                valid_stanza, context.conversation);

            Message wrong_sender_reply = context.persist_message(
                "wrong sender reply", false, "reply-wrong", null,
                base_time.add_seconds(2));
            context.add_message_item(wrong_sender_reply);
            MessageStanza wrong_sender_stanza = new MessageStanza(
                "reply-wrong");
            Xmpp.Xep.Replies.set_reply_to(wrong_sender_stanza,
                new Xmpp.Xep.Replies.ReplyTo(
                    new Jid("mallory@example.test"), "parent-origin"));
            context.replies.process_incoming_for_tests(wrong_sender_reply,
                wrong_sender_stanza, context.conversation);

            assert_reply_row(context.db, valid_reply.id, 0,
                "parent-origin", context.account.bare_jid.to_string());
            assert_reply_row(context.db, wrong_sender_reply.id, 0,
                "parent-origin", "mallory@example.test");

            Message parent = context.persist_message("parent", true,
                "parent-origin", "parent-server", base_time);
            int parent_item_id = context.add_message_item(parent);
            context.replies.process_incoming_for_tests(parent,
                new MessageStanza("parent-origin"), context.conversation);

            fail_if(valid_reply.quoted_item_id != parent_item_id,
                "A reply delivered before its parent must resolve once the sender-checked parent arrives");
            fail_if(wrong_sender_reply.quoted_item_id != 0,
                "A colliding target id from another declared sender must remain unresolved");
            assert_reply_row(context.db, valid_reply.id, parent_item_id,
                "parent-origin", context.account.bare_jid.to_string());
            assert_reply_row(context.db, wrong_sender_reply.id, 0,
                "parent-origin", "mallory@example.test");

            ContentItem? parent_item = context.content_item_store
                .get_item_by_id(context.conversation, parent_item_id);
            fail_if(parent_item == null,
                "The parent ContentItem must be materializable");
            Gee.List<ContentItem> direct = context.replies
                .get_direct_replies(context.conversation, (!) parent_item);
            fail_if(direct.size != 1 || direct[0].id != valid_reply_item_id,
                "Only the sender-verified direct reply may enter the reverse lookup");
        } catch (Error e) {
            fail_if_reached(@"Late reply resolution test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_direct_lookup_deduplicates_corrections_files_and_orphans() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("reverse-lookup");
            DateTime base_time = new DateTime.from_unix_utc(1702000000);

            Message parent = context.persist_message("parent", true,
                "parent", "parent-server", base_time);
            int parent_item_id = context.add_message_item(parent);
            ContentItem? parent_item = context.content_item_store
                .get_item_by_id(context.conversation, parent_item_id);
            fail_if(parent_item == null,
                "The reverse lookup parent must be materializable");

            Message original_reply = context.persist_message("reply v0",
                false, "reply-v0", "reply-server-v0",
                base_time.add_seconds(1));
            original_reply.set_quoted_item(parent_item_id, "parent",
                context.account.bare_jid);
            int corrected_item_id = context.add_message_item(original_reply);

            Message correction = context.persist_message("reply v1", false,
                "reply-v1", "reply-server-v1", base_time.add_seconds(2));
            correction.edit_to = "reply-v0";
            context.db.message_correction.insert()
                .value(context.db.message_correction.message_id,
                    correction.id)
                .value(context.db.message_correction.to_stanza_id,
                    "reply-v0")
                .perform();
            // A correction is a new physical stanza. Other clients need not
            // repeat the XEP-0461 payload, so the only reply edge deliberately
            // remains attached to the original revision.
            context.db.content_item.update()
                .with(context.db.content_item.id, "=", corrected_item_id)
                .set(context.db.content_item.foreign_id, correction.id)
                .perform();

            Message file_message = context.persist_message("file", false,
                "file-message", "file-server", base_time.add_seconds(3));
            file_message.set_quoted_item(parent_item_id, "parent",
                context.account.bare_jid);
            var file_transfer = new FileTransfer();
            file_transfer.account = context.account;
            file_transfer.counterpart = (!) file_message.counterpart;
            file_transfer.ourpart = context.account.bare_jid
                .with_resource("desktop");
            file_transfer.direction = FileTransfer.DIRECTION_RECEIVED;
            file_transfer.time = base_time.add_seconds(3);
            file_transfer.local_time = file_transfer.time;
            file_transfer.file_name = "reply.txt";
            file_transfer.size = 5;
            file_transfer.info = file_message.id.to_string();
            file_transfer.persist(context.db);
            int file_item_id = context.db.add_content_item(
                context.conversation, file_transfer.time,
                file_transfer.local_time, 2, file_transfer.id, false);

            // No backing message/content item: must never leak into results.
            context.db.reply.insert()
                .value(context.db.reply.message_id, 999999)
                .value(context.db.reply.quoted_content_item_id,
                    parent_item_id)
                .perform();

            var other_conversation = new Conversation(
                new Jid("charlie@example.test"), context.account,
                Conversation.Type.CHAT);
            other_conversation.persist(context.db);
            Message other_message = context.persist_message_for(
                other_conversation, "other conversation", false,
                "other-reply", base_time.add_seconds(4));
            int other_item_id = context.db.add_content_item(
                other_conversation, other_message.time,
                other_message.local_time, 1, other_message.id, false);
            other_message.set_quoted_item(parent_item_id, "parent",
                context.account.bare_jid);

            Gee.List<ContentItem> direct = context.replies
                .get_direct_replies(context.conversation, (!) parent_item);
            fail_if(direct.size != 2,
                "One corrected reply and one file reply must yield exactly two logical rows");
            fail_if(!contains_item(direct, corrected_item_id) ||
                    !contains_item(direct, file_item_id) ||
                    contains_item(direct, other_item_id),
                "The reverse lookup must include current local rows only and remain conversation scoped");

            context.db.content_item.update()
                .with(context.db.content_item.id, "=", corrected_item_id)
                .set(context.db.content_item.hide, true)
                .perform();
            Gee.List<ContentItem> visible = context.replies
                .get_direct_replies(context.conversation, (!) parent_item);
            Gee.List<ContentItem> including_hidden = context.replies
                .get_direct_replies(context.conversation, (!) parent_item,
                    true);
            fail_if(visible.size != 1 || visible[0].id != file_item_id,
                "Hidden direct replies must be excluded by default");
            fail_if(including_hidden.size != 2 ||
                    !contains_item(including_hidden, corrected_item_id),
                "Callers preparing later graph traversal must be able to include hidden connectors");

            bool found_index = false;
            RowIterator index_rows = context.db.query_sql(
                "PRAGMA index_list(reply)");
            Row? index_row;
            while ((index_row = index_rows.get_next()) != null) {
                Row row = (!) index_row;
                if (row.get_text("name") ==
                        "reply_quoted_content_item_id") {
                    found_index = true;
                    break;
                }
            }
            fail_if(!found_index,
                "The direct reverse lookup requires its quoted-content-item index");
        } catch (Error e) {
            fail_if_reached(@"Direct reply lookup test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_reply_sender_selection_uses_quoted_item() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("outgoing-direct-reply");
            DateTime time = new DateTime.from_unix_utc(1703000000);
            Message quoted_message = context.persist_message("quoted", false,
                "quoted-origin", "quoted-server", time);
            int quoted_item_id = context.add_message_item(quoted_message);
            Message quoted_correction = context.persist_message_with_sender(
                "quoted corrected", false, "quoted-correction",
                "quoted-correction-server", time.add_seconds(1),
                new Jid("bob@example.test/laptop"));
            quoted_correction.edit_to = "quoted-origin";
            context.db.message_correction.insert()
                .value(context.db.message_correction.message_id,
                    quoted_correction.id)
                .value(context.db.message_correction.to_stanza_id,
                    "quoted-origin")
                .perform();
            context.db.content_item.update()
                .with(context.db.content_item.id, "=", quoted_item_id)
                .set(context.db.content_item.foreign_id,
                    quoted_correction.id)
                .perform();
            ContentItem? quoted_item = context.content_item_store
                .get_item_by_id(context.conversation, quoted_item_id);
            fail_if(quoted_item == null,
                "The outgoing reply target must be materializable");

            Message outgoing = context.message_processor.create_out_message(
                "reply", context.conversation);
            Dino.set_outgoing_reply_reference(context.content_item_store,
                context.conversation, outgoing, (!) quoted_item);
            var stanza = new MessageStanza(outgoing.stanza_id);
            string error_text = "";
            fail_if(!context.message_processor.add_reply_payload(outgoing,
                    stanza, context.conversation, out error_text),
                "The production reply payload helper must build a direct reply: " +
                    error_text);

            Xmpp.Xep.Replies.ReplyTo? wire_reply =
                Xmpp.Xep.Replies.get_reply_to(stanza);
            fail_if(wire_reply == null ||
                    ((!) wire_reply).to_message_id != "quoted-origin" ||
                    !((!) wire_reply).to_jid.equals(quoted_message.from),
                "The emitted XEP-0461 payload must use the quoted message id and exact full sender");
            assert_reply_row(context.db, outgoing.id, quoted_item_id,
                "quoted-origin", quoted_message.from.to_string());

            Message correct_inbound = context.persist_message(
                "correct tuple", false, "correct-tuple-reply", null,
                time.add_seconds(2));
            context.add_message_item(correct_inbound);
            var correct_stanza = new MessageStanza("correct-tuple-reply");
            Xmpp.Xep.Replies.set_reply_to(correct_stanza,
                new Xmpp.Xep.Replies.ReplyTo((!) quoted_message.from,
                    "quoted-origin"));
            context.replies.process_incoming_for_tests(correct_inbound,
                correct_stanza, context.conversation);
            fail_if(correct_inbound.quoted_item_id != quoted_item_id,
                "A direct reply must resolve the original id and original full sender after a resource-changing correction");

            Message mismatched_inbound = context.persist_message(
                "mismatched tuple", false, "mismatched-tuple-reply", null,
                time.add_seconds(3));
            context.add_message_item(mismatched_inbound);
            var mismatched_stanza = new MessageStanza(
                "mismatched-tuple-reply");
            Xmpp.Xep.Replies.set_reply_to(mismatched_stanza,
                new Xmpp.Xep.Replies.ReplyTo(
                    (!) quoted_correction.from, "quoted-origin"));
            context.replies.process_incoming_for_tests(mismatched_inbound,
                mismatched_stanza, context.conversation);
            fail_if(mismatched_inbound.quoted_item_id != 0,
                "An original id paired with the correction's different full resource must fail closed");

            var other_conversation = new Conversation(
                new Jid("charlie@example.test"), context.account,
                Conversation.Type.CHAT);
            other_conversation.persist(context.db);
            Message foreign_target = context.persist_message_for(
                other_conversation, "other conversation target", false,
                "other-conversation-origin", time.add_seconds(4));
            int foreign_item_id = (int) context.db.add_content_item(
                other_conversation, foreign_target.time,
                foreign_target.local_time, 1, foreign_target.id, false);
            fail_if(context.content_item_store.get_item_by_id(
                    context.conversation, foreign_item_id) != null,
                "A globally valid ContentItem id from another conversation must not materialize in this chat");
            Message cross_chat_reply =
                context.message_processor.create_out_message(
                    "cross-chat reply", context.conversation);
            cross_chat_reply.set_quoted_item(foreign_item_id);
            var cross_chat_stanza = new MessageStanza(
                cross_chat_reply.stanza_id);
            fail_if(context.message_processor.add_reply_payload(
                    cross_chat_reply, cross_chat_stanza,
                    context.conversation, out error_text) ||
                    Xmpp.Xep.Replies.get_reply_to(cross_chat_stanza) != null,
                "A stale reply target from another conversation must fail closed without wire or raw provenance");
        } catch (Error e) {
            fail_if_reached(@"Outgoing reply sender test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_corrected_reply_uses_latest_explicit_parent() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("corrected-reply-new-parent");
            DateTime base_time = new DateTime.from_unix_utc(1702500000);

            Message first_parent = context.persist_message("first parent",
                true, "parent-one", "parent-one-server", base_time);
            int first_parent_item_id = context.add_message_item(first_parent);
            ContentItem? first_parent_item = context.content_item_store
                .get_item_by_id(context.conversation, first_parent_item_id);

            Message second_parent = context.persist_message("second parent",
                true, "parent-two", "parent-two-server",
                base_time.add_seconds(1));
            int second_parent_item_id = context.add_message_item(second_parent);
            ContentItem? second_parent_item = context.content_item_store
                .get_item_by_id(context.conversation, second_parent_item_id);
            fail_if(first_parent_item == null || second_parent_item == null,
                "Both candidate parents must be materializable");

            Message original_reply = context.persist_message("reply v0",
                false, "reply-change-v0", "reply-change-server-v0",
                base_time.add_seconds(2));
            original_reply.set_quoted_item(first_parent_item_id,
                "parent-one", context.account.bare_jid);
            int reply_item_id = context.add_message_item(original_reply);
            Gee.List<ContentItem> original_snapshot = context.replies
                .get_direct_replies(context.conversation,
                    (!) first_parent_item);
            fail_if(original_snapshot.size != 1 ||
                    !context.replies.direct_reply_snapshot_matches(
                        context.conversation, (!) first_parent_item,
                        original_snapshot),
                "An unchanged direct-reply snapshot must compare equal");

            Message correction = context.persist_message("reply v1",
                false, "reply-change-v1", "reply-change-server-v1",
                base_time.add_seconds(3));
            correction.edit_to = "reply-change-v0";
            context.db.message_correction.insert()
                .value(context.db.message_correction.message_id,
                    correction.id)
                .value(context.db.message_correction.to_stanza_id,
                    "reply-change-v0")
                .perform();
            correction.set_quoted_item(second_parent_item_id,
                "parent-two", context.account.bare_jid);
            context.db.content_item.update()
                .with(context.db.content_item.id, "=", reply_item_id)
                .set(context.db.content_item.foreign_id, correction.id)
                .perform();

            Gee.List<ContentItem> first_replies = context.replies
                .get_direct_replies(context.conversation,
                    (!) first_parent_item);
            Gee.List<ContentItem> second_replies = context.replies
                .get_direct_replies(context.conversation,
                    (!) second_parent_item);
            fail_if(first_replies.size != 0,
                "A correction with a new explicit XEP-0461 target must leave the old parent");
            fail_if(second_replies.size != 1 ||
                    second_replies[0].id != reply_item_id,
                "The latest explicit XEP-0461 target must own the corrected reply");
            fail_if(context.replies.direct_reply_snapshot_matches(
                    context.conversation, (!) first_parent_item,
                    original_snapshot),
                "A correction that moves the reply must invalidate the old local-delete snapshot");
            fail_if(!context.replies.direct_reply_snapshot_matches(
                    context.conversation, (!) second_parent_item,
                    second_replies),
                "The current corrected reply snapshot must compare equal");
        } catch (Error e) {
            fail_if_reached(@"Corrected reply parent test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_groupchat_reply_uses_original_room_stanza_id() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("outgoing-muc-reply",
                Conversation.Type.GROUPCHAT);
            DateTime base_time = new DateTime.from_unix_utc(1703250000);

            Message original = context.persist_message_with_sender(
                "original", false, "muc-origin-v0", "room-stanza-v0",
                base_time,
                new Jid("room@conference.example.test/OldNick"), 42);
            int logical_item_id = context.add_message_item(original);
            Message correction = context.persist_message_with_sender(
                "corrected", false, "muc-origin-v1", "room-stanza-v1",
                base_time.add_seconds(1),
                new Jid("room@conference.example.test/NewNick"), 42);
            correction.edit_to = "muc-origin-v0";
            context.db.message_correction.insert()
                .value(context.db.message_correction.message_id,
                    correction.id)
                .value(context.db.message_correction.to_stanza_id,
                    "muc-origin-v0")
                .perform();
            context.db.content_item.update()
                .with(context.db.content_item.id, "=", logical_item_id)
                .set(context.db.content_item.foreign_id, correction.id)
                .perform();
            ContentItem? target = context.content_item_store.get_item_by_id(
                context.conversation, logical_item_id);
            fail_if(target == null,
                "The corrected MUC reply target must be materializable");
            fail_if(context.content_item_store
                    .get_message_id_for_content_item(context.conversation,
                        (!) target) != "room-stanza-v0",
                "A corrected MUC target must use its logical original's room-assigned stanza id");

            Message outgoing = context.persist_message("reply", true,
                "outgoing-muc-reply", null, base_time.add_seconds(2));
            Dino.set_outgoing_reply_reference(context.content_item_store,
                context.conversation, outgoing, (!) target);
            var stanza = new MessageStanza(outgoing.stanza_id);
            string error_text = "";
            fail_if(!context.message_processor.add_reply_payload(outgoing,
                    stanza, context.conversation, out error_text),
                "A room-assigned MUC target must produce an XEP-0461 payload: " +
                    error_text);
            Xmpp.Xep.Replies.ReplyTo? wire_reply =
                Xmpp.Xep.Replies.get_reply_to(stanza);
            fail_if(wire_reply == null ||
                    ((!) wire_reply).to_message_id != "room-stanza-v0" ||
                    !((!) wire_reply).to_jid.equals(original.from),
                "MUC wire replies must pair the original room stanza id with that same revision's old occupant JID");
            assert_reply_row(context.db, outgoing.id, logical_item_id,
                "room-stanza-v0", original.from.to_string());

            Message pre_echo = context.persist_message("pending", false,
                "pending-muc-origin", null, base_time.add_seconds(3));
            int pre_echo_item_id = context.add_message_item(pre_echo);
            ContentItem? pre_echo_item = context.content_item_store
                .get_item_by_id(context.conversation, pre_echo_item_id);
            fail_if(pre_echo_item == null || context.content_item_store
                    .get_message_id_for_content_item(context.conversation,
                        (!) pre_echo_item) != null,
                "A pre-echo MUC message must not expose its sender-controlled origin id as reply target");

            Message blocked = context.persist_message("blocked reply", true,
                "blocked-muc-reply", null, base_time.add_seconds(4));
            Dino.set_outgoing_reply_reference(context.content_item_store,
                context.conversation, blocked, (!) pre_echo_item);
            var blocked_stanza = new MessageStanza(blocked.stanza_id);
            fail_if(context.message_processor.add_reply_payload(blocked,
                    blocked_stanza, context.conversation, out error_text) ||
                    error_text.strip().length == 0 ||
                    Xmpp.Xep.Replies.get_reply_to(blocked_stanza) != null,
                "A MUC reply without a room stanza id must fail closed before emitting a plain fallback-only message");

            Message correct_inbound = context.persist_message_with_sender(
                "correct MUC tuple", false, "correct-muc-tuple", null,
                base_time.add_seconds(5),
                new Jid("room@conference.example.test/Carol"), 77);
            context.add_message_item(correct_inbound);
            var correct_inbound_stanza = new MessageStanza(
                "correct-muc-tuple");
            Xmpp.Xep.Replies.set_reply_to(correct_inbound_stanza,
                new Xmpp.Xep.Replies.ReplyTo((!) original.from,
                    "room-stanza-v0"));
            context.replies.process_incoming_for_tests(correct_inbound,
                correct_inbound_stanza, context.conversation);
            fail_if(correct_inbound.quoted_item_id != logical_item_id,
                "A MUC reply must resolve the physical original sender/id tuple through the corrected logical item");

            Message mismatched_inbound =
                context.persist_message_with_sender(
                    "mismatched MUC tuple", false,
                    "mismatched-muc-tuple", null,
                    base_time.add_seconds(6),
                    new Jid("room@conference.example.test/Carol"), 77);
            context.add_message_item(mismatched_inbound);
            var mismatched_inbound_stanza = new MessageStanza(
                "mismatched-muc-tuple");
            Xmpp.Xep.Replies.set_reply_to(mismatched_inbound_stanza,
                new Xmpp.Xep.Replies.ReplyTo((!) correction.from,
                    "room-stanza-v0"));
            context.replies.process_incoming_for_tests(mismatched_inbound,
                mismatched_inbound_stanza, context.conversation);
            fail_if(mismatched_inbound.quoted_item_id != 0,
                "A room id paired with a later correction nick must fail closed");
        } catch (Error e) {
            fail_if_reached(@"Outgoing MUC reply reference test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_orphan_correction_keeps_its_explicit_reply_edge() {
        ReplyTestContext? context = null;
        try {
            context = new ReplyTestContext("orphan-correction-reply");
            DateTime base_time = new DateTime.from_unix_utc(1702750000);

            Message parent = context.persist_message("parent", true,
                "orphan-parent", "orphan-parent-server", base_time);
            int parent_item_id = context.add_message_item(parent);
            ContentItem? parent_item = context.content_item_store
                .get_item_by_id(context.conversation, parent_item_id);
            fail_if(parent_item == null,
                "The orphan-correction reply parent must be materializable");

            Message orphan_correction = context.persist_message(
                "orphan reply correction", false, "orphan-reply-v1",
                "orphan-reply-server-v1", base_time.add_seconds(1));
            orphan_correction.edit_to = "missing-reply-v0";
            context.db.message_correction.insert()
                .value(context.db.message_correction.message_id,
                    orphan_correction.id)
                .value(context.db.message_correction.to_stanza_id,
                    "missing-reply-v0")
                .perform();
            orphan_correction.set_quoted_item(parent_item_id,
                "orphan-parent", context.account.bare_jid);
            int reply_item_id = context.add_message_item(orphan_correction);

            Gee.List<ContentItem> direct = context.replies
                .get_direct_replies(context.conversation, (!) parent_item);
            fail_if(direct.size != 1 || direct[0].id != reply_item_id,
                "An orphan correction's own explicit XEP-0461 edge must remain discoverable");

            Message later_correction = context.persist_message(
                "later orphan reply correction", false, "orphan-reply-v2",
                "orphan-reply-server-v2", base_time.add_seconds(2));
            later_correction.edit_to = "missing-reply-v0";
            context.db.message_correction.insert()
                .value(context.db.message_correction.message_id,
                    later_correction.id)
                .value(context.db.message_correction.to_stanza_id,
                    "missing-reply-v0")
                .perform();
            context.db.content_item.update()
                .with(context.db.content_item.id, "=", reply_item_id)
                .set(context.db.content_item.foreign_id,
                    later_correction.id)
                .perform();

            Gee.List<ContentItem> inherited = context.replies
                .get_direct_replies(context.conversation, (!) parent_item);
            fail_if(inherited.size != 1 ||
                    inherited[0].id != reply_item_id,
                "A later orphan correction without XEP-0461 must inherit the newest known sender-scoped reply edge");
        } catch (Error e) {
            fail_if_reached(@"Orphan correction reply test failed: $(e.message)");
        } finally {
            if (context != null) ((!) context).close();
        }
    }

    private void test_sender_matching_is_bare_only_for_direct_chat() {
        try {
            Jid direct_bare = new Jid("alice@example.test");
            Jid direct_full = new Jid("alice@example.test/desktop");
            Jid room_alice = new Jid(
                "room@conference.example.test/Alice");
            Jid room_other = new Jid(
                "room@conference.example.test/Other");

            fail_if(!Dino.Replies.reply_target_sender_matches(
                    Conversation.Type.CHAT, direct_bare, direct_full),
                "Direct-chat reply targets are sender-scoped by bare JID");
            fail_if(Dino.Replies.reply_target_sender_matches(
                    Conversation.Type.CHAT,
                    new Jid("alice@example.test/phone"),
                    new Jid("alice@example.test/laptop")),
                "A full direct-chat reply target must not match another resource of the same bare JID");
            fail_if(!Dino.Replies.reply_target_sender_matches(
                    Conversation.Type.CHAT,
                    new Jid("alice@example.test/phone"),
                    new Jid("alice@example.test/phone")),
                "A full direct-chat reply target must retain its exact resource");
            fail_if(Dino.Replies.reply_target_sender_matches(
                    Conversation.Type.GROUPCHAT, room_alice, room_other),
                "MUC reply targets must retain the exact occupant identity");
            fail_if(Dino.Replies.reply_target_sender_matches(
                    Conversation.Type.GROUPCHAT_PM, room_alice, room_other),
                "Private MUC reply targets must retain the exact full JID");
        } catch (Error e) {
            fail_if_reached(@"Reply sender matching test failed: $(e.message)");
        }
    }

    private static bool contains_item(Gee.List<ContentItem> items, int id) {
        foreach (ContentItem item in items) {
            if (item.id == id) return true;
        }
        return false;
    }

    private static void assert_reply_row(Database db, int message_id,
            int quoted_content_item_id, string raw_id, string raw_sender) {
        RowOption row = db.reply.select()
            .with(db.reply.message_id, "=", message_id)
            .single().row();
        fail_if(!row.is_present(), "Expected persisted reply metadata");
        if (!row.is_present()) return;

        int stored_item_id = row.get(db.reply.quoted_content_item_id, 0);
        fail_if(stored_item_id != quoted_content_item_id,
            "Unexpected resolved quoted ContentItem id");
        fail_if_not_eq_str(row[db.reply.quoted_message_stanza_id], raw_id,
            "Raw XEP-0461 target id must survive resolution");
        fail_if_not_eq_str(row[db.reply.quoted_message_from], raw_sender,
            "Raw XEP-0461 target sender must survive resolution");
    }

    private class ReplyTestContext : Object {
        public string temp_dir;
        public string db_path;
        public Database db;
        public Account account;
        public Conversation conversation;
        public StreamInteractor stream_interactor;
        public Dino.Replies replies;
        public ContentItemStore content_item_store;
        public MessageStorage message_storage;
        public MessageProcessor message_processor;

        public ReplyTestContext(string suffix,
                Conversation.Type conversation_type =
                    Conversation.Type.CHAT) throws Error {
            temp_dir = Path.build_filename(Environment.get_tmp_dir(),
                "dinox-replies-" + suffix + "-" + Uuid.string_random());
            db_path = Path.build_filename(temp_dir, "dino.db");
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "reply-integrity-test");

            account = new Account(new Jid("alice@example.test"), "secret");
            account.persist(db);
            Jid counterpart = conversation_type == Conversation.Type.GROUPCHAT
                ? new Jid("room@conference.example.test")
                : new Jid("bob@example.test");
            conversation = new Conversation(counterpart, account,
                conversation_type);
            conversation.persist(db);

            stream_interactor = new StreamInteractor.for_tests(db);
            MessageProcessor.start(stream_interactor, db);
            MessageStorage.start(stream_interactor, db);
            PresenceManager.start(stream_interactor, db);
            Calls.start(stream_interactor, db);
            stream_interactor.add_module(FileManager.create_for_tests());
            ContentItemStore.start(stream_interactor, db);
            MessageCorrection.start(stream_interactor, db);
            FileTransferStorage.start(stream_interactor, db);
            replies = new Dino.Replies.for_tests(stream_interactor, db);
            stream_interactor.add_module(replies);

            content_item_store = stream_interactor
                .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            message_storage = stream_interactor
                .get_module<MessageStorage>(MessageStorage.IDENTITY);
            message_processor = stream_interactor
                .get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        }

        public Message persist_message(string body, bool sent,
                string stanza_id, string? server_id, DateTime time)
                throws Error {
            return persist_message_for(conversation, body, sent, stanza_id,
                time, server_id);
        }

        public Message persist_message_for(Conversation target_conversation,
                string body, bool sent, string stanza_id, DateTime time,
                string? server_id = null, Jid? sender_override = null,
                int occupant_db_id = -1) throws Error {
            var message = new Message(body);
            message.account = account;
            bool groupchat = target_conversation.type_ ==
                Conversation.Type.GROUPCHAT;
            message.counterpart = sent
                ? target_conversation.counterpart
                : target_conversation.counterpart.with_resource(
                    groupchat ? "Bob" : "phone");
            message.ourpart = groupchat
                ? target_conversation.counterpart.with_resource("Alice")
                : account.bare_jid.with_resource("desktop");
            if (sender_override != null) {
                if (sent) {
                    message.ourpart = sender_override;
                } else {
                    message.counterpart = sender_override;
                }
            }
            message.occupant_db_id = occupant_db_id;
            message.direction = sent ? Message.DIRECTION_SENT
                : Message.DIRECTION_RECEIVED;
            message.type_ = Util.get_message_type_for_conversation(
                target_conversation);
            message.time = time;
            message.local_time = time;
            message.stanza_id = stanza_id;
            message.server_id = server_id;
            message_storage.add_message(message, target_conversation);
            return message;
        }

        public Message persist_message_with_sender(string body, bool sent,
                string stanza_id, string? server_id, DateTime time,
                Jid sender, int occupant_db_id = -1) throws Error {
            return persist_message_for(conversation, body, sent, stanza_id,
                time, server_id, sender, occupant_db_id);
        }

        public int add_message_item(Message message, bool hide = false) {
            return db.add_content_item(conversation, message.time,
                message.local_time, 1, message.id, hide);
        }

        public void close() {
            db.close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }
}

}
