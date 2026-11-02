using Xmpp;

namespace Dino.Test {

private class AuditVideoDevice : Object, Dino.Plugins.MediaDevice {
    public string id { owned get { return "audit-camera"; } }
    public string display_name { owned get { return "Audit camera"; } }
    public string? detail_name { owned get { return null; } }
    public string? media { owned get { return "video"; } }
    public bool incoming { get { return false; } }
}

private class AuditMujiCodecProvider : Object,
        Xmpp.Xep.Muji.CodecProvider {
    public async Gee.List<Xmpp.Xep.JingleRtp.PayloadType>
            get_supported_payloads(string media) throws GLib.Error {
        return new Gee.ArrayList<Xmpp.Xep.JingleRtp.PayloadType>();
    }

    public async bool is_payload_supported(string media,
            Xmpp.Xep.JingleRtp.PayloadType payload_type)
            throws GLib.Error {
        return false;
    }
}

private class AuditMujiGroupSession :
        Dino.Plugins.MujiCallEngineGroupSession {
    private Jid audit_room;
    private AuditMujiCodecProvider audit_codec_provider =
        new AuditMujiCodecProvider();
    internal uint video_device_calls { get; private set; default=0; }

    public override Jid room_jid { get { return audit_room; } }
    public override Xmpp.Xep.Muji.CodecProvider codec_provider {
        get { return audit_codec_provider; }
    }

    internal AuditMujiGroupSession(Jid room) {
        audit_room = room;
    }

    public override void configure_conference_media(
            Gee.Map<string, string> content_names_by_media,
            Gee.Map<string, Gee.List<Xmpp.Xep.JingleRtp.PayloadType>>
                payload_types_by_media)
            throws GLib.Error {
    }

    public override Dino.Plugins.JmiCallEngineSession
            start_outgoing_peer_session(
                Jid peer_full_jid, string sid, bool video_requested)
            throws GLib.Error {
        throw new IOError.NOT_SUPPORTED("Not used by this audit fake");
    }

    public override void prepare_peer_adoption(Jid peer_full_jid,
            Dino.Plugins.JmiCallEngineSession session) throws GLib.Error {
    }

    public override bool copy_preferred_conference_media(
            out Gee.Map<string, string> content_names_by_media,
            out Gee.Map<string, Gee.List<Xmpp.Xep.JingleRtp.PayloadType>>
                payload_types_by_media) {
        content_names_by_media = new Gee.HashMap<string, string>();
        payload_types_by_media = new Gee.HashMap<string,
            Gee.List<Xmpp.Xep.JingleRtp.PayloadType>>();
        return false;
    }

    public override void adopt_peer_session(Jid peer_full_jid,
            Dino.Plugins.JmiCallEngineSession session) throws GLib.Error {
    }

    public override void expect_incoming_peer_session(
            Jid peer_full_jid, bool video_requested)
            throws GLib.Error {
    }

    public override bool cancel_expected_incoming_peer_session(
            Jid peer_full_jid) {
        return false;
    }

    public override void set_video_device(Dino.Plugins.MediaDevice device)
            throws GLib.Error {
        video_device_calls++;
    }

    public override void close() {
    }
}

private class AuditMujiInviteFixture : Object {
    internal MujiInviteAttemptRegistry registry = new MujiInviteAttemptRegistry();
    internal Xep.Muji.GroupCall group;
    internal XmppStream stream;
    internal Jid real_jid;
    internal Jid occupant;
    internal string call_id = "audit-muji-invite";
    internal int timeout_retractions = 0;
    private ulong ready_handler;

    internal AuditMujiInviteFixture() throws InvalidJidError {
        real_jid = new Jid("bob@example.test/Phone");
        occupant = new Jid("call@conference.example.test/Bob");
        group = new Xep.Muji.GroupCall(occupant.bare_jid, new AuditMujiCodecProvider());
        stream = new StartTlsXmppStream(new Jid("alice@example.test"), "example.test", 5222,
            new TlsXmppStream.OnInvalidCertWrapper((_certificate, _errors) => false));
        ready_handler = group.peer_joined.connect((jid) => {
            MujiInviteAttempt? attempt = registry.get_current(jid);
            if (attempt != null) registry.complete_ready_peer((!) attempt, jid, group, stream, call_id);
        });
    }

    internal MujiInviteAttempt arm() {
        MujiInviteAttempt attempt = registry.begin(real_jid);
        attempt.group_call = group;
        attempt.stream = stream;
        attempt.call_id = call_id;
        attempt.timeout_source_id = Timeout.add_seconds(60, () => {
            attempt.timeout_source_id = 0;
            if (registry.is_current(attempt)) timeout_retractions++;
            return Source.REMOVE;
        });
        return attempt;
    }

    internal void ready(bool emit_signal = true) {
        // Seed the published-ready cache consumed by CallState. The XMPP
        // parser/codec selection that populates it has its own MUJI audits.
        group.peers.add(occupant);
        group.track_muji_participant(occupant, real_jid);
        if (emit_signal) group.peer_joined(real_jid);
    }

    internal void expire(MujiInviteAttempt attempt) {
        Source? timeout = MainContext.default().find_source_by_id(attempt.timeout_source_id);
        assert(timeout != null);
        ((!) timeout).set_ready_time(0);
        while (MainContext.default().pending()) MainContext.default().iteration(false);
    }

    internal void close() {
        registry.clear();
        if (ready_handler != 0 && SignalHandler.is_connected(group, ready_handler)) {
            SignalHandler.disconnect(group, ready_handler);
        }
        ready_handler = 0;
    }
}

class CallStateAudit : Gee.TestCase {
    public CallStateAudit() {
        base("CallStateAudit");
        add_test("reinvite_invalidates_old_generation_before_async_work",
            test_reinvite_invalidates_old_generation);
        add_test("failed_owner_cleanup_retry_is_bounded_and_owned",
            test_cleanup_retry_is_bounded_and_owned);
        add_test("ready_muji_join_retires_invite_before_media_peer_failure",
            test_ready_join_retires_invite);
        add_test("ready_muji_join_requires_exact_current_invite_context",
            test_ready_join_requires_exact_context);
        add_test("muji_invite_without_ready_keeps_60s_expiry",
            test_unaccepted_invite_still_expires);
        add_test("muji_reinvite_after_leave_has_new_generation",
            test_ready_join_then_reinvite);
        add_test("already_ready_muji_reinvite_completes_without_new_lease",
            test_already_ready_reinvite);
        add_test("muji_ready_during_grant_cancels_retry_and_late_work",
            test_ready_during_grant);
        add_test("video_effect_latest_wins_restarts_after_session_cancel",
            test_video_effect_latest_wins_restarts_after_session_cancel);
        add_test("video_effect_handler_rekeys_and_releases_after_peer_rename",
            test_video_effect_handler_rekeys_and_releases_after_peer_rename);
        add_test("muji_capability_late_room_discovery",
            test_muji_capability_late_room_discovery);
        add_test("muji_capability_late_service_discovery",
            test_muji_capability_late_service_discovery);
        add_test("muji_capability_respects_audio_video_engine_split",
            test_muji_capability_respects_audio_video_engine_split);
        add_test("muji_capability_stale_selection_is_rejected",
            test_muji_capability_stale_selection_is_rejected);
        add_test("muji_group_and_media_engine_facets_must_match",
            test_muji_group_and_media_engine_facets_must_match);
        add_test("call_lifecycle_generation_invalidates_async_continuations",
            test_call_lifecycle_generation_invalidates_async_continuations);
        add_test("cim_targets_preserve_type_and_exact_destination",
            test_cim_targets_preserve_type_and_exact_destination);
        add_test("cim_groupchat_echo_binds_only_room_reference",
            test_cim_groupchat_echo_binds_only_room_reference);
        add_test("cim_actions_bind_sender_type_and_reference_atomically",
            test_cim_actions_bind_sender_type_and_reference_atomically);
        add_test("own_cim_action_selection_is_incoming_and_unique",
            test_own_cim_action_selection_is_incoming_and_unique);
        add_test("cim_direct_target_removal_preserves_other_resource",
            test_cim_direct_target_removal_preserves_other_resource);
        add_test("cim_groupchat_terminal_waits_for_matching_echo",
            test_cim_groupchat_terminal_waits_for_matching_echo);
        add_test("cim_invite_replay_tombstone_is_exact_and_bounded",
            test_cim_invite_replay_tombstone_is_exact_and_bounded);
        add_test("muji_reinvite_has_fresh_message_reference_and_stable_context",
            test_muji_reinvite_has_fresh_reference);
        add_test("muji_reinvite_rejects_stale_actions_and_own_carbons",
            test_muji_reinvite_rejects_stale_actions);
        add_test("muji_reinvite_reference_preserves_parallel_and_room_targets",
            test_muji_reinvite_preserves_other_references);
        add_test("direct_to_muji_never_escalates_camera",
            test_direct_to_muji_never_escalates_camera);
        add_test("muji_media_policy_downgrades_video_and_requires_audio",
            test_muji_media_policy_downgrades_video_and_requires_audio);
        add_test("call_capability_excludes_groupchat_private_messages",
            test_call_capability_excludes_groupchat_private_messages);
        add_test("stale_group_join_cannot_publish_owned_state",
            test_stale_group_join_cannot_publish_owned_state);
        add_test("google_muji_accept_never_routes_to_legacy_peer",
            test_google_muji_accept_never_routes_to_legacy_peer);
        add_test("streamless_terminal_cleanup_claims_fake_peer_once",
            test_streamless_terminal_cleanup_claims_fake_peer_once);
        add_test("failed_private_config_rolls_back_without_proposal",
            test_failed_private_config_rolls_back_without_proposal);
        add_test("incoming_group_source_stale_blocks_join_and_accept",
            test_incoming_group_source_stale_blocks_join_and_accept);
        add_test("incoming_group_inviter_requires_exact_live_resource",
            test_incoming_group_inviter_requires_exact_live_resource);
        add_test("establishing_retract_invalidates_group_accept",
            test_establishing_retract_invalidates_group_accept);
        add_test("muji_video_device_dispatches_once_to_group_owner",
            test_muji_video_device_dispatches_once_to_group_owner);
        add_test("direct_camera_is_inherited_by_new_group_owner",
            test_direct_camera_is_inherited_by_new_group_owner);
        add_test("groupchat_participant_reject_keeps_room_target",
            test_groupchat_participant_reject_keeps_room_target);
        add_test("published_muji_rooms_leave_without_destroy",
            test_published_muji_rooms_leave_without_destroy);
        add_test("delayed_peer_capability_cannot_start_after_teardown",
            test_delayed_peer_capability_cannot_start_after_teardown);
        add_test("duplicate_group_invite_preserves_live_call",
            test_duplicate_group_invite_preserves_live_call);
        add_test("muji_invitees_receive_member_affiliation",
            test_muji_invitees_receive_member_affiliation);
        add_test("empty_media_peer_set_waits_for_preparing_participant",
            test_empty_media_peer_set_waits_for_preparing_participant);
        add_test("muji_empty_timeout_only_ends_unanswered_groups",
            test_muji_empty_timeout_only_ends_unanswered_groups);
        add_test("hangup_before_cim_accept_published_sends_reject",
            test_hangup_before_cim_accept_published_sends_reject);
        add_test("shared_groupchat_reject_cannot_close_other_recipient",
            test_shared_groupchat_reject_cannot_close_other_recipient);
        add_test("call_invite_protocol_rejects_muc_private_message",
            test_call_invite_protocol_rejects_muc_private_message);
        add_test("parallel_invites_wait_for_private_config_commit",
            test_parallel_invites_wait_for_private_config_commit);
        add_test("cim_left_routes_only_owned_call_or_participant",
            test_cim_left_routes_only_owned_call_or_participant);
        add_test("failed_muji_peer_expect_keeps_empty_timeout_owned",
            test_failed_muji_peer_expect_keeps_empty_timeout_owned);
        add_test("foreign_private_reject_cannot_cancel_incoming_room_invite",
            test_foreign_private_reject_cannot_cancel_incoming_room_invite);
    }

    private void test_reinvite_invalidates_old_generation() {
        var registry = new MujiInviteAttemptRegistry();
        Jid invitee;
        try {
            invitee = new Jid("bob@example.test/device");
        } catch (InvalidJidError e) {
            fail_if_reached("Static test JID is invalid: %s".printf(e.message));
            return;
        }
        MujiInviteAttempt old_attempt = registry.begin(invitee);

        old_attempt.timeout_source_id = Timeout.add_seconds(60, () => {
            return Source.REMOVE;
        });
        old_attempt.cleanup_retry_source_id = Timeout.add_seconds(60, () => {
            return Source.REMOVE;
        });

        MujiInviteAttempt new_attempt = registry.begin(invitee.bare_jid);

        fail_if(old_attempt.timeout_source_id != 0,
            "Re-invite must synchronously cancel the old join timeout");
        fail_if(old_attempt.cleanup_retry_source_id != 0,
            "Re-invite must synchronously cancel the old cleanup retry");
        fail_if(registry.is_current(old_attempt),
            "The old generation must be stale before any re-invite await");
        fail_if(!registry.is_current(new_attempt),
            "The replacement generation must exclusively own the invite");
        fail_if(old_attempt.generation == new_attempt.generation,
            "Every re-invite must receive a distinct generation");

        uint stale_retry_delay;
        fail_if(registry.register_cleanup_failure(old_attempt,
                out stale_retry_delay),
            "A stale generation must not reacquire cleanup ownership");
        fail_if(stale_retry_delay != 0 || !registry.is_current(new_attempt),
            "Stale cleanup must not disturb the replacement generation");
        registry.clear();
    }

    private void test_cleanup_retry_is_bounded_and_owned() {
        var registry = new MujiInviteAttemptRegistry();
        Jid invitee;
        try {
            invitee = new Jid("bob@example.test");
        } catch (InvalidJidError e) {
            fail_if_reached("Static test JID is invalid: %s".printf(e.message));
            return;
        }
        MujiInviteAttempt attempt = registry.begin(invitee);
        uint retry_delay;

        fail_if(!registry.register_cleanup_failure(attempt, out retry_delay) ||
                retry_delay != 2 || !registry.is_current(attempt),
            "First failed Owner cleanup must stay owned for a 2s retry");
        fail_if(!registry.register_cleanup_failure(attempt, out retry_delay) ||
                retry_delay != 5 || !registry.is_current(attempt),
            "Second failed Owner cleanup must stay owned for a 5s retry");
        fail_if(!registry.register_cleanup_failure(attempt, out retry_delay) ||
                retry_delay != 10 || !registry.is_current(attempt),
            "Third failed Owner cleanup must stay owned for a 10s retry");
        fail_if(registry.register_cleanup_failure(attempt, out retry_delay),
            "Owner cleanup retry count must be bounded");
        fail_if(retry_delay != 0 || registry.is_current(attempt),
            "Exhausted cleanup must release its local ownership deterministically");
    }

    private delegate void InviteFixtureCheck(AuditMujiInviteFixture fixture) throws GLib.Error;

    private void with_invite_fixture(InviteFixtureCheck check) {
        AuditMujiInviteFixture? fixture = null;
        try {
            fixture = new AuditMujiInviteFixture();
            check((!) fixture);
        } catch (GLib.Error error) {
            fail_if_reached("MUJI invite audit failed: " + error.message);
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void test_ready_join_retires_invite() {
        with_invite_fixture((f) => {
            MujiInviteAttempt attempt = f.arm();
            Source? timeout = MainContext.default().find_source_by_id(attempt.timeout_source_id);
            f.ready();
            // The media PeerState may now fail/disappear; room Ready remains.
            // No timer or cleanup ownership may depend on that transient leg.
            fail_if(!attempt.ready_joined || f.registry.is_current(attempt) ||
                    attempt.timeout_source_id != 0 || timeout == null || !((!) timeout).is_destroyed(),
                "Published Ready must destroy the actual invite timer before any media-leg failure");
            uint retry_delay;
            fail_if(f.registry.register_cleanup_failure(attempt, out retry_delay),
                "Media failure cannot reacquire cleanup for an accepted invite");
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            fail_if(f.timeout_retractions != 0 || !f.group.has_muji_participant(f.occupant),
                "An accepted room member must not receive a later never-joined retraction");
        });
    }

    private void test_ready_join_requires_exact_context() {
        with_invite_fixture((f) => {
            MujiInviteAttempt attempt = f.arm();
            uint timeout_id = attempt.timeout_source_id;
            f.ready(false);
            var other_group = new Xep.Muji.GroupCall(f.occupant.bare_jid, new AuditMujiCodecProvider());
            var other_stream = new StartTlsXmppStream(new Jid("alice@example.test"), "example.test", 5222,
                new TlsXmppStream.OnInvalidCertWrapper((_certificate, _errors) => false));
            fail_if(f.registry.complete_ready_peer(attempt, new Jid("carol@example.test/Phone"), f.group, f.stream, f.call_id) ||
                    f.registry.complete_ready_peer(attempt, new Jid("bob@example.test/Desktop"), f.group, f.stream, f.call_id) ||
                    f.registry.complete_ready_peer(attempt, f.real_jid.bare_jid, f.group, f.stream, f.call_id) ||
                    f.registry.complete_ready_peer(attempt, f.real_jid, other_group, f.stream, f.call_id) ||
                    f.registry.complete_ready_peer(attempt, f.real_jid, f.group, other_stream, f.call_id) ||
                    f.registry.complete_ready_peer(attempt, f.real_jid, f.group, f.stream, "different-call"),
                "Another real identity/resource, room instance, stream or call cannot accept this invite");
            fail_if(!f.registry.is_current(attempt) || attempt.ready_joined || attempt.timeout_source_id != timeout_id,
                "Unrelated Ready evidence must leave the current invitation timer intact");
        });
    }

    private void test_unaccepted_invite_still_expires() {
        with_invite_fixture((f) => {
            MujiInviteAttempt attempt = f.arm();
            // Preliminary membership/Preparing alone is not published Ready.
            f.group.track_muji_participant(f.occupant, f.real_jid);
            fail_if(f.registry.complete_if_ready(attempt, f.group, f.stream, f.call_id),
                "A room occupant that never became Ready cannot retain an invitation lease");
            f.expire(attempt);
            fail_if(attempt.ready_joined || f.timeout_retractions != 1,
                "The unchanged 60-second source must still expire a never-ready invitation");
        });
    }

    private void test_ready_join_then_reinvite() {
        with_invite_fixture((f) => {
            MujiInviteAttempt old_attempt = f.arm();
            f.ready();
            Jid? departed;
            f.group.forget_muji_participant(f.occupant, out departed);
            MujiInviteAttempt fresh_attempt = f.arm();
            fail_if(fresh_attempt.generation == old_attempt.generation || fresh_attempt.ready_joined ||
                    f.registry.complete_if_ready(fresh_attempt, f.group, f.stream, f.call_id),
                "A new invitation after genuine leave needs its own Ready and timeout generation");
            f.ready(false);
            fail_if(f.registry.complete_ready_peer(old_attempt, f.real_jid, f.group, f.stream, f.call_id) ||
                    !f.registry.is_current(fresh_attempt) || fresh_attempt.timeout_source_id == 0,
                "An old invitation continuation cannot retire a fresh generation's timer");
            f.group.peer_joined(f.real_jid);
            fail_if(!fresh_attempt.ready_joined || f.registry.is_current(fresh_attempt),
                "The new generation must complete only on its own current Ready");
        });
    }

    private void test_already_ready_reinvite() {
        with_invite_fixture((f) => {
            f.ready(false);
            MujiInviteAttempt attempt = f.arm();
            fail_if(!f.registry.complete_if_ready(attempt, f.group, f.stream, f.call_id) ||
                    !attempt.ready_joined || attempt.timeout_source_id != 0,
                "An already-ready member must complete before a new grant/proposal/timeout");
            MujiInviteAttempt repeat = f.arm();
            fail_if(!f.registry.complete_if_ready(repeat, f.group, f.stream, f.call_id) ||
                    f.registry.is_current(repeat) || repeat.timeout_source_id != 0,
                "Re-inviting an existing Ready member must not leave another expiring lease");
        });
    }

    private void test_ready_during_grant() {
        with_invite_fixture((f) => {
            MujiInviteAttempt attempt = f.arm();
            attempt.retract_sent = true; // An already-dispatched request cannot be recalled.
            attempt.cleanup_retry_source_id = Timeout.add_seconds(60, () => Source.REMOVE);
            Source? retry = MainContext.default().find_source_by_id(attempt.cleanup_retry_source_id);
            f.ready();
            fail_if(!attempt.ready_joined || !attempt.retract_sent || f.registry.is_current(attempt) ||
                    attempt.timeout_source_id != 0 || attempt.cleanup_retry_source_id != 0 ||
                    retry == null || !((!) retry).is_destroyed(),
                "Ready during async work must preserve its outcome and retire every pending source");
            uint retry_delay;
            fail_if(f.registry.complete_if_ready(attempt, f.group, f.stream, f.call_id) ||
                    f.registry.register_cleanup_failure(attempt, out retry_delay),
                "A delayed grant/cleanup continuation must not reacquire a completed invitation");
        });
    }

    private void test_video_effect_latest_wins_restarts_after_session_cancel() {
        var queue = new VideoEffectLatestWinsQueue();
        var grayscale = new Plugins.JmiVideoEffectSelection(
            Plugins.JmiVideoEffectKind.GRAYSCALE);
        var warm_tone = new Plugins.JmiVideoEffectSelection(
            Plugins.JmiVideoEffectKind.WARM_TONE);
        var off = new Plugins.JmiVideoEffectSelection(
            Plugins.JmiVideoEffectKind.OFF);

        queue.enqueue(grayscale);
        uint64 old_session_generation = queue.begin_processing();
        Plugins.JmiVideoEffectSelection? first = queue.take(old_session_generation);
        fail_if(first == null || ((!) first).kind != Plugins.JmiVideoEffectKind.GRAYSCALE,
            "The first session must own the in-flight grayscale choice");

        // Simulate a warm-tone replacement arriving while PeerState awaits
        // the old engine session. That await then returns IOError.CANCELLED.
        queue.enqueue(warm_tone);
        fail_if(!queue.finish(old_session_generation),
            "Session cancellation must request another processing pass for the latest choice");
        fail_if(!queue.has_pending || queue.in_flight,
            "The latest choice must remain pending without a stuck in-flight flag");

        uint64 replacement_generation = queue.begin_processing();
        Plugins.JmiVideoEffectSelection? replacement = queue.take(replacement_generation);
        fail_if(replacement == null || ((!) replacement).kind != Plugins.JmiVideoEffectKind.WARM_TONE,
            "The replacement session must receive the pending warm-tone choice");

        queue.enqueue(off);
        fail_if(!queue.finish(replacement_generation),
            "An Off choice arriving during warm-tone apply must request one final processing pass");
        uint64 off_generation = queue.begin_processing();
        Plugins.JmiVideoEffectSelection? final_choice = queue.take(off_generation);
        fail_if(final_choice == null || ((!) final_choice).kind != Plugins.JmiVideoEffectKind.OFF,
            "Gray-to-Warm-to-Off switching must preserve the latest explicit choice");
        fail_if(queue.finish(off_generation) || queue.has_pending || queue.in_flight,
            "A drained Off choice must leave the queue idle");
    }

    private void test_video_effect_handler_rekeys_and_releases_after_peer_rename() {
        Jid bare_jid;
        Jid full_jid;
        try {
            bare_jid = new Jid("bob@example.test");
            full_jid = new Jid("bob@example.test/Phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static test JID is invalid: %s".printf(e.message));
            return;
        }

        var effect_handler_ids = new Gee.HashMap<Jid, ulong>(
            Jid.hash_func, Jid.equals_func);
        effect_handler_ids[bare_jid] = 417;

        CallState.rekey_peer_handler_id(effect_handler_ids, bare_jid, full_jid);
        fail_if(effect_handler_ids.has_key(bare_jid),
            "Bare-to-Full rename must release the old effect-handler key");
        fail_if(!effect_handler_ids.has_key(full_jid) || effect_handler_ids[full_jid] != 417,
            "Bare-to-Full rename must preserve effect-handler ownership at the Full JID");

        ulong teardown_handler_id = CallState.take_peer_handler_id(
            effect_handler_ids, full_jid);
        fail_if(teardown_handler_id != 417 || !effect_handler_ids.is_empty,
            "Call teardown must recover and remove the renamed effect handler without a leak");
    }

    private void test_muji_capability_late_room_discovery() {
        ConversationCallCapabilities pending =
            Calls.evaluate_group_call_capabilities(
                true, true, false, true, true, false, false, true);
        fail_if_not(pending.visible,
            "A joined room with in-flight room info must keep the call control visible");
        fail_if(pending.audio != CallCapabilityStatus.PENDING ||
                pending.video != CallCapabilityStatus.UNAVAILABLE ||
                pending.reason != CallCapabilityReason.ROOM_INFO_PENDING,
            "Room-info discovery must preserve the independent engine capabilities");

        ConversationCallCapabilities ready =
            Calls.evaluate_group_call_capabilities(
                true, true, false, true, false, false, true, true);
        fail_if(!ready.visible ||
                ready.audio != CallCapabilityStatus.AVAILABLE ||
                ready.video != CallCapabilityStatus.UNAVAILABLE ||
                ready.reason != CallCapabilityReason.NONE,
            "A late private-room result must enable audio without inventing video support");
    }

    private void test_muji_capability_late_service_discovery() {
        ConversationCallCapabilities pending =
            Calls.evaluate_group_call_capabilities(
                true, true, false, true, false, false, true, false);
        fail_if(!pending.visible ||
                pending.audio != CallCapabilityStatus.PENDING ||
                pending.reason != CallCapabilityReason.MUC_SERVICE_PENDING,
            "A private room must stay visible while its conference service is discovered");

        ConversationCallCapabilities ready =
            Calls.evaluate_group_call_capabilities(
                true, true, false, true, false, false, true, true);
        fail_if(ready.audio != CallCapabilityStatus.AVAILABLE,
            "Late conference-service discovery must enable the existing audio action");

        ConversationCallCapabilities public_room =
            Calls.evaluate_group_call_capabilities(
                true, true, false, true, false, false, false, true);
        fail_if(public_room.visible ||
                public_room.reason != CallCapabilityReason.ROOM_NOT_PRIVATE,
            "Public rooms must remain outside DinoX's private-MUC call policy");
    }

    private void test_muji_capability_respects_audio_video_engine_split() {
        ConversationCallCapabilities audio_only =
            Calls.evaluate_group_call_capabilities(
                true, true, false, true, false, false, true, true);
        fail_if(audio_only.audio != CallCapabilityStatus.AVAILABLE ||
                audio_only.video != CallCapabilityStatus.UNAVAILABLE,
            "The group-call menu must expose audio without enabling unsupported video");

        ConversationCallCapabilities audio_video =
            Calls.evaluate_group_call_capabilities(
                true, true, true, true, false, false, true, true);
        fail_if(audio_video.audio != CallCapabilityStatus.AVAILABLE ||
                audio_video.video != CallCapabilityStatus.AVAILABLE,
            "Video must become available only when the selected plugin advertises group video");
    }

    private void test_muji_capability_stale_selection_is_rejected() {
        ConversationCallCapabilities pending =
            Calls.evaluate_group_call_capabilities(
                true, true, true, true, true, false, false, true);
        fail_if(Calls.requested_call_is_available(pending, false) ||
                Calls.requested_call_is_available(pending, true),
            "A stale enabled menu action must not start audio or video while room info is pending");

        ConversationCallCapabilities public_room =
            Calls.evaluate_group_call_capabilities(
                true, true, true, true, false, false, false, true);
        fail_if(Calls.requested_call_is_available(public_room, false) ||
                Calls.requested_call_is_available(public_room, true),
            "A room that became public must be rejected before call persistence or MUJI setup");

        ConversationCallCapabilities audio_only =
            Calls.evaluate_group_call_capabilities(
                true, true, false, true, false, false, true, true);
        fail_if(!Calls.requested_call_is_available(audio_only, false) ||
                Calls.requested_call_is_available(audio_only, true),
            "The initiation guard must preserve the selected audio/video capability split");
    }

    private void test_muji_group_and_media_engine_facets_must_match() {
        fail_if(!Calls.group_engine_facets_match(
                "google-libwebrtc", "google-libwebrtc"),
            "Equal group and media engine facets must form one selectable backend");
        fail_if(Calls.group_engine_facets_match(
                "google-libwebrtc", "different-engine") ||
                Calls.group_engine_facets_match("google-libwebrtc", null) ||
                Calls.group_engine_facets_match(null, "google-libwebrtc"),
            "Missing or mismatched media facets must fail closed before call persistence");
    }

    private void test_call_lifecycle_generation_invalidates_async_continuations() {
        var lifecycle = new CallLifecycleGeneration();
        uint64 first = lifecycle.capture();
        fail_if(!lifecycle.is_current(first),
            "A freshly captured lifecycle token must own its continuation");
        lifecycle.supersede();
        fail_if(lifecycle.is_current(first),
            "Superseding an operation must invalidate its pre-await token");
        uint64 second = lifecycle.capture();
        fail_if(!lifecycle.close() || lifecycle.is_current(second),
            "Teardown must synchronously invalidate every async continuation");
        fail_if(lifecycle.close(),
            "Lifecycle teardown must be idempotent");
    }

    private void test_cim_targets_preserve_type_and_exact_destination() {
        Jid room;
        Jid occupant;
        Jid device;
        try {
            room = new Jid("room@conference.example.test");
            occupant = new Jid("room@conference.example.test/Alice");
            device = new Jid("alice@example.test/Phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static test JID is invalid: %s".printf(e.message));
            return;
        }

        var targets = new CimTargetRegistry();
        targets.add(occupant, MessageStanza.TYPE_GROUPCHAT);
        targets.add(room, MessageStanza.TYPE_GROUPCHAT);
        targets.add(device, MessageStanza.TYPE_CHAT);
        targets.add(device, MessageStanza.TYPE_CHAT);
        fail_if(targets.size != 2,
            "CIM targets must deduplicate the room and exact chat resource independently");
        fail_if(!targets.contains(room, MessageStanza.TYPE_GROUPCHAT) ||
                !targets.contains(device, MessageStanza.TYPE_CHAT),
            "Each CIM target must retain its own stanza type");
        fail_if(targets.contains(device.bare_jid, MessageStanza.TYPE_CHAT),
            "A chat target must not silently widen from one resource to a bare JID");
    }

    private void test_cim_groupchat_echo_binds_only_room_reference() {
        Jid room;
        Jid other_room;
        Jid direct_target;
        try {
            room = new Jid("room@conference.example.test");
            other_room = new Jid("other@conference.example.test");
            direct_target = new Jid("peer@example.test/device");
        } catch (InvalidJidError e) {
            fail_if_reached("Static CIM binding JID is invalid: %s".printf(
                e.message));
            return;
        }

        var targets = new CimTargetRegistry();
        targets.add(room, MessageStanza.TYPE_GROUPCHAT);
        targets.add(direct_target, MessageStanza.TYPE_CHAT);

        var group_only = new CimTargetRegistry();
        group_only.add(room, MessageStanza.TYPE_GROUPCHAT);
        fail_if(group_only.matches_reference("provisional-origin-id",
                    "provisional-origin-id", false),
            "An outgoing groupchat target must not use the provisional origin-id before its room echo");
        foreach (CimTarget target in group_only.snapshot()) {
            fail_if(target.resolve_reference("provisional-origin-id", false) !=
                    null,
                "An unbound outgoing groupchat target must defer its response reference");
        }

        fail_if(!targets.bind_groupchat_reference(room, "room-stanza-id"),
            "An owned groupchat target must accept its authoritative room reference");
        fail_if(!targets.bind_groupchat_reference(room, "room-stanza-id"),
            "A duplicate room echo with the same stanza-id must be idempotent");
        fail_if(targets.bind_groupchat_reference(room,
                "conflicting-room-stanza-id"),
            "A second room stanza-id must not replace the bound reference");
        fail_if(targets.bind_groupchat_reference(other_room,
                "foreign-room-stanza-id"),
            "A room echo must not bind another groupchat target");
        fail_if(!targets.matches_reference("provisional-origin-id",
                    "provisional-origin-id", false) ||
                !targets.matches_reference("room-stanza-id",
                    "provisional-origin-id", false),
            "Both the direct origin-id and bound room stanza-id must resolve the same call");

        string? room_reference = null;
        string? direct_reference = null;
        foreach (CimTarget target in targets.snapshot()) {
            if (target.message_type == MessageStanza.TYPE_GROUPCHAT) {
                room_reference = target.resolve_reference(
                    "provisional-origin-id", false);
            } else if (target.jid.equals(direct_target)) {
                direct_reference = target.resolve_reference(
                    "provisional-origin-id", false);
            }
        }
        fail_if(room_reference != "room-stanza-id" ||
                direct_reference != "provisional-origin-id",
            "Groupchat and direct CIM targets must retain their own response references");
    }

    private void test_cim_actions_bind_sender_type_and_reference_atomically() {
        Jid room;
        Jid room_occupant;
        Jid direct_target;
        Jid other_resource;
        try {
            room = new Jid("room@conference.example.test");
            room_occupant = new Jid(
                "room@conference.example.test/Alice");
            direct_target = new Jid("alice@example.test/Phone");
            other_resource = new Jid("alice@example.test/Laptop");
        } catch (InvalidJidError e) {
            fail_if_reached("Static CIM action JID is invalid: %s".printf(
                e.message));
            return;
        }

        var targets = new CimTargetRegistry();
        targets.add(room, MessageStanza.TYPE_GROUPCHAT);
        targets.add(direct_target, MessageStanza.TYPE_CHAT);
        fail_if(!targets.bind_groupchat_reference(room, "room-reference"),
            "The owned room reference must bind before action routing");

        fail_if(!targets.matches_action(room_occupant,
                    MessageStanza.TYPE_GROUPCHAT, "room-reference",
                    "direct-reference", false),
            "A room action must match its sender, type, and bound room reference");
        fail_if(!targets.matches_action(direct_target,
                    MessageStanza.TYPE_CHAT, "direct-reference",
                    "direct-reference", false),
            "A direct action must match its exact target and origin reference");
        fail_if(!targets.matches_destination(direct_target,
                    MessageStanza.TYPE_CHAT, "direct-reference",
                    "direct-reference", false) ||
                !targets.matches_destination(room,
                    MessageStanza.TYPE_GROUPCHAT, "room-reference",
                    "direct-reference", false),
            "An own-device carbon must match its exact destination, type, and reference");
        fail_if(targets.matches_action(direct_target,
                    MessageStanza.TYPE_CHAT, "room-reference",
                    "direct-reference", false) ||
                targets.matches_action(other_resource,
                    MessageStanza.TYPE_CHAT, "direct-reference",
                    "direct-reference", false) ||
                targets.matches_action(room_occupant,
                    MessageStanza.TYPE_GROUPCHAT, "direct-reference",
                    "direct-reference", false) ||
                targets.matches_destination(other_resource,
                    MessageStanza.TYPE_CHAT, "direct-reference",
                    "direct-reference", false),
            "A reference from one target must never authorize another target or resource");
    }

    private void test_own_cim_action_selection_is_incoming_and_unique() {
        var selection = new CimOwnActionCandidateSelection();

        fail_if(selection.consider(false, true) ||
                selection.has_unique_match,
            "An outgoing MUJI target with a colliding call id must never own another resource's Carboned answer");
        fail_if(!selection.consider(true, true) ||
                !selection.has_unique_match || selection.is_ambiguous,
            "Exactly one matching incoming proposal must own the Carboned answer");
        fail_if(selection.consider(true, false) ||
                !selection.has_unique_match,
            "A non-matching incoming CallState must not disturb the unique owner");
        fail_if(selection.consider(true, true) ||
                selection.has_unique_match || !selection.is_ambiguous,
            "Two matching incoming CallStates must fail closed instead of selecting the first one");
    }

    private void test_cim_direct_target_removal_preserves_other_resource() {
        Jid phone;
        Jid laptop;
        try {
            phone = new Jid("alice@example.test/Phone");
            laptop = new Jid("alice@example.test/Laptop");
        } catch (InvalidJidError e) {
            fail_if_reached("Static CIM resource JID is invalid: %s".printf(
                e.message));
            return;
        }

        var targets = new CimTargetRegistry();
        targets.add(phone, MessageStanza.TYPE_CHAT);
        targets.add(laptop, MessageStanza.TYPE_CHAT);
        fail_if(!targets.remove_action_target(phone, MessageStanza.TYPE_CHAT,
                    "direct-reference", "direct-reference", false),
            "The exact rejecting resource must be removable");
        fail_if(targets.contains(phone, MessageStanza.TYPE_CHAT) ||
                !targets.contains(laptop, MessageStanza.TYPE_CHAT) ||
                targets.size != 1,
            "Removing one full-JID target must preserve the sibling resource");
    }

    private void test_cim_groupchat_terminal_waits_for_matching_echo() {
        try {
            var account = new Entities.Account(
                new Jid("alice@example.test"), "secret");
            var other_account = new Entities.Account(
                new Jid("bob@example.test"), "secret");
            Jid room = new Jid("room@conference.example.test");
            Jid other_room = new Jid(
                "other@conference.example.test");
            var deferred = new DeferredCimGroupchatTerminalRegistry();

            deferred.defer(account, room, "provisional-reference",
                CimTerminalSignalAction.RETRACT);
            deferred.defer(account, room, "provisional-reference",
                CimTerminalSignalAction.LEFT);
            fail_if(deferred.size != 1,
                "One account/room/provisional tuple may own only one terminal action");
            fail_if(deferred.take(other_account, room,
                        "provisional-reference") !=
                    CimTerminalSignalAction.NONE ||
                deferred.take(account, other_room,
                        "provisional-reference") !=
                    CimTerminalSignalAction.NONE ||
                deferred.take(account, room, "foreign-reference") !=
                    CimTerminalSignalAction.NONE || deferred.size != 1,
                "A foreign account, room, or provisional ID must not consume the deferred action");
            fail_if(deferred.take(account, room, "provisional-reference") !=
                        CimTerminalSignalAction.RETRACT || deferred.size != 0,
                "Only the matching room echo may release the first claimed terminal action");
        } catch (InvalidJidError e) {
            fail_if_reached("Static deferred CIM JID is invalid: %s".printf(
                e.message));
        }
    }

    private void test_cim_invite_replay_tombstone_is_exact_and_bounded() {
        try {
            var account = new Entities.Account(
                new Jid("alice@example.test"), "secret");
            var other_account = new Entities.Account(
                new Jid("bob@example.test"), "secret");
            Jid phone = new Jid("peer@example.test/Phone");
            Jid laptop = new Jid("peer@example.test/Laptop");
            Jid room_alice = new Jid(
                "room@conference.example.test/Alice");
            Jid room_bob = new Jid("room@conference.example.test/Bob");
            var replays = new CimInviteReplayRegistry();

            fail_if(!replays.try_claim(account, phone,
                        MessageStanza.TYPE_CHAT, "call-reference") ||
                    replays.try_claim(account, phone,
                        MessageStanza.TYPE_CHAT, "call-reference"),
                "The first exact direct invite must win and its replay must be ignored");
            fail_if(!replays.try_claim(other_account, phone,
                        MessageStanza.TYPE_CHAT, "call-reference") ||
                    !replays.try_claim(account, laptop,
                        MessageStanza.TYPE_CHAT, "call-reference"),
                "Account and full-JID resource are part of a direct replay key");
            fail_if(!replays.try_claim(account, room_alice,
                        MessageStanza.TYPE_GROUPCHAT, "room-reference") ||
                    replays.try_claim(account, room_bob,
                        MessageStanza.TYPE_GROUPCHAT, "room-reference"),
                "A groupchat replay key must normalize occupants to the assigning bare room");
            fail_if(!replays.try_claim(account, phone,
                        MessageStanza.TYPE_CHAT, "second-reference") ||
                    replays.size != 5,
                "A genuinely new reference must remain independently claimable");
            for (int i = 0; i < 520; i++) {
                fail_if(!replays.try_claim(account, phone,
                            MessageStanza.TYPE_CHAT,
                            "bounded-reference-%d".printf(i)),
                    "Every new reference must be claimable while old tombstones are evicted");
            }
            fail_if(replays.size != 512,
                "The replay registry must retain at most 512 tombstones");
            replays.clear();
            fail_if(replays.size != 0,
                "Replay tombstones must release their bounded timeout ownership");
        } catch (InvalidJidError e) {
            fail_if_reached("Static replay CIM JID is invalid: %s".printf(
                e.message));
        }
    }

    private void test_muji_reinvite_has_fresh_reference() {
        with_invite_fixture((f) => {
            var account = new Entities.Account(
                new Jid("alice@example.test"), "secret");
            Jid proposer = new Jid("carol@example.test/Desktop");
            MujiInviteAttempt first = f.arm();
            f.ready();
            Jid? departed;
            f.group.forget_muji_participant(f.occupant, out departed);
            MujiInviteAttempt second = f.arm();
            fail_if(first.proposal_id == second.proposal_id ||
                    first.proposal_id.strip() == "" ||
                    second.proposal_id.strip() == "" ||
                    first.call_id != f.call_id || second.call_id != f.call_id ||
                    first.group_call != second.group_call ||
                    first.stream != second.stream,
                "A re-invite needs a new proposal ID while retaining its exact conference context");

            var replays = new CimInviteReplayRegistry();
            foreach (MujiInviteAttempt attempt in
                    new MujiInviteAttempt[] { first, second }) {
                var method = new StanzaNode.build("muji", Xep.Muji.NS_URI)
                    .add_self_xmlns().put_attribute("room",
                        f.group.muc_jid.to_string());
                MessageStanza message = Xep.CallInvites.Module
                    .build_propose_message(attempt.proposal_id,
                        attempt.invitee, false, true,
                        MessageStanza.TYPE_CHAT, method, method);
                Xep.CallInvites.ParsedCallInvite? parsed =
                    Xep.CallInvites.Module.parse_call_invite(message);
                StanzaNode? compatibility = message.stanza.get_subnode(
                    "propose", Xep.CallInvites.NS_URI_CUSTOM);
                fail_if(parsed == null ||
                        ((!) parsed).call_id != attempt.proposal_id ||
                        message.id != attempt.proposal_id ||
                        Xep.UniqueStableStanzaIDs.get_origin_id(message) !=
                            attempt.proposal_id || compatibility == null ||
                        ((!) compatibility).get_attribute("id") !=
                            attempt.proposal_id ||
                        ((!) parsed).join_methods.size != 1 ||
                        ((!) parsed).join_methods[0].get_attribute("room") !=
                            f.group.muc_jid.to_string(),
                    "Standard and compatibility messages must reference this attempt, with the same MUJI room");
                fail_if(!replays.try_claim(account, proposer,
                            MessageStanza.TYPE_CHAT, attempt.proposal_id) ||
                        replays.try_claim(account, proposer,
                            MessageStanza.TYPE_CHAT, attempt.proposal_id),
                    "A fresh re-invite must pass the real replay registry while a duplicate of either message stays rejected");
            }
            replays.clear();
        });
    }

    private void test_muji_reinvite_rejects_stale_actions() {
        try {
            Jid phone = new Jid("bob@example.test/Phone");
            Jid laptop = new Jid("bob@example.test/Laptop");
            var targets = new CimTargetRegistry();
            targets.add(phone, MessageStanza.TYPE_CHAT);
            targets.add(laptop, MessageStanza.TYPE_CHAT);
            var old_snapshot = targets.snapshot();
            fail_if(!targets.replace_direct_reference(phone.bare_jid,
                        "fresh-proposal") || targets.size != 1,
                "A bare re-invite must supersede old full-resource conversion targets for this participant");
            foreach (Jid sender in new Jid[] { phone, laptop }) {
                fail_if(targets.matches_action(sender, MessageStanza.TYPE_CHAT,
                            "old-proposal", "old-proposal", false) ||
                        targets.matches_destination(sender,
                            MessageStanza.TYPE_CHAT, "old-proposal",
                            "old-proposal", false) ||
                        targets.remove_action_target(sender,
                            MessageStanza.TYPE_CHAT, "old-proposal",
                            "old-proposal", false),
                    "Stale reject/left/retract lookup, own carbon and late timeout removal must not match the replacement");
                fail_if(!targets.matches_action(sender,
                            MessageStanza.TYPE_CHAT, "fresh-proposal",
                            "old-proposal", false) ||
                        !targets.matches_destination(sender,
                            MessageStanza.TYPE_CHAT, "fresh-proposal",
                            "old-proposal", false),
                    "The new bare proposal must accept only its current reference from a real full resource");
            }
            foreach (CimTarget old_target in old_snapshot) {
                fail_if(old_target.resolve_reference("old-proposal", false) !=
                        "old-proposal",
                    "Replacement must not rewrite references captured by older work");
            }
            fail_if(!targets.remove_action_target(phone,
                        MessageStanza.TYPE_CHAT, "fresh-proposal",
                        "old-proposal", false) || targets.size != 0,
                "Only a response to the current proposal may retire its participant target");
        } catch (InvalidJidError error) {
            fail_if_reached("Static reinvite JID is invalid: " + error.message);
        }
    }

    private void test_muji_reinvite_preserves_other_references() {
        try {
            Jid bob = new Jid("bob@example.test/Phone");
            Jid carol = new Jid("carol@example.test/Phone");
            Jid room = new Jid("call@conference.example.test");
            var targets = new CimTargetRegistry();
            targets.add(bob, MessageStanza.TYPE_CHAT);
            targets.add(carol, MessageStanza.TYPE_CHAT);
            targets.add(room, MessageStanza.TYPE_GROUPCHAT);
            fail_if(!targets.bind_groupchat_reference(room, "room-stanza-id") ||
                    !targets.replace_direct_reference(bob.bare_jid,
                        "bob-first") ||
                    !targets.replace_direct_reference(carol, "carol-current"),
                "Parallel direct proposals and a room stanza-id must bind independently");
            var first_snapshot = targets.snapshot();
            fail_if(!targets.replace_direct_reference(bob.bare_jid,
                        "bob-second") ||
                    targets.replace_direct_reference(bob.bare_jid, " ") ||
                    targets.size != 3,
                "A fresh attempt replaces only its participant; an invalid reference changes nothing");
            fail_if(targets.matches_action(bob, MessageStanza.TYPE_CHAT,
                        "bob-first", "stable-conference", false) ||
                    targets.remove_action_target(bob.bare_jid,
                        MessageStanza.TYPE_CHAT, "bob-first",
                        "stable-conference", false) ||
                    !targets.matches_action(carol, MessageStanza.TYPE_CHAT,
                        "carol-current", "stable-conference", false) ||
                    !targets.matches_action(room,
                        MessageStanza.TYPE_GROUPCHAT, "room-stanza-id",
                        "stable-conference", false),
                "A late first-attempt cleanup must preserve the replacement, parallel peer and authoritative room reference");
            foreach (CimTarget target in targets.snapshot()) {
                string expected = target.message_type ==
                    MessageStanza.TYPE_GROUPCHAT ? "room-stanza-id" :
                    (target.jid.equals(carol) ? "carol-current" : "bob-second");
                fail_if(target.resolve_reference("stable-conference", false) !=
                        expected,
                    "Terminal signaling must use each current target's exact reference");
            }
            foreach (CimTarget target in first_snapshot) {
                if (target.jid.equals(bob.bare_jid)) {
                    fail_if(target.resolve_reference("stable-conference", false) !=
                            "bob-first",
                        "A replaced target object must retain its original proposal identity");
                }
            }
            fail_if(targets.bind_groupchat_reference(room, "bob-second"),
                "A fresh direct proposal must never rebind the room's stanza-id");
        } catch (InvalidJidError error) {
            fail_if_reached("Static parallel reinvite JID is invalid: " + error.message);
        }
    }

    private void test_direct_to_muji_never_escalates_camera() {
        bool effective_video;
        fail_if(CallState.direct_to_muji_media_allowed(false, true,
                out effective_video) || effective_video,
            "An audio-only direct call must reject a MUJI camera escalation");
        fail_if(CallState.direct_to_muji_media_allowed(true, false,
                out effective_video) || effective_video,
            "A video direct leg must not retain hidden video in an audio-only MUJI room");
        fail_if(!CallState.direct_to_muji_media_allowed(true, true,
                out effective_video) || !effective_video,
            "An explicitly video-enabled direct call may preserve video");
    }

    private void test_muji_media_policy_downgrades_video_and_requires_audio() {
        fail_if(CallState.muji_media_policy_action("video",
                Xep.Muji.CodecAvailability.OPTIONAL_UNAVAILABLE) !=
                MujiMediaPolicyAction.DOWNGRADE_TO_AUDIO,
            "Missing optional video codecs must make the whole group audio-only");
        fail_if(CallState.muji_media_policy_action("audio",
                Xep.Muji.CodecAvailability.REQUIRED_UNAVAILABLE) !=
                MujiMediaPolicyAction.END_CALL,
            "Missing required audio codecs must end the call fail-closed");
        fail_if(CallState.muji_media_policy_action("audio",
                Xep.Muji.CodecAvailability.AVAILABLE) !=
                MujiMediaPolicyAction.NONE,
            "Available required audio must not change the call lifecycle");
    }

    private void test_call_capability_excludes_groupchat_private_messages() {
        fail_if(!Calls.is_supported_call_conversation_type(
                Entities.Conversation.Type.CHAT) ||
                !Calls.is_supported_call_conversation_type(
                    Entities.Conversation.Type.GROUPCHAT),
            "Direct chats and full group conversations must remain callable");
        fail_if(Calls.is_supported_call_conversation_type(
                Entities.Conversation.Type.GROUPCHAT_PM),
            "A private message inside a MUC must not expose the group-call action");
    }

    private void test_stale_group_join_cannot_publish_owned_state() {
        var lifecycle = new CallLifecycleGeneration();
        var join = new GroupJoinPublicationTransaction(lifecycle);

        var left_lifecycle = new CallLifecycleGeneration();
        var left_join = new GroupJoinPublicationTransaction(left_lifecycle);
        fail_if(left_join.try_commit(false) || left_join.committed,
            "A MUJI result that left during preparing must never cross the publication boundary");

        // Models end() winning while join_call() is suspended. The production
        // continuation must pass this exact transaction before assigning both
        // group_call and its immutable media-engine owner.
        lifecycle.close();
        bool group_published = false;
        bool engine_published = false;
        bool peer_published = false;
        bool signal_published = false;
        if (join.try_commit()) {
            group_published = true;
            engine_published = true;
        }
        if (join.try_publish_event()) peer_published = true;
        if (join.try_publish_event()) signal_published = true;

        fail_if(join.committed || group_published || engine_published ||
                peer_published || signal_published ||
                join.published_events != 0,
            "A join continuation stale after teardown must publish no group, engine, peer, or signal");
    }

    private void test_google_muji_accept_never_routes_to_legacy_peer() {
        uint legacy_resource_calls = 0;
        CallAcceptedRoute before_presence = Calls.select_call_accepted_route(
            false, CallMediaBackend.GOOGLE_WEBRTC, false, true);
        if (before_presence == CallAcceptedRoute.LEGACY_RESOURCE) {
            legacy_resource_calls++;
        }
        CallAcceptedRoute after_presence = Calls.select_call_accepted_route(
            false, CallMediaBackend.GOOGLE_WEBRTC, true, true);
        if (after_presence == CallAcceptedRoute.LEGACY_RESOURCE) {
            legacy_resource_calls++;
        }

        fail_if(before_presence != CallAcceptedRoute.GOOGLE_WAIT_FOR_MUJI ||
                after_presence != CallAcceptedRoute.GOOGLE_MUJI_OWNED ||
                legacy_resource_calls != 0,
            "Google MUJI accept must remain signaling-only before and after participant presence");
    }

    private void test_streamless_terminal_cleanup_claims_fake_peer_once() {
        var teardown = new TerminalTeardownGate();
        uint fake_peer_close_count = 0;
        uint fake_peer_release_count = 0;

        // No stream participates in this ownership gate. CallState uses the
        // same claim before touching protocol-only XMPP cleanup.
        for (int attempt = 0; attempt < 2; attempt++) {
            if (!teardown.try_claim()) continue;
            fake_peer_close_count++;
            fake_peer_release_count++;
        }
        fail_if(!teardown.claimed || fake_peer_close_count != 1 ||
                fake_peer_release_count != 1,
            "Streamless terminal cleanup must close and release each owned peer exactly once");
    }

    private void test_failed_private_config_rolls_back_without_proposal() {
        var conversion = new PrivateMujiConversionTransaction();
        conversion.mark_room_joined();
        conversion.rollback();
        uint proposals_sent = 0;
        if (conversion.try_claim_proposal()) proposals_sent++;

        fail_if(!conversion.rolled_back || conversion.may_propose() ||
                conversion.proposal_claimed || proposals_sent != 0,
            "A failed private-room configuration must roll back and authorize zero MUJI proposals");

        var committed = new PrivateMujiConversionTransaction();
        committed.mark_room_joined();
        committed.mark_private_config_applied();
        fail_if(!committed.try_claim_proposal() ||
                committed.try_claim_proposal(),
            "Only one proposal may claim a successfully committed private-room transaction");
    }

    private void test_incoming_group_source_stale_blocks_join_and_accept() {
        var lifecycle = new CallLifecycleGeneration();
        var accept = new IncomingGroupAcceptTransaction(lifecycle);
        var join = new GroupJoinPublicationTransaction(lifecycle);
        bool group_published = false;
        bool accept_sent = false;

        fail_if(!accept.may_continue(true),
            "A freshly captured live private source must allow join work");
        // Models the source room leaving/reconnecting while join_call() is
        // suspended. Production checks this before its publication commit.
        if (accept.may_continue(false) && join.try_commit() &&
                accept.try_publish_join(false)) {
            group_published = true;
        }
        if (accept.try_claim_accept(false)) accept_sent = true;

        fail_if(group_published || join.committed || accept.join_published ||
                accept.accept_claimed || accept_sent,
            "A stale source-room lifecycle must publish neither MUJI join nor accept");
    }

    private void test_incoming_group_inviter_requires_exact_live_resource() {
        try {
            Jid occupant = new Jid(
                "private@conference.example.test/Monocles");
            Jid expected_real = new Jid(
                "alice@example.test/Phone");
            Jid other_resource = new Jid(
                "alice@example.test/Desktop");

            fail_if(!CallState.incoming_group_inviter_is_current(
                    occupant, expected_real, expected_real, true),
                "The exact live inviter resource must remain authorized");
            fail_if(CallState.incoming_group_inviter_is_current(
                    occupant, expected_real, other_resource, true),
                "Another resource of the same bare JID must not inherit a MUJI invite");
            fail_if(CallState.incoming_group_inviter_is_current(
                    occupant, expected_real, expected_real, false),
                "An inviter that left the room must block join and accept");
            fail_if(CallState.incoming_group_inviter_is_current(
                    occupant, expected_real, null, true),
                "Missing current real-JID evidence must fail closed");
            fail_if(!CallState.incoming_group_inviter_is_current(
                    null, null, null, false),
                "A groupchat source uses the separately validated room occupant path");
        } catch (Xmpp.InvalidJidError e) {
            fail_if_reached("Static MUJI inviter JID is invalid: %s"
                .printf(e.message));
        }
    }

    private void test_establishing_retract_invalidates_group_accept() {
        var lifecycle = new CallLifecycleGeneration();
        var accept = new IncomingGroupAcceptTransaction(lifecycle);
        fail_if(!CallState.call_invite_retractable(
                    Entities.Call.State.ESTABLISHING) ||
                CallState.call_invite_retractable(
                    Entities.Call.State.IN_PROGRESS),
            "Retract must remain valid during async accept but not after the call is established");

        // finish_remote_retract() reaches begin_teardown(), which closes this
        // lifecycle and invalidates the same production accept transaction.
        lifecycle.close();
        accept.invalidate();
        bool join_published = accept.try_publish_join(true);
        bool accept_sent = accept.try_claim_accept(true);
        fail_if(join_published || accept_sent,
            "A valid ESTABLISHING retract must make the pending join and accept stale");
    }

    private void test_muji_video_device_dispatches_once_to_group_owner() {
        Jid room;
        try {
            room = new Jid("call@conference.example.test");
        } catch (InvalidJidError e) {
            fail_if_reached("Static MUJI room JID is invalid: %s".printf(
                e.message));
            return;
        }
        var group = new AuditMujiGroupSession(room);
        var device = new AuditVideoDevice();
        try {
            CallState.set_muji_group_video_device_once(group, device);
        } catch (GLib.Error e) {
            fail_if_reached("Audit group video dispatch failed: %s".printf(
                e.message));
            return;
        }
        fail_if(group.video_device_calls != 1,
            "A MUJI camera change must reach the group owner exactly once even with zero peers");
    }

    private void test_direct_camera_is_inherited_by_new_group_owner() {
        Jid room;
        try {
            room = new Jid("converted@conference.example.test");
        } catch (InvalidJidError e) {
            fail_if_reached("Static MUJI room JID is invalid: %s".printf(
                e.message));
            return;
        }
        var group = new AuditMujiGroupSession(room);
        var cached_direct_device = new AuditVideoDevice();
        bool inherited;
        try {
            inherited = CallState.inherit_selected_muji_group_video_device(
                group, cached_direct_device, true);
        } catch (GLib.Error e) {
            fail_if_reached("Cached camera inheritance failed: %s".printf(
                e.message));
            return;
        }
        fail_if(!inherited || group.video_device_calls != 1,
            "A newly published group owner must inherit the latest direct-call camera exactly once");
    }

    private void test_groupchat_participant_reject_keeps_room_target() {
        Jid room;
        Jid occupant;
        Jid direct;
        try {
            room = new Jid("private@conference.example.test");
            occupant = new Jid("private@conference.example.test/c");
            direct = new Jid("d@example.test/device");
        } catch (InvalidJidError e) {
            fail_if_reached("Static CIM target JID is invalid: %s".printf(
                e.message));
            return;
        }
        var targets = new CimTargetRegistry();
        targets.add(room, MessageStanza.TYPE_GROUPCHAT);
        targets.add(direct.bare_jid, MessageStanza.TYPE_CHAT);

        fail_if(targets.remove_rejected_participant(occupant,
                    MessageStanza.TYPE_GROUPCHAT) ||
                !targets.contains(room, MessageStanza.TYPE_GROUPCHAT),
            "One room occupant rejection must retain the shared bare-room CIM target");
        fail_if(!targets.remove_rejected_participant(direct,
                    MessageStanza.TYPE_CHAT) ||
                targets.contains(direct.bare_jid, MessageStanza.TYPE_CHAT),
            "A direct invite rejection must remove only its own direct target");
    }

    private void test_published_muji_rooms_leave_without_destroy() {
        var creator = new MujiPublishedRoomLifecycle(true);
        var participant = new MujiPublishedRoomLifecycle(false);
        creator.mark_published();
        participant.mark_published();
        uint leave_count = 0;
        uint destroy_count = 0;
        if (creator.claim_terminal_exit() ==
                MujiPublishedRoomExitAction.LEAVE) leave_count++;
        if (participant.claim_terminal_exit() ==
                MujiPublishedRoomExitAction.LEAVE) leave_count++;
        // The published lifecycle intentionally has no destroy action.
        fail_if(creator.claim_terminal_exit() !=
                    MujiPublishedRoomExitAction.NONE ||
                participant.claim_terminal_exit() !=
                    MujiPublishedRoomExitAction.NONE ||
                leave_count != 2 || destroy_count != 0,
            "Creator and participant hangup must each leave once and never destroy the published room");

        var invite_creator = new MujiPublishedRoomLifecycle(true);
        var invite_participant = new MujiPublishedRoomLifecycle(false);
        invite_creator.mark_published();
        invite_participant.mark_published();
        fail_if(!invite_creator.can_manage_invites(true) ||
                invite_creator.can_manage_invites(false) ||
                invite_participant.can_manage_invites(true),
            "Only the local creator may expose invite controls after private config commit");
    }

    private void test_delayed_peer_capability_cannot_start_after_teardown() {
        var lifecycle = new CallLifecycleGeneration();
        var expected_stream = new Object();
        var transaction = new PeerCallInitiationTransaction(lifecycle,
            expected_stream);
        int terminal_state = (int) Entities.Call.State.MISSED;

        fail_if(!transaction.may_continue(expected_stream),
            "The outgoing capability lookup must begin on its captured stream");
        // Models end() while get_call_resources()/contains_jmi_resources()
        // is delayed. The terminal state is already owned by teardown.
        lifecycle.close();
        bool session_started =
            transaction.try_claim_session_start(expected_stream);
        bool proposal_sent = transaction.try_claim_proposal(expected_stream);

        fail_if(session_started || proposal_sent ||
                transaction.session_start_claims != 0 ||
                transaction.proposal_claims != 0 ||
                terminal_state != (int) Entities.Call.State.MISSED,
            "A stale capability continuation must create no session/proposal and must not replace terminal state");
    }

    private void test_duplicate_group_invite_preserves_live_call() {
        bool duplicate_allowed = CallState.direct_group_conversion_allowed(
            true, false, true, false, false, false,
            Entities.Call.State.IN_PROGRESS, "call-1", "call-2");
        bool joining_duplicate_allowed =
            CallState.direct_group_conversion_allowed(true, false, false,
                true, false, true, Entities.Call.State.ESTABLISHING,
                "call-1", "call-1");
        bool active_group_blocks_second_state =
            Calls.existing_call_blocks_new_muji(
                Entities.Call.State.IN_PROGRESS, false);
        fail_if(duplicate_allowed || joining_duplicate_allowed ||
                !active_group_blocks_second_state,
            "A duplicate/new invite must not re-enter conversion or terminate the existing group call");
        fail_if(!CallState.direct_group_conversion_allowed(true, false,
                false, false, false, false,
                Entities.Call.State.IN_PROGRESS, null, "call-1"),
            "A live unconverted direct call must still allow its first MUJI conversion");
    }

    private void test_muji_invitees_receive_member_affiliation() {
        fail_if(CallState.MUJI_INVITEE_AFFILIATION != "member",
            "MUJI invitees need membership only; owner would grant room destruction/admin rights");
    }

    private void test_empty_media_peer_set_waits_for_preparing_participant() {
        var lifecycle = new MujiPublishedRoomLifecycle(true);
        lifecycle.mark_published();
        fail_if(!lifecycle.should_wait_for_preparing_peer(0),
            "A published group with zero media peers must wait for a preparing room participant");
        fail_if(lifecycle.should_wait_for_preparing_peer(1),
            "The empty-room timeout is only needed after the last media peer leaves");
        fail_if(lifecycle.claim_terminal_exit() !=
                    MujiPublishedRoomExitAction.LEAVE ||
                lifecycle.should_wait_for_preparing_peer(0),
            "Only the bounded terminal timeout may end the empty published group");
    }

    private void test_muji_empty_timeout_only_ends_unanswered_groups() {
        foreach (Entities.Call.State state in new Entities.Call.State[] {
                Entities.Call.State.RINGING, Entities.Call.State.ESTABLISHING }) {
            fail_if(!CallState.muji_initial_peer_timeout_required(state, 0, true),
                "An unanswered zero-peer MUJI call must retain its initial bounded wait");
            fail_if(CallState.muji_initial_peer_timeout_required(state, 1, true),
                "A published media peer must disarm the initial empty-room timeout");
        }
        fail_if(CallState.muji_initial_peer_timeout_required(
                Entities.Call.State.IN_PROGRESS, 0, true),
            "Losing the last established MUJI peer must not rearm or fire an initial wait timeout");
        foreach (Entities.Call.State state in new Entities.Call.State[] {
                Entities.Call.State.ENDED, Entities.Call.State.FAILED,
                Entities.Call.State.MISSED }) {
            fail_if(CallState.muji_initial_peer_timeout_required(state, 0, true),
                "A delayed empty-room callback must not terminate an already terminal call");
        }
        fail_if(CallState.muji_initial_peer_timeout_required(
                Entities.Call.State.ESTABLISHING, 0, false),
            "The MUJI wait timeout must not apply after group ownership has been released");
    }

    private void test_hangup_before_cim_accept_published_sends_reject() {
        var publication = new CimAcceptPublication();
        fail_if(publication.terminal_action(
                    Entities.Call.DIRECTION_INCOMING,
                    Entities.Call.State.ESTABLISHING) !=
                CimTerminalSignalAction.REJECT,
            "Local hangup while MUJI join is pending must reject the unaccepted invite");
        fail_if(publication.claim_terminal_action(
                    Entities.Call.DIRECTION_INCOMING,
                    Entities.Call.State.ESTABLISHING) !=
                    CimTerminalSignalAction.REJECT ||
                publication.claim_terminal_action(
                    Entities.Call.DIRECTION_INCOMING,
                    Entities.Call.State.ESTABLISHING) !=
                    CimTerminalSignalAction.NONE,
            "Local pre-accept failure must own exactly one CIM reject");
        publication = new CimAcceptPublication();
        publication.mark_published();
        fail_if(publication.terminal_action(
                    Entities.Call.DIRECTION_INCOMING,
                    Entities.Call.State.ESTABLISHING) !=
                CimTerminalSignalAction.LEFT,
            "Only a published CIM accept may turn later hangup into left");
    }

    private void test_shared_groupchat_reject_cannot_close_other_recipient() {
        CimRejectDisposition other_occupant =
            CallState.select_cim_reject_disposition(false, false, true,
                true, false,
                MessageStanza.TYPE_GROUPCHAT);
        CimRejectDisposition own_carbon =
            CallState.select_cim_reject_disposition(true, false, false,
                false, false,
                MessageStanza.TYPE_GROUPCHAT);
        fail_if(other_occupant != CimRejectDisposition.IGNORE ||
                own_carbon != CimRejectDisposition.FINISH_LOCAL,
            "Another occupant's shared-room reject must leave this recipient ringing; only own carbon closes it");
    }

    private void test_call_invite_protocol_rejects_muc_private_message() {
        fail_if(Calls.call_invite_source_allowed(MessageStanza.TYPE_CHAT,
                    true) ||
                !Calls.call_invite_source_allowed(
                    MessageStanza.TYPE_GROUPCHAT, true) ||
                !Calls.call_invite_source_allowed(MessageStanza.TYPE_CHAT,
                    false),
            "Call Invites from a known MUC occupant must use the room GROUPCHAT path, never GROUPCHAT_PM chat");
    }

    private void test_parallel_invites_wait_for_private_config_commit() {
        Jid first;
        Jid second;
        try {
            first = new Jid("first@example.test/device");
            second = new Jid("second@example.test/device");
        } catch (InvalidJidError e) {
            fail_if_reached("Static pending invite JID is invalid: %s".printf(
                e.message));
            return;
        }
        var pending = new PendingMujiInviteRegistry();
        pending.add(first);
        pending.add(second);
        pending.add(second.bare_jid);
        var conversion = new PrivateMujiConversionTransaction();
        conversion.mark_room_joined();

        uint affiliations = 0;
        uint proposals = 0;
        if (CallState.private_room_ready_for_invites(true, true,
                conversion)) {
            affiliations += (uint) pending.size;
            proposals += (uint) pending.size;
        }
        fail_if(affiliations != 0 || proposals != 0 || pending.size != 2,
            "Parallel invites must stay de-duplicated and send nothing before private config commit");

        conversion.mark_private_config_applied();
        Gee.ArrayList<Jid> released = pending.drain();
        if (CallState.private_room_ready_for_invites(false, true,
                conversion)) {
            affiliations += (uint) released.size;
            proposals += (uint) released.size;
        }
        fail_if(released.size != 2 || affiliations != 2 || proposals != 2,
            "After private config commit each queued invite must publish exactly once");

        var failed = new PrivateMujiConversionTransaction();
        failed.mark_room_joined();
        failed.rollback();
        fail_if(CallState.private_room_ready_for_invites(false, true, failed),
            "Private config rollback must authorize zero queued affiliations or proposals");
    }

    private void test_cim_left_routes_only_owned_call_or_participant() {
        Jid room;
        Jid room_occupant;
        Jid direct_target;
        Jid direct_sender;
        try {
            room = new Jid("source-room@muc.example.test");
            room_occupant = room.with_resource("alice");
            direct_target = new Jid("bob@example.test");
            direct_sender = direct_target.with_resource("phone");
        } catch (InvalidJidError e) {
            fail_if_reached("Static CIM routing JID is invalid: %s".printf(
                e.message));
            return;
        }

        var targets = new CimTargetRegistry();
        targets.add(room, MessageStanza.TYPE_GROUPCHAT);
        targets.add(direct_target, MessageStanza.TYPE_CHAT);

        CimLeftDisposition shared_room =
            CallState.select_cim_left_disposition(false, false, true,
                targets.contains_participant(room_occupant,
                    MessageStanza.TYPE_GROUPCHAT), true,
                MessageStanza.TYPE_GROUPCHAT);
        CimLeftDisposition direct_participant =
            CallState.select_cim_left_disposition(false, false, true,
                targets.contains_participant(direct_sender,
                    MessageStanza.TYPE_CHAT), true,
                MessageStanza.TYPE_CHAT);
        CimLeftDisposition unowned_sender =
            CallState.select_cim_left_disposition(false, false, true,
                false, true, MessageStanza.TYPE_CHAT);

        fail_if(shared_room != CimLeftDisposition.IGNORE,
            "One occupant's GROUPCHAT left must not terminate the shared call");
        fail_if(direct_participant !=
                    CimLeftDisposition.REMOVE_DIRECT_PARTICIPANT ||
                unowned_sender != CimLeftDisposition.IGNORE,
            "Only an owned direct target may remove one group participant");
        fail_if(!targets.remove_rejected_participant(direct_sender,
                    MessageStanza.TYPE_CHAT) ||
                !targets.contains(room, MessageStanza.TYPE_GROUPCHAT),
            "Direct left must remove only that target and retain the shared room target");
    }

    private void test_failed_muji_peer_expect_keeps_empty_timeout_owned() {
        var failed_expect = new MujiPeerJoinPublication();
        fail_if(failed_expect.claim_empty_timeout_cancel(),
            "Presence without a published PeerState must keep the empty-room timeout armed");

        var published_peer = new MujiPeerJoinPublication();
        published_peer.mark_peer_published();
        fail_if(!published_peer.claim_empty_timeout_cancel() ||
                published_peer.claim_empty_timeout_cancel(),
            "A successfully published PeerState must cancel the watchdog exactly once");
    }

    private void test_foreign_private_reject_cannot_cancel_incoming_room_invite() {
        CimRejectDisposition forged_private =
            CallState.select_cim_reject_disposition(false, false, false,
                true, false, MessageStanza.TYPE_CHAT);
        CimRejectDisposition owned_outgoing_target =
            CallState.select_cim_reject_disposition(false, false, true,
                true, true, MessageStanza.TYPE_CHAT);
        fail_if(forged_private != CimRejectDisposition.IGNORE,
            "A foreign private reject must not close an incoming shared-room invitation");
        fail_if(owned_outgoing_target !=
                    CimRejectDisposition.REMOVE_DIRECT_TARGET,
            "Only a response from our outgoing direct target may update that group invite");
    }
}

}
