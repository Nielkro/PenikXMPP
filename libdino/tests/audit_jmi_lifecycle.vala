using Xmpp;
using Dino.Entities;

namespace Dino.Test {

private class AuditJmiOwner : Object {
}

class JmiLifecycleAudit : Gee.TestCase {
    public JmiLifecycleAudit() {
        base("JmiLifecycleAudit");
        add_test("jmi_live_registry_is_account_peer_sid_scoped",
            test_jmi_live_registry_scope);
        add_test("jmi_live_registry_claims_actions_idempotently",
            test_jmi_live_registry_action_claims);
        add_test("jmi_proceed_requires_live_full_resource_selection",
            test_jmi_proceed_routing);
        add_test("jmi_terminal_replay_is_exact_expiring_and_bounded",
            test_jmi_terminal_replay);
        add_test("jmi_incoming_authorization_requires_presence_visibility",
            test_jmi_incoming_authorization);
        add_test("jmi_received_carbon_defers_native_engine",
            test_jmi_incoming_engine_policy);
        add_test("jmi_tie_break_uses_octet_sid_then_jid",
            test_jmi_tie_break_ordering);
        add_test("jmi_offline_feature_lookup_is_account_scoped",
            test_jmi_offline_feature_account_scope);
        add_test("jmi_archive_terminal_state_survives_persistence",
            test_jmi_archive_terminal_state_persistence);
        add_test("jmi_recovered_proposal_survives_process_restart",
            test_jmi_recovered_proposal_restart_persistence);
        add_test("jmi_recovered_proposal_conflict_rolls_back_all_sids",
            test_jmi_recovered_proposal_conflict_rollback);
        add_test("jmi_archive_replay_is_order_independent_and_passive",
            test_jmi_archive_replay_ordering);
        add_test("jmi_archive_replay_recovers_current_proposal_passively",
            test_jmi_archive_replay_actionable_proposal);
        add_test("jmi_cross_device_accept_blocks_persisted_recovery",
            test_jmi_cross_device_accept_blocks_persisted_recovery);
        add_test("jmi_archive_replay_is_stream_fenced_and_bounded",
            test_jmi_archive_replay_fencing);
        add_test("jmi_archive_terminal_survives_observation_pressure",
            test_jmi_archive_terminal_retention);
        add_test("jmi_late_proposal_retains_finish_under_pressure",
            test_jmi_late_proposal_terminal_retention);
        add_test("jmi_late_proposal_selects_matching_finish_after_resource_flood",
            test_jmi_late_proposal_matching_finish_resource_flood);
        add_test("jmi_observation_truncation_blocks_uncertain_actionable",
            test_jmi_observation_truncation_blocks_actionable);
        add_test("jmi_entry_overflow_blocks_actionable_but_keeps_terminal",
            test_jmi_entry_overflow_blocks_actionable);
        add_test("jmi_migration_settlement_orders_actionable_first",
            test_jmi_migration_settlement_ordering);
        add_test("jmi_active_migration_transfers_one_direct_owner",
            test_jmi_active_migration_owner_transfer);
        add_test("jmi_migration_excludes_every_muji_transition_owner",
            test_jmi_migration_excludes_muji_transitions);
        add_test("direct_jmi_setup_timeout_excludes_legacy_and_muji",
            test_direct_jmi_setup_timeout_boundary);
    }

    private void test_jmi_live_registry_scope() {
        try {
            var registry = new JmiLiveSessionRegistry();
            var account = new Account(new Jid("alice@example.test"),
                "secret");
            var other_account = new Account(
                new Jid("alice@other.example.test"), "secret");
            Jid peer = new Jid("bob@example.test/phone");
            Jid source = new Jid("bob@example.test/phone");
            var owner = new AuditJmiOwner();

            fail_if(registry.inspect_proposal(account, peer, "sid-1",
                    source) != JmiProposalDisposition.NEW,
                "A fresh account/peer/SID tuple must be claimable");
            JmiLiveSessionEntry? entry = registry.register(account, peer,
                "sid-1", source, account.full_jid, true, owner);
            fail_if(entry == null || registry.size != 1,
                "Registering a fresh JMI tuple must create one owner");
            fail_if(registry.inspect_proposal(account, peer, "sid-1",
                    source) != JmiProposalDisposition.DUPLICATE,
                "A live/Carbon replay from the same full source must be a duplicate");
            fail_if(registry.inspect_proposal(account, peer, "sid-1",
                    new Jid("bob@example.test/tablet")) !=
                    JmiProposalDisposition.CONFLICT,
                "The same tuple from another full resource must fail closed");
            fail_if(registry.inspect_proposal(account,
                    new Jid("mallory@example.test"), "sid-1",
                    new Jid("mallory@example.test/device")) !=
                    JmiProposalDisposition.CONFLICT,
                "One account must not bind the same SID to another peer");
            fail_if(registry.inspect_proposal(account, peer, "sid-2",
                    source) != JmiProposalDisposition.CONFLICT,
                "One account/peer may own only one live JMI SID");
            fail_if(registry.inspect_proposal(other_account, peer, "sid-1",
                    source) != JmiProposalDisposition.NEW,
                "The same SID on another account must remain independently scoped");

            JmiLiveSessionEntry? found = registry.find(account,
                peer.bare_jid, "sid-1");
            fail_if(found == null || ((!) found).owner != owner,
                "Exact lookup must retain the registered owner");
            bool ambiguous;
            JmiLiveSessionEntry? own_action = registry.find_unique_by_sid(
                account, "sid-1", true, out ambiguous);
            fail_if(ambiguous || own_action == null ||
                    ((!) own_action).owner != owner,
                "An own-resource action must resolve one incoming owner only");

            registry.remove_owner(owner);
            fail_if(registry.size != 0 || registry.tombstone_size != 1,
                "Terminal owner removal must release live ownership and retain one replay fence");
            fail_if(registry.inspect_proposal(account, peer, "sid-1",
                    source) != JmiProposalDisposition.TERMINAL,
                "A delayed proposal replay must remain suppressed after terminal cleanup");
        } catch (Error e) {
            fail_if_reached("Static JMI registry JID is invalid: %s".printf(
                e.message));
        }
    }

    private void test_jmi_live_registry_action_claims() {
        try {
            var registry = new JmiLiveSessionRegistry();
            var account = new Account(new Jid("alice@example.test"),
                "secret");
            var owner = new AuditJmiOwner();
            Jid peer_bare = new Jid("bob@example.test");
            Jid phone = new Jid("bob@example.test/phone");
            Jid tablet = new Jid("bob@example.test/tablet");
            Jid other_local = account.bare_jid.with_resource("tablet");
            JmiLiveSessionEntry? maybe_entry = registry.register(account,
                peer_bare, "sid-2", account.full_jid, peer_bare, false,
                owner);
            fail_if(maybe_entry == null,
                "Action-claim test requires one registered owner");
            JmiLiveSessionEntry entry = (!) maybe_entry;

            fail_if(!entry.pre_proceed_external_action_matches(
                        Xep.JingleMessageInitiation.Action.RINGING,
                        phone, account.full_jid) ||
                    entry.pre_proceed_external_action_matches(
                        Xep.JingleMessageInitiation.Action.RINGING,
                        phone, other_local),
                "Pre-proceed actions must stay bound to the proposal's local owner");
            fail_if(!entry.claim_outgoing_ringing() ||
                    entry.claim_outgoing_ringing(),
                "An incoming device must publish ringing only once");
            fail_if(!entry.claim_action_once(
                        Xep.JingleMessageInitiation.Action.PROCEED) ||
                    entry.claim_action_once(
                        Xep.JingleMessageInitiation.Action.PROCEED),
                "A live/Carbon proceed duplicate must be claimed once");
            fail_if(!entry.claim_action_from_source(
                        Xep.JingleMessageInitiation.Action.RINGING, phone) ||
                    entry.claim_action_from_source(
                        Xep.JingleMessageInitiation.Action.RINGING, phone) ||
                    !entry.claim_action_from_source(
                        Xep.JingleMessageInitiation.Action.RINGING, tablet),
                "Ringing must deduplicate one source without hiding another device");

            fail_if(!entry.reserve_local_proceed(phone, account.full_jid) ||
                    entry.reserve_local_proceed(tablet, account.full_jid) ||
                    !entry.commit_local_proceed(phone, account.full_jid),
                "Proceed must reserve and commit one exact peer/local endpoint pair");
            fail_if(!entry.selected_external_action_matches(phone,
                        account.full_jid) ||
                    entry.selected_external_action_matches(tablet,
                        account.full_jid) ||
                    entry.selected_external_action_matches(phone,
                        other_local) ||
                    !entry.selected_own_action_matches(account.full_jid,
                        phone) ||
                    entry.selected_own_action_matches(other_local, phone) ||
                    entry.pre_proceed_external_action_matches(
                        Xep.JingleMessageInitiation.Action.REJECT,
                        phone, account.full_jid),
                "After proceed, terminal ownership must remain bound to both selected full JIDs");

            var incoming_owner = new AuditJmiOwner();
            JmiLiveSessionEntry? maybe_incoming = registry.register(account,
                new Jid("carol@example.test"), "sid-incoming",
                new Jid("carol@example.test/phone"), account.bare_jid,
                true, incoming_owner);
            fail_if(maybe_incoming == null,
                "Incoming endpoint test requires one registered owner");
            JmiLiveSessionEntry incoming = (!) maybe_incoming;
            fail_if(!incoming.pre_proceed_external_action_matches(
                        Xep.JingleMessageInitiation.Action.RETRACT,
                        new Jid("carol@example.test/phone"),
                        account.bare_jid) ||
                    incoming.pre_proceed_external_action_matches(
                        Xep.JingleMessageInitiation.Action.RETRACT,
                        new Jid("carol@example.test/tablet"),
                        account.bare_jid) ||
                    !incoming.own_incoming_response_matches(other_local,
                        new Jid("carol@example.test/phone")) ||
                    incoming.own_incoming_response_matches(other_local,
                        new Jid("carol@example.test/tablet")),
                "Incoming retract and own-device responses must match the exact proposer resource");
        } catch (Error e) {
            fail_if_reached("Static JMI registry JID is invalid: %s".printf(
                e.message));
        }
    }

    private void test_jmi_proceed_routing() {
        try {
            var account = new Account(new Jid("alice@example.test"),
                "secret");
            Jid peer_full = new Jid("bob@example.test/phone");
            Jid peer_bare = peer_full.bare_jid;
            Jid local_full = account.full_jid;
            Jid local_bare = account.bare_jid;
            Jid other_local_resource = account.bare_jid.with_resource(
                "other-device");

            Jid? current = JmiProceedRouting.select_destination(account,
                peer_full, local_full,
                Xep.JingleMessageInitiation.Delivery.LIVE, true);
            fail_if(current == null || !((!) current).equals(local_full),
                "A live current full-JID proceed must select this process");

            Jid? legacy = JmiProceedRouting.select_destination(account,
                peer_full, local_bare,
                Xep.JingleMessageInitiation.Delivery.LIVE, true);
            fail_if(legacy == null || !((!) legacy).equals(local_full),
                "A directly delivered legacy bare target must normalize to the local full JID");

            fail_if(JmiProceedRouting.select_destination(account,
                    peer_bare, local_full,
                    Xep.JingleMessageInitiation.Delivery.LIVE, true) != null,
                "A bare peer sender must never select a Jingle resource");
            fail_if(JmiProceedRouting.select_destination(account,
                    peer_full, local_bare,
                    Xep.JingleMessageInitiation.Delivery.CARBON_RECEIVED,
                    true) != null ||
                    JmiProceedRouting.select_destination(account,
                        peer_full, local_full,
                        Xep.JingleMessageInitiation.Delivery.CARBON_SENT,
                        true) != null,
                "A Carboned proceed must not start media on another device");
            fail_if(JmiProceedRouting.select_destination(account,
                    peer_full, other_local_resource,
                    Xep.JingleMessageInitiation.Delivery.LIVE, true) != null,
                "A proceed addressed to another full resource must remain there");
            fail_if(JmiProceedRouting.select_destination(account,
                    peer_full, local_full,
                    Xep.JingleMessageInitiation.Delivery.LIVE, false) != null,
                "A mirrored outgoing call must never acquire media ownership");
        } catch (Error e) {
            fail_if_reached("Static JMI routing JID is invalid: %s".printf(
                e.message));
        }
    }

    private void test_jmi_terminal_replay() {
        try {
            var registry = new JmiLiveSessionRegistry(3, TimeSpan.SECOND);
            var account = new Account(new Jid("alice@example.test"),
                "secret");
            var other_account = new Account(
                new Jid("alice@other.example.test"), "secret");
            Jid peer = new Jid("bob@example.test/phone");
            Jid source = new Jid("bob@example.test/phone");
            int64 before = GLib.get_monotonic_time();

            registry.remember_terminal(account, peer, "terminal-1", source);
            fail_if(registry.inspect_proposal(account, peer, "terminal-1",
                        source) != JmiProposalDisposition.TERMINAL ||
                    registry.inspect_proposal(account, peer, "terminal-1",
                        new Jid("bob@example.test/tablet")) !=
                        JmiProposalDisposition.TERMINAL,
                "Terminal replay fences must reject both exact and conflicting SID reuse");
            fail_if(registry.inspect_proposal(other_account, peer,
                        "terminal-1", source) != JmiProposalDisposition.NEW,
                "Terminal replay fences must remain account scoped");

            for (int i = 2; i <= 5; i++) {
                registry.remember_terminal(account, peer,
                    "terminal-%d".printf(i), source);
            }
            fail_if(registry.tombstone_size != 3,
                "The JMI terminal registry must evict old entries at its bound");
            fail_if(registry.inspect_proposal(account, peer, "terminal-1",
                        source) != JmiProposalDisposition.NEW,
                "The oldest replay fence must be evicted deterministically");

            registry.purge_expired_tombstones_for_test(before +
                2 * TimeSpan.SECOND);
            fail_if(registry.tombstone_size != 0,
                "Expired JMI replay fences must release retained account/JID state");
        } catch (Error e) {
            fail_if_reached("Static JMI replay JID is invalid: %s".printf(
                e.message));
        }
    }

    private void test_jmi_incoming_authorization() {
        fail_if(!JmiIncomingAuthorization.is_allowed(false,
                    Roster.Item.SUBSCRIPTION_FROM) ||
                !JmiIncomingAuthorization.is_allowed(false,
                    Roster.Item.SUBSCRIPTION_BOTH),
            "Contacts allowed to see our presence may initiate a JMI call");
        fail_if(JmiIncomingAuthorization.is_allowed(true,
                    Roster.Item.SUBSCRIPTION_BOTH) ||
                JmiIncomingAuthorization.is_allowed(false,
                    Roster.Item.SUBSCRIPTION_TO) ||
                JmiIncomingAuthorization.is_allowed(false,
                    Roster.Item.SUBSCRIPTION_NONE) ||
                JmiIncomingAuthorization.is_allowed(false, null),
            "Blocked or unauthorised contacts must not allocate call UI or media");
    }

    private void test_jmi_incoming_engine_policy() {
        fail_if(!JmiIncomingEnginePolicy.attach_on_proposal(false,
                    Xep.JingleMessageInitiation.Delivery.LIVE),
            "A directly selected live incoming proposal may prepare its native session");
        fail_if(JmiIncomingEnginePolicy.attach_on_proposal(false,
                    Xep.JingleMessageInitiation.Delivery.CARBON_RECEIVED) ||
                JmiIncomingEnginePolicy.attach_on_proposal(false,
                    Xep.JingleMessageInitiation.Delivery.CARBON_SENT) ||
                JmiIncomingEnginePolicy.attach_on_proposal(false,
                    Xep.JingleMessageInitiation.Delivery.MAM) ||
                JmiIncomingEnginePolicy.attach_on_proposal(true,
                    Xep.JingleMessageInitiation.Delivery.LIVE),
            "Carbons, archives and own-resource mirrors must not allocate a native worker on proposal");
    }

    private void test_jmi_tie_break_ordering() {
        try {
            Jid lower_jid = new Jid("alice@example.test/A");
            Jid higher_jid = new Jid("bob@example.test/Z");
            fail_if(JmiTieBreak.compare("0001", higher_jid, "0002",
                        lower_jid) >= 0 ||
                    JmiTieBreak.compare("0002", lower_jid, "0001",
                        higher_jid) <= 0,
                "The lower SID must win independently of JID order");
            fail_if(JmiTieBreak.compare("same", lower_jid, "same",
                        higher_jid) >= 0 ||
                    JmiTieBreak.compare("same", higher_jid, "same",
                        lower_jid) <= 0,
                "Equal SIDs must fall back to bytewise full-JID order");
            fail_if(JmiTieBreak.compare("same", lower_jid, "same",
                        lower_jid) != 0,
                "Identical proposal identities must compare equal");
        } catch (Error e) {
            fail_if_reached("Static JMI tie-break JID is invalid: %s".printf(
                e.message));
        }
    }

    private void test_jmi_offline_feature_account_scope() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-jmi-account-scope-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "jmi-account-scope-audit");
            var first = new Account(new Jid("first@example.test"), "secret");
            var second = new Account(new Jid("second@example.test"), "secret");
            first.persist((!) db);
            second.persist((!) db);
            Jid peer = new Jid("peer@example.test/phone");
            const string CAPS = "jmi-account-scope-caps";

            ((!) db).entity.upsert()
                .value<int>(((!) db).entity.account_id, first.id, true)
                .value<int>(((!) db).entity.jid_id,
                    ((!) db).get_jid_id(peer), true)
                .value<string>(((!) db).entity.resource,
                    (!) peer.resourcepart, true)
                .value<string>(((!) db).entity.caps_hash, CAPS)
                .value<long>(((!) db).entity.last_seen,
                    (long) (new DateTime.now_utc()).to_unix())
                .perform();
            ((!) db).entity_feature.insert()
                .value<string>(((!) db).entity_feature.entity, CAPS)
                .value<string>(((!) db).entity_feature.feature,
                    Xep.JingleMessageInitiation.NS_URI)
                .perform();

            fail_if(!EntityInfo.has_any_resource_feature_in_database((!) db,
                        first, peer.bare_jid,
                        Xep.JingleMessageInitiation.NS_URI) ||
                    EntityInfo.has_any_resource_feature_in_database((!) db,
                        second, peer.bare_jid,
                        Xep.JingleMessageInitiation.NS_URI),
                "Cached JMI resources must never leak between accounts sharing a peer JID");
        } catch (Error e) {
            fail_if_reached("Unexpected JMI account-scope audit error: %s"
                .printf(e.message));
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jmi_archive_terminal_state_persistence() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-jmi-terminal-persistence-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "jmi-terminal-persistence-audit");
            var account = new Account(new Jid("archive@example.test"),
                "secret");
            account.persist((!) db);
            Jid peer = new Jid("peer@example.test/phone");
            DateTime timestamp = new DateTime.now_utc();

            var call = new Entities.Call();
            call.account = account;
            call.counterpart = peer;
            call.ourpart = account.full_jid;
            call.direction = Entities.Call.DIRECTION_INCOMING;
            call.time = call.local_time = timestamp;
            call.end_time = timestamp.add_seconds(10);
            call.encryption = Encryption.UNKNOWN;
            call.state = Entities.Call.State.MISSED;
            call.add_peer(peer);
            call.persist((!) db);
            var call_sids = new Gee.ArrayList<string>();
            call_sids.add("archive-sid-old");
            call_sids.add("archive-sid-new");
            fail_if(!CallStore.claim_jmi_sids_in_database((!) db, call,
                        call_sids),
                "A fresh persisted call must atomically claim all JMI identities");

            Qlite.RowOption persisted = ((!) db).call.select()
                .with(((!) db).call.id, "=", call.id)
                .single().row();
            fail_if(!persisted.is_present() ||
                    persisted.inner[((!) db).call.state] !=
                        (int) Entities.Call.State.MISSED,
                "A passive JMI archive projection must retain its terminal state after restart");
            fail_if(((!) db).call_jmi_sid.select()
                        .with(((!) db).call_jmi_sid.account_id, "=",
                            account.id)
                        .with(((!) db).call_jmi_sid.call_id, "=", call.id)
                        .count() != 2,
                "Every migrated JMI SID must persist against the same call row");

            var reloaded = new Entities.Call.from_row((!) db,
                persisted.inner);
            fail_if(!reloaded.owns_jmi_sid("archive-sid-old") ||
                    !reloaded.owns_jmi_sid("archive-sid-new"),
                "Persisted JMI lifecycle identities must survive a restart");

            var duplicate = new Entities.Call();
            duplicate.account = account;
            duplicate.counterpart = peer;
            duplicate.ourpart = account.full_jid;
            duplicate.direction = Entities.Call.DIRECTION_INCOMING;
            duplicate.time = duplicate.local_time = timestamp.add_seconds(1);
            duplicate.end_time = timestamp.add_seconds(2);
            duplicate.encryption = Encryption.UNKNOWN;
            duplicate.state = Entities.Call.State.MISSED;
            duplicate.add_peer(peer);
            duplicate.persist((!) db);
            var duplicate_sid = new Gee.ArrayList<string>();
            duplicate_sid.add("archive-sid-partial");
            duplicate_sid.add("archive-sid-old");
            fail_if(CallStore.claim_jmi_sids_in_database((!) db, duplicate,
                        duplicate_sid) ||
                    duplicate.owns_jmi_sid("archive-sid-old") ||
                    duplicate.owns_jmi_sid("archive-sid-partial"),
                "A conflicting JMI identity must roll back the complete claim before changing in-memory state");
            fail_if(((!) db).call_jmi_sid.select()
                        .with(((!) db).call_jmi_sid.account_id, "=",
                            account.id)
                        .with(((!) db).call_jmi_sid.sid, "=",
                            "archive-sid-old")
                        .count() != 1,
                "An account/SID replay must not acquire a second database owner");
            fail_if(((!) db).call_jmi_sid.select()
                        .with(((!) db).call_jmi_sid.account_id, "=",
                            account.id)
                        .with(((!) db).call_jmi_sid.sid, "=",
                            "archive-sid-partial")
                        .count() != 0,
                "An earlier SID insert in a failed multi-claim must be rolled back atomically");
        } catch (Error e) {
            fail_if_reached("Unexpected JMI terminal-persistence audit error: %s"
                .printf(e.message));
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jmi_recovered_proposal_restart_persistence() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-jmi-proposal-restart-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        const string DB_KEY = "jmi-proposal-restart-audit";
        Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, DB_KEY);
            var account = new Account(new Jid("restart@example.test"),
                "secret");
            account.persist((!) db);
            Jid peer = new Jid("peer@example.test/phone");
            var conversation = new Entities.Conversation(peer.bare_jid,
                account, Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);
            DateTime started_at = new DateTime.now_utc().add_minutes(-10);
            DateTime expires_at = started_at.add_hours(1);

            var call = new Entities.Call();
            call.account = account;
            call.counterpart = peer;
            call.ourpart = account.full_jid;
            call.direction = Entities.Call.DIRECTION_INCOMING;
            call.time = call.local_time = started_at;
            call.end_time = expires_at;
            call.encryption = Encryption.UNKNOWN;
            call.state = Entities.Call.State.RINGING;
            call.add_peer(peer);
            call.persist((!) db);
            var sid = new Gee.ArrayList<string>();
            sid.add("restart-sid");
            fail_if(!CallStore.claim_jmi_sids_in_database((!) db, call, sid),
                "A restart-safe proposal must own its persisted JMI SID");

            var store = new JmiRecoveredProposalStore((!) db);
            fail_if(!store.save_with_sids(call, conversation, "restart-sid",
                        peer, account.full_jid, started_at, expires_at, true,
                        true, sid),
                "A current passive JMI proposal must be stored before publication");
            int account_id = account.id;
            int call_id = call.id;
            int conversation_id = conversation.id;

            ((!) db).close();
            db = new Database(db_path, DB_KEY);
            Account restored_account = ((!) db).get_account_by_id(account_id);
            var restored_store = new JmiRecoveredProposalStore((!) db);
            Gee.List<JmiRecoveredProposalRecord> records =
                restored_store.load(restored_account);
            fail_if(records.size != 1 || records[0].call_id != call_id ||
                    records[0].conversation_id != conversation_id ||
                    records[0].sid != "restart-sid" ||
                    records[0].proposal_source != peer.to_string() ||
                    records[0].proposal_target !=
                        account.full_jid.to_string() ||
                    records[0].started_at != started_at.to_unix() ||
                    records[0].expires_at != expires_at.to_unix() ||
                    !records[0].audio_requested ||
                    !records[0].video_requested ||
                    records[0].build_descriptions().size != 2,
                "A process restart must retain the exact proposal roles, media and expiry deadline");

            Qlite.RowOption persisted_call = ((!) db).call.select()
                .with(((!) db).call.id, "=", call_id)
                .single().row();
            fail_if(!persisted_call.is_present() ||
                    persisted_call.inner[((!) db).call.state] !=
                        (int) Entities.Call.State.ENDED,
                "The ordinary call row must remain a non-actionable history projection after restart");
            fail_if(((!) db).call_jmi_sid.select()
                        .with(((!) db).call_jmi_sid.account_id, "=",
                            account_id)
                        .with(((!) db).call_jmi_sid.sid, "=", "restart-sid")
                        .with(((!) db).call_jmi_sid.call_id, "=", call_id)
                        .count() != 1,
                "Restart recovery must retain exactly one SID owner");
            var restored_call = new Entities.Call.from_row((!) db,
                persisted_call.inner);
            fail_if(!restored_store.owns(restored_call, "restart-sid"),
                "Only the dedicated restart record may make terminal-looking call history actionable");
            restored_store.remove(restored_call);
            fail_if(restored_store.owns(restored_call, "restart-sid"),
                "Removing the restart record must permanently fence a later archived proposal");
        } catch (Error e) {
            fail_if_reached("Unexpected JMI proposal-restart audit error: %s"
                .printf(e.message));
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jmi_recovered_proposal_conflict_rollback() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-jmi-proposal-conflict-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "jmi-proposal-conflict-audit");
            var account = new Account(new Jid("conflict@example.test"),
                "secret");
            account.persist((!) db);
            Jid peer = new Jid("peer@example.test/phone");
            var conversation = new Entities.Conversation(peer.bare_jid,
                account, Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);
            DateTime started_at = new DateTime.now_utc().add_minutes(-5);
            DateTime expires_at = started_at.add_hours(1);
            var store = new JmiRecoveredProposalStore((!) db);

            var candidate_call = new Entities.Call();
            candidate_call.account = account;
            candidate_call.counterpart = peer;
            candidate_call.ourpart = account.full_jid;
            candidate_call.direction = Entities.Call.DIRECTION_INCOMING;
            candidate_call.time = candidate_call.local_time =
                started_at.add_seconds(1);
            candidate_call.end_time = expires_at;
            candidate_call.encryption = Encryption.UNKNOWN;
            candidate_call.state = Entities.Call.State.RINGING;
            candidate_call.add_peer(peer);
            candidate_call.persist((!) db);
            var baseline_sids = new Gee.ArrayList<string>();
            baseline_sids.add("candidate-existing-sid");
            fail_if(!store.save_with_sids(candidate_call, conversation,
                        "candidate-existing-sid", peer, account.full_jid,
                        started_at, expires_at, true, false, baseline_sids),
                "The candidate baseline proposal must be persisted before the conflicting update");

            var requested_sids = new Gee.ArrayList<string>();
            requested_sids.add("candidate-new-primary-sid");
            requested_sids.add("candidate-new-secondary-sid");
            fail_if(store.save_with_sids(candidate_call, conversation,
                        "candidate-new-primary-sid", peer, account.full_jid,
                        started_at.add_seconds(1), expires_at, true, false,
                        requested_sids),
                "A second primary SID must conflict with the existing proposal row");

            Gee.List<string> candidate_sids =
                candidate_call.snapshot_jmi_sids();
            fail_if(candidate_sids.size != 1 ||
                    !candidate_sids.contains("candidate-existing-sid") ||
                    candidate_sids.contains("candidate-new-primary-sid") ||
                    candidate_sids.contains("candidate-new-secondary-sid"),
                "A failed aggregate save must leave Call SID memory unchanged");
            fail_if(((!) db).call_jmi_sid.select()
                        .with(((!) db).call_jmi_sid.account_id, "=",
                            account.id)
                        .with(((!) db).call_jmi_sid.sid, "=",
                            "candidate-new-primary-sid")
                        .count() != 0,
                "A proposal conflict must roll back the newly staged primary SID");
            fail_if(((!) db).call_jmi_sid.select()
                        .with(((!) db).call_jmi_sid.account_id, "=",
                            account.id)
                        .with(((!) db).call_jmi_sid.sid, "=",
                            "candidate-new-secondary-sid")
                        .count() != 0,
                "A proposal conflict must roll back the newly staged secondary SID");
            fail_if(((!) db).call_jmi_sid.select()
                        .with(((!) db).call_jmi_sid.account_id, "=",
                            account.id)
                        .with(((!) db).call_jmi_sid.call_id, "=",
                            candidate_call.id)
                        .with(((!) db).call_jmi_sid.sid, "=",
                            "candidate-existing-sid")
                        .count() != 1,
                "Aggregate rollback must not remove a previously committed SID");
            fail_if(((!) db).call_jmi_proposal.select()
                        .with(((!) db).call_jmi_proposal.call_id, "=",
                            candidate_call.id)
                        .with(((!) db).call_jmi_proposal.sid, "=",
                            "candidate-existing-sid")
                        .count() != 1 ||
                    !store.owns(candidate_call, "candidate-existing-sid") ||
                    store.owns(candidate_call, "candidate-new-primary-sid"),
                "A failed aggregate save must retain only the baseline proposal row");
        } catch (Error e) {
            fail_if_reached("Unexpected JMI proposal-conflict audit error: %s"
                .printf(e.message));
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jmi_archive_replay_ordering() {
        Account account;
        Jid own;
        Jid peer;
        try {
            account = new Account(new Jid("alice@example.test"), "secret");
            own = new Jid("alice@example.test/desktop");
            peer = new Jid("bob@example.test/phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static JMI archive JID is invalid: %s".printf(
                e.message));
            return;
        }

        var registry = new JmiArchiveReplayRegistry(8, 3600);
        var stream = new Object();
        DateTime now = new DateTime.now_utc();
        registry.begin_stream(account, stream);

        // Deliberately observe the terminal page before the proposal page.
        fail_if(!registry.observe_archive(account, stream, peer, own,
                    "archive-sid", Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-5), false) ||
                !registry.observe_archive(account, stream, peer, own,
                    "archive-sid", Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-60), true) ||
                !registry.observe_archive(account, stream, own, peer,
                    "archive-sid", Xep.JingleMessageInitiation.Action.PROCEED,
                    now.add_seconds(-30), false) ||
                !registry.observe_archive(account, stream, peer, own,
                    "archive-sid", Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-5), false),
            "Reordered and duplicate archive actions must be accumulated idempotently");

        Gee.List<JmiArchiveReplayResult> results =
            registry.settle_success(account, stream, now);
        fail_if(results.size != 1 || registry.size != 0 ||
                results[0].state != Entities.Call.State.ENDED ||
                results[0].direction != Entities.Call.DIRECTION_INCOMING ||
                !results[0].peer.equals_bare(peer) ||
                !results[0].video_requested,
            "A completed archived call must yield one passive terminal projection");
        fail_if(!registry.settle_success(account, stream, now).is_empty,
            "Repeated archive settlement must not publish duplicate history");
    }

    private void test_jmi_archive_replay_actionable_proposal() {
        Account account;
        Jid own;
        Jid peer;
        try {
            account = new Account(new Jid("eve@example.test"), "secret");
            own = new Jid("eve@example.test/desktop");
            peer = new Jid("frank@example.test/phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static actionable JMI JID is invalid: %s"
                .printf(e.message));
            return;
        }

        var descriptions = new Gee.ArrayList<StanzaNode>();
        descriptions.add(new StanzaNode.build("description",
            Xep.JingleRtp.NS_URI).add_self_xmlns()
                .put_attribute("media", "audio"));
        DateTime now = new DateTime.now_utc();
        DateTime proposed_at = now.add_seconds(-10);
        var registry = new JmiArchiveReplayRegistry(8, 60);
        var stream = new Object();
        registry.begin_stream(account, stream);
        fail_if(!registry.observe_archive(account, stream, peer, own,
                    "actionable-sid",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    proposed_at, false, null, false, null, descriptions),
            "A valid archived proposal must be retained for settlement");

        Gee.List<JmiArchiveReplayResult> recovered =
            registry.settle_success(account, stream, now);
        fail_if(recovered.size != 1 || !recovered[0].actionable ||
                recovered[0].state != Call.State.RINGING ||
                recovered[0].direction != Call.DIRECTION_INCOMING ||
                recovered[0].descriptions.size != 1 ||
                recovered[0].ended_at.to_unix() !=
                    proposed_at.add_seconds(60).to_unix() ||
                registry.size != 1,
            "A current incoming proposal must become actionable without consuming its replay owner");
        fail_if(!registry.settle_success(account, stream, now).is_empty,
            "An actionable proposal must be published only once per stream owner");

        var reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.BUSY);
        Gee.List<JmiArchiveReplayResult> terminal =
            registry.observe_delayed(account, stream, own, peer,
                "actionable-sid",
                Xep.JingleMessageInitiation.Action.REJECT,
                now.add_seconds(-1), now, false, reason);
        fail_if(terminal.size != 1 || terminal[0].actionable ||
                terminal[0].state != Call.State.DECLINED ||
                terminal[0].reason == null ||
                ((!) terminal[0].reason).condition !=
                    Xep.Jingle.ReasonElement.BUSY || registry.size != 0,
            "A delayed terminal must settle the passive proposal exactly once");

        var finish_registry = new JmiArchiveReplayRegistry(8, 60);
        var finish_stream = new Object();
        finish_registry.begin_stream(account, finish_stream);
        fail_if(!finish_registry.observe_archive(account, finish_stream,
                    peer, own, "finished-without-proceed",
                    Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-1), false) ||
                !finish_registry.observe_archive(account, finish_stream,
                    peer, own, "finished-without-proceed",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    proposed_at, false, null, false, null, descriptions),
            "Archive ordering must retain finish until its proposal defines exact roles");
        Gee.List<JmiArchiveReplayResult> finished =
            finish_registry.settle_success(account, finish_stream, now);
        fail_if(finished.size != 1 || finished[0].actionable ||
                finished[0].state != Call.State.ENDED ||
                finish_registry.size != 0,
            "Finish must prevent stale proposal recovery even when MAM omitted proceed");
    }

    private void test_jmi_cross_device_accept_blocks_persisted_recovery() {
        Account account;
        Jid own;
        Jid peer;
        try {
            account = new Account(new Jid("cross-device@example.test"),
                "secret");
            own = new Jid("cross-device@example.test/desktop");
            peer = new Jid("caller@example.test/phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static cross-device JMI JID is invalid: %s"
                .printf(e.message));
            return;
        }

        var descriptions = new Gee.ArrayList<StanzaNode>();
        descriptions.add(new StanzaNode.build("description",
            Xep.JingleRtp.NS_URI).add_self_xmlns()
                .put_attribute("media", "audio"));
        DateTime now = new DateTime.now_utc();
        DateTime proposed_at = now.add_seconds(-30);

        var proceed_registry = new JmiArchiveReplayRegistry(8, 300);
        var proceed_stream = new Object();
        proceed_registry.begin_stream(account, proceed_stream);
        fail_if(!proceed_registry.observe_archive(account, proceed_stream,
                    peer, own, "proceeded-on-other-device",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    proposed_at, false, null, false, null, descriptions) ||
                !proceed_registry.observe_archive(account, proceed_stream,
                    own, peer, "proceeded-on-other-device",
                    Xep.JingleMessageInitiation.Action.PROCEED,
                    now.add_seconds(-20), false),
            "A proposal and its cross-device proceed must be retained");
        Gee.List<JmiArchiveReplayResult> proceed_results =
            proceed_registry.settle_success(account, proceed_stream, now);
        fail_if(!proceed_results.is_empty || proceed_registry.size != 1 ||
                proceed_registry.permits_persisted_recovery(account,
                    proceed_stream, peer, "proceeded-on-other-device", now),
            "A proceed from another own device must keep a persisted proposal non-actionable");

        var accept_registry = new JmiArchiveReplayRegistry(8, 300);
        var accept_stream = new Object();
        accept_registry.begin_stream(account, accept_stream);
        fail_if(!accept_registry.observe_archive(account, accept_stream,
                    peer, own, "accepted-on-other-device",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    proposed_at, false, null, false, null, descriptions) ||
                !accept_registry.observe_archive(account, accept_stream,
                    own, account.bare_jid, "accepted-on-other-device",
                    Xep.JingleMessageInitiation.Action.LEGACY_ACCEPT,
                    now.add_seconds(-20), false),
            "A proposal and its legacy cross-device accept must be retained");
        Gee.List<JmiArchiveReplayResult> accept_results =
            accept_registry.settle_success(account, accept_stream, now);
        fail_if(!accept_results.is_empty || accept_registry.size != 1 ||
                accept_registry.permits_persisted_recovery(account,
                    accept_stream, peer, "accepted-on-other-device", now),
            "A legacy accept from another own device must keep a persisted proposal non-actionable");
    }

    private void test_jmi_archive_replay_fencing() {
        Account account;
        Jid own;
        Jid peer;
        try {
            account = new Account(new Jid("carol@example.test"), "secret");
            own = new Jid("carol@example.test/laptop");
            peer = new Jid("dave@example.test/mobile");
        } catch (InvalidJidError e) {
            fail_if_reached("Static JMI replay fence JID is invalid: %s".printf(
                e.message));
            return;
        }

        DateTime now = new DateTime.now_utc();
        var registry = new JmiArchiveReplayRegistry(2, 60);
        var stale_stream = new Object();
        var current_stream = new Object();
        registry.begin_stream(account, stale_stream);
        registry.begin_stream(account, current_stream);
        fail_if(registry.observe_archive(account, stale_stream, peer, own,
                    "stale", Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-10), false),
            "A stale stream must not repopulate archive replay state");

        for (int i = 0; i < 3; i++) {
            registry.observe_archive(account, current_stream, peer, own,
                "bounded-%d".printf(i),
                Xep.JingleMessageInitiation.Action.PROPOSE,
                now.add_seconds(i == 2 ? -120 : -10), false);
        }
        fail_if(registry.size != 2,
            "Archive replay state must remain bounded before settlement");

        Gee.List<JmiArchiveReplayResult> expired =
            registry.settle_success(account, current_stream, now);
        fail_if(expired.size != 1 ||
                expired[0].state != Entities.Call.State.MISSED ||
                registry.size != 1,
            "Only an unresolved proposal older than the retention window must expire into history");

        JmiArchiveReplayResult? completed =
            registry.observe_live_followup(account, current_stream, own, peer,
                "bounded-1", Xep.JingleMessageInitiation.Action.REJECT, now);
        fail_if(completed == null ||
                ((!) completed).state != Entities.Call.State.DECLINED ||
                registry.size != 0,
            "A live terminal follow-up may complete one settled passive replay without creating active state");

        registry.begin_stream(account, current_stream);
        registry.observe_archive(account, current_stream, peer, own,
            "timed-expiry", Xep.JingleMessageInitiation.Action.PROPOSE,
            now.add_seconds(-10), false);
        fail_if(!registry.settle_success(account, current_stream, now).is_empty ||
                registry.next_expiry_delay_seconds(account, current_stream,
                    now) != 50,
            "A recent unresolved archive proposal must retain one bounded expiry deadline");
        Gee.List<JmiArchiveReplayResult> timed_expiry =
            registry.expire_settled(account, current_stream,
                now.add_seconds(50));
        fail_if(timed_expiry.size != 1 ||
                timed_expiry[0].state != Entities.Call.State.MISSED ||
                registry.size != 0 ||
                registry.next_expiry_delay_seconds(account, current_stream,
                    now.add_seconds(50)) != -1,
            "A settled unresolved archive proposal must expire without requiring another reconnect");

        registry.begin_stream(account, current_stream);
        registry.observe_archive(account, current_stream, peer, own, "failed",
            Xep.JingleMessageInitiation.Action.PROPOSE,
            now.add_seconds(-10), false);
        registry.settle_failed(account, current_stream);
        fail_if(registry.size != 0,
            "A failed catch-up must discard its uncertain partial lifecycle");
    }

    private void test_jmi_archive_terminal_retention() {
        Account account;
        Jid own;
        Jid own_tablet;
        Jid own_phone;
        Jid peer;
        try {
            account = new Account(new Jid("alice@example.test"), "secret");
            own = new Jid("alice@example.test/desktop");
            own_tablet = new Jid("alice@example.test/tablet");
            own_phone = new Jid("alice@example.test/phone");
            peer = new Jid("bob@example.test/laptop");
        } catch (InvalidJidError e) {
            fail_if_reached("Static JMI retention JID is invalid: %s".printf(
                e.message));
            return;
        }

        DateTime now = new DateTime.now_utc();
        var registry = new JmiArchiveReplayRegistry(4, 120, 3);
        var stream = new Object();
        registry.begin_stream(account, stream);

        bool proposal_retained = registry.observe_archive(account, stream,
            peer, own, "pressure-sid",
            Xep.JingleMessageInitiation.Action.PROPOSE,
            now.add_seconds(-50), false);
        bool selected_proceed_retained = registry.observe_archive(account,
            stream, own, peer, "pressure-sid",
            Xep.JingleMessageInitiation.Action.PROCEED,
            now.add_seconds(-40), false);
        // These duplicate responders deliberately exceed the bound. Whether
        // either one survives is irrelevant; the first selected responder and
        // the authoritative terminal action must remain.
        registry.observe_archive(account, stream, own_tablet, peer,
            "pressure-sid", Xep.JingleMessageInitiation.Action.PROCEED,
            now.add_seconds(-35), false);
        registry.observe_archive(account, stream, own_phone, peer,
            "pressure-sid", Xep.JingleMessageInitiation.Action.PROCEED,
            now.add_seconds(-30), false);
        bool terminal_retained = registry.observe_archive(account, stream,
            peer, own, "pressure-sid",
            Xep.JingleMessageInitiation.Action.FINISH,
            now.add_seconds(-10), false);
        fail_if(!proposal_retained || !selected_proceed_retained ||
                !terminal_retained,
            "A terminal event must outrank redundant proceed observations under the per-call bound");

        Gee.List<JmiArchiveReplayResult> results =
            registry.settle_success(account, stream, now);
        fail_if(results.size != 1 ||
                results[0].state != Entities.Call.State.ENDED ||
                registry.size != 0,
            "Observation pressure must never revive a call whose terminal finish was archived");

        // Preserve both the selected proceed phase boundary and its matching
        // finish even if many later post-proceed rejects fill the raw bound.
        var phase_registry = new JmiArchiveReplayRegistry(4, 120, 32);
        var phase_stream = new Object();
        phase_registry.begin_stream(account, phase_stream);
        phase_registry.observe_archive(account, phase_stream, peer, own,
            "phase-pressure-sid",
            Xep.JingleMessageInitiation.Action.PROPOSE,
            now.add_seconds(-100), false);
        phase_registry.observe_archive(account, phase_stream, own, peer,
            "phase-pressure-sid",
            Xep.JingleMessageInitiation.Action.PROCEED,
            now.add_seconds(-90), false);
        for (int index = 0; index < 30; index++) {
            phase_registry.observe_archive(account, phase_stream, own, peer,
                "phase-pressure-sid",
                Xep.JingleMessageInitiation.Action.REJECT,
                now.add_seconds(-80 + index), false);
        }
        var finish_reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.SUCCESS, "Moved to another device");
        bool finish_retained = phase_registry.observe_archive(account,
            phase_stream, peer, own, "phase-pressure-sid",
            Xep.JingleMessageInitiation.Action.FINISH,
            now.add_seconds(-10), false, finish_reason, false,
            "replacement-sid");
        phase_registry.observe_archive(account, phase_stream, own, peer,
            "phase-pressure-sid",
            Xep.JingleMessageInitiation.Action.REJECT,
            now.add_seconds(-5), false);

        Gee.List<JmiArchiveReplayResult> phase_results =
            phase_registry.settle_success(account, phase_stream, now);
        fail_if(!finish_retained || phase_results.size != 1 ||
                phase_results[0].state != Entities.Call.State.ENDED ||
                phase_results[0].reason == null ||
                ((!) phase_results[0].reason).condition !=
                    Xep.Jingle.ReasonElement.SUCCESS ||
                phase_results[0].migrated_to_sid != "replacement-sid" ||
                phase_registry.size != 0,
            "Terminal pressure must retain the selected proceed boundary and its finish metadata");
    }

    private void test_jmi_late_proposal_terminal_retention() {
        Account account;
        Jid own;
        Jid peer;
        try {
            account = new Account(new Jid("late@example.test"), "secret");
            own = new Jid("late@example.test/desktop");
            peer = new Jid("peer@example.test/phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static late-proposal JMI JID is invalid: %s"
                .printf(e.message));
            return;
        }

        const int MAX_OBSERVATIONS = 4;
        DateTime now = new DateTime.now_utc();
        DateTime finish_at = now.add_seconds(-10);
        var registry = new JmiArchiveReplayRegistry(4, 120,
            MAX_OBSERVATIONS);
        var stream = new Object();
        registry.begin_stream(account, stream);

        bool proceed_retained = registry.observe_archive(account, stream,
            own, peer, "late-proposal-sid",
            Xep.JingleMessageInitiation.Action.PROCEED,
            now.add_seconds(-90), false);
        for (int index = 0; index < MAX_OBSERVATIONS + 3; index++) {
            registry.observe_archive(account, stream, own, peer,
                "late-proposal-sid",
                Xep.JingleMessageInitiation.Action.REJECT,
                now.add_seconds(-80 + index), false);
        }
        var finish_reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.SUCCESS, "Moved to replacement");
        bool finish_retained = registry.observe_archive(account, stream,
            peer, own, "late-proposal-sid",
            Xep.JingleMessageInitiation.Action.FINISH, finish_at, false,
            finish_reason, false, "late-replacement-sid");
        bool proposal_retained = registry.observe_archive(account, stream,
            peer, own, "late-proposal-sid",
            Xep.JingleMessageInitiation.Action.PROPOSE,
            now.add_seconds(-100), false);

        Gee.List<JmiArchiveReplayResult> results =
            registry.settle_success(account, stream, now);
        fail_if(!proceed_retained || !finish_retained ||
                !proposal_retained || results.size != 1 ||
                results[0].state != Entities.Call.State.ENDED ||
                results[0].ended_at.to_unix() != finish_at.to_unix() ||
                results[0].reason == null ||
                ((!) results[0].reason).condition !=
                    Xep.Jingle.ReasonElement.SUCCESS ||
                ((!) results[0].reason).text != "Moved to replacement" ||
                results[0].migrated_to_sid != "late-replacement-sid" ||
                registry.size != 0,
            "A proposal arriving on the last MAM page must retain the established finish and migration metadata under pressure");
    }

    private void test_jmi_late_proposal_matching_finish_resource_flood() {
        Account account;
        Jid own;
        Jid proposal_peer;
        var foreign_peers = new Gee.ArrayList<Jid>();
        try {
            account = new Account(new Jid("resource@example.test"),
                "secret");
            own = new Jid("resource@example.test/desktop");
            proposal_peer = new Jid("peer@example.test/actual-phone");
            for (int index = 0; index < 32; index++) {
                foreign_peers.add(new Jid(
                    "peer@example.test/foreign-%d".printf(index)));
            }
        } catch (InvalidJidError e) {
            fail_if_reached("Static resource-flood JMI JID is invalid: %s"
                .printf(e.message));
            return;
        }

        DateTime now = new DateTime.now_utc();
        DateTime finish_at = now.add_seconds(-10);
        var registry = new JmiArchiveReplayRegistry(4, 300, 32);
        var stream = new Object();
        registry.begin_stream(account, stream);

        for (int index = 0; index < foreign_peers.size; index++) {
            fail_if(!registry.observe_archive(account, stream,
                        foreign_peers[index], own, "resource-flood-sid",
                        Xep.JingleMessageInitiation.Action.FINISH,
                        now.add_seconds(-90 + index), false),
                "Every formally valid foreign-resource finish must enter the bounded pre-proposal set");
        }
        var finish_reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.SUCCESS, "Moved by matching resource");
        bool finish_retained = registry.observe_archive(account, stream,
            proposal_peer, own, "resource-flood-sid",
            Xep.JingleMessageInitiation.Action.FINISH, finish_at, false,
            finish_reason, false, "resource-replacement-sid");
        bool proposal_retained = registry.observe_archive(account, stream,
            proposal_peer, own, "resource-flood-sid",
            Xep.JingleMessageInitiation.Action.PROPOSE,
            now.add_seconds(-120), false);

        Gee.List<JmiArchiveReplayResult> results =
            registry.settle_success(account, stream, now);
        fail_if(!finish_retained || !proposal_retained || results.size != 1 ||
                results[0].state != Entities.Call.State.ENDED ||
                results[0].ended_at.to_unix() != finish_at.to_unix() ||
                !results[0].proposal_source.equals(proposal_peer) ||
                results[0].reason == null ||
                ((!) results[0].reason).condition !=
                    Xep.Jingle.ReasonElement.SUCCESS ||
                ((!) results[0].reason).text !=
                    "Moved by matching resource" ||
                results[0].migrated_to_sid != "resource-replacement-sid" ||
                registry.size != 0,
            "A late proposal must select its matching full-JID finish despite a full bounded set of foreign resources");
    }

    private void test_jmi_observation_truncation_blocks_actionable() {
        Account account;
        Jid own;
        Jid proposal_peer;
        var foreign_peers = new Gee.ArrayList<Jid>();
        try {
            account = new Account(new Jid("truncated@example.test"),
                "secret");
            own = new Jid("truncated@example.test/desktop");
            proposal_peer = new Jid("peer@example.test/matching-phone");
            for (int index = 0; index < 32; index++) {
                foreign_peers.add(new Jid(
                    "peer@example.test/younger-%d".printf(index)));
            }
        } catch (InvalidJidError e) {
            fail_if_reached("Static truncated-observation JMI JID is invalid: %s"
                .printf(e.message));
            return;
        }

        var descriptions = new Gee.ArrayList<StanzaNode>();
        descriptions.add(new StanzaNode.build("description",
            Xep.JingleRtp.NS_URI).add_self_xmlns()
                .put_attribute("media", "audio"));
        DateTime now = new DateTime.now_utc();
        var registry = new JmiArchiveReplayRegistry(4, 300, 32);
        var stream = new Object();
        registry.begin_stream(account, stream);

        var matching_reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.SUCCESS, "Matching terminal");
        fail_if(!registry.observe_archive(account, stream, proposal_peer, own,
                    "truncated-sid",
                    Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-60), false, matching_reason, false,
                    "matching-replacement-sid"),
            "The matching finish must enter the pre-proposal observation set");
        for (int index = 0; index < foreign_peers.size; index++) {
            var foreign_reason = new Xep.JingleMessageInitiation.JmiReason(
                Xep.Jingle.ReasonElement.SUCCESS, "Foreign terminal");
            registry.observe_archive(account, stream, foreign_peers[index],
                own, "truncated-sid",
                Xep.JingleMessageInitiation.Action.FINISH,
                now.add_seconds(-59 + index), false, foreign_reason, false,
                "foreign-replacement-%d".printf(index));
        }
        fail_if(!registry.observe_archive(account, stream, proposal_peer, own,
                    "truncated-sid",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-100), false, null, false, null,
                    descriptions),
            "The late matching proposal must still be retained after trimming");

        Gee.List<JmiArchiveReplayResult> results =
            registry.settle_success(account, stream, now);
        fail_if(!results.is_empty || registry.size != 1 ||
                registry.permits_persisted_recovery(account, stream,
                    proposal_peer, "truncated-sid", now),
            "Truncated terminal evidence must block both immediate and persisted actionable recovery");

        var clean_registry = new JmiArchiveReplayRegistry(4, 300, 32);
        var clean_stream = new Object();
        clean_registry.begin_stream(account, clean_stream);
        fail_if(!clean_registry.observe_archive(account, clean_stream,
                    proposal_peer, own, "clean-recovery-sid",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-30), false, null, false, null,
                    descriptions),
            "The clean recovery control proposal must be retained");
        Gee.List<JmiArchiveReplayResult> clean_results =
            clean_registry.settle_success(account, clean_stream, now);
        fail_if(clean_results.size != 1 || !clean_results[0].actionable ||
                !clean_registry.permits_persisted_recovery(account,
                    clean_stream, proposal_peer, "clean-recovery-sid", now),
            "A settled non-truncated replay must permit persisted recovery");
    }

    private void test_jmi_entry_overflow_blocks_actionable() {
        Account account;
        Jid own;
        Jid peer;
        try {
            account = new Account(new Jid("overflow@example.test"),
                "secret");
            own = new Jid("overflow@example.test/desktop");
            peer = new Jid("peer@example.test/phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static entry-overflow JMI JID is invalid: %s"
                .printf(e.message));
            return;
        }

        var descriptions = new Gee.ArrayList<StanzaNode>();
        descriptions.add(new StanzaNode.build("description",
            Xep.JingleRtp.NS_URI).add_self_xmlns()
                .put_attribute("media", "audio"));
        DateTime now = new DateTime.now_utc();
        var registry = new JmiArchiveReplayRegistry(2, 300);
        var stream = new Object();
        registry.begin_stream(account, stream);

        var old_reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.SUCCESS, "Evicted terminal");
        fail_if(!registry.observe_archive(account, stream, peer, own,
                    "overflow-a",
                    Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-20), false, old_reason, false,
                    "overflow-a-replacement") ||
                !registry.observe_archive(account, stream, peer, own,
                    "overflow-filler",
                    Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-19), false),
            "The terminal and filler entries must exist before global eviction");

        fail_if(!registry.observe_archive(account, stream, peer, own,
                    "overflow-terminal",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-100), false),
            "The terminal control proposal must evict the oldest SID entry");
        var control_reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.SUCCESS, "Control terminal");
        fail_if(!registry.observe_archive(account, stream, peer, own,
                    "overflow-terminal",
                    Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-10), false, control_reason, false,
                    "overflow-control-replacement"),
            "The retained control lifecycle must become terminal");
        fail_if(!registry.observe_archive(account, stream, peer, own,
                    "overflow-a",
                    Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-100), false, null, false, null,
                    descriptions),
            "The replayed proposal must be retained after its old terminal entry was evicted");

        Gee.List<JmiArchiveReplayResult> results =
            registry.settle_success(account, stream, now);
        fail_if(results.size != 1 || results[0].actionable ||
                results[0].sid != "overflow-terminal" ||
                results[0].state != Entities.Call.State.ENDED ||
                results[0].reason == null ||
                ((!) results[0].reason).condition !=
                    Xep.Jingle.ReasonElement.SUCCESS ||
                results[0].migrated_to_sid !=
                    "overflow-control-replacement" ||
                registry.size != 1 ||
                registry.permits_persisted_recovery(account, stream, peer,
                    "overflow-a", now),
            "Global replay overflow must suppress immediate and persisted recovery without suppressing retained terminal results");
    }

    private void test_jmi_migration_settlement_ordering() {
        Account account;
        Jid own;
        Jid old_peer;
        Jid new_peer;
        try {
            account = new Account(new Jid("migration@example.test"),
                "secret");
            own = new Jid("migration@example.test/desktop");
            old_peer = new Jid("peer@example.test/old-phone");
            new_peer = new Jid("peer@example.test/new-phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static migration-order JMI JID is invalid: %s"
                .printf(e.message));
            return;
        }

        var descriptions = new Gee.ArrayList<StanzaNode>();
        descriptions.add(new StanzaNode.build("description",
            Xep.JingleRtp.NS_URI).add_self_xmlns()
                .put_attribute("media", "audio"));
        var finish_reason = new Xep.JingleMessageInitiation.JmiReason(
            Xep.Jingle.ReasonElement.SUCCESS, "Migrated");
        DateTime now = new DateTime.now_utc();
        var registry = new JmiArchiveReplayRegistry(8, 120);
        var stream = new Object();
        registry.begin_stream(account, stream);

        fail_if(!registry.observe_archive(account, stream, old_peer, own,
                    "old-sid", Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-60), false) ||
                !registry.observe_archive(account, stream, own, old_peer,
                    "old-sid", Xep.JingleMessageInitiation.Action.PROCEED,
                    now.add_seconds(-50), false) ||
                !registry.observe_archive(account, stream, old_peer, own,
                    "old-sid", Xep.JingleMessageInitiation.Action.FINISH,
                    now.add_seconds(-40), false, finish_reason, false,
                    "new-sid") ||
                !registry.observe_archive(account, stream, new_peer, own,
                    "new-sid", Xep.JingleMessageInitiation.Action.PROPOSE,
                    now.add_seconds(-30), true, null, false, null,
                    descriptions),
            "Both the terminal old leg and active replacement proposal must be retained");

        Gee.List<JmiArchiveReplayResult> results =
            registry.settle_success(account, stream, now);
        fail_if(results.size != 2 ||
                !results[0].actionable || results[0].sid != "new-sid" ||
                results[0].state != Entities.Call.State.RINGING ||
                !results[0].proposal_source.equals(new_peer) ||
                results[1].actionable || results[1].sid != "old-sid" ||
                results[1].state != Entities.Call.State.ENDED ||
                results[1].reason == null ||
                ((!) results[1].reason).condition !=
                    Xep.Jingle.ReasonElement.SUCCESS ||
                results[1].migrated_to_sid != "new-sid" ||
                registry.size != 1,
            "Settlement must publish the actionable replacement before the migrated terminal leg");
    }

    private void test_jmi_active_migration_owner_transfer() {
        Account account;
        Jid peer_old;
        Jid peer_new;
        Jid other_peer;
        try {
            account = new Account(new Jid("erin@example.test"), "secret");
            peer_old = new Jid("frank@example.test/old-phone");
            peer_new = new Jid("frank@example.test/new-phone");
            other_peer = new Jid("mallory@example.test/device");
        } catch (InvalidJidError e) {
            fail_if_reached("Static JMI migration JID is invalid: %s".printf(
                e.message));
            return;
        }

        var registry = new JmiLiveSessionRegistry();
        var owner = new AuditJmiOwner();
        JmiLiveSessionEntry? old_entry = registry.register(account, peer_old,
            "old-sid", account.full_jid, peer_old, false, owner);
        fail_if(old_entry == null ||
                !((!) old_entry).reserve_local_proceed(peer_old,
                    account.full_jid) ||
                !((!) old_entry).commit_local_proceed(peer_old,
                    account.full_jid),
            "The active owner must be bound to its original full resource");

        JmiLiveSessionEntry? replacement =
            registry.replace_for_migration((!) old_entry, "new-sid",
                peer_new, account.full_jid, owner);
        fail_if(replacement == null || registry.size != 1 ||
                registry.tombstone_size != 1 ||
                ((!) replacement).sid != "new-sid" ||
                !((!) replacement).incoming ||
                ((!) replacement).owner != owner ||
                !((!) replacement).peer_bare_jid.equals_bare(peer_new) ||
                registry.inspect_proposal(account, peer_old, "old-sid",
                    account.full_jid) != JmiProposalDisposition.TERMINAL,
            "Migration must atomically replace one live owner and retain an exact old-SID replay fence");
        fail_if(registry.replace_for_migration((!) replacement, "bad-sid",
                    other_peer, account.full_jid, owner) != null,
            "A migration proposal from another bare peer must fail closed");

        fail_if(!JmiActiveMigrationPolicy.may_stage(true,
                    CallMediaBackend.GOOGLE_WEBRTC, true,
                    Entities.Call.State.IN_PROGRESS,
                    Xep.JingleMessageInitiation.Delivery.LIVE,
                    peer_new, peer_old) ||
                JmiActiveMigrationPolicy.may_stage(false,
                    CallMediaBackend.GOOGLE_WEBRTC, true,
                    Entities.Call.State.IN_PROGRESS,
                    Xep.JingleMessageInitiation.Delivery.LIVE,
                    peer_new, peer_old) ||
                !JmiActiveMigrationPolicy.may_stage(true,
                    CallMediaBackend.GOOGLE_WEBRTC, true,
                    Entities.Call.State.IN_PROGRESS,
                    Xep.JingleMessageInitiation.Delivery.CARBON_RECEIVED,
                    peer_new, peer_old) ||
                JmiActiveMigrationPolicy.may_stage(true,
                    CallMediaBackend.LEGACY_RTP, true,
                    Entities.Call.State.IN_PROGRESS,
                    Xep.JingleMessageInitiation.Delivery.LIVE,
                    peer_new, peer_old),
            "Only a direct Google/libwebrtc owner may migrate; live and received-Carbon proposals are valid while MUJI and legacy RTP stay excluded");
    }

    private void test_jmi_migration_excludes_muji_transitions() {
        fail_if(!CallState.direct_jmi_migration_allowed(false, false,
                    false, false, false, false, false, false, false),
            "An idle direct JMI owner must be eligible for migration");
        fail_if(CallState.direct_jmi_migration_allowed(true, false,
                    false, false, false, false, false, false, false) ||
                CallState.direct_jmi_migration_allowed(false, true,
                    false, false, false, false, false, false, false) ||
                CallState.direct_jmi_migration_allowed(false, false,
                    true, false, false, false, false, false, false) ||
                CallState.direct_jmi_migration_allowed(false, false,
                    false, true, false, false, false, false, false) ||
                CallState.direct_jmi_migration_allowed(false, false,
                    false, false, true, false, false, false, false) ||
                CallState.direct_jmi_migration_allowed(false, false,
                    false, false, false, true, false, false, false) ||
                CallState.direct_jmi_migration_allowed(false, false,
                    false, false, false, false, true, false, false) ||
                CallState.direct_jmi_migration_allowed(false, false,
                    false, false, false, false, false, true, false) ||
                CallState.direct_jmi_migration_allowed(false, false,
                    false, false, false, false, false, false, true),
            "Teardown, group ownership, join/conversion and CIM must each block direct JMI migration");
    }

    private void test_direct_jmi_setup_timeout_boundary() {
        fail_if(!CallState.direct_jmi_setup_timeout_allowed(
                    CallMediaBackend.GOOGLE_WEBRTC, false, false,
                    "direct-sid", "direct-sid",
                    Entities.Call.State.ESTABLISHING),
            "A selected direct Google/libwebrtc leg must own a bounded post-proceed timeout");
        fail_if(CallState.direct_jmi_setup_timeout_allowed(
                    CallMediaBackend.LEGACY_RTP, false, false,
                    "direct-sid", "direct-sid",
                    Entities.Call.State.ESTABLISHING) ||
                CallState.direct_jmi_setup_timeout_allowed(
                    CallMediaBackend.GOOGLE_WEBRTC, true, false,
                    "direct-sid", "direct-sid",
                    Entities.Call.State.ESTABLISHING) ||
                CallState.direct_jmi_setup_timeout_allowed(
                    CallMediaBackend.GOOGLE_WEBRTC, false, true,
                    "direct-sid", "direct-sid",
                    Entities.Call.State.ESTABLISHING) ||
                CallState.direct_jmi_setup_timeout_allowed(
                    CallMediaBackend.GOOGLE_WEBRTC, false, false,
                    "stale-sid", "direct-sid",
                    Entities.Call.State.ESTABLISHING) ||
                CallState.direct_jmi_setup_timeout_allowed(
                    CallMediaBackend.GOOGLE_WEBRTC, false, false,
                    "direct-sid", "direct-sid",
                    Entities.Call.State.IN_PROGRESS),
            "Legacy RTP, MUJI, stale SID ownership and completed setup must never share the direct JMI timeout");
    }
}

}
