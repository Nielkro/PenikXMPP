namespace Xmpp.Test {

class MucAudit : Gee.TestCase {

    public const string NS_DISCO_INFO = "http://jabber.org/protocol/disco#info";
    public const string NS_MUC = "http://jabber.org/protocol/muc";
    public const string NS_MUC_ADMIN = "http://jabber.org/protocol/muc#admin";
    public const string NS_MUC_OWNER = "http://jabber.org/protocol/muc#owner";
    public const string NS_MUC_USER = "http://jabber.org/protocol/muc#user";
    public const string NS_MUC_HATS = "urn:xmpp:hats:0";
    public const string NS_VCARD_UPDATE = "vcard-temp:x:update";
    public const string NS_STANZA_ERROR = "urn:ietf:params:xml:ns:xmpp-stanzas";
    public const string ROOM = "room@conference.example.test";
    public const string OWNER_OCCUPANT = ROOM + "/owner";
    public const string ALICE_OCCUPANT = ROOM + "/alice";
    public const string ALICE_REAL = "alice@example.test/laptop";
    public const string OTHER_ROOM = "other@conference.example.test";
    public const string OTHER_OWNER_OCCUPANT = OTHER_ROOM + "/owner";
    public const string OTHER_ALICE_OCCUPANT = OTHER_ROOM + "/alice";
    public const string OTHER_ALICE_REAL = "other-alice@example.test/phone";
    public const string LOCAL_FULL = "owner@example.test/dinox";
    public const string ROOM_AVATAR_HASH =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    public MucAudit() {
        base("MucAudit");

        add_async_test("XEP0045_full_occupant_affiliation_uses_real_jid_member_list", test_full_occupant_affiliation_uses_real_jid_member_list);
        add_async_test("XEP0045_rejoin_preserves_real_jid_member_list_affiliation", test_rejoin_preserves_real_jid_member_list_affiliation);
        add_async_test("XEP0045_unavailable_without_muc_x_clears_live_affiliation", test_unavailable_without_muc_x_clears_live_affiliation);
        add_async_test("XEP0045_privacy_change_clears_disclosed_real_jids",
            test_privacy_change_clears_disclosed_real_jids);
        add_async_test("XEP0045_fully_anonymous_revokes_moderator_jids_and_survives_disco",
            test_fully_anonymous_revokes_moderator_jids_and_survives_disco);
        add_async_test("XEP0045_forged_privacy_change_is_ignored",
            test_forged_privacy_change_is_ignored);
        add_async_test("XEP0045_presence_replay_requires_join_and_is_merge_only",
            test_presence_replay_requires_join_and_is_merge_only);
        add_async_test("XEP0045_live_config_status_replay_matrix",
            test_live_config_status_replay_matrix);
        add_async_test("XEP0045_confirmed_presence_broadcast_removes_only_known_excluded_roles",
            test_confirmed_presence_broadcast_removes_only_known_excluded_roles);
        add_async_test("XEP0317_confirmed_hats_disable_clears_hats_without_removing_occupants",
            test_confirmed_hats_disable_clears_hats_without_removing_occupants);
        add_async_test("XEP0045_confirmed_whois_applies_authoritative_privacy",
            test_confirmed_whois_applies_authoritative_privacy);
        add_async_test("XEP0045_status_100_is_initial_visibility_authority",
            test_status_100_is_visibility_authority);
        add_async_test("XEP0045_stale_status_100_cannot_change_visibility",
            test_stale_status_100_is_ignored);
        add_async_test("XEP0045_status_100_message_requires_active_enter",
            test_status_100_message_requires_active_enter);
        add_async_test("XEP0045_cancel_after_status_100_message_clears_visibility",
            test_cancel_after_status_100_message_clears_visibility);
        add_async_test("XEP0045_real_jid_visibility_signal_tracks_live_state",
            test_real_jid_visibility_signal);
        add_async_test("XEP0045_replayed_privacy_status_messages_are_ignored",
            test_replayed_privacy_status_messages_are_ignored);
        add_async_test("XEP0045_authoritative_missing_jid_clears_identity",
            test_authoritative_missing_jid_clears_identity);
        add_async_test("XEP0045_member_query_preserves_live_full_occupant_affiliation", test_member_query_preserves_live_full_occupant_affiliation);
        add_async_test("XEP0045_immutable_occupant_presence_event_is_atomic", test_immutable_occupant_presence_event);
        add_async_test("XEP0153_empty_photo_is_authoritative_avatar_reset",
            test_empty_photo_is_authoritative_avatar_reset);
        add_async_test("XEP0410_self_ping_timeout_returns_unknown", test_self_ping_timeout_returns_unknown);
        add_async_test("IQ_write_failure_completes_waiter", test_iq_write_failure_completes_waiter);
        add_async_test("XEP0045_enter_stream_detach_completes_waiter", test_enter_stream_detach_completes_waiter);
        add_async_test("XEP0045_enter_error_without_id_completes_waiter", test_enter_error_without_id_completes_waiter);
        add_async_test("XEP0045_enter_error_with_mismatched_id_is_ignored", test_enter_error_with_mismatched_id_is_ignored);
        add_async_test("XEP0045_enter_bare_room_error_without_id_completes_waiter", test_enter_bare_room_error_without_id_completes_waiter);
        add_async_test("XEP0045_enter_presence_without_110_is_ignored", test_enter_presence_without_110_is_ignored);
        add_async_test("XEP0045_enter_completion_is_atomic_and_reentrant_exit_safe",
            test_enter_completion_is_atomic_and_reentrant_exit_safe);
        add_async_test("XEP0045_cancel_enter_completes_waiter_and_allows_retry", test_cancel_enter_completes_waiter_and_allows_retry);
        add_async_test("XEP0045_late_cancelled_self_preserves_same_jid_rejoin_cache",
            test_late_cancelled_self_preserves_same_jid_rejoin_cache);
        add_async_test("XEP0045_room_configuration_submits_all_changed_fields", test_room_configuration_submits_all_changed_fields);
        add_async_test("XEP0045_room_configuration_propagates_iq_error", test_room_configuration_propagates_iq_error);
        add_async_test("XEP0045_room_info_refresh_is_atomic", test_room_info_refresh_is_atomic);
        add_async_test("XEP0486_room_info_publishes_accepted_avatar_projection",
            test_room_info_publishes_avatar_projection);
        add_async_test("XEP0045_query_generations_survive_same_stream_rejoin", test_query_generations_survive_same_stream_rejoin);
        add_async_test("XEP0045_member_affiliation_snapshot_coalesces_join_queries",
            test_member_affiliation_snapshot_coalesces_join_queries);
        add_async_test("XEP0045_member_affiliation_snapshot_force_supersedes_old_queries",
            test_member_affiliation_snapshot_force_supersedes_old_queries);
        add_async_test("XEP0045_role_change_propagates_iq_error", test_role_change_propagates_iq_error);
        add_async_test("XEP0045_mutation_rejects_missing_room_sender", test_mutation_rejects_missing_room_sender);
        add_async_test("XEP0045_config_rejects_wrong_room_sender", test_config_rejects_wrong_room_sender);
        add_async_test("XEP0045_affiliation_query_accepts_missing_room_sender", test_affiliation_query_accepts_missing_room_sender);
        add_async_test("XEP0045_affiliation_query_rejects_malformed_payload_atomically", test_affiliation_query_rejects_malformed_payload_atomically);
        add_async_test("XEP0045_bare_affiliation_change_updates_snapshot_after_success", test_bare_affiliation_change_updates_snapshot_after_success);
        add_async_test("XEP0045_bare_affiliation_change_updates_live_projection_after_success", test_bare_affiliation_change_updates_live_projection_after_success);
        add_async_test("XEP0045_presence_keeps_bare_affiliation_snapshot_current", test_presence_keeps_bare_affiliation_snapshot_current);
        add_async_test("XEP0045_explicit_none_is_known_only_while_live", test_explicit_none_is_known_only_while_live);
        add_async_test("XEP0045_room_exit_invalidates_only_live_room_projection",
            test_room_exit_invalidates_only_live_room_projection);
        add_async_test("XEP0045_local_exit_clears_only_room_presence_bucket",
            test_local_exit_clears_only_room_presence_bucket);
    }

    private void test_full_occupant_affiliation_uses_real_jid_member_list(Gee.TestFinishedCallback cb) {
        test_full_occupant_affiliation_uses_real_jid_member_list_async.begin(cb);
    }

    private async void test_full_occupant_affiliation_uses_real_jid_member_list_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var occupant = new Jid(ALICE_OCCUPANT);

            yield enter_room(stream, room);
            stream.member_query_jid = "alice@example.test";
            yield query_members(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL, null, "participant", false));

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.MEMBER,
                "XEP-0045: a full room/nick occupant must resolve the known bare real-JID member affiliation");
            Gee.List<Jid> offline_members = ((!) flag).get_offline_members(room);
            fail_if(offline_members.size != 1 || offline_members[0].is_full() ||
                    !offline_members[0].equals_bare(new Jid("alice@example.test")),
                "Offline member projection must contain one deduplicated bare real JID, never room/nick");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC affiliation test: $(e.message)");
        }
        cb();
    }

    private void test_rejoin_preserves_real_jid_member_list_affiliation(Gee.TestFinishedCallback cb) {
        test_rejoin_preserves_real_jid_member_list_affiliation_async.begin(cb);
    }

    private void test_privacy_change_clears_disclosed_real_jids(
            Gee.TestFinishedCallback cb) {
        test_privacy_change_clears_disclosed_real_jids_async.begin(cb);
    }

    private async void test_privacy_change_clears_disclosed_real_jids_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid(ALICE_OCCUPANT);
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            module.occupant_presence_events_enabled = true;
            int cleared_signals = 0;
            int privacy_controls = 0;
            int privacy_revocations = 0;
            module.received_occupant_jid.connect((_, occupant, real_jid) => {
                if (occupant.equals_bare(room) && real_jid == null) {
                    cleared_signals++;
                }
            });
            module.received_occupant_presence.connect((_, event) => {
                if (event.kind == Xep.Muc.OccupantPresenceKind.CONTROL &&
                        event.real_jid_known && event.real_bare_jid == null) {
                    privacy_controls++;
                }
            });
            module.room_real_jid_visibility_revoked.connect((_, changed_room) => {
                if (changed_room.equals_bare(room)) privacy_revocations++;
            });

            yield enter_room(stream, room);
            stream.member_query_jid = "alice@example.test";
            yield query_complete_affiliation_snapshot(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "member", "participant", false));
            Xep.Muc.Flag flag = (!) stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_real_jid(alice) == null,
                "Test setup must cache the disclosed occupant real JID");

            stream.disco_semi_anonymous = true;
            stream.emit_message(build_muc_config_status_message("173"));
            drain_main_context();

            fail_if(flag.get_real_jid(alice) == null ||
                    !flag.has_affiliation(room,
                        new Jid("alice@example.test")),
                "A moderator must retain disclosed JIDs in a semi-anonymous room");
            fail_if(cleared_signals != 0 || privacy_controls != 0 ||
                    privacy_revocations != 0,
                "Status 173 must not revoke a moderator's permitted identity view");

            // Some services omit status 110 on a later self-role update. The
            // known own nickname must still make this a privacy boundary.
            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "participant", false));

            fail_if(flag.get_real_jid(alice) != null ||
                    flag.has_affiliation(room,
                        new Jid("alice@example.test")),
                "A moderator-to-participant transition must revoke disclosed live and bare JIDs");
            fail_if(flag.get_real_jid(new Jid(OWNER_OCCUPANT)) != null,
                "The self-demotion presence must not reintroduce the moderator's real JID after revocation");
            fail_if(cleared_signals < 1 || privacy_controls < 1,
                "Privacy revocation must reach compatibility and worker consumers");
            fail_if(privacy_revocations != 1,
                "One role privacy boundary must emit one room invalidation");
            fail_if(flag.get_affiliation(room, alice) !=
                    Xep.Muc.Affiliation.MEMBER ||
                    flag.get_occupant_role(alice) !=
                        Xep.Muc.Role.PARTICIPANT,
                "Privacy revocation must preserve room/nick affiliation and role state");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC privacy-change test: $(e.message)");
        }
        cb();
    }

    private void test_forged_privacy_change_is_ignored(
            Gee.TestFinishedCallback cb) {
        test_forged_privacy_change_is_ignored_async.begin(cb);
    }

    private void test_presence_replay_requires_join_and_is_merge_only(
            Gee.TestFinishedCallback cb) {
        test_presence_replay_requires_join_and_is_merge_only_async.begin(cb);
    }

    private async void test_presence_replay_requires_join_and_is_merge_only_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            fail_if(module.request_occupant_presence_resync(stream, room) ||
                    stream.occupant_presence_resync_count != 0,
                "An occupant replay must require an actually joined room");

            yield enter_room(stream, room);
            var alice = new Jid(ALICE_OCCUPANT);
            StanzaNode initial = build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "member", "participant", false);
            initial.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                    .put_attribute("uri", "urn:xmpp:hats:initial")
                    .put_attribute("title", "Initial")));
            stream.emit_presence(initial);

            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_real_jid(alice) == null ||
                    flag.get_affiliation(room, alice) !=
                        Xep.Muc.Affiliation.MEMBER ||
                    flag.get_occupant_role(alice) !=
                        Xep.Muc.Role.PARTICIPANT ||
                    flag.get_occupant_hats(alice).size != 1,
                "Replay audit setup must contain one complete live occupant");

            fail_if(!module.request_occupant_presence_resync(stream, room) ||
                    stream.occupant_presence_resync_count != 1,
                "A joined room must send one best-effort occupant replay request");
            StanzaNode? resync = stream.last_occupant_presence_resync;
            StanzaNode? x = resync != null
                ? ((!) resync).get_subnode("x", NS_MUC) : null;
            StanzaNode? history = x != null
                ? ((!) x).get_subnode("history", NS_MUC) : null;
            fail_if(resync == null ||
                    ((!) resync).get_attribute("to") != OWNER_OCCUPANT ||
                    history == null ||
                    ((!) history).get_attribute("maxchars") != "0",
                "Occupant replay must be tagged join presence to room/ownnick with history maxchars=0");

            // A service only SHOULD answer the replay. No response must leave
            // the complete live projection untouched.
            fail_if(flag.get_real_jid(alice) == null ||
                    flag.get_affiliation(room, alice) !=
                        Xep.Muc.Affiliation.MEMBER ||
                    flag.get_occupant_role(alice) !=
                        Xep.Muc.Role.PARTICIPANT ||
                    flag.get_occupant_hats(alice).size != 1,
                "A missing replay response must never erase valid occupant data");

            StanzaNode update = build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "admin", "moderator", false);
            update.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                    .put_attribute("uri", "urn:xmpp:hats:updated")
                    .put_attribute("title", "Updated")));
            stream.emit_presence(update);
            Gee.List<Xep.Muc.Hat> updated_hats =
                flag.get_occupant_hats(alice);
            fail_if(flag.get_affiliation(room, alice) !=
                        Xep.Muc.Affiliation.ADMIN ||
                    flag.get_occupant_role(alice) !=
                        Xep.Muc.Role.MODERATOR ||
                    updated_hats.size != 1 ||
                    updated_hats[0].uri != "urn:xmpp:hats:updated",
                "Later authoritative server presences must merge through the normal occupant parser");
        } catch (Error error) {
            fail_if_reached(@"Unexpected MUC presence replay error: $(error.message)");
        }
        cb();
    }

    private void test_live_config_status_replay_matrix(
            Gee.TestFinishedCallback cb) {
        test_live_config_status_replay_matrix_async.begin(cb);
    }

    private async void test_live_config_status_replay_matrix_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            yield enter_room(stream, room);
            stream.hold_disco_results = true;

            stream.emit_message(build_muc_config_status_message("104"));
            drain_main_context();
            fail_if(stream.occupant_presence_resync_count != 1,
                "A live status 104 must request one occupant replay");

            stream.emit_message(build_muc_config_status_message("102"));
            drain_main_context();
            fail_if(stream.occupant_presence_resync_count != 2,
                "A live status 102 must request one occupant replay");

            StanzaNode combined = build_muc_config_status_message("104");
            StanzaNode? x = combined.get_subnode("x", NS_MUC_USER);
            fail_if(x == null,
                "Combined live-status audit requires a MUC user payload");
            ((!) x).put_node(new StanzaNode.build("status", NS_MUC_USER)
                .put_attribute("code", "172"));
            stream.emit_message(combined);
            drain_main_context();
            fail_if(stream.occupant_presence_resync_count != 3,
                "One live message containing status 104 and 172 must request exactly one replay");

            stream.emit_message(build_muc_config_status_message("170"));
            stream.emit_message(build_muc_config_status_message("171"));
            stream.emit_message(build_muc_config_status_message("103"));
            drain_main_context();
            fail_if(stream.occupant_presence_resync_count != 3,
                "Statuses 170, 171, and 103 must not request occupant replay");
        } catch (Error error) {
            fail_if_reached(@"Unexpected live MUC config-status error: $(error.message)");
        }
        cb();
    }

    private void test_confirmed_presence_broadcast_removes_only_known_excluded_roles(
            Gee.TestFinishedCallback cb) {
        test_confirmed_presence_broadcast_removes_only_known_excluded_roles_async.begin(cb);
    }

    private async void test_confirmed_presence_broadcast_removes_only_known_excluded_roles_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            yield enter_room(stream, room);

            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            Presence.Flag presence_flag = stream.get_flag<Presence.Flag>(
                Presence.Flag.IDENTITY);
            var included = new Jid(ROOM + "/included");
            var excluded = new Jid(ROOM + "/excluded");
            var unknown = new Jid(ROOM + "/unknown");
            var own = new Jid(OWNER_OCCUPANT);

            stream.emit_presence(build_muc_presence(included.to_string(),
                "included@example.test/device", "member", "participant",
                false));
            stream.emit_presence(build_muc_presence(excluded.to_string(),
                "excluded@example.test/device", "admin", "moderator",
                false));
            StanzaNode unknown_node = new StanzaNode.build("presence")
                .put_attribute("from", unknown.to_string())
                .put_attribute("to", LOCAL_FULL);
            presence_flag.add_presence(new Presence.Stanza.from_stanza(
                unknown_node, new Jid(LOCAL_FULL)));

            fail_if(!presence_has_resource(presence_flag, room, included) ||
                    !presence_has_resource(presence_flag, room, excluded) ||
                    !presence_has_resource(presence_flag, room, unknown) ||
                    !presence_has_resource(presence_flag, room, own) ||
                    flag.has_occupant_role(unknown),
                "Presence-broadcast audit setup must contain included, excluded, self, and unknown-role occupants");

            int removed = module.apply_confirmed_presence_broadcast_roles(
                stream, room, { "participant" });
            fail_if(removed != 1 ||
                    !presence_has_resource(presence_flag, room, included) ||
                    presence_has_resource(presence_flag, room, excluded) ||
                    !presence_has_resource(presence_flag, room, unknown) ||
                    !presence_has_resource(presence_flag, room, own),
                "A verified presence-broadcast restriction must remove only known excluded non-self roles");
            fail_if(flag.has_occupant_role(excluded) ||
                    flag.get_real_jid(excluded) != null ||
                    !flag.has_occupant_role(included) ||
                    flag.get_occupant_role(included) !=
                        Xep.Muc.Role.PARTICIPANT ||
                    !flag.has_occupant_role(own),
                "Targeted presence-broadcast cleanup must preserve included and self metadata while removing excluded metadata");
        } catch (Error error) {
            fail_if_reached(@"Unexpected confirmed presence-broadcast error: $(error.message)");
        }
        cb();
    }

    private void test_confirmed_hats_disable_clears_hats_without_removing_occupants(
            Gee.TestFinishedCallback cb) {
        test_confirmed_hats_disable_clears_hats_without_removing_occupants_async.begin(cb);
    }

    private async void test_confirmed_hats_disable_clears_hats_without_removing_occupants_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid(ALICE_OCCUPANT);
            yield enter_room(stream, room);

            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            Presence.Flag presence_flag = stream.get_flag<Presence.Flag>(
                Presence.Flag.IDENTITY);
            StanzaNode presence = build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "member", "participant", false);
            presence.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                    .put_attribute("uri", "urn:xmpp:hats:support")
                    .put_attribute("title", "Support")));
            stream.emit_presence(presence);
            fail_if(flag.get_occupant_hats(alice).size != 1 ||
                    !presence_has_resource(presence_flag, room, alice),
                "Hats-disable audit setup must contain one live hatted occupant");

            int cleared = module.clear_confirmed_room_hats(stream, room);
            fail_if(cleared != 1 ||
                    !flag.get_occupant_hats(alice).is_empty ||
                    !presence_has_resource(presence_flag, room, alice) ||
                    flag.get_real_jid(alice) == null ||
                    flag.get_affiliation(room, alice) !=
                        Xep.Muc.Affiliation.MEMBER ||
                    flag.get_occupant_role(alice) !=
                        Xep.Muc.Role.PARTICIPANT,
                "Verified Hats disable must clear Hats without removing or degrading the occupant");
        } catch (Error error) {
            fail_if_reached(@"Unexpected confirmed Hats-disable error: $(error.message)");
        }
        cb();
    }

    private void test_confirmed_whois_applies_authoritative_privacy(
            Gee.TestFinishedCallback cb) {
        test_confirmed_whois_applies_authoritative_privacy_async.begin(cb);
    }

    private async void test_confirmed_whois_applies_authoritative_privacy_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid(ALICE_OCCUPANT);
            var alice_bare = new Jid("alice@example.test");
            yield enter_room(stream, room);
            drain_main_context();

            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            fail_if(!module.apply_confirmed_room_whois(stream, room,
                    { "anyone" }),
                "UNKNOWN-to-ANYONE whois setup must report replay need");
            stream.member_query_jid = alice_bare.to_string();
            yield query_complete_affiliation_snapshot(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "member", "participant", false));
            fail_if(flag.get_real_jid(alice) == null ||
                    !flag.has_affiliation(room, alice_bare),
                "whois audit setup must contain live and bare disclosed real-JID state");

            fail_if(module.apply_confirmed_room_whois(stream, room,
                    { "none" }) ||
                    flag.get_real_jid_visibility(room) !=
                        Xep.Muc.RealJidVisibility.NOBODY ||
                    flag.get_real_jid(alice) != null ||
                    flag.has_affiliation(room, alice_bare) ||
                    flag.get_affiliation(room, alice) !=
                        Xep.Muc.Affiliation.MEMBER ||
                    flag.get_occupant_role(alice) !=
                        Xep.Muc.Role.PARTICIPANT,
                "ANYONE-to-none must scrub live and bare real JIDs while preserving occupant state");

            fail_if(!module.apply_confirmed_room_whois(stream, room,
                    { "moderators" }) ||
                    flag.get_real_jid_visibility(room) !=
                        Xep.Muc.RealJidVisibility.MODERATORS,
                "none-to-moderators for the own moderator must report replay need");

            fail_if(module.apply_confirmed_room_whois(stream, room,
                        { "server-extension" }) ||
                    module.apply_confirmed_room_whois(stream, room,
                        { "anyone", "moderators" }) ||
                    flag.get_real_jid_visibility(room) !=
                        Xep.Muc.RealJidVisibility.MODERATORS,
                "Unknown and multi-valued whois forms must be privacy-authority no-ops");
        } catch (Error error) {
            fail_if_reached(@"Unexpected confirmed whois error: $(error.message)");
        }
        cb();
    }

    private static bool presence_has_resource(Presence.Flag flag, Jid room,
            Jid occupant) {
        Gee.List<Jid>? resources = flag.get_resources(room);
        if (resources == null) return false;
        foreach (Jid resource in (!) resources) {
            if (resource.equals(occupant)) return true;
        }
        return false;
    }

    private void test_status_100_is_visibility_authority(
            Gee.TestFinishedCallback cb) {
        test_status_100_is_visibility_authority_async.begin(cb);
    }

    private async void test_status_100_is_visibility_authority_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            yield enter_room(stream, room);
            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            stream.hold_disco_results = true;
            stream.emit_message(build_muc_config_status_message("173"));
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.MODERATORS,
                "Status 100 test setup must start semi-anonymous");

            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true,
                false, true));
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.ANYONE,
                "Self-presence status 100 must establish non-anonymous visibility");
        } catch (Error error) {
            fail_if_reached(@"Unexpected status 100 error: $(error.message)");
        }
        cb();
    }

    private void test_stale_status_100_is_ignored(
            Gee.TestFinishedCallback cb) {
        test_stale_status_100_is_ignored_async.begin(cb);
    }

    private async void test_stale_status_100_is_ignored_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            yield enter_room(stream, room);
            stream.hold_disco_results = true;
            stream.emit_message(build_muc_config_status_message("173"));
            drain_main_context();

            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            StanzaNode stale = build_muc_presence(ROOM + "/old-owner",
                "owner@example.test/old", "owner", "moderator", true,
                false, true).put_attribute("id", "stale-enter-id");
            stream.emit_presence(stale);
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.MODERATORS,
                "A stale status-100 self-presence must not expose real JIDs");

            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true));
            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true));
        } catch (Error error) {
            fail_if_reached(@"Unexpected stale status-100 error: $(error.message)");
        }
        cb();
    }

    private void test_status_100_message_requires_active_enter(
            Gee.TestFinishedCallback cb) {
        test_status_100_message_requires_active_enter_async.begin(cb);
    }

    private async void test_status_100_message_requires_active_enter_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            stream.hold_disco_results = true;
            stream.hold_join_self_presence = true;
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var join_finished = new Gee.Promise<Xep.Muc.JoinResult?>();
            module.enter.begin(stream, room, "owner", null, null, true, null,
                (_, result) => {
                    join_finished.set_value(module.enter.end(result));
                });
            drain_main_context();

            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_enter_id(room) == null,
                "Status-100 message test must have an active enter");
            stream.emit_message(build_muc_config_status_message("100"));
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.ANYONE,
                "A live status-100 message during active enter must establish JID visibility");
            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true));
            Xep.Muc.JoinResult? join_result = yield
                join_finished.future.wait_async();
            fail_if(join_result == null || ((!) join_result).nick != "owner",
                "The active enter must still complete on current self-presence");

            stream.emit_message(build_muc_config_status_message("173"));
            drain_main_context();
            stream.emit_message(build_muc_config_status_message("100"));
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.MODERATORS,
                "A post-join status-100 message must not change live visibility");
        } catch (Error error) {
            fail_if_reached(@"Unexpected status-100 message error: $(error.message)");
        }
        cb();
    }

    private void test_cancel_after_status_100_message_clears_visibility(
            Gee.TestFinishedCallback cb) {
        test_cancel_after_status_100_message_clears_visibility_async.begin(cb);
    }

    private async void test_cancel_after_status_100_message_clears_visibility_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            stream.hold_disco_results = true;
            stream.hold_join_self_presence = true;
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var changes = new Gee.ArrayList<int>();
            module.room_real_jid_visibility_changed.connect((_, changed_room,
                    visibility) => {
                if (changed_room.equals_bare(room)) changes.add((int) visibility);
            });
            var join_finished = new Gee.Promise<Xep.Muc.JoinResult?>();
            module.enter.begin(stream, room, "owner", null, null, true, null,
                (_, result) => {
                    join_finished.set_value(module.enter.end(result));
                });
            drain_main_context();

            stream.emit_message(build_muc_config_status_message("100"));
            drain_main_context();
            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.ANYONE,
                "Enter-time status 100 must establish the test disclosure");

            module.cancel_enter(stream, room, false);
            Xep.Muc.JoinResult? result = yield join_finished.future.wait_async();
            fail_if(result == null || ((!) result).stanza_error == null,
                "Cancelling the enter must complete its waiter with an error");
            fail_if(flag.get_muc_nick(room) != null ||
                    flag.get_real_jid_visibility(room) !=
                        Xep.Muc.RealJidVisibility.UNKNOWN,
                "A failed initial enter must not retain ANYONE visibility or a joined nick");
            fail_if(changes.size != 2 ||
                    changes[0] != (int) Xep.Muc.RealJidVisibility.ANYONE ||
                    changes[1] != (int) Xep.Muc.RealJidVisibility.UNKNOWN,
                "Status-100 cancellation must emit one disclosure and one cleanup transition");

            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true));
            Presence.Flag presence_flag = stream.get_flag<Presence.Flag>(
                Presence.Flag.IDENTITY);
            fail_if(presence_flag.get_resources(room) != null,
                "A late cancelled self-presence must not recreate the room presence bucket");
        } catch (Error error) {
            fail_if_reached(@"Unexpected status-100 cancel error: $(error.message)");
        }
        cb();
    }

    private void test_real_jid_visibility_signal(
            Gee.TestFinishedCallback cb) {
        test_real_jid_visibility_signal_async.begin(cb);
    }

    private async void test_real_jid_visibility_signal_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            yield enter_room(stream, room);
            stream.hold_disco_results = true;
            var changes = new Gee.ArrayList<int>();
            module.room_real_jid_visibility_changed.connect((_, changed_room,
                    visibility) => {
                if (changed_room.equals_bare(room)) changes.add((int) visibility);
            });

            stream.emit_message(build_muc_config_status_message("173"));
            drain_main_context();
            stream.emit_message(build_muc_config_status_message("172"));
            drain_main_context();
            stream.emit_message(build_muc_config_status_message("172"));
            drain_main_context();
            module.exit(stream, room);

            fail_if(changes.size != 3 ||
                    changes[0] != (int) Xep.Muc.RealJidVisibility.MODERATORS ||
                    changes[1] != (int) Xep.Muc.RealJidVisibility.ANYONE ||
                    changes[2] != (int) Xep.Muc.RealJidVisibility.UNKNOWN,
                "Visibility signal must emit each live state transition exactly once");
        } catch (Error error) {
            fail_if_reached(@"Unexpected visibility-signal error: $(error.message)");
        }
        cb();
    }

    private void test_replayed_privacy_status_messages_are_ignored(
            Gee.TestFinishedCallback cb) {
        test_replayed_privacy_status_messages_are_ignored_async.begin(cb);
    }

    private async void test_replayed_privacy_status_messages_are_ignored_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            yield enter_room(stream, room);
            stream.hold_disco_results = true;
            stream.emit_message(build_muc_config_status_message("173"));
            drain_main_context();
            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);

            StanzaNode delayed = build_muc_config_status_message("172")
                .put_node(new StanzaNode.build("delay",
                    Xep.DelayedDelivery.NS_URI).add_self_xmlns()
                    .put_attribute("stamp", "2026-01-01T00:00:00Z"));
            stream.emit_message(delayed);
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.MODERATORS,
                "A delayed status 172 must not change live room privacy");

            var mam = new MessageArchiveManagement.Module();
            stream.add_module(mam);
            mam.attach(stream);
            MessageArchiveManagement.Flag.get_flag(stream).active_query_ids
                .add("muc-status-history");
            stream.emit_message(build_mam_muc_config_status_message("174",
                "muc-status-history"));
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.MODERATORS,
                "A MAM-replayed status 174 must not change live room privacy");

            stream.emit_message(build_muc_config_status_message("172"));
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.ANYONE,
                "A subsequent live status 172 must still update room privacy");
        } catch (Error error) {
            fail_if_reached(@"Unexpected replayed-status error: $(error.message)");
        }
        cb();
    }

    private void test_fully_anonymous_revokes_moderator_jids_and_survives_disco(
            Gee.TestFinishedCallback cb) {
        test_fully_anonymous_revokes_moderator_jids_and_survives_disco_async.begin(
            cb);
    }

    private async void test_fully_anonymous_revokes_moderator_jids_and_survives_disco_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid(ALICE_OCCUPANT);
            yield enter_room(stream, room);
            drain_main_context();

            stream.member_query_jid = "alice@example.test";
            yield query_complete_affiliation_snapshot(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "member", "participant", false));

            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_real_jid(alice) == null ||
                    !flag.has_affiliation(room,
                        new Jid("alice@example.test")),
                "Test setup must contain both live and bare disclosed JIDs");

            // Hold the automatic disco refreshes so the two privacy boundary
            // effects can be asserted independently of the asynchronous
            // readback. The second response is then the authoritative current
            // generation and intentionally contains no anonymity feature.
            stream.hold_disco_results = true;
            stream.emit_message(build_muc_config_status_message("173"));
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                        Xep.Muc.RealJidVisibility.MODERATORS ||
                    flag.get_real_jid(alice) == null ||
                    !flag.has_affiliation(room,
                        new Jid("alice@example.test")),
                "Status 173 must let the current moderator retain disclosed JIDs");

            stream.emit_message(build_muc_config_status_message("174"));
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                        Xep.Muc.RealJidVisibility.NOBODY ||
                    flag.get_real_jid(alice) != null ||
                    flag.has_affiliation(room,
                        new Jid("alice@example.test")),
                "Status 174 must revoke live and bare disclosed JIDs even for a moderator");
            fail_if(stream.held_disco_result_count != 2,
                "Status 173 and 174 must each schedule one room-info refresh");

            stream.hold_disco_results = false;
            stream.emit_next_held_disco_result(false, -1);
            drain_main_context();
            stream.emit_next_held_disco_result(false, -1);
            drain_main_context();
            fail_if(flag.get_real_jid_visibility(room) !=
                    Xep.Muc.RealJidVisibility.NOBODY,
                "A successful disco readback without an anonymity feature must not weaken an explicit status-174 boundary");
        } catch (Error e) {
            fail_if_reached(@"Unexpected fully-anonymous MUC privacy test error: $(e.message)");
        }
        cb();
    }

    private async void test_forged_privacy_change_is_ignored_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid(ALICE_OCCUPANT);
            yield enter_room(stream, room);
            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "participant", false));
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "member", "participant", false));

            StanzaNode forged = build_muc_config_status_message("173");
            forged.set_attribute("from", ALICE_OCCUPANT);
            stream.emit_message(forged);
            drain_main_context();

            StanzaNode forged_fully_anonymous =
                build_muc_config_status_message("174");
            forged_fully_anonymous.set_attribute("from", ALICE_OCCUPANT);
            stream.emit_message(forged_fully_anonymous);
            drain_main_context();

            Xep.Muc.Flag flag = (!) stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_real_jid(alice) == null ||
                    flag.are_real_jids_moderator_only(room) ||
                    flag.get_real_jid_visibility(room) ==
                        Xep.Muc.RealJidVisibility.NOBODY,
                "A full room/nick sender must not spoof status 173/174 or clear identity state");
        } catch (Error e) {
            fail_if_reached(@"Unexpected forged MUC privacy-change test error: $(e.message)");
        }
        cb();
    }

    private void test_authoritative_missing_jid_clears_identity(
            Gee.TestFinishedCallback cb) {
        test_authoritative_missing_jid_clears_identity_async.begin(cb);
    }

    private async void test_authoritative_missing_jid_clears_identity_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid(ALICE_OCCUPANT);
            yield enter_room(stream, room);
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            module.occupant_presence_events_enabled = true;
            int null_signals = 0;
            bool authoritative_event = false;
            module.received_occupant_jid.connect((_, occupant, real_jid) => {
                if (occupant.equals(alice) && real_jid == null) null_signals++;
            });
            module.received_occupant_presence.connect((_, event) => {
                if (event.occupant_full_jid == ALICE_OCCUPANT &&
                        event.real_jid_known && event.real_bare_jid == null) {
                    authoritative_event = true;
                }
            });

            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "member", "participant", false));
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, null,
                "member", "participant", false));

            Xep.Muc.Flag flag = (!) stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_real_jid(alice) != null || null_signals != 1 ||
                    !authoritative_event,
                "An authoritative item without jid must clear every identity consumer exactly once");
        } catch (Error e) {
            fail_if_reached(@"Unexpected authoritative missing-JID test error: $(e.message)");
        }
        cb();
    }

    private async void test_rejoin_preserves_real_jid_member_list_affiliation_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var occupant = new Jid(ALICE_OCCUPANT);

            yield enter_room(stream, room);
            stream.member_query_jid = "alice@example.test";
            yield query_members(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, null, "admin", "moderator", false));

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.ADMIN,
                "test setup must prefer the live full room/nick affiliation before leave cleanup");

            stream.emit_presence(build_muc_unavailable_presence(ALICE_OCCUPANT));
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL, null, "participant", false));

            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.MEMBER,
                "XEP-0045: a rejoined room/nick occupant must fall back to the real-JID member-list affiliation");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC affiliation rejoin test: $(e.message)");
        }
        cb();
    }

    private void test_unavailable_without_muc_x_clears_live_affiliation(Gee.TestFinishedCallback cb) {
        test_unavailable_without_muc_x_clears_live_affiliation_async.begin(cb);
    }

    private async void test_unavailable_without_muc_x_clears_live_affiliation_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var occupant = new Jid(ALICE_OCCUPANT);

            yield enter_room(stream, room);
            stream.member_query_jid = "alice@example.test";
            yield query_members(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, null, "admin", "moderator", false));

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.ADMIN,
                "test setup must prefer the live full room/nick affiliation before leave cleanup");

            stream.emit_presence(build_plain_unavailable_presence(ALICE_OCCUPANT));
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL, null, "participant", false));

            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.MEMBER,
                "XEP-0045: unavailable without muc#user x must still clear stale full room/nick affiliation");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC plain-unavailable test: $(e.message)");
        }
        cb();
    }

    private void test_member_query_preserves_live_full_occupant_affiliation(Gee.TestFinishedCallback cb) {
        test_member_query_preserves_live_full_occupant_affiliation_async.begin(cb);
    }

    private void test_immutable_occupant_presence_event(Gee.TestFinishedCallback cb) {
        test_immutable_occupant_presence_event_async.begin(cb);
    }

    private void test_empty_photo_is_authoritative_avatar_reset(
            Gee.TestFinishedCallback cb) {
        test_empty_photo_is_authoritative_avatar_reset_async.begin(cb);
    }

    private async void test_empty_photo_is_authoritative_avatar_reset_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            yield enter_room(stream, room);

            var events = new Gee.ArrayList<Xep.Muc.OccupantPresenceEvent>();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            ((!) module).occupant_presence_events_enabled = true;
            ((!) module).received_occupant_presence.connect(
                (event_stream, event) => {
                    events.add(event);
                });

            StanzaNode empty_photo = build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "member", "participant", false);
            empty_photo.put_node(new StanzaNode.build("x", NS_VCARD_UPDATE)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("photo", NS_VCARD_UPDATE)));
            stream.emit_presence(empty_photo);

            StanzaNode no_photo = build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "member", "participant", false);
            no_photo.put_node(new StanzaNode.build("x", NS_VCARD_UPDATE)
                .add_self_xmlns());
            stream.emit_presence(no_photo);

            fail_if(events.size != 2,
                "Both avatar parser cases must emit an occupant event");
            if (events.size == 2) {
                fail_if(events[0].avatar_hash == null ||
                        events[0].avatar_hash != "",
                    "XEP-0153: an empty <photo/> must be an authoritative empty avatar hash");
                fail_if(events[1].avatar_hash != null,
                    "XEP-0153: presence without <photo> must not fabricate an avatar update");
            }
        } catch (Error error) {
            fail_if_reached(@"Unexpected error in empty XEP-0153 photo test: $(error.message)");
        }
        cb();
    }

    private async void test_immutable_occupant_presence_event_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            yield enter_room(stream, room);

            var events = new Gee.ArrayList<Xep.Muc.OccupantPresenceEvent>();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            ((!) module).received_occupant_presence.connect((event_stream, event) => {
                events.add(event);
            });

            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "admin", "moderator", false));
            fail_if(events.size != 0,
                "Atomic occupant events must stay disabled outside explicit worker validation");
            ((!) module).occupant_presence_events_enabled = true;

            StanzaNode available = build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "admin", "moderator", false);
            available.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                    .put_attribute("uri", "urn:xmpp:hats:support")
                    .put_attribute("title", "Support")
                    .put_attribute("hue", "120")));
            available.put_node(new StanzaNode.build("x", NS_VCARD_UPDATE)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("photo", NS_VCARD_UPDATE)
                    .put_node(new StanzaNode.text("sha1-avatar"))));
            stream.emit_presence(available);

            fail_if(events.size != 1,
                "One parsed available presence must emit one atomic occupant event");
            if (events.size == 1) {
                Xep.Muc.OccupantPresenceEvent event = events[0];
                fail_if(event.kind != Xep.Muc.OccupantPresenceKind.AVAILABLE,
                    "Available presence kind must be preserved");
                fail_if_not_eq_str(event.occupant_full_jid, ALICE_OCCUPANT,
                    "Atomic event occupant full JID");
                fail_if_not_eq_str(event.room_bare_jid, ROOM,
                    "Atomic event room bare JID");
                fail_if_not_eq_str(event.real_bare_jid, "alice@example.test",
                    "Atomic event must normalize the real JID to bare form");
                fail_if(!event.affiliation_known ||
                        event.affiliation != Xep.Muc.Affiliation.ADMIN,
                    "Atomic event must preserve authoritative affiliation");
                fail_if(!event.role_known || event.role != Xep.Muc.Role.MODERATOR,
                    "Atomic event must preserve authoritative role");
                fail_if_not_eq_str(event.avatar_hash, "sha1-avatar",
                    "Atomic event must preserve the XEP-0153 avatar hash");
                string[] hats = event.dup_hat_uris();
                fail_if(hats.length != 1 || hats[0] != "urn:xmpp:hats:support",
                    "Atomic event must preserve parsed hats");
                if (hats.length == 1) hats[0] = "mutated";
                fail_if(event.dup_hat_uris()[0] != "urn:xmpp:hats:support",
                    "Atomic event array access must return a defensive copy");
                string[] hues = event.dup_hat_hues();
                fail_if(hues.length != 1 || hues[0] != "120",
                    "Atomic event must preserve the parsed hat hue");
            }

            stream.emit_presence(build_plain_unavailable_presence(ALICE_OCCUPANT));
            fail_if(events.size != 2 ||
                    events[1].kind != Xep.Muc.OccupantPresenceKind.UNAVAILABLE,
                "Unavailable without muc#user payload must still emit a removal event");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in immutable MUC event test: $(e.message)");
        }
        cb();
    }

    private async void test_member_query_preserves_live_full_occupant_affiliation_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var occupant = new Jid(ALICE_OCCUPANT);

            yield enter_room(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, null, "member", "participant", false));

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.MEMBER,
                "test setup must store the live full room/nick member affiliation");

            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            Gee.List<Jid>? members = yield ((!) module).query_affiliation(stream, room, "member");
            fail_if(members == null, "MUC member query test setup must complete");
            fail_if(((!) members).size != 0, "MUC member query test setup must return an empty server list");

            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.MEMBER,
                "XEP-0045: refreshing the server member list must not clear live full room/nick affiliation");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC member-query live-affiliation test: $(e.message)");
        }
        cb();
    }

    private void test_self_ping_timeout_returns_unknown(Gee.TestFinishedCallback cb) {
        test_self_ping_timeout_returns_unknown_async.begin(cb);
    }

    private async void test_self_ping_timeout_returns_unknown_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_ping_timeout_stream();

            Xep.MucSelfPing.JoinState join_state = yield Xep.MucSelfPing.get_join_state(stream, new Jid(OWNER_OCCUPANT));

            fail_if(join_state != Xep.MucSelfPing.JoinState.UNKNOWN, "XEP-0410: timed-out self-ping must be treated as unknown, not not-joined");
            fail_if(stream.written_nodes.size != 1, "XEP-0410: self-ping should write exactly one IQ request");
            fail_if_not_eq_str(stream.written_nodes[0].get_attribute("type"), "get", "XEP-0410: self-ping must be an IQ get");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC self-ping timeout test: $(e.message)");
        }
        cb();
    }

    private void test_iq_write_failure_completes_waiter(Gee.TestFinishedCallback cb) {
        test_iq_write_failure_completes_waiter_async.begin(cb);
    }

    private async void test_iq_write_failure_completes_waiter_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_iq_write_failure_stream();
            var iq_module = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
            var iq = new Iq.Stanza.get(new StanzaNode.build("query", NS_DISCO_INFO).add_self_xmlns()) {
                to = new Jid("example.test")
            };

            try {
                yield ((!) iq_module).send_iq_async(stream, iq);
                fail_if_reached("IQ write failure must not be reported as a successful IQ result");
            } catch (IOError.CLOSED e) {
                fail_if(stream.written_nodes.size != 1, "IQ write failure test setup must try exactly one write");
            } catch (Error e) {
                fail_if_reached(@"IQ write failure must propagate the write error, got: $(e.message)");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in IQ write failure test: $(e.message)");
        }
        cb();
    }

    private void test_enter_stream_detach_completes_waiter(Gee.TestFinishedCallback cb) {
        test_enter_stream_detach_completes_waiter_async.begin(cb);
    }

    private async void test_enter_stream_detach_completes_waiter_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_enter_detach_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);

            Xep.Muc.JoinResult? result = yield ((!) module).enter(stream, new Jid(ROOM), "owner", null, null, true, null);

            fail_if(result == null, "MUC enter must complete when the stream detaches");
            fail_if(((!) result).stanza_error != ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT,
                "MUC enter stream detach must be surfaced as a join stanza error");
            fail_if(!stream.wrote_join_presence, "MUC enter detach test setup must write the join presence");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC enter detach test: $(e.message)");
        }
        cb();
    }

    private void test_enter_error_without_id_completes_waiter(Gee.TestFinishedCallback cb) {
        test_enter_error_without_id_completes_waiter_async.begin(cb);
    }

    private async void test_enter_error_without_id_completes_waiter_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_enter_error_without_id_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);

            Xep.Muc.JoinResult? result = yield ((!) module).enter(stream, new Jid(ROOM), "owner", null, null, true, null);

            fail_if(result == null, "MUC enter must complete on matching presence error without reflected id");
            fail_if(((!) result).muc_error != Xep.Muc.MucEnterError.NICK_CONFLICT,
                "MUC enter must map matching id-less conflict presence errors");
            fail_if(!stream.wrote_join_presence, "MUC enter error test setup must write the join presence");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC enter error without id test: $(e.message)");
        }
        cb();
    }

    private void test_enter_error_with_mismatched_id_is_ignored(Gee.TestFinishedCallback cb) {
        test_enter_error_with_mismatched_id_is_ignored_async.begin(cb);
    }

    private async void test_enter_error_with_mismatched_id_is_ignored_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_enter_mismatched_error_id_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);

            Xep.Muc.JoinResult? result = yield ((!) module).enter(stream, new Jid(ROOM), "owner", null, null, true, null);

            fail_if(result == null, "MUC enter must continue after a mismatched presence error id");
            fail_if(((!) result).muc_error != null, "MUC enter must ignore a presence error with an unrelated id");
            fail_if(((!) result).nick != "owner", "MUC enter must still complete on the matching self-presence");
            fail_if(!stream.wrote_join_presence, "MUC enter mismatched id test setup must write the join presence");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC enter mismatched id test: $(e.message)");
        }
        cb();
    }

    private void test_enter_bare_room_error_without_id_completes_waiter(Gee.TestFinishedCallback cb) {
        test_enter_bare_room_error_without_id_completes_waiter_async.begin(cb);
    }

    private async void test_enter_bare_room_error_without_id_completes_waiter_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_enter_bare_error_without_id_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);

            Xep.Muc.JoinResult? result = yield ((!) module).enter(stream, new Jid(ROOM), "owner", null, null, true, null);

            fail_if(result == null, "MUC enter must complete on matching bare-room presence error without reflected id");
            fail_if(((!) result).muc_error != Xep.Muc.MucEnterError.ROOM_DOESNT_EXIST,
                "MUC enter must map matching id-less bare-room item-not-found errors");
            fail_if(!stream.wrote_join_presence, "MUC enter bare-room error test setup must write the join presence");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC enter bare-room error without id test: $(e.message)");
        }
        cb();
    }

    private void test_enter_presence_without_110_is_ignored(Gee.TestFinishedCallback cb) {
        test_enter_presence_without_110_is_ignored_async.begin(cb);
    }

    private async void test_enter_presence_without_110_is_ignored_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_enter_presence_without_110_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);

            Xep.Muc.JoinResult? result = yield ((!) module).enter(stream, new Jid(ROOM), "owner", null, null, true, null);

            fail_if(result == null, "MUC enter must continue after a non-self presence with the requested nick");
            fail_if(((!) result).nick != "owner", "MUC enter must complete only on the later self-presence with status 110");
            fail_if(!((!) result).newly_created, "MUC enter must ignore the first no-110 presence and use the later self-presence result");
            fail_if(!stream.wrote_join_presence, "MUC enter no-110 test setup must write the join presence");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC enter no-110 test: $(e.message)");
        }
        cb();
    }

    private void test_enter_completion_is_atomic_and_reentrant_exit_safe(
            Gee.TestFinishedCallback cb) {
        test_enter_completion_is_atomic_and_reentrant_exit_safe_async.begin(cb);
    }

    private async void test_enter_completion_is_atomic_and_reentrant_exit_safe_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var own_occupant = new Jid(OWNER_OCCUPANT);
            stream.hold_join_self_presence = true;
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            Xep.Muc.Flag flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            module.occupant_presence_events_enabled = true;
            var joined = new Gee.Promise<Xep.Muc.JoinResult?>();
            bool callback_saw_complete_state = false;
            bool affiliation_signal_published = false;
            bool atomic_presence_published = false;
            bool exit_started = false;
            int available_events_after_exit = 0;
            module.received_occupant_affiliation.connect((_, occupant,
                    affiliation) => {
                if (occupant.equals(own_occupant) &&
                        affiliation == Xep.Muc.Affiliation.OWNER) {
                    affiliation_signal_published = true;
                }
            });
            module.received_occupant_presence.connect((_, event) => {
                if (event.occupant_full_jid == OWNER_OCCUPANT &&
                        event.is_self_presence &&
                        event.kind ==
                            Xep.Muc.OccupantPresenceKind.AVAILABLE) {
                    if (exit_started) {
                        available_events_after_exit++;
                    } else {
                        atomic_presence_published =
                            event.affiliation_known &&
                            event.affiliation ==
                                Xep.Muc.Affiliation.OWNER &&
                            event.role_known &&
                            event.role == Xep.Muc.Role.MODERATOR &&
                            event.real_bare_jid == "owner@example.test";
                    }
                }
            });

            module.enter.begin(stream, room, "owner", null, null, true, null,
                (_, result) => {
                    Xep.Muc.JoinResult? join_result = module.enter.end(result);
                    Jid? real_jid = flag.get_real_jid(own_occupant);
                    callback_saw_complete_state =
                        affiliation_signal_published &&
                        atomic_presence_published &&
                        flag.has_affiliation(room, own_occupant) &&
                        flag.get_affiliation(room, own_occupant) ==
                            Xep.Muc.Affiliation.OWNER &&
                        flag.has_occupant_role(own_occupant) &&
                        flag.get_occupant_role(own_occupant) ==
                            Xep.Muc.Role.MODERATOR &&
                        real_jid != null &&
                        ((!) real_jid).bare_jid.to_string() ==
                            "owner@example.test";
                    exit_started = true;
                    module.exit(stream, room, "owner");
                    joined.set_value(join_result);
                });
            drain_main_context();

            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true,
                true));
            Xep.Muc.JoinResult? result = yield joined.future.wait_async();

            fail_if(result == null || !((!) result).newly_created,
                "A status-201 self-presence must complete a newly-created-room join");
            fail_if(!callback_saw_complete_state,
                "MUC enter completion must follow the complete self-presence state");
            fail_if(flag.get_muc_nick(room) != null ||
                    flag.has_affiliation(room, own_occupant) ||
                    flag.has_occupant_role(own_occupant) ||
                    flag.get_real_jid(own_occupant) != null,
                "A reentrant exit must leave no recreated MUC self state");
            fail_if(available_events_after_exit != 0,
                "No AVAILABLE occupant event may be emitted after the reentrant exit");
        } catch (Error e) {
            fail_if_reached(@"Unexpected atomic MUC enter error: $(e.message)");
        }
        cb();
    }

    private void test_cancel_enter_completes_waiter_and_allows_retry(Gee.TestFinishedCallback cb) {
        test_cancel_enter_completes_waiter_and_allows_retry_async.begin(cb);
    }

    private void test_room_configuration_submits_all_changed_fields(Gee.TestFinishedCallback cb) {
        test_room_configuration_submits_all_changed_fields_async.begin(cb);
    }

    private void test_late_cancelled_self_preserves_same_jid_rejoin_cache(
            Gee.TestFinishedCallback cb) {
        test_late_cancelled_self_preserves_same_jid_rejoin_cache_async.begin(cb);
    }

    private async void test_late_cancelled_self_preserves_same_jid_rejoin_cache_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var own_occupant = new Jid(OWNER_OCCUPANT);
            stream.hold_join_self_presence = true;
            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            Xep.Muc.Flag muc_flag = (!) stream.get_flag<Xep.Muc.Flag>(
                Xep.Muc.Flag.IDENTITY);
            Presence.Flag presence_flag = stream.get_flag<Presence.Flag>(
                Presence.Flag.IDENTITY);

            var cancelled_result = new Gee.Promise<Xep.Muc.JoinResult?>();
            module.enter.begin(stream, room, "owner", null, null, true, null,
                (_, result) => {
                    cancelled_result.set_value(module.enter.end(result));
                });
            drain_main_context();
            string? cancelled_id = muc_flag.get_enter_id(room);
            fail_if(cancelled_id == null,
                "Cancelled-enter admission test must capture the first enter ID");
            module.cancel_enter(stream, room, false);
            yield cancelled_result.future.wait_async();

            var second_cancelled_result =
                new Gee.Promise<Xep.Muc.JoinResult?>();
            module.enter.begin(stream, room, "owner", null, null, true, null,
                (_, result) => {
                    second_cancelled_result.set_value(module.enter.end(result));
                });
            drain_main_context();
            string? second_cancelled_id = muc_flag.get_enter_id(room);
            fail_if(second_cancelled_id == null ||
                    second_cancelled_id == cancelled_id,
                "Second cancelled enter must use another exact ID");
            module.cancel_enter(stream, room, false);
            yield second_cancelled_result.future.wait_async();

            var rejoin_result = new Gee.Promise<Xep.Muc.JoinResult?>();
            module.enter.begin(stream, room, "owner", null, null, true, null,
                (_, result) => {
                    rejoin_result.set_value(module.enter.end(result));
                });
            drain_main_context();
            string? rejoin_id = muc_flag.get_enter_id(room);
            fail_if(rejoin_id == null || rejoin_id == cancelled_id,
                "Same-nick rejoin must use a fresh enter ID");

            StanzaNode current_self = build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true)
                .put_attribute("id", (!) rejoin_id);
            stream.emit_presence(current_self);
            Xep.Muc.JoinResult? joined = yield rejoin_result.future.wait_async();
            fail_if(joined == null || ((!) joined).nick != "owner",
                "Same-nick rejoin must complete before the old self-presence arrives");

            Presence.Stanza? current_cached = presence_flag.get_presence(
                own_occupant);
            fail_if(current_cached == null || ((!) current_cached).id != rejoin_id,
                "Confirmed rejoin self-presence must be the active cache generation");

            int raw_presence_dispatches = 0;
            int available_dispatches = 0;
            int show_dispatches = 0;
            Presence.Module presence_module = (!)
                stream.get_module<Presence.Module>(Presence.Module.IDENTITY);
            presence_module.received_presence.connect((event_stream,
                    event_presence) => {
                raw_presence_dispatches++;
            });
            presence_module.received_available.connect((event_stream,
                    event_presence) => {
                available_dispatches++;
            });
            presence_module.received_available_show.connect((event_stream,
                    event_jid, event_show) => {
                show_dispatches++;
            });

            StanzaNode stale_self = build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/old", "none", "visitor", true)
                .put_attribute("id", (!) cancelled_id);
            stream.emit_presence(stale_self);
            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/second-old", "none", "visitor", true)
                .put_attribute("id", (!) second_cancelled_id));
            // A duplicate of the first retired ID must remain rejected too.
            stream.emit_presence(stale_self);

            Presence.Stanza? cached_after_stale = presence_flag.get_presence(
                own_occupant);
            fail_if(cached_after_stale == null ||
                    ((!) cached_after_stale) != ((!) current_cached) ||
                    ((!) cached_after_stale).id != rejoin_id,
                "Rejecting an old same-JID self-presence must preserve the confirmed rejoin cache object");
            fail_if(raw_presence_dispatches != 0 ||
                    available_dispatches != 0 || show_dispatches != 0,
                "Rejected old self-presence must be stopped before every generic presence signal");
            fail_if(muc_flag.get_occupant_role(own_occupant) !=
                    Xep.Muc.Role.MODERATOR,
                "Rejected old self-presence must not alter current MUC role state");

            // The same admission gate must keep a cancelled old generation out
            // while the replacement enter is still outstanding.
            var entering_stream = create_attached_muc_stream();
            entering_stream.hold_join_self_presence = true;
            Xep.Muc.Module entering_module = (!)
                entering_stream.get_module<Xep.Muc.Module>(
                    Xep.Muc.Module.IDENTITY);
            Xep.Muc.Flag entering_muc_flag = (!)
                entering_stream.get_flag<Xep.Muc.Flag>(Xep.Muc.Flag.IDENTITY);
            Presence.Flag entering_presence_flag =
                entering_stream.get_flag<Presence.Flag>(Presence.Flag.IDENTITY);

            var old_enter_result = new Gee.Promise<Xep.Muc.JoinResult?>();
            entering_module.enter.begin(entering_stream, room, "owner", null,
                null, true, null, (_, result) => {
                    old_enter_result.set_value(entering_module.enter.end(result));
                });
            drain_main_context();
            string? old_enter_id = entering_muc_flag.get_enter_id(room);
            fail_if(old_enter_id == null,
                "Outstanding-enter admission test must capture its old enter ID");
            entering_module.cancel_enter(entering_stream, room, false);
            yield old_enter_result.future.wait_async();

            var replacement_result = new Gee.Promise<Xep.Muc.JoinResult?>();
            entering_module.enter.begin(entering_stream, room, "owner", null,
                null, true, null, (_, result) => {
                    replacement_result.set_value(
                        entering_module.enter.end(result));
                });
            drain_main_context();
            string? replacement_id = entering_muc_flag.get_enter_id(room);
            fail_if(replacement_id == null || replacement_id == old_enter_id,
                "Replacement enter must retain its own generation ID");

            entering_stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/old", "none", "visitor", true)
                .put_attribute("id", (!) old_enter_id));
            fail_if(entering_presence_flag.get_resources(room) != null ||
                    entering_muc_flag.get_enter_id(room) != replacement_id,
                "Old self-presence during replacement enter must be rejected without cancelling or caching over the new generation");

            entering_stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true)
                .put_attribute("id", (!) replacement_id));
            Xep.Muc.JoinResult? replacement_joined = yield
                replacement_result.future.wait_async();
            Presence.Stanza? replacement_cached =
                entering_presence_flag.get_presence(own_occupant);
            fail_if(replacement_joined == null ||
                    ((!) replacement_joined).nick != "owner" ||
                    replacement_cached == null ||
                    ((!) replacement_cached).id != replacement_id,
                "Replacement enter must still complete and cache its own self-presence after rejecting the old generation");
        } catch (Error error) {
            fail_if_reached(@"Unexpected same-JID presence admission error: $(error.message)");
        }
        cb();
    }

    private async void test_room_configuration_submits_all_changed_fields_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            var form_node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field("muc#roomconfig_changesubject", "boolean", "0"))
                .put_node(build_config_field("muc#roomconfig_roomdesc", "text-single", "Before"))
                .put_node(build_config_field("muc#roomconfig_whois", "list-single", "moderators"));
            Xep.DataForms.DataForm? maybe_form = Xep.DataForms.DataForm.create_from_node(form_node);
            fail_if(maybe_form == null, "room configuration test form must parse");
            Xep.DataForms.DataForm form = (!) maybe_form;

            ((Xep.DataForms.DataForm.BooleanField) form.fields[0]).value = true;
            ((Xep.DataForms.DataForm.TextSingleField) form.fields[1]).value = "After";
            ((Xep.DataForms.DataForm.ListSingleField) form.fields[2]).value = "anyone";

            bool saved = yield ((!) module).set_config_form(stream, new Jid(ROOM), form);
            fail_if_not(saved, "room configuration submit must complete successfully");
            fail_if(stream.last_config_set == null, "room configuration submit must send one owner IQ");

            StanzaNode iq = (!) stream.last_config_set;
            fail_if_not_eq_str(iq.get_attribute("to"), ROOM, "room configuration IQ target");
            StanzaNode? query = iq.get_subnode("query", NS_MUC_OWNER);
            fail_if(query == null, "room configuration IQ must use the MUC owner namespace");
            StanzaNode? submitted = ((!) query).get_subnode("x", Xep.DataForms.NS_URI);
            fail_if(submitted == null || ((!) submitted).get_attribute("type") != "submit",
                "room configuration data form must be submitted as type=submit");
            fail_if_not_eq_str(get_submitted_config_value((!) submitted, "muc#roomconfig_changesubject"), "1",
                "submitted boolean room setting");
            fail_if_not_eq_str(get_submitted_config_value((!) submitted, "muc#roomconfig_roomdesc"), "After",
                "submitted text room setting");
            fail_if_not_eq_str(get_submitted_config_value((!) submitted, "muc#roomconfig_whois"), "anyone",
                "submitted list room setting");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in room configuration submit test: $(e.message)");
        }
        cb();
    }

    private void test_role_change_propagates_iq_error(Gee.TestFinishedCallback cb) {
        test_role_change_propagates_iq_error_async.begin(cb);
    }

    private void test_room_info_refresh_is_atomic(Gee.TestFinishedCallback cb) {
        test_room_info_refresh_is_atomic_async.begin(cb);
    }

    private void test_room_info_publishes_avatar_projection(
            Gee.TestFinishedCallback cb) {
        test_room_info_publishes_avatar_projection_async.begin(cb);
    }

    private async void test_room_info_publishes_avatar_projection_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            Jid room = new Jid(ROOM);
            stream.disco_avatar_hash = ROOM_AVATAR_HASH;
            int projections = 0;
            Xep.MucAvatars.RoomAvatarInfo? received = null;
            ((!) module).room_avatar_info_received.connect((source,
                    source_room, info) => {
                if (source != stream || !source_room.equals_bare(room)) return;
                projections++;
                received = info;
            });

            bool succeeded = yield ((!) module).query_room_info(stream, room);
            fail_if(!succeeded || projections != 1 || received == null ||
                    !((!) received).roominfo_form_present ||
                    !((!) received).hash_field_present ||
                    !((!) received).hashes_valid ||
                    ((!) received).hash_count != 1 ||
                    ((!) received).hash_at(0) != ROOM_AVATAR_HASH,
                "Only the accepted room-info generation must publish one normalized XEP-0486 projection");

            stream.omit_muc_result_from = true;
            bool senderless_succeeded = yield ((!) module).query_room_info(
                stream, room);
            stream.omit_muc_result_from = false;
            fail_if(!senderless_succeeded || projections != 1,
                "A sender-less compatibility room-info result must not authorize an XEP-0486 avatar projection");
        } catch (Error error) {
            fail_if_reached(@"Unexpected XEP-0486 room-info signal error: $(error.message)");
        }
        cb();
    }

    private async void test_room_info_refresh_is_atomic_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            Jid room = new Jid(ROOM);
            stream.disco_members_only = true;
            stream.disco_stable_ids = true;
            stream.disco_subject_policy = 1;
            stream.disco_invite_policy = 1;
            stream.disco_foreign_invite_policy = 0;
            int updates = 0;
            ((!) module).room_info_updated.connect((source, updated_room) => {
                if (source == stream && updated_room.equals_bare(room))
                    updates++;
            });

            bool first = yield ((!) module).query_room_info(stream, room);
            fail_if(!first || !((!) flag).knows_room_features(room) ||
                    !((!) flag).has_current_room_features(room) ||
                    !((!) flag).has_room_feature(room,
                        Xep.Muc.Feature.MEMBERS_ONLY) ||
                    !((!) flag).has_room_feature(room,
                        Xep.Muc.Feature.STABLE_ID) ||
                    ((!) flag).get_occupants_may_change_subject(room) != true ||
                    ((!) flag).get_occupants_may_invite(room) != true ||
                    updates != 1,
                "a valid disco result must atomically publish room features once");

            stream.disco_error_condition = ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
            bool second = yield ((!) module).query_room_info(stream, room);
            fail_if(second,
                "a failed disco refresh must report failure");
            fail_if(!((!) flag).knows_room_features(room) ||
                    ((!) flag).has_current_room_features(room) ||
                    !((!) flag).has_room_feature(room,
                        Xep.Muc.Feature.MEMBERS_ONLY) ||
                    ((!) flag).get_occupants_may_change_subject(room) != true ||
                    ((!) flag).get_occupants_may_invite(room) != true ||
                    updates != 1,
                "a failed disco refresh must preserve the previous feature projection without emitting an update");

            stream.disco_error_condition = null;
            stream.muc_result_from_override =
                "other@conference.example.test";
            GLib.Test.expect_message("xmpp-vala",
                LogLevelFlags.LEVEL_WARNING,
                "*Ignoring room info result*unexpected JID*");
            bool third = yield ((!) module).query_room_info(stream, room);
            GLib.Test.assert_expected_messages();
            fail_if(third || ((!) flag).has_current_room_features(room) ||
                    !((!) flag).has_room_feature(room,
                        Xep.Muc.Feature.MEMBERS_ONLY) ||
                    ((!) flag).get_occupants_may_invite(room) != true ||
                    updates != 1,
                "room-info with an explicit foreign sender must preserve display state but never restore security freshness");

            stream.muc_result_from_override = null;
            stream.disco_stable_ids = false;
            stream.disco_invite_policy = 0;
            stream.disco_foreign_invite_policy = 1;
            bool fourth = yield ((!) module).query_room_info(stream, room);
            fail_if(!fourth || !((!) flag).has_current_room_features(room) ||
                    ((!) flag).has_room_feature(room,
                        Xep.Muc.Feature.STABLE_ID) ||
                    ((!) flag).get_occupants_may_invite(room) != false ||
                    updates != 2,
                "a fresh room-info result must publish a changed mediated-invitation policy");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in atomic room-info audit: $(e.message)");
        }
        cb();
    }

    private void test_room_configuration_propagates_iq_error(Gee.TestFinishedCallback cb) {
        test_room_configuration_propagates_iq_error_async.begin(cb);
    }

    private void test_query_generations_survive_same_stream_rejoin(
            Gee.TestFinishedCallback cb) {
        test_query_generations_survive_same_stream_rejoin_async.begin(cb);
    }

    private void test_member_affiliation_snapshot_coalesces_join_queries(
            Gee.TestFinishedCallback cb) {
        test_member_affiliation_snapshot_coalesces_join_queries_async.begin(
            cb);
    }

    private async void
            test_member_affiliation_snapshot_coalesces_join_queries_async(
                Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            var room = new Jid(ROOM);
            var alice = new Jid("alice@example.test");
            var bob = new Jid("bob@example.test");
            var carol = new Jid("carol@example.test");
            stream.hold_affiliation_results = true;

            yield enter_room(stream, room);
            fail_if(stream.held_affiliation_result_count != 3,
                "join must start exactly one parallel member/admin/owner snapshot");

            bool waiter_done = false;
            bool waiter_success = false;
            ((!) module).query_member_affiliation_snapshot.begin(stream,
                    room, false, (_, result) => {
                waiter_success = ((!) module)
                    .query_member_affiliation_snapshot.end(result);
                waiter_done = true;
            });
            fail_if(stream.held_affiliation_result_count != 3,
                "a concurrent snapshot waiter must coalesce without new IQs");

            stream.emit_next_held_affiliation_result("member",
                alice.to_string());
            stream.emit_next_held_affiliation_result("admin",
                bob.to_string());
            drain_main_context();
            fail_if(waiter_done,
                "the aggregate must not complete before all three lists arrive");
            stream.emit_next_held_affiliation_result("owner",
                carol.to_string());
            drain_main_context();

            Gee.List<Jid> members = ((!) flag).get_offline_members(room);
            fail_if(!waiter_done || !waiter_success ||
                    !((!) flag).has_complete_member_affiliation_snapshot(
                        room) || members.size != 3 ||
                    !members.contains(alice) || !members.contains(bob) ||
                    !members.contains(carol),
                "all coalesced waiters must observe the same complete snapshot");
        } catch (Error e) {
            fail_if_reached(@"Unexpected coalesced affiliation snapshot error: $(e.message)");
        }
        cb();
    }

    private void
            test_member_affiliation_snapshot_force_supersedes_old_queries(
                Gee.TestFinishedCallback cb) {
        test_member_affiliation_snapshot_force_supersedes_old_queries_async
            .begin(cb);
    }

    private async void
            test_member_affiliation_snapshot_force_supersedes_old_queries_async(
                Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            var room = new Jid(ROOM);
            var alice = new Jid("alice@example.test");
            var bob = new Jid("bob@example.test");
            stream.hold_affiliation_results = true;

            yield enter_room(stream, room);
            fail_if(stream.held_affiliation_result_count != 3,
                "test setup must hold the initial three affiliation IQs");

            bool old_done = false;
            bool old_success = true;
            ((!) module).query_member_affiliation_snapshot.begin(stream,
                    room, false, (_, result) => {
                old_success = ((!) module)
                    .query_member_affiliation_snapshot.end(result);
                old_done = true;
            });

            bool fresh_done = false;
            bool fresh_success = false;
            ((!) module).query_member_affiliation_snapshot.begin(stream,
                    room, true, (_, result) => {
                fresh_success = ((!) module)
                    .query_member_affiliation_snapshot.end(result);
                fresh_done = true;
            });
            fail_if(stream.held_affiliation_result_count != 6,
                "a forced refresh must start exactly one fresh three-IQ generation");
            drain_main_context();
            fail_if(!old_done || old_success,
                "the superseded aggregate waiter must fail closed");

            stream.emit_next_held_affiliation_result("member",
                alice.to_string());
            stream.emit_next_held_affiliation_result("admin", null);
            stream.emit_next_held_affiliation_result("owner", null);
            drain_main_context();
            fail_if(((!) flag).has_complete_member_affiliation_snapshot(
                        room) ||
                    ((!) flag).get_offline_members(room).contains(alice),
                "superseded affiliation results must not commit");

            stream.emit_next_held_affiliation_result("member",
                bob.to_string());
            stream.emit_next_held_affiliation_result("admin", null);
            stream.emit_next_held_affiliation_result("owner", null);
            drain_main_context();

            Gee.List<Jid> members = ((!) flag).get_offline_members(room);
            fail_if(!fresh_done || !fresh_success ||
                    !((!) flag).has_complete_member_affiliation_snapshot(
                        room) || members.size != 1 ||
                    !members[0].equals_bare(bob) || members.contains(alice),
                "only the forced post-boundary snapshot may become current");
        } catch (Error e) {
            fail_if_reached(@"Unexpected forced affiliation snapshot error: $(e.message)");
        }
        cb();
    }

    private async void test_query_generations_survive_same_stream_rejoin_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            var room = new Jid(ROOM);
            var alice = new Jid("alice@example.test");
            var bob = new Jid("bob@example.test");

            yield enter_room(stream, room);
            stream.hold_disco_results = true;
            stream.hold_affiliation_results = true;

            bool stale_room_done = false;
            bool stale_room_success = true;
            ((!) module).query_room_info.begin(stream, room, (_, result) => {
                stale_room_success = ((!) module).query_room_info.end(result);
                stale_room_done = true;
            });

            bool stale_members_done = false;
            Gee.List<Jid>? stale_members = null;
            ((!) module).query_affiliation.begin(stream, room, "member",
                    (_, result) => {
                stale_members = ((!) module).query_affiliation.end(result);
                stale_members_done = true;
            });

            fail_if(stream.held_disco_result_count != 1 ||
                    stream.held_affiliation_result_count != 1,
                "test setup must hold one room-info and one affiliation result from the old lifecycle");

            ((!) module).exit(stream, room);
            yield enter_room(stream, room);

            fail_if(stream.held_disco_result_count != 2 ||
                    stream.held_affiliation_result_count != 4,
                "same-stream rejoin must start fresh room-info and complete affiliation queries");

            stream.emit_next_held_disco_result(true, 1);
            stream.emit_next_held_affiliation_result("member",
                alice.to_string());
            drain_main_context();

            fail_if(!stale_room_done || stale_room_success ||
                    !stale_members_done || stale_members != null,
                "late room-info and affiliation results from the old lifecycle must be rejected");
            fail_if(((!) flag).has_room_feature(room,
                        Xep.Muc.Feature.MEMBERS_ONLY) ||
                    ((!) flag).get_offline_members(room).contains(alice),
                "old-lifecycle room features and members must not contaminate the rejoined room");

            stream.emit_next_held_disco_result(false, 0);
            stream.emit_next_held_affiliation_result("member",
                bob.to_string());
            stream.emit_next_held_affiliation_result("admin", null);
            stream.emit_next_held_affiliation_result("owner", null);
            drain_main_context();

            Gee.List<Jid> offline_members = ((!) flag).get_offline_members(
                room);
            fail_if(!((!) flag).has_current_room_features(room) ||
                    ((!) flag).has_room_feature(room,
                        Xep.Muc.Feature.MEMBERS_ONLY) ||
                    !((!) flag).has_complete_member_affiliation_snapshot(
                        room) ||
                    offline_members.size != 1 ||
                    !offline_members[0].equals_bare(bob),
                "only current-lifecycle room-info and member results may populate the rejoined room");
        } catch (Error e) {
            fail_if_reached(@"Unexpected same-stream MUC generation test error: $(e.message)");
        }
        cb();
    }

    private static void drain_main_context() {
        MainContext context = MainContext.default();
        while (context.pending()) context.iteration(false);
    }

    private async void test_room_configuration_propagates_iq_error_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            var form = new Xep.DataForms.DataForm();
            form.add_field(new Xep.DataForms.DataForm.Field() {
                var = "FORM_TYPE",
                type_ = Xep.DataForms.DataForm.Type.HIDDEN
            });
            form.fields[0].set_value_string("http://jabber.org/protocol/muc#roomconfig");

            stream.owner_set_error_condition = ErrorStanza.CONDITION_FORBIDDEN;
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to set config form*");
            bool saved = yield ((!) module).set_config_form(stream,
                new Jid(ROOM), form);
            GLib.Test.assert_expected_messages();

            fail_if(saved,
                "A room configuration IQ error must not be reported as saved");
            fail_if(stream.last_config_set == null,
                "Rejected room configuration must still send one owner IQ");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC config IQ-error test: $(e.message)");
        }
        cb();
    }

    private async void test_role_change_propagates_iq_error_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            stream.admin_set_error_condition = ErrorStanza.CONDITION_FORBIDDEN;

            try {
                yield ((!) module).change_role(stream, new Jid(ROOM), "alice", "visitor");
                fail_if_reached("MUC role change must not accept an IQ error as success");
            } catch (IOError.FAILED e) {
                fail_if(!e.message.contains(ErrorStanza.CONDITION_FORBIDDEN),
                    "MUC role error must preserve the stanza condition");
            }

            fail_if(stream.last_admin_set == null,
                "MUC role change must send one MUC admin IQ");
            StanzaNode? query = ((!) stream.last_admin_set).get_subnode("query", NS_MUC_ADMIN);
            StanzaNode? item = query != null
                ? ((!) query).get_subnode("item", NS_MUC_ADMIN)
                : null;
            fail_if(item == null, "MUC role change IQ must contain an admin item");
            fail_if_not_eq_str(((!) item).get_attribute("nick"), "alice",
                "MUC role change target nick");
            fail_if_not_eq_str(((!) item).get_attribute("role"), "visitor",
                "MUC role change target role");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC role IQ-error test: $(e.message)");
        }
        cb();
    }

    private void test_mutation_rejects_missing_room_sender(
            Gee.TestFinishedCallback cb) {
        test_mutation_rejects_missing_room_sender_async.begin(cb);
    }

    private async void test_mutation_rejects_missing_room_sender_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            stream.omit_muc_result_from = true;

            try {
                yield ((!) module).change_role(stream, new Jid(ROOM),
                    "alice", "visitor");
                fail_if_reached(
                    "MUC role change must reject a sender-less IQ result");
            } catch (IOError.FAILED e) {
                fail_if(!e.message.contains("without room sender"),
                    "sender-less MUC mutation must report its validation failure");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in missing MUC sender test: $(e.message)");
        }
        cb();
    }

    private void test_config_rejects_wrong_room_sender(
            Gee.TestFinishedCallback cb) {
        test_config_rejects_wrong_room_sender_async.begin(cb);
    }

    private async void test_config_rejects_wrong_room_sender_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var form = new Xep.DataForms.DataForm();
            stream.muc_result_from_override = "other@conference.example.test";

            GLib.Test.expect_message("xmpp-vala",
                LogLevelFlags.LEVEL_WARNING,
                "*Failed to set config form*unexpected JID*");
            bool saved = yield ((!) module).set_config_form(stream,
                new Jid(ROOM), form);
            GLib.Test.assert_expected_messages();
            fail_if(saved,
                "room configuration must reject an IQ result from another room");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in wrong MUC sender test: $(e.message)");
        }
        cb();
    }

    private void test_affiliation_query_accepts_missing_room_sender(
            Gee.TestFinishedCallback cb) {
        test_affiliation_query_accepts_missing_room_sender_async.begin(cb);
    }

    private async void test_affiliation_query_accepts_missing_room_sender_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            stream.omit_muc_result_from = true;
            Gee.List<Jid>? result = yield ((!) module).query_affiliation(
                stream, new Jid(ROOM), "member");
            fail_if(result == null,
                "read-only affiliation queries must retain from-less result compatibility");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in affiliation sender test: $(e.message)");
        }
        cb();
    }

    private void test_affiliation_query_rejects_malformed_payload_atomically(
            Gee.TestFinishedCallback cb) {
        test_affiliation_query_rejects_malformed_payload_atomically_async.begin(
            cb);
    }

    private async void test_affiliation_query_rejects_malformed_payload_atomically_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid("alice@example.test");
            var bob = new Jid("bob@example.test");
            var module = stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);

            stream.member_query_jid = alice.to_string();
            yield query_complete_affiliation_snapshot(stream, room);
            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(!snapshot_contains((!) flag, room, alice),
                "valid member snapshot setup must contain Alice");

            stream.affiliation_query_payload_override =
                new StanzaNode.build("query", NS_MUC_ADMIN)
                    .add_self_xmlns()
                    .put_node(new StanzaNode.build("item", NS_MUC_ADMIN)
                        .put_attribute("jid", bob.to_string())
                        .put_attribute("affiliation", "member"))
                    .put_node(new StanzaNode.build("item", NS_MUC_ADMIN)
                        .put_attribute("affiliation", "member"));
            GLib.Test.expect_message("xmpp-vala",
                LogLevelFlags.LEVEL_WARNING,
                "*Rejecting malformed member affiliation list*");
            Gee.List<Jid>? result = yield ((!) module).query_affiliation(
                stream, room, "member");
            GLib.Test.assert_expected_messages();

            fail_if(result != null,
                "malformed affiliation list must fail as one transaction");
            Gee.List<Jid> preserved_projection =
                ((!) flag).get_offline_members(room);
            fail_if(!preserved_projection.contains(alice) ||
                    preserved_projection.contains(bob),
                "malformed affiliation list must preserve the last display projection without partial Bob data");
            fail_if(((!) flag).has_complete_member_affiliation_snapshot(room),
                "a failed fresh affiliation query must revoke cryptographic snapshot freshness");
        } catch (Error e) {
            fail_if_reached(@"Unexpected malformed affiliation-list test error: $(e.message)");
        }
        cb();
    }

    private void test_bare_affiliation_change_updates_snapshot_after_success(Gee.TestFinishedCallback cb) {
        test_bare_affiliation_change_updates_snapshot_after_success_async.begin(cb);
    }

    private async void test_bare_affiliation_change_updates_snapshot_after_success_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid("alice@example.test");
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            yield enter_room(stream, room);
            stream.member_query_jid = null;
            yield query_complete_affiliation_snapshot(stream, room);

            int changed_count = 0;
            Jid? changed_room = null;
            Jid? changed_target = null;
            Xep.Muc.Affiliation? changed_affiliation = null;
            ((!) module).bare_affiliation_changed.connect((changed_stream,
                    signal_room, signal_target, signal_affiliation) => {
                changed_count++;
                changed_room = signal_room;
                changed_target = signal_target;
                changed_affiliation = signal_affiliation;
            });

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            stream.admin_set_error_condition = ErrorStanza.CONDITION_NOT_ALLOWED;
            try {
                yield ((!) module).change_affiliation(stream, room, alice, null, "member");
                fail_if_reached("Rejected bare-JID affiliation change must throw");
            } catch (IOError.FAILED e) {
                fail_if(!e.message.contains(ErrorStanza.CONDITION_NOT_ALLOWED),
                    "Affiliation IQ error must preserve the stanza condition");
            }
            fail_if(((!) flag).get_affiliation(room, alice) != Xep.Muc.Affiliation.NONE,
                "Rejected affiliation change must not mutate live affiliation state");
            fail_if(snapshot_contains((!) flag, room, alice),
                "Rejected affiliation change must not mutate the affiliation snapshot");
            fail_if(changed_count != 0,
                "Rejected affiliation change must not emit a confirmed bare update");

            stream.admin_set_error_condition = null;
            yield ((!) module).change_affiliation(stream, room, alice, null, "member");
            fail_if(((!) flag).get_affiliation(room, alice) != Xep.Muc.Affiliation.MEMBER,
                "Successful bare-JID affiliation change must update live affiliation state");
            fail_if(!snapshot_contains((!) flag, room, alice),
                "Successful bare-JID affiliation change must update the complete snapshot");
            fail_if(changed_count != 1 || changed_room == null ||
                    !((!) changed_room).equals_bare(room) ||
                    changed_target == null ||
                    !((!) changed_target).equals_bare(alice) ||
                    changed_affiliation != Xep.Muc.Affiliation.MEMBER,
                "Successful affiliation change must emit one room-scoped bare update");

            fail_if(stream.last_admin_set == null,
                "Bare-JID affiliation change must send one MUC admin IQ");
            StanzaNode? query = ((!) stream.last_admin_set).get_subnode("query", NS_MUC_ADMIN);
            StanzaNode? item = query != null
                ? ((!) query).get_subnode("item", NS_MUC_ADMIN)
                : null;
            fail_if(item == null, "Affiliation change IQ must contain an admin item");
            fail_if_not_eq_str(((!) item).get_attribute("jid"), alice.to_string(),
                "Affiliation change must use the bare JID");
            fail_if_not_eq_str(((!) item).get_attribute("affiliation"), "member",
                "Affiliation change target affiliation");

            yield ((!) module).change_affiliation(stream, room, alice, null, "none");
            fail_if(((!) flag).get_affiliation(room, alice) != Xep.Muc.Affiliation.NONE,
                "Successful affiliation removal must clear live affiliation state");
            fail_if(((!) flag).has_affiliation(room, alice),
                "A bare affiliation=none result must not create a persistent none-list entry");
            fail_if(snapshot_contains((!) flag, room, alice),
                "Successful affiliation removal must clear the complete snapshot");
            fail_if(changed_count != 2 ||
                    changed_affiliation != Xep.Muc.Affiliation.NONE,
                "Successful affiliation removal must emit its confirmed bare update");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in bare-JID affiliation mutation test: $(e.message)");
        }
        cb();
    }

    private void test_bare_affiliation_change_updates_live_projection_after_success(
            Gee.TestFinishedCallback cb) {
        test_bare_affiliation_change_updates_live_projection_after_success_async.begin(cb);
    }

    private async void test_bare_affiliation_change_updates_live_projection_after_success_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var alice = new Jid("alice@example.test");
            var alice_occupant = new Jid(ALICE_OCCUPANT);
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            yield enter_room(stream, room);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "admin", "moderator", false));

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(((!) flag).get_affiliation(room, alice_occupant) !=
                    Xep.Muc.Affiliation.ADMIN,
                "test setup must begin with a live admin projection");

            int changed_count = 0;
            ((!) module).bare_affiliation_changed.connect((changed_stream,
                    signal_room, signal_target, signal_affiliation) => {
                changed_count++;
            });

            stream.admin_set_error_condition = ErrorStanza.CONDITION_NOT_ALLOWED;
            try {
                yield ((!) module).change_affiliation(stream, room, alice,
                    null, "member");
                fail_if_reached("Rejected live affiliation change must throw");
            } catch (IOError.FAILED e) {
                // Expected server rejection.
            }
            fail_if(((!) flag).get_affiliation(room, alice_occupant) !=
                    Xep.Muc.Affiliation.ADMIN || changed_count != 0,
                "Rejected change must preserve the live projection and emit no update");

            stream.admin_set_error_condition = null;
            yield ((!) module).change_affiliation(stream, room, alice, null,
                "member");
            fail_if(((!) flag).get_affiliation(room, alice_occupant) !=
                    Xep.Muc.Affiliation.MEMBER,
                "Successful bare-JID change must update the matching live room/nick projection");
            fail_if(changed_count != 1,
                "Successful live affiliation change must emit one confirmed update");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in live affiliation mutation test: $(e.message)");
        }
        cb();
    }

    private void test_explicit_none_is_known_only_while_live(Gee.TestFinishedCallback cb) {
        test_explicit_none_is_known_only_while_live_async.begin(cb);
    }

    private async void test_explicit_none_is_known_only_while_live_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var occupant = new Jid(ALICE_OCCUPANT);
            yield enter_room(stream, room);

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "none", "participant", false));
            fail_if(!((!) flag).has_affiliation(room, occupant),
                "Explicit affiliation=none in live presence must be known");
            fail_if(((!) flag).get_affiliation(room, occupant) != Xep.Muc.Affiliation.NONE,
                "Explicit live none affiliation must retain its value");
            Gee.List<Jid> offline = ((!) flag).get_offline_members(room);
            fail_if(offline.contains(occupant) ||
                    offline.contains(new Jid("alice@example.test")),
                "Known-none live occupants must not become offline affiliation-list rows");
            stream.emit_presence(build_muc_affiliation_unavailable_presence(
                ROOM + "/blocked", "blocked@example.test", "outcast", "301"));
            fail_if(((!) flag).get_offline_members(room).contains(
                    new Jid("blocked@example.test")),
                "Outcasts must never be exposed as offline room members");

            stream.emit_presence(build_plain_unavailable_presence(ALICE_OCCUPANT));
            fail_if(((!) flag).has_affiliation(room, occupant),
                "Known-none live state must be removed when the occupant leaves");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in explicit-none state test: $(e.message)");
        }
        cb();
    }

    private void test_room_exit_invalidates_only_live_room_projection(
            Gee.TestFinishedCallback cb) {
        test_room_exit_invalidates_only_live_room_projection_async.begin(cb);
    }

    private async void test_room_exit_invalidates_only_live_room_projection_async(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room_a = new Jid(ROOM);
            var room_b = new Jid(OTHER_ROOM);
            var occupant_a = new Jid(ALICE_OCCUPANT);
            var occupant_b = new Jid(OTHER_ALICE_OCCUPANT);
            var alice_bare = new Jid("alice@example.test");

            yield enter_room(stream, room_a);
            yield enter_room(stream, room_b);

            StanzaNode presence_a = build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "member", "participant", false);
            presence_a.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                    .put_attribute("uri", "urn:xmpp:hats:room-a")
                    .put_attribute("title", "Room A")));
            stream.emit_presence(presence_a);

            StanzaNode presence_b = build_muc_presence(OTHER_ALICE_OCCUPANT,
                OTHER_ALICE_REAL, "admin", "moderator", false);
            presence_b.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                    .put_attribute("uri", "urn:xmpp:hats:room-b")
                    .put_attribute("title", "Room B")));
            stream.emit_presence(presence_b);

            // Exceed one deferred-disposal batch so the rejoin assertion
            // below also covers callbacks that outlive the exit turn.
            for (int i = 0; i < 130; i++) {
                stream.emit_presence(build_muc_presence(
                    @"$(ROOM)/bulk-$i",
                    @"bulk-$i@example.test/device", "member",
                    "participant", false));
            }

            Xep.Muc.Flag flag = (!) stream.get_flag(Xep.Muc.Flag.IDENTITY);
            fail_if(flag.get_real_jid(occupant_a) == null ||
                    flag.get_affiliation(room_a, occupant_a) !=
                        Xep.Muc.Affiliation.MEMBER ||
                    flag.get_occupant_role(occupant_a) !=
                        Xep.Muc.Role.PARTICIPANT ||
                    flag.get_occupant_hats(occupant_a).size != 1 ||
                    flag.get_real_jid(occupant_b) == null ||
                    flag.get_affiliation(room_b, occupant_b) !=
                        Xep.Muc.Affiliation.ADMIN ||
                    flag.get_occupant_role(occupant_b) !=
                        Xep.Muc.Role.MODERATOR ||
                    flag.get_occupant_hats(occupant_b).size != 1,
                "Room-exit audit setup must contain complete live projections in both rooms");

            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            module.exit(stream, room_a);

            fail_if(flag.get_real_jid(occupant_a) != null ||
                    flag.has_affiliation(room_a, occupant_a) ||
                    flag.has_occupant_role(occupant_a) ||
                    !flag.get_occupant_hats(occupant_a).is_empty,
                "Leaving room A must invalidate its real JID, live affiliation, role and hats projection");
            fail_if(flag.get_affiliation(room_a, alice_bare) !=
                        Xep.Muc.Affiliation.MEMBER ||
                    !flag.get_offline_members(room_a).contains(alice_bare),
                "Leaving room A must preserve its bare member affiliation cache");
            fail_if(flag.get_real_jid(occupant_b) == null ||
                    flag.get_affiliation(room_b, occupant_b) !=
                        Xep.Muc.Affiliation.ADMIN ||
                    flag.get_occupant_role(occupant_b) !=
                        Xep.Muc.Role.MODERATOR ||
                    flag.get_occupant_hats(occupant_b).size != 1 ||
                    flag.get_occupant_hats(occupant_b)[0].uri !=
                        "urn:xmpp:hats:room-b",
                "Leaving room A must not invalidate room B occupant state");

            module.exit(stream, room_b);
            fail_if(flag.get_real_jid(occupant_b) != null ||
                    flag.has_affiliation(room_b, occupant_b) ||
                    flag.has_occupant_role(occupant_b) ||
                    !flag.get_occupant_hats(occupant_b).is_empty,
                "A second quick room exit must immediately invalidate its own live projection");

            yield enter_room(stream, room_a);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT,
                ALICE_REAL, "admin", "moderator", false));
            yield enter_room(stream, room_b);
            stream.emit_presence(build_muc_presence(OTHER_ALICE_OCCUPANT,
                OTHER_ALICE_REAL, "member", "participant", false));
            drain_main_context();
            fail_if(flag.get_real_jid(occupant_a) == null ||
                    flag.get_affiliation(room_a, occupant_a) !=
                        Xep.Muc.Affiliation.ADMIN ||
                    flag.get_occupant_role(occupant_a) !=
                        Xep.Muc.Role.MODERATOR ||
                    flag.get_real_jid(occupant_b) == null ||
                    flag.get_affiliation(room_b, occupant_b) !=
                        Xep.Muc.Affiliation.MEMBER ||
                    flag.get_occupant_role(occupant_b) !=
                        Xep.Muc.Role.PARTICIPANT,
                "The coordinated disposal backlog must not erase either same-room rejoin generation");
        } catch (Error e) {
            fail_if_reached(@"Unexpected room-exit invalidation test error: $(e.message)");
        }
        cb();
    }

    private void test_local_exit_clears_only_room_presence_bucket(
            Gee.TestFinishedCallback cb) {
        test_local_exit_clears_only_room_presence_bucket_async.begin(cb);
    }

    private async void test_local_exit_clears_only_room_presence_bucket_async(
            Gee.TestFinishedCallback cb) {
        try {
            const int OCCUPANT_COUNT = 4096;
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var other_room = new Jid(OTHER_ROOM);
            var contact = new Jid("contact@example.test/desktop");
            var reused_occupant = new Jid(ROOM + "/occupant-0");

            yield enter_room(stream, room);
            yield enter_room(stream, other_room);
            for (int i = 0; i < OCCUPANT_COUNT; i++) {
                stream.emit_presence(build_muc_presence(
                    @"$(ROOM)/occupant-$i",
                    @"occupant-$i@example.test/device", "member",
                    "participant", false));
            }
            stream.emit_presence(build_muc_presence(OTHER_ALICE_OCCUPANT,
                OTHER_ALICE_REAL, "member", "participant", false));
            stream.emit_presence(new StanzaNode.build("presence")
                .put_attribute("from", contact.to_string())
                .put_attribute("to", LOCAL_FULL));

            Presence.Flag presence_flag = stream.get_flag<Presence.Flag>(
                Presence.Flag.IDENTITY);
            Gee.List<Jid>? room_resources = presence_flag.get_resources(room);
            fail_if(room_resources == null ||
                    ((!) room_resources).size != OCCUPANT_COUNT + 1,
                "Large-room exit setup must retain every occupant plus self");
            fail_if(presence_flag.get_presence(reused_occupant) == null ||
                    presence_flag.get_presence(new Jid(OTHER_ALICE_OCCUPANT)) ==
                        null ||
                    presence_flag.get_presence(contact) == null,
                "Room-exit isolation setup must contain room, other-room, and contact presences");

            Xep.Muc.Module module = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            // MucAuditStream deliberately does not synthesize one unavailable
            // response per remote occupant for a locally sent room exit.
            module.exit(stream, room);

            fail_if(presence_flag.get_resources(room) != null ||
                    presence_flag.get_presence(reused_occupant) != null,
                "Local MUC exit must immediately invalidate the complete room presence bucket");
            fail_if(presence_flag.get_presence(
                        new Jid(OTHER_ALICE_OCCUPANT)) == null ||
                    presence_flag.get_presence(contact) == null,
                "Local MUC exit must preserve other rooms and direct-contact presences");

            var late_occupant = new Jid(ROOM + "/late-occupant");
            stream.emit_presence(build_muc_presence(
                late_occupant.to_string(),
                "late@example.test/device", "member", "participant", false));
            stream.emit_presence(build_muc_presence(OWNER_OCCUPANT,
                "owner@example.test/dinox", "owner", "moderator", true));
            fail_if(presence_flag.get_resources(room) != null ||
                    presence_flag.get_presence(late_occupant) != null,
                "Late server presences after local exit must not recreate the retired room bucket");

            // Reusing a full room/nick JID before deferred disposal completes
            // must keep the new generation alive.
            yield enter_room(stream, room);
            stream.emit_presence(build_muc_presence(
                reused_occupant.to_string(),
                "replacement@example.test/device", "admin", "moderator",
                false));
            drain_main_context();
            fail_if(presence_flag.get_presence(reused_occupant) == null,
                "Deferred room cleanup must not erase a same-JID rejoin generation");
        } catch (Error e) {
            fail_if_reached(@"Unexpected local MUC presence cleanup error: $(e.message)");
        }
        cb();
    }

    private void test_presence_keeps_bare_affiliation_snapshot_current(Gee.TestFinishedCallback cb) {
        test_presence_keeps_bare_affiliation_snapshot_current_async.begin(cb);
    }

    private async void test_presence_keeps_bare_affiliation_snapshot_current_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_muc_stream();
            var room = new Jid(ROOM);
            var occupant = new Jid(ALICE_OCCUPANT);
            var alice = new Jid("alice@example.test");
            yield enter_room(stream, room);
            stream.member_query_jid = null;
            yield query_complete_affiliation_snapshot(stream, room);

            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            stream.emit_presence(build_muc_presence(ALICE_OCCUPANT, ALICE_REAL,
                "member", "participant", false));
            fail_if(!snapshot_contains((!) flag, room, alice),
                "Available real-JID member presence must update the complete snapshot");

            stream.emit_presence(build_muc_affiliation_unavailable_presence(
                ALICE_OCCUPANT, ALICE_REAL, "outcast", "301"));
            fail_if(((!) flag).get_real_jid(occupant) != null,
                "Unavailable presence must still clean up the live occupant real-JID mapping");
            fail_if(((!) flag).get_affiliation(room, alice) != Xep.Muc.Affiliation.OUTCAST,
                "Unavailable outcast presence must retain authoritative bare-JID affiliation state");
            fail_if(snapshot_contains((!) flag, room, alice),
                "Unavailable outcast presence must remove the JID from the member snapshot before cleanup");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC affiliation presence snapshot test: $(e.message)");
        }
        cb();
    }

    private async void test_cancel_enter_completes_waiter_and_allows_retry_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_enter_cancel_stream();
            var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);

            Xep.Muc.JoinResult? cancelled = yield ((!) module).enter(stream, new Jid(ROOM), "owner", null, null, true, null);

            fail_if(cancelled == null, "MUC enter cancel must complete the pending waiter");
            fail_if(((!) cancelled).stanza_error != ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT,
                "MUC enter cancel must surface a stanza error to release waiters");
            fail_if(stream.join_presence_count != 1, "MUC enter cancel setup must send one initial join presence");
            fail_if(stream.unavailable_presence_count != 1, "MUC enter cancel must send one unavailable presence for the pending nick");

            Xep.Muc.JoinResult? retry = yield ((!) module).enter(stream, new Jid(ROOM), "owner", null, null, true, null);

            fail_if(retry == null, "MUC enter retry must complete after cancel");
            fail_if(((!) retry).nick != "owner", "MUC enter retry must not wait on the cancelled enter future");
            fail_if(stream.join_presence_count != 2, "MUC enter retry must write a new join presence");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC enter cancel retry test: $(e.message)");
        }
        cb();
    }

    private async void enter_room(MucAuditStream stream, Jid room) throws Error {
        var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
        Xep.Muc.JoinResult? result = yield ((!) module).enter(stream, room, "owner", null, null, true, null);
        fail_if(result == null, "MUC enter test setup must complete");
        fail_if(((!) result).stanza_error != null, "MUC enter test setup must not return a stanza error");
        fail_if(((!) result).muc_error != null, "MUC enter test setup must not return a MUC error");
    }

    private async void query_members(MucAuditStream stream, Jid room) throws Error {
        var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
        Gee.List<Jid>? members = yield ((!) module).query_affiliation(stream, room, "member");
        fail_if(members == null, "MUC member query test setup must complete");
        fail_if(((!) members).size != 1, "MUC member query test setup must return Alice as member");
    }

    private async void query_complete_affiliation_snapshot(MucAuditStream stream,
            Jid room) throws Error {
        var module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
        string[] affiliations = { "member", "admin", "owner" };
        foreach (string affiliation in affiliations) {
            Gee.List<Jid>? result = yield ((!) module).query_affiliation(
                stream, room, affiliation);
            fail_if(result == null,
                "Complete MUC affiliation snapshot test setup must complete all queries");
        }
    }

    private static bool snapshot_contains(Xep.Muc.Flag flag, Jid room, Jid jid) {
        Gee.List<Jid>? snapshot = flag.get_complete_member_affiliation_snapshot(room);
        if (snapshot == null) return false;
        foreach (Jid candidate in (!) snapshot) {
            if (candidate.equals_bare(jid)) return true;
        }
        return false;
    }

    private MucAuditStream create_attached_muc_stream() throws Error {
        var stream = new MucAuditStream(new Jid("example.test"));
        attach_muc_modules(stream);
        return stream;
    }

    private MucEnterDetachAuditStream create_attached_enter_detach_stream() throws Error {
        var stream = new MucEnterDetachAuditStream(new Jid("example.test"));
        attach_muc_modules(stream);
        return stream;
    }

    private MucEnterErrorWithoutIdAuditStream create_attached_enter_error_without_id_stream() throws Error {
        var stream = new MucEnterErrorWithoutIdAuditStream(new Jid("example.test"));
        attach_muc_modules(stream);
        return stream;
    }

    private MucEnterMismatchedErrorIdAuditStream create_attached_enter_mismatched_error_id_stream() throws Error {
        var stream = new MucEnterMismatchedErrorIdAuditStream(new Jid("example.test"));
        attach_muc_modules(stream);
        return stream;
    }

    private MucEnterBareErrorWithoutIdAuditStream create_attached_enter_bare_error_without_id_stream() throws Error {
        var stream = new MucEnterBareErrorWithoutIdAuditStream(new Jid("example.test"));
        attach_muc_modules(stream);
        return stream;
    }

    private MucEnterPresenceWithout110AuditStream create_attached_enter_presence_without_110_stream() throws Error {
        var stream = new MucEnterPresenceWithout110AuditStream(new Jid("example.test"));
        attach_muc_modules(stream);
        return stream;
    }

    private MucEnterCancelAuditStream create_attached_enter_cancel_stream() throws Error {
        var stream = new MucEnterCancelAuditStream(new Jid("example.test"));
        attach_muc_modules(stream);
        return stream;
    }

    private void attach_muc_modules(XmppStream stream) throws Error {
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = new Jid(LOCAL_FULL);
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var message = new MessageModule();
        stream.add_module(message);
        message.attach(stream);

        var presence = new Presence.Module();
        stream.add_module(presence);
        presence.attach(stream);

        var service_discovery = new Xep.ServiceDiscovery.Module.with_identity("client", "pc", "DinoX Test");
        service_discovery.cache = new MucAuditCapsCache();
        stream.add_module(service_discovery);
        service_discovery.attach(stream);

        var muc = new Xep.Muc.Module();
        stream.add_module(muc);
        muc.attach(stream);
    }

    private PingTimeoutAuditStream create_attached_ping_timeout_stream() throws Error {
        var stream = new PingTimeoutAuditStream(new Jid("example.test"));

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var service_discovery = new Xep.ServiceDiscovery.Module.with_identity("client", "pc", "DinoX Test");
        service_discovery.cache = new MucAuditCapsCache();
        stream.add_module(service_discovery);
        service_discovery.attach(stream);

        var ping = new Xep.Ping.Module();
        stream.add_module(ping);
        ping.attach(stream);

        return stream;
    }

    private IqWriteFailureAuditStream create_attached_iq_write_failure_stream() throws Error {
        var stream = new IqWriteFailureAuditStream(new Jid("example.test"));

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        return stream;
    }

    public static StanzaNode build_muc_presence(string from, string? real_jid,
            string? affiliation, string role, bool self_presence,
            bool newly_created = false, bool jid_visible = false) {
        var item = new StanzaNode.build("item", NS_MUC_USER).put_attribute("role", role);
        if (real_jid != null) item.put_attribute("jid", (!) real_jid);
        if (affiliation != null) item.put_attribute("affiliation", (!) affiliation);

        var x_node = new StanzaNode.build("x", NS_MUC_USER).add_self_xmlns().put_node(item);
        if (self_presence) {
            x_node.put_node(new StanzaNode.build("status", NS_MUC_USER).put_attribute("code", "110"));
        }
        if (newly_created) {
            x_node.put_node(new StanzaNode.build("status", NS_MUC_USER).put_attribute("code", "201"));
        }
        if (jid_visible) {
            x_node.put_node(new StanzaNode.build("status", NS_MUC_USER)
                .put_attribute("code", "100"));
        }

        return new StanzaNode.build("presence")
            .put_attribute("from", from)
            .put_attribute("to", LOCAL_FULL)
            .put_node(x_node);
    }

    public static StanzaNode build_muc_unavailable_presence(string from) {
        return new StanzaNode.build("presence")
            .put_attribute("from", from)
            .put_attribute("to", LOCAL_FULL)
            .put_attribute("type", Presence.Stanza.TYPE_UNAVAILABLE)
            .put_node(new StanzaNode.build("x", NS_MUC_USER).add_self_xmlns());
    }

    public static StanzaNode build_muc_config_status_message(string code) {
        return new StanzaNode.build("message")
            .put_attribute("from", ROOM)
            .put_attribute("to", LOCAL_FULL)
            .put_attribute("type", MessageStanza.TYPE_GROUPCHAT)
            .put_node(new StanzaNode.build("x", NS_MUC_USER)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("status", NS_MUC_USER)
                    .put_attribute("code", code)));
    }

    public static StanzaNode build_mam_muc_config_status_message(string code,
            string query_id) {
        var inner_message = new StanzaNode.build("message", "jabber:client")
            .add_self_xmlns()
            .put_attribute("from", ROOM)
            .put_attribute("to", LOCAL_FULL)
            .put_attribute("type", MessageStanza.TYPE_GROUPCHAT)
            .put_node(new StanzaNode.build("x", NS_MUC_USER)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("status", NS_MUC_USER)
                    .put_attribute("code", code)));
        var forwarded = new StanzaNode.build("forwarded",
                StanzaForwarding.NS_URI)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("delay",
                Xep.DelayedDelivery.NS_URI).add_self_xmlns()
                .put_attribute("stamp", "2026-01-01T00:00:00Z"))
            .put_node(inner_message);
        return new StanzaNode.build("message")
            .put_attribute("from", "owner@example.test")
            .put_attribute("to", LOCAL_FULL)
            .put_node(new StanzaNode.build("result",
                MessageArchiveManagement.NS_URI).add_self_xmlns()
                .put_attribute("id", "archived-status")
                .put_attribute("queryid", query_id)
                .put_node(forwarded));
    }

    public static StanzaNode build_muc_affiliation_unavailable_presence(string from,
            string real_jid, string affiliation, string status_code) {
        return new StanzaNode.build("presence")
            .put_attribute("from", from)
            .put_attribute("to", LOCAL_FULL)
            .put_attribute("type", Presence.Stanza.TYPE_UNAVAILABLE)
            .put_node(new StanzaNode.build("x", NS_MUC_USER)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("item", NS_MUC_USER)
                    .put_attribute("jid", real_jid)
                    .put_attribute("affiliation", affiliation)
                    .put_attribute("role", "none"))
                .put_node(new StanzaNode.build("status", NS_MUC_USER)
                    .put_attribute("code", status_code)));
    }

    public static StanzaNode build_plain_unavailable_presence(string from) {
        return new StanzaNode.build("presence")
            .put_attribute("from", from)
            .put_attribute("to", LOCAL_FULL)
            .put_attribute("type", Presence.Stanza.TYPE_UNAVAILABLE);
    }

    public static StanzaNode build_muc_error_presence(string from, string? id, string error_type, string condition) {
        var error_node = new StanzaNode.build("error")
            .put_attribute("type", error_type)
            .put_node(new StanzaNode.build(condition, NS_STANZA_ERROR).add_self_xmlns());

        var presence = new StanzaNode.build("presence")
            .put_attribute("from", from)
            .put_attribute("to", LOCAL_FULL)
            .put_attribute("type", "error")
            .put_node(new StanzaNode.build("x", NS_MUC).add_self_xmlns())
            .put_node(error_node);
        if (id != null) presence.put_attribute("id", (!) id);
        return presence;
    }

    public static StanzaNode build_iq_result_for_request(StanzaNode request,
            StanzaNode payload, string? from_override = null,
            bool omit_from = false) {
        StanzaNode result = new StanzaNode.build("iq")
            .put_attribute("type", "result")
            .put_attribute("id", request.get_attribute("id"))
            .put_attribute("to", LOCAL_FULL)
            .put_node(payload);
        if (!omit_from) {
            result.put_attribute("from", from_override != null
                ? (!) from_override : request.get_attribute("to"));
        }
        return result;
    }

    public static StanzaNode build_iq_error_for_request(StanzaNode request,
            string condition) {
        return new StanzaNode.build("iq")
            .put_attribute("type", "error")
            .put_attribute("id", request.get_attribute("id"))
            .put_attribute("from", request.get_attribute("to"))
            .put_attribute("to", LOCAL_FULL)
            .put_node(new StanzaNode.build("error")
                .put_attribute("type", ErrorStanza.TYPE_CANCEL)
                .put_node(new StanzaNode.build(condition, NS_STANZA_ERROR)
                    .add_self_xmlns()));
    }

    public static StanzaNode build_disco_info_result_payload(
            bool members_only = false, int subject_policy = -1,
            bool semi_anonymous = false, int invite_policy = -1,
            int foreign_invite_policy = -1,
            bool stable_ids = false, string? avatar_hash = null) {
        StanzaNode query = new StanzaNode.build("query", NS_DISCO_INFO)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("identity", NS_DISCO_INFO)
                .put_attribute("category", "conference")
                .put_attribute("type", "text")
                .put_attribute("name", "Test Room"))
            .put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", "http://jabber.org/protocol/muc"));
        if (members_only) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", "muc_membersonly"));
        }
        if (semi_anonymous) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", "muc_semianonymous"));
        }
        if (stable_ids) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var",
                    Xep.UniqueStableStanzaIDs.NS_URI));
        }
        if (subject_policy >= 0 || invite_policy >= 0 ||
                avatar_hash != null) {
            StanzaNode form = new StanzaNode.build("x",
                    Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "result")
                .put_node(build_config_field("FORM_TYPE", "hidden",
                    "http://jabber.org/protocol/muc#roominfo"));
            if (subject_policy >= 0) {
                form.put_node(build_config_field(
                    "muc#roomconfig_changesubject", "boolean",
                    subject_policy == 0 ? "0" : "1"));
            }
            if (invite_policy >= 0) {
                form.put_node(build_config_field(
                    "muc#roomconfig_allowinvites", "boolean",
                    invite_policy == 0 ? "0" : "1"));
            }
            if (avatar_hash != null) {
                form.put_node(build_config_field(
                    Xep.MucAvatars.AVATAR_HASH_FIELD, "text-multi",
                    (!) avatar_hash));
            }
            query.put_node(form);
        }
        if (foreign_invite_policy >= 0) {
            // Neither a submit form nor an unrelated result form may alter
            // the effective room-info policy, even when they reuse a MUC
            // configuration field name.
            query.put_node(new StanzaNode.build("x", Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "submit")
                .put_node(build_config_field("FORM_TYPE", "hidden",
                    "http://jabber.org/protocol/muc#roominfo"))
                .put_node(build_config_field(
                    "muc#roomconfig_allowinvites", "boolean",
                    foreign_invite_policy == 0 ? "0" : "1")));
            query.put_node(new StanzaNode.build("x", Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "result")
                .put_node(build_config_field("FORM_TYPE", "hidden",
                    "urn:example:unrelated-room-info"))
                .put_node(build_config_field(
                    "muc#roomconfig_allowinvites", "boolean",
                    foreign_invite_policy == 0 ? "0" : "1")));
        }
        return query;
    }

    public static StanzaNode build_affiliation_result_payload(string? affiliation, string? jid) {
        var query = new StanzaNode.build("query", NS_MUC_ADMIN).add_self_xmlns();
        if (affiliation != null && jid != null) {
            query.put_node(new StanzaNode.build("item", NS_MUC_ADMIN)
                .put_attribute("jid", (!) jid)
                .put_attribute("affiliation", (!) affiliation));
        }
        return query;
    }

    private static StanzaNode build_config_field(string field_var, string field_type, string value) {
        return new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("var", field_var)
            .put_attribute("type", field_type)
            .put_node(new StanzaNode.build("value", Xep.DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
    }

    private static string? get_submitted_config_value(StanzaNode form, string field_var) {
        foreach (StanzaNode field in form.get_subnodes("field", Xep.DataForms.NS_URI)) {
            if (field.get_attribute("var") != field_var) continue;
            StanzaNode? value = field.get_subnode("value", Xep.DataForms.NS_URI);
            return value != null ? ((!) value).get_string_content() : null;
        }
        return null;
    }
}

private class MucAuditStream : XmppStream {
    public string? member_query_jid { get; set; default = null; }
    public StanzaNode? affiliation_query_payload_override { get; set;
        default = null; }
    public StanzaNode? last_config_set { get; private set; default = null; }
    public StanzaNode? last_admin_set { get; private set; default = null; }
    public string? admin_set_error_condition { get; set; default = null; }
    public string? owner_set_error_condition { get; set; default = null; }
    public string? disco_error_condition { get; set; default = null; }
    public bool disco_members_only { get; set; default = false; }
    public bool disco_semi_anonymous { get; set; default = false; }
    public bool disco_stable_ids { get; set; default = false; }
    public int disco_subject_policy { get; set; default = -1; }
    public int disco_invite_policy { get; set; default = -1; }
    public int disco_foreign_invite_policy { get; set; default = -1; }
    public string? disco_avatar_hash { get; set; default = null; }
    public string? muc_result_from_override { get; set; default = null; }
    public bool omit_muc_result_from { get; set; default = false; }
    public bool hold_disco_results { get; set; default = false; }
    public bool hold_affiliation_results { get; set; default = false; }
    public bool hold_join_self_presence { get; set; default = false; }
    public int occupant_presence_resync_count { get; private set;
        default = 0; }
    public StanzaNode? last_occupant_presence_resync { get; private set;
        default = null; }
    public int held_disco_result_count {
        get { return held_disco_requests.size; }
    }
    public int held_affiliation_result_count {
        get { return held_affiliation_requests.size; }
    }
    private Gee.ArrayList<StanzaNode> held_disco_requests =
        new Gee.ArrayList<StanzaNode>();
    private Gee.ArrayList<StanzaNode> held_affiliation_requests =
        new Gee.ArrayList<StanzaNode>();
    private Gee.HashSet<string> joined_presence_rooms =
        new Gee.HashSet<string>();

    public MucAuditStream(Jid remote_name) {
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

        string? presence_target = node.get_attribute("to");
        if (node.name == "presence" &&
                (presence_target == MucAudit.OWNER_OCCUPANT ||
                    presence_target == MucAudit.OTHER_OWNER_OCCUPANT)) {
            string room = presence_target == MucAudit.OWNER_OCCUPANT
                ? MucAudit.ROOM : MucAudit.OTHER_ROOM;
            if (node.get_attribute("type") == Presence.Stanza.TYPE_UNAVAILABLE) {
                joined_presence_rooms.remove(room);
                return;
            }
            if (!joined_presence_rooms.contains(room)) {
                joined_presence_rooms.add(room);
                if (hold_join_self_presence) return;
                emit_presence(MucAudit.build_muc_presence(
                    (!) presence_target, "owner@example.test/dinox",
                    "owner", "moderator", true));
            } else {
                occupant_presence_resync_count++;
                last_occupant_presence_resync = node;
            }
            return;
        }

        if (node.name != "iq") return;

        if (node.get_attribute("type") == "set" && node.get_subnode("query", MucAudit.NS_MUC_OWNER) != null) {
            last_config_set = node;
            if (owner_set_error_condition != null) {
                emit_iq_result(MucAudit.build_iq_error_for_request(node,
                    (!) owner_set_error_condition));
            } else {
                emit_iq_result(MucAudit.build_iq_result_for_request(node,
                    new StanzaNode.build("query", MucAudit.NS_MUC_OWNER)
                        .add_self_xmlns(), muc_result_from_override,
                    omit_muc_result_from));
            }
            return;
        }

        if (node.get_attribute("type") == "set" &&
                node.get_subnode("query", MucAudit.NS_MUC_ADMIN) != null) {
            last_admin_set = node;
            if (admin_set_error_condition != null) {
                emit_iq_result(MucAudit.build_iq_error_for_request(node,
                    (!) admin_set_error_condition));
            } else {
                emit_iq_result(MucAudit.build_iq_result_for_request(node,
                    new StanzaNode.build("query", MucAudit.NS_MUC_ADMIN)
                        .add_self_xmlns(), muc_result_from_override,
                    omit_muc_result_from));
            }
            return;
        }

        if (node.get_attribute("type") != "get") return;

        StanzaNode? query_node = node.get_subnode("query", MucAudit.NS_DISCO_INFO);
        if (query_node != null) {
            if (hold_disco_results) {
                held_disco_requests.add(node);
                return;
            }
            if (disco_error_condition != null) {
                emit_iq_result(MucAudit.build_iq_error_for_request(node,
                    (!) disco_error_condition));
            } else {
                emit_iq_result(MucAudit.build_iq_result_for_request(node,
                    MucAudit.build_disco_info_result_payload(
                        disco_members_only, disco_subject_policy,
                        disco_semi_anonymous, disco_invite_policy,
                        disco_foreign_invite_policy,
                        disco_stable_ids, disco_avatar_hash),
                    muc_result_from_override, omit_muc_result_from));
            }
            return;
        }

        query_node = node.get_subnode("query", MucAudit.NS_MUC_ADMIN);
        if (query_node == null) return;

        if (hold_affiliation_results) {
            held_affiliation_requests.add(node);
            return;
        }

        StanzaNode? item_node = ((!) query_node).get_subnode("item", MucAudit.NS_MUC_ADMIN);
        string? requested_affiliation = item_node != null ? ((!) item_node).get_attribute("affiliation") : null;
        string? result_jid = requested_affiliation == "member" ? member_query_jid : null;
        StanzaNode affiliation_payload =
            affiliation_query_payload_override != null ?
                (!) affiliation_query_payload_override :
                MucAudit.build_affiliation_result_payload(
                    result_jid != null ? "member" : null, result_jid);
        affiliation_query_payload_override = null;
        emit_iq_result(MucAudit.build_iq_result_for_request(
            node, affiliation_payload,
            muc_result_from_override, omit_muc_result_from
        ));
    }

    public void emit_next_held_disco_result(bool members_only,
            int subject_policy) {
        fail_if(held_disco_requests.size == 0,
            "No held disco request is available");
        StanzaNode request = held_disco_requests.remove_at(0);
        emit_iq_result(MucAudit.build_iq_result_for_request(request,
            MucAudit.build_disco_info_result_payload(members_only,
                subject_policy), muc_result_from_override,
            omit_muc_result_from));
    }

    public void emit_next_held_affiliation_result(string affiliation,
            string? jid) {
        fail_if(held_affiliation_requests.size == 0,
            "No held affiliation request is available");
        StanzaNode request = held_affiliation_requests.remove_at(0);
        emit_iq_result(MucAudit.build_iq_result_for_request(request,
            MucAudit.build_affiliation_result_payload(affiliation, jid),
            muc_result_from_override, omit_muc_result_from));
    }

    public void emit_iq_result(StanzaNode node) {
        received_iq_stanza(this, node);
    }

    public void emit_presence(StanzaNode node) {
        received_presence_stanza(this, node);
    }

    public void emit_message(StanzaNode node) {
        received_message_stanza(this, node);
    }

    public override async void setup() throws IOError {
    }
}

private class MucEnterDetachAuditStream : XmppStream {
    public bool wrote_join_presence { get; private set; default = false; }

    public MucEnterDetachAuditStream(Jid remote_name) {
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

        if (node.name == "presence" && !wrote_join_presence && node.get_attribute("to") == MucAudit.OWNER_OCCUPANT) {
            wrote_join_presence = true;
            Idle.add(() => {
                Xep.Muc.Module? muc = get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
                if (muc != null) {
                    ((!) muc).detach(this);
                }
                return Source.REMOVE;
            });
        }
    }

    public override async void setup() throws IOError {
    }
}

private class MucEnterErrorWithoutIdAuditStream : XmppStream {
    public bool wrote_join_presence { get; private set; default = false; }

    public MucEnterErrorWithoutIdAuditStream(Jid remote_name) {
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

        if (node.name == "presence" && !wrote_join_presence && node.get_attribute("to") == MucAudit.OWNER_OCCUPANT) {
            wrote_join_presence = true;
            received_presence_stanza(this, MucAudit.build_muc_error_presence(
                MucAudit.OWNER_OCCUPANT,
                null,
                ErrorStanza.TYPE_CANCEL,
                ErrorStanza.CONDITION_CONFLICT
            ));
        }
    }

    public override async void setup() throws IOError {
    }
}

private class MucEnterMismatchedErrorIdAuditStream : XmppStream {
    public bool wrote_join_presence { get; private set; default = false; }

    public MucEnterMismatchedErrorIdAuditStream(Jid remote_name) {
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

        if (node.name == "presence" && !wrote_join_presence && node.get_attribute("to") == MucAudit.OWNER_OCCUPANT) {
            wrote_join_presence = true;
            received_presence_stanza(this, MucAudit.build_muc_error_presence(
                MucAudit.OWNER_OCCUPANT,
                "unrelated-id",
                ErrorStanza.TYPE_CANCEL,
                ErrorStanza.CONDITION_CONFLICT
            ));
            received_presence_stanza(this, MucAudit.build_muc_presence(
                MucAudit.OWNER_OCCUPANT,
                "owner@example.test/dinox",
                "owner",
                "moderator",
                true
            ));
        }
    }

    public override async void setup() throws IOError {
    }
}

private class MucEnterBareErrorWithoutIdAuditStream : XmppStream {
    public bool wrote_join_presence { get; private set; default = false; }

    public MucEnterBareErrorWithoutIdAuditStream(Jid remote_name) {
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

        if (node.name == "presence" && !wrote_join_presence && node.get_attribute("to") == MucAudit.OWNER_OCCUPANT) {
            wrote_join_presence = true;
            received_presence_stanza(this, MucAudit.build_muc_error_presence(
                MucAudit.ROOM,
                null,
                ErrorStanza.TYPE_CANCEL,
                ErrorStanza.CONDITION_ITEM_NOT_FOUND
            ));
        }
    }

    public override async void setup() throws IOError {
    }
}

private class MucEnterPresenceWithout110AuditStream : XmppStream {
    public bool wrote_join_presence { get; private set; default = false; }

    public MucEnterPresenceWithout110AuditStream(Jid remote_name) {
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

        if (node.name == "presence" && !wrote_join_presence && node.get_attribute("to") == MucAudit.OWNER_OCCUPANT) {
            wrote_join_presence = true;
            received_presence_stanza(this, MucAudit.build_muc_presence(
                MucAudit.OWNER_OCCUPANT,
                "owner@example.test/dinox",
                "owner",
                "moderator",
                false
            ));
            received_presence_stanza(this, MucAudit.build_muc_presence(
                MucAudit.OWNER_OCCUPANT,
                "owner@example.test/dinox",
                "owner",
                "moderator",
                true,
                true
            ));
        }
    }

    public override async void setup() throws IOError {
    }
}

private class MucEnterCancelAuditStream : XmppStream {
    public int join_presence_count { get; private set; default = 0; }
    public int unavailable_presence_count { get; private set; default = 0; }

    public MucEnterCancelAuditStream(Jid remote_name) {
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

        if (node.name == "presence" && node.get_attribute("to") == MucAudit.OWNER_OCCUPANT) {
            if (node.get_attribute("type") == Presence.Stanza.TYPE_UNAVAILABLE) {
                unavailable_presence_count++;
                return;
            }

            join_presence_count++;
            if (join_presence_count == 1) {
                Idle.add(() => {
                    Xep.Muc.Module? muc = get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
                    if (muc != null) {
                        try {
                            ((!) muc).cancel_enter(this, new Jid(MucAudit.ROOM));
                        } catch (InvalidJidError e) {
                            fail_if_reached(@"Unexpected invalid room JID in MUC enter cancel test: $(e.message)");
                        }
                    }
                    return Source.REMOVE;
                });
            } else {
                received_presence_stanza(this, MucAudit.build_muc_presence(
                    MucAudit.OWNER_OCCUPANT,
                    "owner@example.test/dinox",
                    "owner",
                    "moderator",
                    true
                ));
            }
            return;
        }

        if (node.name != "iq" || node.get_attribute("type") != "get") return;

        StanzaNode? query_node = node.get_subnode("query", MucAudit.NS_DISCO_INFO);
        if (query_node != null) {
            received_iq_stanza(this, MucAudit.build_iq_result_for_request(node, MucAudit.build_disco_info_result_payload()));
            return;
        }

        query_node = node.get_subnode("query", MucAudit.NS_MUC_ADMIN);
        if (query_node != null) {
            received_iq_stanza(this, MucAudit.build_iq_result_for_request(node, MucAudit.build_affiliation_result_payload(null, null)));
        }
    }

    public override async void setup() throws IOError {
    }
}

private class PingTimeoutAuditStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode>();

    public PingTimeoutAuditStream(Jid remote_name) {
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
        written_nodes.add(node);

        Idle.add(() => {
            Iq.Module? iq = get_module<Iq.Module>(Iq.Module.IDENTITY);
            if (iq != null) {
                ((!) iq).detach(this);
            }
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

private class IqWriteFailureAuditStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode>();

    public IqWriteFailureAuditStream(Jid remote_name) {
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
        written_nodes.add(node);
        throw new IOError.CLOSED("simulated write failure");
    }

    public override async void setup() throws IOError {
    }
}

private class MucAuditCapsCache : Object, Xep.ServiceDiscovery.CapsCache {
    public async bool has_entity_feature(Jid jid, string feature) {
        return false;
    }

    public async Gee.Set<Xep.ServiceDiscovery.Identity> get_entity_identities(Jid jid) {
        return new Gee.HashSet<Xep.ServiceDiscovery.Identity>(
            Xep.ServiceDiscovery.Identity.hash_func,
            Xep.ServiceDiscovery.Identity.equals_func);
    }
}

}
