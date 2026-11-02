using Xmpp;

namespace Dino.Test {

class DisplayedStateAudit : Gee.TestCase {
    public DisplayedStateAudit() {
        base("DisplayedState");
        add_test("xep0333_chat_uses_sender_id",
            test_chat_target_uses_sender_id);
        add_test("xep0333_groupchat_uses_room_id",
            test_groupchat_target_uses_room_id);
        add_test("xep0333_muc_pm_uses_sender_id",
            test_muc_pm_target_uses_sender_id);
        add_test("xep0333_missing_reference_is_rejected",
            test_missing_reference_is_rejected);
        add_test("displayed_state_moves_forward_only",
            test_forward_only_ordering);
        add_test("stable_reference_authority_matrix",
            test_stable_reference_authority_matrix);
        add_test("stable_reference_wrong_authority_is_rejected",
            test_stable_reference_wrong_authority);
        add_test("stable_reference_prefers_live_sid_over_mam_id",
            test_stable_reference_preference);
        add_test("markable_flag_survives_database_reopen",
            test_markable_persistence);
        add_test("sender_wire_id_is_separate_from_origin_id",
            test_sender_wire_id_is_separate);
        add_test("groupchat_pm_uses_chat_stanza_type",
            test_groupchat_pm_uses_chat_type);
        add_test("response_policy_roster_matrix",
            test_response_policy_roster_matrix);
        add_test("xep0490_authority_selects_conversation_type",
            test_xep0490_authority_matrix);
        add_test("xep0490_publication_queue_is_latest_wins",
            test_xep0490_publication_queue);
        add_test("xep0490_global_setting_persists",
            test_xep0490_global_setting_persistence);
        add_test("read_state_pair_persists_together",
            test_read_state_pair_persistence);
        add_test("remote_read_through_is_not_page_limited",
            test_remote_read_through_not_page_limited);
        add_test("ambiguous_sender_id_does_not_use_legacy_fallback",
            test_ambiguous_sender_id_no_fallback);
        add_test("contact_marker_operation_rejects_stale_completion",
            test_contact_marker_operation_rejects_stale_completion);
        add_test("contact_marker_async_completion_retains_manager",
            test_contact_marker_async_completion_retains_manager);
        add_test("sender_id_lookup_is_direction_scoped",
            test_sender_id_lookup_is_direction_scoped);
        add_test("pending_control_replay_is_bounded_and_expires",
            test_pending_control_replay_is_bounded_and_expires);
        add_test("remote_read_does_not_cover_later_notification",
            test_remote_read_does_not_cover_later_notification);
        add_test("private_muc_reader_pointers_are_independent_and_persist",
            test_private_muc_reader_pointers_are_independent_and_persist);
        add_test("message_pipeline_guard_rejects_replaced_stream",
            test_message_pipeline_guard_rejects_replaced_stream);
        add_test("xep0490_catchup_waits_for_presence_and_history",
            test_xep0490_catchup_waits_for_presence_and_history);
        add_test("xep0490_server_assist_target_matrix",
            test_xep0490_server_assist_target_matrix);
        add_test("xep0490_server_assist_fallback_matrix",
            test_xep0490_server_assist_fallback_matrix);
        add_test("xep0490_server_assist_stream_lifecycle",
            test_xep0490_server_assist_stream_lifecycle);
    }

    private void test_contact_marker_operation_rejects_stale_completion() {
        Entities.Account account = make_account();
        var conversation = new Entities.Conversation(
            jid("bob@example.test"), account,
            Entities.Conversation.Type.CHAT);
        var tracker = new ConversationOperationTracker();

        uint64 stale = tracker.begin(conversation);
        tracker.clear(conversation);
        uint64 current = tracker.begin(conversation);

        fail_if(tracker.finish(conversation, stale),
            "A stale callback must not finish a newer marker operation");
        fail_if_not(tracker.is_active(conversation),
            "The newer marker operation must remain active");
        fail_if_not(tracker.finish(conversation, current),
            "The current marker callback must finish its own operation");
        fail_if(tracker.is_active(conversation),
            "The completed marker operation must be removed");
    }

    private void test_contact_marker_async_completion_retains_manager() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-marker-lifetime-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "marker-lifetime-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            var stream = new DisplayedMarkerDelayedAuditStream(
                jid("example.test"));
            stream.add_module(new Xmpp.MessageModule());
            stream.add_module(new Xep.ChatMarkers.Module());
            interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            DisplayedStateManager? manager =
                new DisplayedStateManager.for_tests(interactor,
                    new Dino.Entities.Settings.from_db((!) db));
            WeakRef manager_ref = WeakRef((!) manager);
            var conversation = new Entities.Conversation(
                jid("bob@example.test"), account,
                Entities.Conversation.Type.CHAT);
            Entities.Message message = make_received_message(account,
                jid("bob@example.test/phone"),
                Entities.Message.Type.CHAT);
            message.sender_stanza_id = "delayed-marker-id";

            var loop = new MainLoop();
            bool timed_out = false;
            uint timeout_id = Timeout.add_seconds(2, () => {
                timed_out = true;
                loop.quit();
                return Source.REMOVE;
            });
            stream.write_completed.connect(() => {
                Idle.add(() => {
                    loop.quit();
                    return Source.REMOVE;
                });
            });

            ((!) manager).queue_contact_marker_for_tests(conversation,
                message);
            manager = null;
            fail_if(manager_ref.get() == null,
                "The in-flight async marker state must retain its manager");
            loop.run();
            if (timeout_id != 0 && !timed_out) Source.remove(timeout_id);

            fail_if(timed_out,
                "The delayed marker write must complete");
            fail_if(manager_ref.get() != null,
                "The completed async marker state must release its manager");
        } catch (Error error) {
            fail_if_reached("Unexpected marker lifetime error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_pending_control_replay_is_bounded_and_expires() {
        Entities.Account account = make_account();
        var conversation = new Entities.Conversation(
            jid("bob@example.test"), account,
            Entities.Conversation.Type.CHAT);
        Jid sender = jid("bob@example.test/phone");
        var queue = new PendingMessageStateQueue();

        queue.offer_at(conversation, sender, "duplicate", 100);
        queue.offer_at(conversation, sender, "duplicate", 100);
        fail_if(queue.size != 1,
            "Identical pending control stanzas must be deduplicated");

        queue = new PendingMessageStateQueue();
        for (int i = 0; i <= PendingMessageStateQueue.MAX_ENTRIES; i++) {
            queue.offer_at(conversation, sender, "id-" + i.to_string(),
                100);
        }
        fail_if(queue.size != PendingMessageStateQueue.MAX_ENTRIES,
            "The pending control queue must remain bounded");
        fail_if(queue.take_at(conversation, "id-0", 100).size != 0,
            "The oldest pending control stanza must be evicted first");

        queue = new PendingMessageStateQueue();
        queue.offer_at(conversation, sender, "expired", 100);
        fail_if(queue.take_at(conversation, "expired",
                100 + PendingMessageStateQueue.TTL_US).size != 0,
            "Expired pending control stanzas must not be replayed");
    }

    private void test_remote_read_does_not_cover_later_notification() {
        Entities.Account account = make_account();
        var conversation = new Entities.Conversation(
            jid("bob@example.test"), account,
            Entities.Conversation.Type.CHAT);
        Entities.Message earlier = make_received_message(account,
            jid("bob@example.test/phone"), Entities.Message.Type.CHAT);
        earlier.local_time = new DateTime.from_unix_utc(100);
        var read_item = new MessageItem(earlier, conversation, 1);

        Entities.Message later = make_received_message(account,
            jid("bob@example.test/phone"), Entities.Message.Type.CHAT);
        later.local_time = new DateTime.from_unix_utc(101);
        later.time = new DateTime.from_unix_utc(101);
        var latest_item = new MessageItem(later, conversation, 2);

        fail_if(NotificationEvents.read_item_covers_latest(read_item,
                latest_item),
            "Reading N remotely must not retract the notification for N+1");
        fail_if_not(NotificationEvents.read_item_covers_latest(latest_item,
                latest_item),
            "The latest remotely read item may retract its notification");
    }

    private void test_private_muc_reader_pointers_are_independent_and_persist() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-muc-readers-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "muc-readers-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var conversation = new Entities.Conversation(
                jid("room@conference.example.test"), account,
                Entities.Conversation.Type.GROUPCHAT);
            conversation.persist((!) db);

            Entities.Message older = make_sent_groupchat_message(account,
                conversation.counterpart, 100);
            older.persist((!) db);
            Entities.Message newer = make_sent_groupchat_message(account,
                conversation.counterpart, 101);
            newer.persist((!) db);

            var store = new MucDisplayedStateStore((!) db);
            fail_if_not(store.advance(conversation,
                    jid("bob@example.test"), older),
                "The first verified reader pointer must be stored");
            fail_if_not(store.advance(conversation,
                    jid("carol@example.test"), newer),
                "A second participant needs an independent pointer");
            fail_if(store.get_reader_count(conversation, older) != 2,
                "Both participants have displayed the older message");
            fail_if(store.get_reader_count(conversation, newer) != 1,
                "Only the participant at the newer pointer has displayed it");
            fail_if(store.advance(conversation, jid("bob@example.test"),
                    older),
                "A duplicate marker must not move a reader pointer");
            fail_if_not(store.advance(conversation,
                    jid("bob@example.test"), newer),
                "A verified reader pointer must move forward");
            fail_if(store.get_reader_count(conversation, newer) != 2,
                "Both forward pointers must cover the newer message");
            fail_if(store.advance(conversation, jid("bob@example.test"),
                    older),
                "An older marker must not move a reader pointer backward");
            fail_if(store.advance(conversation, account.bare_jid, newer),
                "The account itself must not be counted as a room reader");
            fail_if(older.marked == Entities.Message.Marked.READ ||
                    newer.marked == Entities.Message.Marked.READ,
                "Participant pointers must not mutate the room-wide read flag");

            ((!) db).close();
            db = new Database(db_path, "muc-readers-test");
            store = new MucDisplayedStateStore((!) db);
            fail_if(store.get_reader_count(conversation, older) != 2 ||
                    store.get_reader_count(conversation, newer) != 2,
                "Private-MUC reader pointers must survive a database reopen");
        } catch (Error error) {
            fail_if_reached("Unexpected private-MUC reader-state error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_message_pipeline_guard_rejects_replaced_stream() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-pipeline-guard-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "pipeline-guard-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            var first = new DisplayedStateAuditStream(
                jid("example.test"));
            var replacement = new DisplayedStateAuditStream(
                jid("example.test"));
            interactor.connection_manager.set_connected_stream_for_tests(
                account, first);
            var guard = new MessagePipelineGuard(interactor, account, first);
            fail_if_not(guard.is_current(),
                "The pipeline guard must accept its source stream");

            interactor.connection_manager.set_connected_stream_for_tests(
                account, replacement);
            fail_if(guard.is_current(),
                "The pipeline guard must reject a replaced stream");
        } catch (Error error) {
            fail_if_reached("Unexpected pipeline guard error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_xep0490_catchup_waits_for_presence_and_history() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-mds-catchup-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        DisplayedStateSyncOwner? owner = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "mds-catchup-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            interactor.module_manager.initialize(account);

            var stream = new DisplayedStateCatchupAuditStream(
                jid("example.test"));
            var bind_flag = new Bind.Flag();
            bind_flag.my_jid = jid("alice@example.test/desktop");
            bind_flag.finished = true;
            stream.add_flag(bind_flag);

            Iq.Module iq = interactor.module_manager.get_module<Iq.Module>(
                account,
                Iq.Module.IDENTITY);
            Xep.Pubsub.Module pubsub = interactor.module_manager.get_module<
                Xep.Pubsub.Module>(account, Xep.Pubsub.Module.IDENTITY);
            Xep.MessageDisplayedSynchronization.Module mds = interactor
                .module_manager.get_module<
                    Xep.MessageDisplayedSynchronization.Module>(account,
                        Xep.MessageDisplayedSynchronization.Module.IDENTITY);
            Presence.Module presence = interactor.module_manager.get_module<
                Presence.Module>(account, Presence.Module.IDENTITY);
            stream.add_module(iq);
            iq.attach(stream);
            stream.add_module(pubsub);
            stream.add_module(mds);

            interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            owner = new DisplayedStateSyncOwner(interactor, account);
            int catchup_count = 0;
            int catchup_item_count = 0;
            ((!) owner).catchup_ready.connect((bound_account, items) => {
                catchup_count++;
                catchup_item_count = items.size;
            });

            ((!) owner).prepare_stream(stream);
            ((!) owner).begin_fresh_stream(stream);
            fail_if(stream.written_nodes.size != 0,
                "Fresh-stream catch-up must wait for initial presence");

            var loop = new MainLoop();
            bool timed_out = false;
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(2, () => {
                timeout_id = 0;
                timed_out = true;
                loop.quit();
                return Source.REMOVE;
            });
            stream.fetch_response_settled.connect(() => {
                if (timeout_id != 0) {
                    Source.remove(timeout_id);
                    timeout_id = 0;
                }
                loop.quit();
            });
            var initial_presence = new Presence.Stanza();
            presence.initial_presence_sent(stream, initial_presence);
            loop.run();

            fail_if(timed_out, "MDS fetch did not settle before the timeout");
            fail_if(stream.written_nodes.size != 1,
                "Initial presence must start exactly one MDS fetch");
            fail_if(catchup_count != 0,
                "Fetched MDS state must wait until account MAM is settled");

            ((!) owner).mark_history_settled(stream);
            fail_if(catchup_count != 1 || catchup_item_count != 1,
                "Settled MAM must release the fetched MDS state exactly once");
            ((!) owner).mark_history_settled(stream);
            fail_if(catchup_count != 1,
                "Duplicate history completion must not replay MDS catch-up");
        } catch (Error error) {
            fail_if_reached("Unexpected MDS owner catch-up error: " +
                error.message);
        } finally {
            if (owner != null) ((!) owner).shutdown();
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_xep0490_server_assist_target_matrix() {
        Entities.Account account = make_account();

        var chat = new Entities.Conversation(jid("bob@example.test"),
            account, Entities.Conversation.Type.CHAT);
        Entities.Message chat_message = make_received_message(account,
            jid("bob@example.test/phone"), Entities.Message.Type.CHAT);
        chat_message.sender_stanza_id = "sender-wire-id";
        chat_message.set_stable_reference("account-stable-id",
            account.bare_jid);
        DisplayedMarkerTarget? chat_marker = DisplayedStateManager
            .get_xep0333_target(chat, chat_message);
        fail_if(chat_marker == null,
            "The 1:1 marker prerequisite must be available");
        if (chat_marker != null) {
            DisplayedServerAssistTarget? assisted = DisplayedStateManager
                .get_server_assist_target(chat, chat_message,
                    (!) chat_marker);
            fail_if(assisted == null || !((!) assisted).chat.equals(
                    jid("bob@example.test")) ||
                    ((!) assisted).reference.id != "account-stable-id" ||
                    !((!) assisted).reference.by.equals(account.bare_jid),
                "1:1 assist must use the bare contact and account SID");

            var mismatched = new DisplayedMarkerTarget(
                jid("mallory@example.test/device"), "sender-wire-id",
                MessageStanza.TYPE_CHAT);
            fail_if(DisplayedStateManager.get_server_assist_target(chat,
                    chat_message, mismatched) != null,
                "Assist must reject a marker target outside the chat item");
        }

        var groupchat = new Entities.Conversation(
            jid("room@conference.example.test"), account,
            Entities.Conversation.Type.GROUPCHAT);
        Entities.Message group_message = make_received_message(account,
            jid("room@conference.example.test/bob"),
            Entities.Message.Type.GROUPCHAT);
        group_message.set_stable_reference("room-stable-id",
            groupchat.counterpart);
        DisplayedMarkerTarget? group_marker = DisplayedStateManager
            .get_xep0333_target(groupchat, group_message);
        fail_if(group_marker == null || DisplayedStateManager
                .get_server_assist_target(groupchat, group_message,
                    (!) group_marker) == null,
            "Room markers may combine with the room-authoritative SID");

        var muc_pm = new Entities.Conversation(
            jid("room@conference.example.test/bob"), account,
            Entities.Conversation.Type.GROUPCHAT_PM);
        Entities.Message private_message = make_received_message(account,
            jid("room@conference.example.test/bob"),
            Entities.Message.Type.GROUPCHAT_PM);
        private_message.sender_stanza_id = "private-wire-id";
        private_message.set_stable_reference("account-private-id",
            account.bare_jid);
        DisplayedMarkerTarget? private_marker = DisplayedStateManager
            .get_xep0333_target(muc_pm, private_message);
        fail_if(private_marker == null,
            "The MUC-PM contact marker prerequisite must be available");
        if (private_marker != null) {
            fail_if(DisplayedStateManager.get_server_assist_target(muc_pm,
                    private_message, (!) private_marker) != null,
                "MUC-PM full item IDs must use regular PubSub");
        }
    }

    private void test_xep0490_server_assist_fallback_matrix() {
        fail_if(DisplayedStateManager.select_sync_route(true, true,
                true, true) != DisplayedStateSyncRoute.SERVER_ASSIST,
            "Assist is allowed only when the private sync and external " +
            "marker paths are both active");
        fail_if(DisplayedStateManager.select_sync_route(true, true,
                false, true) != DisplayedStateSyncRoute.REGULAR_PEP,
            "Disabled external markers must force private regular PubSub");
        fail_if(DisplayedStateManager.select_sync_route(true, true,
                true, false) != DisplayedStateSyncRoute.REGULAR_PEP,
            "Missing server support must fall back to regular PubSub");
        fail_if(DisplayedStateManager.select_sync_route(true, true,
                false, false) != DisplayedStateSyncRoute.REGULAR_PEP,
            "Private sync must not depend on a contact-visible marker");
        fail_if(DisplayedStateManager.select_sync_route(true, false,
                true, true) != DisplayedStateSyncRoute.NONE,
            "Disabled private sync must not send PEP or server assist");
        fail_if(DisplayedStateManager.select_sync_route(false, true,
                true, true) != DisplayedStateSyncRoute.NONE,
            "A duplicate local read pointer must not republish state");
    }

    private void test_xep0490_server_assist_stream_lifecycle() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-mds-assist-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        DisplayedStateSyncOwner? owner = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "mds-assist-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            interactor.module_manager.initialize(account);

            Xep.ServiceDiscovery.Module discovery = interactor.module_manager
                .get_module<Xep.ServiceDiscovery.Module>(account,
                    Xep.ServiceDiscovery.Module.IDENTITY);
            discovery.cache = new DisplayedStateAssistCapsCache();
            var stream = new DisplayedStateAuditStream(jid("example.test"));
            add_bound_account_modules(stream, discovery, account);
            interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            owner = new DisplayedStateSyncOwner(interactor, account);
            ((!) owner).prepare_stream(stream);
            ((!) owner).begin_resumed_stream(stream);

            if (!((!) owner).can_use_server_assist(stream)) {
                var loop = new MainLoop();
                bool timed_out = false;
                uint timeout_id = 0;
                uint idle_id = 0;
                timeout_id = Timeout.add_seconds(2, () => {
                    timeout_id = 0;
                    timed_out = true;
                    loop.quit();
                    return Source.REMOVE;
                });
                idle_id = Idle.add(() => {
                    if (!((!) owner).can_use_server_assist(stream)) {
                        return Source.CONTINUE;
                    }
                    idle_id = 0;
                    if (timeout_id != 0) {
                        Source.remove(timeout_id);
                        timeout_id = 0;
                    }
                    loop.quit();
                    return Source.REMOVE;
                });
                loop.run();
                if (idle_id != 0) Source.remove(idle_id);
                fail_if(timed_out,
                    "Server-assist discovery did not settle in time");
            }
            fail_if(!((!) owner).can_use_server_assist(stream),
                "The current advertised stream must enable server assist");

            var replacement = new DisplayedStateAuditStream(
                jid("example.test"));
            add_bound_account_modules(replacement, discovery, account);
            interactor.connection_manager.set_connected_stream_for_tests(
                account, replacement);
            ((!) owner).prepare_stream(replacement);
            fail_if(((!) owner).can_use_server_assist(stream) ||
                    ((!) owner).can_use_server_assist(replacement),
                "A replacement stream must clear the previous capability");
        } catch (Error error) {
            fail_if_reached("Unexpected assist lifecycle error: " +
                error.message);
        } finally {
            if (owner != null) ((!) owner).shutdown();
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void add_bound_account_modules(XmppStream stream,
            Xep.ServiceDiscovery.Module discovery,
        Entities.Account account) {
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = jid(account.bare_jid.to_string() + "/desktop");
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream.add_module(discovery);
    }

    private void test_chat_target_uses_sender_id() {
        Entities.Account account = make_account();
        var conversation = new Entities.Conversation(
            jid("bob@example.test"), account,
            Entities.Conversation.Type.CHAT);
        Entities.Message message = make_received_message(account,
            jid("bob@example.test/phone"), Entities.Message.Type.CHAT);
        message.sender_stanza_id = "sender-id";
        message.server_id = "account-server-id";

        DisplayedMarkerTarget? target = DisplayedStateManager
            .get_xep0333_target(conversation, message);
        fail_if(target == null, "A 1:1 marker target should be available");
        if (target == null) return;
        fail_if_not_eq_str(((!) target).recipient.to_string(),
            "bob@example.test/phone",
            "1:1 XEP-0333 markers must target the sender resource");
        fail_if_not_eq_str(((!) target).message_id, "sender-id",
            "1:1 XEP-0333 markers must copy the sender's message id");
    }

    private void test_groupchat_target_uses_room_id() {
        Entities.Account account = make_account();
        var conversation = new Entities.Conversation(
            jid("room@conference.example.test"), account,
            Entities.Conversation.Type.GROUPCHAT);
        Entities.Message message = make_received_message(account,
            jid("room@conference.example.test/bob"),
            Entities.Message.Type.GROUPCHAT);
        message.stanza_id = "sender-id";
        message.server_id = "room-stable-id";
        message.set_stable_reference("room-stable-id",
            jid("room@conference.example.test"));

        DisplayedMarkerTarget? target = DisplayedStateManager
            .get_xep0333_target(conversation, message);
        fail_if(target == null,
            "A groupchat marker target should be available");
        if (target == null) return;
        fail_if_not_eq_str(((!) target).recipient.to_string(),
            "room@conference.example.test",
            "Groupchat XEP-0333 markers must target the room bare JID");
        fail_if_not_eq_str(((!) target).message_id, "room-stable-id",
            "Groupchat XEP-0333 markers must use the room-assigned id");
    }

    private void test_muc_pm_target_uses_sender_id() {
        Entities.Account account = make_account();
        var conversation = new Entities.Conversation(
            jid("room@conference.example.test/bob"), account,
            Entities.Conversation.Type.GROUPCHAT_PM);
        Entities.Message message = make_received_message(account,
            jid("room@conference.example.test/bob"),
            Entities.Message.Type.GROUPCHAT_PM);
        message.sender_stanza_id = "sender-private-id";
        message.server_id = "account-server-id";

        DisplayedMarkerTarget? target = DisplayedStateManager
            .get_xep0333_target(conversation, message);
        fail_if(target == null, "A MUC-PM marker target should be available");
        if (target == null) return;
        fail_if_not_eq_str(((!) target).recipient.to_string(),
            "room@conference.example.test/bob",
            "MUC-PM XEP-0333 markers must target the full occupant JID");
        fail_if_not_eq_str(((!) target).message_id, "sender-private-id",
            "MUC-PM is type=chat and must copy the sender's message id");
    }

    private void test_missing_reference_is_rejected() {
        Entities.Account account = make_account();
        var conversation = new Entities.Conversation(
            jid("room@conference.example.test"), account,
            Entities.Conversation.Type.GROUPCHAT);
        Entities.Message message = make_received_message(account,
            jid("room@conference.example.test/bob"),
            Entities.Message.Type.GROUPCHAT);
        message.stanza_id = "sender-controlled-id";

        fail_if(DisplayedStateManager.get_xep0333_target(conversation,
                message) != null,
            "A room marker must not fall back to a sender-controlled id");
    }

    private void test_forward_only_ordering() {
        Entities.Message current = new Entities.Message("current");
        current.id = 10;
        current.local_time = new DateTime.from_unix_utc(100);

        Entities.Message older = new Entities.Message("older");
        older.id = 99;
        older.local_time = new DateTime.from_unix_utc(90);
        fail_if(DisplayedStateManager.advances_read_pointer(current, older),
            "An older displayed marker must not move the pointer backwards");

        Entities.Message newer = new Entities.Message("newer");
        newer.id = 1;
        newer.local_time = new DateTime.from_unix_utc(110);
        fail_if_not(DisplayedStateManager.advances_read_pointer(current, newer),
            "A newer displayed marker must advance the pointer");

        Entities.Message same_second_later = new Entities.Message("later");
        same_second_later.id = 11;
        same_second_later.local_time = new DateTime.from_unix_utc(100);
        fail_if_not(DisplayedStateManager.advances_read_pointer(current,
                same_second_later),
            "Database id must break equal-second ordering ties");
        fail_if(DisplayedStateManager.advances_read_pointer(current, current),
            "A duplicate displayed marker must be ignored");
    }

    private void test_stable_reference_authority_matrix() {
        Entities.Account account = make_account();

        var chat = new Entities.Conversation(jid("bob@example.test"), account,
            Entities.Conversation.Type.CHAT);
        Entities.Message chat_message = make_received_message(account,
            jid("bob@example.test/phone"), Entities.Message.Type.CHAT);
        chat_message.set_stable_reference("account-id", account.bare_jid);
        StableStanzaReference? chat_reference =
            StableStanzaReferenceResolver.for_message(chat, chat_message);
        fail_if(chat_reference == null ||
                !((!) chat_reference).by.equals(account.bare_jid),
            "1:1 stable references must be assigned by the account server");
        fail_if_not_eq_str(StableStanzaReferenceResolver.get_chat_item_id(chat)
                .to_string(), "bob@example.test",
            "1:1 XEP-0490 item ids must be contact bare JIDs");

        var groupchat = new Entities.Conversation(
            jid("room@conference.example.test"), account,
            Entities.Conversation.Type.GROUPCHAT);
        Entities.Message group_message = make_received_message(account,
            jid("room@conference.example.test/bob"),
            Entities.Message.Type.GROUPCHAT);
        group_message.set_stable_reference("room-id",
            groupchat.counterpart);
        StableStanzaReference? group_reference =
            StableStanzaReferenceResolver.for_message(groupchat,
                group_message);
        fail_if(group_reference == null ||
                !((!) group_reference).by.equals(groupchat.counterpart),
            "Groupchat stable references must be assigned by the room");

        var muc_pm = new Entities.Conversation(
            jid("room@conference.example.test/bob"), account,
            Entities.Conversation.Type.GROUPCHAT_PM);
        fail_if_not_eq_str(StableStanzaReferenceResolver
                .get_chat_item_id(muc_pm).to_string(),
            "room@conference.example.test/bob",
            "MUC-PM XEP-0490 item ids must retain the occupant resource");
    }

    private void test_stable_reference_wrong_authority() {
        Entities.Account account = make_account();
        var groupchat = new Entities.Conversation(
            jid("room@conference.example.test"), account,
            Entities.Conversation.Type.GROUPCHAT);
        Entities.Message message = make_received_message(account,
            jid("room@conference.example.test/bob"),
            Entities.Message.Type.GROUPCHAT);
        message.set_stable_reference("account-archive-id",
            account.bare_jid);

        fail_if(StableStanzaReferenceResolver.for_message(groupchat,
                message) != null,
            "An account-archive id must not authorize a room displayed state");
    }

    private void test_stable_reference_preference() {
        Jid authority = jid("juliet@example.test");
        fail_if_not_eq_str(MessageProcessor.select_authoritative_stable_id(
                "live-sid", true, "mam-id", authority, authority),
            "live-sid",
            "A live and archived copy must converge on the embedded SID");
        fail_if_not_eq_str(MessageProcessor.select_authoritative_stable_id(
                null, false, "mam-id", authority, authority),
            "mam-id",
            "A trusted MAM result id is the fallback without an embedded SID");
        fail_if(MessageProcessor.select_authoritative_stable_id(null, false,
                "mam-id", jid("mallory@example.test"), authority) != null,
            "A MAM id from the wrong archive authority must be rejected");
    }

    private void test_markable_persistence() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-displayed-state-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        const string db_key = "displayed-state-test";
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, db_key);
            Entities.Account account = make_account();
            account.persist((!) db);

            Entities.Message message = make_received_message(account,
                jid("bob@example.test/phone"),
                Entities.Message.Type.CHAT);
            message.stanza_id = "persisted-markable-id";
            message.sender_stanza_id = "persisted-wire-id";
            message.markable = true;
            message.set_stable_reference("persisted-account-id",
                account.bare_jid);
            message.persist((!) db);
            int message_id = message.id;

            ((!) db).close();
            db = new Database(db_path, db_key);
            Entities.Message? restored = ((!) db).get_message_by_id(message_id);
            fail_if(restored == null,
                "The persisted message must survive a database reopen");
            fail_if(restored != null && !((!) restored).markable,
                "The XEP-0333 markable request must survive delayed focus");
            fail_if(restored != null &&
                    ((!) restored).sender_stanza_id != "persisted-wire-id",
                "The exact sender wire id must survive a database reopen");
            fail_if(restored != null &&
                    (((!) restored).stable_id != "persisted-account-id" ||
                    ((!) restored).stable_id_by == null ||
                    !((!) restored).stable_id_by.equals(
                        account.bare_jid)),
                "The stable id and assigning authority must persist together");
        } catch (Error error) {
            fail_if_reached("Unexpected displayed-state database error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_xep0490_global_setting_persistence() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-displayed-setting-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        const string db_key = "displayed-setting-test";
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, db_key);
            var settings = new Entities.Settings.from_db((!) db);
            fail_if(!settings.sync_displayed_state,
                "Same-account read-state sync must default to enabled");

            settings.sync_displayed_state = false;
            ((!) db).close();
            db = new Database(db_path, db_key);
            var restored = new Entities.Settings.from_db((!) db);
            fail_if(restored.sync_displayed_state,
                "The XEP-0490 privacy setting must survive a database reopen");
        } catch (Error error) {
            fail_if_reached("Unexpected displayed-state setting error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_sender_wire_id_is_separate() {
        var stanza = new MessageStanza();
        stanza.id = "  sender-wire-id\t";
        Xep.UniqueStableStanzaIDs.set_origin_id(stanza, "origin-id");
        var message = new Entities.Message("test");

        MessageProcessor.assign_sender_ids(message, stanza);
        fail_if_not_eq_str(message.sender_stanza_id,
            "  sender-wire-id\t",
            "XEP-0184/0333 must retain the exact sender wire id");
        fail_if_not_eq_str(message.stanza_id, "origin-id",
            "The canonical origin id must remain a separate reference");
    }

    private void test_groupchat_pm_uses_chat_type() {
        var message = new Entities.Message("test");
        message.type_ = Entities.Message.Type.GROUPCHAT_PM;
        fail_if_not_eq_str(message.get_type_string(),
            MessageStanza.TYPE_CHAT,
            "A MUC private message is a type=chat stanza on the wire");
    }

    private void test_response_policy_roster_matrix() {
        fail_if_not(MessageResponsePolicy.allows_roster_subscription(
                Roster.Item.SUBSCRIPTION_FROM),
            "A sender subscribed to our presence may receive responses");
        fail_if_not(MessageResponsePolicy.allows_roster_subscription(
                Roster.Item.SUBSCRIPTION_BOTH),
            "A mutual contact may receive responses");
        fail_if(MessageResponsePolicy.allows_roster_subscription(
                Roster.Item.SUBSCRIPTION_TO),
            "Our outbound-only subscription does not reveal our activity");
        fail_if(MessageResponsePolicy.allows_roster_subscription(
                Roster.Item.SUBSCRIPTION_NONE),
            "A non-contact must not receive presence-equivalent activity");
        fail_if(MessageResponsePolicy.allows_roster_subscription(null),
            "Missing roster state must fail closed");
    }

    private void test_xep0490_authority_matrix() {
        Entities.Account account = make_account();
        var direct = new Xep.MessageDisplayedSynchronization.DisplayedItem(
            jid("bob@example.test"), "direct-id", account.bare_jid);
        Entities.Conversation.Type? direct_type = DisplayedStateManager
            .get_xep0490_conversation_type(account, direct);
        fail_if(direct_type == null || (!) direct_type !=
                Entities.Conversation.Type.CHAT,
            "The account server authority must select a direct chat");

        Jid room = jid("room@conference.example.test");
        var group = new Xep.MessageDisplayedSynchronization.DisplayedItem(
            room, "room-id", room);
        Entities.Conversation.Type? group_type = DisplayedStateManager
            .get_xep0490_conversation_type(account, group);
        fail_if(group_type == null || (!) group_type !=
                Entities.Conversation.Type.GROUPCHAT,
            "The room authority must select a groupchat");

        var muc_pm = new Xep.MessageDisplayedSynchronization.DisplayedItem(
            jid("room@conference.example.test/bob"), "private-id",
            account.bare_jid);
        Entities.Conversation.Type? pm_type = DisplayedStateManager
            .get_xep0490_conversation_type(account, muc_pm);
        fail_if(pm_type == null || (!) pm_type !=
                Entities.Conversation.Type.GROUPCHAT_PM,
            "A full item JID with account authority must select a MUC PM");

        var hostile = new Xep.MessageDisplayedSynchronization.DisplayedItem(
            jid("bob@example.test"), "hostile-id",
            jid("mallory@example.test"));
        fail_if(DisplayedStateManager.get_xep0490_conversation_type(account,
                hostile) != null,
            "An unrelated authority must not select a conversation scope");

        var ambiguous = new Xep.MessageDisplayedSynchronization.DisplayedItem(
            account.bare_jid, "ambiguous-id", account.bare_jid);
        fail_if(DisplayedStateManager.get_xep0490_conversation_type(account,
                ambiguous) != null,
            "An ambiguous own-JID item must fail closed");
    }

    private void test_xep0490_publication_queue() {
        var queue = new DisplayedStatePublicationQueue();
        Entities.Message older = new Entities.Message("older");
        older.id = 10;
        older.local_time = new DateTime.from_unix_utc(100);
        Entities.Message newer = new Entities.Message("newer");
        newer.id = 11;
        newer.local_time = new DateTime.from_unix_utc(101);
        Entities.Message other = new Entities.Message("other");
        other.id = 12;
        other.local_time = new DateTime.from_unix_utc(99);

        Jid authority = jid("alice@example.test");
        queue.offer(new DisplayedStatePublication(jid("bob@example.test"),
            new StableStanzaReference("older-id", authority), older));
        queue.offer(new DisplayedStatePublication(jid("bob@example.test"),
            new StableStanzaReference("newer-id", authority), newer));
        queue.offer(new DisplayedStatePublication(jid("carol@example.test"),
            new StableStanzaReference("other-id", authority), other));
        fail_if(queue.size != 2,
            "The queue must retain one latest item per chat");

        bool found_newer = false;
        bool found_other = false;
        while (queue.size > 0) {
            DisplayedStatePublication? publication = queue.take_next();
            fail_if(publication == null,
                "A non-empty queue must return a publication");
            if (publication == null) return;
            if (((!) publication).chat.equals(jid("bob@example.test"))) {
                found_newer = ((!) publication).reference.id == "newer-id";
            } else if (((!) publication).chat.equals(
                    jid("carol@example.test"))) {
                found_other = true;
            }
        }
        fail_if_not(found_newer,
            "A newer state must replace the pending state for that chat");
        fail_if_not(found_other,
            "Coalescing one chat must not remove another chat's state");
    }

    private void test_read_state_pair_persistence() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-read-state-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "read-state-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var conversation = new Entities.Conversation(
                jid("bob@example.test"), account,
                Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            Entities.Message message = make_received_message(account,
                jid("bob@example.test/phone"), Entities.Message.Type.CHAT);
            message.persist((!) db);
            conversation.set_read_state(message, 73);

            int? persisted_message = ((!) db).conversation.select({
                    ((!) db).conversation.read_up_to })
                .with(((!) db).conversation.id, "=", conversation.id)
                .single().row().get(((!) db).conversation.read_up_to);
            int? persisted_item = ((!) db).conversation.select({
                    ((!) db).conversation.read_up_to_item })
                .with(((!) db).conversation.id, "=", conversation.id)
                .single().row().get(((!) db).conversation.read_up_to_item);
            fail_if(persisted_message == null ||
                    (!) persisted_message != message.id ||
                    persisted_item == null || (!) persisted_item != 73,
                "Both read pointers must be persisted by the same operation");
        } catch (Error error) {
            fail_if_reached("Unexpected read-state database error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_remote_read_through_not_page_limited() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-read-through-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "read-through-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var conversation = new Entities.Conversation(
                jid("bob@example.test"), account,
                Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            MessageStorage.start(interactor, (!) db);
            MessageStorage storage = interactor.get_module<MessageStorage>(
                MessageStorage.IDENTITY);

            Entities.Message? target = null;
            Entities.Message? oldest_visible = null;
            for (int i = 0; i < 350; i++) {
                Entities.Message message = make_sent_message(account,
                    jid("bob@example.test"), 100 + i);
                message.marked = i == 330
                    ? Entities.Message.Marked.SENDING
                    : Entities.Message.Marked.RECEIVED;
                storage.add_message(message, conversation);
                if (i == 0) oldest_visible = message;
                if (i == 330) target = message;
            }
            fail_if(target == null,
                "The read-through target must have been created");
            if (target == null) return;
            fail_if_not(storage.mark_sent_messages_read_through(conversation,
                    (!) target),
                "A valid outgoing target must advance remote read state");

            int64 read_count = ((!) db).message.select()
                .with(((!) db).message.account_id, "=", account.id)
                .with(((!) db).message.marked, "=",
                    Entities.Message.Marked.READ)
                .count();
            fail_if(read_count != 331,
                "Read-through must update every message before the target, " +
                "not only the newest query page");
            fail_if(oldest_visible == null || ((!) oldest_visible).marked !=
                    Entities.Message.Marked.READ,
                "An older live MessageItem must update after leaving the " +
                "300-entry strong cache");
        } catch (Error error) {
            fail_if_reached("Unexpected read-through database error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_ambiguous_sender_id_no_fallback() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-sender-id-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "sender-id-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var conversation = new Entities.Conversation(
                jid("bob@example.test"), account,
                Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            MessageStorage.start(interactor, (!) db);
            MessageStorage storage = interactor.get_module<MessageStorage>(
                MessageStorage.IDENTITY);

            for (int i = 0; i < 2; i++) {
                Entities.Message message = make_sent_message(account,
                    jid("bob@example.test"), 100 + i);
                message.sender_stanza_id = "duplicate-wire-id";
                message.stanza_id = "origin-" + i.to_string();
                storage.add_message(message, conversation);
            }
            Entities.Message legacy = make_sent_message(account,
                jid("bob@example.test"), 99);
            legacy.stanza_id = "duplicate-wire-id";
            storage.add_message(legacy, conversation);

            fail_if(storage.get_message_by_sender_stanza_id(
                    "duplicate-wire-id", conversation,
                    Entities.Message.DIRECTION_SENT) != null,
                "An ambiguous exact sender id must fail closed without " +
                "falling back to a legacy row");
        } catch (Error error) {
            fail_if_reached("Unexpected sender-id database error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_sender_id_lookup_is_direction_scoped() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-sender-direction-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "sender-direction-test");
            Entities.Account account = make_account();
            account.persist((!) db);
            var conversation = new Entities.Conversation(
                jid("bob@example.test"), account,
                Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            MessageStorage.start(interactor, (!) db);
            MessageStorage storage = interactor.get_module<MessageStorage>(
                MessageStorage.IDENTITY);

            Entities.Message sent = make_sent_message(account,
                jid("bob@example.test"), 100);
            sent.sender_stanza_id = "same-wire-id";
            sent.marked = Entities.Message.Marked.SENT;
            storage.add_message(sent, conversation);

            Entities.Message received = make_received_message(account,
                jid("bob@example.test/phone"), Entities.Message.Type.CHAT);
            received.sender_stanza_id = "same-wire-id";
            received.local_time = new DateTime.from_unix_utc(101);
            storage.add_message(received, conversation);

            Entities.Message? sent_match = storage
                .get_message_by_sender_stanza_id("same-wire-id",
                    conversation, Entities.Message.DIRECTION_SENT);
            Entities.Message? received_match = storage
                .get_message_by_sender_stanza_id("same-wire-id",
                    conversation, Entities.Message.DIRECTION_RECEIVED);
            fail_if(sent_match == null || ((!) sent_match).id != sent.id,
                "A receipt must resolve the outgoing message only");
            fail_if(sent_match != sent,
                "A receipt lookup must retain the live Message instance " +
                "observed by the conversation UI");
            fail_if(received_match == null ||
                    ((!) received_match).id != received.id,
                "An own displayed marker must resolve the incoming message only");
            fail_if(received_match != received,
                "A displayed lookup must retain the live Message instance " +
                "observed by the conversation UI");

            ((!) sent_match).marked = Entities.Message.Marked.RECEIVED;
            fail_if(sent.marked != Entities.Message.Marked.RECEIVED,
                "Applying an XEP-0184 receipt must update the live UI object");
            fail_if_not(storage.mark_sent_messages_read_through(conversation,
                    (!) sent_match),
                "Applying an XEP-0333 marker must advance the sent message");
            fail_if(sent.marked != Entities.Message.Marked.READ,
                "Applying an XEP-0333 marker must update the live UI object");
        } catch (Error error) {
            fail_if_reached("Unexpected direction lookup database error: " +
                error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private Entities.Account make_account() {
        return new Entities.Account(jid("alice@example.test"), "secret");
    }

    private Entities.Message make_received_message(Entities.Account account,
            Jid sender, Entities.Message.Type type) {
        var message = new Entities.Message("test");
        message.account = account;
        message.counterpart = sender;
        message.ourpart = jid("alice@example.test/desktop");
        message.direction = Entities.Message.DIRECTION_RECEIVED;
        message.type_ = type;
        message.time = new DateTime.from_unix_utc(100);
        message.local_time = new DateTime.from_unix_utc(100);
        return message;
    }

    private Entities.Message make_sent_message(Entities.Account account,
            Jid counterpart, int64 timestamp) {
        var message = new Entities.Message("test");
        message.account = account;
        message.counterpart = counterpart;
        message.ourpart = jid("alice@example.test/desktop");
        message.direction = Entities.Message.DIRECTION_SENT;
        message.type_ = Entities.Message.Type.CHAT;
        message.time = new DateTime.from_unix_utc(timestamp);
        message.local_time = new DateTime.from_unix_utc(timestamp);
        return message;
    }

    private Entities.Message make_sent_groupchat_message(
            Entities.Account account, Jid room, int64 timestamp) {
        Entities.Message message = make_sent_message(account, room,
            timestamp);
        message.type_ = Entities.Message.Type.GROUPCHAT;
        return message;
    }

    private Jid jid(string value) {
        try {
            return new Jid(value);
        } catch (InvalidJidError error) {
            GLib.error("Invalid fixed test JID '%s': %s", value,
                error.message);
        }
    }
}

private class DisplayedStateAssistCapsCache : Object,
        Xep.ServiceDiscovery.CapsCache {
    public async bool has_entity_feature(Jid jid, string feature) {
        return feature ==
            Xep.MessageDisplayedSynchronization.SERVER_ASSIST_FEATURE;
    }

    public async Gee.Set<Xep.ServiceDiscovery.Identity>
            get_entity_identities(Jid jid) {
        return new Gee.HashSet<Xep.ServiceDiscovery.Identity>(
            Xep.ServiceDiscovery.Identity.hash_func,
            Xep.ServiceDiscovery.Identity.equals_func);
    }
}

private class DisplayedStateAuditStream : XmppStream {
    public DisplayedStateAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("audit stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
    }

    public override async void setup() throws IOError {
    }
}

private class DisplayedMarkerDelayedAuditStream : XmppStream {
    public signal void write_completed();

    public DisplayedMarkerDelayedAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("delayed audit stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        Idle.add(write_async.callback);
        yield;
        write_completed();
    }

    public override async void setup() throws IOError {
    }
}

private class DisplayedStateCatchupAuditStream : XmppStream {
    private const string NS_MDS = "urn:xmpp:mds:displayed:0";
    private const string NS_SID = "urn:xmpp:sid:0";

    public signal void fetch_response_settled();
    public Gee.ArrayList<StanzaNode> written_nodes =
        new Gee.ArrayList<StanzaNode>();

    public DisplayedStateCatchupAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("catch-up audit stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        written_nodes.add(node);

        Idle.add(() => {
            var item = new StanzaNode.build("item", Xep.Pubsub.NS_URI)
                .put_attribute("id", "bob@example.test")
                .put_node(new StanzaNode.build("displayed", NS_MDS)
                    .add_self_xmlns()
                    .put_node(new StanzaNode.build("stanza-id", NS_SID)
                        .add_self_xmlns()
                        .put_attribute("id", "stable-1")
                        .put_attribute("by", "alice@example.test")));
            var response = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("id", node.get_attribute("id"))
                .put_attribute("type", "result")
                .put_attribute("from", "alice@example.test")
                .put_node(new StanzaNode.build("pubsub", Xep.Pubsub.NS_URI)
                    .add_self_xmlns()
                    .put_node(new StanzaNode.build("items",
                            Xep.Pubsub.NS_URI)
                        .put_attribute("node", NS_MDS)
                        .put_node(item)));
            received_iq_stanza(this, response);
            Idle.add(() => {
                fetch_response_settled();
                return Source.REMOVE;
            });
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

}
