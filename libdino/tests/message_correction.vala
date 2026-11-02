using Dino.Entities;
using Qlite;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

class MessageCorrectionTest : Gee.TestCase {
    private CorrectionTestContext context;

    public MessageCorrectionTest() {
        base("MessageCorrection");
        add_test("same_second_outgoing_revisions_resolve_actual_row", test_same_second_outgoing);
        add_test("displaced_revision_time_preserves_content_row", test_displaced_time);
        add_test("reloaded_original_resolves_existing_correction", test_reloaded_original);
        add_test("incoming_edits_keep_original_reference_and_time", test_incoming_edits);
        add_test("row_resolution_excludes_account_type_direction_and_conversation_collisions", test_conversation_scope);
        add_test("private_muc_revisions_keep_exact_resource_scope", test_private_muc_scope);
        add_test("ambiguous_content_rows_do_not_apply_correction", test_ambiguous_rows);
        add_test("hidden_content_row_stays_hidden", test_hidden_row);
        add_test("missing_content_preserves_standalone_payload", test_missing_row);
        add_test("file_target_preserves_attachment_and_standalone_payload", test_file_target);
        add_test("muc_cache_checks_occupant_identity_and_legacy_nick", test_muc_identity);
        add_test("previous_edit_target_stays_standalone", test_previous_edit_target);
        add_test("wrong_order_previous_edit_is_not_an_original", test_wrong_order_previous_edit);
        add_test("foreign_occupant_cannot_invalidate_pending_correction", test_foreign_pending_collision);
        add_test("correction_runs_after_message_storage", test_store_dependency);
    }

    public override void set_up() {
        try {
            context = new CorrectionTestContext();
        } catch (Error e) {
            fail_if_reached(@"Correction test setup failed: $(e.message)");
        }
    }

    public override void tear_down() {
        if (context != null) context.close();
    }

    private void test_same_second_outgoing() {
        Message original = context.persist_message("original", true, "O", context.time);
        int item_id = context.add_message_item(original);
        Message c1 = context.persist_message("first edit", true, "C1", context.time);
        context.set_outgoing_correction(c1, original);
        Message c2 = context.persist_message("second edit", true, "C2", context.time);
        context.set_outgoing_correction(c2, c1);

        fail_if(context.correction.get_latest_correction_message_id(context.conversation, original) != c2.id,
            "Equal-second corrections must use the larger physical message id");
        context.check_target(original, item_id, c2.id);
        context.check_target(c1, item_id, c2.id);

        var wire_stanza = new MessageStanza("C2");
        context.processor.build_message_stanza(c2, wire_stanza, context.conversation);
        fail_if_not_eq_str(LastMessageCorrection.get_replace_id(wire_stanza), "O",
            "A repeated outgoing edit must keep the original wire reference");
        Message following = context.persist_message("following carbon edit", true,
            "C3", context.time.add_seconds(1), null, context.jid("alice@example.test/phone"));
        fail_if_not(context.process(following, "O"),
            "A following own-device correction must apply to the moved content row");
        context.check_target(original, item_id, following.id);
        context.check_row_time(item_id, context.time);
    }

    private void test_displaced_time() {
        Message original = context.persist_message("original", true, "O", context.time);
        int item_id = context.add_message_item(original);
        Message c1 = context.persist_message("newer clock", true, "C1", context.time.add_seconds(10));
        context.set_outgoing_correction(c1, original);
        Message c2 = context.persist_message("last physical row", true, "C2", context.time.add_seconds(5));
        context.set_outgoing_correction(c2, c1);
        fail_if(context.correction.get_latest_correction_message_id(context.conversation, original) != c1.id,
            "Latest correction ordering must keep the existing timestamp model");
        context.check_target(original, item_id, c2.id);

        Message delayed = context.persist_message("delayed edit", true, "C3", context.time.add_seconds(7));
        fail_if_not(context.process(delayed, "O"),
            "A displaced pointer must resolve even when its revision is not newest by timestamp");
        context.check_target(original, item_id, c1.id);
        context.check_row_time(item_id, context.time);
    }

    private void test_reloaded_original() {
        Message original = context.create_message("original", true, "O", context.time);
        original.persist(context.db);
        int item_id = context.add_message_item(original);
        Message first = context.create_message("first edit", true, "C1", context.time.add_seconds(1));
        first.persist(context.db);
        context.set_outgoing_correction(first, original);
        Message reloaded = context.storage.get_persisted_message_by_id(original.id, context.conversation);
        fail_if(reloaded.occupant_db_id != -1,
            "A missing database occupant relation must remain unknown after reload");
        context.check_target(reloaded, item_id, first.id);
        Message following = context.persist_message("later edit", true, "C2", context.time.add_seconds(2));
        fail_if_not(context.process(following, "O"),
            "A database-loaded original must still resolve its already corrected content row");
        context.check_target(reloaded, item_id, following.id);
    }

    private void test_incoming_edits() {
        Message original = context.persist_message("original", false, "O", context.time);
        int item_id = context.add_message_item(original);
        Message c1 = context.persist_message("first edit", false, "C1", context.time.add_seconds(1));
        Message c2 = context.persist_message("second edit", false, "C2", context.time.add_seconds(1),
            null, context.jid("bob@example.test/laptop"));
        fail_if_not(context.process(c1, "O"), "The first incoming edit must apply");
        fail_if_not(context.process(c2, "O"), "A second edit must still target the original");
        context.check_target(original, item_id, c2.id);
        context.check_row_time(item_id, context.time);
        fail_if_not_eq_str(context.correction_reference(c1), "O");
        fail_if_not_eq_str(context.correction_reference(c2), "O");
    }

    private void test_conversation_scope() {
        Message original = context.persist_message("original", true, "O", context.time);
        Message valid = context.persist_message("valid edit", true, "C1", context.time.add_seconds(1));
        context.link_correction(valid, "O");
        Conversation other_thread = context.create_conversation("carol@example.test", Conversation.Type.CHAT);
        int other_item_id = context.db.add_content_item(other_thread, context.time, context.time, 1, valid.id, false);
        fail_if(context.store.get_content_item_row_for_message(context.conversation, original) != null ||
                context.store.get_item_by_foreign(context.conversation, 1, valid.id) != null,
            "A revision's content row in another conversation must not resolve the local target");
        context.db.content_item.update().with(context.db.content_item.id, "=", other_item_id)
            .set(context.db.content_item.conversation_id, context.conversation.id).perform();
        int item_id = other_item_id;

        Account other_account = new Account(context.jid("other@example.test"), "secret");
        other_account.persist(context.db);
        Conversation other_account_thread = context.create_conversation("bob@example.test", Conversation.Type.CHAT, other_account);
        Conversation other_type_thread = context.create_conversation("bob@example.test", Conversation.Type.GROUPCHAT);
        Conversation[] collisions = { other_thread, other_account_thread, other_type_thread };
        foreach (Conversation collision in collisions) {
            Message wrong = context.persist_message("foreign edit", true, "foreign-" + collision.id.to_string(),
                context.time.add_seconds(20), collision);
            context.link_correction(wrong, "O");
            context.db.add_content_item(context.conversation, context.time, context.time, 1, wrong.id, false);
            fail_if(context.store.get_content_item_row_for_message(context.conversation, wrong) != null,
                "A foreign account, counterpart or message type must not resolve a target row");
        }
        Message wrong_direction = context.persist_message("other sender", false, "opposite-direction", context.time.add_seconds(30));
        context.link_correction(wrong_direction, "O");
        context.add_message_item(wrong_direction);
        context.check_target(original, item_id, valid.id);
        fail_if(context.correction.get_latest_correction_message_id(context.conversation, original) != valid.id,
            "A correction id collision outside the validated sender scope must not win latest selection");
        ContentItem? scoped_item = context.store.get_item_by_foreign(context.conversation, 1, valid.id);
        fail_if(scoped_item == null || scoped_item.id != item_id,
            "Correction notifications must resolve the content row in the requested conversation");
    }

    private void test_private_muc_scope() {
        context.conversation = context.create_conversation("room@conference.example.test/Bob", Conversation.Type.GROUPCHAT_PM);
        Message original = context.persist_message("private original", true, "O", context.time);
        int item_id = context.add_message_item(original);
        Message valid = context.persist_message("private edit", true, "C1", context.time.add_seconds(1));
        context.set_outgoing_correction(valid, original);
        Conversation other_nick = context.create_conversation("room@conference.example.test/Carol", Conversation.Type.GROUPCHAT_PM);
        Message collision = context.persist_message("other private edit", true, "C2", context.time.add_seconds(20), other_nick);
        context.link_correction(collision, "O");
        context.db.add_content_item(context.conversation, context.time, context.time, 1, collision.id, false);
        context.check_target(original, item_id, valid.id);
        fail_if(context.correction.get_latest_correction_message_id(context.conversation, original) != valid.id,
            "A private MUC correction must not borrow another nickname's revisions");
        fail_if(context.store.get_content_item_row_for_message(context.conversation, collision) != null,
            "A private MUC anchor must stay scoped to the full conversation resource");
    }

    private void test_ambiguous_rows() {
        Message original = context.persist_message("original", false, "O", context.time);
        int original_item = context.add_message_item(original);
        Message c1 = context.persist_message("old standalone edit", false, "C1", context.time.add_seconds(1));
        context.link_correction(c1, "O");
        int other_item = context.add_message_item(c1);
        fail_if(context.store.get_content_item_row_for_message(context.conversation, original) != null,
            "Two rows for one validated correction chain must remain ambiguous");
        Message c2 = context.persist_message("new edit", false, "C2", context.time.add_seconds(2));
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*no unique text content item*");
        fail_if(context.process(c2, "O"), "An ambiguous target must preserve the fallback message");
        GLib.Test.assert_expected_messages();
        fail_if(context.has_correction(c2), "An ambiguous target must not create a validated correction edge");
        fail_if(context.foreign_id(original_item) != original.id || context.foreign_id(other_item) != c1.id,
            "An ambiguous lookup must not modify either target row");
        context.check_standalone(c2);
    }

    private void test_hidden_row() {
        Message original = context.persist_message("hidden original", false, "O", context.time);
        int item_id = context.add_message_item(original, true);
        Message edit = context.persist_message("hidden edit", false, "C1", context.time.add_seconds(1));
        fail_if_not(context.process(edit, "O"), "A stored hidden target still has a resolvable revision");
        context.check_target(original, item_id, edit.id);
        RowOption row = context.db.content_item.select().with(context.db.content_item.id, "=", item_id).single().row();
        fail_if_not(row[context.db.content_item.hide], "An edit must retain the existing hidden state");
        fail_if(!context.store.get_n_latest(context.conversation, 10).is_empty,
            "Applying an edit must not resurrect a hidden timeline row");
    }

    private void test_missing_row() {
        Message original = context.persist_message("stored without content", false, "O", context.time);
        Message edit = context.persist_message("fallback remains visible", false, "C1", context.time.add_seconds(1));
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*no unique text content item*");
        fail_if(context.process(edit, "O"), "A truly absent content row must use the normal fallback path");
        GLib.Test.assert_expected_messages();
        fail_if(context.has_correction(edit), "A missing target must not create a validated correction edge");
        fail_if(context.store.get_content_item_row_for_message(context.conversation, original) != null,
            "A missing target must not be recreated through the fallback row");
        context.check_standalone(edit);
        Message orphan = context.persist_message("unknown original fallback", false, "C2", context.time.add_seconds(2));
        fail_if(context.process(orphan, "unknown-root"), "An unknown original must remain a standalone payload");
        fail_if(context.has_correction(orphan), "An unknown original must not create a validated correction edge");
        context.check_standalone(orphan);
    }

    private void test_file_target() {
        Message original = context.persist_message("https://upload.example.test/file.txt", false, "O", context.time);
        var transfer = new FileTransfer();
        transfer.account = context.account;
        transfer.counterpart = (!) original.counterpart;
        transfer.ourpart = (!) original.ourpart;
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.time = context.time;
        transfer.local_time = context.time;
        transfer.file_name = "file.txt";
        transfer.size = 42;
        transfer.info = "url:https://upload.example.test/file.txt";
        transfer.message_db_id = original.id;
        transfer.persist(context.db);
        int file_item_id = context.db.add_content_item(context.conversation, context.time, context.time, 2, transfer.id, false);
        Message edit = context.persist_message("standalone replacement body", false, "C1", context.time.add_seconds(1));
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*no unique text content item*");
        fail_if(context.process(edit, "O"), "A text correction must not consume an attachment target");
        GLib.Test.assert_expected_messages();
        fail_if(context.has_correction(edit), "An attachment target must not create a text correction edge");
        fail_if(context.foreign_id(file_item_id) != transfer.id, "An attachment foreign id must remain unchanged");
        fail_if(!(context.store.get_item_by_id(context.conversation, file_item_id) is FileItem),
            "The attachment must remain available after rejecting the correction");
        context.check_standalone(edit);
    }

    private void test_muc_identity() {
        context.conversation = context.create_conversation("room@conference.example.test", Conversation.Type.GROUPCHAT);
        Message original = context.persist_message("Bob original", false, "O", context.time, null, null, 23);
        fail_if(context.process(original, null), "A normal MUC message must populate the legacy correction cache");
        int item_id = context.store.get_content_item_for_message(context.conversation, original).id;
        Message hostile = context.persist_message("same nick, different occupant", false, "bad", context.time.add_seconds(1), null, null, 24);
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Got unacceptable correction*");
        fail_if(context.process(hostile, "O"), "A cached nickname match must not override contradictory occupant IDs");
        GLib.Test.assert_expected_messages();
        fail_if(context.has_correction(hostile), "An unauthorized occupant must not create a correction edge");
        context.check_target(original, item_id, original.id);

        Message legacy = context.persist_message("legacy same-nick edit", false, "C1", context.time.add_seconds(2));
        fail_if_not(context.process(legacy, "O"), "A matching legacy nickname with no occupant ID must remain supported");
        Message persisted_legacy = context.storage.get_persisted_message_by_id(legacy.id, context.conversation);
        fail_if(persisted_legacy.occupant_db_id != -1,
            "An absent occupant ID must not become a shared synthetic identity after reload");
        fail_if(context.correction.get_latest_correction_message_id(context.conversation, original) != legacy.id,
            "Latest revision selection must agree with accepted legacy nick matching");
        Message moved_nick = context.persist_message("same occupant, new nick", false, "C2", context.time.add_seconds(3),
            null, context.jid("room@conference.example.test/Robert"), 23);
        fail_if_not(context.process(moved_nick, "O"), "A stable occupant ID must support a nickname change");
        context.check_target(original, item_id, moved_nick.id);
        Message foreign_legacy = context.persist_message("foreign legacy nick", false, "legacy-Carol",
            context.time.add_seconds(4), null, context.jid("room@conference.example.test/Carol"));
        context.link_correction(foreign_legacy, "O");
        foreach (Message revision in context.storage.get_revision_chain(context.conversation,
                    persisted_legacy, false, true)) {
            fail_if(revision.id == foreign_legacy.id,
                "Two persisted messages without occupant IDs must still match the same nickname");
        }
        context.link_correction(hostile, "O");
        fail_if(context.correction.get_latest_correction_message_id(context.conversation, original) != moved_nick.id,
            "A stored foreign occupant correction must remain outside the validated revision chain");
    }

    private void test_previous_edit_target() {
        Message original = context.persist_message("original", false, "O", context.time);
        int item_id = context.add_message_item(original);
        Message valid = context.persist_message("valid edit", false, "C1", context.time.add_seconds(1));
        fail_if_not(context.process(valid, "O"));
        Message nonconforming = context.persist_message("previous-edit payload", false, "C2", context.time.add_seconds(2));
        fail_if(context.process(nonconforming, "C1"), "XEP-0308 edits referencing another edit must remain standalone");
        fail_if(context.has_correction(nonconforming), "A previous edit must not become a correction root");
        fail_if(nonconforming.edit_to != null, "A known invalid target must not enter the unmatched cache");
        context.check_target(original, item_id, valid.id);
        context.check_standalone(nonconforming);
    }

    private void test_wrong_order_previous_edit() {
        Message last = context.persist_message("C2 before C1", false, "C2", context.time.add_seconds(2));
        fail_if(context.process(last, "C1"));
        Message another = context.persist_message("C3 before C1", false, "C3", context.time.add_seconds(3));
        fail_if(context.process(another, "C1"));
        Message first = context.persist_message("C1 before original", false, "C1", context.time.add_seconds(1));
        fail_if(context.process(first, "O"), "A correction arriving later must not be swallowed as a previous edit's original");
        fail_if(context.has_correction(last), "An out-of-order previous-edit reference must not become a validated edge");
        fail_if(last.edit_to != null, "A now-known invalid previous-edit target must leave the unmatched cache");
        context.check_standalone(last);
        context.check_standalone(first);
        Message without_id = context.persist_message("ordinary message without a sender id", false,
            "temporary-id", context.time.add_seconds(4));
        without_id.stanza_id = null;
        fail_if(context.process(without_id, null),
            "A cleared pending edit must not consume an ordinary message without an id");
        context.check_standalone(without_id);
    }

    private void test_foreign_pending_collision() {
        context.conversation = context.create_conversation("room@conference.example.test", Conversation.Type.GROUPCHAT);
        Message pending = context.persist_message("pending Bob edit", false, "C1", context.time.add_seconds(1), null, null, 23);
        fail_if(context.process(pending, "Bob-original"));
        Message foreign = context.persist_message("foreign id collision", false, "Bob-original", context.time.add_seconds(2),
            null, context.jid("room@conference.example.test/Carol"), 24);
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Got unacceptable correction*");
        fail_if(context.process(foreign, "Carol-original"));
        GLib.Test.assert_expected_messages();
        fail_if_not_eq_str(pending.edit_to, "Bob-original",
            "A foreign occupant's colliding id must not invalidate a pending correction");
        fail_if(context.has_correction(pending));
        context.check_standalone(pending);
        fail_if_not(context.has_pending(pending), "The rejected foreign correction must retain the pending entry");

        Message foreign_original = context.persist_message("foreign original id collision", false,
            "Bob-original", context.time.add_seconds(3), null,
            context.jid("room@conference.example.test/Carol"), 24);
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Got unacceptable correction*");
        fail_if(context.process(foreign_original, null));
        GLib.Test.assert_expected_messages();
        fail_if_not(context.has_pending(pending),
            "A rejected plain original from another occupant must retain the pending correction");
        fail_if_not_eq_str(pending.edit_to, "Bob-original");

        int pending_item_id = context.store.get_item_by_foreign(context.conversation, 1, pending.id).id;
        Message real_original = context.persist_message("Bob original", false, "Bob-original",
            context.time, null, null, 23);
        fail_if_not(context.process(real_original, null),
            "The matching occupant's later original must still resolve the pending correction");
        fail_if(context.has_pending(pending), "The resolved correction must leave the pending cache");
        fail_if_not_eq_str(context.correction_reference(pending), "Bob-original");
        context.check_target(real_original, pending_item_id, pending.id);
        context.check_row_time(pending_item_id, context.time);
    }

    private void test_store_dependency() {
        Message original = context.persist_message("original", false, "O", context.time);
        int item_id = context.add_message_item(original);
        Message edit = context.create_message("unstored incoming edit", false, "C1", context.time.add_seconds(1));
        var holder = new MessageListenerHolder();
        holder.connect(context.correction);
        holder.connect(new CorrectionStoreTestListener(context.storage));
        fail_if_not(context.run_holder(holder, edit, "O"), "The correction listener must run after STORE regardless of registration order");
        fail_if(edit.id <= 0, "A correction must have a persisted physical message id before it is applied");
        context.check_target(original, item_id, edit.id);
        fail_if_not_eq_str(context.correction_reference(edit), "O");
    }
}

private class CorrectionStoreTestListener : MessageListener {
    private MessageStorage storage;
    private string[] after_actions_const = {};
    public override string action_group { get { return "STORE"; } }
    public override string[] after_actions { get { return after_actions_const; } }
    public CorrectionStoreTestListener(MessageStorage storage) { this.storage = storage; }
    public override async bool run(Message message, MessageStanza stanza, Conversation conversation) {
        storage.add_message(message, conversation);
        return false;
    }
}

private class CorrectionTestContext : Object {
    public string temp_dir;
    public string db_path;
    public Database db;
    public Account account;
    public Conversation conversation;
    public StreamInteractor stream_interactor;
    public MessageCorrection correction;
    public ContentItemStore store;
    public MessageStorage storage;
    public MessageProcessor processor;
    public DateTime time = new DateTime.from_unix_utc(1701600000);

    public CorrectionTestContext(bool with_file_manager = false) throws Error {
        temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-correction-" + Uuid.string_random());
        db_path = Path.build_filename(temp_dir, "dino.db");
        DirUtils.create_with_parents(temp_dir, 0700);
        db = new Database(db_path, "correction-integrity-test");
        account = new Account(jid("alice@example.test"), "secret");
        account.persist(db);
        conversation = create_conversation("bob@example.test", Conversation.Type.CHAT);

        stream_interactor = new StreamInteractor.for_tests(db);
        MessageProcessor.start(stream_interactor, db);
        MessageStorage.start(stream_interactor, db);
        PresenceManager.start(stream_interactor, db);
        Calls.start(stream_interactor, db);
        if (with_file_manager) {
            FileManager.start(stream_interactor, db,
                new Dino.Security.FileEncryption("correction receive test"));
        } else {
            stream_interactor.add_module(FileManager.create_for_tests());
        }
        ContentItemStore.start(stream_interactor, db);
        MessageCorrection.start(stream_interactor, db);
        FileTransferStorage.start(stream_interactor, db);
        correction = stream_interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY);
        store = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        storage = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY);
        processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
    }

    public Jid jid(string value) {
        try { return new Jid(value); } catch (InvalidJidError e) { assert_not_reached(); }
    }

    public Conversation create_conversation(string address, Conversation.Type type, Account? owner = null) {
        var result = new Conversation(jid(address), owner ?? account, type);
        result.persist(db);
        return result;
    }

    public Message create_message(string body, bool sent, string stanza_id, DateTime message_time,
            Conversation? target = null, Jid? sender = null, int occupant_id = -1) {
        Conversation target_conversation = target ?? conversation;
        var message = new Message(body);
        message.account = target_conversation.account;
        bool room = target_conversation.type_ == Conversation.Type.GROUPCHAT;
        message.counterpart = sent || target_conversation.type_ == Conversation.Type.GROUPCHAT_PM
            ? target_conversation.counterpart
            : jid(target_conversation.counterpart.bare_jid.to_string() + (room ? "/Bob" : "/phone"));
        message.ourpart = room ? jid(target_conversation.counterpart.bare_jid.to_string() + "/Alice")
            : jid(target_conversation.account.bare_jid.to_string() + "/desktop");
        if (sender != null) {
            if (sent) message.ourpart = sender;
            else message.counterpart = sender;
        }
        message.direction = sent ? Message.DIRECTION_SENT : Message.DIRECTION_RECEIVED;
        message.type_ = Util.get_message_type_for_conversation(target_conversation);
        message.occupant_db_id = occupant_id;
        message.stanza_id = stanza_id;
        message.sender_stanza_id = stanza_id;
        message.time = message_time;
        message.local_time = message_time;
        return message;
    }

    public Message persist_message(string body, bool sent, string stanza_id, DateTime message_time,
            Conversation? target = null, Jid? sender = null, int occupant_id = -1) {
        Message message = create_message(body, sent, stanza_id, message_time, target, sender, occupant_id);
        storage.add_message(message, target ?? conversation);
        return message;
    }

    public int add_message_item(Message message, bool hide = false) {
        return db.add_content_item(conversation, message.time, message.local_time, 1, message.id, hide);
    }

    public void link_correction(Message message, string reference) {
        message.edit_to = reference;
        db.message_correction.insert().value(db.message_correction.message_id, message.id)
            .value(db.message_correction.to_stanza_id, reference).perform();
    }

    public void set_outgoing_correction(Message message, Message previous) {
        message.edit_to = previous.edit_to ?? previous.stanza_id;
        correction.set_correction(conversation, message, previous);
    }

    public bool process(Message message, string? reference, bool fallback = true) {
        var holder = new MessageListenerHolder();
        holder.connect(correction);
        bool stopped = run_holder(holder, message, reference);
        if (!stopped && fallback) {
            store.insert_message(message, conversation);
            processor.message_received(message, conversation);
        }
        return stopped;
    }

    public bool run_holder(MessageListenerHolder holder, Message message, string? reference) {
        var stanza = new MessageStanza((!) message.stanza_id);
        stanza.body = message.body;
        stanza.from = message.from;
        stanza.to = message.to;
        stanza.type_ = message.type_ == Message.Type.GROUPCHAT ? MessageStanza.TYPE_GROUPCHAT : MessageStanza.TYPE_CHAT;
        if (reference != null) LastMessageCorrection.set_replace_id(stanza, reference);
        bool completed = false;
        bool stopped = false;
        var loop = new MainLoop();
        uint timeout_id = Timeout.add_seconds(5, () => { loop.quit(); return Source.REMOVE; });
        holder.run.begin(message, stanza, conversation, null, (obj, result) => {
            stopped = holder.run.end(result);
            completed = true;
            if (timeout_id != 0) { Source.remove(timeout_id); timeout_id = 0; }
            loop.quit();
        });
        if (!completed) loop.run();
        if (timeout_id != 0) Source.remove(timeout_id);
        fail_if_not(completed, "The synthetic correction pipeline must complete without network access");
        return stopped;
    }

    public int foreign_id(int item_id) {
        RowOption row = db.content_item.select().with(db.content_item.id, "=", item_id).single().row();
        fail_if_not(row.is_present(), "The expected physical content row must remain stored");
        return row[db.content_item.foreign_id];
    }

    public bool has_correction(Message message) {
        return db.message_correction.select().with(db.message_correction.message_id, "=", message.id).single().row().is_present();
    }

    public bool has_pending(Message message) {
        if (!correction.unmatched_corrections.has_key(conversation)) return false;
        foreach (ContentItem item in correction.unmatched_corrections[conversation]) {
            MessageItem? message_item = item as MessageItem;
            if (message_item != null && message_item.message.id == message.id) return true;
        }
        return false;
    }

    public string? correction_reference(Message message) {
        RowOption row = db.message_correction.select().with(db.message_correction.message_id, "=", message.id).single().row();
        return row.is_present() ? row[db.message_correction.to_stanza_id] : null;
    }

    public void check_target(Message anchor, int item_id, int expected_message_id) {
        Row? row = store.get_content_item_row_for_message(conversation, anchor);
        fail_if(row == null || row[db.content_item.id] != item_id || row[db.content_item.foreign_id] != expected_message_id,
            "The logical correction target must resolve its unique actual content row");
        fail_if(foreign_id(item_id) != expected_message_id, "The content row must point to the expected physical revision");
    }

    public void check_row_time(int item_id, DateTime expected_time) {
        RowOption row = db.content_item.select().with(db.content_item.id, "=", item_id).single().row();
        fail_if(row[db.content_item.time] != expected_time.to_unix() || row[db.content_item.local_time] != expected_time.to_unix(),
            "Corrections must preserve the original content row's time and local time");
    }

    public void check_standalone(Message message) {
        ContentItem? item = store.get_item_by_foreign(conversation, 1, message.id);
        fail_if(!(item is MessageItem) || ((MessageItem) item).message.body != message.body,
            "The normal fallback path must retain the standalone correction payload");
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
