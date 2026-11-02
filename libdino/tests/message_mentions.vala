using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

class MessageMentionsTest : Gee.TestCase {
    private MentionTestContext context;

    public MessageMentionsTest() {
        base("MessageMentions");
        add_test("nickname_unicode_symbols_and_codepoint_offsets", test_nickname_boundaries);
        add_test("offline_nickname_is_room_and_account_scoped", test_offline_scope);
        add_test("new_room_without_nickname_remains_reclassifiable", test_unknown_nickname);
        add_test("own_archived_real_jid_is_not_an_incoming_mention", test_own_archived_identity);
        add_test("explicit_references_preserve_direct_and_private_messages", test_explicit_direct_and_private);
        add_test("reference_uri_roundtrips_reserved_nickname_characters", test_reference_uri);
        add_test("invalid_reference_ranges_do_not_highlight", test_reference_ranges);
        add_test("reply_fallback_is_not_a_new_mention", test_reply_fallback);
        add_test("positive_and_negative_results_survive_database_reload", () => test_persistence(false));
        add_test("version56_rows_remain_unknown_and_preserve_content", () => test_persistence(true));
        add_test("receive_pipeline_classifies_before_storage_and_corrections", test_pipeline_order);
        add_test("unread_mention_after500_items_is_found", () => test_unread_range(true, false));
        add_test("old_unread_mention_before_latest500_items_is_found", () => test_unread_range(false, true));
        add_test("legacy_unknown_mention_after500_candidates_is_found", test_unknown_unread_range);
        add_test("hidden_read_sent_and_foreign_items_are_not_mentions", test_unread_exclusions);
        add_test("xep0372_discovery_and_caps_are_account_and_stream_scoped", test_discovery);
    }

    public override void set_up() {
        try {
            context = new MentionTestContext();
        } catch (Error error) {
            fail_if_reached(@"Mention test setup failed: $(error.message)");
        }
    }

    public override void tear_down() {
        if (context != null) context.close();
    }

    private void test_nickname_boundaries() {
        int begin, end;
        fail_if_not(MessageMentions.find_nickname("🙂 Grüße, Änne!", "änne",
                out begin, out end), "Unicode nicknames must match case-insensitively");
        fail_if(begin != 9 || end != 13,
            "XEP-0372 positions must count Unicode codepoints, not UTF-8 bytes");
        foreach (string nickname in new string[] { "Alice!", "[Alice]", "🙂", "東京", "A+B" }) {
            fail_if_not(MessageMentions.find_nickname("Hello " + nickname + ", welcome",
                nickname, out begin, out end),
                "Nickname symbol edges must not require an ASCII word boundary");
        }
        foreach (string body in new string[] { "Malice", "Alice2", "Alice_extra", "前Alice後", "Alice\u0301" }) {
            fail_if(MessageMentions.find_nickname(body, "Alice", out begin, out end),
                "A nickname inside another Unicode word is not a mention");
        }
    }

    private void test_offline_scope() {
        Message message = context.message("Hello Alice!", context.room);
        fail_if_not(MessageMentions.is_mentioned(context.interactor, context.room,
            message), "Saved room nickname must work without a joined stream");
        Conversation other_room = context.conversation("other@conference.example.test",
            Conversation.Type.GROUPCHAT, context.account, "Other");
        fail_if(MessageMentions.is_mentioned(context.interactor, other_room,
            message), "A room nickname must never leak to another room");
        Conversation other_account_room = context.conversation(context.room.counterpart.to_string(),
            Conversation.Type.GROUPCHAT, context.other_account, "Alice");
        fail_if(MessageMentions.is_mentioned(context.interactor, other_account_room,
            message), "A message must never become a mention for another account");
        message.direction = Message.DIRECTION_SENT;
        message.has_mention = true;
        fail_if(MessageMentions.is_mentioned(context.interactor, context.room,
            message), "Own outgoing messages are not received mentions");
        message.direction = Message.DIRECTION_RECEIVED;
        message.decryption_failed = true;
        fail_if(MessageMentions.is_mentioned(context.interactor, context.room,
            message), "Unauthenticated failure text cannot produce mentions");
    }

    private void test_explicit_direct_and_private() {
        foreach (Conversation.Type type in new Conversation.Type[] {
                Conversation.Type.CHAT, Conversation.Type.GROUPCHAT_PM }) {
            Conversation conversation = context.conversation(
                type == Conversation.Type.CHAT ? "bob@example.test"
                    : "room@conference.example.test/Bob", type, context.account);
            Message message = context.message("Welcome!", conversation);
            MessageStanza stanza = context.stanza(message);
            context.add_reference(stanza, MessageMentions.reference_uri(context.account.bare_jid));
            MessageMentions.classify(context.interactor, conversation, message, stanza);
            fail_if_not(MessageMentions.is_mentioned(context.interactor,
                conversation, message), "Explicit mentions must remain available in direct and MUC private messages");
            Message nickname_only = context.message("Hello Alice", conversation);
            MessageMentions.classify(context.interactor, conversation,
                nickname_only, context.stanza(nickname_only));
            fail_if(nickname_only.has_mention,
                "Direct and MUC private messages must not match the room nickname heuristically");
        }
    }

    private void test_unknown_nickname() {
        context.room.nickname = null;
        Message message = context.message("Hello Alice!", context.room);
        MessageMentions.classify(context.interactor, context.room, message,
            context.stanza(message));
        fail_if(message.mention_state != Message.MentionState.UNKNOWN,
            "Missing room nickname must not permanently classify a received message negative");
        message.persist(context.db);
        context.room.nickname = "Alice";
        fail_if_not(MessageMentions.is_mentioned(context.interactor, context.room,
            message), "Joining the room must make its pending historical text recognizable");
    }

    private void test_own_archived_identity() {
        try {
            Message message = context.message("Hello Alice!", context.room);
            message.counterpart = context.room.counterpart.with_resource("OlderOwnNick");
            message.real_jid = context.account.bare_jid;
            // MAM with an old nickname can initially look received.
            message.direction = Message.DIRECTION_RECEIVED;
            MessageMentions.classify(context.interactor, context.room, message,
                context.stanza(message));
            fail_if(MessageMentions.is_mentioned(context.interactor, context.room,
                message), "Our authorized historical sender JID must exclude an older own nickname");
            message.real_jid = context.other_account.bare_jid;
            MessageMentions.classify(context.interactor, context.room, message,
                context.stanza(message));
            fail_if_not(MessageMentions.is_mentioned(context.interactor, context.room,
                message), "Another account's historical sender JID must remain eligible for a mention");
            fail_if(MessageMentions.is_mentioned(context.interactor, context.room,
                context.message("desktop-resource", context.room)),
                "An account resource stored as ourpart must not become a room nickname");
        } catch (Error error) {
            fail_if_reached(error.message);
        }
    }

    private void test_reference_uri() {
        context.room.nickname = "Ali? ce#%";
        Message message = context.message("Hello friend!", context.room);
        MessageStanza stanza = context.stanza(message);
        try {
            string uri = MessageMentions.reference_uri(context.room.counterpart.with_resource(
                (!) context.room.nickname));
            fail_if(uri.index_of("%3F") < 0 || uri.index_of("%23") < 0 ||
                uri.index_of("%25") < 0 || uri.index_of("%20") < 0,
                "Reserved URI characters must be percent-encoded");
            context.add_reference(stanza, uri, "0", "5");
            MessageMentions.classify(context.interactor, context.room, message, stanza);
            fail_if_not(message.has_mention,
                "An escaped own room nickname reference must roundtrip");
        } catch (Error error) {
            fail_if_reached(error.message);
        }
    }

    private void test_reference_ranges() {
        string?[] begins = { "-1", "0", "2", "1", "999999999999999999999", "x", null };
        string?[] ends = { "2", "100", "2", null, "999999999999999999999", "2", "2" };
        for (int i = 0; i < begins.length; i++) {
            Message message = context.message("Welcome!", context.room);
            MessageStanza stanza = context.stanza(message);
            context.add_reference(stanza, MessageMentions.reference_uri(context.account.bare_jid),
                begins[i], ends[i]);
            MessageMentions.classify(context.interactor, context.room, message, stanza);
            fail_if(message.has_mention, "Malformed/out-of-bounds mention ranges must be ignored");
        }
        Message trimmed = context.message("Welcome!", context.room);
        MessageStanza valid = context.stanza(trimmed);
        valid.body = " \nWelcome!";
        context.add_reference(valid, MessageMentions.reference_uri(context.account.bare_jid), "2", "10");
        MessageMentions.classify(context.interactor, context.room, trimmed, valid);
        fail_if_not(trimmed.has_mention,
            "Reference ranges must address the untrimmed wire body");
    }

    private void test_reply_fallback() {
        Message message = context.message("> Alice: old message\nA new reply", context.room);
        MessageStanza stanza = context.stanza(message);
        var locations = new Gee.ArrayList<FallbackIndication.FallbackLocation>();
        locations.add(new FallbackIndication.FallbackLocation.partial_body(0, 21));
        var fallback = new FallbackIndication.Fallback(Xmpp.Xep.Replies.NS_URI, locations);
        FallbackIndication.set_fallback(stanza, fallback);
        context.add_reference(stanza, MessageMentions.reference_uri(context.account.bare_jid), "2", "7");
        MessageMentions.classify(context.interactor, context.room, message, stanza);
        fail_if(message.has_mention,
            "Quoted nickname or quoted reference must not produce a fresh mention");
        message.body = "> Alice: old message\nA new reply for Alice!";
        stanza = context.stanza(message);
        FallbackIndication.set_fallback(stanza, fallback);
        MessageMentions.classify(context.interactor, context.room, message, stanza);
        fail_if_not(message.has_mention,
            "A nickname in the actual reply body still counts as a mention");
        message.persist(context.db);
        var stored_fallbacks = new Gee.ArrayList<FallbackIndication.Fallback>();
        stored_fallbacks.add(fallback);
        message.set_fallbacks(stored_fallbacks);
        int begin, end;
        fail_if_not(MessageMentions.find_nickname_in_message(message, "Alice", out begin, out end),
            "Outgoing reply matching must find the real body mention");
        fail_if(begin != 37 || end != 42,
            "Removing fallback quotes must not shift outgoing XEP-0372 offsets");
    }

    private void test_persistence(bool upgrade) {
        try {
            Message positive = context.message("Welcome!", context.room);
            MessageStanza stanza = context.stanza(positive);
            context.add_reference(stanza, MessageMentions.reference_uri(context.account.bare_jid));
            MessageMentions.classify(context.interactor, context.room, positive, stanza);
            positive.persist(context.db);
            Message negative = context.message("Hello FutureNick!", context.room);
            MessageMentions.classify(context.interactor, context.room, negative,
                context.stanza(negative));
            negative.persist(context.db);
            Message legacy = context.message("Hello Alice!", context.room);
            legacy.persist(context.db);
            int positive_id = positive.id, negative_id = negative.id, legacy_id = legacy.id;
            if (upgrade) {
                context.db.exec("""
CREATE TABLE message_pre57_fixture AS SELECT
    id, stanza_id, server_id, sender_stanza_id, stable_id, stable_id_by,
    account_id, counterpart_id, counterpart_resource, our_resource,
    direction, type, time, local_time, body, encryption, encryption_protocol,
    decryption_failed, encryption_time_mismatch, marked, markable FROM message;
DROP TABLE message;
ALTER TABLE message_pre57_fixture RENAME TO message;
UPDATE _meta SET int_val=56 WHERE name='version';
""");
                rebuild_account_fixture_at_version(context.db, 56);
            }
            context.reopen();
            Message? reloaded_positive = context.db.get_message_by_id(positive_id);
            Message? reloaded_negative = context.db.get_message_by_id(negative_id);
            Message? reloaded_legacy = context.db.get_message_by_id(legacy_id);
            fail_if(reloaded_positive == null || reloaded_negative == null ||
                reloaded_legacy == null, "Schema migration must retain every message");
            if (reloaded_positive == null || reloaded_negative == null || reloaded_legacy == null) return;
            fail_if(((!) reloaded_positive).mention_state != (upgrade
                    ? Message.MentionState.UNKNOWN : Message.MentionState.MENTIONED),
                "Persisted reference-only mentions must survive an actual database reopen");
            fail_if_not_eq_str(((!) reloaded_legacy).body, "Hello Alice!");
            fail_if_not(MessageMentions.is_mentioned(context.interactor, context.room,
                (!) reloaded_legacy), "Old rows must use the stored nickname offline");
            context.room.nickname = "FutureNick";
            if (!upgrade) {
                fail_if(MessageMentions.is_mentioned(context.interactor, context.room,
                    (!) reloaded_negative), "A new nickname must not reinterpret known-negative historical messages");
                ((!) reloaded_positive).has_mention = false;
                Message? updated = context.db.get_message_by_id(positive_id);
                fail_if(updated == null || ((!) updated).mention_state != Message.MentionState.NONE,
                    "Mention provenance updates must be persisted");
            } else {
                fail_if(((!) reloaded_negative).mention_state != Message.MentionState.UNKNOWN,
                    "A migration must not guess reference metadata for old rows");
            }
        } catch (Error error) {
            fail_if_reached(error.message);
        }
    }

    private void test_pipeline_order() {
        Message original = context.message("Welcome!", context.room);
        MessageStanza original_stanza = context.stanza(original);
        context.add_reference(original_stanza,
            MessageMentions.reference_uri(context.account.bare_jid));
        fail_if(context.run_pipeline(original, original_stanza),
            "An ordinary incoming message must reach the content store");
        Message? original_row = context.db.get_message_by_id(original.id);
        fail_if(original_row == null || !((!) original_row).has_mention,
            "The production receive pipeline must classify before storing");
        fail_if_not(ChatInteraction.has_unread_mention_in_store(context.interactor,
            context.room), "Stored positive original must be an unread mention");
        ContentItem? item = context.store.get_item_by_foreign(context.room, 1, original.id);
        fail_if(item == null, "The original must have one content row");
        if (item == null) return;
        Message corrected = context.message("No nickname here", context.room);
        MessageStanza correction = context.stanza(corrected);
        LastMessageCorrection.set_replace_id(correction, (!) original.stanza_id);
        fail_if_not(context.run_pipeline(corrected, correction),
            "An accepted correction must consume its separate content row");
        ContentItem? corrected_item = context.store.get_item_by_id(context.room, ((!) item).id);
        fail_if(!(corrected_item is MessageItem) ||
            ((MessageItem) corrected_item).message.id != corrected.id ||
            ((MessageItem) corrected_item).message.mention_state != Message.MentionState.NONE,
            "Correction must remove an old mention using the newly classified revision");
        fail_if(ChatInteraction.has_unread_mention_in_store(context.interactor,
            context.room), "The SQL candidate query must not retain a superseded positive original");
        Message explicit_edit = context.message("Welcome back!", context.room);
        MessageStanza explicit_stanza = context.stanza(explicit_edit);
        LastMessageCorrection.set_replace_id(explicit_stanza, (!) original.stanza_id);
        context.add_reference(explicit_stanza,
            MessageMentions.reference_uri(context.account.bare_jid));
        fail_if_not(context.run_pipeline(explicit_edit, explicit_stanza),
            "The reference-only correction must apply");
        Message? edit_row = context.db.get_message_by_id(explicit_edit.id);
        fail_if(edit_row == null || !((!) edit_row).has_mention,
            "A correction's explicit reference must be classified before correction can stop the pipeline");
        fail_if_not(ChatInteraction.has_unread_mention_in_store(context.interactor,
            context.room), "The SQL candidate query must include the current positive revision of a negative body");
    }

    private void test_unread_range(bool with_marker, bool oldest_mention) {
        Message marker = context.message("already read", context.room);
        marker.has_mention = false;
        int marker_id = context.add_item(marker);
        context.room.read_up_to_item = with_marker ? marker_id : -1;
        for (int i = 0; i < 510; i++) {
            Message message = context.message("plain new message", context.room);
            message.has_mention = oldest_mention ? i == 0 : i == 509;
            context.add_item(message);
        }
        fail_if_not(ChatInteraction.has_unread_mention_in_store(context.interactor,
            context.room), "All unread messages must be checked beyond the old 500-item truncation");
    }

    private void test_unknown_unread_range() {
        Message marker = context.message("already read", context.room);
        marker.has_mention = false;
        context.room.read_up_to_item = context.add_item(marker);
        for (int i = 0; i < 510; i++) {
            Message message = context.message(i == 509 ? "Hello Alice!" : "ordinary legacy message",
                context.room);
            context.add_item(message);
        }
        fail_if_not(ChatInteraction.has_unread_mention_in_store(context.interactor,
            context.room), "UNKNOWN legacy rows must continue across multiple bounded query pages");
    }

    private void test_unread_exclusions() {
        Message read = context.message("read mention", context.room);
        read.has_mention = true;
        context.room.read_up_to_item = context.add_item(read);
        Message hidden = context.message("hidden mention", context.room);
        hidden.has_mention = true;
        context.add_item(hidden, true);
        Message sent = context.message("own mention", context.room);
        sent.direction = Message.DIRECTION_SENT;
        sent.has_mention = true;
        context.add_item(sent);
        Conversation foreign_room = context.conversation(context.room.counterpart.to_string(),
            Conversation.Type.GROUPCHAT, context.other_account, "Alice");
        Message foreign = context.message("foreign mention", foreign_room);
        foreign.has_mention = true;
        foreign.persist(context.db);
        // Deliberately inconsistent content relation must not cross account.
        context.db.add_content_item(context.room, foreign.time, foreign.local_time, 1, foreign.id, false);
        fail_if(ChatInteraction.has_unread_mention_in_store(context.interactor,
            context.room), "Read, hidden, own and foreign-account rows must not produce unread mentions");
    }

    private void test_discovery() {
        try {
            ModuleManager modules = context.interactor.module_manager;
            // Match connection startup. Before constructing the modules,
            // Vala's static IDENTITY fields have not been initialized yet.
            modules.initialize(context.account);
            modules.initialize(context.other_account);
            ServiceDiscovery.Module? maybe_first = modules.get_module<
                ServiceDiscovery.Module>(context.account,
                    ServiceDiscovery.Module.IDENTITY);
            ServiceDiscovery.Module? maybe_second = modules.get_module<
                ServiceDiscovery.Module>(context.other_account,
                    ServiceDiscovery.Module.IDENTITY);
            if (fail_if(maybe_first == null || maybe_second == null,
                    "Account startup must initialize both service discovery modules")) return;
            ServiceDiscovery.Module first = (!) maybe_first;
            ServiceDiscovery.Module second = (!) maybe_second;
            fail_if(first == second,
                "Service discovery instances must remain separated by account");
            var first_stream = new MentionDiscoveryTestStream(new Jid("example.test"));
            var second_stream = new MentionDiscoveryTestStream(new Jid("example.test"));
            first_stream.add_module((!) modules.get_module<Iq.Module>(
                context.account, Iq.Module.IDENTITY));
            second_stream.add_module((!) modules.get_module<Iq.Module>(
                context.other_account, Iq.Module.IDENTITY));
            first_stream.add_module(first);
            second_stream.add_module(second);
            first.attach(first_stream);
            second.attach(second_stream);
            ServiceDiscovery.Flag first_flag = (!) first_stream.get_flag<
                ServiceDiscovery.Flag>(ServiceDiscovery.Flag.IDENTITY);
            ServiceDiscovery.Flag second_flag = (!) second_stream.get_flag<
                ServiceDiscovery.Flag>(ServiceDiscovery.Flag.IDENTITY);
            fail_if_not(first_flag.own_features.contains(References.NS_URI) &&
                second_flag.own_features.contains(References.NS_URI),
                "Every account's actual attached discovery module must advertise XEP-0372");

            Presence.Module presence_module = (!) modules.get_module<Presence.Module>(
                context.account, Presence.Module.IDENTITY);
            first_stream.add_module(presence_module);
            var caps = new EntityCapabilities.Module(
                new EntityCapabilitiesStorage(context.db));
            first_stream.add_module(caps);
            caps.attach(first_stream);
            var presence = new Presence.Stanza() {
                type_ = Presence.Stanza.TYPE_AVAILABLE
            };
            presence_module.pre_send_presence_stanza(first_stream, presence);
            string expected_hash = EntityCapabilities.Module.compute_hash(
                first_flag.own_identities, first_flag.own_features,
                new Gee.ArrayList<DataForms.DataForm>());
            fail_if_not_eq_str(EntityCapabilities.get_caps_hash(presence),
                expected_hash, "Initial presence must hash the features that include XEP-0372");
            Gee.List<string> without_mentions = first_flag.own_features;
            without_mentions.remove(References.NS_URI);
            fail_if(expected_hash == EntityCapabilities.Module.compute_hash(
                first_flag.own_identities, without_mentions,
                new Gee.ArrayList<DataForms.DataForm>()),
                "The capability hash must change when mention support is omitted");
            var next_presence = new Presence.Stanza() {
                type_ = Presence.Stanza.TYPE_AVAILABLE
            };
            presence_module.pre_send_presence_stanza(first_stream, next_presence);
            fail_if_not_eq_str(EntityCapabilities.get_caps_hash(next_presence),
                expected_hash, "The cached presence hash must retain the announced mention capability");

            caps.detach(first_stream);
            first.detach(first_stream);
            fail_if(first_flag.own_features.contains(References.NS_URI),
                "Detaching a stream must remove its mention capability");
            fail_if_not(second_flag.own_features.contains(References.NS_URI),
                "Detaching one account must not change another account's capabilities");
            second.detach(second_stream);
        } catch (Error error) {
            fail_if_reached(error.message);
        }
    }
}

private class MentionDiscoveryTestStream : XmppStream {
    public MentionDiscoveryTestStream(Jid remote_name) { base(remote_name); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("isolated mention discovery stream has no reader");
    }
    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        throw new IOError.NOT_CONNECTED("isolated mention discovery never writes to a server");
    }
}

private class MentionTestContext : Object {
    private const string DATABASE_KEY = "isolated mention regression test";
    private string directory;
    private string path;
    private int serial = 0;
    public Database db;
    public StreamInteractor interactor;
    public Account account;
    public Account other_account;
    public Conversation room;
    public ContentItemStore store;
    public MessageProcessor processor;

    public MentionTestContext() throws Error {
        directory = DirUtils.make_tmp("dinox-mention-XXXXXX");
        path = Path.build_filename(directory, "test.db");
        db = new Database(path, DATABASE_KEY);
        account = new Account(new Jid("alice@example.test"), "test-only");
        account.persist(db);
        other_account = new Account(new Jid("other@example.test"), "test-only");
        other_account.persist(db);
        room = conversation("room@conference.example.test", Conversation.Type.GROUPCHAT,
            account, "Alice");
        start_modules();
    }

    private void start_modules() {
        interactor = new StreamInteractor.for_tests(db);
        MessageStorage.start(interactor, db);
        MessageProcessor.start(interactor, db);
        PresenceManager.start(interactor, db);
        store = new ContentItemStore.for_tests(interactor, db);
        interactor.add_module(store);
        MessageCorrection.start(interactor, db);
        processor = interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
    }

    public Conversation conversation(string address, Conversation.Type type,
            Account owner, string? nickname = null) {
        try {
            var result = new Conversation(new Jid(address), owner, type) {
                nickname = nickname, encryption = Encryption.NONE
            };
            result.persist(db);
            return result;
        } catch (Error error) { assert_not_reached(); }
    }

    public Message message(string body, Conversation target) {
        DateTime time = new DateTime.from_unix_utc(1701700000).add_seconds(++serial);
        try {
            return new Message(body) {
                account = target.account,
                counterpart = target.type_ == Conversation.Type.GROUPCHAT
                    ? target.counterpart.with_resource("Bob") : target.counterpart,
                // This is how incoming room stanzas are actually addressed:
                // the account resource is not a historical room nickname.
                ourpart = target.account.bare_jid.with_resource("desktop-resource"),
                type_ = Util.get_message_type_for_conversation(target),
                direction = Message.DIRECTION_RECEIVED,
                time = time, local_time = time,
                stanza_id = "mention-" + serial.to_string(),
                sender_stanza_id = "mention-" + serial.to_string()
            };
        } catch (Error error) { assert_not_reached(); }
    }

    public MessageStanza stanza(Message message) {
        var result = new MessageStanza((!) message.stanza_id);
        result.from = message.from;
        result.to = message.to;
        result.body = message.body;
        result.type_ = message.type_ == Message.Type.GROUPCHAT
            ? MessageStanza.TYPE_GROUPCHAT : MessageStanza.TYPE_CHAT;
        return result;
    }

    public void add_reference(MessageStanza stanza, string uri,
            string? begin = null, string? end = null) {
        References.add_reference(stanza, new References.Reference() {
            type_ = "mention", uri = uri, begin = begin, end = end
        });
    }

    public int add_item(Message message, bool hidden = false) {
        message.persist(db);
        return db.add_content_item(room, message.time, message.local_time, 1,
            message.id, hidden);
    }

    public bool run_pipeline(Message message, MessageStanza stanza) {
        bool complete = false, stopped = false;
        var loop = new MainLoop();
        uint timeout = Timeout.add_seconds(5, () => {
            loop.quit();
            return Source.REMOVE;
        });
        processor.received_pipeline.run.begin(message, stanza, room, null,
            (object, result) => {
                stopped = processor.received_pipeline.run.end(result);
                complete = true;
                if (timeout != 0) { Source.remove(timeout); timeout = 0; }
                loop.quit();
            });
        if (!complete) loop.run();
        if (timeout != 0) Source.remove(timeout);
        fail_if_not(complete, "The offline production receive pipeline must finish");
        return stopped;
    }

    public void reopen() throws Error {
        int room_id = room.id;
        db.close();
        db = new Database(path, DATABASE_KEY);
        account = (!) db.get_account_by_id(account.id);
        other_account = (!) db.get_account_by_id(other_account.id);
        Qlite.RowOption row = db.conversation.select()
            .with(db.conversation.id, "=", room_id).single().row();
        room = new Conversation.from_row(db, row.inner);
        start_modules();
    }

    public void close() {
        db.close();
        foreach (string name in new string[] { path, path + "-wal", path + "-shm" }) {
            FileUtils.unlink(name);
        }
        DirUtils.remove(directory);
    }
}

}
