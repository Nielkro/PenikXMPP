using Xmpp;
using Xmpp.Xep;
using Dino.Entities;

namespace Dino.Test {
class ArchiveRetractionTest : Gee.TestCase {
    private CorrectionTestContext context;
    public ArchiveRetractionTest() {
        base("ArchiveRetractions");
        add_test("archived_correction_removes_existing_logical_message", test_existing);
        add_test("reverse_archive_order_and_duplicate_tombstones", test_reverse);
        add_test("later_revisions_remain_removed_after_cache_reload", test_reload);
        add_test("foreign_archive_live_payload_and_wrong_room_are_rejected", test_authority);
        add_test("sender_and_occupant_collisions_do_not_remove_others", test_sender);
        add_test("accounts_rooms_and_private_muc_chats_are_separate", test_scope);
        add_test("stable_id_survives_missing_origin_id", test_stable);
        add_test("ordinary_messages_and_corrections_keep_working", test_ordinary);
        add_test("tombstone_precedes_stable_id_deduplication", test_order);
        add_test("v59_upgrade_and_persistent_marker_after_reopen", test_migration);
        add_test("room_archive_id_handles_messages_without_sender_id", test_no_sender_id);
        add_test("unmerged_revision_rows_are_all_hidden", test_unmerged);
        add_test("wire_and_origin_ids_link_in_both_archive_orders", test_wire_origin);
        add_test("legacy_and_current_live_retractions_still_work", test_live_formats);
        add_test("own_old_nickname_uses_room_id_without_crossing_authors", test_own_nickname);
    }
    public override void set_up() {
        try {
            context = new CorrectionTestContext();
            context.conversation = context.create_conversation("room@conference.example.test", Conversation.Type.GROUPCHAT);
            MessageDeletion.start(context.stream_interactor, context.db);
        } catch (Error e) { fail_if_reached(e.message); }
    }
    public override void tear_down() {
        if (context != null) {
            context.close();
            context = null;
        }
    }
    private Message incoming(string id, string? body = "text", Jid? sender = null, int occupant = -1) {
        var message = context.create_message(body ?? "", false, id, context.time, null, sender, occupant);
        message.body = body;
        return message;
    }
    private MessageStanza stanza(Message message, string? replace = null, bool tombstone = false, string? archive = "room@conference.example.test") {
        var result = new MessageStanza(message.stanza_id);
        result.from = message.from; result.to = message.to; result.body = message.body;
        result.type_ = message.type_ == Message.Type.GROUPCHAT ? "groupchat" : "chat";
        if (replace != null) LastMessageCorrection.set_replace_id(result, replace);
        if (tombstone) result.stanza.put_node(new StanzaNode.build("retracted", MessageRetraction.NS_URI)
            .put_attribute("stamp", "2026-11-01T10:00:00Z")
            .put_node(new StanzaNode.build("moderated", MessageModeration.NS_URI)));
        if (archive != null) result.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(context.jid(archive), context.time, "mam-" + message.stanza_id, "query"));
        return result;
    }
    private bool run(Message message, MessageStanza wire) {
        bool done = false; bool stopped = false;
        var loop = new MainLoop();
        context.processor.received_pipeline.run.begin(message, wire, context.conversation, null, (obj, res) => {
            stopped = context.processor.received_pipeline.run.end(res); done = true; loop.quit();
        });
        if (!done) loop.run();
        return stopped;
    }
    private void assert_removed(Message message) {
        var stored = context.storage.get_persisted_message_by_id(message.id, context.conversation);
        assert_nonnull(stored); assert_true(stored.archive_retracted); assert_cmpstr(stored.body, CompareOperator.EQ, "");
    }
    private int visible_count() {
        return (int) context.db.content_item.select().with(context.db.content_item.conversation_id, "=", context.conversation.id)
                .with(context.db.content_item.hide, "=", false).count();
    }
    private void test_existing() {
        var original = context.persist_message("original", false, "O", context.time);
        context.add_message_item(original);
        var edit = context.persist_message("edit", false, "C", context.time.add_seconds(1));
        assert_true(context.process(edit, "O"));
        var gone = incoming("C", null);
        assert_true(run(gone, stanza(gone, "O", true)));
        assert_removed(original); assert_removed(edit); assert_true(visible_count() == 0);
    }
    private void test_reverse() {
        var gone = incoming("C", null); assert_true(run(gone, stanza(gone, "O", true)));
        var duplicate = incoming("C", null); assert_true(run(duplicate, stanza(duplicate, "O", true)));
        var original = incoming("O", "old original"); assert_true(run(original, stanza(original)));
        var older = incoming("C0", "old correction"); assert_true(run(older, stanza(older, "O")));
        assert_removed(original); assert_removed(older); assert_true(visible_count() == 0);
        assert_true(context.db.message.select().count() == 3);
    }
    private void test_reload() {
        var gone = incoming("O", null); run(gone, stanza(gone, null, true));
        context.storage.clear_conversation_cache(context.conversation);
        var loaded = context.storage.get_persisted_message_by_id(gone.id, context.conversation);
        assert_true(loaded.archive_retracted);
        var later = incoming("C", "must not reappear");
        assert_true(run(later, stanza(later, "O"))); assert_removed(later); assert_true(visible_count() == 0);
    }
    private void test_authority() {
        var original = context.persist_message("keep", false, "O", context.time); context.add_message_item(original);
        foreach (string? archive in new string?[]{null, "elsewhere@conference.example.test", "alice@example.test"}) {
            var fake = incoming("O", null);
            var wire = stanza(fake, null, true, archive);
            assert_false(ArchiveRetractionListener.is_room_tombstone(wire, context.conversation));
            run(fake, wire);
        }
        var with_body = incoming("O", "not a tombstone");
        assert_false(ArchiveRetractionListener.is_room_tombstone(stanza(with_body, null, true), context.conversation));
        assert_cmpstr(original.body, CompareOperator.EQ, "keep"); assert_true(visible_count() == 1);
    }
    private void test_sender() {
        var original = context.persist_message("keep", false, "O", context.time, null, context.jid("room@conference.example.test/Alice"), 1);
        context.add_message_item(original);
        var other = incoming("C", null, context.jid("room@conference.example.test/Bob"), 2);
        run(other, stanza(other, "O", true));
        assert_cmpstr(original.body, CompareOperator.EQ, "keep"); assert_true(visible_count() == 1);
        var colliding = incoming("O", "different occupant", context.jid("room@conference.example.test/Bob"), 3);
        assert_false(run(colliding, stanza(colliding))); // occupant IDs take precedence over reused nicknames
        assert_false(colliding.archive_retracted);
    }
    private void test_scope() {
        var gone = incoming("O", null); run(gone, stanza(gone, null, true));
        var first = context.conversation;
        var other_account = new Account(context.jid("other@example.test"), "secret"); other_account.persist(context.db);
        var targets = new Conversation[]{
            context.create_conversation("elsewhere@conference.example.test", Conversation.Type.GROUPCHAT),
            context.create_conversation(first.counterpart.to_string(), Conversation.Type.GROUPCHAT, other_account),
            context.create_conversation("room@conference.example.test/Bob", Conversation.Type.GROUPCHAT_PM)
        };
        foreach (var target in targets) {
            context.conversation = target;
            var unaffected = incoming("O", "keep");
            assert_false(run(unaffected, stanza(unaffected, null, false, null)));
            assert_false(unaffected.archive_retracted);
        }
        context.conversation = first;
    }
    private void test_stable() {
        var original = context.persist_message("keep until moderated", false, "origin", context.time);
        original.set_stable_reference("room-id", context.conversation.counterpart);
        context.add_message_item(original);
        var gone = incoming("wire-id", null); gone.set_stable_reference("room-id", context.conversation.counterpart);
        assert_true(run(gone, stanza(gone, null, true))); assert_removed(original); assert_true(visible_count() == 0);
    }
    private void test_ordinary() {
        var original = incoming("O"); assert_false(run(original, stanza(original)));
        var edit = incoming("C", "edited"); assert_true(run(edit, stanza(edit, "O")));
        assert_false(original.archive_retracted); assert_false(edit.archive_retracted);
        assert_true(visible_count() == 1);
    }
    private void test_order() {
        var original = incoming("O"); original.set_stable_reference("room-id", context.conversation.counterpart);
        assert_false(run(original, stanza(original)));
        var gone = incoming("O", null); gone.set_stable_reference("room-id", context.conversation.counterpart);
        assert_true(run(gone, stanza(gone, null, true))); assert_removed(original);
    }
    private void test_no_sender_id() {
        var original = incoming("O"); original.stanza_id = null;
        original.set_stable_reference("room-only", context.conversation.counterpart);
        context.storage.add_message(original, context.conversation); context.add_message_item(original);
        var gone = incoming("O", null); var wire = stanza(gone, null, true);
        gone.stanza_id = null; gone.set_stable_reference("room-only", context.conversation.counterpart);
        assert_true(run(gone, wire)); assert_removed(original); assert_true(visible_count() == 0);
    }
    private void test_migration() {
        try {
            var original = context.persist_message("ordinary existing text", false, "O", context.time);
            int id = original.id;
            remove_archive_retraction_fixture_column(context.db);
            context.db.exec("UPDATE _meta SET int_val=59 WHERE name='version'");
            context.db.close();
            context.db = new Database(context.db_path, "correction-integrity-test");
            var loaded = context.db.get_message_by_id(id);
            assert_nonnull(loaded); assert_false(loaded.archive_retracted);
            assert_cmpstr(loaded.body, CompareOperator.EQ, "ordinary existing text");
            loaded.archive_retracted = true; loaded.body = "";
            context.db.close();
            context.db = new Database(context.db_path, "correction-integrity-test");
            var reopened = context.db.get_message_by_id(id);
            assert_true(reopened.archive_retracted); assert_cmpstr(reopened.body, CompareOperator.EQ, "");
        } catch (Error e) { fail_if_reached(e.message); }
    }
    private void test_unmerged() {
        var original = context.persist_message("original", false, "O", context.time); context.add_message_item(original);
        var correction = context.persist_message("correction", false, "C", context.time);
        context.link_correction(correction, "O"); context.add_message_item(correction);
        assert_true(visible_count() == 2);
        var gone = incoming("C", null); run(gone, stanza(gone, "O", true));
        assert_removed(original); assert_removed(correction); assert_true(visible_count() == 0);
    }
    private void test_wire_origin() {
        foreach (bool original_first in new bool[]{true, false}) {
            string suffix = original_first ? "first" : "later";
            var original = incoming("origin-" + suffix);
            original.sender_stanza_id = "wire-" + suffix;
            if (original_first) assert_false(run(original, stanza(original)));
            var gone = incoming("C-" + suffix, null);
            assert_true(run(gone, stanza(gone, "wire-" + suffix, true)));
            if (!original_first) assert_true(run(original, stanza(original)));
            assert_removed(original); assert_true(visible_count() == 0);
        }
    }
    private void test_live_formats() {
        foreach (bool legacy in new bool[]{true, false}) {
            string id = legacy ? "old-format" : "current-format";
            var original = context.persist_message("retract me", false, id, context.time); context.add_message_item(original);
            var control = incoming("control-" + id, "This message was retracted.");
            var wire = stanza(control, null, false, null);
            if (legacy) {
                wire.stanza.put_node(new StanzaNode.build("apply-to", MessageRetraction.NS_FASTEN)
                    .put_attribute("id", id).put_node(new StanzaNode.build("retract", MessageRetraction.NS_URI_0)));
            } else {
                wire.stanza.put_node(new StanzaNode.build("retract", MessageRetraction.NS_URI).put_attribute("id", id));
            }
            assert_true(run(control, wire)); assert_true(visible_count() == 0);
        }
    }
    private void test_own_nickname() {
        var old_sender = context.jid("room@conference.example.test/OldNick");
        var original = context.persist_message("own old text", true, "O", context.time, null, old_sender, 7);
        original.set_stable_reference("own-room-id", context.conversation.counterpart);
        context.add_message_item(original);
        var fake = incoming("O", null, old_sender, 8);
        fake.set_stable_reference("own-room-id", context.conversation.counterpart);
        run(fake, stanza(fake, null, true));
        assert_false(original.archive_retracted); assert_true(visible_count() == 1);
        var gone = incoming("O", null, old_sender, 7);
        gone.set_stable_reference("own-room-id", context.conversation.counterpart);
        assert_true(run(gone, stanza(gone, null, true)));
        assert_removed(original); assert_true(visible_count() == 0);
    }
}
}
